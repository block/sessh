const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const daemon_executable = @import("executable.zig");
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_name = try socket_namespace.defaultDirName(allocator);
    defer allocator.free(dir_name);
    return socketPathForDirName(allocator, dir_name);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return socket_namespace.socketPath(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    const path = try socketPath(allocator);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    const fd = try connectOrStart(allocator, exe);
    defer _ = c.close(fd);
    try protocol.sendPing(fd);
    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    if (frame.message_type != .pong) return error.UnexpectedDaemonFrame;
}

pub fn connectOrStart(allocator: std.mem.Allocator, exe: []const u8) !c.fd_t {
    const dir_name = try socket_namespace.defaultDirName(allocator);
    defer allocator.free(dir_name);
    return connectOrStartForDirName(allocator, exe, dir_name);
}

pub fn connectOrStartForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !c.fd_t {
    var spawned = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (!spawned) {
            spawned = try spawnDaemonIfNamespaceUnlocked(allocator, exe, dir_name);
        }
        if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}
        io.sleepMillis(20);
    }
    return error.DaemonDidNotStart;
}

fn spawnDaemonIfNamespaceUnlocked(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !bool {
    var runtime_executables = (try daemon_executable.installRuntimeExecutablesForDaemonStart(allocator, exe, dir_name)) orelse return false;
    defer runtime_executables.deinit();
    const argv = [_][]const u8{ runtime_executables.daemon, dir_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    return true;
}

pub fn printDaemonLog(allocator: std.mem.Allocator, exe: []const u8) !void {
    const dir_name = try socket_namespace.defaultDirName(allocator);
    defer allocator.free(dir_name);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);

    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
    try io.writeAll(posix.STDOUT_FILENO, "daemon socket ");
    try io.writeAll(posix.STDOUT_FILENO, path);
    try io.writeAll(posix.STDOUT_FILENO, "\n");

    const request_payload = try protocol.encodePayload(allocator, pb.DaemonLogRequest{});
    defer allocator.free(request_payload);
    try protocol.sendFrame(fd, .daemon_log_request, request_payload);

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .daemon_log_entry => {
                var entry = try protocol.decodePayload(pb.DaemonLogEntry, allocator, frame.payload);
                defer entry.deinit(allocator);
                const line = try daemonLogLine(allocator, entry.unix_ms, entry.message);
                defer allocator.free(line);
                try io.writeAll(posix.STDOUT_FILENO, line);
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
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
    const dir_name = try socket_namespace.defaultDirName(allocator);
    defer allocator.free(dir_name);
    return connectAndHandshakeForDirName(allocator, dir_name);
}

pub fn connectAndHandshakeForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    const fd = try socket_transport.connectSocket(path);
    errdefer _ = c.close(fd);
    try initiateHandshake(allocator, fd);
    return fd;
}

pub fn initiateHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.DaemonHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
}

fn readHelloRequest(allocator: std.mem.Allocator, fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            else => {
                try sendHelloError(fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
                defer ok.deinit(allocator);
                return null;
            },
            .hello_error => {
                const err = try protocol.decodePayload(hpb.HelloError, allocator, frame.payload);
                return err;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}
