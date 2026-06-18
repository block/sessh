const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const client_renderer = @import("renderer.zig");
const vt = @import("vt.zig");

// What we believe one attached client currently has on its outer terminal.
// This is separate from the headless terminal model. It lets us track the
// inner viewport height and send small redraws when the client is in sync.
pub const PresentationState = struct {
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

    pub fn reset(self: *PresentationState) void {
        self.* = .{};
    }

    // Keep scrollback, but redraw the visible screen from scratch.
    //
    // The client may have shown a reconnect overlay or skipped stale draws, so
    // cached cursor, mode, and color state is no longer trustworthy. The old
    // height is kept only so the next draw can clear stale rows.
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
    pub fn applyAttachedClientEndRestoreScreen(
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
    pub fn clearOuterVisibleForScreen(self: *PresentationState, renderer: client_renderer.Renderer, screen: *const vt.RenderedScreen) !void {
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
    pub fn appendScrollbackRows(
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
    pub fn canApplyPlainReplay(
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
    pub fn assumePlainReplayScreen(self: *PresentationState, session_rows: u16, screen: *const vt.RenderedScreen) !void {
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

pub const TerminalOrigin = struct {
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

fn screenWantsMouseReporting(screen: *const vt.RenderedScreen) bool {
    return screen.modes.mouse_tracking != 0;
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
    // The remote terminal process therefore only needs to record whether the batch started at a
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
