// Dispatcher-facing IO primitives. Concrete byte/frame sources and sinks hide
// partial read/write state from callers; the Dispatcher owns the mapping from
// fds to these objects and uses their readiness methods to schedule work.
const std = @import("std");
const c = std.c;

const core_blocking = @import("blocking.zig");
const fd_passing = @import("fd_passing.zig");
const io = @import("io.zig");
const protocol_frame = @import("../protocol/frame.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

/// Default byte-sink buffering for long-lived dispatcher-owned fds.
///
/// Specific paths can use a tighter or looser bound, but an omitted limit must
/// never mean "unbounded". Once a sink is above its low watermark, tasks that
/// depend on it stop reading more input, which pushes backpressure through the
/// dispatcher instead of letting memory grow without limit.
pub const default_byte_sink_max_pending_bytes: usize = 1024 * 1024;
pub const default_byte_sink_low_watermark: usize = 256 * 1024;

/// Default frame-sink buffering for long-lived dispatcher-owned fds.
///
/// Frames are larger than raw byte bridge chunks because a single repaint or
/// forwarded payload can legitimately be sizeable. The important property is
/// still that every frame sink has a finite queue unless a caller deliberately
/// opts into a different bound.
pub const default_frame_sink_max_pending_bytes: usize = 64 * 1024 * 1024;
pub const default_frame_sink_low_watermark: usize = 16 * 1024 * 1024;

pub const SourceReadStatus = enum {
    blocked,
    progress,
    ready,
    eof,
};

pub const SinkWriteStatus = enum {
    blocked,
    progress,
    drained,
};

pub const DispatchTaskStatus = enum {
    done,
    pending,
};

/// Non-blocking reader for raw bytes from one fd.
///
/// The dispatcher calls `readReady()` when `poll(2)` says the fd is readable.
/// Any positive read is enough to wake the owning task; callers then use
/// `read()` to take that byte slice. The internal buffer is deliberately not
/// exposed as a queue because task code should reason in terms of "bytes became
/// available", not "how much storage is currently filled".
pub const ByteSource = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    buffer: []u8,
    read_options: io.ReadSomeOptions = .{},
    filled: usize = 0,
    eof: bool = false,

    pub const Read = union(enum) {
        bytes: []const u8,
        eof,
    };

    pub fn init(allocator: std.mem.Allocator, fd: c.fd_t, capacity: usize) !ByteSource {
        return initWithOptions(.{
            .allocator = allocator,
            .fd = fd,
            .capacity = capacity,
        });
    }

    pub fn initWithOptions(options: ByteSourceOptions) !ByteSource {
        return .{
            .allocator = options.allocator,
            .fd = options.fd,
            .buffer = try options.allocator.alloc(u8, options.capacity),
            .read_options = options.read_options,
        };
    }

    pub fn deinit(self: *ByteSource) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Takes the currently available bytes or EOF marker.
    ///
    /// Returning bytes transfers that slice to the caller until the next
    /// `readReady()` call. The source has a single consumer, so clearing
    /// `filled` here is the transfer; no explicit discard API should exist.
    pub fn read(self: *ByteSource) ?Read {
        if (self.filled != 0) {
            const bytes = self.buffer[0..self.filled];
            self.filled = 0;
            return .{ .bytes = bytes };
        }
        if (self.eof) {
            self.eof = false;
            return .eof;
        }
        return null;
    }

    /// Pull at most one readiness unit from the fd.
    ///
    /// A short read is not treated as "try again immediately"; on a
    /// non-blocking fd the next read may block, and fairness is better if the
    /// dispatcher gets a chance to run other ready tasks first.
    pub fn readReady(self: *ByteSource) !SourceReadStatus {
        if (self.filled != 0 or self.eof) return .ready;
        switch (try io.readSomeNonBlockingWithOptions(self.fd, self.buffer[self.filled..], self.read_options)) {
            .would_block => return .blocked,
            .eof => {
                std.debug.assert(self.filled == 0);
                self.eof = true;
                return .eof;
            },
            .bytes => |bytes| {
                self.filled += bytes.len;
                return .ready;
            },
        }
    }
    pub fn hasReadyUnit(self: *const ByteSource) bool {
        return self.filled != 0 or self.eof;
    }
};

pub const ByteSourceOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    capacity: usize,
    read_options: io.ReadSomeOptions = .{},
};

/// Non-blocking writer for raw bytes to one fd.
///
/// `writeBytes()` accepts ownership of a copy of the bytes into bounded
/// internal storage. The dispatcher calls `writeReady()` while the fd is
/// writable until the stored bytes drain below task watermarks.
pub const ByteSink = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    bytes: std.ArrayList(u8) = .empty,
    written: usize = 0,
    max_pending_bytes: usize,
    low_watermark: usize,
    drained_ready: bool = false,
    write_error: ?anyerror = null,

    pub fn init(options: ByteSinkOptions) ByteSink {
        return .{
            .allocator = options.allocator,
            .fd = options.fd,
            .max_pending_bytes = options.max_pending_bytes,
            .low_watermark = options.low_watermark,
        };
    }

    pub fn deinit(self: *ByteSink) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pendingBytes(self: *const ByteSink) usize {
        return self.bytes.items.len - self.written;
    }

    pub fn hasPendingWrite(self: *const ByteSink) bool {
        return self.pendingBytes() != 0;
    }

    pub fn belowWatermark(self: *const ByteSink) bool {
        return self.pendingBytes() <= self.low_watermark;
    }

    pub fn writeBytes(self: *ByteSink, bytes: []const u8) !void {
        if (self.write_error != null) return error.ByteSinkFailed;
        if (bytes.len > self.max_pending_bytes or self.pendingBytes() > self.max_pending_bytes - bytes.len) {
            return error.ByteSinkFull;
        }
        self.drained_ready = false;
        if (self.written == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.written = 0;
        }
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    pub fn writeReady(self: *ByteSink) !SinkWriteStatus {
        const had_pending = self.hasPendingWrite();
        var made_progress = false;
        while (self.written < self.bytes.items.len) {
            const remaining = self.bytes.items[self.written..];
            switch (try io.writeSomeNonBlocking(self.fd, remaining)) {
                .would_block => return if (made_progress) .progress else .blocked,
                .wrote => |count| {
                    if (count == 0) return error.WriteFailed;
                    self.written += count;
                    made_progress = true;
                    if (self.written < self.bytes.items.len) return .progress;
                },
            }
        }
        self.bytes.clearRetainingCapacity();
        self.written = 0;
        if (had_pending) self.drained_ready = true;
        return .drained;
    }

    pub fn hasReadyUnit(self: *const ByteSink) bool {
        return self.drained_ready or self.write_error != null;
    }

    pub fn takeReadyUnit(self: *ByteSink) bool {
        if (!self.drained_ready) return false;
        self.drained_ready = false;
        return true;
    }

    pub fn markWriteError(self: *ByteSink, err: anyerror) void {
        self.write_error = err;
    }

    pub fn takeWriteError(self: *ByteSink) ?anyerror {
        const err = self.write_error orelse return null;
        self.write_error = null;
        return err;
    }
};

pub const ByteSinkOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    max_pending_bytes: usize = default_byte_sink_max_pending_bytes,
    low_watermark: usize = default_byte_sink_low_watermark,
};

/// Non-blocking reader for sessh frames from one fd.
///
/// This wraps `protocol.FrameReader`, which understands the four-byte frame
/// length, the protobuf Frame message, optional attached raw bytes, and
/// optional SCM_RIGHTS descriptor marker. The source returns complete frames
/// only; task code never sees a partially decoded protocol message.
pub const FrameSource = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reader: protocol_frame.FrameReader,
    frames: std.ArrayList(protocol.OwnedFrame) = .empty,
    eof: bool = false,

    pub const Read = union(enum) {
        blocked,
        eof,
        frame: protocol.OwnedFrame,
    };

    pub fn init(allocator: std.mem.Allocator, fd: c.fd_t) FrameSource {
        return .{
            .allocator = allocator,
            .fd = fd,
            .reader = protocol_frame.FrameReader.init(allocator),
        };
    }

    pub fn deinit(self: *FrameSource) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.reader.deinit();
        self.* = undefined;
    }

    pub fn popFrame(self: *FrameSource) ?protocol.OwnedFrame {
        if (self.frames.items.len == 0) return null;
        return self.frames.orderedRemove(0);
    }

    pub fn readFrame(self: *FrameSource) !Read {
        if (self.popFrame()) |frame| return .{ .frame = frame };
        if (self.eof) {
            self.eof = false;
            return .eof;
        }
        const status = try self.readReady();
        return switch (status) {
            .blocked, .progress => .blocked,
            .ready => .{ .frame = self.popFrame() orelse return error.ExpectedFrame },
            .eof => blk: {
                self.eof = false;
                break :blk .eof;
            },
        };
    }

    pub fn readReady(self: *FrameSource) !SourceReadStatus {
        // Read at most one logical frame per dispatcher readiness event. A
        // frame can involve several syscalls, but stopping at one completed
        // frame gives the DispatchTask scheduler a chance to run unrelated
        // ready work before this connection consumes more input.
        while (true) {
            switch (try self.reader.readReady(self.fd)) {
                .blocked => return .blocked,
                .progress => return .progress,
                .eof => {
                    self.eof = true;
                    return .eof;
                },
                .truncated_frame => return error.TruncatedFrame,
                .frame => |frame| {
                    try self.frames.append(self.allocator, frame);
                    return .ready;
                },
            }
        }
    }
    pub fn hasReadyUnit(self: *const FrameSource) bool {
        return self.frames.items.len != 0 or self.eof;
    }
};

/// Non-blocking writer for sessh frames to one fd.
///
/// Callers ask to write logical frames. The sink serializes them one at a time
/// so protobuf bytes, attached raw bytes, and SCM_RIGHTS descriptor markers
/// never interleave with bytes from another frame.
pub const FrameSink = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    entries: std.ArrayList(FrameSinkEntry) = .empty,
    max_pending_bytes: usize,
    low_watermark: usize,
    drained_ready: bool = false,
    write_error: ?anyerror = null,

    pub fn init(options: FrameSinkOptions) FrameSink {
        return .{
            .allocator = options.allocator,
            .fd = options.fd,
            .max_pending_bytes = options.max_pending_bytes,
            .low_watermark = options.low_watermark,
        };
    }

    pub fn deinit(self: *FrameSink) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasPendingWrite(self: *const FrameSink) bool {
        return self.entries.items.len != 0;
    }

    pub fn pendingBytes(self: *const FrameSink) usize {
        var total: usize = 0;
        for (self.entries.items) |*entry| total += entry.pendingBytes();
        return total;
    }

    pub fn belowWatermark(self: *const FrameSink) bool {
        return self.pendingBytes() <= self.low_watermark;
    }

    pub fn writeFrame(
        self: *FrameSink,
        message_type: protocol.MessageType,
        payload: []const u8,
    ) !void {
        var entry = try FrameSinkEntry.initFrame(self.allocator, message_type, payload);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn writeFrameBounded(self: *FrameSink, request: BoundedFrameWrite) !void {
        var entry = try FrameSinkEntry.initFrame(self.allocator, request.message_type, request.payload);
        errdefer entry.deinit();
        try self.appendEntry(entry, request.max_pending_bytes);
    }

    pub fn writeFrameWithScmRightsFd(
        self: *FrameSink,
        message_type: protocol.MessageType,
        payload: []const u8,
        passed_fd: c.fd_t,
    ) !void {
        var entry = try FrameSinkEntry.initScmRightsFrame(self.allocator, message_type, payload, passed_fd);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn writeOwnedFrame(self: *FrameSink, frame: *protocol.OwnedFrame) !void {
        if (frame.fd) |fd| {
            frame.fd = null;
            try self.writeFrameWithScmRightsFd(frame.message_type, frame.payload, fd);
            return;
        }
        var entry = try FrameSinkEntry.initOwnedFrame(self.allocator, frame.*);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn writeDaemonTunnelPayload(
        self: *FrameSink,
        payload: protocol.DaemonTunnelPayload,
    ) !void {
        const encoded = try protocol.encodeDaemonTunnelPayload(self.allocator, payload);
        defer self.allocator.free(encoded);
        try self.writeFrame(.daemon_tunnel, encoded);
    }

    pub fn writeClientRemotePayload(
        self: *FrameSink,
        payload: protocol.ClientRemotePayload,
    ) !void {
        const encoded = try protocol.encodeClientRemotePayload(self.allocator, payload);
        defer self.allocator.free(encoded);
        try self.writeFrame(.client_remote, encoded);
    }

    pub fn writeTerminalEmulatorPayload(
        self: *FrameSink,
        payload: protocol.TerminalEmulatorPayload,
    ) !void {
        try self.writeClientRemotePayload(.{ .terminal_emulator = .{ .payload = payload } });
    }

    pub fn writeMuxStreamFrame(
        self: *FrameSink,
        message: pb.DaemonTunnelItem.MuxStreamFrame,
    ) !void {
        try self.writeDaemonTunnelPayload(.{ .mux_stream = message });
    }

    pub fn writeReadyTo(self: *FrameSink, fd: c.fd_t) !SinkWriteStatus {
        self.fd = fd;
        return self.writeReady();
    }

    pub fn writeReady(self: *FrameSink) !SinkWriteStatus {
        const had_pending = self.hasPendingWrite();
        var made_progress = false;
        while (self.entries.items.len != 0) {
            const entry = &self.entries.items[0];
            switch (try entry.writeReady(self.fd)) {
                .blocked => return if (made_progress) .progress else .blocked,
                .progress => return .progress,
                .done => {
                    made_progress = true;
                    entry.deinit();
                    _ = self.entries.orderedRemove(0);
                },
            }
        }
        if (had_pending) self.drained_ready = true;
        return .drained;
    }

    fn appendEntry(self: *FrameSink, entry: FrameSinkEntry, override_limit: ?usize) !void {
        if (self.write_error != null) return error.FrameSinkFailed;
        const limit = override_limit orelse self.max_pending_bytes;
        const entry_len = entry.pendingBytes();
        if (entry_len > limit or self.pendingBytes() > limit - entry_len) {
            return error.FrameSinkFull;
        }
        self.drained_ready = false;
        try self.entries.append(self.allocator, entry);
    }

    pub fn hasReadyUnit(self: *const FrameSink) bool {
        return self.drained_ready or self.write_error != null;
    }

    pub fn takeReadyUnit(self: *FrameSink) bool {
        if (!self.drained_ready) return false;
        self.drained_ready = false;
        return true;
    }

    pub fn markWriteError(self: *FrameSink, err: anyerror) void {
        self.write_error = err;
    }

    pub fn takeWriteError(self: *FrameSink) ?anyerror {
        const err = self.write_error orelse return null;
        self.write_error = null;
        return err;
    }
};

pub const FrameSinkOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    max_pending_bytes: usize = default_frame_sink_max_pending_bytes,
    low_watermark: usize = default_frame_sink_low_watermark,
};

pub const BoundedFrameWrite = struct {
    message_type: protocol.MessageType,
    payload: []const u8,
    max_pending_bytes: usize,
};

// One queued logical frame. Ordinary frames are a contiguous byte string, while
// SCM_RIGHTS frames have to write a normal prefix first and then a one-byte
// marker with sendmsg so the descriptor is attached to that exact byte.
const FrameSinkEntry = union(enum) {
    frame: protocol.FrameWriteState,
    scm_rights_frame: ScmRightsFrameWriteState,

    fn initFrame(
        allocator: std.mem.Allocator,
        message_type: protocol.MessageType,
        payload: []const u8,
    ) !FrameSinkEntry {
        return .{ .frame = try protocol.FrameWriteState.init(allocator, message_type, payload) };
    }

    fn initOwnedFrame(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !FrameSinkEntry {
        return .{ .frame = try protocol.FrameWriteState.initOwnedFrame(allocator, frame) };
    }

    fn initScmRightsFrame(
        allocator: std.mem.Allocator,
        message_type: protocol.MessageType,
        payload: []const u8,
        passed_fd: c.fd_t,
    ) !FrameSinkEntry {
        return .{
            .scm_rights_frame = try ScmRightsFrameWriteState.init(allocator, message_type, payload, passed_fd),
        };
    }

    fn deinit(self: *FrameSinkEntry) void {
        switch (self.*) {
            .frame => |*frame| frame.deinit(),
            .scm_rights_frame => |*frame| frame.deinit(),
        }
        self.* = undefined;
    }

    fn pendingBytes(self: *const FrameSinkEntry) usize {
        return switch (self.*) {
            .frame => |*frame| frame.bytes.len - frame.written,
            .scm_rights_frame => |*frame| frame.pendingBytes(),
        };
    }

    fn writeReady(self: *FrameSinkEntry, fd: c.fd_t) !protocol.FrameWriteStatus {
        return switch (self.*) {
            .frame => |*frame| frame.writeReady(fd),
            .scm_rights_frame => |*frame| frame.writeReady(fd),
        };
    }
};

// Write state for one frame that carries an SCM_RIGHTS descriptor.
//
// The encoded frame is still one sessh frame: a length-prefixed protobuf
// message followed by one attached marker byte. Only that marker byte is sent
// with sendmsg/SCM_RIGHTS; the prefix is ordinary stream data. Splitting the
// state this way keeps fd passing localized without making every frame write
// use sendmsg.
const ScmRightsFrameWriteState = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    prefix: fd_passing.SendByteProgress,
    marker: fd_passing.SendBufferWithFdProgress,

    fn init(
        allocator: std.mem.Allocator,
        message_type: protocol.MessageType,
        payload: []const u8,
        passed_fd: c.fd_t,
    ) !ScmRightsFrameWriteState {
        var owned_fd = @import("fds.zig").OwnedFd.init(passed_fd);
        errdefer owned_fd.deinit();

        const marker = [_]u8{0};
        const bytes = try protocol.encodeFrameWithAttachedKindAndBytes(allocator, .{
            .message_type = message_type,
            .payload = payload,
            .attached_kind = protocol.pb.Frame.Attached.Kind.SCM_RIGHTS,
            .attached_bytes = &marker,
        });
        errdefer allocator.free(bytes);

        var header: [protocol.frame_header_len]u8 = undefined;
        @memcpy(&header, bytes[0..protocol.frame_header_len]);
        const message_len = protocol.messageLenFromHeader(&header);
        const attached_start = protocol.frame_header_len + message_len;
        if (bytes.len != attached_start + marker.len) return error.InvalidFileDescriptorCarrierFrame;

        return .{
            .allocator = allocator,
            .bytes = bytes,
            .prefix = fd_passing.SendByteProgress.init(bytes[0..attached_start]),
            .marker = fd_passing.SendBufferWithFdProgress.init(bytes[attached_start..], owned_fd.take()),
        };
    }

    fn deinit(self: *ScmRightsFrameWriteState) void {
        self.marker.deinit();
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn pendingBytes(self: *const ScmRightsFrameWriteState) usize {
        return self.prefix.remaining().len + self.marker.remaining().len;
    }

    fn writeReady(self: *ScmRightsFrameWriteState, fd: c.fd_t) !protocol.FrameWriteStatus {
        switch (try fd_passing.sendByteProgress(fd, &self.prefix)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .complete => {},
            .eof => unreachable,
        }
        switch (try fd_passing.sendBufferWithFdProgress(fd, &self.marker)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .complete => return .done,
            .eof => unreachable,
        }
    }
};

test "byte sink preserves pending byte order" {
    const posix = std.posix;
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var sink = ByteSink.init(.{
        .allocator = std.testing.allocator,
        .fd = pipe[1],
        .max_pending_bytes = 64,
    });
    defer sink.deinit();

    try sink.writeBytes("ab");
    try sink.writeBytes("cd");
    try std.testing.expect(sink.hasPendingWrite());
    try std.testing.expectEqual(SinkWriteStatus.drained, try sink.writeReady());

    var buf: [4]u8 = undefined;
    const n = c.read(pipe[0], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("abcd", buf[0..@intCast(n)]);
}

test "byte source is ready after any bytes are read" {
    const posix = std.posix;
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var source = try ByteSource.init(std.testing.allocator, pipe[0], 8);
    defer source.deinit();

    try core_blocking.fromTest().writeAll(pipe[1], "x");
    try std.testing.expectEqual(SourceReadStatus.ready, try source.readReady());
    switch (source.read() orelse return error.ExpectedRead) {
        .bytes => |bytes| try std.testing.expectEqualStrings("x", bytes),
        .eof => return error.UnexpectedEof,
    }
}

test "sink defaults are finite" {
    try std.testing.expect(default_byte_sink_max_pending_bytes < std.math.maxInt(usize));
    try std.testing.expect(default_frame_sink_max_pending_bytes < std.math.maxInt(usize));
    try std.testing.expect(default_byte_sink_low_watermark < default_byte_sink_max_pending_bytes);
    try std.testing.expect(default_frame_sink_low_watermark < default_frame_sink_max_pending_bytes);
}

test "frame source and sink preserve frame order" {
    const posix = std.posix;
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var sink = FrameSink.init(.{
        .allocator = std.testing.allocator,
        .fd = pipe[1],
    });
    defer sink.deinit();

    const first = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(first);
    const second = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_entry = .{
        .unix_ms = 1,
        .message = "ordered",
    } });
    defer std.testing.allocator.free(second);

    try sink.writeFrame(.client_daemon, first);
    try sink.writeFrame(.client_daemon, second);
    try std.testing.expectEqual(SinkWriteStatus.drained, try sink.writeReady());

    var source = FrameSource.init(std.testing.allocator, pipe[0]);
    defer source.deinit();

    try std.testing.expectEqual(SourceReadStatus.ready, try source.readReady());
    var first_frame = source.popFrame() orelse return error.ExpectedFrame;
    defer first_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, first_frame.message_type);

    try std.testing.expectEqual(SourceReadStatus.ready, try source.readReady());
    var second_frame = source.popFrame() orelse return error.ExpectedFrame;
    defer second_frame.deinit(std.testing.allocator);
    var decoded = try protocol.decodePayload(protocol.pb.ClientDaemonItem, std.testing.allocator, second_frame.payload);
    defer decoded.deinit(std.testing.allocator);
    switch (decoded.payload orelse return error.MissingClientDaemonPayload) {
        .log_entry => |entry| try std.testing.expectEqualStrings("ordered", entry.message),
        else => return error.UnexpectedClientDaemonPayload,
    }
}

test "frame sink rejects writes above its pending limit" {
    const posix = std.posix;
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var sink = FrameSink.init(.{
        .allocator = std.testing.allocator,
        .fd = pipe[1],
        .max_pending_bytes = 0,
    });
    defer sink.deinit();

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(error.FrameSinkFull, sink.writeFrame(.client_daemon, payload));
}

test "frame sink can send an SCM_RIGHTS frame" {
    const blocking = core_blocking.fromTest();
    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer {
        _ = c.close(control[0]);
        _ = c.close(control[1]);
    }

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    var sink = FrameSink.init(.{
        .allocator = std.testing.allocator,
        .fd = control[0],
    });
    defer sink.deinit();

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .proxy_fd_pass_open = .{} });
    defer std.testing.allocator.free(payload);
    try sink.writeFrameWithScmRightsFd(.client_daemon, payload, raw[0]);
    try std.testing.expectEqual(SinkWriteStatus.drained, try sink.writeReady());

    var source = FrameSource.init(std.testing.allocator, control[1]);
    defer source.deinit();
    try std.testing.expectEqual(SourceReadStatus.ready, try source.readReady());

    var frame = source.popFrame() orelse return error.ExpectedFrame;
    defer frame.deinit(std.testing.allocator);
    const received_fd = frame.takeFd() orelse return error.ExpectedFileDescriptor;
    defer _ = c.close(received_fd);

    try blocking.writeAll(received_fd, "raw");
    var buf: [3]u8 = undefined;
    const n = c.read(raw[1], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("raw", buf[0..@intCast(n)]);
}
