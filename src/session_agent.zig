const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const client_renderer = @import("client_renderer.zig");
const io = @import("io.zig");
const protocol = @import("protocol.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");
const vt = @import("vt.zig");

const max_sessions = 64;
const max_attachments = 128;
const max_attachment_output_queue_bytes = 64 * 1024 * 1024;
const preferred_live_output_batch_bytes = 1024;
const max_live_output_reads_per_batch = 64;

const pb = protocol.pb;
const hpb = protocol.hpb;

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
    kill_waiter_fd: c.fd_t = -1,
    attached: bool = false,
    alive: bool = false,
    pending_plain_output: std.ArrayList(u8) = .empty,
    pending_plain_starts_at_boundary: bool = false,

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
    }
};

const Attachment = struct {
    fd: c.fd_t = -1,
    session_index: usize = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    origin: ?TerminalOrigin = null,
    active: bool = false,
    close_after_flush: bool = false,
    presentation: PresentationState = .{},
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    input_pending: [128]u8 = [_]u8{0} ** 128,
    input_pending_len: usize = 0,

    fn queuedBytes(self: *const Attachment) usize {
        return self.output.items.len - self.output_offset;
    }
};

const SessionAgent = struct {
    sessions: [max_sessions]Session = [_]Session{Session{}} ** max_sessions,
    attachments: [max_attachments]Attachment = [_]Attachment{Attachment{}} ** max_attachments,
    next_id: usize = 1,
    running: bool = true,
    log_file: ?std.fs.File = null,
    fixed_session_id: ?[]const u8 = null,
    session_paths: ?session_registry.SessionPaths = null,
    started_session: bool = false,
};

const PollKind = union(enum) {
    listen,
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

    fn applyRelayEndRestoreScreen(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        session_rows: u16,
        screen: *const vt.RenderedScreen,
    ) !void {
        try self.moveToRenderedTop(renderer);
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
        self.rendered_rows = @max(@as(u16, @intCast(rows.len)), min_rendered_rows);
        self.cursor_row = cursor_row;
        self.cursor_col = cursor_col;
        self.cursor_visible = cursor_visible;
        self.cursor_style = cursor_style;
    }

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

    fn renderInitial(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        rows: []const vt.RenderedRow,
        cursor_row: u16,
        cursor_col: u16,
        min_rendered_rows: u16,
    ) !void {
        _ = self;
        const rendered_rows = @max(@as(u16, @intCast(rows.len)), min_rendered_rows);
        var row_index: u16 = 0;
        while (row_index < rendered_rows) : (row_index += 1) {
            if (row_index > 0) try renderer.newline();
            if (min_rendered_rows > 0) try renderer.clearLine();
            if (row_index < rows.len) try renderVtRow(renderer, rows[row_index]);
        }
        try moveToSnapshotCursor(renderer, rendered_rows, cursor_row, cursor_col);
    }

    fn redraw(
        self: *PresentationState,
        renderer: client_renderer.Renderer,
        rows: []const vt.RenderedRow,
        cursor_row: u16,
        cursor_col: u16,
        min_rendered_rows: u16,
    ) !void {
        try self.moveToRenderedTop(renderer);

        const new_rows = @max(@as(u16, @intCast(rows.len)), min_rendered_rows);
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
        self.rendered_rows = 0;
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    fn applyTerminalModes(self: *PresentationState, renderer: client_renderer.Renderer, modes: client_renderer.TerminalModes) !void {
        if (self.terminal_modes_initialized and self.terminal_modes.eql(modes)) return;
        try renderer.applyTerminalModes(modes);
        self.terminal_modes = modes;
        self.terminal_modes_initialized = true;
    }

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

    fn moveToRenderedTop(self: *const PresentationState, renderer: client_renderer.Renderer) !void {
        if (self.rendered_rows == 0) return;
        try renderer.cursorUp(self.cursor_row);
        try renderer.carriageReturn();
    }

    fn moveToGridPosition(self: *PresentationState, renderer: client_renderer.Renderer, row: u16, col: u16) !void {
        try self.ensureGridRow(renderer, row);
        try self.moveWithinGrid(renderer, row, col);
    }

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
};

const SessionNewRequest = struct {
    resize: ResizePayload,
    scrollback_row_count: u32,
    environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,

    fn deinit(self: *SessionNewRequest) void {
        self.environment.deinit();
        self.* = undefined;
    }
};

const RepaintRequest = struct {
    id: u64,
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

const CommandOutput = struct {
    buf: []u8,
    len: usize = 0,

    fn written(self: *const CommandOutput) []const u8 {
        return self.buf[0..self.len];
    }

    fn append(self: *CommandOutput, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.PayloadTooLarge;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn print(self: *CommandOutput, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += formatted.len;
    }
};

/// Run one long-lived agent for exactly one session directory.
///
/// This is the process shape used by the session-agent architecture. It still
/// reuses the session agent's terminal and attachment machinery, but it fixes the
/// session id to the registry directory name and exits after that session ends.
pub fn runSessionAgent(session_dir: []const u8) !void {
    socket_transport.publishRuntimeRootSymlinkOnce(app_allocator.allocator());

    const paths = try session_registry.pathsForSessionDir(app_allocator.allocator(), session_dir);

    const fixed_session_id = std.fs.path.basename(paths.dir);
    var session_agent = SessionAgent{
        .fixed_session_id = fixed_session_id,
        .session_paths = paths,
    };
    defer if (session_agent.session_paths) |*session_paths| session_paths.deinit(app_allocator.allocator());

    const listen_fd = try socket_transport.listenSocket(session_agent.session_paths.?.socket);
    defer _ = c.close(listen_fd);
    defer session_registry.removeEndedHints(session_agent.session_paths.?) catch {};

    try writeAgentCompatBinary(session_agent.session_paths.?);
    try session_registry.writeMeta(session_agent.session_paths.?, c.getpid(), config.version);
    try openSessionAgentLog(&session_agent, session_agent.session_paths.?.socket);
    defer closeSessionAgentLog(&session_agent);
    logSessionAgent(&session_agent, "event=session_agent_start id={s} socket={s}", .{ fixed_session_id, session_agent.session_paths.?.socket });
    defer logSessionAgent(&session_agent, "event=session_agent_stop id={s}", .{fixed_session_id});
    defer closeSessionAgent(&session_agent);

    while (session_agent.running) {
        try sessionAgentPollOnce(&session_agent, listen_fd);
        reapSessions(&session_agent);
        stopSessionAgentIfComplete(&session_agent);
    }
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

fn sessionAgentPollOnce(session_agent: *SessionAgent, listen_fd: c.fd_t) !void {
    var pollfds: [1 + max_sessions + max_attachments]posix.pollfd = undefined;
    var kinds: [1 + max_sessions + max_attachments]PollKind = undefined;
    var count: usize = 0;

    pollfds[count] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
    kinds[count] = .listen;
    count += 1;

    for (&session_agent.sessions, 0..) |*session, i| {
        if (!session.alive) continue;
        pollfds[count] = .{ .fd = session.pty_fd, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .{ .session = i };
        count += 1;
    }

    for (&session_agent.attachments, 0..) |*attachment, i| {
        if (!attachment.active) continue;
        var events: i16 = if (attachment.close_after_flush) 0 else posix.POLL.IN;
        if (attachment.queuedBytes() > 0) events |= posix.POLL.OUT;
        pollfds[count] = .{ .fd = attachment.fd, .events = events, .revents = 0 };
        kinds[count] = .{ .attachment = i };
        count += 1;
    }

    _ = try posix.poll(pollfds[0..count], -1);

    for (pollfds[0..count], kinds[0..count]) |pollfd, kind| {
        if (pollfd.revents == 0) continue;
        switch (kind) {
            .listen => acceptSessionAgentClient(session_agent, listen_fd),
            .session => |session_index| drainSessionOutput(session_agent, session_index),
            .attachment => |attachment_index| handleAttachmentEvents(session_agent, attachment_index, pollfd.revents),
        }
    }
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
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_RESIZE => continue,
                .FRAME_TYPE_BROKER_COMMAND_REQUEST => return try handleCommandRequest(session_agent, fd, frame.payload),
                .FRAME_TYPE_SESSION_NEW => {
                    var request = readSessionNewRequest(frame.payload) catch {
                        try sendError(session_agent, fd, "PROTOCOL_ERROR", "invalid SESSION_NEW payload", "");
                        return false;
                    };
                    defer request.deinit();
                    const session_index = try createSession(
                        session_agent,
                        request.resize.rows,
                        request.resize.cols,
                        request.scrollback_row_count,
                        request.environment,
                        request.query_default_colors,
                    );
                    try attachSession(session_agent, session_index, fd, request.resize);
                    return true;
                },
                .FRAME_TYPE_SESSION_ATTACH => {
                    const request = try readAttachRequest(frame.payload);
                    const session_index = findMostRecentSessionIndex(session_agent);
                    const resolved_session_index = session_index orelse {
                        try sendError(session_agent, fd, "SESSION_NOT_FOUND", "session not found", "");
                        return false;
                    };
                    updateSessionSize(&session_agent.sessions[resolved_session_index], request.resize.rows, request.resize.cols);
                    try attachSession(session_agent, resolved_session_index, fd, request.resize);
                    return true;
                },
                else => {
                    try sendError(session_agent, fd, "PROTOCOL_ERROR", "unexpected first action", "");
                    return false;
                },
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn handleCommandRequest(session_agent: *SessionAgent, fd: c.fd_t, payload: []const u8) !bool {
    var request = try protocol.decodeBrokerCommandRequest(app_allocator.allocator(), payload);
    defer request.deinit(app_allocator.allocator());
    if (request.argv.len > 8) {
        try sendCommandResponse(fd, 64, "", "ERROR too many command arguments\n");
        return false;
    }
    const argv = request.argv;
    const argc = argv.len;
    if (argc == 0) {
        try sendCommandResponse(fd, 64, "", "ERROR missing command\n");
        return false;
    }

    const command = argv[0];
    if (std.mem.eql(u8, command, "list")) {
        if (argc != 1) {
            try sendCommandResponse(fd, 64, "", "ERROR usage: list\n");
            return false;
        }
        try sendListCommandResponse(fd, session_agent);
        return false;
    }
    if (std.mem.eql(u8, command, "kill")) {
        if (argc != 2) {
            try sendCommandResponse(fd, 64, "", "ERROR usage: kill ID\n");
            return false;
        }
        return try handleKillCommand(session_agent, fd, argv[1]);
    }
    if (std.mem.eql(u8, command, "kill-all")) {
        if (argc != 1) {
            try sendCommandResponse(fd, 64, "", "ERROR usage: kill-all\n");
            return false;
        }
        try handleKillAllCommand(session_agent, fd);
        return false;
    }

    try sendCommandResponse(fd, 64, "", "ERROR unknown command\n");
    return false;
}

fn handleKillCommand(session_agent: *SessionAgent, fd: c.fd_t, id: []const u8) !bool {
    const session_index = findSessionIndex(session_agent, id) orelse {
        logSessionAgent(session_agent, "event=error code=SESSION_NOT_FOUND message=session not found", .{});
        try sendCommandResponse(fd, 1, "", "ERROR session not found\n");
        return false;
    };
    const session = &session_agent.sessions[session_index];
    if (session.kill_waiter_fd >= 0) {
        try sendCommandResponse(fd, 1, "", "ERROR session kill already in progress\n");
        return false;
    }
    if (!signalSession(session, 0)) {
        try sendCommandResponse(fd, 1, "", "ERROR failed to signal session process\n");
        return false;
    }
    session.end_reason = 1;
    logSessionAgent(session_agent, "event=session_kill_requested id={s} signal=0", .{session.idSlice()});
    session.kill_waiter_fd = fd;
    return true;
}

fn handleKillAllCommand(session_agent: *SessionAgent, fd: c.fd_t) !void {
    logSessionAgent(session_agent, "event=session_agent_stop_requested", .{});
    for (&session_agent.sessions) |*session| {
        if (!session.alive) continue;
        posix.kill(session.pid, c.SIG.TERM) catch {};
    }
    for (0..session_agent.sessions.len) |i| {
        if (session_agent.sessions[i].alive) endSession(session_agent, i, 2, .{});
    }
    try sendCommandResponse(fd, 0, "KILLING_ALL\n", "");
    session_agent.running = false;
}

fn openSessionAgentLog(session_agent: *SessionAgent, socket_path: []const u8) !void {
    const log_path = try sessionAgentLogPath(app_allocator.allocator(), socket_path);
    defer app_allocator.allocator().free(log_path);
    session_agent.log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true });
}

fn sessionAgentLogPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, socket_path, '/') orelse return error.InvalidSocketPath;
    return std.fmt.allocPrint(allocator, "{s}/agent.log", .{socket_path[0..slash]});
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
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_REQUEST => return protocol.decodePayload(hpb.HelloRequest, app_allocator.allocator(), frame.payload),
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => {
                    try sendHelloError(fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                    return error.UnexpectedFrame;
                },
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn readHelloReply(fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_OK => {
                    var ok = try protocol.decodePayload(hpb.HelloOk, app_allocator.allocator(), frame.payload);
                    defer ok.deinit(app_allocator.allocator());
                    return null;
                },
                .FRAME_TYPE_HELLO_ERROR => {
                    const err = try protocol.decodePayload(hpb.HelloError, app_allocator.allocator(), frame.payload);
                    return err;
                },
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return hello.protocol_major == config.protocol_major and
        hello.protocol_minor >= config.protocol_minor and
        std.mem.eql(u8, hello.version, config.version);
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_REQUEST, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_OK, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_ERROR, payload);
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
    try protocol.sendFrame(fd, .FRAME_TYPE_ERROR, payload);
}

fn sendUnrecognizedFrame(fd: c.fd_t, seq: u64, frame_type: u32) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.UnrecognizedFrame{
        .seq = seq,
        .frame_type = frame_type,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_UNRECOGNIZED, payload);
}

fn queueAttachmentError(session_agent: *SessionAgent, attachment: *Attachment, code: []const u8, message: []const u8, hint: []const u8) !void {
    logSessionAgent(session_agent, "event=error code={s} message={s}", .{ code, message });
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .FRAME_TYPE_ERROR, payload);
}

fn queueAttachmentUnrecognized(attachment: *Attachment, seq: u64, frame_type: u32) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.UnrecognizedFrame{
        .seq = seq,
        .frame_type = frame_type,
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .FRAME_TYPE_UNRECOGNIZED, payload);
}

fn sendCommandResponse(fd: c.fd_t, exit_status: u8, stdout: []const u8, stderr: []const u8) !void {
    const payload = try protocol.encodeBrokerCommandResponse(app_allocator.allocator(), exit_status, stdout, stderr);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_BROKER_COMMAND_RESPONSE, payload);
}

fn queueAttachmentFrame(attachment: *Attachment, message_type: protocol.MessageType, payload: []const u8) !void {
    const header = try protocol.frameHeader(message_type, payload.len);
    const frame_len = header.len + payload.len;
    if (frame_len > max_attachment_output_queue_bytes or
        attachment.queuedBytes() > max_attachment_output_queue_bytes - frame_len)
    {
        return error.AttachmentOutputQueueFull;
    }

    compactAttachmentOutput(attachment);
    try attachment.output.appendSlice(app_allocator.allocator(), &header);
    try attachment.output.appendSlice(app_allocator.allocator(), payload);
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

fn sendListCommandResponse(fd: c.fd_t, session_agent: *SessionAgent) !void {
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout = CommandOutput{ .buf = &stdout_buf };
    try stdout.append("ID\tATTACHED\tPID\n");
    for (&session_agent.sessions, 0..) |*session, session_index| {
        if (!session.alive) continue;
        try stdout.print("{s}\t{s}\t{}\n", .{
            session.idSlice(),
            if (attachedCount(session_agent, session_index) > 0) "yes" else "no",
            session.pid,
        });
    }
    try sendCommandResponse(fd, 0, stdout.written(), "");
}

fn attachedCount(session_agent: *SessionAgent, session_index: usize) u32 {
    var count: u32 = 0;
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active and attachment.session_index == session_index) count += 1;
    }
    return count;
}

fn sendSessionAttached(attachment: *Attachment) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.SessionAttached{});
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .FRAME_TYPE_SESSION_ATTACHED, payload);
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
    try queueAttachmentFrame(attachment, .FRAME_TYPE_SESSION_ENDED, payload);
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
    try queueAttachmentFrame(attachment, .FRAME_TYPE_DRAW, payload);
}

fn appendDrawCleanup(draw_bytes: *std.ArrayList(u8)) !void {
    const renderer = client_renderer.Renderer.buffered(draw_bytes, .{ .kind = .xterm_compatible });
    try renderer.restoreBannerPresentation();
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
    const effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, align_viewport);
    try attachment.presentation.appendScrollbackRows(renderer, session.rows, rows);
    try attachment.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    try appendDrawCleanup(&bytes);
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
    const effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, align_viewport);
    try attachment.presentation.applyScreen(renderer, session.rows, screen, force_redraw, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    if (bytes.items.len > 0) {
        try appendDrawCleanup(&bytes);
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
    try queueDrawFrame(attachment, session, 0, bytes.items, null);
}

fn queueRepaintResponseFrame(
    attachment: *Attachment,
    session: *const Session,
    request_id: u64,
    scrollback_cursor: u64,
    draw_bytes: []const u8,
    relay_end_restore_bytes: ?[]const u8,
) !void {
    var encoded_cursor: [encoded_scrollback_cursor_len]u8 = undefined;
    encodeScrollbackCursor(&encoded_cursor, session.scrollback_epoch, scrollback_cursor);
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintResponse{
        .id = request_id,
        .draw = .{
            .scrollback_cursor = encoded_cursor[0..],
            .viewport_offset = attachment.presentation.protocolViewportOffset(),
            .draw_bytes = draw_bytes,
            .relay_end_restore_bytes = relay_end_restore_bytes,
        },
    });
    defer app_allocator.allocator().free(payload);
    try queueAttachmentFrame(attachment, .FRAME_TYPE_REPAINT_RESPONSE, payload);
}

fn queueRepaintResponseDraw(
    attachment: *Attachment,
    session: *Session,
    request_id: u64,
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
        try renderer.clearForReplace();
        attachment.presentation.reset();
    }
    if (truncated_rows > 0) try appendScrollbackTruncatedMarker(&bytes, renderer, truncated_rows);
    try attachment.presentation.appendScrollbackRows(renderer, session.rows, rows);
    const effective_align_viewport = shouldAlignViewportForDraw(attachment, screen, false);
    try attachment.presentation.applyScreen(renderer, session.rows, screen, true, effective_align_viewport);
    if (effective_align_viewport) attachment.origin = .{ .row = 0, .col = 0 };
    updateMouseOriginAfterDraw(attachment, screen);
    try appendDrawCleanup(&bytes);
    var restore_bytes = std.ArrayList(u8).empty;
    defer restore_bytes.deinit(app_allocator.allocator());
    const restore = try appendRelayEndRestoreBytes(attachment, session, screen, restore_screen, &restore_bytes);
    try queueRepaintResponseFrame(attachment, session, request_id, scrollback_cursor, bytes.items, restore);
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
            request.id,
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
            attachment,
            session,
            request.id,
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

fn signalSession(session: *const Session, signal_number: u8) bool {
    if (signal_number == 0) {
        var sent = false;
        sent = signalPidOrGroup(session.pid, c.SIG.HUP) or sent;
        sent = signalPidOrGroup(session.pid, c.SIG.TERM) or sent;
        return sent;
    }
    return signalPidOrGroup(session.pid, signal_number);
}

fn signalPidOrGroup(pid: c.pid_t, signal: u8) bool {
    var sent = false;
    if (posix.kill(-pid, signal)) {
        sent = true;
    } else |_| {}
    if (posix.kill(pid, signal)) {
        sent = true;
    } else |_| {}
    return sent;
}

fn readSessionNewRequest(payload: []const u8) !SessionNewRequest {
    var message = try protocol.decodePayload(pb.SessionNew, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    const resize = message.resize orelse return error.MissingResize;
    var environment = SessionEnvironment{};
    errdefer environment.deinit();
    var query_default_colors = vt.DefaultColors{};

    for (message.environment.items) |entry| {
        try applySessionEnvironmentEntry(&environment, entry);
    }
    if (message.query_default_colors) |colors| {
        query_default_colors = try readDefaultColors(colors);
    }

    return .{
        .resize = try resizePayloadFromMessage(resize),
        .scrollback_row_count = message.scrollback_row_limit,
        .environment = environment,
        .query_default_colors = query_default_colors,
    };
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
    return .{
        .resize = try resizePayloadFromMessage(resize),
    };
}

fn readRepaintRequest(payload: []const u8) !RepaintRequest {
    var message = try protocol.decodePayload(pb.RepaintRequest, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return repaintRequestFromMessage(message);
}

fn repaintRequestFromMessage(message: pb.RepaintRequest) !RepaintRequest {
    return .{
        .id = message.id,
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

        var id_buf: [64]u8 = undefined;
        const id = if (session_agent.fixed_session_id) |fixed_session_id|
            try std.fmt.bufPrint(&id_buf, "{s}", .{fixed_session_id})
        else
            try std.fmt.bufPrint(&id_buf, "s{}", .{session_agent.next_id});
        const session_id_z = try app_allocator.allocator().dupeZ(u8, id);
        defer app_allocator.allocator().free(session_id_z);

        const shell_path = session_environment.shell orelse defaultShellPath();
        const shell_z = try app_allocator.allocator().dupeZ(u8, shell_path);
        defer app_allocator.allocator().free(shell_z);
        const shell_argv0 = try loginShellArg0(app_allocator.allocator(), shell_path);
        defer app_allocator.allocator().free(shell_argv0);

        var master: c_int = -1;
        var size = c.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        const pid = forkpty(&master, null, null, &size);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            terminal.setSigpipe(posix.SIG.DFL);
            _ = setenv("TERM", "xterm-256color", 1);
            _ = setenv("SHELL", shell_z.ptr, 1);
            _ = setenv("SESSH_ID", session_id_z.ptr, 1);
            const dash_i: [*:0]const u8 = "-i";
            var child_argv = [_:null]?[*:0]const u8{ shell_argv0.ptr, dash_i };
            _ = c.execve(shell_z.ptr, &child_argv, @ptrCast(c.environ));
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
        @memcpy(session.id[0..id.len], id);
        session.id_len = id.len;
        session_agent.started_session = true;
        if (session_agent.fixed_session_id == null) session_agent.next_id += 1;
        logSessionAgent(session_agent, "event=session_create id={s} pid={} rows={} cols={} scrollback_rows={} shell={s}", .{
            session.idSlice(),
            pid,
            rows,
            cols,
            scrollback_row_count,
            shell_path,
        });
        return session_index;
    }
    return error.TooManySessions;
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
) !void {
    const session = &session_agent.sessions[session_index];

    for (&session_agent.attachments, 0..) |*attachment, attachment_index| {
        if (attachment.active) continue;
        attachment.* = .{
            .fd = client_fd,
            .session_index = session_index,
            .rows = resize.rows,
            .cols = resize.cols,
            .active = true,
        };
        attachment.presentation.setViewportOffset(resize.viewport_offset);
        errdefer {
            attachment.output.deinit(app_allocator.allocator());
            attachment.* = Attachment{};
        }
        try sendSessionAttached(attachment);
        if (resize.repaint_request) |request| {
            try sendSessionRepaintSnapshot(attachment, session, request);
        } else {
            try sendSessionSnapshot(attachment, session);
        }
        refreshAttachedFlag(session_agent, session_index);
        logSessionAgent(session_agent, "event=attach id={s} rows={} cols={} attachments={}", .{
            session.idSlice(),
            resize.rows,
            resize.cols,
            attachedCount(session_agent, session_index),
        });
        flushAttachmentOutput(session_agent, attachment_index);
        return;
    }

    return error.TooManyAttachments;
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
    broadcastSessionPatch(session_agent, session_index);
    session_agent.sessions[session_index].clearPendingPlainOutput();
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
        .known => |message_type| switch (message_type) {
            .FRAME_TYPE_INPUT => handleInputFrame(session_agent, attachment_index, frame.payload),
            .FRAME_TYPE_RESIZE => handleResizeFrame(session_agent, attachment_index, frame.payload),
            .FRAME_TYPE_REPAINT => handleRepaintFrame(session_agent, attachment_index, frame.payload),
            .FRAME_TYPE_PING_REQUEST => handlePingRequestFrame(session_agent, attachment_index, frame.seq, frame.payload),
            .FRAME_TYPE_UNRECOGNIZED => {},
            else => {
                queueAttachmentError(session_agent, attachment, "PROTOCOL_ERROR", "unexpected attached message", "") catch {
                    detachAttachment(session_agent, attachment_index);
                    return;
                };
                closeAttachmentAfterFlush(session_agent, attachment_index);
            },
        },
        .unknown => |raw| {
            queueAttachmentUnrecognized(attachment, frame.seq, raw) catch {
                detachAttachment(session_agent, attachment_index);
                return;
            };
            flushAttachmentOutput(session_agent, attachment_index);
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

    if (session.rows != attachment.rows or session.cols != attachment.cols) {
        updateSessionSize(session, attachment.rows, attachment.cols);
    }

    var translated = std.ArrayList(u8).empty;
    defer translated.deinit(app_allocator.allocator());
    translateAttachmentInput(attachment, session, input.data, &translated) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    if (translated.items.len == 0) return;

    io.writeAll(session.pty_fd, translated.items) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
}

fn handlePingRequestFrame(session_agent: *SessionAgent, attachment_index: usize, request_seq_number: u64, payload: []const u8) void {
    const attachment = &session_agent.attachments[attachment_index];
    var request = protocol.decodePayload(pb.PingRequest, app_allocator.allocator(), payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer request.deinit(app_allocator.allocator());

    const response_payload = protocol.encodePayload(app_allocator.allocator(), pb.PingResponse{ .request_seq_number = request_seq_number }) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    defer app_allocator.allocator().free(response_payload);
    queueAttachmentFrame(attachment, .FRAME_TYPE_PING_RESPONSE, response_payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    flushAttachmentOutput(session_agent, attachment_index);
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

        if (!attachmentSgrMouseActive(attachment)) {
            try out.append(app_allocator.allocator(), input.items[index]);
            index += 1;
            continue;
        }

        switch (parseSgrMouseReport(input.items, index)) {
            .complete => |report| {
                try appendTranslatedSgrMouseReport(attachment, session, report, out);
                index = report.end;
            },
            .incomplete => {
                const pending = input.items[index..];
                if (pending.len <= attachment.input_pending.len) {
                    @memcpy(attachment.input_pending[0..pending.len], pending);
                    attachment.input_pending_len = pending.len;
                } else {
                    try out.appendSlice(app_allocator.allocator(), pending);
                }
                return;
            },
            .not_mouse => {
                try out.append(app_allocator.allocator(), input.items[index]);
                index += 1;
            },
        }
    }
}

fn attachmentLocalInputParserActive(attachment: *const Attachment) bool {
    return attachmentSgrMouseActive(attachment);
}

fn attachmentSgrMouseActive(attachment: *const Attachment) bool {
    return attachment.presentation.terminal_modes_initialized and
        attachment.presentation.terminal_modes.mouse_tracking != .disabled and
        attachment.presentation.terminal_modes.mouse_sgr;
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

fn handleResizeFrame(session_agent: *SessionAgent, attachment_index: usize, payload: []const u8) void {
    const attachment = &session_agent.attachments[attachment_index];
    const session = &session_agent.sessions[attachment.session_index];
    const resize = readResizePayload(payload) catch {
        detachAttachment(session_agent, attachment_index);
        return;
    };
    attachment.rows = resize.rows;
    attachment.cols = resize.cols;
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

    const was_attached = session_agent.sessions[session_index].attached;
    var now_attached = false;
    for (&session_agent.attachments) |*attachment| {
        if (attachment.active and attachment.session_index == session_index) {
            now_attached = true;
            break;
        }
    }
    session_agent.sessions[session_index].attached = now_attached;
    updateDetachedHint(session_agent, was_attached, now_attached);
}

fn endSession(session_agent: *SessionAgent, session_index: usize, reason: u8, exit_info: ExitInfo) void {
    const session = &session_agent.sessions[session_index];
    if (!session.alive) return;

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
    if (session.kill_waiter_fd >= 0) {
        var stdout_buf: [128]u8 = undefined;
        var stdout = CommandOutput{ .buf = &stdout_buf };
        stdout.print("ENDED {s}\n", .{session.idSlice()}) catch {};
        sendCommandResponse(session.kill_waiter_fd, 0, stdout.written(), "") catch {};
        _ = c.close(session.kill_waiter_fd);
        session.kill_waiter_fd = -1;
    }
    if (session.pty_fd >= 0) _ = c.close(session.pty_fd);
    if (session.terminal_model) |model| {
        model.destroy();
        session.terminal_model = null;
    }
    clearDetachedHint(session_agent);
    session.deinit();
    session.alive = false;
    session.attached = false;
}

fn updateDetachedHint(session_agent: *SessionAgent, was_attached: bool, now_attached: bool) void {
    if (session_agent.session_paths == null) return;
    if (!was_attached and now_attached) {
        session_registry.markAttached(session_agent.session_paths.?) catch {};
    } else if (was_attached and !now_attached) {
        session_registry.markDetached(session_agent.session_paths.?) catch {};
    }
}

fn clearDetachedHint(session_agent: *SessionAgent) void {
    if (session_agent.session_paths) |paths| session_registry.markAttached(paths) catch {};
}

fn stopSessionAgentIfComplete(session_agent: *SessionAgent) void {
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

fn findMostRecentSessionIndex(session_agent: *SessionAgent) ?usize {
    var selected: ?usize = null;
    var selected_number: usize = 0;
    for (&session_agent.sessions, 0..) |*session, i| {
        if (!session.alive) continue;
        const id = session.idSlice();
        if (id.len < 2 or id[0] != 's') continue;
        const number = std.fmt.parseInt(usize, id[1..], 10) catch continue;
        if (selected == null or number > selected_number) {
            selected = i;
            selected_number = number;
        }
    }
    return selected;
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
    var status: c_int = 0;
    const result = c.waitpid(session_agent.sessions[session_index].pid, &status, 1);
    if (result == session_agent.sessions[session_index].pid) {
        endSession(session_agent, session_index, session_agent.sessions[session_index].end_reason, exitInfoFromWaitStatus(status));
        return;
    }
    endSession(session_agent, session_index, session_agent.sessions[session_index].end_reason, .{ .ended_at_unix_ms = nowUnixMs() });
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
