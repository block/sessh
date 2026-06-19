const std = @import("std");
const c = std.c;
const posix = std.posix;

pub fn closeInheritedNonStdioFileDescriptors() void {
    closeInheritedNonStdioFileDescriptorsExcept(-1);
}

pub fn closeInheritedNonStdioFileDescriptorsExcept(except_fd: c.fd_t) void {
    closeInheritedNonStdioFileDescriptorsExceptList(&.{except_fd});
}

pub fn closeInheritedNonStdioFileDescriptorsExceptList(except_fds: []const c.fd_t) void {
    const limit = inheritedFdCloseLimit();
    var fd: c.fd_t = 3;
    while (fd < limit) : (fd += 1) {
        if (fdIsExcepted(fd, except_fds)) continue;
        _ = c.close(fd);
    }
}

fn fdIsExcepted(fd: c.fd_t, except_fds: []const c.fd_t) bool {
    for (except_fds) |except_fd| {
        if (fd == except_fd) return true;
    }
    return false;
}

pub fn setNonBlocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = nonBlockingFlag();
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

pub fn nonBlockingFlag() c_int {
    return @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
}

pub const StatusFlagsGuard = struct {
    fd: c.fd_t,
    original: c_int,
    active: bool = false,

    // F_SETFL changes the open file description, not merely this process's fd
    // table entry. Use this guard when temporarily putting inherited descriptors
    // such as stdin into non-blocking mode so the caller's terminal/shell does
    // not inherit EAGAIN-producing state after sessh exits normally.
    pub fn setNonBlocking(fd: c.fd_t) !StatusFlagsGuard {
        const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.FcntlFailed;
        const nonblocking_flag = nonBlockingFlag();
        if ((flags & nonblocking_flag) != 0) return .{ .fd = fd, .original = flags };
        if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
        return .{ .fd = fd, .original = flags, .active = true };
    }

    pub fn restore(self: *StatusFlagsGuard) void {
        if (!self.active) return;
        _ = c.fcntl(self.fd, c.F.SETFL, self.original);
        self.active = false;
    }
};

fn inheritedFdCloseLimit() c.fd_t {
    const fallback: c.fd_t = 1024;
    const max_reasonable: u64 = 65_536;
    const limits = posix.getrlimit(.NOFILE) catch return fallback;
    if (limits.cur <= 3) return 3;
    const capped = @min(limits.cur, max_reasonable);
    return @intCast(capped);
}
