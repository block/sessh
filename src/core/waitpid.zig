const std = @import("std");
const c = std.c;
const posix = std.posix;

// Zig 0.15 exposes WNOHANG through platform-specific surfaces, not as a stable
// cross-platform posix constant. The POSIX value is stable on sessh's supported
// Unix targets, so keep the numeric escape hatch in one auditable place.
pub const nohang: c_int = 1;

pub fn termFromStatus(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .Stopped = posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

test "termFromStatus decodes exit status" {
    const status: u32 = 7 << 8;
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 7 }, termFromStatus(status));
}
