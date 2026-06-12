const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const client_config = @import("../session/client_config.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const session_runtime = @import("../session/runtime.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_executable = @import("executable.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");
const stream_runtime = @import("../stream/runtime.zig");
const transport_ssh = @import("../transport/ssh.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

const daemon_idle_check_ms: u64 = 250;
const daemon_idle_shutdown_ms: u64 = 1_000;
const daemon_start_attempts: usize = 100;
const daemon_start_sleep_ms: u64 = 20;
const daemon_spawn_every_attempts: usize = 10;
const daemon_lock_attempts: usize = 100;
const daemon_lock_sleep_ms: u64 = 20;

var active_client_threads: std.atomic.Value(usize) = .init(0);

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return socketPathForDirName(allocator, dir_name);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return socket_namespace.socketPath(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    const path = try socketPath(allocator);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return ensureStartedForDirName(allocator, exe, dir_name);
}

fn ensureStartedForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !void {
    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
}

pub fn forwardBrokerToDaemon(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :internal-broker: accepts at most one daemon socket namespace\n");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    try ensureStartedForDirName(allocator, exe, dir_name);
    const fd = try connectForDirName(allocator, dir_name);
    defer _ = c.close(fd);
    try forwardBrokerFramesToDaemon(allocator, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, fd);
}

pub fn reexecBrokerOrForward(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :internal-broker: accepts at most one daemon socket namespace\n");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var runtime_executables = try daemon_executable.installRuntimeExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer runtime_executables.deinit();
    return daemon_executable.reexec(allocator, runtime_executables.broker, args);
}

pub fn reexecDaemonOrRun(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :internal-daemon: accepts at most one daemon socket namespace\n");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var runtime_executables = try daemon_executable.installRuntimeExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer runtime_executables.deinit();
    return daemon_executable.reexec(allocator, runtime_executables.daemon, args);
}

fn connectOrStartForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !c.fd_t {
    var attempts: usize = 0;
    while (attempts < daemon_start_attempts) : (attempts += 1) {
        if (attempts % daemon_spawn_every_attempts == 0) {
            _ = try spawnDaemon(allocator, exe, dir_name);
        }
        if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}
        io.sleepMillis(daemon_start_sleep_ms);
    }
    return error.DaemonDidNotStart;
}

fn spawnDaemon(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !bool {
    var runtime_executables = (try daemon_executable.installRuntimeExecutablesForDaemonStart(allocator, exe, dir_name)) orelse return false;
    defer runtime_executables.deinit();
    const argv = [_][]const u8{ runtime_executables.daemon, dir_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    return true;
}

fn connectForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

fn connectAndHandshakeForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const fd = try connectForDirName(allocator, dir_name);
    errdefer _ = c.close(fd);
    try initiateHandshake(allocator, fd);
    return fd;
}

fn forwardBrokerFramesToDaemon(
    allocator: std.mem.Allocator,
    stdin_fd: c.fd_t,
    stdout_fd: c.fd_t,
    daemon_fd: c.fd_t,
) !void {
    defer {
        _ = c.shutdown(stdin_fd, c.SHUT.WR);
        if (stdout_fd != stdin_fd) _ = c.shutdown(stdout_fd, c.SHUT.WR);
        _ = c.shutdown(daemon_fd, c.SHUT.WR);
    }

    var pollfds = [_]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = daemon_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = try std.posix.poll(&pollfds, -1);

        if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!try copyClientFrameToDaemon(allocator, stdin_fd, daemon_fd)) return;
        }
        if ((pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!try copyFrame(allocator, daemon_fd, stdout_fd)) return;
        }
    }
}

fn copyClientFrameToDaemon(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var frame = protocol.readFrameAlloc(allocator, read_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);

    if (frame.message_type == .client_remote) {
        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
        defer item.deinit(allocator);
        if (item.payload) |item_payload| {
            switch (item_payload) {
                .open => |request| {
                    const open_payload = try protocol.encodePayload(allocator, request);
                    defer allocator.free(open_payload);
                    const payload = try session_daemon_handler.sessionOpenPayloadWithCurrentEnvironment(allocator, open_payload);
                    defer allocator.free(payload);
                    var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, payload);
                    defer open.deinit(allocator);
                    try protocol.sendTeStreamPayloadFrame(allocator, write_fd, .{ .open = open });
                    return true;
                },
                else => {},
            }
        }
    }

    try protocol.sendFrame(write_fd, frame.message_type, frame.payload);
    return true;
}

fn copyFrame(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var frame = protocol.readFrameAlloc(allocator, read_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);
    try protocol.sendFrame(write_fd, frame.message_type, frame.payload);
    return true;
}

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    core_fds.closeInheritedNonStdioFileDescriptors();

    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :internal-daemon: accepts at most one daemon socket namespace\n");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    const daemon_exe = try socket_namespace.executablePath(allocator, dir_name, daemon_executable.daemon_name);
    defer allocator.free(daemon_exe);

    socket_transport.publishRuntimeRootSymlinkOnce(allocator);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    const identity = try daemon_identity.current(allocator, path);
    defer allocator.free(identity.start_time);

    var daemon_lock = try acquireDaemonSocketLock(allocator, dir_name, path);
    defer daemon_lock.deinit();
    var locked_runtime_executables = try daemon_executable.installRuntimeExecutablesWhileHoldingLock(allocator, exe, dir_name);
    defer locked_runtime_executables.deinit();

    const listen_fd = try socket_transport.listenSocket(path);
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(path) catch {};
    daemon_log.infof(allocator, "daemon started socket={s}", .{path});

    var daemon_dispatcher = try dispatcher.Dispatcher.init(allocator);
    defer daemon_dispatcher.deinit();

    var accept_context = DaemonAcceptContext{
        .allocator = allocator,
        .exe = daemon_exe,
        .identity = identity,
        .listen_fd = listen_fd,
    };
    const file_config = client_config.loadFileConfig(allocator) catch client_config.FileConfig{};
    var cleanup_context = DaemonCleanupContext{
        .allocator = allocator,
        .cleanup_wakeup_interval_ms = file_config.cleanup_wakeup_interval_ms orelse config.default_cleanup_wakeup_interval_ms,
        .cleanup_retry_limit_ms = file_config.cleanup_retry_limit_ms orelse config.default_cleanup_retry_limit_ms,
    };
    var idle_context = DaemonIdleContext{
        .allocator = allocator,
        .last_live_work_ms = daemon_dispatcher.nowMs(),
        .cleanup_enabled = cleanup_context.cleanup_wakeup_interval_ms > 0,
    };
    _ = try daemon_dispatcher.watchFd(listen_fd, .{ .readable = true }, .{
        .ctx = &accept_context,
        .callback = acceptDaemonClient,
    });
    _ = try daemon_dispatcher.watchTimerAfter(daemon_idle_check_ms, .{
        .ctx = &idle_context,
        .callback = checkDaemonIdle,
    });
    if (cleanup_context.cleanup_wakeup_interval_ms > 0) {
        _ = try daemon_dispatcher.watchTimerAfter(@min(cleanup_context.cleanup_wakeup_interval_ms, @as(u64, 1_000)), .{
            .ctx = &cleanup_context,
            .callback = checkDaemonCleanup,
        });
    }
    try daemon_dispatcher.run();
}

const DaemonAcceptContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    listen_fd: c.fd_t,
};

fn acceptDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = daemon_dispatcher;
    _ = id;
    const accept_context: *DaemonAcceptContext = @ptrCast(@alignCast(ctx));

    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonTimer,
    };
    if (fd_event.error_event or fd_event.invalid) return error.DaemonListenFailed;
    if (!fd_event.readable) return;

    const client_fd = c.accept(accept_context.listen_fd, null, null);
    if (client_fd < 0) return;
    daemon_log.infof(accept_context.allocator, "client connected", .{});
    socket_transport.setCloseOnExec(client_fd) catch {
        _ = c.close(client_fd);
        return;
    };
    const context = accept_context.allocator.create(ClientContext) catch {
        _ = c.close(client_fd);
        return;
    };
    context.* = .{
        .allocator = accept_context.allocator,
        .exe = accept_context.exe,
        .identity = accept_context.identity,
        .fd = client_fd,
    };
    _ = active_client_threads.fetchAdd(1, .acq_rel);
    const thread = std.Thread.spawn(.{}, clientThread, .{context}) catch {
        _ = active_client_threads.fetchSub(1, .acq_rel);
        accept_context.allocator.destroy(context);
        _ = c.close(client_fd);
        return;
    };
    thread.detach();
}

const ClientContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    fd: c.fd_t,
};

fn clientThread(context: *ClientContext) void {
    const allocator = context.allocator;
    const exe = context.exe;
    const identity = context.identity;
    const fd = context.fd;
    defer allocator.destroy(context);
    defer _ = c.close(fd);
    defer _ = active_client_threads.fetchSub(1, .acq_rel);
    handleClient(allocator, exe, identity, fd) catch {};
}

const DaemonIdleContext = struct {
    allocator: std.mem.Allocator,
    last_live_work_ms: u64,
    cleanup_enabled: bool,
};

const DaemonCleanupContext = struct {
    allocator: std.mem.Allocator,
    cleanup_wakeup_interval_ms: u64,
    cleanup_retry_limit_ms: u64,
};

fn checkDaemonIdle(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const idle_context: *DaemonIdleContext = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedDaemonFdEvent,
    }

    const now_ms = daemon_dispatcher.nowMs();
    if (daemonHasLiveWork(idle_context.allocator, idle_context.cleanup_enabled)) {
        idle_context.last_live_work_ms = now_ms;
    } else if (now_ms -| idle_context.last_live_work_ms >= daemon_idle_shutdown_ms) {
        daemon_log.infof(idle_context.allocator, "daemon idle; shutting down", .{});
        daemon_dispatcher.stop();
        return;
    }

    _ = try daemon_dispatcher.watchTimerAfter(daemon_idle_check_ms, .{
        .ctx = idle_context,
        .callback = checkDaemonIdle,
    });
}

fn daemonHasLiveWork(allocator: std.mem.Allocator, cleanup_enabled: bool) bool {
    return active_client_threads.load(.acquire) != 0 or
        transport_ssh.activeTerminalTunnelCount() != 0 or
        session_runtime.activeRuntimeCount() != 0 or
        stream_runtime.activeProxyRuntimeCount() != 0 or
        (cleanup_enabled and daemon_cleanup.hasRecords(allocator));
}

fn checkDaemonCleanup(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const cleanup_context: *DaemonCleanupContext = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedDaemonFdEvent,
    }

    var maybe_lock = try daemon_cleanup.tryAcquireSweepLock(cleanup_context.allocator, cleanup_context.cleanup_wakeup_interval_ms);
    if (maybe_lock) |*lock| {
        defer lock.deinit();
        daemon_log.infof(cleanup_context.allocator, "cleanup sweep started", .{});
        try daemon_cleanup.sweepRecords(
            cleanup_context.allocator,
            cleanup_context.cleanup_retry_limit_ms,
            cleanup_context,
            cleanupRecordViaRemote,
        );
        daemon_log.infof(cleanup_context.allocator, "cleanup sweep finished", .{});
    }

    if (cleanup_context.cleanup_wakeup_interval_ms > 0) {
        _ = try daemon_dispatcher.watchTimerAfter(cleanup_context.cleanup_wakeup_interval_ms, .{
            .ctx = cleanup_context,
            .callback = checkDaemonCleanup,
        });
    }
}

fn cleanupRecordViaRemote(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    record: daemon_cleanup.Record,
) !daemon_cleanup.CleanupResult {
    _ = ctx;
    daemon_log.infof(
        allocator,
        "cleanup record attempting remote cleanup guid={s} host={s}@{s}:{s}",
        .{ record.guid, record.remote_user, record.remote_host, record.remote_port },
    );
    const result = try transport_ssh.sendCleanupRequestToRemote(allocator, record);
    daemon_log.infof(
        allocator,
        "cleanup record remote cleanup finished guid={s} result={s}",
        .{ record.guid, @tagName(result) },
    );
    return result;
}

const DaemonSocketLock = struct {
    file: std.fs.File,

    fn deinit(self: *DaemonSocketLock) void {
        std.posix.flock(self.file.handle, std.posix.LOCK.UN) catch {};
        self.file.close();
        self.* = undefined;
    }
};

// The lock file, not the socket path, serializes daemon ownership. A Unix
// socket pathname can briefly be stale, absent, or connected to a daemon that is
// already exiting; the lock gives startup and shutdown one shared ordering point.
fn acquireDaemonSocketLock(allocator: std.mem.Allocator, dir_name: []const u8, socket_path: []const u8) !DaemonSocketLock {
    try socket_transport.ensureSocketDir(allocator, socket_path);

    var attempts: usize = 0;
    while (attempts < daemon_lock_attempts) : (attempts += 1) {
        if (tryAcquireDaemonSocketLock(allocator, socket_path)) |lock| return lock else |err| switch (err) {
            error.DaemonLockBusy => {},
            else => return err,
        }

        if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| {
            _ = c.close(fd);
            return error.DaemonAlreadyRunning;
        } else |_| {}

        io.sleepMillis(daemon_lock_sleep_ms);
    }
    return error.DaemonLockBusy;
}

fn tryAcquireDaemonSocketLock(allocator: std.mem.Allocator, socket_path: []const u8) !DaemonSocketLock {
    const lock_path = try daemonSocketLockPath(allocator, socket_path);
    defer allocator.free(lock_path);

    var file = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer file.close();
    try socket_transport.setCloseOnExec(file.handle);

    std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonLockBusy,
        else => return err,
    };
    return .{ .file = file };
}

fn daemonSocketLockPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, socket_path, '/') orelse return error.InvalidDaemonSocketPath;
    return std.fmt.allocPrint(allocator, "{s}/sesshd.lock", .{socket_path[0..slash]});
}

fn handleClient(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    fd: c.fd_t,
) !void {
    const handshake_result = try acceptHandshake(allocator, fd);
    if (handshake_result == .mismatch) return;
    daemon_log.infof(allocator, "client hello completed", .{});

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => {
                daemon_log.infof(allocator, "client disconnected from daemon", .{});
                return;
            },
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
                defer item.deinit(allocator);
                const item_payload = item.payload orelse {
                    try sendError(fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
                    return;
                };
                switch (item_payload) {
                    .resize => continue,
                    .open => {
                        try session_daemon_handler.serveFrameAfterHandshake(allocator, exe, frame, fd, fd);
                        return;
                    },
                    .debug_sever_connection_request,
                    .debug_unresponsive_connection_request,
                    => {
                        try session_daemon_handler.serveDebugFrameAfterHandshake(allocator, frame, fd);
                        return;
                    },
                    else => {
                        try sendError(fd, "PROTOCOL_ERROR", "unexpected terminal stream item", "");
                        return;
                    },
                }
            },
            .daemon_tunnel => {
                if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd)) continue;
                if (try handleDaemonTunnelControlFrame(allocator, identity, frame, fd)) continue;
                if (isMuxOpenFrame(allocator, frame)) {
                    var typed_open_frame = try readMuxTypedOpenFrame(allocator, fd);
                    defer typed_open_frame.deinit(allocator);
                    if (session_daemon_handler.isTeMuxOpenFrame(allocator, typed_open_frame)) {
                        try session_daemon_handler.serveMuxStreamFramesAfterHandshake(allocator, exe, identity, frame, typed_open_frame, fd);
                    } else if (stream_runtime.isProxyMuxOpenFrame(allocator, typed_open_frame)) {
                        try stream_runtime.serveMuxStreamFramesAfterHandshake(allocator, exe, identity, frame, typed_open_frame, fd);
                    } else {
                        try sendError(fd, "PROTOCOL_ERROR", "expected typed mux stream open payload", "");
                    }
                } else if (session_daemon_handler.isTeMuxOpenFrame(allocator, frame)) {
                    try session_daemon_handler.serveMuxStreamFrameAfterHandshake(allocator, exe, identity, frame, fd);
                } else if (stream_runtime.isProxyMuxOpenFrame(allocator, frame)) {
                    try stream_runtime.serveMuxStreamFrameAfterHandshake(allocator, exe, identity, frame, fd);
                } else {
                    try sendError(fd, "PROTOCOL_ERROR", "expected mux stream open", "");
                }
                return;
            },
            .client_daemon => {
                var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
                defer item.deinit(allocator);
                const item_payload = item.payload orelse {
                    try sendError(fd, "PROTOCOL_ERROR", "empty client daemon item", "");
                    return;
                };
                switch (item_payload) {
                    .ssh_transport_acquire => |request| {
                        daemon_log.infof(allocator, "terminal transport requested", .{});
                        try transport_ssh.serveTerminalTransportFromDaemon(allocator, fd, request);
                        return;
                    },
                    .proxy_control_open => |request| {
                        daemon_log.infof(allocator, "proxy control requested guid={s}", .{request.proxy_guid});
                        try transport_ssh.serveProxyControlOpen(allocator, fd, request);
                        return;
                    },
                    .log_request => {
                        try serveDaemonLogRequest(allocator, fd);
                        return;
                    },
                    else => {
                        try sendError(fd, "PROTOCOL_ERROR", "unexpected client daemon item", "");
                        return;
                    },
                }
            },
            else => {
                try sendError(fd, "PROTOCOL_ERROR", "sesshd does not support this request yet", "");
                return;
            },
        }
    }
}

fn handleDaemonTunnelControlFrame(
    allocator: std.mem.Allocator,
    identity: daemon_identity.DaemonIdentity,
    frame: protocol.OwnedFrame,
    fd: c.fd_t,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, allocator, frame.payload);
    defer item.deinit(allocator);
    const payload = item.payload orelse return false;
    switch (payload) {
        .remote_process_cleanup_request => |request| {
            try daemon_cleanup.handleRemoteProcessCleanupRequest(allocator, fd, identity, request);
            return true;
        },
        else => return false,
    }
}

fn isMuxOpenFrame(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var mux_frame = protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload) catch return false;
    defer mux_frame.deinit(allocator);
    const message = mux_frame.message orelse return false;
    return message == .open;
}

fn readMuxTypedOpenFrame(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        errdefer frame.deinit(allocator);
        if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd)) {
            frame.deinit(allocator);
            continue;
        }
        return frame;
    }
}

fn serveDaemonLogRequest(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try daemon_log.subscribe(allocator, fd);
    defer daemon_log.unsubscribe(fd);
    daemon_log.infof(allocator, "daemon log subscribed", .{});

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => {
                daemon_log.infof(allocator, "daemon log subscriber disconnected", .{});
                return;
            },
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            else => return error.UnexpectedFrame,
        }
    }
}

fn initiateHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.DaemonHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
}

const HandshakeResult = enum {
    accepted,
    mismatch,
};

fn acceptHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !HandshakeResult {
    var peer_hello = try readHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return .mismatch;
    }
    try sendHelloOk(fd);
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |_| return .mismatch;
    return .accepted;
}

fn readHelloRequest(allocator: std.mem.Allocator, fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            else => {
                try sendHelloError(fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
                defer ok.deinit(allocator);
                return null;
            },
            .hello_error => {
                const err = try protocol.decodePayload(hpb.HelloError, allocator, frame.payload);
                return err;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

test "daemon socket path uses runtime root" {
    const allocator = std.testing.allocator;
    const path = try socketPathForDirName(allocator, "1.dev.abcdef12");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/1.dev.abcdef12/sesshd.sock"));
}
