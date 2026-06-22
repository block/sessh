// `sessh-bridge` bridges OpenSSH stdio to the local daemon. It deliberately
// owns no session or stream state; once connected, it is just the process that
// carries framed daemon-to-daemon traffic across ssh.
const std = @import("std");
const c = std.c;

const core_blocking = @import("../core/blocking.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const user_error = @import("../core/user_error.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const daemon_client = @import("client.zig");
const daemon_executable = @import("executable.zig");
const socket_namespace = @import("socket_namespace.zig");

const pb = protocol.pb;

pub fn forwardBridgeToDaemon(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.roleLine(blocking, "sessh-bridge", "accepts at most one daemon socket namespace");
        return error.InvalidBridgeArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    try daemon_client.ensureStartedForDirName(blocking, allocator, exe, dir_name);
    const fd = try daemon_client.connectForDirName(allocator, dir_name);
    defer _ = c.close(fd);
    try forwardBridgeFramesToDaemon(blocking, allocator, .{
        .stdin = std.posix.STDIN_FILENO,
        .stdout = std.posix.STDOUT_FILENO,
        .daemon = fd,
    });
}

pub fn reexecBridgeOrForward(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.roleLine(blocking, "sessh-bridge", "accepts at most one daemon socket namespace");
        return error.InvalidBridgeArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var namespace_executables = try daemon_executable.installNamespaceExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer namespace_executables.deinit();
    return daemon_executable.reexec(allocator, namespace_executables.bridge, args);
}

const BridgeFds = struct {
    stdin: c.fd_t,
    stdout: c.fd_t,
    daemon: c.fd_t,
};

fn forwardBridgeFramesToDaemon(
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    fds: BridgeFds,
) !void {
    // sessh-bridge is the OpenSSH-facing process in ProxyCommand mode. It
    // speaks framed sessh protocol on OpenSSH stdio and forwards those frames to
    // local sesshd; it does not interpret terminal or proxy stream payloads.
    defer {
        _ = c.shutdown(fds.stdin, c.SHUT.WR);
        if (fds.stdout != fds.stdin) _ = c.shutdown(fds.stdout, c.SHUT.WR);
        _ = c.shutdown(fds.daemon, c.SHUT.WR);
    }

    try core_fds.setNonBlocking(fds.stdin);
    try core_fds.setNonBlocking(fds.stdout);
    try core_fds.setNonBlocking(fds.daemon);

    const stdio_dispatcher = dispatcher.get();
    var client_to_daemon = try BridgeFramePipe.init(
        allocator,
        stdio_dispatcher,
        fds.stdin,
        fds.daemon,
        .add_current_environment,
    );
    defer client_to_daemon.deinit();
    var daemon_to_client = try BridgeFramePipe.init(
        allocator,
        stdio_dispatcher,
        fds.daemon,
        fds.stdout,
        .none,
    );
    defer daemon_to_client.deinit();

    // sessh-bridge is only a framed relay between OpenSSH
    // and the local daemon. It registers that bridge on the process Dispatcher.
    var bridge = StdioBridge{
        .client_to_daemon = &client_to_daemon,
        .daemon_to_client = &daemon_to_client,
    };
    defer bridge.deinit();
    try bridge.registerSources(stdio_dispatcher);
    try blocking.runLoop();
}

const StdioBridge = struct {
    client_to_daemon: *BridgeFramePipe,
    daemon_to_client: *BridgeFramePipe,

    fn registerSources(self: *StdioBridge, stdio_dispatcher: *dispatcher.Dispatcher) !void {
        try self.client_to_daemon.schedule(stdio_dispatcher);
        try self.daemon_to_client.schedule(stdio_dispatcher);
    }

    fn deinit(self: *StdioBridge) void {
        _ = self;
    }
};

const BridgeFrameTransform = enum {
    none,
    add_current_environment,
};

const BridgeFramePipe = struct {
    allocator: std.mem.Allocator,
    transform: BridgeFrameTransform,
    source: dispatcher.Source,
    sink: dispatcher.Sink,
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),

    fn init(
        allocator: std.mem.Allocator,
        stdio_dispatcher: *dispatcher.Dispatcher,
        source_fd: c.fd_t,
        sink_fd: c.fd_t,
        transform: BridgeFrameTransform,
    ) !BridgeFramePipe {
        var source = try stdio_dispatcher.frameSource(source_fd);
        errdefer source.deinit();
        var sink = try stdio_dispatcher.frameSink(.{ .allocator = allocator, .fd = sink_fd });
        errdefer sink.deinit();
        return .{
            .allocator = allocator,
            .transform = transform,
            .source = source,
            .sink = sink,
        };
    }

    fn deinit(self: *BridgeFramePipe) void {
        self.task.deinit();
        self.source.deinit();
        self.sink.deinit();
    }

    fn schedule(self: *BridgeFramePipe, stdio_dispatcher: *dispatcher.Dispatcher) !void {
        self.task = dispatcher.dispatchTask(BridgeFramePipe, self.allocator, self, runBridgeFramePipeTask);
        try self.task.requireSource(self.source);
        try self.task.requireSink(self.sink);
        try self.task.schedule(stdio_dispatcher);
    }

    fn run(self: *BridgeFramePipe, stdio_dispatcher: *dispatcher.Dispatcher) !dispatch_io.DispatchTaskStatus {
        switch (self.source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                stdio_dispatcher.stop();
                return .done;
            },
            else => return err,
        }) {
            .blocked => return .pending,
            .eof => {
                stdio_dispatcher.stop();
                return .done;
            },
            .frame => |frame_value| {
                var owned_frame = frame_value;
                defer owned_frame.deinit(self.allocator);
                try self.writeFrame(&owned_frame);
                return .pending;
            },
        }
    }

    fn writeFrame(self: *BridgeFramePipe, owned_frame: *protocol.OwnedFrame) !void {
        switch (self.transform) {
            .none => return self.sink.writeOwnedFrame(owned_frame),
            .add_current_environment => return self.writeClientFrame(owned_frame),
        }
    }

    fn writeClientFrame(self: *BridgeFramePipe, owned_frame: *protocol.OwnedFrame) !void {
        if (owned_frame.message_type != .client_remote) return self.sink.writeOwnedFrame(owned_frame);
        if (owned_frame.fd != null) return error.FdSendUnsupported;

        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(self.allocator, owned_frame.payload);
        defer item.deinit(self.allocator);
        if (item.payload) |item_payload| {
            switch (item_payload) {
                .open => |request| {
                    return self.writeEnvironmentOpen(request);
                },
                else => {},
            }
        }
        return self.sink.writeOwnedFrame(owned_frame);
    }

    fn writeEnvironmentOpen(self: *BridgeFramePipe, request: pb.TerminalEmulatorItem.Open) !void {
        const open_payload = try protocol.encodePayload(self.allocator, request);
        defer self.allocator.free(open_payload);
        const payload = try session_daemon_handler.sessionOpenPayloadWithCurrentEnvironment(self.allocator, open_payload);
        defer self.allocator.free(payload);
        var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, self.allocator, payload);
        defer open.deinit(self.allocator);
        const terminal_item = pb.TerminalEmulatorItem{ .payload = .{ .open = open } };
        const client_remote_payload = try protocol.encodeTerminalEmulatorItemPayload(self.allocator, terminal_item);
        defer self.allocator.free(client_remote_payload);
        return self.sink.writeFrame(.client_remote, client_remote_payload);
    }
};

fn runBridgeFramePipeTask(
    pipe: *BridgeFramePipe,
    stdio_dispatcher: *dispatcher.Dispatcher,
    _: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    return pipe.run(stdio_dispatcher);
}
