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
    stream_registry: mux_tunnel.StreamRegistry,
    remote_streams: MuxRemoteStreams = .{},

    fn deinit(self: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        // A mux connection owns every stream registered on that daemon-to-daemon
        // tunnel. Closing it tears down terminal and proxy stream endpoints
        // before dropping the shared fd/watch.
        self.task.deinit();
        self.mux_source.deinit();
        self.mux_sink.deinit();
        self.remote_streams.closeAll(self.allocator, daemon_dispatcher);
        self.stream_registry.deinit();
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

const MuxRemoteStreams = struct {
    terminal: std.ArrayList(session_daemon_handler.TerminalMuxStream) = .empty,
    proxy: std.ArrayList(proxy_worker.ProxyMuxStream) = .empty,

    fn closeAll(self: *MuxRemoteStreams, allocator: std.mem.Allocator, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        session_daemon_handler.closeTerminalMuxStreams(allocator, &self.terminal, daemon_dispatcher);
        proxy_worker.closeProxyMuxStreams(allocator, &self.proxy, daemon_dispatcher);
    }

    fn deinitForTest(self: *MuxRemoteStreams, allocator: std.mem.Allocator) void {
        self.terminal.deinit(allocator);
        self.proxy.deinit(allocator);
    }

    fn requireSources(self: *const MuxRemoteStreams, task: *dispatcher.DispatchTask) !void {
        for (self.terminal.items) |stream| {
            if (stream.endpoint.dispatch_source.isInitialized()) try task.requireSource(stream.endpoint.dispatch_source);
        }
        for (self.proxy.items) |stream| {
            if (stream.endpoint.dispatch_source.isInitialized()) try task.requireSource(stream.endpoint.dispatch_source);
        }
    }

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

    fn markCleanupRecorded(self: *MuxRemoteStreams, stream_id: u64) void {
        if (session_daemon_handler.findTerminalMuxStreamIndex(&self.terminal, stream_id)) |index| {
            self.terminal.items[index].cleanup_recorded = true;
        }
        if (proxy_worker.findProxyMuxStreamIndex(&self.proxy, stream_id)) |index| {
            self.proxy.items[index].cleanup_recorded = true;
        }
    }
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
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
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

// Handle tunnel-level control messages before stream routing. Stream frames are
// handed to StreamRegistry so opens, closes, and type changes are interpreted in
// one place before dispatching to terminal or proxy owners.
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

// Route one logical mux-stream frame. Open frames may create a terminal/proxy
// worker before the same frame is dispatched, while close/reset removes the
// stream registry entry after the owner has seen the final event.
fn handleMuxStreamFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const stream_id = mux_frame.stream_id;
    const route = try mux_tunnel.routeIncomingFrame(&connection.stream_registry, mux_frame);
    switch (route) {
        .pending_open => {
            var owned = mux_frame;
            owned.deinit(connection.allocator);
            return;
        },
        .changed_kind => {
            var owned = mux_frame;
            defer owned.deinit(connection.allocator);
            try muxWriter(connection).writeMuxStreamFrame(protocol.muxStreamResetFrame(
                stream_id,
                "PROTOCOL_ERROR",
                "mux stream changed payload type",
            ));
            return error.UnexpectedDaemonMuxFrame;
        },
        .unexpected => {
            var owned = mux_frame;
            owned.deinit(connection.allocator);
            return error.UnexpectedDaemonMuxFrame;
        },
        .stream => |stream_route| {
            if (stream_route.open_before_dispatch) |open| try handleMuxStreamOpen(.{
                .connection = connection,
                .daemon_dispatcher = daemon_dispatcher,
                .stream_id = stream_id,
                .kind = stream_route.kind,
                .open = open,
            });
            try dispatchMuxStreamFrame(.{
                .connection = connection,
                .daemon_dispatcher = daemon_dispatcher,
                .kind = stream_route.kind,
                .mux_frame = mux_frame,
            });
            if (stream_route.closes_after_dispatch) connection.stream_registry.remove(stream_id);
        },
    }
}

const MuxStreamOpenDispatch = struct {
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_id: u64,
    kind: mux_tunnel.StreamKind,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
};

fn handleMuxStreamOpen(dispatch: MuxStreamOpenDispatch) !void {
    switch (dispatch.kind) {
        .terminal => try session_daemon_handler.handleTerminalMuxOpen(
            terminalMuxContext(dispatch.connection, dispatch.daemon_dispatcher),
            dispatch.stream_id,
        ),
        .proxy => try proxy_worker.handleProxyMuxOpen(
            proxyMuxContext(dispatch.connection, dispatch.daemon_dispatcher),
            dispatch.stream_id,
            dispatch.open,
        ),
        .unknown => {},
    }
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

const MuxStreamFrameDispatch = struct {
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    kind: mux_tunnel.StreamKind,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
};

fn dispatchMuxStreamFrame(dispatch: MuxStreamFrameDispatch) !void {
    const connection = dispatch.connection;
    const daemon_dispatcher = dispatch.daemon_dispatcher;
    switch (dispatch.kind) {
        .terminal => try session_daemon_handler.handleTerminalMuxStreamFrame(
            terminalMuxContext(connection, daemon_dispatcher),
            dispatch.mux_frame,
        ),
        .proxy => try proxy_worker.handleProxyMuxStreamFrame(
            proxyMuxContext(connection, daemon_dispatcher),
            dispatch.mux_frame,
        ),
        .unknown => return error.UnexpectedDaemonMuxFrame,
    }
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
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    active_mux_connections += 1;
    try std.testing.expectEqual(before + 1, activeMuxConnectionCount());

    connection.deinit(null);
    try std.testing.expectEqual(before, activeMuxConnectionCount());
}

test "remote process recorded marks only matching terminal stream cleanup recorded" {
    const allocator = std.testing.allocator;
    var connection = MuxConnection{
        .allocator = allocator,
        .terminal_remote_exe = "",
        .proxy_remote_exe = "",
        .identity = .{ .pid = 0, .start_time = "", .socket_path = "" },
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    defer {
        connection.remote_streams.deinitForTest(allocator);
        connection.stream_registry.deinit();
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
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    defer {
        connection.remote_streams.deinitForTest(allocator);
        connection.stream_registry.deinit();
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
    connection.stream_registry.remove(stream_id);
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
    connection.stream_registry.remove(stream.stream_id);
    proxy_worker.closeProxyMuxStream(.{
        .allocator = connection.allocator,
        .stream = stream,
        .send_startup_failed = false,
        .daemon_dispatcher = daemon_dispatcher,
    });
}
