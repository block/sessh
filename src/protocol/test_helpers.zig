// Protocol fixtures used by Zig unit tests. These helpers produce real framed
// sessh messages so tests exercise the same encoding and fd behavior as the
// daemon, without depending on a running ssh transport.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const core_blocking = @import("../core/blocking.zig");
const fd_passing = @import("../core/fd_passing.zig");
const frame = @import("frame.zig");
const typed_send = @import("typed_send.zig");

pub const MuxStreamResetFrameOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
};

pub fn setNonBlockingFdForTest(fd: c.fd_t) !void {
    try core_fds.setNonBlocking(fd);
}

pub fn closePipeForTest(pipe: [2]c.fd_t) void {
    _ = c.close(pipe[0]);
    _ = c.close(pipe[1]);
}

pub fn socketPairForTest() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

pub fn drainPipeForTest(allocator: std.mem.Allocator, fd: c.fd_t, actual: *std.ArrayList(u8)) !void {
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return;
        try actual.appendSlice(allocator, buffer[0..@intCast(n)]);
    }
}

pub fn readAvailableForTest(allocator: std.mem.Allocator, fd: c.fd_t, out: *std.ArrayList(u8)) !void {
    var buf: [128]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return;
        try out.appendSlice(allocator, buf[0..n]);
    }
}

pub fn rawFrameForTest(allocator: std.mem.Allocator, frame_header_len: usize, payload: []const u8) ![]u8 {
    const frame_bytes = try allocator.alloc(u8, frame_header_len + payload.len);
    const len: u32 = @intCast(payload.len);
    frame_bytes[0] = @intCast((len >> 24) & 0xff);
    frame_bytes[1] = @intCast((len >> 16) & 0xff);
    frame_bytes[2] = @intCast((len >> 8) & 0xff);
    frame_bytes[3] = @intCast(len & 0xff);
    @memcpy(frame_bytes[frame_header_len..], payload);
    return frame_bytes;
}

pub fn sendFrameBlocking(fd: c.fd_t, message_type: frame.MessageType, payload: []const u8) !void {
    const frame_bytes = try frame.encodeFrame(std.testing.allocator, message_type, payload);
    defer std.testing.allocator.free(frame_bytes);
    try core_blocking.fromTest().writeAll(fd, frame_bytes);
}

pub fn sendFrameWithAttachedKindAndBytesBlocking(
    fd: c.fd_t,
    options: frame.AttachedFrameOptions,
) !void {
    const frame_bytes = try frame.encodeFrameWithAttachedKindAndBytes(std.testing.allocator, options);
    defer std.testing.allocator.free(frame_bytes);
    try core_blocking.fromTest().writeAll(fd, frame_bytes);
}

pub fn sendClientDaemonPayloadFrameBlocking(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: typed_send.ClientDaemonPayload,
) !void {
    const encoded = try typed_send.encodeClientDaemonPayload(allocator, payload);
    defer allocator.free(encoded);
    try sendFrameBlocking(fd, .client_daemon, encoded);
}

pub fn sendDaemonTunnelPayloadFrameBlocking(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: typed_send.DaemonTunnelPayload,
) !void {
    const encoded = try typed_send.encodeDaemonTunnelPayload(allocator, payload);
    defer allocator.free(encoded);
    try sendFrameBlocking(fd, .daemon_tunnel, encoded);
}

pub fn sendMuxStreamFrameBlocking(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message: frame.pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try sendDaemonTunnelPayloadFrameBlocking(allocator, fd, .{ .mux_stream = message });
}

pub fn sendMuxStreamResetFrameBlocking(options: MuxStreamResetFrameOptions) !void {
    try sendMuxStreamFrameBlocking(options.allocator, options.fd, typed_send.muxStreamResetFrame(options.stream_id, options.code, options.message));
}

pub fn sendTerminalEmulatorItemFrameBlocking(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    item: frame.pb.TerminalEmulatorItem,
) !void {
    const encoded = try typed_send.encodeTerminalEmulatorItemPayload(allocator, item);
    defer allocator.free(encoded);
    try sendFrameBlocking(fd, .client_remote, encoded);
}

pub fn sendTerminalEmulatorPayloadFrameBlocking(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: typed_send.TerminalEmulatorPayload,
) !void {
    try sendTerminalEmulatorItemFrameBlocking(allocator, fd, .{ .payload = payload });
}

pub fn readFrameForTest(allocator: std.mem.Allocator, fd: c.fd_t) !frame.OwnedFrame {
    const blocking = core_blocking.fromTest();
    var header: [frame.frame_header_len]u8 = undefined;
    try blocking.readExact(fd, &header);

    const message_len = frame.messageLenFromHeader(&header);
    if (message_len == 0) return error.UnknownFrame;
    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    try blocking.readExact(fd, message);

    var decoded = try frame.decodeMessageEnvelopeAlloc(allocator, message);
    errdefer decoded.frame.deinit(allocator);
    if (decoded.attached_bytes_len == 0) return decoded.frame;

    switch (decoded.attached_kind) {
        .RAW => {
            decoded.frame.attached_bytes = try allocator.alloc(u8, decoded.attached_bytes_len);
            try blocking.readExact(fd, decoded.frame.attached_bytes);
            return decoded.frame;
        },
        .SCM_RIGHTS => {
            if (decoded.attached_bytes_len != 1) return error.InvalidFileDescriptorCarrierFrame;
            decoded.frame.fd = try recvScmRightsForTest(fd);
            return decoded.frame;
        },
        _ => return error.InvalidFrame,
    }
}

fn recvScmRightsForTest(fd: c.fd_t) !c.fd_t {
    var marker: [1]u8 = undefined;
    var progress = fd_passing.RecvBufferWithFdProgress.init(&marker, null);
    defer progress.deinit();

    while (true) {
        switch (try fd_passing.recvBufferWithFdProgress(fd, &progress)) {
            .blocked => try waitReadableForTest(fd),
            .progress => continue,
            .complete => return progress.takeFd() orelse error.MissingFileDescriptor,
            .eof => return error.TruncatedFrame,
        }
    }
}

fn waitReadableForTest(fd: c.fd_t) !void {
    var pollfds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const ready = try posix.poll(&pollfds, -1);
        if (ready == 0) continue;
        const revents = pollfds[0].revents;
        if ((revents & posix.POLL.IN) != 0) return;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) return error.EndOfStream;
    }
}
