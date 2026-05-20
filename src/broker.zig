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

const AgentCommandResponse = struct {
    exit_status: u32,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *AgentCommandResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr);
        allocator.free(self.stdout);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, exe: []const u8) !void {
    socket_transport.publishRuntimeRootSymlinkOnce(allocator);

    var hello = try protocol.readFrameAlloc(allocator, 0);
    defer hello.deinit(allocator);
    if (hello.message_type != .FRAME_TYPE_HELLO) {
        try sendError(1, "PROTOCOL_ERROR", "expected HELLO", "");
        return;
    }
    if (!try helloIsCompatible(allocator, hello.payload)) {
        try sendError(1, "VERSION_MISMATCH", "broker is incompatible with this client", "");
        return;
    }
    try sendHelloOk(1);

    var pending_resize: ?protocol.OwnedFrame = null;
    defer if (pending_resize) |*frame| frame.deinit(allocator);

    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, 0);
        errdefer frame.deinit(allocator);
        switch (frame.message_type) {
            .FRAME_TYPE_RESIZE => {
                if (pending_resize) |*old| old.deinit(allocator);
                pending_resize = frame;
            },
            .FRAME_TYPE_COMMAND_REQUEST => {
                defer frame.deinit(allocator);
                try handleCommandRequest(allocator, hello.payload, frame.payload);
                return;
            },
            .FRAME_TYPE_SESSION_ATTACH => {
                defer frame.deinit(allocator);
                const resize = pending_resize orelse {
                    try sendError(1, "PROTOCOL_ERROR", "SESSION_ATTACH requires RESIZE first", "");
                    return;
                };
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
                try attachAgentAndRelay(allocator, hello.payload, agent_fd, resize.payload, frame.payload);
                return;
            },
            .FRAME_TYPE_SESSION_NEW => {
                defer frame.deinit(allocator);
                const resize = pending_resize orelse {
                    try sendError(1, "PROTOCOL_ERROR", "SESSION_NEW requires RESIZE first", "");
                    return;
                };
                const agent_fd = try startSessionAgentAndConnect(allocator, exe);
                defer _ = c.close(agent_fd);
                try startAgentAndRelay(allocator, hello.payload, agent_fd, resize.payload, frame.payload);
                return;
            },
            else => {
                defer frame.deinit(allocator);
                try sendError(1, "PROTOCOL_ERROR", "broker only supports SESSION_NEW in this mode", "");
                return;
            },
        }
    }
}

fn handleCommandRequest(allocator: std.mem.Allocator, hello_payload: []const u8, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.CommandRequest, allocator, payload);
    defer request.deinit(allocator);
    const argv = request.argv.items;
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
        try listAgents(allocator, hello_payload);
        return;
    }
    if (std.mem.eql(u8, command, "kill")) {
        if (argv.len != 2) {
            try sendCommandResponse(1, 64, "", "ERROR usage: kill ID\n");
            return;
        }
        try commandOneAgent(allocator, hello_payload, argv[1], &.{ "kill", argv[1] });
        return;
    }
    if (std.mem.eql(u8, command, "kill-all")) {
        if (argv.len != 1) {
            try sendCommandResponse(1, 64, "", "ERROR usage: kill-all\n");
            return;
        }
        try killAllAgents(allocator, hello_payload);
        return;
    }

    try sendCommandResponse(1, 64, "", "ERROR unknown command\n");
}

fn listAgents(allocator: std.mem.Allocator, hello_payload: []const u8) !void {
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
        var response = queryAgentCommand(allocator, hello_payload, paths, &.{"list"}) catch |err| switch (err) {
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
    hello_payload: []const u8,
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

    var response = queryAgentCommand(allocator, hello_payload, paths, argv) catch |err| switch (err) {
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

fn killAllAgents(allocator: std.mem.Allocator, hello_payload: []const u8) !void {
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
        var response = queryAgentCommand(allocator, hello_payload, paths, &.{"kill-all"}) catch |err| switch (err) {
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
    hello_payload: []const u8,
    paths: session_registry.SessionPaths,
    argv: []const []const u8,
) !AgentCommandResponse {
    const fd = try socket_transport.connectSocket(paths.socket);
    defer _ = c.close(fd);
    try agentHandshake(allocator, hello_payload, fd);
    try sendAgentCommandRequest(allocator, fd, argv);

    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    if (frame.message_type == .FRAME_TYPE_ERROR) {
        if (try errorIsVersionMismatch(allocator, frame.payload)) return error.VersionMismatch;
        return error.AgentError;
    }
    if (frame.message_type != .FRAME_TYPE_COMMAND_RESPONSE) return error.UnexpectedFrame;
    var message = try protocol.decodePayload(pb.CommandResponse, allocator, frame.payload);
    defer message.deinit(allocator);
    return .{
        .exit_status = message.exit_status,
        .stdout = try allocator.dupe(u8, message.stdout),
        .stderr = try allocator.dupe(u8, message.stderr),
    };
}

fn sendAgentCommandRequest(allocator: std.mem.Allocator, fd: c.fd_t, argv: []const []const u8) !void {
    var message = pb.CommandRequest{};
    defer message.argv.deinit(allocator);
    for (argv) |arg| try message.argv.append(allocator, arg);
    const payload = try protocol.encodePayload(allocator, message);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_COMMAND_REQUEST, payload);
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
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.CommandResponse{
        .exit_status = exit_status,
        .stdout = stdout,
        .stderr = stderr,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_COMMAND_RESPONSE, payload);
}

fn connectAgentForAttach(allocator: std.mem.Allocator, payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.SessionAttach, allocator, payload);
    defer request.deinit(allocator);
    var paths = if (request.session_id) |id|
        try session_registry.pathsForSessionId(allocator, id)
    else
        (try mostRecentDetachedAgent(allocator)) orelse return error.NoSessions;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
}

fn mostRecentDetachedAgent(allocator: std.mem.Allocator) !?session_registry.SessionPaths {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var selected: ?session_registry.SessionPaths = null;
    var selected_mtime: i128 = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        errdefer paths.deinit(allocator);
        const stat = statAbsolute(paths.detached) catch |err| switch (err) {
            error.FileNotFound => {
                paths.deinit(allocator);
                continue;
            },
            else => return err,
        };
        if (selected == null or stat.mtime > selected_mtime) {
            if (selected) |*old| old.deinit(allocator);
            selected = paths;
            selected_mtime = stat.mtime;
        } else {
            paths.deinit(allocator);
        }
    }
    return selected;
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.stat();
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
    hello_payload: []const u8,
    agent_fd: c.fd_t,
    resize_payload: []const u8,
    session_new_payload: []const u8,
) !void {
    agentHandshake(allocator, hello_payload, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_RESIZE, resize_payload);
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_SESSION_NEW, session_new_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn attachAgentAndRelay(
    allocator: std.mem.Allocator,
    hello_payload: []const u8,
    agent_fd: c.fd_t,
    resize_payload: []const u8,
    session_attach_payload: []const u8,
) !void {
    agentHandshake(allocator, hello_payload, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_RESIZE, resize_payload);
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_SESSION_ATTACH, session_attach_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn agentHandshake(allocator: std.mem.Allocator, hello_payload: []const u8, agent_fd: c.fd_t) !void {
    try protocol.sendFrame(agent_fd, .FRAME_TYPE_HELLO, hello_payload);
    var agent_hello = try protocol.readFrameAlloc(allocator, agent_fd);
    defer agent_hello.deinit(allocator);
    if (agent_hello.message_type == .FRAME_TYPE_ERROR) {
        if (try errorIsVersionMismatch(allocator, agent_hello.payload)) return error.VersionMismatch;
        return error.AgentHandshakeFailed;
    }
    if (agent_hello.message_type != .FRAME_TYPE_HELLO_OK) return error.AgentHandshakeFailed;
}

fn errorIsVersionMismatch(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var message = try protocol.decodePayload(pb.Error, allocator, payload);
    defer message.deinit(allocator);
    return std.mem.eql(u8, message.code, "VERSION_MISMATCH");
}

fn helloIsCompatible(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var hello = try protocol.decodePayload(pb.Hello, allocator, payload);
    defer hello.deinit(allocator);
    return hello.protocol_major == config.protocol_major and
        hello.protocol_minor == config.protocol_minor and
        std.mem.eql(u8, hello.version, config.version);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Hello{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_OK, payload);
}

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_ERROR, payload);
}
