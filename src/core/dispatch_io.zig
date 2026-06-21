// Dispatcher-facing IO primitives. Source and Sink are deliberately small
// interfaces: the Dispatcher should know that a dependency can be read or
// written, but it should not know whether that dependency is a byte stream, a
// protobuf frame stream, or an fd-passing frame stream.
const std = @import("std");
const c = std.c;

const fd_passing = @import("fd_passing.zig");
const io = @import("io.zig");
const protocol = @import("../protocol/mod.zig");

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

pub const Source = struct {
    ctx: *anyopaque,
    fdFn: *const fn (*anyopaque) c.fd_t,
    readReadyFn: *const fn (*anyopaque) anyerror!SourceReadStatus,
    hasReadyUnitFn: *const fn (*anyopaque) bool,

    pub fn fd(self: Source) c.fd_t {
        return self.fdFn(self.ctx);
    }

    pub fn readReady(self: Source) !SourceReadStatus {
        return self.readReadyFn(self.ctx);
    }

    pub fn hasReadyUnit(self: Source) bool {
        return self.hasReadyUnitFn(self.ctx);
    }
};

pub const Sink = struct {
    ctx: *anyopaque,
    fdFn: *const fn (*anyopaque) c.fd_t,
    writeReadyFn: *const fn (*anyopaque) anyerror!SinkWriteStatus,
    hasQueuedBytesFn: *const fn (*anyopaque) bool,
    belowWatermarkFn: *const fn (*anyopaque) bool,

    pub fn fd(self: Sink) c.fd_t {
        return self.fdFn(self.ctx);
    }

    pub fn writeReady(self: Sink) !SinkWriteStatus {
        return self.writeReadyFn(self.ctx);
    }

    pub fn hasQueuedBytes(self: Sink) bool {
        return self.hasQueuedBytesFn(self.ctx);
    }

    pub fn belowWatermark(self: Sink) bool {
        return self.belowWatermarkFn(self.ctx);
    }
};

pub const DispatchTask = struct {
    ctx: *anyopaque,
    sources: []const Source = &.{},
    sinks: []const Sink = &.{},
    not_before_ms: ?u64 = null,
    runFn: *const fn (*anyopaque) anyerror!DispatchTaskStatus,

    pub fn readyAt(self: DispatchTask, now_ms: u64) bool {
        if (self.not_before_ms) |deadline| {
            if (deadline > now_ms) return false;
        }
        for (self.sinks) |sink| {
            if (!sink.belowWatermark()) return false;
        }
        for (self.sources) |source| {
            if (!source.hasReadyUnit()) return false;
        }
        return true;
    }

    pub fn run(self: DispatchTask) !DispatchTaskStatus {
        return self.runFn(self.ctx);
    }
};

pub const ByteSource = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    buffer: []u8,
    filled: usize = 0,
    eof: bool = false,

    pub fn init(allocator: std.mem.Allocator, fd: c.fd_t, capacity: usize) !ByteSource {
        return .{
            .allocator = allocator,
            .fd = fd,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    pub fn deinit(self: *ByteSource) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn source(self: *ByteSource) Source {
        return .{
            .ctx = self,
            .fdFn = byteSourceFd,
            .readReadyFn = byteSourceReadReady,
            .hasReadyUnitFn = byteSourceHasReadyUnit,
        };
    }

    pub fn queuedBytes(self: *const ByteSource) []const u8 {
        return self.buffer[0..self.filled];
    }

    pub fn discardQueuedBytes(self: *ByteSource) void {
        self.filled = 0;
    }

    pub fn readReady(self: *ByteSource) !SourceReadStatus {
        if (self.filled == self.buffer.len) return .ready;
        switch (try io.readSomeNonBlocking(self.fd, self.buffer[self.filled..])) {
            .would_block => return .blocked,
            .eof => {
                self.eof = true;
                return .eof;
            },
            .bytes => |bytes| {
                self.filled += bytes.len;
                return if (self.filled == 0) .progress else .ready;
            },
        }
    }
};

fn byteSourceFd(ctx: *anyopaque) c.fd_t {
    const self: *ByteSource = @ptrCast(@alignCast(ctx));
    return self.fd;
}

fn byteSourceReadReady(ctx: *anyopaque) !SourceReadStatus {
    const self: *ByteSource = @ptrCast(@alignCast(ctx));
    return self.readReady();
}

fn byteSourceHasReadyUnit(ctx: *anyopaque) bool {
    const self: *ByteSource = @ptrCast(@alignCast(ctx));
    return self.filled != 0 or self.eof;
}

pub const ByteSink = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    bytes: std.ArrayList(u8) = .empty,
    written: usize = 0,
    max_queued_bytes: usize,
    low_watermark: usize,

    pub fn init(options: ByteSinkOptions) ByteSink {
        return .{
            .allocator = options.allocator,
            .fd = options.fd,
            .max_queued_bytes = options.max_queued_bytes,
            .low_watermark = options.low_watermark,
        };
    }

    pub fn deinit(self: *ByteSink) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *ByteSink) Sink {
        return .{
            .ctx = self,
            .fdFn = byteSinkFd,
            .writeReadyFn = byteSinkWriteReady,
            .hasQueuedBytesFn = byteSinkHasQueuedBytes,
            .belowWatermarkFn = byteSinkBelowWatermark,
        };
    }

    pub fn queuedBytes(self: *const ByteSink) usize {
        return self.bytes.items.len - self.written;
    }

    pub fn queueBytes(self: *ByteSink, bytes: []const u8) !void {
        if (bytes.len > self.max_queued_bytes or self.queuedBytes() > self.max_queued_bytes - bytes.len) {
            return error.ByteSinkFull;
        }
        if (self.written == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.written = 0;
        }
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    pub fn writeReady(self: *ByteSink) !SinkWriteStatus {
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
        return .drained;
    }
};

pub const ByteSinkOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    max_queued_bytes: usize = std.math.maxInt(usize),
    low_watermark: usize = 0,
};

fn byteSinkFd(ctx: *anyopaque) c.fd_t {
    const self: *ByteSink = @ptrCast(@alignCast(ctx));
    return self.fd;
}

fn byteSinkWriteReady(ctx: *anyopaque) !SinkWriteStatus {
    const self: *ByteSink = @ptrCast(@alignCast(ctx));
    return self.writeReady();
}

fn byteSinkHasQueuedBytes(ctx: *anyopaque) bool {
    const self: *ByteSink = @ptrCast(@alignCast(ctx));
    return self.queuedBytes() != 0;
}

fn byteSinkBelowWatermark(ctx: *anyopaque) bool {
    const self: *ByteSink = @ptrCast(@alignCast(ctx));
    return self.queuedBytes() <= self.low_watermark;
}

pub const FrameSource = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reader: protocol.FrameReader,
    frames: std.ArrayList(protocol.OwnedFrame) = .empty,
    eof: bool = false,

    pub fn init(allocator: std.mem.Allocator, fd: c.fd_t) FrameSource {
        return .{
            .allocator = allocator,
            .fd = fd,
            .reader = protocol.FrameReader.init(allocator),
        };
    }

    pub fn deinit(self: *FrameSource) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.reader.deinit();
        self.* = undefined;
    }

    pub fn source(self: *FrameSource) Source {
        return .{
            .ctx = self,
            .fdFn = frameSourceFd,
            .readReadyFn = frameSourceReadReady,
            .hasReadyUnitFn = frameSourceHasReadyUnit,
        };
    }

    pub fn popFrame(self: *FrameSource) ?protocol.OwnedFrame {
        if (self.frames.items.len == 0) return null;
        return self.frames.orderedRemove(0);
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
};

fn frameSourceFd(ctx: *anyopaque) c.fd_t {
    const self: *FrameSource = @ptrCast(@alignCast(ctx));
    return self.fd;
}

fn frameSourceReadReady(ctx: *anyopaque) !SourceReadStatus {
    const self: *FrameSource = @ptrCast(@alignCast(ctx));
    return self.readReady();
}

fn frameSourceHasReadyUnit(ctx: *anyopaque) bool {
    const self: *FrameSource = @ptrCast(@alignCast(ctx));
    return self.frames.items.len != 0 or self.eof;
}

pub const FrameSink = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    entries: std.ArrayList(FrameSinkEntry) = .empty,
    max_queued_bytes: usize,
    low_watermark: usize,

    pub fn init(options: FrameSinkOptions) FrameSink {
        return .{
            .allocator = options.allocator,
            .fd = options.fd,
            .max_queued_bytes = options.max_queued_bytes,
            .low_watermark = options.low_watermark,
        };
    }

    pub fn deinit(self: *FrameSink) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *FrameSink) Sink {
        return .{
            .ctx = self,
            .fdFn = frameSinkFd,
            .writeReadyFn = frameSinkWriteReady,
            .hasQueuedBytesFn = frameSinkHasQueuedBytes,
            .belowWatermarkFn = frameSinkBelowWatermark,
        };
    }

    pub fn hasPending(self: *const FrameSink) bool {
        return self.entries.items.len != 0;
    }

    pub fn queuedBytes(self: *const FrameSink) usize {
        var total: usize = 0;
        for (self.entries.items) |*entry| total += entry.queuedBytes();
        return total;
    }

    pub fn queueFrame(
        self: *FrameSink,
        message_type: protocol.MessageType,
        payload: []const u8,
    ) !void {
        var entry = try FrameSinkEntry.initFrame(self.allocator, message_type, payload);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn queueFrameWithByteLimit(
        self: *FrameSink,
        message_type: protocol.MessageType,
        payload: []const u8,
        max_queued_bytes: usize,
    ) !void {
        var entry = try FrameSinkEntry.initFrame(self.allocator, message_type, payload);
        errdefer entry.deinit();
        try self.appendEntry(entry, max_queued_bytes);
    }

    pub fn queueFrameWithScmRightsFd(
        self: *FrameSink,
        message_type: protocol.MessageType,
        payload: []const u8,
        passed_fd: c.fd_t,
    ) !void {
        var entry = try FrameSinkEntry.initScmRightsFrame(self.allocator, message_type, payload, passed_fd);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn queueOwnedFrame(self: *FrameSink, frame: *protocol.OwnedFrame) !void {
        if (frame.fd) |fd| {
            frame.fd = null;
            try self.queueFrameWithScmRightsFd(frame.message_type, frame.payload, fd);
            return;
        }
        var entry = try FrameSinkEntry.initOwnedFrame(self.allocator, frame.*);
        errdefer entry.deinit();
        try self.appendEntry(entry, null);
    }

    pub fn writeReady(self: *FrameSink) !SinkWriteStatus {
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
        return .drained;
    }

    fn appendEntry(self: *FrameSink, entry: FrameSinkEntry, override_limit: ?usize) !void {
        const limit = override_limit orelse self.max_queued_bytes;
        const entry_len = entry.queuedBytes();
        if (entry_len > limit or self.queuedBytes() > limit - entry_len) {
            return error.FrameWriteQueueFull;
        }
        try self.entries.append(self.allocator, entry);
    }
};

pub const FrameSinkOptions = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    max_queued_bytes: usize = std.math.maxInt(usize),
    low_watermark: usize = 0,
};

fn frameSinkFd(ctx: *anyopaque) c.fd_t {
    const self: *FrameSink = @ptrCast(@alignCast(ctx));
    return self.fd;
}

fn frameSinkWriteReady(ctx: *anyopaque) !SinkWriteStatus {
    const self: *FrameSink = @ptrCast(@alignCast(ctx));
    return self.writeReady();
}

fn frameSinkHasQueuedBytes(ctx: *anyopaque) bool {
    const self: *FrameSink = @ptrCast(@alignCast(ctx));
    return self.hasPending();
}

fn frameSinkBelowWatermark(ctx: *anyopaque) bool {
    const self: *FrameSink = @ptrCast(@alignCast(ctx));
    return self.queuedBytes() <= self.low_watermark;
}

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

    fn queuedBytes(self: *const FrameSinkEntry) usize {
        return switch (self.*) {
            .frame => |*frame| frame.bytes.len - frame.written,
            .scm_rights_frame => |*frame| frame.queuedBytes(),
        };
    }

    fn writeReady(self: *FrameSinkEntry, fd: c.fd_t) !protocol.FrameWriteStatus {
        return switch (self.*) {
            .frame => |*frame| frame.writeReady(fd),
            .scm_rights_frame => |*frame| frame.writeReady(fd),
        };
    }
};

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

    fn queuedBytes(self: *const ScmRightsFrameWriteState) usize {
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

test "byte sink preserves queued byte order" {
    const posix = std.posix;
    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var sink = ByteSink.init(.{
        .allocator = std.testing.allocator,
        .fd = pipe[1],
        .max_queued_bytes = 64,
    });
    defer sink.deinit();

    try sink.queueBytes("ab");
    try sink.queueBytes("cd");
    try std.testing.expect(sink.sink().hasQueuedBytes());
    try std.testing.expectEqual(SinkWriteStatus.drained, try sink.sink().writeReady());

    var buf: [4]u8 = undefined;
    const n = c.read(pipe[0], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("abcd", buf[0..@intCast(n)]);
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

    try sink.queueFrame(.client_daemon, first);
    try sink.queueFrame(.client_daemon, second);
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

test "frame sink can send an SCM_RIGHTS frame" {
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
    try sink.queueFrameWithScmRightsFd(.client_daemon, payload, raw[0]);
    try std.testing.expectEqual(SinkWriteStatus.drained, try sink.writeReady());

    var source = FrameSource.init(std.testing.allocator, control[1]);
    defer source.deinit();
    try std.testing.expectEqual(SourceReadStatus.ready, try source.readReady());

    var frame = source.popFrame() orelse return error.ExpectedFrame;
    defer frame.deinit(std.testing.allocator);
    const received_fd = frame.takeFd() orelse return error.ExpectedFileDescriptor;
    defer _ = c.close(received_fd);

    try io.writeAll(received_fd, "raw");
    var buf: [3]u8 = undefined;
    const n = c.read(raw[1], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("raw", buf[0..@intCast(n)]);
}
