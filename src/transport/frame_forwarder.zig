const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const daemon_log = @import("../daemon/log.zig");
const protocol = @import("../protocol/mod.zig");

pub const ClientCloseAction = enum {
    none,
};

pub const ClientDiagnosticForwarding = struct {
    notify_read_fd: c.fd_t = -1,
    notify_remote_close: bool = false,
    log_context: LogContext = .{},
};

pub const LogContext = struct {
    host: []const u8 = "",
};

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

pub fn forwardFrames(stdin_fd: c.fd_t, stdout_fd: c.fd_t, peer_fd: c.fd_t) !void {
    return forwardFramesBetween(stdin_fd, stdout_fd, peer_fd, peer_fd);
}

pub fn forwardFramesBetween(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    peer_read_fd: c.fd_t,
    peer_write_fd: c.fd_t,
) !void {
    return forwardFramesBetweenWithClientCloseAction(
        client_read_fd,
        client_write_fd,
        peer_read_fd,
        peer_write_fd,
        .none,
    );
}

pub fn forwardFramesBetweenWithClientCloseAction(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    peer_read_fd: c.fd_t,
    peer_write_fd: c.fd_t,
    client_close_action: ClientCloseAction,
) !void {
    return forwardFramesBetweenWithClientCloseActionAndDiagnostics(
        client_read_fd,
        client_write_fd,
        peer_read_fd,
        peer_write_fd,
        client_close_action,
        .{},
    );
}

pub fn forwardFramesBetweenWithClientCloseActionAndDiagnostics(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    peer_read_fd: c.fd_t,
    peer_write_fd: c.fd_t,
    client_close_action: ClientCloseAction,
    diagnostics: ClientDiagnosticForwarding,
) !void {
    defer {
        _ = c.shutdown(client_read_fd, c.SHUT.WR);
        if (client_write_fd != client_read_fd) _ = c.shutdown(client_write_fd, c.SHUT.WR);
        _ = c.shutdown(peer_write_fd, c.SHUT.WR);
    }

    while (true) {
        var pollfds: [3]posix.pollfd = undefined;
        var count: usize = 0;
        const client_index = count;
        pollfds[count] = .{ .fd = client_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
        const peer_index = count;
        pollfds[count] = .{ .fd = peer_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
        var diagnostic_index: ?usize = null;
        if (diagnostics.notify_read_fd >= 0) {
            diagnostic_index = count;
            pollfds[count] = .{ .fd = diagnostics.notify_read_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        _ = try posix.poll(pollfds[0..count], -1);

        if (diagnostic_index) |index| {
            if ((pollfds[index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                try forwardRawTransportDiagnostics(client_write_fd, diagnostics.notify_read_fd);
            }
        }
        if ((pollfds[client_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(client_read_fd, peer_write_fd)) {
                try handleClientClose(peer_write_fd, client_close_action, diagnostics.log_context);
                return;
            }
        }
        if ((pollfds[peer_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(peer_read_fd, client_write_fd)) {
                logDaemonEvent(diagnostics.log_context, "ssh transport disconnected from daemon");
                if (diagnostics.notify_remote_close) try sendSshTransportClosed(client_write_fd);
                return;
            }
        }
    }
}

fn copyOneFrame(read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var frame = protocol.readFrameAlloc(std.heap.page_allocator, read_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(std.heap.page_allocator);
    try protocol.sendOwnedFrame(write_fd, frame);
    return true;
}

fn handleClientClose(peer_write_fd: c.fd_t, action: ClientCloseAction, log_context: LogContext) !void {
    _ = peer_write_fd;
    _ = log_context;
    switch (action) {
        .none => {},
    }
}

fn logDaemonEvent(log_context: LogContext, message: []const u8) void {
    if (log_context.host.len == 0) {
        daemon_log.infof(std.heap.page_allocator, "{s}", .{message});
    } else {
        daemon_log.infof(std.heap.page_allocator, "{s} host={s}", .{ message, log_context.host });
    }
}

fn logDaemonEventFmt(log_context: LogContext, comptime fmt: []const u8, args: anytype) void {
    if (log_context.host.len == 0) {
        daemon_log.infof(std.heap.page_allocator, fmt, args);
    } else {
        const message = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(message);
        daemon_log.infof(std.heap.page_allocator, "{s} host={s}", .{ message, log_context.host });
    }
}

pub fn forwardRawTransportDiagnostics(fd: c.fd_t, diagnostic_read_fd: c.fd_t) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var pollfds = [_]posix.pollfd{.{
            .fd = diagnostic_read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 0);
        if (ready == 0 or (pollfds[0].revents & posix.POLL.IN) == 0) return;

        const n = c.read(diagnostic_read_fd, &buf, buf.len);
        if (n <= 0) return;
        const chunk = buf[0..@intCast(n)];
        try protocol.sendSshTransportStderrFrame(std.heap.page_allocator, fd, chunk);
        if (chunk.len < buf.len) return;
    }
}

fn sendSshTransportClosed(fd: c.fd_t) !void {
    try protocol.sendSshTransportClosedFrame(std.heap.page_allocator, fd);
}

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
