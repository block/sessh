const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const session_agent = @import("agent.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("../transport/socket.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

pub fn serveFrameAfterHandshake(
    allocator: std.mem.Allocator,
    exe: []const u8,
    frame: protocol.OwnedFrame,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
) !void {
    switch (frame.message_type) {
        .te_resize => return,
        .te_session_attach => {
            const agent_fd = connectAgentForAttach(allocator, frame.payload) catch |err| switch (err) {
                error.SessionRefNotLocal => {
                    try sendError(write_fd, "SESSION_REF_NOT_LOCAL", "session reference resolves to another host", "");
                    return;
                },
                error.InvalidSessionId, error.MissingSessionRef, error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                    try sendError(write_fd, "SESSION_NOT_FOUND", "session not found", "");
                    return;
                },
                else => return err,
            };
            defer _ = c.close(agent_fd);
            try attachAgentAndForwardFrames(allocator, agent_fd, frame.payload, read_fd, write_fd);
            return;
        },
        .te_session_create => {
            const session_create_payload = try sessionCreatePayloadWithCurrentEnvironment(allocator, frame.payload);
            defer allocator.free(session_create_payload);
            const agent_fd = startSessionAgentAndConnect(allocator, exe, session_create_payload) catch |err| switch (err) {
                else => return err,
            };
            defer _ = c.close(agent_fd);
            try createSessionAndForwardFrames(allocator, agent_fd, session_create_payload, read_fd, write_fd);
            return;
        },
        else => {
            try sendError(write_fd, "PROTOCOL_ERROR", "broker only supports SESSION_CREATE or SESSION_ATTACH in this mode", "");
            return;
        },
    }
}

pub fn serveDebugFrameAfterHandshake(
    allocator: std.mem.Allocator,
    frame: protocol.OwnedFrame,
    write_fd: c.fd_t,
) !void {
    switch (frame.message_type) {
        .te_session_client_debug_sever_connection_request,
        .te_session_client_debug_unresponsive_connection_request,
        => {},
        else => {
            try sendError(write_fd, "PROTOCOL_ERROR", "broker only supports session debug frames in this mode", "");
            return;
        },
    }

    const agent_fd = connectSingleLiveSessionAgent(allocator) catch |err| switch (err) {
        error.SessionNotFound, error.AmbiguousSession => {
            try sendError(write_fd, "SESSION_NOT_FOUND", "session not found", "");
            return;
        },
        else => return err,
    };
    defer _ = c.close(agent_fd);

    try initiateRuntimeHandshake(allocator, agent_fd);
    try protocol.sendFrame(agent_fd, frame.message_type, frame.payload);
    try forwardAgentFramesToClient(allocator, agent_fd, write_fd);
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn connectSingleLiveSessionAgent(allocator: std.mem.Allocator) !c.fd_t {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const guid_dir = try std.fmt.allocPrint(allocator, "{s}/guid", .{runtime_root});
    defer allocator.free(guid_dir);

    var dir = std.fs.openDirAbsolute(guid_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer dir.close();

    var found_fd: c.fd_t = -1;
    errdefer {
        if (found_fd >= 0) _ = c.close(found_fd);
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!session_registry.isValidSessionGuid(entry.name)) continue;

        const session_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guid_dir, entry.name });
        defer allocator.free(session_dir);
        var paths = session_registry.pathsForSessionDir(allocator, session_dir) catch continue;
        defer paths.deinit(allocator);

        const fd = socket_transport.connectSocket(paths.socket) catch continue;
        if (found_fd >= 0) {
            _ = c.close(fd);
            return error.AmbiguousSession;
        }
        found_fd = fd;
    }

    if (found_fd < 0) return error.SessionNotFound;
    return found_fd;
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
        return error.MissingSessionRef;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
}

fn pathsForLocalSessionRef(allocator: std.mem.Allocator, ref: []const u8) !session_registry.SessionPaths {
    if (!session_registry.isValidSessionRef(ref)) return error.InvalidSessionId;
    const guid = try session_registry.resolveRefToGuid(allocator, ref);
    defer allocator.free(guid);

    var route = session_registry.readRouteForRef(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => null,
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

fn startSessionAgentAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_create_payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.TeSessionCreate, allocator, session_create_payload);
    defer request.deinit(allocator);
    var allocation = if (request.session_guid.len > 0)
        try session_registry.allocateSessionDirForGuid(allocator, request.session_guid)
    else
        try session_registry.allocateSessionDir(allocator);
    defer allocation.deinit(allocator);

    _ = exe;
    try session_agent.startSessionAgentThread(allocator, allocation.paths.dir);

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

pub fn sessionCreatePayloadWithCurrentEnvironment(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var request = try protocol.decodePayload(pb.TeSessionCreate, allocator, payload);
    defer request.deinit(allocator);

    try appendCurrentEnvironment(allocator, &request);
    return protocol.encodePayload(allocator, request);
}

fn appendCurrentEnvironment(allocator: std.mem.Allocator, request: *pb.TeSessionCreate) !void {
    var index: usize = 0;
    while (c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        try appendEnvironmentEntry(allocator, request, entry[0..equals], entry[equals + 1 ..]);
    }
}

fn appendEnvironmentEntry(
    allocator: std.mem.Allocator,
    request: *pb.TeSessionCreate,
    name_bytes: []const u8,
    value_bytes: []const u8,
) !void {
    const name = try allocator.dupe(u8, name_bytes);
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, value_bytes);
    errdefer allocator.free(value);
    try request.environment.append(allocator, .{
        .name = name,
        .value = value,
    });
}

fn createSessionAndForwardFrames(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_create_payload: []const u8,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(write_fd, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .te_session_create, session_create_payload);
    try frame_forwarder.forwardFrames(read_fd, write_fd, agent_fd);
}

fn attachAgentAndForwardFrames(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_attach_payload: []const u8,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(write_fd, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .te_session_attach, session_attach_payload);
    try frame_forwarder.forwardFrames(read_fd, write_fd, agent_fd);
}

fn forwardAgentFramesToClient(allocator: std.mem.Allocator, agent_fd: c.fd_t, write_fd: c.fd_t) !void {
    while (true) {
        var frame = protocol.readFrameAlloc(allocator, agent_fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        try protocol.sendFrame(write_fd, frame.message_type, frame.payload);
    }
}

fn errorIsVersionMismatch(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var message = try protocol.decodePayload(hpb.Error, allocator, payload);
    defer message.deinit(allocator);
    return std.mem.eql(u8, message.code, "VERSION_MISMATCH");
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
        try sendHelloError(fd, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client", "Start a fresh sessh connection with matching binaries");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
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
