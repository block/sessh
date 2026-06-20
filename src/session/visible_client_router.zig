const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");
const terminal = @import("../tty/terminal.zig");
const input_translation = @import("input_translation.zig");
const visible_client_presentation = @import("visible_client_presentation.zig");

const pb = protocol.pb;
const max_output_queue_bytes = 64 * 1024 * 1024;
const WindowSize = terminal.WindowSize;

pub const VisibleClient = struct {
    fd: c.fd_t = -1,
    size: WindowSize = .{},
    connected_at_unix_ms: u64 = 0,
    origin: ?terminal.Position = null,
    active: bool = false,
    close_after_flush: bool = false,
    debug_unresponsive_until_ms: i64 = 0,
    presentation: visible_client_presentation.PresentationState = .{},
    writer: frame_write_queue.FrameWriteQueue = undefined,
    writer_initialized: bool = false,
    input_pending: input_translation.PendingInput = .{},
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    capture_tty_transcript: bool = false,

    pub fn queuedBytes(self: *const VisibleClient) usize {
        if (!self.writer_initialized) return 0;
        return self.writer.queuedBytes();
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
        try self.queueFrame(.error_message, payload);
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
        try self.queueFrame(.client_remote, encoded);
    }

    pub fn queueDaemonTunnelPayload(self: *VisibleClient, payload: protocol.DaemonTunnelPayload) !void {
        const encoded = try protocol.encodeDaemonTunnelPayload(app_allocator.allocator(), payload);
        defer app_allocator.allocator().free(encoded);
        try self.queueFrame(.daemon_tunnel, encoded);
    }

    pub fn queueFrame(self: *VisibleClient, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.writer_initialized) return error.VisibleClientWriterMissing;
        self.writer.queueFrameWithByteLimit(.{
            .message_type = message_type,
            .payload = payload,
            .max_queued_bytes = max_output_queue_bytes,
        }) catch |err| switch (err) {
            error.FrameWriteQueueFull => return error.VisibleClientOutputQueueFull,
            else => return err,
        };
    }
};

pub const PendingWorkerClient = struct {
    fd: c.fd_t = -1,
    active: bool = false,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    writer: frame_write_queue.FrameWriteQueue = undefined,
    writer_initialized: bool = false,
    close_after_flush: bool = false,

    pub fn start(self: *PendingWorkerClient, fd: c.fd_t) void {
        self.close();
        self.* = .{
            .fd = fd,
            .active = true,
            .reader = protocol.FrameReader.init(app_allocator.allocator()),
            .reader_initialized = true,
            .writer = frame_write_queue.FrameWriteQueue.init(app_allocator.allocator()),
            .writer_initialized = true,
        };
    }

    pub fn close(self: *PendingWorkerClient) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
        }
        if (self.reader_initialized) self.reader.deinit();
        if (self.writer_initialized) self.writer.deinit();
        self.* = .{};
    }

    pub fn takeFd(self: *PendingWorkerClient) c.fd_t {
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }

    pub fn hasPendingWrite(self: *const PendingWorkerClient) bool {
        return self.writer_initialized and self.writer.hasPending();
    }

    pub fn watchEvents(self: *const PendingWorkerClient) dispatcher.FdEvents {
        return .{
            .readable = !self.close_after_flush,
            .writable = self.hasPendingWrite(),
        };
    }

    pub fn queueError(self: *PendingWorkerClient, info: protocol.ErrorInfo) !void {
        const payload = try protocol.encodeErrorPayload(app_allocator.allocator(), info);
        defer app_allocator.allocator().free(payload);
        try self.queueFrame(.error_message, payload);
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
        try self.queueFrame(.client_remote, encoded);
    }

    pub fn queueDaemonTunnelPayload(self: *PendingWorkerClient, payload: protocol.DaemonTunnelPayload) !void {
        if (!self.writer_initialized) return error.PendingWorkerClientWriterMissing;
        try self.writer.queueDaemonTunnelPayload(payload);
    }

    pub fn drainWrites(self: *PendingWorkerClient) !frame_write_queue.WriteQueueStatus {
        if (!self.writer_initialized or self.fd < 0) return .drained;
        return self.writer.writeReady(self.fd);
    }

    fn queueFrame(self: *PendingWorkerClient, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.writer_initialized) return error.PendingWorkerClientWriterMissing;
        try self.writer.queueFrame(message_type, payload);
    }
};

pub const WorkerFdWatch = struct {
    id: ?dispatcher.FdWatchId = null,
    fd: c.fd_t = -1,

    pub fn cancel(self: *WorkerFdWatch, daemon_dispatcher: *dispatcher.Dispatcher) void {
        if (self.id) |id| daemon_dispatcher.cancel(.{ .fd = id });
        self.* = .{};
    }

    pub fn matches(self: *const WorkerFdWatch, id: dispatcher.FdWatchId) bool {
        const watch_id = self.id orelse return false;
        return watch_id.index == id.index and watch_id.generation == id.generation;
    }
};

test "pending worker client drains queued error before close" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const pipe = try std.posix.pipe();
    defer {
        _ = c.close(pipe[0]);
    }

    var pending = PendingWorkerClient{};
    pending.start(pipe[1]);
    defer pending.close();

    try pending.queueProtocolError("bad request");
    pending.close_after_flush = true;
    try std.testing.expect(pending.hasPendingWrite());
    try std.testing.expectEqual(frame_write_queue.WriteQueueStatus.drained, try pending.drainWrites());
    try std.testing.expect(!pending.hasPendingWrite());

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.error_message, frame.message_type);
}
