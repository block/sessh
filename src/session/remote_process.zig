const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const process_wait = @import("../core/waitpid.zig");
const pty_process = @import("../tty/pty_process.zig");
const terminal = @import("../tty/terminal.zig");

pub const pty_hangup_reap_poll_ms: i64 = 50;

pub const ExitInfo = struct {
    kind: u8 = 0,
    status: i32 = 0,
    ended_at_unix_ms: u64 = 0,
};

pub const PollExitResult = union(enum) {
    running,
    interrupted,
    failed,
    exited: ExitInfo,
};

pub const Process = struct {
    pid: c.pid_t = 0,
    pty_fd: c.fd_t = -1,
    pty_closed_for_hangup: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, options: pty_process.SpawnOptions) !Process {
        const pty = try pty_process.spawn(allocator, options);
        errdefer posix.close(pty.master_fd);
        try core_fds.setNonBlocking(pty.master_fd);
        return .{
            .pid = pty.pid,
            .pty_fd = pty.master_fd,
        };
    }

    pub fn hasOpenPty(self: *const Process) bool {
        return self.pty_fd >= 0;
    }

    pub fn setPtySize(self: *const Process, size: terminal.WindowSize) void {
        if (self.pty_fd >= 0) _ = terminal.setPtySize(self.pty_fd, size);
    }

    pub fn closePty(self: *Process) void {
        if (self.pty_fd >= 0) {
            _ = c.close(self.pty_fd);
            self.pty_fd = -1;
        }
    }

    pub fn closePtyForHangup(self: *Process) void {
        self.closePty();
        self.pty_closed_for_hangup = true;
    }

    pub fn writeSomeInput(self: *const Process, bytes: []const u8) !io.WriteSomeResult {
        return io.writeSomeNonBlocking(self.pty_fd, bytes);
    }
};

pub fn reapPid(pid: c.pid_t) bool {
    if (pid <= 0) return true;
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, process_wait.nohang);
    if (result == pid) return true;
    if (result < 0) return switch (posix.errno(result)) {
        .CHILD => true,
        else => false,
    };
    return false;
}

pub fn waitForExitInfo(pid: c.pid_t, now_unix_ms: u64) ?ExitInfo {
    return switch (pollExit(pid, now_unix_ms)) {
        .exited => |exit_info| exit_info,
        else => null,
    };
}

pub fn pollExit(pid: c.pid_t, now_unix_ms: u64) PollExitResult {
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, process_wait.nohang);
    if (result == pid) return .{ .exited = exitInfoFromWaitStatus(status, now_unix_ms) };
    if (result < 0) {
        return switch (posix.errno(result)) {
            .INTR => .interrupted,
            else => .failed,
        };
    }
    return .running;
}

fn exitInfoFromWaitStatus(status: c_int, now_unix_ms: u64) ExitInfo {
    const raw: u32 = @bitCast(status);
    const signal_number = raw & 0x7f;
    if (signal_number == 0) {
        return .{
            .kind = 1,
            .status = @intCast((raw >> 8) & 0xff),
            .ended_at_unix_ms = now_unix_ms,
        };
    }
    return .{
        .kind = 2,
        .status = @intCast(signal_number),
        .ended_at_unix_ms = now_unix_ms,
    };
}
