const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const client_config = @import("client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_renderer = @import("renderer.zig");
const client_ui = @import("client_ui.zig");
const io_helpers = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;
const WindowSize = terminal.WindowSize;

var next_repaint_request_seq: u64 = 1;

const unknown_viewport_offset: i32 = -1;
const ErrorPayload = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

pub const AttachedClientEnd = enum {
    detach,
    unresponsive,
    transport_closed,
    session_ended,
};

pub const ReconnectInputPumpResult = enum {
    wait_elapsed,
    reconnect_now,
    detach,
    transport_closed,
};

pub const RuntimeRecovery = enum {
    recovered,
    transport_closed,
    session_ended,
    detach,
};

pub const AttachedClientOptions = struct {
    monitor_connection: bool = false,
    responsiveness_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
};

const input_chunk_bytes = 1024;
const default_responsiveness_timeout_ms: i64 = 5_000;
const max_responsiveness_timeout_ms: i64 = 15_000;
const resize_repaint_timeout_ms: i64 = 1_000;
const paste_like_single_read_bytes = 32;
const paste_like_window_bytes = 64;
const paste_like_window_ms: i64 = 250;

const ConnectionMonitor = struct {
    enabled: bool = false,
    any_response_wait_started_ms: ?i64 = null,
    smoothed_rtt_ms: ?i64 = null,
    rtt_variance_ms: i64 = 0,
    responsiveness_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    clock: ?std.time.Timer = null,

    fn afterInput(self: *ConnectionMonitor) void {
        if (!self.enabled) return;
        const now = self.nowMs();
        self.afterInputAt(now);
    }

    fn afterInputAt(self: *ConnectionMonitor, now: i64) void {
        if (!self.enabled) return;
        if (self.any_response_wait_started_ms == null) {
            self.any_response_wait_started_ms = now;
        }
    }

    fn noteInputAckProgress(self: *ConnectionMonitor, still_pending: bool) void {
        if (self.any_response_wait_started_ms) |started| {
            const now = self.nowMs();
            const rtt_ms = @max(now - started, 0);
            self.updateRtt(rtt_ms);
            self.any_response_wait_started_ms = if (still_pending) now else null;
            return;
        }
        self.any_response_wait_started_ms = if (still_pending) self.nowMs() else null;
    }

    fn updateRtt(self: *ConnectionMonitor, rtt_ms: i64) void {
        if (self.smoothed_rtt_ms) |srtt| {
            const delta = if (rtt_ms > srtt) rtt_ms - srtt else srtt - rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(3 * self.rtt_variance_ms + delta, 4), 1);
            self.smoothed_rtt_ms = @divTrunc(7 * srtt + rtt_ms, 8);
        } else {
            self.smoothed_rtt_ms = rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(rtt_ms, 2), 1);
        }
    }

    fn pollTimeoutMs(self: *ConnectionMonitor) i32 {
        if (!self.enabled) return 100;
        const started = self.any_response_wait_started_ms orelse return 100;
        const elapsed = self.nowMs() - started;
        const remaining = self.responsivenessTimeoutMs() - elapsed;
        if (remaining <= 0) return 0;
        return @intCast(@min(@as(i64, 100), remaining));
    }

    fn isUnresponsive(self: *ConnectionMonitor) bool {
        return self.isUnresponsiveAt(self.nowMs());
    }

    fn isUnresponsiveAt(self: *const ConnectionMonitor, now: i64) bool {
        if (!self.enabled) return false;
        const started = self.any_response_wait_started_ms orelse return false;
        return now - started >= self.responsivenessTimeoutMs();
    }

    fn responsivenessTimeoutMs(self: *const ConnectionMonitor) i64 {
        // TCP-style adaptive timeout: smoothed RTT plus variance, bounded so a
        // single retransmit-scale delay does not immediately force reconnect.
        const timeout = if (self.smoothed_rtt_ms) |srtt|
            srtt + 4 * self.rtt_variance_ms
        else
            default_responsiveness_timeout_ms;
        const floor = @min(max_responsiveness_timeout_ms, @max(default_responsiveness_timeout_ms, self.responsiveness_timeout_floor_ms));
        return @min(max_responsiveness_timeout_ms, @max(floor, timeout));
    }

    fn nowMs(self: *ConnectionMonitor) i64 {
        if (self.clock == null) {
            self.clock = std.time.Timer.start() catch return std.time.milliTimestamp();
        }
        return if (self.clock) |*timer|
            @intCast(timer.read() / std.time.ns_per_ms)
        else
            std.time.milliTimestamp();
    }
};

const PasteLikeInputClassifier = struct {
    window_started_ms: ?i64 = null,
    window_bytes: usize = 0,
    clock: ?std.time.Timer = null,

    fn classify(self: *PasteLikeInputClassifier, forwarded_bytes: usize) bool {
        if (forwarded_bytes == 0) return false;
        // TODO: Detect bracketed paste delimiters here once client input
        // parsing tracks them explicitly.
        if (forwarded_bytes >= paste_like_single_read_bytes) return true;

        const now = self.nowMs();
        if (self.window_started_ms) |started| {
            if (now - started <= paste_like_window_ms) {
                self.window_bytes += forwarded_bytes;
            } else {
                self.window_started_ms = now;
                self.window_bytes = forwarded_bytes;
            }
        } else {
            self.window_started_ms = now;
            self.window_bytes = forwarded_bytes;
        }

        return self.window_bytes >= paste_like_window_bytes;
    }

    fn nowMs(self: *PasteLikeInputClassifier) i64 {
        if (self.clock == null) {
            self.clock = std.time.Timer.start() catch return std.time.milliTimestamp();
        }
        return if (self.clock) |*timer|
            @intCast(timer.read() / std.time.ns_per_ms)
        else
            std.time.milliTimestamp();
    }
};

const max_scrollback_cursor_bytes = 64;

pub const ScrollbackCursor = struct {
    bytes: [max_scrollback_cursor_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ScrollbackCursor) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *ScrollbackCursor, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len) return error.ScrollbackCursorTooLarge;
        @memcpy(self.bytes[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

const PendingRepaint = struct {
    const Kind = enum {
        none,
        generic,
        resize,
    };

    repaint_request_seq: u64 = 0,
    kind: Kind = .none,
    started_at_unix_ms: i64 = 0,

    fn active(self: PendingRepaint) bool {
        return self.repaint_request_seq != 0;
    }

    fn start(self: *PendingRepaint) u64 {
        return self.startInner(.generic, std.time.milliTimestamp());
    }

    fn startResize(self: *PendingRepaint) u64 {
        return self.startInner(.resize, std.time.milliTimestamp());
    }

    fn startResizeAt(self: *PendingRepaint, now_ms: i64) u64 {
        return self.startInner(.resize, now_ms);
    }

    fn startInner(self: *PendingRepaint, kind: Kind, now_ms: i64) u64 {
        self.repaint_request_seq = allocateRepaintRequestSeq();
        self.kind = kind;
        self.started_at_unix_ms = now_ms;
        return self.repaint_request_seq;
    }

    fn matches(self: PendingRepaint, repaint_request_seq: u64) bool {
        return self.repaint_request_seq == repaint_request_seq;
    }

    fn resizeTimedOut(self: PendingRepaint, now_ms: i64) bool {
        if (!self.active() or self.kind != .resize) return false;
        return now_ms - self.started_at_unix_ms >= resize_repaint_timeout_ms;
    }

    fn requiresRepaintForRecovery(self: PendingRepaint) bool {
        return self.active() and self.kind == .resize;
    }

    fn clear(self: *PendingRepaint) void {
        self.repaint_request_seq = 0;
        self.kind = .none;
        self.started_at_unix_ms = 0;
    }
};

/// Client-side state carried across runtime transports for one attached session.
pub const RuntimeSession = struct {
    const max_title_fallback_bytes = 512;

    guid: [session_registry.session_guid_len]u8 = [_]u8{0} ** session_registry.session_guid_len,
    guid_len: usize = 0,
    session_dir: [4096]u8 = [_]u8{0} ** 4096,
    session_dir_len: usize = 0,
    scrollback_cursor: ScrollbackCursor = .{},
    viewport_offset: i32 = 0,
    /// Latest outstanding RepaintRequest sequence. Older responses are stale.
    pending_repaint: PendingRepaint = .{},
    attached_client_end_restore: std.ArrayList(u8) = .empty,
    unresponsive_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    input_ack_tracker: InputAckTracker = .{},
    input_escape_filter: terminal.EscapeFilter = .{},
    paste_like_input_classifier: PasteLikeInputClassifier = .{},
    ended_process_exit_code: ?u8 = null,
    /// Local-only fallback for the terminal title while this session is active.
    /// For remote sessh this is the host string the user passed locally. We do
    /// not send it to the session agent because ssh aliases can reveal local
    /// naming that the remote machine would not otherwise know.
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,
    /// Most recent app-title presence bit from Draw/RepaintResponse. True means
    /// the app owns the title, even if it set it to an empty string.
    app_title_present: ?bool = null,

    pub fn adoptReconnectState(self: *RuntimeSession, reconnected: *const RuntimeSession) void {
        self.pending_repaint = reconnected.pending_repaint;
    }

    pub fn noteUnresponsiveRecovery(self: *RuntimeSession) void {
        self.unresponsive_timeout_floor_ms = @min(
            max_responsiveness_timeout_ms,
            @max(default_responsiveness_timeout_ms, self.unresponsive_timeout_floor_ms * 2),
        );
    }

    pub fn hasPendingInputAck(self: *const RuntimeSession) bool {
        return self.input_ack_tracker.pending();
    }

    pub fn hasPendingPasteLikeInputAck(self: *const RuntimeSession) bool {
        return self.input_ack_tracker.pendingPasteLike();
    }

    pub fn discardPendingInputAcks(self: *RuntimeSession) void {
        self.input_ack_tracker.discardPending();
    }

    pub fn restoreAttachedClientEndPresentation(self: *RuntimeSession) void {
        restoreAttachedClientEndPresentationBytes(&self.attached_client_end_restore);
    }

    pub fn restoreAttachedClientEndPresentationForExit(self: *RuntimeSession) void {
        self.restoreAttachedClientEndPresentation();
        restoreLocalTerminalPresentation();
    }

    pub fn deinit(self: *RuntimeSession) void {
        self.attached_client_end_restore.deinit(app_allocator.allocator());
        self.attached_client_end_restore = .empty;
    }

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const RuntimeSession) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn titleFallbackSlice(self: *const RuntimeSession) []const u8 {
        if (self.title_fallback_len > 0) return self.title_fallback[0..self.title_fallback_len];
        return self.idSlice();
    }

    pub fn sessionDirSlice(self: *const RuntimeSession) []const u8 {
        return self.session_dir[0..self.session_dir_len];
    }

    pub fn setSessionDir(self: *RuntimeSession, session_dir: []const u8) !void {
        if (session_dir.len == 0) {
            self.session_dir_len = 0;
            return;
        }
        if (!std.mem.startsWith(u8, session_dir, "/")) return error.InvalidSessionDir;
        if (session_dir.len > self.session_dir.len) return error.SessionDirTooLarge;
        @memcpy(self.session_dir[0..session_dir.len], session_dir);
        self.session_dir_len = session_dir.len;
    }

    pub fn setTitleFallback(self: *RuntimeSession, title: []const u8) void {
        self.title_fallback_len = copyTitleFallback(&self.title_fallback, title);
    }

    pub fn setIdentity(self: *RuntimeSession, guid: []const u8) !void {
        if (guid.len > self.guid.len) return error.SessionGuidTooLarge;
        @memcpy(self.guid[0..guid.len], guid);
        self.guid_len = guid.len;
        tty_transcript.setSessionGuid(guid);
    }

    fn recordSessionEndedPayload(self: *RuntimeSession, payload: []const u8) !void {
        var ended = try protocol.decodePayload(pb.TeSessionEnded, app_allocator.allocator(), payload);
        defer ended.deinit(app_allocator.allocator());
        self.ended_process_exit_code = processExitCodeFromSessionEnded(ended);
    }

    pub fn endedProcessExitCode(self: *const RuntimeSession) u8 {
        return self.ended_process_exit_code orelse 0;
    }
};

fn processExitCodeFromSessionEnded(ended: pb.TeSessionEnded) u8 {
    const status = ended.exit_status orelse return 0;
    return switch (status.kind) {
        .EXIT_STATUS_KIND_EXITED => if (status.status >= 0 and status.status <= 255) @intCast(status.status) else 255,
        .EXIT_STATUS_KIND_SIGNALLED => if (status.status >= 0 and status.status <= 127) @intCast(128 + status.status) else 255,
        else => 0,
    };
}

pub fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn copyTitleFallback(dest: []u8, title: []const u8) usize {
    const len = @min(dest.len, title.len);
    @memcpy(dest[0..len], title[0..len]);
    return len;
}

const InputAckTracker = struct {
    next_seq: u64 = 1,
    last_sent_seq: u64 = 0,
    last_acked_seq: u64 = 0,
    paste_like_sent_seq: u64 = 0,

    fn allocate(self: *InputAckTracker, paste_like: bool) u64 {
        const seq = self.next_seq;
        self.last_sent_seq = seq;
        if (paste_like) self.paste_like_sent_seq = seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return seq;
    }

    fn acknowledge(self: *InputAckTracker, input_seq: u64) bool {
        if (input_seq <= self.last_acked_seq) return false;
        self.last_acked_seq = input_seq;
        if (self.paste_like_sent_seq <= self.last_acked_seq) self.paste_like_sent_seq = 0;
        return true;
    }

    fn pending(self: InputAckTracker) bool {
        return self.last_sent_seq > self.last_acked_seq;
    }

    fn pendingPasteLike(self: InputAckTracker) bool {
        return self.paste_like_sent_seq > self.last_acked_seq;
    }

    fn discardPending(self: *InputAckTracker) void {
        self.last_acked_seq = self.last_sent_seq;
        self.paste_like_sent_seq = 0;
    }
};

const DrawPayload = struct {
    scrollback_cursor: []const u8,
    viewport_offset: i32,
    draw_bytes: []const u8,
    app_title_present: ?bool,
    attached_client_end_restore_bytes: ?[]const u8,
};

test "connection monitor starts responsiveness wait after input" {
    var monitor = ConnectionMonitor{ .enabled = true };

    monitor.afterInputAt(1_000);
    try std.testing.expectEqual(@as(?i64, 1_000), monitor.any_response_wait_started_ms);
    try std.testing.expect(!monitor.isUnresponsiveAt(5_999));
    try std.testing.expect(monitor.isUnresponsiveAt(6_000));
}

test "runtime session backs off unresponsive floor after recovery" {
    var session = RuntimeSession{};
    try std.testing.expectEqual(default_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(@as(i64, 10_000), session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
}

test "connection monitor clears responsiveness wait after input ack progress" {
    var monitor = ConnectionMonitor{ .enabled = true };

    monitor.afterInputAt(1_000);
    try std.testing.expectEqual(@as(?i64, 1_000), monitor.any_response_wait_started_ms);

    monitor.noteInputAckProgress(false);
    try std.testing.expectEqual(@as(?i64, null), monitor.any_response_wait_started_ms);
}

test "input ack tracker records pending and acknowledged input" {
    var tracker = InputAckTracker{};
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
    var tracker = InputAckTracker{};
    const normal = tracker.allocate(false);
    try std.testing.expect(!tracker.pendingPasteLike());
    const pasted = tracker.allocate(true);
    try std.testing.expect(tracker.pendingPasteLike());
    try std.testing.expect(tracker.acknowledge(normal));
    try std.testing.expect(tracker.pendingPasteLike());
    try std.testing.expect(tracker.acknowledge(pasted));
    try std.testing.expect(!tracker.pendingPasteLike());
}

test "paste-like input classifier uses read size and short rolling window" {
    var classifier = PasteLikeInputClassifier{};
    try std.testing.expect(!classifier.classify(31));

    var large_read = PasteLikeInputClassifier{};
    try std.testing.expect(large_read.classify(32));

    var window = PasteLikeInputClassifier{};
    try std.testing.expect(!window.classify(20));
    try std.testing.expect(!window.classify(20));
    try std.testing.expect(window.classify(24));
}

test "resize repaint timeout waits for short grace period" {
    var pending = PendingRepaint{};
    _ = pending.startResizeAt(1_000);

    try std.testing.expect(pending.requiresRepaintForRecovery());
    try std.testing.expect(!pending.resizeTimedOut(1_999));
    try std.testing.expect(pending.resizeTimedOut(2_000));

    pending.clear();
    try std.testing.expect(!pending.requiresRepaintForRecovery());
    try std.testing.expect(!pending.resizeTimedOut(3_000));
}

test "resize repaint timeout clears stale attached client display and enters unresponsive state" {
    var pending = PendingRepaint{};
    _ = pending.startResizeAt(1_000);
    var viewport_offset: i32 = 7;

    try std.testing.expectEqual(
        @as(?AttachedClientEnd, null),
        checkResizeRepaintTimeout(&pending, &viewport_offset, 1_999),
    );
    try std.testing.expectEqual(@as(i32, 7), viewport_offset);

    try std.testing.expectEqual(
        AttachedClientEnd.unresponsive,
        checkResizeRepaintTimeout(&pending, &viewport_offset, 2_000).?,
    );
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);
    try std.testing.expect(pending.requiresRepaintForRecovery());
}

test "attached client drains pending session end before monitor timeout" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    const draw = try protocol.encodePayload(app_allocator.allocator(), pb.TeDraw{
        .scrollback_cursor = "cursor-v1",
    });
    defer app_allocator.allocator().free(draw);
    try protocol.sendFrame(remote_to_client[1], .te_draw, draw);

    const session_ended = try protocol.encodePayload(app_allocator.allocator(), pb.TeSessionEnded{
        .reason = .TE_SESSION_END_REASON_PROCESS_EXITED,
    });
    defer app_allocator.allocator().free(session_ended);
    try protocol.sendFrame(remote_to_client[1], .te_session_ended, session_ended);

    var presentation_guard = client_renderer.PresentationGuard.init(1);
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};

    try std.testing.expectEqual(
        AttachedClientEnd.session_ended,
        try runAttachedTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &attached_client_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            null,
            &app_title_present,
            .{ .monitor_connection = true },
        ),
    );
}

test "attached client treats input write failure as transport closed" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    var presentation_guard = client_renderer.PresentationGuard.init(1);
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};
    var app_title_present: ?bool = null;

    try io_helpers.writeAll(input[1], "typed");

    try std.testing.expectEqual(
        AttachedClientEnd.transport_closed,
        try runAttachedTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &attached_client_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            null,
            &app_title_present,
            .{ .monitor_connection = true },
        ),
    );
}

test "attached client keeps attached-client-end restore bytes while reconnecting" {
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    try attached_client_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    try std.testing.expectEqual(AttachedClientEnd.transport_closed, finishAttachedClient(.transport_closed, &attached_client_end_restore));
    try std.testing.expectEqualStrings("restore-primary", attached_client_end_restore.items);

    try std.testing.expectEqual(AttachedClientEnd.unresponsive, finishAttachedClient(.unresponsive, &attached_client_end_restore));
    try std.testing.expectEqualStrings("restore-primary", attached_client_end_restore.items);
}

test "final attached-client-end restore writes and clears saved cleanup bytes" {
    const output = try posix.pipe();
    defer posix.close(output[0]);
    defer posix.close(output[1]);

    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    try attached_client_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    restoreAttachedClientEndPresentationBytesToFd(output[1], &attached_client_end_restore);

    var pollfds = [_]posix.pollfd{.{
        .fd = output[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 1000));

    var buf: [64]u8 = undefined;
    const n = c.read(output[0], &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("restore-primary", buf[0..@intCast(n)]);
    try std.testing.expectEqual(@as(usize, 0), attached_client_end_restore.items.len);
}

test "cancelled reconnect frame read returns without input" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ReconnectDetached, readFrameAllocMaybeCancelled(fds[0], &cancelled));
}

test "draw payload preserves app title presence bit" {
    const draw = try drawPayloadFromMessage(.{
        .scrollback_cursor = "opaque-cursor",
        .draw_bytes = "",
        .app_title_present = false,
    });
    defer freeDrawPayload(draw);

    try std.testing.expect(draw.app_title_present != null);
    try std.testing.expect(!draw.app_title_present.?);
}

test "draw payload updates runtime app title presence state" {
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var app_title_present: ?bool = null;

    try handleDrawPayload(.{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .app_title_present = false,
        .attached_client_end_restore_bytes = null,
    }, null, &scrollback_cursor, &viewport_offset, &app_title_present);

    try std.testing.expect(app_title_present != null);
    try std.testing.expect(!app_title_present.?);
}

test "recovery polling stores attached-client-end restore bytes from draw" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.attached_client_end_restore.deinit(app_allocator.allocator());

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeDraw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .attached_client_end_restore_bytes = "restore-primary",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .te_draw, payload);

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.attached_client_end_restore.items);
}

test "recovery polling ignores draw while repaint is outstanding" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{ .pending_repaint = .{ .repaint_request_seq = 7 } };
    defer session.attached_client_end_restore.deinit(app_allocator.allocator());

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeDraw{
        .scrollback_cursor = "stale-cursor",
        .viewport_offset = 3,
        .draw_bytes = "",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .te_draw, payload);

    try std.testing.expectEqual(@as(?RuntimeRecovery, null), try pollRuntimeRecovery(fds[0], &session, 0));
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);
    try std.testing.expect(session.pending_repaint.active());
}

test "recovery polling waits for resize repaint after input ack" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.attached_client_end_restore.deinit(app_allocator.allocator());
    const repaint_seq = session.pending_repaint.startResizeAt(1_000);

    const ack_payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeInputAck{
        .input_seq = 1,
    });
    defer app_allocator.allocator().free(ack_payload);
    try protocol.sendFrame(fds[1], .te_input_ack, ack_payload);

    try std.testing.expectEqual(@as(?RuntimeRecovery, null), try pollRuntimeRecovery(fds[0], &session, 0));
    try std.testing.expect(session.pending_repaint.requiresRepaintForRecovery());

    const repaint_payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintResponse{
        .repaint_request_seq = repaint_seq,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 0,
            .draw_bytes = "",
        },
    });
    defer app_allocator.allocator().free(repaint_payload);
    try protocol.sendFrame(fds[1], .te_repaint_response, repaint_payload);

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
}

test "repaint response applies only latest outstanding request" {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintResponse{
        .repaint_request_seq = 7,
        .draw = .{
            .scrollback_cursor = "cursor-v7",
            .viewport_offset = 4,
            .draw_bytes = "",
            .attached_client_end_restore_bytes = "restore-v7",
        },
    });
    defer app_allocator.allocator().free(payload);

    var restore = std.ArrayList(u8).empty;
    defer restore.deinit(app_allocator.allocator());
    var cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var no_pending = PendingRepaint{};
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &no_pending, null));
    try std.testing.expectEqual(@as(usize, 0), cursor.len);
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);

    var older_pending = PendingRepaint{ .repaint_request_seq = 8 };
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &older_pending, null));
    try std.testing.expectEqual(@as(u64, 8), older_pending.repaint_request_seq);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    var matching_pending = PendingRepaint{ .repaint_request_seq = 7 };
    try std.testing.expect(try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &matching_pending, null));
    try std.testing.expect(!matching_pending.active());
    try std.testing.expectEqualStrings("cursor-v7", cursor.slice());
    try std.testing.expectEqual(@as(i32, 4), viewport_offset);
    try std.testing.expectEqualStrings("restore-v7", restore.items);
}

test "reconnect waits for repaint response before returning" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 77;

    const hello_ok = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(hello_ok);
    try protocol.sendFrame(remote_to_client[1], .hello_ok, hello_ok);

    const hello_request = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(hello_request);
    try protocol.sendFrame(remote_to_client[1], .hello_request, hello_request);

    const session_attached = try protocol.encodePayload(app_allocator.allocator(), pb.TeSessionAttached{});
    defer app_allocator.allocator().free(session_attached);
    try protocol.sendFrame(remote_to_client[1], .te_session_attached, session_attached);

    const repaint_response = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintResponse{
        .repaint_request_seq = 77,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 5,
            .draw_bytes = "",
        },
    });
    defer app_allocator.allocator().free(repaint_response);
    try protocol.sendFrame(remote_to_client[1], .te_repaint_response, repaint_response);

    var session = RuntimeSession{};
    defer session.attached_client_end_restore.deinit(app_allocator.allocator());
    try session.scrollback_cursor.set("old-cursor");

    try reconnectSessionOnRuntime(remote_to_client[0], client_to_remote[1], &session);

    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 5), session.viewport_offset);
}

test "runtime repaint after local ui requests screen-only repaint" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 91;

    const repaint_response = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintResponse{
        .repaint_request_seq = 91,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 6,
            .draw_bytes = "",
        },
    });
    defer app_allocator.allocator().free(repaint_response);
    try protocol.sendFrame(remote_to_client[1], .te_repaint_response, repaint_response);

    var session = RuntimeSession{};
    defer session.attached_client_end_restore.deinit(app_allocator.allocator());
    try session.scrollback_cursor.set("old-cursor");
    session.viewport_offset = 5;

    try repaintRuntimeSession(remote_to_client[0], client_to_remote[1], &session);

    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), client_to_remote[0]);
    defer frame.deinit(app_allocator.allocator());
    try std.testing.expectEqual(protocol.MessageType.te_resize, frame.message_type);
    var resize = try protocol.decodePayload(pb.TeResize, app_allocator.allocator(), frame.payload);
    defer resize.deinit(app_allocator.allocator());
    try std.testing.expectEqual(@as(u32, 24), resize.terminal_rows);
    try std.testing.expectEqual(@as(u32, 80), resize.terminal_cols);
    try std.testing.expectEqual(@as(?i32, 5), resize.viewport_offset);
    const repaint = resize.repaint_request orelse return error.ExpectedRepaintRequest;
    try std.testing.expectEqual(@as(u64, 91), repaint.repaint_request_seq);
    try std.testing.expect(repaint.scrollback_cursor == null);
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 6), session.viewport_offset);
}

pub fn startNewSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    reap_ms: u64,
) !RuntimeSession {
    const size = terminal.currentWindowSize();
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    const repaint_request_seq = try sendSessionCreate(
        write_fd,
        size,
        viewport_offset,
        scrollback_row_count,
        session_guid,
        command_argv,
        shell_command,
        reap_ms,
    );
    var session = try readRuntimeSession(read_fd);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn startAttachSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_ref: []const u8,
    session_dir: []const u8,
    initial_scrollback_row_count: ?u32,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    const repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), viewport_offset, initial_scrollback_row_count, null, session_ref, session_dir);
    var session = try readRuntimeSession(read_fd);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn ensureLocalRouteForRemoteSession(
    allocator: std.mem.Allocator,
    session: *const RuntimeSession,
    host: []const u8,
    resolved_host: []const u8,
    port: []const u8,
    ssh_options: []const []const u8,
) !void {
    if (session.guidSlice().len == 0) return;
    try session_registry.writeSshRoute(
        allocator,
        session.guidSlice(),
        session.sessionDirSlice(),
        host,
        resolved_host,
        port,
        ssh_options,
        config.version,
    );
}

pub fn reconnectSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, null, true);
}

pub fn reconnectSessionOnRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: *const std.atomic.Value(bool),
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, cancelled, false);
}

pub fn prepareReconnectRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: *const std.atomic.Value(bool),
) !void {
    _ = try runtimeHandshakeInner(read_fd, write_fd, cancelled);
}

pub fn attachPreparedReconnectRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: *const std.atomic.Value(bool),
) !void {
    try attachReconnectRuntimeInner(read_fd, write_fd, session, cancelled, false);
}

fn reconnectSessionOnRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
    wait_for_repaint: bool,
) !void {
    _ = try runtimeHandshakeInner(read_fd, write_fd, cancelled);
    try attachReconnectRuntimeInner(read_fd, write_fd, session, cancelled, wait_for_repaint);
}

fn attachReconnectRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
    wait_for_repaint: bool,
) !void {
    session.pending_repaint.repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), nonZeroViewportOffset(session.viewport_offset), null, &session.scrollback_cursor, session.guidSlice(), session.sessionDirSlice());
    try readSessionAttachedInner(read_fd, write_fd, cancelled);
    if (wait_for_repaint) try finishReconnectRepaintInner(read_fd, write_fd, session, cancelled);
}

pub fn finishReconnectRepaint(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try finishReconnectRepaintInner(read_fd, write_fd, session, null);
}

pub fn repaintRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try sendResizeScreenRepaint(write_fd, terminal.currentWindowSize(), session.viewport_offset, &session.pending_repaint);
    try finishReconnectRepaint(read_fd, write_fd, session);
}

fn finishReconnectRepaintInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    while (session.pending_repaint.active()) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .te_draw => {},
            .te_repaint_response => {
                _ = try handleRepaintResponseFrame(
                    frame.payload,
                    &session.attached_client_end_restore,
                    &session.scrollback_cursor,
                    &session.viewport_offset,
                    &session.pending_repaint,
                    &session.app_title_present,
                );
            },
            .te_input_ack => {
                _ = try handleInputAckFrame(frame.payload, &session.input_ack_tracker);
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            .te_tty_transcript_chunk => try handleTtyTranscriptChunkFrame(frame.payload),
            .te_session_ended => {
                try session.recordSessionEndedPayload(frame.payload);
                return error.SessionEnded;
            },
            .error_message => {
                try printErrorPayload(frame.payload);
                return error.RemoteError;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

pub fn runAttachedClient(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    return runAttachedClientLoop(
        read_fd,
        write_fd,
        &session.input_escape_filter,
        &session.scrollback_cursor,
        &session.viewport_offset,
        &session.pending_repaint,
        &session.attached_client_end_restore,
        &session.input_ack_tracker,
        &session.paste_like_input_classifier,
        &session.ended_process_exit_code,
        &session.app_title_present,
        .{
            .monitor_connection = options.monitor_connection,
            .responsiveness_timeout_floor_ms = @max(options.responsiveness_timeout_floor_ms, session.unresponsive_timeout_floor_ms),
        },
    );
}

pub fn pollRuntimeRecovery(
    read_fd: c.fd_t,
    session: *RuntimeSession,
    timeout_ms: i32,
) !?RuntimeRecovery {
    var pollfds = [_]posix.pollfd{.{
        .fd = read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return null;
    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
        (pollfds[0].revents & posix.POLL.IN) == 0)
    {
        return .transport_closed;
    }
    if ((pollfds[0].revents & posix.POLL.IN) == 0) return null;

    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .te_draw => {
            if (session.pending_repaint.active()) return null;
            try handleDrawFrame(frame.payload, &session.attached_client_end_restore, &session.scrollback_cursor, &session.viewport_offset, &session.app_title_present);
            return .recovered;
        },
        .te_repaint_response => {
            const applied = try handleRepaintResponseFrame(
                frame.payload,
                &session.attached_client_end_restore,
                &session.scrollback_cursor,
                &session.viewport_offset,
                &session.pending_repaint,
                &session.app_title_present,
            );
            return if (applied) .recovered else null;
        },
        .te_input_ack => {
            _ = try handleInputAckFrame(frame.payload, &session.input_ack_tracker);
            if (session.pending_repaint.requiresRepaintForRecovery()) return null;
            return .recovered;
        },
        .te_tty_transcript_chunk => {
            try handleTtyTranscriptChunkFrame(frame.payload);
            return .recovered;
        },
        .te_session_ended => {
            try session.recordSessionEndedPayload(frame.payload);
            _ = finishAttachedClient(.session_ended, &session.attached_client_end_restore);
            return .session_ended;
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            _ = finishAttachedClient(.session_ended, &session.attached_client_end_restore);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

pub fn pollAndForwardReconnectInput(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    timeout_ms: i32,
) !ReconnectInputPumpResult {
    try reconnect_ui.refreshForResize();
    if (reconnect_ui.consumeResizeForRuntime()) {
        session.viewport_offset = reconnect_ui.currentViewportOffset();
        sendResizeWithRepaint(
            write_fd,
            terminal.currentWindowSize(),
            &session.scrollback_cursor,
            session.viewport_offset,
            &session.pending_repaint,
        ) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        };
    }
    try reconnect_ui.refreshOverlayIfDiagnosticsChanged();

    var pollfds = [_]posix.pollfd{.{
        .fd = 0,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return .wait_elapsed;
    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .detach;
    if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

    var input: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    const n = c.read(0, &input, input.len);
    if (n <= 0) return .detach;
    const bytes = input[0..@intCast(n)];
    io_helpers.noteRead(0, bytes);

    for (bytes) |byte| {
        if (byte == 0x03) return .detach;
        if (byte == 0x12) {
            reconnect_ui.reconnect_acknowledged = true;
            return .reconnect_now;
        }
    }

    const result = session.input_escape_filter.filter(bytes, &filtered);
    if (result.bytes.len > 0) {
        const paste_like = session.paste_like_input_classifier.classify(result.bytes.len);
        sendInputChunks(write_fd, result.bytes, &session.input_ack_tracker, paste_like) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        };
    }

    if (result.end) |end| switch (end) {
        .detach => return switch (requestSessionDetach(read_fd, write_fd)) {
            .detach => .detach,
            else => .transport_closed,
        },
        .help => {},
        .repaint => sendRepaint(write_fd, "", &session.pending_repaint) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        },
    };

    try reconnect_ui.refreshOverlayIfDiagnosticsChanged();
    return .wait_elapsed;
}

pub fn writeDetachOverlayForTarget(ssh_options: []const []const u8, target: []const u8, sessh_options: []const []const u8, session_id: []const u8) void {
    if (c.isatty(1) == 0) return;
    _ = ssh_options;
    _ = target;
    _ = sessh_options;
    _ = session_id;
    writeDetachOverlay() catch {};
}

pub fn writeDetachOverlayForSessionRef(sessh_options: []const []const u8, session_ref: []const u8) void {
    if (c.isatty(1) == 0) return;
    _ = sessh_options;
    _ = session_ref;
    writeDetachOverlay() catch {};
}

fn writeDetachOverlay() !void {
    try io_helpers.writeAll(1, "--- sessh: disconnected ---\r\n");
}

fn readRuntimeSession(read_fd: c.fd_t) !RuntimeSession {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), read_fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
                if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                    freeErrorPayload(parsed);
                    return error.VersionMismatch;
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .te_session_attached => {
                var attached = try protocol.decodePayload(pb.TeSessionAttached, app_allocator.allocator(), frame.payload);
                defer attached.deinit(app_allocator.allocator());
                var session = RuntimeSession{};
                try session.setIdentity(attached.session_guid);
                try session.setSessionDir(attached.session_dir);
                return session;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn queryInitialViewportOffset() ?i32 {
    if (c.isatty(0) == 0 or c.isatty(1) == 0) return null;
    const position = terminal.queryCursorPosition(0, 1) catch return unknown_viewport_offset;
    return initialViewportOffsetFromCursorPosition(position);
}

fn initialViewportOffsetFromCursorPosition(position: ?terminal.CursorPosition) ?i32 {
    return if (position) |value| @as(i32, @intCast(value.row)) else unknown_viewport_offset;
}

fn nonZeroViewportOffset(viewport_offset: i32) ?i32 {
    return if (viewport_offset == 0) null else viewport_offset;
}

test "initial viewport offset marks missing cursor response unknown" {
    try std.testing.expectEqual(@as(?i32, unknown_viewport_offset), initialViewportOffsetFromCursorPosition(null));
    try std.testing.expectEqual(@as(?i32, 4), initialViewportOffsetFromCursorPosition(.{ .row = 4, .col = 12 }));
}

fn readSessionAttached(conn: c.fd_t) !void {
    return readSessionAttachedInner(conn, conn, null);
}

fn readSessionAttachedInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
                if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                    freeErrorPayload(parsed);
                    return error.VersionMismatch;
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .te_session_attached => {
                var attached = try protocol.decodePayload(pb.TeSessionAttached, app_allocator.allocator(), frame.payload);
                defer attached.deinit(app_allocator.allocator());
                return;
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readFrameAllocMaybeCancelled(
    fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !protocol.OwnedFrame {
    const flag = cancelled orelse return protocol.readFrameAlloc(app_allocator.allocator(), fd);
    while (true) {
        if (flag.load(.acquire)) return error.ReconnectDetached;
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 50);
        if (flag.load(.acquire)) return error.ReconnectDetached;
        if (ready == 0) continue;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) {
            return protocol.readFrameAlloc(app_allocator.allocator(), fd);
        }
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            return error.EndOfStream;
        }
    }
}

pub fn runtimeHandshake(read_fd: c.fd_t, write_fd: c.fd_t) !void {
    try runtimeHandshakeInner(read_fd, write_fd, null);
}

fn runtimeHandshakeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    try sendHelloRequest(write_fd);
    var hello_error = try readHelloReply(read_fd, cancelled);
    defer if (hello_error) |*err| err.deinit(app_allocator.allocator());
    if (hello_error) |err| {
        const parsed = errorPayloadFromHelloError(err);
        if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        try printBorrowedError(parsed);
        return process_exit.request(1);
    }

    var peer_hello = try readHelloRequest(read_fd, write_fd, cancelled);
    defer peer_hello.deinit(app_allocator.allocator());
    if (helloRequestIsCompatible(peer_hello)) {
        try sendHelloOk(write_fd);
    } else {
        try sendHelloError(write_fd, "VERSION_MISMATCH", "existing remote sessh is incompatible with this client", "");
        return error.VersionMismatch;
    }
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}

fn readHelloReply(
    read_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !?hpb.HelloError {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, app_allocator.allocator(), frame.payload);
                defer ok.deinit(app_allocator.allocator());
                return null;
            },
            .hello_error => {
                const err = try protocol.decodePayload(hpb.HelloError, app_allocator.allocator(), frame.payload);
                return err;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readHelloRequest(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !hpb.HelloRequest {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, app_allocator.allocator(), frame.payload),
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            else => {
                try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

fn errorPayloadFromHelloError(response_error: hpb.HelloError) ErrorPayload {
    return .{
        .code = response_error.code,
        .message = response_error.message,
        .hint = response_error.hint orelse "",
    };
}

fn sendSessionCreate(
    conn: c.fd_t,
    size: WindowSize,
    viewport_offset: ?i32,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    reap_ms: u64,
) !u64 {
    if (command_argv.len > 0 and shell_command != null) return error.InvalidSessionCommand;
    const repaint_request_seq = allocateRepaintRequestSeq();
    var message = pb.TeSessionCreate{
        .resize = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
            .viewport_offset = viewport_offset,
            .repaint_request = .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = "",
            },
        },
        .scrollback_row_limit = scrollback_row_count,
        .session_guid = session_guid,
        .reap_ms = reap_ms,
        .capture_tty_transcript = tty_transcript.enabled(),
    };
    defer message.environment.deinit(app_allocator.allocator());
    // The normal sessh path runs a terminal emulator on the remote side. Copy
    // portable line-discipline modes, but keep TERM tied to that emulator
    // contract instead of leaking the outer terminal's TERM.
    var captured_tty_settings = tty_settings.capture(app_allocator.allocator(), 0, .{ .include_term = false }) catch |err| blk: {
        client_log.debug("event=tty_settings_capture_failed error={t}", .{err});
        break :blk null;
    };
    defer if (captured_tty_settings) |*settings| settings.deinit(app_allocator.allocator());
    var protocol_tty_settings = pb.TeTtySettings{};
    defer protocol_tty_settings.tty_mode.deinit(app_allocator.allocator());
    if (captured_tty_settings) |settings| {
        for (settings.modes) |mode| {
            try protocol_tty_settings.tty_mode.append(app_allocator.allocator(), .{
                .opcode = mode.opcode,
                .value = mode.value,
            });
        }
        message.tty_settings = protocol_tty_settings;
    }
    var exec_command = pb.TeExecCommand{};
    defer exec_command.argv.deinit(app_allocator.allocator());
    if (shell_command) |command| {
        message.command = .{ .shell_command = .{ .command = command } };
    } else if (command_argv.len > 0) {
        try exec_command.argv.appendSlice(app_allocator.allocator(), command_argv);
        message.command = .{ .exec_command = exec_command };
    }
    const default_colors = queryDefaultColorsForSession();
    message.query_default_colors = .{
        .foreground_color = default_colors.foreground_color,
        .background_color = default_colors.background_color,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .te_session_create, payload);
    return repaint_request_seq;
}

const ProtocolDefaultColors = struct {
    foreground_color: u32 = 0xffffffff,
    background_color: u32 = 0xffffffff,
};

fn queryDefaultColorsForSession() ProtocolDefaultColors {
    const queried = terminal.queryDefaultColors(0, 1) catch return .{};
    return .{
        .foreground_color = protocolColorFromRgb(queried.foreground),
        .background_color = protocolColorFromRgb(queried.background),
    };
}

fn protocolColorFromRgb(rgb: ?terminal.Rgb) u32 {
    const value = rgb orelse return 0xffffffff;
    return 0x01000000 |
        (@as(u32, value.r) << 16) |
        (@as(u32, value.g) << 8) |
        @as(u32, value.b);
}

fn sendSessionAttach(
    conn: c.fd_t,
    size: WindowSize,
    viewport_offset: ?i32,
    initial_scrollback_row_count: ?u32,
    reconnect_cursor: ?*const ScrollbackCursor,
    session_ref: []const u8,
    session_dir: []const u8,
) !u64 {
    const repaint_request_seq = allocateRepaintRequestSeq();
    const message = pb.TeSessionAttach{
        .resize = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
            .viewport_offset = viewport_offset,
            .repaint_request = if (reconnect_cursor) |cursor| .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = cursor.slice(),
            } else .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = if (initial_scrollback_row_count != null and initial_scrollback_row_count.? == 0)
                    null
                else
                    "",
                .initial_scrollback_rows = initial_scrollback_row_count,
            },
        },
        .session_ref = session_ref,
        .capture_tty_transcript = tty_transcript.enabled(),
        .session_dir = session_dir,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .te_session_attach, payload);
    return repaint_request_seq;
}

fn readSessionEndedOrError(conn: c.fd_t) !bool {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), conn);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                try printErrorPayload(frame.payload);
                return true;
            },
            .te_session_ended => return false,
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, conn);
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn printErrorPayload(payload: []const u8) !void {
    try printParsedError(try parseErrorPayload(payload));
}

fn parseErrorPayload(payload: []const u8) !ErrorPayload {
    var decoded = try protocol.decodePayload(hpb.Error, app_allocator.allocator(), payload);
    defer decoded.deinit(app_allocator.allocator());
    return .{
        .code = try app_allocator.allocator().dupe(u8, decoded.code),
        .message = try app_allocator.allocator().dupe(u8, decoded.message),
        .hint = try app_allocator.allocator().dupe(u8, decoded.hint orelse ""),
    };
}

fn printParsedError(parsed: ErrorPayload) !void {
    defer freeErrorPayload(parsed);
    try printBorrowedError(parsed);
}

fn printBorrowedError(parsed: ErrorPayload) !void {
    try io_helpers.writeAll(2, "ERROR ");
    try io_helpers.writeAll(2, parsed.message);
    try io_helpers.writeAll(2, "\n");
    if (parsed.hint.len > 0) {
        try io_helpers.writeAll(2, parsed.hint);
        try io_helpers.writeAll(2, "\n");
    }
}

fn freeErrorPayload(parsed: ErrorPayload) void {
    app_allocator.allocator().free(parsed.code);
    app_allocator.allocator().free(parsed.message);
    app_allocator.allocator().free(parsed.hint);
}

fn runAttachedClientLoop(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    const initial_kitty_keyboard_flags = client_ui.queryInitialKittyKeyboardFlags();
    var mode_guard = try terminal.TerminalModeGuard.enable(0);
    defer mode_guard.restore();
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    defer if (cleanup_title) |title| app_allocator.allocator().free(title);
    var presentation_guard = if (cleanup_title) |title|
        client_renderer.PresentationGuard.initWithCleanupTitleAndInitialKittyKeyboardFlags(
            1,
            title,
            initial_kitty_keyboard_flags,
        )
    else
        client_renderer.PresentationGuard.initWithInitialKittyKeyboardFlags(1, initial_kitty_keyboard_flags);
    defer presentation_guard.restore();

    const end = try runAttachedTerminal(
        0,
        read_fd,
        write_fd,
        input_escape_filter,
        &presentation_guard,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        attached_client_end_restore,
        input_ack_tracker,
        paste_like_input_classifier,
        ended_process_exit_code,
        app_title_present,
        options,
    );
    if (end == .detach) writeDetachBoundary();
    return end;
}

fn runAttachedTerminal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    presentation_guard: *client_renderer.PresentationGuard,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    var pollfds = [_]posix.pollfd{
        .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    var buf: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    var last_size = terminal.currentWindowSize();
    var connection_monitor = ConnectionMonitor{
        .enabled = options.monitor_connection,
        .responsiveness_timeout_floor_ms = options.responsiveness_timeout_floor_ms,
    };
    _ = presentation_guard;

    while (true) {
        _ = try posix.poll(&pollfds, connection_monitor.pollTimeoutMs());

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (try drainAttachedClientRuntimeFrames(
                read_fd,
                write_fd,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                attached_client_end_restore,
                input_ack_tracker,
                ended_process_exit_code,
                app_title_present,
            )) |end| return finishAttachedClient(end, attached_client_end_restore);
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishAttachedClient(requestSessionDetach(read_fd, write_fd), attached_client_end_restore);
            io_helpers.noteRead(input_fd, buf[0..@intCast(n)]);
            const result = input_escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) {
                const paste_like = paste_like_input_classifier.classify(result.bytes.len);
                sendInputChunks(write_fd, result.bytes, input_ack_tracker, paste_like) catch |err| switch (err) {
                    error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                        read_fd,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        attached_client_end_restore,
                        input_ack_tracker,
                        ended_process_exit_code,
                        app_title_present,
                    ),
                    else => return err,
                };
                connection_monitor.afterInput();
            }
            if (result.end) |end| switch (end) {
                .detach => return finishAttachedClient(requestSessionDetach(read_fd, write_fd), attached_client_end_restore),
                .help => {
                    if (try showEscapeHelpModal(
                        input_fd,
                        read_fd,
                        write_fd,
                        viewport_offset,
                        pending_repaint,
                        input_ack_tracker,
                        ended_process_exit_code,
                    )) |modal_end| return finishAttachedClient(modal_end, attached_client_end_restore);
                },
                .repaint => sendRepaint(write_fd, "", pending_repaint) catch |err| switch (err) {
                    error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                        read_fd,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        attached_client_end_restore,
                        input_ack_tracker,
                        ended_process_exit_code,
                        app_title_present,
                    ),
                    else => return err,
                },
            };
        }

        maybeSendResize(write_fd, &last_size, scrollback_cursor, viewport_offset, pending_repaint) catch |err| switch (err) {
            error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                read_fd,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                attached_client_end_restore,
                input_ack_tracker,
                ended_process_exit_code,
                app_title_present,
            ),
            else => return err,
        };

        if (checkResizeRepaintTimeout(pending_repaint, viewport_offset, std.time.milliTimestamp())) |end| return end;

        if (connection_monitor.isUnresponsive()) {
            return .unresponsive;
        }
    }
}

fn showEscapeHelpModal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    // The help overlay is local UI, not part of the remote terminal model. While
    // it is visible, remote draw frames are discarded and a repaint is requested
    // after dismissal so the client resumes from the session agent's latest
    // screen state.
    const renderer = client_renderer.Renderer.init(1);
    var overlay_state: ?client_ui.OverlayDrawState = null;
    var last_size = terminal.currentWindowSize();
    try drawEscapeHelpOverlay(renderer, last_size, viewport_offset, &overlay_state);

    while (true) {
        var pollfds = [_]posix.pollfd{
            .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&pollfds, 250);

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (try drainEscapeHelpRuntimeFrames(
                read_fd,
                write_fd,
                input_ack_tracker,
                ended_process_exit_code,
            )) |end| {
                try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
                return end;
            }
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var input: [256]u8 = undefined;
            const n = c.read(input_fd, &input, input.len);
            if (n <= 0) {
                try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
                return requestSessionDetach(read_fd, write_fd);
            }
            const bytes = input[0..@intCast(n)];
            io_helpers.noteRead(input_fd, bytes);
            // The key that dismisses the help screen is local UI input. Do not
            // forward it to the remote session after the repaint.
            break;
        }

        const size = terminal.currentWindowSize();
        if (size.rows != last_size.rows or size.cols != last_size.cols) {
            last_size = size;
            try drawEscapeHelpOverlay(renderer, size, viewport_offset, &overlay_state);
        }
    }

    try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
    sendScreenRepaint(write_fd, pending_repaint) catch |err| switch (err) {
        error.WriteFailed => return .transport_closed,
        else => return err,
    };
    return null;
}

fn drawEscapeHelpOverlay(
    renderer: client_renderer.Renderer,
    size: WindowSize,
    viewport_offset: *i32,
    overlay_state: *?client_ui.OverlayDrawState,
) !void {
    var lines: [terminal.escape_help_overlay_lines.len]client_ui.OverlayLine = undefined;
    inline for (terminal.escape_help_overlay_lines, 0..) |line, index| {
        lines[index] = .{
            .text = line,
            .alignment = if (index == 0) .center else .left,
        };
    }
    const top: u16 = if (viewport_offset.* > 0)
        @intCast(@min(@as(usize, @intCast(viewport_offset.*)), @as(usize, std.math.maxInt(u16))))
    else
        0;
    const next = try client_ui.drawOverlayLines(renderer, size, top, overlay_state.*, &lines);
    viewport_offset.* = @intCast(next.viewport_offset);
    overlay_state.* = next;
}

fn clearEscapeHelpOverlay(
    renderer: client_renderer.Renderer,
    viewport_offset: *i32,
    overlay_state: *?client_ui.OverlayDrawState,
) !void {
    const state = overlay_state.* orelse return;
    const size = terminal.currentWindowSize();
    try client_ui.eraseOverlayRows(renderer, state, size.rows, size.cols);
    try client_ui.restoreOverlayExpansion(renderer, state, size.rows);
    const cleared = client_ui.clearedOverlayViewportOffset(state);
    viewport_offset.* = @intCast(cleared);
    overlay_state.* = null;
    try renderer.moveCursor(cleared, 0);
}

fn drainEscapeHelpRuntimeFrames(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    while (true) {
        var runtime_poll = [_]posix.pollfd{.{
            .fd = read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = try posix.poll(&runtime_poll, 0);
        const revents = runtime_poll[0].revents;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((revents & posix.POLL.IN) == 0) return null;

        if (try handleEscapeHelpRuntimeFrame(read_fd, write_fd, input_ack_tracker, ended_process_exit_code)) |end| return end;
    }
}

fn handleEscapeHelpRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        // The overlay sits on top of the last rendered screen. Applying remote
        // draws here would interleave two renderers; repaint-after-dismiss is
        // the boundary that gets us back to a single source of screen truth.
        .te_draw, .te_repaint_response => return null,
        .te_tty_transcript_chunk => {
            try handleTtyTranscriptChunkFrame(frame.payload);
            return null;
        },
        .te_input_ack => {
            _ = try handleInputAckFrame(frame.payload, input_ack_tracker);
            return null;
        },
        .ping, .pong => {
            _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            return null;
        },
        .te_session_ended => {
            if (ended_process_exit_code) |exit_code| {
                var ended = try protocol.decodePayload(pb.TeSessionEnded, app_allocator.allocator(), frame.payload);
                defer ended.deinit(app_allocator.allocator());
                exit_code.* = processExitCodeFromSessionEnded(ended);
            }
            return .session_ended;
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

fn drainAttachedClientRuntimeFrames(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
) !?AttachedClientEnd {
    while (true) {
        var runtime_poll = [_]posix.pollfd{.{
            .fd = read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = try posix.poll(&runtime_poll, 0);
        const revents = runtime_poll[0].revents;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((revents & posix.POLL.IN) == 0) return null;

        if (try handleAttachedClientRuntimeFrame(
            read_fd,
            write_fd,
            connection_monitor,
            scrollback_cursor,
            viewport_offset,
            pending_repaint,
            attached_client_end_restore,
            input_ack_tracker,
            ended_process_exit_code,
            app_title_present,
        )) |end| return end;
    }
}

fn finishAttachedClientAfterRuntimeWriteFailed(
    read_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
) !AttachedClientEnd {
    if (try drainAttachedClientRuntimeFrames(
        read_fd,
        @as(c.fd_t, -1),
        connection_monitor,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        attached_client_end_restore,
        input_ack_tracker,
        ended_process_exit_code,
        app_title_present,
    )) |end| return finishAttachedClient(end, attached_client_end_restore);
    return .transport_closed;
}

fn handleAttachedClientRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
) !?AttachedClientEnd {
    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .te_draw => {
            if (!pending_repaint.active()) {
                try handleDrawFrame(frame.payload, attached_client_end_restore, scrollback_cursor, viewport_offset, app_title_present);
            }
            return null;
        },
        .te_repaint_response => {
            _ = try handleRepaintResponseFrame(
                frame.payload,
                attached_client_end_restore,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                app_title_present,
            );
            return null;
        },
        .te_tty_transcript_chunk => {
            try handleTtyTranscriptChunkFrame(frame.payload);
            return null;
        },
        .te_input_ack => {
            const ack = try handleInputAckFrame(frame.payload, input_ack_tracker);
            if (ack.progressed) connection_monitor.noteInputAckProgress(ack.still_pending);
            return null;
        },
        .ping, .pong => {
            _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            return null;
        },
        .te_session_ended => {
            if (ended_process_exit_code) |exit_code| {
                var ended = try protocol.decodePayload(pb.TeSessionEnded, app_allocator.allocator(), frame.payload);
                defer ended.deinit(app_allocator.allocator());
                exit_code.* = processExitCodeFromSessionEnded(ended);
            }
            return .session_ended;
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

fn finishAttachedClient(end: AttachedClientEnd, attached_client_end_restore: ?*std.ArrayList(u8)) AttachedClientEnd {
    if (end == .detach or end == .session_ended) {
        restoreAttachedClientEndPresentationBytes(attached_client_end_restore);
    }
    return end;
}

fn restoreAttachedClientEndPresentationBytes(attached_client_end_restore: ?*std.ArrayList(u8)) void {
    restoreAttachedClientEndPresentationBytesToFd(1, attached_client_end_restore);
}

fn restoreAttachedClientEndPresentationBytesToFd(fd: c.fd_t, attached_client_end_restore: ?*std.ArrayList(u8)) void {
    const restore = attached_client_end_restore orelse return;
    if (restore.items.len == 0) return;
    io_helpers.writeAll(fd, restore.items) catch {};
    restore.clearRetainingCapacity();
}

fn restoreLocalTerminalPresentation() void {
    const renderer = client_renderer.Renderer.init(1);
    renderer.restorePresentation(client_ui.queryInitialKittyKeyboardFlags()) catch {};
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    if (cleanup_title) |title| {
        defer app_allocator.allocator().free(title);
        renderer.setTitle(title) catch {};
    }
}

fn clearVisibleAfterResizeTimeout(viewport_offset: *i32) void {
    viewport_offset.* = 0;
    if (c.isatty(1) == 0) return;
    const renderer = client_renderer.Renderer.init(1);
    renderer.restorePresentation(client_ui.queryInitialKittyKeyboardFlags()) catch {};
    renderer.clearVisible() catch {};
}

fn checkResizeRepaintTimeout(pending_repaint: *const PendingRepaint, viewport_offset: *i32, now_ms: i64) ?AttachedClientEnd {
    if (!pending_repaint.resizeTimedOut(now_ms)) return null;
    clearVisibleAfterResizeTimeout(viewport_offset);
    return .unresponsive;
}

fn requestSessionDetach(read_fd: c.fd_t, write_fd: c.fd_t) AttachedClientEnd {
    _ = read_fd;
    _ = write_fd;
    return .detach;
}

fn writeDetachBoundary() void {
    if (c.isatty(1) == 0) return;
    io_helpers.writeAll(1, "\r\n") catch {};
}

fn handleDrawFrame(
    payload: []const u8,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
) !void {
    const draw = try parseDrawPayload(payload);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, attached_client_end_restore, scrollback_cursor, viewport_offset, app_title_present);
}

fn handleRepaintResponseFrame(
    payload: []const u8,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    app_title_present: ?*?bool,
) !bool {
    var response = try protocol.decodePayload(pb.TeRepaintResponse, app_allocator.allocator(), payload);
    defer response.deinit(app_allocator.allocator());
    if (!pending_repaint.active() or !pending_repaint.matches(response.repaint_request_seq)) return false;
    const response_draw = response.draw orelse return error.MissingDraw;
    const draw = try drawPayloadFromMessage(response_draw);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, attached_client_end_restore, scrollback_cursor, viewport_offset, app_title_present);
    pending_repaint.clear();
    return true;
}

fn handleTtyTranscriptChunkFrame(payload: []const u8) !void {
    var chunk = try protocol.decodePayload(pb.TeTtyTranscriptChunk, app_allocator.allocator(), payload);
    defer chunk.deinit(app_allocator.allocator());
    switch (chunk.stream) {
        .TE_TTY_TRANSCRIPT_STREAM_INNER_IN => tty_transcript.recordInnerIn(chunk.data),
        .TE_TTY_TRANSCRIPT_STREAM_INNER_OUT => tty_transcript.recordInnerOut(chunk.data),
        .TE_TTY_TRANSCRIPT_STREAM_UNSPECIFIED => {},
        _ => {},
    }
}

const InputAckResult = struct {
    progressed: bool,
    still_pending: bool,
};

fn handleInputAckFrame(payload: []const u8, input_ack_tracker: *InputAckTracker) !InputAckResult {
    var ack = try protocol.decodePayload(pb.TeInputAck, app_allocator.allocator(), payload);
    defer ack.deinit(app_allocator.allocator());
    return .{
        .progressed = input_ack_tracker.acknowledge(ack.input_seq),
        .still_pending = input_ack_tracker.pending(),
    };
}

fn handleDrawPayload(
    draw: DrawPayload,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
) !void {
    try io_helpers.writeAll(1, draw.draw_bytes);
    if (attached_client_end_restore) |target| {
        if (draw.attached_client_end_restore_bytes) |restore| {
            target.clearRetainingCapacity();
            try target.appendSlice(app_allocator.allocator(), restore);
        }
    }
    try scrollback_cursor.set(draw.scrollback_cursor);
    viewport_offset.* = draw.viewport_offset;
    if (app_title_present) |target| {
        if (draw.app_title_present) |present| target.* = present;
    }
}

fn parseDrawPayload(payload: []const u8) !DrawPayload {
    var message = try protocol.decodePayload(pb.TeDraw, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return drawPayloadFromMessage(message);
}

fn drawPayloadFromMessage(message: pb.TeDraw) !DrawPayload {
    if (message.viewport_offset) |offset| {
        if (offset < -1) return error.InvalidViewportOffset;
        if (offset > std.math.maxInt(u16)) return error.IntOutOfRange;
    }
    if (message.scrollback_cursor.len == 0) return error.MissingScrollbackCursor;
    return .{
        .scrollback_cursor = try app_allocator.allocator().dupe(u8, message.scrollback_cursor),
        .viewport_offset = message.viewport_offset orelse 0,
        .draw_bytes = try app_allocator.allocator().dupe(u8, message.draw_bytes),
        .app_title_present = message.app_title_present,
        .attached_client_end_restore_bytes = if (message.attached_client_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.scrollback_cursor);
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.attached_client_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
}

fn maybeSendResize(
    socket_fd: c.fd_t,
    last_size: *WindowSize,
    scrollback_cursor: *const ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
) !void {
    const size = terminal.currentWindowSize();
    if (size.rows == last_size.rows and size.cols == last_size.cols) return;
    last_size.* = size;
    const resize_viewport_offset: i32 = if (viewport_offset.* == 0) 0 else -1;
    viewport_offset.* = resize_viewport_offset;
    sendResizeWithRepaint(socket_fd, size, scrollback_cursor, resize_viewport_offset, pending_repaint) catch |err| {
        pending_repaint.clear();
        return err;
    };
}

fn sendResize(socket_fd: c.fd_t, size: WindowSize) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeResize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_resize, payload);
}

fn sendResizeWithRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
    scrollback_cursor: *const ScrollbackCursor,
    viewport_offset: i32,
    pending_repaint: *PendingRepaint,
) !void {
    const repaint_request_seq = pending_repaint.startResize();
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeResize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
        .viewport_offset = nonZeroViewportOffset(viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
            .scrollback_cursor = scrollback_cursor.slice(),
        },
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_resize, payload);
}

fn sendResizeScreenRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
    viewport_offset: i32,
    pending_repaint: *PendingRepaint,
) !void {
    const repaint_request_seq = pending_repaint.start();
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeResize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
        .viewport_offset = nonZeroViewportOffset(viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
        },
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_resize, payload);
}

fn sendRepaint(socket_fd: c.fd_t, scrollback_cursor: []const u8, pending_repaint: *PendingRepaint) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintRequest{
        .repaint_request_seq = pending_repaint.start(),
        .scrollback_cursor = scrollback_cursor,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_repaint_request, payload);
}

fn sendScreenRepaint(socket_fd: c.fd_t, pending_repaint: *PendingRepaint) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeRepaintRequest{
        .repaint_request_seq = pending_repaint.start(),
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_repaint_request, payload);
}

fn allocateRepaintRequestSeq() u64 {
    const seq = next_repaint_request_seq;
    next_repaint_request_seq +%= 1;
    if (next_repaint_request_seq == 0) next_repaint_request_seq = 1;
    return seq;
}

fn sendInput(socket_fd: c.fd_t, bytes: []const u8, input_ack_tracker: *InputAckTracker, paste_like: bool) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeInput{
        .data = bytes,
        .input_seq = input_ack_tracker.allocate(paste_like),
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .te_input, payload);
}

fn sendInputChunks(socket_fd: c.fd_t, bytes: []const u8, input_ack_tracker: *InputAckTracker, paste_like: bool) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + input_chunk_bytes, bytes.len);
        try sendInput(socket_fd, bytes[offset..end], input_ack_tracker, paste_like);
        offset = end;
    }
}
