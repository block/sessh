const std = @import("std");
const c = std.c;
const posix = std.posix;

pub fn readExact(fd: c.fd_t, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = c.read(fd, buf[offset..].ptr, buf.len - offset);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        offset += @intCast(n);
    }
}

pub fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub const WriteSomeResult = union(enum) {
    wrote: usize,
    would_block,
};

pub fn writeSomeNonBlocking(fd: c.fd_t, bytes: []const u8) !WriteSomeResult {
    if (bytes.len == 0) return .{ .wrote = 0 };

    const original_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (original_flags < 0) return error.WriteFailed;

    const nonblocking_flag = nonblockingFlag();
    const changed_flags = (original_flags & nonblocking_flag) == 0;
    if (changed_flags and c.fcntl(fd, c.F.SETFL, original_flags | nonblocking_flag) < 0) {
        return error.WriteFailed;
    }
    defer {
        if (changed_flags) _ = c.fcntl(fd, c.F.SETFL, original_flags);
    }

    while (true) {
        const n = c.write(fd, bytes.ptr, bytes.len);
        if (n > 0) return .{ .wrote = @intCast(n) };
        if (n == 0) return error.WriteFailed;

        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn nonblockingFlag() c_int {
    return @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
}

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAll(2, text);
}

pub fn sleepMillis(ms: u64) void {
    const ts = c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = c.nanosleep(&ts, null);
}
