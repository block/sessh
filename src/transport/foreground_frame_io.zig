// Synchronous framed IO for short foreground setup phases. Long-lived daemon
// paths use dispatcher-owned readers/writers; this module is for bounded setup
// handshakes that still need cancellation and SCM_RIGHTS handling.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const core_io = @import("../core/io.zig");
const fd_passing = @import("../core/fd_passing.zig");
const protocol = @import("../protocol/mod.zig");

const cancellation_poll_ms: i32 = 50;

pub const ReadOptions = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    cancelled: ?*const bool = null,
    cancel_error: anyerror = error.OperationCancelled,
};

pub fn readFrame(options: ReadOptions) !protocol.OwnedFrame {
    // Foreground setup/reconnect reads happen before a dispatcher-owned source
    // owns the fd. Keep the phases explicit here instead of routing through the
    // async FrameSource state machine.
    var header: [protocol.frame_header_len]u8 = undefined;
    try readExactForeground(options, &header, error.EndOfStream, error.TruncatedFrame);

    const message_len = protocol.messageLenFromHeader(&header);
    if (message_len == 0) return error.UnknownFrame;
    const message = try options.allocator.alloc(u8, message_len);
    defer options.allocator.free(message);
    try readExactForeground(options, message, error.TruncatedFrame, error.TruncatedFrame);

    var decoded = try protocol.decodeMessageEnvelopeAlloc(options.allocator, message);
    errdefer decoded.frame.deinit(options.allocator);

    if (decoded.attached_bytes_len == 0) return decoded.frame;

    switch (decoded.attached_kind) {
        .RAW => {
            decoded.frame.attached_bytes = try options.allocator.alloc(u8, decoded.attached_bytes_len);
            try readExactForeground(options, decoded.frame.attached_bytes, error.TruncatedFrame, error.TruncatedFrame);
            return decoded.frame;
        },
        .SCM_RIGHTS => {
            if (decoded.attached_bytes_len != 1) return error.InvalidFileDescriptorCarrierFrame;
            decoded.frame.fd = try readScmRightsMarkerForeground(options);
            return decoded.frame;
        },
        _ => return error.InvalidFrame,
    }
}

fn isCancelled(cancelled: ?*const bool) bool {
    const flag = cancelled orelse return false;
    return flag.*;
}

pub const WriteOptions = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message_type: protocol.MessageType,
    payload: []const u8,
};

pub fn writeFrame(options: WriteOptions) !void {
    const frame = try protocol.encodeFrame(options.allocator, options.message_type, options.payload);
    defer options.allocator.free(frame);
    try options.blocking.writeAll(options.fd, frame);
}

pub const ScmRightsWriteOptions = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message_type: protocol.MessageType,
    payload: []const u8,
    passed_fd: c.fd_t,
};

pub fn writeFrameWithScmRightsFd(options: ScmRightsWriteOptions) !void {
    // Send a frame whose attached marker byte carries one SCM_RIGHTS fd. The
    // normal frame prefix is written first; only the explicit attached byte is
    // associated with the descriptor, which keeps fd passing out of unrelated
    // framed traffic.
    var owned_fd = core_fds.OwnedFd.init(options.passed_fd);
    defer owned_fd.deinit();

    const marker = [_]u8{0};
    const frame = try protocol.encodeFrameWithAttachedKindAndBytes(options.allocator, .{
        .message_type = options.message_type,
        .payload = options.payload,
        .attached_kind = .SCM_RIGHTS,
        .attached_bytes = &marker,
    });
    defer options.allocator.free(frame);

    var header: [protocol.frame_header_len]u8 = undefined;
    @memcpy(&header, frame[0..protocol.frame_header_len]);
    const message_len = protocol.messageLenFromHeader(&header);
    const attached_start = protocol.frame_header_len + message_len;
    if (frame.len != attached_start + marker.len) return error.InvalidFileDescriptorCarrierFrame;

    // ProxyUseFdPass setup is a short-lived foreground process, but fd passing
    // still has two phases. Send the ordinary frame bytes first, then the
    // single marker byte together with SCM_RIGHTS so the receiver can
    // correlate the descriptor with this explicit frame.
    var prefix = fd_passing.SendByteProgress.init(frame[0..attached_start]);
    try writeByteProgress(options.blocking, options.fd, &prefix);

    var fd_progress = fd_passing.SendBufferWithFdProgress.init(frame[attached_start..], owned_fd.take());
    defer fd_progress.deinit();
    try writeBufferWithFdProgress(options.blocking, options.fd, &fd_progress);
}

fn writeByteProgress(blocking: core_blocking.Blocking, fd: c.fd_t, progress: *fd_passing.SendByteProgress) !void {
    while (true) {
        switch (try fd_passing.sendByteProgress(fd, progress)) {
            .complete => return,
            .progress => continue,
            .blocked => try waitForegroundWritable(blocking, fd),
            .eof => unreachable,
        }
    }
}

fn writeBufferWithFdProgress(blocking: core_blocking.Blocking, fd: c.fd_t, progress: *fd_passing.SendBufferWithFdProgress) !void {
    while (true) {
        switch (try fd_passing.sendBufferWithFdProgress(fd, progress)) {
            .complete => return,
            .progress => continue,
            .blocked => try waitForegroundWritable(blocking, fd),
            .eof => unreachable,
        }
    }
}

fn waitForegroundWritable(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
    // this module is only used by short setup paths before a
    // dispatcher-owned relay loop exists. Keep the synchronous wait local and
    // auditable instead of letting foreground callers each grow their own poll
    // loop.
    while (true) {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        _ = try blocking.poll(pollfds[0..], -1);
        const revents = pollfds[0].revents;
        if ((revents & posix.POLL.OUT) != 0) return;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
            return error.EndOfStream;
        }
    }
}

fn readExactForeground(
    options: ReadOptions,
    buf: []u8,
    empty_eof_error: anyerror,
    partial_eof_error: anyerror,
) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        if (isCancelled(options.cancelled)) return options.cancel_error;
        switch (try core_io.readSomeNonBlocking(options.fd, buf[filled..])) {
            .would_block => {
                try waitForegroundReadable(options);
            },
            .eof => return if (filled == 0) empty_eof_error else partial_eof_error,
            .bytes => |bytes| {
                core_io.noteRead(options.fd, bytes);
                filled += bytes.len;
            },
        }
    }
}

fn readScmRightsMarkerForeground(options: ReadOptions) !c.fd_t {
    var marker: [1]u8 = undefined;
    var progress = fd_passing.RecvBufferWithFdProgress.init(&marker, null);
    defer progress.deinit();

    while (true) {
        if (isCancelled(options.cancelled)) return options.cancel_error;
        switch (try fd_passing.recvBufferWithFdProgress(options.fd, &progress)) {
            .blocked => try waitForegroundReadable(options),
            .progress => continue,
            .complete => return progress.takeFd() orelse error.MissingFileDescriptor,
            .eof => return error.TruncatedFrame,
        }
    }
}

fn waitForegroundReadable(options: ReadOptions) !void {
    // This module is only used by short setup paths before a dispatcher-owned
    // relay loop exists. Use direct `poll(2)` here so cancellation-aware
    // foreground callers can wake periodically without building a second event
    // loop.
    while (true) {
        if (isCancelled(options.cancelled)) return options.cancel_error;
        var pollfds = [_]posix.pollfd{.{
            .fd = options.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const timeout_ms: i32 = if (options.cancelled == null) -1 else cancellation_poll_ms;
        _ = try options.blocking.poll(pollfds[0..], timeout_ms);
        if (isCancelled(options.cancelled)) return options.cancel_error;

        const revents = pollfds[0].revents;
        if ((revents & posix.POLL.IN) != 0) return;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
            return error.EndOfStream;
        }
    }
}

test "foreground frame io writes and reads one frame" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const pipe = try std.posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    try writeFrame(.{
        .blocking = core_blocking.fromTest(),
        .allocator = std.testing.allocator,
        .fd = pipe[1],
        .message_type = .client_daemon,
        .payload = payload,
    });

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, frame.message_type);
}

test "foreground frame io writes frame with SCM_RIGHTS fd" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer {
        _ = c.close(control[0]);
        _ = c.close(control[1]);
    }

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    try writeFrameWithScmRightsFd(.{
        .blocking = core_blocking.fromTest(),
        .allocator = std.testing.allocator,
        .fd = control[0],
        .message_type = .client_daemon,
        .payload = payload,
        .passed_fd = raw[0],
    });

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, control[1]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, frame.message_type);
    const received_fd = frame.takeFd() orelse return error.ExpectedFileDescriptor;
    defer _ = c.close(received_fd);

    try core_blocking.fromTest().writeAll(received_fd, "raw-bytes");
    var buf: [32]u8 = undefined;
    const n = c.read(raw[1], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("raw-bytes", buf[0..@intCast(n)]);
}

test "foreground frame read honors cancellation before polling" {
    const pipe = try std.posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var cancelled = true;
    try std.testing.expectError(error.TestCancelled, readFrame(.{
        .blocking = core_blocking.fromTest(),
        .allocator = std.testing.allocator,
        .fd = pipe[0],
        .cancelled = &cancelled,
        .cancel_error = error.TestCancelled,
    }));
}
