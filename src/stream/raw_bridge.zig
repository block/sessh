// Non-blocking raw byte bridge between split local fds and one peer fd. This is
// used for uninterpreted bytes, so the bridge only tracks readiness, EOF, and
// bounded in-memory buffering.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");

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

    // this process is only a byte bridge. It uses the
    // process Dispatcher initialized by main.
    const raw_dispatcher = dispatcher.get();
    var bridge = try RawBridge.init(raw_dispatcher, .{
        .left_to_right = .{ .read_fd = left.read, .write_fd = right_fd },
        .right_to_left = .{ .read_fd = right_fd, .write_fd = left.write },
    });
    defer bridge.deinit();
    try bridge.start(raw_dispatcher);
    try blocking.runLoop();
}

const RawBridge = struct {
    left_to_right: RawDirection,
    right_to_left: RawDirection,
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),

    const DirectionFds = struct {
        read_fd: c.fd_t,
        write_fd: c.fd_t,
    };

    const Init = struct {
        left_to_right: DirectionFds,
        right_to_left: DirectionFds,
    };

    fn init(raw_dispatcher: *dispatcher.Dispatcher, options: Init) !RawBridge {
        var left_to_right = try RawDirection.init(raw_dispatcher, options.left_to_right);
        errdefer left_to_right.deinit();
        var right_to_left = try RawDirection.init(raw_dispatcher, options.right_to_left);
        errdefer right_to_left.deinit();
        return .{
            .left_to_right = left_to_right,
            .right_to_left = right_to_left,
        };
    }

    fn start(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        self.task = dispatcher.dispatchTask(RawBridge, raw_dispatcher.allocator, self, runRawBridgeTask);
        self.task.setSourceReadiness(.any);
        try self.updateSources(raw_dispatcher);
    }

    fn deinit(self: *RawBridge) void {
        self.task.deinit();
        self.left_to_right.deinit();
        self.right_to_left.deinit();
    }

    fn updateSources(self: *RawBridge, raw_dispatcher: *dispatcher.Dispatcher) !void {
        self.task.clearSources();
        self.task.clearSinks();
        try self.left_to_right.configureTask(&self.task);
        try self.right_to_left.configureTask(&self.task);
        if (self.left_to_right.done() and self.right_to_left.done()) {
            raw_dispatcher.stop();
            self.task.cancel();
            return;
        }
        if (self.task.sources.items.len == 0 and self.task.sinks.items.len == 0) {
            self.task.cancel();
        } else {
            try self.task.schedule(raw_dispatcher);
        }
    }
};

fn runRawBridgeTask(
    bridge: *RawBridge,
    raw_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
) !@import("../core/dispatch_io.zig").DispatchTaskStatus {
    _ = task;
    try bridge.left_to_right.readReady();
    bridge.left_to_right.noteSinkProgress();
    try bridge.right_to_left.readReady();
    bridge.right_to_left.noteSinkProgress();
    try bridge.updateSources(raw_dispatcher);
    return .pending;
}

const RawDirection = struct {
    write_fd: c.fd_t,
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    read_closed: bool = false,
    write_closed: bool = false,

    fn init(raw_dispatcher: *dispatcher.Dispatcher, fds: RawBridge.DirectionFds) !RawDirection {
        var source = try raw_dispatcher.byteSource(fds.read_fd, buffer_len);
        errdefer source.deinit();
        var sink = try raw_dispatcher.byteSink(.{
            .allocator = raw_dispatcher.allocator,
            .fd = fds.write_fd,
            .max_pending_bytes = buffer_len,
        });
        errdefer sink.deinit();
        return .{
            .write_fd = fds.write_fd,
            .source = source,
            .sink = sink,
        };
    }

    fn deinit(self: *RawDirection) void {
        self.source.deinit();
        self.sink.deinit();
    }

    fn done(self: *const RawDirection) bool {
        return self.read_closed and !self.sink.hasPendingWrite() and self.write_closed;
    }

    fn wantsRead(self: *const RawDirection) bool {
        return !self.read_closed and !self.sink.hasPendingWrite();
    }

    fn configureTask(self: *RawDirection, task: *dispatcher.DispatchTask) !void {
        if (self.wantsRead()) try task.requireSource(self.source);
        if (self.sink.hasPendingWrite()) try task.requireSink(self.sink);
    }

    fn readReady(self: *RawDirection) !void {
        if (!self.wantsRead()) return;
        const read = self.source.readBytes() orelse return;
        switch (read) {
            .bytes => |bytes| try self.sink.writeBytes(bytes),
            .eof => self.closeReadAndMaybeWrite(),
        }
    }

    fn noteSinkProgress(self: *RawDirection) void {
        if (!self.sink.hasPendingWrite()) self.closeWriteIfReadClosed();
    }

    fn closeReadAndMaybeWrite(self: *RawDirection) void {
        self.read_closed = true;
        self.closeWriteIfReadClosed();
    }

    fn closeWriteIfReadClosed(self: *RawDirection) void {
        if (!self.read_closed or self.sink.hasPendingWrite()) return;
        _ = c.shutdown(self.write_fd, c.SHUT.WR);
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
    try dispatcher.initGlobal(std.testing.allocator);
    defer dispatcher.deinitGlobal();

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

    var direction = try RawDirection.init(dispatcher.get(), .{ .read_fd = pipe[0], .write_fd = pipe[1] });
    defer direction.deinit();
    try direction.sink.writeBytes("pending");
    try std.testing.expectEqual(dispatch_io.SinkWriteStatus.blocked, try direction.sink.byte().writeReady());
    try std.testing.expect(direction.sink.hasPendingWrite());
}
