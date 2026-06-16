const std = @import("std");
const non_suspending_timer = @import("non_suspending_timer.zig");

// Process-independent monotonic time for same-machine IPC deadlines.
//
// This intentionally is not `std.time.Timer` or `NonSuspendingTimer`: those
// report elapsed time since a particular process created a timer, so their
// values cannot be compared across a visible client and daemon. These readings
// come from the same suspend-inclusive OS clock, but use its machine-wide epoch.
pub fn nowMs() u64 {
    return non_suspending_timer.nowMs() catch @intCast(std.time.milliTimestamp());
}
