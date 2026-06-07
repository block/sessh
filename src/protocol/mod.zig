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

    te_stream_open,
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
    mux_stream_frame,
    proxy_stream_item,
    proxy_control_capabilities,
    proxy_control_diagnostic,
    proxy_control_ctrl_r,
    te_stream_item,
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
            .ping => |message| ownedFrameFromMessage(allocator, .ping, message),
            .pong => |message| ownedFrameFromMessage(allocator, .pong, message),
            .mux_stream_frame => |message| ownedFrameFromMessage(allocator, .mux_stream_frame, message),
            .te_stream_item => |message| ownedFrameFromTeStreamItem(allocator, message),
            .proxy_stream_item => |message| ownedFrameFromProxyStreamItem(allocator, message),
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

fn ownedFrameFromTeStreamItem(allocator: std.mem.Allocator, item: pb.TeStreamItem) !OwnedFrame {
    const payload = item.payload orelse return error.UnknownFrame;
    return switch (payload) {
        .open => |message| ownedFrameFromMessage(allocator, .te_stream_open, message),
        .input => |message| ownedFrameFromMessage(allocator, .te_input, message),
        .input_ack => |message| ownedFrameFromMessage(allocator, .te_input_ack, message),
        .resize => |message| ownedFrameFromMessage(allocator, .te_resize, message),
        .repaint_request => |message| ownedFrameFromMessage(allocator, .te_repaint_request, message),
        .session_attached => |message| ownedFrameFromMessage(allocator, .te_session_attached, message),
        .session_ended => |message| ownedFrameFromMessage(allocator, .te_session_ended, message),
        .draw => |message| ownedFrameFromMessage(allocator, .te_draw, message),
        .repaint_response => |message| ownedFrameFromMessage(allocator, .te_repaint_response, message),
        .tty_transcript_chunk => |message| ownedFrameFromMessage(allocator, .te_tty_transcript_chunk, message),
        .diagnostic => |message| ownedFrameFromMessage(allocator, .te_stream_item, pb.TeStreamItem{ .payload = .{ .diagnostic = message } }),
        .session_client_control_response => |message| ownedFrameFromMessage(allocator, .te_session_client_control_response, message),
        .debug_sever_connection_request => |message| ownedFrameFromMessage(allocator, .te_session_client_debug_sever_connection_request, message),
        .debug_unresponsive_connection_request => |message| ownedFrameFromMessage(allocator, .te_session_client_debug_unresponsive_connection_request, message),
    };
}

fn ownedFrameFromProxyStreamItem(allocator: std.mem.Allocator, item: pb.ProxyStreamItem) !OwnedFrame {
    const payload = item.payload orelse return error.UnknownFrame;
    return switch (payload) {
        .control_capabilities => |message| ownedFrameFromMessage(allocator, .proxy_control_capabilities, message),
        .control_diagnostic => |message| ownedFrameFromMessage(allocator, .proxy_control_diagnostic, message),
        .control_ctrl_r => |message| ownedFrameFromMessage(allocator, .proxy_control_ctrl_r, message),
        else => ownedFrameFromMessage(allocator, .proxy_stream_item, item),
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
        .te_stream_open => blk: {
            var message = try decodePayload(pb.TeStreamOpen, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .open = message } } } });
        },
        .te_input => blk: {
            var message = try decodePayload(pb.TeInput, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .input = message } } } });
        },
        .te_resize => blk: {
            var message = try decodePayload(pb.TeResize, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .resize = message } } } });
        },
        .te_repaint_request => blk: {
            var message = try decodePayload(pb.TeRepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .repaint_request = message } } } });
        },
        .te_session_attached => blk: {
            var message = try decodePayload(pb.TeSessionAttached, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .session_attached = message } } } });
        },
        .te_session_ended => blk: {
            var message = try decodePayload(pb.TeSessionEnded, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .session_ended = message } } } });
        },
        .te_draw => blk: {
            var message = try decodePayload(pb.TeDraw, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .draw = message } } } });
        },
        .te_repaint_response => blk: {
            var message = try decodePayload(pb.TeRepaintResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .repaint_response = message } } } });
        },
        .te_tty_transcript_chunk => blk: {
            var message = try decodePayload(pb.TeTtyTranscriptChunk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .tty_transcript_chunk = message } } } });
        },
        .te_input_ack => blk: {
            var message = try decodePayload(pb.TeInputAck, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .input_ack = message } } } });
        },
        .te_session_client_control_response => blk: {
            var message = try decodePayload(pb.TeSessionClientControlResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .session_client_control_response = message } } } });
        },
        .te_session_client_debug_sever_connection_request => blk: {
            var message = try decodePayload(pb.TeSessionClientDebugSeverConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .debug_sever_connection_request = message } } } });
        },
        .te_session_client_debug_unresponsive_connection_request => blk: {
            var message = try decodePayload(pb.TeSessionClientDebugUnresponsiveConnectionRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = .{ .payload = .{ .debug_unresponsive_connection_request = message } } } });
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
        .mux_stream_frame => blk: {
            var message = try decodePayload(pb.MuxStreamFrame, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .mux_stream_frame = message } });
        },
        .proxy_stream_item => blk: {
            var message = try decodePayload(pb.ProxyStreamItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_item = message } });
        },
        .proxy_control_capabilities => blk: {
            var message = try decodePayload(pb.ProxyControlCapabilities, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_item = .{ .payload = .{ .control_capabilities = message } } } });
        },
        .proxy_control_diagnostic => blk: {
            var message = try decodePayload(pb.ProxyControlDiagnostic, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_item = .{ .payload = .{ .control_diagnostic = message } } } });
        },
        .proxy_control_ctrl_r => blk: {
            var message = try decodePayload(pb.ProxyControlCtrlR, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .proxy_stream_item = .{ .payload = .{ .control_ctrl_r = message } } } });
        },
        .te_stream_item => blk: {
            var message = try decodePayload(pb.TeStreamItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .te_stream_item = message } });
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

test "mux stream frame preserves stream id offset and proxy payload" {
    const payload = try encodePayload(std.testing.allocator, pb.MuxStreamFrame{
        .stream_id = 7,
        .message = .{ .payload = .{
            .offset = 42,
            .item = .{ .proxy = .{ .payload = .{ .data = "hello" } } },
        } },
    });
    defer std.testing.allocator.free(payload);

    const frame_bytes = try encodeFrame(std.testing.allocator, .mux_stream_frame, payload);
    defer std.testing.allocator.free(frame_bytes);

    var frame = try decodeEnvelopeAlloc(std.testing.allocator, frame_bytes[frame_header_len..]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.mux_stream_frame, frame.message_type);

    var decoded = try decodePayload(pb.MuxStreamFrame, std.testing.allocator, frame.payload);
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
