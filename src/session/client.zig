const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const attached_client = @import("attached_client.zig");
const config = @import("../core/config.zig");
const client_config = @import("client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_renderer = @import("renderer.zig");
const client_ui = @import("client_ui.zig");
const io_helpers = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const route_commands = @import("../runtime/route_commands.zig");
const session_registry = @import("../runtime/session_registry.zig");
const shell = @import("../core/shell.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;
const WindowSize = terminal.WindowSize;

const client_list_target_help = "incoming, outgoing, session, or a guid";

const LocalAction = enum {
    new,
    attach,
    list,
    kill,
    kill_all,
    detach_client,
    repaint_client,
    debug_client,
};

const ClientTarget = enum {
    default,
    all,
    last_input,
    client_guid,
};

const DebugClientAction = enum {
    sever_connection,
    unresponsive_connection,
};

const LocalOptions = struct {
    action: LocalAction = .new,
    action_set: bool = false,
    new_detached: bool = false,
    attach_id: ?[]const u8 = null,
    kill_id: ?[]const u8 = null,
    kill_ids: []const []const u8 = &.{},
    owned_kill_ids: ?[][]const u8 = null,
    kill_current: bool = false,
    kill_request_args: []const []const u8 = &.{},
    kill_jsonl: bool = false,
    list_refresh: bool = false,
    list_include_cached_routes: bool = true,
    list_jsonl: bool = false,
    list_exited: bool = false,
    list_all: bool = false,
    list_client_target: ?[]const u8 = null,
    client_session_ref: ?[]const u8 = null,
    client_target: ClientTarget = .default,
    client_guid: ?[]const u8 = null,
    client_repaint_scrollback: bool = false,
    debug_client_action: ?DebugClientAction = null,
    debug_unresponsive_seconds: ?u32 = null,
    overlay_args: client_ui.DetachOverlayArgs = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    compat_mode: bool = false,
    capture_tty_transcript: ?[]const u8 = null,

    fn deinit(self: *LocalOptions, allocator: std.mem.Allocator) void {
        if (self.owned_kill_ids) |ids| allocator.free(ids);
        self.owned_kill_ids = null;
        self.kill_ids = &.{};
    }
};

pub const LocalNewSessionRequest = struct {
    exe: []const u8,
    new_detached: bool = false,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    overlay_args: []const []const u8 = &.{},
    capture_tty_transcript: ?[]const u8 = null,
    command_argv: []const []const u8 = &.{},
    shell_command: ?[]const u8 = null,
};
/// Implements sesshmux-local commands after the public mux parser has selected
/// the local endpoint.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var options = parseLocalOptions(allocator, args) catch |err| {
        try writeLocalArgError(err);
        return process_exit.request(64);
    };
    defer options.deinit(allocator);
    applyFileConfigToLocal(allocator, &options) catch |err| {
        try io_helpers.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(options.client_log_level);

    return runBrokerClient(allocator, args, options);
}

fn writeLocalArgError(err: anyerror) !void {
    switch (err) {
        error.MissingClientListTarget => try io_helpers.writeAll(2, "sessh: --client requires a value: " ++ client_list_target_help ++ "\n"),
        error.MissingKillTarget => try io_helpers.writeAll(2, "sesshmux: kill requires --all, a guid, or --current\n"),
        error.MissingCurrentSession => try io_helpers.writeAll(2, "sesshmux: --current requires $SESSH_GUID\n"),
        error.MissingHost => try io_helpers.writeAll(2, "sesshmux: --host requires a value\n"),
        error.MissingId => try io_helpers.writeAll(2, "sesshmux: --id requires a value\n"),
        error.InvalidLocalHost => try io_helpers.writeAll(2, "sesshmux: local commands only accept --host .\n"),
        error.DetachedCaptureUnsupported => try io_helpers.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n"),
        else => try io_helpers.stderrPrint("sessh: invalid . arguments: {t}\n", .{err}),
    }
}

pub fn runLocalNewSession(allocator: std.mem.Allocator, request: LocalNewSessionRequest) !void {
    if (request.new_detached and request.capture_tty_transcript != null) {
        try io_helpers.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n");
        return process_exit.request(64);
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (request.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    const generated_guid = try session_registry.generateGuid(allocator);
    defer allocator.free(generated_guid);

    const runtime_broker_args: []const []const u8 = &.{};
    var child = try startLocalBroker(allocator, request.exe, runtime_broker_args);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    if (request.new_detached) {
        var created = attached_client.createSessionOnRuntime(
            child_read_fd,
            child_write_fd,
            request.scrollback_row_count,
            generated_guid,
            request.command_argv,
            request.shell_command,
            null,
            request.reap_ms,
            request.tombstone_retention_ms,
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime create failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        defer created.deinit();
        try session_registry.writeLocalRoute(allocator, created.guid, created.session_dir, config.version, request.tombstone_retention_ms);
        session_registry.markRouteDetachedNow(allocator, created.guid) catch |err| {
            client_log.debug("event=local_route_detached_mark_failed session={s} error={t}", .{ created.guid, err });
        };
        closeChildStdin(&child);
        _ = child.wait() catch {};
        var created_buf: [128]u8 = undefined;
        const created_line = try std.fmt.bufPrint(&created_buf, "CREATED {s}\n", .{created.guid});
        try io_helpers.writeAll(1, created_line);
        return;
    }

    var session = attached_client.startNewSessionOnRuntime(
        child_read_fd,
        child_write_fd,
        request.scrollback_row_count,
        generated_guid,
        request.command_argv,
        request.shell_command,
        null,
        request.reap_ms,
        request.tombstone_retention_ms,
    ) catch |err| {
        if (process_exit.is(err)) return err;
        terminateChild(&child);
        try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    try session_registry.writeLocalRoute(allocator, session.guidSlice(), session.sessionDirSlice(), config.version, request.tombstone_retention_ms);
    attached_client.writeClientRouteHintForSession(allocator, &session);
    defer attached_client.removeClientRouteHintForSession(allocator, &session);

    while (true) {
        const end = attached_client.runAttachedClient(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                attached_client.markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                attached_client.writeDetachOverlayForTarget(&.{}, ".", request.overlay_args, session.idSlice());
                if (session.kill_requested) attached_client.writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.spawnLocalKillJsonl(allocator, request.exe, &.{session.guidSlice()});
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, request.exe, &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = attached_client.nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreAttachedClientEndPresentationForExit();
                closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                terminateChild(&child);
            },
            .transport_closed => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!anySessionExistsViaBroker(allocator, request.exe, runtime_broker_args)) {
                    session.restoreAttachedClientEndPresentationForExit();
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\n");
        try io_helpers.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io_helpers.writeAll(2, "\r\n");
        child = startLocalBroker(allocator, request.exe, runtime_broker_args) catch |err| {
            session.restoreAttachedClientEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        attached_client.reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            session.restoreAttachedClientEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn runBrokerClient(allocator: std.mem.Allocator, args: []const []const u8, options: LocalOptions) !void {
    if (options.capture_tty_transcript != null and options.action != .new and options.action != .attach) {
        try io_helpers.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }

    const runtime_broker_args: []const []const u8 = &.{};
    switch (options.action) {
        .list => {
            if (options.list_client_target != null) {
                const exit_status = runLocalClientListCommand(allocator, args[0], runtime_broker_args, options) catch |err| switch (err) {
                    error.MissingSessionRef => {
                        try io_helpers.writeAll(2, "sessh: list --client=session requires $SESSH_GUID\n");
                        return process_exit.request(64);
                    },
                    else => return err,
                };
                if (exit_status != 0) return process_exit.request(exit_status);
                return;
            }
            const exit_status = try route_commands.runLocalListCommand(allocator, args[0], runtime_broker_args, options.list_refresh, options.list_include_cached_routes, options.list_jsonl, options.list_exited, options.list_all, null);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var kill_refs: ?LocalKillRefs = null;
            defer if (kill_refs) |*refs| refs.deinit(allocator);
            if (options.kill_request_args.len == 0) {
                kill_refs = resolveLocalKillRefs(allocator, options) catch |err| switch (err) {
                    error.MissingCurrentSession => {
                        try writeLocalArgError(err);
                        return process_exit.request(64);
                    },
                    error.MissingKillTarget => {
                        try writeLocalArgError(err);
                        return process_exit.request(64);
                    },
                    else => return err,
                };
            }
            var command_args: std.ArrayList([]const u8) = .empty;
            defer command_args.deinit(allocator);
            try command_args.appendSlice(allocator, runtime_broker_args);
            try command_args.append(allocator, "kill");
            if (options.kill_jsonl) try command_args.append(allocator, "--jsonl");
            try command_args.appendSlice(allocator, options.kill_request_args);
            if (kill_refs) |refs| try command_args.appendSlice(allocator, refs.refs);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args.items);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill_all => {
            var command_args: std.ArrayList([]const u8) = .empty;
            defer command_args.deinit(allocator);
            try command_args.appendSlice(allocator, runtime_broker_args);
            try command_args.append(allocator, "kill");
            if (options.kill_jsonl) try command_args.append(allocator, "--jsonl");
            try command_args.append(allocator, "--all");
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args.items);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .detach_client, .repaint_client, .debug_client => {
            const exit_status = runLocalClientControlCommand(allocator, args[0], runtime_broker_args, options) catch |err| switch (err) {
                error.MissingSessionRef => {
                    try io_helpers.writeAll(2, "sessh: client command requires an ID outside a sessh session\n");
                    return process_exit.request(64);
                },
                error.AmbiguousClientId => {
                    try io_helpers.writeAll(2, "sessh: client id is ambiguous\n");
                    return process_exit.request(1);
                },
                error.InvalidClientId => {
                    try io_helpers.writeAll(2, "sessh: invalid client id\n");
                    return process_exit.request(64);
                },
                else => return err,
            };
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .new, .attach => {},
    }

    if (options.action == .new) {
        return runLocalNewSession(allocator, .{
            .exe = args[0],
            .new_detached = options.new_detached,
            .scrollback_row_count = options.scrollback_row_count,
            .reap_ms = options.reap_ms,
            .tombstone_retention_ms = options.tombstone_retention_ms,
            .overlay_args = options.overlay_args.slice(),
            .capture_tty_transcript = options.capture_tty_transcript,
        });
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (options.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    var compat_attach_id: ?[]u8 = null;
    defer if (compat_attach_id) |id| allocator.free(id);
    if (options.action == .attach and options.attach_id == null and options.compat_mode) {
        // Compat callers set SESSH_GUID when they already know the intended
        // session. Prefer that over the older "latest detached" behavior.
        compat_attach_id = std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
    }

    var child = try startLocalBroker(allocator, args[0], runtime_broker_args);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    var session = (switch (options.action) {
        .attach => attached_client.startAttachSessionOnRuntime(
            child_read_fd,
            child_write_fd,
            options.attach_id orelse compat_attach_id orelse "",
            "",
            options.initial_scrollback_row_count,
            null,
        ),
        .new, .list, .kill, .kill_all, .detach_client, .repaint_client, .debug_client => unreachable,
    }) catch |err| {
        if (process_exit.is(err)) return err;
        terminateChild(&child);
        try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    if (options.action == .attach and session.guidSlice().len > 0) {
        session_registry.markRouteAttached(allocator, session.guidSlice()) catch |err| {
            client_log.debug("event=local_route_attached_mark_failed session={s} error={t}", .{ session.guidSlice(), err });
        };
    }
    attached_client.writeClientRouteHintForSession(allocator, &session);
    defer attached_client.removeClientRouteHintForSession(allocator, &session);

    while (true) {
        const end = attached_client.runAttachedClient(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                attached_client.markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                attached_client.writeDetachOverlayForTarget(&.{}, ".", options.overlay_args.slice(), session.idSlice());
                if (session.kill_requested) attached_client.writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.spawnLocalKillJsonl(allocator, args[0], &.{session.guidSlice()});
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, args[0], &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = attached_client.nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreAttachedClientEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreAttachedClientEndPresentationForExit();
                closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                terminateChild(&child);
            },
            .transport_closed => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!anySessionExistsViaBroker(allocator, args[0], runtime_broker_args)) {
                    session.restoreAttachedClientEndPresentationForExit();
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\n");
        try io_helpers.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io_helpers.writeAll(2, "\r\n");
        child = startLocalBroker(allocator, args[0], runtime_broker_args) catch |err| {
            session.restoreAttachedClientEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        attached_client.reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            session.restoreAttachedClientEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn appendBrokerCommand(
    runtime_args: []const []const u8,
    command: []const u8,
    value: ?[]const u8,
    buf: [][]const u8,
) []const []const u8 {
    @memcpy(buf[0..runtime_args.len], runtime_args);
    buf[runtime_args.len] = command;
    if (value) |arg| {
        buf[runtime_args.len + 1] = arg;
        return buf[0 .. runtime_args.len + 2];
    }
    return buf[0 .. runtime_args.len + 1];
}

const ClientSessionResolution = struct {
    session_ref: ?[]u8 = null,
    client_route: ?session_registry.Route = null,

    fn deinit(self: *ClientSessionResolution, allocator: std.mem.Allocator) void {
        if (self.client_route) |*route| route.deinit(allocator);
        if (self.session_ref) |ref| allocator.free(ref);
        self.* = undefined;
    }
};

fn runLocalClientListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    runtime_broker_args: []const []const u8,
    options: LocalOptions,
) !u8 {
    const target = options.list_client_target orelse return error.MissingSessionRef;
    if (try remoteRouteForClientListTarget(allocator, target)) |route| {
        var route_copy = route;
        defer route_copy.deinit(allocator);
        const remote_target = if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) target else route_copy.guid;
        return runRemoteClientListCommand(allocator, exe, &route_copy, remote_target, options.list_jsonl);
    }

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(allocator);
    var client_arg: ?[]u8 = null;
    defer if (client_arg) |arg| allocator.free(arg);
    try command_args.appendSlice(allocator, runtime_broker_args);
    try command_args.append(allocator, "list");
    client_arg = try std.fmt.allocPrint(allocator, "--client={s}", .{target});
    try command_args.append(allocator, client_arg.?);
    if (options.list_jsonl) try command_args.append(allocator, "--jsonl");
    return runLocalBrokerCommand(allocator, exe, command_args.items);
}

fn remoteRouteForClientListTarget(allocator: std.mem.Allocator, target: []const u8) !?session_registry.Route {
    if (std.mem.eql(u8, target, "incoming") or
        std.mem.eql(u8, target, "outgoing") or
        std.mem.eql(u8, target, "session"))
    {
        return null;
    }
    if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) {
        var route = session_registry.readRouteForClientGuid(allocator, target) catch |err| switch (err) {
            error.FileNotFound, error.InvalidClientId, error.AmbiguousClientId => return null,
            else => return err,
        };
        errdefer route.deinit(allocator);
        if (routeIsRemote(&route)) return route;
        route.deinit(allocator);
        return null;
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

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try io_helpers.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
    return switch (result.term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn runLocalClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    runtime_broker_args: []const []const u8,
    options: LocalOptions,
) !u8 {
    var session_resolution = try resolveClientControlSessionRef(allocator, options.client_session_ref, options.client_guid);
    defer session_resolution.deinit(allocator);
    if (session_resolution.client_route) |*route| {
        if (routeIsRemote(route)) {
            return runRemoteClientControlCommand(allocator, exe, route, options);
        }
    }
    var debug_seconds_arg: ?[]u8 = null;
    defer if (debug_seconds_arg) |arg| allocator.free(arg);

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(allocator);
    try command_args.appendSlice(allocator, runtime_broker_args);
    switch (options.action) {
        .detach_client => try command_args.append(allocator, "detach"),
        .repaint_client => try command_args.append(allocator, "repaint"),
        .debug_client => {
            try command_args.append(allocator, "debug");
            try command_args.append(allocator, switch (options.debug_client_action.?) {
                .sever_connection => "sever-connection",
                .unresponsive_connection => "unresponsive-connection",
            });
        },
        else => unreachable,
    }
    switch (options.client_target) {
        .default => {},
        .all => try command_args.append(allocator, "--all"),
        .last_input => try command_args.append(allocator, "--last-input"),
        .client_guid => {
            try command_args.append(allocator, options.client_guid.?);
        },
    }
    if (options.client_repaint_scrollback) try command_args.append(allocator, "--scrollback");
    if (options.debug_unresponsive_seconds) |seconds| {
        const seconds_arg = try std.fmt.allocPrint(allocator, "{d}", .{seconds});
        debug_seconds_arg = seconds_arg;
        try command_args.append(allocator, "--seconds");
        try command_args.append(allocator, seconds_arg);
    }
    if (session_resolution.session_ref) |session_ref| try command_args.append(allocator, session_ref);
    return runLocalBrokerCommand(allocator, exe, command_args.items);
}

fn resolveClientSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8) ![]u8 {
    if (explicit_ref) |ref| return allocator.dupe(u8, ref);
    return std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingSessionRef,
        else => err,
    };
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

fn resolveLocalKillRefs(allocator: std.mem.Allocator, options: LocalOptions) !LocalKillRefs {
    if (options.kill_ids.len > 0) return .{ .refs = options.kill_ids };
    if (options.kill_current) {
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

fn resolveClientControlSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8, client_guid: ?[]const u8) !ClientSessionResolution {
    if (explicit_ref) |ref| {
        return .{ .session_ref = try allocator.dupe(u8, ref) };
    }

    if (client_guid) |guid| {
        const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (socket_path) |path| {
            allocator.free(path);
            return .{};
        }

        var route = session_registry.readRouteForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        errdefer route.deinit(allocator);
        return .{
            .session_ref = try allocator.dupe(u8, route.guid),
            .client_route = route,
        };
    }

    return .{ .session_ref = try resolveClientSessionRef(allocator, null) };
}

fn routeIsRemote(route: *const session_registry.Route) bool {
    return route.host.len > 0 and !std.mem.eql(u8, route.host, ".");
}

// A client-id lookup can resolve to a cached remote route. Re-enter the mux CLI
// with that host so the existing ssh transport path runs the broker command.
fn runRemoteClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    options: LocalOptions,
) !u8 {
    var debug_seconds_arg: ?[]u8 = null;
    defer if (debug_seconds_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    switch (options.action) {
        .detach_client => {
            try argv.append(allocator, "detach");
        },
        .repaint_client => {
            try argv.append(allocator, "repaint");
        },
        .debug_client => {
            try argv.append(allocator, "debug");
        },
        else => unreachable,
    }
    try argv.appendSlice(allocator, route.ssh_options);
    try argv.append(allocator, "--host");
    try argv.append(allocator, route.host);
    try argv.append(allocator, "--id");
    try argv.append(allocator, route.guid);
    if (options.action == .debug_client) {
        try argv.append(allocator, switch (options.debug_client_action.?) {
            .sever_connection => "sever-connection",
            .unresponsive_connection => "unresponsive-connection",
        });
    }
    switch (options.client_target) {
        .default => {},
        .all => try argv.append(allocator, "--all"),
        .last_input => try argv.append(allocator, "--last-input"),
        .client_guid => {
            try argv.append(allocator, options.client_guid.?);
        },
    }
    if (options.client_repaint_scrollback) try argv.append(allocator, "--scrollback");
    if (options.debug_unresponsive_seconds) |seconds| {
        const seconds_arg = try std.fmt.allocPrint(allocator, "{d}", .{seconds});
        debug_seconds_arg = seconds_arg;
        try argv.append(allocator, "--seconds");
        try argv.append(allocator, seconds_arg);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try io_helpers.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
    return switch (result.term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn startLocalBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !std.process.Child {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn runLocalBrokerCommand(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(config.client_version_env, config.version);

    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn anySessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) bool {
    return brokerListMatches(allocator, exe, broker_args, null);
}

fn brokerListMatches(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8, session_id: ?[]const u8) bool {
    const argv = allocator.alloc([]const u8, 4 + broker_args.len) catch return false;
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2 .. 2 + broker_args.len], broker_args);
    argv[2 + broker_args.len] = "list";
    argv[3 + broker_args.len] = "--jsonl";
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (session_id) |id| return listContainsSession(result.stdout, id);
    return listHasAnySession(result.stdout);
}

fn listContainsSession(stdout: []const u8, session_id: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, app_allocator.allocator(), line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const id = jsonStringField(object, "id") orelse "";
        const guid = jsonStringField(object, "guid") orelse "";
        if (std.mem.eql(u8, id, session_id) or std.mem.eql(u8, guid, session_id)) return true;
    }
    return false;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn listHasAnySession(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) return true;
    }
    return false;
}

fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}

fn parseLocalOptions(allocator: std.mem.Allocator, args: []const []const u8) !LocalOptions {
    return parseLocalOptionsWithCompatMode(allocator, args, compatModeFromEnv());
}

fn compatModeFromEnv() bool {
    const value_z = c.getenv(config.compat_env) orelse return false;
    return std.mem.eql(u8, std.mem.span(value_z), "1");
}

fn parseLocalOptionsWithCompatMode(allocator: std.mem.Allocator, args: []const []const u8, compat_mode: bool) !LocalOptions {
    var options = LocalOptions{};
    errdefer options.deinit(allocator);
    options.compat_mode = compat_mode;
    var i: usize = 1;

    // Process-wide options may appear before the command word. Command flags
    // are parsed only after the command is known, so one command's flags do not
    // accidentally become valid for another command.
    while (i < args.len) {
        if (try parseLocalPreCommandOption(args, &i, &options)) continue;
        break;
    }

    if (i >= args.len) return try validateLocalOptions(options);

    // Pick the command before parsing command flags. This keeps options such as
    // `--all` scoped to the commands that actually understand them.
    const command = args[i];
    if (std.mem.eql(u8, command, "new")) {
        try setAction(&options, .new);
        i += 1;
        try parseLocalNewOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "list")) {
        try setAction(&options, .list);
        i += 1;
        try parseLocalListOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "detach")) {
        try setAction(&options, .detach_client);
        i += 1;
        try parseLocalClientControlOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "repaint")) {
        try setAction(&options, .repaint_client);
        i += 1;
        try parseLocalClientControlOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "debug")) {
        try setAction(&options, .debug_client);
        i += 1;
        try parseLocalDebugOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "attach")) {
        try setAction(&options, .attach);
        i += 1;
        try parseLocalAttachOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "kill")) {
        i += 1;
        try parseLocalKillOptions(allocator, args, &i, &options);
    } else {
        try parseLocalNewOptions(args, &i, &options);
    }

    return try validateLocalOptions(options);
}

fn parseLocalPreCommandOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--log-level")) {
        try parseLocalLogLevel(args, index, options);
        return true;
    }
    return false;
}

fn parseLocalNewOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--detached")) {
            options.new_detached = true;
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalAttachOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.attach_id)) continue;
        break;
    }
    if (index.* < args.len and !std.mem.startsWith(u8, args[index.*], "--")) {
        if (options.attach_id != null) return error.MultipleTargets;
        options.attach_id = args[index.*];
        index.* += 1;
    }
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.attach_id)) continue;
        if (try parseLocalCommonSessionOption(args, index, options)) continue;
        return error.UnknownArgument;
    }
}

fn parseLocalListOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--refresh")) {
            options.list_refresh = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--local-only")) {
            options.list_include_cached_routes = false;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            options.list_jsonl = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.list_all = true;
            index.* += 1;
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            const value = arg["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            if (options.list_client_target != null) return error.MultipleTargets;
            options.list_client_target = value;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--client")) {
            if (options.list_client_target != null) return error.MultipleTargets;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingClientListTarget;
            options.list_client_target = args[index.*];
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--exited")) {
            options.list_exited = true;
            index.* += 1;
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".")) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalKillOptions(allocator: std.mem.Allocator, args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    try setAction(options, .kill);
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--jsonl")) {
            options.kill_jsonl = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--all")) {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            options.action = .kill_all;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--current")) {
            if (options.action == .kill_all or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            options.kill_current = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--id")) {
            if (options.action == .kill_all or options.kill_current or options.kill_request_args.len > 0) return error.MultipleTargets;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingId;
            try appendLocalKillId(allocator, options, args[index.*]);
            index.* += 1;
        } else if (std.mem.startsWith(u8, arg, "--request=") or std.mem.eql(u8, arg, "--request")) {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0) return error.MultipleTargets;
            if (options.kill_request_args.len > 0) return error.MultipleTargets;
            const start = index.*;
            while (index.* < args.len) {
                if (std.mem.startsWith(u8, args[index.*], "--request=")) {
                    index.* += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[index.*], "--request")) {
                    index.* += 1;
                    if (index.* >= args.len) return error.MissingKillTarget;
                    index.* += 1;
                    continue;
                }
                break;
            }
            options.kill_request_args = args[start..index.*];
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".") and options.action == .kill and !options.kill_current and options.kill_ids.len == 0 and options.kill_request_args.len == 0) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            const start = index.*;
            while (index.* < args.len and !std.mem.startsWith(u8, args[index.*], "--")) {
                index.* += 1;
            }
            options.kill_ids = args[start..index.*];
            if (options.kill_ids.len > 0) options.kill_id = options.kill_ids[0];
        }
    }
}

fn parseLocalDebugOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.client_session_ref)) continue;
        if (try parseLocalCommonSessionOption(args, index, options)) continue;
        if (std.mem.startsWith(u8, args[index.*], "--")) return error.UnknownArgument;
        break;
    }
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugAction;
    if (std.mem.eql(u8, args[index.*], "sever-connection")) {
        options.debug_client_action = .sever_connection;
    } else if (std.mem.eql(u8, args[index.*], "unresponsive-connection")) {
        options.debug_client_action = .unresponsive_connection;
    } else {
        return error.InvalidDebugAction;
    }
    index.* += 1;
    try parseLocalClientControlOptions(args, index, options);
}

fn appendLocalKillId(allocator: std.mem.Allocator, options: *LocalOptions, id: []const u8) !void {
    const old = options.kill_ids;
    const owned = try allocator.alloc([]const u8, old.len + 1);
    errdefer allocator.free(owned);
    @memcpy(owned[0..old.len], old);
    owned[old.len] = id;
    if (options.owned_kill_ids) |previous| allocator.free(previous);
    options.owned_kill_ids = owned;
    options.kill_ids = owned;
    options.kill_id = options.kill_ids[0];
}

fn parseLocalClientControlOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--all")) {
            try setClientTarget(options, .all, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            try setClientTarget(options, .last_input, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (options.action != .repaint_client) return error.UnsupportedClientTarget;
            options.client_repaint_scrollback = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (options.action != .debug_client or options.debug_client_action != .unresponsive_connection) return error.UnsupportedDebugSeconds;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugSeconds;
            options.debug_unresponsive_seconds = try parseDebugUnresponsiveSeconds(args[index.*]);
            index.* += 1;
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (try parseLocalIdOption(args, index, &options.client_session_ref)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".")) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else if (!std.mem.startsWith(u8, arg, "--") and options.client_target == .default and std.mem.startsWith(u8, arg, session_registry.client_guid_prefix)) {
            try setClientTarget(options, .client_guid, arg);
            index.* += 1;
        } else if (!std.mem.startsWith(u8, arg, "--") and options.client_session_ref == null) {
            options.client_session_ref = arg;
            index.* += 1;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalIdOption(args: []const []const u8, index: *usize, target: *?[]const u8) !bool {
    if (!std.mem.eql(u8, args[index.*], "--id")) return false;
    index.* += 1;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingId;
    if (target.* != null) return error.MultipleTargets;
    target.* = args[index.*];
    index.* += 1;
    return true;
}

fn parseLocalHostTargetOption(args: []const []const u8, index: *usize) !bool {
    if (!std.mem.eql(u8, args[index.*], "--host")) return false;
    index.* += 1;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingHost;
    if (!std.mem.eql(u8, args[index.*], ".")) return error.InvalidLocalHost;
    index.* += 1;
    return true;
}

fn parseLocalCommonSessionOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    if (try parseLocalCommonProcessOption(args, index, options)) return true;
    const arg = args[index.*];

    // Compat-mode delegates every command to an older local client and appends
    // these session-presentation options after the command. SESSH_COMPAT is the
    // behavior switch; SESSH_CLIENT_VERSION is only metadata for diagnostics.
    if (std.mem.eql(u8, arg, "--scrollback-limit")) {
        if (!options.compat_mode) return error.UnsupportedConfigOrEnvOnlyOption;
        index.* += 1;
        if (index.* >= args.len) return error.MissingScrollbackRowCount;
        options.scrollback_row_count = try client_config.parseScrollbackRowCount(args[index.*]);
        options.scrollback_row_count_set = true;
        try options.overlay_args.append(arg);
        try options.overlay_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--initial-scrollback")) {
        if (!options.compat_mode) return error.UnsupportedConfigOrEnvOnlyOption;
        index.* += 1;
        if (index.* >= args.len) return error.MissingInitialScrollback;
        options.initial_scrollback_row_count = try client_config.parseInitialScrollbackRowCount(args[index.*]);
        options.initial_scrollback_row_count_set = true;
        try options.overlay_args.append(arg);
        try options.overlay_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
        options.capture_tty_transcript = args[index.*];
        index.* += 1;
        return true;
    }
    return false;
}

fn parseLocalCommonProcessOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--log-level")) {
        try parseLocalLogLevel(args, index, options);
        return true;
    }
    return false;
}

fn parseLocalLogLevel(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    const arg = args[index.*];
    index.* += 1;
    if (index.* >= args.len) return error.MissingClientLogLevel;
    options.client_log_level = try client_log.parseLevel(args[index.*]);
    options.client_log_level_set = true;
    try options.overlay_args.append(arg);
    try options.overlay_args.append(args[index.*]);
    index.* += 1;
}

fn validateLocalOptions(options: LocalOptions) !LocalOptions {
    if (options.list_refresh and options.action != .list) return error.UnsupportedListRefresh;
    if (!options.list_include_cached_routes and options.action != .list) return error.UnsupportedListLocalOnly;
    if (options.list_jsonl and options.action != .list) return error.UnsupportedListJsonl;
    if (options.list_exited and options.action != .list) return error.UnsupportedListExited;
    if (options.list_all and options.action != .list) return error.UnsupportedListAll;
    if (options.list_client_target != null and options.action != .list) return error.UnsupportedClientTarget;
    if (options.list_client_target != null and (options.list_refresh or !options.list_include_cached_routes or options.list_exited)) return error.UnsupportedClientTarget;
    if (options.list_all and (options.list_exited or options.list_client_target != null)) return error.UnsupportedListAll;
    if (options.client_target != .default and !actionSupportsClientTarget(options.action)) return error.UnsupportedClientTarget;
    if (options.client_guid != null and options.client_target != .client_guid) return error.UnsupportedClientTarget;
    if (options.client_repaint_scrollback and options.action != .repaint_client) return error.UnsupportedClientTarget;
    if (options.debug_client_action != null and options.action != .debug_client) return error.UnsupportedDebugAction;
    if (options.action == .debug_client and options.debug_client_action == null) return error.MissingDebugAction;
    if (options.debug_unresponsive_seconds != null and
        (options.action != .debug_client or options.debug_client_action != .unresponsive_connection)) return error.UnsupportedDebugSeconds;
    if (options.new_detached and options.action != .new) return error.UnsupportedClientTarget;
    if (options.new_detached and options.capture_tty_transcript != null) return error.DetachedCaptureUnsupported;
    if (options.action == .kill) {
        const target_modes: u8 = (if (options.kill_ids.len > 0) @as(u8, 1) else 0) +
            (if (options.kill_current) @as(u8, 1) else 0) +
            (if (options.kill_request_args.len > 0) @as(u8, 1) else 0);
        if (target_modes > 1) return error.MultipleTargets;
        if (target_modes == 0) return error.MissingKillTarget;
    }
    return options;
}

fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}

fn actionSupportsClientTarget(action: LocalAction) bool {
    return action == .detach_client or action == .repaint_client or action == .debug_client;
}

fn setClientTarget(options: *LocalOptions, target: ClientTarget, client_guid: ?[]const u8) !void {
    if (options.client_target != .default) return error.MultipleTargets;
    options.client_target = target;
    options.client_guid = client_guid;
}

fn applyFileConfigToLocal(allocator: std.mem.Allocator, options: *LocalOptions) !void {
    const file_config = try client_config.loadFileConfig(allocator);
    if (!options.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| options.scrollback_row_count = count;
    }
    if (!options.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        options.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (file_config.reap_ms) |ms| options.reap_ms = ms;
    if (file_config.tombstone_retention_ms) |ms| options.tombstone_retention_ms = ms;
    if (!options.client_log_level_set) {
        if (file_config.client_log_level) |level| options.client_log_level = level;
    }
}

fn setAction(options: *LocalOptions, action: LocalAction) !void {
    if (options.action_set) return error.MultipleActions;
    options.action = action;
    options.action_set = true;
}

test "parseLocalOptions keeps command flags command-specific" {
    const list_all = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--all",
    });
    try std.testing.expect(list_all.list_all);
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--current",
    }));
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--refresh",
    }));
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "s1",
        "--exited",
    }));
    const detached_new = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--detached",
    });
    try std.testing.expect(detached_new.new_detached);
    try std.testing.expectEqual(LocalAction.new, detached_new.action);
    try std.testing.expectError(error.UnsupportedClientTarget, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "detach",
        "--scrollback",
    }));
}

test "parseLocalOptions supports compatibility options before local commands" {
    const attach = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--host",
        ".",
        "s1",
        "--scrollback-limit",
        "42",
    }, true);

    try std.testing.expectEqual(LocalAction.attach, attach.action);
    try std.testing.expect(attach.compat_mode);
    try std.testing.expectEqualStrings("s1", attach.attach_id.?);
    try std.testing.expectEqual(@as(u32, 42), attach.scrollback_row_count);

    const list = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--initial-scrollback",
        "0",
    }, true);

    try std.testing.expectEqual(LocalAction.list, list.action);
    try std.testing.expectEqual(@as(?u32, 0), list.initial_scrollback_row_count);
}

test "parseLocalOptions uses current session only when explicit" {
    try std.testing.expectError(error.MissingKillTarget, parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
    }, false));

    const current = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--current",
    }, false);
    try std.testing.expectEqual(LocalAction.kill, current.action);
    try std.testing.expect(current.kill_current);

    const all = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--all",
    }, false);
    try std.testing.expectEqual(LocalAction.kill_all, all.action);

    try std.testing.expectError(error.MissingKillTarget, parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
    }, true));
}

test "parseLocalOptions accepts id option for local route commands" {
    const debug = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "debug",
        "--host",
        ".",
        "--id",
        "s1",
        "sever-connection",
        "--all",
    });
    try std.testing.expectEqual(LocalAction.debug_client, debug.action);
    try std.testing.expectEqual(DebugClientAction.sever_connection, debug.debug_client_action.?);
    try std.testing.expectEqual(ClientTarget.all, debug.client_target);
    try std.testing.expectEqualStrings("s1", debug.client_session_ref.?);

    var kill = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--id",
        "s1",
        "--id",
        "p1",
    });
    defer kill.deinit(std.testing.allocator);
    try std.testing.expectEqual(LocalAction.kill, kill.action);
    try std.testing.expectEqual(@as(usize, 2), kill.kill_ids.len);
    try std.testing.expectEqualStrings("s1", kill.kill_ids[0]);
    try std.testing.expectEqualStrings("p1", kill.kill_ids[1]);
}

test "parseLocalOptions supports kill request mode" {
    const request_json = "{\"guid\":\"s-00000000-0000-4000-8000-000000000001\",\"requested_age_ms\":123}";
    const request = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--jsonl",
        "--request",
        request_json,
    });
    try std.testing.expectEqual(LocalAction.kill, request.action);
    try std.testing.expect(request.kill_jsonl);
    try std.testing.expectEqual(@as(usize, 2), request.kill_request_args.len);
    try std.testing.expectEqualStrings("--request", request.kill_request_args[0]);
    try std.testing.expectEqualStrings(request_json, request.kill_request_args[1]);

    try std.testing.expectError(error.MultipleTargets, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--request",
        request_json,
        "s-00000000-0000-4000-8000-000000000001",
    }));
}
