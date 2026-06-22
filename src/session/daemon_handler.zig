// Daemon-side terminal-session mux handling. It accepts logical terminal
// streams from a daemon tunnel, starts or connects the worker that owns the PTY,
// and forwards frames between that worker and the mux stream.
const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const frame_forwarder = @import("../transport/frame_forwarder.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const one_shot_frame_writer = @import("../transport/one_shot_frame_writer.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const worker_endpoint = @import("../daemon/worker_endpoint.zig");
const terminal_worker = @import("terminal_worker.zig");
const terminal_worker_process = @import("terminal_worker_process.zig");
const guid_ref = @import("../core/guid.zig");

const pb = protocol.pb;

const TerminalRemoteRegistration = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    exe: []const u8,
    frame: protocol.OwnedFrame,
    client_fd: c.fd_t,
};

// Move a freshly accepted terminal client from the generic daemon router into a
// terminal worker. On error we still own the client fd long enough to return a
// framed protocol error instead of silently closing the local client socket.
pub fn registerFrameWithTerminalRemoteFromDaemon(options: TerminalRemoteRegistration) !void {
    const allocator = options.allocator;
    const daemon_dispatcher = options.daemon_dispatcher;
    const exe = options.exe;
    const frame = options.frame;
    var client_fd = core_fds.OwnedFd.init(options.client_fd);
    defer client_fd.deinit();
    const client_error = OneShotErrorClient{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .fd = &client_fd,
    };

    if (frame.message_type != .client_remote) {
        try client_error.queueProtocolError("session handler only supports terminal stream open in this mode");
        return;
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse {
        try client_error.queueProtocolError("empty terminal stream item");
        return;
    };
    const request = switch (item_payload) {
        .resize => return,
        .open => |open| open,
        else => {
            try client_error.queueProtocolError("session handler only supports terminal stream open in this mode");
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

    const raw_process_fd = if (request.create == null) blk: {
        break :blk connectTerminalWorkerForOpen(allocator, request, daemon_dispatcher) catch |err| switch (err) {
            error.InvalidSessionGuid, error.SessionNotFound => {
                try client_error.queueSessionNotFound();
                return;
            },
            else => return err,
        };
    } else blk: {
        const open_payload = try sessionOpenPayloadWithCurrentEnvironment(allocator, request_payload);
        defer allocator.free(open_payload);
        break :blk try startTerminalWorkerAndConnect(.{
            .allocator = allocator,
            .exe = exe,
            .session_open_payload = open_payload,
            .daemon_dispatcher = daemon_dispatcher,
        });
    };
    var process_fd = core_fds.OwnedFd.init(raw_process_fd);
    defer process_fd.deinit();

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

    var session_open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, open_payload);
    defer session_open.deinit(allocator);
    const client_remote_payload = try protocol.encodeTerminalEmulatorItemPayload(allocator, .{ .payload = .{ .open = session_open } });
    defer allocator.free(client_remote_payload);

    try frame_forwarder.registerFrameRelayWithInitialWrites(.{
        .allocator = allocator,
        .dispatcher = daemon_dispatcher,
        .endpoints = .{ .left = client_fd.get(), .right = process_fd.get() },
        .initial_writes = .{ .left_to_right = .{ .message_type = .client_remote, .payload = client_remote_payload } },
    });
    _ = client_fd.take();
    _ = process_fd.take();
}

const TerminalRemoteDebugRegistration = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
    client_fd: c.fd_t,
};

/// Connect a one-shot debug request to the currently live terminal worker. This
/// path intentionally bypasses normal open handling because the request targets
/// an already-running worker and should either relay exactly one frame or return
/// a clear protocol error.
pub fn registerDebugFrameWithTerminalRemoteFromDaemon(options: TerminalRemoteDebugRegistration) !void {
    const allocator = options.allocator;
    const daemon_dispatcher = options.daemon_dispatcher;
    const frame = options.frame;
    var client_fd = core_fds.OwnedFd.init(options.client_fd);
    defer client_fd.deinit();
    const client_error = OneShotErrorClient{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .fd = &client_fd,
    };

    if (frame.message_type != .client_remote) {
        try client_error.queueProtocolError("session handler only supports session debug frames in this mode");
        return;
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse {
        try client_error.queueProtocolError("session handler only supports session debug frames in this mode");
        return;
    };
    switch (item_payload) {
        .debug_sever_connection_request,
        .debug_unresponsive_connection_request,
        => {},
        else => {
            try client_error.queueProtocolError("session handler only supports session debug frames in this mode");
            return;
        },
    }

    var process_fd = core_fds.OwnedFd.init(terminal_worker.connectSingleLiveTerminalWorkerFromDaemon(allocator, daemon_dispatcher) catch |err| switch (err) {
        error.SessionNotFound, error.AmbiguousSession => {
            try client_error.queueSessionNotFound();
            return;
        },
        else => return err,
    });
    defer process_fd.deinit();

    try registerOneShotTerminalDebugControl(.{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .client_fd = client_fd.get(),
        .worker_fd = process_fd.get(),
        .frame = frame,
    });
    _ = client_fd.take();
    _ = process_fd.take();
}

const OneShotTerminalDebugControlRegistration = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    worker_fd: c.fd_t,
    frame: protocol.OwnedFrame,
};

fn registerOneShotTerminalDebugControl(options: OneShotTerminalDebugControlRegistration) !void {
    try core_fds.setNonBlocking(options.client_fd);
    try core_fds.setNonBlocking(options.worker_fd);

    const control = try options.allocator.create(OneShotTerminalDebugControl);
    errdefer options.allocator.destroy(control);
    control.* = .{
        .allocator = options.allocator,
        .client_fd = options.client_fd,
        .worker_fd = options.worker_fd,
    };
    errdefer control.deinit();

    control.worker_source = try options.daemon_dispatcher.frameSource(options.worker_fd);
    control.worker_sink = try options.daemon_dispatcher.frameSink(.{ .allocator = options.allocator, .fd = options.worker_fd });
    control.client_sink = try options.daemon_dispatcher.frameSink(.{ .allocator = options.allocator, .fd = options.client_fd });
    try control.worker_sink.writeFrame(options.frame.message_type, options.frame.payload);

    control.task = dispatcher.dispatchTask(
        OneShotTerminalDebugControl,
        options.allocator,
        control,
        OneShotTerminalDebugControl.run,
    );
    control.task.setSourceReadiness(.any);
    try control.task.requireSource(control.worker_source);
    try control.task.requireSink(control.worker_sink);
    try control.task.requireSink(control.client_sink);
    try control.task.schedule(options.daemon_dispatcher);
}

const OneShotTerminalDebugControl = struct {
    allocator: std.mem.Allocator,
    client_fd: c.fd_t,
    worker_fd: c.fd_t,
    worker_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    worker_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    client_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    response_queued: bool = false,

    fn deinit(self: *OneShotTerminalDebugControl) void {
        self.task.deinit();
        self.worker_source.deinit();
        self.worker_sink.deinit();
        self.client_sink.deinit();
        if (self.client_fd >= 0) {
            _ = c.close(self.client_fd);
            self.client_fd = -1;
        }
        if (self.worker_fd >= 0) {
            _ = c.close(self.worker_fd);
            self.worker_fd = -1;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn run(
        self: *OneShotTerminalDebugControl,
        _: *dispatcher.Dispatcher,
        _: *dispatcher.DispatchTask,
    ) !dispatch_io.DispatchTaskStatus {
        if (self.worker_sink.takeWriteError() != null or self.client_sink.takeWriteError() != null) {
            self.deinit();
            return .done;
        }

        if (!self.response_queued and !self.worker_sink.hasPendingWrite()) {
            var frame = switch (try self.worker_source.readFrame()) {
                .blocked => return .pending,
                .eof => {
                    self.deinit();
                    return .done;
                },
                .frame => |frame_value| frame_value,
            };
            defer frame.deinit(self.allocator);
            try self.client_sink.writeOwnedFrame(&frame);
            self.response_queued = true;
        }

        if (self.response_queued and !self.client_sink.hasPendingWrite()) {
            self.deinit();
            return .done;
        }
        return .pending;
    }
};

pub const TerminalMuxStream = struct {
    stream_id: u64,
    endpoint: worker_endpoint.Endpoint = .{},
    session_guid: []u8 = &.{},
    inbound_next_offset: u64 = 0,
    outbound_next_offset: u64 = 0,
    session_ready_logged: bool = false,
    ended: bool = false,
    cleanup_recorded: bool = false,
};

// The terminal mux handler sits between the daemon tunnel and per-session worker
// processes. Keeping that boundary state together makes the open/error paths
// explicit without hiding the fact that the handler mutates shared tunnel state.
pub const TerminalMuxContext = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    sessions: *std.ArrayList(TerminalMuxStream),
    mux_writer: *dispatch_io.FrameSink,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
};

pub fn closeTerminalMuxStreams(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(TerminalMuxStream),
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    for (sessions.items) |stream| {
        closeTerminalMuxStream(.{
            .allocator = allocator,
            .stream = stream,
            .send_hangup = true,
            .daemon_dispatcher = daemon_dispatcher,
        });
    }
    sessions.deinit(allocator);
}

pub const CloseTerminalMuxStreamOptions = struct {
    allocator: std.mem.Allocator,
    stream: TerminalMuxStream,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
    send_hangup: bool,
};

pub fn closeTerminalMuxStream(options: CloseTerminalMuxStreamOptions) void {
    var moved_stream = options.stream;
    if (moved_stream.endpoint.fd >= 0) {
        if (options.send_hangup and !moved_stream.cleanup_recorded) {
            if (options.daemon_dispatcher) |d| {
                queueTerminalHangupAndCloseEndpoint(options.allocator, &moved_stream.endpoint, d) catch {
                    moved_stream.endpoint.close(options.daemon_dispatcher);
                };
                if (options.stream.session_guid.len != 0) options.allocator.free(options.stream.session_guid);
                return;
            }
        }
    }
    moved_stream.endpoint.close(options.daemon_dispatcher);
    if (options.stream.session_guid.len != 0) options.allocator.free(options.stream.session_guid);
}

/// Apply one mux-stream frame for terminal-emulator traffic. Open/payload errors
/// are translated into mux resets so the daemon tunnel survives one bad logical
/// stream.
pub fn handleTerminalMuxStreamFrame(
    ctx: TerminalMuxContext,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(ctx.allocator);
    const message = owned_mux_frame.message orelse return error.UnexpectedFrame;
    switch (message) {
        .open => handleTerminalMuxOpen(ctx, owned_mux_frame.stream_id) catch |err| {
            try sendTerminalMuxResetForError(.{
                .allocator = ctx.allocator,
                .mux_writer = ctx.mux_writer,
                .stream_id = owned_mux_frame.stream_id,
                .code = "OPEN_FAILED",
                .err = err,
            });
        },
        .payload => |payload| handleTerminalMuxPayload(ctx, owned_mux_frame.stream_id, payload) catch |err| {
            try sendTerminalMuxResetForError(.{
                .allocator = ctx.allocator,
                .mux_writer = ctx.mux_writer,
                .stream_id = owned_mux_frame.stream_id,
                .code = "STREAM_FAILED",
                .err = err,
            });
            try removeTerminalMuxStream(ctx, owned_mux_frame.stream_id);
        },
        .ack, .open_ok => {},
        .eof => try removeTerminalMuxStream(ctx, owned_mux_frame.stream_id),
        .reset => try removeTerminalMuxStream(ctx, owned_mux_frame.stream_id),
    }
}

pub fn handleTerminalMuxOpen(ctx: TerminalMuxContext, stream_id: u64) !void {
    if (findTerminalMuxStreamIndex(ctx.sessions, stream_id) != null) return;
    try ctx.sessions.append(ctx.allocator, .{ .stream_id = stream_id });
}

// A terminal mux stream is not usable until the worker endpoint exists and the
// remote process identity has been sent back for cleanup tracking. Only then do
// we acknowledge the mux open and forward the terminal open to the worker.
const TerminalMuxPayloadOpen = struct {
    stream_id: u64,
    payload_offset: u64,
    open: pb.TerminalEmulatorItem.Open,
};

// Complete terminal stream startup: create/connect the worker endpoint, publish
// remote cleanup identity, acknowledge the mux open, and forward the terminal
// open payload to the worker in that order.
fn handleTerminalMuxPayloadOpen(
    ctx: TerminalMuxContext,
    request: TerminalMuxPayloadOpen,
) !void {
    const stream_id = request.stream_id;
    const te_open = request.open;
    const payload_offset = request.payload_offset;
    const stream_index = findTerminalMuxStreamIndex(ctx.sessions, stream_id) orelse return error.UnexpectedFrame;
    if (ctx.sessions.items[stream_index].endpoint.active()) return;
    const action = teStreamActionName(te_open);
    const open_started_ms = std.time.milliTimestamp();
    daemon_log.infof(
        ctx.allocator,
        "terminal mux stream opening stream_id={} session={s} action={s}",
        .{ stream_id, te_open.session_guid, action },
    );
    const session_guid = try ctx.allocator.dupe(u8, te_open.session_guid);
    var session_guid_owned = true;
    errdefer if (session_guid_owned) ctx.allocator.free(session_guid);

    const open_payload = try protocol.encodePayload(ctx.allocator, te_open);
    defer ctx.allocator.free(open_payload);
    const remote_payload = if (te_open.create == null)
        open_payload
    else
        try sessionOpenPayloadWithCurrentEnvironment(ctx.allocator, open_payload);
    defer if (te_open.create != null) ctx.allocator.free(remote_payload);

    const raw_process_fd = openTerminalMuxStream(ctx, .{
        .stream_id = stream_id,
        .request = te_open,
        .action = action,
        .remote_payload = remote_payload,
        .open_started_ms = open_started_ms,
    }) catch |err| switch (err) {
        error.InvalidSessionGuid, error.SessionNotFound => {
            daemon_log.infof(
                ctx.allocator,
                "terminal mux stream open failed stream_id={} session={s} action={s} error={t}",
                .{ stream_id, te_open.session_guid, action, err },
            );
            try sendTerminalMuxReset(.{
                .mux_writer = ctx.mux_writer,
                .stream_id = stream_id,
                .code = "SESSION_NOT_FOUND",
                .message = "session not found",
            });
            return;
        },
        else => {
            daemon_log.infof(
                ctx.allocator,
                "terminal mux stream open failed stream_id={} session={s} action={s} error={t}",
                .{ stream_id, te_open.session_guid, action, err },
            );
            try sendTerminalMuxResetForError(.{
                .allocator = ctx.allocator,
                .mux_writer = ctx.mux_writer,
                .stream_id = stream_id,
                .code = "OPEN_FAILED",
                .err = err,
            });
            return;
        },
    };
    var process_fd = core_fds.OwnedFd.init(raw_process_fd);
    defer process_fd.deinit();
    if (ctx.daemon_dispatcher != null) {
        try core_fds.setNonBlocking(process_fd.get());
    }

    try ctx.mux_writer.writeDaemonTunnelPayload(.{ .remote_process_started = .{
        .stream_id = stream_id,
        .process = daemon_cleanup.makeRemoteProcessIdentity(ctx.identity, te_open.session_guid),
    } });
    try sendTerminalMuxOpenOk(ctx.mux_writer, stream_id);
    ctx.sessions.items[stream_index].endpoint.fd = process_fd.take();
    if (ctx.daemon_dispatcher) |d| {
        try ctx.sessions.items[stream_index].endpoint.initIo(d, ctx.allocator);
    }
    var remote_open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, ctx.allocator, remote_payload);
    defer remote_open.deinit(ctx.allocator);
    try queueTerminalWorkerPayload(ctx.allocator, &ctx.sessions.items[stream_index], .{ .open = remote_open });
    if (ctx.daemon_dispatcher) |d| {
        // Try the first nonblocking flush now. The dispatcher remains
        // responsible for backpressure if the worker socket cannot accept all
        // queued bytes immediately.
        _ = try ctx.sessions.items[stream_index].endpoint.drainWrites(d);
    }
    ctx.sessions.items[stream_index].session_guid = session_guid;
    ctx.sessions.items[stream_index].inbound_next_offset = @max(ctx.sessions.items[stream_index].inbound_next_offset, payload_offset +| 1);
    session_guid_owned = false;
    daemon_log.infof(
        ctx.allocator,
        "terminal mux stream open ok stream_id={} session={s} action={s} elapsed_ms={}",
        .{ stream_id, te_open.session_guid, action, elapsedMsSince(open_started_ms) },
    );
}

const TerminalMuxOpenOptions = struct {
    stream_id: u64,
    request: pb.TerminalEmulatorItem.Open,
    action: []const u8,
    remote_payload: []const u8,
    open_started_ms: i64,
};

// Resolve the terminal open into either an existing worker connection or a new
// worker process/in-daemon worker, depending on whether the payload is a create
// request and which isolation mode was selected.
fn openTerminalMuxStream(
    ctx: TerminalMuxContext,
    options: TerminalMuxOpenOptions,
) !c.fd_t {
    const prepare_started_ms = std.time.milliTimestamp();
    daemon_log.infof(
        ctx.allocator,
        "terminal mux remote payload prepared stream_id={} session={s} action={s} elapsed_ms={} since_open_ms={}",
        .{ options.stream_id, options.request.session_guid, options.action, elapsedMsSince(prepare_started_ms), elapsedMsSince(options.open_started_ms) },
    );

    const process_fd = if (options.request.create == null)
        try connectTerminalWorkerForOpen(ctx.allocator, options.request, ctx.daemon_dispatcher)
    else
        try startTerminalWorkerAndConnect(.{
            .allocator = ctx.allocator,
            .exe = ctx.exe,
            .session_open_payload = options.remote_payload,
            .daemon_dispatcher = ctx.daemon_dispatcher,
        });
    daemon_log.infof(
        ctx.allocator,
        "terminal mux remote open queued stream_id={} session={s} action={s} since_open_ms={}",
        .{ options.stream_id, options.request.session_guid, options.action, elapsedMsSince(options.open_started_ms) },
    );
    return process_fd;
}

// Forward a terminal-emulator payload from the tunnel into the worker endpoint.
// The first payload may itself be the terminal open; subsequent payloads must
// target an active endpoint and advance the inbound offset.
fn handleTerminalMuxPayload(
    ctx: TerminalMuxContext,
    stream_id: u64,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
) !void {
    const index = findTerminalMuxStreamIndex(ctx.sessions, stream_id) orelse {
        try sendTerminalMuxReset(.{
            .mux_writer = ctx.mux_writer,
            .stream_id = stream_id,
            .code = "STREAM_NOT_FOUND",
            .message = "mux stream not found",
        });
        return;
    };
    const item = payload.item orelse return error.UnexpectedFrame;
    const te_item = switch (item) {
        .terminal_emulator => |terminal_emulator| terminal_emulator,
        else => return error.UnexpectedFrame,
    };
    var stream = &ctx.sessions.items[index];
    if (te_item.payload) |te_payload| {
        if (te_payload == .open) {
            try handleTerminalMuxPayloadOpen(ctx, .{
                .stream_id = stream_id,
                .payload_offset = payload.offset,
                .open = te_payload.open,
            });
            return;
        }
    }
    if (!stream.endpoint.active()) return error.UnexpectedFrame;
    stream.inbound_next_offset = @max(stream.inbound_next_offset, payload.offset +| 1);
    if (te_item.payload) |te_payload| {
        if (te_payload == .session_hangup_request) {
            daemon_log.infof(
                ctx.allocator,
                "remote terminal hangup requested stream_id={} session={s}",
                .{ stream_id, stream.session_guid },
            );
        }
    }
    try queueTerminalWorkerItem(ctx.allocator, stream, te_item);
    if (ctx.daemon_dispatcher) |d| {
        // Queueing is enough for correctness, but an immediate nonblocking
        // flush keeps in-daemon workers responsive even when no other tunnel
        // event is about to wake this mux task.
        _ = try stream.endpoint.drainWrites(d);
    }
}

pub fn drainTerminalWorkerWrites(
    stream: *TerminalMuxStream,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !dispatch_io.SinkWriteStatus {
    return stream.endpoint.drainWrites(daemon_dispatcher);
}

fn queueTerminalWorkerPayload(
    allocator: std.mem.Allocator,
    stream: *TerminalMuxStream,
    payload: protocol.TerminalEmulatorPayload,
) !void {
    try queueTerminalWorkerItem(allocator, stream, .{ .payload = payload });
}

fn queueTerminalWorkerItem(
    allocator: std.mem.Allocator,
    stream: *TerminalMuxStream,
    item: pb.TerminalEmulatorItem,
) !void {
    const encoded = try protocol.encodeTerminalEmulatorItemPayload(allocator, item);
    defer allocator.free(encoded);
    stream.endpoint.writeFrame(.client_remote, encoded) catch |err| switch (err) {
        error.WorkerEndpointWriterMissing => return error.TerminalWorkerWriterMissing,
        else => return err,
    };
}

pub const ForwardTerminalRemoteFrameToMuxOptions = struct {
    allocator: std.mem.Allocator,
    mux_writer: *dispatch_io.FrameSink,
    stream: *TerminalMuxStream,
    frame: *protocol.OwnedFrame,
};

/// Forward one frame from the terminal worker endpoint to its mux stream. Returns
/// false when the worker produced a terminal error or final session state that
/// should close the stream locally.
pub fn forwardTerminalRemoteFrameToMux(options: ForwardTerminalRemoteFrameToMuxOptions) !bool {
    const allocator = options.allocator;
    const mux_writer = options.mux_writer;
    const stream = options.stream;
    const frame = options.frame;
    if (frame.message_type == .error_message) {
        try sendTerminalMuxReset(.{
            .mux_writer = mux_writer,
            .stream_id = stream.stream_id,
            .code = "REMOTE_PROCESS_ERROR",
            .message = "terminal worker process error",
        });
        return false;
    }
    if (frame.message_type != .client_remote) return error.UnexpectedFrame;
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
    defer item.deinit(allocator);
    try sendTerminalMuxPayload(mux_writer, stream, item);
    stream.outbound_next_offset +|= 1;
    if (item.payload) |item_payload| {
        if (item_payload == .session_ready and !stream.session_ready_logged) {
            stream.session_ready_logged = true;
            daemon_log.infof(
                allocator,
                "terminal session ready stream_id={} session={s}",
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
            try sendTerminalMuxEof(mux_writer, stream.stream_id, stream.outbound_next_offset);
        }
    }
    return true;
}

pub fn findTerminalMuxStreamIndexBySource(sessions: *const std.ArrayList(TerminalMuxStream), source: dispatcher.Source) ?usize {
    for (sessions.items, 0..) |stream, index| {
        if (!stream.endpoint.source.isInitialized()) continue;
        if (stream.endpoint.source.eql(source)) return index;
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
    ctx: TerminalMuxContext,
    stream_id: u64,
) !void {
    const index = findTerminalMuxStreamIndex(ctx.sessions, stream_id) orelse return;
    const stream = ctx.sessions.swapRemove(index);
    daemon_log.infof(
        ctx.allocator,
        "terminal mux stream closing stream_id={} session={s}",
        .{ stream.stream_id, stream.session_guid },
    );
    closeTerminalMuxStream(.{
        .allocator = ctx.allocator,
        .stream = stream,
        .send_hangup = true,
        .daemon_dispatcher = ctx.daemon_dispatcher,
    });
}

fn sendTerminalMuxOpenOk(mux_writer: *dispatch_io.FrameSink, stream_id: u64) !void {
    try sendTerminalMuxFrame(mux_writer, protocol.muxStreamOpenOkFrame(stream_id, 0));
}

fn sendTerminalMuxPayload(
    mux_writer: *dispatch_io.FrameSink,
    stream: *const TerminalMuxStream,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendTerminalMuxFrame(mux_writer, protocol.terminalMuxPayloadFrame(
        stream.stream_id,
        stream.outbound_next_offset,
        item,
    ));
}

fn sendTerminalMuxEof(mux_writer: *dispatch_io.FrameSink, stream_id: u64, final_offset: u64) !void {
    try sendTerminalMuxFrame(mux_writer, protocol.muxStreamEofFrame(stream_id, final_offset));
}

const TerminalMuxResetOptions = struct {
    mux_writer: *dispatch_io.FrameSink,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
};

fn sendTerminalMuxReset(options: TerminalMuxResetOptions) !void {
    try options.mux_writer.writeMuxStreamFrame(protocol.muxStreamResetFrame(
        options.stream_id,
        options.code,
        options.message,
    ));
}

const TerminalMuxResetForErrorOptions = struct {
    allocator: std.mem.Allocator,
    mux_writer: *dispatch_io.FrameSink,
    stream_id: u64,
    code: []const u8,
    err: anyerror,
};

fn sendTerminalMuxResetForError(options: TerminalMuxResetForErrorOptions) !void {
    const message = try std.fmt.allocPrint(options.allocator, "terminal mux stream failed: {t}", .{options.err});
    defer options.allocator.free(message);
    try sendTerminalMuxReset(.{
        .mux_writer = options.mux_writer,
        .stream_id = options.stream_id,
        .code = options.code,
        .message = message,
    });
}

fn sendTerminalMuxFrame(mux_writer: *dispatch_io.FrameSink, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    try mux_writer.writeMuxStreamFrame(message);
}

fn queueTerminalHangupAndCloseEndpoint(
    allocator: std.mem.Allocator,
    endpoint: *worker_endpoint.Endpoint,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    // Client disconnect is represented by closing the client endpoint after a
    // hang-up request frame. The terminal worker then closes the PTY, matching
    // sshd's behavior when a session's client connection disappears.
    var fd = core_fds.OwnedFd.init(endpoint.takeFd(daemon_dispatcher));
    if (fd.get() < 0) return;
    defer fd.deinit();

    const payload = try protocol.encodeTerminalEmulatorItemPayload(allocator, .{ .payload = .{ .session_hangup_request = .{} } });
    defer allocator.free(payload);
    try one_shot_frame_writer.registerFrameAndClose(.{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .fd = fd.get(),
        .message_type = .client_remote,
        .payload = payload,
    });
    _ = fd.take();
}

fn connectTerminalWorkerForOpen(
    allocator: std.mem.Allocator,
    request: pb.TerminalEmulatorItem.Open,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !c.fd_t {
    if (!guid_ref.isValidSessionGuid(request.session_guid)) return error.InvalidSessionGuid;
    return terminal_worker.connectTerminalWorker(allocator, daemon_dispatcher, request.session_guid);
}

const StartTerminalWorkerRequest = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    session_open_payload: []const u8,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
};

// Start the worker that will own the PTY, then immediately connect to it so the
// mux open can finish without exposing a create-without-client state.
fn startTerminalWorkerAndConnect(request: StartTerminalWorkerRequest) !c.fd_t {
    const allocator = request.allocator;
    const started_ms = std.time.milliTimestamp();
    var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, allocator, request.session_open_payload);
    defer open.deinit(allocator);
    if (open.create == null) return error.MissingSessionCreate;
    const guid = if (open.session_guid.len > 0)
        try guid_ref.canonicalSessionGuid(allocator, open.session_guid)
    else
        try guid_ref.generateSessionGuid(allocator);
    defer allocator.free(guid);

    daemon_log.infof(allocator, "terminal session creating session={s}", .{guid});
    const uses_daemon_worker = terminalOpenUsesInDaemonWorker(open);
    const control = if (uses_daemon_worker)
        try terminal_worker.startTerminalWorkerInDaemon(allocator, request.daemon_dispatcher orelse return error.MissingDispatcher, guid)
    else
        try terminal_worker_process.start(allocator, request.exe, guid);
    const process_fd = terminal_worker.connectStartedTerminalWorker(control, request.daemon_dispatcher) catch |err| {
        if (uses_daemon_worker) {
            terminal_worker.destroyInDaemonTerminalWorker(control, request.daemon_dispatcher.?);
        }
        return err;
    };
    daemon_log.infof(
        allocator,
        "terminal worker connected session={s} isolation_mode={s} elapsed_ms={}",
        .{ guid, terminalIsolationModeName(open), elapsedMsSince(started_ms) },
    );
    return process_fd;
}

fn terminalOpenUsesInDaemonWorker(request: pb.TerminalEmulatorItem.Open) bool {
    return switch (request.isolation_mode) {
        .ISOLATION_MODE_FULL, .ISOLATION_MODE_NONE => true,
        else => false,
    };
}

fn terminalIsolationModeName(request: pb.TerminalEmulatorItem.Open) []const u8 {
    return switch (request.isolation_mode) {
        .ISOLATION_MODE_FULL => "full",
        .ISOLATION_MODE_NONE => "none",
        else => "process",
    };
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
        try appendEnvironmentEntry(allocator, request, .{
            .name = entry[0..equals],
            .value = entry[equals + 1 ..],
        });
    }
}

const EnvironmentEntryBytes = struct {
    name: []const u8,
    value: []const u8,
};

fn appendEnvironmentEntry(
    allocator: std.mem.Allocator,
    request: *pb.TerminalEmulatorItem.SessionCreate,
    entry: EnvironmentEntryBytes,
) !void {
    const name = try allocator.dupe(u8, entry.name);
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, entry.value);
    errdefer allocator.free(value);
    try request.environment.append(allocator, .{
        .name = name,
        .value = value,
    });
}

const OneShotErrorClient = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: *core_fds.OwnedFd,

    fn queue(self: OneShotErrorClient, code: []const u8, message: []const u8) !void {
        const payload = try protocol.encodeErrorPayload(self.allocator, .{
            .code = code,
            .message = message,
        });
        defer self.allocator.free(payload);
        try one_shot_frame_writer.registerFrameAndClose(.{
            .allocator = self.allocator,
            .daemon_dispatcher = self.daemon_dispatcher,
            .fd = self.fd.get(),
            .message_type = .error_message,
            .payload = payload,
        });
        _ = self.fd.take();
    }

    fn queueProtocolError(self: OneShotErrorClient, message: []const u8) !void {
        try self.queue("PROTOCOL_ERROR", message);
    }

    fn queueSessionNotFound(self: OneShotErrorClient) !void {
        try self.queue("SESSION_NOT_FOUND", "session not found");
    }
};

test "terminal mux close without dispatcher closes endpoint without blocking hangup" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    closeTerminalMuxStream(.{
        .allocator = std.testing.allocator,
        .stream = .{
            .stream_id = 1,
            .endpoint = .{ .fd = fds[1] },
            .cleanup_recorded = false,
        },
        .send_hangup = true,
        .daemon_dispatcher = null,
    });

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[0], &byte, byte.len));
}

test "terminal mux close queues hangup through dispatcher when available" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    closeTerminalMuxStream(.{
        .allocator = std.testing.allocator,
        .stream = .{
            .stream_id = 1,
            .endpoint = .{ .fd = fds[1] },
            .cleanup_recorded = false,
        },
        .send_hangup = true,
        .daemon_dispatcher = &d,
    });
    _ = try d.loopForBlocking();

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_remote, frame.message_type);
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.TerminalEmulatorPayload{ .session_hangup_request = .{} }, item.payload.?);
}

test "terminal mux close after cleanup record sends no startup hangup" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    closeTerminalMuxStream(.{
        .allocator = std.testing.allocator,
        .stream = .{
            .stream_id = 1,
            .endpoint = .{ .fd = fds[1] },
            .cleanup_recorded = true,
        },
        .send_hangup = true,
        .daemon_dispatcher = null,
    });

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[0], &byte, byte.len));
}
