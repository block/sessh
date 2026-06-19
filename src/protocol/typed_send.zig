const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;

const frame = @import("frame.zig");

pub const pb = @import("../proto/sessh/protocol/v1.pb.zig");

pub const ClientDaemonPayload = pb.ClientDaemonItem.payload_union;
pub const ClientRemotePayload = pb.ClientRemoteItem.payload_union;
pub const DaemonTunnelPayload = pb.DaemonTunnelItem.payload_union;
pub const MuxStreamMessage = pb.DaemonTunnelItem.MuxStreamFrame.message_union;
pub const ProxyStreamPayload = pb.ProxyStreamItem.payload_union;
pub const TerminalEmulatorPayload = pb.TerminalEmulatorItem.payload_union;

pub fn sendPing(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .ping = .{} });
}

pub fn sendPong(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .pong = .{} });
}

pub fn handleTransportControlFrame(message_type: frame.MessageType, payload: []const u8, write_fd: c.fd_t) !bool {
    if (message_type != .daemon_tunnel) return false;

    var item = try frame.decodePayload(pb.DaemonTunnelItem, app_allocator.allocator(), payload);
    defer item.deinit(app_allocator.allocator());

    switch (item.payload orelse return false) {
        .ping => try sendPong(write_fd),
        .pong => {},
        else => return false,
    }
    return true;
}

pub fn encodeClientDaemonPayload(
    allocator: std.mem.Allocator,
    payload: ClientDaemonPayload,
) ![]u8 {
    return frame.encodePayload(allocator, pb.ClientDaemonItem{ .payload = payload });
}

pub fn encodeDaemonTunnelPayload(
    allocator: std.mem.Allocator,
    payload: DaemonTunnelPayload,
) ![]u8 {
    return frame.encodePayload(allocator, pb.DaemonTunnelItem{ .payload = payload });
}

pub fn encodeClientRemotePayload(
    allocator: std.mem.Allocator,
    payload: ClientRemotePayload,
) ![]u8 {
    return frame.encodePayload(allocator, pb.ClientRemoteItem{ .payload = payload });
}

pub fn encodeConnectionEventPayload(
    allocator: std.mem.Allocator,
    event: pb.ConnectionEvent.event_union,
) ![]u8 {
    return encodeClientDaemonPayload(allocator, .{ .connection_event = .{ .event = event } });
}

pub fn encodeMuxStreamFramePayload(
    allocator: std.mem.Allocator,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) ![]u8 {
    return encodeDaemonTunnelPayload(allocator, .{ .mux_stream = message });
}

pub fn muxStreamResetFrame(
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    };
}

pub fn encodeErrorPayload(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
) ![]u8 {
    return frame.encodePayload(allocator, frame.hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
}

pub fn encodeTerminalEmulatorItemPayload(
    allocator: std.mem.Allocator,
    item: pb.TerminalEmulatorItem,
) ![]u8 {
    return encodeClientRemotePayload(allocator, .{ .terminal_emulator = item });
}

pub fn sendClientDaemonPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: ClientDaemonPayload,
) !void {
    const encoded = try encodeClientDaemonPayload(allocator, payload);
    defer allocator.free(encoded);
    try frame.sendFrame(fd, .client_daemon, encoded);
}

pub fn sendDaemonTunnelPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: DaemonTunnelPayload,
) !void {
    const encoded = try encodeDaemonTunnelPayload(allocator, payload);
    defer allocator.free(encoded);
    try frame.sendFrame(fd, .daemon_tunnel, encoded);
}

pub fn sendClientRemotePayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: ClientRemotePayload,
) !void {
    const encoded = try encodeClientRemotePayload(allocator, payload);
    defer allocator.free(encoded);
    try frame.sendFrame(fd, .client_remote, encoded);
}

pub fn sendErrorFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
) !void {
    const encoded = try encodeErrorPayload(allocator, code, message, hint);
    defer allocator.free(encoded);
    try frame.sendFrame(fd, .error_message, encoded);
}

pub fn sendMuxStreamFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try sendDaemonTunnelPayloadFrame(allocator, fd, .{ .mux_stream = message });
}

pub fn sendMuxStreamResetFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendMuxStreamFrame(allocator, fd, muxStreamResetFrame(stream_id, code, message));
}

pub fn sendTerminalEmulatorItemFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendClientRemotePayloadFrame(allocator, fd, .{ .terminal_emulator = item });
}

pub fn sendTerminalEmulatorPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: TerminalEmulatorPayload,
) !void {
    try sendTerminalEmulatorItemFrame(allocator, fd, .{ .payload = payload });
}

pub fn sendProxyStreamPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: ProxyStreamPayload,
) !void {
    try sendClientRemotePayloadFrame(allocator, fd, .{ .proxy = .{ .payload = payload } });
}

pub fn sendSshTransportAcquireFrame(allocator: std.mem.Allocator, fd: c.fd_t, request: pb.ClientDaemonItem.SshTransportAcquire) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .ssh_transport_acquire = request });
}

pub fn sendClientDaemonConnectionEventFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    event: pb.ConnectionEvent.event_union,
) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .connection_event = .{ .event = event } });
}

pub fn sendSshTransportStderrFrame(allocator: std.mem.Allocator, fd: c.fd_t, chunk: []const u8) !void {
    try sendClientDaemonConnectionEventFrame(allocator, fd, .{ .ssh_stderr = .{ .data = chunk } });
}

pub fn sendSshTransportClosedFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendClientDaemonConnectionEventFrame(allocator, fd, .{ .daemon_disconnected = .{} });
}

pub fn sendSshTransportBinaryBootstrappingFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendClientDaemonConnectionEventFrame(allocator, fd, .{ .binary_bootstrapping = .{} });
}

pub fn sendSshTransportDaemonConnectingFrame(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendClientDaemonConnectionEventFrame(allocator, fd, .{ .daemon_connecting = .{} });
}

pub fn sendDaemonLogRequestFrame(allocator: std.mem.Allocator, fd: c.fd_t, request: pb.ClientDaemonItem.DaemonLogRequest) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .log_request = request });
}

pub fn sendDaemonLogEntryFrame(allocator: std.mem.Allocator, fd: c.fd_t, entry: pb.ClientDaemonItem.DaemonLogEntry) !void {
    try sendClientDaemonPayloadFrame(allocator, fd, .{ .log_entry = entry });
}

pub fn decodeClientRemoteTerminalEmulatorItem(allocator: std.mem.Allocator, payload: []const u8) !pb.TerminalEmulatorItem {
    var item = try frame.decodePayload(pb.ClientRemoteItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .terminal_emulator => |terminal_emulator| {
            item.payload = null;
            return terminal_emulator;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientRemoteProxyStreamItem(allocator: std.mem.Allocator, payload: []const u8) !pb.ProxyStreamItem {
    var item = try frame.decodePayload(pb.ClientRemoteItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .proxy => |proxy| {
            item.payload = null;
            return proxy;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeDaemonMuxStreamFrame(allocator: std.mem.Allocator, payload: []const u8) !pb.DaemonTunnelItem.MuxStreamFrame {
    var item = try frame.decodePayload(pb.DaemonTunnelItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .mux_stream => |mux| {
            item.payload = null;
            return mux;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientDaemonSshTransportAcquire(allocator: std.mem.Allocator, payload: []const u8) !pb.ClientDaemonItem.SshTransportAcquire {
    var item = try frame.decodePayload(pb.ClientDaemonItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .ssh_transport_acquire => |open| {
            item.payload = null;
            return open;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

pub fn decodeClientDaemonLogEntry(allocator: std.mem.Allocator, payload: []const u8) !pb.ClientDaemonItem.DaemonLogEntry {
    var item = try frame.decodePayload(pb.ClientDaemonItem, allocator, payload);
    switch (item.payload orelse {
        item.deinit(allocator);
        return error.UnexpectedFrame;
    }) {
        .log_entry => |entry| {
            item.payload = null;
            return entry;
        },
        else => {
            item.deinit(allocator);
            return error.UnexpectedFrame;
        },
    }
}

test "remote process started preserves stream id and cleanup identity" {
    const payload = try frame.encodePayload(std.testing.allocator, pb.DaemonTunnelItem{
        .payload = .{ .remote_process_started = .{
            .stream_id = 9,
            .process = .{
                .pid = 1234,
                .start_time = "opaque-start",
                .daemon_socket_path = "/tmp/sessh/sesshd.sock",
                .guid = "s-550e8400-e29b-41d4-a716-446655440000",
            },
        } },
    });
    defer std.testing.allocator.free(payload);

    var item = try frame.decodePayload(pb.DaemonTunnelItem, std.testing.allocator, payload);
    defer item.deinit(std.testing.allocator);
    const item_payload = item.payload orelse return error.MissingDaemonTunnelPayload;
    switch (item_payload) {
        .remote_process_started => |started| {
            try std.testing.expectEqual(@as(u64, 9), started.stream_id);
            const process = started.process orelse return error.MissingRemoteProcessIdentity;
            try std.testing.expectEqual(@as(u64, 1234), process.pid);
            try std.testing.expectEqualStrings("opaque-start", process.start_time);
            try std.testing.expectEqualStrings("/tmp/sessh/sesshd.sock", process.daemon_socket_path);
            try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", process.guid);
        },
        else => return error.UnexpectedDaemonTunnelPayload,
    }
}

test "session ended exit status is optional" {
    const payload = try frame.encodePayload(std.testing.allocator, pb.TerminalEmulatorItem.SessionEnded{
        .reason = .REASON_KILLED_BY_REQUEST,
        .ended_at_unix_ms = 42,
    });
    defer std.testing.allocator.free(payload);

    var decoded = try frame.decodePayload(pb.TerminalEmulatorItem.SessionEnded, std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.TerminalEmulatorItem.SessionEnded.Reason.REASON_KILLED_BY_REQUEST, decoded.reason);
    try std.testing.expectEqual(@as(?pb.TerminalEmulatorItem.SessionEnded.ExitStatus, null), decoded.exit_status);
    try std.testing.expectEqual(@as(?u64, 42), decoded.ended_at_unix_ms);
}
