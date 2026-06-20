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
const frame_write_queue = @import("../transport/frame_write_queue.zig");
const mux_tunnel = @import("../transport/mux_tunnel.zig");

const pb = protocol.pb;

const MuxConnection = struct {
    allocator: std.mem.Allocator,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    counted_active: bool = false,
    mux_fd: c.fd_t = -1,
    mux_watch_id: ?dispatcher.FdWatchId = null,
    mux_reader: protocol.FrameReader = undefined,
    mux_writer: frame_write_queue.FrameWriteQueue = undefined,
    stream_registry: mux_tunnel.StreamRegistry,
    terminal_sessions: std.ArrayList(session_daemon_handler.TerminalMuxStream) = .empty,
    proxy_streams: std.ArrayList(proxy_worker.ProxyMuxStream) = .empty,

    fn deinit(self: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            if (self.mux_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        }
        self.mux_watch_id = null;
        session_daemon_handler.closeTerminalMuxStreams(self.allocator, &self.terminal_sessions, daemon_dispatcher);
        proxy_worker.closeProxyMuxStreams(self.allocator, &self.proxy_streams, daemon_dispatcher);
        self.stream_registry.deinit();
        self.mux_writer.deinit();
        self.mux_reader.deinit();
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
        .mux_reader = protocol.FrameReader.init(allocator),
        .mux_writer = frame_write_queue.FrameWriteQueue.init(allocator),
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    active_mux_connections += 1;
    errdefer connection.deinit(daemon_dispatcher);

    try core_fds.setNonBlocking(options.fd);
    for (options.initial_frames) |frame| {
        try handleMuxConnectionFrame(connection, daemon_dispatcher, frame);
    }
    connection.mux_watch_id = try daemon_dispatcher.watchFd(.{
        .fd = options.fd,
        .events = muxWatchEvents(connection),
        .handler = .{
            .ctx = connection,
            .callback = readMuxConnection,
        },
    });
}

fn readMuxConnection(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readMuxConnectionInner(connection, daemon_dispatcher, handler_event.event) catch |err| {
        daemon_log.infof(connection.allocator, "daemon mux connection failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };
}

fn readMuxConnectionInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonMuxTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        daemon_log.infof(connection.allocator, "daemon mux connection closing reason=fd-error", .{});
        connection.deinit(daemon_dispatcher);
        return;
    }

    if (fd_event.writable) {
        switch (try connection.mux_writer.writeReady(connection.mux_fd)) {
            .blocked, .progress => {
                try updateMuxWatch(connection, daemon_dispatcher);
                if (!fd_event.readable) return;
            },
            .drained => {},
        }
    }

    if (!fd_event.readable) {
        if (fd_event.hangup) {
            daemon_log.infof(connection.allocator, "daemon mux connection closing reason=hangup", .{});
            connection.deinit(daemon_dispatcher);
            return;
        }
        try updateMuxWatch(connection, daemon_dispatcher);
        return;
    }

    while (true) {
        const status = try connection.mux_reader.readReady(connection.mux_fd);
        switch (status) {
            .blocked => {
                try updateMuxWatch(connection, daemon_dispatcher);
                return;
            },
            .progress => continue,
            .eof, .truncated_frame => {
                daemon_log.infof(connection.allocator, "daemon mux connection closing reason={s}", .{@tagName(status)});
                connection.deinit(daemon_dispatcher);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                try handleMuxConnectionFrame(connection, daemon_dispatcher, frame);
            },
        }
    }
}

fn muxWatchEvents(connection: *const MuxConnection) dispatcher.FdEvents {
    return .{
        .readable = true,
        .writable = connection.mux_writer.hasPending(),
    };
}

fn updateMuxWatch(connection: *MuxConnection, daemon_dispatcher: *dispatcher.Dispatcher) !void {
    const watch_id = connection.mux_watch_id orelse return;
    try daemon_dispatcher.updateFdEvents(watch_id, muxWatchEvents(connection));
}

fn handleMuxConnectionFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
) !void {
    defer updateMuxWatch(connection, daemon_dispatcher) catch |err| {
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
                .mux_writer = &connection.mux_writer,
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
            try connection.mux_writer.queueDaemonTunnelPayload(.{ .pong = .{} });
            return true;
        },
        .pong => return true,
    }
}

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
            try connection.mux_writer.queueMuxStreamFrame(protocol.muxStreamResetFrame(
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
        .sessions = &connection.terminal_sessions,
        .mux_writer = &connection.mux_writer,
        .process_watch_handler = .{ .ctx = connection, .callback = readTerminalRemote },
        .daemon_dispatcher = daemon_dispatcher,
    };
}

fn proxyMuxContext(connection: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) proxy_worker.ProxyMuxContext {
    return .{
        .allocator = connection.allocator,
        .exe = connection.proxy_remote_exe,
        .identity = connection.identity,
        .streams = &connection.proxy_streams,
        .mux_writer = &connection.mux_writer,
        .process_watch_handler = .{ .ctx = connection, .callback = readProxyRemote },
        .daemon_dispatcher = daemon_dispatcher,
    };
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
    if (session_daemon_handler.findTerminalMuxStreamIndex(&connection.terminal_sessions, stream_id)) |index| {
        connection.terminal_sessions.items[index].cleanup_recorded = true;
    }
    if (proxy_worker.findProxyMuxStreamIndex(&connection.proxy_streams, stream_id)) |index| {
        connection.proxy_streams.items[index].cleanup_recorded = true;
    }
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
        .mux_reader = protocol.FrameReader.init(allocator),
        .mux_writer = frame_write_queue.FrameWriteQueue.init(allocator),
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
        .mux_reader = protocol.FrameReader.init(allocator),
        .mux_writer = frame_write_queue.FrameWriteQueue.init(allocator),
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    defer {
        connection.terminal_sessions.deinit(allocator);
        connection.proxy_streams.deinit(allocator);
        connection.stream_registry.deinit();
        connection.mux_reader.deinit();
        connection.mux_writer.deinit();
    }

    try connection.terminal_sessions.append(allocator, .{ .stream_id = 1 });
    try connection.terminal_sessions.append(allocator, .{ .stream_id = 2 });
    try connection.proxy_streams.append(allocator, .{ .stream_id = 1, .open = .{} });

    markCleanupRecorded(&connection, 1);

    try std.testing.expect(connection.terminal_sessions.items[0].cleanup_recorded);
    try std.testing.expect(!connection.terminal_sessions.items[1].cleanup_recorded);
    try std.testing.expect(connection.proxy_streams.items[0].cleanup_recorded);
}

test "remote process recorded before stream open is ignored until stream exists" {
    const allocator = std.testing.allocator;
    var connection = MuxConnection{
        .allocator = allocator,
        .terminal_remote_exe = "",
        .proxy_remote_exe = "",
        .identity = .{ .pid = 0, .start_time = "", .socket_path = "" },
        .mux_reader = protocol.FrameReader.init(allocator),
        .mux_writer = frame_write_queue.FrameWriteQueue.init(allocator),
        .stream_registry = mux_tunnel.StreamRegistry.init(allocator),
    };
    defer {
        connection.terminal_sessions.deinit(allocator);
        connection.proxy_streams.deinit(allocator);
        connection.stream_registry.deinit();
        connection.mux_reader.deinit();
        connection.mux_writer.deinit();
    }

    markCleanupRecorded(&connection, 7);
    try connection.terminal_sessions.append(allocator, .{ .stream_id = 7 });
    try connection.proxy_streams.append(allocator, .{ .stream_id = 7, .open = .{} });

    try std.testing.expect(!connection.terminal_sessions.items[0].cleanup_recorded);
    try std.testing.expect(!connection.proxy_streams.items[0].cleanup_recorded);
}

fn readTerminalRemote(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readTerminalRemoteInner(connection, handler_event) catch |err| {
        daemon_log.infof(connection.allocator, "terminal mux remote process failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };
}

fn readTerminalRemoteInner(
    connection: *MuxConnection,
    handler_event: dispatcher.HandlerEvent,
) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonMuxTimer,
    };
    const stream_index = session_daemon_handler.findTerminalMuxStreamIndexByWatch(&connection.terminal_sessions, id.fd) orelse return;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
        return;
    }

    if (fd_event.writable) {
        const stream = &connection.terminal_sessions.items[stream_index];
        switch (try session_daemon_handler.drainTerminalWorkerWrites(stream, daemon_dispatcher)) {
            .blocked, .progress => if (!fd_event.readable) return,
            .drained => {},
        }
    }

    if (!fd_event.readable) return;

    while (true) {
        const current_index = session_daemon_handler.findTerminalMuxStreamIndexByWatch(&connection.terminal_sessions, id.fd) orelse return;
        var stream = &connection.terminal_sessions.items[current_index];
        switch (try stream.endpoint.reader.readReady(stream.endpoint.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (try session_daemon_handler.forwardTerminalRemoteFrameToMux(.{
                    .allocator = connection.allocator,
                    .mux_writer = &connection.mux_writer,
                    .stream = stream,
                    .frame = &frame,
                })) {
                    try updateMuxWatch(connection, daemon_dispatcher);
                    continue;
                }
                closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return;
            },
        }
    }
}

fn closeTerminalRemoteAfterProcessClose(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_index: usize,
) void {
    const stream_id = connection.terminal_sessions.items[stream_index].stream_id;
    if (!connection.terminal_sessions.items[stream_index].ended) {
        daemon_log.infof(
            connection.allocator,
            "terminal mux connection closing after remote process transport closed stream_id={} session={s}",
            .{ stream_id, connection.terminal_sessions.items[stream_index].session_guid },
        );
        connection.deinit(daemon_dispatcher);
        return;
    }
    const stream = connection.terminal_sessions.swapRemove(stream_index);
    session_daemon_handler.closeTerminalMuxStream(.{
        .allocator = connection.allocator,
        .stream = stream,
        .send_hangup = false,
        .daemon_dispatcher = daemon_dispatcher,
    });
    connection.stream_registry.remove(stream_id);
}

fn readProxyRemote(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readProxyRemoteInner(connection, handler_event) catch |err| {
        daemon_log.infof(connection.allocator, "proxy mux remote process failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };
}

fn readProxyRemoteInner(
    connection: *MuxConnection,
    handler_event: dispatcher.HandlerEvent,
) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonMuxTimer,
    };
    const stream_index = proxy_worker.findProxyMuxStreamIndexByWatch(&connection.proxy_streams, id.fd) orelse return;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
        try updateMuxWatch(connection, daemon_dispatcher);
        return;
    }
    if (fd_event.writable) {
        const stream = &connection.proxy_streams.items[stream_index];
        switch (try proxy_worker.drainProxyProcessWrites(stream, daemon_dispatcher)) {
            .blocked, .progress => if (!fd_event.readable) return,
            .drained => {},
        }
    }
    if (!fd_event.readable) return;

    while (true) {
        const current_index = proxy_worker.findProxyMuxStreamIndexByWatch(&connection.proxy_streams, id.fd) orelse return;
        var stream = &connection.proxy_streams.items[current_index];
        switch (try stream.endpoint.reader.readReady(stream.endpoint.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                try updateMuxWatch(connection, daemon_dispatcher);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (try proxy_worker.handleProxyRemoteControlFrame(connection.allocator, stream, &frame)) {
                    _ = try proxy_worker.drainProxyProcessWrites(stream, daemon_dispatcher);
                    continue;
                }
                if (try proxy_worker.forwardProxyRemoteFrameToMux(.{
                    .allocator = connection.allocator,
                    .mux_writer = &connection.mux_writer,
                    .stream = stream,
                    .frame = &frame,
                })) {
                    try updateMuxWatch(connection, daemon_dispatcher);
                    continue;
                }
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                try updateMuxWatch(connection, daemon_dispatcher);
                return;
            },
        }
    }
}

fn closeProxyRemoteAfterProcessClose(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_index: usize,
) void {
    const stream = connection.proxy_streams.swapRemove(stream_index);
    connection.mux_writer.queueMuxStreamFrame(protocol.muxStreamResetFrame(stream.stream_id, "REMOTE_PROCESS_CLOSED", "remote proxy process closed")) catch {};
    connection.stream_registry.remove(stream.stream_id);
    proxy_worker.closeProxyMuxStream(.{
        .allocator = connection.allocator,
        .stream = stream,
        .send_startup_failed = false,
        .daemon_dispatcher = daemon_dispatcher,
    });
}
