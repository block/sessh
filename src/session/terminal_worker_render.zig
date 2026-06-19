const std = @import("std");

const app_allocator = @import("../core/app_allocator.zig");
const client_renderer = @import("renderer.zig");
const protocol = @import("../protocol/mod.zig");
const remote_process = @import("remote_process.zig");
const terminal_worker_requests = @import("terminal_worker_requests.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");
const attached_client_router = @import("attached_client_router.zig");
const vt = @import("vt.zig");

const pb = protocol.pb;
const AttachedClient = attached_client_router.AttachedClient;
const ExitInfo = remote_process.ExitInfo;
const RepaintRequest = terminal_worker_requests.RepaintRequest;
const Session = terminal_worker_state.Session;
const encoded_scrollback_cursor_len = terminal_worker_requests.encoded_scrollback_cursor_len;
const encodeScrollbackCursor = terminal_worker_requests.encodeScrollbackCursor;

pub const ScrollbackAndScreenSnapshot = struct {
    rows: []const vt.RenderedRow,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    align_viewport: bool,
    scrollback_cursor: u64,
};

pub const ScreenSnapshot = struct {
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    align_viewport: bool,
    materialize: bool,
    scrollback_cursor: u64,
};

const DrawFrame = struct {
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    app_title_present: ?bool = null,
    attached_client_end_restore_bytes: ?[]const u8 = null,
};

const RepaintResponseFrame = struct {
    repaint_request_seq: u64,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    app_title_present: ?bool = null,
    attached_client_end_restore_bytes: ?[]const u8 = null,
};

const RepaintDrawRequest = struct {
    repaint_request_seq: u64,
    clear_for_replace: bool,
    truncated_rows: u64,
    rows: []const vt.RenderedRow,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    scrollback_cursor: u64,
};

pub const DrawEmitter = struct {
    attached_client: *AttachedClient,
    session: *Session,

    pub fn init(attached_client: *AttachedClient, session: *Session) DrawEmitter {
        return .{
            .attached_client = attached_client,
            .session = session,
        };
    }

    pub fn emitSessionSnapshot(self: DrawEmitter) !void {
        try sendSessionSnapshot(self.attached_client, self.session);
    }

    pub fn emitRepaintSnapshot(self: DrawEmitter, request: RepaintRequest) !void {
        try sendSessionRepaintSnapshot(self.attached_client, self.session, request);
    }

    pub fn emitRepaint(self: DrawEmitter, request: RepaintRequest, clear_for_replace: bool) !usize {
        return queueRepaintSnapshot(self.attached_client, self.session, request, clear_for_replace);
    }

    pub fn emitRetainedScrollbackClear(self: DrawEmitter) !void {
        try queueRetainedScrollbackClearDraw(self.attached_client, self.session);
    }

    pub fn emitScrollbackAndScreen(self: DrawEmitter, snapshot: ScrollbackAndScreenSnapshot) !void {
        try queueScrollbackRowsAndScreenDraw(self.attached_client, self.session, snapshot);
    }

    pub fn emitScreen(self: DrawEmitter, snapshot: ScreenSnapshot) !bool {
        return queueScreenDraw(self.attached_client, self.session, snapshot);
    }

    pub fn emitRenderBarrier(self: DrawEmitter, barrier: vt.RenderBarrier, scrollback_cursor: u64) !void {
        try queueRenderBarrierDraw(self.attached_client, self.session, barrier, scrollback_cursor);
    }
};

pub fn sendSessionAttached(attached_client: *AttachedClient, session: *const Session) !void {
    try attached_client.queueTerminalEmulatorFrame(.{ .session_attached = .{
        .session_guid = session.idSlice(),
    } });
}

pub fn sendSessionEnded(attached_client: *AttachedClient, reason: u8, exit_info: ExitInfo) !void {
    const exit_status: ?pb.TerminalEmulatorItem.SessionEnded.ExitStatus = switch (exit_info.kind) {
        1 => .{ .kind = .KIND_EXITED, .status = exit_info.status },
        2 => .{ .kind = .KIND_SIGNALLED, .status = exit_info.status },
        else => null,
    };
    try attached_client.queueTerminalEmulatorFrame(.{ .session_ended = .{
        .reason = switch (reason) {
            1 => .REASON_KILLED_BY_REQUEST,
            2 => .REASON_DAEMON_SHUTDOWN,
            3 => .REASON_DISCONNECTED_TIMEOUT,
            else => .REASON_PROCESS_EXITED,
        },
        .exit_status = exit_status,
        .ended_at_unix_ms = if (exit_info.ended_at_unix_ms == 0) null else exit_info.ended_at_unix_ms,
    } });
}

pub fn queueTtyTranscriptChunk(
    attached_client: *AttachedClient,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) !void {
    if (!attached_client.capture_tty_transcript or bytes.len == 0) return;
    try attached_client.queueTerminalEmulatorFrame(.{ .tty_transcript_chunk = .{
        .stream = stream,
        .data = bytes,
    } });
}

fn queueDrawFrame(
    attached_client: *AttachedClient,
    session: *const Session,
    draw: DrawFrame,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, draw.scrollback_cursor);
    try attached_client.queueTerminalEmulatorFrame(.{ .draw = .{
        .scrollback_cursor = encoded_cursor[0..],
        .viewport_offset = attached_client.presentation.protocolViewportOffset(),
        .draw_bytes = draw.draw_bytes,
        .app_title_present = draw.app_title_present,
        .attached_client_end_restore_bytes = draw.attached_client_end_restore_bytes,
    } });
}

fn appendDrawCleanup(draw_bytes: *std.ArrayList(u8)) !void {
    const renderer = client_renderer.Renderer.buffered(draw_bytes, .{ .kind = .xterm_compatible });
    try renderer.restoreOverlayPresentation();
}

fn wrapDrawInSynchronizedUpdate(draw_bytes: *std.ArrayList(u8)) !void {
    if (draw_bytes.items.len == 0) return;
    try draw_bytes.insertSlice(app_allocator.allocator(), 0, "\x1b[?2026h");
    try draw_bytes.appendSlice(app_allocator.allocator(), "\x1b[?2026l");
}

fn appendAttachedClientEndRestoreBytes(
    attached_client: *const AttachedClient,
    session: *const Session,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    restore_bytes: *std.ArrayList(u8),
) !?[]const u8 {
    if (restore_screen) |primary| {
        var restore_presentation = attached_client.presentation;
        const restore_renderer = client_renderer.Renderer.buffered(restore_bytes, .{ .kind = .xterm_compatible });
        try restore_presentation.applyAttachedClientEndRestoreScreen(restore_renderer, session.rows, primary);
        return restore_bytes.items;
    }
    if (screen.active_screen == 0) return "";
    return null;
}

fn renderBarrierTargetActiveScreen(barrier: vt.RenderBarrier) u8 {
    return switch (barrier) {
        .enter_alternate_screen => 1,
        .leave_alternate_screen => 0,
    };
}

fn renderBarrierAttachedClientEndRestoreBytes(barrier: vt.RenderBarrier) []const u8 {
    return switch (barrier) {
        // The primary screen was flushed immediately before this barrier, so
        // leaving the outer alternate screen is enough to get attached-client cleanup
        // back to the user's normal terminal buffer.
        .enter_alternate_screen => "\x1b[?1049l",
        .leave_alternate_screen => "",
    };
}

pub fn queueRenderBarrierDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    barrier: vt.RenderBarrier,
    scrollback_cursor: u64,
) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attached_client.presentation.switchActiveScreen(renderer, renderBarrierTargetActiveScreen(barrier));
    if (bytes.items.len == 0) return;
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attached_client, session, .{
        .scrollback_cursor = scrollback_cursor,
        .draw_bytes = bytes.items,
        .attached_client_end_restore_bytes = renderBarrierAttachedClientEndRestoreBytes(barrier),
    });
}

fn queueScrollbackRowsDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    rows: []const vt.RenderedRow,
    scrollback_cursor: u64,
) !void {
    if (rows.len == 0) return;
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try attached_client.presentation.appendScrollbackRows(renderer, session.rows, rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attached_client, session, .{
        .scrollback_cursor = scrollback_cursor,
        .draw_bytes = bytes.items,
    });
}

pub fn queueScrollbackRowsAndScreenDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    snapshot: ScrollbackAndScreenSnapshot,
) !void {
    if (snapshot.rows.len == 0) return;
    if (snapshot.rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const plain_replay = session.pending_plain_output.items;
    if (try attached_client.presentation.canApplyPlainReplay(
        snapshot.screen,
        snapshot.align_viewport,
        plain_replay,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attached_client.presentation.assumePlainReplayScreen(session.rows, snapshot.screen);
        try queueDrawFrame(attached_client, session, .{
            .scrollback_cursor = snapshot.scrollback_cursor,
            .draw_bytes = plain_replay,
            .app_title_present = snapshot.screen.title_present,
        });
        return;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    // Screen clears first copy the old visible rows into scrollback, then draw
    // the cleared screen. After that copy, another alignment pass would only
    // add blank rows to scrollback.
    const align_after_scrollback = snapshot.align_viewport and snapshot.screen.display_clear == null;
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, snapshot.screen, align_after_scrollback);
    if (shouldClearOuterVisibleForDisplayClear(snapshot.screen)) {
        effective_align_viewport = false;
    }
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try attached_client.presentation.appendScrollbackRows(renderer, session.rows, snapshot.rows);
    if (shouldClearOuterVisibleForDisplayClear(snapshot.screen)) {
        // Full-screen clears must happen after copying the old rows. Clearing
        // first would leave those rows nowhere to go except back on screen.
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, snapshot.screen);
    }
    try attached_client.presentation.applyScreen(renderer, session.rows, snapshot.screen, true, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, snapshot.screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, snapshot.screen, snapshot.restore_screen, &restore_bytes);
    try queueDrawFrame(attached_client, session, .{
        .scrollback_cursor = snapshot.scrollback_cursor,
        .draw_bytes = bytes.items,
        .app_title_present = snapshot.screen.title_present,
        .attached_client_end_restore_bytes = restore,
    });
}

fn queueScrollbackTruncatedDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    truncated_rows: u64,
    scrollback_cursor: u64,
) !void {
    if (truncated_rows == 0) return;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attached_client, session, .{
        .scrollback_cursor = scrollback_cursor,
        .draw_bytes = bytes.items,
    });
}

fn appendScrollbackTruncatedMarker(bytes: *std.ArrayList(u8), renderer: client_renderer.Renderer, truncated_rows: u64) !void {
    const marker = try std.fmt.allocPrint(
        app_allocator.allocator(),
        "--- sessh scrollback truncated: {} lines ---",
        .{truncated_rows},
    );
    defer app_allocator.allocator().free(marker);
    try bytes.appendSlice(app_allocator.allocator(), marker);
    try renderer.newline();
}

fn updateMouseOriginAfterDraw(attached_client: *AttachedClient, screen: *const vt.RenderedScreen) void {
    if (!screenWantsMouseReporting(screen)) {
        attached_client.origin = null;
        return;
    }

    if (attached_client.presentation.full_height_rendering) {
        attached_client.origin = .{ .row = 0, .col = 0 };
    }
}

fn screenWantsMouseReporting(screen: *const vt.RenderedScreen) bool {
    return screen.modes.mouse_tracking != 0;
}

fn shouldAlignViewportForDraw(attached_client: *const AttachedClient, screen: *const vt.RenderedScreen, requested: bool) bool {
    if (screen.active_screen == 1) return false;
    return requested or
        attached_client.presentation.viewportOffsetUnknown() or
        (screenWantsMouseReporting(screen) and !attached_client.presentation.full_height_rendering);
}

fn shouldClearOuterVisibleForDisplayClear(screen: *const vt.RenderedScreen) bool {
    const clear = screen.display_clear orelse return false;
    return clear.mode == .complete;
}

pub fn queueScreenDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    snapshot: ScreenSnapshot,
) !bool {
    const plain_replay = session.pending_plain_output.items;
    if (try attached_client.presentation.canApplyPlainReplay(
        snapshot.screen,
        snapshot.align_viewport,
        plain_replay,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attached_client.presentation.assumePlainReplayScreen(session.rows, snapshot.screen);
        try queueDrawFrame(attached_client, session, .{
            .scrollback_cursor = snapshot.scrollback_cursor,
            .draw_bytes = plain_replay,
            .app_title_present = snapshot.screen.title_present,
        });
        return true;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, snapshot.screen, snapshot.align_viewport);
    if (shouldClearOuterVisibleForDisplayClear(snapshot.screen)) {
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, snapshot.screen);
        effective_align_viewport = false;
    }
    try attached_client.presentation.applyScreen(renderer, session.rows, snapshot.screen, snapshot.materialize, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, snapshot.screen);
    if (bytes.items.len > 0) {
        try appendDrawCleanup(&bytes);
        try wrapDrawInSynchronizedUpdate(&bytes);
        var restore_bytes = std.ArrayList(u8).empty;
        defer restore_bytes.deinit(app_allocator.allocator());
        const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, snapshot.screen, snapshot.restore_screen, &restore_bytes);
        try queueDrawFrame(attached_client, session, .{
            .scrollback_cursor = snapshot.scrollback_cursor,
            .draw_bytes = bytes.items,
            .app_title_present = snapshot.screen.title_present,
            .attached_client_end_restore_bytes = restore,
        });
        return true;
    }
    return false;
}

pub fn advanceScrollbackEpoch(session: *Session) void {
    session.scrollback_epoch +%= 1;
    if (session.scrollback_epoch == 0) session.scrollback_epoch = 1;
}

pub fn advanceScrollbackEpochForClear(session: *Session) void {
    advanceScrollbackEpoch(session);
    session.last_scrollback_clear_epoch = session.scrollback_epoch;
}

pub fn queueRetainedScrollbackClearDraw(attached_client: *AttachedClient, session: *Session) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try renderer.clearScrollback();
    try queueDrawFrame(attached_client, session, .{
        .scrollback_cursor = 0,
        .draw_bytes = bytes.items,
    });
}

fn queueRepaintResponseFrame(
    attached_client: *AttachedClient,
    session: *const Session,
    response: RepaintResponseFrame,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, response.scrollback_cursor);
    try attached_client.queueTerminalEmulatorFrame(.{ .repaint_response = .{
        .repaint_request_seq = response.repaint_request_seq,
        .draw = .{
            .scrollback_cursor = encoded_cursor[0..],
            .viewport_offset = attached_client.presentation.protocolViewportOffset(),
            .draw_bytes = response.draw_bytes,
            .app_title_present = response.app_title_present,
            .attached_client_end_restore_bytes = response.attached_client_end_restore_bytes,
        },
    } });
}

fn queueRepaintResponseDraw(
    attached_client: *AttachedClient,
    session: *Session,
    request: RepaintDrawRequest,
) !void {
    if (request.rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    if (request.clear_for_replace) {
        try attached_client.presentation.preparePrimaryForScrollback(renderer);
        try renderer.clearForReplace();
        attached_client.presentation.reset();
    }
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, request.screen, false);
    if (!request.clear_for_replace and shouldClearOuterVisibleForDisplayClear(request.screen)) {
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, request.screen);
        effective_align_viewport = false;
    }
    if (request.truncated_rows > 0 or request.rows.len > 0) {
        try attached_client.presentation.preparePrimaryForScrollback(renderer);
    }
    if (request.truncated_rows > 0) try appendScrollbackTruncatedMarker(&bytes, renderer, request.truncated_rows);
    try attached_client.presentation.appendScrollbackRows(renderer, session.rows, request.rows);
    try attached_client.presentation.applyScreen(renderer, session.rows, request.screen, true, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, request.screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, request.screen, request.restore_screen, &restore_bytes);
    try queueRepaintResponseFrame(attached_client, session, .{
        .repaint_request_seq = request.repaint_request_seq,
        .scrollback_cursor = request.scrollback_cursor,
        .draw_bytes = bytes.items,
        .app_title_present = request.screen.title_present,
        .attached_client_end_restore_bytes = restore,
    });
}

pub fn queueRepaintSnapshot(
    attached_client: *AttachedClient,
    session: *Session,
    request: RepaintRequest,
    clear_for_replace: bool,
) !usize {
    const model = session.terminal_model orelse return 0;
    var screen = try model.renderedScreen(app_allocator.allocator());
    defer screen.deinit(app_allocator.allocator());

    var primary_screen: ?vt.RenderedScreen = null;
    defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
    if (screen.active_screen == 1) {
        primary_screen = try model.renderedPrimaryScreen(app_allocator.allocator());
    }

    // Retained scrollback is owned by the remote terminal worker only for the
    // currently visible client recovering after a dropped transport. There is
    // no detached reattach flow; the cursor below is just the client's last
    // acknowledged point in this one session transcript.
    if (request.scrollback_cursor) |requested_cursor| {
        var scrollback = try model.scrollbackSnapshot(app_allocator.allocator());
        defer scrollback.deinit(app_allocator.allocator());

        const effective_cursor = if (requested_cursor.epoch == session.scrollback_epoch)
            requested_cursor.per_epoch_cursor
        else
            0;
        var rows_to_draw = scrollback.rows;
        var truncated_rows_to_report: u64 = 0;
        if (effective_cursor < scrollback.truncated_rows) {
            truncated_rows_to_report = scrollback.truncated_rows - effective_cursor;
        } else {
            const skip = effective_cursor -| scrollback.truncated_rows;
            if (skip >= @as(u64, @intCast(rows_to_draw.len))) {
                rows_to_draw = rows_to_draw[rows_to_draw.len..];
            } else {
                rows_to_draw = rows_to_draw[@intCast(skip)..];
            }
        }

        const clear_scrollback_for_stale_clear =
            requested_cursor.epoch != 0 and requested_cursor.epoch < session.last_scrollback_clear_epoch;
        try queueRepaintResponseDraw(attached_client, session, .{
            .repaint_request_seq = request.repaint_request_seq,
            .clear_for_replace = clear_for_replace or clear_scrollback_for_stale_clear,
            .truncated_rows = truncated_rows_to_report,
            .rows = rows_to_draw,
            .screen = &screen,
            .restore_screen = if (primary_screen) |*primary| primary else null,
            .scrollback_cursor = scrollback.absolute_count,
        });
    } else {
        const scrollback_cursor = try model.scrollbackCursor();
        try queueRepaintResponseDraw(attached_client, session, .{
            .repaint_request_seq = request.repaint_request_seq,
            .clear_for_replace = clear_for_replace,
            .truncated_rows = 0,
            .rows = &.{},
            .screen = &screen,
            .restore_screen = if (primary_screen) |*primary| primary else null,
            .scrollback_cursor = scrollback_cursor,
        });
    }

    return screen.rows.len;
}

pub fn sendSessionSnapshot(attached_client: *AttachedClient, session: *Session) !void {
    if (session.terminal_model) |model| {
        var scrollback = try model.scrollbackSnapshot(app_allocator.allocator());
        defer scrollback.deinit(app_allocator.allocator());
        var screen = try model.renderedScreen(app_allocator.allocator());
        defer screen.deinit(app_allocator.allocator());

        const rows_to_draw = scrollback.rows;
        const truncated_rows_to_report = scrollback.truncated_rows;

        if (truncated_rows_to_report > 0) {
            try queueScrollbackTruncatedDraw(attached_client, session, truncated_rows_to_report, truncated_rows_to_report);
        }
        if (rows_to_draw.len > 0) try queueScrollbackRowsDraw(attached_client, session, rows_to_draw, scrollback.absolute_count);
        var primary_screen: ?vt.RenderedScreen = null;
        defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
        if (screen.active_screen == 1) {
            primary_screen = try model.renderedPrimaryScreen(app_allocator.allocator());
        }
        _ = try queueScreenDraw(attached_client, session, .{
            .screen = &screen,
            .restore_screen = if (primary_screen) |*primary| primary else null,
            .align_viewport = false,
            .materialize = true,
            .scrollback_cursor = scrollback.absolute_count,
        });
        model.markScrollbackReported();
        model.markRendered(screen.rows.len);
        return;
    }
}

pub fn sendSessionRepaintSnapshot(attached_client: *AttachedClient, session: *Session, request: RepaintRequest) !void {
    const model = session.terminal_model orelse return;
    const screen_rows = try queueRepaintSnapshot(attached_client, session, request, false);
    model.markScrollbackReported();
    model.markRendered(screen_rows);
}
