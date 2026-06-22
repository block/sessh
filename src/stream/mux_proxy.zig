// Daemon-side proxy-stream mux handling. It connects logical proxy streams from
// the daemon tunnel to a remote proxy worker and records cleanup identity before
// acknowledging the stream as usable.
const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const worker_endpoint = @import("../daemon/worker_endpoint.zig");
const dispatcher = @import("../core/dispatcher.zig");
const guid_ref = @import("../core/guid.zig");
const protocol = @import("../protocol/mod.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const one_shot_frame_writer = @import("../transport/one_shot_frame_writer.zig");
const proxy_remote = @import("proxy_remote.zig");

const pb = protocol.pb;
const proxy_mux_stream_id: u64 = 1;

pub const ProxyMuxStream = struct {
    stream_id: u64,
    endpoint: worker_endpoint.Endpoint = .{},
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
    proxy_guid: guid_ref.FixedProxyGuid = .{},
    cleanup_recorded: bool = false,
};

// Proxy mux streams bridge one daemon-tunnel stream to one proxy worker process.
// The worker speaks its own local stream id, so this state is where tunnel ids,
// worker endpoint state, and cleanup identity meet.
pub const ProxyMuxContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_writer: *dispatch_io.FrameSink,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
};

pub fn closeProxyMuxStreams(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    // Closing a mux connection owns all proxy streams on it. If a stream never
    // recorded cleanup identity, notify its worker that startup failed before
    // dropping the endpoint.
    for (streams.items) |stream| {
        if (daemon_dispatcher) |d| {
            closeProxyMuxStream(.{
                .allocator = allocator,
                .stream = stream,
                .send_startup_failed = true,
                .daemon_dispatcher = d,
            });
        } else {
            var moved_stream = stream;
            moved_stream.endpoint.close(null);
        }
    }
    streams.deinit(allocator);
}

pub const CloseProxyMuxStreamOptions = struct {
    allocator: std.mem.Allocator,
    stream: ProxyMuxStream,
    daemon_dispatcher: *dispatcher.Dispatcher,
    send_startup_failed: bool,
};

pub fn closeProxyMuxStream(options: CloseProxyMuxStreamOptions) void {
    var moved_stream = options.stream;
    if (moved_stream.endpoint.fd >= 0 and options.send_startup_failed and !moved_stream.cleanup_recorded) {
        sendProxyStartupFailedAndClose(options.allocator, &moved_stream, options.daemon_dispatcher) catch {
            moved_stream.endpoint.close(options.daemon_dispatcher);
        };
        return;
    }
    moved_stream.endpoint.close(options.daemon_dispatcher);
}

pub fn handleProxyMuxStreamFrame(
    ctx: ProxyMuxContext,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(ctx.allocator);
    const message = owned_mux_frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| try handleProxyMuxOpen(ctx, owned_mux_frame.stream_id, open),
        .payload => try handleProxyMuxPayload(ctx, owned_mux_frame),
        .open_ok, .ack, .eof => try forwardProxyMuxFrameToProxyRemote(ctx.streams, owned_mux_frame),
        .reset => {
            forwardProxyMuxFrameToProxyRemote(ctx.streams, owned_mux_frame) catch {};
            try removeProxyMuxStream(ctx, owned_mux_frame.stream_id);
        },
    }
}

pub fn handleProxyMuxOpen(
    ctx: ProxyMuxContext,
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
) !void {
    // Mux open may arrive before the proxy payload that identifies the worker.
    // Store it until payload open connects the worker, then forward it to the
    // worker-local fixed stream id.
    const streams = ctx.streams;
    if (findProxyMuxStreamIndex(streams, stream_id)) |index| {
        streams.items[index].open = open;
        if (streams.items[index].endpoint.active()) {
            try queueProxyProcessFrame(
                &streams.items[index],
                protocol.muxStreamOpenMessageFrame(proxy_mux_stream_id, open),
            );
        }
        return;
    }
    try streams.append(ctx.allocator, .{
        .stream_id = stream_id,
        .open = open,
    });
}

// Decode the proxy-specific payload inside a daemon mux frame. The first proxy
// open starts/connects the remote worker; later data frames are remapped onto the
// worker's fixed internal stream id.
fn handleProxyMuxPayload(
    ctx: ProxyMuxContext,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const stream_id = mux_frame.stream_id;
    const payload = switch (mux_frame.message orelse return error.StreamUnexpectedFrame) {
        .payload => |value| value,
        else => return error.StreamUnexpectedFrame,
    };
    const item = payload.item orelse return error.StreamUnexpectedFrame;
    const proxy_item = switch (item) {
        .proxy => |proxy| proxy,
        else => return error.StreamUnexpectedFrame,
    };
    const proxy_payload = proxy_item.payload orelse return error.StreamUnexpectedFrame;
    switch (proxy_payload) {
        .open => |request| try handleProxyMuxPayloadOpen(ctx, stream_id, request),
        .data => {
            try forwardProxyMuxFrameToProxyRemote(ctx.streams, mux_frame);
        },
    }
}

fn handleProxyMuxPayloadOpen(
    ctx: ProxyMuxContext,
    stream_id: u64,
    request: pb.ProxyStreamItem.Open,
) !void {
    // A proxy open binds a mux stream to a remote proxy worker. After this
    // point daemon-tunnel stream ids and worker-local stream ids differ. The
    // daemon records the worker identity for cleanup and remaps later frames
    // through the recorded endpoint.
    const index = findProxyMuxStreamIndex(ctx.streams, stream_id) orelse return error.StreamUnexpectedFrame;
    if (ctx.streams.items[index].endpoint.active()) return;
    if (!guid_ref.isValidProxyGuid(request.proxy_guid)) return error.InvalidStreamGuid;
    if (request.proxy_port == 0 or request.proxy_port > std.math.maxInt(u16)) return error.InvalidStreamArgs;

    const remote_process = try proxy_remote.connectOrStart(.{
        .allocator = ctx.allocator,
        .exe = ctx.exe,
        .guid = request.proxy_guid,
        .proxy_host = request.proxy_host,
        .proxy_port = @intCast(request.proxy_port),
    });
    var process_fd = core_fds.OwnedFd.init(try proxy_remote.connectStarted(remote_process));
    defer process_fd.deinit();
    if (ctx.daemon_dispatcher != null) {
        try core_fds.setNonBlocking(process_fd.get());
    }

    ctx.streams.items[index].endpoint.fd = process_fd.take();
    if (ctx.daemon_dispatcher) |d| {
        try ctx.streams.items[index].endpoint.initIo(d, ctx.allocator);
    }
    try queueProxyProcessFrame(
        &ctx.streams.items[index],
        protocol.muxStreamOpenMessageFrame(proxy_mux_stream_id, ctx.streams.items[index].open),
    );
    const canonical = try guid_ref.canonicalProxyGuid(ctx.allocator, request.proxy_guid);
    defer ctx.allocator.free(canonical);
    try ctx.streams.items[index].proxy_guid.set(canonical);
    try ctx.mux_writer.writeDaemonTunnelPayload(.{ .remote_process_started = .{
        .stream_id = stream_id,
        .process = daemon_cleanup.makeRemoteProcessIdentity(ctx.identity, canonical),
    } });
    if (ctx.daemon_dispatcher) |d| {
        _ = try drainProxyProcessWrites(&ctx.streams.items[index], d);
    }
}

fn forwardProxyMuxFrameToProxyRemote(
    streams: *std.ArrayList(ProxyMuxStream),
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const index = findProxyMuxStreamIndex(streams, mux_frame.stream_id) orelse return error.StreamUnexpectedFrame;
    if (!streams.items[index].endpoint.active()) return error.StreamUnexpectedFrame;
    var remapped = mux_frame;
    remapped.stream_id = proxy_mux_stream_id;
    try queueProxyProcessFrame(&streams.items[index], remapped);
}

pub const ForwardProxyRemoteFrameToMuxOptions = struct {
    allocator: std.mem.Allocator,
    mux_writer: *dispatch_io.FrameSink,
    stream: *ProxyMuxStream,
    frame: *protocol.OwnedFrame,
};

pub fn forwardProxyRemoteFrameToMux(options: ForwardProxyRemoteFrameToMuxOptions) !bool {
    const allocator = options.allocator;
    const mux_writer = options.mux_writer;
    const stream = options.stream;
    const frame = options.frame;
    if (frame.message_type != .daemon_tunnel) return error.StreamUnexpectedFrame;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    mux_frame.stream_id = stream.stream_id;
    try queueProxyMuxFrame(mux_writer, mux_frame);
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
            try stream.endpoint.writeDaemonTunnelPayload(.{ .pong = .{} });
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

pub fn findProxyMuxStreamIndexBySource(streams: *const std.ArrayList(ProxyMuxStream), source: dispatcher.Source) ?usize {
    for (streams.items, 0..) |stream, index| {
        if (!stream.endpoint.source.isInitialized()) continue;
        if (stream.endpoint.source.eql(source)) return index;
    }
    return null;
}

fn removeProxyMuxStream(
    ctx: ProxyMuxContext,
    stream_id: u64,
) !void {
    const index = findProxyMuxStreamIndex(ctx.streams, stream_id) orelse return;
    const stream = ctx.streams.swapRemove(index);
    if (stream.proxy_guid.isSet()) proxy_remote.terminate(stream.proxy_guid.slice());
    if (ctx.daemon_dispatcher) |d| {
        closeProxyMuxStream(.{
            .allocator = ctx.allocator,
            .stream = stream,
            .send_startup_failed = false,
            .daemon_dispatcher = d,
        });
    } else {
        var moved_stream = stream;
        moved_stream.endpoint.close(null);
    }
}

fn sendProxyStartupFailedAndClose(
    allocator: std.mem.Allocator,
    stream: *ProxyMuxStream,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    // If cleanup identity was never acknowledged, fail the worker explicitly so
    // it does not assume the remote proxy process was durably recorded.
    const payload = try protocol.encodeMuxStreamFramePayload(allocator, protocol.muxStreamResetFrame(
        proxy_mux_stream_id,
        "STARTUP_FAILED",
        "proxy cleanup record was not acknowledged",
    ));
    defer allocator.free(payload);
    const fd = stream.endpoint.takeFd(daemon_dispatcher);
    if (fd < 0) return;
    try one_shot_frame_writer.registerFrameAndClose(.{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .fd = fd,
        .message_type = .daemon_tunnel,
        .payload = payload,
    });
}

pub fn drainProxyProcessWrites(
    stream: *ProxyMuxStream,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !dispatch_io.SinkWriteStatus {
    return stream.endpoint.drainWrites(daemon_dispatcher);
}

fn queueProxyProcessFrame(
    stream: *ProxyMuxStream,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    stream.endpoint.writeMuxStreamFrame(message) catch |err| switch (err) {
        error.WorkerEndpointWriterMissing => return error.ProxyProcessWriterMissing,
        else => return err,
    };
}

fn queueProxyMuxFrame(
    mux_writer: *dispatch_io.FrameSink,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try mux_writer.writeMuxStreamFrame(message);
}
