// Foreground visible-client session state shared across reconnect attempts. It
// keeps terminal presentation, input ACKs, repaint sequencing, transcript state,
// and local title fallback together for one user-visible session.
const std = @import("std");

const app_allocator = @import("../core/app_allocator.zig");
const core_blocking = @import("../core/blocking.zig");
const client_loop = @import("client_loop.zig");
const fixed_buffer = @import("../core/fixed_buffer.zig");
const guid_ref = @import("../core/guid.zig");
const input_ack = @import("input_ack.zig");
const presentation_guard = @import("presentation_guard.zig");
const protocol = @import("../protocol/mod.zig");
const repaint = @import("repaint.zig");
const terminal = @import("../tty/terminal.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const default_responsiveness_timeout_ms = @import("connection_monitor.zig").default_responsiveness_timeout_ms;
const max_responsiveness_timeout_ms = @import("connection_monitor.zig").max_responsiveness_timeout_ms;

const max_scrollback_cursor_bytes = 64;
const max_title_fallback_bytes = 512;
pub const ScrollbackCursor = fixed_buffer.FixedBuffer(max_scrollback_cursor_bytes);
const TitleFallback = fixed_buffer.FixedBuffer(max_title_fallback_bytes);

pub const InitialDrawAlignment = struct {
    cursor_position: ?terminal.CursorPosition = null,
    pending: bool = false,

    pub fn setCursor(self: *InitialDrawAlignment, cursor_position: ?terminal.CursorPosition) void {
        self.cursor_position = cursor_position;
        self.pending = cursor_position != null;
    }

    pub fn takePendingCursor(self: *InitialDrawAlignment) ?terminal.CursorPosition {
        if (!self.pending) return null;
        self.pending = false;
        defer self.cursor_position = null;
        return self.cursor_position;
    }
};

/// Visible-client state carried across terminal worker transports for one session.
pub const VisibleClientSessionState = struct {
    guid: guid_ref.FixedSessionGuid = .{},
    scrollback_cursor: ScrollbackCursor = .{},
    viewport_offset: i32 = 0,
    /// Latest outstanding RepaintRequest sequence. Older responses are stale.
    pending_repaint: repaint.Pending = .{},
    visible_client_end_restore: std.ArrayList(u8) = .empty,
    unresponsive_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    input_ack_tracker: input_ack.Tracker = .{},
    input_escape_filter: terminal.EscapeFilter = .{},
    paste_like_input_classifier: client_loop.PasteLikeInputClassifier = .{},
    ended_process_exit_code: ?u8 = null,
    /// Local-only fallback for the terminal title while this session is active.
    /// For remote sessh this is the host string the user passed locally. We do
    /// not send it to the terminal worker because ssh aliases can reveal local
    /// naming that the remote machine would not otherwise know.
    title_fallback: TitleFallback = .{},
    /// Most recent app-title presence bit from Draw/RepaintResponse. True means
    /// the app owns the title, even if it set it to an empty string.
    app_title_present: ?bool = null,
    initial_draw_alignment: InitialDrawAlignment = .{},
    initial_kitty_keyboard_flags: u5 = 0,

    pub fn adoptReconnectState(self: *VisibleClientSessionState, reconnected: *const VisibleClientSessionState) void {
        self.pending_repaint = reconnected.pending_repaint;
    }

    pub fn noteUnresponsiveRecovery(self: *VisibleClientSessionState) void {
        self.unresponsive_timeout_floor_ms = @min(
            max_responsiveness_timeout_ms,
            @max(default_responsiveness_timeout_ms, self.unresponsive_timeout_floor_ms * 2),
        );
    }

    pub fn hasPendingInputAck(self: *const VisibleClientSessionState) bool {
        return self.input_ack_tracker.pending();
    }

    pub fn hasPendingPasteLikeInputAck(self: *const VisibleClientSessionState) bool {
        return self.input_ack_tracker.pendingPasteLike();
    }

    pub fn discardPendingInputAcks(self: *VisibleClientSessionState) void {
        self.input_ack_tracker.discardPending();
    }

    pub fn restoreVisibleClientEndPresentation(self: *VisibleClientSessionState, blocking: core_blocking.Blocking) void {
        presentation_guard.restoreVisibleClientEndBytes(blocking, &self.visible_client_end_restore);
    }

    pub fn restoreVisibleClientEndPresentationForExit(self: *VisibleClientSessionState, blocking: core_blocking.Blocking) void {
        self.restoreVisibleClientEndPresentation(blocking);
        presentation_guard.restoreLocal(blocking, self.initial_kitty_keyboard_flags);
    }

    pub fn deinit(self: *VisibleClientSessionState) void {
        self.visible_client_end_restore.deinit(app_allocator.allocator());
        self.visible_client_end_restore = .empty;
    }

    pub fn idSlice(self: *const VisibleClientSessionState) []const u8 {
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const VisibleClientSessionState) []const u8 {
        return self.guid.slice();
    }

    pub fn titleFallbackSlice(self: *const VisibleClientSessionState) []const u8 {
        if (!self.title_fallback.isEmpty()) return self.title_fallback.slice();
        return self.idSlice();
    }

    pub fn setTitleFallback(self: *VisibleClientSessionState, title: []const u8) void {
        self.title_fallback.setTruncate(title);
    }

    pub fn setIdentity(self: *VisibleClientSessionState, guid: []const u8) !void {
        try self.guid.set(guid);
        tty_transcript.setSessionGuid(guid);
    }

    pub fn recordSessionEnded(self: *VisibleClientSessionState, ended: pb.TerminalEmulatorItem.SessionEnded) void {
        self.ended_process_exit_code = processExitCodeFromSessionEnded(ended);
    }

    pub fn endedProcessExitCode(self: *const VisibleClientSessionState) u8 {
        return self.ended_process_exit_code orelse 0;
    }
};

fn processExitCodeFromSessionEnded(ended: pb.TerminalEmulatorItem.SessionEnded) u8 {
    const status = ended.exit_status orelse return 0;
    return switch (status.kind) {
        .KIND_EXITED => if (status.status >= 0 and status.status <= 255) @intCast(status.status) else 255,
        .KIND_SIGNALLED => if (status.status >= 0 and status.status <= 127) @intCast(128 + status.status) else 255,
        else => 0,
    };
}

test "visible client backs off unresponsive floor after recovery" {
    var session = VisibleClientSessionState{};
    try std.testing.expectEqual(default_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(@as(i64, 10_000), session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
}

test "visible client title fallback uses local title when present" {
    var session = VisibleClientSessionState{};
    try session.setIdentity("s-550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", session.titleFallbackSlice());

    session.setTitleFallback("work-host");
    try std.testing.expectEqualStrings("work-host", session.titleFallbackSlice());

    session.setTitleFallback("");
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", session.titleFallbackSlice());
}
