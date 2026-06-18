const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");

const buffer_len = 8192;

pub fn forwardRawDuplex(left_read_fd: c.fd_t, left_write_fd: c.fd_t, right_fd: c.fd_t) !void {
    try core_fds.setNonBlocking(left_read_fd);
    try core_fds.setNonBlocking(left_write_fd);
    try core_fds.setNonBlocking(right_fd);

    var left_to_right = RawDirection{
        .read_fd = left_read_fd,
        .write_fd = right_fd,
    };
    var right_to_left = RawDirection{
        .read_fd = right_fd,
        .write_fd = left_write_fd,
    };

    // PROCESS_EVENT_LOOP: foreground raw proxy bridge. This process exists only
    // to relay bytes between two fds, so a direct poll loop is the event loop.
    while (!left_to_right.done() or !right_to_left.done()) {
        var pollfds: [4]posix.pollfd = undefined;
        var refs: [4]PollRef = undefined;
        var count: usize = 0;
        left_to_right.appendPoll(&pollfds, &refs, &count, .left_to_right);
        right_to_left.appendPoll(&pollfds, &refs, &count, .right_to_left);
        if (count == 0) return;
        _ = try posix.poll(pollfds[0..count], -1);

        for (pollfds[0..count], refs[0..count]) |pollfd, poll_ref| {
            const direction = switch (poll_ref.direction) {
                .left_to_right => &left_to_right,
                .right_to_left => &right_to_left,
            };
            switch (poll_ref.kind) {
                .read => if ((pollfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                    direction.readReady();
                },
                .write => if ((pollfd.revents & (posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                    direction.writeReady();
                },
            }
        }
    }
}

const DirectionId = enum {
    left_to_right,
    right_to_left,
};

const PollKind = enum {
    read,
    write,
};

const PollRef = struct {
    direction: DirectionId,
    kind: PollKind,
};

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

    fn appendPoll(
        self: *const RawDirection,
        pollfds: *[4]posix.pollfd,
        refs: *[4]PollRef,
        count: *usize,
        direction: DirectionId,
    ) void {
        if (!self.read_closed and self.len == 0) {
            pollfds[count.*] = .{ .fd = self.read_fd, .events = posix.POLL.IN, .revents = 0 };
            refs[count.*] = .{ .direction = direction, .kind = .read };
            count.* += 1;
        }
        if (!self.write_closed and self.len > 0) {
            pollfds[count.*] = .{ .fd = self.write_fd, .events = posix.POLL.OUT, .revents = 0 };
            refs[count.*] = .{ .direction = direction, .kind = .write };
            count.* += 1;
        }
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

    try forwardRawDuplex(left_input[0], left_output[0], right[0]);

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
