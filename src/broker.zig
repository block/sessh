const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;

const config = @import("config.zig");
const io = @import("io.zig");
const protocol = @import("protocol.zig");
const relay = @import("relay.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

const AgentCommandResponse = protocol.BrokerCommandResponse;

pub fn run(allocator: std.mem.Allocator, exe: []const u8) !void {
    socket_transport.publishRuntimeRootSymlinkOnce(allocator);

    const handshake_result = try acceptRuntimeHandshake(allocator, 0, 1);
    if (handshake_result == .mismatch) return;

    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, 0);
        errdefer frame.deinit(allocator);
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_RESIZE => {
                    frame.deinit(allocator);
                    continue;
                },
                .FRAME_TYPE_BROKER_COMMAND_REQUEST => {
                    defer frame.deinit(allocator);
                    try handleCommandRequest(allocator, frame.payload);
                    return;
                },
                .FRAME_TYPE_SESSION_ATTACH => {
                    defer frame.deinit(allocator);
                    const agent_fd = connectAgentForAttach(allocator, frame.payload) catch |err| switch (err) {
                        error.NoSessions => {
                            try sendError(1, "SESSION_NOT_FOUND", "no sessions", "");
                            return;
                        },
                        error.InvalidSessionId, error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                            try sendError(1, "SESSION_NOT_FOUND", "session not found", "");
                            return;
                        },
                        else => return err,
                    };
                    defer _ = c.close(agent_fd);
                    try attachAgentAndRelay(allocator, agent_fd, frame.payload);
                    return;
                },
                .FRAME_TYPE_SESSION_NEW => {
                    defer frame.deinit(allocator);
                    const agent_fd = try startSessionAgentAndConnect(allocator, exe);
                    defer _ = c.close(agent_fd);
                    try startAgentAndRelay(allocator, agent_fd, frame.payload);
                    return;
                },
                else => {
                    defer frame.deinit(allocator);
                    try sendError(1, "PROTOCOL_ERROR", "broker only supports SESSION_NEW in this mode", "");
                    return;
                },
            },
            .unknown => |raw| {
                defer frame.deinit(allocator);
                try sendUnrecognizedFrame(1, frame.seq, raw);
                continue;
            },
        }
    }
}

fn handleCommandRequest(allocator: std.mem.Allocator, payload: []const u8) !void {
    var request = try protocol.decodeBrokerCommandRequest(allocator, payload);
    defer request.deinit(allocator);
    const argv = request.argv;
    if (argv.len == 0) {
        try sendCommandResponse(1, 64, "", "ERROR missing command\n");
        return;
    }

    const command = argv[0];
    if (std.mem.eql(u8, command, "list")) {
        if (argv.len != 1) {
            try sendCommandResponse(1, 64, "", "ERROR usage: list\n");
            return;
        }
        try listAgents(allocator);
        return;
    }
    if (std.mem.eql(u8, command, "kill")) {
        if (argv.len != 2) {
            try sendCommandResponse(1, 64, "", "ERROR usage: kill ID\n");
            return;
        }
        try commandOneAgent(allocator, argv[1], &.{ "kill", argv[1] });
        return;
    }
    if (std.mem.eql(u8, command, "kill-all")) {
        if (argv.len != 1) {
            try sendCommandResponse(1, 64, "", "ERROR usage: kill-all\n");
            return;
        }
        try killAllAgents(allocator);
        return;
    }

    try sendCommandResponse(1, 64, "", "ERROR unknown command\n");
}

fn listAgents(allocator: std.mem.Allocator) !void {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try stdout.appendSlice(allocator, "ID\tATTACHED\tPID\n");

    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try sendCommandResponse(1, 0, stdout.items, "");
            return;
        },
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        defer paths.deinit(allocator);
        var response = queryAgentCommand(allocator, paths, &.{"list"}) catch |err| switch (err) {
            error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                session_registry.removeStaleHints(paths) catch {};
                continue;
            },
            error.VersionMismatch => {
                try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
                return;
            },
            else => return err,
        };
        defer response.deinit(allocator);
        if (response.exit_status == 0) {
            try appendListRows(allocator, &stdout, response.stdout);
        } else if (response.stderr.len > 0) {
            try stderr.appendSlice(allocator, response.stderr);
        }
    }

    try sendCommandResponse(1, if (stderr.items.len == 0) 0 else 1, stdout.items, stderr.items);
}

fn commandOneAgent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    argv: []const []const u8,
) !void {
    var paths = session_registry.pathsForSessionId(allocator, session_id) catch |err| switch (err) {
        error.InvalidSessionId => {
            try sendCommandResponse(1, 1, "", "ERROR session not found\n");
            return;
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    var response = queryAgentCommand(allocator, paths, argv) catch |err| switch (err) {
        error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
            session_registry.removeStaleHints(paths) catch {};
            try sendCommandResponse(1, 1, "", "ERROR session not found\n");
            return;
        },
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    defer response.deinit(allocator);
    try sendCommandResponse(1, response.exit_status, response.stdout, response.stderr);
}

fn killAllAgents(allocator: std.mem.Allocator) !void {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try sendCommandResponse(1, 0, "KILLING_ALL\n", "");
            return;
        },
        else => return err,
    };
    defer dir.close();

    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        defer paths.deinit(allocator);
        var response = queryAgentCommand(allocator, paths, &.{"kill-all"}) catch |err| switch (err) {
            error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                session_registry.removeStaleHints(paths) catch {};
                continue;
            },
            error.VersionMismatch => {
                try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
                return;
            },
            else => return err,
        };
        defer response.deinit(allocator);
        if (response.exit_status != 0 and response.stderr.len > 0) {
            try stderr.appendSlice(allocator, response.stderr);
        }
    }

    try sendCommandResponse(1, if (stderr.items.len == 0) 0 else 1, "KILLING_ALL\n", stderr.items);
}

fn queryAgentCommand(
    allocator: std.mem.Allocator,
    paths: session_registry.SessionPaths,
    argv: []const []const u8,
) !AgentCommandResponse {
    const fd = try socket_transport.connectSocket(paths.socket);
    defer _ = c.close(fd);
    try initiateRuntimeHandshake(allocator, fd);
    try sendAgentCommandRequest(allocator, fd, argv);

    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    if (frame.knownMessageType() == .FRAME_TYPE_ERROR) {
        if (try errorIsVersionMismatch(allocator, frame.payload)) return error.VersionMismatch;
        return error.AgentError;
    }
    if (frame.knownMessageType() != .FRAME_TYPE_BROKER_COMMAND_RESPONSE) return error.UnexpectedFrame;
    return protocol.decodeBrokerCommandResponse(allocator, frame.payload);
}

fn sendAgentCommandRequest(allocator: std.mem.Allocator, fd: c.fd_t, argv: []const []const u8) !void {
    const payload = try protocol.encodeBrokerCommandRequest(allocator, argv);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_BROKER_COMMAND_REQUEST, payload);
}

fn appendListRows(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), agent_stdout: []const u8) !void {
    var lines = std.mem.splitScalar(u8, agent_stdout, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try stdout.appendSlice(allocator, line);
        try stdout.append(allocator, '\n');
    }
}

fn sendCommandResponse(fd: c.fd_t, exit_status: u32, stdout: []const u8, stderr: []const u8) !void {
    if (exit_status > std.math.maxInt(u8)) return error.IntOutOfRange;
    const payload = try protocol.encodeBrokerCommandResponse(app_allocator.allocator(), @intCast(exit_status), stdout, stderr);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_BROKER_COMMAND_RESPONSE, payload);
}

fn connectAgentForAttach(allocator: std.mem.Allocator, payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.SessionAttach, allocator, payload);
    defer request.deinit(allocator);
    var paths = (try mostRecentAgent(allocator)) orelse return error.NoSessions;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
}

fn mostRecentAgent(allocator: std.mem.Allocator) !?session_registry.SessionPaths {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var selected: ?session_registry.SessionPaths = null;
    var selected_number: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        errdefer paths.deinit(allocator);
        _ = statAbsolute(paths.socket) catch |err| switch (err) {
            error.FileNotFound => {
                paths.deinit(allocator);
                continue;
            },
            else => return err,
        };
        const number = std.fmt.parseInt(usize, entry.name[1..], 10) catch {
            paths.deinit(allocator);
            continue;
        };
        if (selected == null or number > selected_number) {
            if (selected) |*old| old.deinit(allocator);
            selected = paths;
            selected_number = number;
        } else {
            paths.deinit(allocator);
        }
    }
    return selected;
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    return std.fs.cwd().statFile(path);
}

fn startSessionAgentAndConnect(allocator: std.mem.Allocator, exe: []const u8) !c.fd_t {
    var allocation = try session_registry.allocateSessionDir(allocator);
    defer allocation.deinit(allocator);

    const argv = [_][]const u8{
        exe,
        ":internal-session-agent:",
        "--session-dir",
        allocation.paths.dir,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (socket_transport.connectSocket(allocation.paths.socket)) |fd| return fd else |err| switch (err) {
            error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {},
            else => return err,
        }
        io.sleepMillis(20);
    }
    return error.SessionAgentDidNotStart;
}

fn startAgentAndRelay(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_new_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_SESSION_NEW, session_new_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn attachAgentAndRelay(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_attach_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_SESSION_ATTACH, session_attach_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn errorIsVersionMismatch(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var message = try protocol.decodePayload(hpb.Error, allocator, payload);
    defer message.deinit(allocator);
    return std.mem.eql(u8, message.code, "VERSION_MISMATCH");
}

const HandshakeResult = enum {
    accepted,
    mismatch,
};

fn acceptRuntimeHandshake(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !HandshakeResult {
    var peer_hello = try readHelloRequest(allocator, read_fd, write_fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(write_fd, "VERSION_MISMATCH", "broker is incompatible with this client", "");
        return .mismatch;
    }
    try sendHelloOk(write_fd);
    try sendHelloRequest(write_fd);
    var hello_error = try readHelloReply(allocator, read_fd, write_fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.HandshakeFailed;
    }
    return .accepted;
}

fn initiateRuntimeHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.AgentHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
}

fn readHelloRequest(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_REQUEST => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => {
                    try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                    return error.UnexpectedFrame;
                },
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(write_fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_OK => {
                    var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
                    defer ok.deinit(allocator);
                    return null;
                },
                .FRAME_TYPE_HELLO_ERROR => {
                    const err = try protocol.decodePayload(hpb.HelloError, allocator, frame.payload);
                    return err;
                },
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(write_fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return hello.protocol_major == config.protocol_major and
        hello.protocol_minor >= config.protocol_minor and
        std.mem.eql(u8, hello.version, config.version);
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_REQUEST, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_OK, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_ERROR, payload);
}

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_ERROR, payload);
}

fn sendUnrecognizedFrame(fd: c.fd_t, seq: u64, frame_type: u32) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.UnrecognizedFrame{
        .seq = seq,
        .frame_type = frame_type,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_UNRECOGNIZED, payload);
}
