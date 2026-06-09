const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;

const io = @import("../core/io.zig");
pub const pb = @import("../proto/sessh/protocol/v1.pb.zig");
pub const hpb = @import("../proto/sessh/handshake/v1.pb.zig");

pub const MessageType = enum {
    hello_request,
    hello_ok,
    hello_error,
    error_message,
    client_daemon,
    client_remote,
    daemon_tunnel,
};

pub const frame_header_len = 4;

pub const OwnedFrame = struct {
    message_type: MessageType,
    payload: []u8,

    pub fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn encodePayload(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try message.encode(&writer.writer, allocator);
    return writer.toOwnedSlice();
}

pub fn decodePayload(comptime T: type, allocator: std.mem.Allocator, payload: []const u8) !T {
    var reader: std.Io.Reader = .fixed(payload);
    return T.decode(&reader, allocator);
}

pub fn helloRequestIsCompatible(
    hello: hpb.HelloRequest,
    min_major: u32,
    min_minor: u32,
) bool {
    return hello.protocol_major > min_major or
        (hello.protocol_major == min_major and hello.protocol_minor >= min_minor);
}

pub fn readFrameAlloc(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedFrame {
    const envelope = try readEnvelopeAlloc(allocator, fd);
    defer allocator.free(envelope);
    return decodeEnvelopeAlloc(allocator, envelope);
}

pub fn sendFrame(fd: c.fd_t, message_type: MessageType, payload: []const u8) !void {
    const frame = try encodeFrame(app_allocator.allocator(), message_type, payload);
    defer app_allocator.allocator().free(frame);
    try io.writeAll(fd, frame);
}

pub fn sendPing(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .ping = .{} });
}

pub fn sendPong(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .pong = .{} });
}

pub fn handleTransportControlFrame(message_type: MessageType, payload: []const u8, write_fd: c.fd_t) !bool {
    if (message_type != .daemon_tunnel) return false;

    var item = try decodePayload(pb.DaemonTunnelItem, app_allocator.allocator(), payload);
    defer item.deinit(app_allocator.allocator());

    switch (item.payload orelse return false) {
        .ping => try sendPong(write_fd),
        .pong => {},
        else => return false,
    }
    return true;
}

pub fn sendClientDaemonPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ClientDaemonItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.ClientDaemonItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .client_daemon, encoded);
}

pub fn sendDaemonTunnelPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.DaemonTunnelItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.DaemonTunnelItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .daemon_tunnel, encoded);
}

pub fn sendClientRemotePayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ClientRemoteItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.ClientRemoteItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .client_remote, encoded);
}

pub fn sendMuxStreamFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try sendDaemonTunnelPayloadFrame(allocator, fd, .{ .mux_stream = message });
}

pub fn sendTeStreamItemFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendClientRemotePayloadFrame(allocator, fd, .{ .terminal_emulator = item });
}

pub fn sendTeStreamPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.TerminalEmulatorItem.payload_union,
) !void {
    try sendTeStreamItemFrame(allocator, fd, .{ .payload = payload });
}

pub fn sendProxyStreamPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ProxyStreamItem.payload_union,
) !void {
    try sendClientRemotePayloadFrame(allocator, fd, .{ .proxy = .{ .payload = payload } });
}

pub fn sendSshTransportOpenFrame(allocator: std.mem.Allocator, fd: c.fd_t, request: pb.ClientDaemonItem.SshTransportOpen) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .ssh_transport_open = request });
}

pub fn sendSshTransportEventFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ClientDaemonItem.SshTransportEvent.event_union,
) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .ssh_transport_event = .{ .event = payload } });
}

pub fn sendSshTransportStderrFrame(allocator: std.mem.Allocator, fd: c.fd_t, chunk: []const u8) !void {
    try sendSshTransportEventFrame(allocator, fd, .{ .stderr_chunk = .{ .chunk = chunk } });
}

pub fn sendSshTransportClosedFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendSshTransportEventFrame(allocator, fd, .{ .closed = .{} });
}

pub fn sendSshTransportBootstrapStartedFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendSshTransportEventFrame(allocator, fd, .{ .bootstrap_started = .{} });
}

pub fn sendSshTransportBootstrapFinishedFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendSshTransportEventFrame(allocator, fd, .{ .bootstrap_finished = .{} });
}

pub fn sendDaemonLogRequestFrame(allocator: std.mem.Allocator, fd: c.fd_t, request: pb.ClientDaemonItem.DaemonLogRequest) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .log_request = request });
}

pub fn sendDaemonLogEntryFrame(allocator: std.mem.Allocator, fd: c.fd_t, entry: pb.ClientDaemonItem.DaemonLogEntry) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .log_entry = entry });
}

pub fn decodeClientRemoteTerminalEmulatorItem(allocator: std.mem.Allocator, payload: []const u8) !pb.TerminalEmulatorItem {
    var item = try decodePayload(pb.ClientRemoteItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .terminal_emulator => |terminal_emulator| {
            item.payload = null;
            return terminal_emulator;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientRemoteProxyStreamItem(allocator: std.mem.Allocator, payload: []const u8) !pb.ProxyStreamItem {
    var item = try decodePayload(pb.ClientRemoteItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .proxy => |proxy| {
            item.payload = null;
            return proxy;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeDaemonMuxStreamFrame(allocator: std.mem.Allocator, payload: []const u8) !pb.DaemonTunnelItem.MuxStreamFrame {
    var item = try decodePayload(pb.DaemonTunnelItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .mux_stream => |mux| {
            item.payload = null;
            return mux;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientDaemonSshTransportOpen(allocator: std.mem.Allocator, payload: []const u8) !pb.ClientDaemonItem.SshTransportOpen {
    var item = try decodePayload(pb.ClientDaemonItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .ssh_transport_open => |open| {
            item.payload = null;
            return open;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientDaemonSshTransportEvent(allocator: std.mem.Allocator, payload: []const u8) !pb.ClientDaemonItem.SshTransportEvent {
    var item = try decodePayload(pb.ClientDaemonItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .ssh_transport_event => |event| {
            item.payload = null;
            return event;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientDaemonLogEntry(allocator: std.mem.Allocator, payload: []const u8) !pb.ClientDaemonItem.DaemonLogEntry {
    var item = try decodePayload(pb.ClientDaemonItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .log_entry => |entry| {
            item.payload = null;
            return entry;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn encodeFrame(allocator: std.mem.Allocator, message_type: MessageType, payload: []const u8) ![]u8 {
    const envelope = try encodeEnvelopePayload(allocator, message_type, payload);
    defer allocator.free(envelope);
    if (envelope.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    const frame = try allocator.alloc(u8, frame_header_len + envelope.len);
    writeU32(frame[0..frame_header_len], @intCast(envelope.len));
    @memcpy(frame[frame_header_len..], envelope);
    return frame;
}

pub fn payloadLenFromHeader(header: *const [frame_header_len]u8) usize {
    return @intCast(readU32(header));
}

fn readEnvelopeAlloc(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var length_bytes: [frame_header_len]u8 = undefined;
    try io.readExact(fd, &length_bytes);

    const payload_len: usize = @intCast(readU32(&length_bytes));
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try io.readExact(fd, payload);
    return payload;
}

fn decodeEnvelopeAlloc(allocator: std.mem.Allocator, envelope: []const u8) !OwnedFrame {
    if (envelope.len == 0) return error.UnknownFrame;
    if (isHelloFrameEnvelope(envelope)) return decodeHelloEnvelopeAlloc(allocator, envelope);

    var frame = try decodePayload(pb.Frame, allocator, envelope);
    defer frame.deinit(allocator);

    return switch (frame.payload orelse return error.UnknownFrame) {
        .@"error" => |message| ownedFrameFromMessage(allocator, .error_message, message),
        .client_daemon => |message| ownedFrameFromMessage(allocator, .client_daemon, message),
        .client_remote => |message| ownedFrameFromMessage(allocator, .client_remote, message),
        .daemon_tunnel => |message| ownedFrameFromMessage(allocator, .daemon_tunnel, message),
    };
}

fn decodeHelloEnvelopeAlloc(allocator: std.mem.Allocator, envelope: []const u8) !OwnedFrame {
    var hello_frame = try decodePayload(hpb.HelloFrame, allocator, envelope);
    defer hello_frame.deinit(allocator);

    return switch (hello_frame.payload orelse return error.UnknownFrame) {
        .hello_request => |message| ownedFrameFromMessage(allocator, .hello_request, message),
        .hello_ok => |message| ownedFrameFromMessage(allocator, .hello_ok, message),
        .hello_error => |message| ownedFrameFromMessage(allocator, .hello_error, message),
    };
}

fn isHelloFrameEnvelope(envelope: []const u8) bool {
    return envelope[0] == 0x0a or envelope[0] == 0x12 or envelope[0] == 0x1a;
}

fn ownedFrameFromMessage(allocator: std.mem.Allocator, message_type: MessageType, message: anytype) !OwnedFrame {
    return .{
        .message_type = message_type,
        .payload = try encodePayload(allocator, message),
    };
}

fn encodeEnvelopePayload(allocator: std.mem.Allocator, message_type: MessageType, payload: []const u8) ![]u8 {
    return switch (message_type) {
        .hello_request => blk: {
            var message = try decodePayload(hpb.HelloRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_request = message } });
        },
        .hello_ok => blk: {
            var message = try decodePayload(hpb.HelloOk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_ok = message } });
        },
        .hello_error => blk: {
            var message = try decodePayload(hpb.HelloError, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_error = message } });
        },
        .error_message => blk: {
            var message = try decodePayload(hpb.Error, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .@"error" = message } });
        },
        .client_daemon => blk: {
            var message = try decodePayload(pb.ClientDaemonItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .client_daemon = message } });
        },
        .client_remote => blk: {
            var message = try decodePayload(pb.ClientRemoteItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .client_remote = message } });
        },
        .daemon_tunnel => blk: {
            var message = try decodePayload(pb.DaemonTunnelItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .daemon_tunnel = message } });
        },
    };
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writeU32(bytes: []u8, value: u32) void {
    bytes[0] = @intCast((value >> 24) & 0xff);
    bytes[1] = @intCast((value >> 16) & 0xff);
    bytes[2] = @intCast((value >> 8) & 0xff);
    bytes[3] = @intCast(value & 0xff);
}

test "generated protobuf payload round trip" {
    const original = pb.TerminalEmulatorItem.Draw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 4,
        .draw_bytes = "sessh",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.TerminalEmulatorItem.Draw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("opaque-cursor", decoded.scrollback_cursor);
    try std.testing.expectEqual(@as(?i32, 4), decoded.viewport_offset);
    try std.testing.expectEqualStrings("sessh", decoded.draw_bytes);
}

test "frame envelope round trip" {
    const payload = try encodePayload(std.testing.allocator, pb.ClientRemoteItem{
        .payload = .{ .terminal_emulator = .{ .payload = .{ .input_ack = .{ .input_seq = 42 } } } },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .client_remote, payload);
    defer std.testing.allocator.free(frame_bytes);

    var frame = try decodeEnvelopeAlloc(std.testing.allocator, frame_bytes[frame_header_len..]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.client_remote, frame.message_type);

    var item = try decodeClientRemoteTerminalEmulatorItem(std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    const item_payload = item.payload orelse return error.MissingTePayload;
    switch (item_payload) {
        .input_ack => |ack| try std.testing.expectEqual(@as(u64, 42), ack.input_seq),
        else => return error.UnexpectedTePayload,
    }
}

test "mux stream frame preserves stream id offset and proxy payload" {
    const payload = try encodePayload(std.testing.allocator, pb.DaemonTunnelItem{
        .payload = .{ .mux_stream = .{
            .stream_id = 7,
            .message = .{ .payload = .{
                .offset = 42,
                .item = .{ .proxy = .{ .payload = .{ .data = "hello" } } },
            } },
        } },
    });
    defer std.testing.allocator.free(payload);

    const frame_bytes = try encodeFrame(std.testing.allocator, .daemon_tunnel, payload);
    defer std.testing.allocator.free(frame_bytes);

    var frame = try decodeEnvelopeAlloc(std.testing.allocator, frame_bytes[frame_header_len..]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.daemon_tunnel, frame.message_type);

    var decoded = try decodeDaemonMuxStreamFrame(std.testing.allocator, frame.payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), decoded.stream_id);

    const message = decoded.message orelse return error.MissingMuxMessage;
    switch (message) {
        .payload => |mux_payload| {
            try std.testing.expectEqual(@as(u64, 42), mux_payload.offset);
            const item = mux_payload.item orelse return error.MissingMuxPayloadItem;
            switch (item) {
                .proxy => |proxy_item| {
                    const proxy_payload = proxy_item.payload orelse return error.MissingProxyPayload;
                    switch (proxy_payload) {
                        .data => |data| try std.testing.expectEqualStrings("hello", data),
                        else => return error.UnexpectedProxyPayload,
                    }
                },
                else => return error.UnexpectedMuxPayloadItem,
            }
        },
        else => return error.UnexpectedMuxMessage,
    }
}

test "hello compatibility accepts peer max protocol when it satisfies local minimum" {
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 9,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 4,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 4,
        .protocol_minor = 0,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.6.0-dev",
    }, 3, 0));
}

test "session ended exit status is optional" {
    const payload = try encodePayload(std.testing.allocator, pb.TerminalEmulatorItem.SessionEnded{
        .reason = .REASON_KILLED_BY_REQUEST,
        .ended_at_unix_ms = 42,
    });
    defer std.testing.allocator.free(payload);

    var decoded = try decodePayload(pb.TerminalEmulatorItem.SessionEnded, std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.TerminalEmulatorItem.SessionEnded.Reason.REASON_KILLED_BY_REQUEST, decoded.reason);
    try std.testing.expectEqual(@as(?pb.TerminalEmulatorItem.SessionEnded.ExitStatus, null), decoded.exit_status);
    try std.testing.expectEqual(@as(?u64, 42), decoded.ended_at_unix_ms);
}
