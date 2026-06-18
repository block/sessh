const std = @import("std");
const c = std.c;

const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const WriteQueueStatus = enum {
    blocked,
    progress,
    drained,
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

    pub fn queueFrame(
        self: *FrameWriteQueue,
        message_type: protocol.MessageType,
        payload: []const u8,
    ) !void {
        var frame = try protocol.FrameWriteState.init(self.allocator, message_type, payload);
        errdefer frame.deinit();
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
    try std.testing.expectEqual(WriteQueueStatus.drained, try queue.writeReady(pipe[1]));
    try std.testing.expect(!queue.hasPending());

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
