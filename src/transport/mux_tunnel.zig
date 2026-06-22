// Shared mux helpers for daemon-to-daemon tunnels. One SSH connection carries
// many independent byte streams, each identified by `MuxStreamFrame.stream_id`;
// daemon/tunnel.zig owns the per-stream handler state.
const std = @import("std");

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
    return encodeMuxStreamFrameBytes(allocator, protocol.muxStreamOpenFrame(stream_id, recv_next_offset));
}

pub fn encodeAckPayload(
    allocator: std.mem.Allocator,
    stream_id: u64,
    recv_next_offset: u64,
) ![]u8 {
    return encodeMuxStreamPayload(allocator, protocol.muxStreamAckFrame(stream_id, recv_next_offset));
}

pub fn encodeOpenOkPayload(
    allocator: std.mem.Allocator,
    stream_id: u64,
    recv_next_offset: u64,
) ![]u8 {
    return encodeMuxStreamPayload(allocator, protocol.muxStreamOpenOkFrame(stream_id, recv_next_offset));
}

test "stream id allocator starts at one and advances" {
    var allocator = StreamIdAllocator{};
    try std.testing.expectEqual(@as(u64, 1), allocator.take());
    try std.testing.expectEqual(@as(u64, 2), allocator.take());
}
