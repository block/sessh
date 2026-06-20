const std = @import("std");

const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;

pub const default_responsiveness_timeout_ms: i64 = 5_000;
pub const max_responsiveness_timeout_ms: i64 = 15_000;

pub const ConnectionMonitor = struct {
    enabled: bool = false,
    any_response_wait_started_ms: ?i64 = null,
    smoothed_rtt_ms: ?i64 = null,
    rtt_variance_ms: i64 = 0,
    responsiveness_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    clock: ?NonSuspendingTimer = null,

    pub fn afterInput(self: *ConnectionMonitor) void {
        if (!self.enabled) return;
        const now = self.nowMs();
        self.afterInputAt(now);
    }

    pub fn afterInputAt(self: *ConnectionMonitor, now: i64) void {
        if (!self.enabled) return;
        if (self.any_response_wait_started_ms == null) {
            self.any_response_wait_started_ms = now;
        }
    }

    pub const InputAckProgress = struct {
        still_pending: bool,
    };

    pub fn noteInputAckProgress(self: *ConnectionMonitor, progress: InputAckProgress) void {
        if (self.any_response_wait_started_ms) |started| {
            const now = self.nowMs();
            const rtt_ms = @max(now - started, 0);
            self.updateRtt(rtt_ms);
            self.any_response_wait_started_ms = if (progress.still_pending) now else null;
            return;
        }
        self.any_response_wait_started_ms = if (progress.still_pending) self.nowMs() else null;
    }

    fn updateRtt(self: *ConnectionMonitor, rtt_ms: i64) void {
        if (self.smoothed_rtt_ms) |srtt| {
            const delta = if (rtt_ms > srtt) rtt_ms - srtt else srtt - rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(3 * self.rtt_variance_ms + delta, 4), 1);
            self.smoothed_rtt_ms = @divTrunc(7 * srtt + rtt_ms, 8);
        } else {
            self.smoothed_rtt_ms = rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(rtt_ms, 2), 1);
        }
    }

    pub fn pollTimeoutMs(self: *ConnectionMonitor) i32 {
        if (!self.enabled) return 100;
        const started = self.any_response_wait_started_ms orelse return 100;
        const elapsed = self.nowMs() - started;
        const remaining = self.responsivenessTimeoutMs() - elapsed;
        if (remaining <= 0) return 0;
        return @intCast(@min(@as(i64, 100), remaining));
    }

    pub fn isUnresponsive(self: *ConnectionMonitor) bool {
        return self.isUnresponsiveAt(self.nowMs());
    }

    pub fn isUnresponsiveAt(self: *const ConnectionMonitor, now: i64) bool {
        if (!self.enabled) return false;
        const started = self.any_response_wait_started_ms orelse return false;
        return now - started >= self.responsivenessTimeoutMs();
    }

    fn responsivenessTimeoutMs(self: *const ConnectionMonitor) i64 {
        // TCP-style adaptive timeout: smoothed RTT plus variance, bounded so a
        // single retransmit-scale delay does not immediately force reconnect.
        const timeout = if (self.smoothed_rtt_ms) |srtt|
            srtt + 4 * self.rtt_variance_ms
        else
            default_responsiveness_timeout_ms;
        const floor = @min(max_responsiveness_timeout_ms, @max(default_responsiveness_timeout_ms, self.responsiveness_timeout_floor_ms));
        return @min(max_responsiveness_timeout_ms, @max(floor, timeout));
    }

    fn nowMs(self: *ConnectionMonitor) i64 {
        if (self.clock == null) {
            self.clock = NonSuspendingTimer.start() catch return std.time.milliTimestamp();
        }
        return if (self.clock) |*timer|
            @intCast(timer.read() / std.time.ns_per_ms)
        else
            std.time.milliTimestamp();
    }
};

test "connection monitor starts responsiveness wait after input" {
    var monitor = ConnectionMonitor{ .enabled = true };

    monitor.afterInputAt(1_000);
    try std.testing.expectEqual(@as(?i64, 1_000), monitor.any_response_wait_started_ms);
    try std.testing.expect(!monitor.isUnresponsiveAt(5_999));
    try std.testing.expect(monitor.isUnresponsiveAt(6_000));
}

test "connection monitor clears responsiveness wait after input ack progress" {
    var monitor = ConnectionMonitor{ .enabled = true };

    monitor.afterInputAt(1_000);
    try std.testing.expectEqual(@as(?i64, 1_000), monitor.any_response_wait_started_ms);

    monitor.noteInputAckProgress(.{ .still_pending = false });
    try std.testing.expectEqual(@as(?i64, null), monitor.any_response_wait_started_ms);
}
