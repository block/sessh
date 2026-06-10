const std = @import("std");
const builtin = @import("builtin");

// Process-independent monotonic time for same-machine IPC deadlines.
//
// This intentionally is not `std.time.Timer`: Timer reports elapsed time since a
// particular process created the timer, so its values cannot be compared across
// a visible client and daemon. These readings come from an OS clock with a
// machine-wide epoch and are suitable for local client/daemon/control messages.
pub fn nowMs() u64 {
    const clock_id = switch (builtin.os.tag) {
        .linux => std.posix.CLOCK.BOOTTIME,
        .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.UPTIME_RAW,
        else => std.posix.CLOCK.MONOTONIC,
    };
    const ts = std.posix.clock_gettime(clock_id) catch return @intCast(std.time.milliTimestamp());
    return (@as(u64, @intCast(ts.sec)) * std.time.ms_per_s) + @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
}
