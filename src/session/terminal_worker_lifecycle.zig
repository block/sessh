const std = @import("std");

const attached_client_router = @import("attached_client_router.zig");
const remote_process = @import("remote_process.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");

const AttachedClient = attached_client_router.AttachedClient;
const Session = terminal_worker_state.Session;

pub const PollTiming = struct {
    synchronized_output_max_hold_ms: i64 = 1000,
    pty_hangup_reap_poll_ms: i64 = remote_process.pty_hangup_reap_poll_ms,
    pty_eof_exit_reap_poll_ms: i64 = 1,
    pty_eof_exit_status_grace_ms: i64 = 250,
};

pub fn pollTimeoutMs(
    session: *const Session,
    attached_client: *const AttachedClient,
    now_ms: i64,
    now_unix_ms: u64,
    timing: PollTiming,
) i32 {
    var timeout_ms: ?i64 = null;
    if (attached_client.active and attached_client.debug_unresponsive_until_ms > now_ms) {
        const remaining_ms = attached_client.debug_unresponsive_until_ms - now_ms;
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    if (session.alive and session.synchronized_output_since_ms != 0) {
        const elapsed_ms = now_ms - session.synchronized_output_since_ms;
        const remaining_ms = timing.synchronized_output_max_hold_ms - elapsed_ms;
        const clamped_remaining_ms = @max(remaining_ms, 0);
        if (timeout_ms == null or clamped_remaining_ms < timeout_ms.?) timeout_ms = clamped_remaining_ms;
    }
    if (session.alive and session.process.pty_closed_for_hangup) {
        if (timeout_ms == null or timing.pty_hangup_reap_poll_ms < timeout_ms.?) timeout_ms = timing.pty_hangup_reap_poll_ms;
    }
    if (session.alive and session.pty_eof_wait_started_ms != 0) {
        const elapsed_ms = now_ms - session.pty_eof_wait_started_ms;
        const remaining_grace_ms = @max(timing.pty_eof_exit_status_grace_ms - elapsed_ms, 0);
        const remaining_ms = @min(timing.pty_eof_exit_reap_poll_ms, remaining_grace_ms);
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    if (sessionReapEnabled(session)) {
        const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
        const remaining_ms: i64 = if (deadline_ms <= now_unix_ms)
            0
        else
            @intCast(@min(deadline_ms - now_unix_ms, @as(u64, @intCast(std.math.maxInt(i64)))));
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    const ms = timeout_ms orelse return -1;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

pub fn sessionReapEnabled(session: *const Session) bool {
    return session.alive and
        !session.attached and
        session.disconnected_at_unix_ms != 0 and
        session.reap_ms != 0;
}

pub fn shouldReapDisconnected(session: *const Session, now_unix_ms: u64) bool {
    if (!sessionReapEnabled(session)) return false;
    const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
    return now_unix_ms >= deadline_ms;
}

pub fn applyAttachedState(session: *Session, now_attached: bool, now_unix_ms: u64) void {
    if (!session.alive) {
        session.attached = false;
        return;
    }

    const was_attached = session.attached;
    session.attached = now_attached;
    if (now_attached) {
        session.disconnected_at_unix_ms = 0;
    } else if (was_attached or session.disconnected_at_unix_ms == 0) {
        session.disconnected_at_unix_ms = now_unix_ms;
    }
}

test "terminal worker lifecycle poll timeout includes reap deadline" {
    var session = Session{
        .alive = true,
        .attached = false,
        .disconnected_at_unix_ms = 1_000,
        .reap_ms = 5_000,
    };
    const attached_client = AttachedClient{};

    try std.testing.expectEqual(@as(i32, 5_000), pollTimeoutMs(&session, &attached_client, 0, 1_000, .{}));
    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(&session, &attached_client, 0, 5_999, .{}));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(&session, &attached_client, 0, 6_000, .{}));

    session.attached = true;
    try std.testing.expectEqual(@as(i32, -1), pollTimeoutMs(&session, &attached_client, 0, 6_000, .{}));
}

test "terminal worker lifecycle poll timeout wakes to reap pty hangup" {
    const session = Session{
        .alive = true,
        .process = .{ .pty_closed_for_hangup = true },
    };
    const attached_client = AttachedClient{};

    try std.testing.expectEqual(@as(i32, remote_process.pty_hangup_reap_poll_ms), pollTimeoutMs(&session, &attached_client, 0, 0, .{}));
}

test "terminal worker lifecycle poll timeout wakes while pty eof awaits exit status" {
    const session = Session{
        .alive = true,
        .pty_eof_wait_started_ms = 10,
    };
    const attached_client = AttachedClient{};

    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(&session, &attached_client, 10, 0, .{}));
    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(&session, &attached_client, 259, 0, .{}));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(&session, &attached_client, 260, 0, .{}));
}

test "terminal worker lifecycle tracks attached transitions" {
    var session = Session{ .alive = true, .attached = true };
    applyAttachedState(&session, false, 42);
    try std.testing.expect(!session.attached);
    try std.testing.expectEqual(@as(u64, 42), session.disconnected_at_unix_ms);

    applyAttachedState(&session, true, 50);
    try std.testing.expect(session.attached);
    try std.testing.expectEqual(@as(u64, 0), session.disconnected_at_unix_ms);
}
