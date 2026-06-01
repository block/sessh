const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;

const io = @import("io.zig");
pub const pb = @import("proto/sessh/protocol/v1.pb.zig");
pub const hpb = @import("proto/sessh/handshake/v1.pb.zig");

pub const MessageType = enum {
    hello_request,
    hello_ok,
    hello_error,
    error_message,

    session_create,
    session_attach,
    input,
    resize,
    repaint_request,

    session_created,
    session_attached,
    session_ended,
    draw,
    repaint_response,
    tty_transcript_chunk,
    input_ack,
    session_live_state_query,
    session_live_state,
    session_client_control_response,
    client_repaint_request,
    client_detach_request,
    session_client_detach_request,
    session_client_repaint_request,
    session_client_debug_sever_connection_request,
    session_client_debug_unresponsive_connection_request,
    stream_resume,
    stream_data,
    stream_ack,
    stream_eof,
    stream_eof_ack,
    stream_ping,
    stream_pong,
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
            .session_create => |message| ownedFrameFromMessage(allocator, .session_create, message),
            .session_attach => |message| ownedFrameFromMessage(allocator, .session_attach, message),
            .input => |message| ownedFrameFromMessage(allocator, .input, message),
            .resize => |message| ownedFrameFromMessage(allocator, .resize, message),
            .repaint_request => |message| ownedFrameFromMessage(allocator, .repaint_request, message),
            .session_created => |message| ownedFrameFromMessage(allocator, .session_created, message),
            .session_attached => |message| ownedFrameFromMessage(allocator, .session_attached, message),
            .session_ended => |message| ownedFrameFromMessage(allocator, .session_ended, message),
            .draw => |message| ownedFrameFromMessage(allocator, .draw, message),
            .repaint_response => |message| ownedFrameFromMessage(allocator, .repaint_response, message),
            .tty_transcript_chunk => |message| ownedFrameFromMessage(allocator, .tty_transcript_chunk, message),
            .input_ack => |message| ownedFrameFromMessage(allocator, .input_ack, message),
            .session_live_state_query => |message| ownedFrameFromMessage(allocator, .session_live_state_query, message),
            .session_live_state => |message| ownedFrameFromMessage(allocator, .session_live_state, message),
            .session_client_control_response => |message| ownedFrameFromMessage(allocator, .session_client_control_response, message),
            .client_repaint_request => |message| ownedFrameFromMessage(allocator, .client_repaint_request, message),
            .client_detach_request => |message| ownedFrameFromMessage(allocator, .client_detach_request, message),
            .session_client_detach_request => |message| ownedFrameFromMessage(allocator, .session_client_detach_request, message),
            .session_client_repaint_request => |message| ownedFrameFromMessage(allocator, .session_client_repaint_request, message),
            .session_client_debug_sever_connection_request => |message| ownedFrameFromMessage(allocator, .session_client_debug_sever_connection_request, message),
            .session_client_debug_unresponsive_connection_request => |message| ownedFrameFromMessage(allocator, .session_client_debug_unresponsive_connection_request, message),
            .stream_resume => |message| ownedFrameFromMessage(allocator, .stream_resume, message),
            .stream_data => |message| ownedFrameFromMessage(allocator, .stream_data, message),
            .stream_ack => |message| ownedFrameFromMessage(allocator, .stream_ack, message),
            .stream_eof => |message| ownedFrameFromMessage(allocator, .stream_eof, message),
            .stream_eof_ack => |message| ownedFrameFromMessage(allocator, .stream_eof_ack, message),
            .stream_ping => |message| ownedFrameFromMessage(allocator, .stream_ping, message),
            .stream_pong => |message| ownedFrameFromMessage(allocator, .stream_pong, message),
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
        .session_create => blk: {
            var message = try decodePayload(pb.SessionCreate, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_create = message } });
        },
        .session_attach => blk: {
            var message = try decodePayload(pb.SessionAttach, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_attach = message } });
        },
        .input => blk: {
            var message = try decodePayload(pb.Input, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .input = message } });
        },
        .resize => blk: {
            var message = try decodePayload(pb.Resize, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .resize = message } });
        },
        .repaint_request => blk: {
            var message = try decodePayload(pb.RepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .repaint_request = message } });
        },
        .session_created => blk: {
            var message = try decodePayload(pb.SessionCreated, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_created = message } });
        },
        .session_attached => blk: {
            var message = try decodePayload(pb.SessionAttached, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_attached = message } });
        },
        .session_ended => blk: {
            var message = try decodePayload(pb.SessionEnded, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_ended = message } });
        },
        .draw => blk: {
            var message = try decodePayload(pb.Draw, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .draw = message } });
        },
        .repaint_response => blk: {
            var message = try decodePayload(pb.RepaintResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .repaint_response = message } });
        },
        .tty_transcript_chunk => blk: {
            var message = try decodePayload(pb.TtyTranscriptChunk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .tty_transcript_chunk = message } });
        },
        .input_ack => blk: {
            var message = try decodePayload(pb.InputAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .input_ack = message } });
        },
        .session_live_state_query => blk: {
            var message = try decodePayload(pb.SessionLiveStateQuery, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_live_state_query = message } });
        },
        .session_live_state => blk: {
            var message = try decodePayload(pb.SessionLiveState, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_live_state = message } });
        },
        .session_client_control_response => blk: {
            var message = try decodePayload(pb.SessionClientControlResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_client_control_response = message } });
        },
        .client_repaint_request => blk: {
            var message = try decodePayload(pb.ClientRepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .client_repaint_request = message } });
        },
        .client_detach_request => blk: {
            var message = try decodePayload(pb.ClientDetachRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .client_detach_request = message } });
        },
        .session_client_detach_request => blk: {
            var message = try decodePayload(pb.SessionClientDetachRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_client_detach_request = message } });
        },
        .session_client_repaint_request => blk: {
            var message = try decodePayload(pb.SessionClientRepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_client_repaint_request = message } });
        },
        .session_client_debug_sever_connection_request => blk: {
            var message = try decodePayload(pb.SessionClientDebugSeverConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_client_debug_sever_connection_request = message } });
        },
        .session_client_debug_unresponsive_connection_request => blk: {
            var message = try decodePayload(pb.SessionClientDebugUnresponsiveConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_client_debug_unresponsive_connection_request = message } });
        },
        .stream_resume => blk: {
            var message = try decodePayload(pb.StreamResume, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_resume = message } });
        },
        .stream_data => blk: {
            var message = try decodePayload(pb.StreamData, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_data = message } });
        },
        .stream_ack => blk: {
            var message = try decodePayload(pb.StreamAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_ack = message } });
        },
        .stream_eof => blk: {
            var message = try decodePayload(pb.StreamEof, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_eof = message } });
        },
        .stream_eof_ack => blk: {
            var message = try decodePayload(pb.StreamEofAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_eof_ack = message } });
        },
        .stream_ping => blk: {
            var message = try decodePayload(pb.StreamPing, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_ping = message } });
        },
        .stream_pong => blk: {
            var message = try decodePayload(pb.StreamPong, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .stream_pong = message } });
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
    const original = pb.Draw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 4,
        .draw_bytes = "sessh",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.Draw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("opaque-cursor", decoded.scrollback_cursor);
    try std.testing.expectEqual(@as(?i32, 4), decoded.viewport_offset);
    try std.testing.expectEqualStrings("sessh", decoded.draw_bytes);
}

test "frame envelope round trip" {
    const payload = try encodePayload(std.testing.allocator, pb.InputAck{ .input_seq = 42 });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .input_ack, payload);
    defer std.testing.allocator.free(frame_bytes);

    const envelope = frame_bytes[frame_header_len..];
    var frame = try decodeEnvelopeAlloc(std.testing.allocator, envelope);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.input_ack, frame.message_type);

    var decoded = try decodePayload(pb.InputAck, std.testing.allocator, frame.payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), decoded.input_seq);
}

test "hello compatibility accepts peer max protocol when it satisfies local minimum" {
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 4,
        .version = "0.5.0-dev",
    }, 2, 3));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 2,
        .version = "0.5.0-dev",
    }, 2, 3));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 1,
        .protocol_minor = 4,
        .version = "0.5.0-dev",
    }, 2, 3));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 0,
        .version = "0.5.0-dev",
    }, 2, 3));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 1,
        .version = "0.5.0-dev",
    }, 2, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 4,
        .version = "0.6.0-dev",
    }, 2, 3));
}

test "session ended exit status is optional" {
    const payload = try encodePayload(std.testing.allocator, pb.SessionEnded{
        .reason = .SESSION_END_REASON_KILLED_BY_REQUEST,
        .ended_at_unix_ms = 42,
    });
    defer std.testing.allocator.free(payload);

    var decoded = try decodePayload(pb.SessionEnded, std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.SessionEndReason.SESSION_END_REASON_KILLED_BY_REQUEST, decoded.reason);
    try std.testing.expectEqual(@as(?pb.ExitStatus, null), decoded.exit_status);
    try std.testing.expectEqual(@as(?u64, 42), decoded.ended_at_unix_ms);
}
