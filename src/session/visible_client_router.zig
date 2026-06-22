// Terminal-worker side of a visible-client connection. It owns queued output,
// input translation state, and dispatcher watches for the client fd after the
// daemon has routed the client to this worker.
const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const terminal = @import("../tty/terminal.zig");
const input_translation = @import("input_translation.zig");
const visible_client_presentation = @import("visible_client_presentation.zig");

const pb = protocol.pb;
const max_output_pending_bytes = 64 * 1024 * 1024;
const WindowSize = terminal.WindowSize;

pub const VisibleClient = struct {
    fd: c.fd_t = -1,
    // Distinguishes a new client connection from an old one that happened to
    // use the same integer fd after close/reconnect.
    generation: u64 = 0,
    size: WindowSize = .{},
    connected_at_unix_ms: u64 = 0,
    origin: ?terminal.Position = null,
    active: bool = false,
    close_after_flush: bool = false,
    debug_unresponsive_until_ms: i64 = 0,
    presentation: visible_client_presentation.PresentationState = .{},
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    input_pending: input_translation.PendingInput = .{},
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    capture_tty_transcript: bool = false,

    pub fn pendingBytes(self: *const VisibleClient) usize {
        if (!self.sink.isInitialized()) return 0;
        return self.sink.frame().pendingBytes();
    }

    pub fn hasPendingWrite(self: *const VisibleClient) bool {
        return self.sink.isInitialized() and self.sink.hasPendingWrite();
    }

    pub fn inputModeState(self: *const VisibleClient) input_translation.ModeState {
        return .{
            .origin = self.origin,
            .terminal_modes = self.presentation.terminal_modes,
            .terminal_modes_initialized = self.presentation.terminal_modes_initialized,
        };
    }

    pub fn queueError(self: *VisibleClient, info: protocol.ErrorInfo) !void {
        const payload = try protocol.encodeErrorPayload(app_allocator.allocator(), info);
        defer app_allocator.allocator().free(payload);
        try self.writeFrame(.error_message, payload);
    }

    pub fn queueProtocolError(self: *VisibleClient, message: []const u8) !void {
        try self.queueError(.{
            .code = "PROTOCOL_ERROR",
            .message = message,
        });
    }

    pub fn queueTerminalEmulatorFrame(self: *VisibleClient, payload: protocol.TerminalEmulatorPayload) !void {
        const encoded = try protocol.encodeTerminalEmulatorItemPayload(app_allocator.allocator(), .{ .payload = payload });
        defer app_allocator.allocator().free(encoded);
        try self.writeFrame(.client_remote, encoded);
    }

    pub fn writeDaemonTunnelPayload(self: *VisibleClient, payload: protocol.DaemonTunnelPayload) !void {
        const encoded = try protocol.encodeDaemonTunnelPayload(app_allocator.allocator(), payload);
        defer app_allocator.allocator().free(encoded);
        try self.writeFrame(.daemon_tunnel, encoded);
    }

    pub fn writeFrame(self: *VisibleClient, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.sink.isInitialized()) return error.VisibleClientWriterMissing;
        self.sink.frame().writeFrameBounded(.{
            .message_type = message_type,
            .payload = payload,
            .max_pending_bytes = max_output_pending_bytes,
        }) catch |err| switch (err) {
            error.FrameSinkFull => return error.VisibleClientOutputQueueFull,
            else => return err,
        };
    }

    pub fn readReady(self: *VisibleClient) !dispatch_io.SourceReadStatus {
        if (!self.source.isInitialized()) return error.VisibleClientReaderMissing;
        return self.source.frame().readReady();
    }

    pub fn popFrame(self: *VisibleClient) ?protocol.OwnedFrame {
        if (!self.source.isInitialized()) return null;
        return self.source.frame().popFrame();
    }

    pub fn readFrame(self: *VisibleClient) !dispatch_io.FrameSource.Read {
        if (!self.source.isInitialized()) return error.VisibleClientReaderMissing;
        return self.source.readFrame();
    }
};

pub const PendingWorkerClient = struct {
    fd: c.fd_t = -1,
    active: bool = false,
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    close_after_flush: bool = false,

    pub fn start(self: *PendingWorkerClient, daemon_dispatcher: *dispatcher.Dispatcher, fd: c.fd_t) !void {
        self.close();
        var source = try daemon_dispatcher.frameSource(fd);
        errdefer source.deinit();
        var sink = try daemon_dispatcher.frameSink(.{ .allocator = app_allocator.allocator(), .fd = fd });
        errdefer sink.deinit();
        self.* = .{
            .fd = fd,
            .active = true,
            .source = source,
            .sink = sink,
        };
    }

    pub fn close(self: *PendingWorkerClient) void {
        self.source.deinit();
        self.sink.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
        }
        self.* = .{};
    }

    pub fn takeFd(self: *PendingWorkerClient) c.fd_t {
        const fd = self.fd;
        self.fd = -1;
        self.source.deinit();
        self.sink.deinit();
        return fd;
    }

    pub fn hasPendingWrite(self: *const PendingWorkerClient) bool {
        return self.sink.isInitialized() and self.sink.hasPendingWrite();
    }

    pub fn queueError(self: *PendingWorkerClient, info: protocol.ErrorInfo) !void {
        const payload = try protocol.encodeErrorPayload(app_allocator.allocator(), info);
        defer app_allocator.allocator().free(payload);
        try self.writeFrame(.error_message, payload);
    }

    pub fn queueProtocolError(self: *PendingWorkerClient, message: []const u8) !void {
        try self.queueError(.{
            .code = "PROTOCOL_ERROR",
            .message = message,
        });
    }

    pub fn queueSessionNotFound(self: *PendingWorkerClient) !void {
        try self.queueError(.{
            .code = "SESSION_NOT_FOUND",
            .message = "session not found",
        });
    }

    pub fn queueTerminalEmulatorFrame(self: *PendingWorkerClient, payload: protocol.TerminalEmulatorPayload) !void {
        const encoded = try protocol.encodeTerminalEmulatorItemPayload(app_allocator.allocator(), .{ .payload = payload });
        defer app_allocator.allocator().free(encoded);
        try self.writeFrame(.client_remote, encoded);
    }

    pub fn writeDaemonTunnelPayload(self: *PendingWorkerClient, payload: protocol.DaemonTunnelPayload) !void {
        if (!self.sink.isInitialized()) return error.PendingWorkerClientWriterMissing;
        try self.sink.frame().writeDaemonTunnelPayload(payload);
    }

    pub fn readReady(self: *PendingWorkerClient) !dispatch_io.SourceReadStatus {
        if (!self.source.isInitialized()) return error.PendingWorkerClientReaderMissing;
        return self.source.frame().readReady();
    }

    pub fn popFrame(self: *PendingWorkerClient) ?protocol.OwnedFrame {
        if (!self.source.isInitialized()) return null;
        return self.source.frame().popFrame();
    }

    pub fn readFrame(self: *PendingWorkerClient) !dispatch_io.FrameSource.Read {
        if (!self.source.isInitialized()) return error.PendingWorkerClientReaderMissing;
        return self.source.readFrame();
    }

    fn writeFrame(self: *PendingWorkerClient, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.sink.isInitialized()) return error.PendingWorkerClientWriterMissing;
        try self.sink.writeFrame(message_type, payload);
    }
};

pub const WorkerFdWatch = struct {
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    fd: c.fd_t = -1,
    // Optional owner-provided identity for fd reuse. Without this, handoff from
    // pending client to visible client can accidentally reuse and then cancel
    // the same Dispatcher Source when the OS recycles the fd number.
    token: u64 = 0,

    pub fn cancel(self: *WorkerFdWatch, daemon_dispatcher: *dispatcher.Dispatcher) void {
        _ = daemon_dispatcher;
        self.source.deinit();
        self.* = .{};
    }

    pub fn active(self: *const WorkerFdWatch) bool {
        return self.source.isInitialized();
    }

    pub fn takeEvent(self: *WorkerFdWatch) ?dispatcher.FdEvent {
        if (!self.source.isInitialized()) return null;
        return self.source.takeFdEvent();
    }
};

test "pending worker client drains queued error before close" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const pipe = try std.posix.pipe();
    defer {
        _ = c.close(pipe[0]);
    }
    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var pending = PendingWorkerClient{};
    try pending.start(&d, pipe[1]);
    defer pending.close();

    try pending.queueProtocolError("bad request");
    pending.close_after_flush = true;
    try std.testing.expect(pending.hasPendingWrite());
    try std.testing.expectEqual(dispatch_io.SinkWriteStatus.drained, try pending.sink.frame().writeReady());
    try std.testing.expect(!pending.hasPendingWrite());

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.error_message, frame.message_type);
}
