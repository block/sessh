// Non-blocking raw byte bridge between split local fds and one peer fd. This is
// used for uninterpreted bytes, so the bridge only tracks readiness, EOF, and
// bounded in-memory buffering.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");

const buffer_len = 8192;

pub const SplitEndpointFds = struct {
    read: c.fd_t,
    write: c.fd_t,
};

pub fn forwardRawDuplex(blocking: core_blocking.Blocking, left: SplitEndpointFds, right_fd: c.fd_t) !void {
    // Bridge two raw byte directions without interpreting sessh frames. This is
    // used after setup has handed one side to OpenSSH or another process that
    // expects an ordinary stream socket.
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

    // this process is only a byte bridge. It uses the
    // process Dispatcher initialized by main.
    const raw_dispatcher = dispatcher.get();
    var bridge = RawBridge{
        .left_to_right = &left_to_right,
        .right_to_left = &right_to_left,
    };
    defer bridge.deinit();
    try bridge.start(raw_dispatcher);
    try blocking.runLoop();
}

const RawBridge = struct {
    left_to_right: *RawDirection,
    right_to_left: *RawDirection,
    sources: [3]dispatcher.Source = .{
        dispatcher.Source.uninitialized(),
        dispatcher.Source.uninitialized(),
        dispatcher.Source.uninitialized(),
    },
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),

    fn start(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        // Three fds model the two directions: left input, left output, and the
        // bidirectional right fd. The right Source carries both readable and
        // writable interests, preserving the invariant that each fd has one
        // dispatcher Source.
        self.sources[0] = try raw_dispatcher.fdSource(self.left_to_right.read_fd, .{});
        self.sources[1] = try raw_dispatcher.fdSource(self.right_to_left.write_fd, .{});
        self.sources[2] = try raw_dispatcher.fdSource(self.right_to_left.read_fd, .{});
        self.task = dispatcher.dispatchTask(RawBridge, raw_dispatcher.allocator, self, runRawBridgeTask);
        self.task.setSourceReadiness(.any);
        for (self.sources) |source| try self.task.requireSource(source);
        try self.updateSources(raw_dispatcher);
        try self.task.schedule(raw_dispatcher);
    }

    fn deinit(self: *RawBridge) void {
        self.task.deinit();
        for (&self.sources) |*source| source.deinit();
    }

    fn updateSources(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        self.sources[0].setFdEvents(.{ .readable = self.left_to_right.wantsRead() });
        self.sources[1].setFdEvents(.{ .writable = self.right_to_left.wantsWrite() });
        self.sources[2].setFdEvents(.{
            .readable = self.right_to_left.wantsRead(),
            .writable = self.left_to_right.wantsWrite(),
        });
        if (self.left_to_right.done() and self.right_to_left.done()) raw_dispatcher.stop();
    }
};

fn runRawBridgeTask(
    bridge: *RawBridge,
    raw_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
) !@import("../core/dispatch_io.zig").DispatchTaskStatus {
    _ = task;
    if (bridge.sources[0].takeFdEvent()) |fd_event| {
        if (fd_event.readable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            bridge.left_to_right.readReady();
        }
    }
    if (bridge.sources[1].takeFdEvent()) |fd_event| {
        if (fd_event.writable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            bridge.right_to_left.writeReady();
        }
    }
    if (bridge.sources[2].takeFdEvent()) |fd_event| {
        if (fd_event.writable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            bridge.left_to_right.writeReady();
        }
        if (fd_event.readable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
            bridge.right_to_left.readReady();
        }
    }
    try bridge.updateSources(raw_dispatcher);
    return .pending;
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
    try dispatcher.initGlobal(std.testing.allocator);
    defer dispatcher.deinitGlobal();

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

    const blocking = core_blocking.fromTest();
    try forwardRawDuplex(blocking, .{
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
