const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const OwnedFd = struct {
    fd: c.fd_t = -1,

    pub fn init(fd: c.fd_t) OwnedFd {
        return .{ .fd = fd };
    }

    pub fn deinit(self: *OwnedFd) void {
        if (self.fd < 0) return;
        _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn get(self: OwnedFd) c.fd_t {
        return self.fd;
    }

    pub fn take(self: *OwnedFd) c.fd_t {
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }
};

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

pub fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const close_on_exec_flag = @as(c_int, @intCast(c.FD_CLOEXEC));
    if ((flags & close_on_exec_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFD, flags | close_on_exec_flag) < 0) return error.FcntlFailed;
}

pub fn clearCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const close_on_exec_flag = @as(c_int, @intCast(c.FD_CLOEXEC));
    if ((flags & close_on_exec_flag) == 0) return;
    if (c.fcntl(fd, c.F.SETFD, flags & ~close_on_exec_flag) < 0) return error.FcntlFailed;
}

fn nonBlockingFlag() c_int {
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

test "OwnedFd take transfers close responsibility" {
    const pipe_fds = try posix.pipe();
    var read_end = OwnedFd.init(pipe_fds[0]);
    defer read_end.deinit();
    defer posix.close(pipe_fds[1]);

    const taken = read_end.take();
    defer posix.close(taken);
    try std.testing.expectEqual(@as(c.fd_t, -1), read_end.get());
}

test "close-on-exec helpers update descriptor flags" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    try clearCloseOnExec(pipe_fds[0]);
    try std.testing.expect(!try closeOnExecSet(pipe_fds[0]));

    try setCloseOnExec(pipe_fds[0]);
    try std.testing.expect(try closeOnExecSet(pipe_fds[0]));

    try clearCloseOnExec(pipe_fds[0]);
    try std.testing.expect(!try closeOnExecSet(pipe_fds[0]));
}

fn closeOnExecSet(fd: c.fd_t) !bool {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    return (flags & @as(c_int, @intCast(c.FD_CLOEXEC))) != 0;
}
