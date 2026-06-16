const std = @import("std");
const builtin = @import("builtin");

/// A `std.time.Timer`-shaped timer backed by a clock that includes time spent
/// asleep when the platform exposes one.
///
/// Zig 0.15's `std.time.Timer` uses `CLOCK_UPTIME_RAW` on Darwin, and that
/// clock stops while the machine is suspended. Zig main has fixed this by
/// splitting clocks by intent: `Io.Clock.awake` excludes suspended time, while
/// `Io.Clock.boot` includes it. Until we build against a release with that API,
/// reconnect, cleanup, and UI deadlines use this timer so they expire when the
/// machine wakes instead of waiting for additional awake time.
pub const NonSuspendingTimer = struct {
    started_ns: u64,
    previous_ns: u64,

    pub const Error = error{TimerUnsupported};

    pub fn start() Error!NonSuspendingTimer {
        const current = nowNs() catch return error.TimerUnsupported;
        return .{
            .started_ns = current,
            .previous_ns = current,
        };
    }

    pub fn read(self: *NonSuspendingTimer) u64 {
        const current = self.sample();
        return current -| self.started_ns;
    }

    pub fn reset(self: *NonSuspendingTimer) void {
        self.started_ns = self.sample();
    }

    pub fn lap(self: *NonSuspendingTimer) u64 {
        const current = self.sample();
        defer self.started_ns = current;
        return current -| self.started_ns;
    }

    fn sample(self: *NonSuspendingTimer) u64 {
        const current = nowNs() catch unreachable;
        if (current > self.previous_ns) self.previous_ns = current;
        return self.previous_ns;
    }
};

pub fn nowMs() NonSuspendingTimer.Error!u64 {
    return (try nowNs()) / std.time.ns_per_ms;
}

pub fn nowNs() NonSuspendingTimer.Error!u64 {
    const clock_id = switch (builtin.os.tag) {
        .linux => std.posix.CLOCK.BOOTTIME,
        .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.MONOTONIC,
        else => std.posix.CLOCK.MONOTONIC,
    };
    const ts = std.posix.clock_gettime(clock_id) catch return error.TimerUnsupported;
    return (@as(u64, @intCast(ts.sec)) * std.time.ns_per_s) + @as(u64, @intCast(ts.nsec));
}

test "NonSuspendingTimer has std.time.Timer shape" {
    var timer = try NonSuspendingTimer.start();
    _ = timer.read();
    _ = timer.lap();
    timer.reset();
    _ = timer.read();
}
