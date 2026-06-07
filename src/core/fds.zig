const std = @import("std");
const c = std.c;
const posix = std.posix;

pub fn closeInheritedNonStdioFileDescriptors() void {
    const limit = inheritedFdCloseLimit();
    var fd: c.fd_t = 3;
    while (fd < limit) : (fd += 1) {
        _ = c.close(fd);
    }
}

fn inheritedFdCloseLimit() c.fd_t {
    const fallback: c.fd_t = 1024;
    const max_reasonable: u64 = 65_536;
    const limits = posix.getrlimit(.NOFILE) catch return fallback;
    if (limits.cur <= 3) return 3;
    const capped = @min(limits.cur, max_reasonable);
    return @intCast(capped);
}
