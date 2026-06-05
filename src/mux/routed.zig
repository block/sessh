const std = @import("std");

const client_control_args = @import("client_control_args.zig");
const io = @import("../core/io.zig");
const mux_local = @import("local.zig");
const process_exit = @import("../core/process_exit.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub fn runInvocation(
    allocator: std.mem.Allocator,
    exe: []const u8,
    parsed: anytype,
) !void {
    if (parsed.action == .list and parsed.list_client_target != null) {
        if (try remoteRouteForClientListTarget(allocator, parsed.list_client_target.?)) |route| {
            var route_copy = route;
            defer route_copy.deinit(allocator);
            const remote_target = if (std.mem.startsWith(u8, parsed.list_client_target.?, session_registry.client_guid_prefix))
                parsed.list_client_target.?
            else
                route_copy.guid;
            const exit_status = try runRemoteClientListCommand(allocator, exe, &route_copy, remote_target, parsed.list_jsonl);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        }
    }

    if (isClientControlAction(parsed.action)) {
        if (try remoteRouteForClientControlTarget(allocator, parsed)) |route| {
            var route_copy = route;
            defer route_copy.deinit(allocator);
            const exit_status = try runRemoteClientControlCommand(allocator, exe, &route_copy, parsed);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        }
    }

    return mux_local.runInvocation(allocator, exe, parsed);
}

fn isClientControlAction(action: anytype) bool {
    return switch (action) {
        .detach_client, .repaint_client, .debug_client => true,
        else => false,
    };
}

fn remoteRouteForClientListTarget(allocator: std.mem.Allocator, target: []const u8) !?session_registry.Route {
    if (std.mem.eql(u8, target, "incoming") or
        std.mem.eql(u8, target, "outgoing") or
        std.mem.eql(u8, target, "session"))
    {
        return null;
    }
    if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) {
        return remoteRouteForClientGuid(allocator, target);
    }
    var route = session_registry.readRouteForRef(allocator, target) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer route.deinit(allocator);
    if (routeIsRemote(&route)) return route;
    route.deinit(allocator);
    return null;
}

fn remoteRouteForClientControlTarget(allocator: std.mem.Allocator, parsed: anytype) !?session_registry.Route {
    if (parsed.client_session_ref != null) return null;
    if (parsed.client_target != .client_guid) return null;
    return remoteRouteForClientGuid(allocator, parsed.client_guid.?);
}

fn remoteRouteForClientGuid(allocator: std.mem.Allocator, client_guid: []const u8) !?session_registry.Route {
    const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, client_guid) catch |err| switch (err) {
        error.FileNotFound, error.InvalidClientId, error.AmbiguousClientId => null,
        else => return err,
    };
    if (socket_path) |path| {
        allocator.free(path);
        return null;
    }

    var route = session_registry.readRouteForClientGuid(allocator, client_guid) catch |err| switch (err) {
        error.FileNotFound, error.InvalidClientId, error.AmbiguousClientId => return null,
        else => return err,
    };
    errdefer route.deinit(allocator);
    if (routeIsRemote(&route)) return route;
    route.deinit(allocator);
    return null;
}

fn routeIsRemote(route: *const session_registry.Route) bool {
    return route.host.len > 0 and !std.mem.eql(u8, route.host, ".");
}

fn runRemoteClientListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    target: []const u8,
    jsonl: bool,
) !u8 {
    var client_arg: ?[]u8 = null;
    defer if (client_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, "list");
    try argv.appendSlice(allocator, route.ssh_options);
    try argv.append(allocator, "--host");
    try argv.append(allocator, route.host);
    client_arg = try std.fmt.allocPrint(allocator, "--client={s}", .{target});
    try argv.append(allocator, client_arg.?);
    if (jsonl) try argv.append(allocator, "--jsonl");

    return runAndForward(allocator, argv.items);
}

fn runRemoteClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    parsed: anytype,
) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try client_control_args.appendCommandName(allocator, &argv, parsed.action);
    try argv.appendSlice(allocator, route.ssh_options);
    try argv.append(allocator, "--host");
    try argv.append(allocator, route.host);
    try argv.append(allocator, "--id");
    try argv.append(allocator, route.guid);
    try client_control_args.appendTail(allocator, &argv, parsed, null);
    return runAndForward(allocator, argv.items);
}

fn runAndForward(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try io.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io.writeAll(2, result.stderr);
    return switch (result.term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}
