const std = @import("std");

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const mux_cli = @import("cli.zig");
const process_exit = @import("../core/process_exit.zig");
const remote_command = @import("../runtime/remote_command.zig");
const route_commands = @import("../runtime/route_commands.zig");
const runtime_commands = @import("../runtime/commands.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub fn runCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    command: mux_cli.Command,
    remote_runner: ?*remote_command.Runner,
) !void {
    return switch (command) {
        .list => |list| runListCommand(allocator, exe, list, remote_runner),
        .kill => |kill| runKillCommand(allocator, kill),
        .detach => |control| runLocalClientControlCommandOrExit(allocator, .detach, control),
        .repaint => |control| runLocalClientControlCommandOrExit(allocator, .repaint, control),
        .debug => |debug| runLocalClientControlCommandOrExit(allocator, switch (debug.action) {
            .sever_connection => .debug_sever_connection,
            .unresponsive_connection => .debug_unresponsive_connection,
        }, debug.control),
        .new, .attach => unreachable,
    };
}

pub fn runListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    list: mux_cli.List,
    remote_runner: ?*remote_command.Runner,
) !void {
    if (list.common.capture_tty_transcript != null) {
        try writeCaptureTranscriptUnsupported();
        return process_exit.request(64);
    }

    if (list.client_target) |target| {
        const exit_status = try runtime_commands.runListCommand(allocator, .{
            .format = if (list.jsonl) .jsonl else .table,
            .client_selector = clientListSelector(target),
        });
        if (exit_status != 0) return process_exit.request(exit_status);
        return;
    }

    const exit_status = try route_commands.runLocalListCommand(
        allocator,
        exe,
        list.refresh,
        list.include_cached_routes,
        list.jsonl,
        list.exited,
        list.all,
        remote_runner,
    );
    if (exit_status != 0) return process_exit.request(exit_status);
}

pub fn runKillCommand(
    allocator: std.mem.Allocator,
    kill: mux_cli.Kill,
) !void {
    if (kill.common.capture_tty_transcript != null) {
        try writeCaptureTranscriptUnsupported();
        return process_exit.request(64);
    }

    if (kill.all) {
        return runtime_commands.runKillCommand(allocator, .{
            .format = if (kill.jsonl) .jsonl else .text,
            .all = true,
        });
    }

    var kill_refs: ?LocalKillRefs = null;
    defer if (kill_refs) |*refs| refs.deinit(allocator);
    if (kill.request_jsons.len == 0) {
        kill_refs = resolveLocalKillRefs(allocator, kill) catch |err| switch (err) {
            error.MissingCurrentSession, error.MissingKillTarget => {
                try writeLocalArgError(err);
                return process_exit.request(64);
            },
            else => return err,
        };
    }
    return runLocalKillCommand(allocator, kill, if (kill_refs) |refs| refs.refs else &.{});
}

fn writeCaptureTranscriptUnsupported() !void {
    try io.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
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

fn resolveLocalKillRefs(allocator: std.mem.Allocator, kill: mux_cli.Kill) !LocalKillRefs {
    const ids = switch (kill.command_target) {
        .route_ref_or_local_id => |ref| {
            const refs = try allocator.alloc([]const u8, 1);
            refs[0] = ref;
            return .{ .refs = refs, .owned_refs = refs };
        },
        .local => kill.ids,
        .host => unreachable,
    };
    if (ids.len > 0) return .{ .refs = ids };
    if (kill.current) {
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
    kill: mux_cli.Kill,
    targets: []const []const u8,
) !void {
    var requests: std.ArrayList(runtime_commands.KillRequest) = .empty;
    defer {
        for (requests.items) |*request| request.deinit(allocator);
        requests.deinit(allocator);
    }
    for (kill.request_jsons) |request_json| {
        try requests.append(allocator, try runtime_commands.parseKillRequestJson(allocator, request_json));
    }
    return runtime_commands.runKillCommand(allocator, .{
        .format = if (kill.jsonl) .jsonl else .text,
        .targets = targets,
        .requests = requests.items,
    });
}

pub const ClientControlKind = enum {
    detach,
    repaint,
    debug_sever_connection,
    debug_unresponsive_connection,
};

fn runLocalClientControlCommandOrExit(
    allocator: std.mem.Allocator,
    kind: ClientControlKind,
    control: mux_cli.ClientControl,
) !void {
    runLocalClientControlCommand(allocator, kind, control) catch |err| switch (err) {
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
}

fn runLocalClientControlCommand(
    allocator: std.mem.Allocator,
    kind: ClientControlKind,
    control: mux_cli.ClientControl,
) !void {
    if (control.common.capture_tty_transcript != null) {
        try writeCaptureTranscriptUnsupported();
        return process_exit.request(64);
    }

    const session_ref = try resolveClientControlSessionRef(allocator, control.session_ref, control.client_guid);
    defer if (session_ref) |ref| allocator.free(ref);
    return runtime_commands.runClientControlCommand(allocator, clientControlCommand(kind, control, session_ref));
}

fn clientControlCommand(
    kind: ClientControlKind,
    control: mux_cli.ClientControl,
    session_ref: ?[]const u8,
) runtime_commands.ClientControlCommand {
    const target_kind = mux_cli.clientControlTarget(control);
    const target = runtime_commands.ClientControlTarget{
        .kind = switch (target_kind) {
            .default => if (kind == .repaint)
                .TE_CLIENT_CONTROL_TARGET_KIND_ALL
            else
                .TE_CLIENT_CONTROL_TARGET_KIND_DEFAULT,
            .all => .TE_CLIENT_CONTROL_TARGET_KIND_ALL,
            .last_input => .TE_CLIENT_CONTROL_TARGET_KIND_LAST_INPUT,
            .client_guid => .TE_CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID,
        },
        .client_guid = if (target_kind == .client_guid) control.client_guid.? else "",
    };
    return switch (kind) {
        .detach => .{ .detach = .{
            .session_ref = session_ref,
            .target = target,
        } },
        .repaint => .{ .repaint = .{
            .session_ref = session_ref,
            .target = target,
            .include_scrollback = control.scrollback,
        } },
        .debug_sever_connection => .{ .debug_sever_connection = .{
            .session_ref = session_ref,
            .target = target,
        } },
        .debug_unresponsive_connection => .{ .debug_unresponsive_connection = .{
            .session_ref = session_ref,
            .target = target,
            .seconds = if (control.seconds) |seconds|
                std.fmt.parseInt(u32, seconds, 10) catch unreachable
            else
                config.default_debug_unresponsive_seconds,
        } },
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
