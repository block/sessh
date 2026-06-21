const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const dispatch_io = @import("../core/dispatch_io.zig");

pub const Endpoint = struct {
    fd: c.fd_t = -1,
    dispatch_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    source: dispatch_io.FrameSource = undefined,
    source_initialized: bool = false,
    writer: dispatch_io.FrameSink = undefined,
    writer_initialized: bool = false,

    pub fn active(self: *const Endpoint) bool {
        return self.fd >= 0;
    }

    pub fn close(self: *Endpoint, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        _ = daemon_dispatcher;
        self.dispatch_source.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.source_initialized) {
            self.source.deinit();
            self.source_initialized = false;
        }
        if (self.writer_initialized) {
            self.writer.deinit();
            self.writer_initialized = false;
        }
    }

    pub fn takeFd(self: *Endpoint, daemon_dispatcher: ?*dispatcher.Dispatcher) c.fd_t {
        _ = daemon_dispatcher;
        self.dispatch_source.deinit();
        if (self.source_initialized) {
            self.source.deinit();
            self.source_initialized = false;
        }
        if (self.writer_initialized) {
            self.writer.deinit();
            self.writer_initialized = false;
        }
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }

    pub fn initWriter(self: *Endpoint, allocator: std.mem.Allocator) void {
        self.writer = dispatch_io.FrameSink.init(.{ .allocator = allocator, .fd = -1 });
        self.writer_initialized = true;
    }

    pub fn initReader(self: *Endpoint, allocator: std.mem.Allocator) void {
        self.source = dispatch_io.FrameSource.init(allocator, self.fd);
        self.source_initialized = true;
    }

    pub fn watchEvents(self: *const Endpoint) dispatcher.FdEvents {
        return .{
            .readable = true,
            .writable = self.writer_initialized and self.writer.hasPendingWrite(),
        };
    }

    pub fn updateDispatchSource(self: *Endpoint) void {
        if (!self.dispatch_source.isInitialized()) return;
        self.dispatch_source.setFdEvents(self.watchEvents());
    }

    pub fn initDispatchSource(
        self: *Endpoint,
        daemon_dispatcher: *dispatcher.Dispatcher,
    ) !void {
        if (self.dispatch_source.isInitialized()) {
            self.updateDispatchSource();
            return;
        }
        self.dispatch_source = try daemon_dispatcher.fdSource(self.fd, self.watchEvents());
    }

    pub fn drainWrites(self: *Endpoint, daemon_dispatcher: *dispatcher.Dispatcher) !dispatch_io.SinkWriteStatus {
        _ = daemon_dispatcher;
        if (!self.writer_initialized or self.fd < 0) return .drained;
        const status = try self.writer.writeReadyTo(self.fd);
        self.updateDispatchSource();
        return status;
    }

    pub fn readReady(self: *Endpoint) !dispatch_io.SourceReadStatus {
        if (!self.source_initialized) return error.WorkerEndpointReaderMissing;
        return self.source.readReady();
    }

    pub fn popFrame(self: *Endpoint) ?protocol.OwnedFrame {
        if (!self.source_initialized) return null;
        return self.source.popFrame();
    }

    pub fn readFrame(self: *Endpoint) !dispatch_io.FrameSource.Read {
        if (!self.source_initialized) return error.WorkerEndpointReaderMissing;
        return self.source.readFrame();
    }

    pub fn writeFrame(self: *Endpoint, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.writer_initialized) return error.WorkerEndpointWriterMissing;
        try self.writer.writeFrame(message_type, payload);
    }

    pub fn writeMuxStreamFrame(self: *Endpoint, message: protocol.pb.DaemonTunnelItem.MuxStreamFrame) !void {
        if (!self.writer_initialized) return error.WorkerEndpointWriterMissing;
        try self.writer.writeMuxStreamFrame(message);
    }
};
