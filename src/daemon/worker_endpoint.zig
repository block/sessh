const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const dispatch_io = @import("../core/dispatch_io.zig");

pub const Endpoint = struct {
    fd: c.fd_t = -1,
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),

    pub fn active(self: *const Endpoint) bool {
        return self.fd >= 0;
    }

    pub fn close(self: *Endpoint, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        _ = daemon_dispatcher;
        self.source.deinit();
        self.sink.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn takeFd(self: *Endpoint, daemon_dispatcher: ?*dispatcher.Dispatcher) c.fd_t {
        _ = daemon_dispatcher;
        self.source.deinit();
        self.sink.deinit();
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }

    pub fn initIo(
        self: *Endpoint,
        daemon_dispatcher: *dispatcher.Dispatcher,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.source.isInitialized() or self.sink.isInitialized()) return;
        self.source = try daemon_dispatcher.frameSource(self.fd);
        self.sink = try daemon_dispatcher.frameSink(.{ .allocator = allocator, .fd = self.fd });
    }

    pub fn drainWrites(self: *Endpoint, daemon_dispatcher: *dispatcher.Dispatcher) !dispatch_io.SinkWriteStatus {
        _ = daemon_dispatcher;
        if (!self.sink.isInitialized()) return .drained;
        return self.sink.frame().writeReady();
    }

    pub fn readFrame(self: *Endpoint) !dispatch_io.FrameSource.Read {
        if (!self.source.isInitialized()) return error.WorkerEndpointReaderMissing;
        return self.source.readFrame();
    }

    pub fn writeFrame(self: *Endpoint, message_type: protocol.MessageType, payload: []const u8) !void {
        if (!self.sink.isInitialized()) return error.WorkerEndpointWriterMissing;
        try self.sink.frame().writeFrame(message_type, payload);
    }

    pub fn writeMuxStreamFrame(self: *Endpoint, message: protocol.pb.DaemonTunnelItem.MuxStreamFrame) !void {
        if (!self.sink.isInitialized()) return error.WorkerEndpointWriterMissing;
        try self.sink.frame().writeMuxStreamFrame(message);
    }

    pub fn writeDaemonTunnelPayload(self: *Endpoint, payload: protocol.DaemonTunnelPayload) !void {
        if (!self.sink.isInitialized()) return error.WorkerEndpointWriterMissing;
        try self.sink.frame().writeDaemonTunnelPayload(payload);
    }
};
