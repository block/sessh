const std = @import("std");
const c = std.c;

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
    try forwardBrokerFramesToDaemon(allocator, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, fd);
}

pub fn reexecBrokerOrForward(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.roleLine("sessh-broker", "accepts at most one daemon socket namespace");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var runtime_executables = try daemon_executable.installRuntimeExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer runtime_executables.deinit();
    return daemon_executable.reexec(allocator, runtime_executables.broker, args);
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

    // PROCESS_EVENT_LOOP: sessh-broker is only the daemon-tunnel bridge that
    // ssh runs as its remote command. It owns no session/proxy business logic;
    // its whole job is relaying frames between ssh stdin/stdout and the remote
    // daemon socket. It is intentionally a direct poll loop, not a helper-owned
    // Dispatcher.
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
