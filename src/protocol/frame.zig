// Framed protobuf transport used after the compatibility handshake. Each
// post-handshake frame is:
//
//   4-byte big-endian length
//   protobuf Frame message of that length
//   optional raw bytes declared by Frame.attached
//
// The protocol code here is pure frame encoding/decoding. Dispatcher-owned
// Source/Sink code and foreground setup helpers decide how those bytes move
// across fds, including the SCM_RIGHTS marker byte used by local daemon IPC.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const test_helpers = if (builtin.is_test) @import("test_helpers.zig") else struct {};
pub const pb = @import("../proto/sessh/protocol/v1.pb.zig");
pub const hpb = @import("../proto/sessh/handshake/v1.pb.zig");

pub const MessageType = enum {
    hello_request,
    hello_ok,
    hello_error,
    error_message,
    client_daemon,
    client_remote,
    daemon_tunnel,
};

pub const frame_header_len = 4;

pub const OwnedFrame = struct {
    message_type: MessageType,
    // Structured protobuf message bytes for `message_type`. Attached bytes are
    // uninterpreted bytes that follow the protobuf Frame message on the wire.
    payload: []u8,
    attached_bytes: []u8 = &.{},
    fd: ?c.fd_t = null,

    pub fn takeFd(self: *OwnedFrame) ?c.fd_t {
        const fd = self.fd;
        self.fd = null;
        return fd;
    }

    pub fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.attached_bytes);
        if (self.fd) |fd| {
            _ = c.close(fd);
            self.fd = null;
        }
        self.* = undefined;
    }
};

pub const AttachedFrameOptions = struct {
    message_type: MessageType,
    payload: []const u8,
    attached_kind: pb.Frame.Attached.Kind = .RAW,
    attached_bytes: []const u8 = &.{},
};

const MessagePayloadOptions = struct {
    message_type: MessageType,
    payload: []const u8,
    attached_bytes_len: usize = 0,
    attached_kind: pb.Frame.Attached.Kind = .RAW,
};

pub fn encodePayload(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try message.encode(&writer.writer, allocator);
    return writer.toOwnedSlice();
}

pub fn decodePayload(comptime T: type, allocator: std.mem.Allocator, payload: []const u8) !T {
    var reader: std.Io.Reader = .fixed(payload);
    return T.decode(&reader, allocator);
}

pub fn encodeFrame(allocator: std.mem.Allocator, message_type: MessageType, payload: []const u8) ![]u8 {
    return encodeFrameWithAttachedKindAndBytes(allocator, .{
        .message_type = message_type,
        .payload = payload,
    });
}

pub fn encodeFrameWithAttachedKindAndBytes(
    allocator: std.mem.Allocator,
    options: AttachedFrameOptions,
) ![]u8 {
    // The outer frame length covers the protobuf message plus any attached raw
    // bytes. SCM_RIGHTS uses a one-byte attached marker so the receiver knows
    // exactly which frame carried the fd.
    const message = try encodeMessagePayload(allocator, .{
        .message_type = options.message_type,
        .payload = options.payload,
        .attached_bytes_len = options.attached_bytes.len,
        .attached_kind = options.attached_kind,
    });
    defer allocator.free(message);
    if (message.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    if (options.attached_bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    const frame = try allocator.alloc(u8, frame_header_len + message.len + options.attached_bytes.len);
    writeU32(frame[0..frame_header_len], @intCast(message.len));
    @memcpy(frame[frame_header_len..][0..message.len], message);
    @memcpy(frame[frame_header_len + message.len ..], options.attached_bytes);
    return frame;
}

pub fn messageLenFromHeader(header: *const [frame_header_len]u8) usize {
    return @intCast(readU32(header));
}

pub const DecodedMessageEnvelope = struct {
    frame: OwnedFrame,
    attached_bytes_len: usize = 0,
    attached_kind: pb.Frame.Attached.Kind = .RAW,
};

/// Decode only the protobuf message portion of a frame. Attached raw bytes and
/// SCM_RIGHTS marker bytes are not present in `message_bytes`; the returned
/// metadata tells the caller how much out-of-band payload still has to be read.
pub fn decodeMessageEnvelopeAlloc(allocator: std.mem.Allocator, message_bytes: []const u8) !DecodedMessageEnvelope {
    if (message_bytes.len == 0) return error.UnknownFrame;
    if (isHelloFrameEnvelope(message_bytes)) return .{
        .frame = try decodeHelloMessageAlloc(allocator, message_bytes),
    };

    var frame = try decodePayload(pb.Frame, allocator, message_bytes);
    defer frame.deinit(allocator);
    const attached = frame.attached orelse pb.Frame.Attached{};
    const attached_bytes_len: usize = @intCast(attached.attached_bytes_len);
    if (attached_bytes_len == 0 and attached.kind != .RAW) return error.InvalidFrame;

    const decoded = switch (frame.payload orelse return error.UnknownFrame) {
        .@"error" => |message| DecodedMessageEnvelope{
            .frame = try ownedFrameFromMessage(allocator, .error_message, message),
            .attached_bytes_len = attached_bytes_len,
            .attached_kind = attached.kind,
        },
        .client_daemon => |message| DecodedMessageEnvelope{
            .frame = try ownedFrameFromMessage(allocator, .client_daemon, message),
            .attached_bytes_len = attached_bytes_len,
            .attached_kind = attached.kind,
        },
        .client_remote => |message| DecodedMessageEnvelope{
            .frame = try ownedFrameFromMessage(allocator, .client_remote, message),
            .attached_bytes_len = attached_bytes_len,
            .attached_kind = attached.kind,
        },
        .daemon_tunnel => |message| DecodedMessageEnvelope{
            .frame = try ownedFrameFromMessage(allocator, .daemon_tunnel, message),
            .attached_bytes_len = attached_bytes_len,
            .attached_kind = attached.kind,
        },
    };
    return decoded;
}

fn decodeHelloMessageAlloc(allocator: std.mem.Allocator, message_bytes: []const u8) !OwnedFrame {
    var hello_frame = try decodePayload(hpb.HelloFrame, allocator, message_bytes);
    defer hello_frame.deinit(allocator);

    return switch (hello_frame.payload orelse return error.UnknownFrame) {
        .hello_request => |message| ownedFrameFromMessage(allocator, .hello_request, message),
        .hello_ok => |message| ownedFrameFromMessage(allocator, .hello_ok, message),
        .hello_error => |message| ownedFrameFromMessage(allocator, .hello_error, message),
    };
}

fn isHelloFrameEnvelope(message: []const u8) bool {
    return message[0] == 0x0a or message[0] == 0x12 or message[0] == 0x1a;
}

fn ownedFrameFromMessage(allocator: std.mem.Allocator, message_type: MessageType, message: anytype) !OwnedFrame {
    return .{
        .message_type = message_type,
        .payload = try encodePayload(allocator, message),
    };
}

// Put an already-encoded message into the protobuf container used on the wire.
// The compatibility hello still uses HelloFrame. Everything after hello uses
// Frame, which can also declare that raw bytes or an SCM_RIGHTS descriptor
// marker follows the protobuf bytes.
fn encodeMessagePayload(
    allocator: std.mem.Allocator,
    options: MessagePayloadOptions,
) ![]u8 {
    return switch (options.message_type) {
        .hello_request => blk: {
            if (options.attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            if (options.attached_kind != .RAW) return error.ScmUnsupported;
            var message = try decodePayload(hpb.HelloRequest, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_request = message } });
        },
        .hello_ok => blk: {
            if (options.attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            if (options.attached_kind != .RAW) return error.ScmUnsupported;
            var message = try decodePayload(hpb.HelloOk, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_ok = message } });
        },
        .hello_error => blk: {
            if (options.attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            if (options.attached_kind != .RAW) return error.ScmUnsupported;
            var message = try decodePayload(hpb.HelloError, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_error = message } });
        },
        .error_message => blk: {
            var message = try decodePayload(hpb.Error, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached = try optionalAttached(options.attached_bytes_len, options.attached_kind),
                .payload = .{ .@"error" = message },
            });
        },
        .client_daemon => blk: {
            var message = try decodePayload(pb.ClientDaemonItem, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached = try optionalAttached(options.attached_bytes_len, options.attached_kind),
                .payload = .{ .client_daemon = message },
            });
        },
        .client_remote => blk: {
            var message = try decodePayload(pb.ClientRemoteItem, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached = try optionalAttached(options.attached_bytes_len, options.attached_kind),
                .payload = .{ .client_remote = message },
            });
        },
        .daemon_tunnel => blk: {
            var message = try decodePayload(pb.DaemonTunnelItem, allocator, options.payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached = try optionalAttached(options.attached_bytes_len, options.attached_kind),
                .payload = .{ .daemon_tunnel = message },
            });
        },
    };
}

fn optionalAttached(attached_bytes_len: usize, attached_kind: pb.Frame.Attached.Kind) !?pb.Frame.Attached {
    if (attached_bytes_len == 0) {
        if (attached_kind != .RAW) return error.InvalidFrame;
        return null;
    }
    return .{
        .attached_bytes_len = @intCast(attached_bytes_len),
        .kind = attached_kind,
    };
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writeU32(bytes: []u8, value: u32) void {
    bytes[0] = @intCast((value >> 24) & 0xff);
    bytes[1] = @intCast((value >> 16) & 0xff);
    bytes[2] = @intCast((value >> 8) & 0xff);
    bytes[3] = @intCast(value & 0xff);
}

test "generated protobuf payload round trip" {
    const original = pb.TerminalEmulatorItem.Draw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 4,
        .draw_bytes = "sessh",
    };
    const encoded = try encodePayload(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodePayload(pb.TerminalEmulatorItem.Draw, std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("opaque-cursor", decoded.scrollback_cursor);
    try std.testing.expectEqual(@as(?i32, 4), decoded.viewport_offset);
    try std.testing.expectEqualStrings("sessh", decoded.draw_bytes);
}

test "protobuf frame container round trip" {
    const blocking = core_blocking.fromTest();
    const payload = try encodePayload(std.testing.allocator, pb.ClientRemoteItem{
        .payload = .{ .terminal_emulator = .{ .payload = .{ .input_ack = .{ .input_seq = 42 } } } },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .client_remote, payload);
    defer std.testing.allocator.free(frame_bytes);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try blocking.writeAll(pipe[1], frame_bytes);
    var frame = try test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.client_remote, frame.message_type);
    try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);

    var item = try decodePayload(pb.ClientRemoteItem, std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    const item_payload = item.payload orelse return error.MissingClientRemotePayload;
    switch (item_payload) {
        .terminal_emulator => |terminal_emulator| switch (terminal_emulator.payload orelse return error.MissingTerminalEmulatorPayload) {
            .input_ack => |ack| try std.testing.expectEqual(@as(u64, 42), ack.input_seq),
            else => return error.UnexpectedTerminalEmulatorPayload,
        },
        else => return error.UnexpectedTerminalEmulatorPayload,
    }
}

test "mux stream frame preserves stream id offset and proxy payload" {
    const blocking = core_blocking.fromTest();
    const payload = try encodePayload(std.testing.allocator, pb.DaemonTunnelItem{
        .payload = .{ .mux_stream = .{
            .stream_id = 7,
            .message = .{ .payload = .{
                .offset = 42,
                .item = .{ .proxy = .{ .payload = .{ .data = "hello" } } },
            } },
        } },
    });
    defer std.testing.allocator.free(payload);

    const frame_bytes = try encodeFrame(std.testing.allocator, .daemon_tunnel, payload);
    defer std.testing.allocator.free(frame_bytes);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try blocking.writeAll(pipe[1], frame_bytes);
    var frame = try test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.daemon_tunnel, frame.message_type);
    try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);

    var daemon_tunnel = try decodePayload(pb.DaemonTunnelItem, std.testing.allocator, frame.payload);
    defer daemon_tunnel.deinit(std.testing.allocator);
    const daemon_payload = daemon_tunnel.payload orelse return error.MissingDaemonTunnelPayload;
    const decoded = switch (daemon_payload) {
        .mux_stream => |mux| mux,
        else => return error.UnexpectedDaemonTunnelPayload,
    };
    try std.testing.expectEqual(@as(u64, 7), decoded.stream_id);

    const message = decoded.message orelse return error.MissingMuxMessage;
    switch (message) {
        .payload => |mux_payload| {
            try std.testing.expectEqual(@as(u64, 42), mux_payload.offset);
            const item = mux_payload.item orelse return error.MissingMuxPayloadItem;
            switch (item) {
                .proxy => |proxy_item| {
                    const proxy_payload = proxy_item.payload orelse return error.MissingProxyPayload;
                    switch (proxy_payload) {
                        .data => |data| try std.testing.expectEqualStrings("hello", data),
                        else => return error.UnexpectedProxyPayload,
                    }
                },
                else => return error.UnexpectedMuxPayloadItem,
            }
        },
        else => return error.UnexpectedMuxMessage,
    }
}

test "protobuf frame container preserves attached bytes appendix" {
    const blocking = core_blocking.fromTest();
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrameWithAttachedKindAndBytes(std.testing.allocator, .{
        .message_type = .client_daemon,
        .payload = payload,
        .attached_bytes = "attached-bytes",
    });
    defer std.testing.allocator.free(frame_bytes);

    var header: [frame_header_len]u8 = undefined;
    @memcpy(&header, frame_bytes[0..frame_header_len]);
    const message_len = messageLenFromHeader(&header);
    try std.testing.expectEqual(frame_bytes.len, frame_header_len + message_len + "attached-bytes".len);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try blocking.writeAll(pipe[1], frame_bytes);
    var frame = try test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(MessageType.client_daemon, frame.message_type);
    try std.testing.expectEqualStrings("attached-bytes", frame.attached_bytes);
    var item = try decodePayload(pb.ClientDaemonItem, std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    switch (item.payload orelse return error.MissingClientDaemonPayload) {
        .log_request => {},
        else => return error.UnexpectedClientDaemonPayload,
    }
}
