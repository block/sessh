const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("app_allocator.zig");
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const pb = protocol.pb;
const hpb = protocol.hpb;

pub const OutputMode = enum {
    none,
    update,
    diagnostic_line,
};

pub const Capabilities = struct {
    output_mode: OutputMode,
    ctrl_r_available: bool,
};

pub const Diagnostic = struct {
    update: ?[]const u8 = null,
    diagnostic_line: ?[]const u8 = null,
    intercept_ctrl_r: bool,
};

pub const Message = union(enum) {
    diagnostic: Diagnostic,
    ctrl_r,
};

pub const OwnedMessage = struct {
    message: Message,
    owned_update: ?[]u8 = null,
    owned_diagnostic_line: ?[]u8 = null,

    pub fn deinit(self: *OwnedMessage, allocator: std.mem.Allocator) void {
        if (self.owned_update) |owned| allocator.free(owned);
        if (self.owned_diagnostic_line) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

// Establishes the generic compatibility handshake, then reads the visible
// client's capabilities as the first post-handshake proxy-control frame.
pub fn clientHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !Capabilities {
    try sendHelloRequest(fd);
    try readHelloOk(allocator, fd);

    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "proxy control client is incompatible with this sessh", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
    return readCapabilities(allocator, fd);
}

// Establishes the generic compatibility handshake, then sends the visible
// client's capabilities as the first post-handshake proxy-control frame.
pub fn serverHandshake(allocator: std.mem.Allocator, fd: c.fd_t, capabilities: Capabilities) !void {
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "proxy control server is incompatible with this sessh", "");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);

    try sendHelloRequest(fd);
    try readHelloOk(allocator, fd);
    try writeCapabilities(fd, capabilities);
}

fn writeCapabilities(fd: c.fd_t, capabilities: Capabilities) !void {
    try sendMessage(fd, .proxy_control_capabilities, pb.ProxyControlCapabilities{
        .output_mode = toPbOutputMode(capabilities.output_mode),
        .ctrl_r_available = capabilities.ctrl_r_available,
    });
}

pub fn writeDiagnostic(fd: c.fd_t, diagnostic: Diagnostic) !void {
    try sendMessage(fd, .proxy_control_diagnostic, pb.ProxyControlDiagnostic{
        .update = diagnostic.update,
        .diagnostic_line = diagnostic.diagnostic_line,
        .intercept_ctrl_r = diagnostic.intercept_ctrl_r,
    });
}

pub fn writeCtrlR(fd: c.fd_t) !void {
    try sendMessage(fd, .proxy_control_ctrl_r, pb.ProxyControlCtrlR{});
}

fn readCapabilities(allocator: std.mem.Allocator, fd: c.fd_t) !Capabilities {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);

        switch (frame.message_type) {
            .proxy_control_capabilities => {
                var message = try protocol.decodePayload(pb.ProxyControlCapabilities, allocator, frame.payload);
                defer message.deinit(allocator);
                return .{
                    .output_mode = fromPbOutputMode(message.output_mode),
                    .ctrl_r_available = message.ctrl_r_available,
                };
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            else => return error.UnexpectedProxyControlFrame,
        }
    }
}

pub fn readMessage(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedMessage {
    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);

    return switch (frame.message_type) {
        .proxy_control_diagnostic => blk: {
            var message = try protocol.decodePayload(pb.ProxyControlDiagnostic, allocator, frame.payload);
            defer message.deinit(allocator);

            const update = if (message.update) |line| try allocator.dupe(u8, line) else null;
            errdefer if (update) |owned| allocator.free(owned);
            const diagnostic_line = if (message.diagnostic_line) |line| try allocator.dupe(u8, line) else null;
            errdefer if (diagnostic_line) |owned| allocator.free(owned);

            break :blk OwnedMessage{
                .message = .{ .diagnostic = .{
                    .update = update,
                    .diagnostic_line = diagnostic_line,
                    .intercept_ctrl_r = message.intercept_ctrl_r,
                } },
                .owned_update = update,
                .owned_diagnostic_line = diagnostic_line,
            };
        },
        .proxy_control_ctrl_r => blk: {
            var message = try protocol.decodePayload(pb.ProxyControlCtrlR, allocator, frame.payload);
            defer message.deinit(allocator);
            break :blk OwnedMessage{ .message = .ctrl_r };
        },
        else => error.UnexpectedProxyControlFrame,
    };
}

fn sendMessage(fd: c.fd_t, message_type: protocol.MessageType, message: anytype) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, message_type, payload);
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
            .ping, .pong => {
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

fn toPbOutputMode(mode: OutputMode) pb.ProxyControlCapabilities.OutputMode {
    return switch (mode) {
        .none => .OUTPUT_MODE_NONE,
        .update => .OUTPUT_MODE_UPDATE,
        .diagnostic_line => .OUTPUT_MODE_DIAGNOSTIC_LINE,
    };
}

fn fromPbOutputMode(mode: pb.ProxyControlCapabilities.OutputMode) OutputMode {
    return switch (mode) {
        .OUTPUT_MODE_UPDATE => .update,
        .OUTPUT_MODE_DIAGNOSTIC_LINE => .diagnostic_line,
        .OUTPUT_MODE_NONE, _ => .none,
    };
}

test "proxy control protocol uses framed protobuf messages" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Server = struct {
        fn run(fd: c.fd_t) void {
            serverHandshake(std.testing.allocator, fd, .{
                .output_mode = .update,
                .ctrl_r_available = true,
            }) catch @panic("proxy control server handshake failed");
        }
    };
    const thread = try std.Thread.spawn(.{}, Server.run, .{fds[0]});
    const capabilities = try clientHandshake(std.testing.allocator, fds[1]);
    thread.join();
    try std.testing.expectEqual(OutputMode.update, capabilities.output_mode);
    try std.testing.expect(capabilities.ctrl_r_available);

    try writeDiagnostic(fds[0], .{ .update = "hello", .intercept_ctrl_r = true });
    try writeDiagnostic(fds[0], .{ .diagnostic_line = "ssh: nope", .intercept_ctrl_r = true });
    try writeDiagnostic(fds[0], .{ .intercept_ctrl_r = false });
    try writeCtrlR(fds[0]);

    var update = try readMessage(std.testing.allocator, fds[1]);
    defer update.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", update.message.diagnostic.update.?);
    try std.testing.expect(update.message.diagnostic.intercept_ctrl_r);

    var diagnostic = try readMessage(std.testing.allocator, fds[1]);
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ssh: nope", diagnostic.message.diagnostic.diagnostic_line.?);
    try std.testing.expect(diagnostic.message.diagnostic.intercept_ctrl_r);

    var clear = try readMessage(std.testing.allocator, fds[1]);
    defer clear.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), clear.message.diagnostic.update);
    try std.testing.expectEqual(@as(?[]const u8, null), clear.message.diagnostic.diagnostic_line);
    try std.testing.expect(!clear.message.diagnostic.intercept_ctrl_r);

    var ctrl_r = try readMessage(std.testing.allocator, fds[1]);
    defer ctrl_r.deinit(std.testing.allocator);
    try std.testing.expectEqual(Message.ctrl_r, ctrl_r.message);
}
