// Converts the terminal worker's VT model into frames for the visible client.
// This is the boundary where scrollback, screen deltas, repaint responses, and
// cleanup identity are serialized into protocol messages.
const std = @import("std");

const app_allocator = @import("../core/app_allocator.zig");
const client_renderer = @import("renderer.zig");
const protocol = @import("../protocol/mod.zig");
const remote_process = @import("remote_process.zig");
const terminal_worker_requests = @import("terminal_worker_requests.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");
const tty = @import("../tty/terminal.zig");
const visible_client_router = @import("visible_client_router.zig");
const vt = @import("vt.zig");

const pb = protocol.pb;
const VisibleClient = visible_client_router.VisibleClient;
const ExitInfo = remote_process.ExitInfo;
const RepaintRequest = terminal_worker_requests.RepaintRequest;
const Session = terminal_worker_state.Session;
const encodeScrollbackCursor = terminal_worker_requests.encodeScrollbackCursor;

const ScreenDrawSnapshot = struct {
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    align_viewport: bool,
    scrollback_cursor: u64,
};

const ScrollbackAndScreenSnapshot = struct {
    rows: []const vt.RenderedRow,
    draw: ScreenDrawSnapshot,
};

const ScreenSnapshot = struct {
    draw: ScreenDrawSnapshot,
    materialize: bool,
};

const DrawFrame = struct {
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    app_title_present: ?bool = null,
    visible_client_end_restore_bytes: ?[]const u8 = null,
};

const RepaintResponseFrame = struct {
    repaint_request_seq: u64,
    draw: DrawFrame,
};

const RepaintDrawRequest = struct {
    repaint_request_seq: u64,
    clear_for_replace: bool,
    truncated_rows: u64,
    rows: []const vt.RenderedRow,
    draw: ScreenDrawSnapshot,
};

pub const DrawEmitter = struct {
    visible_client: *VisibleClient,
    session: *Session,

    pub fn init(visible_client: *VisibleClient, session: *Session) DrawEmitter {
        return .{
            .visible_client = visible_client,
            .session = session,
        };
    }

    pub fn emitSessionSnapshot(self: DrawEmitter) !void {
        try sendSessionSnapshot(self);
    }

    pub fn emitRepaintSnapshot(self: DrawEmitter, request: RepaintRequest) !void {
        try sendSessionRepaintSnapshot(self, request);
    }

    pub fn emitRepaint(self: DrawEmitter, request: RepaintRequest, clear_for_replace: bool) !usize {
        return queueRepaintSnapshot(self, request, clear_for_replace);
    }

    pub fn emitRetainedScrollbackClear(self: DrawEmitter) !void {
        try queueRetainedScrollbackClearDraw(self);
    }

    pub fn emitScrollbackAndScreen(self: DrawEmitter, snapshot: ScrollbackAndScreenSnapshot) !void {
        try queueScrollbackRowsAndScreenDraw(self, snapshot);
    }

    pub fn emitScreen(self: DrawEmitter, snapshot: ScreenSnapshot) !bool {
        return queueScreenDraw(self, snapshot);
    }

    pub fn emitRenderBarrier(self: DrawEmitter, barrier: vt.RenderBarrier) !void {
        try queueRenderBarrierDraw(self, barrier);
    }
};

pub fn sendSessionReady(visible_client: *VisibleClient, session: *const Session) !void {
    try visible_client.queueTerminalEmulatorFrame(.{ .session_ready = .{
        .session_guid = session.idSlice(),
    } });
}

pub fn sendSessionEnded(visible_client: *VisibleClient, reason: u8, exit_info: ExitInfo) !void {
    const exit_status: ?pb.TerminalEmulatorItem.SessionEnded.ExitStatus = switch (exit_info.kind) {
        1 => .{ .kind = .KIND_EXITED, .status = exit_info.status },
        2 => .{ .kind = .KIND_SIGNALLED, .status = exit_info.status },
        else => null,
    };
    try visible_client.queueTerminalEmulatorFrame(.{ .session_ended = .{
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
    visible_client: *VisibleClient,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) !void {
    if (!visible_client.capture_tty_transcript or bytes.len == 0) return;
    try visible_client.queueTerminalEmulatorFrame(.{ .tty_transcript_chunk = .{
        .stream = stream,
        .data = bytes,
    } });
}

fn queueDrawFrame(
    emitter: DrawEmitter,
    draw: DrawFrame,
) !void {
    const encoded_cursor = encodeScrollbackCursor(emitter.session.scrollback_epoch, draw.scrollback_cursor);
    const visible_client = emitter.visible_client;
    try visible_client.queueTerminalEmulatorFrame(.{ .draw = .{
        .scrollback_cursor = encoded_cursor[0..],
        .viewport_offset = visible_client.presentation.protocolViewportOffset(),
        .draw_bytes = draw.draw_bytes,
        .app_title_present = draw.app_title_present,
        .visible_client_end_restore_bytes = draw.visible_client_end_restore_bytes,
    } });
}

fn appendDrawCleanup(draw_bytes: *std.ArrayList(u8)) !void {
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(draw_bytes);
    try renderer.restoreOverlayPresentation();
}

fn wrapDrawInSynchronizedUpdate(draw_bytes: *std.ArrayList(u8)) !void {
    if (draw_bytes.items.len == 0) return;
    try draw_bytes.insertSlice(app_allocator.allocator(), 0, "\x1b[?2026h");
    try draw_bytes.appendSlice(app_allocator.allocator(), "\x1b[?2026l");
}

fn appendVisibleClientEndRestoreBytes(
    emitter: DrawEmitter,
    draw: ScreenDrawSnapshot,
    restore_bytes: *std.ArrayList(u8),
) !?[]const u8 {
    if (draw.restore_screen) |primary| {
        var restore_presentation = emitter.visible_client.presentation;
        const restore_renderer = client_renderer.Renderer.bufferedXtermCompatible(restore_bytes);
        try restore_presentation.applyVisibleClientEndRestoreScreen(restore_renderer, emitter.session.size, primary);
        return restore_bytes.items;
    }
    if (draw.screen.active_screen == 0) return "";
    return null;
}

fn renderBarrierTargetActiveScreen(barrier: vt.RenderBarrier) u8 {
    return switch (barrier) {
        .enter_alternate_screen => 1,
        .leave_alternate_screen => 0,
    };
}

fn renderBarrierVisibleClientEndRestoreBytes(barrier: vt.RenderBarrier) []const u8 {
    return switch (barrier) {
        // The primary screen was flushed immediately before this barrier, so
        // leaving the outer alternate screen is enough to restore the visible
        // client back to the user's normal terminal buffer.
        .enter_alternate_screen => "\x1b[?1049l",
        .leave_alternate_screen => "",
    };
}

fn queueRenderBarrierDraw(
    emitter: DrawEmitter,
    barrier: vt.RenderBarrier,
) !void {
    // Tell the visible client about an alternate-screen boundary after the
    // pre-barrier state has been flushed. The draw is synchronized so the outer
    // terminal does not expose an intermediate half-switched frame.
    const model = emitter.session.terminal_model orelse return;
    const scrollback_cursor = try model.scrollbackCursor();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    const visible_client = emitter.visible_client;
    try visible_client.presentation.switchActiveScreen(renderer, renderBarrierTargetActiveScreen(barrier));
    if (bytes.items.len == 0) return;
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(emitter, .{
        .scrollback_cursor = scrollback_cursor,
        .draw_bytes = bytes.items,
        .visible_client_end_restore_bytes = renderBarrierVisibleClientEndRestoreBytes(barrier),
    });
}

fn queueScrollbackRowsDraw(
    emitter: DrawEmitter,
    rows: []const vt.RenderedRow,
    scrollback_cursor: u64,
) !void {
    if (rows.len == 0) return;
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    const visible_client = emitter.visible_client;
    try visible_client.presentation.preparePrimaryForScrollback(renderer);
    try visible_client.presentation.appendScrollbackRows(renderer, emitter.session.size, rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(emitter, .{
        .scrollback_cursor = scrollback_cursor,
        .draw_bytes = bytes.items,
    });
}

// Emit retained scrollback rows and the current screen as one visible update.
// It first tries byte-for-byte replay of pending plain output for the fast path;
// if that is unsafe, it materializes the VT model into renderer operations.
fn queueScrollbackRowsAndScreenDraw(
    emitter: DrawEmitter,
    snapshot: ScrollbackAndScreenSnapshot,
) !void {
    if (snapshot.rows.len == 0) return;
    if (snapshot.rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const draw = snapshot.draw;
    const visible_client = emitter.visible_client;
    const session = emitter.session;
    const plain_replay = session.pending_plain_output.items;
    if (try visible_client.presentation.canApplyPlainReplay(.{
        .screen = draw.screen,
        .align_viewport = draw.align_viewport,
        .bytes = plain_replay,
        .parser_boundary_ok = session.pendingPlainOutputCanReplay(),
    })) {
        try visible_client.presentation.assumePlainReplayScreen(session.size, draw.screen);
        try queueDrawFrame(emitter, .{
            .scrollback_cursor = draw.scrollback_cursor,
            .draw_bytes = plain_replay,
            .app_title_present = draw.screen.title_present,
        });
        return;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    // Screen clears first copy the currently visible rows into scrollback, then
    // draw the cleared screen. After that copy, another alignment pass would
    // only add blank rows to scrollback.
    const align_after_scrollback = draw.align_viewport and draw.screen.display_clear == null;
    var effective_align_viewport = shouldAlignViewportForDraw(visible_client, draw.screen, align_after_scrollback);
    if (shouldClearOuterVisibleForDisplayClear(draw.screen)) {
        effective_align_viewport = false;
    }
    try visible_client.presentation.preparePrimaryForScrollback(renderer);
    try visible_client.presentation.appendScrollbackRows(renderer, session.size, snapshot.rows);
    if (shouldClearOuterVisibleForDisplayClear(draw.screen)) {
        // Full-screen clears must happen after copying the currently visible
        // rows. Clearing first would leave those rows nowhere to go except back
        // on screen.
        try visible_client.presentation.clearOuterVisibleForScreen(renderer, draw.screen);
    }
    try visible_client.presentation.applyScreen(renderer, .{
        .session_size = session.size,
        .screen = draw.screen,
        .force_redraw = true,
        .align_viewport = effective_align_viewport,
    });
    if (effective_align_viewport) visible_client.origin = tty.top_left_position;
    updateMouseOriginAfterDraw(visible_client, draw.screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendVisibleClientEndRestoreBytes(emitter, draw, &restore_bytes);
    try queueDrawFrame(emitter, .{
        .scrollback_cursor = draw.scrollback_cursor,
        .draw_bytes = bytes.items,
        .app_title_present = draw.screen.title_present,
        .visible_client_end_restore_bytes = restore,
    });
}

fn queueScrollbackTruncatedDraw(
    emitter: DrawEmitter,
    truncated_rows: u64,
    scrollback_cursor: u64,
) !void {
    if (truncated_rows == 0) return;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    const visible_client = emitter.visible_client;
    try visible_client.presentation.preparePrimaryForScrollback(renderer);
    try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(emitter, .{
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

fn updateMouseOriginAfterDraw(visible_client: *VisibleClient, screen: *const vt.RenderedScreen) void {
    if (!screenWantsMouseReporting(screen)) {
        visible_client.origin = null;
        return;
    }

    if (visible_client.presentation.full_height_rendering) {
        visible_client.origin = tty.top_left_position;
    }
}

fn screenWantsMouseReporting(screen: *const vt.RenderedScreen) bool {
    return screen.modes.mouse_tracking != .disabled;
}

fn shouldAlignViewportForDraw(
    visible_client: *const VisibleClient,
    screen: *const vt.RenderedScreen,
    requested_align_viewport: bool,
) bool {
    if (screen.active_screen == 1) return false;
    return requested_align_viewport or
        visible_client.presentation.viewportOffsetUnknown() or
        (screenWantsMouseReporting(screen) and !visible_client.presentation.full_height_rendering);
}

fn shouldClearOuterVisibleForDisplayClear(screen: *const vt.RenderedScreen) bool {
    const clear = screen.display_clear orelse return false;
    return clear.mode == .complete;
}

// Emit a screen-only draw. The return value tells callers whether anything was
// actually queued, which lets the worker avoid treating an unchanged model as a
// repaint boundary.
fn queueScreenDraw(
    emitter: DrawEmitter,
    snapshot: ScreenSnapshot,
) !bool {
    const draw = snapshot.draw;
    const visible_client = emitter.visible_client;
    const session = emitter.session;
    const plain_replay = session.pending_plain_output.items;
    if (try visible_client.presentation.canApplyPlainReplay(.{
        .screen = draw.screen,
        .align_viewport = draw.align_viewport,
        .bytes = plain_replay,
        .parser_boundary_ok = session.pendingPlainOutputCanReplay(),
    })) {
        try visible_client.presentation.assumePlainReplayScreen(session.size, draw.screen);
        try queueDrawFrame(emitter, .{
            .scrollback_cursor = draw.scrollback_cursor,
            .draw_bytes = plain_replay,
            .app_title_present = draw.screen.title_present,
        });
        return true;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    var effective_align_viewport = shouldAlignViewportForDraw(visible_client, draw.screen, draw.align_viewport);
    if (shouldClearOuterVisibleForDisplayClear(draw.screen)) {
        try visible_client.presentation.clearOuterVisibleForScreen(renderer, draw.screen);
        effective_align_viewport = false;
    }
    try visible_client.presentation.applyScreen(renderer, .{
        .session_size = session.size,
        .screen = draw.screen,
        .force_redraw = snapshot.materialize,
        .align_viewport = effective_align_viewport,
    });
    if (effective_align_viewport) visible_client.origin = tty.top_left_position;
    updateMouseOriginAfterDraw(visible_client, draw.screen);
    if (bytes.items.len > 0) {
        try appendDrawCleanup(&bytes);
        try wrapDrawInSynchronizedUpdate(&bytes);
        var restore_bytes = std.ArrayList(u8).empty;
        defer restore_bytes.deinit(app_allocator.allocator());
        const restore = try appendVisibleClientEndRestoreBytes(emitter, draw, &restore_bytes);
        try queueDrawFrame(emitter, .{
            .scrollback_cursor = draw.scrollback_cursor,
            .draw_bytes = bytes.items,
            .app_title_present = draw.screen.title_present,
            .visible_client_end_restore_bytes = restore,
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

fn queueRetainedScrollbackClearDraw(emitter: DrawEmitter) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    const visible_client = emitter.visible_client;
    try visible_client.presentation.preparePrimaryForScrollback(renderer);
    try renderer.clearScrollback();
    try queueDrawFrame(emitter, .{
        .scrollback_cursor = 0,
        .draw_bytes = bytes.items,
    });
}

fn queueRepaintResponseFrame(
    emitter: DrawEmitter,
    response: RepaintResponseFrame,
) !void {
    const draw = response.draw;
    const encoded_cursor = encodeScrollbackCursor(emitter.session.scrollback_epoch, draw.scrollback_cursor);
    const visible_client = emitter.visible_client;
    try visible_client.queueTerminalEmulatorFrame(.{ .repaint_response = .{
        .repaint_request_seq = response.repaint_request_seq,
        .draw = .{
            .scrollback_cursor = encoded_cursor[0..],
            .viewport_offset = visible_client.presentation.protocolViewportOffset(),
            .draw_bytes = draw.draw_bytes,
            .app_title_present = draw.app_title_present,
            .visible_client_end_restore_bytes = draw.visible_client_end_restore_bytes,
        },
    } });
}

// Build the draw payload for an explicit repaint request. Unlike incremental
// draws, repaint may need to replace the entire visible area and replay a slice
// of retained scrollback selected by the client's cursor.
fn queueRepaintResponseDraw(
    emitter: DrawEmitter,
    request: RepaintDrawRequest,
) !void {
    if (request.rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const draw = request.draw;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);
    const visible_client = emitter.visible_client;
    const session = emitter.session;
    if (request.clear_for_replace) {
        try visible_client.presentation.preparePrimaryForScrollback(renderer);
        try renderer.clearForReplace();
        visible_client.presentation.reset();
    }
    var effective_align_viewport = shouldAlignViewportForDraw(visible_client, draw.screen, draw.align_viewport);
    if (!request.clear_for_replace and shouldClearOuterVisibleForDisplayClear(draw.screen)) {
        try visible_client.presentation.clearOuterVisibleForScreen(renderer, draw.screen);
        effective_align_viewport = false;
    }
    if (request.truncated_rows > 0 or request.rows.len > 0) {
        try visible_client.presentation.preparePrimaryForScrollback(renderer);
    }
    if (request.truncated_rows > 0) try appendScrollbackTruncatedMarker(&bytes, renderer, request.truncated_rows);
    try visible_client.presentation.appendScrollbackRows(renderer, session.size, request.rows);
    try visible_client.presentation.applyScreen(renderer, .{
        .session_size = session.size,
        .screen = draw.screen,
        .force_redraw = true,
        .align_viewport = effective_align_viewport,
    });
    if (effective_align_viewport) visible_client.origin = tty.top_left_position;
    updateMouseOriginAfterDraw(visible_client, draw.screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendVisibleClientEndRestoreBytes(emitter, draw, &restore_bytes);
    try queueRepaintResponseFrame(emitter, .{
        .repaint_request_seq = request.repaint_request_seq,
        .draw = .{
            .scrollback_cursor = draw.scrollback_cursor,
            .draw_bytes = bytes.items,
            .app_title_present = draw.screen.title_present,
            .visible_client_end_restore_bytes = restore,
        },
    });
}

// Resolve the client's scrollback cursor into rows to replay, then send a
// repaint response containing those rows plus the current screen. Epoch changes
// mean the cursor came from an older clear/reset boundary and must be treated as
// stale.
fn queueRepaintSnapshot(emitter: DrawEmitter, request: RepaintRequest, clear_for_replace: bool) !usize {
    const session = emitter.session;

    const model = session.terminal_model orelse return 0;
    var screen = try model.renderedScreen(app_allocator.allocator());
    defer screen.deinit(app_allocator.allocator());

    var primary_screen: ?vt.RenderedScreen = null;
    defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
    if (screen.active_screen == 1) {
        primary_screen = try model.renderedPrimaryScreen(app_allocator.allocator());
    }

    // Retained scrollback is replayed only to the visible client recovering
    // after a dropped transport. The cursor is that client's last acknowledged
    // point in this session transcript.
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
        try queueRepaintResponseDraw(emitter, .{
            .repaint_request_seq = request.repaint_request_seq,
            .clear_for_replace = clear_for_replace or clear_scrollback_for_stale_clear,
            .truncated_rows = truncated_rows_to_report,
            .rows = rows_to_draw,
            .draw = .{
                .screen = &screen,
                .restore_screen = if (primary_screen) |*primary| primary else null,
                .align_viewport = false,
                .scrollback_cursor = scrollback.absolute_count,
            },
        });
    } else {
        const scrollback_cursor = try model.scrollbackCursor();
        try queueRepaintResponseDraw(emitter, .{
            .repaint_request_seq = request.repaint_request_seq,
            .clear_for_replace = clear_for_replace,
            .truncated_rows = 0,
            .rows = &.{},
            .draw = .{
                .screen = &screen,
                .restore_screen = if (primary_screen) |*primary| primary else null,
                .align_viewport = false,
                .scrollback_cursor = scrollback_cursor,
            },
        });
    }

    return screen.rows.len;
}

// Send the initial visible-client snapshot: retained scrollback, active screen,
// and restoration bytes for the current terminal modes. After this point the VT
// model marks those rows as reported so later draws can be deltas.
fn sendSessionSnapshot(emitter: DrawEmitter) !void {
    const session = emitter.session;
    if (session.terminal_model) |model| {
        var scrollback = try model.scrollbackSnapshot(app_allocator.allocator());
        defer scrollback.deinit(app_allocator.allocator());
        var screen = try model.renderedScreen(app_allocator.allocator());
        defer screen.deinit(app_allocator.allocator());

        const rows_to_draw = scrollback.rows;
        const truncated_rows_to_report = scrollback.truncated_rows;

        if (truncated_rows_to_report > 0) {
            try queueScrollbackTruncatedDraw(emitter, truncated_rows_to_report, truncated_rows_to_report);
        }
        if (rows_to_draw.len > 0) try queueScrollbackRowsDraw(emitter, rows_to_draw, scrollback.absolute_count);
        var primary_screen: ?vt.RenderedScreen = null;
        defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
        if (screen.active_screen == 1) {
            primary_screen = try model.renderedPrimaryScreen(app_allocator.allocator());
        }
        _ = try queueScreenDraw(emitter, .{
            .materialize = true,
            .draw = .{
                .screen = &screen,
                .restore_screen = if (primary_screen) |*primary| primary else null,
                .align_viewport = false,
                .scrollback_cursor = scrollback.absolute_count,
            },
        });
        model.markScrollbackReported();
        model.markRendered(screen.rows.len);
        return;
    }
}

fn sendSessionRepaintSnapshot(emitter: DrawEmitter, request: RepaintRequest) !void {
    const model = emitter.session.terminal_model orelse return;
    const screen_rows = try queueRepaintSnapshot(emitter, request, false);
    model.markScrollbackReported();
    model.markRendered(screen_rows);
}
