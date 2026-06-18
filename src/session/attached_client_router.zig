const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const input_translation = @import("input_translation.zig");
const attached_client_presentation = @import("attached_client_presentation.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;
const max_output_queue_bytes = 64 * 1024 * 1024;

pub const AttachedClient = struct {
    fd: c.fd_t = -1,
    rows: u16 = 24,
    cols: u16 = 80,
    attached_at_unix_ms: u64 = 0,
    origin: ?attached_client_presentation.TerminalOrigin = null,
    active: bool = false,
    close_after_flush: bool = false,
    debug_unresponsive_until_ms: i64 = 0,
    presentation: attached_client_presentation.PresentationState = .{},
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    input_pending: input_translation.PendingInput = .{},
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    capture_tty_transcript: bool = false,

    pub fn queuedBytes(self: *const AttachedClient) usize {
        return self.output.items.len - self.output_offset;
    }

    pub fn queueError(self: *AttachedClient, code: []const u8, message: []const u8, hint: []const u8) !void {
        const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
            .code = code,
            .message = message,
            .hint = hint,
        });
        defer app_allocator.allocator().free(payload);
        try self.queueFrame(.error_message, payload);
    }

    pub fn queueTerminalEmulatorFrame(self: *AttachedClient, payload: protocol.TerminalEmulatorPayload) !void {
        const encoded = try protocol.encodeTerminalEmulatorItemPayload(app_allocator.allocator(), .{ .payload = payload });
        defer app_allocator.allocator().free(encoded);
        try self.queueFrame(.client_remote, encoded);
    }

    pub fn queueFrame(self: *AttachedClient, message_type: protocol.MessageType, payload: []const u8) !void {
        const frame = try protocol.encodeFrame(app_allocator.allocator(), message_type, payload);
        defer app_allocator.allocator().free(frame);
        const frame_len = frame.len;
        if (frame_len > max_output_queue_bytes or
            self.queuedBytes() > max_output_queue_bytes - frame_len)
        {
            return error.AttachedClientOutputQueueFull;
        }

        self.compactOutput();
        try self.output.appendSlice(app_allocator.allocator(), frame);
    }

    fn compactOutput(self: *AttachedClient) void {
        if (self.output_offset == 0) return;
        if (self.output_offset >= self.output.items.len) {
            self.output.clearRetainingCapacity();
            self.output_offset = 0;
            return;
        }

        const remaining = self.output.items.len - self.output_offset;
        std.mem.copyForwards(
            u8,
            self.output.items[0..remaining],
            self.output.items[self.output_offset..],
        );
        self.output.shrinkRetainingCapacity(remaining);
        self.output_offset = 0;
    }
};

pub const PendingWorkerClient = struct {
    fd: c.fd_t = -1,
    active: bool = false,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,

    pub fn start(self: *PendingWorkerClient, fd: c.fd_t) void {
        self.close();
        self.* = .{
            .fd = fd,
            .active = true,
            .reader = protocol.FrameReader.init(app_allocator.allocator()),
            .reader_initialized = true,
        };
    }

    pub fn close(self: *PendingWorkerClient) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
        }
        if (self.reader_initialized) self.reader.deinit();
        self.* = .{};
    }

    pub fn takeFd(self: *PendingWorkerClient) c.fd_t {
        const fd = self.fd;
        self.fd = -1;
        return fd;
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
