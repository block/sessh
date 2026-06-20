// Client-facing presentation cache for one visible terminal connection.
// This is separate from the headless terminal model: reconnect overlays,
// skipped stale draws, and terminal resize recovery can invalidate what the
// user sees without changing the remote PTY's terminal state.
const std = @import("std");
const builtin = @import("builtin");
const app_allocator = @import("../core/app_allocator.zig");
const client_renderer = @import("renderer.zig");
const vt = @import("vt.zig");
const tty = @import("../tty/terminal.zig");

pub const ApplyScreenRequest = struct {
    session_size: tty.WindowSize,
    screen: *const vt.RenderedScreen,
    force_redraw: bool,
    align_viewport: bool,
};

pub const PlainReplayRequest = struct {
    screen: *const vt.RenderedScreen,
    align_viewport: bool,
    bytes: []const u8,
    parser_boundary_ok: bool,
};

pub const PresentationState = struct {
    initialized: bool = false,
    active_screen: u8 = 0,
    saved_primary: ?ScreenBufferState = null,
    rendered_rows: u16 = 0,
    cursor: tty.CursorState = .{},
    terminal_modes: tty.TerminalModes = .{},
    terminal_modes_initialized: bool = false,
    default_colors: client_renderer.DefaultColors = .{},
    default_colors_initialized: bool = false,
    full_height_rendering: bool = false,
    viewport_offset: i32 = 0,

    pub fn reset(self: *PresentationState) void {
        self.* = .{};
    }

    // Keep scrollback, but redraw the visible screen from scratch.
    //
    // The client may have shown a reconnect overlay or skipped stale draws, so
    // repaint invalidates cached cursor, mode, and color state. The
    // previous height is kept only so the next draw can clear stale rows.
    pub fn resetForScreenRepaint(self: *PresentationState) void {
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
    pub fn applyScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        request: ApplyScreenRequest,
    ) !void {
        const session_rows = request.session_size.rows;
        const screen = request.screen;
        const force_redraw = request.force_redraw;
        try self.switchActiveScreen(renderer, screen.active_screen);

        const desired_modes = screen.modes;
        const mouse_requested = desired_modes.mouse_tracking != .disabled;
        if (screen.active_screen == 1 and mouse_requested) {
            self.full_height_rendering = true;
        }

        if (request.align_viewport and screen.active_screen == 0) {
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
            try self.render(renderer, screen, min_rendered_rows);
        } else {
            if (min_rendered_rows > 0) try self.ensureGridRow(renderer, min_rendered_rows - 1);
            for (screen.rows, 0..) |row, row_index| {
                if (!row.dirty) continue;
                try self.moveToGridPosition(renderer, tty.top_left_position.withRow(@intCast(row_index)));
                try renderer.clearLine();
                try renderVtRow(renderer, row);
                self.cursor.position = self.cursor.position.withCol(renderedCellsDisplayWidth(row.cells));
                self.rendered_rows = @max(self.rendered_rows, @as(u16, @intCast(row_index + 1)));
            }
            try self.moveToGridPosition(renderer, screen.cursor.position);
            self.cursor = screen.cursor;
            try renderer.setCursorVisibility(self.cursor.visibility);
            try renderer.setCursorStyle(self.cursor.style);
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

    // Restore a full-height screen before the visible client exits, so the user
    // does not return to a partially painted alternate/full-screen app.
    pub fn applyVisibleClientEndRestoreScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_size: tty.WindowSize,
        screen: *const vt.RenderedScreen,
    ) !void {
        try self.switchActiveScreen(renderer, screen.active_screen);
        try self.render(renderer, screen, session_size.rows);
        if (screen.title_dirty) try renderer.setTitle(screen.title);
        try self.applyTerminalModes(renderer, screen.modes);
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
        self.cursor.position = tty.top_left_position;
        self.viewport_offset = 0;
    }

    // The inner terminal cleared its display. Clear the outer visible area too,
    // then forget the cached row/cursor position.
    pub fn clearOuterVisibleForScreen(self: *PresentationState, renderer: client_renderer.Renderer, screen: *const vt.RenderedScreen) !void {
        try self.switchActiveScreen(renderer, screen.active_screen);
        try renderer.clearVisible();
        self.initialized = false;
        self.rendered_rows = 0;
        self.cursor.position = tty.top_left_position;
        self.full_height_rendering = screenWantsMouseReporting(screen);
        self.viewport_offset = 0;
    }

    // After any full draw, the visible terminal should match the VT snapshot,
    // including cursor attributes that are not implied by row contents.
    fn render(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        screen: *const vt.RenderedScreen,
        min_rendered_rows: u16,
    ) !void {
        const target_rows = targetRenderedRows(screen, min_rendered_rows);
        if (!self.initialized) {
            try self.renderInitial(renderer, screen, target_rows);
        } else {
            try self.redraw(renderer, screen, target_rows);
        }

        self.cursor = screen.cursor;
        try renderer.setCursorVisibility(self.cursor.visibility);
        try renderer.setCursorStyle(self.cursor.style);
        self.initialized = true;
        self.rendered_rows = target_rows;
    }

    // Retained scrollback appears above the rendered screen, matching normal
    // terminal output that scrolls earlier rows upward.
    pub fn appendScrollbackRows(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_size: tty.WindowSize,
        rows: []const vt.RenderedRow,
    ) !void {
        const session_rows = session_size.rows;
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
            self.cursor.position = tty.top_left_position;
            try renderer.carriageReturn();
            try renderer.clearLine();
            try renderVtRow(renderer, row);
            self.cursor.position = self.cursor.position.withCol(renderedCellsDisplayWidth(row.cells));
            try self.moveToGridPosition(renderer, tty.top_left_position.withRow(self.rendered_rows - 1));
            try renderer.newline();
            self.cursor.position = tty.top_left_position.withRow(self.rendered_rows - 1);
        }
        self.viewport_offset = 0;
    }

    // Draw when we cannot rely on the cached cursor position or terminal
    // state. If resetForScreenRepaint left a stale height behind, clear that
    // stale area before drawing the new trimmed screen.
    fn renderInitial(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        screen: *const vt.RenderedScreen,
        target_rows: u16,
    ) !void {
        // Include the cached height in the clear pass. Repaint resets keep that
        // height specifically so a shorter replacement cannot leave stale rows
        // stranded below the new snapshot.
        const rendered_rows = @max(
            self.rendered_rows,
            target_rows,
        );
        var row_index: u16 = 0;
        while (row_index < rendered_rows) : (row_index += 1) {
            if (row_index > 0) try renderer.newline();
            try renderer.clearLine();
            if (row_index < screen.rows.len) try renderVtRow(renderer, screen.rows[row_index]);
        }
        try moveToSnapshotCursor(renderer, rendered_rows, screen.cursor.position);
    }

    // Redraw when we know where our cached rendered grid is. Clear the larger
    // of cached and new row counts so a shorter terminal screen does not leave
    // stale content behind.
    fn redraw(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        screen: *const vt.RenderedScreen,
        new_rows: u16,
    ) !void {
        try self.moveToRenderedTop(renderer);

        const redraw_rows = @max(self.rendered_rows, new_rows);
        var row_index: u16 = 0;
        while (row_index < redraw_rows) : (row_index += 1) {
            try renderer.carriageReturn();
            try renderer.clearLine();
            if (row_index < screen.rows.len) try renderVtRow(renderer, screen.rows[row_index]);
            if (row_index + 1 < redraw_rows) try renderer.newline();
        }

        try moveToSnapshotCursor(renderer, redraw_rows, screen.cursor.position);
    }

    // Switch the real terminal buffer to match the inner terminal. We save the
    // primary-buffer cursor/grid state before entering the outer alternate
    // screen, because the terminal restores that primary cursor when we leave.
    pub fn switchActiveScreen(self: *PresentationState, renderer: client_renderer.Renderer, active_screen: u8) !void {
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
            .cursor = self.cursor,
            .full_height_rendering = self.full_height_rendering,
            .viewport_offset = self.viewport_offset,
        };
    }

    fn restoreScreenBufferState(self: *PresentationState, state: ScreenBufferState) void {
        self.initialized = state.initialized;
        self.rendered_rows = state.rendered_rows;
        self.cursor = state.cursor;
        self.full_height_rendering = state.full_height_rendering;
        self.viewport_offset = state.viewport_offset;
    }

    // Terminal modes are global settings on the outer terminal. Emit the full
    // desired mode set only when our cached value differs.
    fn applyTerminalModes(self: *PresentationState, renderer: client_renderer.Renderer, modes: tty.TerminalModes) !void {
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

    // Sometimes remote output can be forwarded unchanged instead of converted
    // into a synthetic redraw. Only do that when it cannot disturb hidden
    // state that PresentationState is tracking.
    pub fn canApplyPlainReplay(self: *const PresentationState, request: PlainReplayRequest) !bool {
        const screen = request.screen;
        if (!self.initialized) return false;
        if (self.full_height_rendering) return false;
        if (self.viewportOffsetUnknown()) return false;
        if (request.align_viewport) return false;
        if (screen.active_screen != 0) return false;
        if (screen.active_screen_changed) return false;
        if (screen.title_dirty or
            screen.default_colors_dirty or
            screen.retained_scrollback_clear_dirty or
            screen.display_clear != null)
        {
            return false;
        }
        if (!request.parser_boundary_ok) return false;
        if (!isSafePlainReplay(request.bytes)) return false;
        if (!rowsHaveOnlyDefaultPresentation(screen.rows)) return false;
        if (!self.terminal_modes_initialized or
            !self.terminal_modes.eql(screen.modes))
        {
            return false;
        }
        if (!self.default_colors_initialized or
            !self.default_colors.eql(try vtDefaultColorsToClient(screen.default_colors)))
        {
            return false;
        }
        const screen_cursor = screen.cursor;
        if (self.cursor.visibility != screen_cursor.visibility) return false;
        if (self.cursor.style != screen_cursor.style) return false;
        return true;
    }

    // Plain replay bypasses synthetic rendering, so the cache has to jump to
    // the VT snapshot that was produced by those original bytes.
    pub fn assumePlainReplayScreen(self: *PresentationState, session_size: tty.WindowSize, screen: *const vt.RenderedScreen) !void {
        const session_rows = session_size.rows;
        if (screen.active_screen > 1) return error.InvalidActiveScreen;
        if (self.active_screen != screen.active_screen) return error.ActiveScreenSwitchRequiresDraw;
        self.initialized = true;
        self.rendered_rows = @min(
            session_rows,
            @max(self.rendered_rows, targetRenderedRows(screen, 0)),
        );
        self.cursor = screen.cursor;
        self.terminal_modes = screen.modes;
        self.terminal_modes_initialized = true;
        self.default_colors = try vtDefaultColorsToClient(screen.default_colors);
        self.default_colors_initialized = true;
        if (screen.modes.mouse_tracking == .disabled or !screen.modes.mouse_sgr) {
            self.full_height_rendering = false;
        }
        self.updateViewportOffset(session_rows);
    }

    // Retained scrollback belongs to the primary buffer. If the outer terminal
    // is showing the alternate buffer, switch back before appending scrollback
    // rows; the following screen draw can switch to alternate again if the
    // inner terminal is still there.
    pub fn preparePrimaryForScrollback(self: *PresentationState, renderer: client_renderer.Renderer) !void {
        try self.switchActiveScreen(renderer, 0);
    }

    pub fn setViewportOffset(self: *PresentationState, viewport_offset: ?i32) void {
        self.viewport_offset = viewport_offset orelse 0;
    }

    pub fn protocolViewportOffset(self: *const PresentationState) ?i32 {
        return if (self.viewport_offset == 0) null else self.viewport_offset;
    }

    pub fn viewportOffsetUnknown(self: *const PresentationState) bool {
        return self.viewport_offset < 0;
    }

    // Once enough rows have been rendered to fill the viewport, future draws
    // can treat the inner and outer viewport origins as aligned.
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

    // The rendered grid may sit above the current terminal cursor in scrollback,
    // so moves are relative to our cached cursor rather than absolute screen
    // coordinates.
    fn moveToRenderedTop(self: *const PresentationState, renderer: client_renderer.Renderer) !void {
        if (self.rendered_rows == 0) return;
        try renderer.cursorUp(self.cursor.position.row);
        try renderer.carriageReturn();
    }

    // Row writes assume their destination row already exists in the outer
    // transcript. Extend with blank lines before using relative cursor motion.
    fn moveToGridPosition(self: *PresentationState, renderer: client_renderer.Renderer, position: tty.CursorPosition) !void {
        try self.ensureGridRow(renderer, position.row);
        try self.moveWithinGrid(renderer, position);
    }

    // Make sure a row exists in the outer terminal before we move to it.
    fn ensureGridRow(self: *PresentationState, renderer: client_renderer.Renderer, row: u16) !void {
        if (self.rendered_rows == 0) {
            self.rendered_rows = 1;
            self.cursor.position = tty.top_left_position;
        }

        while (row >= self.rendered_rows) {
            try self.moveWithinGrid(renderer, self.cursor.position.withRow(self.rendered_rows - 1));
            try renderer.newline();
            self.cursor.position = tty.top_left_position.withRow(self.rendered_rows);
            self.rendered_rows += 1;
        }
    }

    // Absolute cursor addressing only works inside the visible screen. Use
    // relative movement so the same code works when our grid lives in
    // scrollback-backed rows.
    fn moveWithinGrid(self: *PresentationState, renderer: client_renderer.Renderer, position: tty.CursorPosition) !void {
        const row = position.row;
        const col = position.col;
        if (self.cursor.position.row > row) {
            try renderer.cursorUp(self.cursor.position.row - row);
        } else if (row > self.cursor.position.row) {
            try renderer.cursorDown(row - self.cursor.position.row);
        }
        try renderer.carriageReturn();
        try renderer.cursorRight(col);
        self.cursor.position = position;
    }
};

const ScreenBufferState = struct {
    initialized: bool = false,
    rendered_rows: u16 = 0,
    cursor: tty.CursorState = .{},
    full_height_rendering: bool = false,
    viewport_offset: i32 = 0,
};

fn screenWantsMouseReporting(screen: *const vt.RenderedScreen) bool {
    return screen.modes.mouse_tracking != .disabled;
}

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
    // The terminal worker therefore only needs to record whether the batch started at a
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

// Rows are drawn from top to bottom, leaving the real cursor on the last
// rendered row. Move relative to that point instead of jumping absolutely so
// this still works while the rendered grid lives in scrollback-backed rows.
fn moveToSnapshotCursor(renderer: client_renderer.Renderer, rendered_rows: u16, cursor: tty.CursorPosition) !void {
    if (rendered_rows == 0) {
        try renderer.cursorDown(cursor.row);
        try renderer.carriageReturn();
        try renderer.cursorRight(cursor.col);
        return;
    }
    const last_row = rendered_rows - 1;
    if (cursor.row < last_row) try renderer.cursorUp(last_row - cursor.row);
    if (cursor.row > last_row) try renderer.cursorDown(cursor.row - last_row);
    try renderer.carriageReturn();
    try renderer.cursorRight(cursor.col);
}

// How many rows of the inner viewport this client has mapped onto the outer
// terminal.
//
// A trimmed snapshot can mean two different things: the inner viewport is
// aligned and the bottom rows are blank, or the viewport is still unaligned and
// drawing more rows would scroll existing outer-terminal content. After
// alignment, callers need a way to choose the first meaning; min_rendered_rows
// lets them do that.
fn targetRenderedRows(screen: *const vt.RenderedScreen, min_rendered_rows: u16) u16 {
    return @max(
        @max(@as(u16, @intCast(screen.rows.len)), min_rendered_rows),
        screen.cursor.position.row +| 1,
    );
}

fn terminalModesWithoutMouse(modes: tty.TerminalModes) tty.TerminalModes {
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
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);

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
        .cursor = .{},
        .modes = .{ .mouse_tracking = .normal, .mouse_sgr = true },
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
    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 3, .cols = 20 },
        .screen = &screen,
        .force_redraw = true,
        .align_viewport = false,
    });
    try std.testing.expectEqual(@as(u16, 3), presentation.rendered_rows);
}

test "active-screen change uses outer alternate screen" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);

    var first_primary = try testing.renderedScreen(std.testing.allocator, .{
        .cursor = .{ .position = .{ .row = 2, .col = 0 } },
        .labels = &.{ "PRIMARY0", "PRIMARY1", "PRIMARY2" },
    });
    defer first_primary.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 4, .cols = 20 },
        .screen = &first_primary,
        .force_redraw = true,
        .align_viewport = false,
    });

    bytes.clearRetainingCapacity();

    var alt_screen = try testing.renderedScreen(std.testing.allocator, .{
        .active_screen = 1,
        .cursor = .{ .position = .{ .row = 3, .col = 0 } },
        .labels = &.{ "ALT0", "ALT1", "ALT2", "ALT3" },
    });
    defer alt_screen.deinit(std.testing.allocator);

    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 4, .cols = 20 },
        .screen = &alt_screen,
        .force_redraw = true,
        .align_viewport = false,
    });
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[?1049h") != null);
    try std.testing.expectEqual(@as(u16, 3), presentation.cursor.position.row);

    bytes.clearRetainingCapacity();

    var primary_screen = try testing.renderedScreen(std.testing.allocator, .{
        .labels = &.{"PRIMARY"},
    });
    defer primary_screen.deinit(std.testing.allocator);

    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 4, .cols = 20 },
        .screen = &primary_screen,
        .force_redraw = true,
        .align_viewport = false,
    });
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[?1049l\x1b[2A\r"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "PRIMARY") != null);
}

test "visible-client exit restore leaves outer alternate screen" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);

    var alt_screen = try testing.renderedScreen(std.testing.allocator, .{
        .active_screen = 1,
        .cursor = .{ .position = .{ .row = 3, .col = 0 } },
        .labels = &.{ "ALT0", "ALT1", "ALT2", "ALT3" },
    });
    defer alt_screen.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 4, .cols = 20 },
        .screen = &alt_screen,
        .force_redraw = true,
        .align_viewport = false,
    });

    bytes.clearRetainingCapacity();

    var primary_screen = try testing.renderedScreen(std.testing.allocator, .{
        .labels = &.{"PRIMARY"},
    });
    defer primary_screen.deinit(std.testing.allocator);

    try presentation.applyVisibleClientEndRestoreScreen(renderer, .{ .rows = 4, .cols = 20 }, &primary_screen);
    try std.testing.expect(std.mem.startsWith(u8, bytes.items, "\x1b[?1049l"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "PRIMARY") != null);
}

test "initial screen render clears target rows before drawing" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);

    var screen = try testing.renderedScreen(std.testing.allocator, .{
        .cursor = .{ .position = .{ .row = 2, .col = 0 } },
        .labels = &.{ "short", "", "tiny" },
    });
    defer screen.deinit(std.testing.allocator);

    var presentation = PresentationState{};
    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 4, .cols = 20 },
        .screen = &screen,
        .force_redraw = true,
        .align_viewport = false,
    });

    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[2K\x1b[0mshort") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\r\n\x1b[2K\x1b[0m\x1b[0m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\x1b[2K\x1b[0mtiny") != null);
}

test "screen repaint reset clears previous rows then records new height" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(app_allocator.allocator());
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&bytes);

    var screen = try testing.renderedScreen(std.testing.allocator, .{
        .labels = &.{"short"},
    });
    defer screen.deinit(std.testing.allocator);

    var presentation = PresentationState{
        .initialized = true,
        .rendered_rows = 5,
    };
    presentation.resetForScreenRepaint();
    try presentation.applyScreen(renderer, .{
        .session_size = .{ .rows = 5, .cols = 20 },
        .screen = &screen,
        .force_redraw = true,
        .align_viewport = false,
    });

    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, bytes.items, "\x1b[2K"));
    try std.testing.expectEqual(@as(u16, 1), presentation.rendered_rows);
}

const testing = if (builtin.is_test) struct {
    const RenderedScreenFixture = struct {
        active_screen: u8 = 0,
        cursor: tty.CursorState = .{},
        labels: []const []const u8,
    };

    fn renderedScreen(allocator: std.mem.Allocator, fixture: RenderedScreenFixture) !vt.RenderedScreen {
        // Build the smallest RenderedScreen needed by presentation tests. Real
        // screens carry per-cell text and attributes; these fixtures only care
        // about row identity and cursor/alternate-screen state.
        const labels = fixture.labels;
        const rows = try allocator.alloc(vt.RenderedRow, labels.len);
        var rows_filled: usize = 0;
        errdefer {
            for (rows[0..rows_filled]) |*row| row.deinit(allocator);
            allocator.free(rows);
        }

        for (labels, 0..) |label, index| {
            rows[index] = try renderedRow(allocator, label);
            rows_filled += 1;
        }

        return .{
            .rows = rows,
            .cols = 80,
            .active_screen = fixture.active_screen,
            .title = "",
            .title_present = false,
            .title_dirty = false,
            .default_colors = .{},
            .default_colors_dirty = false,
            .retained_scrollback_clear_dirty = false,
            .cursor = fixture.cursor,
            .modes = .{},
            .dirty_state = .full,
            .active_screen_changed = true,
            .display_clear = null,
        };
    }

    fn renderedRow(allocator: std.mem.Allocator, label: []const u8) !vt.RenderedRow {
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
} else struct {};

fn vtAttrsToClient(attrs: vt.CellAttrs) !client_renderer.CellAttrs {
    // Translate the compact VT wire representation back into renderer attrs.
    // The bit layout is owned by sessh's protocol, while Renderer uses named
    // fields that map directly to ANSI SGR output.
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
