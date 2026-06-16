const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;

const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const session_runtime = @import("runtime.zig");
const session_registry = @import("../runtime/session_registry.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

pub fn registerFrameAfterHandshakeFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    exe: []const u8,
    frame: protocol.OwnedFrame,
    client_fd: c.fd_t,
) !void {
    var owns_client_fd = true;
    defer {
        if (owns_client_fd) _ = c.close(client_fd);
    }

    if (frame.message_type != .client_remote) {
        try sendError(client_fd, "PROTOCOL_ERROR", "session handler only supports terminal stream open in this mode", "");
        return;
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse {
        try sendError(client_fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
        return;
    };
    const request = switch (item_payload) {
        .resize => return,
        .open => |open| open,
        else => {
            try sendError(client_fd, "PROTOCOL_ERROR", "session handler only supports terminal stream open in this mode", "");
            return;
        },
    };

    const action = teStreamActionName(request);
    daemon_log.infof(
        allocator,
        "terminal stream opening session={s} action={s}",
        .{ request.session_guid, action },
    );

    const request_payload = try protocol.encodePayload(allocator, request);
    defer allocator.free(request_payload);

    const process_fd = if (request.create == null) blk: {
        break :blk connectTerminalRemoteForOpen(allocator, request) catch |err| switch (err) {
            error.InvalidSessionGuid, error.SessionNotFound => {
                try sendError(client_fd, "SESSION_NOT_FOUND", "session not found", "");
                return;
            },
            else => return err,
        };
    } else blk: {
        const open_payload = try sessionOpenPayloadWithCurrentEnvironment(allocator, request_payload);
        defer allocator.free(open_payload);
        break :blk try startTerminalRemoteAndConnect(allocator, exe, open_payload);
    };
    var owns_process_fd = true;
    defer {
        if (owns_process_fd) _ = c.close(process_fd);
    }

    daemon_log.infof(
        allocator,
        "terminal stream remote connected session={s} action={s}",
        .{ request.session_guid, action },
    );

    const open_payload = if (request.create == null)
        request_payload
    else
        try sessionOpenPayloadWithCurrentEnvironment(allocator, request_payload);
    defer if (request.create != null) allocator.free(open_payload);

    initiateTerminalRemoteHandshake(allocator, process_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(client_fd, "VERSION_MISMATCH", "existing remote terminal process is incompatible with this client", "Start a fresh sessh connection with matching binaries");
            return;
        },
        else => return err,
    };
    var session_open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, open_payload);
    defer session_open.deinit(allocator);
    try protocol.sendTeStreamPayloadFrame(allocator, process_fd, .{ .open = session_open });

    try frame_forwarder.registerFrameRelay(allocator, daemon_dispatcher, client_fd, process_fd);
    owns_client_fd = false;
    owns_process_fd = false;
}

pub fn serveDebugFrameAfterHandshake(
    allocator: std.mem.Allocator,
    frame: protocol.OwnedFrame,
    write_fd: c.fd_t,
) !void {
    if (frame.message_type != .client_remote) {
        try sendError(write_fd, "PROTOCOL_ERROR", "session handler only supports session debug frames in this mode", "");
        return;
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse {
        try sendError(write_fd, "PROTOCOL_ERROR", "session handler only supports session debug frames in this mode", "");
        return;
    };
    switch (item_payload) {
        .debug_sever_connection_request,
        .debug_unresponsive_connection_request,
        => {},
        else => {
            try sendError(write_fd, "PROTOCOL_ERROR", "session handler only supports session debug frames in this mode", "");
            return;
        },
    }

    const process_fd = session_runtime.connectSingleLiveTerminalRemote(allocator) catch |err| switch (err) {
        error.SessionNotFound, error.AmbiguousSession => {
            try sendError(write_fd, "SESSION_NOT_FOUND", "session not found", "");
            return;
        },
        else => return err,
    };
    defer _ = c.close(process_fd);

    try initiateTerminalRemoteHandshake(allocator, process_fd);
    try protocol.sendFrame(process_fd, frame.message_type, frame.payload);
    try forwardTerminalRemoteFramesToClient(allocator, process_fd, write_fd);
}

pub const TerminalMuxStream = struct {
    stream_id: u64,
    process_fd: c.fd_t = -1,
    process_watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    session_guid: []u8 = &.{},
    inbound_next_offset: u64 = 0,
    outbound_next_offset: u64 = 0,
    attached_logged: bool = false,
    ended: bool = false,
    cleanup_recorded: bool = false,
};

pub fn closeTerminalMuxStreams(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(TerminalMuxStream),
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    for (sessions.items) |stream| {
        closeTerminalMuxStream(allocator, stream, true, daemon_dispatcher);
    }
    sessions.deinit(allocator);
}

pub fn closeTerminalMuxStream(
    allocator: std.mem.Allocator,
    stream: TerminalMuxStream,
    send_hangup: bool,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    if (daemon_dispatcher) |d| {
        if (stream.process_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
    }
    if (stream.process_fd >= 0) {
        if (send_hangup and !stream.cleanup_recorded) sendTerminalHangupToRemote(stream.process_fd) catch {};
        _ = c.close(stream.process_fd);
    }
    var moved_stream = stream;
    if (moved_stream.reader_initialized) moved_stream.reader.deinit();
    if (stream.session_guid.len != 0) allocator.free(stream.session_guid);
}

pub fn handleTerminalMuxStreamFrame(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    sessions: *std.ArrayList(TerminalMuxStream),
    mux_fd: c.fd_t,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(allocator);
    const message = owned_mux_frame.message orelse return error.UnexpectedFrame;
    switch (message) {
        .open => |open| handleTerminalMuxOpen(allocator, sessions, owned_mux_frame.stream_id, open) catch |err| {
            try sendTerminalMuxResetForError(allocator, mux_fd, owned_mux_frame.stream_id, "OPEN_FAILED", err);
        },
        .payload => |payload| handleTerminalMuxPayload(allocator, exe, identity, sessions, mux_fd, owned_mux_frame.stream_id, payload, process_watch_handler, daemon_dispatcher) catch |err| {
            try sendTerminalMuxResetForError(allocator, mux_fd, owned_mux_frame.stream_id, "STREAM_FAILED", err);
            try removeTerminalMuxStream(allocator, sessions, owned_mux_frame.stream_id, daemon_dispatcher);
        },
        .ack, .open_ok => {},
        .eof => try removeTerminalMuxStream(allocator, sessions, owned_mux_frame.stream_id, daemon_dispatcher),
        .reset => try removeTerminalMuxStream(allocator, sessions, owned_mux_frame.stream_id, daemon_dispatcher),
    }
}

pub fn handleTerminalMuxOpen(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(TerminalMuxStream),
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
) !void {
    _ = open;
    if (findTerminalMuxStreamIndex(sessions, stream_id) != null) return;
    try sessions.append(allocator, .{ .stream_id = stream_id });
}

fn handleTerminalMuxPayloadOpen(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    sessions: *std.ArrayList(TerminalMuxStream),
    mux_fd: c.fd_t,
    stream_id: u64,
    payload_offset: u64,
    te_open: pb.TerminalEmulatorItem.Open,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const stream_index = findTerminalMuxStreamIndex(sessions, stream_id) orelse return error.UnexpectedFrame;
    if (sessions.items[stream_index].process_fd >= 0) return;
    const action = teStreamActionName(te_open);
    const open_started_ms = std.time.milliTimestamp();
    daemon_log.infof(
        allocator,
        "terminal mux stream opening stream_id={} session={s} action={s}",
        .{ stream_id, te_open.session_guid, action },
    );
    const session_guid = try allocator.dupe(u8, te_open.session_guid);
    var session_guid_owned = true;
    errdefer if (session_guid_owned) allocator.free(session_guid);

    const open_payload = try protocol.encodePayload(allocator, te_open);
    defer allocator.free(open_payload);

    const process_fd = openTerminalMuxStream(allocator, exe, stream_id, te_open, action, open_payload, open_started_ms) catch |err| switch (err) {
        error.InvalidSessionGuid, error.SessionNotFound => {
            daemon_log.infof(
                allocator,
                "terminal mux stream open failed stream_id={} session={s} action={s} error={t}",
                .{ stream_id, te_open.session_guid, action, err },
            );
            try sendTerminalMuxReset(allocator, mux_fd, stream_id, "SESSION_NOT_FOUND", "session not found");
            return;
        },
        error.VersionMismatch => {
            daemon_log.infof(
                allocator,
                "terminal mux stream open failed stream_id={} session={s} action={s} error={t}",
                .{ stream_id, te_open.session_guid, action, err },
            );
            try sendTerminalMuxReset(allocator, mux_fd, stream_id, "VERSION_MISMATCH", "existing remote terminal process is incompatible with this client");
            return;
        },
        else => {
            daemon_log.infof(
                allocator,
                "terminal mux stream open failed stream_id={} session={s} action={s} error={t}",
                .{ stream_id, te_open.session_guid, action, err },
            );
            try sendTerminalMuxResetForError(allocator, mux_fd, stream_id, "OPEN_FAILED", err);
            return;
        },
    };
    errdefer _ = c.close(process_fd);
    if (daemon_dispatcher != null) {
        try core_fds.setNonBlocking(process_fd);
    }

    try daemon_cleanup.sendRemoteProcessStarted(
        allocator,
        mux_fd,
        stream_id,
        daemon_cleanup.makeRemoteProcessIdentity(identity, te_open.session_guid),
    );
    try sendTerminalMuxOpenOk(allocator, mux_fd, stream_id);
    sessions.items[stream_index].process_fd = process_fd;
    if (daemon_dispatcher) |d| {
        const handler = process_watch_handler orelse return error.MissingTerminalRemoteHandler;
        sessions.items[stream_index].reader = protocol.FrameReader.init(allocator);
        sessions.items[stream_index].reader_initialized = true;
        sessions.items[stream_index].process_watch_id = try d.watchFd(process_fd, .{ .readable = true }, .{
            .ctx = handler.ctx,
            .callback = handler.callback,
        });
    }
    sessions.items[stream_index].session_guid = session_guid;
    sessions.items[stream_index].inbound_next_offset = @max(sessions.items[stream_index].inbound_next_offset, payload_offset +| 1);
    session_guid_owned = false;
    daemon_log.infof(
        allocator,
        "terminal mux stream open ok stream_id={} session={s} action={s} elapsed_ms={}",
        .{ stream_id, te_open.session_guid, action, elapsedMsSince(open_started_ms) },
    );
}

fn openTerminalMuxStream(
    allocator: std.mem.Allocator,
    exe: []const u8,
    stream_id: u64,
    request: pb.TerminalEmulatorItem.Open,
    action: []const u8,
    open_payload: []const u8,
    open_started_ms: i64,
) !c.fd_t {
    const prepare_started_ms = std.time.milliTimestamp();
    const remote_payload = if (request.create == null)
        open_payload
    else
        try sessionOpenPayloadWithCurrentEnvironment(allocator, open_payload);
    defer if (request.create != null) allocator.free(remote_payload);
    daemon_log.infof(
        allocator,
        "terminal mux remote payload prepared stream_id={} session={s} action={s} elapsed_ms={} since_open_ms={}",
        .{ stream_id, request.session_guid, action, elapsedMsSince(prepare_started_ms), elapsedMsSince(open_started_ms) },
    );

    const process_fd = if (request.create == null)
        try connectTerminalRemoteForOpen(allocator, request)
    else
        try startTerminalRemoteAndConnect(allocator, exe, remote_payload);
    errdefer _ = c.close(process_fd);
    const handshake_started_ms = std.time.milliTimestamp();
    try initiateTerminalRemoteHandshake(allocator, process_fd);
    daemon_log.infof(
        allocator,
        "terminal mux remote handshake complete stream_id={} session={s} action={s} elapsed_ms={} since_open_ms={}",
        .{ stream_id, request.session_guid, action, elapsedMsSince(handshake_started_ms), elapsedMsSince(open_started_ms) },
    );
    const send_started_ms = std.time.milliTimestamp();
    var remote_open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, remote_payload);
    defer remote_open.deinit(allocator);
    try protocol.sendTeStreamPayloadFrame(allocator, process_fd, .{ .open = remote_open });
    daemon_log.infof(
        allocator,
        "terminal mux remote open sent stream_id={} session={s} action={s} elapsed_ms={} since_open_ms={}",
        .{ stream_id, request.session_guid, action, elapsedMsSince(send_started_ms), elapsedMsSince(open_started_ms) },
    );
    return process_fd;
}

fn handleTerminalMuxPayload(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    sessions: *std.ArrayList(TerminalMuxStream),
    mux_fd: c.fd_t,
    stream_id: u64,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findTerminalMuxStreamIndex(sessions, stream_id) orelse {
        try sendTerminalMuxReset(allocator, mux_fd, stream_id, "STREAM_NOT_FOUND", "mux stream not found");
        return;
    };
    const item = payload.item orelse return error.UnexpectedFrame;
    const te_item = switch (item) {
        .terminal_emulator => |terminal_emulator| terminal_emulator,
        else => return error.UnexpectedFrame,
    };
    var stream = &sessions.items[index];
    if (te_item.payload) |te_payload| {
        if (te_payload == .open) {
            try handleTerminalMuxPayloadOpen(allocator, exe, identity, sessions, mux_fd, stream_id, payload.offset, te_payload.open, process_watch_handler, daemon_dispatcher);
            return;
        }
    }
    if (stream.process_fd < 0) return error.UnexpectedFrame;
    stream.inbound_next_offset = @max(stream.inbound_next_offset, payload.offset +| 1);
    if (te_item.payload) |te_payload| {
        if (te_payload == .session_hangup_request) {
            daemon_log.infof(
                allocator,
                "remote terminal hangup requested stream_id={} session={s}",
                .{ stream_id, stream.session_guid },
            );
        }
    }
    try protocol.sendTeStreamItemFrame(allocator, stream.process_fd, te_item);
}

pub fn forwardTerminalRemoteFrameToMux(
    allocator: std.mem.Allocator,
    mux_fd: c.fd_t,
    stream: *TerminalMuxStream,
    frame: *protocol.OwnedFrame,
) !bool {
    if (frame.message_type == .error_message) {
        try sendTerminalMuxReset(allocator, mux_fd, stream.stream_id, "REMOTE_PROCESS_ERROR", "terminal remote process error");
        return false;
    }
    if (frame.message_type != .client_remote) return error.UnexpectedFrame;
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    try sendTerminalMuxPayload(allocator, mux_fd, stream.stream_id, stream.outbound_next_offset, item);
    stream.outbound_next_offset +|= 1;
    if (item.payload) |item_payload| {
        if (item_payload == .session_attached and !stream.attached_logged) {
            stream.attached_logged = true;
            daemon_log.infof(
                allocator,
                "terminal session attached stream_id={} session={s}",
                .{ stream.stream_id, stream.session_guid },
            );
        }
        if (item_payload == .session_ended) {
            stream.ended = true;
            daemon_log.infof(
                allocator,
                "terminal session ended stream_id={} session={s}",
                .{ stream.stream_id, stream.session_guid },
            );
            try sendTerminalMuxEof(allocator, mux_fd, stream.stream_id, stream.outbound_next_offset);
        }
    }
    return true;
}

pub fn findTerminalMuxStreamIndexByWatch(sessions: *const std.ArrayList(TerminalMuxStream), watch_id: dispatcher.FdWatchId) ?usize {
    for (sessions.items, 0..) |stream, index| {
        const process_watch_id = stream.process_watch_id orelse continue;
        if (process_watch_id.index == watch_id.index and process_watch_id.generation == watch_id.generation) return index;
    }
    return null;
}

pub fn findTerminalMuxStreamIndex(sessions: *const std.ArrayList(TerminalMuxStream), stream_id: u64) ?usize {
    for (sessions.items, 0..) |stream, index| {
        if (stream.stream_id == stream_id) return index;
    }
    return null;
}

fn removeTerminalMuxStream(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(TerminalMuxStream),
    stream_id: u64,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findTerminalMuxStreamIndex(sessions, stream_id) orelse return;
    const stream = sessions.swapRemove(index);
    daemon_log.infof(
        allocator,
        "terminal mux stream closing stream_id={} session={s}",
        .{ stream.stream_id, stream.session_guid },
    );
    closeTerminalMuxStream(allocator, stream, true, daemon_dispatcher);
}

fn sendTerminalMuxOpenOk(allocator: std.mem.Allocator, fd: c.fd_t, stream_id: u64) !void {
    try sendTerminalMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .open_ok = .{
            .recv_next_offset = 0,
            .receive_window_bytes = 0,
        } },
    });
}

fn sendTerminalMuxPayload(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    offset: u64,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendTerminalMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .payload = .{
            .offset = offset,
            .item = .{ .terminal_emulator = item },
        } },
    });
}

fn sendTerminalMuxEof(allocator: std.mem.Allocator, fd: c.fd_t, stream_id: u64, final_offset: u64) !void {
    try sendTerminalMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .eof = .{ .final_offset = final_offset } },
    });
}

fn sendTerminalMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendTerminalMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendTerminalMuxResetForError(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(allocator, "terminal mux stream failed: {t}", .{err});
    defer allocator.free(message);
    try sendTerminalMuxReset(allocator, fd, stream_id, code, message);
}

fn sendTerminalMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, message);
}

fn sendTerminalHangupToRemote(fd: c.fd_t) !void {
    try protocol.sendTeStreamPayloadFrame(app_allocator.allocator(), fd, .{ .session_hangup_request = .{} });
}

fn connectTerminalRemoteForOpen(allocator: std.mem.Allocator, request: pb.TerminalEmulatorItem.Open) !c.fd_t {
    if (!session_registry.isValidSessionGuid(request.session_guid)) return error.InvalidSessionGuid;
    return session_runtime.connectTerminalRemoteProcess(allocator, request.session_guid);
}

fn startTerminalRemoteAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_open_payload: []const u8) !c.fd_t {
    const started_ms = std.time.milliTimestamp();
    var request = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, session_open_payload);
    defer request.deinit(allocator);
    if (request.create == null) return error.MissingSessionCreate;
    const guid = if (request.session_guid.len > 0)
        try session_registry.canonicalGuid(allocator, request.session_guid)
    else
        try session_registry.generateGuid(allocator);
    defer allocator.free(guid);

    daemon_log.infof(allocator, "terminal session creating session={s}", .{guid});
    const control = try session_runtime.startTerminalRemoteProcess(allocator, exe, guid);
    const process_fd = try session_runtime.connectStartedTerminalRemoteProcess(control);
    daemon_log.infof(
        allocator,
        "terminal remote process connected session={s} elapsed_ms={}",
        .{ guid, elapsedMsSince(started_ms) },
    );
    return process_fd;
}

fn teStreamActionName(request: pb.TerminalEmulatorItem.Open) []const u8 {
    return if (request.create == null) "resume" else "create";
}

fn elapsedMsSince(start_ms: i64) u64 {
    const end_ms = std.time.milliTimestamp();
    if (end_ms <= start_ms) return 0;
    return @intCast(end_ms - start_ms);
}

pub fn sessionOpenPayloadWithCurrentEnvironment(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var request = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, payload);
    defer request.deinit(allocator);
    if (request.create) |*create| {
        try appendCurrentEnvironment(allocator, create);
    } else {
        return allocator.dupe(u8, payload);
    }
    return protocol.encodePayload(allocator, request);
}

pub const sessionCreatePayloadWithCurrentEnvironment = sessionOpenPayloadWithCurrentEnvironment;

fn appendCurrentEnvironment(allocator: std.mem.Allocator, request: *pb.TerminalEmulatorItem.SessionCreate) !void {
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
    request: *pb.TerminalEmulatorItem.SessionCreate,
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

fn forwardTerminalRemoteFramesToClient(allocator: std.mem.Allocator, process_fd: c.fd_t, write_fd: c.fd_t) !void {
    while (true) {
        var frame = protocol.readFrameAlloc(allocator, process_fd) catch |err| switch (err) {
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

fn initiateTerminalRemoteHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.RemoteHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing remote terminal process is incompatible with this client", "Start a fresh sessh connection with matching binaries");
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
