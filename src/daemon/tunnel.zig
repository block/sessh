const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const stream_runtime = @import("../stream/runtime.zig");

const pb = protocol.pb;

const StreamKind = enum {
    unknown,
    terminal,
    proxy,
};

const StreamEntry = struct {
    stream_id: u64,
    kind: StreamKind = .unknown,
    pending_open: ?pb.DaemonTunnelItem.MuxStreamFrame.Open = null,
};

const MuxConnection = struct {
    allocator: std.mem.Allocator,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    mux_fd: c.fd_t = -1,
    mux_watch_id: ?dispatcher.FdWatchId = null,
    mux_reader: protocol.FrameReader = undefined,
    stream_entries: std.ArrayList(StreamEntry) = .empty,
    terminal_sessions: std.ArrayList(session_daemon_handler.TerminalMuxStream) = .empty,
    proxy_streams: std.ArrayList(stream_runtime.ProxyMuxStream) = .empty,

    fn deinit(self: *MuxConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            if (self.mux_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        }
        self.mux_watch_id = null;
        session_daemon_handler.closeTerminalMuxStreams(self.allocator, &self.terminal_sessions, daemon_dispatcher);
        stream_runtime.closeProxyMuxStreams(self.allocator, &self.proxy_streams, daemon_dispatcher);
        self.stream_entries.deinit(self.allocator);
        self.mux_reader.deinit();
        if (self.mux_fd >= 0) {
            _ = c.close(self.mux_fd);
            self.mux_fd = -1;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

pub fn registerMuxConnectionFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    initial_frames: []const protocol.OwnedFrame,
    fd: c.fd_t,
) !void {
    const connection = try allocator.create(MuxConnection);
    errdefer allocator.destroy(connection);
    connection.* = .{
        .allocator = allocator,
        .terminal_remote_exe = terminal_remote_exe,
        .proxy_remote_exe = proxy_remote_exe,
        .identity = identity,
        .mux_fd = fd,
        .mux_reader = protocol.FrameReader.init(allocator),
    };
    errdefer connection.deinit(daemon_dispatcher);

    try core_fds.setNonBlocking(fd);
    for (initial_frames) |frame| {
        try handleMuxConnectionFrame(connection, daemon_dispatcher, frame);
    }
    connection.mux_watch_id = try daemon_dispatcher.watchFd(fd, .{ .readable = true }, .{
        .ctx = connection,
        .callback = readMuxConnection,
    });
}

fn readMuxConnection(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readMuxConnectionInner(connection, daemon_dispatcher, event) catch |err| {
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
        connection.deinit(daemon_dispatcher);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) connection.deinit(daemon_dispatcher);
        return;
    }

    while (true) {
        switch (try connection.mux_reader.readReady(connection.mux_fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
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

fn handleMuxConnectionFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
) !void {
    if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, connection.mux_fd)) return;
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
            try daemon_cleanup.handleRemoteProcessCleanupRequest(connection.allocator, connection.mux_fd, connection.identity, request);
            return;
        },
        .mux_stream => |mux| {
            item.payload = null;
            try handleMuxStreamFrame(connection, daemon_dispatcher, mux);
        },
        else => return error.UnexpectedDaemonMuxFrame,
    }
}

fn handleMuxStreamFrame(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const stream_id = mux_frame.stream_id;
    const message = mux_frame.message orelse return error.UnexpectedDaemonMuxFrame;
    switch (message) {
        .open => |open| {
            try noteMuxOpen(connection, stream_id, open);
            var owned = mux_frame;
            switch (streamKind(connection, stream_id)) {
                .terminal => try session_daemon_handler.handleTerminalMuxStreamFrame(
                    connection.allocator,
                    connection.terminal_remote_exe,
                    connection.identity,
                    &connection.terminal_sessions,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readTerminalRemote },
                    daemon_dispatcher,
                ),
                .proxy => try stream_runtime.handleProxyMuxStreamFrame(
                    connection.allocator,
                    connection.proxy_remote_exe,
                    connection.identity,
                    &connection.proxy_streams,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readProxyRemote },
                    daemon_dispatcher,
                ),
                .unknown => {},
            }
            if (streamKind(connection, stream_id) == .unknown) owned.deinit(connection.allocator);
        },
        .payload => |payload| {
            const kind = payloadKind(payload) orelse return error.UnexpectedDaemonMuxFrame;
            try ensureStreamKind(connection, daemon_dispatcher, stream_id, kind);
            const owned = mux_frame;
            if (kind == .terminal) {
                try session_daemon_handler.handleTerminalMuxStreamFrame(
                    connection.allocator,
                    connection.terminal_remote_exe,
                    connection.identity,
                    &connection.terminal_sessions,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readTerminalRemote },
                    daemon_dispatcher,
                );
            } else {
                try stream_runtime.handleProxyMuxStreamFrame(
                    connection.allocator,
                    connection.proxy_remote_exe,
                    connection.identity,
                    &connection.proxy_streams,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readProxyRemote },
                    daemon_dispatcher,
                );
            }
        },
        .ack, .open_ok, .eof, .reset => {
            const kind = streamKind(connection, stream_id);
            var owned = mux_frame;
            const closes_stream = message == .eof or message == .reset;
            switch (kind) {
                .terminal => try session_daemon_handler.handleTerminalMuxStreamFrame(
                    connection.allocator,
                    connection.terminal_remote_exe,
                    connection.identity,
                    &connection.terminal_sessions,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readTerminalRemote },
                    daemon_dispatcher,
                ),
                .proxy => try stream_runtime.handleProxyMuxStreamFrame(
                    connection.allocator,
                    connection.proxy_remote_exe,
                    connection.identity,
                    &connection.proxy_streams,
                    connection.mux_fd,
                    owned,
                    .{ .ctx = connection, .callback = readProxyRemote },
                    daemon_dispatcher,
                ),
                .unknown => {
                    owned.deinit(connection.allocator);
                    return error.UnexpectedDaemonMuxFrame;
                },
            }
            if (closes_stream) removeStreamEntry(connection, stream_id);
        },
    }
}

fn payloadKind(payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload) ?StreamKind {
    const item = payload.item orelse return null;
    return switch (item) {
        .terminal_emulator => .terminal,
        .proxy => .proxy,
    };
}

fn noteMuxOpen(
    connection: *MuxConnection,
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
) !void {
    const index = try streamEntryIndexOrAppend(connection, stream_id);
    connection.stream_entries.items[index].pending_open = open;
}

fn ensureStreamKind(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    stream_id: u64,
    kind: StreamKind,
) !void {
    const index = try streamEntryIndexOrAppend(connection, stream_id);
    const entry = &connection.stream_entries.items[index];
    if (entry.kind == kind) return;
    if (entry.kind != .unknown) {
        try sendMuxReset(connection.allocator, connection.mux_fd, stream_id, "PROTOCOL_ERROR", "mux stream changed payload type");
        return error.UnexpectedDaemonMuxFrame;
    }

    entry.kind = kind;
    const open = entry.pending_open orelse pb.DaemonTunnelItem.MuxStreamFrame.Open{};
    switch (kind) {
        .terminal => try session_daemon_handler.handleTerminalMuxOpen(connection.allocator, &connection.terminal_sessions, stream_id, open),
        .proxy => try stream_runtime.handleProxyMuxOpen(connection.allocator, &connection.proxy_streams, stream_id, open),
        .unknown => {},
    }
    _ = daemon_dispatcher;
}

fn streamEntryIndexOrAppend(connection: *MuxConnection, stream_id: u64) !usize {
    if (streamEntryIndex(connection, stream_id)) |index| return index;
    try connection.stream_entries.append(connection.allocator, .{ .stream_id = stream_id });
    return connection.stream_entries.items.len - 1;
}

fn streamEntryIndex(connection: *const MuxConnection, stream_id: u64) ?usize {
    for (connection.stream_entries.items, 0..) |entry, index| {
        if (entry.stream_id == stream_id) return index;
    }
    return null;
}

fn streamKind(connection: *const MuxConnection, stream_id: u64) StreamKind {
    const index = streamEntryIndex(connection, stream_id) orelse return .unknown;
    return connection.stream_entries.items[index].kind;
}

fn removeStreamEntry(connection: *MuxConnection, stream_id: u64) void {
    const index = streamEntryIndex(connection, stream_id) orelse return;
    _ = connection.stream_entries.swapRemove(index);
}

fn markCleanupRecorded(connection: *MuxConnection, stream_id: u64) void {
    if (session_daemon_handler.findTerminalMuxStreamIndex(&connection.terminal_sessions, stream_id)) |index| {
        connection.terminal_sessions.items[index].cleanup_recorded = true;
    }
    if (stream_runtime.findProxyMuxStreamIndex(&connection.proxy_streams, stream_id)) |index| {
        connection.proxy_streams.items[index].cleanup_recorded = true;
    }
}

fn readTerminalRemote(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readTerminalRemoteInner(connection, daemon_dispatcher, id, event) catch |err| {
        daemon_log.infof(connection.allocator, "terminal mux remote process failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };
}

fn readTerminalRemoteInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonMuxTimer,
    };
    const stream_index = session_daemon_handler.findTerminalMuxStreamIndexByWatch(&connection.terminal_sessions, id.fd) orelse return;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
        return;
    }
    if (!fd_event.readable) return;

    while (true) {
        const current_index = session_daemon_handler.findTerminalMuxStreamIndexByWatch(&connection.terminal_sessions, id.fd) orelse return;
        var stream = &connection.terminal_sessions.items[current_index];
        switch (try stream.reader.readReady(stream.process_fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                closeTerminalRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (try session_daemon_handler.forwardTerminalRemoteFrameToMux(connection.allocator, connection.mux_fd, stream, &frame)) {
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
    session_daemon_handler.closeTerminalMuxStream(connection.allocator, stream, false, daemon_dispatcher);
    removeStreamEntry(connection, stream_id);
}

fn readProxyRemote(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    const connection: *MuxConnection = @ptrCast(@alignCast(ctx));
    readProxyRemoteInner(connection, daemon_dispatcher, id, event) catch |err| {
        daemon_log.infof(connection.allocator, "proxy mux remote process failed error={t}", .{err});
        connection.deinit(daemon_dispatcher);
    };
}

fn readProxyRemoteInner(
    connection: *MuxConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonMuxTimer,
    };
    const stream_index = stream_runtime.findProxyMuxStreamIndexByWatch(&connection.proxy_streams, id.fd) orelse return;
    if (fd_event.error_event or fd_event.invalid or (!fd_event.readable and fd_event.hangup)) {
        closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, stream_index);
        return;
    }
    if (!fd_event.readable) return;

    while (true) {
        const current_index = stream_runtime.findProxyMuxStreamIndexByWatch(&connection.proxy_streams, id.fd) orelse return;
        var stream = &connection.proxy_streams.items[current_index];
        switch (try stream.reader.readReady(stream.process_fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (try stream_runtime.forwardProxyRemoteFrameToMux(connection.allocator, connection.mux_fd, stream, &frame)) {
                    continue;
                }
                closeProxyRemoteAfterProcessClose(connection, daemon_dispatcher, current_index);
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
    stream_runtime.sendProxyMuxReset(connection.allocator, connection.mux_fd, stream.stream_id, "REMOTE_PROCESS_CLOSED", "remote proxy process closed") catch {};
    removeStreamEntry(connection, stream.stream_id);
    stream_runtime.closeProxyMuxStream(connection.allocator, stream, false, daemon_dispatcher);
}

fn sendMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}
