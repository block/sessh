const std = @import("std");

pub fn FixedBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = [_]u8{0} ** capacity,
        len: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn storageSlice(self: *Self) []u8 {
            return self.bytes[0..];
        }

        pub fn remainingSlice(self: *Self) []u8 {
            return self.bytes[self.len..];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn assumeLen(self: *Self, len: usize) void {
            std.debug.assert(len <= self.bytes.len);
            self.len = len;
        }

        pub fn set(self: *Self, source: []const u8) !void {
            if (source.len > self.bytes.len) return error.FixedBufferTooLarge;
            @memcpy(self.bytes[0..source.len], source);
            self.len = source.len;
        }

        pub fn setTruncate(self: *Self, source: []const u8) void {
            const len = @min(self.bytes.len, source.len);
            @memcpy(self.bytes[0..len], source[0..len]);
            self.len = len;
        }

        pub fn appendByteIfRoom(self: *Self, byte: u8) bool {
            if (self.len >= self.bytes.len) return false;
            self.bytes[self.len] = byte;
            self.len += 1;
            return true;
        }

        pub fn commitWrite(self: *Self, n: usize) void {
            std.debug.assert(n <= self.remainingSlice().len);
            self.len += n;
        }
    };
}

test "fixed buffer stores, truncates, and appends" {
    var buffer = FixedBuffer(4){};

    try buffer.set("abc");
    try std.testing.expectEqualStrings("abc", buffer.slice());

    buffer.setTruncate("abcdef");
    try std.testing.expectEqualStrings("abcd", buffer.slice());

    buffer.clear();
    try std.testing.expect(buffer.appendByteIfRoom('x'));
    try std.testing.expect(buffer.appendByteIfRoom('y'));
    try std.testing.expectEqualStrings("xy", buffer.slice());

    const remaining = buffer.remainingSlice();
    @memcpy(remaining[0..2], "zw");
    buffer.commitWrite(2);
    try std.testing.expectEqualStrings("xyzw", buffer.slice());
}
