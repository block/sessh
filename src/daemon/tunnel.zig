// Remote daemon-tunnel endpoint. This module owns mux connection registration
// and dispatches opened logical streams to terminal-session or proxy-stream
// handlers while preserving cleanup identity ordering.
const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const mux_tunnel = @import("../transport/mux_tunnel.zig");

const pb = protocol.pb;

// One daemon-to-daemon SSH tunnel. The fd carries sessh frames for multiple
// logical streams; `remote_streams` owns the pending stream ids and the worker
// processes that implement terminal/proxy streams on this machine.
const MuxConnection = struct {
    allocator: std.mem.Allocator,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    counted_active: bool = false,
    mux_fd: c.fd_t = -1,
    mux_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    mux_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    remote_streams: MuxRemoteStreams = .{},

    fn deinit(self: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        // A mux connection owns every stream registered on that daemon-to-daemon
        // tunnel. Closing it tears down terminal and proxy stream endpoints
        // before dropping the shared fd/watch.
        self.task.deinit();
        self.mux_source.deinit();
        self.mux_sink.deinit();
        self.remote_streams.closeAll(self.allocator, daemon_dispatcher);
        if (self.mux_fd >= 0) {
            _ = c.close(self.mux_fd);
            self.mux_fd = -1;
        }
        if (self.counted_active) {
            active_mux_connections -= 1;
            self.counted_active = false;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const PendingMuxStream = struct {
    stream_id: u64,
    envelope_open: ?pb.DaemonTunnelItem.MuxStreamFrame.Open = null,
};

// Streams opened by one mux connection. `MuxStreamFrame` is the mux envelope:
// it carries stream id, offsets, and close/reset state. `Payload.item` is the
// typed payload inside that envelope. A stream starts in `pending` when the
// envelope open arrives before the first typed payload; that payload chooses
// the terminal or proxy owner, and later frames are dispatched by stream id.
const MuxRemoteStreams = struct {
    pending: std.ArrayList(PendingMuxStream) = .empty,
    terminal: std.ArrayList(session_daemon_handler.TerminalMuxStream) = .empty,
    proxy: std.ArrayList(proxy_worker.ProxyMuxStream) = .empty,

    fn closeAll(self: *MuxRemoteStreams, allocator: std.mem.Allocator, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        self.pending.deinit(allocator);
        session_daemon_handler.closeTerminalMuxStreams(allocator, &self.terminal, daemon_dispatcher);
        proxy_worker.closeProxyMuxStreams(allocator, &self.proxy, daemon_dispatcher);
    }

    fn deinitForTest(self: *MuxRemoteStreams, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        self.terminal.deinit(allocator);
        self.proxy.deinit(allocator);
    }

    // Add every live worker fd to the mux task. The same task also watches the
    // shared mux fd, so bytes from either side of the bridge are processed by
    // one state machine instead of competing event loops.
    fn requireSources(self: *const MuxRemoteStreams, task: *dispatcher.DispatchTask) !void {
        for (self.terminal.items) |stream| {
            if (stream.endpoint.dispatch_source.isInitialized()) try task.requireSource(stream.endpoint.dispatch_source);
        }
        for (self.proxy.items) |stream| {
            if (stream.endpoint.dispatch_source.isInitialized()) try task.requireSource(stream.endpoint.dispatch_source);
        }
    }

    // Return the first worker readiness event already captured by Dispatcher.
    // The caller loops on this so multiple ready workers are drained fairly
    // during the same task run without exposing terminal/proxy array details.
    fn nextReadySource(self: *const MuxRemoteStreams) ?ReadyRemoteSource {
        for (self.terminal.items) |stream| {
            if (!stream.endpoint.dispatch_source.isInitialized()) continue;
            if (stream.endpoint.dispatch_source.takeFdEvent()) |event| {
                return .{ .terminal = .{ .source = stream.endpoint.dispatch_source, .event = event } };
            }
        }
        for (self.proxy.items) |stream| {
            if (!stream.endpoint.dispatch_source.isInitialized()) continue;
            if (stream.endpoint.dispatch_source.takeFdEvent()) |event| {
                return .{ .proxy = .{ .source = stream.endpoint.dispatch_source, .event = event } };
            }
        }
        return null;
    }

    // A cleanup record is keyed by mux stream id, not by worker type. Mark both
    // registries because ids are unique within the tunnel and only one side can
    // match.
    fn markCleanupRecorded(self: *MuxRemoteStreams, stream_id: u64) void {
        if (session_daemon_handler.findTerminalMuxStreamIndex(&self.terminal, stream_id)) |index| {
            self.terminal.items[index].cleanup_recorded = true;
        }
        if (proxy_worker.findProxyMuxStreamIndex(&self.proxy, stream_id)) |index| {
            self.proxy.items[index].cleanup_recorded = true;
        }
    }

    fn saveEnvelopeOpen(self: *MuxRemoteStreams, allocator: std.mem.Allocator, stream_id: u64, open: pb.DaemonTunnelItem.MuxStreamFrame.Open) !void {
        if (self.findPendingIndex(stream_id)) |index| {
            self.pending.items[index].envelope_open = open;
            return;
        }
        try self.pending.append(allocator, .{
            .stream_id = stream_id,
            .envelope_open = open,
        });
    }

    fn takeEnvelopeOpen(self: *MuxRemoteStreams, stream_id: u64) ?pb.DaemonTunnelItem.MuxStreamFrame.Open {
        const index = self.findPendingIndex(stream_id) orelse return null;
        const pending = self.pending.swapRemove(index);
        return pending.envelope_open;
    }

    fn forgetPending(self: *MuxRemoteStreams, stream_id: u64) void {
        const index = self.findPendingIndex(stream_id) orelse return;
        _ = self.pending.swapRemove(index);
    }

    fn findPendingIndex(self: *const MuxRemoteStreams, stream_id: u64) ?usize {
        for (self.pending.items, 0..) |stream, index| {
            if (stream.stream_id == stream_id) return index;
        }
        return null;
    }
};

const StreamOwner = enum {
    terminal,
    proxy,
};

const ReadyRemoteSourceEvent = struct {
    source: dispatcher.Source,
    event: dispatcher.FdEvent,
};

const ReadyRemoteSource = union(enum) {
    terminal: ReadyRemoteSourceEvent,
    proxy: ReadyRemoteSourceEvent,
};

// PROCESS_GLOBAL_REGISTRY: one daemon-to-daemon mux connection is useful work
// even if its terminal/proxy worker registry is temporarily empty. Idle
// shutdown should not close a remote daemon while the local daemon still holds
// an active tunnel to it.
var active_mux_connections: usize = 0;

pub fn activeMuxConnectionCount() usize {
    return active_mux_connections;
}

pub const RegisterMuxConnectionOptions = struct {
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    initial_frames: []const protocol.OwnedFrame,
    fd: c.fd_t,
};

/// Take ownership of a daemon-to-daemon tunnel fd and start routing multiplexed
/// stream frames. Any frames already read by the generic client router are
/// processed before the fd watch is installed, preserving wire order.
pub fn registerMuxConnectionFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    options: RegisterMuxConnectionOptions,
) !void {
    const connection = try allocator.create(MuxConnection);
    errdefer allocator.destroy(connection);
    connection.* = .{
        .allocator = allocator,
        .terminal_remote_exe = options.terminal_remote_exe,
        .proxy_remote_exe = options.proxy_remote_exe,
        .identity = options.identity,
        .counted_active = true,
        .mux_fd = options.fd,
    };
    active_mux_connections += 1;
    errdefer connection.deinit(daemon_dispatcher);

    try core_fds.setNonBlocking(options.fd);
    connection.mux_source = try daemon_dispatcher.frameSource(options.fd);
    connection.mux_sink = try daemon_dispatcher.frameSink(.{ .allocator = allocator, .fd = options.fd });
    connection.task = dispatcher.dispatchTask(MuxConnection, allocator, connection, runMuxConnectionTask);
    connection.task.setSourceReadiness(.any);
    for (options.initial_frames) |frame| {
        try handleMuxConnectionFrame(connection, daemon_dispatcher, frame);
    }
    try refreshMuxConnectionTask(connection, daemon_dispatcher);
}

const ConnectionEventResult = enum {
    alive,
    closed,
};

fn runMuxConnectionTask(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    // Process complete frames from the shared daemon tunnel first, then process
    // frames/events from worker processes. Both directions can enqueue writes
    // to `mux_sink`; requiring that Sink on the task lets Dispatcher apply
    // backpressure before scheduling more reads.
    switch (readMuxConnectionInner(connection, daemon_dispatcher) catch |err| {
        daemon_log.infof(connection.allocator, "daemon mux connection failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
        return .done;
    }) {
        .alive => {},
        .closed => return .done,
    }

    while (connection.remote_streams.nextReadySource()) |ready| {
        switch (readRemoteProcessInner(connection, daemon_dispatcher, ready) catch |err| {
            daemon_log.infof(connection.allocator, "mux remote process failed error={t}", .{err});
            connection.deinit(daemon_dispatcher);
            return .done;
        }) {
            .alive => {},
            .closed => return .done,
        }
    }

    try refreshMuxConnectionTask(connection, daemon_dispatcher);
    return .pending;
}

// Event-loop body for the daemon tunnel fd. The dispatcher-owned FrameSink
// handles writes and backpressure; this task only consumes complete mux frames
// that the dispatcher-owned FrameSource has assembled.
fn readMuxConnectionInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !ConnectionEventResult {
    while (true) {
        var frame = switch (connection.mux_source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                daemon_log.infof(connection.allocator, "daemon mux connection closing reason=truncated_frame", .{});
                connection.deinit(daemon_dispatcher);
                return .closed;
            },
            else => return err,
        }) {
            .blocked => return .alive,
            .eof => {
                daemon_log.infof(connection.allocator, "daemon mux connection closing reason=eof", .{});
                connection.deinit(daemon_dispatcher);
                return .closed;
            },
            .frame => |frame_value| frame_value,
        };
        defer frame.deinit(connection.allocator);
        try handleMuxConnectionFrame(connection, daemon_dispatcher, frame);
    }
}

fn refreshMuxConnectionTask(connection: *MuxConnection, daemon_dispatcher: *dispatcher.Dispatcher) !void {
    connection.task.clearSources();
    connection.task.clearSinks();
    try connection.task.requireSource(connection.mux_source);
    try connection.task.requireSink(connection.mux_sink);
    try connection.remote_streams.requireSources(&connection.task);
    try connection.task.schedule(daemon_dispatcher);
}

// Handle tunnel-level control messages before stream dispatch. Mux stream frames
// are either delivered to an existing terminal/proxy owner, recorded as a
// pending envelope open, or used to create the owner named by the first typed
// payload.
fn handleMuxConnectionFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
) !void {
    defer refreshMuxConnectionTask(connection, daemon_dispatcher) catch |err| {
        daemon_log.infof(connection.allocator, "daemon mux watch update failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };

    if (try handleMuxTransportControlFrame(connection, frame.message_type, frame.payload)) return;
    if (frame.message_type != .daemon_tunnel) return error.UnexpectedDaemonMuxFrame;

    var item = try protocol.decodePayload(pb.DaemonTunnelItem, connection.allocator, frame.payload);
    defer item.deinit(connection.allocator);
    const payload = item.payload orelse return error.UnexpectedDaemonMuxFrame;
    switch (payload) {
        .remote_process_recorded => |recorded| {
            markCleanupRecorded(connection, recorded.stream_id);
            return;
        },
        .remote_process_cleanup_request => |request| {
            try daemon_cleanup.handleRemoteProcessCleanupRequestQueued(.{
                .allocator = connection.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .mux_writer = muxWriter(connection),
                .identity = connection.identity,
                .request = request,
            });
            return;
        },
        .mux_stream => |mux| {
            item.payload = null;
            try handleMuxStreamFrame(connection, daemon_dispatcher, mux);
        },
        else => return error.UnexpectedDaemonMuxFrame,
    }
}

fn handleMuxTransportControlFrame(
    connection: *MuxConnection,
    message_type: protocol.MessageType,
    payload: []const u8,
) !bool {
    switch (try protocol.decodeTransportControlFrame(connection.allocator, message_type, payload) orelse return false) {
        .ping => {
            try muxWriter(connection).writeDaemonTunnelPayload(.{ .pong = .{} });
            return true;
        },
        .pong => return true,
    }
}

// Route one logical mux-stream frame through the owner chosen during stream
// startup.
fn handleMuxStreamFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const stream_id = mux_frame.stream_id;

    if (terminalStreamExists(connection, stream_id)) {
        if (payloadOwner(mux_frame) == .proxy) return changedMuxStreamOwner(connection, stream_id, mux_frame);
        try dispatchTerminalMuxStreamFrame(connection, daemon_dispatcher, mux_frame);
        return;
    }
    if (proxyStreamExists(connection, stream_id)) {
        if (payloadOwner(mux_frame) == .terminal) return changedMuxStreamOwner(connection, stream_id, mux_frame);
        try dispatchProxyMuxStreamFrame(connection, daemon_dispatcher, mux_frame);
        return;
    }

    const message = mux_frame.message orelse {
        var owned = mux_frame;
        owned.deinit(connection.allocator);
        return error.UnexpectedDaemonMuxFrame;
    };
    switch (message) {
        .open => |open| {
            try connection.remote_streams.saveEnvelopeOpen(connection.allocator, stream_id, open);
            var owned = mux_frame;
            owned.deinit(connection.allocator);
        },
        .payload => |payload| {
            const owner = ownerFromPayload(payload) orelse {
                var owned = mux_frame;
                owned.deinit(connection.allocator);
                return error.UnexpectedDaemonMuxFrame;
            };
            const envelope_open = connection.remote_streams.takeEnvelopeOpen(stream_id) orelse pb.DaemonTunnelItem.MuxStreamFrame.Open{};
            switch (owner) {
                .terminal => {
                    try session_daemon_handler.handleTerminalMuxOpen(terminalMuxContext(connection, daemon_dispatcher), stream_id);
                    try dispatchTerminalMuxStreamFrame(connection, daemon_dispatcher, mux_frame);
                },
                .proxy => {
                    try proxy_worker.handleProxyMuxOpen(proxyMuxContext(connection, daemon_dispatcher), stream_id, envelope_open);
                    try dispatchProxyMuxStreamFrame(connection, daemon_dispatcher, mux_frame);
                },
            }
        },
        .ack, .open_ok, .eof, .reset => {
            connection.remote_streams.forgetPending(stream_id);
            var owned = mux_frame;
            owned.deinit(connection.allocator);
            return error.UnexpectedDaemonMuxFrame;
        },
    }
}

fn terminalStreamExists(connection: *MuxConnection, stream_id: u64) bool {
    return session_daemon_handler.findTerminalMuxStreamIndex(&connection.remote_streams.terminal, stream_id) != null;
}

fn proxyStreamExists(connection: *MuxConnection, stream_id: u64) bool {
    return proxy_worker.findProxyMuxStreamIndex(&connection.remote_streams.proxy, stream_id) != null;
}

fn changedMuxStreamOwner(connection: *MuxConnection, stream_id: u64, mux_frame: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    var owned = mux_frame;
    defer owned.deinit(connection.allocator);
    try muxWriter(connection).writeMuxStreamFrame(protocol.muxStreamResetFrame(
        stream_id,
        "PROTOCOL_ERROR",
        "mux stream changed payload type",
    ));
    return error.UnexpectedDaemonMuxFrame;
}

fn ownerFromPayload(payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload) ?StreamOwner {
    const item = payload.item orelse return null;
    return switch (item) {
        .terminal_emulator => .terminal,
        .proxy => .proxy,
    };
}

fn payloadOwner(mux_frame: pb.DaemonTunnelItem.MuxStreamFrame) ?StreamOwner {
    return switch (mux_frame.message orelse return null) {
        .payload => |payload| ownerFromPayload(payload),
        else => null,
    };
}

fn terminalMuxContext(connection: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) session_daemon_handler.TerminalMuxContext {
    return .{
        .allocator = connection.allocator,
        .exe = connection.terminal_remote_exe,
        .identity = connection.identity,
        .sessions = &connection.remote_streams.terminal,
        .mux_writer = muxWriter(connection),
        .daemon_dispatcher = daemon_dispatcher,
    };
}

fn proxyMuxContext(connection: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) proxy_worker.ProxyMuxContext {
    return .{
        .allocator = connection.allocator,
        .exe = connection.proxy_remote_exe,
        .identity = connection.identity,
        .streams = &connection.remote_streams.proxy,
        .mux_writer = muxWriter(connection),
        .daemon_dispatcher = daemon_dispatcher,
    };
}

fn muxWriter(connection: *MuxConnection) *dispatch_io.FrameSink {
    return connection.mux_sink.frame();
}

fn dispatchTerminalMuxStreamFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try session_daemon_handler.handleTerminalMuxStreamFrame(
        terminalMuxContext(connection, daemon_dispatcher),
        mux_frame,
    );
}

fn dispatchProxyMuxStreamFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try proxy_worker.handleProxyMuxStreamFrame(
        proxyMuxContext(connection, daemon_dispatcher),
        mux_frame,
    );
}

fn markCleanupRecorded(connection: *MuxConnection, stream_id: u64) void {
    connection.remote_streams.markCleanupRecorded(stream_id);
}

test "active mux connection count follows connection lifetime" {
    const allocator = std.testing.allocator;
    const before = activeMuxConnectionCount();
    const connection = try allocator.create(MuxConnection);
    connection.* = .{
        .allocator = allocator,
        .terminal_remote_exe = "",
        .proxy_remote_exe = "",
        .identity = .{ .pid = 0, .start_time = "", .socket_path = "" },
        .counted_active = true,
    };
    active_mux_connections += 1;
    try std.testing.expectEqual(before + 1, activeMuxConnectionCount());

    connection.deinit(null);
    try std.testing.expectEqual(before, activeMuxConnectionCount());
}

test "pending mux stream stores envelope open until first typed payload chooses owner" {
    const allocator = std.testing.allocator;
    var streams = MuxRemoteStreams{};
    defer streams.deinitForTest(allocator);

    try streams.saveEnvelopeOpen(allocator, 9, .{ .recv_next_offset = 42 });
    try std.testing.expectEqual(@as(usize, 1), streams.pending.items.len);
    try streams.saveEnvelopeOpen(allocator, 9, .{ .recv_next_offset = 43 });
    try std.testing.expectEqual(@as(usize, 1), streams.pending.items.len);

    const open = streams.takeEnvelopeOpen(9) orelse return error.ExpectedEnvelopeOpen;
    try std.testing.expectEqual(@as(u64, 43), open.recv_next_offset);
    try std.testing.expect(streams.takeEnvelopeOpen(9) == null);
    try std.testing.expectEqual(@as(usize, 0), streams.pending.items.len);
}

test "remote process recorded marks only matching terminal stream cleanup recorded" {
    const allocator = std.testing.allocator;
    var connection = MuxConnection{
        .allocator = allocator,
        .terminal_remote_exe = "",
        .proxy_remote_exe = "",
        .identity = .{ .pid = 0, .start_time = "", .socket_path = "" },
    };
    defer {
        connection.remote_streams.deinitForTest(allocator);
    }

    try connection.remote_streams.terminal.append(allocator, .{ .stream_id = 1 });
    try connection.remote_streams.terminal.append(allocator, .{ .stream_id = 2 });
    try connection.remote_streams.proxy.append(allocator, .{ .stream_id = 1, .open = .{} });

    markCleanupRecorded(&connection, 1);

    try std.testing.expect(connection.remote_streams.terminal.items[0].cleanup_recorded);
    try std.testing.expect(!connection.remote_streams.terminal.items[1].cleanup_recorded);
    try std.testing.expect(connection.remote_streams.proxy.items[0].cleanup_recorded);
}

test "remote process recorded before stream open is ignored until stream exists" {
    const allocator = std.testing.allocator;
    var connection = MuxConnection{
        .allocator = allocator,
        .terminal_remote_exe = "",
        .proxy_remote_exe = "",
        .identity = .{ .pid = 0, .start_time = "", .socket_path = "" },
    };
    defer {
        connection.remote_streams.deinitForTest(allocator);
    }

    markCleanupRecorded(&connection, 7);
    try connection.remote_streams.terminal.append(allocator, .{ .stream_id = 7 });
    try connection.remote_streams.proxy.append(allocator, .{ .stream_id = 7, .open = .{} });

    try std.testing.expect(!connection.remote_streams.terminal.items[0].cleanup_recorded);
    try std.testing.expect(!connection.remote_streams.proxy.items[0].cleanup_recorded);
}

fn readRemoteProcessInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    ready: ReadyRemoteSource,
) !ConnectionEventResult {
    return switch (ready) {
        .terminal => |terminal| readTerminalRemoteInner(connection, daemon_dispatcher, terminal.source, terminal.event),
        .proxy => |proxy| readProxyRemoteInner(connection, daemon_dispatcher, proxy.source, proxy.event),
    };
}

// Bridge frames from a terminal remote worker back into the daemon tunnel. If
// the worker closes before sending its terminal-ended frame, the entire mux
// connection is considered suspect because the remote PTY may still need cleanup.
fn readTerminalRemoteInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    source: dispatcher.Source,
    fd_event: dispatcher.FdEvent,
) !ConnectionEventResult {
    const stream_index = session_daemon_handler.findTerminalMuxStreamIndexBySource(&connection.remote_streams.terminal, source) orelse return .alive;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        return closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
    }

    if (fd_event.writable) {
        const stream = &connection.remote_streams.terminal.items[stream_index];
        switch (try session_daemon_handler.drainTerminalWorkerWrites(stream, daemon_dispatcher)) {
            .blocked, .progress => if (!fd_event.readable) return .alive,
            .drained => {},
        }
    }

    if (!fd_event.readable) return .alive;

    while (true) {
        const current_index = session_daemon_handler.findTerminalMuxStreamIndexBySource(&connection.remote_streams.terminal, source) orelse return .alive;
        var stream = &connection.remote_streams.terminal.items[current_index];
        var frame = switch (stream.endpoint.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                return closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
            },
            else => return err,
        }) {
            .blocked => return .alive,
            .eof => {
                return closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
            },
            .frame => |frame| frame,
        };
        defer frame.deinit(connection.allocator);
        if (try session_daemon_handler.forwardTerminalRemoteFrameToMux(.{
            .allocator = connection.allocator,
            .mux_writer = muxWriter(connection),
            .stream = stream,
            .frame = &frame,
        })) {
            continue;
        }
        return closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
    }
}

fn closeTerminalRemoteAfterProcessClose(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_index: usize,
) ConnectionEventResult {
    // Terminal workers normally send an ended frame before their process socket
    // closes. If the socket closes first, treat the whole mux connection as
    // suspect; otherwise remove just the completed stream endpoint.
    const stream_id = connection.remote_streams.terminal.items[stream_index].stream_id;
    if (!connection.remote_streams.terminal.items[stream_index].ended) {
        daemon_log.infof(
            connection.allocator,
            "terminal mux connection closing after remote process transport closed stream_id={} session={s}",
            .{ stream_id, connection.remote_streams.terminal.items[stream_index].session_guid },
        );
        connection.deinit(daemon_dispatcher);
        return .closed;
    }
    const stream = connection.remote_streams.terminal.swapRemove(stream_index);
    session_daemon_handler.closeTerminalMuxStream(.{
        .allocator = connection.allocator,
        .stream = stream,
        .send_hangup = false,
        .daemon_dispatcher = daemon_dispatcher,
    });
    return .alive;
}

// Bridge frames from a proxy remote worker back into the daemon tunnel. Proxy
// workers can also send local control frames that only affect their process-side
// write queue, so those are handled before forwarding stream data.
fn readProxyRemoteInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    source: dispatcher.Source,
    fd_event: dispatcher.FdEvent,
) !ConnectionEventResult {
    const stream_index = proxy_worker.findProxyMuxStreamIndexBySource(&connection.remote_streams.proxy, source) orelse return .alive;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
        return .alive;
    }
    if (fd_event.writable) {
        const stream = &connection.remote_streams.proxy.items[stream_index];
        switch (try proxy_worker.drainProxyProcessWrites(stream, daemon_dispatcher)) {
            .blocked, .progress => if (!fd_event.readable) return .alive,
            .drained => {},
        }
    }
    if (!fd_event.readable) return .alive;

    while (true) {
        const current_index = proxy_worker.findProxyMuxStreamIndexBySource(&connection.remote_streams.proxy, source) orelse return .alive;
        var stream = &connection.remote_streams.proxy.items[current_index];
        var frame = switch (stream.endpoint.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return .alive;
            },
            else => return err,
        }) {
            .blocked => return .alive,
            .eof => {
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return .alive;
            },
            .frame => |frame| frame,
        };
        defer frame.deinit(connection.allocator);
        if (try proxy_worker.handleProxyRemoteControlFrame(connection.allocator, stream, &frame)) {
            _ = try proxy_worker.drainProxyProcessWrites(stream, daemon_dispatcher);
            continue;
        }
        if (try proxy_worker.forwardProxyRemoteFrameToMux(.{
            .allocator = connection.allocator,
            .mux_writer = muxWriter(connection),
            .stream = stream,
            .frame = &frame,
        })) {
            continue;
        }
        closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
        return .alive;
    }
}

fn closeProxyRemoteAfterProcessClose(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_index: usize,
) void {
    const stream = connection.remote_streams.proxy.swapRemove(stream_index);
    muxWriter(connection).writeMuxStreamFrame(protocol.muxStreamResetFrame(stream.stream_id, "REMOTE_PROCESS_CLOSED", "remote proxy process closed")) catch {};
    proxy_worker.closeProxyMuxStream(.{
        .allocator = connection.allocator,
        .stream = stream,
        .send_startup_failed = false,
        .daemon_dispatcher = daemon_dispatcher,
    });
}
