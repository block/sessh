const std = @import("std");

const io = @import("../core/io.zig");
const mux_cli = @import("cli.zig");
const mux_local = @import("local.zig");
const process_exit = @import("../core/process_exit.zig");
const remote_command = @import("../runtime/remote_command.zig");
const session_registry = @import("../runtime/session_registry.zig");
const shell = @import("../core/shell.zig");

pub fn runCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    command: mux_cli.Command,
    remote_runner: ?*remote_command.Runner,
) !void {
    return switch (command) {
        .list => |list| runListCommand(allocator, exe, list, remote_runner),
        .kill => |kill| mux_local.runKillCommand(allocator, kill),
        .detach => |control| runClientControlCommand(allocator, exe, .detach, control),
        .repaint => |control| runClientControlCommand(allocator, exe, .repaint, control),
        .debug => |debug| runClientControlCommand(allocator, exe, switch (debug.action) {
            .sever_connection => .debug_sever_connection,
            .unresponsive_connection => .debug_unresponsive_connection,
        }, debug.control),
        .new, .attach => unreachable,
    };
}

fn runListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    list: mux_cli.List,
    remote_runner: ?*remote_command.Runner,
) !void {
    if (list.client_target) |target| {
        if (try remoteRouteForClientListTarget(allocator, target)) |route| {
            var route_copy = route;
            defer route_copy.deinit(allocator);
            const remote_target = if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix))
                target
            else
                route_copy.guid;
            const exit_status = try runRemoteClientListCommand(allocator, exe, &route_copy, remote_target, list.jsonl);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        }
    }

    return mux_local.runListCommand(allocator, exe, list, remote_runner);
}

fn runClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    kind: mux_local.ClientControlKind,
    control: mux_cli.ClientControl,
) !void {
    if (try remoteRouteForClientControlTarget(allocator, control)) |route| {
        var route_copy = route;
        defer route_copy.deinit(allocator);
        const exit_status = try runRemoteClientControlCommand(allocator, exe, &route_copy, kind, control);
        if (exit_status != 0) return process_exit.request(exit_status);
        return;
    }

    return mux_local.runCommand(allocator, exe, switch (kind) {
        .detach => .{ .detach = control },
        .repaint => .{ .repaint = control },
        .debug_sever_connection => .{ .debug = .{
            .action = .sever_connection,
            .control = control,
            .seconds = control.seconds,
        } },
        .debug_unresponsive_connection => .{ .debug = .{
            .action = .unresponsive_connection,
            .control = control,
            .seconds = control.seconds,
        } },
    }, null);
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

fn remoteRouteForClientControlTarget(allocator: std.mem.Allocator, control: mux_cli.ClientControl) !?session_registry.Route {
    if (control.session_ref != null) return null;
    if (mux_cli.clientControlTarget(control) != .client_guid) return null;
    return remoteRouteForClientGuid(allocator, control.client_guid.?);
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
    var ssh_options_arg: ?[]u8 = null;
    defer if (ssh_options_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, "list");
    ssh_options_arg = try appendRoutedTarget(allocator, &argv, route);
    client_arg = try std.fmt.allocPrint(allocator, "--client={s}", .{target});
    try argv.append(allocator, client_arg.?);
    if (jsonl) try argv.append(allocator, "--jsonl");

    return runAndForward(allocator, argv.items);
}

fn runRemoteClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    kind: mux_local.ClientControlKind,
    control: mux_cli.ClientControl,
) !u8 {
    var ssh_options_arg: ?[]u8 = null;
    defer if (ssh_options_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try appendClientControlCommandName(allocator, &argv, kind);
    ssh_options_arg = try appendRoutedTarget(allocator, &argv, route);
    try argv.append(allocator, "--id");
    try argv.append(allocator, route.guid);
    try appendClientControlTail(allocator, &argv, kind, control, null);
    return runAndForward(allocator, argv.items);
}

fn appendRoutedTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    route: *const session_registry.Route,
) !?[]u8 {
    const ssh_options_arg = if (route.ssh_options.len > 0) try shell.joinArgs(allocator, route.ssh_options) else null;
    if (ssh_options_arg) |value| {
        try out.append(allocator, "--ssh-options");
        try out.append(allocator, value);
    }
    try out.append(allocator, "--host");
    try out.append(allocator, route.host);
    return ssh_options_arg;
}

fn appendClientControlCommandName(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    kind: mux_local.ClientControlKind,
) !void {
    switch (kind) {
        .detach => try out.append(allocator, "detach"),
        .repaint => try out.append(allocator, "repaint"),
        .debug_sever_connection, .debug_unresponsive_connection => try out.append(allocator, "debug"),
    }
}

fn appendClientControlTail(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    kind: mux_local.ClientControlKind,
    control: mux_cli.ClientControl,
    session_ref: ?[]const u8,
) !void {
    switch (kind) {
        .debug_sever_connection => try out.append(allocator, "sever-connection"),
        .debug_unresponsive_connection => try out.append(allocator, "unresponsive-connection"),
        .detach, .repaint => {},
    }
    switch (mux_cli.clientControlTarget(control)) {
        .default => {},
        .all => try out.append(allocator, "--all"),
        .last_input => try out.append(allocator, "--last-input"),
        .client_guid => try out.append(allocator, control.client_guid.?),
    }
    if (control.scrollback) try out.append(allocator, "--scrollback");
    if (control.seconds) |seconds| {
        try out.append(allocator, "--seconds");
        try out.append(allocator, seconds);
    }
    if (session_ref) |ref| try out.append(allocator, ref);
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
