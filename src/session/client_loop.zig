const std = @import("std");

const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;

const paste_like_single_read_bytes = 32;
const paste_like_window_bytes = 64;
const paste_like_window_ms: i64 = 250;

pub const PasteLikeInputClassifier = struct {
    window_started_ms: ?i64 = null,
    window_bytes: usize = 0,
    clock: ?NonSuspendingTimer = null,

    pub fn classify(self: *PasteLikeInputClassifier, forwarded_bytes: usize) bool {
        if (forwarded_bytes == 0) return false;
        // TODO: Detect bracketed paste delimiters here once client input
        // parsing tracks them explicitly.
        if (forwarded_bytes >= paste_like_single_read_bytes) return true;

        const now = self.nowMs();
        if (self.window_started_ms) |started| {
            if (now - started <= paste_like_window_ms) {
                self.window_bytes += forwarded_bytes;
            } else {
                self.window_started_ms = now;
                self.window_bytes = forwarded_bytes;
            }
        } else {
            self.window_started_ms = now;
            self.window_bytes = forwarded_bytes;
        }

        return self.window_bytes >= paste_like_window_bytes;
    }

    fn nowMs(self: *PasteLikeInputClassifier) i64 {
        if (self.clock == null) {
            self.clock = NonSuspendingTimer.start() catch return std.time.milliTimestamp();
        }
        return if (self.clock) |*timer|
            @intCast(timer.read() / std.time.ns_per_ms)
        else
            std.time.milliTimestamp();
    }
};

