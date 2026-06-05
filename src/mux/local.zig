const std = @import("std");

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");
const route_commands = @import("../runtime/route_commands.zig");
const runtime_commands = @import("../runtime/commands.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub fn runInvocation(
    allocator: std.mem.Allocator,
    exe: []const u8,
    parsed: anytype,
) !void {
    if (parsed.capture_tty_transcript != null and parsed.action != .new and parsed.action != .attach) {
        try io.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }

    switch (parsed.action) {
        .list => {
            if (parsed.list_client_target) |target| {
                const exit_status = try runtime_commands.runListCommand(allocator, .{
                    .format = if (parsed.list_jsonl) .jsonl else .table,
                    .client_selector = clientListSelector(target),
                });
                if (exit_status != 0) return process_exit.request(exit_status);
                return;
            }
            const exit_status = try route_commands.runLocalListCommand(
                allocator,
                exe,
                parsed.list_refresh,
                parsed.list_include_cached_routes,
                parsed.list_jsonl,
                parsed.list_exited,
                parsed.list_all,
                null,
            );
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var kill_refs: ?LocalKillRefs = null;
            defer if (kill_refs) |*refs| refs.deinit(allocator);
            if (parsed.kill_request_jsons.len == 0) {
                kill_refs = resolveLocalKillRefs(allocator, parsed) catch |err| switch (err) {
                    error.MissingCurrentSession, error.MissingKillTarget => {
                        try writeLocalArgError(err);
                        return process_exit.request(64);
                    },
                    else => return err,
                };
            }
            return runLocalKillCommand(allocator, parsed, if (kill_refs) |refs| refs.refs else &.{});
        },
        .kill_all => {
            return runtime_commands.runKillCommand(allocator, .{
                .format = if (parsed.kill_jsonl) .jsonl else .text,
                .all = true,
            });
        },
        .detach_client, .repaint_client, .debug_client => {
            runLocalClientControlCommand(allocator, parsed) catch |err| switch (err) {
                error.MissingSessionRef => {
                    try io.writeAll(2, "sessh: client command requires an ID outside a sessh session\n");
                    return process_exit.request(64);
                },
                error.AmbiguousClientId => {
                    try io.writeAll(2, "sessh: client id is ambiguous\n");
                    return process_exit.request(1);
                },
                error.InvalidClientId => {
                    try io.writeAll(2, "sessh: invalid client id\n");
                    return process_exit.request(64);
                },
                else => return err,
            };
            return;
        },
        .new, .attach => unreachable,
    }
}

fn writeLocalArgError(err: anyerror) !void {
    switch (err) {
        error.MissingKillTarget => try io.writeAll(2, "sesshmux: kill requires --all, a guid, or --current\n"),
        error.MissingCurrentSession => try io.writeAll(2, "sesshmux: --current requires $SESSH_GUID\n"),
        else => try io.stderrPrint("sessh: invalid local command: {t}\n", .{err}),
    }
}

const LocalKillRefs = struct {
    refs: []const []const u8,
    owned_refs: ?[]const []const u8 = null,
    owned_current: ?[]u8 = null,

    fn deinit(self: *LocalKillRefs, allocator: std.mem.Allocator) void {
        if (self.owned_refs) |value| allocator.free(value);
        if (self.owned_current) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn resolveLocalKillRefs(allocator: std.mem.Allocator, parsed: anytype) !LocalKillRefs {
    if (parsed.kill_ids.len > 0) return .{ .refs = parsed.kill_ids };
    if (parsed.kill_current) {
        const current = resolveClientSessionRef(allocator, null) catch |err| switch (err) {
            error.MissingSessionRef => return error.MissingCurrentSession,
            else => return err,
        };
        const refs = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(refs);
        refs[0] = current;
        return .{ .refs = refs, .owned_refs = refs, .owned_current = current };
    }
    return error.MissingKillTarget;
}

fn clientListSelector(target: []const u8) runtime_commands.ClientListSelector {
    if (std.mem.eql(u8, target, "incoming")) return .incoming;
    if (std.mem.eql(u8, target, "outgoing")) return .outgoing;
    if (std.mem.eql(u8, target, "session")) return .session;
    if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) return .{ .client_ref = target };
    return .{ .session_ref = target };
}

fn runLocalKillCommand(
    allocator: std.mem.Allocator,
    parsed: anytype,
    targets: []const []const u8,
) !void {
    var requests: std.ArrayList(runtime_commands.KillRequest) = .empty;
    defer {
        for (requests.items) |*request| request.deinit(allocator);
        requests.deinit(allocator);
    }
    for (parsed.kill_request_jsons) |request_json| {
        try requests.append(allocator, try runtime_commands.parseKillRequestJson(allocator, request_json));
    }
    return runtime_commands.runKillCommand(allocator, .{
        .format = if (parsed.kill_jsonl) .jsonl else .text,
        .targets = targets,
        .requests = requests.items,
    });
}

fn runLocalClientControlCommand(
    allocator: std.mem.Allocator,
    parsed: anytype,
) !void {
    const session_ref = try resolveClientControlSessionRef(allocator, parsed.client_session_ref, parsed.client_guid);
    defer if (session_ref) |ref| allocator.free(ref);
    return runtime_commands.runClientControlCommand(allocator, clientControlCommand(parsed, session_ref));
}

fn clientControlCommand(parsed: anytype, session_ref: ?[]const u8) runtime_commands.ClientControlCommand {
    const target = runtime_commands.ClientControlTarget{
        .kind = switch (parsed.client_target) {
            .default => if (parsed.action == .repaint_client)
                .TE_CLIENT_CONTROL_TARGET_KIND_ALL
            else
                .TE_CLIENT_CONTROL_TARGET_KIND_DEFAULT,
            .all => .TE_CLIENT_CONTROL_TARGET_KIND_ALL,
            .last_input => .TE_CLIENT_CONTROL_TARGET_KIND_LAST_INPUT,
            .client_guid => .TE_CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID,
        },
        .client_guid = if (parsed.client_target == .client_guid) parsed.client_guid.? else "",
    };
    return switch (parsed.action) {
        .detach_client => .{ .detach = .{
            .session_ref = session_ref,
            .target = target,
        } },
        .repaint_client => .{ .repaint = .{
            .session_ref = session_ref,
            .target = target,
            .include_scrollback = parsed.client_repaint_scrollback,
        } },
        .debug_client => switch (parsed.debug_client_action.?) {
            .sever_connection => .{ .debug_sever_connection = .{
                .session_ref = session_ref,
                .target = target,
            } },
            .unresponsive_connection => .{ .debug_unresponsive_connection = .{
                .session_ref = session_ref,
                .target = target,
                .seconds = if (parsed.debug_unresponsive_seconds) |seconds|
                    std.fmt.parseInt(u32, seconds, 10) catch unreachable
                else
                    config.default_debug_unresponsive_seconds,
            } },
        },
        else => unreachable,
    };
}

fn resolveClientSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8) ![]u8 {
    if (explicit_ref) |ref| return allocator.dupe(u8, ref);
    return std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingSessionRef,
        else => err,
    };
}

fn resolveClientControlSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8, client_guid: ?[]const u8) !?[]u8 {
    if (explicit_ref) |ref| {
        return try allocator.dupe(u8, ref);
    }

    if (client_guid) |guid| {
        const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (socket_path) |path| {
            allocator.free(path);
            return null;
        }

        var route = session_registry.readRouteForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer route.deinit(allocator);
        return try allocator.dupe(u8, route.guid);
    }

    return try resolveClientSessionRef(allocator, null);
}
