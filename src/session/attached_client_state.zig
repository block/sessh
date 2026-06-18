const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const client_loop = @import("client_loop.zig");
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

/// Client-side state carried across terminal worker transports for one attached session.
pub const AttachedSessionState = struct {
    const max_title_fallback_bytes = 512;

    guid: [guid_ref.session_guid_len]u8 = [_]u8{0} ** guid_ref.session_guid_len,
    guid_len: usize = 0,
    scrollback_cursor: ScrollbackCursor = .{},
    viewport_offset: i32 = 0,
    /// Latest outstanding RepaintRequest sequence. Older responses are stale.
    pending_repaint: repaint.Pending = .{},
    attached_client_end_restore: std.ArrayList(u8) = .empty,
    unresponsive_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    input_ack_tracker: input_ack.Tracker = .{},
    input_escape_filter: terminal.EscapeFilter = .{},
    paste_like_input_classifier: client_loop.PasteLikeInputClassifier = .{},
    ended_process_exit_code: ?u8 = null,
    /// Local-only fallback for the terminal title while this session is active.
    /// For remote sessh this is the host string the user passed locally. We do
    /// not send it to the remote terminal process because ssh aliases can reveal local
    /// naming that the remote machine would not otherwise know.
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,
    /// Most recent app-title presence bit from Draw/RepaintResponse. True means
    /// the app owns the title, even if it set it to an empty string.
    app_title_present: ?bool = null,
    initial_cursor_position: ?terminal.CursorPosition = null,
    initial_draw_alignment_pending: bool = false,
    initial_kitty_keyboard_flags: u5 = 0,
    recovery_reader: protocol.FrameReader = undefined,
    recovery_reader_fd: c.fd_t = -1,
    recovery_reader_initialized: bool = false,

    pub fn adoptReconnectState(self: *AttachedSessionState, reconnected: *const AttachedSessionState) void {
        self.pending_repaint = reconnected.pending_repaint;
    }

    pub fn noteUnresponsiveRecovery(self: *AttachedSessionState) void {
        self.unresponsive_timeout_floor_ms = @min(
            max_responsiveness_timeout_ms,
            @max(default_responsiveness_timeout_ms, self.unresponsive_timeout_floor_ms * 2),
        );
    }

    pub fn hasPendingInputAck(self: *const AttachedSessionState) bool {
        return self.input_ack_tracker.pending();
    }

    pub fn hasPendingPasteLikeInputAck(self: *const AttachedSessionState) bool {
        return self.input_ack_tracker.pendingPasteLike();
    }

    pub fn discardPendingInputAcks(self: *AttachedSessionState) void {
        self.input_ack_tracker.discardPending();
    }

    pub fn restoreAttachedClientEndPresentation(self: *AttachedSessionState) void {
        presentation_guard.restoreAttachedClientEndBytes(&self.attached_client_end_restore);
    }

    pub fn restoreAttachedClientEndPresentationForExit(self: *AttachedSessionState) void {
        self.restoreAttachedClientEndPresentation();
        presentation_guard.restoreLocal(self.initial_kitty_keyboard_flags);
    }

    pub fn deinit(self: *AttachedSessionState) void {
        self.resetRecoveryReader();
        self.attached_client_end_restore.deinit(app_allocator.allocator());
        self.attached_client_end_restore = .empty;
    }

    fn resetRecoveryReader(self: *AttachedSessionState) void {
        if (!self.recovery_reader_initialized) return;
        self.recovery_reader.deinit();
        self.recovery_reader_initialized = false;
        self.recovery_reader_fd = -1;
    }

    pub fn recoveryReader(self: *AttachedSessionState, fd: c.fd_t) *protocol.FrameReader {
        if (self.recovery_reader_initialized and self.recovery_reader_fd == fd) return &self.recovery_reader;
        self.resetRecoveryReader();
        self.recovery_reader = protocol.FrameReader.init(app_allocator.allocator());
        self.recovery_reader_fd = fd;
        self.recovery_reader_initialized = true;
        return &self.recovery_reader;
    }

    pub fn idSlice(self: *const AttachedSessionState) []const u8 {
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const AttachedSessionState) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn titleFallbackSlice(self: *const AttachedSessionState) []const u8 {
        if (self.title_fallback_len > 0) return self.title_fallback[0..self.title_fallback_len];
        return self.idSlice();
    }

    pub fn setTitleFallback(self: *AttachedSessionState, title: []const u8) void {
        self.title_fallback_len = copyTitleFallback(&self.title_fallback, title);
    }

    pub fn setIdentity(self: *AttachedSessionState, guid: []const u8) !void {
        if (guid.len > self.guid.len) return error.SessionGuidTooLarge;
        @memcpy(self.guid[0..guid.len], guid);
        self.guid_len = guid.len;
        tty_transcript.setSessionGuid(guid);
    }

    pub fn recordSessionEnded(self: *AttachedSessionState, ended: pb.TerminalEmulatorItem.SessionEnded) void {
        self.ended_process_exit_code = processExitCodeFromSessionEnded(ended);
    }

    pub fn endedProcessExitCode(self: *const AttachedSessionState) u8 {
        return self.ended_process_exit_code orelse 0;
    }
};

pub fn processExitCodeFromSessionEnded(ended: pb.TerminalEmulatorItem.SessionEnded) u8 {
    const status = ended.exit_status orelse return 0;
    return switch (status.kind) {
        .KIND_EXITED => if (status.status >= 0 and status.status <= 255) @intCast(status.status) else 255,
        .KIND_SIGNALLED => if (status.status >= 0 and status.status <= 127) @intCast(128 + status.status) else 255,
        else => 0,
    };
}

fn copyTitleFallback(dest: []u8, title: []const u8) usize {
    const len = @min(dest.len, title.len);
    @memcpy(dest[0..len], title[0..len]);
    return len;
}

test "attached session backs off unresponsive floor after recovery" {
    var session = AttachedSessionState{};
    try std.testing.expectEqual(default_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(@as(i64, 10_000), session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
    session.noteUnresponsiveRecovery();
    try std.testing.expectEqual(max_responsiveness_timeout_ms, session.unresponsive_timeout_floor_ms);
}
