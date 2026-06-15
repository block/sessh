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

var active_local_clients: std.atomic.Value(usize) = .init(0);

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
    defer cleanup_context.deinit();
    var idle_context = DaemonIdleContext{
        .allocator = allocator,
        .cleanup_context = &cleanup_context,
        .last_live_work_ms = daemon_dispatcher.nowMs(),
    };
    _ = try daemon_dispatcher.watchFd(listen_fd, .{ .readable = true }, .{
        .ctx = &accept_context,
        .callback = acceptDaemonClient,
    });
    _ = try daemon_dispatcher.watchTimerAfter(daemon_idle_check_ms, .{
        .ctx = &idle_context,
        .callback = checkDaemonIdle,
    });
    try daemon_dispatcher.run();
}

const DaemonAcceptContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    listen_fd: c.fd_t,
};

fn acceptDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
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
    core_fds.setNonBlocking(client_fd) catch {
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
    context.initReader();
    _ = active_local_clients.fetchAdd(1, .acq_rel);
    _ = daemon_dispatcher.watchFd(client_fd, .{ .readable = true }, .{
        .ctx = context,
        .callback = readDaemonClient,
    }) catch {
        _ = active_local_clients.fetchSub(1, .acq_rel);
        accept_context.allocator.destroy(context);
        _ = c.close(client_fd);
        return;
    };
}

const ClientStage = enum {
    waiting_peer_hello,
    waiting_peer_reply,
    waiting_request,
    daemon_log,
};

const ClientContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    fd: c.fd_t,
    reader: protocol.FrameReader = undefined,
    stage: ClientStage = .waiting_peer_hello,
    owns_active_count: bool = true,

    fn initReader(self: *ClientContext) void {
        self.reader = protocol.FrameReader.init(self.allocator);
    }

    fn deinit(self: *ClientContext) void {
        self.reader.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.owns_active_count) {
            _ = active_local_clients.fetchSub(1, .acq_rel);
            self.owns_active_count = false;
        }
        self.allocator.destroy(self);
    }
};

fn readDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    const context: *ClientContext = @ptrCast(@alignCast(ctx));
    readDaemonClientInner(context, daemon_dispatcher, id, event) catch |err| {
        daemon_log.infof(context.allocator, "client handler failed error={t}", .{err});
        closeDaemonClient(context, daemon_dispatcher, id);
    };
}

fn readDaemonClientInner(context: *ClientContext, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    switch (event) {
        .fd => |fd_event| {
            if (fd_event.error_event or fd_event.invalid) {
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            }
            if (!fd_event.readable and !fd_event.hangup) return;
        },
        .timer => return error.UnexpectedDaemonTimer,
    }

    while (true) {
        switch (try context.reader.readReady(context.fd)) {
            .blocked => return,
            .progress => continue,
            .eof => {
                if (context.stage == .daemon_log) {
                    daemon_log.infof(context.allocator, "daemon log subscriber disconnected", .{});
                } else {
                    daemon_log.infof(context.allocator, "client disconnected from daemon", .{});
                }
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            },
            .truncated_frame => {
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                const action = try handleDaemonClientFrame(context, daemon_dispatcher, id, &frame);
                switch (action) {
                    .consumed => frame.deinit(context.allocator),
                    .close => {
                        frame.deinit(context.allocator);
                        closeDaemonClient(context, daemon_dispatcher, id);
                        return;
                    },
                    .transferred => {
                        frame.deinit(context.allocator);
                        context.deinit();
                        return;
                    },
                }
            },
        }
    }
}

const DaemonClientFrameAction = enum {
    consumed,
    close,
    transferred,
};

fn handleDaemonClientFrame(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    frame: *protocol.OwnedFrame,
) !DaemonClientFrameAction {
    switch (context.stage) {
        .waiting_peer_hello => {
            if (frame.message_type != .hello_request) {
                try sendHelloError(context.fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return .close;
            }
            var peer_hello = try protocol.decodePayload(hpb.HelloRequest, context.allocator, frame.payload);
            defer peer_hello.deinit(context.allocator);
            if (!helloRequestIsCompatible(peer_hello)) {
                try sendHelloError(context.fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
                return .close;
            }
            try sendHelloOk(context.fd);
            try sendHelloRequest(context.fd);
            context.stage = .waiting_peer_reply;
            return .consumed;
        },
        .waiting_peer_reply => {
            switch (frame.message_type) {
                .hello_ok => {
                    var ok = try protocol.decodePayload(hpb.HelloOk, context.allocator, frame.payload);
                    defer ok.deinit(context.allocator);
                    daemon_log.infof(context.allocator, "client hello completed", .{});
                    context.stage = .waiting_request;
                    return .consumed;
                },
                .hello_error => return .close,
                else => return error.UnexpectedFrame,
            }
        },
        .waiting_request => {
            if (try dispatcherConsumesInitialRequest(context, frame)) return .consumed;
            switch (try transferInitialRequestToDispatcherOwner(context, daemon_dispatcher, id, frame)) {
                .not_transferred => {},
                .consumed => return .consumed,
                .transferred => return .transferred,
                .close => return .close,
            }
            return if (try handleClientFrameAfterHandshake(context.allocator, context.exe, context.identity, context.fd, frame.*))
                .consumed
            else
                .close;
        },
        .daemon_log => return .close,
    }
}

fn dispatcherConsumesInitialRequest(context: *ClientContext, frame: *protocol.OwnedFrame) !bool {
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try sendError(context.fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
                return true;
            };
            switch (item_payload) {
                .resize => return true,
                else => return false,
            }
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try sendError(context.fd, "PROTOCOL_ERROR", "empty client daemon item", "");
                return true;
            };
            switch (item_payload) {
                .log_request => {
                    try daemon_log.subscribe(context.allocator, context.fd);
                    daemon_log.infof(context.allocator, "daemon log subscribed", .{});
                    context.stage = .daemon_log;
                    return true;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

const TransferInitialRequestResult = enum {
    not_transferred,
    consumed,
    transferred,
    close,
};

fn transferInitialRequestToDispatcherOwner(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    frame: *protocol.OwnedFrame,
) !TransferInitialRequestResult {
    if (frame.message_type == .daemon_tunnel) {
        if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, context.fd)) return .consumed;
        if (try handleDaemonTunnelControlFrame(context.allocator, context.identity, frame.*, context.fd)) return .consumed;
        if (isMuxOpenFrame(context.allocator, frame.*)) {
            var typed_open_frame = try readMuxTypedOpenFrame(context.allocator, context.fd);
            defer typed_open_frame.deinit(context.allocator);
            if (session_daemon_handler.isTeMuxOpenFrame(context.allocator, typed_open_frame)) {
                var initial_frames = [_]protocol.OwnedFrame{ frame.*, typed_open_frame };
                daemon_dispatcher.cancel(id);
                try session_daemon_handler.registerTeMuxConnectionFromDaemon(
                    context.allocator,
                    daemon_dispatcher,
                    context.exe,
                    context.identity,
                    initial_frames[0..],
                    context.fd,
                );
                context.fd = -1;
                return .transferred;
            }
            if (stream_runtime.isProxyMuxOpenFrame(context.allocator, typed_open_frame)) {
                var initial_frames = [_]protocol.OwnedFrame{ frame.*, typed_open_frame };
                daemon_dispatcher.cancel(id);
                try stream_runtime.registerProxyMuxConnectionFromDaemon(
                    context.allocator,
                    daemon_dispatcher,
                    context.exe,
                    context.identity,
                    initial_frames[0..],
                    context.fd,
                );
                context.fd = -1;
                return .transferred;
            }
            try sendError(context.fd, "PROTOCOL_ERROR", "expected typed mux stream open payload", "");
            return .close;
        }
        if (session_daemon_handler.isTeMuxOpenFrame(context.allocator, frame.*)) {
            var initial_frames = [_]protocol.OwnedFrame{frame.*};
            daemon_dispatcher.cancel(id);
            try session_daemon_handler.registerTeMuxConnectionFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.exe,
                context.identity,
                initial_frames[0..],
                context.fd,
            );
            context.fd = -1;
            return .transferred;
        }
        if (stream_runtime.isProxyMuxOpenFrame(context.allocator, frame.*)) {
            var initial_frames = [_]protocol.OwnedFrame{frame.*};
            daemon_dispatcher.cancel(id);
            try stream_runtime.registerProxyMuxConnectionFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.exe,
                context.identity,
                initial_frames[0..],
                context.fd,
            );
            context.fd = -1;
            return .transferred;
        }
        return .not_transferred;
    }

    if (frame.message_type != .client_daemon) return .not_transferred;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
    defer item.deinit(context.allocator);
    const item_payload = item.payload orelse return .not_transferred;
    switch (item_payload) {
        .ssh_transport_acquire => |request| {
            daemon_log.infof(context.allocator, "ssh transport requested", .{});
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerPooledSshTransportFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        .proxy_control_open => |request| {
            daemon_log.infof(context.allocator, "proxy control requested guid={s}", .{request.proxy_guid});
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerProxyControlOpenFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        else => return .not_transferred,
    }
}

fn closeDaemonClient(context: *ClientContext, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId) void {
    daemon_dispatcher.cancel(id);
    if (context.stage == .daemon_log and context.fd >= 0) daemon_log.unsubscribe(context.fd);
    context.deinit();
}

const DaemonIdleContext = struct {
    allocator: std.mem.Allocator,
    cleanup_context: *DaemonCleanupContext,
    last_live_work_ms: u64,
};

const DaemonCleanupContext = struct {
    allocator: std.mem.Allocator,
    cleanup_wakeup_interval_ms: u64,
    cleanup_retry_limit_ms: u64,
    sweep_lock: ?daemon_cleanup.SweepLock = null,
    shutdown_satisfied: bool = false,

    fn deinit(self: *DaemonCleanupContext) void {
        self.releaseSweepLock();
    }

    fn enabled(self: *const DaemonCleanupContext) bool {
        return self.cleanup_wakeup_interval_ms > 0;
    }

    fn releaseSweepLock(self: *DaemonCleanupContext) void {
        if (self.sweep_lock) |*lock| lock.deinit();
        self.sweep_lock = null;
    }
};

fn checkDaemonIdle(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const idle_context: *DaemonIdleContext = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedDaemonFdEvent,
    }

    const now_ms = daemon_dispatcher.nowMs();
    const has_local_client = active_local_clients.load(.acquire) != 0;
    const cleanup_keeps_daemon_alive = try maintainDaemonCleanup(idle_context.cleanup_context, now_ms, has_local_client);
    if (daemonHasLiveWork() or cleanup_keeps_daemon_alive) {
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

fn daemonHasLiveWork() bool {
    return active_local_clients.load(.acquire) != 0 or
        transport_ssh.activePooledSshTransportCount() != 0 or
        session_runtime.activeRuntimeCount() != 0 or
        stream_runtime.activeProxyRuntimeCount() != 0;
}

fn maintainDaemonCleanup(cleanup_context: *DaemonCleanupContext, now_ms: u64, has_local_client: bool) !bool {
    if (!cleanup_context.enabled()) {
        cleanup_context.releaseSweepLock();
        cleanup_context.shutdown_satisfied = true;
        return false;
    }

    const has_records = daemon_cleanup.hasRecords(cleanup_context.allocator);
    const decision = cleanupMaintenanceDecision(.{
        .has_records = has_records,
        .has_local_client = has_local_client,
        .has_lock = cleanup_context.sweep_lock != null,
        .shutdown_satisfied = cleanup_context.shutdown_satisfied,
    });

    if (decision.release_without_sweep) {
        cleanup_context.releaseSweepLock();
    }
    cleanup_context.shutdown_satisfied = decision.shutdown_satisfied;
    if (decision.acquire) {
        const acquired = try daemon_cleanup.tryAcquireSweepLock(cleanup_context.allocator);
        if (acquired) |lock| {
            cleanup_context.sweep_lock = lock;
        } else {
            cleanup_context.shutdown_satisfied = decision.shutdown_satisfied_on_acquire_failure;
            return decision.keeps_daemon_alive;
        }
    }
    if (decision.sweep == .if_due) {
        if (cleanup_context.sweep_lock == null) {
            return decision.keeps_daemon_alive;
        }
        if (cleanup_context.sweep_lock) |*lock| {
            if (try daemon_cleanup.sweepDueAndMark(
                lock,
                cleanup_context.cleanup_wakeup_interval_ms,
                now_ms,
            )) {
                try runCleanupSweep(cleanup_context);
            }
        }
    } else if (decision.sweep == .always) {
        if (cleanup_context.sweep_lock) |*lock| try daemon_cleanup.markSweepStarted(lock, now_ms);
        try runCleanupSweep(cleanup_context);
    }
    if (decision.release_after_sweep) cleanup_context.releaseSweepLock();
    return decision.keeps_daemon_alive;
}

fn runCleanupSweep(cleanup_context: *DaemonCleanupContext) !void {
    daemon_log.infof(cleanup_context.allocator, "cleanup sweep started", .{});
    try daemon_cleanup.sweepRecords(
        cleanup_context.allocator,
        cleanup_context.cleanup_retry_limit_ms,
        cleanup_context,
        cleanupRecordViaRemote,
    );
    daemon_log.infof(cleanup_context.allocator, "cleanup sweep finished", .{});
}

const CleanupSweepMode = enum {
    none,
    if_due,
    always,
};

const CleanupMaintenanceInput = struct {
    has_records: bool,
    has_local_client: bool,
    has_lock: bool,
    shutdown_satisfied: bool,
};

const CleanupMaintenanceDecision = struct {
    acquire: bool = false,
    sweep: CleanupSweepMode = .none,
    release_without_sweep: bool = false,
    release_after_sweep: bool = false,
    keeps_daemon_alive: bool = false,
    shutdown_satisfied: bool = false,
    shutdown_satisfied_on_acquire_failure: bool = false,
};

fn cleanupMaintenanceDecision(input: CleanupMaintenanceInput) CleanupMaintenanceDecision {
    if (!input.has_records) {
        return .{
            .release_without_sweep = input.has_lock,
            .shutdown_satisfied = true,
        };
    }
    if (input.has_local_client) {
        return .{
            .acquire = !input.has_lock,
            .sweep = .if_due,
            .keeps_daemon_alive = true,
            .shutdown_satisfied = false,
            .shutdown_satisfied_on_acquire_failure = false,
        };
    }
    if (input.shutdown_satisfied) {
        return .{
            .shutdown_satisfied = true,
        };
    }
    return .{
        .acquire = !input.has_lock,
        .sweep = .always,
        .release_after_sweep = true,
        .shutdown_satisfied = true,
        .shutdown_satisfied_on_acquire_failure = true,
    };
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

fn handleClientFrameAfterHandshake(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    fd: c.fd_t,
    frame: protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
            defer item.deinit(allocator);
            const item_payload = item.payload orelse {
                try sendError(fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
                return false;
            };
            switch (item_payload) {
                .resize => return true,
                .open => {
                    try session_daemon_handler.serveFrameAfterHandshake(allocator, exe, frame, fd, fd);
                    return false;
                },
                .debug_sever_connection_request,
                .debug_unresponsive_connection_request,
                => {
                    try session_daemon_handler.serveDebugFrameAfterHandshake(allocator, frame, fd);
                    return false;
                },
                else => {
                    try sendError(fd, "PROTOCOL_ERROR", "unexpected terminal stream item", "");
                    return false;
                },
            }
        },
        .daemon_tunnel => {
            if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd)) return true;
            if (try handleDaemonTunnelControlFrame(allocator, identity, frame, fd)) return true;
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
            return false;
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
            defer item.deinit(allocator);
            const item_payload = item.payload orelse {
                try sendError(fd, "PROTOCOL_ERROR", "empty client daemon item", "");
                return false;
            };
            switch (item_payload) {
                .ssh_transport_acquire => |request| {
                    _ = request;
                    try sendError(fd, "PROTOCOL_ERROR", "ssh transport must be dispatcher-owned", "");
                    return false;
                },
                .proxy_control_open => |request| {
                    daemon_log.infof(allocator, "proxy control requested guid={s}", .{request.proxy_guid});
                    try transport_ssh.serveProxyControlOpen(allocator, fd, request);
                    return false;
                },
                .log_request => {
                    try serveDaemonLogRequest(allocator, fd);
                    return false;
                },
                else => {
                    try sendError(fd, "PROTOCOL_ERROR", "unexpected client daemon item", "");
                    return false;
                },
            }
        },
        else => {
            try sendError(fd, "PROTOCOL_ERROR", "sesshd does not support this request yet", "");
            return false;
        },
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

test "cleanup maintenance decisions hold lock for live clients" {
    const decision = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = true,
        .has_lock = false,
        .shutdown_satisfied = true,
    });
    try std.testing.expect(decision.acquire);
    try std.testing.expectEqual(CleanupSweepMode.if_due, decision.sweep);
    try std.testing.expect(decision.keeps_daemon_alive);
    try std.testing.expect(!decision.release_after_sweep);
    try std.testing.expect(!decision.shutdown_satisfied);
}

test "cleanup maintenance decisions let idle daemon exit after one attempt" {
    const needs_attempt = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = false,
        .has_lock = false,
        .shutdown_satisfied = false,
    });
    try std.testing.expect(needs_attempt.acquire);
    try std.testing.expectEqual(CleanupSweepMode.always, needs_attempt.sweep);
    try std.testing.expect(needs_attempt.release_after_sweep);
    try std.testing.expect(needs_attempt.shutdown_satisfied);
    try std.testing.expect(needs_attempt.shutdown_satisfied_on_acquire_failure);
    try std.testing.expect(!needs_attempt.keeps_daemon_alive);

    const already_attempted = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = false,
        .has_lock = false,
        .shutdown_satisfied = true,
    });
    try std.testing.expect(!already_attempted.acquire);
    try std.testing.expectEqual(CleanupSweepMode.none, already_attempted.sweep);
    try std.testing.expect(already_attempted.shutdown_satisfied);
}

test "cleanup maintenance decisions release stale idle locks when no records remain" {
    const decision = cleanupMaintenanceDecision(.{
        .has_records = false,
        .has_local_client = false,
        .has_lock = true,
        .shutdown_satisfied = false,
    });
    try std.testing.expect(decision.release_without_sweep);
    try std.testing.expectEqual(CleanupSweepMode.none, decision.sweep);
    try std.testing.expect(decision.shutdown_satisfied);
    try std.testing.expect(!decision.keeps_daemon_alive);
}
