const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const user_error = @import("../core/user_error.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const daemon_client = @import("client.zig");
const daemon_executable = @import("executable.zig");
const socket_namespace = @import("socket_namespace.zig");

const pb = protocol.pb;

pub fn forwardBrokerToDaemon(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.roleLine("sessh-broker", "accepts at most one daemon socket namespace");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    try daemon_client.ensureStartedForDirName(allocator, exe, dir_name);
    const fd = try daemon_client.connectForDirName(allocator, dir_name);
    defer _ = c.close(fd);
    try forwardBrokerFramesToDaemon(allocator, .{
        .stdin = std.posix.STDIN_FILENO,
        .stdout = std.posix.STDOUT_FILENO,
        .daemon = fd,
    });
}

pub fn reexecBrokerOrForward(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.roleLine("sessh-broker", "accepts at most one daemon socket namespace");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var namespace_executables = try daemon_executable.installNamespaceExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer namespace_executables.deinit();
    return daemon_executable.reexec(allocator, namespace_executables.broker, args);
}

const BrokerBridgeFds = struct {
    stdin: c.fd_t,
    stdout: c.fd_t,
    daemon: c.fd_t,
};

fn forwardBrokerFramesToDaemon(
    allocator: std.mem.Allocator,
    fds: BrokerBridgeFds,
) !void {
    defer {
        _ = c.shutdown(fds.stdin, c.SHUT.WR);
        if (fds.stdout != fds.stdin) _ = c.shutdown(fds.stdout, c.SHUT.WR);
        _ = c.shutdown(fds.daemon, c.SHUT.WR);
    }

    try core_fds.setNonBlocking(fds.stdin);
    try core_fds.setNonBlocking(fds.stdout);
    try core_fds.setNonBlocking(fds.daemon);

    var client_to_daemon = BrokerFramePipe.init(allocator, .add_current_environment);
    defer client_to_daemon.deinit();
    var daemon_to_client = BrokerFramePipe.init(allocator, .none);
    defer daemon_to_client.deinit();

    // PROCESS_EVENT_LOOP: sessh-broker is only a framed relay between OpenSSH
    // and the local daemon. It has no daemon-owned state to service outside
    // this bridge.
    var broker_dispatcher = try dispatcher.Dispatcher.init(allocator);
    defer broker_dispatcher.deinit();
    var bridge = BrokerBridge{
        .stdin_fd = fds.stdin,
        .stdout_fd = fds.stdout,
        .daemon_fd = fds.daemon,
        .client_to_daemon = &client_to_daemon,
        .daemon_to_client = &daemon_to_client,
    };
    try bridge.watch(&broker_dispatcher);
    try broker_dispatcher.run();
}

const BrokerWatchKind = enum {
    stdin,
    stdout,
    daemon,
};

const BrokerWatchContext = struct {
    bridge: *BrokerBridge,
    kind: BrokerWatchKind,
};

const BrokerBridge = struct {
    stdin_fd: c.fd_t,
    stdout_fd: c.fd_t,
    daemon_fd: c.fd_t,
    client_to_daemon: *BrokerFramePipe,
    daemon_to_client: *BrokerFramePipe,
    stdin_watch: dispatcher.FdWatchId = undefined,
    stdout_watch: dispatcher.FdWatchId = undefined,
    daemon_watch: dispatcher.FdWatchId = undefined,
    watch_contexts: [3]BrokerWatchContext = undefined,

    fn watch(self: *BrokerBridge, broker_dispatcher: *dispatcher.Dispatcher) !void {
        self.watch_contexts = .{
            .{ .bridge = self, .kind = .stdin },
            .{ .bridge = self, .kind = .stdout },
            .{ .bridge = self, .kind = .daemon },
        };
        self.stdin_watch = try broker_dispatcher.watchFd(.{
            .fd = self.stdin_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[0], .callback = handleBrokerBridgeEvent },
        });
        self.stdout_watch = try broker_dispatcher.watchFd(.{
            .fd = self.stdout_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[1], .callback = handleBrokerBridgeEvent },
        });
        self.daemon_watch = try broker_dispatcher.watchFd(.{
            .fd = self.daemon_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[2], .callback = handleBrokerBridgeEvent },
        });
        try self.updateWatches(broker_dispatcher);
    }

    fn updateWatches(self: *BrokerBridge, broker_dispatcher: *dispatcher.Dispatcher) !void {
        try broker_dispatcher.updateFdEvents(self.stdin_watch, .{ .readable = self.client_to_daemon.wantsRead() });
        try broker_dispatcher.updateFdEvents(self.stdout_watch, .{ .writable = self.daemon_to_client.wantsWrite() });
        try broker_dispatcher.updateFdEvents(self.daemon_watch, .{
            .readable = self.daemon_to_client.wantsRead(),
            .writable = self.client_to_daemon.wantsWrite(),
        });
    }
};

fn handleBrokerBridgeEvent(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const broker_dispatcher = handler_event.dispatcher;
    const event = handler_event.event;
    const watch: *BrokerWatchContext = @ptrCast(@alignCast(ctx));
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedBrokerBridgeTimer,
    };
    const closed = switch (watch.kind) {
        .stdout => blk: {
            if (!fd_event.writable and !fd_event.hangup and !fd_event.error_event and !fd_event.invalid) break :blk false;
            switch (try watch.bridge.daemon_to_client.writeReady(watch.bridge.stdout_fd)) {
                .blocked, .progress, .drained => break :blk false,
            }
        },
        .stdin => blk: {
            if (!fd_event.readable and !fd_event.hangup and !fd_event.error_event and !fd_event.invalid) break :blk false;
            switch (try watch.bridge.client_to_daemon.readReady(watch.bridge.stdin_fd)) {
                .blocked, .progress => break :blk false,
                .closed => break :blk true,
            }
        },
        .daemon => blk: {
            if (fd_event.writable) {
                switch (try watch.bridge.client_to_daemon.writeReady(watch.bridge.daemon_fd)) {
                    .blocked, .progress, .drained => {},
                }
            }
            if (fd_event.readable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
                switch (try watch.bridge.daemon_to_client.readReady(watch.bridge.daemon_fd)) {
                    .blocked, .progress => break :blk false,
                    .closed => break :blk true,
                }
            }
            break :blk false;
        },
    };
    if (closed) {
        broker_dispatcher.stop();
        return;
    }
    try watch.bridge.updateWatches(broker_dispatcher);
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
                var owned_frame = frame_value;
                defer owned_frame.deinit(self.allocator);
                self.writer = try self.writerForFrame(&owned_frame);
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

    fn writerForFrame(self: *BrokerFramePipe, owned_frame: *protocol.OwnedFrame) !protocol.FrameWriteState {
        switch (self.transform) {
            .none => return protocol.FrameWriteState.initOwnedFrame(self.allocator, owned_frame.*),
            .add_current_environment => return self.writerForClientFrame(owned_frame),
        }
    }

    fn writerForClientFrame(self: *BrokerFramePipe, owned_frame: *protocol.OwnedFrame) !protocol.FrameWriteState {
        if (owned_frame.message_type != .client_remote) return protocol.FrameWriteState.initOwnedFrame(self.allocator, owned_frame.*);
        if (owned_frame.fd != null) return error.FdSendUnsupported;

        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(self.allocator, owned_frame.payload);
        defer item.deinit(self.allocator);
        if (item.payload) |item_payload| {
            switch (item_payload) {
                .open => |request| {
                    return self.writerForEnvironmentOpen(request);
                },
                else => {},
            }
        }
        return protocol.FrameWriteState.initOwnedFrame(self.allocator, owned_frame.*);
    }

    fn writerForEnvironmentOpen(self: *BrokerFramePipe, request: pb.TerminalEmulatorItem.Open) !protocol.FrameWriteState {
        const open_payload = try protocol.encodePayload(self.allocator, request);
        defer self.allocator.free(open_payload);
        const payload = try session_daemon_handler.sessionOpenPayloadWithCurrentEnvironment(self.allocator, open_payload);
        defer self.allocator.free(payload);
        var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, self.allocator, payload);
        defer open.deinit(self.allocator);
        const terminal_item = pb.TerminalEmulatorItem{ .payload = .{ .open = open } };
        const client_remote_payload = try protocol.encodeTerminalEmulatorItemPayload(self.allocator, terminal_item);
        defer self.allocator.free(client_remote_payload);
        return protocol.FrameWriteState.init(self.allocator, .client_remote, client_remote_payload);
    }
};
