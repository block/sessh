// Shared mux helpers for daemon-to-daemon tunnels. One SSH connection carries
// many independent byte streams, each identified by `MuxStreamFrame.stream_id`;
// daemon/tunnel.zig owns the per-stream handler state.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const first_stream_id: u64 = 1;

/// Allocates stream ids for one side of a mux tunnel.
///
/// Zero is skipped because protobuf defaults make it too easy to confuse with
/// "not set" in logs and validation.
pub const StreamIdAllocator = struct {
    next: u64 = first_stream_id,

    pub fn take(self: *StreamIdAllocator) u64 {
        const id = self.next;
        self.next +%= 1;
        if (self.next == 0) self.next = first_stream_id;
        return id;
    }
};

pub fn encodeDaemonTunnelPayload(
    allocator: std.mem.Allocator,
    payload: protocol.DaemonTunnelPayload,
) ![]u8 {
    return protocol.encodeDaemonTunnelPayload(allocator, payload);
}

pub fn encodeMuxStreamFrameBytes(
    allocator: std.mem.Allocator,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) ![]u8 {
    const payload = try protocol.encodeMuxStreamFramePayload(allocator, mux_frame);
    defer allocator.free(payload);
    return protocol.encodeFrame(allocator, .daemon_tunnel, payload);
}

pub fn encodeMuxStreamPayload(
    allocator: std.mem.Allocator,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) ![]u8 {
    return encodeDaemonTunnelPayload(allocator, .{ .mux_stream = mux_frame });
}

// Encodes only the MuxStreamFrame.Open envelope described in proto/sessh.proto;
// the terminal/proxy typed open payload is sent as a separate mux frame.
pub fn encodeMuxEnvelopeOpenFrameBytes(
    allocator: std.mem.Allocator,
    stream_id: u64,
    recv_next_offset: u64,
) ![]u8 {
    return encodeMuxStreamFrameBytes(allocator, .{
        .stream_id = stream_id,
        .message = .{ .open = .{
            .recv_next_offset = recv_next_offset,
        } },
    });
}

pub fn encodeAckPayload(
    allocator: std.mem.Allocator,
    stream_id: u64,
    recv_next_offset: u64,
) ![]u8 {
    return encodeMuxStreamPayload(allocator, .{
        .stream_id = stream_id,
        .message = .{ .ack = .{ .recv_next_offset = recv_next_offset } },
    });
}

pub fn encodeOpenOkPayload(
    allocator: std.mem.Allocator,
    stream_id: u64,
    recv_next_offset: u64,
) ![]u8 {
    return encodeMuxStreamPayload(allocator, .{
        .stream_id = stream_id,
        .message = .{ .open_ok = .{ .recv_next_offset = recv_next_offset } },
    });
}

pub fn TaggedFrameWrite(comptime Kind: type) type {
    // Encoded-frame writes often complete asynchronously relative to their
    // caller's state machine. The tag records why the frame was queued without
    // requiring the completion path to decode serialized bytes.
    return struct {
        frame: protocol.FrameWriteState,
        kind: Kind,

        pub fn deinit(self: *@This()) void {
            self.frame.deinit();
            self.* = undefined;
        }
    };
}

pub fn TaggedRawWrite(comptime Kind: type) type {
    // Raw writes are used where the bytes are not themselves sessh frames, but
    // the caller still needs to remember which logical operation the write will
    // complete after handling short writes.
    return struct {
        bytes: []u8,
        offset: usize = 0,
        kind: Kind,

        pub fn remaining(self: *const @This()) []const u8 {
            return self.bytes[self.offset..];
        }

        pub fn writeReady(self: *@This(), fd: c.fd_t) !bool {
            while (self.remaining().len != 0) {
                const chunk = self.remaining();
                const n = c.write(fd, chunk.ptr, chunk.len);
                if (n < 0) switch (posix.errno(n)) {
                    .AGAIN => return false,
                    .INTR => continue,
                    else => return error.WriteFailed,
                };
                if (n == 0) return error.WriteFailed;
                const written: usize = @intCast(n);
                io.noteWrite(fd, chunk[0..written]);
                self.offset += written;
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}

pub fn TaggedFrameWrites(comptime Kind: type) type {
    // Small FIFO of encoded frames tagged with caller-owned state. The tag lets
    // write completion drive the surrounding state machine without decoding the
    // already-serialized frame.
    return struct {
        const Self = @This();
        const Write = TaggedFrameWrite(Kind);

        allocator: std.mem.Allocator,
        pending: std.ArrayList(Write) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.pending.items) |*write| write.deinit();
            self.pending.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn hasPending(self: *const Self) bool {
            return self.pending.items.len != 0;
        }

        pub fn appendFrame(
            self: *Self,
            message_type: protocol.MessageType,
            payload: []const u8,
            kind: Kind,
        ) !void {
            var frame = try protocol.FrameWriteState.init(self.allocator, message_type, payload);
            errdefer frame.deinit();
            try self.pending.append(self.allocator, .{ .frame = frame, .kind = kind });
        }

        pub fn appendWrite(self: *Self, write: Write) !void {
            try self.pending.append(self.allocator, write);
        }

        pub fn popFirst(self: *Self) ?Write {
            if (self.pending.items.len == 0) return null;
            return self.pending.orderedRemove(0);
        }
    };
}

test "stream id allocator starts at one and advances" {
    var allocator = StreamIdAllocator{};
    try std.testing.expectEqual(@as(u64, 1), allocator.take());
    try std.testing.expectEqual(@as(u64, 2), allocator.take());
}

test "tagged frame writes preserves order and kind" {
    const TestKind = enum { first, second };
    const Queue = TaggedFrameWrites(TestKind);
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);
    try queue.appendFrame(.client_daemon, payload, .first);
    try queue.appendFrame(.client_daemon, payload, .second);
    try std.testing.expect(queue.hasPending());

    var first = queue.popFirst().?;
    defer first.deinit();
    try std.testing.expectEqual(TestKind.first, first.kind);
    var second = queue.popFirst().?;
    defer second.deinit();
    try std.testing.expectEqual(TestKind.second, second.kind);
    try std.testing.expect(!queue.hasPending());
}

test "tagged raw write tracks partial progress" {
    const posix_test = std.posix;
    const TestKind = enum { payload };
    const RawWrite = TaggedRawWrite(TestKind);

    const pipe = try posix_test.pipe();
    defer {
        posix_test.close(pipe[0]);
        posix_test.close(pipe[1]);
    }

    const bytes = try std.testing.allocator.dupe(u8, "raw");
    var raw = RawWrite{ .bytes = bytes, .kind = .payload };
    defer raw.deinit(std.testing.allocator);

    try std.testing.expect(try raw.writeReady(pipe[1]));
    try std.testing.expectEqual(@as(usize, 3), raw.offset);
}
