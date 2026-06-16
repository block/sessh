const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const daemon_executable = @import("executable.zig");
const daemon_handshake = @import("handshake.zig");
const socket_namespace = @import("socket_namespace.zig");
const daemon_startup = @import("startup.zig");
const socket_transport = @import("../transport/socket.zig");

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return socketPathForDirName(allocator, dir_name);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return socket_namespace.socketPath(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return connectForDirName(allocator, dir_name);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    const fd = try connectOrStart(allocator, exe);
    defer _ = c.close(fd);
}

pub fn ensureStartedForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !void {
    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
}

pub fn connectOrStart(allocator: std.mem.Allocator, exe: []const u8) !c.fd_t {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return connectOrStartForDirName(allocator, exe, dir_name);
}

// Foreground startup path shared by sessh, sesshd reexec helpers, and proxy
// roles. It owns the daemon startup lock/ready-pipe choreography so daemon
// runtime code does not duplicate client-side spawn behavior.
pub fn connectOrStartForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !c.fd_t {
    if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}

    var startup_lock = (try daemon_startup.tryAcquireStartupLock(allocator, dir_name)) orelse {
        try daemon_startup.waitForStartupLockRelease(allocator, dir_name);
        return connectAndHandshakeForDirName(allocator, dir_name);
    };
    defer startup_lock.deinit();

    if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}

    var pipe = try daemon_startup.ReadyPipe.init();
    defer pipe.deinit();
    if (!try spawnDaemonIfNamespaceUnlocked(allocator, exe, dir_name, pipe.write_fd, startup_lock.file.handle)) {
        return error.DaemonDidNotStart;
    }
    pipe.closeWrite();
    switch (try daemon_startup.waitForReady(pipe.read_fd)) {
        .ready => return connectAndHandshakeForDirName(allocator, dir_name),
        .closed, .timed_out => return error.DaemonDidNotStart,
    }
}

fn spawnDaemonIfNamespaceUnlocked(
    allocator: std.mem.Allocator,
    exe: []const u8,
    dir_name: []const u8,
    ready_fd: c.fd_t,
    startup_lock_fd: c.fd_t,
) !bool {
    var runtime_executables = (try daemon_executable.installRuntimeExecutablesForDaemonStart(allocator, exe, dir_name)) orelse return false;
    defer runtime_executables.deinit();
    const argv = [_][]const u8{ runtime_executables.daemon, dir_name };
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try daemon_startup.addReadyFdToEnvMap(allocator, &env_map, ready_fd);
    try daemon_startup.addStartupLockFdToEnvMap(allocator, &env_map, startup_lock_fd);
    try socket_transport.clearCloseOnExec(startup_lock_fd);
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = &env_map;
    child.pgid = 0;
    try child.spawn();
    return true;
}

pub fn printDaemonLog(allocator: std.mem.Allocator, exe: []const u8) !void {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);

    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
    try io.writeAll(posix.STDOUT_FILENO, "daemon socket ");
    try io.writeAll(posix.STDOUT_FILENO, path);
    try io.writeAll(posix.STDOUT_FILENO, "\n");

    try protocol.sendDaemonLogRequestFrame(allocator, fd, .{});

    while (true) {
        var frame = readDaemonLogFrameBlocking(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .client_daemon => {
                var entry = try protocol.decodeClientDaemonLogEntry(allocator, frame.payload);
                defer entry.deinit(allocator);
                const line = try daemonLogLine(allocator, entry.unix_ms, entry.message);
                defer allocator.free(line);
                try io.writeAll(posix.STDOUT_FILENO, line);
            },
            else => return error.UnexpectedDaemonFrame,
        }
    }
}

fn daemonLogLine(allocator: std.mem.Allocator, unix_ms: i64, message: []const u8) ![]u8 {
    var timestamp_buf: [daemon_log_timestamp_len]u8 = undefined;
    if (formatDaemonLogTimestamp(&timestamp_buf, unix_ms)) |timestamp| {
        return std.fmt.allocPrint(allocator, "{s} {s}\n", .{ timestamp, message });
    } else |_| {
        return std.fmt.allocPrint(allocator, "{} {s}\n", .{ unix_ms, message });
    }
}

const daemon_log_timestamp_len = "00:00:00.000".len;

const LocalTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};

extern "c" fn localtime_r(timer: *const c.time_t, result: *LocalTm) ?*LocalTm;

fn formatDaemonLogTimestamp(buf: *[daemon_log_timestamp_len]u8, unix_ms: i64) ![]const u8 {
    const seconds_i64 = @divFloor(unix_ms, 1000);
    const milliseconds_i64 = @mod(unix_ms, 1000);
    const seconds = std.math.cast(c.time_t, seconds_i64) orelse return error.TimestampOutOfRange;
    const milliseconds = std.math.cast(u16, milliseconds_i64) orelse return error.TimestampOutOfRange;

    var local_time: LocalTm = undefined;
    if (localtime_r(&seconds, &local_time) == null) return error.TimestampOutOfRange;
    return formatDaemonLogTimestampParts(buf, local_time, milliseconds);
}

fn formatDaemonLogTimestampParts(buf: *[daemon_log_timestamp_len]u8, local_time: LocalTm, milliseconds: u16) ![]const u8 {
    const hour = std.math.cast(u8, local_time.tm_hour) orelse return error.InvalidLocalTime;
    const minute = std.math.cast(u8, local_time.tm_min) orelse return error.InvalidLocalTime;
    const second = std.math.cast(u8, local_time.tm_sec) orelse return error.InvalidLocalTime;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        hour,
        minute,
        second,
        milliseconds,
    });
}

// BLOCKING_FRAME_READ: `sessh --daemon-log` is an explicit foreground log
// subscriber. It intentionally waits for future log entries on stdout and is
// not used by the daemon, pooled transport, or session runtime.
fn readDaemonLogFrameBlocking(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked => return error.WouldBlock,
            .progress => continue,
            .frame => |frame| return frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
}

test "daemon log timestamp uses readable milliseconds" {
    var local_time = std.mem.zeroes(LocalTm);
    local_time.tm_hour = 3;
    local_time.tm_min = 4;
    local_time.tm_sec = 5;
    var buf: [daemon_log_timestamp_len]u8 = undefined;
    const text = try formatDaemonLogTimestampParts(&buf, local_time, 7);
    try std.testing.expectEqualStrings("03:04:05.007", text);
}

pub fn connectAndHandshake(allocator: std.mem.Allocator) !c.fd_t {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return connectAndHandshakeForDirName(allocator, dir_name);
}

pub fn connectForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

pub fn connectAndHandshakeForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const fd = try connectForDirName(allocator, dir_name);
    errdefer _ = c.close(fd);
    try daemon_handshake.initiateForegroundClientHandshake(allocator, fd);
    return fd;
}
