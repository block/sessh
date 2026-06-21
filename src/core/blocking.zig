// Explicit facade for blocking operations. New production code should reach
// raw blocking syscalls through this module only, and only from process
// entrypoints or short foreground setup phases where there is no dispatcher
// work to service. `scripts/check_blocking.py` enforces that policy.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const dispatcher = @import("dispatcher.zig");
const io = @import("io.zig");
const process_wait = @import("waitpid.zig");

pub const Blocking = struct {
    _private: void = {},

    pub fn readExact(_: Blocking, fd: c.fd_t, buf: []u8) !void {
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
        io.noteRead(fd, buf);
    }

    pub fn writeAll(_: Blocking, fd: c.fd_t, bytes: []const u8) !void {
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
        io.noteWrite(fd, bytes);
    }

    pub fn stderrPrint(self: Blocking, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(posix.STDERR_FILENO, text);
    }

    pub fn sleepMs(_: Blocking, milliseconds: u64) void {
        posix.nanosleep(0, milliseconds * std.time.ns_per_ms);
    }

    pub fn poll(_: Blocking, pollfds: []posix.pollfd, timeout_ms: i32) !usize {
        return posix.poll(pollfds, timeout_ms);
    }

    pub fn waitPid(_: Blocking, pid: c.pid_t) std.process.Child.Term {
        const result = posix.waitpid(pid, 0);
        return process_wait.termFromStatus(result.status);
    }

    pub const ChildRunOptions = struct {
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        max_output_bytes: usize = 50 * 1024,
        expand_arg0: std.process.Child.Arg0Expand = .no_expand,
    };

    pub fn childRun(_: Blocking, options: ChildRunOptions) !std.process.Child.RunResult {
        return std.process.Child.run(.{
            .allocator = options.allocator,
            .argv = options.argv,
            .max_output_bytes = options.max_output_bytes,
            .expand_arg0 = options.expand_arg0,
        });
    }

    pub fn loop(_: Blocking) !dispatcher.LoopExit {
        return dispatcher.get().loopForBlocking();
    }

    pub fn runLoop(self: Blocking) !void {
        _ = try self.loop();
    }
};

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

pub fn fromMain() Blocking {
    return .{};
}

pub fn fromTest() Blocking {
    return .{};
}

test "blocking token wraps foreground write helpers" {
    const token = fromTest();
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    try token.writeAll(pipe[1], "x");
    var buf: [1]u8 = undefined;
    try token.readExact(pipe[0], &buf);
    try std.testing.expectEqual(@as(u8, 'x'), buf[0]);
}
