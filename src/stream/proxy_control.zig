const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const protocol = @import("../protocol/mod.zig");
const pb = protocol.pb;
const hpb = protocol.hpb;

pub const Message = union(enum) {
    connection_event: pb.ConnectionEvent,
    retry_now,
};

pub const OwnedMessage = struct {
    message: Message,

    pub fn deinit(self: *OwnedMessage, allocator: std.mem.Allocator) void {
        switch (self.message) {
            .connection_event => |*event| event.deinit(allocator),
            .retry_now => {},
        }
        self.* = undefined;
    }
};

pub fn clientHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    try readHelloOk(allocator, fd);

    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "proxy control client is incompatible with this sessh", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
}

pub fn serverHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "proxy control server is incompatible with this sessh", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);

    try sendHelloRequest(fd);
    try readHelloOk(allocator, fd);
}

pub fn writeConnectionEvent(fd: c.fd_t, event: pb.ConnectionEvent.event_union) !void {
    try protocol.sendClientDaemonConnectionEventFrame(app_allocator.allocator(), fd, event);
}

pub fn writeRetryNow(fd: c.fd_t) !void {
    try protocol.sendClientDaemonPayloadFrame(app_allocator.allocator(), fd, .{ .retry_now = .{} });
}

pub fn readMessage(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedMessage {
    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);

    if (frame.message_type != .client_daemon) return error.UnexpectedProxyControlFrame;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse return error.UnexpectedProxyControlFrame;
    return switch (item_payload) {
        .connection_event => |event| blk: {
            break :blk OwnedMessage{ .message = .{ .connection_event = try event.dupe(allocator) } };
        },
        .retry_now => OwnedMessage{ .message = .retry_now },
        else => error.UnexpectedProxyControlFrame,
    };
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

fn readHelloOk(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
                defer ok.deinit(allocator);
                return;
            },
            .hello_error => {
                var err = try protocol.decodePayload(hpb.HelloError, allocator, frame.payload);
                defer err.deinit(allocator);
                return error.PeerRejectedProxyControlHandshake;
            },
            else => return error.UnexpectedProxyControlFrame,
        }
    }
}

fn readHelloRequest(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            .daemon_tunnel => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            else => {
                try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedProxyControlFrame;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

test "proxy control protocol uses framed protobuf messages" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Server = struct {
        fn run(fd: c.fd_t) void {
            serverHandshake(std.testing.allocator, fd) catch @panic("proxy control server handshake failed");
        }
    };
    const thread = try std.Thread.spawn(.{}, Server.run, .{fds[0]});
    try clientHandshake(std.testing.allocator, fds[1]);
    thread.join();

    try writeConnectionEvent(fds[0], .{ .daemon_disconnected = .{
        .retry_at_local_boot_time_ms = 1234,
    } });
    try writeConnectionEvent(fds[0], .{ .ssh_stderr = .{ .data = "ssh: nope" } });
    try writeConnectionEvent(fds[0], .{ .daemon_connected = .{} });
    try writeRetryNow(fds[0]);

    var disconnected = try readMessage(std.testing.allocator, fds[1]);
    defer disconnected.deinit(std.testing.allocator);
    switch (disconnected.message.connection_event.event.?) {
        .daemon_disconnected => |event| try std.testing.expectEqual(@as(?u64, 1234), event.retry_at_local_boot_time_ms),
        else => return error.UnexpectedProxyControlFrame,
    }

    var stderr = try readMessage(std.testing.allocator, fds[1]);
    defer stderr.deinit(std.testing.allocator);
    switch (stderr.message.connection_event.event.?) {
        .ssh_stderr => |event| try std.testing.expectEqualStrings("ssh: nope", event.data),
        else => return error.UnexpectedProxyControlFrame,
    }

    var connected = try readMessage(std.testing.allocator, fds[1]);
    defer connected.deinit(std.testing.allocator);
    switch (connected.message.connection_event.event.?) {
        .daemon_connected => {},
        else => return error.UnexpectedProxyControlFrame,
    }

    var retry_now = try readMessage(std.testing.allocator, fds[1]);
    defer retry_now.deinit(std.testing.allocator);
    try std.testing.expectEqual(Message.retry_now, retry_now.message);
}
