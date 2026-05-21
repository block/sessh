const std = @import("std");
const c = std.c;

const io = @import("io.zig");
pub const pb = @import("proto/sessh/protocol/v1.pb.zig");
pub const hpb = @import("proto/sessh/handshake/v1.pb.zig");

pub const RemoteMessageType = pb.FrameType;
pub const StableMessageType = hpb.FrameType;

pub const MessageType = enum(u32) {
    FRAME_TYPE_UNSPECIFIED = 0,

    FRAME_TYPE_HELLO_REQUEST = frameTypeEnumValue(StableMessageType.FRAME_TYPE_HELLO_REQUEST),
    FRAME_TYPE_HELLO_OK = frameTypeEnumValue(StableMessageType.FRAME_TYPE_HELLO_OK),
    FRAME_TYPE_HELLO_ERROR = frameTypeEnumValue(StableMessageType.FRAME_TYPE_HELLO_ERROR),
    FRAME_TYPE_ERROR = frameTypeEnumValue(StableMessageType.FRAME_TYPE_ERROR),
    FRAME_TYPE_UNRECOGNIZED = frameTypeEnumValue(StableMessageType.FRAME_TYPE_UNRECOGNIZED),

    FRAME_TYPE_COMMAND_REQUEST = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_COMMAND_REQUEST),
    FRAME_TYPE_SESSION_NEW = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_SESSION_NEW),
    FRAME_TYPE_SESSION_ATTACH = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_SESSION_ATTACH),
    FRAME_TYPE_INPUT = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_INPUT),
    FRAME_TYPE_RESIZE = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_RESIZE),
    FRAME_TYPE_REPAINT = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_REPAINT),
    FRAME_TYPE_PING_REQUEST = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_PING_REQUEST),

    FRAME_TYPE_COMMAND_RESPONSE = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_COMMAND_RESPONSE),
    FRAME_TYPE_SESSION_ATTACHED = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_SESSION_ATTACHED),
    FRAME_TYPE_SESSION_ENDED = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_SESSION_ENDED),
    FRAME_TYPE_DRAW = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_DRAW),
    FRAME_TYPE_PING_RESPONSE = frameTypeEnumValue(RemoteMessageType.FRAME_TYPE_PING_RESPONSE),
};

var next_seq: u64 = 1;

/// Fixed 16-byte, big-endian frame header:
///
///   bytes 0..3   payload length
///   bytes 4..7   frame type
///   bytes 8..15  sender-local sequence number
///
/// `seq` is owned by the endpoint that writes the frame. It is not scoped to a
/// particular socket or SSH transport: when the client reconnects, the
/// surviving client and session-agent processes keep incrementing their
/// sequence numbers, and brokers relay headers unchanged rather than
/// renumbering session frames. This gives reconnect diagnostics a continuous
/// stream for spotting gaps and avoids reusing sequence numbers during one
/// process lifetime.
pub const FrameHeader = struct {
    pub const encoded_len = 16;

    payload_len: u32,
    message_type: FrameType,
    seq: u64,

    pub fn decode(bytes: *const [encoded_len]u8) FrameHeader {
        return .{
            .payload_len = readU32(bytes[0..4]),
            .message_type = messageTypeFromInt(readU32(bytes[4..8])),
            .seq = readU64(bytes[8..16]),
        };
    }

    pub fn encode(self: FrameHeader) [encoded_len]u8 {
        var bytes: [encoded_len]u8 = undefined;
        writeU32(bytes[0..4], self.payload_len);
        writeU32(bytes[4..8], self.message_type.value());
        writeU64(bytes[8..16], self.seq);
        return bytes;
    }

    pub fn init(message_type: MessageType, payload_len_usize: usize, seq: u64) !FrameHeader {
        if (payload_len_usize > std.math.maxInt(u32)) return error.FrameTooLarge;
        return .{
            .payload_len = @intCast(payload_len_usize),
            .message_type = .{ .known = message_type },
            .seq = seq,
        };
    }
};

pub const frame_header_len = FrameHeader.encoded_len;

pub const FrameType = union(enum) {
    known: MessageType,
    unknown: u32,

    pub fn value(self: FrameType) u32 {
        return switch (self) {
            .known => |message_type| messageTypeValue(message_type),
            .unknown => |raw| raw,
        };
    }
};

pub const Frame = struct {
    message_type: FrameType,
    seq: u64,
    payload: []const u8,

    pub fn knownMessageType(self: Frame) ?MessageType {
        return switch (self.message_type) {
            .known => |message_type| message_type,
            .unknown => null,
        };
    }
};

pub const OwnedFrame = struct {
    message_type: FrameType,
    seq: u64,
    payload: []u8,

    pub fn knownMessageType(self: OwnedFrame) ?MessageType {
        return switch (self.message_type) {
            .known => |message_type| message_type,
            .unknown => null,
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

pub fn readFrame(fd: c.fd_t, payload_buf: []u8) !Frame {
    var header_bytes: [frame_header_len]u8 = undefined;
    try io.readExact(fd, &header_bytes);
    const header = FrameHeader.decode(&header_bytes);
    const payload_len: usize = @intCast(header.payload_len);
    if (payload_len > payload_buf.len) return error.FrameTooLarge;
    const payload = payload_buf[0..payload_len];
    try io.readExact(fd, payload);
    return .{ .message_type = header.message_type, .seq = header.seq, .payload = payload };
}

pub fn readFrameAlloc(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedFrame {
    var header_bytes: [frame_header_len]u8 = undefined;
    try io.readExact(fd, &header_bytes);
    const header = FrameHeader.decode(&header_bytes);
    const payload_len: usize = @intCast(header.payload_len);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try io.readExact(fd, payload);
    return .{ .message_type = header.message_type, .seq = header.seq, .payload = payload };
}

pub fn sendFrame(fd: c.fd_t, message_type: MessageType, payload: []const u8) !void {
    _ = try sendFrameWithAllocatedSeq(fd, message_type, payload);
}

pub fn sendFrameWithAllocatedSeq(fd: c.fd_t, message_type: MessageType, payload: []const u8) !u64 {
    const seq = allocateSeq();
    const header = try frameHeaderWithSeq(message_type, payload.len, seq);
    try io.writeAll(fd, &header);
    try io.writeAll(fd, payload);
    return seq;
}

pub fn sendFrameWithSeq(fd: c.fd_t, message_type: MessageType, payload: []const u8, seq: u64) !void {
    const header = try frameHeaderWithSeq(message_type, payload.len, seq);
    try io.writeAll(fd, &header);
    try io.writeAll(fd, payload);
    observeSentSeq(seq);
}

pub fn frameHeader(message_type: MessageType, payload_len_usize: usize) ![frame_header_len]u8 {
    return frameHeaderWithSeq(message_type, payload_len_usize, allocateSeq());
}

pub fn frameHeaderWithSeq(message_type: MessageType, payload_len_usize: usize, seq: u64) ![frame_header_len]u8 {
    return (try FrameHeader.init(message_type, payload_len_usize, seq)).encode();
}

pub fn payloadLenFromHeader(header: *const [frame_header_len]u8) usize {
    return @intCast(FrameHeader.decode(header).payload_len);
}

fn messageTypeValue(message_type: MessageType) u32 {
    return @intFromEnum(message_type);
}

pub fn messageTypeFromInt(value: u32) FrameType {
    inline for (@typeInfo(MessageType).@"enum".fields) |field| {
        if (field.value != 0 and field.value == value) return .{ .known = @enumFromInt(@as(u32, field.value)) };
    }
    return .{ .unknown = value };
}

fn frameTypeEnumValue(comptime message_type: anytype) u32 {
    return @intCast(@intFromEnum(message_type));
}

fn allocateSeq() u64 {
    const seq = next_seq;
    next_seq +%= 1;
    if (next_seq == 0) next_seq = 1;
    return seq;
}

fn observeSentSeq(seq: u64) void {
    if (seq == 0) return;
    if (seq >= next_seq) {
        next_seq = seq +% 1;
        if (next_seq == 0) next_seq = 1;
    }
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn readU64(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        @as(u64, bytes[7]);
}

fn writeU32(bytes: []u8, value: u32) void {
    bytes[0] = @intCast((value >> 24) & 0xff);
    bytes[1] = @intCast((value >> 16) & 0xff);
    bytes[2] = @intCast((value >> 8) & 0xff);
    bytes[3] = @intCast(value & 0xff);
}

fn writeU64(bytes: []u8, value: u64) void {
    bytes[0] = @intCast((value >> 56) & 0xff);
    bytes[1] = @intCast((value >> 48) & 0xff);
    bytes[2] = @intCast((value >> 40) & 0xff);
    bytes[3] = @intCast((value >> 32) & 0xff);
    bytes[4] = @intCast((value >> 24) & 0xff);
    bytes[5] = @intCast((value >> 16) & 0xff);
    bytes[6] = @intCast((value >> 8) & 0xff);
    bytes[7] = @intCast(value & 0xff);
}

test "generated protobuf payload round trip" {
    const original = pb.Draw{
        .scrollback_epoch = 12,
        .scroll_count = 3,
        .cursor_row = 4,
        .draw_bytes = "sessh",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.Draw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 12), decoded.scrollback_epoch);
    try std.testing.expectEqual(@as(u64, 3), decoded.scroll_count);
    try std.testing.expectEqual(@as(u32, 4), decoded.cursor_row);
    try std.testing.expectEqualStrings("sessh", decoded.draw_bytes);
}

test "observed explicit seq advances automatic allocation" {
    const saved_next_seq = next_seq;
    defer next_seq = saved_next_seq;

    next_seq = 10;
    observeSentSeq(12);
    try std.testing.expectEqual(@as(u64, 13), allocateSeq());
    try std.testing.expectEqual(@as(u64, 14), allocateSeq());

    observeSentSeq(7);
    try std.testing.expectEqual(@as(u64, 15), allocateSeq());
}
