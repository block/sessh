const std = @import("std");
const builtin = @import("builtin");

const non_suspending_timer = @import("../core/non_suspending_timer.zig");

pub const resize_timeout_ms: u64 = 1_000;

var next_request_seq: u64 = 1;

pub const Pending = struct {
    const Kind = enum {
        none,
        generic,
        resize,
    };

    repaint_request_seq: u64 = 0,
    kind: Kind = .none,
    started_at_ms: u64 = 0,

    pub fn active(self: Pending) bool {
        return self.repaint_request_seq != 0;
    }

    pub fn start(self: *Pending) u64 {
        return self.startInner(.generic, nowMs());
    }

    pub fn startResize(self: *Pending) u64 {
        return self.startInner(.resize, nowMs());
    }

    pub fn startResizeAt(self: *Pending, now_ms: u64) u64 {
        return self.startInner(.resize, now_ms);
    }

    fn startInner(self: *Pending, kind: Kind, now_ms: u64) u64 {
        self.repaint_request_seq = allocateRequestSeq();
        self.kind = kind;
        self.started_at_ms = now_ms;
        return self.repaint_request_seq;
    }

    pub fn matches(self: Pending, repaint_request_seq: u64) bool {
        return self.repaint_request_seq == repaint_request_seq;
    }

    pub fn resizeTimedOut(self: Pending) bool {
        return self.resizeTimedOutAt(nowMs());
    }

    pub fn resizeTimedOutAt(self: Pending, now_ms: u64) bool {
        if (!self.active() or self.kind != .resize) return false;
        return now_ms -| self.started_at_ms >= resize_timeout_ms;
    }

    pub fn requiresRepaintForRecovery(self: Pending) bool {
        return self.active() and self.kind == .resize;
    }

    pub fn clear(self: *Pending) void {
        self.repaint_request_seq = 0;
        self.kind = .none;
        self.started_at_ms = 0;
    }
};

pub fn allocateRequestSeq() u64 {
    const seq = next_request_seq;
    next_request_seq +%= 1;
    if (next_request_seq == 0) next_request_seq = 1;
    return seq;
}

fn nowMs() u64 {
    return non_suspending_timer.nowMs() catch {
        const ms = std.time.milliTimestamp();
        if (ms < 0) return 0;
        return @intCast(ms);
    };
}

pub const testing = if (builtin.is_test) struct {
    pub fn setNextRequestSeq(seq: u64) void {
        next_request_seq = if (seq == 0) 1 else seq;
    }
} else struct {};

test "resize repaint timeout waits for short grace period" {
    var pending = Pending{};
    _ = pending.startResizeAt(1_000);

    try std.testing.expect(pending.requiresRepaintForRecovery());
    try std.testing.expect(!pending.resizeTimedOutAt(1_999));
    try std.testing.expect(pending.resizeTimedOutAt(2_000));

    pending.clear();
    try std.testing.expect(!pending.requiresRepaintForRecovery());
    try std.testing.expect(!pending.resizeTimedOutAt(3_000));
}
