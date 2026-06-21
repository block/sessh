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
        try io.readExact(fd, buf);
    }

    pub fn writeAll(_: Blocking, fd: c.fd_t, bytes: []const u8) !void {
        try io.writeAll(fd, bytes);
    }

    pub fn stderrPrint(_: Blocking, comptime fmt: []const u8, args: anytype) !void {
        try io.stderrPrint(fmt, args);
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

    pub fn childRun(_: Blocking, options: anytype) !std.process.Child.RunResult {
        return std.process.Child.run(options);
    }

    pub fn loop(_: Blocking) !dispatcher.LoopExit {
        return dispatcher.get().loopForBlocking();
    }

    pub fn runLoop(self: Blocking) !void {
        _ = try self.loop();
    }
};

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
