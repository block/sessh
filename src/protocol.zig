const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;

const io = @import("io.zig");
pub const pb = @import("proto/sessh/protocol/v1.pb.zig");
pub const hpb = @import("proto/sessh/handshake/v1.pb.zig");

pub const MessageType = enum {
    FRAME_TYPE_HELLO_REQUEST,
    FRAME_TYPE_HELLO_OK,
    FRAME_TYPE_HELLO_ERROR,
    FRAME_TYPE_ERROR,

    FRAME_TYPE_SESSION_NEW,
    FRAME_TYPE_SESSION_ATTACH,
    FRAME_TYPE_INPUT,
    FRAME_TYPE_RESIZE,
    FRAME_TYPE_REPAINT,
    FRAME_TYPE_PING_REQUEST,

    FRAME_TYPE_SESSION_ATTACHED,
    FRAME_TYPE_SESSION_ENDED,
    FRAME_TYPE_DRAW,
    FRAME_TYPE_PING_RESPONSE,
    FRAME_TYPE_REPAINT_RESPONSE,
};

pub const frame_header_len = 4;

pub const FrameType = union(enum) {
    known: MessageType,
};

pub const Frame = struct {
    message_type: FrameType,
    payload: []const u8,

    pub fn knownMessageType(self: Frame) ?MessageType {
        return switch (self.message_type) {
            .known => |message_type| message_type,
        };
    }
};

pub const OwnedFrame = struct {
    message_type: FrameType,
    payload: []u8,

    pub fn knownMessageType(self: OwnedFrame) ?MessageType {
        return switch (self.message_type) {
            .known => |message_type| message_type,
        };
    }

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
            .@"error" => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_ERROR, message),
            .session_new => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_SESSION_NEW, message),
            .session_attach => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_SESSION_ATTACH, message),
            .input => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_INPUT, message),
            .resize => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_RESIZE, message),
            .repaint_request => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_REPAINT, message),
            .ping_request => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_PING_REQUEST, message),
            .session_attached => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_SESSION_ATTACHED, message),
            .session_ended => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_SESSION_ENDED, message),
            .draw => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_DRAW, message),
            .ping_response => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_PING_RESPONSE, message),
            .repaint_response => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_REPAINT_RESPONSE, message),
        };
    }

    var hello_frame = try decodePayload(hpb.HelloFrame, allocator, envelope);
    defer hello_frame.deinit(allocator);
    if (hello_frame.payload) |payload| {
        return switch (payload) {
            .hello_request => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_HELLO_REQUEST, message),
            .hello_ok => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_HELLO_OK, message),
            .hello_error => |message| ownedFrameFromMessage(allocator, .FRAME_TYPE_HELLO_ERROR, message),
        };
    }
    return error.UnknownFrame;
}

fn isHelloFrameEnvelope(envelope: []const u8) bool {
    return envelope[0] == 0x0a or envelope[0] == 0x12 or envelope[0] == 0x1a;
}

fn ownedFrameFromMessage(allocator: std.mem.Allocator, message_type: MessageType, message: anytype) !OwnedFrame {
    return .{
        .message_type = .{ .known = message_type },
        .payload = try encodePayload(allocator, message),
    };
}

fn encodeEnvelopePayload(allocator: std.mem.Allocator, message_type: MessageType, payload: []const u8) ![]u8 {
    return switch (message_type) {
        .FRAME_TYPE_HELLO_REQUEST => blk: {
            var message = try decodePayload(hpb.HelloRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_request = message } });
        },
        .FRAME_TYPE_HELLO_OK => blk: {
            var message = try decodePayload(hpb.HelloOk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_ok = message } });
        },
        .FRAME_TYPE_HELLO_ERROR => blk: {
            var message = try decodePayload(hpb.HelloError, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_error = message } });
        },
        .FRAME_TYPE_ERROR => blk: {
            var message = try decodePayload(hpb.Error, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .@"error" = message } });
        },
        .FRAME_TYPE_SESSION_NEW => blk: {
            var message = try decodePayload(pb.SessionNew, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_new = message } });
        },
        .FRAME_TYPE_SESSION_ATTACH => blk: {
            var message = try decodePayload(pb.SessionAttach, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_attach = message } });
        },
        .FRAME_TYPE_INPUT => blk: {
            var message = try decodePayload(pb.Input, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .input = message } });
        },
        .FRAME_TYPE_RESIZE => blk: {
            var message = try decodePayload(pb.Resize, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .resize = message } });
        },
        .FRAME_TYPE_REPAINT => blk: {
            var message = try decodePayload(pb.RepaintRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .repaint_request = message } });
        },
        .FRAME_TYPE_PING_REQUEST => blk: {
            var message = try decodePayload(pb.PingRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .ping_request = message } });
        },
        .FRAME_TYPE_SESSION_ATTACHED => blk: {
            var message = try decodePayload(pb.SessionAttached, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_attached = message } });
        },
        .FRAME_TYPE_SESSION_ENDED => blk: {
            var message = try decodePayload(pb.SessionEnded, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .session_ended = message } });
        },
        .FRAME_TYPE_DRAW => blk: {
            var message = try decodePayload(pb.Draw, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .draw = message } });
        },
        .FRAME_TYPE_PING_RESPONSE => blk: {
            var message = try decodePayload(pb.PingResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .ping_response = message } });
        },
        .FRAME_TYPE_REPAINT_RESPONSE => blk: {
            var message = try decodePayload(pb.RepaintResponse, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{ .payload = .{ .repaint_response = message } });
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
    const payload = try encodePayload(std.testing.allocator, pb.PingRequest{ .ping_request_seq = 42 });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .FRAME_TYPE_PING_REQUEST, payload);
    defer std.testing.allocator.free(frame_bytes);

    const envelope = frame_bytes[frame_header_len..];
    var frame = try decodeEnvelopeAlloc(std.testing.allocator, envelope);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(frame.knownMessageType() == .FRAME_TYPE_PING_REQUEST);

    var decoded = try decodePayload(pb.PingRequest, std.testing.allocator, frame.payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), decoded.ping_request_seq);
}
