const std = @import("std");
const c = std.c;

const io = @import("io.zig");
pub const pb = @import("proto/sessh/protocol/v1.pb.zig");

pub const MessageType = pb.FrameType;

pub const Frame = struct {
    message_type: MessageType,
    payload: []const u8,
};

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

pub fn readFrame(fd: c.fd_t, payload_buf: []u8) !Frame {
    var header: [6]u8 = undefined;
    try io.readExact(fd, &header);
    const payload_len = (@as(u32, header[0]) << 24) |
        (@as(u32, header[1]) << 16) |
        (@as(u32, header[2]) << 8) |
        @as(u32, header[3]);
    if (payload_len > payload_buf.len) return error.FrameTooLarge;
    const message_value = (@as(u16, header[4]) << 8) | @as(u16, header[5]);
    const message_type = try messageTypeFromInt(message_value);
    const payload = payload_buf[0..payload_len];
    try io.readExact(fd, payload);
    return .{ .message_type = message_type, .payload = payload };
}

pub fn readFrameAlloc(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedFrame {
    var header: [6]u8 = undefined;
    try io.readExact(fd, &header);
    const payload_len = (@as(u32, header[0]) << 24) |
        (@as(u32, header[1]) << 16) |
        (@as(u32, header[2]) << 8) |
        @as(u32, header[3]);
    const message_value = (@as(u16, header[4]) << 8) | @as(u16, header[5]);
    const message_type = try messageTypeFromInt(message_value);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try io.readExact(fd, payload);
    return .{ .message_type = message_type, .payload = payload };
}

pub fn sendFrame(fd: c.fd_t, message_type: MessageType, payload: []const u8) !void {
    const header = try frameHeader(message_type, payload.len);
    try io.writeAll(fd, &header);
    try io.writeAll(fd, payload);
}

pub fn frameHeader(message_type: MessageType, payload_len_usize: usize) ![6]u8 {
    if (payload_len_usize > std.math.maxInt(u32)) return error.FrameTooLarge;
    const payload_len: u32 = @intCast(payload_len_usize);
    const message_value = @intFromEnum(message_type);
    if (message_value <= 0 or message_value > std.math.maxInt(u16)) return error.UnknownMessageType;
    const message_u16: u16 = @intCast(message_value);
    const header = [_]u8{
        @intCast((payload_len >> 24) & 0xff),
        @intCast((payload_len >> 16) & 0xff),
        @intCast((payload_len >> 8) & 0xff),
        @intCast(payload_len & 0xff),
        @intCast((message_u16 >> 8) & 0xff),
        @intCast(message_u16 & 0xff),
    };
    return header;
}

pub fn messageTypeFromInt(value: u16) !MessageType {
    inline for (@typeInfo(MessageType).@"enum".fields) |field| {
        if (field.value != 0 and field.value == value) return @enumFromInt(@as(i32, field.value));
    }
    return error.UnknownMessageType;
}

test "generated protobuf payload round trip" {
    const original = pb.Draw{
        .scrollback_epoch = 12,
        .scroll_count = 3,
        .cursor_row = 4,
        .bytes = "sessh",
        .cleanup_after = "",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.Draw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 12), decoded.scrollback_epoch);
    try std.testing.expectEqual(@as(u64, 3), decoded.scroll_count);
    try std.testing.expectEqual(@as(u32, 4), decoded.cursor_row);
    try std.testing.expectEqualStrings("sessh", decoded.bytes);
    try std.testing.expectEqualStrings("", decoded.cleanup_after.?);
}
