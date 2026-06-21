// Thin IO wrappers used where sessh needs auditable hooks around raw read/write
// syscalls. Production code gets the normal POSIX behavior; tests and
// transcripts can observe bytes without changing call sites.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("fds.zig");

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

pub fn noteWrite(fd: c.fd_t, bytes: []const u8) void {
    if (write_hook) |hook| hook(fd, bytes);
}

// Blocking convenience helpers. These are appropriate for foreground command
// setup, terminal restoration, tests, and other paths where the current process
// has no dispatcher work to service while waiting. Long-lived daemon/session
// callbacks must keep read/write progress in their own state machines instead;
// otherwise one stalled fd can freeze unrelated clients sharing the process.
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
    noteWrite(fd, bytes);
}

pub const WriteSomeResult = union(enum) {
    wrote: usize,
    would_block,
};

pub const ReadSomeResult = union(enum) {
    bytes: []const u8,
    would_block,
    eof,
};

pub fn readSome(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .eof;

        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

pub fn readSomeNonBlocking(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    var flags_guard = core_fds.StatusFlagsGuard.setNonBlocking(fd) catch return error.ReadFailed;
    defer flags_guard.restore();
    return readSome(fd, buf);
}

pub fn writeSomeNonBlocking(fd: c.fd_t, bytes: []const u8) !WriteSomeResult {
    if (bytes.len == 0) return .{ .wrote = 0 };

    var flags_guard = core_fds.StatusFlagsGuard.setNonBlocking(fd) catch return error.WriteFailed;
    defer flags_guard.restore();

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

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAll(posix.STDERR_FILENO, text);
}

fn waitReadable(fd: c.fd_t) !void {
    // used only by the blocking helpers above. Long-lived
    // daemon/session callbacks should use dispatcher-driven FrameReader state
    // instead of reaching this helper.
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        pollfds[0].revents = 0;
        _ = posix.poll(pollfds[0..], -1) catch return error.ReadFailed;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) return;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.ReadFailed;
    }
}

fn waitWritable(fd: c.fd_t) !void {
    // used only by the blocking helpers above. Long-lived
    // daemon/session callbacks should use dispatcher-owned write state instead
    // of reaching this helper.
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    while (true) {
        pollfds[0].revents = 0;
        _ = posix.poll(pollfds[0..], -1) catch return error.WriteFailed;
        if ((pollfds[0].revents & posix.POLL.OUT) != 0) return;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.WriteFailed;
    }
}

test "readSomeNonBlocking reports bytes, would-block, and eof" {
    const pipe_fds = try posix.pipe();
    var read_end = core_fds.OwnedFd.init(pipe_fds[0]);
    defer read_end.deinit();
    var write_end = core_fds.OwnedFd.init(pipe_fds[1]);
    defer write_end.deinit();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(ReadSomeResult.would_block, try readSomeNonBlocking(read_end.get(), &buf));

    try writeAll(write_end.get(), "abc");
    switch (try readSomeNonBlocking(read_end.get(), &buf)) {
        .bytes => |bytes| try std.testing.expectEqualStrings("abc", bytes),
        else => return error.ExpectedBytes,
    }

    write_end.deinit();
    try std.testing.expectEqual(ReadSomeResult.eof, try readSomeNonBlocking(read_end.get(), &buf));
}
