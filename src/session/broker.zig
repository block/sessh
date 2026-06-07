const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const session_runtime = @import("runtime.zig");
const session_registry = @import("../runtime/session_registry.zig");

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
        .te_stream_open => {
            var request = try protocol.decodePayload(pb.TeStreamOpen, allocator, frame.payload);
            defer request.deinit(allocator);
            if (request.create == null) {
                const runtime_fd = connectRuntimeForOpen(allocator, request) catch |err| switch (err) {
                    error.InvalidSessionGuid, error.SessionNotFound => {
                        try sendError(write_fd, "SESSION_NOT_FOUND", "session not found", "");
                        return;
                    },
                    else => return err,
                };
                defer _ = c.close(runtime_fd);
                try openRuntimeAndForwardFrames(allocator, runtime_fd, frame.payload, read_fd, write_fd);
                return;
            }

            const open_payload = try sessionOpenPayloadWithCurrentEnvironment(allocator, frame.payload);
            defer allocator.free(open_payload);
            const runtime_fd = startSessionRuntimeAndConnect(allocator, exe, open_payload) catch |err| switch (err) {
                else => return err,
            };
            defer _ = c.close(runtime_fd);
            try openRuntimeAndForwardFrames(allocator, runtime_fd, open_payload, read_fd, write_fd);
            return;
        },
        else => {
            try sendError(write_fd, "PROTOCOL_ERROR", "broker only supports terminal stream open in this mode", "");
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

    const runtime_fd = session_runtime.connectSingleLiveSessionRuntime(allocator) catch |err| switch (err) {
        error.SessionNotFound, error.AmbiguousSession => {
            try sendError(write_fd, "SESSION_NOT_FOUND", "session not found", "");
            return;
        },
        else => return err,
    };
    defer _ = c.close(runtime_fd);

    try initiateRuntimeHandshake(allocator, runtime_fd);
    try protocol.sendFrame(runtime_fd, frame.message_type, frame.payload);
    try forwardRuntimeFramesToClient(allocator, runtime_fd, write_fd);
}

fn connectRuntimeForOpen(allocator: std.mem.Allocator, request: pb.TeStreamOpen) !c.fd_t {
    if (!session_registry.isValidSessionGuid(request.session_guid)) return error.InvalidSessionGuid;
    return session_runtime.connectSessionRuntime(allocator, request.session_guid);
}

fn startSessionRuntimeAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_open_payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.TeStreamOpen, allocator, session_open_payload);
    defer request.deinit(allocator);
    if (request.create == null) return error.MissingSessionCreate;
    var allocation = if (request.session_guid.len > 0)
        try session_registry.allocateSessionDirForGuid(allocator, request.session_guid)
    else
        try session_registry.allocateSessionDir(allocator);
    defer allocation.deinit(allocator);

    _ = exe;
    _ = try session_runtime.startSessionRuntimeThread(allocator, allocation.paths.dir);
    return session_runtime.connectSessionRuntime(allocator, allocation.id);
}

pub fn sessionOpenPayloadWithCurrentEnvironment(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var request = try protocol.decodePayload(pb.TeStreamOpen, allocator, payload);
    defer request.deinit(allocator);
    if (request.create) |*create| {
        try appendCurrentEnvironment(allocator, create);
    } else {
        return allocator.dupe(u8, payload);
    }
    return protocol.encodePayload(allocator, request);
}

pub const sessionCreatePayloadWithCurrentEnvironment = sessionOpenPayloadWithCurrentEnvironment;

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

fn openRuntimeAndForwardFrames(
    allocator: std.mem.Allocator,
    runtime_fd: c.fd_t,
    session_open_payload: []const u8,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
) !void {
    initiateRuntimeHandshake(allocator, runtime_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(write_fd, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(runtime_fd, .te_stream_open, session_open_payload);
    try frame_forwarder.forwardFrames(read_fd, write_fd, runtime_fd);
}

fn forwardRuntimeFramesToClient(allocator: std.mem.Allocator, runtime_fd: c.fd_t, write_fd: c.fd_t) !void {
    while (true) {
        var frame = protocol.readFrameAlloc(allocator, runtime_fd) catch |err| switch (err) {
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
        return error.RuntimeHandshakeFailed;
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
