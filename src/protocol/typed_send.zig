// Type-focused helpers for building protobuf frame payloads. Common message
// construction lives at the protocol boundary, including nested `oneof`
// envelopes used by many callers.
const std = @import("std");

const frame = @import("frame.zig");

pub const pb = @import("../proto/sessh/protocol/v1.pb.zig");

pub const ClientDaemonPayload = pb.ClientDaemonItem.payload_union;
pub const ClientRemotePayload = pb.ClientRemoteItem.payload_union;
pub const DaemonTunnelPayload = pb.DaemonTunnelItem.payload_union;
pub const MuxStreamMessage = pb.DaemonTunnelItem.MuxStreamFrame.message_union;
pub const MuxStreamPayloadItem = pb.DaemonTunnelItem.MuxStreamFrame.Payload.item_union;
pub const TerminalEmulatorPayload = pb.TerminalEmulatorItem.payload_union;
pub const ProxyStreamPayload = pb.ProxyStreamItem.payload_union;
pub const TransportControl = enum {
    ping,
    pong,
};

pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8 = "",
};

pub fn decodeTransportControlFrame(
    allocator: std.mem.Allocator,
    message_type: frame.MessageType,
    payload: []const u8,
) !?TransportControl {
    if (message_type != .daemon_tunnel) return null;

    var item = try frame.decodePayload(pb.DaemonTunnelItem, allocator, payload);
    defer item.deinit(allocator);

    return switch (item.payload orelse return null) {
        .ping => .ping,
        .pong => .pong,
        else => null,
    };
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

pub fn terminalEmulatorItem(payload: TerminalEmulatorPayload) pb.TerminalEmulatorItem {
    return .{ .payload = payload };
}

pub fn proxyStreamItem(payload: ProxyStreamPayload) pb.ProxyStreamItem {
    return .{ .payload = payload };
}

pub fn muxStreamOpenFrame(
    stream_id: u64,
    recv_next_offset: u64,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return muxStreamOpenMessageFrame(stream_id, .{ .recv_next_offset = recv_next_offset });
}

pub fn muxStreamOpenMessageFrame(
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .open = open },
    };
}

pub fn muxStreamOpenOkFrame(
    stream_id: u64,
    recv_next_offset: u64,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .open_ok = .{ .recv_next_offset = recv_next_offset } },
    };
}

pub fn muxStreamAckFrame(
    stream_id: u64,
    recv_next_offset: u64,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .ack = .{ .recv_next_offset = recv_next_offset } },
    };
}

pub fn muxStreamEofFrame(
    stream_id: u64,
    final_offset: u64,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .eof = .{ .final_offset = final_offset } },
    };
}

pub fn muxStreamPayloadFrame(
    stream_id: u64,
    offset: u64,
    item: MuxStreamPayloadItem,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = stream_id,
        .message = .{ .payload = .{
            .offset = offset,
            .item = item,
        } },
    };
}

pub fn terminalMuxPayloadFrame(
    stream_id: u64,
    offset: u64,
    item: pb.TerminalEmulatorItem,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return muxStreamPayloadFrame(stream_id, offset, .{ .terminal_emulator = item });
}

pub fn terminalMuxPayloadFromPayloadFrame(
    stream_id: u64,
    offset: u64,
    payload: TerminalEmulatorPayload,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return terminalMuxPayloadFrame(stream_id, offset, terminalEmulatorItem(payload));
}

pub fn proxyMuxPayloadFrame(
    stream_id: u64,
    offset: u64,
    item: pb.ProxyStreamItem,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return muxStreamPayloadFrame(stream_id, offset, .{ .proxy = item });
}

pub fn proxyMuxPayloadFromPayloadFrame(
    stream_id: u64,
    offset: u64,
    payload: ProxyStreamPayload,
) pb.DaemonTunnelItem.MuxStreamFrame {
    return proxyMuxPayloadFrame(stream_id, offset, proxyStreamItem(payload));
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

test "mux stream builders keep envelope and typed payload fields in one place" {
    const open = muxStreamOpenFrame(7, 11);
    try std.testing.expectEqual(@as(u64, 7), open.stream_id);
    try std.testing.expectEqual(@as(u64, 11), open.message.?.open.recv_next_offset);

    const ack = muxStreamAckFrame(7, 19);
    try std.testing.expectEqual(@as(u64, 19), ack.message.?.ack.recv_next_offset);

    const eof = muxStreamEofFrame(7, 23);
    try std.testing.expectEqual(@as(u64, 23), eof.message.?.eof.final_offset);

    const terminal_payload = terminalMuxPayloadFromPayloadFrame(7, 29, .{ .session_hangup_request = .{} });
    const payload = terminal_payload.message.?.payload;
    try std.testing.expectEqual(@as(u64, 29), payload.offset);
    try std.testing.expect(payload.item.? == .terminal_emulator);
    try std.testing.expect(payload.item.?.terminal_emulator.payload.? == .session_hangup_request);

    const proxy_payload = proxyMuxPayloadFromPayloadFrame(8, 31, .{ .data = "hello" });
    const proxy = proxy_payload.message.?.payload;
    try std.testing.expectEqual(@as(u64, 31), proxy.offset);
    try std.testing.expect(proxy.item.? == .proxy);
    try std.testing.expectEqualStrings("hello", proxy.item.?.proxy.payload.?.data);
}

pub fn encodeErrorPayload(allocator: std.mem.Allocator, info: ErrorInfo) ![]u8 {
    return frame.encodePayload(allocator, frame.hpb.Error{
        .code = info.code,
        .message = info.message,
        .hint = info.hint,
    });
}

pub fn encodeTerminalEmulatorItemPayload(
    allocator: std.mem.Allocator,
    item: pb.TerminalEmulatorItem,
) ![]u8 {
    return encodeClientRemotePayload(allocator, .{ .terminal_emulator = item });
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
