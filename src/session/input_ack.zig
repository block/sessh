const std = @import("std");

pub const Tracker = struct {
    next_seq: u64 = 1,
    last_sent_seq: u64 = 0,
    last_acked_seq: u64 = 0,
    paste_like_sent_seq: u64 = 0,

    pub fn allocate(self: *Tracker, paste_like: bool) u64 {
        const seq = self.next_seq;
        self.last_sent_seq = seq;
        if (paste_like) self.paste_like_sent_seq = seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return seq;
    }

    pub fn acknowledge(self: *Tracker, input_seq: u64) bool {
        if (input_seq <= self.last_acked_seq) return false;
        self.last_acked_seq = input_seq;
        if (self.paste_like_sent_seq <= self.last_acked_seq) self.paste_like_sent_seq = 0;
        return true;
    }

    pub fn pending(self: Tracker) bool {
        return self.last_sent_seq > self.last_acked_seq;
    }

    pub fn pendingPasteLike(self: Tracker) bool {
        return self.paste_like_sent_seq > self.last_acked_seq;
    }

    pub fn discardPending(self: *Tracker) void {
        self.last_acked_seq = self.last_sent_seq;
        self.paste_like_sent_seq = 0;
    }
};

pub const AckResult = struct {
    progressed: bool,
    still_pending: bool,
};

pub fn acknowledge(tracker: *Tracker, input_seq: u64) AckResult {
    return .{
        .progressed = tracker.acknowledge(input_seq),
        .still_pending = tracker.pending(),
    };
}

test "input ack tracker records pending and acknowledged input" {
    var tracker = Tracker{};
    try std.testing.expect(!tracker.pending());
    const first = tracker.allocate(false);
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expect(tracker.pending());
    try std.testing.expect(tracker.acknowledge(first));
    try std.testing.expect(!tracker.pending());
    const second = tracker.allocate(false);
    _ = second;
    try std.testing.expect(!tracker.acknowledge(first));
    try std.testing.expect(tracker.pending());
    tracker.discardPending();
    try std.testing.expect(!tracker.pending());
}

test "input ack tracker records pending paste-like input" {
    var tracker = Tracker{};
    const normal = tracker.allocate(false);
    try std.testing.expect(!tracker.pendingPasteLike());
    const pasted = tracker.allocate(true);
    try std.testing.expect(tracker.pendingPasteLike());
    try std.testing.expect(tracker.acknowledge(normal));
    try std.testing.expect(tracker.pendingPasteLike());
    try std.testing.expect(tracker.acknowledge(pasted));
    try std.testing.expect(!tracker.pendingPasteLike());
}
