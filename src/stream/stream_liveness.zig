const std = @import("std");

pub const default_ping_interval_ms: u64 = 1_000;
pub const default_unresponsive_after_ms: u64 = 10_000;

pub const StreamLiveness = struct {
    last_incoming_ms: u64,
    next_ping_ms: u64,
    ping_interval_ms: u64 = default_ping_interval_ms,
    unresponsive_after_ms: u64 = default_unresponsive_after_ms,

    pub fn init(now_ms: u64) StreamLiveness {
        return .{
            .last_incoming_ms = now_ms,
            .next_ping_ms = now_ms + default_ping_interval_ms,
        };
    }

    pub fn noteIncoming(self: *StreamLiveness, now_ms: u64) void {
        self.last_incoming_ms = now_ms;
        self.next_ping_ms = now_ms + self.ping_interval_ms;
    }

    pub fn pollTimeoutMs(self: *const StreamLiveness, now_ms: u64, requested_timeout_ms: i32) i32 {
        var deadline_ms = self.next_ping_ms;
        const unresponsive_deadline_ms = self.last_incoming_ms + self.unresponsive_after_ms;
        if (unresponsive_deadline_ms < deadline_ms) deadline_ms = unresponsive_deadline_ms;
        const liveness_timeout_ms: i32 = if (deadline_ms <= now_ms)
            if (requested_timeout_ms >= 0 and self.timedOut(now_ms)) requested_timeout_ms else 0
        else
            @intCast(@min(deadline_ms - now_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
        if (requested_timeout_ms < 0) return liveness_timeout_ms;
        return @min(requested_timeout_ms, liveness_timeout_ms);
    }

    pub fn timedOut(self: *const StreamLiveness, now_ms: u64) bool {
        return elapsedMs(self.last_incoming_ms, now_ms) >= self.unresponsive_after_ms;
    }

    pub fn pingDue(self: *const StreamLiveness, now_ms: u64) bool {
        return now_ms >= self.next_ping_ms;
    }

    pub fn notePingSent(self: *StreamLiveness, now_ms: u64) void {
        self.next_ping_ms = now_ms + self.ping_interval_ms;
    }
};

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    return end_ms -| start_ms;
}

test "stream liveness schedules probes before declaring unresponsive" {
    var liveness = StreamLiveness.init(1_000);
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(1_000, -1));
    try std.testing.expect(liveness.pingDue(2_000));
    try std.testing.expect(!liveness.timedOut(2_000));
    liveness.notePingSent(2_000);
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(2_000, -1));
    try std.testing.expect(liveness.timedOut(11_000));
    try std.testing.expectEqual(@as(i32, 50), liveness.pollTimeoutMs(11_000, 50));
    liveness.noteIncoming(11_000);
    try std.testing.expect(!liveness.timedOut(11_000));
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(11_000, -1));
}
