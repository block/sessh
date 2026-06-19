const std = @import("std");

pub const InboundData = struct {
    new_data: []const u8,
    recv_next_offset: u64,
};

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

// Tracks one byte stream in each direction. The local side appends source bytes
// to `outbound`; peer data advances `inbound.recv_next_offset`.
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    guid: []const u8,
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    outbound: StreamByteState = .{},
    inbound: StreamByteState = .{},
    peer_ready: bool = false,
    source_eof: bool = false,

    pub fn init(allocator: std.mem.Allocator, guid: []const u8, proxy_host: []const u8, proxy_port: u16) StreamState {
        return .{
            .allocator = allocator,
            .guid = guid,
            .proxy_host = proxy_host,
            .proxy_port = proxy_port,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.outbound.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
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

    pub fn acceptInboundData(self: *StreamState, offset: u64, data: []const u8) !InboundData {
        if (offset < self.inbound.recv_next_offset) {
            const already_received: usize = @intCast(self.inbound.recv_next_offset - offset);
            if (already_received >= data.len) {
                return .{ .new_data = data[data.len..], .recv_next_offset = self.inbound.recv_next_offset };
            }
            const new_data = data[already_received..];
            self.inbound.recv_next_offset += new_data.len;
            return .{ .new_data = new_data, .recv_next_offset = self.inbound.recv_next_offset };
        }
        if (offset != self.inbound.recv_next_offset) return error.StreamOffsetGap;
        self.inbound.recv_next_offset += data.len;
        return .{ .new_data = data, .recv_next_offset = self.inbound.recv_next_offset };
    }

    pub fn markInboundEof(self: *StreamState, final_offset: u64) !void {
        if (final_offset != self.inbound.recv_next_offset) return error.StreamOffsetGap;
        self.inbound.inbound_eof = true;
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
            self.outbound.outbound_base != 0 or
            self.outbound.outbound.items.len != 0;
    }
};

test "byte stream appends outbound bytes and ACK drops them" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    defer state.deinit();

    try state.appendOutbound("abcdef");
    try std.testing.expectEqual(@as(u64, 6), state.outbound.outboundNext());
    try state.ackOutbound(2);
    try std.testing.expectEqual(@as(u64, 2), state.outbound.outbound_base);
    try std.testing.expectEqualStrings("cdef", state.outbound.outbound.items);
}

test "byte stream rejects ACK beyond buffered outbound data" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    defer state.deinit();

    try state.appendOutbound("abc");
    try std.testing.expectError(error.StreamAckOutOfRange, state.ackOutbound(4));
}

test "byte stream accepts duplicate inbound data without moving backwards" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    defer state.deinit();

    const first = try state.acceptInboundData(0, "abcdef");
    try std.testing.expectEqualStrings("abcdef", first.new_data);
    try std.testing.expectEqual(@as(u64, 6), first.recv_next_offset);

    const duplicate = try state.acceptInboundData(0, "abc");
    try std.testing.expectEqual(@as(usize, 0), duplicate.new_data.len);
    try std.testing.expectEqual(@as(u64, 6), duplicate.recv_next_offset);

    const overlap = try state.acceptInboundData(3, "defgh");
    try std.testing.expectEqualStrings("gh", overlap.new_data);
    try std.testing.expectEqual(@as(u64, 8), overlap.recv_next_offset);
}

test "byte stream rejects out-of-order inbound offsets" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    defer state.deinit();

    try std.testing.expectError(error.StreamOffsetGap, state.acceptInboundData(1, "x"));
}

test "byte stream marks inbound eof only at current offset" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    defer state.deinit();

    _ = try state.acceptInboundData(0, "abc");
    try std.testing.expectError(error.StreamOffsetGap, state.markInboundEof(2));
    try state.markInboundEof(3);
    try std.testing.expect(state.inbound.inbound_eof);
}

test "byte stream cleanup releases outbound buffer" {
    var state = StreamState.init(std.testing.allocator, "p-test", "host", 22);
    try state.appendOutbound("abc");
    state.deinit();
}
