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
