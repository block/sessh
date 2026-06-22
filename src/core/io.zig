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

pub const WriteSomeResult = union(enum) {
    wrote: usize,
    would_block,
};

pub const ReadSomeResult = union(enum) {
    bytes: []const u8,
    would_block,
    eof,
};

pub const ReadSomeOptions = struct {
    /// PTY masters on Linux report "slave side closed" as EIO rather than a
    /// zero-length read. Ordinary byte streams should keep the default so EIO
    /// remains an error; PTY-backed dispatcher sources opt into EOF semantics.
    eio_is_eof: bool = false,
};

pub fn readSome(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    return readSomeWithOptions(fd, buf, .{});
}

pub fn readSomeWithOptions(fd: c.fd_t, buf: []u8, options: ReadSomeOptions) !ReadSomeResult {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .eof;

        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            .IO => if (options.eio_is_eof) return .eof else return error.InputOutput,
            else => return error.ReadFailed,
        }
    }
}

pub fn readSomeNonBlocking(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    return readSomeNonBlockingWithOptions(fd, buf, .{});
}

pub fn readSomeNonBlockingWithOptions(fd: c.fd_t, buf: []u8, options: ReadSomeOptions) !ReadSomeResult {
    var flags_guard = core_fds.StatusFlagsGuard.setNonBlocking(fd) catch return error.ReadFailed;
    defer flags_guard.restore();
    return readSomeWithOptions(fd, buf, options);
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

test "readSomeNonBlocking reports bytes, would-block, and eof" {
    const blocking = @import("blocking.zig").fromTest();
    const pipe_fds = try posix.pipe();
    var read_end = core_fds.OwnedFd.init(pipe_fds[0]);
    defer read_end.deinit();
    var write_end = core_fds.OwnedFd.init(pipe_fds[1]);
    defer write_end.deinit();

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(ReadSomeResult.would_block, try readSomeNonBlocking(read_end.get(), &buf));

    try blocking.writeAll(write_end.get(), "abc");
    switch (try readSomeNonBlocking(read_end.get(), &buf)) {
        .bytes => |bytes| try std.testing.expectEqualStrings("abc", bytes),
        else => return error.ExpectedBytes,
    }

    write_end.deinit();
    try std.testing.expectEqual(ReadSomeResult.eof, try readSomeNonBlocking(read_end.get(), &buf));
}
