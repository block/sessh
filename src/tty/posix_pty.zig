const std = @import("std");
const c = std.c;
const posix = std.posix;

// Keep the libutil/termios PTY ABI boundary here so higher-level terminal and
// diagnostics code works with fd-shaped helpers instead of repeating C
// declarations and null-terminated pointer handling.
extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
extern "c" fn ttyname(fd: c_int) ?[*:0]u8;

pub const Pair = struct {
    master_fd: c.fd_t = -1,
    slave_fd: c.fd_t = -1,

    pub fn close(self: *Pair) void {
        if (self.master_fd >= 0) {
            posix.close(self.master_fd);
            self.master_fd = -1;
        }
        if (self.slave_fd >= 0) {
            posix.close(self.slave_fd);
            self.slave_fd = -1;
        }
    }
};

pub fn open() !Pair {
    var master_fd: c.fd_t = -1;
    var slave_fd: c.fd_t = -1;
    if (openpty(&master_fd, &slave_fd, null, null, null) != 0) return error.OpenPtyFailed;
    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
    };
}

pub fn nameZ(fd: c.fd_t) ?[*:0]u8 {
    return ttyname(fd);
}

pub fn name(fd: c.fd_t) ?[]const u8 {
    const path_z = nameZ(fd) orelse return null;
    return std.mem.span(path_z);
}
