const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const client_renderer = @import("renderer.zig");
const io = @import("../core/io.zig");
const pty_process = @import("../tty/pty_process.zig");
const protocol = @import("../protocol/mod.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const vt = @import("vt.zig");

const max_attached_client_output_queue_bytes = 64 * 1024 * 1024;
const preferred_live_output_batch_bytes = 1024;
const max_live_output_reads_per_batch = 64;
const synchronized_output_max_hold_ms: i64 = 1000;
const pty_hangup_reap_poll_ms: i64 = 50;

const pb = protocol.pb;
const hpb = protocol.hpb;

const Session = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: usize = 0,
    pid: c.pid_t = 0,
    pty_fd: c.fd_t = -1,
    pty_closed_for_hangup: bool = false,
    terminal_model: ?*vt.SessionTerminal = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_epoch: u64 = 1,
    last_scrollback_clear_epoch: u64 = 1,
    end_reason: u8 = 0,
    attached: bool = false,
    disconnected_at_unix_ms: u64 = 0,
    reap_ms: u64 = 0,
    alive: bool = false,
    pending_plain_output: std.ArrayList(u8) = .empty,
    pending_plain_starts_at_boundary: bool = false,
    synchronized_output_since_ms: i64 = 0,

    fn idSlice(self: *const Session) []const u8 {
        return self.id[0..self.id_len];
    }

    fn clearPendingPlainOutput(self: *Session) void {
        self.pending_plain_output.clearRetainingCapacity();
        self.pending_plain_starts_at_boundary = false;
    }

    fn appendPendingPlainOutput(
        self: *Session,
        bytes: []const u8,
        starts_at_boundary: bool,
    ) !void {
        if (self.pending_plain_output.items.len == 0) {
            self.pending_plain_starts_at_boundary = starts_at_boundary;
        }
        try self.pending_plain_output.appendSlice(app_allocator.allocator(), bytes);
    }

    fn pendingPlainOutputCanReplay(self: *const Session) bool {
        return self.pending_plain_output.items.len > 0 and
            self.pending_plain_starts_at_boundary;
    }

    fn deinit(self: *Session) void {
        self.pending_plain_output.deinit(app_allocator.allocator());
        self.pending_plain_output = .empty;
        self.pending_plain_starts_at_boundary = false;
        self.synchronized_output_since_ms = 0;
    }
};

const AttachedClient = struct {
    fd: c.fd_t = -1,
    rows: u16 = 24,
    cols: u16 = 80,
    attached_at_unix_ms: u64 = 0,
    origin: ?TerminalOrigin = null,
    active: bool = false,
    close_after_flush: bool = false,
    debug_unresponsive_until_ms: i64 = 0,
    presentation: PresentationState = .{},
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    input_pending: [128]u8 = [_]u8{0} ** 128,
    input_pending_len: usize = 0,
    capture_tty_transcript: bool = false,

    fn queuedBytes(self: *const AttachedClient) usize {
        return self.output.items.len - self.output_offset;
    }
};

const SessionRuntime = struct {
    session: Session = .{},
    attached_client: AttachedClient = .{},
    running: bool = true,
    shutting_down: bool = false,
    monotonic_clock: ?std.time.Timer = null,
    fixed_session_id: ?[]const u8 = null,
    started_session: bool = false,
};

const RuntimeControl = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    notify_read_fd: c.fd_t,
    notify_write_fd: c.fd_t,
    pending_mutex: std.Thread.Mutex = .{},
    pending_clients: std.ArrayList(c.fd_t) = .empty,
    closed: bool = false,

    fn enqueue(self: *RuntimeControl, fd: c.fd_t) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.closed) return error.SessionNotFound;
        try self.pending_clients.append(self.allocator, fd);
        var byte = [_]u8{1};
        const n = c.write(self.notify_write_fd, &byte, byte.len);
        if (n < 0 or @as(usize, @intCast(n)) != byte.len) {
            _ = self.pending_clients.pop();
            return error.RuntimeNotifyFailed;
        }
    }

    fn takePending(self: *RuntimeControl) ?c.fd_t {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending_clients.items.len == 0) return null;
        return self.pending_clients.orderedRemove(0);
    }

    fn close(self: *RuntimeControl) void {
        self.pending_mutex.lock();
        self.closed = true;
        while (self.pending_clients.items.len > 0) {
            const fd = self.pending_clients.pop().?;
            _ = c.close(fd);
        }
        self.pending_mutex.unlock();
    }

    fn deinit(self: *RuntimeControl) void {
        self.close();
        self.pending_clients.deinit(self.allocator);
        if (self.notify_read_fd >= 0) _ = c.close(self.notify_read_fd);
        if (self.notify_write_fd >= 0) _ = c.close(self.notify_write_fd);
        self.allocator.free(self.guid);
        self.* = undefined;
    }
};

var runtime_registry_mutex = std.Thread.Mutex{};
var runtime_registry: std.ArrayList(*RuntimeControl) = .empty;

const PollKind = union(enum) {
    listen,
    shutdown_signal,
    runtime_repair,
    session,
    attached_client,
};

const HandshakeResult = enum {
    accepted,
    mismatch,
};

const ExitInfo = struct {
    kind: u8 = 0,
    status: i32 = 0,
    ended_at_unix_ms: u64 = 0,
};

const SessionEnvironment = struct {
    shell: ?[]const u8 = null,
    entries: std.ArrayList(pty_process.EnvironmentEntry) = .empty,

    fn deinit(self: *SessionEnvironment) void {
        if (self.shell) |shell| app_allocator.allocator().free(shell);
        for (self.entries.items) |entry| {
            app_allocator.allocator().free(entry.name);
            app_allocator.allocator().free(entry.value);
        }
        self.entries.deinit(app_allocator.allocator());
        self.* = .{};
    }
};

// What we believe one attached client currently has on its outer terminal.
// This is separate from the headless terminal model. It lets us track the
// inner viewport height and send small redraws when the client is in sync.
const PresentationState = struct {
    initialized: bool = false,
    active_screen: u8 = 0,
    saved_primary: ?ScreenBufferState = null,
    rendered_rows: u16 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,
    cursor_style: client_renderer.CursorStyle = .default,
    terminal_modes: client_renderer.TerminalModes = .{},
    terminal_modes_initialized: bool = false,
    default_colors: client_renderer.DefaultColors = .{},
    default_colors_initialized: bool = false,
    full_height_rendering: bool = false,
    viewport_offset: i32 = 0,

    fn reset(self: *PresentationState) void {
        self.* = .{};
    }

    // Keep scrollback, but redraw the visible screen from scratch.
    //
    // The client may have shown a reconnect overlay or skipped stale draws, so
    // cached cursor, mode, and color state is no longer trustworthy. The old
    // height is kept only so the next draw can clear stale rows.
    fn resetForScreenRepaint(self: *PresentationState) void {
        const active_screen = self.active_screen;
        const saved_primary = self.saved_primary;
        const rendered_rows = self.rendered_rows;
        self.* = .{
            .active_screen = active_screen,
            .saved_primary = saved_primary,
            .rendered_rows = rendered_rows,
        };
    }

    // Paint one terminal screen snapshot onto this client. This chooses between
    // dirty-row updates and a full redraw, then syncs terminal-wide state.
    fn applyScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_rows: u16,
        screen: *const vt.RenderedScreen,
        force_redraw: bool,
        align_viewport: bool,
    ) !void {
        try self.switchActiveScreen(renderer, screen.active_screen);

        const desired_modes = vtModesToClient(screen.modes);
        const mouse_requested = desired_modes.mouse_tracking != .disabled;
        if (screen.active_screen == 1 and mouse_requested) {
            self.full_height_rendering = true;
        }

        if (align_viewport and screen.active_screen == 0) {
            try self.alignViewportTop(renderer, session_rows);
            if (mouse_requested) self.full_height_rendering = true;
        }
        const min_rendered_rows: u16 = if (self.full_height_rendering and
            mouse_requested)
            session_rows
        else
            0;

        const replace_visible_grid = force_redraw or
            !self.initialized or
            screen.dirty_state == .full or
            screen.active_screen_changed;

        if (replace_visible_grid) {
            try self.render(
                renderer,
                screen.rows,
                screen.cursor_row,
                screen.cursor_col,
                screen.cursor_visible,
                try cursorStyleFromVt(screen.cursor_style),
                min_rendered_rows,
            );
        } else {
            if (min_rendered_rows > 0) try self.ensureGridRow(renderer, min_rendered_rows - 1);
            for (screen.rows, 0..) |row, row_index| {
                if (!row.dirty) continue;
                try self.moveToGridPosition(renderer, @intCast(row_index), 0);
                try renderer.clearLine();
                try renderVtRow(renderer, row);
                self.cursor_col = renderedCellsDisplayWidth(row.cells);
                self.rendered_rows = @max(self.rendered_rows, @as(u16, @intCast(row_index + 1)));
            }
            try self.moveToGridPosition(renderer, screen.cursor_row, screen.cursor_col);
            try renderer.setCursorVisible(screen.cursor_visible);
            try renderer.setCursorStyle(try cursorStyleFromVt(screen.cursor_style));
            self.cursor_visible = screen.cursor_visible;
            self.cursor_style = try cursorStyleFromVt(screen.cursor_style);
        }

        if (screen.title_dirty or (force_redraw and screen.title_present)) {
            try renderer.setTitle(screen.title);
        }
        const modes_to_apply = if (mouse_requested and !self.full_height_rendering)
            terminalModesWithoutMouse(desired_modes)
        else
            desired_modes;
        try self.applyTerminalModes(renderer, modes_to_apply);
        try self.applyDefaultColors(renderer, try vtDefaultColorsToClient(screen.default_colors));
        if (!mouse_requested) {
            self.full_height_rendering = false;
        }
        self.updateViewportOffset(session_rows);

        if (self.initialized and self.rendered_rows < session_rows and
            (screen.active_screen == 1 or min_rendered_rows > 0))
        {
            self.rendered_rows = @max(self.rendered_rows, @as(u16, @intCast(screen.rows.len)));
        }
    }

    // Restore a full-height screen before leaving attached-client mode, so the user does
    // not return to a partially painted alternate/full-screen app.
    fn applyAttachedClientEndRestoreScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_rows: u16,
        screen: *const vt.RenderedScreen,
    ) !void {
        try self.switchActiveScreen(renderer, screen.active_screen);
        try self.render(
            renderer,
            screen.rows,
            screen.cursor_row,
            screen.cursor_col,
            screen.cursor_visible,
            try cursorStyleFromVt(screen.cursor_style),
            session_rows,
        );
        if (screen.title_dirty) try renderer.setTitle(screen.title);
        try self.applyTerminalModes(renderer, vtModesToClient(screen.modes));
        try self.applyDefaultColors(renderer, try vtDefaultColorsToClient(screen.default_colors));
        self.full_height_rendering = false;
    }

    // Grow the outer terminal transcript until our rendered grid starts at the
    // top of the viewport. This makes mouse coordinates and full-screen redraws
    // line up with the inner terminal screen.
    fn alignViewportTop(self: *PresentationState, renderer: client_renderer.Renderer, session_rows: u16) !void {
        if (session_rows == 0) return;
        var row: u16 = 0;
        while (row + 1 < session_rows) : (row += 1) {
            try renderer.newline();
        }
        try renderer.cursorUp(session_rows - 1);
        try renderer.carriageReturn();
        self.initialized = false;
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.viewport_offset = 0;
    }

    // The inner terminal cleared its display. Clear the outer visible area too,
    // then forget our old row/cursor position.
    fn clearOuterVisibleForScreen(self: *PresentationState, renderer: client_renderer.Renderer, screen: *const vt.RenderedScreen) !void {
        try self.switchActiveScreen(renderer, screen.active_screen);
        try renderer.clearVisible();
        self.initialized = false;
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.full_height_rendering = screenWantsMouseReporting(screen);
        self.viewport_offset = 0;
    }

    // Draw the visible screen and record the new cursor and rendered height.
    fn render(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        rows: []const vt.RenderedRow,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
        cursor_style: client_renderer.CursorStyle,
        min_rendered_rows: u16,
    ) !void {
        if (!self.initialized) {
            try self.renderInitial(renderer, rows, cursor_row, cursor_col, min_rendered_rows);
        } else {
            try self.redraw(renderer, rows, cursor_row, cursor_col, min_rendered_rows);
        }

        try renderer.setCursorVisible(cursor_visible);
        try renderer.setCursorStyle(cursor_style);
        self.initialized = true;
        self.rendered_rows = targetRenderedRows(rows.len, cursor_row, min_rendered_rows);
        self.cursor_row = cursor_row;
        self.cursor_col = cursor_col;
        self.cursor_visible = cursor_visible;
        self.cursor_style = cursor_style;
    }

    // Add retained scrollback above the currently rendered screen, like normal
    // terminal output scrolling older rows upward.
    fn appendScrollbackRows(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_rows: u16,
        rows: []const vt.RenderedRow,
    ) !void {
        if (rows.len == 0) return;
        if (!self.initialized or self.rendered_rows == 0) {
            try renderTranscriptRows(renderer, rows);
            self.updateViewportOffsetForRenderedRows(session_rows, @intCast(@min(rows.len, std.math.maxInt(u16))));
            return;
        }

        if (self.rendered_rows < session_rows) {
            try self.ensureGridRow(renderer, session_rows - 1);
        }

        for (rows) |row| {
            try self.moveToRenderedTop(renderer);
            self.cursor_row = 0;
            self.cursor_col = 0;
            try renderer.carriageReturn();
            try renderer.clearLine();
            try renderVtRow(renderer, row);
            self.cursor_col = renderedCellsDisplayWidth(row.cells);
            try self.moveToGridPosition(renderer, self.rendered_rows - 1, 0);
            try renderer.newline();
            self.cursor_row = self.rendered_rows - 1;
            self.cursor_col = 0;
        }
        self.viewport_offset = 0;
    }

    // Draw when we cannot rely on the old cursor position or cached terminal
    // state. If resetForScreenRepaint left an old height behind, clear that
    // old area before drawing the new trimmed screen.
    fn renderInitial(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        rows: []const vt.RenderedRow,
        cursor_row: u16,
        cursor_col: u16,
        min_rendered_rows: u16,
    ) !void {
        // The new snapshot may be shorter than the screen we previously drew.
        // Clear any old rows below the new screen so stale text and colors are
        // not left behind.
        const rendered_rows = @max(
            self.rendered_rows,
            targetRenderedRows(rows.len, cursor_row, min_rendered_rows),
        );
        var row_index: u16 = 0;
        while (row_index < rendered_rows) : (row_index += 1) {
            if (row_index > 0) try renderer.newline();
            try renderer.clearLine();
            if (row_index < rows.len) try renderVtRow(renderer, rows[row_index]);
        }
        try moveToSnapshotCursor(renderer, rendered_rows, cursor_row, cursor_col);
    }

    // Redraw when we know where our old rendered grid is. Clear max(old, new)
    // rows so a shorter terminal screen does not leave stale content behind.
    fn redraw(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        rows: []const vt.RenderedRow,
        cursor_row: u16,
        cursor_col: u16,
        min_rendered_rows: u16,
    ) !void {
        try self.moveToRenderedTop(renderer);

        const new_rows = targetRenderedRows(rows.len, cursor_row, min_rendered_rows);
        const redraw_rows = @max(self.rendered_rows, new_rows);
        var row_index: u16 = 0;
        while (row_index < redraw_rows) : (row_index += 1) {
            try renderer.carriageReturn();
            try renderer.clearLine();
            if (row_index < rows.len) try renderVtRow(renderer, rows[row_index]);
            if (row_index + 1 < redraw_rows) try renderer.newline();
        }

        try moveToSnapshotCursor(renderer, redraw_rows, cursor_row, cursor_col);
    }

    // Switch the real terminal buffer to match the inner terminal. We save the
    // primary-buffer cursor/grid state before entering the outer alternate
    // screen, because the terminal restores that primary cursor when we leave.
    fn switchActiveScreen(self: *PresentationState, renderer: client_renderer.Renderer, active_screen: u8) !void {
        if (active_screen > 1) return error.InvalidActiveScreen;
        if (self.active_screen == active_screen) return;

        if (active_screen == 1) {
            self.saved_primary = self.captureScreenBufferState();
            try renderer.enterAlternateScreen();
            try renderer.clearVisible();
            self.restoreScreenBufferState(.{ .full_height_rendering = true });
        } else {
            try renderer.leaveAlternateScreen();
            if (self.saved_primary) |primary| {
                self.restoreScreenBufferState(primary);
                self.saved_primary = null;
            } else {
                self.restoreScreenBufferState(.{});
            }
        }

        self.active_screen = active_screen;
    }

    fn captureScreenBufferState(self: *const PresentationState) ScreenBufferState {
        return .{
            .initialized = self.initialized,
            .rendered_rows = self.rendered_rows,
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
            .cursor_visible = self.cursor_visible,
            .cursor_style = self.cursor_style,
            .full_height_rendering = self.full_height_rendering,
            .viewport_offset = self.viewport_offset,
        };
    }

    fn restoreScreenBufferState(self: *PresentationState, state: ScreenBufferState) void {
        self.initialized = state.initialized;
        self.rendered_rows = state.rendered_rows;
        self.cursor_row = state.cursor_row;
        self.cursor_col = state.cursor_col;
        self.cursor_visible = state.cursor_visible;
        self.cursor_style = state.cursor_style;
        self.full_height_rendering = state.full_height_rendering;
        self.viewport_offset = state.viewport_offset;
    }

    // Terminal modes are global settings on the outer terminal. Emit the full
    // desired mode set only when our cached value differs.
    fn applyTerminalModes(self: *PresentationState, renderer: client_renderer.Renderer, modes: client_renderer.TerminalModes) !void {
        if (self.terminal_modes_initialized and self.terminal_modes.eql(modes)) return;
        try renderer.applyTerminalModes(modes);
        self.terminal_modes = modes;
        self.terminal_modes_initialized = true;
    }

    // Terminal default colors are also global. If the first known value is the
    // normal default, remember it without sending a reset sequence.
    fn applyDefaultColors(self: *PresentationState, renderer: client_renderer.Renderer, colors: client_renderer.DefaultColors) !void {
        if (self.default_colors_initialized and self.default_colors.eql(colors)) return;
        if (!self.default_colors_initialized and colors.isDefault()) {
            self.default_colors = colors;
            self.default_colors_initialized = true;
            return;
        }
        try renderer.applyDefaultColors(colors);
        self.default_colors = colors;
        self.default_colors_initialized = true;
    }

    // Sometimes child output can be forwarded unchanged instead of converted
    // into a synthetic redraw. Only do that when it cannot disturb hidden
    // state that PresentationState is tracking.
    fn canApplyPlainReplay(
        self: *const PresentationState,
        screen: *const vt.RenderedScreen,
        align_viewport: bool,
        bytes: []const u8,
        parser_boundary_ok: bool,
    ) !bool {
        if (!self.initialized) return false;
        if (self.full_height_rendering) return false;
        if (self.viewportOffsetUnknown()) return false;
        if (align_viewport) return false;
        if (screen.active_screen != 0) return false;
        if (screen.active_screen_changed) return false;
        if (screen.title_dirty or
            screen.default_colors_dirty or
            screen.retained_scrollback_clear_dirty or
            screen.display_clear != null)
        {
            return false;
        }
        if (!parser_boundary_ok) return false;
        if (!isSafePlainReplay(bytes)) return false;
        if (!rowsHaveOnlyDefaultPresentation(screen.rows)) return false;
        if (!self.terminal_modes_initialized or
            !self.terminal_modes.eql(vtModesToClient(screen.modes)))
        {
            return false;
        }
        if (!self.default_colors_initialized or
            !self.default_colors.eql(try vtDefaultColorsToClient(screen.default_colors)))
        {
            return false;
        }
        if (self.cursor_visible != screen.cursor_visible) return false;
        if (self.cursor_style != try cursorStyleFromVt(screen.cursor_style)) return false;
        return true;
    }

    // Update our cache after original plain output was replayed successfully.
    fn assumePlainReplayScreen(self: *PresentationState, session_rows: u16, screen: *const vt.RenderedScreen) !void {
        if (screen.active_screen > 1) return error.InvalidActiveScreen;
        if (self.active_screen != screen.active_screen) return error.ActiveScreenSwitchRequiresDraw;
        self.initialized = true;
        const row_count: u16 = @intCast(screen.rows.len);
        const cursor_row_count = screen.cursor_row +| 1;
        self.rendered_rows = @min(session_rows, @max(self.rendered_rows, @max(row_count, cursor_row_count)));
        self.cursor_row = screen.cursor_row;
        self.cursor_col = screen.cursor_col;
        self.cursor_visible = screen.cursor_visible;
        self.cursor_style = try cursorStyleFromVt(screen.cursor_style);
        self.terminal_modes = vtModesToClient(screen.modes);
        self.terminal_modes_initialized = true;
        self.default_colors = try vtDefaultColorsToClient(screen.default_colors);
        self.default_colors_initialized = true;
        if (screen.modes.mouse_tracking == 0 or !screen.modes.mouse_sgr) {
            self.full_height_rendering = false;
        }
        self.updateViewportOffset(session_rows);
    }

    // Retained scrollback belongs to the primary buffer. If the outer terminal
    // is currently showing the alternate buffer, switch back before appending
    // scrollback rows; the following screen draw can switch to alternate again
    // if the inner terminal is still there.
    fn preparePrimaryForScrollback(self: *PresentationState, renderer: client_renderer.Renderer) !void {
        try self.switchActiveScreen(renderer, 0);
    }

    fn setViewportOffset(self: *PresentationState, viewport_offset: ?i32) void {
        self.viewport_offset = viewport_offset orelse 0;
    }

    fn protocolViewportOffset(self: *const PresentationState) ?i32 {
        return if (self.viewport_offset == 0) null else self.viewport_offset;
    }

    fn viewportOffsetUnknown(self: *const PresentationState) bool {
        return self.viewport_offset < 0;
    }

    // Keep our viewport-offset estimate consistent with the height we rendered.
    fn updateViewportOffset(self: *PresentationState, session_rows: u16) void {
        self.updateViewportOffsetForRenderedRows(session_rows, self.rendered_rows);
    }

    fn updateViewportOffsetForRenderedRows(self: *PresentationState, session_rows: u16, rendered_rows: u16) void {
        if (self.viewport_offset <= 0 or session_rows == 0) return;
        self.viewport_offset = if (rendered_rows >= session_rows)
            0
        else
            @min(self.viewport_offset, @as(i32, @intCast(session_rows - rendered_rows)));
    }

    // Move from the cached cursor position back to row 0 of our rendered grid.
    fn moveToRenderedTop(self: *const PresentationState, renderer: client_renderer.Renderer) !void {
        if (self.rendered_rows == 0) return;
        try renderer.cursorUp(self.cursor_row);
        try renderer.carriageReturn();
    }

    // Move within our rendered grid, extending it with blank lines if needed.
    fn moveToGridPosition(self: *PresentationState, renderer: client_renderer.Renderer, row: u16, col: u16) !void {
        try self.ensureGridRow(renderer, row);
        try self.moveWithinGrid(renderer, row, col);
    }

    // Make sure a row exists in the outer terminal before we move to it.
    fn ensureGridRow(self: *PresentationState, renderer: client_renderer.Renderer, row: u16) !void {
        if (self.rendered_rows == 0) {
            self.rendered_rows = 1;
            self.cursor_row = 0;
        }

        while (row >= self.rendered_rows) {
            try self.moveWithinGrid(renderer, self.rendered_rows - 1, self.cursor_col);
            try renderer.newline();
            self.cursor_row = self.rendered_rows;
            self.cursor_col = 0;
            self.rendered_rows += 1;
        }
    }

    // Move to an already existing row/column and update the cached cursor.
    fn moveWithinGrid(self: *PresentationState, renderer: client_renderer.Renderer, row: u16, col: u16) !void {
        if (self.cursor_row > row) {
            try renderer.cursorUp(self.cursor_row - row);
        } else if (row > self.cursor_row) {
            try renderer.cursorDown(row - self.cursor_row);
        }
        try renderer.carriageReturn();
        try renderer.cursorRight(col);
        self.cursor_row = row;
        self.cursor_col = col;
    }
};

const TerminalOrigin = struct {
    row: u16,
    col: u16,
};

const ScreenBufferState = struct {
    initialized: bool = false,
    rendered_rows: u16 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,
    cursor_style: client_renderer.CursorStyle = .default,
    full_height_rendering: bool = false,
    viewport_offset: i32 = 0,
};

const AttachRequest = struct {
    resize: ResizePayload,
    session_guid: []u8,
    capture_tty_transcript: bool,

    fn deinit(self: *AttachRequest) void {
        app_allocator.allocator().free(self.session_guid);
        self.* = undefined;
    }
};

const SessionCreateRequest = struct {
    resize: ResizePayload,
    scrollback_row_count: u32,
    environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []u8,
    command_argv: [][]u8,
    shell_command: ?[]u8,
    tty_settings: ?tty_settings.Settings,
    reap_ms: u64,
    capture_tty_transcript: bool,

    fn deinit(self: *SessionCreateRequest) void {
        app_allocator.allocator().free(self.session_guid);
        for (self.command_argv) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(self.command_argv);
        if (self.shell_command) |shell_command| app_allocator.allocator().free(shell_command);
        if (self.tty_settings) |*settings| settings.deinit(app_allocator.allocator());
        self.environment.deinit();
        self.* = undefined;
    }
};

const RepaintRequest = struct {
    repaint_request_seq: u64,
    scrollback_cursor: ?ScrollbackCursor,
};

const ScrollbackCursor = struct {
    epoch: u64,
    per_epoch_cursor: u64,
};

const encoded_scrollback_cursor_len = 16;

const ResizePayload = struct {
    rows: u16,
    cols: u16,
    viewport_offset: ?i32,
    repaint_request: ?RepaintRequest,
};

fn renderTranscriptRows(renderer: client_renderer.Renderer, rows: []const vt.RenderedRow) !void {
    for (rows) |row| {
        try renderVtRow(renderer, row);
        try renderer.newline();
    }
}

fn renderVtRow(renderer: client_renderer.Renderer, row: vt.RenderedRow) !void {
    const allocator = app_allocator.allocator();
    const cells = try allocator.alloc(client_renderer.Cell, row.cells.len);
    defer allocator.free(cells);
    for (row.cells, 0..) |cell, index| {
        cells[index] = .{
            .text = cell.text,
            .display_width = cell.display_width,
            .attrs = try vtAttrsToClient(cell.attrs),
            .hyperlink = cell.hyperlink,
        };
    }
    try renderer.renderRow(.{ .cells = cells });
}

fn renderedCellsDisplayWidth(cells: []const vt.RenderedCell) u16 {
    var width: u16 = 0;
    for (cells) |cell| width +|= cell.display_width;
    return width;
}

fn rowsHaveOnlyDefaultPresentation(rows: []const vt.RenderedRow) bool {
    for (rows) |row| {
        for (row.cells) |cell| {
            if (!cell.attrs.eql(.{})) return false;
            if (cell.hyperlink != null) return false;
        }
    }
    return true;
}

fn isSafePlainReplay(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    // Starting at libghostty-vt ground state plus this byte allowlist preserves
    // ground state: there is no ESC/control introducer and no partial UTF-8.
    // The remote session runtime therefore only needs to record whether the batch started at a
    // plain-text parser boundary before considering original-byte replay.
    // TAB is intentionally excluded because its visual effect depends on tab
    // stop state; add it only after modeling and testing that state boundary.
    for (bytes) |byte| {
        switch (byte) {
            '\r', '\n' => {},
            0x20...0x7e => {},
            else => return false,
        }
    }
    return true;
}

// After drawing rows from top to bottom, move to the cursor position reported
// by the terminal snapshot.
fn moveToSnapshotCursor(renderer: client_renderer.Renderer, rendered_rows: u16, cursor_row: u16, cursor_col: u16) !void {
    if (rendered_rows == 0) {
        try renderer.cursorDown(cursor_row);
        try renderer.carriageReturn();
        try renderer.cursorRight(cursor_col);
        return;
    }
    const last_row = rendered_rows - 1;
    if (cursor_row < last_row) try renderer.cursorUp(last_row - cursor_row);
    if (cursor_row > last_row) try renderer.cursorDown(cursor_row - last_row);
    try renderer.carriageReturn();
    try renderer.cursorRight(cursor_col);
}

// How many rows of the inner viewport this client currently has mapped onto
// the outer terminal.
//
// A trimmed snapshot can mean two different things: the inner viewport is
// aligned and the bottom rows are blank, or the viewport is still unaligned and
// drawing more rows would scroll existing outer-terminal content. After
// alignment, callers need a way to choose the first meaning; min_rendered_rows
// lets them do that.
fn targetRenderedRows(rows_len: usize, cursor_row: u16, min_rendered_rows: u16) u16 {
    return @max(
        @max(@as(u16, @intCast(rows_len)), min_rendered_rows),
        cursor_row +| 1,
    );
}

fn vtModesToClient(modes: vt.TerminalModes) client_renderer.TerminalModes {
    return .{
        .mode_flags = modes.mode_flags,
        .mouse_tracking = switch (modes.mouse_tracking) {
            0 => .disabled,
            1 => .normal,
            2 => .button,
            3 => .any,
            else => .disabled,
        },
        .mouse_sgr = modes.mouse_sgr,
        .kitty_keyboard_flags = modes.kitty_keyboard_flags,
    };
}

fn terminalModesWithoutMouse(modes: client_renderer.TerminalModes) client_renderer.TerminalModes {
    var without_mouse = modes;
    without_mouse.mouse_tracking = .disabled;
    without_mouse.mouse_sgr = false;
    return without_mouse;
}

fn vtDefaultColorsToClient(colors: vt.DefaultColors) !client_renderer.DefaultColors {
    return .{
        .foreground = try vtColorToClient(colors.foreground_color),
        .background = try vtColorToClient(colors.background_color),
    };
}

test "full-height redraw pads blank rows without indexing past VT rows" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });

    const rows = try std.testing.allocator.alloc(vt.RenderedRow, 0);
    var screen = vt.RenderedScreen{
        .rows = rows,
        .cols = 80,
        .active_screen = 0,
        .title = "",
        .title_present = false,
        .title_dirty = false,
        .default_colors = .{},
        .default_colors_dirty = false,
        .retained_scrollback_clear_dirty = false,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .cursor_style = 0,
        .modes = .{ .mouse_tracking = 1, .mouse_sgr = true },
        .dirty_state = .full,
        .active_screen_changed = false,
        .display_clear = null,
    };
    defer screen.deinit(std.testing.allocator);

    var presentation = PresentationState{
        .initialized = true,
        .rendered_rows = 3,
        .full_height_rendering = true,
    };
    try presentation.applyScreen(renderer, 3, &screen, true, false);
    try std.testing.expectEqual(@as(u16, 3), presentation.rendered_rows);
}

test "active-screen change uses outer alternate screen" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });

    var first_primary = try testRenderedScreen(
        std.testing.allocator,
        0,
        2,
        &.{ "PRIMARY0", "PRIMARY1", "PRIMARY2" },
    );
    defer first_primary.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, 4, &first_primary, true, false);

    bytes.clearRetainingCapacity();

    var alt_screen = try testRenderedScreen(
        std.testing.allocator,
        1,
        3,
        &.{ "ALT0", "ALT1", "ALT2", "ALT3" },
    );
    defer alt_screen.deinit(std.testing.allocator);

    try presentation.applyScreen(renderer, 4, &alt_screen, true, false);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[?1049h") != null);
    try std.testing.expectEqual(@as(u16, 3), presentation.cursor_row);

    bytes.clearRetainingCapacity();

    var primary_screen = try testRenderedScreen(
        std.testing.allocator,
        0,
        0,
        &.{"PRIMARY"},
    );
    defer primary_screen.deinit(std.testing.allocator);

    try presentation.applyScreen(renderer, 4, &primary_screen, true, false);
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[?1049l\x1b[2A\r"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "PRIMARY") != null);
}

test "attached-client-end restore leaves outer alternate screen" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });

    var alt_screen = try testRenderedScreen(
        std.testing.allocator,
        1,
        3,
        &.{ "ALT0", "ALT1", "ALT2", "ALT3" },
    );
    defer alt_screen.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, 4, &alt_screen, true, false);

    bytes.clearRetainingCapacity();

    var primary_screen = try testRenderedScreen(
        std.testing.allocator,
        0,
        0,
        &.{"PRIMARY"},
    );
    defer primary_screen.deinit(std.testing.allocator);

    try presentation.applyAttachedClientEndRestoreScreen(renderer, 4, &primary_screen);
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[?1049l"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "PRIMARY") != null);
}

test "initial screen render clears target rows before drawing" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });

    var screen = try testRenderedScreen(
        std.testing.allocator,
        0,
        2,
        &.{ "short", "", "tiny" },
    );
    defer screen.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, 4, &screen, true, false);

    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[2K\x1b[0mshort") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\r\n\x1b[2K\x1b[0m\x1b[0m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[2K\x1b[0mtiny") != null);
}

test "screen repaint reset clears previous rows then records new height" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });

    var screen = try testRenderedScreen(
        std.testing.allocator,
        0,
        0,
        &.{"short"},
    );
    defer screen.deinit(std.testing.allocator);

    var presentation = PresentationState{
        .initialized = true,
        .rendered_rows = 5,
    };
    presentation.resetForScreenRepaint();
    try presentation.applyScreen(renderer, 5, &screen, true, false);

    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, bytes.items, "\x1b[2K"));
    try std.testing.expectEqual(@as(u16, 1), presentation.rendered_rows);
}

fn testRenderedScreen(
    allocator: std.mem.Allocator,
    active_screen: u8,
    cursor_row: u16,
    labels: []const []const u8,
) !vt.RenderedScreen {
    const rows = try allocator.alloc(vt.RenderedRow, labels.len);
    var rows_filled: usize = 0;
    errdefer {
        for (rows[0..rows_filled]) |*row| row.deinit(allocator);
        allocator.free(rows);
    }

    for (labels, 0..) |label, index| {
        rows[index] = try testRenderedRow(allocator, label);
        rows_filled += 1;
    }

    return .{
        .rows = rows,
        .cols = 80,
        .active_screen = active_screen,
        .title = "",
        .title_present = false,
        .title_dirty = false,
        .default_colors = .{},
        .default_colors_dirty = false,
        .retained_scrollback_clear_dirty = false,
        .cursor_row = cursor_row,
        .cursor_col = 0,
        .cursor_visible = true,
        .cursor_style = 0,
        .modes = .{},
        .dirty_state = .full,
        .active_screen_changed = true,
        .display_clear = null,
    };
}

fn testRenderedRow(allocator: std.mem.Allocator, label: []const u8) !vt.RenderedRow {
    const cells = try allocator.alloc(vt.RenderedCell, 1);
    errdefer allocator.free(cells);
    cells[0] = .{
        .text = try allocator.dupe(u8, label),
        .display_width = @intCast(label.len),
        .attrs = .{},
    };
    return .{
        .cells = cells,
        .width_cols = 80,
        .flags = 0,
        .dirty = true,
    };
}

fn vtAttrsToClient(attrs: vt.CellAttrs) !client_renderer.CellAttrs {
    if ((attrs.style_flags & 0xfffff000) != 0) return error.InvalidStyleFlags;
    const underline = (attrs.style_flags & (1 << 3)) != 0;
    const underline_style_raw = (attrs.style_flags >> 9) & 0x7;
    const underline_style: client_renderer.UnderlineStyle = if (underline) switch (underline_style_raw) {
        0, 1 => .single,
        2 => .double,
        3 => .curly,
        4 => .dotted,
        5 => .dashed,
        else => return error.InvalidUnderlineStyle,
    } else .single;
    return .{
        .bold = (attrs.style_flags & (1 << 0)) != 0,
        .faint = (attrs.style_flags & (1 << 1)) != 0,
        .italic = (attrs.style_flags & (1 << 2)) != 0,
        .underline = underline,
        .underline_style = underline_style,
        .blink = (attrs.style_flags & (1 << 4)) != 0,
        .inverse = (attrs.style_flags & (1 << 5)) != 0,
        .hidden = (attrs.style_flags & (1 << 6)) != 0,
        .strikethrough = (attrs.style_flags & (1 << 7)) != 0,
        .overline = (attrs.style_flags & (1 << 8)) != 0,
        .fg = try vtColorToClient(attrs.fg_color),
        .bg = try vtColorToClient(attrs.bg_color),
        .underline_color = try vtColorToClient(attrs.underline_color),
    };
}

fn vtColorToClient(raw: u32) !client_renderer.Color {
    if (raw == vt.CellAttrs.default_color) return .default;
    if (raw <= 0xff) return .{ .indexed = @intCast(raw) };
    if ((raw & 0xff000000) == 0x01000000) {
        return .{ .rgb = .{
            .r = @intCast((raw >> 16) & 0xff),
            .g = @intCast((raw >> 8) & 0xff),
            .b = @intCast(raw & 0xff),
        } };
    }
    return error.InvalidTerminalColor;
}

fn cursorStyleFromVt(value: u8) !client_renderer.CursorStyle {
    return switch (value) {
        0 => .default,
        1 => .blinking_block,
        2 => .steady_block,
        3 => .blinking_underline,
        4 => .steady_underline,
        5 => .blinking_bar,
        6 => .steady_bar,
        else => error.InvalidCursorStyle,
    };
}

pub fn startSessionRuntimeThread(allocator: std.mem.Allocator, session_guid: []const u8) !*RuntimeControl {
    const guid = try session_registry.canonicalGuid(allocator, session_guid);
    errdefer allocator.free(guid);

    const notify_pipe = try posix.pipe();
    errdefer {
        posix.close(notify_pipe[0]);
        posix.close(notify_pipe[1]);
    }
    setNonBlockingFd(notify_pipe[0]) catch {};
    setNonBlockingFd(notify_pipe[1]) catch {};
    socket_transport.setCloseOnExec(notify_pipe[0]) catch {};
    socket_transport.setCloseOnExec(notify_pipe[1]) catch {};

    const control = try allocator.create(RuntimeControl);
    errdefer allocator.destroy(control);
    control.* = .{
        .allocator = allocator,
        .guid = guid,
        .notify_read_fd = notify_pipe[0],
        .notify_write_fd = notify_pipe[1],
    };
    errdefer control.deinit();

    try registerRuntime(control);
    errdefer unregisterRuntime(control);

    const context = try allocator.create(SessionRuntimeThreadContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .session_guid = try allocator.dupe(u8, guid),
        .control = control,
    };
    errdefer allocator.free(context.session_guid);

    const thread = try std.Thread.spawn(.{}, sessionRuntimeThreadMain, .{context});
    thread.detach();
    return control;
}

const SessionRuntimeThreadContext = struct {
    allocator: std.mem.Allocator,
    session_guid: []u8,
    control: *RuntimeControl,
};

fn sessionRuntimeThreadMain(context: *SessionRuntimeThreadContext) void {
    const allocator = context.allocator;
    const control = context.control;
    defer {
        unregisterRuntime(control);
        control.deinit();
        allocator.destroy(control);
        allocator.free(context.session_guid);
        allocator.destroy(context);
    }
    socket_transport.publishRuntimeRootSymlinkOnce(app_allocator.allocator());
    const shutdown_pipe = posix.pipe() catch return;
    defer {
        posix.close(shutdown_pipe[0]);
        posix.close(shutdown_pipe[1]);
    }
    runSessionRuntimeLoop(context.session_guid, shutdown_pipe[0], control) catch {};
}

fn runSessionRuntimeLoop(session_guid: []const u8, shutdown_signal_fd: c.fd_t, control: *RuntimeControl) !void {
    var session_runtime = SessionRuntime{
        .fixed_session_id = session_guid,
    };

    defer closeSessionRuntime(&session_runtime);

    while (session_runtime.running) {
        try sessionRuntimePollOnce(&session_runtime, control, shutdown_signal_fd);
        stopSessionRuntimeIfComplete(&session_runtime);
    }
}

pub fn connectSessionRuntime(allocator: std.mem.Allocator, guid: []const u8) !c.fd_t {
    const canonical = try session_registry.canonicalGuid(allocator, guid);
    defer allocator.free(canonical);

    const control = lookupRuntime(canonical) orelse return error.SessionNotFound;
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    try socket_transport.setCloseOnExec(fds[0]);
    try socket_transport.setCloseOnExec(fds[1]);
    try control.enqueue(fds[1]);
    return fds[0];
}

pub fn connectSingleLiveSessionRuntime(allocator: std.mem.Allocator) !c.fd_t {
    runtime_registry_mutex.lock();
    var found_guid: ?[]u8 = null;
    for (runtime_registry.items) |control| {
        control.pending_mutex.lock();
        const live = !control.closed;
        control.pending_mutex.unlock();
        if (!live) continue;
        if (found_guid != null) {
            runtime_registry_mutex.unlock();
            return error.AmbiguousSession;
        }
        found_guid = try allocator.dupe(u8, control.guid);
    }
    runtime_registry_mutex.unlock();
    defer if (found_guid) |guid| allocator.free(guid);
    return connectSessionRuntime(allocator, found_guid orelse return error.SessionNotFound);
}

fn registerRuntime(control: *RuntimeControl) !void {
    runtime_registry_mutex.lock();
    defer runtime_registry_mutex.unlock();
    for (runtime_registry.items) |existing| {
        if (std.mem.eql(u8, existing.guid, control.guid)) return error.SessionExists;
    }
    try runtime_registry.append(app_allocator.allocator(), control);
}

fn unregisterRuntime(control: *RuntimeControl) void {
    runtime_registry_mutex.lock();
    defer runtime_registry_mutex.unlock();
    for (runtime_registry.items, 0..) |existing, index| {
        if (existing == control) {
            _ = runtime_registry.orderedRemove(index);
            return;
        }
    }
}

pub fn activeRuntimeCount() usize {
    runtime_registry_mutex.lock();
    defer runtime_registry_mutex.unlock();
    return runtime_registry.items.len;
}

fn lookupRuntime(guid: []const u8) ?*RuntimeControl {
    runtime_registry_mutex.lock();
    defer runtime_registry_mutex.unlock();
    for (runtime_registry.items) |control| {
        if (std.mem.eql(u8, control.guid, guid)) return control;
    }
    return null;
}

fn sessionRuntimePollOnce(session_runtime: *SessionRuntime, control: *RuntimeControl, shutdown_signal_fd: c.fd_t) !void {
    const now_ms = sessionRuntimeMonotonicMs(session_runtime);
    const now_unix_ms = nowUnixMs();
    clearExpiredDebugUnresponsiveAttachedClients(session_runtime, now_ms);
    if (reapPtyHangupSessionIfExited(session_runtime)) return;
    if (endReapedSessions(session_runtime, now_unix_ms)) return;

    var pollfds: [5]posix.pollfd = undefined;
    var kinds: [5]PollKind = undefined;
    var count: usize = 0;

    pollfds[count] = .{ .fd = shutdown_signal_fd, .events = posix.POLL.IN, .revents = 0 };
    kinds[count] = .shutdown_signal;
    count += 1;

    if (!session_runtime.shutting_down) {
        pollfds[count] = .{ .fd = control.notify_read_fd, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .listen;
        count += 1;
    }

    if (session_runtime.session.alive and session_runtime.session.pty_fd >= 0) {
        const session = &session_runtime.session;
        pollfds[count] = .{ .fd = session.pty_fd, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .session;
        count += 1;
    }

    if (session_runtime.attached_client.active) {
        const attached_client = &session_runtime.attached_client;
        const debug_unresponsive = attached_client.debug_unresponsive_until_ms > now_ms;
        var events: i16 = if (attached_client.close_after_flush or debug_unresponsive) 0 else posix.POLL.IN;
        if (!debug_unresponsive and attached_client.queuedBytes() > 0) events |= posix.POLL.OUT;
        pollfds[count] = .{ .fd = attached_client.fd, .events = events, .revents = 0 };
        kinds[count] = .attached_client;
        count += 1;
    }

    _ = try posix.poll(pollfds[0..count], sessionRuntimePollTimeoutMs(session_runtime, now_ms, now_unix_ms));
    const after_poll_ms = sessionRuntimeMonotonicMs(session_runtime);
    clearExpiredDebugUnresponsiveAttachedClients(session_runtime, after_poll_ms);
    flushExpiredSynchronizedOutputSessions(session_runtime, after_poll_ms);
    if (reapPtyHangupSessionIfExited(session_runtime)) return;
    if (endReapedSessions(session_runtime, nowUnixMs())) return;

    for (pollfds[0..count], kinds[0..count]) |pollfd, kind| {
        if (pollfd.revents == 0) continue;
        switch (kind) {
            .listen => handleRuntimeHandoffEvent(session_runtime, control),
            .shutdown_signal => handleShutdownSignalEvent(session_runtime, shutdown_signal_fd),
            .runtime_repair => {},
            .session => drainSessionOutput(session_runtime),
            .attached_client => handleAttachedClientEvents(session_runtime, pollfd.revents),
        }
    }
}

fn sessionRuntimeMonotonicMs(session_runtime: *SessionRuntime) i64 {
    if (session_runtime.monotonic_clock == null) {
        session_runtime.monotonic_clock = std.time.Timer.start() catch return std.time.milliTimestamp();
    }
    return if (session_runtime.monotonic_clock) |*timer|
        @intCast(timer.read() / std.time.ns_per_ms)
    else
        std.time.milliTimestamp();
}

fn clearExpiredDebugUnresponsiveAttachedClients(session_runtime: *SessionRuntime, now_ms: i64) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    if (attached_client.debug_unresponsive_until_ms != 0 and attached_client.debug_unresponsive_until_ms <= now_ms) {
        attached_client.debug_unresponsive_until_ms = 0;
    }
}

fn sessionRuntimePollTimeoutMs(session_runtime: *const SessionRuntime, now_ms: i64, now_unix_ms: u64) i32 {
    var timeout_ms: ?i64 = null;
    const attached_client = &session_runtime.attached_client;
    if (attached_client.active and attached_client.debug_unresponsive_until_ms > now_ms) {
        const remaining_ms = attached_client.debug_unresponsive_until_ms - now_ms;
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    const session = &session_runtime.session;
    if (session.alive and session.synchronized_output_since_ms != 0) {
        const elapsed_ms = now_ms - session.synchronized_output_since_ms;
        const remaining_ms = synchronized_output_max_hold_ms - elapsed_ms;
        const clamped_remaining_ms = @max(remaining_ms, 0);
        if (timeout_ms == null or clamped_remaining_ms < timeout_ms.?) timeout_ms = clamped_remaining_ms;
    }
    if (session.alive and session.pty_closed_for_hangup) {
        if (timeout_ms == null or pty_hangup_reap_poll_ms < timeout_ms.?) timeout_ms = pty_hangup_reap_poll_ms;
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

fn endReapedSessions(session_runtime: *SessionRuntime, now_unix_ms: u64) bool {
    const session = &session_runtime.session;
    if (!sessionReapEnabled(session)) return false;
    const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
    if (now_unix_ms < deadline_ms) return false;
    endSession(session_runtime, 3, .{ .ended_at_unix_ms = now_unix_ms });
    return true;
}

fn sessionReapEnabled(session: *const Session) bool {
    return session.alive and
        !session.attached and
        session.disconnected_at_unix_ms != 0 and
        session.reap_ms != 0;
}

test "remote session runtime poll timeout includes reap deadline" {
    var session_runtime = SessionRuntime{};
    session_runtime.session = .{
        .alive = true,
        .attached = false,
        .disconnected_at_unix_ms = 1_000,
        .reap_ms = 5_000,
    };

    try std.testing.expectEqual(@as(i32, 5_000), sessionRuntimePollTimeoutMs(&session_runtime, 0, 1_000));
    try std.testing.expectEqual(@as(i32, 1), sessionRuntimePollTimeoutMs(&session_runtime, 0, 5_999));
    try std.testing.expectEqual(@as(i32, 0), sessionRuntimePollTimeoutMs(&session_runtime, 0, 6_000));

    session_runtime.session.attached = true;
    try std.testing.expectEqual(@as(i32, -1), sessionRuntimePollTimeoutMs(&session_runtime, 0, 6_000));
}

test "remote session runtime poll timeout wakes to reap pty hangup" {
    var session_runtime = SessionRuntime{};
    session_runtime.session = .{
        .alive = true,
        .pty_closed_for_hangup = true,
    };

    try std.testing.expectEqual(@as(i32, pty_hangup_reap_poll_ms), sessionRuntimePollTimeoutMs(&session_runtime, 0, 0));
}

fn flushExpiredSynchronizedOutputSessions(session_runtime: *SessionRuntime, now_ms: i64) void {
    const session = &session_runtime.session;
    if (!session.alive or session.synchronized_output_since_ms == 0) return;
    if (now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms) return;
    broadcastSessionPatch(session_runtime);
    if (session.alive) {
        session.clearPendingPlainOutput();
        session.synchronized_output_since_ms = now_ms;
    }
}

fn drainSignalPipe(fd: c.fd_t) void {
    var buf: [64]u8 = undefined;
    _ = c.read(fd, &buf, buf.len);
}

fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

fn handleShutdownSignalEvent(session_runtime: *SessionRuntime, shutdown_signal_fd: c.fd_t) void {
    var buf: [32]u8 = undefined;
    _ = c.read(shutdown_signal_fd, &buf, buf.len);
    requestGracefulShutdown(session_runtime);
}

fn handleAttachedClientEvents(session_runtime: *SessionRuntime, revents: i16) void {
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        disconnectAttachedClient(session_runtime);
        return;
    }
    if ((revents & posix.POLL.OUT) != 0) {
        flushAttachedClientOutput(session_runtime);
    }
    if (!session_runtime.attached_client.active) return;
    if (session_runtime.attached_client.close_after_flush) return;
    if ((revents & posix.POLL.IN) != 0) {
        drainAttachedClientInput(session_runtime);
    }
}

fn handleRuntimeHandoffEvent(session_runtime: *SessionRuntime, control: *RuntimeControl) void {
    drainSignalPipe(control.notify_read_fd);

    while (control.takePending()) |client_fd| {
        const keep_open = handleSessionRuntimeClient(session_runtime, client_fd) catch |err| blk: {
            io.stderrPrint("sessh remote session runtime: client error: {t}\n", .{err}) catch {};
            break :blk false;
        };
        if (!keep_open) _ = c.close(client_fd);
    }
}

fn handleSessionRuntimeClient(session_runtime: *SessionRuntime, fd: c.fd_t) !bool {
    const handshake_result = try acceptRemoteHandshake(session_runtime, fd);
    if (handshake_result == .mismatch) return false;

    while (true) {
        var frame = protocol.readFrameAlloc(app_allocator.allocator(), fd) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .daemon_tunnel => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
                continue;
            },
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse {
                    try sendError(session_runtime, fd, "PROTOCOL_ERROR", "unexpected empty terminal stream item", "");
                    return false;
                };
                switch (item_payload) {
                    .resize => continue,
                    .open => |open| {
                        if (open.create == null) {
                            var request = try attachRequestFromOpen(open);
                            defer request.deinit();
                            if (request.session_guid.len == 0) return error.MissingSessionGuid;
                            const session = findSession(session_runtime, request.session_guid);
                            const resolved_session = session orelse {
                                try sendError(session_runtime, fd, "SESSION_NOT_FOUND", "session not found", "");
                                return false;
                            };
                            updateSessionSize(resolved_session, request.resize.rows, request.resize.cols);
                            try attachSession(session_runtime, fd, request.resize, request.capture_tty_transcript);
                            return true;
                        }

                        const open_payload = try protocol.encodePayload(app_allocator.allocator(), open);
                        defer app_allocator.allocator().free(open_payload);
                        var request = readSessionCreateRequest(open_payload) catch {
                            try sendError(session_runtime, fd, "PROTOCOL_ERROR", "invalid terminal stream open payload", "");
                            return false;
                        };
                        defer request.deinit();
                        _ = try createSession(
                            session_runtime,
                            request.resize.rows,
                            request.resize.cols,
                            request.scrollback_row_count,
                            request.environment,
                            request.query_default_colors,
                            request.session_guid,
                            request.command_argv,
                            request.shell_command,
                            request.tty_settings,
                            request.reap_ms,
                        );
                        try attachSession(session_runtime, fd, request.resize, request.capture_tty_transcript);
                        return true;
                    },
                    .debug_sever_connection_request => |request| {
                        try handleSessionClientDebugSeverConnectionRequest(session_runtime, fd, request);
                        return false;
                    },
                    .debug_unresponsive_connection_request => |request| {
                        try handleSessionClientDebugUnresponsiveConnectionRequest(session_runtime, fd, request);
                        return false;
                    },
                    else => {
                        try sendError(session_runtime, fd, "PROTOCOL_ERROR", "unexpected first terminal stream item", "");
                        return false;
                    },
                }
            },
            else => {
                try sendError(session_runtime, fd, "PROTOCOL_ERROR", "unexpected first action", "");
                return false;
            },
        }
    }
}

fn requestGracefulShutdown(session_runtime: *SessionRuntime) void {
    if (session_runtime.shutting_down) return;
    session_runtime.shutting_down = true;
    if (session_runtime.session.alive) endSession(session_runtime, 1, .{ .ended_at_unix_ms = nowUnixMs() });
}

fn acceptRemoteHandshake(session_runtime: *SessionRuntime, fd: c.fd_t) !HandshakeResult {
    _ = session_runtime;
    var peer_hello = try readHelloRequest(fd);
    defer peer_hello.deinit(app_allocator.allocator());
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing remote session runtime is incompatible with this client", "Start a fresh sessh connection with matching binaries");
        return .mismatch;
    }
    try sendHelloOk(fd);
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(fd);
    defer if (hello_error) |*err| err.deinit(app_allocator.allocator());
    if (hello_error) |_| {
        return .mismatch;
    }
    return .accepted;
}

fn readHelloRequest(fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, app_allocator.allocator(), frame.payload),
            else => {
                try sendHelloError(fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), fd);
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

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
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

fn sendError(session_runtime: *SessionRuntime, fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    _ = session_runtime;
    try sendErrorFrame(fd, code, message, hint);
}

fn sendErrorFrame(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

fn queueAttachedClientError(session_runtime: *SessionRuntime, attached_client: *AttachedClient, code: []const u8, message: []const u8, hint: []const u8) !void {
    _ = session_runtime;
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachedClientFrame(attached_client, .error_message, payload);
}

fn queueAttachedClientFrame(attached_client: *AttachedClient, message_type: protocol.MessageType, payload: []const u8) !void {
    const frame = try protocol.encodeFrame(app_allocator.allocator(), message_type, payload);
    defer app_allocator.allocator().free(frame);
    const frame_len = frame.len;
    if (frame_len > max_attached_client_output_queue_bytes or
        attached_client.queuedBytes() > max_attached_client_output_queue_bytes - frame_len)
    {
        return error.AttachedClientOutputQueueFull;
    }

    compactAttachedClientOutput(attached_client);
    try attached_client.output.appendSlice(app_allocator.allocator(), frame);
}

fn queueAttachedClientTeFrame(attached_client: *AttachedClient, payload: pb.TerminalEmulatorItem.payload_union) !void {
    const encoded = try protocol.encodePayload(app_allocator.allocator(), pb.ClientRemoteItem{
        .payload = .{ .terminal_emulator = .{ .payload = payload } },
    });
    defer app_allocator.allocator().free(encoded);
    try queueAttachedClientFrame(attached_client, .client_remote, encoded);
}

fn compactAttachedClientOutput(attached_client: *AttachedClient) void {
    if (attached_client.output_offset == 0) return;
    if (attached_client.output_offset >= attached_client.output.items.len) {
        attached_client.output.clearRetainingCapacity();
        attached_client.output_offset = 0;
        return;
    }

    const remaining = attached_client.output.items.len - attached_client.output_offset;
    std.mem.copyForwards(
        u8,
        attached_client.output.items[0..remaining],
        attached_client.output.items[attached_client.output_offset..],
    );
    attached_client.output.shrinkRetainingCapacity(remaining);
    attached_client.output_offset = 0;
}

fn flushAttachedClientOutput(session_runtime: *SessionRuntime) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    if (attached_client.debug_unresponsive_until_ms != 0) {
        const now_ms = sessionRuntimeMonotonicMs(session_runtime);
        if (attached_client.debug_unresponsive_until_ms > now_ms) return;
        attached_client.debug_unresponsive_until_ms = 0;
    }

    while (attached_client.output_offset < attached_client.output.items.len) {
        const result = io.writeSomeNonBlocking(attached_client.fd, attached_client.output.items[attached_client.output_offset..]) catch {
            disconnectAttachedClient(session_runtime);
            return;
        };
        switch (result) {
            .wrote => |n| {
                if (n == 0) break;
                attached_client.output_offset += n;
            },
            .would_block => return,
        }
    }

    if (attached_client.output_offset >= attached_client.output.items.len) {
        attached_client.output.clearRetainingCapacity();
        attached_client.output_offset = 0;
        if (attached_client.close_after_flush) {
            disconnectAttachedClient(session_runtime);
        }
    }
}

fn sendSessionAttachedForSession(session_runtime: *const SessionRuntime, attached_client: *AttachedClient, session: *const Session) !void {
    _ = session_runtime;
    try queueAttachedClientTeFrame(attached_client, .{ .session_attached = .{
        .session_guid = session.idSlice(),
    } });
}

fn handleSessionClientDebugSeverConnectionRequest(session_runtime: *SessionRuntime, fd: c.fd_t, request: pb.TerminalEmulatorItem.SessionClientDebugSeverConnectionRequest) !void {
    _ = request;
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) {
        try sendError(session_runtime, fd, "NO_ATTACHED_CLIENTS", "no attached clients", "");
        return;
    }
    disconnectAttachedClient(session_runtime);
    try sendClientControlResponse(fd);
}

fn handleSessionClientDebugUnresponsiveConnectionRequest(session_runtime: *SessionRuntime, fd: c.fd_t, request: pb.TerminalEmulatorItem.SessionClientDebugUnresponsiveConnectionRequest) !void {
    const seconds = if (request.seconds == 0)
        config.default_debug_unresponsive_seconds
    else
        request.seconds;
    const until_ms = sessionRuntimeMonotonicMs(session_runtime) + @as(i64, seconds) * std.time.ms_per_s;
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) {
        try sendError(session_runtime, fd, "NO_ATTACHED_CLIENTS", "no attached clients", "");
        return;
    }
    attached_client.debug_unresponsive_until_ms = until_ms;
    try sendClientControlResponse(fd);
}

fn sendClientControlResponse(fd: c.fd_t) !void {
    try protocol.sendTeStreamPayloadFrame(app_allocator.allocator(), fd, .{ .session_client_control_response = .{} });
}

fn sendSessionEnded(attached_client: *AttachedClient, reason: u8, exit_info: ExitInfo) !void {
    const exit_status: ?pb.TerminalEmulatorItem.SessionEnded.ExitStatus = switch (exit_info.kind) {
        1 => .{ .kind = .KIND_EXITED, .status = exit_info.status },
        2 => .{ .kind = .KIND_SIGNALLED, .status = exit_info.status },
        else => null,
    };
    try queueAttachedClientTeFrame(attached_client, .{ .session_ended = .{
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

fn queueTtyTranscriptChunk(
    attached_client: *AttachedClient,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) !void {
    if (!attached_client.capture_tty_transcript or bytes.len == 0) return;
    try queueAttachedClientTeFrame(attached_client, .{ .tty_transcript_chunk = .{
        .stream = stream,
        .data = bytes,
    } });
}

fn queueTtyTranscriptChunkForSession(
    session_runtime: *SessionRuntime,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    if (attached_client.close_after_flush or !attached_client.capture_tty_transcript) return;
    queueTtyTranscriptChunk(attached_client, stream, bytes) catch {
        disconnectAttachedClient(session_runtime);
    };
}

fn readDefaultColorValue(color: u32) !u32 {
    if (color == vt.CellAttrs.default_color) return color;
    if ((color & 0xff000000) == 0x01000000) return color;
    return error.InvalidDefaultColor;
}

fn encodeScrollbackCursor(out: *[encoded_scrollback_cursor_len]u8, epoch: u64, per_epoch_cursor: u64) void {
    writeU64BigEndian(out[0..8], epoch);
    writeU64BigEndian(out[8..16], per_epoch_cursor);
}

fn decodeScrollbackCursor(bytes: []const u8) !ScrollbackCursor {
    if (bytes.len == 0) return .{ .epoch = 0, .per_epoch_cursor = 0 };
    if (bytes.len != encoded_scrollback_cursor_len) return error.InvalidScrollbackCursor;
    return .{
        .epoch = readU64BigEndian(bytes[0..8]),
        .per_epoch_cursor = readU64BigEndian(bytes[8..16]),
    };
}

fn writeU64BigEndian(bytes: []u8, value: u64) void {
    bytes[0] = @intCast((value >> 56) & 0xff);
    bytes[1] = @intCast((value >> 48) & 0xff);
    bytes[2] = @intCast((value >> 40) & 0xff);
    bytes[3] = @intCast((value >> 32) & 0xff);
    bytes[4] = @intCast((value >> 24) & 0xff);
    bytes[5] = @intCast((value >> 16) & 0xff);
    bytes[6] = @intCast((value >> 8) & 0xff);
    bytes[7] = @intCast(value & 0xff);
}

fn readU64BigEndian(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        @as(u64, bytes[7]);
}

fn queueDrawFrame(
    attached_client: *AttachedClient,
    session: *const Session,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    app_title_present: ?bool,
    attached_client_end_restore_bytes: ?[]const u8,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, scrollback_cursor);
    try queueAttachedClientTeFrame(attached_client, .{ .draw = .{
        .scrollback_cursor = encoded_cursor[0..],
        .viewport_offset = attached_client.presentation.protocolViewportOffset(),
        .draw_bytes = draw_bytes,
        .app_title_present = app_title_present,
        .attached_client_end_restore_bytes = attached_client_end_restore_bytes,
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

fn queueRenderBarrierDraw(
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
    try queueDrawFrame(
        attached_client,
        session,
        scrollback_cursor,
        bytes.items,
        null,
        renderBarrierAttachedClientEndRestoreBytes(barrier),
    );
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
    try queueDrawFrame(attached_client, session, scrollback_cursor, bytes.items, null, null);
}

fn queueScrollbackRowsAndScreenDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    rows: []const vt.RenderedRow,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    align_viewport: bool,
    scrollback_cursor: u64,
) !void {
    if (rows.len == 0) return;
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const plain_replay = session.pending_plain_output.items;
    if (try attached_client.presentation.canApplyPlainReplay(
        screen,
        align_viewport,
        plain_replay,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attached_client.presentation.assumePlainReplayScreen(session.rows, screen);
        try queueDrawFrame(attached_client, session, scrollback_cursor, plain_replay, screen.title_present, null);
        return;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    // Screen clears first copy the old visible rows into scrollback, then draw
    // the cleared screen. After that copy, another alignment pass would only
    // add blank rows to scrollback.
    const align_after_scrollback = align_viewport and screen.display_clear == null;
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, screen, align_after_scrollback);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        effective_align_viewport = false;
    }
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try attached_client.presentation.appendScrollbackRows(renderer, session.rows, rows);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        // Full-screen clears must happen after copying the old rows. Clearing
        // first would leave those rows nowhere to go except back on screen.
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, screen);
    }
    try attached_client.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, screen, restore_screen, &restore_bytes);
    try queueDrawFrame(attached_client, session, scrollback_cursor, bytes.items, screen.title_present, restore);
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
    try queueDrawFrame(attached_client, session, scrollback_cursor, bytes.items, null, null);
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

fn queueScreenDraw(
    attached_client: *AttachedClient,
    session: *const Session,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    force_redraw: bool,
    align_viewport: bool,
    scrollback_cursor: u64,
) !bool {
    const plain_replay = session.pending_plain_output.items;
    if (try attached_client.presentation.canApplyPlainReplay(
        screen,
        align_viewport,
        plain_replay,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attached_client.presentation.assumePlainReplayScreen(session.rows, screen);
        try queueDrawFrame(attached_client, session, scrollback_cursor, plain_replay, screen.title_present, null);
        return true;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, screen, align_viewport);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, screen);
        effective_align_viewport = false;
    }
    try attached_client.presentation.applyScreen(renderer, session.rows, screen, force_redraw, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, screen);
    if (bytes.items.len > 0) {
        try appendDrawCleanup(&bytes);
        try wrapDrawInSynchronizedUpdate(&bytes);
        var restore_bytes = std.ArrayList(u8).empty;
        defer restore_bytes.deinit(app_allocator.allocator());
        const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, screen, restore_screen, &restore_bytes);
        try queueDrawFrame(attached_client, session, scrollback_cursor, bytes.items, screen.title_present, restore);
        return true;
    }
    return false;
}

fn advanceScrollbackEpoch(session: *Session) void {
    session.scrollback_epoch +%= 1;
    if (session.scrollback_epoch == 0) session.scrollback_epoch = 1;
}

fn advanceScrollbackEpochForClear(session: *Session) void {
    advanceScrollbackEpoch(session);
    session.last_scrollback_clear_epoch = session.scrollback_epoch;
}

fn queueRetainedScrollbackClearDraw(attached_client: *AttachedClient, session: *Session) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attached_client.presentation.preparePrimaryForScrollback(renderer);
    try renderer.clearScrollback();
    try queueDrawFrame(attached_client, session, 0, bytes.items, null, null);
}

fn queueRepaintResponseFrame(
    attached_client: *AttachedClient,
    session: *const Session,
    repaint_request_seq: u64,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    app_title_present: ?bool,
    attached_client_end_restore_bytes: ?[]const u8,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, scrollback_cursor);
    try queueAttachedClientTeFrame(attached_client, .{ .repaint_response = .{
        .repaint_request_seq = repaint_request_seq,
        .draw = .{
            .scrollback_cursor = encoded_cursor[0..],
            .viewport_offset = attached_client.presentation.protocolViewportOffset(),
            .draw_bytes = draw_bytes,
            .app_title_present = app_title_present,
            .attached_client_end_restore_bytes = attached_client_end_restore_bytes,
        },
    } });
}

fn queueRepaintResponseDraw(
    attached_client: *AttachedClient,
    session: *Session,
    repaint_request_seq: u64,
    clear_for_replace: bool,
    truncated_rows: u64,
    rows: []const vt.RenderedRow,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    scrollback_cursor: u64,
) !void {
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    if (clear_for_replace) {
        try attached_client.presentation.preparePrimaryForScrollback(renderer);
        try renderer.clearForReplace();
        attached_client.presentation.reset();
    }
    var effective_align_viewport = shouldAlignViewportForDraw(attached_client, screen, false);
    if (!clear_for_replace and shouldClearOuterVisibleForDisplayClear(screen)) {
        try attached_client.presentation.clearOuterVisibleForScreen(renderer, screen);
        effective_align_viewport = false;
    }
    if (truncated_rows > 0 or rows.len > 0) {
        try attached_client.presentation.preparePrimaryForScrollback(renderer);
    }
    if (truncated_rows > 0) try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try attached_client.presentation.appendScrollbackRows(renderer, session.rows, rows);
    try attached_client.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attached_client.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attached_client, screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendAttachedClientEndRestoreBytes(attached_client, session, screen, restore_screen, &restore_bytes);
    try queueRepaintResponseFrame(attached_client, session, repaint_request_seq, scrollback_cursor, bytes.items, screen.title_present, restore);
}

fn queueRepaintSnapshot(
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
        try queueRepaintResponseDraw(
            attached_client,
            session,
            request.repaint_request_seq,
            clear_for_replace or clear_scrollback_for_stale_clear,
            truncated_rows_to_report,
            rows_to_draw,
            &screen,
            if (primary_screen) |*primary| primary else null,
            scrollback.absolute_count,
        );
    } else {
        const scrollback_cursor = try model.scrollbackCursor();
        try queueRepaintResponseDraw(
            attached_client,
            session,
            request.repaint_request_seq,
            clear_for_replace,
            0,
            &.{},
            &screen,
            if (primary_screen) |*primary| primary else null,
            scrollback_cursor,
        );
    }

    return screen.rows.len;
}

fn sendSessionSnapshot(attached_client: *AttachedClient, session: *Session) !void {
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
        _ = try queueScreenDraw(
            attached_client,
            session,
            &screen,
            if (primary_screen) |*primary| primary else null,
            true,
            false,
            scrollback.absolute_count,
        );
        model.markScrollbackReported();
        model.markRendered(screen.rows.len);
        return;
    }
}

fn sendSessionRepaintSnapshot(attached_client: *AttachedClient, session: *Session, request: RepaintRequest) !void {
    const model = session.terminal_model orelse return;
    const screen_rows = try queueRepaintSnapshot(attached_client, session, request, false);
    model.markScrollbackReported();
    model.markRendered(screen_rows);
}

fn updateSessionSize(session: *Session, rows: u16, cols: u16) void {
    const resized = session.rows != rows or session.cols != cols;
    session.rows = rows;
    session.cols = cols;
    if (session.terminal_model) |model| {
        model.resize(rows, cols) catch {};
        if (resized) advanceScrollbackEpoch(session);
    }
    _ = terminal.setPtySize(session.pty_fd, rows, cols);
}

fn readSessionCreateRequest(payload: []const u8) !SessionCreateRequest {
    var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, app_allocator.allocator(), payload);
    defer open.deinit(app_allocator.allocator());
    const message = open.create orelse return error.MissingSessionCreate;
    const resize = open.resize orelse return error.MissingResize;
    if (!session_registry.isValidSessionGuid(open.session_guid)) return error.InvalidSessionGuid;
    var environment = SessionEnvironment{};
    errdefer environment.deinit();
    var query_default_colors = vt.DefaultColors{};
    var request_tty_settings: ?tty_settings.Settings = null;
    errdefer if (request_tty_settings) |*settings| settings.deinit(app_allocator.allocator());

    for (message.environment.items) |entry| {
        try applySessionEnvironmentEntry(&environment, entry);
    }
    if (message.query_default_colors) |colors| {
        query_default_colors = try readDefaultColors(colors);
    }
    if (message.tty_settings) |settings| {
        request_tty_settings = try readTtySettings(settings);
    }
    var source_argv: []const []const u8 = &.{};
    var shell_command: ?[]const u8 = null;
    if (message.command) |command| switch (command) {
        .exec_command => |exec| source_argv = exec.argv.items,
        .shell_command => |shell| shell_command = shell.command,
    };

    const command_argv = try app_allocator.allocator().alloc([]u8, source_argv.len);
    var command_argv_initialized: usize = 0;
    errdefer {
        for (command_argv[0..command_argv_initialized]) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(command_argv);
    }
    for (source_argv, 0..) |arg, i| {
        if (arg.len == 0) return error.InvalidCommandArgv;
        command_argv[i] = try app_allocator.allocator().dupe(u8, arg);
        command_argv_initialized += 1;
    }

    return .{
        .resize = try resizePayloadFromMessage(resize),
        .scrollback_row_count = message.scrollback_row_limit,
        .environment = environment,
        .query_default_colors = query_default_colors,
        .session_guid = try app_allocator.allocator().dupe(u8, open.session_guid),
        .command_argv = command_argv,
        .shell_command = if (shell_command) |command|
            try app_allocator.allocator().dupe(u8, command)
        else
            null,
        .tty_settings = request_tty_settings,
        .reap_ms = message.reap_ms,
        .capture_tty_transcript = open.capture_tty_transcript,
    };
}

fn readTtySettings(message: pb.TerminalEmulatorItem.SessionCreate.TtySettings) !tty_settings.Settings {
    var modes = try app_allocator.allocator().alloc(tty_settings.Mode, message.tty_mode.items.len);
    errdefer app_allocator.allocator().free(modes);
    for (message.tty_mode.items, 0..) |mode, i| {
        if (mode.opcode > std.math.maxInt(u8)) return error.InvalidTtySettings;
        modes[i] = .{
            .opcode = @intCast(mode.opcode),
            .value = mode.value,
        };
    }

    return .{
        .term = if (message.term) |term|
            try app_allocator.allocator().dupe(u8, term)
        else
            null,
        .modes = modes,
    };
}

fn applySessionEnvironmentEntry(environment: *SessionEnvironment, entry: pb.EnvironmentEntry) !void {
    if (!isValidEnvironmentEntry(entry)) return error.InvalidEnvironmentEntry;
    if (sessionEnvironmentHasEntry(environment, entry.name)) return;

    const name = try app_allocator.allocator().dupeZ(u8, entry.name);
    errdefer app_allocator.allocator().free(name);
    const value = try app_allocator.allocator().dupeZ(u8, entry.value);
    errdefer app_allocator.allocator().free(value);
    try environment.entries.append(app_allocator.allocator(), .{
        .name = name,
        .value = value,
    });

    if (std.mem.eql(u8, entry.name, "SHELL") and entry.value.len > 0 and environment.shell == null) {
        if (environment.shell) |shell| app_allocator.allocator().free(shell);
        environment.shell = try app_allocator.allocator().dupe(u8, entry.value);
    }
}

fn sessionEnvironmentHasEntry(environment: *const SessionEnvironment, name: []const u8) bool {
    for (environment.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn isValidEnvironmentEntry(entry: pb.EnvironmentEntry) bool {
    return isValidEnvironmentName(entry.name) and
        std.mem.indexOfScalar(u8, entry.value, 0) == null;
}

fn isValidEnvironmentName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfScalar(u8, name, '=') == null and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

fn readDefaultColors(colors: pb.TerminalEmulatorItem.SessionCreate.DefaultColors) !vt.DefaultColors {
    return .{
        .foreground_color = try readDefaultColorValue(colors.foreground_color),
        .background_color = try readDefaultColorValue(colors.background_color),
    };
}

fn resizePayloadFromMessage(message: pb.TerminalEmulatorItem.Resize) !ResizePayload {
    if (message.terminal_rows > std.math.maxInt(u16) or
        message.terminal_cols > std.math.maxInt(u16))
    {
        return error.IntOutOfRange;
    }
    if (message.viewport_offset) |offset| {
        if (offset < -1) return error.InvalidViewportOffset;
        if (offset > std.math.maxInt(u16)) return error.IntOutOfRange;
    }
    return .{
        .rows = @intCast(message.terminal_rows),
        .cols = @intCast(message.terminal_cols),
        .viewport_offset = message.viewport_offset,
        .repaint_request = if (message.repaint_request) |repaint| try repaintRequestFromMessage(repaint) else null,
    };
}

fn attachRequestFromOpen(message: pb.TerminalEmulatorItem.Open) !AttachRequest {
    const resize = message.resize orelse return error.MissingResize;
    if (message.session_guid.len > 0 and !session_registry.isValidSessionGuid(message.session_guid)) return error.InvalidSessionGuid;
    return .{
        .resize = try resizePayloadFromMessage(resize),
        .session_guid = try app_allocator.allocator().dupe(u8, message.session_guid),
        .capture_tty_transcript = message.capture_tty_transcript,
    };
}

fn repaintRequestFromMessage(message: pb.TerminalEmulatorItem.RepaintRequest) !RepaintRequest {
    return .{
        .repaint_request_seq = message.repaint_request_seq,
        .scrollback_cursor = if (message.scrollback_cursor) |cursor|
            try decodeScrollbackCursor(cursor)
        else
            null,
    };
}

fn createSession(
    session_runtime: *SessionRuntime,
    rows: u16,
    cols: u16,
    scrollback_row_count: u32,
    session_environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    settings: ?tty_settings.Settings,
    reap_ms: u64,
) !*Session {
    if (session_runtime.started_session or session_runtime.session.alive or session_runtime.attached_client.active) return error.TooManySessions;

    const terminal_model = try vt.SessionTerminal.createWithDefaultColors(
        app_allocator.allocator(),
        rows,
        cols,
        scrollback_row_count,
        query_default_colors,
    );
    errdefer terminal_model.destroy();

    if (!session_registry.isValidSessionGuid(session_guid)) return error.InvalidSessionGuid;
    const session_guid_z = try app_allocator.allocator().dupeZ(u8, session_guid);
    defer app_allocator.allocator().free(session_guid_z);

    const shell_path = session_environment.shell orelse pty_process.defaultShellPath();
    const child = try pty_process.spawn(app_allocator.allocator(), .{
        .rows = rows,
        .cols = cols,
        .shell = shell_path,
        .command_argv = command_argv,
        .shell_command = shell_command,
        .environment = session_environment.entries.items,
        .session_guid = session_guid_z,
        .add_sessh_path_to_env = true,
        .tty_settings = settings,
    });

    const session = &session_runtime.session;
    session.* = Session{
        .pid = child.pid,
        .pty_fd = child.master_fd,
        .terminal_model = terminal_model,
        .rows = rows,
        .cols = cols,
        .scrollback_row_count = scrollback_row_count,
        .reap_ms = reap_ms,
        .alive = true,
    };
    @memcpy(session.id[0..session_guid.len], session_guid);
    session.id_len = session_guid.len;
    session_runtime.started_session = true;
    return session;
}

const PreparedCommand = struct {
    argv: [:null]?[*:0]const u8,
    owned_args: [][:0]u8,

    fn deinit(self: *PreparedCommand, allocator: std.mem.Allocator) void {
        for (self.owned_args) |arg| allocator.free(arg);
        allocator.free(self.owned_args);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

fn prepareCommandArgv(allocator: std.mem.Allocator, command_argv: []const []const u8) !PreparedCommand {
    if (command_argv.len == 0) return error.InvalidCommandArgv;
    return prepareCommandArgvInner(allocator, command_argv, false);
}

fn prepareCommandArgvInner(allocator: std.mem.Allocator, command_argv: []const []const u8, allow_empty_args: bool) !PreparedCommand {
    var owned_args = try allocator.alloc([:0]u8, command_argv.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(owned_args);
    }

    var argv = try allocator.allocSentinel(?[*:0]const u8, command_argv.len, null);
    errdefer allocator.free(argv);

    for (command_argv, 0..) |arg, i| {
        if (!allow_empty_args and arg.len == 0) return error.InvalidCommandArgv;
        owned_args[i] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[i] = owned_args[i].ptr;
    }
    return .{ .argv = argv, .owned_args = owned_args };
}

fn prepareShellCommand(allocator: std.mem.Allocator, shell_path: []const u8, shell_command: []const u8) !PreparedCommand {
    const shell_dash_c = [_][]const u8{ shell_path, "-c", shell_command };
    return prepareCommandArgvInner(allocator, &shell_dash_c, true);
}

test "prepareShellCommand preserves an explicit empty command" {
    var command = try prepareShellCommand(std.testing.allocator, "/bin/sh", "");
    defer command.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("-c", std.mem.span(command.argv[1].?));
    try std.testing.expectEqualStrings("", std.mem.span(command.argv[2].?));
}

fn loginShellArg0(allocator: std.mem.Allocator, shell_path: []const u8) ![:0]u8 {
    const base = std.fs.path.basename(shell_path);
    const name = if (base.len == 0) "sh" else base;
    var arg = try allocator.allocSentinel(u8, name.len + 1, 0);
    arg[0] = '-';
    @memcpy(arg[1 .. 1 + name.len], name);
    return arg;
}

fn defaultShellPath() []const u8 {
    const env_shell = if (c.getenv("SHELL")) |shell_z| std.mem.span(shell_z) else null;
    const passwd_shell = if (c.getpwuid(c.getuid())) |passwd|
        if (passwd.shell) |shell_z| std.mem.span(shell_z) else null
    else
        null;
    return chooseDefaultShell(env_shell, passwd_shell);
}

fn chooseDefaultShell(env_shell: ?[]const u8, passwd_shell: ?[]const u8) []const u8 {
    if (env_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    if (passwd_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    return "/bin/sh";
}

fn sesshPathForEnvironment(allocator: std.mem.Allocator) ![:0]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    return allocator.dupeZ(u8, exe_dir);
}

fn pathWithSesshPathForEnvironment(allocator: std.mem.Allocator, sessh_path: []const u8) ![:0]u8 {
    if (c.getenv("PATH")) |path_z| {
        const path = std.mem.span(path_z);
        if (path.len > 0) {
            const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path, sessh_path });
            defer allocator.free(combined);
            return allocator.dupeZ(u8, combined);
        }
    }
    return allocator.dupeZ(u8, sessh_path);
}

test "login shell argv0 uses dash-prefixed basename" {
    const allocator = std.testing.allocator;
    const arg = try loginShellArg0(allocator, "/usr/local/bin/zsh");
    defer allocator.free(arg);
    try std.testing.expectEqualStrings("-zsh", arg);
}

test "default shell prefers process environment then passwd then sh" {
    try std.testing.expectEqualStrings("/bin/zsh", chooseDefaultShell("/bin/zsh", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", chooseDefaultShell("", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/sh", chooseDefaultShell(null, ""));
}

fn attachSession(
    session_runtime: *SessionRuntime,
    client_fd: c.fd_t,
    resize: ResizePayload,
    capture_tty_transcript: bool,
) !void {
    const session = &session_runtime.session;
    disconnectAttachedClient(session_runtime);

    const attached_client = &session_runtime.attached_client;
    attached_client.* = .{
        .fd = client_fd,
        .rows = resize.rows,
        .cols = resize.cols,
        .attached_at_unix_ms = nowUnixMs(),
        .active = true,
        .capture_tty_transcript = capture_tty_transcript,
    };
    attached_client.presentation.setViewportOffset(resize.viewport_offset);
    errdefer {
        attached_client.output.deinit(app_allocator.allocator());
        attached_client.* = AttachedClient{};
    }
    try sendSessionAttachedForSession(session_runtime, attached_client, session);
    if (resize.repaint_request) |request| {
        try sendSessionRepaintSnapshot(attached_client, session, request);
    } else {
        try sendSessionSnapshot(attached_client, session);
    }
    refreshAttachedFlag(session_runtime);
    flushAttachedClientOutput(session_runtime);
}

fn updateSynchronizedOutputState(session_runtime: *SessionRuntime, now_ms: i64) bool {
    const session = &session_runtime.session;
    const model = session.terminal_model orelse {
        session.synchronized_output_since_ms = 0;
        return false;
    };
    if (!model.synchronizedOutputActive()) {
        session.synchronized_output_since_ms = 0;
        return false;
    }
    if (session.synchronized_output_since_ms == 0) {
        session.synchronized_output_since_ms = now_ms;
    }
    return true;
}

fn shouldDeferSynchronizedOutput(session_runtime: *SessionRuntime, now_ms: i64) bool {
    const session = &session_runtime.session;
    if (!updateSynchronizedOutputState(session_runtime, now_ms)) return false;
    return now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms;
}

fn drainSessionOutput(session_runtime: *SessionRuntime) void {
    const session = &session_runtime.session;
    if (!session.alive) return;

    var context = SessionPtyDrainContext{
        .session_runtime = session_runtime,
    };
    const result = pty_process.drainMasterNonBlocking(
        session.pty_fd,
        &context,
        feedSessionPtyBytes,
        .{
            .max_reads = max_live_output_reads_per_batch,
            .max_bytes = preferred_live_output_batch_bytes,
        },
    ) catch {
        endSessionFromPtyClose(session_runtime);
        return;
    };
    if (!session.alive) return;
    if (result.eof) {
        endSessionFromPtyEof(session_runtime);
        return;
    }
    if (result.read_count == 0) return;

    const now_ms = sessionRuntimeMonotonicMs(session_runtime);
    if (shouldDeferSynchronizedOutput(session_runtime, now_ms)) return;
    broadcastSessionPatch(session_runtime);
    if (session.alive) {
        session.clearPendingPlainOutput();
        if (session.synchronized_output_since_ms != 0) {
            session.synchronized_output_since_ms = now_ms;
        }
    }
}

const SessionPtyDrainContext = struct {
    session_runtime: *SessionRuntime,
};

fn feedSessionPtyBytes(context: *SessionPtyDrainContext, bytes: []const u8) !void {
    const session_runtime = context.session_runtime;
    if (!session_runtime.session.alive) return error.SessionEndedDuringPtyDrain;

    try feedSessionOutputBytes(session_runtime, bytes);

    const session = &session_runtime.session;
    const model = session.terminal_model orelse return;
    const input_responses = model.pendingInputResponses();
    if (input_responses.len == 0) return;
    io.writeAll(session.pty_fd, input_responses) catch return error.SessionPtyResponseWriteFailed;
    model.clearPendingInputResponses();
}

const RenderBarrierContext = struct {
    session_runtime: *SessionRuntime,
};

fn handleSessionRenderBarrier(context: *anyopaque, model: *vt.SessionTerminal, barrier: vt.RenderBarrier) anyerror!void {
    _ = model;
    const barrier_context: *RenderBarrierContext = @ptrCast(@alignCast(context));
    try flushSessionRenderBarrier(barrier_context.session_runtime, barrier);
}

fn flushSessionRenderBarrier(session_runtime: *SessionRuntime, barrier: vt.RenderBarrier) !void {
    const session = &session_runtime.session;
    if (!session.alive) return;
    const model = session.terminal_model orelse return;

    // A render barrier means the current VT state must be queued before the
    // following terminal transition is applied. Original-byte replay cannot
    // cross this boundary because the bytes before the barrier are already
    // inside the VT model and may not match the bytes currently buffered here.
    session.clearPendingPlainOutput();
    broadcastSessionPatch(session_runtime);
    session.clearPendingPlainOutput();

    if (!session.alive) return;
    const scrollback_cursor = try model.scrollbackCursor();
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) return;
    queueRenderBarrierDraw(attached_client, session, barrier, scrollback_cursor) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    flushAttachedClientOutput(session_runtime);
}

fn feedSessionOutputBytes(session_runtime: *SessionRuntime, bytes: []const u8) !void {
    const session = &session_runtime.session;
    queueTtyTranscriptChunkForSession(session_runtime, .STREAM_INNER_OUT, bytes);
    if (session.terminal_model) |model| {
        const starts_at_boundary = model.isPlainTextParserBoundary();
        var barrier_context = RenderBarrierContext{
            .session_runtime = session_runtime,
        };
        const saw_render_barrier = try model.feedWithRenderBarriers(
            bytes,
            &barrier_context,
            handleSessionRenderBarrier,
        );
        if (!saw_render_barrier and hasActiveAttachedClient(session_runtime)) {
            try session.appendPendingPlainOutput(bytes, starts_at_boundary);
        }
    }
}

fn drainAttachedClientInput(session_runtime: *SessionRuntime) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    const session = &session_runtime.session;
    if (!session.alive) {
        disconnectAttachedClient(session_runtime);
        return;
    }

    var frame = protocol.readFrameAlloc(app_allocator.allocator(), attached_client.fd) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    defer frame.deinit(app_allocator.allocator());

    switch (frame.message_type) {
        .client_remote => {
            var item = protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload) catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse {
                disconnectAttachedClient(session_runtime);
                return;
            };
            switch (item_payload) {
                .input => |input| handleInputFrame(session_runtime, input),
                .resize => |resize| handleResizeFrame(session_runtime, resize),
                .repaint_request => |repaint| handleRepaintFrame(session_runtime, repaint),
                .session_hangup_request => handleSessionHangupRequest(session_runtime),
                else => {
                    queueAttachedClientError(session_runtime, attached_client, "PROTOCOL_ERROR", "unexpected attached terminal stream item", "") catch {
                        disconnectAttachedClient(session_runtime);
                        return;
                    };
                    closeAttachedClientAfterFlush(session_runtime);
                },
            }
        },
        .daemon_tunnel => {
            _ = protocol.handleTransportControlFrame(frame.message_type, frame.payload, attached_client.fd) catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
        },
        else => {
            queueAttachedClientError(session_runtime, attached_client, "PROTOCOL_ERROR", "unexpected attached message", "") catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
            closeAttachedClientAfterFlush(session_runtime);
        },
    }
}

fn handleSessionHangupRequest(session_runtime: *SessionRuntime) void {
    requestSessionPtyHangup(session_runtime);
}

fn requestSessionPtyHangup(session_runtime: *SessionRuntime) void {
    const session = &session_runtime.session;
    if (!session.alive) {
        disconnectAttachedClient(session_runtime);
        return;
    }

    disconnectAttachedClient(session_runtime);
    if (session.pty_fd >= 0) {
        _ = c.close(session.pty_fd);
        session.pty_fd = -1;
        session.pty_closed_for_hangup = true;
        session.synchronized_output_since_ms = 0;
    }
    _ = reapPtyHangupSessionIfExited(session_runtime);
}

fn reapPtyHangupSessionIfExited(session_runtime: *SessionRuntime) bool {
    const session = &session_runtime.session;
    if (!session.alive or !session.pty_closed_for_hangup) return false;
    if (session.pid <= 0) {
        endSessionFromPtyClose(session_runtime);
        return true;
    }

    var status: c_int = 0;
    const result = c.waitpid(session.pid, &status, 1);
    if (result == session.pid) {
        endSession(session_runtime, session.end_reason, exitInfoFromWaitStatus(status));
        return true;
    }
    if (result < 0) {
        switch (posix.errno(result)) {
            .INTR => return false,
            else => {
                endSessionFromPtyClose(session_runtime);
                return true;
            },
        }
    }
    return false;
}

fn handleInputFrame(session_runtime: *SessionRuntime, input: pb.TerminalEmulatorItem.Input) void {
    const attached_client = &session_runtime.attached_client;
    const session = &session_runtime.session;
    if (input.data.len == 0) return;

    if (input.input_seq != 0) {
        queueAttachedClientTeFrame(attached_client, .{ .input_ack = .{
            .input_seq = input.input_seq,
        } }) catch {
            disconnectAttachedClient(session_runtime);
            return;
        };
        flushAttachedClientOutput(session_runtime);
    }

    if (session.rows != attached_client.rows or session.cols != attached_client.cols) {
        updateSessionSize(session, attached_client.rows, attached_client.cols);
    }

    var translated = std.ArrayList(u8).empty;
    defer translated.deinit(app_allocator.allocator());
    translateAttachedClientInput(attached_client, session, input.data, &translated) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    if (translated.items.len == 0) return;

    queueTtyTranscriptChunk(attached_client, .STREAM_INNER_IN, translated.items) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    flushAttachedClientOutput(session_runtime);

    io.writeAll(session.pty_fd, translated.items) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
}

const SgrMouseReport = struct {
    button: u32,
    col: u32,
    row: u32,
    suffix: u8,
    end: usize,
};

const SgrMouseParse = union(enum) {
    not_mouse,
    incomplete,
    complete: SgrMouseReport,
};

const XtermModifiedKey = struct {
    modifier: u32,
    key_code: u32,
    end: usize,
};

const XtermModifiedKeyParse = union(enum) {
    not_modified,
    incomplete,
    complete: XtermModifiedKey,
};

fn translateAttachedClientInput(
    attached_client: *AttachedClient,
    session: *const Session,
    bytes: []const u8,
    out: *std.ArrayList(u8),
) !void {
    if (!attachedClientLocalInputParserActive(attached_client)) {
        if (attached_client.input_pending_len > 0) {
            try out.appendSlice(app_allocator.allocator(), attached_client.input_pending[0..attached_client.input_pending_len]);
            attached_client.input_pending_len = 0;
        }
        try out.appendSlice(app_allocator.allocator(), bytes);
        return;
    }

    var input = std.ArrayList(u8).empty;
    defer input.deinit(app_allocator.allocator());
    if (attached_client.input_pending_len > 0) {
        try input.appendSlice(app_allocator.allocator(), attached_client.input_pending[0..attached_client.input_pending_len]);
        attached_client.input_pending_len = 0;
    }
    try input.appendSlice(app_allocator.allocator(), bytes);

    var index: usize = 0;
    while (index < input.items.len) {
        if (input.items[index] != 0x1b) {
            try out.append(app_allocator.allocator(), input.items[index]);
            index += 1;
            continue;
        }

        if (attached_client.presentation.terminal_modes_initialized) {
            switch (parseSgrMouseReport(input.items, index)) {
                .complete => |report| {
                    if (attachedClientSgrMouseActive(attached_client)) {
                        try appendTranslatedSgrMouseReport(attached_client, session, report, out);
                    }
                    index = report.end;
                    continue;
                },
                .incomplete => {
                    if (attachedClientSgrMouseActive(attached_client)) {
                        try savePendingAttachedClientInput(attached_client, input.items[index..], out);
                        return;
                    }
                },
                .not_mouse => {},
            }
        }

        switch (parseFocusReport(input.items, index)) {
            .complete => |report| {
                if (attachedClientFocusReportingActive(attached_client)) {
                    try out.appendSlice(app_allocator.allocator(), input.items[index..report.end]);
                }
                index = report.end;
                continue;
            },
            .incomplete => {
                if (attachedClientFocusReportingActive(attached_client)) {
                    try savePendingAttachedClientInput(attached_client, input.items[index..], out);
                    return;
                }
            },
            .not_focus => {},
        }

        if (attachedClientKittyKeyboardActive(attached_client)) {
            switch (parseXtermModifiedKey(input.items, index)) {
                .complete => |key| {
                    try appendKittyKeyboardKey(key, out);
                    index = key.end;
                    continue;
                },
                .incomplete => {
                    try savePendingAttachedClientInput(attached_client, input.items[index..], out);
                    return;
                },
                .not_modified => {},
            }
        }

        try out.append(app_allocator.allocator(), input.items[index]);
        index += 1;
    }
}

fn savePendingAttachedClientInput(attached_client: *AttachedClient, pending: []const u8, out: *std.ArrayList(u8)) !void {
    if (pending.len <= attached_client.input_pending.len) {
        @memcpy(attached_client.input_pending[0..pending.len], pending);
        attached_client.input_pending_len = pending.len;
    } else {
        try out.appendSlice(app_allocator.allocator(), pending);
    }
}

fn attachedClientLocalInputParserActive(attached_client: *const AttachedClient) bool {
    return attached_client.presentation.terminal_modes_initialized;
}

fn attachedClientSgrMouseActive(attached_client: *const AttachedClient) bool {
    return attached_client.presentation.terminal_modes_initialized and
        attached_client.presentation.terminal_modes.mouse_tracking != .disabled and
        attached_client.presentation.terminal_modes.mouse_sgr;
}

fn attachedClientKittyKeyboardActive(attached_client: *const AttachedClient) bool {
    return attached_client.presentation.terminal_modes_initialized and
        attached_client.presentation.terminal_modes.kitty_keyboard_flags != 0;
}

fn attachedClientFocusReportingActive(attached_client: *const AttachedClient) bool {
    return attached_client.presentation.terminal_modes_initialized and
        (attached_client.presentation.terminal_modes.mode_flags & client_renderer.TerminalModes.focus_reporting) != 0;
}

const FocusReport = struct {
    end: usize,
};

const FocusReportParse = union(enum) {
    not_focus,
    incomplete,
    complete: FocusReport,
};

fn parseFocusReport(input: []const u8, start: usize) FocusReportParse {
    const prefix = "\x1b[";
    if (input.len - start < prefix.len) {
        const available = input[start..];
        if (available.len >= 1 and std.mem.eql(u8, available, prefix[0..available.len])) return .incomplete;
        return .not_focus;
    }
    if (!std.mem.eql(u8, input[start .. start + prefix.len], prefix)) return .not_focus;
    if (input.len - start == prefix.len) return .incomplete;
    const final = input[start + prefix.len];
    if (final != 'I' and final != 'O') return .not_focus;
    return .{ .complete = .{ .end = start + prefix.len + 1 } };
}

fn parseXtermModifiedKey(input: []const u8, start: usize) XtermModifiedKeyParse {
    const prefix = "\x1b[27;";
    if (input.len - start < prefix.len) {
        const available = input[start..];
        if (available.len >= 3 and std.mem.eql(u8, available, prefix[0..available.len])) return .incomplete;
        return .not_modified;
    }
    if (!std.mem.eql(u8, input[start .. start + prefix.len], prefix)) return .not_modified;

    var index = start + prefix.len;
    const modifier = parseCsiNumber(input, &index) orelse return if (index >= input.len) .incomplete else .not_modified;
    if (index >= input.len) return .incomplete;
    if (input[index] != ';') return .not_modified;
    index += 1;

    const key_code = parseCsiNumber(input, &index) orelse return if (index >= input.len) .incomplete else .not_modified;
    if (index >= input.len) return .incomplete;
    if (input[index] != '~') return .not_modified;

    return .{ .complete = .{
        .modifier = modifier,
        .key_code = key_code,
        .end = index + 1,
    } };
}

fn parseCsiNumber(input: []const u8, index: *usize) ?u32 {
    var value: u32 = 0;
    var digits: usize = 0;
    while (index.* < input.len) : (index.* += 1) {
        const byte = input[index.*];
        if (byte < '0' or byte > '9') break;
        if (value > 1_000_000) return null;
        value = value * 10 + @as(u32, byte - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return value;
}

fn appendKittyKeyboardKey(key: XtermModifiedKey, out: *std.ArrayList(u8)) !void {
    var buf: [32]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&buf, "\x1b[{};{}u", .{ key.key_code, key.modifier });
    try out.appendSlice(app_allocator.allocator(), encoded);
}

fn parseSgrMouseReport(input: []const u8, start: usize) SgrMouseParse {
    if (input[start] != 0x1b) return .not_mouse;
    if (start + 1 >= input.len) return .incomplete;
    if (input[start + 1] != '[') return .not_mouse;
    if (start + 2 >= input.len) return .incomplete;
    if (input[start + 2] != '<') return .not_mouse;
    var index = start + 3;

    const button = parseSgrMouseNumber(input, &index) orelse return if (index >= input.len) .incomplete else .not_mouse;
    if (index >= input.len) return .incomplete;
    if (input[index] != ';') return .not_mouse;
    index += 1;
    const col = parseSgrMouseNumber(input, &index) orelse return if (index >= input.len) .incomplete else .not_mouse;
    if (index >= input.len) return .incomplete;
    if (input[index] != ';') return .not_mouse;
    index += 1;
    const row = parseSgrMouseNumber(input, &index) orelse return if (index >= input.len) .incomplete else .not_mouse;
    if (index >= input.len) return .incomplete;
    const suffix = input[index];
    if (suffix != 'M' and suffix != 'm') return .not_mouse;

    return .{ .complete = .{
        .button = button,
        .col = col,
        .row = row,
        .suffix = suffix,
        .end = index + 1,
    } };
}

fn parseSgrMouseNumber(input: []const u8, index: *usize) ?u32 {
    var value: u32 = 0;
    var digits: usize = 0;
    while (index.* < input.len) : (index.* += 1) {
        const byte = input[index.*];
        if (byte < '0' or byte > '9') break;
        if (value > 1_000_000) return null;
        value = value * 10 + @as(u32, byte - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return value;
}

fn appendTranslatedSgrMouseReport(
    attached_client: *const AttachedClient,
    session: *const Session,
    report: SgrMouseReport,
    out: *std.ArrayList(u8),
) !void {
    const origin = attached_client.origin orelse return;
    if (report.row <= origin.row or report.col <= origin.col) return;

    const inner_row = report.row - origin.row;
    const inner_col = report.col - origin.col;
    if (inner_row == 0 or inner_col == 0) return;
    if (inner_row > session.rows or inner_col > session.cols) return;

    var buf: [64]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &buf,
        "\x1b[<{};{};{}{c}",
        .{ report.button, inner_col, inner_row, report.suffix },
    );
    try out.appendSlice(app_allocator.allocator(), encoded);
}

test "SGR mouse input is translated from outer to inner coordinates" {
    var attached_client = AttachedClient{
        .origin = .{ .row = 4, .col = 0 },
        .presentation = .{
            .terminal_modes = .{ .mouse_tracking = .normal, .mouse_sgr = true },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[<0;12;5M", &out);
    try std.testing.expectEqualStrings("\x1b[<0;12;1M", out.items);

    out.clearRetainingCapacity();
    try translateAttachedClientInput(&attached_client, &session, "\x1b[<0;12;3M", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "SGR mouse input is dropped when mouse reporting is inactive" {
    var attached_client = AttachedClient{
        .origin = .{ .row = 4, .col = 0 },
        .presentation = .{
            .terminal_modes = .{},
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[<0;12;5M", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "focus reports are forwarded only while focus reporting is active" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{},
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[I", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    attached_client.presentation.terminal_modes.mode_flags = client_renderer.TerminalModes.focus_reporting;
    try translateAttachedClientInput(&attached_client, &session, "\x1b[O", &out);
    try std.testing.expectEqualStrings("\x1b[O", out.items);
}

test "xterm modified key input is translated to kitty when kitty keyboard is active" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[27;2;13~", &out);
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "split xterm modified key input is held and translated after completion" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[27;2;", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(attached_client.input_pending_len > 0);

    try translateAttachedClientInput(&attached_client, &session, "13~", &out);
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "xterm modified key input passes through when kitty keyboard is inactive" {
    var attached_client = AttachedClient{};
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[27;2;13~", &out);
    try std.testing.expectEqualStrings("\x1b[27;2;13~", out.items);
}

test "non-xterm CSI input passes through when kitty keyboard is active" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b[A", &out);
    try std.testing.expectEqualStrings("\x1b[A", out.items);
}

test "plain enter input is not synthesized as kitty when kitty keyboard is active" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\r", &out);
    try std.testing.expectEqualStrings("\r", out.items);
}

test "bare escape is not held by kitty keyboard translation" {
    var attached_client = AttachedClient{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachedClientInput(&attached_client, &session, "\x1b", &out);
    try std.testing.expectEqualStrings("\x1b", out.items);
    try std.testing.expectEqual(@as(usize, 0), attached_client.input_pending_len);
}

fn handleResizeFrame(session_runtime: *SessionRuntime, message: pb.TerminalEmulatorItem.Resize) void {
    const attached_client = &session_runtime.attached_client;
    const session = &session_runtime.session;
    const resize = resizePayloadFromMessage(message) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    const reset_for_screen_repaint = resize.repaint_request != null and
        resize.repaint_request.?.scrollback_cursor == null;
    attached_client.rows = resize.rows;
    attached_client.cols = resize.cols;
    if (reset_for_screen_repaint) attached_client.presentation.resetForScreenRepaint();
    attached_client.presentation.setViewportOffset(resize.viewport_offset);
    updateSessionSize(session, resize.rows, resize.cols);
    if (resize.repaint_request) |request| {
        handleRepaintRequest(session_runtime, request);
    }
}

fn handleRepaintFrame(session_runtime: *SessionRuntime, message: pb.TerminalEmulatorItem.RepaintRequest) void {
    const request = repaintRequestFromMessage(message) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    handleRepaintRequest(session_runtime, request);
}

fn handleRepaintRequest(session_runtime: *SessionRuntime, request: RepaintRequest) void {
    const attached_client = &session_runtime.attached_client;
    const session = &session_runtime.session;

    const model = session.terminal_model orelse return;
    const clear_for_replace = request.scrollback_cursor != null and
        request.scrollback_cursor.?.per_epoch_cursor == 0;
    const screen_rows = queueRepaintSnapshot(attached_client, session, request, clear_for_replace) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    model.markRendered(screen_rows);
    flushAttachedClientOutput(session_runtime);
}

fn broadcastSessionPatch(session_runtime: *SessionRuntime) void {
    if (!hasActiveAttachedClient(session_runtime)) return;

    const session = &session_runtime.session;
    const model = session.terminal_model orelse return;
    var scrollback = model.scrollbackDelta(app_allocator.allocator()) catch {
        endSessionFromPtyClose(session_runtime);
        return;
    };
    defer scrollback.deinit(app_allocator.allocator());

    var screen = model.renderedScreen(app_allocator.allocator()) catch {
        endSessionFromPtyClose(session_runtime);
        return;
    };
    defer screen.deinit(app_allocator.allocator());

    if (screen.dirty_state == .none and
        scrollback.rows.len == 0 and
        !screen.title_dirty and
        !screen.default_colors_dirty and
        !screen.retained_scrollback_clear_dirty and
        screen.display_clear == null)
    {
        return;
    }

    const materialize_screen_after_scrollback = scrollback.rows.len > 0 and
        model.lastRenderedRowCount() == 0 and
        screen.display_clear != null;
    const should_send_screen_draw = screen.dirty_state != .none or
        screen.title_dirty or
        screen.default_colors_dirty or
        screen.retained_scrollback_clear_dirty or
        screen.display_clear != null or
        materialize_screen_after_scrollback;
    var primary_screen: ?vt.RenderedScreen = null;
    defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
    if ((should_send_screen_draw or scrollback.rows.len > 0) and screen.active_screen == 1) {
        primary_screen = model.renderedPrimaryScreen(app_allocator.allocator()) catch {
            endSessionFromPtyClose(session_runtime);
            return;
        };
    }
    if (screen.retained_scrollback_clear_dirty) advanceScrollbackEpochForClear(session);
    var delivered = false;
    const attached_client = &session_runtime.attached_client;
    if (attached_client.active and !attached_client.close_after_flush) {
        if (screen.retained_scrollback_clear_dirty) {
            queueRetainedScrollbackClearDraw(attached_client, session) catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
        }
        if (scrollback.rows.len > 0) {
            queueScrollbackRowsAndScreenDraw(
                attached_client,
                session,
                scrollback.rows,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
        } else if (should_send_screen_draw) {
            _ = queueScreenDraw(
                attached_client,
                session,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                disconnectAttachedClient(session_runtime);
                return;
            };
        }
        flushAttachedClientOutput(session_runtime);
        if (attached_client.active) delivered = true;
    }
    if (delivered) {
        if (scrollback.rows.len > 0) model.markScrollbackReported();
        if (scrollback.rows.len > 0 or
            screen.dirty_state != .none or
            screen.title_dirty or
            screen.default_colors_dirty or
            screen.retained_scrollback_clear_dirty or
            screen.display_clear != null or
            materialize_screen_after_scrollback)
        {
            model.markRendered(screen.rows.len);
        }
    }
}

fn hasActiveAttachedClient(session_runtime: *const SessionRuntime) bool {
    const attached_client = &session_runtime.attached_client;
    return attached_client.active and !attached_client.close_after_flush;
}

fn sendSessionEndedToAttachedClient(session_runtime: *SessionRuntime, reason: u8, exit_info: ExitInfo) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    sendSessionEnded(attached_client, reason, exit_info) catch {
        disconnectAttachedClient(session_runtime);
        return;
    };
    closeAttachedClientAfterFlush(session_runtime);
}

fn disconnectAttachedClient(session_runtime: *SessionRuntime) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;

    _ = c.close(attached_client.fd);
    attached_client.output.deinit(app_allocator.allocator());
    attached_client.* = AttachedClient{};
    refreshAttachedFlag(session_runtime);
}

fn closeAttachedClientAfterFlush(session_runtime: *SessionRuntime) void {
    const attached_client = &session_runtime.attached_client;
    if (!attached_client.active) return;
    attached_client.close_after_flush = true;
    flushAttachedClientOutput(session_runtime);
}

fn refreshAttachedFlag(session_runtime: *SessionRuntime) void {
    const session = &session_runtime.session;
    if (!session.alive) {
        session.attached = false;
        return;
    }

    const now_attached = hasActiveAttachedClient(session_runtime);
    const was_attached = session.attached;
    session.attached = now_attached;
    if (now_attached) {
        session.disconnected_at_unix_ms = 0;
    } else if (was_attached or session.disconnected_at_unix_ms == 0) {
        session.disconnected_at_unix_ms = nowUnixMs();
    }
}

fn endSession(session_runtime: *SessionRuntime, reason: u8, exit_info: ExitInfo) void {
    const session = &session_runtime.session;
    if (!session.alive) return;

    broadcastSessionPatch(session_runtime);
    session.clearPendingPlainOutput();
    session.synchronized_output_since_ms = 0;

    sendSessionEndedToAttachedClient(session_runtime, reason, exit_info);
    if (session.pty_fd >= 0) _ = c.close(session.pty_fd);
    if (session.terminal_model) |model| {
        model.destroy();
        session.terminal_model = null;
    }
    session.deinit();
    session.alive = false;
    session.attached = false;
}

fn stopSessionRuntimeIfComplete(session_runtime: *SessionRuntime) void {
    if (session_runtime.shutting_down) {
        if (session_runtime.attached_client.active) return;
        session_runtime.running = false;
        return;
    }
    if (session_runtime.fixed_session_id == null or !session_runtime.started_session) return;
    if (session_runtime.session.alive) return;
    if (session_runtime.attached_client.active) return;
    session_runtime.running = false;
}

fn closeSessionRuntime(session_runtime: *SessionRuntime) void {
    disconnectAttachedClient(session_runtime);
    endSession(session_runtime, 2, .{});
}

fn findSession(session_runtime: *SessionRuntime, id: []const u8) ?*Session {
    const session = &session_runtime.session;
    if (session.alive and !session.pty_closed_for_hangup and std.mem.eql(u8, session.idSlice(), id)) return session;
    return null;
}

fn endSessionFromPtyClose(session_runtime: *SessionRuntime) void {
    endSession(session_runtime, session_runtime.session.end_reason, .{ .ended_at_unix_ms = nowUnixMs() });
}

fn endSessionFromPtyEof(session_runtime: *SessionRuntime) void {
    // Only ask for child status after PTY EOF. Exit status is useful metadata,
    // but checking it before PTY EOF can race with final terminal output that
    // still needs to be drained from the master fd.
    if (waitForSessionExitInfo(session_runtime.session.pid)) |exit_info| {
        endSession(session_runtime, session_runtime.session.end_reason, exit_info);
        return;
    }
    endSessionFromPtyClose(session_runtime);
}

fn waitForSessionExitInfo(pid: c.pid_t) ?ExitInfo {
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        var status: c_int = 0;
        const result = c.waitpid(pid, &status, 1);
        if (result == pid) return exitInfoFromWaitStatus(status);
        if (result < 0) return null;
        io.sleepMillis(5);
    }
    return null;
}

fn exitInfoFromWaitStatus(status: c_int) ExitInfo {
    const raw: u32 = @bitCast(status);
    const signal_number = raw & 0x7f;
    if (signal_number == 0) {
        return .{
            .kind = 1,
            .status = @intCast((raw >> 8) & 0xff),
            .ended_at_unix_ms = nowUnixMs(),
        };
    }
    return .{
        .kind = 2,
        .status = @intCast(signal_number),
        .ended_at_unix_ms = nowUnixMs(),
    };
}

fn nowUnixMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    if (ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
