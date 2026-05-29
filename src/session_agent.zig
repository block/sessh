const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const client_renderer = @import("client_renderer.zig");
const io = @import("io.zig");
const protocol = @import("protocol.zig");
const runtime_refresher = @import("runtime_refresher.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");
const vt = @import("vt.zig");

const max_sessions = 64;
const max_attachments = 128;
const max_attachment_output_queue_bytes = 64 * 1024 * 1024;
const preferred_live_output_batch_bytes = 1024;
const max_live_output_reads_per_batch = 64;
const synchronized_output_max_hold_ms: i64 = 1000;

const pb = protocol.pb;
const hpb = protocol.hpb;

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

var shutdown_signal_write_fd: c.fd_t = -1;

fn handleShutdownSignal(_: c_int) callconv(.c) void {
    const fd = shutdown_signal_write_fd;
    if (fd < 0) return;
    var byte = [_]u8{1};
    _ = c.write(fd, &byte, byte.len);
}

const Session = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: usize = 0,
    pid: c.pid_t = 0,
    pty_fd: c.fd_t = -1,
    terminal_model: ?*vt.SessionTerminal = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_epoch: u64 = 1,
    last_scrollback_clear_epoch: u64 = 1,
    end_reason: u8 = 0,
    attached: bool = false,
    detached_at_unix_ms: u64 = 0,
    last_input_at_unix_ms: u64 = 0,
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

const Attachment = struct {
    fd: c.fd_t = -1,
    session_index: usize = 0,
    client_guid: [session_registry.client_guid_len]u8 = [_]u8{0} ** session_registry.client_guid_len,
    client_guid_len: usize = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    attached_at_unix_ms: u64 = 0,
    last_input_at_unix_ms: u64 = 0,
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

    fn queuedBytes(self: *const Attachment) usize {
        return self.output.items.len - self.output_offset;
    }

    fn clientGuidSlice(self: *const Attachment) []const u8 {
        return self.client_guid[0..self.client_guid_len];
    }
};

const SessionAgent = struct {
    sessions: [max_sessions]Session = [_]Session{Session{}} ** max_sessions,
    attachments: [max_attachments]Attachment = [_]Attachment{Attachment{}} ** max_attachments,
    next_id: usize = 1,
    running: bool = true,
    shutting_down: bool = false,
    log_file: ?std.fs.File = null,
    monotonic_clock: ?std.time.Timer = null,
    fixed_session_id: ?[]const u8 = null,
    session_paths: ?session_registry.SessionPaths = null,
    started_session: bool = false,
};

const PollKind = union(enum) {
    listen,
    shutdown_signal,
    runtime_repair,
    session: usize,
    attachment: usize,
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

    fn deinit(self: *SessionEnvironment) void {
        if (self.shell) |shell| app_allocator.allocator().free(shell);
        self.* = .{};
    }
};

// What we believe one attached client currently has on its outer terminal.
// This is separate from the headless terminal model. It lets us track the
// inner viewport height and send small redraws when the client is in sync.
const PresentationState = struct {
    initialized: bool = false,
    active_screen: u8 = 0,
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
    // The client may have shown a reconnect banner or skipped stale draws, so
    // cached cursor, mode, and color state is no longer trustworthy. The old
    // height is kept only so the next draw can clear stale rows.
    fn resetForScreenRepaint(self: *PresentationState) void {
        const rendered_rows = self.rendered_rows;
        self.* = .{ .rendered_rows = rendered_rows };
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
        try self.setActiveScreen(screen.active_screen);

        const desired_modes = vtModesToClient(screen.modes);
        const mouse_requested = desired_modes.mouse_tracking != .disabled;

        if (align_viewport) {
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

        if (screen.title_dirty) try renderer.setTitle(screen.title);
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

    // Restore a full-height screen before leaving relay mode, so the user does
    // not return to a partially painted alternate/full-screen app.
    fn applyRelayEndRestoreScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_rows: u16,
        screen: *const vt.RenderedScreen,
    ) !void {
        try self.setActiveScreen(screen.active_screen);
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

    fn setActiveScreen(self: *PresentationState, active_screen: u8) !void {
        if (active_screen > 1) return error.InvalidActiveScreen;
        if (self.active_screen == active_screen) return;

        self.active_screen = active_screen;
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
    fn canApplyPlainPassthrough(
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
        if (!isSafePlainPassthrough(bytes)) return false;
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

    // Update our cache after raw output was passed through successfully.
    fn assumePlainPassthroughScreen(self: *PresentationState, session_rows: u16, screen: *const vt.RenderedScreen) !void {
        try self.setActiveScreen(screen.active_screen);
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

const AttachRequest = struct {
    resize: ResizePayload,
    session_ref: []u8,
    client_guid: []u8,
    capture_tty_transcript: bool,

    fn deinit(self: *AttachRequest) void {
        app_allocator.allocator().free(self.client_guid);
        app_allocator.allocator().free(self.session_ref);
        self.* = undefined;
    }
};

const TerminalSizePayload = struct {
    rows: u16,
    cols: u16,
};

const SessionCreateRequest = struct {
    terminal_size: TerminalSizePayload,
    scrollback_row_count: u32,
    environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []u8,
    session_alias: []u8,
    command_argv: [][]u8,

    fn deinit(self: *SessionCreateRequest) void {
        app_allocator.allocator().free(self.session_alias);
        app_allocator.allocator().free(self.session_guid);
        for (self.command_argv) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(self.command_argv);
        self.environment.deinit();
        self.* = undefined;
    }
};

const RepaintRequest = struct {
    repaint_request_seq: u64,
    scrollback_cursor: ?ScrollbackCursor,
    initial_scrollback_rows: ?u32 = null,
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

fn isSafePlainPassthrough(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    // Starting at libghostty-vt ground state plus this byte allowlist preserves
    // ground state: there is no ESC/control introducer and no partial UTF-8.
    // The session agent therefore only needs to record whether the batch started at a
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

test "active-screen change redraw starts at previous rendered top" {
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
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[3A\r"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "PRIMARY") != null);
}

test "relay-end restore moves to rendered top only once" {
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

    try presentation.applyRelayEndRestoreScreen(renderer, 4, &primary_screen);
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[3A\r"));
    try std.testing.expect(!std.mem.startsWith(u8, bytes.items, "\x1b[3A\r\x1b[3A\r"));
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

/// Run one long-lived agent for exactly one session directory.
///
/// This is the process shape used by the session-agent architecture. It still
/// reuses the session agent's terminal and attachment machinery, but it fixes the
/// session id to the registry directory name and exits after that session ends.
pub fn runSessionAgent(session_dir: []const u8) !void {
    closeInheritedFileDescriptorsForSessionAgent();
    socket_transport.publishRuntimeRootSymlinkOnce(app_allocator.allocator());

    const paths = try session_registry.pathsForSessionDir(app_allocator.allocator(), session_dir);
    const shutdown_pipe = try posix.pipe();
    defer {
        posix.close(shutdown_pipe[0]);
        posix.close(shutdown_pipe[1]);
    }
    installShutdownSignalHandler(shutdown_pipe[1]);
    defer uninstallShutdownSignalHandler();

    const fixed_session_id = std.fs.path.basename(paths.dir);
    var session_agent = SessionAgent{
        .fixed_session_id = fixed_session_id,
        .session_paths = paths,
    };
    defer if (session_agent.session_paths) |*session_paths| session_paths.deinit(app_allocator.allocator());

    var listen_fd = try socket_transport.listenSocket(session_agent.session_paths.?.socket);
    defer _ = c.close(listen_fd);
    defer session_registry.removeEndedHints(session_agent.session_paths.?) catch {};

    const runtime_repair_pipe = try posix.pipe();
    defer {
        posix.close(runtime_repair_pipe[0]);
        posix.close(runtime_repair_pipe[1]);
    }

    try writeAgentCompatBinary(session_agent.session_paths.?);
    try session_registry.writeMeta(session_agent.session_paths.?, c.getpid(), config.version);
    try openSessionAgentLog(&session_agent, session_agent.session_paths.?);
    defer closeSessionAgentLog(&session_agent);
    logSessionAgent(&session_agent, "event=session_agent_start id={s} socket={s}", .{ fixed_session_id, session_agent.session_paths.?.socket });
    var refresher = runtime_refresher.RuntimeRefresher{};
    refresher.startWithRepairSignal(app_allocator.allocator(), session_agent.session_paths.?, runtimeRefreshIntervalMs(), runtime_repair_pipe[1]) catch |err| {
        logSessionAgent(&session_agent, "event=runtime_refresher_start_failed error={t}", .{err});
    };
    defer refresher.stopAndJoin(app_allocator.allocator());
    defer logSessionAgent(&session_agent, "event=session_agent_stop id={s}", .{fixed_session_id});
    defer closeSessionAgent(&session_agent);

    while (session_agent.running) {
        try sessionAgentPollOnce(&session_agent, &listen_fd, shutdown_pipe[0], runtime_repair_pipe[0]);
        reapSessions(&session_agent);
        stopSessionAgentIfComplete(&session_agent);
    }
}

fn runtimeRefreshIntervalMs() u64 {
    const value_z = c.getenv("SESSH_TEST_RUNTIME_REFRESH_MS") orelse return runtime_refresher.default_refresh_interval_ms;
    const value = std.mem.span(value_z);
    if (value.len == 0) return runtime_refresher.default_refresh_interval_ms;
    const parsed = std.fmt.parseInt(u64, value, 10) catch return runtime_refresher.default_refresh_interval_ms;
    if (parsed == 0) return runtime_refresher.default_refresh_interval_ms;
    return parsed;
}

fn closeInheritedFileDescriptorsForSessionAgent() void {
    // The broker runs behind ssh stdio and may inherit bootstrapper helper fds
    // such as fd 3 pointing at protocol stdout. A session agent must not keep
    // those pipes open after the broker exits, or transport EOF will be hidden
    // from the local client.
    const limit = inheritedFdCloseLimit();
    var fd: c.fd_t = 3;
    while (fd < limit) : (fd += 1) {
        _ = c.close(fd);
    }
}

fn inheritedFdCloseLimit() c.fd_t {
    const fallback: c.fd_t = 1024;
    const max_reasonable: u64 = 65_536;
    const limits = posix.getrlimit(.NOFILE) catch return fallback;
    if (limits.cur <= 3) return 3;
    const capped = @min(limits.cur, max_reasonable);
    return @intCast(capped);
}

fn installShutdownSignalHandler(write_fd: c.fd_t) void {
    shutdown_signal_write_fd = write_fd;
    const action = posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &action, null);
}

fn uninstallShutdownSignalHandler() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = null },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &action, null);
    shutdown_signal_write_fd = -1;
}

fn writeAgentCompatBinary(paths: session_registry.SessionPaths) !void {
    try writeCompatBinaryTo(paths.compat);
}

fn writeCompatBinaryTo(compat_path: []const u8) !void {
    const allocator = app_allocator.allocator();
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const hash_hex = try sha256FileHex(exe_path);
    const artifact_path = try socket_transport.cachedArtifactPath(allocator, config.version, &hash_hex);
    defer allocator.free(artifact_path);
    try ensureContentArtifact(exe_path, artifact_path, &hash_hex);

    const compat_dir = std.fs.path.dirname(compat_path) orelse return error.InvalidCompatPath;
    try std.fs.cwd().makePath(compat_dir);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ compat_path, c.getpid() });
    defer allocator.free(tmp_path);
    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try posix.symlink(artifact_path, tmp_path);
    try std.fs.renameAbsolute(tmp_path, compat_path);
}

fn ensureContentArtifact(exe_path: []const u8, artifact_path: []const u8, expected_hash_hex: []const u8) !void {
    if (sha256FileHex(artifact_path)) |actual_hash| {
        if (std.mem.eql(u8, &actual_hash, expected_hash_hex)) {
            try chmodPath(artifact_path, 0o700);
            return;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const artifact_dir = std.fs.path.dirname(artifact_path) orelse return error.InvalidArtifactPath;
    try std.fs.cwd().makePath(artifact_dir);

    const allocator = app_allocator.allocator();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ artifact_path, c.getpid() });
    defer allocator.free(tmp_path);
    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.fs.copyFileAbsolute(exe_path, tmp_path, .{ .override_mode = 0o700 });
    const copied_hash = try sha256FileHex(tmp_path);
    if (!std.mem.eql(u8, &copied_hash, expected_hash_hex)) return error.ArtifactHashMismatch;
    try std.fs.renameAbsolute(tmp_path, artifact_path);
}

fn sha256FileHex(path: []const u8) ![64]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn chmodPath(path: []const u8, mode: c.mode_t) !void {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);
    switch (posix.errno(c.chmod(path_z.ptr, mode))) {
        .SUCCESS => return,
        else => return error.ChmodFailed,
    }
}

fn sessionAgentPollOnce(session_agent: *SessionAgent, listen_fd: *c.fd_t, shutdown_signal_fd: c.fd_t, runtime_repair_fd: c.fd_t) !void {
    const now_ms = sessionAgentMonotonicMs(session_agent);
    clearExpiredDebugUnresponsiveAttachments(session_agent, now_ms);

    var pollfds: [3 + max_sessions + max_attachments]posix.pollfd = undefined;
    var kinds: [3 + max_sessions + max_attachments]PollKind = undefined;
    var count: usize = 0;

    pollfds[count] = .{ .fd = shutdown_signal_fd, .events = posix.POLL.IN, .revents = 0 };
    kinds[count] = .shutdown_signal;
    count += 1;

    pollfds[count] = .{ .fd = runtime_repair_fd, .events = posix.POLL.IN, .revents = 0 };
    kinds[count] = .runtime_repair;
    count += 1;

    if (!session_agent.shutting_down) {
        pollfds[count] = .{ .fd = listen_fd.*, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .listen;
        count += 1;
    }

    for (&session_agent.sessions, 0..) |*session, i| {
        if (!session.alive) continue;
        pollfds[count] = .{ .fd = session.pty_fd, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .{ .session = i };
        count += 1;
    }

    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!attachment.active) continue;
        const debug_unresponsive = attachment.debug_unresponsive_until_ms > now_ms;
        var events: i16 = if (attachment.close_after_flush or debug_unresponsive) 0 else posix.POLL.IN;
        if (!debug_unresponsive and attachment.queuedBytes() > 0) events |= posix.POLL.OUT;
        pollfds[count] = .{ .fd = attachment.fd, .events = events, .revents = 0 };
        kinds[count] = .{ .attachment = i };
        count += 1;
    }

    _ = try posix.poll(pollfds[0..count], sessionAgentPollTimeoutMs(session_agent, now_ms));
    const after_poll_ms = sessionAgentMonotonicMs(session_agent);
    clearExpiredDebugUnresponsiveAttachments(session_agent, after_poll_ms);
    flushExpiredSynchronizedOutputSessions(session_agent, after_poll_ms);

    for (pollfds[0..count], kinds[0..count]) |pollfd, kind| {
        if (pollfd.revents == 0) continue;
        switch (kind) {
            .listen => acceptSessionAgentClient(session_agent, listen_fd.*),
            .shutdown_signal => handleShutdownSignalEvent(session_agent, shutdown_signal_fd),
            .runtime_repair => handleRuntimeRepairEvent(session_agent, listen_fd, runtime_repair_fd),
            .session => |session_index| drainSessionOutput(session_agent, session_index),
            .attachment => |attachment_index| handleAttachmentEvents(session_agent, attachment_index, pollfd.revents),
        }
    }
}

fn sessionAgentMonotonicMs(session_agent: *SessionAgent) i64 {
    if (session_agent.monotonic_clock == null) {
        session_agent.monotonic_clock = std.time.Timer.start() catch return std.time.milliTimestamp();
    }
    return if (session_agent.monotonic_clock) |*timer|
        @intCast(timer.read() / std.time.ns_per_ms)
    else
        std.time.milliTimestamp();
}

fn clearExpiredDebugUnresponsiveAttachments(session_agent: *SessionAgent, now_ms: i64) void {
    for (&session_agent.attachments) |*attachment| {
        if (!attachment.active) continue;
        if (attachment.debug_unresponsive_until_ms != 0 and attachment.debug_unresponsive_until_ms <= now_ms) {
            attachment.debug_unresponsive_until_ms = 0;
        }
    }
}

fn sessionAgentPollTimeoutMs(session_agent: *const SessionAgent, now_ms: i64) i32 {
    var timeout_ms: ?i64 = null;
    for (&session_agent.attachments) |*attachment| {
        if (!attachment.active or attachment.debug_unresponsive_until_ms <= now_ms) continue;
        const remaining_ms = attachment.debug_unresponsive_until_ms - now_ms;
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    for (&session_agent.sessions) |*session| {
        if (!session.alive or session.synchronized_output_since_ms == 0) continue;
        const elapsed_ms = now_ms - session.synchronized_output_since_ms;
        const remaining_ms = synchronized_output_max_hold_ms - elapsed_ms;
        const clamped_remaining_ms = @max(remaining_ms, 0);
        if (timeout_ms == null or clamped_remaining_ms < timeout_ms.?) timeout_ms = clamped_remaining_ms;
    }
    const ms = timeout_ms orelse return -1;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

fn flushExpiredSynchronizedOutputSessions(session_agent: *SessionAgent, now_ms: i64) void {
    for (&session_agent.sessions, 0..) |*session, session_index| {
        if (!session.alive or session.synchronized_output_since_ms == 0) continue;
        if (now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms) continue;
        broadcastSessionPatch(session_agent, session_index);
        if (session.alive) {
            session.clearPendingPlainOutput();
            session.synchronized_output_since_ms = now_ms;
        }
    }
}

fn handleRuntimeRepairEvent(session_agent: *SessionAgent, listen_fd: *c.fd_t, runtime_repair_fd: c.fd_t) void {
    drainSignalPipe(runtime_repair_fd);
    repairSessionAgentRuntime(session_agent, listen_fd) catch |err| {
        logSessionAgent(session_agent, "event=runtime_repair_failed error={t}", .{err});
    };
}

fn drainSignalPipe(fd: c.fd_t) void {
    var buf: [64]u8 = undefined;
    _ = c.read(fd, &buf, buf.len);
}

fn repairSessionAgentRuntime(session_agent: *SessionAgent, listen_fd: *c.fd_t) !void {
    const paths = session_agent.session_paths orelse return;
    const socket_was_missing = !try socketPathIsSocket(paths.socket);

    try session_registry.ensureRuntimeLayout(app_allocator.allocator(), paths);
    try writeAgentCompatBinary(paths);
    try session_registry.writeMeta(paths, c.getpid(), config.version);

    if (socket_was_missing or !try socketPathIsSocket(paths.socket)) {
        const new_listen_fd = try socket_transport.listenSocket(paths.socket);
        const old_listen_fd = listen_fd.*;
        listen_fd.* = new_listen_fd;
        _ = c.close(old_listen_fd);
        logSessionAgent(session_agent, "event=runtime_socket_rebound socket={s}", .{paths.socket});
    }
}

fn socketPathIsSocket(path: []const u8) !bool {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);
    var stat: c.Stat = undefined;
    switch (posix.errno(c.fstatat(c.AT.FDCWD, path_z.ptr, &stat, c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => return c.S.ISSOCK(stat.mode),
        .NOENT, .NOTDIR => return false,
        else => return error.SocketStatFailed,
    }
}

fn handleShutdownSignalEvent(session_agent: *SessionAgent, shutdown_signal_fd: c.fd_t) void {
    var buf: [32]u8 = undefined;
    _ = c.read(shutdown_signal_fd, &buf, buf.len);
    requestGracefulShutdown(session_agent);
}

fn handleAttachmentEvents(session_agent: *SessionAgent, attachment_index: usize, revents: i16) void {
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        detachAttachment(session_agent, attachment_index);
        return;
    }
    if ((revents & posix.POLL.OUT) != 0) {
        flushAttachmentOutput(session_agent, attachment_index);
    }
    if (attachment_index >= session_agent.attachments.len or !session_agent.attachments[attachment_index].active) return;
    if (session_agent.attachments[attachment_index].close_after_flush) return;
    if ((revents & posix.POLL.IN) != 0) {
        drainAttachmentInput(session_agent, attachment_index);
    }
}

fn acceptSessionAgentClient(session_agent: *SessionAgent, listen_fd: c.fd_t) void {
    const client_fd = c.accept(listen_fd, null, null);
    if (client_fd < 0) return;
    socket_transport.setCloseOnExec(client_fd) catch {
        _ = c.close(client_fd);
        return;
    };

    const keep_open = handleSessionAgentClient(session_agent, client_fd) catch |err| blk: {
        logSessionAgent(session_agent, "event=client_error error={t}", .{err});
        io.stderrPrint("sessh session agent: client error: {t}\n", .{err}) catch {};
        break :blk false;
    };
    if (!keep_open) _ = c.close(client_fd);
}

fn handleSessionAgentClient(session_agent: *SessionAgent, fd: c.fd_t) !bool {
    const handshake_result = try acceptRemoteHandshake(session_agent, fd);
    if (handshake_result == .mismatch) return false;

    while (true) {
        var frame = protocol.readFrameAlloc(app_allocator.allocator(), fd) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .resize => continue,
            .session_create => {
                var request = readSessionCreateRequest(frame.payload) catch {
                    try sendError(session_agent, fd, "PROTOCOL_ERROR", "invalid SESSION_CREATE payload", "");
                    return false;
                };
                defer request.deinit();
                const alias = registerSessionAlias(request.session_guid, request.session_alias) catch |err| switch (err) {
                    error.AliasExists => {
                        try sendError(session_agent, fd, "ALIAS_EXISTS", "session alias already exists", "");
                        return false;
                    },
                    error.InvalidAlias => {
                        try sendError(session_agent, fd, "INVALID_ALIAS", "invalid session alias", "");
                        return false;
                    },
                    else => return err,
                };
                defer app_allocator.allocator().free(alias);
                const session_index = createSession(
                    session_agent,
                    request.terminal_size.rows,
                    request.terminal_size.cols,
                    request.scrollback_row_count,
                    request.environment,
                    request.query_default_colors,
                    request.session_guid,
                    request.command_argv,
                ) catch |err| {
                    session_registry.removeAlias(app_allocator.allocator(), alias) catch {};
                    return err;
                };
                const session = &session_agent.sessions[session_index];
                if (session_agent.session_paths) |paths| {
                    try session_registry.writeLocalRoute(app_allocator.allocator(), session.idSlice(), alias, paths.dir, config.version);
                    session.detached_at_unix_ms = nowUnixMs();
                }
                try sendSessionCreatedForSession(session_agent, fd, session, alias);
                continue;
            },
            .session_live_state_query => {
                try sendSessionLiveState(session_agent, fd);
                return false;
            },
            .session_client_detach_request => {
                try handleSessionClientDetachRequest(session_agent, fd, frame.payload);
                return false;
            },
            .session_client_repaint_request => {
                try handleSessionClientRepaintRequest(session_agent, fd, frame.payload);
                return false;
            },
            .session_client_debug_sever_connection_request => {
                try handleSessionClientDebugSeverConnectionRequest(session_agent, fd, frame.payload);
                return false;
            },
            .session_client_debug_unresponsive_connection_request => {
                try handleSessionClientDebugUnresponsiveConnectionRequest(session_agent, fd, frame.payload);
                return false;
            },
            .session_attach => {
                var request = try readAttachRequest(frame.payload);
                defer request.deinit();
                const session_index = if (request.session_ref.len > 0)
                    try findSessionIndexForRef(session_agent, request.session_ref)
                else
                    findMostRecentSessionIndex(session_agent);
                const resolved_session_index = session_index orelse {
                    try sendError(session_agent, fd, "SESSION_NOT_FOUND", "session not found", "");
                    return false;
                };
                updateSessionSize(&session_agent.sessions[resolved_session_index], request.resize.rows, request.resize.cols);
                try attachSession(session_agent, resolved_session_index, fd, request.resize, request.client_guid, request.capture_tty_transcript);
                return true;
            },
            else => {
                try sendError(session_agent, fd, "PROTOCOL_ERROR", "unexpected first action", "");
                return false;
            },
        }
    }
}

fn requestGracefulShutdown(session_agent: *SessionAgent) void {
    if (session_agent.shutting_down) return;
    session_agent.shutting_down = true;
    logSessionAgent(session_agent, "event=session_agent_shutdown_requested", .{});
    for (0..session_agent.sessions.len) |i| {
        if (session_agent.sessions[i].alive) endSession(session_agent, i, 1, .{ .ended_at_unix_ms = nowUnixMs() });
    }
}

fn openSessionAgentLog(session_agent: *SessionAgent, paths: session_registry.SessionPaths) !void {
    const log_path = try sessionAgentLogPath(app_allocator.allocator(), paths);
    defer app_allocator.allocator().free(log_path);
    const log_dir = std.fs.path.dirname(log_path) orelse return error.InvalidLogPath;
    try std.fs.cwd().makePath(log_dir);
    session_agent.log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true, .mode = 0o600 });
}

fn sessionAgentLogPath(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) ![]u8 {
    const state_session_dir = std.fs.path.dirname(paths.route) orelse return error.InvalidRoutePath;
    return std.fmt.allocPrint(allocator, "{s}/agent.log", .{state_session_dir});
}

fn closeSessionAgentLog(session_agent: *SessionAgent) void {
    if (session_agent.log_file) |*file| {
        file.close();
        session_agent.log_file = null;
    }
}

fn logSessionAgent(session_agent: *SessionAgent, comptime fmt: []const u8, args: anytype) void {
    if (session_agent.log_file) |*file| {
        var body_buf: [384]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, fmt, args) catch return;
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "ts_ms={} {s}\n", .{ nowUnixMs(), body }) catch return;
        file.writeAll(line) catch {};
    }
}

fn acceptRemoteHandshake(session_agent: *SessionAgent, fd: c.fd_t) !HandshakeResult {
    var peer_hello = try readHelloRequest(fd);
    defer peer_hello.deinit(app_allocator.allocator());
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
        return .mismatch;
    }
    try sendHelloOk(fd);
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(fd);
    defer if (hello_error) |*err| err.deinit(app_allocator.allocator());
    if (hello_error) |err| {
        logSessionAgent(session_agent, "event=handshake_rejected code={s} message={s}", .{
            err.code,
            err.message,
        });
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

fn sendError(session_agent: *SessionAgent, fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    logSessionAgent(session_agent, "event=error code={s} message={s}", .{ code, message });
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

fn queueAttachmentError(session_agent: *SessionAgent, attachment: *Attachment, code: []const u8, message: []const u8, hint: []const u8) !void {
    logSessionAgent(session_agent, "event=error code={s} message={s}", .{ code, message });
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .error_message, payload);
}

fn queueAttachmentFrame(attachment: *Attachment, message_type: protocol.MessageType, payload: []const u8) !void {
    const frame = try protocol.encodeFrame(app_allocator.allocator(), message_type, payload);
    defer app_allocator.allocator().free(frame);
    const frame_len = frame.len;
    if (frame_len > max_attachment_output_queue_bytes or
        attachment.queuedBytes() > max_attachment_output_queue_bytes - frame_len)
    {
        return error.AttachmentOutputQueueFull;
    }

    compactAttachmentOutput(attachment);
    try attachment.output.appendSlice(app_allocator.allocator(), frame);
}

fn compactAttachmentOutput(attachment: *Attachment) void {
    if (attachment.output_offset == 0) return;
    if (attachment.output_offset >= attachment.output.items.len) {
        attachment.output.clearRetainingCapacity();
        attachment.output_offset = 0;
        return;
    }

    const remaining = attachment.output.items.len - attachment.output_offset;
    std.mem.copyForwards(
        u8,
        attachment.output.items[0..remaining],
        attachment.output.items[attachment.output_offset..],
    );
    attachment.output.shrinkRetainingCapacity(remaining);
    attachment.output_offset = 0;
}

fn flushAttachmentOutput(session_agent: *SessionAgent, attachment_index: usize) void {
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active) return;
    if (attachment.debug_unresponsive_until_ms != 0) {
        const now_ms = sessionAgentMonotonicMs(session_agent);
        if (attachment.debug_unresponsive_until_ms > now_ms) return;
        attachment.debug_unresponsive_until_ms = 0;
    }

    while (attachment.output_offset < attachment.output.items.len) {
        const result = io.writeSomeNonBlocking(attachment.fd, attachment.output.items[attachment.output_offset..]) catch {
            detachAttachment(session_agent, attachment_index);
            return;
        };
        switch (result) {
            .wrote => |n| {
                if (n == 0) break;
                attachment.output_offset += n;
            },
            .would_block => return,
        }
    }

    if (attachment.output_offset >= attachment.output.items.len) {
        attachment.output.clearRetainingCapacity();
        attachment.output_offset = 0;
        if (attachment.close_after_flush) {
            detachAttachment(session_agent, attachment_index);
        }
    }
}

fn attachedCount(session_agent: *SessionAgent, session_index: usize) u32 {
    var count: u32 = 0;
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active and attachment.session_index == session_index and !attachment.close_after_flush) count += 1;
    }
    return count;
}

fn sendSessionAttachedForSession(session_agent: *const SessionAgent, attachment: *Attachment, session: *const Session) !void {
    const maybe_alias = try session_registry.primaryAliasForGuid(app_allocator.allocator(), session.idSlice());
    defer if (maybe_alias) |alias| app_allocator.allocator().free(alias);
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.SessionAttached{
        .session_guid = session.idSlice(),
        .session_alias = maybe_alias orelse "",
        .session_dir = sessionDirSlice(session_agent),
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .session_attached, payload);
}

fn sendSessionCreatedForSession(session_agent: *const SessionAgent, fd: c.fd_t, session: *const Session, alias: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.SessionCreated{
        .session_guid = session.idSlice(),
        .session_alias = alias,
        .session_dir = sessionDirSlice(session_agent),
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .session_created, payload);
}

fn sendSessionLiveState(session_agent: *SessionAgent, fd: c.fd_t) !void {
    const session_index = findMostRecentSessionIndex(session_agent) orelse {
        try sendError(session_agent, fd, "SESSION_NOT_FOUND", "session not found", "");
        return;
    };
    const session = &session_agent.sessions[session_index];
    var response = pb.SessionLiveState{};
    defer response.attached_clients.deinit(app_allocator.allocator());

    if (session.detached_at_unix_ms != 0) response.detached_at_unix_ms = session.detached_at_unix_ms;
    if (session.last_input_at_unix_ms != 0) response.last_input_at_unix_ms = session.last_input_at_unix_ms;
    for (&session_agent.attachments) |*attachment| {
        if (!attachment.active or attachment.close_after_flush or attachment.session_index != session_index) continue;
        try response.attached_clients.append(app_allocator.allocator(), .{
            .client_guid = attachment.clientGuidSlice(),
            .terminal_size = .{
                .terminal_rows = attachment.rows,
                .terminal_cols = attachment.cols,
            },
            .attached_at_unix_ms = attachment.attached_at_unix_ms,
            .last_input_at_unix_ms = if (attachment.last_input_at_unix_ms == 0) null else attachment.last_input_at_unix_ms,
        });
    }

    const payload = try protocol.encodePayload(app_allocator.allocator(), response);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .session_live_state, payload);
}

const CapturedClientControlGuids = struct {
    bufs: [max_attachments][session_registry.client_guid_len]u8 = undefined,
    lens: [max_attachments]usize = undefined,
    count: usize = 0,
};

fn handleSessionClientDetachRequest(session_agent: *SessionAgent, fd: c.fd_t, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.SessionClientDetachRequest, app_allocator.allocator(), payload);
    defer request.deinit(app_allocator.allocator());
    var selected: [max_attachments]usize = undefined;
    const selected_count = (try resolveClientControlTargetsOrSend(session_agent, fd, request.target, &selected)) orelse return;
    const captured = captureSelectedClientControlGuids(session_agent, selected[0..selected_count]);

    for (selected[0..selected_count]) |attachment_index| {
        requestClientDetachFromControl(session_agent, attachment_index);
    }
    try sendClientControlResponse(fd, captured);
}

fn handleSessionClientRepaintRequest(session_agent: *SessionAgent, fd: c.fd_t, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.SessionClientRepaintRequest, app_allocator.allocator(), payload);
    defer request.deinit(app_allocator.allocator());
    var selected: [max_attachments]usize = undefined;
    const selected_count = (try resolveClientControlTargetsOrSend(session_agent, fd, request.target, &selected)) orelse return;
    const captured = captureSelectedClientControlGuids(session_agent, selected[0..selected_count]);

    for (selected[0..selected_count]) |attachment_index| {
        requestClientRepaintFromControl(session_agent, attachment_index, request.include_scrollback);
    }
    try sendClientControlResponse(fd, captured);
}

fn handleSessionClientDebugSeverConnectionRequest(session_agent: *SessionAgent, fd: c.fd_t, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.SessionClientDebugSeverConnectionRequest, app_allocator.allocator(), payload);
    defer request.deinit(app_allocator.allocator());
    var selected: [max_attachments]usize = undefined;
    const selected_count = (try resolveClientControlTargetsOrSend(session_agent, fd, request.target, &selected)) orelse return;
    const captured = captureSelectedClientControlGuids(session_agent, selected[0..selected_count]);

    for (selected[0..selected_count]) |attachment_index| {
        detachAttachment(session_agent, attachment_index);
    }
    try sendClientControlResponse(fd, captured);
}

fn handleSessionClientDebugUnresponsiveConnectionRequest(session_agent: *SessionAgent, fd: c.fd_t, payload: []const u8) !void {
    var request = try protocol.decodePayload(pb.SessionClientDebugUnresponsiveConnectionRequest, app_allocator.allocator(), payload);
    defer request.deinit(app_allocator.allocator());
    var selected: [max_attachments]usize = undefined;
    const selected_count = (try resolveClientControlTargetsOrSend(session_agent, fd, request.target, &selected)) orelse return;
    const captured = captureSelectedClientControlGuids(session_agent, selected[0..selected_count]);

    const seconds = if (request.seconds == 0)
        config.default_debug_unresponsive_seconds
    else
        request.seconds;
    const until_ms = sessionAgentMonotonicMs(session_agent) + @as(i64, seconds) * std.time.ms_per_s;
    for (selected[0..selected_count]) |attachment_index| {
        if (attachment_index < session_agent.attachments.len and session_agent.attachments[attachment_index].active) {
            session_agent.attachments[attachment_index].debug_unresponsive_until_ms = until_ms;
        }
    }
    try sendClientControlResponse(fd, captured);
}

fn resolveClientControlTargetsOrSend(
    session_agent: *SessionAgent,
    fd: c.fd_t,
    maybe_target: ?pb.ClientControlTarget,
    selected: *[max_attachments]usize,
) !?usize {
    const session_index = findMostRecentSessionIndex(session_agent) orelse {
        try sendError(session_agent, fd, "SESSION_NOT_FOUND", "session not found", "");
        return null;
    };
    const target = maybe_target orelse {
        try sendError(session_agent, fd, "INVALID_TARGET", "invalid client target", "");
        return null;
    };
    return resolveClientControlTargets(session_agent, session_index, target, selected) catch |err| {
        switch (err) {
            error.NoAttachedClients => try sendError(session_agent, fd, "NO_ATTACHED_CLIENTS", "no attached clients", ""),
            error.MultipleAttachedClients => try sendError(session_agent, fd, "MULTIPLE_ATTACHED_CLIENTS", "multiple clients are attached", "Pass --all, --last-input, or a client GUID"),
            error.NoLastInputClient => try sendError(session_agent, fd, "NO_LAST_INPUT_CLIENT", "no attached client has sent user input", ""),
            error.ClientNotFound => try sendError(session_agent, fd, "CLIENT_NOT_FOUND", "client not found", ""),
            error.AmbiguousClientControlTarget => try sendError(session_agent, fd, "AMBIGUOUS_CLIENT_TARGET", "client target is ambiguous", ""),
            error.InvalidClientControlTarget => try sendError(session_agent, fd, "INVALID_TARGET", "invalid client target", ""),
            else => return err,
        }
        return null;
    };
}

fn captureSelectedClientControlGuids(session_agent: *const SessionAgent, selected: []const usize) CapturedClientControlGuids {
    var captured = CapturedClientControlGuids{ .count = selected.len };
    for (selected, 0..) |attachment_index, i| {
        const client_guid = session_agent.attachments[attachment_index].clientGuidSlice();
        @memcpy(captured.bufs[i][0..client_guid.len], client_guid);
        captured.lens[i] = client_guid.len;
    }
    return captured;
}

fn sendClientControlResponse(fd: c.fd_t, captured: CapturedClientControlGuids) !void {
    var response = pb.SessionClientControlResponse{};
    defer response.affected_client_guid.deinit(app_allocator.allocator());
    for (captured.bufs[0..captured.count], captured.lens[0..captured.count]) |*buf, len| {
        try response.affected_client_guid.append(app_allocator.allocator(), buf[0..len]);
    }
    const response_payload = try protocol.encodePayload(app_allocator.allocator(), response);
    defer app_allocator.allocator().free(response_payload);
    try protocol.sendFrame(fd, .session_client_control_response, response_payload);
}

fn resolveClientControlTargets(
    session_agent: *const SessionAgent,
    session_index: usize,
    target: pb.ClientControlTarget,
    selected: *[max_attachments]usize,
) !usize {
    return switch (target.target_kind) {
        .CLIENT_CONTROL_TARGET_KIND_DEFAULT => resolveDefaultClientTarget(session_agent, session_index, selected),
        .CLIENT_CONTROL_TARGET_KIND_ALL => resolveAllClientTargets(session_agent, session_index, selected),
        .CLIENT_CONTROL_TARGET_KIND_LAST_INPUT => resolveLastInputClientTarget(session_agent, session_index, selected),
        .CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID => resolveClientGuidTarget(session_agent, session_index, target.client_guid, selected),
        else => error.InvalidClientControlTarget,
    };
}

fn controlTargetActive(attachment: *const Attachment, session_index: usize) bool {
    return attachment.active and attachment.session_index == session_index and !attachment.close_after_flush;
}

fn resolveDefaultClientTarget(
    session_agent: *const SessionAgent,
    session_index: usize,
    selected: *[max_attachments]usize,
) !usize {
    var found: ?usize = null;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!controlTargetActive(attachment, session_index)) continue;
        if (found != null) return error.MultipleAttachedClients;
        found = i;
    }
    selected[0] = found orelse return error.NoAttachedClients;
    return 1;
}

fn resolveAllClientTargets(
    session_agent: *const SessionAgent,
    session_index: usize,
    selected: *[max_attachments]usize,
) !usize {
    var count: usize = 0;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!controlTargetActive(attachment, session_index)) continue;
        selected[count] = i;
        count += 1;
    }
    if (count == 0) return error.NoAttachedClients;
    return count;
}

fn resolveLastInputClientTarget(
    session_agent: *const SessionAgent,
    session_index: usize,
    selected: *[max_attachments]usize,
) !usize {
    var found: ?usize = null;
    var found_ts: u64 = 0;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!controlTargetActive(attachment, session_index)) continue;
        if (attachment.last_input_at_unix_ms == 0) continue;
        if (found == null or attachment.last_input_at_unix_ms >= found_ts) {
            found = i;
            found_ts = attachment.last_input_at_unix_ms;
        }
    }
    selected[0] = found orelse return error.NoLastInputClient;
    return 1;
}

fn resolveClientGuidTarget(
    session_agent: *const SessionAgent,
    session_index: usize,
    client_guid: []const u8,
    selected: *[max_attachments]usize,
) !usize {
    if (!session_registry.isValidClientGuid(client_guid) and
        !session_registry.isValidClientGuidPrefix(client_guid)) return error.InvalidClientControlTarget;
    const prefix = if (session_registry.isValidClientGuidPrefix(client_guid))
        client_guid
    else
        null;
    var found: ?usize = null;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!controlTargetActive(attachment, session_index)) continue;
        const matches = if (prefix) |value|
            clientGuidMatchesPrefix(attachment.clientGuidSlice(), value)
        else
            std.mem.eql(u8, attachment.clientGuidSlice(), client_guid);
        if (!matches) continue;
        if (found != null) return error.AmbiguousClientControlTarget;
        found = i;
    }
    selected[0] = found orelse return error.ClientNotFound;
    return 1;
}

fn clientGuidMatchesPrefix(client_guid: []const u8, prefix: []const u8) bool {
    var prefix_buf: [session_registry.compact_guid_len]u8 = undefined;
    const prefix_len = compactClientGuidPrefix(prefix, &prefix_buf) orelse return false;
    var compact_buf: [session_registry.compact_guid_len]u8 = undefined;
    var dst: usize = 0;
    for (client_guid[session_registry.client_guid_prefix.len..]) |byte| {
        if (byte == '-') continue;
        compact_buf[dst] = std.ascii.toLower(byte);
        dst += 1;
    }
    return std.mem.startsWith(u8, compact_buf[0..dst], prefix_buf[0..prefix_len]);
}

fn compactClientGuidPrefix(prefix: []const u8, out: *[session_registry.compact_guid_len]u8) ?usize {
    if (!std.mem.startsWith(u8, prefix, session_registry.client_guid_prefix)) return null;
    const body = prefix[session_registry.client_guid_prefix.len..];
    if (body.len == 0) return null;
    if (body.len <= session_registry.compact_guid_len) {
        var len: usize = 0;
        for (body) |byte| {
            if (!std.ascii.isHex(byte)) {
                len = 0;
                break;
            }
            out[len] = std.ascii.toLower(byte);
            len += 1;
        }
        if (len == body.len) return len;
    }

    if (body.len >= session_registry.guid_body_len) return null;
    var len: usize = 0;
    for (body, 0..) |byte, i| {
        switch (i) {
            8, 13, 18, 23 => {
                if (byte != '-') return null;
            },
            else => {
                if (!std.ascii.isHex(byte)) return null;
                out[len] = std.ascii.toLower(byte);
                len += 1;
            },
        }
    }
    if (len == 0) return null;
    return len;
}

fn requestClientDetachFromControl(session_agent: *SessionAgent, attachment_index: usize) void {
    if (attachment_index >= session_agent.attachments.len) return;
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active or attachment.close_after_flush) return;
    const payload = protocol.encodePayload(app_allocator.allocator(), pb.ClientDetachRequest{}) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer app_allocator.allocator().free(payload);
    queueAttachmentFrame(attachment, .client_detach_request, payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    flushAttachmentOutput(session_agent, attachment_index);
}

fn requestClientRepaintFromControl(session_agent: *SessionAgent, attachment_index: usize, include_scrollback: bool) void {
    if (attachment_index >= session_agent.attachments.len) return;
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active or attachment.close_after_flush) return;
    const payload = protocol.encodePayload(app_allocator.allocator(), pb.ClientRepaintRequest{
        .include_scrollback = include_scrollback,
    }) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer app_allocator.allocator().free(payload);
    queueAttachmentFrame(attachment, .client_repaint_request, payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    flushAttachmentOutput(session_agent, attachment_index);
}

fn sessionDirSlice(session_agent: *const SessionAgent) []const u8 {
    return if (session_agent.session_paths) |paths| paths.dir else "";
}

fn sendSessionEnded(attachment: *Attachment, reason: u8, exit_info: ExitInfo) !void {
    const exit_status: ?pb.ExitStatus = switch (exit_info.kind) {
        1 => .{ .kind = .EXIT_STATUS_KIND_EXITED, .status = exit_info.status },
        2 => .{ .kind = .EXIT_STATUS_KIND_SIGNALLED, .status = exit_info.status },
        else => null,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.SessionEnded{
        .reason = switch (reason) {
            1 => .SESSION_END_REASON_KILLED_BY_REQUEST,
            2 => .SESSION_END_REASON_AGENT_SHUTDOWN,
            else => .SESSION_END_REASON_PROCESS_EXITED,
        },
        .exit_status = exit_status,
        .ended_at_unix_ms = if (exit_info.ended_at_unix_ms == 0) null else exit_info.ended_at_unix_ms,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .session_ended, payload);
}

fn queueTtyTranscriptChunk(
    attachment: *Attachment,
    stream: pb.TtyTranscriptStream,
    bytes: []const u8,
) !void {
    if (!attachment.capture_tty_transcript or bytes.len == 0) return;
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TtyTranscriptChunk{
        .stream = stream,
        .data = bytes,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .tty_transcript_chunk, payload);
}

fn queueTtyTranscriptChunkForSession(
    session_agent: *SessionAgent,
    session_index: usize,
    stream: pb.TtyTranscriptStream,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!attachment.active or attachment.session_index != session_index) continue;
        if (attachment.close_after_flush or !attachment.capture_tty_transcript) continue;
        queueTtyTranscriptChunk(attachment, stream, bytes) catch {
            detachAttachment(session_agent, i);
        };
    }
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
    attachment: *Attachment,
    session: *const Session,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    relay_end_restore_bytes: ?[]const u8,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, scrollback_cursor);
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Draw{
        .scrollback_cursor = encoded_cursor[0..],
        .viewport_offset = attachment.presentation.protocolViewportOffset(),
        .draw_bytes = draw_bytes,
        .relay_end_restore_bytes = relay_end_restore_bytes,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .draw, payload);
}

fn appendDrawCleanup(draw_bytes: *std.ArrayList(u8)) !void {
    const renderer = client_renderer.Renderer.buffered(draw_bytes, .{ .kind = .xterm_compatible });
    try renderer.restoreBannerPresentation();
}

fn wrapDrawInSynchronizedUpdate(draw_bytes: *std.ArrayList(u8)) !void {
    if (draw_bytes.items.len == 0) return;
    try draw_bytes.insertSlice(app_allocator.allocator(), 0, "\x1b[?2026h");
    try draw_bytes.appendSlice(app_allocator.allocator(), "\x1b[?2026l");
}

fn appendRelayEndRestoreBytes(
    attachment: *const Attachment,
    session: *const Session,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    restore_bytes: *std.ArrayList(u8),
) !?[]const u8 {
    if (restore_screen) |primary| {
        var restore_presentation = attachment.presentation;
        const restore_renderer = client_renderer.Renderer.buffered(restore_bytes, .{ .kind = .xterm_compatible });
        try restore_presentation.applyRelayEndRestoreScreen(restore_renderer, session.rows, primary);
        return restore_bytes.items;
    }
    if (screen.active_screen == 0) return "";
    return null;
}

fn queueScrollbackRowsDraw(
    attachment: *Attachment,
    session: *const Session,
    rows: []const vt.RenderedRow,
    scrollback_cursor: u64,
) !void {
    if (rows.len == 0) return;
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try attachment.presentation.appendScrollbackRows(renderer, session.rows, rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attachment, session, scrollback_cursor, bytes.items, null);
}

fn queueScrollbackRowsAndScreenDraw(
    attachment: *Attachment,
    session: *const Session,
    rows: []const vt.RenderedRow,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    align_viewport: bool,
    scrollback_cursor: u64,
) !void {
    if (rows.len == 0) return;
    if (rows.len > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const passthrough = session.pending_plain_output.items;
    if (try attachment.presentation.canApplyPlainPassthrough(
        screen,
        align_viewport,
        passthrough,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attachment.presentation.assumePlainPassthroughScreen(session.rows, screen);
        try queueDrawFrame(attachment, session, scrollback_cursor, passthrough, null);
        return;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    // Screen clears first copy the old visible rows into scrollback, then draw
    // the cleared screen. After that copy, another alignment pass would only
    // add blank rows to scrollback.
    const align_after_scrollback = align_viewport and screen.display_clear == null;
    var effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, align_after_scrollback);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        effective_align_viewport = false;
    }
    try attachment.presentation.appendScrollbackRows(renderer, session.rows, rows);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        // Full-screen clears must happen after copying the old rows. Clearing
        // first would leave those rows nowhere to go except back on screen.
        try attachment.presentation.clearOuterVisibleForScreen(renderer, screen);
    }
    try attachment.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendRelayEndRestoreBytes(attachment, session, screen, restore_screen, &restore_bytes);
    try queueDrawFrame(attachment, session, scrollback_cursor, bytes.items, restore);
}

fn queueScrollbackTruncatedDraw(
    attachment: *Attachment,
    session: *const Session,
    truncated_rows: u64,
    scrollback_cursor: u64,
) !void {
    if (truncated_rows == 0) return;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attachment, session, scrollback_cursor, bytes.items, null);
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

fn updateMouseOriginAfterDraw(attachment: *Attachment, screen: *const vt.RenderedScreen) void {
    if (!screenWantsMouseReporting(screen)) {
        attachment.origin = null;
        return;
    }

    if (attachment.presentation.full_height_rendering) {
        attachment.origin = .{ .row = 0, .col = 0 };
    }
}

fn screenWantsMouseReporting(screen: *const vt.RenderedScreen) bool {
    return screen.modes.mouse_tracking != 0;
}

fn shouldAlignViewportForDraw(attachment: *const Attachment, screen: *const vt.RenderedScreen, requested: bool) bool {
    return requested or
        attachment.presentation.viewportOffsetUnknown() or
        (screenWantsMouseReporting(screen) and !attachment.presentation.full_height_rendering);
}

fn shouldClearOuterVisibleForDisplayClear(screen: *const vt.RenderedScreen) bool {
    const clear = screen.display_clear orelse return false;
    return clear.mode == .complete;
}

fn queueScreenDraw(
    attachment: *Attachment,
    session: *const Session,
    screen: *const vt.RenderedScreen,
    restore_screen: ?*const vt.RenderedScreen,
    force_redraw: bool,
    align_viewport: bool,
    scrollback_cursor: u64,
) !bool {
    const passthrough = session.pending_plain_output.items;
    if (try attachment.presentation.canApplyPlainPassthrough(
        screen,
        align_viewport,
        passthrough,
        session.pendingPlainOutputCanReplay(),
    )) {
        try attachment.presentation.assumePlainPassthroughScreen(session.rows, screen);
        try queueDrawFrame(attachment, session, scrollback_cursor, passthrough, null);
        return true;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    var effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, align_viewport);
    if (shouldClearOuterVisibleForDisplayClear(screen)) {
        try attachment.presentation.clearOuterVisibleForScreen(renderer, screen);
        effective_align_viewport = false;
    }
    try attachment.presentation.applyScreen(renderer, session.rows, screen, force_redraw, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    if (bytes.items.len > 0) {
        try appendDrawCleanup(&bytes);
        try wrapDrawInSynchronizedUpdate(&bytes);
        var restore_bytes = std.ArrayList(u8).empty;
        defer restore_bytes.deinit(app_allocator.allocator());
        const restore = try appendRelayEndRestoreBytes(attachment, session, screen, restore_screen, &restore_bytes);
        try queueDrawFrame(attachment, session, scrollback_cursor, bytes.items, restore);
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

fn queueRetainedScrollbackClearDraw(attachment: *Attachment, session: *Session) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.buffered(&bytes, .{ .kind = .xterm_compatible });
    try renderer.clearScrollback();
    try wrapDrawInSynchronizedUpdate(&bytes);
    try queueDrawFrame(attachment, session, 0, bytes.items, null);
}

fn queueRepaintResponseFrame(
    attachment: *Attachment,
    session: *const Session,
    repaint_request_seq: u64,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    relay_end_restore_bytes: ?[]const u8,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, scrollback_cursor);
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintResponse{
        .repaint_request_seq = repaint_request_seq,
        .draw = .{
            .scrollback_cursor = encoded_cursor[0..],
            .viewport_offset = attachment.presentation.protocolViewportOffset(),
            .draw_bytes = draw_bytes,
            .relay_end_restore_bytes = relay_end_restore_bytes,
        },
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .repaint_response, payload);
}

fn queueRepaintResponseDraw(
    attachment: *Attachment,
    session: *Session,
    repaint_request_seq: u64,
    clear_for_replace: bool,
    clear_visible_for_replace: bool,
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
        try renderer.clearForReplace();
        attachment.presentation.reset();
    } else if (clear_visible_for_replace) {
        // initial-scrollback=N replaces the visible screen, not scrollback.
        // Clear stale viewport cells without sending 3J.
        try renderer.clearVisible();
        attachment.presentation.reset();
    }
    var effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, false);
    if (!clear_for_replace and shouldClearOuterVisibleForDisplayClear(screen)) {
        try attachment.presentation.clearOuterVisibleForScreen(renderer, screen);
        effective_align_viewport = false;
    }
    if (truncated_rows > 0) try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try attachment.presentation.appendScrollbackRows(renderer, session.rows, rows);
    try attachment.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    try appendDrawCleanup(&bytes);
    try wrapDrawInSynchronizedUpdate(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendRelayEndRestoreBytes(attachment, session, screen, restore_screen, &restore_bytes);
    try queueRepaintResponseFrame(attachment, session, repaint_request_seq, scrollback_cursor, bytes.items, restore);
}

fn queueRepaintSnapshot(
    attachment: *Attachment,
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
        if (request.initial_scrollback_rows == null and effective_cursor < scrollback.truncated_rows) {
            truncated_rows_to_report = scrollback.truncated_rows - effective_cursor;
        } else {
            const skip = effective_cursor -| scrollback.truncated_rows;
            if (skip >= @as(u64, @intCast(rows_to_draw.len))) {
                rows_to_draw = rows_to_draw[rows_to_draw.len..];
            } else {
                rows_to_draw = rows_to_draw[@intCast(skip)..];
            }
        }
        if (request.initial_scrollback_rows) |initial_rows| {
            const initial_rows_usize: usize = @intCast(initial_rows);
            if (rows_to_draw.len > initial_rows_usize) {
                rows_to_draw = rows_to_draw[rows_to_draw.len - initial_rows_usize ..];
            }
            truncated_rows_to_report = 0;
        }

        const clear_scrollback_for_stale_clear =
            requested_cursor.epoch != 0 and requested_cursor.epoch < session.last_scrollback_clear_epoch;
        try queueRepaintResponseDraw(
            attachment,
            session,
            request.repaint_request_seq,
            clear_for_replace or clear_scrollback_for_stale_clear,
            request.initial_scrollback_rows != null,
            truncated_rows_to_report,
            rows_to_draw,
            &screen,
            if (primary_screen) |*primary| primary else null,
            scrollback.absolute_count,
        );
    } else {
        const scrollback_cursor = try model.scrollbackCursor();
        try queueRepaintResponseDraw(
            attachment,
            session,
            request.repaint_request_seq,
            clear_for_replace,
            request.initial_scrollback_rows != null,
            0,
            &.{},
            &screen,
            if (primary_screen) |*primary| primary else null,
            scrollback_cursor,
        );
    }

    return screen.rows.len;
}

fn sendSessionSnapshot(attachment: *Attachment, session: *Session) !void {
    if (session.terminal_model) |model| {
        var scrollback = try model.scrollbackSnapshot(app_allocator.allocator());
        defer scrollback.deinit(app_allocator.allocator());
        var screen = try model.renderedScreen(app_allocator.allocator());
        defer screen.deinit(app_allocator.allocator());

        const rows_to_draw = scrollback.rows;
        const truncated_rows_to_report = scrollback.truncated_rows;

        if (truncated_rows_to_report > 0) {
            try queueScrollbackTruncatedDraw(attachment, session, truncated_rows_to_report, truncated_rows_to_report);
        }
        if (rows_to_draw.len > 0) try queueScrollbackRowsDraw(attachment, session, rows_to_draw, scrollback.absolute_count);
        var primary_screen: ?vt.RenderedScreen = null;
        defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
        if (screen.active_screen == 1) {
            primary_screen = try model.renderedPrimaryScreen(app_allocator.allocator());
        }
        _ = try queueScreenDraw(
            attachment,
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

fn sendSessionRepaintSnapshot(attachment: *Attachment, session: *Session, request: RepaintRequest) !void {
    const model = session.terminal_model orelse return;
    const screen_rows = try queueRepaintSnapshot(attachment, session, request, false);
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
    var message = try protocol.decodePayload(pb.SessionCreate, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    const terminal_size = message.terminal_size orelse return error.MissingTerminalSize;
    if (!session_registry.isValidSessionGuid(message.session_guid)) return error.InvalidSessionGuid;
    var environment = SessionEnvironment{};
    errdefer environment.deinit();
    var query_default_colors = vt.DefaultColors{};

    for (message.environment.items) |entry| {
        try applySessionEnvironmentEntry(&environment, entry);
    }
    if (message.query_default_colors) |colors| {
        query_default_colors = try readDefaultColors(colors);
    }
    const command_argv = try app_allocator.allocator().alloc([]u8, message.command_argv.items.len);
    var command_argv_initialized: usize = 0;
    errdefer {
        for (command_argv[0..command_argv_initialized]) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(command_argv);
    }
    for (message.command_argv.items, 0..) |arg, i| {
        if (arg.len == 0) return error.InvalidCommandArgv;
        command_argv[i] = try app_allocator.allocator().dupe(u8, arg);
        command_argv_initialized += 1;
    }

    return .{
        .terminal_size = try terminalSizePayloadFromMessage(terminal_size),
        .scrollback_row_count = message.scrollback_row_limit,
        .environment = environment,
        .query_default_colors = query_default_colors,
        .session_guid = try app_allocator.allocator().dupe(u8, message.session_guid),
        .session_alias = try app_allocator.allocator().dupe(u8, message.session_alias),
        .command_argv = command_argv,
    };
}

fn registerSessionAlias(session_guid: []const u8, requested_alias: []const u8) ![]u8 {
    if (requested_alias.len > 0) {
        try session_registry.ensureAliasForGuid(app_allocator.allocator(), requested_alias, session_guid);
        return try app_allocator.allocator().dupe(u8, requested_alias);
    }
    return session_registry.createDefaultAliasForGuid(app_allocator.allocator(), session_guid);
}

fn applySessionEnvironmentEntry(environment: *SessionEnvironment, entry: pb.EnvironmentEntry) !void {
    if (std.mem.eql(u8, entry.name, "SHELL") and entry.value.len > 0) {
        if (environment.shell) |shell| app_allocator.allocator().free(shell);
        environment.shell = try app_allocator.allocator().dupe(u8, entry.value);
    }
}

fn readDefaultColors(colors: pb.DefaultColors) !vt.DefaultColors {
    return .{
        .foreground_color = try readDefaultColorValue(colors.foreground_color),
        .background_color = try readDefaultColorValue(colors.background_color),
    };
}

fn readResizePayload(payload: []const u8) !ResizePayload {
    var message = try protocol.decodePayload(pb.Resize, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return try resizePayloadFromMessage(message);
}

fn terminalSizePayloadFromMessage(message: pb.TerminalSize) !TerminalSizePayload {
    if (message.terminal_rows > std.math.maxInt(u16) or
        message.terminal_cols > std.math.maxInt(u16))
    {
        return error.IntOutOfRange;
    }
    return .{
        .rows = @intCast(message.terminal_rows),
        .cols = @intCast(message.terminal_cols),
    };
}

fn resizePayloadFromMessage(message: pb.Resize) !ResizePayload {
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

fn readAttachRequest(payload: []const u8) !AttachRequest {
    var message = try protocol.decodePayload(pb.SessionAttach, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    const resize = message.resize orelse return error.MissingResize;
    if (message.session_ref.len > 0 and !session_registry.isValidSessionRef(message.session_ref)) return error.InvalidSessionRef;
    if (!session_registry.isValidClientGuid(message.client_guid)) return error.InvalidClientGuid;
    return .{
        .resize = try resizePayloadFromMessage(resize),
        .session_ref = try app_allocator.allocator().dupe(u8, message.session_ref),
        .client_guid = try app_allocator.allocator().dupe(u8, message.client_guid),
        .capture_tty_transcript = message.capture_tty_transcript,
    };
}

fn readRepaintRequest(payload: []const u8) !RepaintRequest {
    var message = try protocol.decodePayload(pb.RepaintRequest, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return repaintRequestFromMessage(message);
}

fn repaintRequestFromMessage(message: pb.RepaintRequest) !RepaintRequest {
    return .{
        .repaint_request_seq = message.repaint_request_seq,
        .scrollback_cursor = if (message.scrollback_cursor) |cursor|
            try decodeScrollbackCursor(cursor)
        else
            null,
        .initial_scrollback_rows = message.initial_scrollback_rows,
    };
}

fn createSession(
    session_agent: *SessionAgent,
    rows: u16,
    cols: u16,
    scrollback_row_count: u32,
    session_environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []const u8,
    command_argv: []const []const u8,
) !usize {
    if (session_agent.fixed_session_id != null and session_agent.started_session) return error.TooManySessions;

    for (&session_agent.sessions, 0..) |*session, session_index| {
        if (session.alive or hasAttachmentForSession(session_agent, session_index)) continue;

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

        const shell_path = session_environment.shell orelse defaultShellPath();
        const shell_z = try app_allocator.allocator().dupeZ(u8, shell_path);
        defer app_allocator.allocator().free(shell_z);
        const sessh_path_z = try sesshPathForEnvironment(app_allocator.allocator());
        defer app_allocator.allocator().free(sessh_path_z);
        const path_z = try pathWithSesshPathForEnvironment(app_allocator.allocator(), sessh_path_z);
        defer app_allocator.allocator().free(path_z);
        const shell_argv0 = try loginShellArg0(app_allocator.allocator(), shell_path);
        defer app_allocator.allocator().free(shell_argv0);
        var prepared_command: ?PreparedCommand = if (command_argv.len > 0)
            try prepareCommandArgv(app_allocator.allocator(), command_argv)
        else
            null;
        defer if (prepared_command) |*command| command.deinit(app_allocator.allocator());

        var master: c_int = -1;
        var size = c.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        const pid = forkpty(&master, null, null, &size);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            terminal.setSigpipe(posix.SIG.DFL);
            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("SHELL", shell_z.ptr, 1);
            _ = setenv("SESSH_GUID", session_guid_z.ptr, 1);
            _ = setenv("SESSH_PATH", sessh_path_z.ptr, 1);
            _ = setenv("PATH", path_z.ptr, 1);
            if (prepared_command) |command| {
                posix.execvpeZ(command.argv[0].?, command.argv.ptr, @ptrCast(c.environ)) catch {};
            } else {
                const dash_i: [*:0]const u8 = "-i";
                var child_argv = [_:null]?[*:0]const u8{ shell_argv0.ptr, dash_i };
                _ = c.execve(shell_z.ptr, &child_argv, @ptrCast(c.environ));
            }
            std.process.exit(127);
        }

        session.* = Session{
            .pid = pid,
            .pty_fd = master,
            .terminal_model = terminal_model,
            .rows = rows,
            .cols = cols,
            .scrollback_row_count = scrollback_row_count,
            .alive = true,
        };
        @memcpy(session.id[0..session_guid.len], session_guid);
        session.id_len = session_guid.len;
        session_agent.started_session = true;
        if (session_agent.fixed_session_id == null) session_agent.next_id += 1;
        logSessionAgent(session_agent, "event=session_create id={s} pid={} rows={} cols={} scrollback_rows={} shell={s} command_argc={}", .{
            session.idSlice(),
            pid,
            rows,
            cols,
            scrollback_row_count,
            shell_path,
            command_argv.len,
        });
        return session_index;
    }
    return error.TooManySessions;
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
    var owned_args = try allocator.alloc([:0]u8, command_argv.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(owned_args);
    }

    var argv = try allocator.allocSentinel(?[*:0]const u8, command_argv.len, null);
    errdefer allocator.free(argv);

    for (command_argv, 0..) |arg, i| {
        if (arg.len == 0) return error.InvalidCommandArgv;
        owned_args[i] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[i] = owned_args[i].ptr;
    }
    return .{ .argv = argv, .owned_args = owned_args };
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
    session_agent: *SessionAgent,
    session_index: usize,
    client_fd: c.fd_t,
    resize: ResizePayload,
    client_guid: []const u8,
    capture_tty_transcript: bool,
) !void {
    const session = &session_agent.sessions[session_index];
    detachExistingAttachmentWithClientGuid(session_agent, session_index, client_guid);

    for (&session_agent.attachments, 0..) |*attachment, attachment_index| {
        if (attachment.active) continue;
        attachment.* = .{
            .fd = client_fd,
            .session_index = session_index,
            .client_guid_len = client_guid.len,
            .rows = resize.rows,
            .cols = resize.cols,
            .attached_at_unix_ms = nowUnixMs(),
            .active = true,
            .capture_tty_transcript = capture_tty_transcript,
        };
        @memcpy(attachment.client_guid[0..client_guid.len], client_guid);
        attachment.presentation.setViewportOffset(resize.viewport_offset);
        errdefer {
            attachment.output.deinit(app_allocator.allocator());
            attachment.* = Attachment{};
        }
        try sendSessionAttachedForSession(session_agent, attachment, session);
        if (resize.repaint_request) |request| {
            try sendSessionRepaintSnapshot(attachment, session, request);
        } else {
            try sendSessionSnapshot(attachment, session);
        }
        writeClientRouteHintForAttachment(session_agent, session, attachment);
        refreshAttachedFlag(session_agent, session_index);
        logSessionAgent(session_agent, "event=attach id={s} client={s} rows={} cols={} attachments={}", .{
            session.idSlice(),
            client_guid,
            resize.rows,
            resize.cols,
            attachedCount(session_agent, session_index),
        });
        flushAttachmentOutput(session_agent, attachment_index);
        return;
    }

    return error.TooManyAttachments;
}

fn writeClientRouteHintForAttachment(session_agent: *SessionAgent, session: *const Session, attachment: *const Attachment) void {
    session_registry.writeClientRouteHint(app_allocator.allocator(), attachment.clientGuidSlice(), session.idSlice()) catch |err| {
        logSessionAgent(session_agent, "event=client_route_hint_write_failed id={s} client={s} error={t}", .{
            session.idSlice(),
            attachment.clientGuidSlice(),
            err,
        });
    };
}

fn removeClientRouteHintForAttachment(session_agent: *SessionAgent, session: *const Session, attachment: *const Attachment) void {
    session_registry.removeClientRouteHint(app_allocator.allocator(), attachment.clientGuidSlice()) catch |err| {
        logSessionAgent(session_agent, "event=client_route_hint_remove_failed id={s} client={s} error={t}", .{
            session.idSlice(),
            attachment.clientGuidSlice(),
            err,
        });
    };
}

fn detachExistingAttachmentWithClientGuid(session_agent: *SessionAgent, session_index: usize, client_guid: []const u8) void {
    for (&session_agent.attachments, 0..) |*attachment, attachment_index| {
        if (!attachment.active or attachment.session_index != session_index) continue;
        if (!std.mem.eql(u8, attachment.clientGuidSlice(), client_guid)) continue;
        detachAttachment(session_agent, attachment_index);
    }
}

fn updateSynchronizedOutputState(session_agent: *SessionAgent, session_index: usize, now_ms: i64) bool {
    const session = &session_agent.sessions[session_index];
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

fn shouldDeferSynchronizedOutput(session_agent: *SessionAgent, session_index: usize, now_ms: i64) bool {
    const session = &session_agent.sessions[session_index];
    if (!updateSynchronizedOutputState(session_agent, session_index, now_ms)) return false;
    return now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms;
}

fn drainSessionOutput(session_agent: *SessionAgent, session_index: usize) void {
    if (!session_agent.sessions[session_index].alive) return;

    var buf: [4096]u8 = undefined;
    const pty_fd = session_agent.sessions[session_index].pty_fd;
    var read_count: u16 = 0;
    var batch_bytes: usize = 0;
    while (true) {
        const n = c.read(pty_fd, &buf, buf.len);
        if (n <= 0) {
            if (read_count > 0) break;
            endSessionFromPtyClose(session_agent, session_index);
            return;
        }
        read_count += 1;

        const bytes = buf[0..@intCast(n)];
        batch_bytes += bytes.len;
        feedSessionOutputBytes(session_agent, session_index, bytes) catch {
            endSessionFromPtyClose(session_agent, session_index);
            return;
        };

        const model = session_agent.sessions[session_index].terminal_model orelse continue;
        const input_responses = model.pendingInputResponses();
        if (input_responses.len > 0) {
            io.writeAll(pty_fd, input_responses) catch {
                endSessionFromPtyClose(session_agent, session_index);
                return;
            };
            model.clearPendingInputResponses();
        }

        if (batch_bytes >= preferred_live_output_batch_bytes or
            read_count >= max_live_output_reads_per_batch)
        {
            break;
        }

        var next = [_]posix.pollfd{.{
            .fd = pty_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&next, 0) catch 0;
        if (ready == 0 or (next[0].revents & posix.POLL.IN) == 0) break;
    }
    const now_ms = sessionAgentMonotonicMs(session_agent);
    if (shouldDeferSynchronizedOutput(session_agent, session_index, now_ms)) return;
    broadcastSessionPatch(session_agent, session_index);
    if (session_agent.sessions[session_index].alive) {
        session_agent.sessions[session_index].clearPendingPlainOutput();
        if (session_agent.sessions[session_index].synchronized_output_since_ms != 0) {
            session_agent.sessions[session_index].synchronized_output_since_ms = now_ms;
        }
    }
}

fn drainSessionOutputBeforeEnd(session_agent: *SessionAgent, session_index: usize) void {
    if (!session_agent.sessions[session_index].alive) return;

    var buf: [4096]u8 = undefined;
    const pty_fd = session_agent.sessions[session_index].pty_fd;
    var read_any = false;
    while (true) {
        var next = [_]posix.pollfd{.{
            .fd = pty_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&next, 0) catch 0;
        if (ready == 0 or next[0].revents == 0) break;

        const n = c.read(pty_fd, &buf, buf.len);
        if (n <= 0) break;
        read_any = true;
        feedSessionOutputBytes(session_agent, session_index, buf[0..@intCast(n)]) catch break;
    }
    if (read_any) {
        broadcastSessionPatch(session_agent, session_index);
        session_agent.sessions[session_index].clearPendingPlainOutput();
    }
}

fn feedSessionOutputBytes(session_agent: *SessionAgent, session_index: usize, bytes: []const u8) !void {
    const session = &session_agent.sessions[session_index];
    queueTtyTranscriptChunkForSession(session_agent, session_index, .TTY_TRANSCRIPT_STREAM_INNER_OUT, bytes);
    if (session.terminal_model) |model| {
        const starts_at_boundary = model.isPlainTextParserBoundary();
        try model.feed(bytes);
        if (hasActiveAttachment(session_agent, session_index)) {
            try session.appendPendingPlainOutput(bytes, starts_at_boundary);
        }
    }
}

fn drainAttachmentInput(session_agent: *SessionAgent, attachment_index: usize) void {
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active) return;
    const session = &session_agent.sessions[attachment.session_index];
    if (!session.alive) {
        detachAttachment(session_agent, attachment_index);
        return;
    }

    var frame = protocol.readFrameAlloc(app_allocator.allocator(), attachment.fd) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer frame.deinit(app_allocator.allocator());

    switch (frame.message_type) {
        .input => handleInputFrame(session_agent, attachment_index, frame.payload),
        .resize => handleResizeFrame(session_agent, attachment_index, frame.payload),
        .repaint_request => handleRepaintFrame(session_agent, attachment_index, frame.payload),
        else => {
            queueAttachmentError(session_agent, attachment, "PROTOCOL_ERROR", "unexpected attached message", "") catch {
                detachAttachment(session_agent, attachment_index);
                return;
            };
            closeAttachmentAfterFlush(session_agent, attachment_index);
        },
    }
}

fn handleInputFrame(session_agent: *SessionAgent, attachment_index: usize, payload: []const u8) void {
    const attachment = &session_agent.attachments[attachment_index];
    const session = &session_agent.sessions[attachment.session_index];
    var input = protocol.decodePayload(pb.Input, app_allocator.allocator(), payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer input.deinit(app_allocator.allocator());
    if (input.data.len == 0) return;

    if (input.input_seq != 0) {
        const ack_payload = protocol.encodePayload(app_allocator.allocator(), pb.InputAck{
            .input_seq = input.input_seq,
        }) catch {
            detachAttachment(session_agent, attachment_index);
            return;
        };
        defer app_allocator.allocator().free(ack_payload);
        queueAttachmentFrame(attachment, .input_ack, ack_payload) catch {
            detachAttachment(session_agent, attachment_index);
            return;
        };
        flushAttachmentOutput(session_agent, attachment_index);
    }

    if (session.rows != attachment.rows or session.cols != attachment.cols) {
        updateSessionSize(session, attachment.rows, attachment.cols);
    }

    var translated = std.ArrayList(u8).empty;
    defer translated.deinit(app_allocator.allocator());
    translateAttachmentInput(attachment, session, input.data, &translated) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    if (inputBytesContainUserInput(attachment, input.data)) {
        const now_ms = nowUnixMs();
        attachment.last_input_at_unix_ms = now_ms;
        session.last_input_at_unix_ms = now_ms;
    }
    if (translated.items.len == 0) return;

    queueTtyTranscriptChunk(attachment, .TTY_TRANSCRIPT_STREAM_INNER_IN, translated.items) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    flushAttachmentOutput(session_agent, attachment_index);

    io.writeAll(session.pty_fd, translated.items) catch {
        detachAttachment(session_agent, attachment_index);
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

fn translateAttachmentInput(
    attachment: *Attachment,
    session: *const Session,
    bytes: []const u8,
    out: *std.ArrayList(u8),
) !void {
    if (!attachmentLocalInputParserActive(attachment)) {
        if (attachment.input_pending_len > 0) {
            try out.appendSlice(app_allocator.allocator(), attachment.input_pending[0..attachment.input_pending_len]);
            attachment.input_pending_len = 0;
        }
        try out.appendSlice(app_allocator.allocator(), bytes);
        return;
    }

    var input = std.ArrayList(u8).empty;
    defer input.deinit(app_allocator.allocator());
    if (attachment.input_pending_len > 0) {
        try input.appendSlice(app_allocator.allocator(), attachment.input_pending[0..attachment.input_pending_len]);
        attachment.input_pending_len = 0;
    }
    try input.appendSlice(app_allocator.allocator(), bytes);

    var index: usize = 0;
    while (index < input.items.len) {
        if (input.items[index] != 0x1b) {
            try out.append(app_allocator.allocator(), input.items[index]);
            index += 1;
            continue;
        }

        if (attachmentSgrMouseActive(attachment)) {
            switch (parseSgrMouseReport(input.items, index)) {
                .complete => |report| {
                    try appendTranslatedSgrMouseReport(attachment, session, report, out);
                    index = report.end;
                    continue;
                },
                .incomplete => {
                    try savePendingAttachmentInput(attachment, input.items[index..], out);
                    return;
                },
                .not_mouse => {},
            }
        }

        if (attachmentKittyKeyboardActive(attachment)) {
            switch (parseXtermModifiedKey(input.items, index)) {
                .complete => |key| {
                    try appendKittyKeyboardKey(key, out);
                    index = key.end;
                    continue;
                },
                .incomplete => {
                    try savePendingAttachmentInput(attachment, input.items[index..], out);
                    return;
                },
                .not_modified => {},
            }
        }

        try out.append(app_allocator.allocator(), input.items[index]);
        index += 1;
    }
}

fn savePendingAttachmentInput(attachment: *Attachment, pending: []const u8, out: *std.ArrayList(u8)) !void {
    if (pending.len <= attachment.input_pending.len) {
        @memcpy(attachment.input_pending[0..pending.len], pending);
        attachment.input_pending_len = pending.len;
    } else {
        try out.appendSlice(app_allocator.allocator(), pending);
    }
}

fn attachmentLocalInputParserActive(attachment: *const Attachment) bool {
    return attachmentSgrMouseActive(attachment) or attachmentKittyKeyboardActive(attachment);
}

fn attachmentSgrMouseActive(attachment: *const Attachment) bool {
    return attachment.presentation.terminal_modes_initialized and
        attachment.presentation.terminal_modes.mouse_tracking != .disabled and
        attachment.presentation.terminal_modes.mouse_sgr;
}

fn attachmentKittyKeyboardActive(attachment: *const Attachment) bool {
    return attachment.presentation.terminal_modes_initialized and
        attachment.presentation.terminal_modes.kitty_keyboard_flags != 0;
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

const EscapeSequenceClassification = union(enum) {
    incomplete,
    terminal_response: usize,
    user_input: usize,
};

fn inputBytesContainUserInput(attachment: *const Attachment, bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == 0x1b) {
            switch (parseSgrMouseReport(bytes, index)) {
                .complete => |report| {
                    index = report.end;
                    continue;
                },
                .incomplete => if (attachmentSgrMouseActive(attachment)) return false,
                .not_mouse => {},
            }
            switch (classifyEscapeSequence(bytes, index)) {
                .terminal_response => |end| {
                    index = end;
                    continue;
                },
                .incomplete, .user_input => return true,
            }
        }
        // Treat C0 controls such as ENTER and CTRL-A as user input. The
        // terminal-generated responses we filter are escape sequences.
        return true;
    }
    return false;
}

fn classifyEscapeSequence(bytes: []const u8, start: usize) EscapeSequenceClassification {
    if (start + 1 >= bytes.len) return .incomplete;
    return switch (bytes[start + 1]) {
        ']' => classifyStringControl(bytes, start + 2),
        'P', '_', '^', 'X' => classifyStringControl(bytes, start + 2),
        '[' => classifyCsiSequence(bytes, start + 2),
        else => .{ .user_input = start + 2 },
    };
}

fn classifyStringControl(bytes: []const u8, start: usize) EscapeSequenceClassification {
    var index = start;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == 0x07) return .{ .terminal_response = index + 1 };
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') {
            return .{ .terminal_response = index + 2 };
        }
    }
    return .incomplete;
}

fn classifyCsiSequence(bytes: []const u8, start: usize) EscapeSequenceClassification {
    var index = start;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte < 0x40 or byte > 0x7e) continue;
        const end = index + 1;
        if (isTerminalGeneratedCsiResponse(bytes[start..index], byte)) return .{ .terminal_response = end };
        return .{ .user_input = end };
    }
    return .incomplete;
}

fn isTerminalGeneratedCsiResponse(params_and_intermediates: []const u8, final: u8) bool {
    switch (final) {
        'c', 'n', 'R', 't', 'x' => return true,
        'I', 'O' => return params_and_intermediates.len == 0,
        'y' => return std.mem.indexOfScalar(u8, params_and_intermediates, '$') != null,
        else => return false,
    }
}

fn appendTranslatedSgrMouseReport(
    attachment: *const Attachment,
    session: *const Session,
    report: SgrMouseReport,
    out: *std.ArrayList(u8),
) !void {
    const origin = attachment.origin orelse return;
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
    var attachment = Attachment{
        .origin = .{ .row = 4, .col = 0 },
        .presentation = .{
            .terminal_modes = .{ .mouse_tracking = .normal, .mouse_sgr = true },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b[<0;12;5M", &out);
    try std.testing.expectEqualStrings("\x1b[<0;12;1M", out.items);

    out.clearRetainingCapacity();
    try translateAttachmentInput(&attachment, &session, "\x1b[<0;12;3M", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "xterm modified key input is translated to kitty when kitty keyboard is active" {
    var attachment = Attachment{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b[27;2;13~", &out);
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "split xterm modified key input is held and translated after completion" {
    var attachment = Attachment{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b[27;2;", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(attachment.input_pending_len > 0);

    try translateAttachmentInput(&attachment, &session, "13~", &out);
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "xterm modified key input passes through when kitty keyboard is inactive" {
    var attachment = Attachment{};
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b[27;2;13~", &out);
    try std.testing.expectEqualStrings("\x1b[27;2;13~", out.items);
}

test "non-xterm CSI input passes through when kitty keyboard is active" {
    var attachment = Attachment{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b[A", &out);
    try std.testing.expectEqualStrings("\x1b[A", out.items);
}

test "plain enter input is not synthesized as kitty when kitty keyboard is active" {
    var attachment = Attachment{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\r", &out);
    try std.testing.expectEqualStrings("\r", out.items);
}

test "bare escape is not held by kitty keyboard translation" {
    var attachment = Attachment{
        .presentation = .{
            .terminal_modes = .{ .kitty_keyboard_flags = 7 },
            .terminal_modes_initialized = true,
        },
    };
    const session = Session{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app_allocator.allocator());

    try translateAttachmentInput(&attachment, &session, "\x1b", &out);
    try std.testing.expectEqualStrings("\x1b", out.items);
    try std.testing.expectEqual(@as(usize, 0), attachment.input_pending_len);
}

test "last input classifier ignores terminal generated responses" {
    var attachment = Attachment{
        .origin = .{ .row = 0, .col = 0 },
        .presentation = .{
            .terminal_modes = .{ .mouse_tracking = .normal, .mouse_sgr = true },
            .terminal_modes_initialized = true,
        },
    };

    try std.testing.expect(!inputBytesContainUserInput(&attachment, "\x1b[<0;12;5M"));
    try std.testing.expect(!inputBytesContainUserInput(&attachment, "\x1b]10;rgb:ffff/ffff/ffff\x07"));
    try std.testing.expect(!inputBytesContainUserInput(&attachment, "\x1b[?1;2c"));
    try std.testing.expect(!inputBytesContainUserInput(&attachment, "\x1b[24;80R"));
    try std.testing.expect(!inputBytesContainUserInput(&attachment, "\x1b[0n"));
    try std.testing.expect(inputBytesContainUserInput(&attachment, "\x1b[A"));
    try std.testing.expect(inputBytesContainUserInput(&attachment, "\x01"));
    try std.testing.expect(inputBytesContainUserInput(&attachment, "\x1b]10;rgb:ffff/ffff/ffff\x07x"));
}

fn handleResizeFrame(session_agent: *SessionAgent, attachment_index: usize, payload: []const u8) void {
    const attachment = &session_agent.attachments[attachment_index];
    const session = &session_agent.sessions[attachment.session_index];
    const resize = readResizePayload(payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    const reset_for_screen_repaint = resize.repaint_request != null and
        resize.repaint_request.?.scrollback_cursor == null;
    attachment.rows = resize.rows;
    attachment.cols = resize.cols;
    if (reset_for_screen_repaint) attachment.presentation.resetForScreenRepaint();
    attachment.presentation.setViewportOffset(resize.viewport_offset);
    updateSessionSize(session, resize.rows, resize.cols);
    if (resize.repaint_request) |request| {
        handleRepaintRequest(session_agent, attachment_index, request);
    }
}

fn handleRepaintFrame(session_agent: *SessionAgent, attachment_index: usize, payload: []const u8) void {
    const request = readRepaintRequest(payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    handleRepaintRequest(session_agent, attachment_index, request);
}

fn handleRepaintRequest(session_agent: *SessionAgent, attachment_index: usize, request: RepaintRequest) void {
    const attachment = &session_agent.attachments[attachment_index];
    const session = &session_agent.sessions[attachment.session_index];

    const model = session.terminal_model orelse return;
    const clear_for_replace = request.scrollback_cursor != null and
        request.scrollback_cursor.?.per_epoch_cursor == 0 and
        request.initial_scrollback_rows == null;
    const screen_rows = queueRepaintSnapshot(attachment, session, request, clear_for_replace) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    model.markRendered(screen_rows);
    flushAttachmentOutput(session_agent, attachment_index);
}

fn broadcastSessionPatch(session_agent: *SessionAgent, session_index: usize) void {
    if (!hasActiveAttachment(session_agent, session_index)) return;

    const session = &session_agent.sessions[session_index];
    const model = session.terminal_model orelse return;
    var scrollback = model.scrollbackDelta(app_allocator.allocator()) catch {
        endSessionFromPtyClose(session_agent, session_index);
        return;
    };
    defer scrollback.deinit(app_allocator.allocator());

    var screen = model.renderedScreen(app_allocator.allocator()) catch {
        endSessionFromPtyClose(session_agent, session_index);
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
            endSessionFromPtyClose(session_agent, session_index);
            return;
        };
    }
    if (screen.retained_scrollback_clear_dirty) advanceScrollbackEpochForClear(session);
    var delivered = false;
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!attachment.active or attachment.session_index != session_index) continue;
        if (attachment.close_after_flush) continue;
        if (screen.retained_scrollback_clear_dirty) {
            queueRetainedScrollbackClearDraw(attachment, session) catch {
                detachAttachment(session_agent, i);
                continue;
            };
        }
        if (scrollback.rows.len > 0) {
            queueScrollbackRowsAndScreenDraw(
                attachment,
                session,
                scrollback.rows,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                detachAttachment(session_agent, i);
                continue;
            };
        } else if (should_send_screen_draw) {
            _ = queueScreenDraw(
                attachment,
                session,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                detachAttachment(session_agent, i);
                continue;
            };
        }
        flushAttachmentOutput(session_agent, i);
        if (attachment.active) delivered = true;
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

fn hasActiveAttachment(session_agent: *const SessionAgent, session_index: usize) bool {
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active and
            attachment.session_index == session_index and
            !attachment.close_after_flush) return true;
    }
    return false;
}

fn hasAttachmentForSession(session_agent: *const SessionAgent, session_index: usize) bool {
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active and attachment.session_index == session_index) return true;
    }
    return false;
}

fn sendSessionEndedToAttachments(session_agent: *SessionAgent, session_index: usize, reason: u8, exit_info: ExitInfo) void {
    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!attachment.active or attachment.session_index != session_index) continue;
        sendSessionEnded(attachment, reason, exit_info) catch {
            detachAttachment(session_agent, i);
            continue;
        };
        closeAttachmentAfterFlush(session_agent, i);
    }
}

fn detachAttachment(session_agent: *SessionAgent, attachment_index: usize) void {
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active) return;

    const session_index = attachment.session_index;
    if (session_index < session_agent.sessions.len) {
        const session = &session_agent.sessions[session_index];
        logSessionAgent(session_agent, "event=detach id={s} rows={} cols={}", .{ session.idSlice(), attachment.rows, attachment.cols });
        removeClientRouteHintForAttachment(session_agent, session, attachment);
    }
    _ = c.close(attachment.fd);
    attachment.output.deinit(app_allocator.allocator());
    attachment.* = Attachment{};
    refreshAttachedFlag(session_agent, session_index);
}

fn closeAttachmentAfterFlush(session_agent: *SessionAgent, attachment_index: usize) void {
    const attachment = &session_agent.attachments[attachment_index];
    if (!attachment.active) return;
    attachment.close_after_flush = true;
    flushAttachmentOutput(session_agent, attachment_index);
}

fn refreshAttachedFlag(session_agent: *SessionAgent, session_index: usize) void {
    if (!session_agent.sessions[session_index].alive) {
        session_agent.sessions[session_index].attached = false;
        return;
    }

    const count = attachedCount(session_agent, session_index);
    const now_attached = count > 0;
    const was_attached = session_agent.sessions[session_index].attached;
    session_agent.sessions[session_index].attached = now_attached;
    if (now_attached) {
        session_agent.sessions[session_index].detached_at_unix_ms = 0;
    } else if (was_attached or session_agent.sessions[session_index].detached_at_unix_ms == 0) {
        session_agent.sessions[session_index].detached_at_unix_ms = nowUnixMs();
    }
}

fn endSession(session_agent: *SessionAgent, session_index: usize, reason: u8, exit_info: ExitInfo) void {
    const session = &session_agent.sessions[session_index];
    if (!session.alive) return;

    broadcastSessionPatch(session_agent, session_index);
    session.clearPendingPlainOutput();
    session.synchronized_output_since_ms = 0;

    if (exit_info.kind != 0) {
        logSessionAgent(session_agent, "event=session_end id={s} pid={} reason={} exit_kind={} status={} ended_at_ms={}", .{
            session.idSlice(),
            session.pid,
            reason,
            exit_info.kind,
            exit_info.status,
            exit_info.ended_at_unix_ms,
        });
    } else {
        logSessionAgent(session_agent, "event=session_end id={s} pid={} reason={} exit_kind=none status=none ended_at_ms={}", .{
            session.idSlice(),
            session.pid,
            reason,
            nowUnixMs(),
        });
    }
    sendSessionEndedToAttachments(session_agent, session_index, reason, exit_info);
    removeClientRouteHintsForSession(session_agent, session_index);
    writeEndedSessionTombstone(session_agent, session, reason, exit_info);
    if (session.pty_fd >= 0) _ = c.close(session.pty_fd);
    if (session.terminal_model) |model| {
        model.destroy();
        session.terminal_model = null;
    }
    clearAttachmentHints(session_agent);
    session.deinit();
    session.alive = false;
    session.attached = false;
}

fn writeEndedSessionTombstone(session_agent: *SessionAgent, session: *const Session, reason: u8, exit_info: ExitInfo) void {
    const allocator = app_allocator.allocator();
    var route = session_registry.readRouteForRef(allocator, session.idSlice()) catch |err| {
        logSessionAgent(session_agent, "event=tombstone_route_missing id={s} error={t}", .{ session.idSlice(), err });
        return;
    };
    defer route.deinit(allocator);

    const exit_status: ?session_registry.TombstoneExitStatus = switch (exit_info.kind) {
        1 => .{ .kind = .exited, .status = exit_info.status },
        2 => .{ .kind = .signalled, .status = exit_info.status },
        else => null,
    };
    session_registry.writeTombstoneForRoute(allocator, &route, .{
        .ended_at_unix_ms = if (exit_info.ended_at_unix_ms == 0) nowUnixMs() else exit_info.ended_at_unix_ms,
        .end_reason = switch (reason) {
            1 => .killed_by_request,
            2 => .agent_shutdown,
            else => .process_exited,
        },
        .exit_status = exit_status,
    }) catch |err| {
        logSessionAgent(session_agent, "event=tombstone_write_failed id={s} error={t}", .{ session.idSlice(), err });
    };
}

fn clearAttachmentHints(session_agent: *SessionAgent) void {
    if (session_agent.session_paths) |paths| session_registry.removeEndedHints(paths) catch {};
}

fn removeClientRouteHintsForSession(session_agent: *SessionAgent, session_index: usize) void {
    if (session_index >= session_agent.sessions.len) return;
    const session = &session_agent.sessions[session_index];
    for (&session_agent.attachments) |*attachment| {
        if (!attachment.active or attachment.session_index != session_index) continue;
        removeClientRouteHintForAttachment(session_agent, session, attachment);
    }
}

fn stopSessionAgentIfComplete(session_agent: *SessionAgent) void {
    if (session_agent.shutting_down) {
        for (&session_agent.attachments) |*attachment| {
            if (attachment.active) return;
        }
        session_agent.running = false;
        return;
    }
    if (session_agent.fixed_session_id == null or !session_agent.started_session) return;
    for (&session_agent.sessions) |*session| {
        if (session.alive) return;
    }
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active) return;
    }
    session_agent.running = false;
}

fn closeSessionAgent(session_agent: *SessionAgent) void {
    for (0..session_agent.attachments.len) |i| detachAttachment(session_agent, i);
    for (0..session_agent.sessions.len) |i| endSession(session_agent, i, 2, .{});
}

fn findSessionIndex(session_agent: *SessionAgent, id: []const u8) ?usize {
    for (&session_agent.sessions, 0..) |*session, i| {
        if (session.alive and std.mem.eql(u8, session.idSlice(), id)) return i;
    }
    return null;
}

fn findSessionIndexForRef(session_agent: *SessionAgent, ref: []const u8) !?usize {
    const guid = try session_registry.resolveRefToGuid(app_allocator.allocator(), ref);
    defer app_allocator.allocator().free(guid);
    return findSessionIndex(session_agent, guid);
}

fn findMostRecentSessionIndex(session_agent: *SessionAgent) ?usize {
    for (&session_agent.sessions, 0..) |*session, i| {
        if (!session.alive) continue;
        return i;
    }
    return null;
}

fn reapSessions(session_agent: *SessionAgent) void {
    while (true) {
        var status: c_int = 0;
        const result = c.waitpid(-1, &status, 1);
        if (result <= 0) return;
        const session_index = findSessionIndexByPid(session_agent, result) orelse continue;
        drainSessionOutputBeforeEnd(session_agent, session_index);
        endSession(session_agent, session_index, session_agent.sessions[session_index].end_reason, exitInfoFromWaitStatus(status));
    }
}

fn endSessionFromPtyClose(session_agent: *SessionAgent, session_index: usize) void {
    if (waitForSessionExitInfo(session_agent.sessions[session_index].pid)) |exit_info| {
        endSession(session_agent, session_index, session_agent.sessions[session_index].end_reason, exit_info);
        return;
    }
    endSession(session_agent, session_index, session_agent.sessions[session_index].end_reason, .{ .ended_at_unix_ms = nowUnixMs() });
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

fn findSessionIndexByPid(session_agent: *SessionAgent, pid: c.pid_t) ?usize {
    for (&session_agent.sessions, 0..) |*session, i| {
        if (session.alive and session.pid == pid) return i;
    }
    return null;
}
