const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");

pub const Endpoint = struct {
    fd: c.fd_t = -1,
    watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    writer: frame_write_queue.FrameWriteQueue = undefined,
    writer_initialized: bool = false,

    pub fn active(self: *const Endpoint) bool {
        return self.fd >= 0;
    }

    pub fn close(self: *Endpoint, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            if (self.watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        }
        self.watch_id = null;
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.reader_initialized) {
            self.reader.deinit();
            self.reader_initialized = false;
        }
        if (self.writer_initialized) {
            self.writer.deinit();
            self.writer_initialized = false;
        }
    }

    pub fn initWriter(self: *Endpoint, allocator: std.mem.Allocator) void {
        self.writer = frame_write_queue.FrameWriteQueue.init(allocator);
        self.writer_initialized = true;
    }

    pub fn initReader(self: *Endpoint, allocator: std.mem.Allocator) void {
        self.reader = protocol.FrameReader.init(allocator);
        self.reader_initialized = true;
    }

    pub fn watchEvents(self: *const Endpoint) dispatcher.FdEvents {
        return .{
            .readable = true,
            .writable = self.writer_initialized and self.writer.hasPending(),
        };
    }

    pub fn updateWatch(self: *Endpoint, daemon_dispatcher: *dispatcher.Dispatcher) !void {
        const watch_id = self.watch_id orelse return;
        try daemon_dispatcher.updateFdEvents(watch_id, self.watchEvents());
    }

    pub fn watch(
        self: *Endpoint,
        daemon_dispatcher: *dispatcher.Dispatcher,
        handler: dispatcher.Handler,
    ) !void {
        self.watch_id = try daemon_dispatcher.watchFd(self.fd, self.watchEvents(), .{
            .ctx = handler.ctx,
            .callback = handler.callback,
        });
    }

    pub fn drainWrites(self: *Endpoint, daemon_dispatcher: *dispatcher.Dispatcher) !frame_write_queue.WriteQueueStatus {
        if (!self.writer_initialized or self.fd < 0) return .drained;
        const status = try self.writer.writeReady(self.fd);
        try self.updateWatch(daemon_dispatcher);
        return status;
    }

    pub fn queueFrame(self: *Endpoint, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.writer_initialized) return error.WorkerEndpointWriterMissing;
        try self.writer.queueFrame(message_type, payload);
    }

    pub fn queueMuxStreamFrame(self: *Endpoint, message: protocol.pb.DaemonTunnelItem.MuxStreamFrame) !void {
        if (!self.writer_initialized) return error.WorkerEndpointWriterMissing;
        try self.writer.queueMuxStreamFrame(message);
    }
};
