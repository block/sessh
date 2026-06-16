const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");

pub const ReadStatus = enum {
    blocked,
    partial,
    filled,
    eof_empty,
    eof_partial,
};

pub const ReadBuffer = struct {
    bytes: []u8,
    filled: usize = 0,

    pub fn init(bytes: []u8) ReadBuffer {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const ReadBuffer) []u8 {
        return self.bytes[self.filled..];
    }

    pub fn reset(self: *ReadBuffer) void {
        self.filled = 0;
    }

    pub fn advance(self: *ReadBuffer, n: usize) void {
        self.filled += n;
        std.debug.assert(self.filled <= self.bytes.len);
    }

    /// Performs at most one nonblocking read into the remaining buffer space.
    /// The fd lives with the connection object; this helper only tracks byte
    /// progress through the caller-owned storage.
    pub fn readReady(self: *ReadBuffer, fd: c.fd_t) !ReadStatus {
        if (self.filled == self.bytes.len) return .filled;
        const n = posix.read(fd, self.remaining()) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        if (n == 0) return if (self.filled == 0) .eof_empty else .eof_partial;
        self.advance(n);
        return if (self.filled == self.bytes.len) .filled else .partial;
    }
};

pub const WriteStatus = enum {
    blocked,
    partial,
    drained,
};

pub const WriteBuffer = struct {
    bytes: []const u8,
    written: usize = 0,

    pub fn init(bytes: []const u8) WriteBuffer {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const WriteBuffer) []const u8 {
        return self.bytes[self.written..];
    }

    pub fn reset(self: *WriteBuffer) void {
        self.written = 0;
    }

    pub fn advance(self: *WriteBuffer, n: usize) void {
        self.written += n;
        std.debug.assert(self.written <= self.bytes.len);
    }

    /// Performs at most one nonblocking write from the remaining bytes.
    /// Larger write queues should own these buffers separately; this type only
    /// tracks progress through one caller-owned byte slice.
    pub fn writeReady(self: *WriteBuffer, fd: c.fd_t) !WriteStatus {
        if (self.written == self.bytes.len) return .drained;
        const n = posix.write(fd, self.remaining()) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        if (n == 0) return .blocked;
        self.advance(n);
        return if (self.written == self.bytes.len) .drained else .partial;
    }
};

pub const FrameForwarderReadStatus = enum {
    blocked,
    progress,
    eof,
    truncated_frame,
};

pub const FrameForwarderWriteStatus = enum {
    blocked,
    progress,
    drained,
};

pub const FrameForwarder = struct {
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    header: [protocol.frame_header_len]u8 = undefined,
    header_filled: usize = 0,
    header_forwarded: bool = false,
    frame_remaining: usize = 0,
    buffer: CircularBuffer,
    read_closed: bool = false,

    pub fn init(read_fd: c.fd_t, write_fd: c.fd_t, storage: []u8) FrameForwarder {
        return .{
            .read_fd = read_fd,
            .write_fd = write_fd,
            .buffer = CircularBuffer.init(storage),
        };
    }

    pub fn wantsRead(self: *const FrameForwarder) bool {
        if (self.read_closed) return false;
        if (self.header_filled < protocol.frame_header_len) return true;
        if (!self.header_forwarded) return self.buffer.freeLen() >= protocol.frame_header_len;
        return self.frame_remaining > 0 and self.buffer.freeLen() > 0;
    }

    pub fn hasPendingWrite(self: *const FrameForwarder) bool {
        return self.buffer.readableLen() > 0;
    }

    /// Reads at most one chunk from `read_fd`.
    ///
    /// This low-level forwarder is only for structured-only frames: the fixed
    /// header names the protobuf message length, while any attached byte
    /// appendix is described inside that protobuf message. Paths that can carry
    /// attached bytes must use a decoded frame reader or teach this forwarder to
    /// scan `Frame.attached_bytes_len`.
    pub fn readReady(self: *FrameForwarder) !FrameForwarderReadStatus {
        if (self.read_closed) return .eof;

        if (self.header_filled < protocol.frame_header_len) {
            var header_buffer = ReadBuffer{
                .bytes = self.header[0..],
                .filled = self.header_filled,
            };
            const status = try header_buffer.readReady(self.read_fd);
            self.header_filled = header_buffer.filled;
            switch (status) {
                .blocked => return .blocked,
                .partial => return .progress,
                .filled => {
                    self.frame_remaining = protocol.messageLenFromHeader(&self.header);
                    return .progress;
                },
                .eof_empty => {
                    self.read_closed = true;
                    return .eof;
                },
                .eof_partial => {
                    self.read_closed = true;
                    return .truncated_frame;
                },
            }
        }

        if (!self.header_forwarded) {
            if (!self.buffer.writeSlice(self.header[0..])) return .blocked;
            self.header_forwarded = true;
            if (self.frame_remaining == 0) self.resetFrameHeader();
            return .progress;
        }

        if (self.frame_remaining == 0) {
            self.resetFrameHeader();
            return .progress;
        }
        if (self.buffer.freeLen() == 0) return .blocked;

        const writable = self.buffer.writableSlice();
        const chunk = writable[0..@min(writable.len, self.frame_remaining)];
        const n = posix.read(self.read_fd, chunk) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        if (n == 0) {
            self.read_closed = true;
            return .truncated_frame;
        }
        self.buffer.commitWrite(n);
        self.frame_remaining -= n;
        if (self.frame_remaining == 0) self.resetFrameHeader();
        return .progress;
    }

    /// Writes at most one contiguous buffered chunk to `write_fd`.
    pub fn writeReady(self: *FrameForwarder) !FrameForwarderWriteStatus {
        if (self.buffer.readableLen() == 0) return .drained;
        const readable = self.buffer.readableSlice();
        const n = posix.write(self.write_fd, readable) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        if (n == 0) return .blocked;
        self.buffer.discard(n);
        return if (self.buffer.readableLen() == 0) .drained else .progress;
    }

    fn resetFrameHeader(self: *FrameForwarder) void {
        self.header_filled = 0;
        self.header_forwarded = false;
        self.frame_remaining = 0;
    }
};

pub const DispatcherFrameRelay = struct {
    allocator: std.mem.Allocator,
    left_fd: c.fd_t,
    right_fd: c.fd_t,
    left_watch_id: ?dispatcher.FdWatchId = null,
    right_watch_id: ?dispatcher.FdWatchId = null,
    left_to_right: FramePipe,
    right_to_left: FramePipe,
    closing: bool = false,

    pub fn init(allocator: std.mem.Allocator, left_fd: c.fd_t, right_fd: c.fd_t) DispatcherFrameRelay {
        return .{
            .allocator = allocator,
            .left_fd = left_fd,
            .right_fd = right_fd,
            .left_to_right = FramePipe.init(allocator),
            .right_to_left = FramePipe.init(allocator),
        };
    }

    pub fn deinit(self: *DispatcherFrameRelay, d: *dispatcher.Dispatcher) void {
        if (self.left_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        if (self.right_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        if (self.left_fd >= 0) {
            _ = c.close(self.left_fd);
            self.left_fd = -1;
        }
        if (self.right_fd >= 0) {
            _ = c.close(self.right_fd);
            self.right_fd = -1;
        }
        self.left_to_right.deinit();
        self.right_to_left.deinit();
        self.allocator.destroy(self);
    }

    fn updateWatches(self: *DispatcherFrameRelay, d: *dispatcher.Dispatcher) !void {
        if (self.left_watch_id) |watch_id| {
            try d.updateFdEvents(watch_id, .{
                .readable = self.left_to_right.wantsRead(),
                .writable = self.right_to_left.wantsWrite(),
            });
        }
        if (self.right_watch_id) |watch_id| {
            try d.updateFdEvents(watch_id, .{
                .readable = self.right_to_left.wantsRead(),
                .writable = self.left_to_right.wantsWrite(),
            });
        }
    }

    fn handleEvent(self: *DispatcherFrameRelay, d: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
        const fd_event = switch (event) {
            .fd => |fd| fd,
            .timer => return error.UnexpectedFrameRelayTimer,
        };
        if (fd_event.error_event or fd_event.invalid) {
            self.close(d);
            return;
        }

        if (self.isLeftWatch(id)) {
            if (fd_event.writable) try self.drainPipeToFd(&self.right_to_left, self.left_fd);
            if (fd_event.readable or fd_event.hangup) try self.readPipeFromFd(&self.left_to_right, self.left_fd);
        } else if (self.isRightWatch(id)) {
            if (fd_event.writable) try self.drainPipeToFd(&self.left_to_right, self.right_fd);
            if (fd_event.readable or fd_event.hangup) try self.readPipeFromFd(&self.right_to_left, self.right_fd);
        }

        if (self.closing) {
            self.deinit(d);
            return;
        }
        try self.updateWatches(d);
    }

    fn readPipeFromFd(self: *DispatcherFrameRelay, pipe: *FramePipe, fd: c.fd_t) !void {
        while (pipe.wantsRead()) {
            switch (try pipe.readReady(fd)) {
                .blocked => return,
                .progress => continue,
                .eof, .truncated_frame => {
                    self.closing = true;
                    return;
                },
            }
        }
    }

    fn drainPipeToFd(self: *DispatcherFrameRelay, pipe: *FramePipe, fd: c.fd_t) !void {
        _ = self;
        while (pipe.wantsWrite()) {
            switch (try pipe.writeReady(fd)) {
                .blocked => return,
                .progress => continue,
                .drained => continue,
            }
        }
    }

    fn close(self: *DispatcherFrameRelay, d: *dispatcher.Dispatcher) void {
        self.closing = true;
        self.deinit(d);
    }

    fn isLeftWatch(self: *const DispatcherFrameRelay, id: dispatcher.WatchId) bool {
        const left_id = self.left_watch_id orelse return false;
        const fd_id = switch (id) {
            .fd => |watch_id| watch_id,
            .timer => return false,
        };
        return watchIdsEqual(left_id, fd_id);
    }

    fn isRightWatch(self: *const DispatcherFrameRelay, id: dispatcher.WatchId) bool {
        const right_id = self.right_watch_id orelse return false;
        const fd_id = switch (id) {
            .fd => |watch_id| watch_id,
            .timer => return false,
        };
        return watchIdsEqual(right_id, fd_id);
    }

    fn onFd(ctx: *anyopaque, d: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
        const self: *DispatcherFrameRelay = @ptrCast(@alignCast(ctx));
        self.handleEvent(d, id, event) catch {
            self.close(d);
        };
    }
};

const FramePipeReadStatus = enum {
    blocked,
    progress,
    eof,
    truncated_frame,
};

const FramePipeWriteStatus = enum {
    blocked,
    progress,
    drained,
};

const FramePipe = struct {
    allocator: std.mem.Allocator,
    reader: protocol.FrameReader,
    writer: ?protocol.FrameWriteState = null,

    fn init(allocator: std.mem.Allocator) FramePipe {
        return .{
            .allocator = allocator,
            .reader = protocol.FrameReader.init(allocator),
        };
    }

    fn deinit(self: *FramePipe) void {
        self.reader.deinit();
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
    }

    fn wantsRead(self: *const FramePipe) bool {
        return self.writer == null;
    }

    fn wantsWrite(self: *const FramePipe) bool {
        return self.writer != null;
    }

    fn readReady(self: *FramePipe, fd: c.fd_t) !FramePipeReadStatus {
        if (self.writer != null) return .blocked;
        switch (try self.reader.readReady(fd)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .eof => return .eof,
            .truncated_frame => return .truncated_frame,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(self.allocator);
                self.writer = try protocol.FrameWriteState.initOwnedFrame(self.allocator, frame);
                return .progress;
            },
        }
    }

    fn writeReady(self: *FramePipe, fd: c.fd_t) !FramePipeWriteStatus {
        var writer = if (self.writer) |*value| value else return .drained;
        switch (try writer.writeReady(fd)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .done => {
                writer.deinit();
                self.writer = null;
                return .drained;
            },
        }
    }
};

pub fn registerFrameRelay(
    allocator: std.mem.Allocator,
    d: *dispatcher.Dispatcher,
    left_fd: c.fd_t,
    right_fd: c.fd_t,
) !void {
    try core_fds.setNonBlocking(left_fd);
    try core_fds.setNonBlocking(right_fd);

    const relay = try allocator.create(DispatcherFrameRelay);
    errdefer allocator.destroy(relay);
    relay.* = DispatcherFrameRelay.init(allocator, left_fd, right_fd);
    errdefer {
        relay.left_to_right.deinit();
        relay.right_to_left.deinit();
    }

    const handler: dispatcher.Handler = .{
        .ctx = relay,
        .callback = DispatcherFrameRelay.onFd,
    };
    relay.left_watch_id = try d.watchFd(left_fd, .{}, handler);
    errdefer if (relay.left_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
    relay.right_watch_id = try d.watchFd(right_fd, .{}, handler);
    errdefer if (relay.right_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
    try relay.updateWatches(d);
}

fn watchIdsEqual(a: dispatcher.FdWatchId, b: dispatcher.FdWatchId) bool {
    return a.index == b.index and a.generation == b.generation;
}

const CircularBuffer = struct {
    storage: []u8,
    read_pos: usize = 0,
    len: usize = 0,

    fn init(storage: []u8) CircularBuffer {
        std.debug.assert(storage.len > 0);
        return .{ .storage = storage };
    }

    fn readableLen(self: *const CircularBuffer) usize {
        return self.len;
    }

    fn freeLen(self: *const CircularBuffer) usize {
        return self.storage.len - self.len;
    }

    fn readableSlice(self: *const CircularBuffer) []const u8 {
        if (self.len == 0) return self.storage[0..0];
        const contiguous = @min(self.len, self.storage.len - self.read_pos);
        return self.storage[self.read_pos..][0..contiguous];
    }

    fn writableSlice(self: *CircularBuffer) []u8 {
        if (self.freeLen() == 0) return self.storage[0..0];
        const write_pos = (self.read_pos + self.len) % self.storage.len;
        if (self.len == 0) return self.storage[write_pos..];
        const contiguous = if (write_pos >= self.read_pos and self.len != 0)
            self.storage.len - write_pos
        else
            self.read_pos - write_pos;
        return self.storage[write_pos..][0..@min(contiguous, self.freeLen())];
    }

    fn commitWrite(self: *CircularBuffer, n: usize) void {
        std.debug.assert(n <= self.freeLen());
        self.len += n;
    }

    fn discard(self: *CircularBuffer, n: usize) void {
        std.debug.assert(n <= self.len);
        if (self.storage.len != 0) self.read_pos = (self.read_pos + n) % self.storage.len;
        self.len -= n;
        if (self.len == 0) self.read_pos = 0;
    }

    fn writeSlice(self: *CircularBuffer, bytes: []const u8) bool {
        if (bytes.len > self.freeLen()) return false;
        var remaining = bytes;
        while (remaining.len > 0) {
            const writable = self.writableSlice();
            const n = @min(writable.len, remaining.len);
            @memcpy(writable[0..n], remaining[0..n]);
            self.commitWrite(n);
            remaining = remaining[n..];
        }
        return true;
    }
};

fn setNonBlockingFdForTest(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

fn closePipeForTest(pipe: [2]c.fd_t) void {
    _ = c.close(pipe[0]);
    _ = c.close(pipe[1]);
}

fn socketPairForTest() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

fn readAvailableForTest(fd: c.fd_t, out: *std.ArrayList(u8)) !void {
    var buf: [128]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return;
        try out.appendSlice(std.testing.allocator, buf[0..n]);
    }
}

fn rawFrameForTest(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const frame = try allocator.alloc(u8, protocol.frame_header_len + payload.len);
    const len: u32 = @intCast(payload.len);
    frame[0] = @intCast((len >> 24) & 0xff);
    frame[1] = @intCast((len >> 16) & 0xff);
    frame[2] = @intCast((len >> 8) & 0xff);
    frame[3] = @intCast(len & 0xff);
    @memcpy(frame[protocol.frame_header_len..], payload);
    return frame;
}

test "ReadBuffer fills incrementally and reports eof shape" {
    const pipe = try posix.pipe();
    defer closePipeForTest(pipe);
    try setNonBlockingFdForTest(pipe[0]);

    var storage: [5]u8 = undefined;
    var buffer = ReadBuffer.init(&storage);
    try io.writeAll(pipe[1], "ab");

    try std.testing.expectEqual(ReadStatus.partial, try buffer.readReady(pipe[0]));
    try std.testing.expectEqualStrings("ab", storage[0..buffer.filled]);
    try std.testing.expectEqual(ReadStatus.blocked, try buffer.readReady(pipe[0]));

    try io.writeAll(pipe[1], "cde");
    try std.testing.expectEqual(ReadStatus.filled, try buffer.readReady(pipe[0]));
    try std.testing.expectEqualStrings("abcde", storage[0..buffer.filled]);
    buffer.reset();
    try std.testing.expectEqual(@as(usize, 0), buffer.filled);
}

test "ReadBuffer distinguishes clean eof from partial frame eof" {
    const clean_pipe = try posix.pipe();
    try setNonBlockingFdForTest(clean_pipe[0]);
    _ = c.close(clean_pipe[1]);
    var clean_storage: [4]u8 = undefined;
    var clean = ReadBuffer.init(&clean_storage);
    try std.testing.expectEqual(ReadStatus.eof_empty, try clean.readReady(clean_pipe[0]));
    _ = c.close(clean_pipe[0]);

    const partial_pipe = try posix.pipe();
    defer _ = c.close(partial_pipe[0]);
    try setNonBlockingFdForTest(partial_pipe[0]);
    try io.writeAll(partial_pipe[1], "xy");
    _ = c.close(partial_pipe[1]);
    var partial_storage: [4]u8 = undefined;
    var partial = ReadBuffer.init(&partial_storage);
    try std.testing.expectEqual(ReadStatus.partial, try partial.readReady(partial_pipe[0]));
    try std.testing.expectEqual(ReadStatus.eof_partial, try partial.readReady(partial_pipe[0]));
}

test "WriteBuffer tracks progress through caller-owned bytes" {
    var buffer = WriteBuffer.init("abcdef");
    try std.testing.expectEqualStrings("abcdef", buffer.remaining());
    buffer.advance(2);
    try std.testing.expectEqualStrings("cdef", buffer.remaining());
    try std.testing.expect(buffer.written != buffer.bytes.len);
    buffer.reset();
    try std.testing.expectEqualStrings("abcdef", buffer.remaining());
}

test "WriteBuffer writes to a nonblocking fd" {
    const pipe = try posix.pipe();
    defer closePipeForTest(pipe);
    try setNonBlockingFdForTest(pipe[1]);

    var buffer = WriteBuffer.init("hello");
    try std.testing.expectEqual(WriteStatus.drained, try buffer.writeReady(pipe[1]));
    var out: [5]u8 = undefined;
    try io.readExact(pipe[0], &out);
    try std.testing.expectEqualStrings("hello", &out);
}

test "CircularBuffer writes into empty and wrapped storage" {
    var storage: [5]u8 = undefined;
    var buffer = CircularBuffer.init(&storage);
    try std.testing.expect(buffer.writeSlice("abc"));
    try std.testing.expectEqualStrings("abc", buffer.readableSlice());
    buffer.discard(2);
    try std.testing.expectEqualStrings("c", buffer.readableSlice());
    try std.testing.expect(buffer.writeSlice("defg"));
    try std.testing.expectEqualStrings("cde", buffer.readableSlice());
    buffer.discard(3);
    try std.testing.expectEqualStrings("fg", buffer.readableSlice());
}

test "FrameForwarder streams multiple raw frames without decoding" {
    const source = try posix.pipe();
    defer closePipeForTest(source);
    const dest = try posix.pipe();
    defer closePipeForTest(dest);
    try setNonBlockingFdForTest(source[0]);
    try setNonBlockingFdForTest(dest[0]);
    try setNonBlockingFdForTest(dest[1]);

    const first = try rawFrameForTest(std.testing.allocator, "abcdef");
    defer std.testing.allocator.free(first);
    const second = try rawFrameForTest(std.testing.allocator, "");
    defer std.testing.allocator.free(second);
    const third = try rawFrameForTest(std.testing.allocator, "xyz");
    defer std.testing.allocator.free(third);
    try io.writeAll(source[1], first);
    try io.writeAll(source[1], second);
    try io.writeAll(source[1], third);
    _ = c.close(source[1]);

    var storage: [5]u8 = undefined;
    var forwarder = FrameForwarder.init(source[0], dest[1], &storage);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    var saw_eof = false;
    var iterations: usize = 0;
    while (iterations < 200 and (!saw_eof or forwarder.hasPendingWrite())) : (iterations += 1) {
        if (forwarder.wantsRead()) {
            switch (try forwarder.readReady()) {
                .eof => saw_eof = true,
                .truncated_frame => return error.UnexpectedTruncatedFrame,
                .blocked, .progress => {},
            }
        }
        if (forwarder.hasPendingWrite()) _ = try forwarder.writeReady();
        try readAvailableForTest(dest[0], &output);
    }
    try std.testing.expect(saw_eof);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.appendSlice(std.testing.allocator, first);
    try expected.appendSlice(std.testing.allocator, second);
    try expected.appendSlice(std.testing.allocator, third);
    try std.testing.expectEqualStrings(expected.items, output.items);
}

test "FrameForwarder applies output backpressure before reading frame body" {
    const source = try posix.pipe();
    defer closePipeForTest(source);
    const dest = try posix.pipe();
    defer closePipeForTest(dest);
    try setNonBlockingFdForTest(source[0]);
    try setNonBlockingFdForTest(dest[0]);
    try setNonBlockingFdForTest(dest[1]);

    const frame = try rawFrameForTest(std.testing.allocator, "body");
    defer std.testing.allocator.free(frame);
    try io.writeAll(source[1], frame);

    var storage: [protocol.frame_header_len]u8 = undefined;
    var forwarder = FrameForwarder.init(source[0], dest[1], &storage);

    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
    try std.testing.expect(forwarder.wantsRead());
    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
    try std.testing.expect(!forwarder.wantsRead());
    try std.testing.expectEqual(FrameForwarderReadStatus.blocked, try forwarder.readReady());

    try std.testing.expectEqual(FrameForwarderWriteStatus.drained, try forwarder.writeReady());
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try readAvailableForTest(dest[0], &output);
    try std.testing.expectEqualStrings(frame[0..protocol.frame_header_len], output.items);

    try std.testing.expect(forwarder.wantsRead());
    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
}

test "dispatcher frame relay forwards attached-byte frames in both directions" {
    const left = try socketPairForTest();
    const right = try socketPairForTest();
    var left_external_open = true;
    var right_external_open = true;
    defer {
        if (left_external_open) _ = c.close(left[0]);
    }
    defer {
        if (right_external_open) _ = c.close(right[0]);
    }

    try core_fds.setNonBlocking(left[0]);
    try core_fds.setNonBlocking(right[0]);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try registerFrameRelay(std.testing.allocator, &d, left[1], right[1]);

    const payload = try protocol.encodePayload(std.testing.allocator, protocol.pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);

    try protocol.sendFrameWithAttachedBytes(left[0], .client_daemon, payload, "left-to-right");
    var first = try readRelayedFrameForTest(&d, right[0]);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, first.message_type);
    try std.testing.expectEqualStrings(payload, first.payload);
    try std.testing.expectEqualStrings("left-to-right", first.attached_bytes);

    try protocol.sendFrameWithAttachedBytes(right[0], .client_daemon, payload, "right-to-left");
    var second = try readRelayedFrameForTest(&d, left[0]);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, second.message_type);
    try std.testing.expectEqualStrings(payload, second.payload);
    try std.testing.expectEqualStrings("right-to-left", second.attached_bytes);

    _ = c.close(left[0]);
    left_external_open = false;
    _ = c.close(right[0]);
    right_external_open = false;
    var iterations: usize = 0;
    while (d.active_count != 0 and iterations < 10) : (iterations += 1) {
        _ = try d.runOnce();
    }
    try std.testing.expectEqual(@as(usize, 0), d.active_count);
}

test "FrameForwarder reports truncated frame bodies" {
    const source = try posix.pipe();
    defer _ = c.close(source[0]);
    const dest = try posix.pipe();
    defer closePipeForTest(dest);
    try setNonBlockingFdForTest(source[0]);
    try setNonBlockingFdForTest(dest[1]);

    const frame = try rawFrameForTest(std.testing.allocator, "abcde");
    defer std.testing.allocator.free(frame);
    try io.writeAll(source[1], frame[0 .. protocol.frame_header_len + 2]);
    _ = c.close(source[1]);

    var storage: [32]u8 = undefined;
    var forwarder = FrameForwarder.init(source[0], dest[1], &storage);
    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
    try std.testing.expectEqual(FrameForwarderReadStatus.progress, try forwarder.readReady());
    try std.testing.expectEqual(FrameForwarderReadStatus.truncated_frame, try forwarder.readReady());
}

fn readRelayedFrameForTest(d: *dispatcher.Dispatcher, fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(std.testing.allocator);
    defer reader.deinit();
    var iterations: usize = 0;
    while (iterations < 100) : (iterations += 1) {
        while (true) {
            switch (try reader.readReady(fd)) {
                .blocked => break,
                .progress => continue,
                .frame => |frame| return frame,
                .eof => return error.UnexpectedEof,
                .truncated_frame => return error.UnexpectedTruncatedFrame,
            }
        }
        _ = try d.runOnce();
    }
    return error.TimedOut;
}
