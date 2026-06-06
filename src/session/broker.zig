const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("../transport/socket.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    socket_transport.publishRuntimeRootSymlinkOnce(allocator);

    if (args.len > 0) {
        try io.writeAll(2, "sessh: :internal-session-broker: does not accept command arguments\n");
        return error.InvalidSessionBrokerArgs;
    }

    const handshake_result = try acceptRuntimeHandshake(allocator, 0, 1);
    if (handshake_result == .mismatch) return;

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, 0) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .te_resize => continue,
            .te_session_attach => {
                const agent_fd = connectAgentForAttach(allocator, frame.payload) catch |err| switch (err) {
                    error.NoSessions => {
                        try sendError(1, "SESSION_NOT_FOUND", "no sessions", "");
                        return;
                    },
                    error.SessionRefNotLocal => {
                        try sendError(1, "SESSION_REF_NOT_LOCAL", "session reference resolves to another host", "");
                        return;
                    },
                    error.SessionAlreadyExited => {
                        try sendError(1, "SESSION_ALREADY_EXITED", "session already exited", "");
                        return;
                    },
                    error.InvalidSessionId, error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                        try sendError(1, "SESSION_NOT_FOUND", "session not found", "");
                        return;
                    },
                    else => return err,
                };
                defer _ = c.close(agent_fd);
                try attachAgentAndForwardFrames(allocator, agent_fd, frame.payload);
                return;
            },
            .te_session_create => {
                const agent_fd = startSessionAgentAndConnect(allocator, exe, frame.payload) catch |err| switch (err) {
                    else => return err,
                };
                defer _ = c.close(agent_fd);
                try createSessionAndForwardFrames(allocator, agent_fd, frame.payload);
                return;
            },
            else => {
                try sendError(1, "PROTOCOL_ERROR", "broker only supports SESSION_CREATE or SESSION_ATTACH in this mode", "");
                return;
            },
        }
    }
}

fn processExists(pid: c.pid_t) bool {
    posix.kill(pid, 0) catch return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn connectAgentForAttach(allocator: std.mem.Allocator, payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.TeSessionAttach, allocator, payload);
    defer request.deinit(allocator);
    var paths = if (request.session_dir.len > 0) blk: {
        if (!std.mem.startsWith(u8, request.session_dir, "/")) return error.InvalidSessionDir;
        break :blk try session_registry.pathsForSessionDir(allocator, request.session_dir);
    } else if (request.session_ref.len > 0)
        try pathsForLocalSessionRef(allocator, request.session_ref)
    else
        (try mostRecentAgent(allocator)) orelse return error.NoSessions;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
}

fn pathsForLocalSessionRef(allocator: std.mem.Allocator, ref: []const u8) !session_registry.SessionPaths {
    if (!session_registry.isValidSessionRef(ref)) return error.InvalidSessionId;
    const guid = session_registry.resolveRefToGuid(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => {
            if (session_registry.tombstoneExistsForRef(allocator, ref)) return error.SessionAlreadyExited;
            return err;
        },
        else => return err,
    };
    defer allocator.free(guid);

    var route = session_registry.readRouteForRef(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (session_registry.tombstoneExistsForRef(allocator, ref) or
                session_registry.tombstoneExistsForRef(allocator, guid)) return error.SessionAlreadyExited;
            break :blk null;
        },
        else => return err,
    };
    if (route) |*value| {
        defer value.deinit(allocator);
        if (value.session_dir.len > 0) {
            var routed_paths = try session_registry.pathsForSessionDir(allocator, value.session_dir);
            errdefer routed_paths.deinit(allocator);
            if (fileExists(routed_paths.meta) or value.host.len == 0 or std.mem.eql(u8, value.host, ".")) return routed_paths;
            return error.SessionRefNotLocal;
        }
        if (value.host.len > 0 and !std.mem.eql(u8, value.host, ".")) {
            var current_paths = try session_registry.pathsForSessionId(allocator, guid);
            errdefer current_paths.deinit(allocator);
            if (!fileExists(current_paths.meta)) return error.SessionRefNotLocal;
            return current_paths;
        }
    }

    var paths = try session_registry.pathsForSessionId(allocator, guid);
    errdefer paths.deinit(allocator);
    if (fileExists(paths.route) and !fileExists(paths.meta)) return error.SessionRefNotLocal;
    return paths;
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
    var selected_detached_ts: u64 = 0;
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
        var meta = session_registry.readMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            paths.deinit(allocator);
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            session_registry.removeStaleHints(paths) catch {};
            paths.deinit(allocator);
            continue;
        }
        const maybe_detached_ts: ?u64 = querySessionLiveStateDetachedAt(allocator, paths) catch blk: {
            break :blk legacyDetachedMarkerTimestampMs(allocator, paths) catch null;
        };
        const detached_ts = maybe_detached_ts orelse {
            paths.deinit(allocator);
            continue;
        };
        if (selected == null or detached_ts > selected_detached_ts) {
            if (selected) |*old| old.deinit(allocator);
            selected = paths;
            selected_detached_ts = detached_ts;
        } else {
            paths.deinit(allocator);
        }
    }
    return selected;
}

fn querySessionLiveStateDetachedAt(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !?u64 {
    var state = try querySessionLiveState(allocator, paths);
    defer state.deinit(allocator);
    return state.detached_at_unix_ms;
}

fn querySessionLiveState(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !pb.TeSessionLiveState {
    return querySessionLiveStateFromSocketPath(allocator, paths.socket);
}

fn querySessionLiveStateFromSocketPath(allocator: std.mem.Allocator, socket_path: []const u8) !pb.TeSessionLiveState {
    const fd = try socket_transport.connectSocket(socket_path);
    defer _ = c.close(fd);

    try initiateRuntimeHandshake(allocator, fd);

    const query_payload = try protocol.encodePayload(allocator, pb.TeSessionLiveStateQuery{});
    defer allocator.free(query_payload);
    try protocol.sendFrame(fd, .te_session_live_state_query, query_payload);

    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    switch (frame.message_type) {
        .te_session_live_state => return protocol.decodePayload(pb.TeSessionLiveState, allocator, frame.payload),
        .error_message => return error.SessionLiveStateUnavailable,
        else => return error.UnexpectedFrame,
    }
}

fn legacyDetachedMarkerTimestampMs(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !?u64 {
    const marker = try std.fmt.allocPrint(allocator, "{s}/detached", .{paths.dir});
    defer allocator.free(marker);
    const stat = std.fs.cwd().statFile(marker) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.mtime <= 0) return 0;
    return @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    return std.fs.cwd().statFile(path);
}

fn startSessionAgentAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_create_payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.TeSessionCreate, allocator, session_create_payload);
    defer request.deinit(allocator);
    var allocation = if (request.session_guid.len > 0)
        try session_registry.allocateSessionDirForGuid(allocator, request.session_guid)
    else
        try session_registry.allocateSessionDir(allocator);
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

fn createSessionAndForwardFrames(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_create_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .te_session_create, session_create_payload);
    try frame_forwarder.forwardFrames(0, 1, agent_fd);
}

fn attachAgentAndForwardFrames(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_attach_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .te_session_attach, session_attach_payload);
    try frame_forwarder.forwardFrames(0, 1, agent_fd);
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
    var hello_error = try readHelloReply(allocator, read_fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.HandshakeFailed;
    }
    const host_guid = try session_registry.ensureHostGuid(allocator);
    defer allocator.free(host_guid);
    try protocol.sendHostGuid(write_fd, host_guid);
    return .accepted;
}

fn initiateRuntimeHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.AgentHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Start a fresh sessh connection with matching binaries");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
    try readHostGuidFrame(allocator, fd);
}

fn readHostGuidFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    if (frame.message_type != .host_guid) return error.UnexpectedFrame;
    var message = try protocol.decodePayload(pb.HostGuid, allocator, frame.payload);
    defer message.deinit(allocator);
    if (!session_registry.isValidHostGuid(message.host_guid)) return error.InvalidHostGuid;
}

fn readHelloRequest(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            else => {
                try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, read_fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
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
