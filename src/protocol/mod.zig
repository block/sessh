const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
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

    pub fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.attached_bytes);
        self.* = undefined;
    }
};

pub const FrameReadStatus = union(enum) {
    blocked,
    progress,
    frame: OwnedFrame,
    eof,
    truncated_frame,
};

pub const FrameWriteStatus = enum {
    blocked,
    progress,
    done,
};

pub const FrameWriteState = struct {
    allocator: std.mem.Allocator,
    bytes: []u8 = &.{},
    written: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        message_type: MessageType,
        payload: []const u8,
    ) !FrameWriteState {
        return initWithAttachedBytes(allocator, message_type, payload, &.{});
    }

    pub fn initWithAttachedBytes(
        allocator: std.mem.Allocator,
        message_type: MessageType,
        payload: []const u8,
        attached_bytes: []const u8,
    ) !FrameWriteState {
        return .{
            .allocator = allocator,
            .bytes = try encodeFrameWithAttachedBytes(allocator, message_type, payload, attached_bytes),
        };
    }

    pub fn initOwnedFrame(allocator: std.mem.Allocator, frame: OwnedFrame) !FrameWriteState {
        return initWithAttachedBytes(allocator, frame.message_type, frame.payload, frame.attached_bytes);
    }

    pub fn deinit(self: *FrameWriteState) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn writeReady(self: *FrameWriteState, fd: c.fd_t) !FrameWriteStatus {
        if (self.written == self.bytes.len) return .done;
        while (true) {
            const remaining = self.bytes[self.written..];
            const n = c.write(fd, remaining.ptr, remaining.len);
            if (n > 0) {
                const written_len: usize = @intCast(n);
                io.noteWrite(fd, remaining[0..written_len]);
                self.written += written_len;
                return if (self.written == self.bytes.len) .done else .progress;
            }
            if (n == 0) return .blocked;
            switch (posix.errno(n)) {
                .AGAIN => return .blocked,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }
};

pub const FrameReader = struct {
    allocator: std.mem.Allocator,
    header: [frame_header_len]u8 = undefined,
    header_filled: usize = 0,
    message: []u8 = &.{},
    message_filled: usize = 0,
    decoded_frame: ?OwnedFrame = null,
    attached_filled: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FrameReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameReader) void {
        self.reset();
        self.* = undefined;
    }

    pub fn readReady(self: *FrameReader, fd: c.fd_t) !FrameReadStatus {
        if (self.header_filled < frame_header_len) {
            switch (try readSome(fd, self.header[self.header_filled..])) {
                .blocked => return .blocked,
                .eof => return if (self.header_filled == 0) .eof else .truncated_frame,
                .bytes => |bytes| {
                    self.header_filled += bytes.len;
                    io.noteRead(fd, bytes);
                    if (self.header_filled < frame_header_len) return .progress;
                },
            }
        }

        if (self.message.len == 0 and self.header_filled == frame_header_len) {
            const message_len = messageLenFromHeader(&self.header);
            if (message_len == 0) return error.UnknownFrame;
            self.message = try self.allocator.alloc(u8, message_len);
            self.message_filled = 0;
        }

        if (self.message_filled < self.message.len) {
            switch (try readSome(fd, self.message[self.message_filled..])) {
                .blocked => return .blocked,
                .eof => return .truncated_frame,
                .bytes => |bytes| {
                    self.message_filled += bytes.len;
                    io.noteRead(fd, bytes);
                    if (self.message_filled < self.message.len) return .progress;
                },
            }
        }

        if (self.decoded_frame == null) {
            var decoded = try decodeMessageEnvelopeAlloc(self.allocator, self.message);
            errdefer decoded.frame.deinit(self.allocator);
            if (decoded.attached_bytes_len == 0) {
                const frame = decoded.frame;
                self.resetFrameStorageOnly();
                return .{ .frame = frame };
            }

            var frame = decoded.frame;
            frame.attached_bytes = try self.allocator.alloc(u8, decoded.attached_bytes_len);
            self.decoded_frame = frame;
            self.attached_filled = 0;
        }

        var frame = &(self.decoded_frame.?);
        if (self.attached_filled < frame.attached_bytes.len) {
            switch (try readSome(fd, frame.attached_bytes[self.attached_filled..])) {
                .blocked => return .blocked,
                .eof => return .truncated_frame,
                .bytes => |bytes| {
                    self.attached_filled += bytes.len;
                    io.noteRead(fd, bytes);
                    if (self.attached_filled < frame.attached_bytes.len) return .progress;
                },
            }
        }

        const result = self.decoded_frame.?;
        self.decoded_frame = null;
        self.resetFrameStorageOnly();
        return .{ .frame = result };
    }

    fn reset(self: *FrameReader) void {
        self.resetFrameStorageOnly();
        if (self.decoded_frame) |*frame| {
            frame.deinit(self.allocator);
            self.decoded_frame = null;
        }
    }

    fn resetFrameStorageOnly(self: *FrameReader) void {
        self.allocator.free(self.message);
        self.message = &.{};
        self.header_filled = 0;
        self.message_filled = 0;
        self.attached_filled = 0;
    }
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

pub fn helloRequestIsCompatible(
    hello: hpb.HelloRequest,
    min_major: u32,
    min_minor: u32,
) bool {
    return hello.protocol_major > min_major or
        (hello.protocol_major == min_major and hello.protocol_minor >= min_minor);
}

pub fn readFrameAlloc(allocator: std.mem.Allocator, fd: c.fd_t) !OwnedFrame {
    const message = try readFrameMessageAlloc(allocator, fd);
    defer allocator.free(message);
    return decodeMessageAlloc(allocator, fd, message);
}

pub fn sendFrame(fd: c.fd_t, message_type: MessageType, payload: []const u8) !void {
    const frame = try encodeFrame(app_allocator.allocator(), message_type, payload);
    defer app_allocator.allocator().free(frame);
    try io.writeAll(fd, frame);
}

pub fn sendFrameWithAttachedBytes(fd: c.fd_t, message_type: MessageType, payload: []const u8, attached_bytes: []const u8) !void {
    const frame = try encodeFrameWithAttachedBytes(app_allocator.allocator(), message_type, payload, attached_bytes);
    defer app_allocator.allocator().free(frame);
    try io.writeAll(fd, frame);
}

pub fn sendOwnedFrame(fd: c.fd_t, frame: OwnedFrame) !void {
    try sendFrameWithAttachedBytes(fd, frame.message_type, frame.payload, frame.attached_bytes);
}

pub fn sendPing(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .ping = .{} });
}

pub fn sendPong(fd: c.fd_t) !void {
    try sendDaemonTunnelPayloadFrame(app_allocator.allocator(), fd, .{ .pong = .{} });
}

pub fn handleTransportControlFrame(message_type: MessageType, payload: []const u8, write_fd: c.fd_t) !bool {
    if (message_type != .daemon_tunnel) return false;

    var item = try decodePayload(pb.DaemonTunnelItem, app_allocator.allocator(), payload);
    defer item.deinit(app_allocator.allocator());

    switch (item.payload orelse return false) {
        .ping => try sendPong(write_fd),
        .pong => {},
        else => return false,
    }
    return true;
}

pub fn sendClientDaemonPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ClientDaemonItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.ClientDaemonItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .client_daemon, encoded);
}

pub fn sendDaemonTunnelPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.DaemonTunnelItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.DaemonTunnelItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .daemon_tunnel, encoded);
}

pub fn sendClientRemotePayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ClientRemoteItem.payload_union,
) !void {
    const encoded = try encodePayload(allocator, pb.ClientRemoteItem{ .payload = payload });
    defer allocator.free(encoded);
    try sendFrame(fd, .client_remote, encoded);
}

pub fn sendMuxStreamFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    try sendDaemonTunnelPayloadFrame(allocator, fd, .{ .mux_stream = message });
}

pub fn sendTeStreamItemFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendClientRemotePayloadFrame(allocator, fd, .{ .terminal_emulator = item });
}

pub fn sendTeStreamPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.TerminalEmulatorItem.payload_union,
) !void {
    try sendTeStreamItemFrame(allocator, fd, .{ .payload = payload });
}

pub fn sendProxyStreamPayloadFrame(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: pb.ProxyStreamItem.payload_union,
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
    var item = try decodePayload(pb.ClientRemoteItem, allocator, payload);
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
    var item = try decodePayload(pb.ClientRemoteItem, allocator, payload);
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
    var item = try decodePayload(pb.DaemonTunnelItem, allocator, payload);
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
    var item = try decodePayload(pb.ClientDaemonItem, allocator, payload);
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
    var item = try decodePayload(pb.ClientDaemonItem, allocator, payload);
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

pub fn encodeFrame(allocator: std.mem.Allocator, message_type: MessageType, payload: []const u8) ![]u8 {
    return encodeFrameWithAttachedBytes(allocator, message_type, payload, &.{});
}

pub fn encodeFrameWithAttachedBytes(
    allocator: std.mem.Allocator,
    message_type: MessageType,
    payload: []const u8,
    attached_bytes: []const u8,
) ![]u8 {
    const message = try encodeMessagePayload(allocator, message_type, payload, attached_bytes.len);
    defer allocator.free(message);
    if (message.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    if (attached_bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    const frame = try allocator.alloc(u8, frame_header_len + message.len + attached_bytes.len);
    writeU32(frame[0..frame_header_len], @intCast(message.len));
    @memcpy(frame[frame_header_len..][0..message.len], message);
    @memcpy(frame[frame_header_len + message.len ..], attached_bytes);
    return frame;
}

pub fn messageLenFromHeader(header: *const [frame_header_len]u8) usize {
    return @intCast(readU32(header));
}

fn readFrameMessageAlloc(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var length_bytes: [frame_header_len]u8 = undefined;
    try io.readExact(fd, &length_bytes);

    const message_len = messageLenFromHeader(&length_bytes);
    const message = try allocator.alloc(u8, message_len);
    errdefer allocator.free(message);
    try io.readExact(fd, message);
    return message;
}

fn decodeMessageAlloc(allocator: std.mem.Allocator, fd: c.fd_t, message_bytes: []const u8) !OwnedFrame {
    var decoded = try decodeMessageEnvelopeAlloc(allocator, message_bytes);
    errdefer decoded.frame.deinit(allocator);
    const attached_bytes = try readAttachedBytesAlloc(allocator, fd, decoded.attached_bytes_len);
    errdefer allocator.free(attached_bytes);

    var frame = decoded.frame;
    frame.attached_bytes = attached_bytes;
    return frame;
}

const DecodedMessageEnvelope = struct {
    frame: OwnedFrame,
    attached_bytes_len: usize = 0,
};

fn decodeMessageEnvelopeAlloc(allocator: std.mem.Allocator, message_bytes: []const u8) !DecodedMessageEnvelope {
    if (message_bytes.len == 0) return error.UnknownFrame;
    if (isHelloFrameEnvelope(message_bytes)) return .{
        .frame = try decodeHelloMessageAlloc(allocator, message_bytes),
    };

    var frame = try decodePayload(pb.Frame, allocator, message_bytes);
    defer frame.deinit(allocator);
    const attached_bytes_len: usize = @intCast(frame.attached_bytes_len orelse 0);

    return switch (frame.payload orelse return error.UnknownFrame) {
        .@"error" => |message| .{
            .frame = try ownedFrameFromMessage(allocator, .error_message, message),
            .attached_bytes_len = attached_bytes_len,
        },
        .client_daemon => |message| .{
            .frame = try ownedFrameFromMessage(allocator, .client_daemon, message),
            .attached_bytes_len = attached_bytes_len,
        },
        .client_remote => |message| .{
            .frame = try ownedFrameFromMessage(allocator, .client_remote, message),
            .attached_bytes_len = attached_bytes_len,
        },
        .daemon_tunnel => |message| .{
            .frame = try ownedFrameFromMessage(allocator, .daemon_tunnel, message),
            .attached_bytes_len = attached_bytes_len,
        },
    };
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

fn readAttachedBytesAlloc(allocator: std.mem.Allocator, fd: c.fd_t, len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try io.readExact(fd, bytes);
    return bytes;
}

const ReadSomeResult = union(enum) {
    blocked,
    eof,
    bytes: []const u8,
};

fn readSome(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    if (buf.len == 0) return .{ .bytes = buf };
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .eof;
        switch (posix.errno(n)) {
            .AGAIN => return .blocked,
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn encodeMessagePayload(
    allocator: std.mem.Allocator,
    message_type: MessageType,
    payload: []const u8,
    attached_bytes_len: usize,
) ![]u8 {
    return switch (message_type) {
        .hello_request => blk: {
            if (attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            var message = try decodePayload(hpb.HelloRequest, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_request = message } });
        },
        .hello_ok => blk: {
            if (attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            var message = try decodePayload(hpb.HelloOk, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_ok = message } });
        },
        .hello_error => blk: {
            if (attached_bytes_len != 0) return error.AttachedBytesUnsupported;
            var message = try decodePayload(hpb.HelloError, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, hpb.HelloFrame{ .payload = .{ .hello_error = message } });
        },
        .error_message => blk: {
            var message = try decodePayload(hpb.Error, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached_bytes_len = optionalAttachedBytesLen(attached_bytes_len),
                .payload = .{ .@"error" = message },
            });
        },
        .client_daemon => blk: {
            var message = try decodePayload(pb.ClientDaemonItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached_bytes_len = optionalAttachedBytesLen(attached_bytes_len),
                .payload = .{ .client_daemon = message },
            });
        },
        .client_remote => blk: {
            var message = try decodePayload(pb.ClientRemoteItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached_bytes_len = optionalAttachedBytesLen(attached_bytes_len),
                .payload = .{ .client_remote = message },
            });
        },
        .daemon_tunnel => blk: {
            var message = try decodePayload(pb.DaemonTunnelItem, allocator, payload);
            defer message.deinit(allocator);
            break :blk encodePayload(allocator, pb.Frame{
                .attached_bytes_len = optionalAttachedBytesLen(attached_bytes_len),
                .payload = .{ .daemon_tunnel = message },
            });
        },
    };
}

fn optionalAttachedBytesLen(attached_bytes_len: usize) ?u32 {
    return if (attached_bytes_len == 0) null else @intCast(attached_bytes_len);
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

test "frame envelope round trip" {
    const payload = try encodePayload(std.testing.allocator, pb.ClientRemoteItem{
        .payload = .{ .terminal_emulator = .{ .payload = .{ .input_ack = .{ .input_seq = 42 } } } },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrame(std.testing.allocator, .client_remote, payload);
    defer std.testing.allocator.free(frame_bytes);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try io.writeAll(pipe[1], frame_bytes);
    var frame = try readFrameAlloc(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.client_remote, frame.message_type);
    try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);

    var item = try decodeClientRemoteTerminalEmulatorItem(std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    const item_payload = item.payload orelse return error.MissingTePayload;
    switch (item_payload) {
        .input_ack => |ack| try std.testing.expectEqual(@as(u64, 42), ack.input_seq),
        else => return error.UnexpectedTePayload,
    }
}

test "mux stream frame preserves stream id offset and proxy payload" {
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
    try io.writeAll(pipe[1], frame_bytes);
    var frame = try readFrameAlloc(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.daemon_tunnel, frame.message_type);
    try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);

    var decoded = try decodeDaemonMuxStreamFrame(std.testing.allocator, frame.payload);
    defer decoded.deinit(std.testing.allocator);
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

test "frame envelope preserves attached bytes appendix" {
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrameWithAttachedBytes(std.testing.allocator, .client_daemon, payload, "attached-bytes");
    defer std.testing.allocator.free(frame_bytes);

    var header: [frame_header_len]u8 = undefined;
    @memcpy(&header, frame_bytes[0..frame_header_len]);
    const message_len = messageLenFromHeader(&header);
    try std.testing.expectEqual(frame_bytes.len, frame_header_len + message_len + "attached-bytes".len);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try io.writeAll(pipe[1], frame_bytes);
    var frame = try readFrameAlloc(std.testing.allocator, pipe[0]);
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

test "frame reader returns complete frame after incremental nonblocking reads" {
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try encodeFrameWithAttachedBytes(std.testing.allocator, .client_daemon, payload, "attached-bytes");
    defer std.testing.allocator.free(frame_bytes);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try setNonBlockingFdForTest(pipe[0]);

    var reader = FrameReader.init(std.testing.allocator);
    defer reader.deinit();

    try std.testing.expectEqual(FrameReadStatus.blocked, try reader.readReady(pipe[0]));
    try io.writeAll(pipe[1], frame_bytes[0..2]);
    try std.testing.expectEqual(FrameReadStatus.progress, try reader.readReady(pipe[0]));
    try std.testing.expectEqual(FrameReadStatus.blocked, try reader.readReady(pipe[0]));

    try io.writeAll(pipe[1], frame_bytes[2 .. frame_bytes.len - 3]);
    while (true) {
        switch (try reader.readReady(pipe[0])) {
            .progress => continue,
            .blocked => break,
            else => return error.UnexpectedFrameReadStatus,
        }
    }

    try io.writeAll(pipe[1], frame_bytes[frame_bytes.len - 3 ..]);
    while (true) {
        switch (try reader.readReady(pipe[0])) {
            .progress => continue,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(std.testing.allocator);
                try std.testing.expectEqual(MessageType.client_daemon, frame.message_type);
                try std.testing.expectEqualStrings("attached-bytes", frame.attached_bytes);
                var item = try decodePayload(pb.ClientDaemonItem, std.testing.allocator, frame.payload);
                defer item.deinit(std.testing.allocator);
                switch (item.payload orelse return error.MissingClientDaemonPayload) {
                    .log_request => {},
                    else => return error.UnexpectedClientDaemonPayload,
                }
                break;
            },
            else => return error.UnexpectedFrameReadStatus,
        }
    }
}

test "frame reader reports eof shape for empty and partial streams" {
    const clean_pipe = try posix.pipe();
    defer _ = c.close(clean_pipe[0]);
    try setNonBlockingFdForTest(clean_pipe[0]);
    _ = c.close(clean_pipe[1]);
    var clean = FrameReader.init(std.testing.allocator);
    defer clean.deinit();
    try std.testing.expectEqual(FrameReadStatus.eof, try clean.readReady(clean_pipe[0]));

    const partial_pipe = try posix.pipe();
    defer _ = c.close(partial_pipe[0]);
    try setNonBlockingFdForTest(partial_pipe[0]);
    try io.writeAll(partial_pipe[1], "\x00\x00");
    _ = c.close(partial_pipe[1]);
    var partial = FrameReader.init(std.testing.allocator);
    defer partial.deinit();
    try std.testing.expectEqual(FrameReadStatus.progress, try partial.readReady(partial_pipe[0]));
    try std.testing.expectEqual(FrameReadStatus.truncated_frame, try partial.readReady(partial_pipe[0]));
}

test "frame writer completes frame through incremental nonblocking writes" {
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);

    const attached_bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(attached_bytes);
    @memset(attached_bytes, 'x');

    const expected = try encodeFrameWithAttachedBytes(std.testing.allocator, .client_daemon, payload, attached_bytes);
    defer std.testing.allocator.free(expected);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try setNonBlockingFdForTest(pipe[0]);
    try setNonBlockingFdForTest(pipe[1]);

    var writer = try FrameWriteState.initWithAttachedBytes(std.testing.allocator, .client_daemon, payload, attached_bytes);
    defer writer.deinit();
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(std.testing.allocator);

    var saw_progress = false;
    while (true) {
        switch (try writer.writeReady(pipe[1])) {
            .blocked => {},
            .progress => saw_progress = true,
            .done => {
                try drainPipeForTest(pipe[0], &actual);
                break;
            },
        }
        try drainPipeForTest(pipe[0], &actual);
    }

    try std.testing.expect(saw_progress);
    try std.testing.expectEqualSlices(u8, expected, actual.items);
}

test "remote process started preserves stream id and cleanup identity" {
    const payload = try encodePayload(std.testing.allocator, pb.DaemonTunnelItem{
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

    var item = try decodePayload(pb.DaemonTunnelItem, std.testing.allocator, payload);
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

fn setNonBlockingFdForTest(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

fn drainPipeForTest(fd: c.fd_t, actual: *std.ArrayList(u8)) !void {
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return;
        try actual.appendSlice(std.testing.allocator, buffer[0..@intCast(n)]);
    }
}

test "hello compatibility accepts peer max protocol when it satisfies local minimum" {
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 9,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 4,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 4,
        .protocol_minor = 0,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.6.0-dev",
    }, 3, 0));
}

test "session ended exit status is optional" {
    const payload = try encodePayload(std.testing.allocator, pb.TerminalEmulatorItem.SessionEnded{
        .reason = .REASON_KILLED_BY_REQUEST,
        .ended_at_unix_ms = 42,
    });
    defer std.testing.allocator.free(payload);

    var decoded = try decodePayload(pb.TerminalEmulatorItem.SessionEnded, std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.TerminalEmulatorItem.SessionEnded.Reason.REASON_KILLED_BY_REQUEST, decoded.reason);
    try std.testing.expectEqual(@as(?pb.TerminalEmulatorItem.SessionEnded.ExitStatus, null), decoded.exit_status);
    try std.testing.expectEqual(@as(?u64, 42), decoded.ended_at_unix_ms);
}
