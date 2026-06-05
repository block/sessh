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
const route_commands = @import("../runtime/route_commands.zig");
const session_registry = @import("../runtime/session_registry.zig");
const shell = @import("../core/shell.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;
const WindowSize = terminal.WindowSize;

var next_repaint_request_seq: u64 = 1;

const unknown_viewport_offset: i32 = -1;
const client_list_target_help = "incoming, outgoing, session, or a guid";

const LocalAction = enum {
    new,
    attach,
    list,
    kill,
    kill_all,
    detach_client,
    repaint_client,
    debug_client,
};

const ClientTarget = enum {
    default,
    all,
    last_input,
    client_guid,
};

const DebugClientAction = enum {
    sever_connection,
    unresponsive_connection,
};

const LocalOptions = struct {
    action: LocalAction = .new,
    action_set: bool = false,
    new_detached: bool = false,
    attach_id: ?[]const u8 = null,
    kill_id: ?[]const u8 = null,
    kill_ids: []const []const u8 = &.{},
    owned_kill_ids: ?[][]const u8 = null,
    kill_current: bool = false,
    kill_request_args: []const []const u8 = &.{},
    kill_jsonl: bool = false,
    list_refresh: bool = false,
    list_include_cached_routes: bool = true,
    list_jsonl: bool = false,
    list_exited: bool = false,
    list_all: bool = false,
    list_client_target: ?[]const u8 = null,
    client_session_ref: ?[]const u8 = null,
    client_target: ClientTarget = .default,
    client_guid: ?[]const u8 = null,
    client_repaint_scrollback: bool = false,
    debug_client_action: ?DebugClientAction = null,
    debug_unresponsive_seconds: ?u32 = null,
    overlay_args: client_ui.DetachOverlayArgs = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    compat_mode: bool = false,
    capture_tty_transcript: ?[]const u8 = null,

    fn deinit(self: *LocalOptions, allocator: std.mem.Allocator) void {
        if (self.owned_kill_ids) |ids| allocator.free(ids);
        self.owned_kill_ids = null;
        self.kill_ids = &.{};
    }
};

pub const LocalNewSessionRequest = struct {
    exe: []const u8,
    new_detached: bool = false,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    overlay_args: []const []const u8 = &.{},
    capture_tty_transcript: ?[]const u8 = null,
    command_argv: []const []const u8 = &.{},
    shell_command: ?[]const u8 = null,
};

const ErrorPayload = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

pub const RelayEnd = enum {
    detach,
    kill_detach,
    kill_wait,
    unresponsive,
    transport_closed,
    session_ended,
};

pub const ReconnectInputPumpResult = enum {
    wait_elapsed,
    reconnect_now,
    detach,
    kill_detach,
    kill_wait,
    transport_closed,
};

pub const RuntimeRecovery = enum {
    recovered,
    transport_closed,
    session_ended,
    detach,
};

pub const CreatedSession = struct {
    guid: []u8,
    session_dir: []u8,
    host_guid: []u8,

    pub fn deinit(self: *CreatedSession) void {
        const allocator = app_allocator.allocator();
        allocator.free(self.host_guid);
        allocator.free(self.session_dir);
        allocator.free(self.guid);
        self.* = undefined;
    }

    fn setHostGuid(self: *CreatedSession, host_guid: []const u8) !void {
        if (!session_registry.isValidHostGuid(host_guid)) return error.InvalidHostGuid;
        const copy = try app_allocator.allocator().dupe(u8, host_guid);
        app_allocator.allocator().free(self.host_guid);
        self.host_guid = copy;
    }
};

pub const RelayOptions = struct {
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
    host_guid: [session_registry.host_guid_len]u8 = [_]u8{0} ** session_registry.host_guid_len,
    host_guid_len: usize = 0,
    client_guid: [session_registry.client_guid_len]u8 = [_]u8{0} ** session_registry.client_guid_len,
    client_guid_len: usize = 0,
    session_dir: [4096]u8 = [_]u8{0} ** 4096,
    session_dir_len: usize = 0,
    scrollback_cursor: ScrollbackCursor = .{},
    viewport_offset: i32 = 0,
    /// Latest outstanding RepaintRequest sequence. Older responses are stale.
    pending_repaint: PendingRepaint = .{},
    relay_end_restore: std.ArrayList(u8) = .empty,
    unresponsive_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
    input_ack_tracker: InputAckTracker = .{},
    input_escape_filter: terminal.EscapeFilter = .{},
    paste_like_input_classifier: PasteLikeInputClassifier = .{},
    ended_tombstone_details: ?session_registry.TombstoneDetails = null,
    kill_requested: bool = false,
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

    pub fn restoreRelayEndPresentation(self: *RuntimeSession) void {
        restoreRelayEndPresentationBytes(&self.relay_end_restore);
    }

    pub fn restoreRelayEndPresentationForExit(self: *RuntimeSession) void {
        self.restoreRelayEndPresentation();
        restoreLocalTerminalPresentation();
    }

    pub fn deinit(self: *RuntimeSession) void {
        self.relay_end_restore.deinit(app_allocator.allocator());
        self.relay_end_restore = .empty;
    }

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const RuntimeSession) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn hostGuidSlice(self: *const RuntimeSession) []const u8 {
        return self.host_guid[0..self.host_guid_len];
    }

    pub fn clientGuidSlice(self: *const RuntimeSession) []const u8 {
        return self.client_guid[0..self.client_guid_len];
    }

    pub fn titleFallbackSlice(self: *const RuntimeSession) []const u8 {
        if (self.title_fallback_len > 0) return self.title_fallback[0..self.title_fallback_len];
        return self.idSlice();
    }

    pub fn sessionDirSlice(self: *const RuntimeSession) []const u8 {
        return self.session_dir[0..self.session_dir_len];
    }

    pub fn ensureClientGuid(self: *RuntimeSession) ![]const u8 {
        if (self.client_guid_len == 0) {
            const generated = try session_registry.generateClientGuid(app_allocator.allocator());
            defer app_allocator.allocator().free(generated);
            try self.setClientGuid(generated);
        }
        return self.clientGuidSlice();
    }

    pub fn setClientGuid(self: *RuntimeSession, client_guid: []const u8) !void {
        if (!session_registry.isValidClientGuid(client_guid)) return error.InvalidClientGuid;
        if (client_guid.len > self.client_guid.len) return error.ClientGuidTooLarge;
        @memcpy(self.client_guid[0..client_guid.len], client_guid);
        self.client_guid_len = client_guid.len;
    }

    pub fn setHostGuid(self: *RuntimeSession, host_guid: []const u8) !void {
        if (host_guid.len == 0) {
            self.host_guid_len = 0;
            return;
        }
        if (!session_registry.isValidHostGuid(host_guid)) return error.InvalidHostGuid;
        if (host_guid.len > self.host_guid.len) return error.HostGuidTooLarge;
        @memcpy(self.host_guid[0..host_guid.len], host_guid);
        self.host_guid_len = host_guid.len;
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
        self.ended_tombstone_details = tombstoneDetailsFromSessionEnded(ended);
    }

    pub fn endedProcessExitCode(self: *const RuntimeSession) u8 {
        return processExitCodeFromTombstoneDetails(self.ended_tombstone_details);
    }
};

fn tombstoneDetailsFromSessionEnded(ended: pb.TeSessionEnded) session_registry.TombstoneDetails {
    return .{
        .ended_at_unix_ms = ended.ended_at_unix_ms orelse nowUnixMs(),
        .end_reason = switch (ended.reason) {
            .TE_SESSION_END_REASON_PROCESS_EXITED => .process_exited,
            .TE_SESSION_END_REASON_KILLED_BY_REQUEST => .killed_by_request,
            .TE_SESSION_END_REASON_AGENT_SHUTDOWN => .agent_shutdown,
            .TE_SESSION_END_REASON_REAPED => .reaped,
            else => .unknown,
        },
        .exit_status = if (ended.exit_status) |status| switch (status.kind) {
            .EXIT_STATUS_KIND_EXITED => .{ .kind = .exited, .status = status.status },
            .EXIT_STATUS_KIND_SIGNALLED => .{ .kind = .signalled, .status = status.status },
            else => null,
        } else null,
    };
}

pub fn recordRuntimeSessionKillRequested(allocator: std.mem.Allocator, host: []const u8, session: *RuntimeSession) void {
    session.kill_requested = true;
    if (session.guidSlice().len == 0) return;
    session_registry.markRouteKillRequested(allocator, session.guidSlice()) catch |err| {
        client_log.debug("event=route_kill_requested_mark_failed session={s} error={t}", .{ session.guidSlice(), err });
    };
    if (host.len == 0 or std.mem.eql(u8, host, ".")) return;
    var route = session_registry.readRouteForRef(allocator, session.guidSlice()) catch null;
    defer if (route) |*value| value.deinit(allocator);
    const pending_host_guid = if (route) |*value| value.host_guid else session.hostGuidSlice();
    if (pending_host_guid.len == 0) {
        client_log.debug("event=pending_kill_queue_skipped_missing_host_guid host={s} session={s}", .{ host, session.guidSlice() });
        return;
    }
    const pending_host = if (route) |*value| value.resolved_host else host;
    const pending_port = if (route) |*value| value.port else session_registry.default_pending_port;
    session_registry.queuePendingKill(allocator, pending_host_guid, pending_host, pending_port, session.guidSlice()) catch |err| {
        client_log.debug("event=pending_kill_queue_failed host_guid={s} host={s} port={s} session={s} error={t}", .{ pending_host_guid, pending_host, pending_port, session.guidSlice(), err });
    };
}

fn tombstoneLocalRouteForPendingKill(allocator: std.mem.Allocator, guid: []const u8, details: session_registry.TombstoneDetails) !void {
    var route = session_registry.readRouteForRef(allocator, guid) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer route.deinit(allocator);
    try session_registry.writeTombstoneForRoute(allocator, &route, details);
}

fn processExitCodeFromTombstoneDetails(details: ?session_registry.TombstoneDetails) u8 {
    const status = if (details) |value| value.exit_status orelse return 0 else return 0;
    return switch (status.kind) {
        .exited => if (status.status >= 0 and status.status <= 255) @intCast(status.status) else 255,
        .signalled => if (status.status >= 0 and status.status <= 127) @intCast(128 + status.status) else 255,
    };
}

fn nowUnixMs() u64 {
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
    relay_end_restore_bytes: ?[]const u8,
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

test "resize repaint timeout clears stale relay display and enters unresponsive state" {
    var pending = PendingRepaint{};
    _ = pending.startResizeAt(1_000);
    var viewport_offset: i32 = 7;

    try std.testing.expectEqual(
        @as(?RelayEnd, null),
        checkResizeRepaintTimeout(&pending, &viewport_offset, 1_999),
    );
    try std.testing.expectEqual(@as(i32, 7), viewport_offset);

    try std.testing.expectEqual(
        RelayEnd.unresponsive,
        checkResizeRepaintTimeout(&pending, &viewport_offset, 2_000).?,
    );
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);
    try std.testing.expect(pending.requiresRepaintForRecovery());
}

test "relay drains pending session end before monitor timeout" {
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
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};
    var kill_requested = false;

    try std.testing.expectEqual(
        RelayEnd.session_ended,
        try relayTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &relay_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            &kill_requested,
            null,
            &app_title_present,
            .{ .monitor_connection = true },
        ),
    );
}

test "relay treats input write failure as transport closed" {
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
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};
    var kill_requested = false;
    var app_title_present: ?bool = null;

    try io_helpers.writeAll(input[1], "typed");

    try std.testing.expectEqual(
        RelayEnd.transport_closed,
        try relayTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &relay_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            &kill_requested,
            null,
            &app_title_present,
            .{ .monitor_connection = true },
        ),
    );
}

test "relay keeps relay-end restore bytes while reconnecting" {
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    try relay_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    try std.testing.expectEqual(RelayEnd.transport_closed, finishRelay(.transport_closed, &relay_end_restore));
    try std.testing.expectEqualStrings("restore-primary", relay_end_restore.items);

    try std.testing.expectEqual(RelayEnd.unresponsive, finishRelay(.unresponsive, &relay_end_restore));
    try std.testing.expectEqualStrings("restore-primary", relay_end_restore.items);
}

test "final relay-end restore writes and clears saved cleanup bytes" {
    const output = try posix.pipe();
    defer posix.close(output[0]);
    defer posix.close(output[1]);

    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    try relay_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    restoreRelayEndPresentationBytesToFd(output[1], &relay_end_restore);

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
    try std.testing.expectEqual(@as(usize, 0), relay_end_restore.items.len);
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
        .relay_end_restore_bytes = null,
    }, null, &scrollback_cursor, &viewport_offset, &app_title_present);

    try std.testing.expect(app_title_present != null);
    try std.testing.expect(!app_title_present.?);
}

test "recovery polling stores relay-end restore bytes from draw" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.relay_end_restore.deinit(app_allocator.allocator());

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeDraw{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .relay_end_restore_bytes = "restore-primary",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .te_draw, payload);

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.relay_end_restore.items);
}

test "recovery polling ignores draw while repaint is outstanding" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{ .pending_repaint = .{ .repaint_request_seq = 7 } };
    defer session.relay_end_restore.deinit(app_allocator.allocator());

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
    defer session.relay_end_restore.deinit(app_allocator.allocator());
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
            .relay_end_restore_bytes = "restore-v7",
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

    const host_guid = try protocol.encodePayload(app_allocator.allocator(), pb.HostGuid{
        .host_guid = "h-550e8400-e29b-41d4-a716-446655440001",
    });
    defer app_allocator.allocator().free(host_guid);
    try protocol.sendFrame(remote_to_client[1], .host_guid, host_guid);

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
    defer session.relay_end_restore.deinit(app_allocator.allocator());
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
    defer session.relay_end_restore.deinit(app_allocator.allocator());
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

test "client repaint request sends screen-only repaint request" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 123;

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeClientRepaintRequest{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(remote_to_client[1], .te_client_repaint_request, payload);

    var connection_monitor = ConnectionMonitor{};
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;

    try std.testing.expectEqual(
        @as(?RelayEnd, null),
        try handleRelayRuntimeFrame(
            remote_to_client[0],
            client_to_remote[1],
            &connection_monitor,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &relay_end_restore,
            &input_ack_tracker,
            null,
            &app_title_present,
        ),
    );

    try std.testing.expect(pending_repaint.active());
    try std.testing.expectEqual(@as(u64, 123), pending_repaint.repaint_request_seq);

    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), client_to_remote[0]);
    defer frame.deinit(app_allocator.allocator());
    try std.testing.expectEqual(protocol.MessageType.te_repaint_request, frame.message_type);
    var request = try protocol.decodePayload(pb.TeRepaintRequest, app_allocator.allocator(), frame.payload);
    defer request.deinit(app_allocator.allocator());
    try std.testing.expectEqual(@as(u64, 123), request.repaint_request_seq);
    try std.testing.expect(request.scrollback_cursor == null);
}

test "client repaint request can request retained scrollback" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 456;

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeClientRepaintRequest{
        .include_scrollback = true,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(remote_to_client[1], .te_client_repaint_request, payload);

    var connection_monitor = ConnectionMonitor{};
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;

    try std.testing.expectEqual(
        @as(?RelayEnd, null),
        try handleRelayRuntimeFrame(
            remote_to_client[0],
            client_to_remote[1],
            &connection_monitor,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &relay_end_restore,
            &input_ack_tracker,
            null,
            &app_title_present,
        ),
    );

    try std.testing.expect(pending_repaint.active());
    try std.testing.expectEqual(@as(u64, 456), pending_repaint.repaint_request_seq);

    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), client_to_remote[0]);
    defer frame.deinit(app_allocator.allocator());
    try std.testing.expectEqual(protocol.MessageType.te_repaint_request, frame.message_type);
    var request = try protocol.decodePayload(pb.TeRepaintRequest, app_allocator.allocator(), frame.payload);
    defer request.deinit(app_allocator.allocator());
    try std.testing.expectEqual(@as(u64, 456), request.repaint_request_seq);
    const cursor = request.scrollback_cursor orelse return error.ExpectedScrollbackCursor;
    try std.testing.expectEqual(@as(usize, 0), cursor.len);
}

test "client detach request uses normal detach relay end" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TeClientDetachRequest{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(remote_to_client[1], .te_client_detach_request, payload);

    var connection_monitor = ConnectionMonitor{};
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var relay_end_restore = std.ArrayList(u8).empty;
    defer relay_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;

    try std.testing.expectEqual(
        RelayEnd.detach,
        (try handleRelayRuntimeFrame(
            remote_to_client[0],
            client_to_remote[1],
            &connection_monitor,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &relay_end_restore,
            &input_ack_tracker,
            null,
            &app_title_present,
        )).?,
    );
}

/// Implements sesshmux-local commands after the public mux parser has selected
/// the local endpoint.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var options = parseLocalOptions(allocator, args) catch |err| {
        try writeLocalArgError(err);
        return process_exit.request(64);
    };
    defer options.deinit(allocator);
    applyFileConfigToLocal(allocator, &options) catch |err| {
        try io_helpers.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(options.client_log_level);

    return runBrokerClient(allocator, args, options);
}

fn writeLocalArgError(err: anyerror) !void {
    switch (err) {
        error.MissingClientListTarget => try io_helpers.writeAll(2, "sessh: --client requires a value: " ++ client_list_target_help ++ "\n"),
        error.MissingKillTarget => try io_helpers.writeAll(2, "sesshmux: kill requires --all, a guid, or --current\n"),
        error.MissingCurrentSession => try io_helpers.writeAll(2, "sesshmux: --current requires $SESSH_GUID\n"),
        error.MissingHost => try io_helpers.writeAll(2, "sesshmux: --host requires a value\n"),
        error.MissingId => try io_helpers.writeAll(2, "sesshmux: --id requires a value\n"),
        error.InvalidLocalHost => try io_helpers.writeAll(2, "sesshmux: local commands only accept --host .\n"),
        error.DetachedCaptureUnsupported => try io_helpers.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n"),
        else => try io_helpers.stderrPrint("sessh: invalid . arguments: {t}\n", .{err}),
    }
}

pub fn runLocalNewSession(allocator: std.mem.Allocator, request: LocalNewSessionRequest) !void {
    if (request.new_detached and request.capture_tty_transcript != null) {
        try io_helpers.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n");
        return process_exit.request(64);
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (request.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    const generated_guid = try session_registry.generateGuid(allocator);
    defer allocator.free(generated_guid);

    const runtime_broker_args: []const []const u8 = &.{};
    var child = try startLocalBroker(allocator, request.exe, runtime_broker_args);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    if (request.new_detached) {
        var created = createSessionOnRuntime(
            child_read_fd,
            child_write_fd,
            request.scrollback_row_count,
            generated_guid,
            request.command_argv,
            request.shell_command,
            null,
            request.reap_ms,
            request.tombstone_retention_ms,
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime create failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        defer created.deinit();
        try session_registry.writeLocalRoute(allocator, created.guid, created.session_dir, config.version, request.tombstone_retention_ms);
        session_registry.markRouteDetachedNow(allocator, created.guid) catch |err| {
            client_log.debug("event=local_route_detached_mark_failed session={s} error={t}", .{ created.guid, err });
        };
        closeChildStdin(&child);
        _ = child.wait() catch {};
        var created_buf: [128]u8 = undefined;
        const created_line = try std.fmt.bufPrint(&created_buf, "CREATED {s}\n", .{created.guid});
        try io_helpers.writeAll(1, created_line);
        return;
    }

    var session = startNewSessionOnRuntime(
        child_read_fd,
        child_write_fd,
        request.scrollback_row_count,
        generated_guid,
        request.command_argv,
        request.shell_command,
        null,
        request.reap_ms,
        request.tombstone_retention_ms,
    ) catch |err| {
        if (process_exit.is(err)) return err;
        terminateChild(&child);
        try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    try session_registry.writeLocalRoute(allocator, session.guidSlice(), session.sessionDirSlice(), config.version, request.tombstone_retention_ms);
    writeClientRouteHintForSession(allocator, &session);
    defer removeClientRouteHintForSession(allocator, &session);

    while (true) {
        const end = relayRuntimeSession(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                writeDetachOverlayForTarget(&.{}, ".", request.overlay_args, session.idSlice());
                if (session.kill_requested) writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.spawnLocalKillJsonl(allocator, request.exe, &.{session.guidSlice()});
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, request.exe, &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreRelayEndPresentationForExit();
                closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                terminateChild(&child);
            },
            .transport_closed => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!anySessionExistsViaBroker(allocator, request.exe, runtime_broker_args)) {
                    session.restoreRelayEndPresentationForExit();
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\n");
        try io_helpers.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io_helpers.writeAll(2, "\r\n");
        child = startLocalBroker(allocator, request.exe, runtime_broker_args) catch |err| {
            session.restoreRelayEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            session.restoreRelayEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn runBrokerClient(allocator: std.mem.Allocator, args: []const []const u8, options: LocalOptions) !void {
    if (options.capture_tty_transcript != null and options.action != .new and options.action != .attach) {
        try io_helpers.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }

    const runtime_broker_args: []const []const u8 = &.{};
    switch (options.action) {
        .list => {
            if (options.list_client_target != null) {
                const exit_status = runLocalClientListCommand(allocator, args[0], runtime_broker_args, options) catch |err| switch (err) {
                    error.MissingSessionRef => {
                        try io_helpers.writeAll(2, "sessh: list --client=session requires $SESSH_GUID\n");
                        return process_exit.request(64);
                    },
                    else => return err,
                };
                if (exit_status != 0) return process_exit.request(exit_status);
                return;
            }
            const exit_status = try route_commands.runLocalListCommand(allocator, args[0], runtime_broker_args, options.list_refresh, options.list_include_cached_routes, options.list_jsonl, options.list_exited, options.list_all, null);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var kill_refs: ?LocalKillRefs = null;
            defer if (kill_refs) |*refs| refs.deinit(allocator);
            if (options.kill_request_args.len == 0) {
                kill_refs = resolveLocalKillRefs(allocator, options) catch |err| switch (err) {
                    error.MissingCurrentSession => {
                        try writeLocalArgError(err);
                        return process_exit.request(64);
                    },
                    error.MissingKillTarget => {
                        try writeLocalArgError(err);
                        return process_exit.request(64);
                    },
                    else => return err,
                };
            }
            var command_args: std.ArrayList([]const u8) = .empty;
            defer command_args.deinit(allocator);
            try command_args.appendSlice(allocator, runtime_broker_args);
            try command_args.append(allocator, "kill");
            if (options.kill_jsonl) try command_args.append(allocator, "--jsonl");
            try command_args.appendSlice(allocator, options.kill_request_args);
            if (kill_refs) |refs| try command_args.appendSlice(allocator, refs.refs);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args.items);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill_all => {
            var command_args: std.ArrayList([]const u8) = .empty;
            defer command_args.deinit(allocator);
            try command_args.appendSlice(allocator, runtime_broker_args);
            try command_args.append(allocator, "kill");
            if (options.kill_jsonl) try command_args.append(allocator, "--jsonl");
            try command_args.append(allocator, "--all");
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args.items);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .detach_client, .repaint_client, .debug_client => {
            const exit_status = runLocalClientControlCommand(allocator, args[0], runtime_broker_args, options) catch |err| switch (err) {
                error.MissingSessionRef => {
                    try io_helpers.writeAll(2, "sessh: client command requires an ID outside a sessh session\n");
                    return process_exit.request(64);
                },
                error.AmbiguousClientId => {
                    try io_helpers.writeAll(2, "sessh: client id is ambiguous\n");
                    return process_exit.request(1);
                },
                error.InvalidClientId => {
                    try io_helpers.writeAll(2, "sessh: invalid client id\n");
                    return process_exit.request(64);
                },
                else => return err,
            };
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .new, .attach => {},
    }

    if (options.action == .new) {
        return runLocalNewSession(allocator, .{
            .exe = args[0],
            .new_detached = options.new_detached,
            .scrollback_row_count = options.scrollback_row_count,
            .reap_ms = options.reap_ms,
            .tombstone_retention_ms = options.tombstone_retention_ms,
            .overlay_args = options.overlay_args.slice(),
            .capture_tty_transcript = options.capture_tty_transcript,
        });
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (options.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    var compat_attach_id: ?[]u8 = null;
    defer if (compat_attach_id) |id| allocator.free(id);
    if (options.action == .attach and options.attach_id == null and options.compat_mode) {
        // Compat callers set SESSH_GUID when they already know the intended
        // session. Prefer that over the older "latest detached" behavior.
        compat_attach_id = std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
    }

    var child = try startLocalBroker(allocator, args[0], runtime_broker_args);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    var session = (switch (options.action) {
        .attach => startAttachSessionOnRuntime(
            child_read_fd,
            child_write_fd,
            options.attach_id orelse compat_attach_id orelse "",
            "",
            options.initial_scrollback_row_count,
            null,
        ),
        .new, .list, .kill, .kill_all, .detach_client, .repaint_client, .debug_client => unreachable,
    }) catch |err| {
        if (process_exit.is(err)) return err;
        terminateChild(&child);
        try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    if (options.action == .attach and session.guidSlice().len > 0) {
        session_registry.markRouteAttached(allocator, session.guidSlice()) catch |err| {
            client_log.debug("event=local_route_attached_mark_failed session={s} error={t}", .{ session.guidSlice(), err });
        };
    }
    writeClientRouteHintForSession(allocator, &session);
    defer removeClientRouteHintForSession(allocator, &session);

    while (true) {
        const end = relayRuntimeSession(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                writeDetachOverlayForTarget(&.{}, ".", options.overlay_args.slice(), session.idSlice());
                if (session.kill_requested) writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.spawnLocalKillJsonl(allocator, args[0], &.{session.guidSlice()});
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, args[0], &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreRelayEndPresentationForExit();
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreRelayEndPresentationForExit();
                closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                terminateChild(&child);
            },
            .transport_closed => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!anySessionExistsViaBroker(allocator, args[0], runtime_broker_args)) {
                    session.restoreRelayEndPresentationForExit();
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\n");
        try io_helpers.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io_helpers.writeAll(2, "\r\n");
        child = startLocalBroker(allocator, args[0], runtime_broker_args) catch |err| {
            session.restoreRelayEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            session.restoreRelayEndPresentationForExit();
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn appendBrokerCommand(
    runtime_args: []const []const u8,
    command: []const u8,
    value: ?[]const u8,
    buf: [][]const u8,
) []const []const u8 {
    @memcpy(buf[0..runtime_args.len], runtime_args);
    buf[runtime_args.len] = command;
    if (value) |arg| {
        buf[runtime_args.len + 1] = arg;
        return buf[0 .. runtime_args.len + 2];
    }
    return buf[0 .. runtime_args.len + 1];
}

const ClientSessionResolution = struct {
    session_ref: ?[]u8 = null,
    client_route: ?session_registry.Route = null,

    fn deinit(self: *ClientSessionResolution, allocator: std.mem.Allocator) void {
        if (self.client_route) |*route| route.deinit(allocator);
        if (self.session_ref) |ref| allocator.free(ref);
        self.* = undefined;
    }
};

fn runLocalClientListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    runtime_broker_args: []const []const u8,
    options: LocalOptions,
) !u8 {
    const target = options.list_client_target orelse return error.MissingSessionRef;
    if (try remoteRouteForClientListTarget(allocator, target)) |route| {
        var route_copy = route;
        defer route_copy.deinit(allocator);
        const remote_target = if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) target else route_copy.guid;
        return runRemoteClientListCommand(allocator, exe, &route_copy, remote_target, options.list_jsonl);
    }

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(allocator);
    var client_arg: ?[]u8 = null;
    defer if (client_arg) |arg| allocator.free(arg);
    try command_args.appendSlice(allocator, runtime_broker_args);
    try command_args.append(allocator, "list");
    client_arg = try std.fmt.allocPrint(allocator, "--client={s}", .{target});
    try command_args.append(allocator, client_arg.?);
    if (options.list_jsonl) try command_args.append(allocator, "--jsonl");
    return runLocalBrokerCommand(allocator, exe, command_args.items);
}

fn remoteRouteForClientListTarget(allocator: std.mem.Allocator, target: []const u8) !?session_registry.Route {
    if (std.mem.eql(u8, target, "incoming") or
        std.mem.eql(u8, target, "outgoing") or
        std.mem.eql(u8, target, "session"))
    {
        return null;
    }
    if (std.mem.startsWith(u8, target, session_registry.client_guid_prefix)) {
        var route = session_registry.readRouteForClientGuid(allocator, target) catch |err| switch (err) {
            error.FileNotFound, error.InvalidClientId, error.AmbiguousClientId => return null,
            else => return err,
        };
        errdefer route.deinit(allocator);
        if (routeIsRemote(&route)) return route;
        route.deinit(allocator);
        return null;
    }
    var route = session_registry.readRouteForRef(allocator, target) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer route.deinit(allocator);
    if (routeIsRemote(&route)) return route;
    route.deinit(allocator);
    return null;
}

fn runRemoteClientListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    target: []const u8,
    jsonl: bool,
) !u8 {
    var client_arg: ?[]u8 = null;
    defer if (client_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, "list");
    try argv.appendSlice(allocator, route.ssh_options);
    try argv.append(allocator, "--host");
    try argv.append(allocator, route.host);
    client_arg = try std.fmt.allocPrint(allocator, "--client={s}", .{target});
    try argv.append(allocator, client_arg.?);
    if (jsonl) try argv.append(allocator, "--jsonl");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try io_helpers.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
    return switch (result.term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn runLocalClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    runtime_broker_args: []const []const u8,
    options: LocalOptions,
) !u8 {
    var session_resolution = try resolveClientControlSessionRef(allocator, options.client_session_ref, options.client_guid);
    defer session_resolution.deinit(allocator);
    if (session_resolution.client_route) |*route| {
        if (routeIsRemote(route)) {
            return runRemoteClientControlCommand(allocator, exe, route, options);
        }
    }
    var debug_seconds_arg: ?[]u8 = null;
    defer if (debug_seconds_arg) |arg| allocator.free(arg);

    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(allocator);
    try command_args.appendSlice(allocator, runtime_broker_args);
    switch (options.action) {
        .detach_client => try command_args.append(allocator, "detach"),
        .repaint_client => try command_args.append(allocator, "repaint"),
        .debug_client => {
            try command_args.append(allocator, "debug");
            try command_args.append(allocator, switch (options.debug_client_action.?) {
                .sever_connection => "sever-connection",
                .unresponsive_connection => "unresponsive-connection",
            });
        },
        else => unreachable,
    }
    switch (options.client_target) {
        .default => {},
        .all => try command_args.append(allocator, "--all"),
        .last_input => try command_args.append(allocator, "--last-input"),
        .client_guid => {
            try command_args.append(allocator, options.client_guid.?);
        },
    }
    if (options.client_repaint_scrollback) try command_args.append(allocator, "--scrollback");
    if (options.debug_unresponsive_seconds) |seconds| {
        const seconds_arg = try std.fmt.allocPrint(allocator, "{d}", .{seconds});
        debug_seconds_arg = seconds_arg;
        try command_args.append(allocator, "--seconds");
        try command_args.append(allocator, seconds_arg);
    }
    if (session_resolution.session_ref) |session_ref| try command_args.append(allocator, session_ref);
    return runLocalBrokerCommand(allocator, exe, command_args.items);
}

fn resolveClientSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8) ![]u8 {
    if (explicit_ref) |ref| return allocator.dupe(u8, ref);
    return std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingSessionRef,
        else => err,
    };
}

const LocalKillRefs = struct {
    refs: []const []const u8,
    owned_refs: ?[]const []const u8 = null,
    owned_current: ?[]u8 = null,

    fn deinit(self: *LocalKillRefs, allocator: std.mem.Allocator) void {
        if (self.owned_refs) |value| allocator.free(value);
        if (self.owned_current) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn resolveLocalKillRefs(allocator: std.mem.Allocator, options: LocalOptions) !LocalKillRefs {
    if (options.kill_ids.len > 0) return .{ .refs = options.kill_ids };
    if (options.kill_current) {
        const current = resolveClientSessionRef(allocator, null) catch |err| switch (err) {
            error.MissingSessionRef => return error.MissingCurrentSession,
            else => return err,
        };
        const refs = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(refs);
        refs[0] = current;
        return .{ .refs = refs, .owned_refs = refs, .owned_current = current };
    }
    return error.MissingKillTarget;
}

fn resolveClientControlSessionRef(allocator: std.mem.Allocator, explicit_ref: ?[]const u8, client_guid: ?[]const u8) !ClientSessionResolution {
    if (explicit_ref) |ref| {
        return .{ .session_ref = try allocator.dupe(u8, ref) };
    }

    if (client_guid) |guid| {
        const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (socket_path) |path| {
            allocator.free(path);
            return .{};
        }

        var route = session_registry.readRouteForClientGuid(allocator, guid) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        errdefer route.deinit(allocator);
        return .{
            .session_ref = try allocator.dupe(u8, route.guid),
            .client_route = route,
        };
    }

    return .{ .session_ref = try resolveClientSessionRef(allocator, null) };
}

fn routeIsRemote(route: *const session_registry.Route) bool {
    return route.host.len > 0 and !std.mem.eql(u8, route.host, ".");
}

// A client-id lookup can resolve to a cached remote route. Re-enter the mux CLI
// with that host so the existing ssh transport path runs the broker command.
fn runRemoteClientControlCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    route: *const session_registry.Route,
    options: LocalOptions,
) !u8 {
    var debug_seconds_arg: ?[]u8 = null;
    defer if (debug_seconds_arg) |arg| allocator.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    switch (options.action) {
        .detach_client => {
            try argv.append(allocator, "detach");
        },
        .repaint_client => {
            try argv.append(allocator, "repaint");
        },
        .debug_client => {
            try argv.append(allocator, "debug");
        },
        else => unreachable,
    }
    try argv.appendSlice(allocator, route.ssh_options);
    try argv.append(allocator, "--host");
    try argv.append(allocator, route.host);
    try argv.append(allocator, "--id");
    try argv.append(allocator, route.guid);
    if (options.action == .debug_client) {
        try argv.append(allocator, switch (options.debug_client_action.?) {
            .sever_connection => "sever-connection",
            .unresponsive_connection => "unresponsive-connection",
        });
    }
    switch (options.client_target) {
        .default => {},
        .all => try argv.append(allocator, "--all"),
        .last_input => try argv.append(allocator, "--last-input"),
        .client_guid => {
            try argv.append(allocator, options.client_guid.?);
        },
    }
    if (options.client_repaint_scrollback) try argv.append(allocator, "--scrollback");
    if (options.debug_unresponsive_seconds) |seconds| {
        const seconds_arg = try std.fmt.allocPrint(allocator, "{d}", .{seconds});
        debug_seconds_arg = seconds_arg;
        try argv.append(allocator, "--seconds");
        try argv.append(allocator, seconds_arg);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try io_helpers.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
    return switch (result.term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn startLocalBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !std.process.Child {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn runLocalBrokerCommand(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(config.client_version_env, config.version);

    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn anySessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) bool {
    return brokerListMatches(allocator, exe, broker_args, null);
}

fn brokerListMatches(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8, session_id: ?[]const u8) bool {
    const argv = allocator.alloc([]const u8, 4 + broker_args.len) catch return false;
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2 .. 2 + broker_args.len], broker_args);
    argv[2 + broker_args.len] = "list";
    argv[3 + broker_args.len] = "--jsonl";
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (session_id) |id| return listContainsSession(result.stdout, id);
    return listHasAnySession(result.stdout);
}

fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}

fn parseLocalOptions(allocator: std.mem.Allocator, args: []const []const u8) !LocalOptions {
    return parseLocalOptionsWithCompatMode(allocator, args, compatModeFromEnv());
}

fn compatModeFromEnv() bool {
    const value_z = c.getenv(config.compat_env) orelse return false;
    return std.mem.eql(u8, std.mem.span(value_z), "1");
}

fn parseLocalOptionsWithCompatMode(allocator: std.mem.Allocator, args: []const []const u8, compat_mode: bool) !LocalOptions {
    var options = LocalOptions{};
    errdefer options.deinit(allocator);
    options.compat_mode = compat_mode;
    var i: usize = 1;

    // Process-wide options may appear before the command word. Command flags
    // are parsed only after the command is known, so one command's flags do not
    // accidentally become valid for another command.
    while (i < args.len) {
        if (try parseLocalPreCommandOption(args, &i, &options)) continue;
        break;
    }

    if (i >= args.len) return try validateLocalOptions(options);

    // Pick the command before parsing command flags. This keeps options such as
    // `--all` scoped to the commands that actually understand them.
    const command = args[i];
    if (std.mem.eql(u8, command, "new")) {
        try setAction(&options, .new);
        i += 1;
        try parseLocalNewOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "list")) {
        try setAction(&options, .list);
        i += 1;
        try parseLocalListOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "detach")) {
        try setAction(&options, .detach_client);
        i += 1;
        try parseLocalClientControlOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "repaint")) {
        try setAction(&options, .repaint_client);
        i += 1;
        try parseLocalClientControlOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "debug")) {
        try setAction(&options, .debug_client);
        i += 1;
        try parseLocalDebugOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "attach")) {
        try setAction(&options, .attach);
        i += 1;
        try parseLocalAttachOptions(args, &i, &options);
    } else if (std.mem.eql(u8, command, "kill")) {
        i += 1;
        try parseLocalKillOptions(allocator, args, &i, &options);
    } else {
        try parseLocalNewOptions(args, &i, &options);
    }

    return try validateLocalOptions(options);
}

fn parseLocalPreCommandOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--log-level")) {
        try parseLocalLogLevel(args, index, options);
        return true;
    }
    return false;
}

fn parseLocalNewOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--detached")) {
            options.new_detached = true;
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalAttachOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.attach_id)) continue;
        break;
    }
    if (index.* < args.len and !std.mem.startsWith(u8, args[index.*], "--")) {
        if (options.attach_id != null) return error.MultipleTargets;
        options.attach_id = args[index.*];
        index.* += 1;
    }
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.attach_id)) continue;
        if (try parseLocalCommonSessionOption(args, index, options)) continue;
        return error.UnknownArgument;
    }
}

fn parseLocalListOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--refresh")) {
            options.list_refresh = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--local-only")) {
            options.list_include_cached_routes = false;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            options.list_jsonl = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.list_all = true;
            index.* += 1;
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            const value = arg["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            if (options.list_client_target != null) return error.MultipleTargets;
            options.list_client_target = value;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--client")) {
            if (options.list_client_target != null) return error.MultipleTargets;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingClientListTarget;
            options.list_client_target = args[index.*];
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--exited")) {
            options.list_exited = true;
            index.* += 1;
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".")) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalKillOptions(allocator: std.mem.Allocator, args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    try setAction(options, .kill);
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--jsonl")) {
            options.kill_jsonl = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--all")) {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            options.action = .kill_all;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--current")) {
            if (options.action == .kill_all or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            options.kill_current = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--id")) {
            if (options.action == .kill_all or options.kill_current or options.kill_request_args.len > 0) return error.MultipleTargets;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingId;
            try appendLocalKillId(allocator, options, args[index.*]);
            index.* += 1;
        } else if (std.mem.startsWith(u8, arg, "--request=") or std.mem.eql(u8, arg, "--request")) {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0) return error.MultipleTargets;
            if (options.kill_request_args.len > 0) return error.MultipleTargets;
            const start = index.*;
            while (index.* < args.len) {
                if (std.mem.startsWith(u8, args[index.*], "--request=")) {
                    index.* += 1;
                    continue;
                }
                if (std.mem.eql(u8, args[index.*], "--request")) {
                    index.* += 1;
                    if (index.* >= args.len) return error.MissingKillTarget;
                    index.* += 1;
                    continue;
                }
                break;
            }
            options.kill_request_args = args[start..index.*];
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".") and options.action == .kill and !options.kill_current and options.kill_ids.len == 0 and options.kill_request_args.len == 0) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (options.action == .kill_all or options.kill_current or options.kill_ids.len > 0 or options.kill_request_args.len > 0) return error.MultipleTargets;
            const start = index.*;
            while (index.* < args.len and !std.mem.startsWith(u8, args[index.*], "--")) {
                index.* += 1;
            }
            options.kill_ids = args[start..index.*];
            if (options.kill_ids.len > 0) options.kill_id = options.kill_ids[0];
        }
    }
}

fn parseLocalDebugOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        if (try parseLocalHostTargetOption(args, index)) continue;
        if (try parseLocalIdOption(args, index, &options.client_session_ref)) continue;
        if (try parseLocalCommonSessionOption(args, index, options)) continue;
        if (std.mem.startsWith(u8, args[index.*], "--")) return error.UnknownArgument;
        break;
    }
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugAction;
    if (std.mem.eql(u8, args[index.*], "sever-connection")) {
        options.debug_client_action = .sever_connection;
    } else if (std.mem.eql(u8, args[index.*], "unresponsive-connection")) {
        options.debug_client_action = .unresponsive_connection;
    } else {
        return error.InvalidDebugAction;
    }
    index.* += 1;
    try parseLocalClientControlOptions(args, index, options);
}

fn appendLocalKillId(allocator: std.mem.Allocator, options: *LocalOptions, id: []const u8) !void {
    const old = options.kill_ids;
    const owned = try allocator.alloc([]const u8, old.len + 1);
    errdefer allocator.free(owned);
    @memcpy(owned[0..old.len], old);
    owned[old.len] = id;
    if (options.owned_kill_ids) |previous| allocator.free(previous);
    options.owned_kill_ids = owned;
    options.kill_ids = owned;
    options.kill_id = options.kill_ids[0];
}

fn parseLocalClientControlOptions(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--all")) {
            try setClientTarget(options, .all, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            try setClientTarget(options, .last_input, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (options.action != .repaint_client) return error.UnsupportedClientTarget;
            options.client_repaint_scrollback = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (options.action != .debug_client or options.debug_client_action != .unresponsive_connection) return error.UnsupportedDebugSeconds;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugSeconds;
            options.debug_unresponsive_seconds = try parseDebugUnresponsiveSeconds(args[index.*]);
            index.* += 1;
        } else if (try parseLocalHostTargetOption(args, index)) {
            continue;
        } else if (try parseLocalIdOption(args, index, &options.client_session_ref)) {
            continue;
        } else if (std.mem.eql(u8, arg, ".")) {
            index.* += 1;
        } else if (try parseLocalCommonSessionOption(args, index, options)) {
            continue;
        } else if (!std.mem.startsWith(u8, arg, "--") and options.client_target == .default and std.mem.startsWith(u8, arg, session_registry.client_guid_prefix)) {
            try setClientTarget(options, .client_guid, arg);
            index.* += 1;
        } else if (!std.mem.startsWith(u8, arg, "--") and options.client_session_ref == null) {
            options.client_session_ref = arg;
            index.* += 1;
        } else {
            return error.UnknownArgument;
        }
    }
}

fn parseLocalIdOption(args: []const []const u8, index: *usize, target: *?[]const u8) !bool {
    if (!std.mem.eql(u8, args[index.*], "--id")) return false;
    index.* += 1;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingId;
    if (target.* != null) return error.MultipleTargets;
    target.* = args[index.*];
    index.* += 1;
    return true;
}

fn parseLocalHostTargetOption(args: []const []const u8, index: *usize) !bool {
    if (!std.mem.eql(u8, args[index.*], "--host")) return false;
    index.* += 1;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingHost;
    if (!std.mem.eql(u8, args[index.*], ".")) return error.InvalidLocalHost;
    index.* += 1;
    return true;
}

fn parseLocalCommonSessionOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    if (try parseLocalCommonProcessOption(args, index, options)) return true;
    const arg = args[index.*];

    // Compat-mode delegates every command to an older local client and appends
    // these session-presentation options after the command. SESSH_COMPAT is the
    // behavior switch; SESSH_CLIENT_VERSION is only metadata for diagnostics.
    if (std.mem.eql(u8, arg, "--scrollback-limit")) {
        if (!options.compat_mode) return error.UnsupportedConfigOrEnvOnlyOption;
        index.* += 1;
        if (index.* >= args.len) return error.MissingScrollbackRowCount;
        options.scrollback_row_count = try client_config.parseScrollbackRowCount(args[index.*]);
        options.scrollback_row_count_set = true;
        try options.overlay_args.append(arg);
        try options.overlay_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--initial-scrollback")) {
        if (!options.compat_mode) return error.UnsupportedConfigOrEnvOnlyOption;
        index.* += 1;
        if (index.* >= args.len) return error.MissingInitialScrollback;
        options.initial_scrollback_row_count = try client_config.parseInitialScrollbackRowCount(args[index.*]);
        options.initial_scrollback_row_count_set = true;
        try options.overlay_args.append(arg);
        try options.overlay_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
        options.capture_tty_transcript = args[index.*];
        index.* += 1;
        return true;
    }
    return false;
}

fn parseLocalCommonProcessOption(args: []const []const u8, index: *usize, options: *LocalOptions) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--log-level")) {
        try parseLocalLogLevel(args, index, options);
        return true;
    }
    return false;
}

fn parseLocalLogLevel(args: []const []const u8, index: *usize, options: *LocalOptions) !void {
    const arg = args[index.*];
    index.* += 1;
    if (index.* >= args.len) return error.MissingClientLogLevel;
    options.client_log_level = try client_log.parseLevel(args[index.*]);
    options.client_log_level_set = true;
    try options.overlay_args.append(arg);
    try options.overlay_args.append(args[index.*]);
    index.* += 1;
}

fn validateLocalOptions(options: LocalOptions) !LocalOptions {
    if (options.list_refresh and options.action != .list) return error.UnsupportedListRefresh;
    if (!options.list_include_cached_routes and options.action != .list) return error.UnsupportedListLocalOnly;
    if (options.list_jsonl and options.action != .list) return error.UnsupportedListJsonl;
    if (options.list_exited and options.action != .list) return error.UnsupportedListExited;
    if (options.list_all and options.action != .list) return error.UnsupportedListAll;
    if (options.list_client_target != null and options.action != .list) return error.UnsupportedClientTarget;
    if (options.list_client_target != null and (options.list_refresh or !options.list_include_cached_routes or options.list_exited)) return error.UnsupportedClientTarget;
    if (options.list_all and (options.list_exited or options.list_client_target != null)) return error.UnsupportedListAll;
    if (options.client_target != .default and !actionSupportsClientTarget(options.action)) return error.UnsupportedClientTarget;
    if (options.client_guid != null and options.client_target != .client_guid) return error.UnsupportedClientTarget;
    if (options.client_repaint_scrollback and options.action != .repaint_client) return error.UnsupportedClientTarget;
    if (options.debug_client_action != null and options.action != .debug_client) return error.UnsupportedDebugAction;
    if (options.action == .debug_client and options.debug_client_action == null) return error.MissingDebugAction;
    if (options.debug_unresponsive_seconds != null and
        (options.action != .debug_client or options.debug_client_action != .unresponsive_connection)) return error.UnsupportedDebugSeconds;
    if (options.new_detached and options.action != .new) return error.UnsupportedClientTarget;
    if (options.new_detached and options.capture_tty_transcript != null) return error.DetachedCaptureUnsupported;
    if (options.action == .kill) {
        const target_modes: u8 = (if (options.kill_ids.len > 0) @as(u8, 1) else 0) +
            (if (options.kill_current) @as(u8, 1) else 0) +
            (if (options.kill_request_args.len > 0) @as(u8, 1) else 0);
        if (target_modes > 1) return error.MultipleTargets;
        if (target_modes == 0) return error.MissingKillTarget;
    }
    return options;
}

fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}

fn actionSupportsClientTarget(action: LocalAction) bool {
    return action == .detach_client or action == .repaint_client or action == .debug_client;
}

fn setClientTarget(options: *LocalOptions, target: ClientTarget, client_guid: ?[]const u8) !void {
    if (options.client_target != .default) return error.MultipleTargets;
    options.client_target = target;
    options.client_guid = client_guid;
}

fn applyFileConfigToLocal(allocator: std.mem.Allocator, options: *LocalOptions) !void {
    const file_config = try client_config.loadFileConfig(allocator);
    if (!options.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| options.scrollback_row_count = count;
    }
    if (!options.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        options.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (file_config.reap_ms) |ms| options.reap_ms = ms;
    if (file_config.tombstone_retention_ms) |ms| options.tombstone_retention_ms = ms;
    if (!options.client_log_level_set) {
        if (file_config.client_log_level) |level| options.client_log_level = level;
    }
}

fn setAction(options: *LocalOptions, action: LocalAction) !void {
    if (options.action_set) return error.MultipleActions;
    options.action = action;
    options.action_set = true;
}

test "parseLocalOptions keeps command flags command-specific" {
    const list_all = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--all",
    });
    try std.testing.expect(list_all.list_all);
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--current",
    }));
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--refresh",
    }));
    try std.testing.expectError(error.UnknownArgument, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "s1",
        "--exited",
    }));
    const detached_new = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--detached",
    });
    try std.testing.expect(detached_new.new_detached);
    try std.testing.expectEqual(LocalAction.new, detached_new.action);
    try std.testing.expectError(error.UnsupportedClientTarget, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "detach",
        "--scrollback",
    }));
}

test "parseLocalOptions supports compatibility options before local commands" {
    const attach = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--host",
        ".",
        "s1",
        "--scrollback-limit",
        "42",
    }, true);

    try std.testing.expectEqual(LocalAction.attach, attach.action);
    try std.testing.expect(attach.compat_mode);
    try std.testing.expectEqualStrings("s1", attach.attach_id.?);
    try std.testing.expectEqual(@as(u32, 42), attach.scrollback_row_count);

    const list = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--initial-scrollback",
        "0",
    }, true);

    try std.testing.expectEqual(LocalAction.list, list.action);
    try std.testing.expectEqual(@as(?u32, 0), list.initial_scrollback_row_count);
}

test "parseLocalOptions uses current session only when explicit" {
    try std.testing.expectError(error.MissingKillTarget, parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
    }, false));

    const current = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--current",
    }, false);
    try std.testing.expectEqual(LocalAction.kill, current.action);
    try std.testing.expect(current.kill_current);

    const all = try parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--all",
    }, false);
    try std.testing.expectEqual(LocalAction.kill_all, all.action);

    try std.testing.expectError(error.MissingKillTarget, parseLocalOptionsWithCompatMode(std.testing.allocator, &.{
        "sesshmux",
        "kill",
    }, true));
}

test "parseLocalOptions accepts id option for local route commands" {
    const debug = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "debug",
        "--host",
        ".",
        "--id",
        "s1",
        "sever-connection",
        "--all",
    });
    try std.testing.expectEqual(LocalAction.debug_client, debug.action);
    try std.testing.expectEqual(DebugClientAction.sever_connection, debug.debug_client_action.?);
    try std.testing.expectEqual(ClientTarget.all, debug.client_target);
    try std.testing.expectEqualStrings("s1", debug.client_session_ref.?);

    var kill = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--id",
        "s1",
        "--id",
        "p1",
    });
    defer kill.deinit(std.testing.allocator);
    try std.testing.expectEqual(LocalAction.kill, kill.action);
    try std.testing.expectEqual(@as(usize, 2), kill.kill_ids.len);
    try std.testing.expectEqualStrings("s1", kill.kill_ids[0]);
    try std.testing.expectEqualStrings("p1", kill.kill_ids[1]);
}

test "parseLocalOptions supports kill request mode" {
    const request_json = "{\"guid\":\"s-00000000-0000-4000-8000-000000000001\",\"requested_age_ms\":123}";
    const request = try parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--jsonl",
        "--request",
        request_json,
    });
    try std.testing.expectEqual(LocalAction.kill, request.action);
    try std.testing.expect(request.kill_jsonl);
    try std.testing.expectEqual(@as(usize, 2), request.kill_request_args.len);
    try std.testing.expectEqualStrings("--request", request.kill_request_args[0]);
    try std.testing.expectEqualStrings(request_json, request.kill_request_args[1]);

    try std.testing.expectError(error.MultipleTargets, parseLocalOptions(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--request",
        request_json,
        "s-00000000-0000-4000-8000-000000000001",
    }));
}

pub fn startNewSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    pending_kill_host: ?[]const u8,
    reap_ms: u64,
    tombstone_retention_ms: u64,
) !RuntimeSession {
    const size = terminal.currentWindowSize();
    const viewport_offset = queryInitialViewportOffset();
    var created = try createSessionOnRuntimeWithSize(
        read_fd,
        write_fd,
        size,
        scrollback_row_count,
        session_guid,
        command_argv,
        shell_command,
        pending_kill_host,
        reap_ms,
        tombstone_retention_ms,
    );
    defer created.deinit();
    const client_guid = try session_registry.generateClientGuid(app_allocator.allocator());
    defer app_allocator.allocator().free(client_guid);
    const repaint_request_seq = try sendSessionAttach(write_fd, size, viewport_offset, null, null, created.guid, client_guid, "");
    var session = try readRuntimeSession(read_fd);
    try session.setClientGuid(client_guid);
    try session.setHostGuid(created.host_guid);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn createSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    pending_kill_host: ?[]const u8,
    reap_ms: u64,
    tombstone_retention_ms: u64,
) !CreatedSession {
    return createSessionOnRuntimeWithSize(
        read_fd,
        write_fd,
        terminal.currentWindowSize(),
        scrollback_row_count,
        session_guid,
        command_argv,
        shell_command,
        pending_kill_host,
        reap_ms,
        tombstone_retention_ms,
    );
}

fn createSessionOnRuntimeWithSize(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    pending_kill_host: ?[]const u8,
    reap_ms: u64,
    tombstone_retention_ms: u64,
) !CreatedSession {
    const handshake = try runtimeHandshakeWithPeerProtocol(read_fd, write_fd);
    _ = pending_kill_host;
    const peer_supports_command_oneof = peerSupportsSessionCreateCommandOneof(handshake.peer_protocol);
    if (shell_command != null and !peer_supports_command_oneof) return error.VersionMismatch;
    var created = try sendSessionCreateAndReadCreated(
        read_fd,
        write_fd,
        size,
        scrollback_row_count,
        session_guid,
        command_argv,
        shell_command,
        peer_supports_command_oneof,
        reap_ms,
        tombstone_retention_ms,
    );
    errdefer created.deinit();
    try created.setHostGuid(handshake.hostGuidSlice());
    return created;
}

pub fn startAttachSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_ref: []const u8,
    session_dir: []const u8,
    initial_scrollback_row_count: ?u32,
    pending_kill_host: ?[]const u8,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    const handshake = try runtimeHandshakeResult(read_fd, write_fd);
    _ = pending_kill_host;
    const client_guid = try session_registry.generateClientGuid(app_allocator.allocator());
    defer app_allocator.allocator().free(client_guid);
    const repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), viewport_offset, initial_scrollback_row_count, null, session_ref, client_guid, session_dir);
    var session = try readRuntimeSession(read_fd);
    try session.setClientGuid(client_guid);
    try session.setHostGuid(handshake.hostGuidSlice());
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn ensureLocalRouteForRemoteSession(
    allocator: std.mem.Allocator,
    session: *const RuntimeSession,
    requested_ref: []const u8,
    host: []const u8,
    resolved_host: []const u8,
    port: []const u8,
    ssh_options: []const []const u8,
    tombstone_retention_ms: u64,
) !void {
    if (session.guidSlice().len == 0) return;
    _ = requested_ref;
    try session_registry.writeSshRoute(
        allocator,
        session.guidSlice(),
        session.sessionDirSlice(),
        session.hostGuidSlice(),
        host,
        resolved_host,
        port,
        ssh_options,
        config.version,
        tombstone_retention_ms,
    );
    if (session.clientGuidSlice().len > 0) {
        session_registry.writeClientRouteHint(allocator, session.clientGuidSlice(), session.guidSlice()) catch |err| {
            client_log.debug("event=client_route_hint_write_failed session={s} client={s} error={t}", .{
                session.guidSlice(),
                session.clientGuidSlice(),
                err,
            });
        };
    }
}

pub fn ensureLocalRouteForCreatedRemoteSession(
    allocator: std.mem.Allocator,
    created: *const CreatedSession,
    host: []const u8,
    resolved_host: []const u8,
    port: []const u8,
    ssh_options: []const []const u8,
    tombstone_retention_ms: u64,
) !void {
    try session_registry.writeSshRoute(
        allocator,
        created.guid,
        created.session_dir,
        created.host_guid,
        host,
        resolved_host,
        port,
        ssh_options,
        config.version,
        tombstone_retention_ms,
    );
}

pub fn removeClientRouteHintForRemoteSession(allocator: std.mem.Allocator, session: *const RuntimeSession) void {
    removeClientRouteHintForSession(allocator, session);
}

pub fn markRouteDetachedForSession(allocator: std.mem.Allocator, session: *const RuntimeSession) void {
    if (session.guidSlice().len == 0) return;
    session_registry.markRouteDetachedNow(allocator, session.guidSlice()) catch |err| {
        client_log.debug("event=route_detached_mark_failed session={s} error={t}", .{
            session.guidSlice(),
            err,
        });
    };
}

fn writeClientRouteHintForSession(allocator: std.mem.Allocator, session: *const RuntimeSession) void {
    if (session.clientGuidSlice().len == 0 or session.guidSlice().len == 0) return;
    session_registry.writeClientRouteHint(allocator, session.clientGuidSlice(), session.guidSlice()) catch |err| {
        client_log.debug("event=client_route_hint_write_failed session={s} client={s} error={t}", .{
            session.guidSlice(),
            session.clientGuidSlice(),
            err,
        });
    };
}

fn removeClientRouteHintForSession(allocator: std.mem.Allocator, session: *const RuntimeSession) void {
    if (session.clientGuidSlice().len == 0) return;
    session_registry.removeClientRouteHint(allocator, session.clientGuidSlice()) catch |err| {
        client_log.debug("event=client_route_hint_remove_failed session={s} client={s} error={t}", .{
            session.guidSlice(),
            session.clientGuidSlice(),
            err,
        });
    };
}

pub fn tombstoneLocalRouteForRemoteSession(allocator: std.mem.Allocator, session: *const RuntimeSession) !void {
    const details = session.ended_tombstone_details orelse return;
    var route = session_registry.readRouteForRef(allocator, session.guidSlice()) catch return;
    defer route.deinit(allocator);
    try session_registry.writeTombstoneForRoute(allocator, &route, details);
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
    const handshake = try runtimeHandshakeInner(read_fd, write_fd, cancelled);
    try session.setHostGuid(handshake.hostGuidSlice());
    try attachReconnectRuntimeInner(read_fd, write_fd, session, cancelled, wait_for_repaint);
}

fn attachReconnectRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
    wait_for_repaint: bool,
) !void {
    const client_guid = try session.ensureClientGuid();
    session.pending_repaint.repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), nonZeroViewportOffset(session.viewport_offset), null, &session.scrollback_cursor, session.guidSlice(), client_guid, session.sessionDirSlice());
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
                    &session.relay_end_restore,
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
            .te_client_repaint_request => {},
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

pub fn relayRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    options: RelayOptions,
) !RelayEnd {
    return relayInteractive(
        read_fd,
        write_fd,
        &session.input_escape_filter,
        &session.scrollback_cursor,
        &session.viewport_offset,
        &session.pending_repaint,
        &session.relay_end_restore,
        &session.input_ack_tracker,
        &session.paste_like_input_classifier,
        &session.kill_requested,
        &session.ended_tombstone_details,
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
            try handleDrawFrame(frame.payload, &session.relay_end_restore, &session.scrollback_cursor, &session.viewport_offset, &session.app_title_present);
            return .recovered;
        },
        .te_repaint_response => {
            const applied = try handleRepaintResponseFrame(
                frame.payload,
                &session.relay_end_restore,
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
        .te_client_repaint_request => return null,
        .te_client_detach_request => {
            var request = try protocol.decodePayload(pb.TeClientDetachRequest, app_allocator.allocator(), frame.payload);
            defer request.deinit(app_allocator.allocator());
            _ = finishRelay(.detach, &session.relay_end_restore);
            return .detach;
        },
        .te_tty_transcript_chunk => {
            try handleTtyTranscriptChunkFrame(frame.payload);
            return .recovered;
        },
        .te_session_ended => {
            try session.recordSessionEndedPayload(frame.payload);
            _ = finishRelay(.session_ended, &session.relay_end_restore);
            return .session_ended;
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            _ = finishRelay(.session_ended, &session.relay_end_restore);
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

    if (session.kill_requested) {
        if (inputRequestsImmediateKillDetach(&session.input_escape_filter, bytes, &filtered)) return .detach;
        return .wait_elapsed;
    }

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
        .kill => return .kill_detach,
        .kill_wait => return .kill_wait,
    };

    try reconnect_ui.refreshOverlayIfDiagnosticsChanged();
    return .wait_elapsed;
}

pub fn writeDetachOverlayForTarget(ssh_options: []const []const u8, target: []const u8, sessh_options: []const []const u8, session_id: []const u8) void {
    if (c.isatty(1) == 0) return;
    _ = ssh_options;
    _ = target;
    _ = sessh_options;
    writeDetachOverlayForSessionRefInner(session_id) catch {};
}

pub fn writeDetachOverlayForSessionRef(sessh_options: []const []const u8, session_ref: []const u8) void {
    if (c.isatty(1) == 0) return;
    _ = sessh_options;
    writeDetachOverlayForSessionRefInner(session_ref) catch {};
}

pub fn writeUnconfirmedKillDetachWarningForSessionRef(session_ref: []const u8) void {
    if (c.isatty(1) == 0) return;
    writeUnconfirmedKillDetachWarningForSessionRefInner(session_ref) catch {};
}

fn writeDetachOverlayForSessionRefInner(session_ref: []const u8) !void {
    var display_ref_storage: [session_registry.session_guid_prefix.len + session_registry.short_guid_hex_len]u8 = undefined;
    const display_ref = sessionRefForOverlay(session_ref, &display_ref_storage);
    try io_helpers.writeAll(1, "--- sessh: detached. Re-attach: `");
    try shell.writeArg(1, "sesshmux");
    try io_helpers.writeAll(1, " ");
    try shell.writeArg(1, "attach");
    if (display_ref.len > 0) {
        try io_helpers.writeAll(1, " ");
        try shell.writeArg(1, display_ref);
    }
    try io_helpers.writeAll(1, "` / Kill: `");
    try shell.writeArg(1, "sesshmux");
    try io_helpers.writeAll(1, " ");
    try shell.writeArg(1, "kill");
    if (display_ref.len > 0) {
        try io_helpers.writeAll(1, " ");
        try shell.writeArg(1, display_ref);
    }
    try io_helpers.writeAll(1, "` ---\r\n");
}

fn writeUnconfirmedKillDetachWarningForSessionRefInner(session_ref: []const u8) !void {
    var display_ref_storage: [session_registry.session_guid_prefix.len + session_registry.short_guid_hex_len]u8 = undefined;
    const display_ref = sessionRefForOverlay(session_ref, &display_ref_storage);
    try io_helpers.writeAll(1, "--- sessh: remote session might still be alive. Kill it with `");
    try shell.writeArg(1, "sesshmux");
    try io_helpers.writeAll(1, " ");
    try shell.writeArg(1, "kill");
    if (display_ref.len > 0) {
        try io_helpers.writeAll(1, " ");
        try shell.writeArg(1, display_ref);
    }
    try io_helpers.writeAll(1, "` ---\r\n");
}

fn sessionRefForOverlay(session_ref: []const u8, storage: *[session_registry.session_guid_prefix.len + session_registry.short_guid_hex_len]u8) []const u8 {
    if (session_registry.isValidSessionGuid(session_ref)) {
        @memcpy(storage[0..session_registry.session_guid_prefix.len], session_registry.session_guid_prefix);
        var out_index: usize = session_registry.session_guid_prefix.len;
        for (session_ref[session_registry.session_guid_prefix.len..]) |byte| {
            if (byte == '-') continue;
            storage[out_index] = std.ascii.toLower(byte);
            out_index += 1;
            if (out_index == storage.len) break;
        }
        return storage[0..];
    }
    if (session_registry.isValidCompactGuid(session_ref)) {
        @memcpy(storage[0..session_registry.session_guid_prefix.len], session_registry.session_guid_prefix);
        for (session_ref[0..session_registry.short_guid_hex_len], 0..) |byte, i| {
            storage[session_registry.session_guid_prefix.len + i] = std.ascii.toLower(byte);
        }
        return storage[0..];
    }
    return session_ref;
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

fn readSessionCreated(read_fd: c.fd_t, write_fd: c.fd_t) !CreatedSession {
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
            .te_session_created => {
                var message = try protocol.decodePayload(pb.TeSessionCreated, app_allocator.allocator(), frame.payload);
                defer message.deinit(app_allocator.allocator());
                return .{
                    .guid = try app_allocator.allocator().dupe(u8, message.session_guid),
                    .session_dir = try app_allocator.allocator().dupe(u8, message.session_dir),
                    .host_guid = try app_allocator.allocator().alloc(u8, 0),
                };
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
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

const PeerProtocol = struct {
    major: u32,
    minor: u32,
};

const RuntimeHandshakeResult = struct {
    peer_protocol: PeerProtocol,
    host_guid: [session_registry.host_guid_len]u8 = [_]u8{0} ** session_registry.host_guid_len,
    host_guid_len: usize = 0,

    fn setHostGuid(self: *RuntimeHandshakeResult, host_guid: []const u8) !void {
        if (!session_registry.isValidHostGuid(host_guid)) return error.InvalidHostGuid;
        if (host_guid.len > self.host_guid.len) return error.HostGuidTooLarge;
        @memcpy(self.host_guid[0..host_guid.len], host_guid);
        self.host_guid_len = host_guid.len;
    }

    fn hostGuidSlice(self: *const RuntimeHandshakeResult) []const u8 {
        return self.host_guid[0..self.host_guid_len];
    }
};

pub fn runtimeHandshake(read_fd: c.fd_t, write_fd: c.fd_t) !void {
    _ = try runtimeHandshakeResult(read_fd, write_fd);
}

fn runtimeHandshakeResult(read_fd: c.fd_t, write_fd: c.fd_t) !RuntimeHandshakeResult {
    return runtimeHandshakeInner(read_fd, write_fd, null);
}

fn runtimeHandshakeWithPeerProtocol(read_fd: c.fd_t, write_fd: c.fd_t) !RuntimeHandshakeResult {
    return runtimeHandshakeInner(read_fd, write_fd, null);
}

fn runtimeHandshakeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !RuntimeHandshakeResult {
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
    var result = RuntimeHandshakeResult{
        .peer_protocol = .{
            .major = peer_hello.protocol_major,
            .minor = peer_hello.protocol_minor,
        },
    };
    if (helloRequestIsCompatible(peer_hello)) {
        try sendHelloOk(write_fd);
    } else {
        try sendHelloError(write_fd, "VERSION_MISMATCH", "existing remote sessh is incompatible with this client", "");
        return error.VersionMismatch;
    }
    try readHostGuidFrame(read_fd, write_fd, cancelled, &result);
    return result;
}

fn peerSupportsSessionCreateCommandOneof(peer: PeerProtocol) bool {
    // Older peers understand field 7, but they do not know the newer command
    // fields. Use the legacy field for argv-preserving commands and reject
    // shell-eval commands before SessionCreate so `sessh -t HOST cmd...` never
    // turns into an accidental interactive shell on an older broker.
    return peer.major > 2 or (peer.major == 2 and peer.minor >= 1);
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

fn readHostGuidFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
    result: *RuntimeHandshakeResult,
) !void {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .host_guid => {
                var message = try protocol.decodePayload(pb.HostGuid, app_allocator.allocator(), frame.payload);
                defer message.deinit(app_allocator.allocator());
                try result.setHostGuid(message.host_guid);
                return;
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            else => return error.UnexpectedFrame,
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

fn sendSessionCreateAndReadCreated(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    peer_supports_command_oneof: bool,
    reap_ms: u64,
    tombstone_retention_ms: u64,
) !CreatedSession {
    try sendSessionCreate(write_fd, size, scrollback_row_count, session_guid, command_argv, shell_command, peer_supports_command_oneof, reap_ms, tombstone_retention_ms);
    return readSessionCreated(read_fd, write_fd);
}

fn sendSessionCreate(
    conn: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    peer_supports_command_oneof: bool,
    reap_ms: u64,
    tombstone_retention_ms: u64,
) !void {
    if (command_argv.len > 0 and shell_command != null) return error.InvalidSessionCommand;
    var message = pb.TeSessionCreate{
        .terminal_size = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
        },
        .scrollback_row_limit = scrollback_row_count,
        .session_guid = session_guid,
        .reap_ms = reap_ms,
        .tombstone_retention_ms = tombstone_retention_ms,
    };
    defer message.environment.deinit(app_allocator.allocator());
    defer message.legacy_command_argv.deinit(app_allocator.allocator());
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
    } else if (command_argv.len > 0 and peer_supports_command_oneof) {
        try exec_command.argv.appendSlice(app_allocator.allocator(), command_argv);
        message.command = .{ .exec_command = exec_command };
    } else {
        try message.legacy_command_argv.appendSlice(app_allocator.allocator(), command_argv);
    }
    const default_colors = queryDefaultColorsForSession();
    message.query_default_colors = .{
        .foreground_color = default_colors.foreground_color,
        .background_color = default_colors.background_color,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .te_session_create, payload);
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
    client_guid: []const u8,
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
        .client_guid = client_guid,
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

fn listContainsSession(stdout: []const u8, session_id: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, app_allocator.allocator(), line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const id = jsonStringField(object, "id") orelse "";
        const guid = jsonStringField(object, "guid") orelse "";
        if (std.mem.eql(u8, id, session_id) or std.mem.eql(u8, guid, session_id)) return true;
    }
    return false;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn listHasAnySession(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) return true;
    }
    return false;
}

fn relayInteractive(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    relay_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    kill_requested: *bool,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
    app_title_present: *?bool,
    options: RelayOptions,
) !RelayEnd {
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

    const end = try relayTerminal(
        0,
        read_fd,
        write_fd,
        input_escape_filter,
        &presentation_guard,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        relay_end_restore,
        input_ack_tracker,
        paste_like_input_classifier,
        kill_requested,
        ended_tombstone_details,
        app_title_present,
        options,
    );
    if (end == .detach) writeDetachBoundary();
    return end;
}

fn relayTerminal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    presentation_guard: *client_renderer.PresentationGuard,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    relay_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    kill_requested: *bool,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
    app_title_present: *?bool,
    options: RelayOptions,
) !RelayEnd {
    _ = kill_requested;
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
            if (try drainRelayRuntimeFrames(
                read_fd,
                write_fd,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                relay_end_restore,
                input_ack_tracker,
                ended_tombstone_details,
                app_title_present,
            )) |end| return finishRelay(end, relay_end_restore);
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishRelay(requestSessionDetach(read_fd, write_fd), relay_end_restore);
            io_helpers.noteRead(input_fd, buf[0..@intCast(n)]);
            const result = input_escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) {
                const paste_like = paste_like_input_classifier.classify(result.bytes.len);
                sendInputChunks(write_fd, result.bytes, input_ack_tracker, paste_like) catch |err| switch (err) {
                    error.WriteFailed => return try finishRelayAfterRuntimeWriteFailed(
                        read_fd,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        relay_end_restore,
                        input_ack_tracker,
                        ended_tombstone_details,
                        app_title_present,
                    ),
                    else => return err,
                };
                connection_monitor.afterInput();
            }
            if (result.end) |end| switch (end) {
                .detach => return finishRelay(requestSessionDetach(read_fd, write_fd), relay_end_restore),
                .kill => return finishRelay(.kill_detach, relay_end_restore),
                .kill_wait => return finishRelay(.kill_wait, relay_end_restore),
                .help => {
                    if (try showEscapeHelpModal(
                        input_fd,
                        read_fd,
                        write_fd,
                        viewport_offset,
                        pending_repaint,
                        input_ack_tracker,
                        ended_tombstone_details,
                    )) |modal_end| return finishRelay(modal_end, relay_end_restore);
                },
                .repaint => sendRepaint(write_fd, "", pending_repaint) catch |err| switch (err) {
                    error.WriteFailed => return try finishRelayAfterRuntimeWriteFailed(
                        read_fd,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        relay_end_restore,
                        input_ack_tracker,
                        ended_tombstone_details,
                        app_title_present,
                    ),
                    else => return err,
                },
            };
        }

        maybeSendResize(write_fd, &last_size, scrollback_cursor, viewport_offset, pending_repaint) catch |err| switch (err) {
            error.WriteFailed => return try finishRelayAfterRuntimeWriteFailed(
                read_fd,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                relay_end_restore,
                input_ack_tracker,
                ended_tombstone_details,
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
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
) !?RelayEnd {
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
                ended_tombstone_details,
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
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
) !?RelayEnd {
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

        if (try handleEscapeHelpRuntimeFrame(read_fd, write_fd, input_ack_tracker, ended_tombstone_details)) |end| return end;
    }
}

fn handleEscapeHelpRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_ack_tracker: *InputAckTracker,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
) !?RelayEnd {
    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        // The overlay sits on top of the last rendered screen. Applying remote
        // draws here would interleave two renderers; repaint-after-dismiss is
        // the boundary that gets us back to a single source of screen truth.
        .te_draw, .te_repaint_response, .te_client_repaint_request => return null,
        .te_client_detach_request => {
            var request = try protocol.decodePayload(pb.TeClientDetachRequest, app_allocator.allocator(), frame.payload);
            defer request.deinit(app_allocator.allocator());
            return .detach;
        },
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
            if (ended_tombstone_details) |details| {
                var ended = try protocol.decodePayload(pb.TeSessionEnded, app_allocator.allocator(), frame.payload);
                defer ended.deinit(app_allocator.allocator());
                details.* = tombstoneDetailsFromSessionEnded(ended);
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

fn drainRelayRuntimeFrames(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    relay_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
    app_title_present: *?bool,
) !?RelayEnd {
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

        if (try handleRelayRuntimeFrame(
            read_fd,
            write_fd,
            connection_monitor,
            scrollback_cursor,
            viewport_offset,
            pending_repaint,
            relay_end_restore,
            input_ack_tracker,
            ended_tombstone_details,
            app_title_present,
        )) |end| return end;
    }
}

fn finishRelayAfterRuntimeWriteFailed(
    read_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    relay_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
    app_title_present: *?bool,
) !RelayEnd {
    if (try drainRelayRuntimeFrames(
        read_fd,
        @as(c.fd_t, -1),
        connection_monitor,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        relay_end_restore,
        input_ack_tracker,
        ended_tombstone_details,
        app_title_present,
    )) |end| return finishRelay(end, relay_end_restore);
    return .transport_closed;
}

fn handleRelayRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    relay_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_tombstone_details: ?*?session_registry.TombstoneDetails,
    app_title_present: *?bool,
) !?RelayEnd {
    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .te_draw => {
            if (!pending_repaint.active()) {
                try handleDrawFrame(frame.payload, relay_end_restore, scrollback_cursor, viewport_offset, app_title_present);
            }
            return null;
        },
        .te_repaint_response => {
            _ = try handleRepaintResponseFrame(
                frame.payload,
                relay_end_restore,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                app_title_present,
            );
            return null;
        },
        .te_client_repaint_request => {
            var request = try protocol.decodePayload(pb.TeClientRepaintRequest, app_allocator.allocator(), frame.payload);
            defer request.deinit(app_allocator.allocator());
            if (request.include_scrollback) {
                sendRepaint(write_fd, "", pending_repaint) catch |err| switch (err) {
                    error.WriteFailed => return .transport_closed,
                    else => return err,
                };
            } else {
                sendScreenRepaint(write_fd, pending_repaint) catch |err| switch (err) {
                    error.WriteFailed => return .transport_closed,
                    else => return err,
                };
            }
            return null;
        },
        .te_client_detach_request => {
            var request = try protocol.decodePayload(pb.TeClientDetachRequest, app_allocator.allocator(), frame.payload);
            defer request.deinit(app_allocator.allocator());
            return .detach;
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
            if (ended_tombstone_details) |details| {
                var ended = try protocol.decodePayload(pb.TeSessionEnded, app_allocator.allocator(), frame.payload);
                defer ended.deinit(app_allocator.allocator());
                details.* = tombstoneDetailsFromSessionEnded(ended);
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

fn finishRelay(end: RelayEnd, relay_end_restore: ?*std.ArrayList(u8)) RelayEnd {
    if (end == .detach or end == .session_ended) {
        restoreRelayEndPresentationBytes(relay_end_restore);
    }
    return end;
}

fn restoreRelayEndPresentationBytes(relay_end_restore: ?*std.ArrayList(u8)) void {
    restoreRelayEndPresentationBytesToFd(1, relay_end_restore);
}

fn restoreRelayEndPresentationBytesToFd(fd: c.fd_t, relay_end_restore: ?*std.ArrayList(u8)) void {
    const restore = relay_end_restore orelse return;
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

fn checkResizeRepaintTimeout(pending_repaint: *const PendingRepaint, viewport_offset: *i32, now_ms: i64) ?RelayEnd {
    if (!pending_repaint.resizeTimedOut(now_ms)) return null;
    clearVisibleAfterResizeTimeout(viewport_offset);
    return .unresponsive;
}

fn requestSessionDetach(read_fd: c.fd_t, write_fd: c.fd_t) RelayEnd {
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
    relay_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
) !void {
    const draw = try parseDrawPayload(payload);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, relay_end_restore, scrollback_cursor, viewport_offset, app_title_present);
}

fn handleRepaintResponseFrame(
    payload: []const u8,
    relay_end_restore: ?*std.ArrayList(u8),
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
    try handleDrawPayload(draw, relay_end_restore, scrollback_cursor, viewport_offset, app_title_present);
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
    relay_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
) !void {
    try io_helpers.writeAll(1, draw.draw_bytes);
    if (relay_end_restore) |target| {
        if (draw.relay_end_restore_bytes) |restore| {
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
        .relay_end_restore_bytes = if (message.relay_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.scrollback_cursor);
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.relay_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
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

fn inputRequestsImmediateKillDetach(filter: *terminal.EscapeFilter, input: []const u8, scratch: []u8) bool {
    for (input) |byte| {
        if (byte == 0x03) return true;
    }
    const result = filter.filter(input, scratch);
    return if (result.end) |end| end == .kill else false;
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
