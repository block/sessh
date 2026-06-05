const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const WriteHook = *const fn (fd: c.fd_t, bytes: []const u8) void;
pub const ReadHook = *const fn (fd: c.fd_t, bytes: []const u8) void;

var write_hook: ?WriteHook = null;
var read_hook: ?ReadHook = null;

pub fn setWriteHook(hook: ?WriteHook) void {
    write_hook = hook;
}

pub fn setReadHook(hook: ?ReadHook) void {
    read_hook = hook;
}

pub fn noteRead(fd: c.fd_t, bytes: []const u8) void {
    if (read_hook) |hook| hook(fd, bytes);
}

// Some callers hand us fds whose blocking mode we did not choose. Keep these
// helpers blocking-style by waiting and retrying when the kernel reports "try
// again".
pub fn readExact(fd: c.fd_t, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = c.read(fd, buf[offset..].ptr, buf.len - offset);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => {
                try waitReadable(fd);
                continue;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        offset += @intCast(n);
    }
    noteRead(fd, buf);
}

pub fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => {
                try waitWritable(fd);
                continue;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        };
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    if (write_hook) |hook| hook(fd, bytes);
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

fn waitReadable(fd: c.fd_t) !void {
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        pollfds[0].revents = 0;
        _ = posix.poll(pollfds[0..], -1) catch return error.ReadFailed;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) return;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.ReadFailed;
    }
}

fn waitWritable(fd: c.fd_t) !void {
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    while (true) {
        pollfds[0].revents = 0;
        _ = posix.poll(pollfds[0..], -1) catch return error.WriteFailed;
        if ((pollfds[0].revents & posix.POLL.OUT) != 0) return;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.WriteFailed;
    }
}
