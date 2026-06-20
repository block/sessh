const std = @import("std");
const c = std.c;
const posix = std.posix;

const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");

pub const ready_fd_env = "SESSH_DAEMON_READY_FD";
pub const startup_lock_fd_env = "SESSH_DAEMON_STARTUP_LOCK_FD";

const startup_lock_wait_timeout_ms: u64 = 1_000;
const startup_lock_retry_ms: u64 = 25;
const daemon_ready_wait_timeout_ms: u64 = 1_000;

// Daemon startup has one unavoidable foreground wait: a client may need to
// pause until another process finishes starting the daemon. That client has no
// other work to service yet, so a bounded synchronous wait is acceptable here.
// The daemon-ready path uses a pipe. The flock-contention path sleeps briefly
// between non-blocking lock attempts because POSIX flock does not provide a
// portable readiness fd or timeout.
pub const ReadyPipe = struct {
    read_fd: c.fd_t,
    write_fd: c.fd_t,

    pub fn init() !ReadyPipe {
        const fds = try posix.pipe();
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        try socket_transport.setCloseOnExec(fds[0]);
        try socket_transport.clearCloseOnExec(fds[1]);
        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
        };
    }

    pub fn closeWrite(self: *ReadyPipe) void {
        if (self.write_fd >= 0) {
            _ = c.close(self.write_fd);
            self.write_fd = -1;
        }
    }

    pub fn deinit(self: *ReadyPipe) void {
        if (self.read_fd >= 0) {
            _ = c.close(self.read_fd);
            self.read_fd = -1;
        }
        self.closeWrite();
    }
};

pub const StartupLock = struct {
    file: std.fs.File,

    pub fn deinit(self: *StartupLock) void {
        std.posix.flock(self.file.handle, std.posix.LOCK.UN) catch {};
        self.file.close();
        self.* = undefined;
    }
};

pub fn tryAcquireStartupLock(allocator: std.mem.Allocator, dir_name: []const u8) !?StartupLock {
    const lock_path = try socket_namespace.startupLockPath(allocator, dir_name);
    defer allocator.free(lock_path);
    try socket_transport.ensureSocketDir(allocator, lock_path);

    var file = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer file.close();
    try socket_transport.setCloseOnExec(file.handle);
    std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    return .{ .file = file };
}

/// Foreground client startup only: if another process owns startup, let that
/// process finish creating the daemon and wait briefly for the lock to clear.
/// A one-second wait is intentionally strict; longer means the startup owner
/// died or wedged before the daemon became ready.
///
/// BLOCKING_WAIT: this runs before the caller has a daemon connection or any
/// process event loop work to service. A simple bounded sleep loop is more
/// direct than building a one-off Dispatcher for this foreground startup path.
pub fn waitForStartupLockRelease(allocator: std.mem.Allocator, dir_name: []const u8) !void {
    var timer = try NonSuspendingTimer.start();
    while (true) {
        if (try tryAcquireStartupLock(allocator, dir_name)) |lock_value| {
            var lock = lock_value;
            lock.deinit();
            return;
        }

        const elapsed_ms = @divTrunc(timer.read(), std.time.ns_per_ms);
        if (elapsed_ms >= startup_lock_wait_timeout_ms) return error.DaemonStartupTimedOut;

        const remaining_ms = startup_lock_wait_timeout_ms - elapsed_ms;
        const sleep_ms: u64 = @min(startup_lock_retry_ms, remaining_ms);
        posix.nanosleep(0, sleep_ms * std.time.ns_per_ms);
    }
}

/// BLOCKING_POLL: foreground daemon startup waits for one byte on the inherited
/// ready pipe. This is not daemon event-loop work; it is the caller waiting for the
/// daemon process it just spawned to begin listening.
pub fn waitForReady(pipe: *const ReadyPipe) !WaitResult {
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe.read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, daemon_ready_wait_timeout_ms);
    if (ready == 0) return .timed_out;

    if ((pollfds[0].revents & posix.POLL.IN) != 0) {
        var buf: [8]u8 = undefined;
        while (true) {
            const n = c.read(pipe.read_fd, &buf, buf.len);
            if (n > 0) return .ready;
            if (n == 0) return .closed;
            switch (posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return .timed_out,
                else => return .closed,
            }
        }
    }

    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) return .closed;
    return .timed_out;
}

pub fn addReadyFdToEnvMap(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    fd: c.fd_t,
) !void {
    const value = try std.fmt.allocPrint(allocator, "{}", .{fd});
    defer allocator.free(value);
    try env_map.put(ready_fd_env, value);
}

pub fn addStartupLockFdToEnvMap(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    fd: c.fd_t,
) !void {
    const value = try std.fmt.allocPrint(allocator, "{}", .{fd});
    defer allocator.free(value);
    try env_map.put(startup_lock_fd_env, value);
}

pub fn inheritedReadyFd() c.fd_t {
    const value_z = c.getenv(ready_fd_env) orelse return -1;
    const value = std.mem.span(value_z);
    const fd = std.fmt.parseInt(c.fd_t, value, 10) catch return -1;
    if (fd < 3) return -1;
    return fd;
}

pub fn inheritedStartupLockFd() c.fd_t {
    const value_z = c.getenv(startup_lock_fd_env) orelse return -1;
    const value = std.mem.span(value_z);
    const fd = std.fmt.parseInt(c.fd_t, value, 10) catch return -1;
    if (fd < 3) return -1;
    return fd;
}

pub fn signalReady(fd: *c.fd_t) void {
    if (fd.* < 0) return;
    const byte = [_]u8{1};
    _ = c.write(fd.*, &byte, byte.len);
    _ = c.close(fd.*);
    fd.* = -1;
}

pub fn closeStartupLockFd(fd: *c.fd_t) void {
    if (fd.* < 0) return;
    std.posix.flock(fd.*, std.posix.LOCK.UN) catch {};
    _ = c.close(fd.*);
    fd.* = -1;
}

pub const WaitResult = enum {
    ready,
    closed,
    timed_out,
};
