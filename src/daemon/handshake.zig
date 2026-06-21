// Local-client handshake helpers for sesshd IPC. The compatibility check is
// deliberately small and foreground-oriented so callers can fail before handing
// a socket to a long-lived daemon route.
const std = @import("std");
const c = std.c;

const config = @import("../core/config.zig");
const protocol = @import("../protocol/mod.zig");
const foreground_frame_io = @import("../transport/foreground_frame_io.zig");

const hpb = protocol.hpb;

fn sendHelloRequestForeground(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(allocator, hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer allocator.free(payload);
    try foreground_frame_io.writeFrame(.{
        .allocator = allocator,
        .fd = fd,
        .message_type = .hello_request,
        .payload = payload,
    });
}

fn sendHelloOkForeground(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(allocator, hpb.HelloOk{});
    defer allocator.free(payload);
    try foreground_frame_io.writeFrame(.{
        .allocator = allocator,
        .fd = fd,
        .message_type = .hello_ok,
        .payload = payload,
    });
}

fn sendHelloErrorForeground(allocator: std.mem.Allocator, fd: c.fd_t, info: protocol.ErrorInfo) !void {
    const payload = try protocol.encodePayload(allocator, hpb.HelloError{
        .code = info.code,
        .message = info.message,
        .hint = info.hint,
    });
    defer allocator.free(payload);
    try foreground_frame_io.writeFrame(.{
        .allocator = allocator,
        .fd = fd,
        .message_type = .hello_error,
        .payload = payload,
    });
}

pub fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

// foreground daemon client handshakes happen before the
// caller enters its long-lived daemon protocol. Keep the synchronous handshake
// shape, but route all frame IO through the shared foreground helpers so this
// setup-only poll loop stays explicit and auditable.
pub fn initiateForegroundClientHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequestForeground(allocator, fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.DaemonHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloErrorForeground(allocator, fd, .{
            .code = "VERSION_MISMATCH",
            .message = "sesshd is incompatible with this client",
        });
        return error.VersionMismatch;
    }
    try sendHelloOkForeground(allocator, fd);
}

fn readHelloRequest(allocator: std.mem.Allocator, fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try readFrameForForegroundHandshake(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            else => {
                try sendHelloErrorForeground(allocator, fd, .{
                    .code = "PROTOCOL_ERROR",
                    .message = "expected HELLO_REQUEST",
                });
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try readFrameForForegroundHandshake(allocator, fd);
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

fn readFrameForForegroundHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    return foreground_frame_io.readFrame(.{
        .allocator = allocator,
        .fd = fd,
    });
}

test "foreground client handshake uses hello exchange" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const fds = try protocol_test_helpers.socketPairForTest();
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    const TestPeer = struct {
        fd: c.fd_t,
        err: ?anyerror = null,

        fn run(peer: *@This()) void {
            peer.runInner() catch |err| {
                peer.err = err;
            };
        }

        fn runInner(peer: *@This()) !void {
            var client_hello = try protocol_test_helpers.readFrameForTest(std.testing.allocator, peer.fd);
            defer client_hello.deinit(std.testing.allocator);
            if (client_hello.message_type != .hello_request) return error.UnexpectedFrame;

            try sendHelloOkForeground(std.testing.allocator, peer.fd);
            try sendHelloRequestForeground(std.testing.allocator, peer.fd);

            var client_ok = try protocol_test_helpers.readFrameForTest(std.testing.allocator, peer.fd);
            defer client_ok.deinit(std.testing.allocator);
            if (client_ok.message_type != .hello_ok) return error.UnexpectedFrame;
        }
    };

    var peer = TestPeer{ .fd = fds[1] };
    var peer_thread = try std.Thread.spawn(.{}, TestPeer.run, .{&peer});
    defer peer_thread.join();

    try initiateForegroundClientHandshake(std.testing.allocator, fds[0]);
    if (peer.err) |err| return err;
}
