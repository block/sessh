// Logical stream registry for daemon-to-daemon tunnels. It tracks stream IDs,
// typed opens, and pending frames so tunnel dispatch can stay independent of
// terminal-session and proxy-stream implementations.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const first_stream_id: u64 = 1;

pub const StreamKind = enum {
    unknown,
    terminal,
    proxy,
};

const StreamEntry = struct {
    stream_id: u64,
    kind: StreamKind = .unknown,
    pending_open: ?pb.DaemonTunnelItem.MuxStreamFrame.Open = null,
};

pub const StreamRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(StreamEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) StreamRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StreamRegistry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn noteOpen(
        self: *StreamRegistry,
        stream_id: u64,
        open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
    ) !void {
        const entry_index = try self.indexOrAppend(stream_id);
        self.entries.items[entry_index].pending_open = open;
    }

    fn setKindIfUnknown(
        self: *StreamRegistry,
        stream_id: u64,
        stream_kind: StreamKind,
    ) !SetKindResult {
        const entry_index = try self.indexOrAppend(stream_id);
        const entry = &self.entries.items[entry_index];
        if (entry.kind == stream_kind) return .already_set;
        if (entry.kind != .unknown) return .changed_kind;
        entry.kind = stream_kind;
        return .new_kind;
    }

    fn pendingOpen(self: *const StreamRegistry, stream_id: u64) ?pb.DaemonTunnelItem.MuxStreamFrame.Open {
        const entry_index = self.index(stream_id) orelse return null;
        return self.entries.items[entry_index].pending_open;
    }

    fn kind(self: *const StreamRegistry, stream_id: u64) StreamKind {
        const entry_index = self.index(stream_id) orelse return .unknown;
        return self.entries.items[entry_index].kind;
    }

    pub fn remove(self: *StreamRegistry, stream_id: u64) void {
        const entry_index = self.index(stream_id) orelse return;
        _ = self.entries.swapRemove(entry_index);
    }

    fn indexOrAppend(self: *StreamRegistry, stream_id: u64) !usize {
        if (self.index(stream_id)) |entry_index| return entry_index;
        try self.entries.append(self.allocator, .{ .stream_id = stream_id });
        return self.entries.items.len - 1;
    }

    fn index(self: *const StreamRegistry, stream_id: u64) ?usize {
        for (self.entries.items, 0..) |entry, entry_index| {
            if (entry.stream_id == stream_id) return entry_index;
        }
        return null;
    }
};

const SetKindResult = enum {
    already_set,
    new_kind,
    changed_kind,
};

pub const StreamRoute = struct {
    kind: StreamKind,
    open_before_dispatch: ?pb.DaemonTunnelItem.MuxStreamFrame.Open = null,
    closes_after_dispatch: bool = false,
};

pub const RouteResult = union(enum) {
    pending_open,
    stream: StreamRoute,
    changed_kind,
    unexpected,
};

pub fn routeIncomingFrame(
    registry: *StreamRegistry,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !RouteResult {
    // Stream type is learned from the typed payload, but open frames can arrive
    // before payload frames. Keep the open pending until the first terminal or
    // proxy payload tells the daemon which handler owns the stream.
    const stream_id = mux_frame.stream_id;
    const message = mux_frame.message orelse return .unexpected;
    switch (message) {
        .open => |open| {
            try registry.noteOpen(stream_id, open);
            const existing_kind = registry.kind(stream_id);
            if (existing_kind == .unknown) return .pending_open;
            return .{ .stream = .{ .kind = existing_kind } };
        },
        .payload => |payload| {
            const stream_kind = kindFromPayload(payload) orelse return .unexpected;
            const kind_result = try registry.setKindIfUnknown(stream_id, stream_kind);
            switch (kind_result) {
                .already_set => return .{ .stream = .{ .kind = stream_kind } },
                .changed_kind => return .changed_kind,
                .new_kind => return .{ .stream = .{
                    .kind = stream_kind,
                    .open_before_dispatch = registry.pendingOpen(stream_id) orelse .{},
                } },
            }
        },
        .ack, .open_ok, .eof, .reset => {
            const stream_kind = registry.kind(stream_id);
            if (stream_kind == .unknown) return .unexpected;
            return .{ .stream = .{
                .kind = stream_kind,
                .closes_after_dispatch = closesStream(message),
            } };
        },
    }
}

pub const StreamIdAllocator = struct {
    next: u64 = first_stream_id,

    pub fn take(self: *StreamIdAllocator) u64 {
        const id = self.next;
        self.next +%= 1;
        if (self.next == 0) self.next = first_stream_id;
        return id;
    }
};

fn kindFromPayload(payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload) ?StreamKind {
    const item = payload.item orelse return null;
    return switch (item) {
        .terminal_emulator => .terminal,
        .proxy => .proxy,
    };
}

fn closesStream(message: protocol.MuxStreamMessage) bool {
    return switch (message) {
        .eof, .reset => true,
        else => false,
    };
}

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

pub fn encodeOpenEnvelopeBytes(
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

pub fn TaggedFrameWriteQueue(comptime Kind: type) type {
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

test "stream registry tracks open kind and close" {
    const allocator = std.testing.allocator;
    var registry = StreamRegistry.init(allocator);
    defer registry.deinit();

    try registry.noteOpen(7, .{ .recv_next_offset = 3 });
    try std.testing.expectEqual(StreamKind.unknown, registry.kind(7));
    try std.testing.expectEqual(@as(u64, 3), registry.pendingOpen(7).?.recv_next_offset);

    try std.testing.expectEqual(SetKindResult.new_kind, try registry.setKindIfUnknown(7, .terminal));
    try std.testing.expectEqual(StreamKind.terminal, registry.kind(7));
    try std.testing.expectEqual(SetKindResult.already_set, try registry.setKindIfUnknown(7, .terminal));
    try std.testing.expectEqual(SetKindResult.changed_kind, try registry.setKindIfUnknown(7, .proxy));

    registry.remove(7);
    try std.testing.expectEqual(StreamKind.unknown, registry.kind(7));
}

test "mux router defers open until typed payload identifies stream kind" {
    const allocator = std.testing.allocator;
    var registry = StreamRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(RouteResult.pending_open, try routeIncomingFrame(&registry, .{
        .stream_id = 9,
        .message = .{ .open = .{ .recv_next_offset = 4 } },
    }));

    const routed = try routeIncomingFrame(&registry, .{
        .stream_id = 9,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .proxy = .{ .payload = .{ .open = .{
                .proxy_guid = "p-11111111-1111-4111-8111-111111111111",
                .proxy_host = "localhost",
                .proxy_port = 22,
            } } } },
        } },
    });
    switch (routed) {
        .stream => |route| {
            try std.testing.expectEqual(StreamKind.proxy, route.kind);
            try std.testing.expectEqual(@as(u64, 4), route.open_before_dispatch.?.recv_next_offset);
            try std.testing.expect(!route.closes_after_dispatch);
        },
        else => return error.ExpectedMuxStreamRoute,
    }
}

test "mux router reports close after eof" {
    const allocator = std.testing.allocator;
    var registry = StreamRegistry.init(allocator);
    defer registry.deinit();

    _ = try routeIncomingFrame(&registry, .{
        .stream_id = 11,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .terminal_emulator = .{ .payload = .{ .open = .{
                .session_guid = "s-11111111-1111-4111-8111-111111111111",
                .resize = .{ .terminal_rows = 24, .terminal_cols = 80 },
            } } } },
        } },
    });

    const routed = try routeIncomingFrame(&registry, .{
        .stream_id = 11,
        .message = .{ .eof = .{ .final_offset = 3 } },
    });
    switch (routed) {
        .stream => |route| {
            try std.testing.expectEqual(StreamKind.terminal, route.kind);
            try std.testing.expect(route.closes_after_dispatch);
        },
        else => return error.ExpectedMuxStreamRoute,
    }
}

test "mux router keeps multiple streams independent and rejects kind changes" {
    const allocator = std.testing.allocator;
    var registry = StreamRegistry.init(allocator);
    defer registry.deinit();

    _ = try routeIncomingFrame(&registry, .{
        .stream_id = 1,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .terminal_emulator = .{ .payload = .{ .open = .{
                .session_guid = "s-11111111-1111-4111-8111-111111111111",
                .resize = .{ .terminal_rows = 24, .terminal_cols = 80 },
            } } } },
        } },
    });
    _ = try routeIncomingFrame(&registry, .{
        .stream_id = 2,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .proxy = .{ .payload = .{ .open = .{
                .proxy_guid = "p-11111111-1111-4111-8111-111111111111",
                .proxy_host = "localhost",
                .proxy_port = 22,
            } } } },
        } },
    });

    try std.testing.expectEqual(StreamKind.terminal, registry.kind(1));
    try std.testing.expectEqual(StreamKind.proxy, registry.kind(2));
    try std.testing.expectEqual(RouteResult.changed_kind, try routeIncomingFrame(&registry, .{
        .stream_id = 1,
        .message = .{ .payload = .{
            .offset = 1,
            .item = .{ .proxy = .{ .payload = .{ .data = "wrong-kind" } } },
        } },
    }));

    _ = try routeIncomingFrame(&registry, .{
        .stream_id = 2,
        .message = .{ .reset = .{ .code = "DONE", .message = "done" } },
    });
    registry.remove(2);
    try std.testing.expectEqual(StreamKind.terminal, registry.kind(1));
    try std.testing.expectEqual(StreamKind.unknown, registry.kind(2));
}

test "tagged frame write queue preserves order and kind" {
    const TestKind = enum { first, second };
    const Queue = TaggedFrameWriteQueue(TestKind);
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
