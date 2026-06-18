const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const dispatcher = @import("../core/dispatcher.zig");
const guid_ref = @import("../core/guid.zig");
const protocol = @import("../protocol/mod.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");
const proxy_remote = @import("proxy_remote.zig");

const pb = protocol.pb;
const proxy_mux_stream_id: u64 = 1;

pub const ProxyMuxStream = struct {
    stream_id: u64,
    process_fd: c.fd_t = -1,
    process_watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    process_writer: frame_write_queue.FrameWriteQueue = undefined,
    writer_initialized: bool = false,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
    proxy_guid: [guid_ref.proxy_guid_len]u8 = [_]u8{0} ** guid_ref.proxy_guid_len,
    proxy_guid_len: usize = 0,
    cleanup_recorded: bool = false,

    pub fn proxyGuidSlice(self: *const ProxyMuxStream) []const u8 {
        return self.proxy_guid[0..self.proxy_guid_len];
    }

    fn setProxyGuid(self: *ProxyMuxStream, guid: []const u8) !void {
        if (guid.len > self.proxy_guid.len) return error.ProxyGuidTooLarge;
        @memcpy(self.proxy_guid[0..guid.len], guid);
        self.proxy_guid_len = guid.len;
    }
};

pub fn closeProxyMuxStreams(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    for (streams.items) |stream| {
        closeProxyMuxStream(allocator, stream, true, daemon_dispatcher);
    }
    streams.deinit(allocator);
}

pub fn closeProxyMuxStream(
    allocator: std.mem.Allocator,
    stream: ProxyMuxStream,
    send_startup_failed: bool,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    if (daemon_dispatcher) |d| {
        if (stream.process_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
    }
    if (stream.process_fd >= 0 and send_startup_failed and !stream.cleanup_recorded) {
        sendProxyMuxReset(allocator, stream.process_fd, proxy_mux_stream_id, "STARTUP_FAILED", "proxy cleanup record was not acknowledged") catch {};
    }
    if (stream.process_fd >= 0) _ = c.close(stream.process_fd);
    var moved_stream = stream;
    if (moved_stream.reader_initialized) moved_stream.reader.deinit();
    if (moved_stream.writer_initialized) moved_stream.process_writer.deinit();
}

pub fn handleProxyMuxStreamFrame(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_writer: *frame_write_queue.FrameWriteQueue,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(allocator);
    const message = owned_mux_frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| try handleProxyMuxOpen(allocator, streams, owned_mux_frame.stream_id, open, daemon_dispatcher),
        .payload => |payload| try handleProxyMuxPayload(allocator, exe, identity, streams, mux_writer, owned_mux_frame.stream_id, payload, owned_mux_frame, process_watch_handler, daemon_dispatcher),
        .open_ok, .ack, .eof => try forwardProxyMuxFrameToProxyRemote(allocator, streams, owned_mux_frame),
        .reset => {
            forwardProxyMuxFrameToProxyRemote(allocator, streams, owned_mux_frame) catch {};
            try removeProxyMuxStream(allocator, streams, owned_mux_frame.stream_id, daemon_dispatcher);
        },
    }
}

pub fn handleProxyMuxOpen(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    if (findProxyMuxStreamIndex(streams, stream_id)) |index| {
        streams.items[index].open = open;
        if (streams.items[index].process_fd >= 0) {
            try queueProxyProcessFrame(allocator, &streams.items[index], .{
                .stream_id = proxy_mux_stream_id,
                .message = .{ .open = open },
            });
            if (daemon_dispatcher) |d| try updateProxyProcessWatch(&streams.items[index], d);
        }
        return;
    }
    try streams.append(allocator, .{
        .stream_id = stream_id,
        .open = open,
    });
}

fn handleProxyMuxPayload(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_writer: *frame_write_queue.FrameWriteQueue,
    stream_id: u64,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const item = payload.item orelse return error.StreamUnexpectedFrame;
    const proxy_item = switch (item) {
        .proxy => |proxy| proxy,
        else => return error.StreamUnexpectedFrame,
    };
    const proxy_payload = proxy_item.payload orelse return error.StreamUnexpectedFrame;
    switch (proxy_payload) {
        .open => |request| try handleProxyMuxPayloadOpen(allocator, exe, identity, streams, mux_writer, stream_id, request, process_watch_handler, daemon_dispatcher),
        .data => {
            try forwardProxyMuxFrameToProxyRemote(allocator, streams, mux_frame);
            if (daemon_dispatcher) |d| {
                const index = findProxyMuxStreamIndex(streams, stream_id) orelse return error.StreamUnexpectedFrame;
                try updateProxyProcessWatch(&streams.items[index], d);
            }
        },
    }
}

fn handleProxyMuxPayloadOpen(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_writer: *frame_write_queue.FrameWriteQueue,
    stream_id: u64,
    request: pb.ProxyStreamItem.Open,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findProxyMuxStreamIndex(streams, stream_id) orelse return error.StreamUnexpectedFrame;
    if (streams.items[index].process_fd >= 0) return;
    if (!guid_ref.isValidProxyGuid(request.proxy_guid)) return error.InvalidStreamGuid;
    if (request.proxy_port == 0 or request.proxy_port > std.math.maxInt(u16)) return error.InvalidStreamArgs;

    const remote_process = try proxy_remote.connectOrStart(
        allocator,
        exe,
        request.proxy_guid,
        request.proxy_host,
        @intCast(request.proxy_port),
    );
    const process_fd = try proxy_remote.connectStarted(remote_process);
    errdefer _ = c.close(process_fd);
    if (daemon_dispatcher != null) {
        try core_fds.setNonBlocking(process_fd);
    }

    streams.items[index].process_writer = frame_write_queue.FrameWriteQueue.init(allocator);
    streams.items[index].writer_initialized = true;
    try queueProxyProcessFrame(allocator, &streams.items[index], .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open = streams.items[index].open },
    });
    streams.items[index].process_fd = process_fd;
    const canonical = try guid_ref.canonicalProxyGuid(allocator, request.proxy_guid);
    defer allocator.free(canonical);
    try streams.items[index].setProxyGuid(canonical);
    try mux_writer.queueDaemonTunnelPayload(.{ .remote_process_started = .{
        .stream_id = stream_id,
        .process = daemon_cleanup.makeRemoteProcessIdentity(identity, canonical),
    } });
    if (daemon_dispatcher) |d| {
        const handler = process_watch_handler orelse return error.MissingProxyRemoteHandler;
        streams.items[index].reader = protocol.FrameReader.init(allocator);
        streams.items[index].reader_initialized = true;
        streams.items[index].process_watch_id = try d.watchFd(process_fd, proxyProcessWatchEvents(&streams.items[index]), .{
            .ctx = handler.ctx,
            .callback = handler.callback,
        });
        _ = try drainProxyProcessWrites(&streams.items[index], d);
    }
}

fn forwardProxyMuxFrameToProxyRemote(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const index = findProxyMuxStreamIndex(streams, mux_frame.stream_id) orelse return error.StreamUnexpectedFrame;
    if (streams.items[index].process_fd < 0) return error.StreamUnexpectedFrame;
    var remapped = mux_frame;
    remapped.stream_id = proxy_mux_stream_id;
    try queueProxyProcessFrame(allocator, &streams.items[index], remapped);
}

pub fn forwardProxyRemoteFrameToMux(
    allocator: std.mem.Allocator,
    mux_writer: *frame_write_queue.FrameWriteQueue,
    stream: *ProxyMuxStream,
    frame: *protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return error.StreamUnexpectedFrame;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    mux_frame.stream_id = stream.stream_id;
    try queueProxyMuxFrame(allocator, mux_writer, mux_frame);
    return true;
}

pub fn handleProxyRemoteControlFrame(
    allocator: std.mem.Allocator,
    stream: *ProxyMuxStream,
    frame: *protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, allocator, frame.payload);
    defer item.deinit(allocator);
    switch (item.payload orelse return false) {
        .ping => {
            try stream.process_writer.queueDaemonTunnelPayload(.{ .pong = .{} });
            return true;
        },
        .pong => return true,
        else => return false,
    }
}

pub fn findProxyMuxStreamIndex(streams: *const std.ArrayList(ProxyMuxStream), stream_id: u64) ?usize {
    for (streams.items, 0..) |stream, index| {
        if (stream.stream_id == stream_id) return index;
    }
    return null;
}

pub fn findProxyMuxStreamIndexByWatch(streams: *const std.ArrayList(ProxyMuxStream), watch_id: dispatcher.FdWatchId) ?usize {
    for (streams.items, 0..) |stream, index| {
        const process_watch_id = stream.process_watch_id orelse continue;
        if (process_watch_id.index == watch_id.index and process_watch_id.generation == watch_id.generation) return index;
    }
    return null;
}

pub fn removeProxyMuxStream(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    stream_id: u64,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findProxyMuxStreamIndex(streams, stream_id) orelse return;
    const stream = streams.swapRemove(index);
    if (stream.proxy_guid_len != 0) proxy_remote.terminate(stream.proxyGuidSlice());
    closeProxyMuxStream(allocator, stream, false, daemon_dispatcher);
}

pub fn sendProxyMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendProxyMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendProxyMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, message);
}

pub fn drainProxyProcessWrites(
    stream: *ProxyMuxStream,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !frame_write_queue.WriteQueueStatus {
    if (!stream.writer_initialized or stream.process_fd < 0) return .drained;
    const status = try stream.process_writer.writeReady(stream.process_fd);
    try updateProxyProcessWatch(stream, daemon_dispatcher);
    return status;
}

fn queueProxyProcessFrame(
    allocator: std.mem.Allocator,
    stream: *ProxyMuxStream,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    _ = allocator;
    if (!stream.writer_initialized) return error.ProxyProcessWriterMissing;
    try stream.process_writer.queueMuxStreamFrame(message);
}

fn proxyProcessWatchEvents(stream: *const ProxyMuxStream) dispatcher.FdEvents {
    return .{
        .readable = true,
        .writable = stream.writer_initialized and stream.process_writer.hasPending(),
    };
}

fn updateProxyProcessWatch(stream: *ProxyMuxStream, daemon_dispatcher: *dispatcher.Dispatcher) !void {
    const watch_id = stream.process_watch_id orelse return;
    try daemon_dispatcher.updateFdEvents(watch_id, proxyProcessWatchEvents(stream));
}

pub fn queueProxyMuxReset(
    allocator: std.mem.Allocator,
    mux_writer: *frame_write_queue.FrameWriteQueue,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try queueProxyMuxFrame(allocator, mux_writer, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn queueProxyMuxFrame(
    allocator: std.mem.Allocator,
    mux_writer: *frame_write_queue.FrameWriteQueue,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    _ = allocator;
    try mux_writer.queueMuxStreamFrame(message);
}
