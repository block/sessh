const std = @import("std");
const c = std.c;
const posix = std.posix;

const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");

const buffer_len = 8192;

pub const SplitEndpointFds = struct {
    read: c.fd_t,
    write: c.fd_t,
};

pub fn forwardRawDuplex(left: SplitEndpointFds, right_fd: c.fd_t) !void {
    try core_fds.setNonBlocking(left.read);
    try core_fds.setNonBlocking(left.write);
    try core_fds.setNonBlocking(right_fd);

    var left_to_right = RawDirection{
        .read_fd = left.read,
        .write_fd = right_fd,
    };
    var right_to_left = RawDirection{
        .read_fd = right_fd,
        .write_fd = left.write,
    };

    // PROCESS_EVENT_LOOP: this process is only a byte bridge. There is no
    // daemon dispatcher hidden behind this loop.
    var raw_dispatcher = try dispatcher.Dispatcher.init(std.heap.page_allocator);
    defer raw_dispatcher.deinit();
    var bridge = RawBridge{
        .left_to_right = &left_to_right,
        .right_to_left = &right_to_left,
    };
    try bridge.watch(&raw_dispatcher);
    try raw_dispatcher.run();
}

const DirectionId = enum {
    left_to_right,
    right_to_left,
};

const PollKind = enum {
    read,
    write,
};

const RawBridge = struct {
    left_to_right: *RawDirection,
    right_to_left: *RawDirection,
    watches: [4]dispatcher.FdWatchId = undefined,
    watch_contexts: [4]RawWatchContext = undefined,

    fn watch(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        self.watch_contexts = .{
            .{ .bridge = self, .direction = .left_to_right, .kind = .read },
            .{ .bridge = self, .direction = .left_to_right, .kind = .write },
            .{ .bridge = self, .direction = .right_to_left, .kind = .read },
            .{ .bridge = self, .direction = .right_to_left, .kind = .write },
        };
        self.watches[0] = try raw_dispatcher.watchFd(.{
            .fd = self.left_to_right.read_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[0], .callback = handleRawBridgeEvent },
        });
        self.watches[1] = try raw_dispatcher.watchFd(.{
            .fd = self.left_to_right.write_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[1], .callback = handleRawBridgeEvent },
        });
        self.watches[2] = try raw_dispatcher.watchFd(.{
            .fd = self.right_to_left.read_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[2], .callback = handleRawBridgeEvent },
        });
        self.watches[3] = try raw_dispatcher.watchFd(.{
            .fd = self.right_to_left.write_fd,
            .events = .{},
            .handler = .{ .ctx = &self.watch_contexts[3], .callback = handleRawBridgeEvent },
        });
        try self.updateWatches(raw_dispatcher);
    }

    fn direction(self: *RawBridge, id: DirectionId) *RawDirection {
        return switch (id) {
            .left_to_right => self.left_to_right,
            .right_to_left => self.right_to_left,
        };
    }

    fn updateWatches(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        try raw_dispatcher.updateFdEvents(self.watches[0], .{ .readable = self.left_to_right.wantsRead() });
        try raw_dispatcher.updateFdEvents(self.watches[1], .{ .writable = self.left_to_right.wantsWrite() });
        try raw_dispatcher.updateFdEvents(self.watches[2], .{ .readable = self.right_to_left.wantsRead() });
        try raw_dispatcher.updateFdEvents(self.watches[3], .{ .writable = self.right_to_left.wantsWrite() });
        if (self.left_to_right.done() and self.right_to_left.done()) raw_dispatcher.stop();
    }
};

const RawWatchContext = struct {
    bridge: *RawBridge,
    direction: DirectionId,
    kind: PollKind,
};

fn handleRawBridgeEvent(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const raw_dispatcher = handler_event.dispatcher;
    const event = handler_event.event;
    const watch: *RawWatchContext = @ptrCast(@alignCast(ctx));
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedRawBridgeTimer,
    };
    const direction = watch.bridge.direction(watch.direction);
    switch (watch.kind) {
        .read => if (fd_event.readable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            direction.readReady();
        },
        .write => if (fd_event.writable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            direction.writeReady();
        },
    }
    try watch.bridge.updateWatches(raw_dispatcher);
}

const RawDirection = struct {
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    buf: [buffer_len]u8 = undefined,
    start: usize = 0,
    len: usize = 0,
    read_closed: bool = false,
    write_closed: bool = false,

    fn done(self: *const RawDirection) bool {
        return self.read_closed and self.len == 0 and self.write_closed;
    }

    fn wantsRead(self: *const RawDirection) bool {
        return !self.read_closed and self.len == 0;
    }

    fn wantsWrite(self: *const RawDirection) bool {
        return !self.write_closed and self.len > 0;
    }

    fn readReady(self: *RawDirection) void {
        if (self.read_closed or self.len != 0) return;
        const n = c.read(self.read_fd, &self.buf, self.buf.len);
        if (n < 0) return switch (posix.errno(n)) {
            .AGAIN, .INTR => {},
            else => self.closeReadAndMaybeWrite(),
        };
        if (n == 0) return self.closeReadAndMaybeWrite();
        self.start = 0;
        self.len = @intCast(n);
        io.noteRead(self.read_fd, self.buf[0..self.len]);
    }

    fn writeReady(self: *RawDirection) void {
        if (self.write_closed or self.len == 0) return;
        const bytes = self.buf[self.start .. self.start + self.len];
        const n = c.write(self.write_fd, bytes.ptr, bytes.len);
        if (n < 0) return switch (posix.errno(n)) {
            .AGAIN, .INTR => {},
            else => self.closeWrite(),
        };
        if (n == 0) return;
        const written: usize = @intCast(n);
        io.noteWrite(self.write_fd, bytes[0..written]);
        self.start += written;
        self.len -= written;
        if (self.len == 0) {
            self.start = 0;
            self.closeWriteIfReadClosed();
        }
    }

    fn closeReadAndMaybeWrite(self: *RawDirection) void {
        self.read_closed = true;
        self.closeWriteIfReadClosed();
    }

    fn closeWriteIfReadClosed(self: *RawDirection) void {
        if (!self.read_closed or self.len != 0) return;
        _ = c.shutdown(self.write_fd, c.SHUT.WR);
        self.write_closed = true;
    }

    fn closeWrite(self: *RawDirection) void {
        self.write_closed = true;
    }
};

test "raw duplex propagates right-side eof to the left peer" {
    const left_input = try posix.pipe();
    posix.close(left_input[1]);
    defer posix.close(left_input[0]);

    var left_output: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &left_output) != 0) return error.SocketPairFailed;
    defer _ = c.close(left_output[0]);
    defer _ = c.close(left_output[1]);

    var right: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &right) != 0) return error.SocketPairFailed;
    defer _ = c.close(right[0]);

    _ = c.close(right[1]);
    right[1] = -1;

    try forwardRawDuplex(.{
        .read = left_input[0],
        .write = left_output[0],
    }, right[0]);

    var pollfds = [_]posix.pollfd{.{
        .fd = left_output[1],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 0));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(left_output[1], &byte, byte.len));
}

test "raw direction keeps pending bytes when destination is backpressured" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try core_fds.setNonBlocking(pipe[1]);

    var fill: [4096]u8 = [_]u8{'x'} ** 4096;
    while (true) {
        const n = c.write(pipe[1], &fill, fill.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => break,
            else => return error.WriteFailed,
        } else {
            try std.testing.expect(n > 0);
        }
    }

    var direction = RawDirection{
        .read_fd = -1,
        .write_fd = pipe[1],
    };
    @memcpy(direction.buf[0.."pending".len], "pending");
    direction.len = "pending".len;
    direction.writeReady();
    try std.testing.expectEqualStrings("pending", direction.buf[direction.start .. direction.start + direction.len]);
}
