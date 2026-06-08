const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const daemon_log = @import("log.zig");
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");
const stream_runtime = @import("../stream/runtime.zig");
const transport_ssh = @import("../transport/ssh.zig");

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
    const dir_name = try socket_namespace.defaultDirName(allocator);
    defer allocator.free(dir_name);
    return ensureStartedForDirName(allocator, exe, dir_name);
}

fn ensureStartedForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !void {
    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
    try protocol.sendPing(fd);
    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    if (frame.message_type != .pong) return error.UnexpectedDaemonFrame;
}

pub fn forwardBrokerToDaemon(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try io.writeAll(2, "sessh: :internal-broker: accepts at most one daemon socket namespace\n");
        return error.InvalidBrokerArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.defaultDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    try ensureStartedForDirName(allocator, exe, dir_name);
    const fd = try connectForDirName(allocator, dir_name);
    defer _ = c.close(fd);
    try forwardBrokerFramesToDaemon(allocator, 0, 1, fd);
}

fn connectOrStartForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !c.fd_t {
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

fn connectForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

fn connectAndHandshakeForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const fd = try connectForDirName(allocator, dir_name);
    errdefer _ = c.close(fd);
    try initiateHandshake(allocator, fd);
    return fd;
}

fn forwardBrokerFramesToDaemon(
    allocator: std.mem.Allocator,
    stdin_fd: c.fd_t,
    stdout_fd: c.fd_t,
    daemon_fd: c.fd_t,
) !void {
    defer {
        _ = c.shutdown(stdin_fd, c.SHUT.WR);
        if (stdout_fd != stdin_fd) _ = c.shutdown(stdout_fd, c.SHUT.WR);
        _ = c.shutdown(daemon_fd, c.SHUT.WR);
    }

    var pollfds = [_]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = daemon_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = try std.posix.poll(&pollfds, -1);

        if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!try copyClientFrameToDaemon(allocator, stdin_fd, daemon_fd)) return;
        }
        if ((pollfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            if (!try copyFrame(allocator, daemon_fd, stdout_fd)) return;
        }
    }
}

fn copyClientFrameToDaemon(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var frame = protocol.readFrameAlloc(allocator, read_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);

    if (frame.message_type == .te_stream_open) {
        const payload = try session_daemon_handler.sessionOpenPayloadWithCurrentEnvironment(allocator, frame.payload);
        defer allocator.free(payload);
        try protocol.sendFrame(write_fd, frame.message_type, payload);
        return true;
    }

    try protocol.sendFrame(write_fd, frame.message_type, frame.payload);
    return true;
}

fn copyFrame(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var frame = protocol.readFrameAlloc(allocator, read_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);
    try protocol.sendFrame(write_fd, frame.message_type, frame.payload);
    return true;
}

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    core_fds.closeInheritedNonStdioFileDescriptors();

    if (args.len > 1) {
        try io.writeAll(2, "sessh: :internal-daemon: accepts at most one daemon socket namespace\n");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.defaultDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    const daemon_exe = try allocator.dupe(u8, exe);
    defer allocator.free(daemon_exe);

    socket_transport.publishRuntimeRootSymlinkOnce(allocator);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);

    if (socket_transport.connectSocket(path)) |fd| {
        _ = c.close(fd);
        return error.DaemonAlreadyRunning;
    } else |_| {}

    const listen_fd = try socket_transport.listenSocket(path);
    defer _ = c.close(listen_fd);
    daemon_log.infof(allocator, "daemon started socket={s}", .{path});

    var daemon_dispatcher = try dispatcher.Dispatcher.init(allocator);
    defer daemon_dispatcher.deinit();

    var accept_context = DaemonAcceptContext{
        .allocator = allocator,
        .exe = daemon_exe,
        .listen_fd = listen_fd,
    };
    _ = try daemon_dispatcher.watchFd(listen_fd, .{ .readable = true }, .{
        .ctx = &accept_context,
        .callback = acceptDaemonClient,
    });
    try daemon_dispatcher.run();
}

const DaemonAcceptContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    listen_fd: c.fd_t,
};

fn acceptDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = daemon_dispatcher;
    _ = id;
    const accept_context: *DaemonAcceptContext = @ptrCast(@alignCast(ctx));

    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonTimer,
    };
    if (fd_event.error_event or fd_event.invalid) return error.DaemonListenFailed;
    if (!fd_event.readable) return;

    const client_fd = c.accept(accept_context.listen_fd, null, null);
    if (client_fd < 0) return;
    daemon_log.infof(accept_context.allocator, "client connected", .{});
    socket_transport.setCloseOnExec(client_fd) catch {
        _ = c.close(client_fd);
        return;
    };
    const context = accept_context.allocator.create(ClientContext) catch {
        _ = c.close(client_fd);
        return;
    };
    context.* = .{
        .allocator = accept_context.allocator,
        .exe = accept_context.exe,
        .fd = client_fd,
    };
    const thread = std.Thread.spawn(.{}, clientThread, .{context}) catch {
        accept_context.allocator.destroy(context);
        _ = c.close(client_fd);
        return;
    };
    thread.detach();
}

const ClientContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    fd: c.fd_t,
};

fn clientThread(context: *ClientContext) void {
    const allocator = context.allocator;
    const exe = context.exe;
    const fd = context.fd;
    defer allocator.destroy(context);
    defer _ = c.close(fd);
    handleClient(allocator, exe, fd) catch {};
}

fn handleClient(allocator: std.mem.Allocator, exe: []const u8, fd: c.fd_t) !void {
    const handshake_result = try acceptHandshake(allocator, fd);
    if (handshake_result == .mismatch) return;
    daemon_log.infof(allocator, "client hello completed", .{});

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            .te_resize => continue,
            .te_stream_open => {
                try session_daemon_handler.serveFrameAfterHandshake(allocator, exe, frame, fd, fd);
                return;
            },
            .te_session_client_debug_sever_connection_request,
            .te_session_client_debug_unresponsive_connection_request,
            => {
                try session_daemon_handler.serveDebugFrameAfterHandshake(allocator, frame, fd);
                return;
            },
            .mux_stream_frame => {
                try stream_runtime.serveMuxStreamFrameAfterHandshake(allocator, exe, frame, fd);
                return;
            },
            .client_te_transport_open => {
                daemon_log.infof(allocator, "terminal transport requested", .{});
                var request = try protocol.decodePayload(pb.ClientTeTransportOpen, allocator, frame.payload);
                defer request.deinit(allocator);
                try transport_ssh.serveTerminalTransportFromDaemon(allocator, fd, request);
                return;
            },
            .daemon_log_request => {
                try serveDaemonLogRequest(allocator, fd, frame.payload);
                return;
            },
            else => {
                try sendError(fd, "PROTOCOL_ERROR", "sesshd does not support this request yet", "");
                return;
            },
        }
    }
}

fn serveDaemonLogRequest(allocator: std.mem.Allocator, fd: c.fd_t, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.DaemonLogRequest, allocator, payload);
    defer request.deinit(allocator);

    try daemon_log.subscribe(allocator, fd);
    defer daemon_log.unsubscribe(fd);
    daemon_log.infof(allocator, "daemon log subscribed", .{});

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn initiateHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
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

const HandshakeResult = enum {
    accepted,
    mismatch,
};

fn acceptHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !HandshakeResult {
    var peer_hello = try readHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return .mismatch;
    }
    try sendHelloOk(fd);
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |_| return .mismatch;
    return .accepted;
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

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

test "daemon socket path uses runtime root" {
    const allocator = std.testing.allocator;
    const path = try socketPathForDirName(allocator, "1.dev.abcdef12");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/1.dev.abcdef12/sesshd.sock"));
}
