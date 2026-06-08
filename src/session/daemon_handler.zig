const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const daemon_log = @import("../daemon/log.zig");
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
            try sendError(write_fd, "PROTOCOL_ERROR", "session handler only supports terminal stream open in this mode", "");
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
            try sendError(write_fd, "PROTOCOL_ERROR", "session handler only supports session debug frames in this mode", "");
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

pub fn isTeMuxOpenFrame(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) bool {
    if (frame.message_type != .mux_stream_frame) return false;
    var mux_frame = protocol.decodePayload(pb.MuxStreamFrame, allocator, frame.payload) catch return false;
    defer mux_frame.deinit(allocator);
    const message = mux_frame.message orelse return false;
    return switch (message) {
        .open => |open| switch (open.detail orelse return false) {
            .te => true,
            else => false,
        },
        else => false,
    };
}

pub fn serveMuxStreamFrameAfterHandshake(
    allocator: std.mem.Allocator,
    exe: []const u8,
    first_frame: protocol.OwnedFrame,
    fd: c.fd_t,
) !void {
    var sessions: std.ArrayList(TeMuxRuntime) = .empty;
    defer closeTeMuxRuntimes(allocator, &sessions);

    try handleTeMuxFrame(allocator, exe, &sessions, fd, first_frame);

    while (true) {
        const poll_targets = try allocator.alloc(TeMuxPollTarget, sessions.items.len);
        defer allocator.free(poll_targets);
        for (sessions.items, 0..) |runtime, index| {
            poll_targets[index] = .{
                .stream_id = runtime.stream_id,
                .runtime_fd = runtime.runtime_fd,
            };
        }

        const pollfds = try allocator.alloc(posix.pollfd, 1 + poll_targets.len);
        defer allocator.free(pollfds);
        pollfds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
        for (poll_targets, 0..) |target, index| {
            pollfds[index + 1] = .{ .fd = target.runtime_fd, .events = posix.POLL.IN, .revents = 0 };
        }

        _ = try posix.poll(pollfds, -1);

        for (poll_targets, 0..) |target, index| {
            const revents = pollfds[index + 1].revents;
            if ((revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) {
                continue;
            }
            const runtime_index = findTeMuxRuntimeIndex(&sessions, target.stream_id) orelse continue;
            if (try forwardTeRuntimeFrameToMux(allocator, fd, &sessions.items[runtime_index])) {
                continue;
            } else {
                const runtime = sessions.swapRemove(runtime_index);
                if (!runtime.ended) {
                    sendTeMuxReset(allocator, fd, runtime.stream_id, "RUNTIME_CLOSED", "terminal runtime closed") catch {};
                }
                _ = c.close(runtime.runtime_fd);
            }
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer frame.deinit(allocator);
            try handleTeMuxFrame(allocator, exe, &sessions, fd, frame);
        }
    }
}

const TeMuxRuntime = struct {
    stream_id: u64,
    runtime_fd: c.fd_t,
    inbound_next_offset: u64 = 0,
    outbound_next_offset: u64 = 0,
    ended: bool = false,
};

const TeMuxPollTarget = struct {
    stream_id: u64,
    runtime_fd: c.fd_t,
};

fn closeTeMuxRuntimes(allocator: std.mem.Allocator, sessions: *std.ArrayList(TeMuxRuntime)) void {
    for (sessions.items) |runtime| {
        sendTeHangupToRuntime(runtime.runtime_fd) catch {};
        _ = c.close(runtime.runtime_fd);
    }
    sessions.deinit(allocator);
}

fn handleTeMuxFrame(
    allocator: std.mem.Allocator,
    exe: []const u8,
    sessions: *std.ArrayList(TeMuxRuntime),
    mux_fd: c.fd_t,
    frame: protocol.OwnedFrame,
) !void {
    if (frame.message_type != .mux_stream_frame) return error.UnexpectedFrame;
    var mux_frame = try protocol.decodePayload(pb.MuxStreamFrame, allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    const message = mux_frame.message orelse return error.UnexpectedFrame;
    switch (message) {
        .open => |open| handleTeMuxOpen(allocator, exe, sessions, mux_fd, mux_frame.stream_id, open) catch |err| {
            try sendTeMuxResetForError(allocator, mux_fd, mux_frame.stream_id, "OPEN_FAILED", err);
        },
        .payload => |payload| handleTeMuxPayload(allocator, sessions, mux_fd, mux_frame.stream_id, payload) catch |err| {
            try sendTeMuxResetForError(allocator, mux_fd, mux_frame.stream_id, "STREAM_FAILED", err);
            try removeTeMuxRuntime(sessions, mux_frame.stream_id);
        },
        .ack, .open_ok => {},
        .reset => try removeTeMuxRuntime(sessions, mux_frame.stream_id),
    }
}

fn handleTeMuxOpen(
    allocator: std.mem.Allocator,
    exe: []const u8,
    sessions: *std.ArrayList(TeMuxRuntime),
    mux_fd: c.fd_t,
    stream_id: u64,
    open: pb.MuxStreamFrame.Open,
) !void {
    const detail = open.detail orelse return error.UnexpectedFrame;
    const te_open = switch (detail) {
        .te => |te| te,
        else => return error.UnexpectedFrame,
    };
    if (findTeMuxRuntimeIndex(sessions, stream_id) != null) {
        try sendTeMuxReset(allocator, mux_fd, stream_id, "STREAM_EXISTS", "mux stream already exists");
        return;
    }

    const open_payload = try protocol.encodePayload(allocator, te_open);
    defer allocator.free(open_payload);

    const runtime_fd = openTeMuxRuntime(allocator, exe, te_open, open_payload) catch |err| switch (err) {
        error.InvalidSessionGuid, error.SessionNotFound => {
            try sendTeMuxReset(allocator, mux_fd, stream_id, "SESSION_NOT_FOUND", "session not found");
            return;
        },
        error.VersionMismatch => {
            try sendTeMuxReset(allocator, mux_fd, stream_id, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client");
            return;
        },
        else => {
            try sendTeMuxReset(allocator, mux_fd, stream_id, "OPEN_FAILED", "terminal stream open failed");
            return;
        },
    };
    errdefer _ = c.close(runtime_fd);

    try sendTeMuxOpenOk(allocator, mux_fd, stream_id);
    try sessions.append(allocator, .{
        .stream_id = stream_id,
        .runtime_fd = runtime_fd,
    });
}

fn openTeMuxRuntime(
    allocator: std.mem.Allocator,
    exe: []const u8,
    request: pb.TeStreamOpen,
    open_payload: []const u8,
) !c.fd_t {
    const runtime_fd = if (request.create == null)
        try connectRuntimeForOpen(allocator, request)
    else
        try startSessionRuntimeAndConnect(allocator, exe, open_payload);
    errdefer _ = c.close(runtime_fd);
    try initiateRuntimeHandshake(allocator, runtime_fd);
    try protocol.sendFrame(runtime_fd, .te_stream_open, open_payload);
    return runtime_fd;
}

fn handleTeMuxPayload(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(TeMuxRuntime),
    mux_fd: c.fd_t,
    stream_id: u64,
    payload: pb.MuxStreamFrame.Payload,
) !void {
    const index = findTeMuxRuntimeIndex(sessions, stream_id) orelse {
        try sendTeMuxReset(allocator, mux_fd, stream_id, "STREAM_NOT_FOUND", "mux stream not found");
        return;
    };
    const item = payload.item orelse return error.UnexpectedFrame;
    const te_item = switch (item) {
        .te => |te| te,
        else => return error.UnexpectedFrame,
    };
    var runtime = &sessions.items[index];
    runtime.inbound_next_offset = @max(runtime.inbound_next_offset, payload.offset +| 1);
    if (te_item.payload) |te_payload| {
        if (te_payload == .session_hangup_request) {
            daemon_log.infof(allocator, "remote terminal hangup requested", .{});
        }
    }
    try protocol.sendTeStreamItemFrame(allocator, runtime.runtime_fd, te_item);
}

fn forwardTeRuntimeFrameToMux(
    allocator: std.mem.Allocator,
    mux_fd: c.fd_t,
    runtime: *TeMuxRuntime,
) !bool {
    var frame = protocol.readFrameAlloc(allocator, runtime.runtime_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);
    if (frame.message_type == .error_message) {
        try sendTeMuxReset(allocator, mux_fd, runtime.stream_id, "RUNTIME_ERROR", "terminal runtime error");
        return false;
    }
    var item = try protocol.teStreamItemFromFramePayload(allocator, frame.message_type, frame.payload);
    defer item.deinit(allocator);
    try sendTeMuxPayload(allocator, mux_fd, runtime.stream_id, runtime.outbound_next_offset, item);
    runtime.outbound_next_offset +|= 1;
    if (frame.message_type == .te_session_ended) runtime.ended = true;
    return true;
}

fn findTeMuxRuntimeIndex(sessions: *const std.ArrayList(TeMuxRuntime), stream_id: u64) ?usize {
    for (sessions.items, 0..) |runtime, index| {
        if (runtime.stream_id == stream_id) return index;
    }
    return null;
}

fn removeTeMuxRuntime(sessions: *std.ArrayList(TeMuxRuntime), stream_id: u64) !void {
    const index = findTeMuxRuntimeIndex(sessions, stream_id) orelse return;
    const runtime = sessions.swapRemove(index);
    sendTeHangupToRuntime(runtime.runtime_fd) catch {};
    _ = c.close(runtime.runtime_fd);
}

fn sendTeMuxOpenOk(allocator: std.mem.Allocator, fd: c.fd_t, stream_id: u64) !void {
    try sendTeMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .open_ok = .{
            .recv_next_offset = 0,
            .receive_window_bytes = 0,
        } },
    });
}

fn sendTeMuxPayload(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    offset: u64,
    item: pb.TeStreamItem,
) !void {
    try sendTeMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .payload = .{
            .offset = offset,
            .item = .{ .te = item },
        } },
    });
}

fn sendTeMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendTeMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendTeMuxResetForError(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(allocator, "terminal mux stream failed: {t}", .{err});
    defer allocator.free(message);
    try sendTeMuxReset(allocator, fd, stream_id, code, message);
}

fn sendTeMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.MuxStreamFrame) !void {
    const payload = try protocol.encodePayload(allocator, message);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .mux_stream_frame, payload);
}

fn sendTeHangupToRuntime(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeSessionHangupRequest{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .te_session_hangup_request, payload);
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
