// Pure lifecycle decisions for terminal workers. The worker loop supplies a
// clock and connection/process state; this module returns poll deadlines and
// state transitions that are easy to unit-test.
const std = @import("std");

const visible_client_router = @import("visible_client_router.zig");
const remote_process = @import("remote_process.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");

const VisibleClient = visible_client_router.VisibleClient;
const Session = terminal_worker_state.Session;

pub const PollTiming = struct {
    synchronized_output_max_hold_ms: i64 = 1000,
    pty_hangup_reap_poll_ms: i64 = remote_process.pty_hangup_reap_poll_ms,
    pty_eof_exit_reap_poll_ms: i64 = 1,
    pty_eof_exit_status_grace_ms: i64 = 250,
};

pub const PollClock = struct {
    monotonic_ms: i64,
    unix_ms: u64,
};

pub const PollTimeoutOptions = struct {
    session: *const Session,
    visible_client: *const VisibleClient,
    clock: PollClock,
    timing: PollTiming = .{},
};

pub fn pollTimeoutMs(options: PollTimeoutOptions) i32 {
    // The terminal worker is event-driven; this computes the next time it must
    // wake even if no fd changes. The minimum deadline wins so synchronized
    // output, PTY reap checks, debug unresponsive state, and disconnected reap
    // policy can share one dispatcher timeout.
    const session = options.session;
    const visible_client = options.visible_client;
    const clock = options.clock;
    const timing = options.timing;
    var timeout_ms: ?i64 = null;

    // Every branch below contributes one possible wakeup time.
    if (visible_client.active and visible_client.debug_unresponsive_until_ms > clock.monotonic_ms) {
        const remaining_ms = visible_client.debug_unresponsive_until_ms - clock.monotonic_ms;
        includeEarlierTimeout(&timeout_ms, remaining_ms);
    }
    if (session.alive and session.synchronized_output_since_ms != 0) {
        const elapsed_ms = clock.monotonic_ms - session.synchronized_output_since_ms;
        const remaining_ms = timing.synchronized_output_max_hold_ms - elapsed_ms;
        includeEarlierTimeout(&timeout_ms, @max(remaining_ms, 0));
    }
    if (session.alive and session.process.pty_closed_for_hangup) {
        includeEarlierTimeout(&timeout_ms, timing.pty_hangup_reap_poll_ms);
    }
    if (session.alive and session.pty_eof_wait_started_ms != 0) {
        const elapsed_ms = clock.monotonic_ms - session.pty_eof_wait_started_ms;
        const remaining_grace_ms = @max(timing.pty_eof_exit_status_grace_ms - elapsed_ms, 0);
        const remaining_ms = @min(timing.pty_eof_exit_reap_poll_ms, remaining_grace_ms);
        includeEarlierTimeout(&timeout_ms, remaining_ms);
    }
    if (sessionReapEnabled(session)) {
        const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
        const remaining_ms: i64 = if (deadline_ms <= clock.unix_ms)
            0
        else
            @intCast(@min(deadline_ms - clock.unix_ms, @as(u64, @intCast(std.math.maxInt(i64)))));
        includeEarlierTimeout(&timeout_ms, remaining_ms);
    }
    const ms = timeout_ms orelse return -1;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

fn includeEarlierTimeout(timeout_ms: *?i64, candidate_ms: i64) void {
    if (timeout_ms.* == null or candidate_ms < timeout_ms.*.?) timeout_ms.* = candidate_ms;
}

fn sessionReapEnabled(session: *const Session) bool {
    return session.alive and
        !session.visible_client_connected and
        session.disconnected_at_unix_ms != 0 and
        session.reap_ms != 0;
}

pub fn shouldReapDisconnected(session: *const Session, now_unix_ms: u64) bool {
    if (!sessionReapEnabled(session)) return false;
    const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
    return now_unix_ms >= deadline_ms;
}

pub const ApplyVisibleClientConnectionStateOptions = struct {
    session: *Session,
    now_connected: bool,
    now_unix_ms: u64,
};

pub fn applyVisibleClientConnectionState(options: ApplyVisibleClientConnectionStateOptions) void {
    const session = options.session;
    if (!session.alive) {
        session.visible_client_connected = false;
        return;
    }

    const was_connected = session.visible_client_connected;
    session.visible_client_connected = options.now_connected;
    if (options.now_connected) {
        session.disconnected_at_unix_ms = 0;
    } else if (was_connected or session.disconnected_at_unix_ms == 0) {
        session.disconnected_at_unix_ms = options.now_unix_ms;
    }
}

test "terminal worker lifecycle poll timeout includes reap deadline" {
    var session = Session{
        .alive = true,
        .visible_client_connected = false,
        .disconnected_at_unix_ms = 1_000,
        .reap_ms = 5_000,
    };
    const visible_client = VisibleClient{};

    try std.testing.expectEqual(@as(i32, 5_000), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 0, .unix_ms = 1_000 },
    }));
    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 0, .unix_ms = 5_999 },
    }));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 0, .unix_ms = 6_000 },
    }));

    session.visible_client_connected = true;
    try std.testing.expectEqual(@as(i32, -1), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 0, .unix_ms = 6_000 },
    }));
}

test "terminal worker lifecycle poll timeout wakes to reap pty hangup" {
    const session = Session{
        .alive = true,
        .process = .{ .pty_closed_for_hangup = true },
    };
    const visible_client = VisibleClient{};

    try std.testing.expectEqual(@as(i32, remote_process.pty_hangup_reap_poll_ms), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 0, .unix_ms = 0 },
    }));
}

test "terminal worker lifecycle poll timeout wakes while pty eof awaits exit status" {
    const session = Session{
        .alive = true,
        .pty_eof_wait_started_ms = 10,
    };
    const visible_client = VisibleClient{};

    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 10, .unix_ms = 0 },
    }));
    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 259, .unix_ms = 0 },
    }));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(.{
        .session = &session,
        .visible_client = &visible_client,
        .clock = .{ .monotonic_ms = 260, .unix_ms = 0 },
    }));
}

test "terminal worker lifecycle tracks visible client connection transitions" {
    var session = Session{ .alive = true, .visible_client_connected = true };
    applyVisibleClientConnectionState(.{
        .session = &session,
        .now_connected = false,
        .now_unix_ms = 42,
    });
    try std.testing.expect(!session.visible_client_connected);
    try std.testing.expectEqual(@as(u64, 42), session.disconnected_at_unix_ms);

    applyVisibleClientConnectionState(.{
        .session = &session,
        .now_connected = true,
        .now_unix_ms = 50,
    });
    try std.testing.expect(session.visible_client_connected);
    try std.testing.expectEqual(@as(u64, 0), session.disconnected_at_unix_ms);
}
