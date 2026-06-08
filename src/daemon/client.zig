const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");

const hpb = protocol.hpb;

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
    if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}

    const argv = [_][]const u8{ exe, ":internal-daemon:", dir_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}
        io.sleepMillis(20);
    }
    return error.DaemonDidNotStart;
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
