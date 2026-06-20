// Bounded non-blocking frame writer. Owners queue complete encoded frames here
// and drive writes from fd readiness, so backpressure remains explicit instead
// of becoming an unbounded allocation path.
const std = @import("std");
const c = std.c;

const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const WriteQueueStatus = enum {
    blocked,
    progress,
    drained,
};

pub const BoundedFrame = struct {
    message_type: protocol.MessageType,
    payload: []const u8,
    max_queued_bytes: usize,
};

pub const FrameWriteQueue = struct {
    allocator: std.mem.Allocator,
    pending_frames: std.ArrayList(protocol.FrameWriteState) = .empty,

    pub fn init(allocator: std.mem.Allocator) FrameWriteQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameWriteQueue) void {
        for (self.pending_frames.items) |*frame| frame.deinit();
        self.pending_frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasPending(self: *const FrameWriteQueue) bool {
        return self.pending_frames.items.len != 0;
    }

    pub fn queuedBytes(self: *const FrameWriteQueue) usize {
        var total: usize = 0;
        for (self.pending_frames.items) |frame| {
            total += frame.bytes.len - frame.written;
        }
        return total;
    }

    pub fn queueFrame(
        self: *FrameWriteQueue,
        message_type: protocol.MessageType,
        payload: []const u8,
    ) !void {
        var frame = try protocol.FrameWriteState.init(self.allocator, message_type, payload);
        errdefer frame.deinit();
        try self.pending_frames.append(self.allocator, frame);
    }

    pub fn queueFrameWithByteLimit(self: *FrameWriteQueue, frame_request: BoundedFrame) !void {
        var frame = try protocol.FrameWriteState.init(self.allocator, frame_request.message_type, frame_request.payload);
        errdefer frame.deinit();
        const frame_len = frame.bytes.len - frame.written;
        if (frame_len > frame_request.max_queued_bytes or self.queuedBytes() > frame_request.max_queued_bytes - frame_len) {
            return error.FrameWriteQueueFull;
        }
        try self.pending_frames.append(self.allocator, frame);
    }

    pub fn queueDaemonTunnelPayload(
        self: *FrameWriteQueue,
        payload: protocol.DaemonTunnelPayload,
    ) !void {
        const encoded = try protocol.encodeDaemonTunnelPayload(self.allocator, payload);
        defer self.allocator.free(encoded);
        try self.queueFrame(.daemon_tunnel, encoded);
    }

    pub fn queueClientRemotePayload(
        self: *FrameWriteQueue,
        payload: protocol.ClientRemotePayload,
    ) !void {
        const encoded = try protocol.encodeClientRemotePayload(self.allocator, payload);
        defer self.allocator.free(encoded);
        try self.queueFrame(.client_remote, encoded);
    }

    pub fn queueTerminalEmulatorPayload(
        self: *FrameWriteQueue,
        payload: protocol.TerminalEmulatorPayload,
    ) !void {
        try self.queueClientRemotePayload(.{ .terminal_emulator = .{ .payload = payload } });
    }

    pub fn queueMuxStreamFrame(
        self: *FrameWriteQueue,
        message: pb.DaemonTunnelItem.MuxStreamFrame,
    ) !void {
        try self.queueDaemonTunnelPayload(.{ .mux_stream = message });
    }

    pub fn writeReady(self: *FrameWriteQueue, fd: c.fd_t) !WriteQueueStatus {
        var made_progress = false;
        while (self.pending_frames.items.len != 0) {
            const write = &self.pending_frames.items[0];
            switch (try write.writeReady(fd)) {
                .blocked => return if (made_progress) .progress else .blocked,
                .progress => return .progress,
                .done => {
                    made_progress = true;
                    write.deinit();
                    _ = self.pending_frames.orderedRemove(0);
                },
            }
        }
        return .drained;
    }
};

test "frame write queue drains frames in order" {
    const posix = std.posix;

    const pipe = try posix.pipe();
    defer {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
    }

    var queue = FrameWriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    const first = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(first);
    const second = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_entry = .{
        .unix_ms = 1,
        .message = "queued",
    } });
    defer std.testing.allocator.free(second);

    try queue.queueFrame(.client_daemon, first);
    try queue.queueFrame(.client_daemon, second);
    try std.testing.expect(queue.hasPending());
    try std.testing.expect(queue.queuedBytes() > 0);
    try std.testing.expectEqual(WriteQueueStatus.drained, try queue.writeReady(pipe[1]));
    try std.testing.expect(!queue.hasPending());
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());

    var reader = protocol.FrameReader.init(std.testing.allocator);
    defer reader.deinit();

    const first_frame = readOneFrame(pipe[0], &reader) catch |err| switch (err) {
        error.NoFrame => return error.ExpectedFrame,
        else => return err,
    };
    defer {
        var frame = first_frame;
        frame.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(protocol.MessageType.client_daemon, first_frame.message_type);

    const second_frame = readOneFrame(pipe[0], &reader) catch |err| switch (err) {
        error.NoFrame => return error.ExpectedFrame,
        else => return err,
    };
    defer {
        var frame = second_frame;
        frame.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(protocol.MessageType.client_daemon, second_frame.message_type);
}

test "frame write queue enforces queued byte limit before appending" {
    var queue = FrameWriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    try std.testing.expectError(
        error.FrameWriteQueueFull,
        queue.queueFrameWithByteLimit(.{
            .message_type = .client_daemon,
            .payload = payload,
            .max_queued_bytes = 1,
        }),
    );
    try std.testing.expect(!queue.hasPending());

    try queue.queueFrameWithByteLimit(.{
        .message_type = .client_daemon,
        .payload = payload,
        .max_queued_bytes = 1024,
    });
    try std.testing.expect(queue.hasPending());
}

fn readOneFrame(fd: c.fd_t, reader: *protocol.FrameReader) !protocol.OwnedFrame {
    while (true) {
        switch (try reader.readReady(fd)) {
            .blocked => return error.NoFrame,
            .progress => continue,
            .eof, .truncated_frame => return error.NoFrame,
            .frame => |frame| return frame,
        }
    }
}
