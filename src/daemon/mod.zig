const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const client_config = @import("../session/client_config.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const session_runtime = @import("../session/runtime.zig");
const daemon_client = @import("client.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_executable = @import("executable.zig");
const daemon_handshake = @import("handshake.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const daemon_startup = @import("startup.zig");
const daemon_tunnel = @import("tunnel.zig");
const socket_namespace = @import("socket_namespace.zig");
const proxy_control_registry = @import("../transport/proxy_control_registry.zig");
const socket_transport = @import("../transport/socket.zig");
const stream_runtime = @import("../stream/runtime.zig");
const transport_ssh = @import("../transport/ssh.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

const daemon_idle_check_ms: u64 = 250;
const daemon_idle_shutdown_ms: u64 = 1_000;

var active_local_clients: usize = 0;

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    return daemon_client.socketPath(allocator);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return daemon_client.socketPathForDirName(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    return daemon_client.connect(allocator);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    return daemon_client.ensureStarted(allocator, exe);
}

fn ensureStartedForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !void {
    return daemon_client.ensureStartedForDirName(allocator, exe, dir_name);
}

pub fn forwardBrokerToDaemon(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :broker: accepts at most one daemon socket namespace\n");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    try ensureStartedForDirName(allocator, exe, dir_name);
    const fd = try daemon_client.connectForDirName(allocator, dir_name);
    defer _ = c.close(fd);
    try forwardBrokerFramesToDaemon(allocator, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, fd);
}

pub fn reexecBrokerOrForward(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :broker: accepts at most one daemon socket namespace\n");
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
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :daemon: accepts at most one daemon socket namespace\n");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var runtime_executables = try daemon_executable.installRuntimeExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer runtime_executables.deinit();
    return daemon_executable.reexec(allocator, runtime_executables.daemon, args);
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

    try core_fds.setNonBlocking(stdin_fd);
    try core_fds.setNonBlocking(stdout_fd);
    try core_fds.setNonBlocking(daemon_fd);

    var client_to_daemon = BrokerFramePipe.init(allocator, .add_current_environment);
    defer client_to_daemon.deinit();
    var daemon_to_client = BrokerFramePipe.init(allocator, .none);
    defer daemon_to_client.deinit();

    // PROCESS_EVENT_LOOP: sessh-broker is a foreground bridge process whose
    // whole job is relaying frames between stdin/stdout and the local daemon.
    // It is intentionally a direct poll loop, not a helper-owned Dispatcher.
    while (true) {
        var pollfds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = if (client_to_daemon.wantsRead()) std.posix.POLL.IN else 0, .revents = 0 },
            .{ .fd = stdout_fd, .events = if (daemon_to_client.wantsWrite()) std.posix.POLL.OUT else 0, .revents = 0 },
            .{ .fd = daemon_fd, .events = brokerDaemonPollEvents(&client_to_daemon, &daemon_to_client), .revents = 0 },
        };
        _ = try std.posix.poll(&pollfds, -1);

        if ((pollfds[1].revents & std.posix.POLL.OUT) != 0) {
            switch (try daemon_to_client.writeReady(stdout_fd)) {
                .blocked, .progress, .drained => {},
            }
        }
        if ((pollfds[2].revents & std.posix.POLL.OUT) != 0) {
            switch (try client_to_daemon.writeReady(daemon_fd)) {
                .blocked, .progress, .drained => {},
            }
        }

        if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            switch (try client_to_daemon.readReady(stdin_fd)) {
                .blocked, .progress => {},
                .closed => return,
            }
        }
        if ((pollfds[2].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            switch (try daemon_to_client.readReady(daemon_fd)) {
                .blocked, .progress => {},
                .closed => return,
            }
        }
    }
}

fn brokerDaemonPollEvents(client_to_daemon: *const BrokerFramePipe, daemon_to_client: *const BrokerFramePipe) i16 {
    var events: i16 = 0;
    if (daemon_to_client.wantsRead()) events |= std.posix.POLL.IN;
    if (client_to_daemon.wantsWrite()) events |= std.posix.POLL.OUT;
    return events;
}

const BrokerFrameReadStatus = enum {
    blocked,
    progress,
    closed,
};

const BrokerFrameWriteStatus = enum {
    blocked,
    progress,
    drained,
};

const BrokerFrameTransform = enum {
    none,
    add_current_environment,
};

const BrokerFramePipe = struct {
    allocator: std.mem.Allocator,
    transform: BrokerFrameTransform,
    reader: protocol.FrameReader,
    writer: ?protocol.FrameWriteState = null,

    fn init(allocator: std.mem.Allocator, transform: BrokerFrameTransform) BrokerFramePipe {
        return .{
            .allocator = allocator,
            .transform = transform,
            .reader = protocol.FrameReader.init(allocator),
        };
    }

    fn deinit(self: *BrokerFramePipe) void {
        self.reader.deinit();
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
    }

    fn wantsRead(self: *const BrokerFramePipe) bool {
        return self.writer == null;
    }

    fn wantsWrite(self: *const BrokerFramePipe) bool {
        return self.writer != null;
    }

    fn readReady(self: *BrokerFramePipe, fd: c.fd_t) !BrokerFrameReadStatus {
        if (self.writer != null) return .blocked;
        switch (try self.reader.readReady(fd)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .eof, .truncated_frame => return .closed,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(self.allocator);
                self.writer = try self.writerForFrame(&frame);
                return .progress;
            },
        }
    }

    fn writeReady(self: *BrokerFramePipe, fd: c.fd_t) !BrokerFrameWriteStatus {
        var writer = if (self.writer) |*value| value else return .drained;
        switch (try writer.writeReady(fd)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .done => {
                writer.deinit();
                self.writer = null;
                return .drained;
            },
        }
    }

    fn writerForFrame(self: *BrokerFramePipe, frame: *protocol.OwnedFrame) !protocol.FrameWriteState {
        switch (self.transform) {
            .none => return protocol.FrameWriteState.initOwnedFrame(self.allocator, frame.*),
            .add_current_environment => return self.writerForClientFrame(frame),
        }
    }

    fn writerForClientFrame(self: *BrokerFramePipe, frame: *protocol.OwnedFrame) !protocol.FrameWriteState {
        if (frame.message_type != .client_remote) return protocol.FrameWriteState.initOwnedFrame(self.allocator, frame.*);
        if (frame.fd != null) return error.FdSendUnsupported;

        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(self.allocator, frame.payload);
        defer item.deinit(self.allocator);
        if (item.payload) |item_payload| {
            switch (item_payload) {
                .open => |request| {
                    return self.writerForEnvironmentOpen(request);
                },
                else => {},
            }
        }
        return protocol.FrameWriteState.initOwnedFrame(self.allocator, frame.*);
    }

    fn writerForEnvironmentOpen(self: *BrokerFramePipe, request: pb.TerminalEmulatorItem.Open) !protocol.FrameWriteState {
        const open_payload = try protocol.encodePayload(self.allocator, request);
        defer self.allocator.free(open_payload);
        const payload = try session_daemon_handler.sessionOpenPayloadWithCurrentEnvironment(self.allocator, open_payload);
        defer self.allocator.free(payload);
        var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, self.allocator, payload);
        defer open.deinit(self.allocator);
        const terminal_item = pb.TerminalEmulatorItem{ .payload = .{ .open = open } };
        const client_remote_payload = try protocol.encodePayload(self.allocator, pb.ClientRemoteItem{ .payload = .{ .terminal_emulator = terminal_item } });
        defer self.allocator.free(client_remote_payload);
        return protocol.FrameWriteState.init(self.allocator, .client_remote, client_remote_payload);
    }
};

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var ready_fd = daemon_startup.inheritedReadyFd();
    var startup_lock_fd = daemon_startup.inheritedStartupLockFd();
    defer {
        if (ready_fd >= 0) _ = c.close(ready_fd);
        daemon_startup.closeStartupLockFd(&startup_lock_fd);
    }
    core_fds.closeInheritedNonStdioFileDescriptorsExceptList(&.{ ready_fd, startup_lock_fd });

    if (args.len > 1) {
        try io.writeAll(std.posix.STDERR_FILENO, "sessh: :daemon: accepts at most one daemon socket namespace\n");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

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
    daemon_startup.signalReady(&ready_fd);
    daemon_startup.closeStartupLockFd(&startup_lock_fd);
    daemon_log.infof(allocator, "daemon started socket={s}", .{path});

    // PROCESS_DISPATCHER: sesshd has exactly one Dispatcher. Daemon helpers
    // receive this pointer when they need fd/timer events; they should not
    // construct nested dispatchers.
    var daemon_dispatcher = try dispatcher.Dispatcher.init(allocator);
    defer daemon_dispatcher.deinit();

    var accept_context = DaemonAcceptContext{
        .allocator = allocator,
        .terminal_remote_exe = locked_runtime_executables.terminal_remote,
        .proxy_remote_exe = locked_runtime_executables.proxy_remote,
        .identity = identity,
        .listen_fd = listen_fd,
    };
    const file_config = client_config.loadFileConfig(allocator) catch client_config.FileConfig{};
    var cleanup_context = DaemonCleanupContext{
        .allocator = allocator,
        .daemon_dispatcher = &daemon_dispatcher,
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
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
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
        .terminal_remote_exe = accept_context.terminal_remote_exe,
        .proxy_remote_exe = accept_context.proxy_remote_exe,
        .identity = accept_context.identity,
        .fd = client_fd,
    };
    context.initReader();
    active_local_clients += 1;
    _ = daemon_dispatcher.watchFd(client_fd, .{ .readable = true }, .{
        .ctx = context,
        .callback = readDaemonClient,
    }) catch {
        active_local_clients -= 1;
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
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
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
            active_local_clients -= 1;
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
                const action = try handleDaemonClientFrame(context, daemon_dispatcher, id, &frame, &frame.fd);
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
    frame_fd: *?c.fd_t,
) !DaemonClientFrameAction {
    switch (context.stage) {
        .waiting_peer_hello => {
            if (frame.message_type != .hello_request) {
                try daemon_handshake.sendHelloError(context.fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return .close;
            }
            var peer_hello = try protocol.decodePayload(hpb.HelloRequest, context.allocator, frame.payload);
            defer peer_hello.deinit(context.allocator);
            if (!daemon_handshake.helloRequestIsCompatible(peer_hello)) {
                try daemon_handshake.sendHelloError(context.fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
                return .close;
            }
            try daemon_handshake.sendHelloOk(context.fd);
            try daemon_handshake.sendHelloRequest(context.fd);
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
            switch (try transferInitialRequestToDispatcherOwner(context, daemon_dispatcher, id, frame, frame_fd)) {
                .not_transferred => {},
                .consumed => return .consumed,
                .transferred => return .transferred,
                .close => return .close,
            }
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "unexpected passed file descriptor", "");
                return .close;
            }
            return if (try handleClientFrameAfterHandshake(context.allocator, context.terminal_remote_exe, context.identity, context.fd, frame.*))
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
    frame_fd: *?c.fd_t,
) !TransferInitialRequestResult {
    if (frame.message_type == .client_remote) {
        if (frame_fd.*) |passed_fd| {
            frame_fd.* = null;
            _ = c.close(passed_fd);
            try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
            return .close;
        }
        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
        defer item.deinit(context.allocator);
        const item_payload = item.payload orelse return .not_transferred;
        if (item_payload == .open) {
            daemon_dispatcher.cancel(id);
            const client_fd = context.fd;
            context.fd = -1;
            try session_daemon_handler.registerFrameWithTerminalRemoteFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.terminal_remote_exe,
                frame.*,
                client_fd,
            );
            return .transferred;
        }
        switch (item_payload) {
            .debug_sever_connection_request,
            .debug_unresponsive_connection_request,
            => {
                daemon_dispatcher.cancel(id);
                const client_fd = context.fd;
                context.fd = -1;
                try session_daemon_handler.registerDebugFrameWithTerminalRemoteFromDaemon(
                    context.allocator,
                    daemon_dispatcher,
                    frame.*,
                    client_fd,
                );
                return .transferred;
            },
            else => {},
        }
        return .not_transferred;
    }

    if (frame.message_type == .daemon_tunnel) {
        if (frame_fd.*) |passed_fd| {
            frame_fd.* = null;
            _ = c.close(passed_fd);
            try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
            return .close;
        }
        if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, context.fd)) return .consumed;
        if (try handleDaemonTunnelControlFrame(context.allocator, context.identity, frame.*, context.fd)) return .consumed;
        var initial_frames = [_]protocol.OwnedFrame{frame.*};
        daemon_dispatcher.cancel(id);
        try daemon_tunnel.registerMuxConnectionFromDaemon(
            context.allocator,
            daemon_dispatcher,
            context.terminal_remote_exe,
            context.proxy_remote_exe,
            context.identity,
            initial_frames[0..],
            context.fd,
        );
        context.fd = -1;
        return .transferred;
    }

    if (frame.message_type != .client_daemon) return .not_transferred;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
    defer item.deinit(context.allocator);
    const item_payload = item.payload orelse return .not_transferred;
    switch (item_payload) {
        .ssh_transport_acquire => |request| {
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
                return .close;
            }
            daemon_log.infof(context.allocator, "ssh transport requested", .{});
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerPooledSshTransportFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        .proxy_control_open => |request| {
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
                return .close;
            }
            daemon_log.infof(context.allocator, "proxy control requested guid={s}", .{request.proxy_guid});
            daemon_dispatcher.cancel(id);
            try proxy_control_registry.registerOpenFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        .proxy_fd_pass_open => |request| {
            const passed_fd = frame_fd.* orelse {
                try sendError(context.fd, "PROTOCOL_ERROR", "proxy fd-pass open missing SCM_RIGHTS fd", "");
                return .close;
            };
            frame_fd.* = null;
            errdefer _ = c.close(passed_fd);
            if (request.proxy) |proxy| {
                daemon_log.infof(
                    context.allocator,
                    "proxy fd-pass requested guid={s} host={s}:{d}",
                    .{ proxy.proxy_guid, proxy.proxy_host, proxy.proxy_port },
                );
            } else {
                daemon_log.infof(context.allocator, "proxy fd-pass requested without proxy details", .{});
            }
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerProxyFdPassOpenFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.fd,
                passed_fd,
                request,
            );
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
    daemon_dispatcher: *dispatcher.Dispatcher,
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
    const has_local_client = active_local_clients != 0;
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
    return active_local_clients != 0 or
        transport_ssh.activePooledSshTransportCount() != 0 or
        session_runtime.activeTerminalRemoteProcessCount() != 0 or
        stream_runtime.activeProxyRemoteProcessCount() != 0;
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
    const cleanup_context: *DaemonCleanupContext = @ptrCast(@alignCast(ctx));
    daemon_log.infof(
        allocator,
        "cleanup record enqueueing remote cleanup guid={s} host={s}@{s}:{s}",
        .{ record.guid, record.remote_user, record.remote_host, record.remote_port },
    );
    try transport_ssh.enqueueCleanupRequestToRemote(allocator, cleanup_context.daemon_dispatcher, record);
    daemon_log.infof(
        allocator,
        "cleanup record remote cleanup enqueued guid={s}",
        .{record.guid},
    );
    return error.CleanupRequestEnqueued;
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

    return tryAcquireDaemonSocketLock(allocator, socket_path) catch |err| switch (err) {
        error.DaemonLockBusy => lock_busy: {
            if (daemon_client.connectAndHandshakeForDirName(allocator, dir_name)) |fd| {
                _ = c.close(fd);
                return error.DaemonAlreadyRunning;
            } else |_| {}
            break :lock_busy error.DaemonLockBusy;
        },
        else => return err,
    };
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
                    _ = exe;
                    try sendError(fd, "PROTOCOL_ERROR", "terminal stream open must be dispatcher-owned", "");
                    return false;
                },
                .debug_sever_connection_request,
                .debug_unresponsive_connection_request,
                => {
                    try sendError(fd, "PROTOCOL_ERROR", "session debug must be dispatcher-owned", "");
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
            try sendError(fd, "PROTOCOL_ERROR", "daemon tunnel must be dispatcher-owned", "");
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
                .proxy_control_open => {
                    try sendError(fd, "PROTOCOL_ERROR", "proxy control must be dispatcher-owned", "");
                    return false;
                },
                .proxy_fd_pass_open => {
                    try sendError(fd, "PROTOCOL_ERROR", "proxy fd-pass open must be dispatcher-owned", "");
                    return false;
                },
                .log_request => {
                    try sendError(fd, "PROTOCOL_ERROR", "daemon log must be dispatcher-owned", "");
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
