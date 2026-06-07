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

    te_session_create,
    te_session_attach,
    te_input,
    te_resize,
    te_repaint_request,

    te_session_attached,
    te_session_ended,
    te_draw,
    te_repaint_response,
    te_tty_transcript_chunk,
    te_input_ack,
    te_session_client_control_response,
    te_session_client_debug_sever_connection_request,
    te_session_client_debug_unresponsive_connection_request,
    ping,
    pong,
    proxy_stream_resume,
    proxy_stream_data,
    proxy_stream_ack,
    proxy_stream_eof,
    proxy_stream_eof_ack,
    proxy_control_capabilities,
    proxy_control_diagnostic,
    proxy_control_ctrl_r,
    client_open_proxy_stream,
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
    const payload = try encodePayload(app_allocator.allocator(), pb.Ping{});
    defer app_allocator.allocator().free(payload);
    try sendFrame(fd, .ping, payload);
}

pub fn sendPong(fd: c.fd_t) !void {
    const payload = try encodePayload(app_allocator.allocator(), pb.Pong{});
    defer app_allocator.allocator().free(payload);
    try sendFrame(fd, .pong, payload);
}

pub fn handleTransportControlFrame(message_type: MessageType, payload: []const u8, write_fd: c.fd_t) !bool {
    switch (message_type) {
        .ping => {
            var message = try decodePayload(pb.Ping, app_allocator.allocator(), payload);
            defer message.deinit(app_allocator.allocator());
            try sendPong(write_fd);
            return true;
        },
        .pong => {
            var message = try decodePayload(pb.Pong, app_allocator.allocator(), payload);
            defer message.deinit(app_allocator.allocator());
            return true;
        },
        else => return false,
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
    if (!isHelloFrameEnvelope(envelope)) {
        var frame = try decodePayload(pb.Frame, allocator, envelope);
        defer frame.deinit(allocator);
        const payload = frame.payload orelse return error.UnknownFrame;
        return switch (payload) {
            .@"error" => |message| ownedFrameFromMessage(allocator, .error_message, message),
            .te_session_create => |message| ownedFrameFromMessage(allocator, .te_session_create, message),
            .te_session_attach => |message| ownedFrameFromMessage(allocator, .te_session_attach, message),
            .te_input => |message| ownedFrameFromMessage(allocator, .te_input, message),
            .te_resize => |message| ownedFrameFromMessage(allocator, .te_resize, message),
            .te_repaint_request => |message| ownedFrameFromMessage(allocator, .te_repaint_request, message),
            .te_session_attached => |message| ownedFrameFromMessage(allocator, .te_session_attached, message),
            .te_session_ended => |message| ownedFrameFromMessage(allocator, .te_session_ended, message),
            .te_draw => |message| ownedFrameFromMessage(allocator, .te_draw, message),
            .te_repaint_response => |message| ownedFrameFromMessage(allocator, .te_repaint_response, message),
            .te_tty_transcript_chunk => |message| ownedFrameFromMessage(allocator, .te_tty_transcript_chunk, message),
            .te_input_ack => |message| ownedFrameFromMessage(allocator, .te_input_ack, message),
            .te_session_client_control_response => |message| ownedFrameFromMessage(allocator, .te_session_client_control_response, message),
            .te_session_client_debug_sever_connection_request => |message| ownedFrameFromMessage(allocator, .te_session_client_debug_sever_connection_request, message),
            .te_session_client_debug_unresponsive_connection_request => |message| ownedFrameFromMessage(allocator, .te_session_client_debug_unresponsive_connection_request, message),
            .ping => |message| ownedFrameFromMessage(allocator, .ping, message),
            .pong => |message| ownedFrameFromMessage(allocator, .pong, message),
            .proxy_stream_resume => |message| ownedFrameFromMessage(allocator, .proxy_stream_resume, message),
            .proxy_stream_data => |message| ownedFrameFromMessage(allocator, .proxy_stream_data, message),
            .proxy_stream_ack => |message| ownedFrameFromMessage(allocator, .proxy_stream_ack, message),
            .proxy_stream_eof => |message| ownedFrameFromMessage(allocator, .proxy_stream_eof, message),
            .proxy_stream_eof_ack => |message| ownedFrameFromMessage(allocator, .proxy_stream_eof_ack, message),
            .proxy_control_capabilities => |message| ownedFrameFromMessage(allocator, .proxy_control_capabilities, message),
            .proxy_control_diagnostic => |message| ownedFrameFromMessage(allocator, .proxy_control_diagnostic, message),
            .proxy_control_ctrl_r => |message| ownedFrameFromMessage(allocator, .proxy_control_ctrl_r, message),
            .client_open_proxy_stream => |message| ownedFrameFromMessage(allocator, .client_open_proxy_stream, message),
        };
    }

    var hello_frame = try decodePayload(hpb.HelloFrame, allocator, envelope);
    defer hello_frame.deinit(allocator);
    if (hello_frame.payload) |payload| {
        return switch (payload) {
            .hello_request => |message| ownedFrameFromMessage(allocator, .hello_request, message),
            .hello_ok => |message| ownedFrameFromMessage(allocator, .hello_ok, message),
            .hello_error => |message| ownedFrameFromMessage(allocator, .hello_error, message),
        };
    }
    return error.UnknownFrame;
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
        .te_session_create => blk: {
            var message = try decodePayload(pb.TeSessionCreate, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_create = message } });
        },
        .te_session_attach => blk: {
            var message = try decodePayload(pb.TeSessionAttach, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_attach = message } });
        },
        .te_input => blk: {
            var message = try decodePayload(pb.TeInput, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_input = message } });
        },
        .te_resize => blk: {
            var message = try decodePayload(pb.TeResize, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_resize = message } });
        },
        .te_repaint_request => blk: {
            var message = try decodePayload(pb.TeRepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_repaint_request = message } });
        },
        .te_session_attached => blk: {
            var message = try decodePayload(pb.TeSessionAttached, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_attached = message } });
        },
        .te_session_ended => blk: {
            var message = try decodePayload(pb.TeSessionEnded, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_ended = message } });
        },
        .te_draw => blk: {
            var message = try decodePayload(pb.TeDraw, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_draw = message } });
        },
        .te_repaint_response => blk: {
            var message = try decodePayload(pb.TeRepaintResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_repaint_response = message } });
        },
        .te_tty_transcript_chunk => blk: {
            var message = try decodePayload(pb.TeTtyTranscriptChunk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_tty_transcript_chunk = message } });
        },
        .te_input_ack => blk: {
            var message = try decodePayload(pb.TeInputAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_input_ack = message } });
        },
        .te_session_client_control_response => blk: {
            var message = try decodePayload(pb.TeSessionClientControlResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_client_control_response = message } });
        },
        .te_session_client_debug_sever_connection_request => blk: {
            var message = try decodePayload(pb.TeSessionClientDebugSeverConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_client_debug_sever_connection_request = message } });
        },
        .te_session_client_debug_unresponsive_connection_request => blk: {
            var message = try decodePayload(pb.TeSessionClientDebugUnresponsiveConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_session_client_debug_unresponsive_connection_request = message } });
        },
        .ping => blk: {
            var message = try decodePayload(pb.Ping, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .ping = message } });
        },
        .pong => blk: {
            var message = try decodePayload(pb.Pong, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .pong = message } });
        },
        .proxy_stream_resume => blk: {
            var message = try decodePayload(pb.ProxyStreamResume, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_resume = message } });
        },
        .proxy_stream_data => blk: {
            var message = try decodePayload(pb.ProxyStreamData, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_data = message } });
        },
        .proxy_stream_ack => blk: {
            var message = try decodePayload(pb.ProxyStreamAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_ack = message } });
        },
        .proxy_stream_eof => blk: {
            var message = try decodePayload(pb.ProxyStreamEof, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_eof = message } });
        },
        .proxy_stream_eof_ack => blk: {
            var message = try decodePayload(pb.ProxyStreamEofAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_eof_ack = message } });
        },
        .proxy_control_capabilities => blk: {
            var message = try decodePayload(pb.ProxyControlCapabilities, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_control_capabilities = message } });
        },
        .proxy_control_diagnostic => blk: {
            var message = try decodePayload(pb.ProxyControlDiagnostic, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_control_diagnostic = message } });
        },
        .proxy_control_ctrl_r => blk: {
            var message = try decodePayload(pb.ProxyControlCtrlR, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_control_ctrl_r = message } });
        },
        .client_open_proxy_stream => blk: {
            var message = try decodePayload(pb.ClientOpenProxyStream, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .client_open_proxy_stream = message } });
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
    const original = pb.TeDraw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 4,
        .draw_bytes = "sessh",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.TeDraw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("opaque-cursor", decoded.scrollback_cursor);
    try std.testing.expectEqual(@as(?i32, 4), decoded.viewport_offset);
    try std.testing.expectEqualStrings("sessh", decoded.draw_bytes);
}

test "frame envelope round trip" {
    const payload = try encodePayload(std.testing.allocator, pb.TeInputAck{ .input_seq = 42 });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .te_input_ack, payload);
    defer std.testing.allocator.free(frame_bytes);

    const envelope = frame_bytes[frame_header_len..];
    var frame = try decodeEnvelopeAlloc(std.testing.allocator, envelope);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.te_input_ack, frame.message_type);

    var decoded = try decodePayload(pb.TeInputAck, std.testing.allocator, frame.payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), decoded.input_seq);
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
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.6.0-dev",
    }, 3, 0));
}

test "session ended exit status is optional" {
    const payload = try encodePayload(std.testing.allocator, pb.TeSessionEnded{
        .reason = .TE_SESSION_END_REASON_KILLED_BY_REQUEST,
        .ended_at_unix_ms = 42,
    });
    defer std.testing.allocator.free(payload);

    var decoded = try decodePayload(pb.TeSessionEnded, std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.TeSessionEndReason.TE_SESSION_END_REASON_KILLED_BY_REQUEST, decoded.reason);
    try std.testing.expectEqual(@as(?pb.ExitStatus, null), decoded.exit_status);
    try std.testing.expectEqual(@as(?u64, 42), decoded.ended_at_unix_ms);
}
