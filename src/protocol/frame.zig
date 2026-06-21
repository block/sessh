// Framed protobuf transport used after the compatibility handshake. The reader
// and writer code here is fd-aware because local daemon IPC can attach
// SCM_RIGHTS descriptors while daemon-to-daemon tunnels carry plain bytes.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const core_blocking = @import("../core/blocking.zig");
const fd_passing = @import("../core/fd_passing.zig");
const io = @import("../core/io.zig");
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

pub const FrameWriteState = struct {
    allocator: std.mem.Allocator,
    bytes: []u8 = &.{},
    written: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        message_type: MessageType,
        payload: []const u8,
    ) !FrameWriteState {
        return initWithAttachedKindAndBytes(allocator, .{
            .message_type = message_type,
            .payload = payload,
        });
    }

    pub fn initWithAttachedKindAndBytes(
        allocator: std.mem.Allocator,
        options: AttachedFrameOptions,
    ) !FrameWriteState {
        return .{
            .allocator = allocator,
            .bytes = try encodeFrameWithAttachedKindAndBytes(allocator, options),
        };
    }

    pub fn initOwnedFrame(allocator: std.mem.Allocator, frame: OwnedFrame) !FrameWriteState {
        if (frame.fd != null) return error.FdSendUnsupported;
        return initWithAttachedKindAndBytes(allocator, .{
            .message_type = frame.message_type,
            .payload = frame.payload,
            .attached_bytes = frame.attached_bytes,
        });
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
    attached_kind: pb.Frame.Attached.Kind = .RAW,
    scm_rights_progress: fd_passing.RecvBufferWithFdProgress = .{},
    scm_rights_storage: [1]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) FrameReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameReader) void {
        self.reset();
        self.* = undefined;
    }

    pub fn readReady(self: *FrameReader, fd: c.fd_t) !FrameReadStatus {
        // Incremental frame decoding for dispatcher callbacks. A frame may
        // contain a protobuf message, optional attached raw bytes, or a single
        // SCM_RIGHTS descriptor marker, so each phase is explicit instead of
        // assuming one read maps to one logical frame.
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
            self.attached_kind = decoded.attached_kind;
            switch (decoded.attached_kind) {
                .RAW => {
                    frame.attached_bytes = try self.allocator.alloc(u8, decoded.attached_bytes_len);
                },
                .SCM_RIGHTS => {
                    if (decoded.attached_bytes_len != 1) return error.InvalidFileDescriptorCarrierFrame;
                    self.scm_rights_progress = fd_passing.RecvBufferWithFdProgress.init(self.scm_rights_storage[0..1], null);
                },
                _ => return error.InvalidFrame,
            }
            self.decoded_frame = frame;
            self.attached_filled = 0;
        }

        var frame = &(self.decoded_frame.?);
        switch (self.attached_kind) {
            .RAW => {
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
            },
            .SCM_RIGHTS => {
                if (!self.scm_rights_progress.complete()) {
                    const status = try fd_passing.recvBufferWithFdProgress(fd, &self.scm_rights_progress);
                    switch (status) {
                        .blocked => return .blocked,
                        .eof => return .truncated_frame,
                        .progress => return .progress,
                        .complete => {},
                    }
                }
                frame.fd = self.scm_rights_progress.takeFd() orelse return error.MissingFileDescriptor;
            },
            _ => return error.InvalidFrame,
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
        self.scm_rights_progress.deinit();
        self.scm_rights_progress = .{};
        self.attached_kind = .RAW;
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

const ReadSomeResult = union(enum) {
    blocked,
    eof,
    bytes: []const u8,
};

fn readSome(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    if (buf.len == 0) return .{ .bytes = buf };
    var flags_guard = core_fds.StatusFlagsGuard.setNonBlocking(fd) catch return error.ReadFailed;
    defer flags_guard.restore();

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

// Re-wrap a typed message payload into the correct top-level protobuf envelope.
// Hello messages deliberately stay in HelloFrame, while post-handshake messages
// share Frame and can advertise attached raw bytes or an SCM_RIGHTS carrier.
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

test "frame envelope round trip" {
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

test "frame envelope preserves attached bytes appendix" {
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

test "frame reader returns complete frame after incremental nonblocking reads" {
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

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try test_helpers.setNonBlockingFdForTest(pipe[0]);

    var reader = FrameReader.init(std.testing.allocator);
    defer reader.deinit();

    try std.testing.expectEqual(FrameReadStatus.blocked, try reader.readReady(pipe[0]));
    try blocking.writeAll(pipe[1], frame_bytes[0..2]);
    try std.testing.expectEqual(FrameReadStatus.progress, try reader.readReady(pipe[0]));
    try std.testing.expectEqual(FrameReadStatus.blocked, try reader.readReady(pipe[0]));

    try blocking.writeAll(pipe[1], frame_bytes[2 .. frame_bytes.len - 3]);
    while (true) {
        switch (try reader.readReady(pipe[0])) {
            .progress => continue,
            .blocked => break,
            else => return error.UnexpectedFrameReadStatus,
        }
    }

    try blocking.writeAll(pipe[1], frame_bytes[frame_bytes.len - 3 ..]);
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

test "frame reader returns fd from SCM_RIGHTS marker byte" {
    const blocking = core_blocking.fromTest();
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .proxy_fd_pass_open = .{} },
    });
    defer std.testing.allocator.free(payload);

    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer _ = c.close(control[0]);
    defer _ = c.close(control[1]);

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    try sendScmRightsFrameForTest(.{
        .fd = control[0],
        .message_type = .client_daemon,
        .payload = payload,
        .passed_fd = raw[0],
    });

    var reader = FrameReader.init(std.testing.allocator);
    defer reader.deinit();
    var received_fd: ?c.fd_t = null;
    while (true) {
        switch (try reader.readReady(control[1])) {
            .blocked, .progress => continue,
            .eof, .truncated_frame => return error.UnexpectedEndOfStream,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(std.testing.allocator);
                try std.testing.expectEqual(MessageType.client_daemon, frame.message_type);
                try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);
                received_fd = frame.takeFd();
                break;
            },
        }
    }
    const fd = received_fd orelse return error.MissingFileDescriptor;
    defer _ = c.close(fd);
    try blocking.writeAll(fd, "through-fd");
    var raw_buf: [32]u8 = undefined;
    const n = c.read(raw[1], &raw_buf, raw_buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("through-fd", raw_buf[0..@intCast(n)]);
}

test "test frame reader returns fd from SCM_RIGHTS frame" {
    const blocking = core_blocking.fromTest();
    const payload = try encodePayload(std.testing.allocator, pb.ClientDaemonItem{
        .payload = .{ .proxy_fd_pass_open = .{} },
    });
    defer std.testing.allocator.free(payload);

    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer _ = c.close(control[0]);
    defer _ = c.close(control[1]);

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    try sendScmRightsFrameForTest(.{
        .fd = control[0],
        .message_type = .client_daemon,
        .payload = payload,
        .passed_fd = raw[0],
    });

    var frame = try test_helpers.readFrameForTest(std.testing.allocator, control[1]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(MessageType.client_daemon, frame.message_type);
    try std.testing.expectEqual(@as(usize, 0), frame.attached_bytes.len);

    const fd = frame.takeFd() orelse return error.MissingFileDescriptor;
    defer _ = c.close(fd);
    try blocking.writeAll(fd, "through-test-reader");
    var raw_buf: [64]u8 = undefined;
    const n = c.read(raw[1], &raw_buf, raw_buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("through-test-reader", raw_buf[0..@intCast(n)]);
}

const ScmRightsFrameForTestOptions = struct {
    fd: c.fd_t,
    message_type: MessageType,
    payload: []const u8,
    passed_fd: c.fd_t,
};

// Build the same two-part SCM_RIGHTS frame production code expects: write the
// length-prefixed protobuf message normally, then send the one-byte attachment
// with the descriptor attached to that byte via sendmsg.
fn sendScmRightsFrameForTest(options: ScmRightsFrameForTestOptions) !void {
    const marker = [_]u8{0};
    const frame_bytes = try encodeFrameWithAttachedKindAndBytes(
        std.testing.allocator,
        .{
            .message_type = options.message_type,
            .payload = options.payload,
            .attached_kind = .SCM_RIGHTS,
            .attached_bytes = &marker,
        },
    );
    defer std.testing.allocator.free(frame_bytes);

    var header: [frame_header_len]u8 = undefined;
    @memcpy(&header, frame_bytes[0..frame_header_len]);
    const message_len = messageLenFromHeader(&header);
    const attached_start = frame_header_len + message_len;
    try std.testing.expectEqual(frame_bytes.len, attached_start + marker.len);

    var header_and_message_progress = fd_passing.SendByteProgress.init(frame_bytes[0..attached_start]);
    while (true) {
        switch (try fd_passing.sendByteProgress(options.fd, &header_and_message_progress)) {
            .blocked, .progress => continue,
            .complete => break,
            .eof => unreachable,
        }
    }

    var send_progress = fd_passing.SendBufferWithFdProgress.init(frame_bytes[attached_start..], options.passed_fd);
    defer send_progress.deinit();
    while (true) {
        switch (try fd_passing.sendBufferWithFdProgress(options.fd, &send_progress)) {
            .blocked, .progress => continue,
            .complete => break,
            .eof => unreachable,
        }
    }
}

test "frame reader reports eof shape for empty and partial streams" {
    const blocking = core_blocking.fromTest();
    const clean_pipe = try posix.pipe();
    defer _ = c.close(clean_pipe[0]);
    try test_helpers.setNonBlockingFdForTest(clean_pipe[0]);
    _ = c.close(clean_pipe[1]);
    var clean = FrameReader.init(std.testing.allocator);
    defer clean.deinit();
    try std.testing.expectEqual(FrameReadStatus.eof, try clean.readReady(clean_pipe[0]));

    const partial_pipe = try posix.pipe();
    defer _ = c.close(partial_pipe[0]);
    try test_helpers.setNonBlockingFdForTest(partial_pipe[0]);
    try blocking.writeAll(partial_pipe[1], "\x00\x00");
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

    const expected = try encodeFrameWithAttachedKindAndBytes(std.testing.allocator, .{
        .message_type = .client_daemon,
        .payload = payload,
        .attached_bytes = attached_bytes,
    });
    defer std.testing.allocator.free(expected);

    const pipe = try posix.pipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try test_helpers.setNonBlockingFdForTest(pipe[0]);
    try test_helpers.setNonBlockingFdForTest(pipe[1]);

    var writer = try FrameWriteState.initWithAttachedKindAndBytes(std.testing.allocator, .{
        .message_type = .client_daemon,
        .payload = payload,
        .attached_bytes = attached_bytes,
    });
    defer writer.deinit();
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(std.testing.allocator);

    var saw_progress = false;
    while (true) {
        switch (try writer.writeReady(pipe[1])) {
            .blocked => {},
            .progress => saw_progress = true,
            .done => {
                try test_helpers.drainPipeForTest(std.testing.allocator, pipe[0], &actual);
                break;
            },
        }
        try test_helpers.drainPipeForTest(std.testing.allocator, pipe[0], &actual);
    }

    try std.testing.expect(saw_progress);
    try std.testing.expectEqualSlices(u8, expected, actual.items);
}
