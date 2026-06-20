const std = @import("std");

pub const StreamByteState = struct {
    outbound: std.ArrayList(u8) = .empty,
    outbound_base: u64 = 0,
    recv_next_offset: u64 = 0,
    peer_recv: u64 = 0,
    // ACKs decide what can be dropped. `outbound_sent_next` separately tracks
    // bytes sent on the current transport so a live transport does not resend
    // overlapping data before the peer has had time to ACK it.
    outbound_sent_next: u64 = 0,
    outbound_eof: bool = false,
    outbound_eof_sent: bool = false,
    outbound_eof_acked: bool = false,
    inbound_eof: bool = false,

    pub fn outboundNext(self: *const StreamByteState) u64 {
        return self.outbound_base + self.outbound.items.len;
    }

    pub fn bufferedBytes(self: *const StreamByteState) usize {
        return self.outbound.items.len;
    }

    pub fn deinit(self: *StreamByteState, allocator: std.mem.Allocator) void {
        self.outbound.deinit(allocator);
        self.* = undefined;
    }
};

// Tracks one byte stream in each direction. `outbound` contains bytes waiting
// for the peer. `inbound.recv_next_offset` is stricter: it advances only after
// bytes have reached the local sink, so ACKs never get ahead of delivery.
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    guid: []const u8,
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    outbound: StreamByteState = .{},
    inbound: StreamByteState = .{},
    inbound_pending: std.ArrayList(u8) = .empty,
    inbound_eof_pending: bool = false,
    inbound_eof_applied: bool = false,
    peer_ready: bool = false,
    source_eof: bool = false,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        guid: []const u8,
        proxy_host: []const u8 = "",
        proxy_port: u16 = 0,
    };

    pub fn init(options: InitOptions) StreamState {
        return .{
            .allocator = options.allocator,
            .guid = options.guid,
            .proxy_host = options.proxy_host,
            .proxy_port = options.proxy_port,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.outbound.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
        self.inbound_pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendOutbound(self: *StreamState, bytes: []const u8) !void {
        try self.outbound.outbound.appendSlice(self.allocator, bytes);
    }

    pub fn dropOutboundThrough(self: *StreamState, offset: u64) !void {
        if (offset < self.outbound.outbound_base) return;
        if (offset > self.outbound.outboundNext()) return error.StreamAckOutOfRange;
        const drop: usize = @intCast(offset - self.outbound.outbound_base);
        if (drop == 0) return;
        const remaining = self.outbound.outbound.items.len - drop;
        std.mem.copyForwards(u8, self.outbound.outbound.items[0..remaining], self.outbound.outbound.items[drop..]);
        self.outbound.outbound.shrinkRetainingCapacity(remaining);
        self.outbound.outbound_base = offset;
    }

    pub fn resumeOutbound(self: *StreamState, offset: u64) !void {
        self.outbound.peer_recv = offset;
        try self.dropOutboundThrough(offset);
        self.outbound.outbound_sent_next = offset;
    }

    pub fn ackOutbound(self: *StreamState, offset: u64) !void {
        self.outbound.peer_recv = offset;
        try self.dropOutboundThrough(offset);
        if (self.outbound.outbound_sent_next < offset) self.outbound.outbound_sent_next = offset;
        if (self.outbound.outbound_eof_sent and offset == self.outbound.outboundNext()) {
            self.outbound.outbound_eof_acked = true;
        }
    }

    pub fn inboundQueuedNext(self: *const StreamState) u64 {
        return self.inbound.recv_next_offset + self.inbound_pending.items.len;
    }

    pub fn queueInboundData(self: *StreamState, offset: u64, data: []const u8) !usize {
        var new_offset = offset;
        var new_data = data;

        if (new_offset < self.inbound.recv_next_offset) {
            const already_delivered: usize = @intCast(self.inbound.recv_next_offset - new_offset);
            if (already_delivered >= new_data.len) return 0;
            new_data = new_data[already_delivered..];
            new_offset = self.inbound.recv_next_offset;
        }

        const queued_next = self.inboundQueuedNext();
        if (new_offset < queued_next) {
            const already_queued: usize = @intCast(queued_next - new_offset);
            if (already_queued >= new_data.len) return 0;
            new_data = new_data[already_queued..];
            new_offset = queued_next;
        }

        if (new_offset != queued_next) return error.StreamOffsetGap;
        try self.inbound_pending.appendSlice(self.allocator, new_data);
        return new_data.len;
    }

    pub fn pendingInboundData(self: *const StreamState) []const u8 {
        return self.inbound_pending.items;
    }

    pub fn noteInboundDelivered(self: *StreamState, n: usize) !void {
        if (n > self.inbound_pending.items.len) return error.StreamAckOutOfRange;
        if (n == 0) return;
        const remaining = self.inbound_pending.items.len - n;
        std.mem.copyForwards(u8, self.inbound_pending.items[0..remaining], self.inbound_pending.items[n..]);
        self.inbound_pending.shrinkRetainingCapacity(remaining);
        self.inbound.recv_next_offset += n;
        if (self.inbound_eof_pending and self.inbound_pending.items.len == 0) {
            self.inbound.inbound_eof = true;
            self.inbound_eof_pending = false;
        }
    }

    pub fn markInboundEof(self: *StreamState, final_offset: u64) !void {
        if (final_offset != self.inboundQueuedNext()) return error.StreamOffsetGap;
        if (self.inbound_pending.items.len == 0) {
            self.inbound.inbound_eof = true;
        } else {
            self.inbound_eof_pending = true;
        }
    }

    pub fn completeOutboundAfterInboundEof(self: *StreamState) void {
        const final_outbound_offset = self.outbound.outboundNext();
        self.outbound.outbound.shrinkRetainingCapacity(0);
        self.outbound.outbound_base = final_outbound_offset;
        self.outbound.peer_recv = final_outbound_offset;
        self.outbound.outbound_sent_next = final_outbound_offset;
        self.outbound.outbound_eof = true;
        self.outbound.outbound_eof_sent = true;
        self.outbound.outbound_eof_acked = true;
        self.source_eof = true;
    }

    pub fn bufferedBytes(self: *const StreamState) usize {
        return self.outbound.bufferedBytes();
    }

    pub fn complete(self: *const StreamState) bool {
        return self.outbound.outbound_eof and
            self.outbound.outbound_eof_acked and
            self.outbound.outbound.items.len == 0 and
            self.inbound.inbound_eof;
    }

    pub fn hasProgress(self: *const StreamState) bool {
        return self.inbound.recv_next_offset != 0 or
            self.inbound_pending.items.len != 0 or
            self.inbound_eof_pending or
            self.outbound.outbound_base != 0 or
            self.outbound.outbound.items.len != 0;
    }
};

test "byte stream appends outbound bytes and ACK drops them" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try state.appendOutbound("abcdef");
    try std.testing.expectEqual(@as(u64, 6), state.outbound.outboundNext());
    try state.ackOutbound(2);
    try std.testing.expectEqual(@as(u64, 2), state.outbound.outbound_base);
    try std.testing.expectEqualStrings("cdef", state.outbound.outbound.items);
}

test "byte stream rejects ACK beyond buffered outbound data" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try state.appendOutbound("abc");
    try std.testing.expectError(error.StreamAckOutOfRange, state.ackOutbound(4));
}

test "byte stream queues duplicate inbound data without moving backwards" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 6), try state.queueInboundData(0, "abcdef"));
    try std.testing.expectEqualStrings("abcdef", state.pendingInboundData());
    try std.testing.expectEqual(@as(u64, 6), state.inboundQueuedNext());

    try std.testing.expectEqual(@as(usize, 0), try state.queueInboundData(0, "abc"));
    try std.testing.expectEqual(@as(u64, 6), state.inboundQueuedNext());

    try std.testing.expectEqual(@as(usize, 2), try state.queueInboundData(3, "defgh"));
    try std.testing.expectEqualStrings("abcdefgh", state.pendingInboundData());
    try std.testing.expectEqual(@as(u64, 8), state.inboundQueuedNext());
}

test "byte stream queues inbound data before ACK delivery" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 3), try state.queueInboundData(0, "abc"));
    try std.testing.expectEqual(@as(u64, 0), state.inbound.recv_next_offset);
    try std.testing.expectEqual(@as(u64, 3), state.inboundQueuedNext());
    try std.testing.expectEqual(@as(usize, 3), try state.queueInboundData(3, "def"));
    try std.testing.expectEqualStrings("abcdef", state.pendingInboundData());

    try state.noteInboundDelivered(2);
    try std.testing.expectEqual(@as(u64, 2), state.inbound.recv_next_offset);
    try std.testing.expectEqualStrings("cdef", state.pendingInboundData());
    try std.testing.expectEqual(@as(usize, 1), try state.queueInboundData(5, "fg"));
    try std.testing.expectEqualStrings("cdefg", state.pendingInboundData());
}

test "byte stream delays inbound eof until pending bytes are delivered" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 3), try state.queueInboundData(0, "abc"));
    try state.markInboundEof(3);
    try std.testing.expect(!state.inbound.inbound_eof);
    try std.testing.expect(state.inbound_eof_pending);

    try state.noteInboundDelivered(3);
    try std.testing.expect(state.inbound.inbound_eof);
    try std.testing.expect(!state.inbound_eof_pending);
}

test "byte stream rejects out-of-order inbound offsets" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try std.testing.expectError(error.StreamOffsetGap, state.queueInboundData(1, "x"));
}

test "byte stream marks inbound eof only at current offset" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 3), try state.queueInboundData(0, "abc"));
    try std.testing.expectError(error.StreamOffsetGap, state.markInboundEof(2));
    try state.noteInboundDelivered(3);
    try state.markInboundEof(3);
    try std.testing.expect(state.inbound.inbound_eof);
}

test "byte stream cleanup releases outbound buffer" {
    var state = StreamState.init(.{
        .allocator = std.testing.allocator,
        .guid = "p-test",
        .proxy_host = "host",
        .proxy_port = 22,
    });
    try state.appendOutbound("abc");
    state.deinit();
}
