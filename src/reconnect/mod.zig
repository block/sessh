const std = @import("std");

const delays_ms = [_]u64{
    10_000,
    20_000,
    40_000,
    80_000,
    160_000,
    320_000,
    600_000,
};

pub fn delayMs(attempt: usize) u64 {
    return if (attempt < delays_ms.len) delays_ms[attempt] else delays_ms[delays_ms.len - 1];
}

pub fn nextAttempt(attempt: usize, reset: bool) usize {
    return if (reset) 0 else attempt + 1;
}

pub fn AsyncResult(comptime Ready: type) type {
    return union(enum) {
        ready: Ready,
        failed: anyerror,
    };
}

// Shared handoff for reconnect attempts that prepare a replacement transport
// in a worker thread. The transport-specific code owns how a replacement is
// created and attached; this type only provides the synchronized result slot
// used by both the PTY reconnect path and reconnectable byte streams.
pub fn AsyncTask(comptime Ready: type) type {
    return struct {
        const Self = @This();
        const Result = AsyncResult(Ready);

        mutex: std.Thread.Mutex = .{},
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?Result = null,

        pub fn store(self: *Self, result: Result) void {
            self.mutex.lock();
            self.result = result;
            self.mutex.unlock();
            self.done.store(true, .release);
        }

        pub fn isDone(self: *const Self) bool {
            return self.done.load(.acquire);
        }

        pub fn take(self: *Self) ?Result {
            self.mutex.lock();
            defer self.mutex.unlock();
            const result = self.result orelse return null;
            self.result = null;
            return result;
        }
    };
}

test "delayMs follows the documented backoff schedule" {
    try std.testing.expectEqual(@as(u64, 10_000), delayMs(0));
    try std.testing.expectEqual(@as(u64, 20_000), delayMs(1));
    try std.testing.expectEqual(@as(u64, 40_000), delayMs(2));
    try std.testing.expectEqual(@as(u64, 80_000), delayMs(3));
    try std.testing.expectEqual(@as(u64, 160_000), delayMs(4));
    try std.testing.expectEqual(@as(u64, 320_000), delayMs(5));
    try std.testing.expectEqual(@as(u64, 600_000), delayMs(6));
    try std.testing.expectEqual(@as(u64, 600_000), delayMs(7));
}

test "nextAttempt can reset after explicit reconnect acknowledgement" {
    try std.testing.expectEqual(@as(usize, 0), nextAttempt(4, true));
    try std.testing.expectEqual(@as(usize, 5), nextAttempt(4, false));
}
