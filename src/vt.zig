const std = @import("std");
const config = @import("config.zig");
const ghostty_vt = @import("ghostty-vt");

/// Boundary module for Ghostty's terminal emulator. Keep upstream API usage
/// concentrated here as we learn which state the session agent needs to serialize.
pub const Terminal = ghostty_vt.Terminal;
pub const RenderState = ghostty_vt.RenderState;
const TerminalStream = ghostty_vt.Stream(ModelTrackingHandler);

pub const DirtyState = enum {
    none,
    partial,
    full,
};

pub const DisplayClearMode = enum(u8) {
    below = 0,
    above = 1,
    complete = 2,
};

pub const DisplayClear = struct {
    mode: DisplayClearMode,
    cursor_row: u16,
    cursor_col: u16,
    protected: bool,
};

pub const PlainSnapshot = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_style: u8,
    text: []const u8,
};

pub const RenderedRow = struct {
    cells: []RenderedCell,
    width_cols: u16,
    flags: u16,
    dirty: bool = false,

    pub fn deinit(self: *RenderedRow, allocator: std.mem.Allocator) void {
        for (self.cells) |cell| cell.deinit(allocator);
        if (self.cells.len > 0) allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const RenderedCell = struct {
    text: []const u8,
    display_width: u8,
    attrs: CellAttrs,
    hyperlink: ?[]const u8 = null,

    pub fn deinit(self: RenderedCell, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.hyperlink) |uri| allocator.free(uri);
    }
};

pub const CellAttrs = struct {
    style_flags: u32 = 0,
    fg_color: u32 = default_color,
    bg_color: u32 = default_color,
    underline_color: u32 = default_color,

    pub const default_color: u32 = 0xffffffff;

    pub fn eql(self: CellAttrs, other: CellAttrs) bool {
        return self.style_flags == other.style_flags and
            self.fg_color == other.fg_color and
            self.bg_color == other.bg_color and
            self.underline_color == other.underline_color;
    }
};

pub const TerminalModes = struct {
    mode_flags: u32 = 0,
    mouse_tracking: u8 = 0,
    mouse_sgr: bool = false,

    pub const insert_mode: u32 = 1 << 0;
    pub const origin_mode: u32 = 1 << 1;
    pub const auto_wrap: u32 = 1 << 2;
    pub const application_cursor_keys: u32 = 1 << 3;
    pub const focus_reporting: u32 = 1 << 4;
    pub const bracketed_paste: u32 = 1 << 5;

    pub fn eql(self: TerminalModes, other: TerminalModes) bool {
        return self.mode_flags == other.mode_flags and
            self.mouse_tracking == other.mouse_tracking and
            self.mouse_sgr == other.mouse_sgr;
    }
};

pub const DefaultColors = struct {
    foreground_color: u32 = CellAttrs.default_color,
    background_color: u32 = CellAttrs.default_color,

    pub fn eql(self: DefaultColors, other: DefaultColors) bool {
        return self.foreground_color == other.foreground_color and
            self.background_color == other.background_color;
    }
};

pub const RenderedScreen = struct {
    rows: []RenderedRow,
    cols: u16,
    active_screen: u8,
    title: []const u8,
    title_dirty: bool,
    default_colors: DefaultColors,
    default_colors_dirty: bool,
    retained_scrollback_clear_dirty: bool,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_style: u8,
    modes: TerminalModes,
    dirty_state: DirtyState,
    active_screen_changed: bool,
    display_clear: ?DisplayClear,

    pub fn deinit(self: *RenderedScreen, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const ScrollbackSnapshot = struct {
    rows: []RenderedRow,
    truncated_rows: u64,
    absolute_count: u64,

    pub fn deinit(self: *ScrollbackSnapshot, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const SessionTerminal = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    stream: TerminalStream,
    dcs_handler: ghostty_vt.dcs.Handler = .{},
    render_state: RenderState,
    scrollback_row_limit: u32,
    reported_history_rows: u64 = 0,
    synthetic_history_rows: std.ArrayList(RenderedRow) = .empty,
    reported_synthetic_history_rows: usize = 0,
    synthetic_history_real_rows: u64 = 0,
    pending_input_responses: std.ArrayList(u8) = .empty,
    rendered_row_count: u16 = 0,
    rendered_active_screen: u8 = 0,
    rendered_cursor_row: u16 = 0,
    rendered_cursor_col: u16 = 0,
    rendered_cursor_visible: bool = true,
    rendered_cursor_style: u8 = 0,
    rendered_modes: TerminalModes = .{},
    rendered_default_colors: DefaultColors = .{},
    query_default_colors: DefaultColors = .{},
    default_colors: DefaultColors = .{},
    default_colors_dirty: bool = false,
    title: ?[]u8 = null,
    title_dirty: bool = false,
    retained_scrollback_clear_dirty: bool = false,
    display_clear: ?DisplayClear = null,

    pub fn create(allocator: std.mem.Allocator, rows: u16, cols: u16, scrollback_rows: u32) !*SessionTerminal {
        return createWithDefaultColors(allocator, rows, cols, scrollback_rows, .{});
    }

    pub fn createWithDefaultColors(
        allocator: std.mem.Allocator,
        rows: u16,
        cols: u16,
        scrollback_rows: u32,
        query_default_colors: DefaultColors,
    ) !*SessionTerminal {
        const self = try allocator.create(SessionTerminal);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.terminal = try .init(allocator, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = scrollbackByteLimit(scrollback_rows, cols),
            // Match Ghostty's Unicode grapheme-width default; bare
            // libghostty-vt leaves mode 2027 off unless the embedder enables it.
            .default_modes = .{ .grapheme_cluster = true },
        });
        errdefer self.terminal.deinit(allocator);

        self.stream = .initAlloc(allocator, .{
            .readonly = self.terminal.vtHandler(),
            .session = self,
        });
        self.dcs_handler = .{};
        self.render_state = .empty;
        self.scrollback_row_limit = scrollback_rows;
        self.reported_history_rows = 0;
        self.synthetic_history_rows = .empty;
        self.reported_synthetic_history_rows = 0;
        self.synthetic_history_real_rows = 0;
        self.pending_input_responses = .empty;
        self.rendered_row_count = 0;
        self.rendered_active_screen = 0;
        self.rendered_cursor_row = 0;
        self.rendered_cursor_col = 0;
        self.rendered_cursor_visible = true;
        self.rendered_cursor_style = 0;
        self.rendered_modes = .{};
        self.rendered_default_colors = .{};
        self.query_default_colors = query_default_colors;
        self.default_colors = .{};
        self.default_colors_dirty = false;
        self.title = null;
        self.title_dirty = false;
        self.retained_scrollback_clear_dirty = false;
        self.display_clear = null;
        return self;
    }

    pub fn destroy(self: *SessionTerminal) void {
        const allocator = self.allocator;
        if (self.title) |title| allocator.free(title);
        self.clearSyntheticHistory();
        self.pending_input_responses.deinit(allocator);
        self.dcs_handler.deinit();
        self.stream.deinit();
        self.render_state.deinit(allocator);
        self.terminal.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn feed(self: *SessionTerminal, bytes: []const u8) !void {
        try self.stream.nextSlice(bytes);
    }

    pub fn isPlainTextParserBoundary(self: *const SessionTerminal) bool {
        return self.stream.parser.state == .ground and self.stream.utf8decoder.state == 0;
    }

    pub fn pendingInputResponses(self: *const SessionTerminal) []const u8 {
        return self.pending_input_responses.items;
    }

    pub fn clearPendingInputResponses(self: *SessionTerminal) void {
        self.pending_input_responses.clearRetainingCapacity();
    }

    pub fn resize(self: *SessionTerminal, rows: u16, cols: u16) !void {
        try self.terminal.resize(self.allocator, cols, rows);
    }

    pub fn renderedScreen(self: *SessionTerminal, allocator: std.mem.Allocator) !RenderedScreen {
        try self.render_state.update(self.allocator, &self.terminal);
        return try self.renderedScreenFromState(
            allocator,
            &self.render_state,
            renderDirtyState(self.render_state.dirty),
            self.rendered_active_screen != self.activeScreenId(),
        );
    }

    pub fn renderedPrimaryScreen(self: *SessionTerminal, allocator: std.mem.Allocator) !RenderedScreen {
        const old_key = self.terminal.screens.active_key;
        if (old_key != .primary) self.terminal.screens.switchTo(.primary);
        defer if (self.terminal.screens.active_key != old_key) self.terminal.screens.switchTo(old_key);

        var state: RenderState = .empty;
        defer state.deinit(self.allocator);
        try state.update(self.allocator, &self.terminal);
        return try self.renderedScreenFromState(allocator, &state, .full, true);
    }

    fn renderedScreenFromState(
        self: *SessionTerminal,
        allocator: std.mem.Allocator,
        state: *RenderState,
        dirty_state_in: DirtyState,
        active_screen_changed: bool,
    ) !RenderedScreen {
        const row_data = state.row_data.slice();
        const row_pins = row_data.items(.pin);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_dirties = row_data.items(.dirty);
        const row_count = trimmedRowCount(row_cells);
        const rows = try allocator.alloc(RenderedRow, row_count);
        var rows_filled: usize = 0;
        errdefer {
            for (rows[0..rows_filled]) |*row| row.deinit(allocator);
            allocator.free(rows);
        }

        while (rows_filled < row_count) : (rows_filled += 1) {
            rows[rows_filled] = .{
                .cells = try rowCellsAlloc(
                    allocator,
                    row_cells[rows_filled],
                    row_pins[rows_filled],
                ),
                .width_cols = @intCast(self.render_state.cols),
                .flags = rowFlags(row_rows[rows_filled]),
                .dirty = row_dirties[rows_filled],
            };
        }

        const active_screen = self.activeScreenId();
        const cursor_row: u16 = @intCast(self.terminal.screens.active.cursor.y);
        const cursor_col: u16 = @intCast(self.terminal.screens.active.cursor.x);
        const cursor_visible = state.cursor.visible;
        const cursor_style = cursorStyleValue(&self.terminal);
        const modes = self.terminalModes();

        var dirty_state = dirty_state_in;
        if (row_count != self.rendered_row_count and dirty_state == .none) {
            dirty_state = .full;
        } else if (row_count < self.rendered_row_count and dirty_state == .partial) {
            dirty_state = .full;
        } else if (dirty_state == .none and self.renderedStateChanged(
            active_screen,
            cursor_row,
            cursor_col,
            cursor_visible,
            cursor_style,
            modes,
        )) {
            dirty_state = .partial;
        }

        return .{
            .rows = rows,
            .cols = @intCast(self.render_state.cols),
            .active_screen = active_screen,
            .title = self.titleSlice(),
            .title_dirty = self.title_dirty,
            .default_colors = self.default_colors,
            .default_colors_dirty = self.default_colors_dirty,
            .retained_scrollback_clear_dirty = self.retained_scrollback_clear_dirty,
            .cursor_row = cursor_row,
            .cursor_col = cursor_col,
            .cursor_visible = cursor_visible,
            .cursor_style = cursor_style,
            .modes = modes,
            .dirty_state = dirty_state,
            .active_screen_changed = active_screen_changed,
            .display_clear = self.display_clear,
        };
    }

    fn renderedStateChanged(
        self: *const SessionTerminal,
        active_screen: u8,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
        cursor_style: u8,
        modes: TerminalModes,
    ) bool {
        return self.rendered_active_screen != active_screen or
            self.rendered_cursor_row != cursor_row or
            self.rendered_cursor_col != cursor_col or
            self.rendered_cursor_visible != cursor_visible or
            self.rendered_cursor_style != cursor_style or
            !self.rendered_modes.eql(modes) or
            !self.rendered_default_colors.eql(self.default_colors);
    }

    pub fn activeScreenId(self: *const SessionTerminal) u8 {
        return switch (self.terminal.screens.active_key) {
            .primary => 0,
            .alternate => 1,
        };
    }

    pub fn terminalModes(self: *const SessionTerminal) TerminalModes {
        var mode_flags: u32 = 0;
        if (self.terminal.modes.get(.insert)) mode_flags |= TerminalModes.insert_mode;
        if (self.terminal.modes.get(.origin)) mode_flags |= TerminalModes.origin_mode;
        if (self.terminal.modes.get(.wraparound)) mode_flags |= TerminalModes.auto_wrap;
        if (self.terminal.modes.get(.cursor_keys)) mode_flags |= TerminalModes.application_cursor_keys;
        if (self.terminal.modes.get(.focus_event)) mode_flags |= TerminalModes.focus_reporting;
        if (self.terminal.modes.get(.bracketed_paste)) mode_flags |= TerminalModes.bracketed_paste;

        const mouse_tracking: u8 = if (self.terminal.modes.get(.mouse_event_any))
            3
        else if (self.terminal.modes.get(.mouse_event_button))
            2
        else if (self.terminal.modes.get(.mouse_event_normal))
            1
        else
            0;

        return .{
            .mode_flags = mode_flags,
            .mouse_tracking = mouse_tracking,
            .mouse_sgr = self.terminal.modes.get(.mouse_format_sgr),
        };
    }

    fn queueInputResponse(self: *SessionTerminal, bytes: []const u8) !void {
        try self.pending_input_responses.appendSlice(self.allocator, bytes);
    }

    fn queueInputResponseFmt(self: *SessionTerminal, comptime fmt: []const u8, args: anytype) !void {
        var buf: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buf, fmt, args);
        try self.queueInputResponse(bytes);
    }

    fn deviceAttributes(self: *SessionTerminal, req: ghostty_vt.DeviceAttributeReq) !void {
        switch (req) {
            // VT220-level response with color text. We do not advertise sixel or
            // clipboard access here because sessh has not modeled those yet.
            .primary => try self.queueInputResponse("\x1b[?62;22c"),
            .secondary => try self.queueInputResponse("\x1b[>1;10;0c"),
            else => {},
        }
    }

    fn deviceStatusReport(self: *SessionTerminal, req: ghostty_vt.device_status.Request) !void {
        switch (req) {
            .operating_status => try self.queueInputResponse("\x1b[0n"),
            .cursor_position => {
                const pos: struct { row: usize, col: usize } = if (self.terminal.modes.get(.origin)) .{
                    .row = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                    .col = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                } else .{
                    .row = self.terminal.screens.active.cursor.y,
                    .col = self.terminal.screens.active.cursor.x,
                };
                try self.queueInputResponseFmt("\x1b[{};{}R", .{ pos.row + 1, pos.col + 1 });
            },
            .color_scheme => {},
        }
    }

    fn requestMode(self: *SessionTerminal, mode: ghostty_vt.Mode) !void {
        const tag: ghostty_vt.modes.ModeTag = @bitCast(@intFromEnum(mode));
        const code: u8 = if (self.terminal.modes.get(mode)) 1 else 2;
        try self.queueInputResponseFmt("\x1b[{s}{};{}$y", .{
            if (tag.ansi) "" else "?",
            tag.value,
            code,
        });
    }

    fn requestModeUnknown(self: *SessionTerminal, mode_raw: u16, ansi: bool) !void {
        try self.queueInputResponseFmt("\x1b[{s}{};0$y", .{
            if (ansi) "" else "?",
            mode_raw,
        });
    }

    fn kittyKeyboardQuery(self: *SessionTerminal) !void {
        try self.queueInputResponseFmt("\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        });
    }

    fn sizeReport(self: *SessionTerminal, style: ghostty_vt.SizeReportStyle) !void {
        switch (style) {
            .csi_18_t => try self.queueInputResponseFmt("\x1b[8;{};{}t", .{
                self.terminal.rows,
                self.terminal.cols,
            }),
            else => {},
        }
    }

    fn reportXtversion(self: *SessionTerminal) !void {
        try self.queueInputResponseFmt("\x1bP>|sessh {s}\x1b\\", .{config.version});
    }

    fn dcsHook(self: *SessionTerminal, dcs: ghostty_vt.DCS) !void {
        var cmd = self.dcs_handler.hook(self.allocator, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsPut(self: *SessionTerminal, byte: u8) !void {
        var cmd = self.dcs_handler.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsUnhook(self: *SessionTerminal) !void {
        var cmd = self.dcs_handler.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *SessionTerminal, cmd: *ghostty_vt.dcs.Command) !void {
        const xtgettcap_term_name = "544E"; // TN
        const xtgettcap_color_count = "436F"; // Co
        const xtgettcap_rgb_bits = "524742"; // RGB

        switch (cmd.*) {
            .xtgettcap => |*gettcap| {
                while (gettcap.next()) |key| {
                    if (std.mem.eql(u8, key, xtgettcap_term_name)) {
                        try self.queueXtgettcapOk(key, "787465726D2D323536636F6C6F72");
                    } else if (std.mem.eql(u8, key, xtgettcap_color_count)) {
                        try self.queueXtgettcapOk(key, "323536");
                    } else if (std.mem.eql(u8, key, xtgettcap_rgb_bits)) {
                        try self.queueXtgettcapOk(key, "38");
                    } else {
                        try self.queueXtgettcapUnsupported(key);
                    }
                }
            },
            .decrqss => |decrqss_req| try self.decrqss(decrqss_req),
            .tmux => {},
        }
    }

    fn queueXtgettcapOk(self: *SessionTerminal, key: []const u8, value_hex: []const u8) !void {
        try self.pending_input_responses.appendSlice(self.allocator, "\x1bP1+r");
        try self.pending_input_responses.appendSlice(self.allocator, key);
        try self.pending_input_responses.append(self.allocator, '=');
        try self.pending_input_responses.appendSlice(self.allocator, value_hex);
        try self.pending_input_responses.appendSlice(self.allocator, "\x1b\\");
    }

    fn queueXtgettcapUnsupported(self: *SessionTerminal, key: []const u8) !void {
        try self.pending_input_responses.appendSlice(self.allocator, "\x1bP0+r");
        try self.pending_input_responses.appendSlice(self.allocator, key);
        try self.pending_input_responses.appendSlice(self.allocator, "\x1b\\");
    }

    fn decrqss(self: *SessionTerminal, req: ghostty_vt.dcs.Command.DECRQSS) !void {
        var response: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&response);
        const writer = stream.writer();
        const prefix_fmt = "\x1bP{}$r";
        const prefix_len = std.fmt.comptimePrint(prefix_fmt, .{0}).len;
        stream.pos = prefix_len;

        switch (req) {
            .none => {},
            .sgr => {
                const buf = try self.terminal.printAttributes(stream.buffer[stream.pos..]);
                stream.pos += buf.len;
                try writer.writeByte('m');
            },
            .decscusr => try writer.print("{} q", .{cursorStyleValue(&self.terminal)}),
            .decstbm => try writer.print("{};{}r", .{
                self.terminal.scrolling_region.top + 1,
                self.terminal.scrolling_region.bottom + 1,
            }),
            .decslrm => if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                try writer.print("{};{}s", .{
                    self.terminal.scrolling_region.left + 1,
                    self.terminal.scrolling_region.right + 1,
                });
            },
        }

        const valid = stream.pos > prefix_len;
        try writer.writeAll("\x1b\\");
        _ = try std.fmt.bufPrint(response[0..prefix_len], prefix_fmt, .{@intFromBool(valid)});
        try self.queueInputResponse(response[0..stream.pos]);
    }

    pub fn markRendered(self: *SessionTerminal, row_count: usize) void {
        self.render_state.dirty = .false;
        const row_data = self.render_state.row_data.slice();
        const row_dirties = row_data.items(.dirty);
        for (row_dirties) |*dirty| dirty.* = false;
        self.rendered_row_count = @intCast(row_count);
        self.rendered_active_screen = self.activeScreenId();
        self.rendered_cursor_row = @intCast(self.terminal.screens.active.cursor.y);
        self.rendered_cursor_col = @intCast(self.terminal.screens.active.cursor.x);
        self.rendered_cursor_visible = self.render_state.cursor.visible;
        self.rendered_cursor_style = cursorStyleValue(&self.terminal);
        self.rendered_modes = self.terminalModes();
        self.rendered_default_colors = self.default_colors;
        self.default_colors_dirty = false;
        self.title_dirty = false;
        self.retained_scrollback_clear_dirty = false;
        self.display_clear = null;
    }

    pub fn lastRenderedRowCount(self: *const SessionTerminal) u16 {
        return self.rendered_row_count;
    }

    pub fn scrollbackSnapshot(self: *SessionTerminal, allocator: std.mem.Allocator) !ScrollbackSnapshot {
        self.consumeSyntheticHistoryForRealScrollback();
        try self.discardSyntheticRedrawRows();
        const history_rows = self.historyRowCount();
        const retained_terminal_rows: usize = @intCast(@min(history_rows, self.scrollback_row_limit));
        const total_rows = retained_terminal_rows + self.synthetic_history_rows.items.len;
        const retained_rows = @min(total_rows, self.scrollback_row_limit);
        const terminal_skip_for_limit = total_rows - retained_rows;
        const skipped_terminal_rows = @min(terminal_skip_for_limit, retained_terminal_rows);
        const skipped_synthetic_rows = terminal_skip_for_limit - skipped_terminal_rows;
        const rows = try allocator.alloc(RenderedRow, retained_rows);
        var rows_filled: usize = 0;
        errdefer {
            for (rows[0..rows_filled]) |*row| row.deinit(allocator);
            allocator.free(rows);
        }

        const skip = history_rows - retained_terminal_rows + skipped_terminal_rows;
        var index: u64 = 0;
        var row_it = self.primaryScreen().pages.rowIterator(.right_down, .{ .history = .{} }, null);
        while (row_it.next()) |pin| : (index += 1) {
            if (index < skip) continue;
            rows[rows_filled] = try rowFromPinAlloc(allocator, pin);
            rows_filled += 1;
        }
        for (self.synthetic_history_rows.items[skipped_synthetic_rows..]) |row| {
            rows[rows_filled] = try cloneRowAlloc(allocator, row);
            rows_filled += 1;
        }

        return .{
            .rows = rows,
            .truncated_rows = skip + skipped_synthetic_rows,
            .absolute_count = history_rows + @as(u64, @intCast(self.synthetic_history_rows.items.len)),
        };
    }

    pub fn scrollbackDelta(self: *SessionTerminal, allocator: std.mem.Allocator) !ScrollbackSnapshot {
        self.consumeSyntheticHistoryForRealScrollback();
        try self.discardSyntheticRedrawRows();
        const history_rows = self.historyRowCount();
        // RIS and similar resets can rebuild libghostty's history behind our
        // reported cursor. Treat that as a fresh terminal-history stream.
        if (history_rows < self.reported_history_rows) self.reported_history_rows = 0;
        self.clampReportedSyntheticHistoryRows();
        const synthetic_new_rows = self.synthetic_history_rows.items[self.reported_synthetic_history_rows..];
        if (history_rows <= self.reported_history_rows and synthetic_new_rows.len == 0) {
            return .{
                .rows = try allocator.alloc(RenderedRow, 0),
                .truncated_rows = if (history_rows > self.scrollback_row_limit)
                    history_rows - self.scrollback_row_limit
                else
                    0,
                .absolute_count = history_rows + @as(u64, @intCast(self.synthetic_history_rows.items.len)),
            };
        }

        const first_retained = if (history_rows > self.scrollback_row_limit)
            history_rows - self.scrollback_row_limit
        else
            0;
        const start = @max(self.reported_history_rows, first_retained);
        const terminal_delta_rows: usize = @intCast(history_rows - start);
        const retained_rows = terminal_delta_rows + synthetic_new_rows.len;
        const rows = try allocator.alloc(RenderedRow, retained_rows);
        var rows_filled: usize = 0;
        errdefer {
            for (rows[0..rows_filled]) |*row| row.deinit(allocator);
            allocator.free(rows);
        }

        var index: u64 = 0;
        var row_it = self.primaryScreen().pages.rowIterator(.right_down, .{ .history = .{} }, null);
        while (row_it.next()) |pin| : (index += 1) {
            if (index < start) continue;
            rows[rows_filled] = try rowFromPinAlloc(allocator, pin);
            rows_filled += 1;
        }
        for (synthetic_new_rows) |row| {
            rows[rows_filled] = try cloneRowAlloc(allocator, row);
            rows_filled += 1;
        }

        return .{
            .rows = rows,
            .truncated_rows = first_retained,
            .absolute_count = history_rows + @as(u64, @intCast(self.synthetic_history_rows.items.len)),
        };
    }

    pub fn markScrollbackReported(self: *SessionTerminal) void {
        self.consumeSyntheticHistoryForRealScrollback();
        self.reported_history_rows = self.historyRowCount();
        self.clampReportedSyntheticHistoryRows();
        self.reported_synthetic_history_rows = self.synthetic_history_rows.items.len;
    }

    pub fn truncatedScrollbackRows(self: *SessionTerminal) u64 {
        const history_rows = self.historyRowCount();
        if (history_rows <= self.scrollback_row_limit) return 0;
        return history_rows - self.scrollback_row_limit;
    }

    pub fn scrollbackCursor(self: *SessionTerminal) !u64 {
        self.consumeSyntheticHistoryForRealScrollback();
        try self.discardSyntheticRedrawRows();
        return self.historyRowCount() + @as(u64, @intCast(self.synthetic_history_rows.items.len));
    }

    pub fn plainSnapshot(self: *SessionTerminal, allocator: std.mem.Allocator) !PlainSnapshot {
        const text = try self.terminal.screens.active.dumpStringAlloc(allocator, .{ .active = .{} });
        return .{
            .rows = @intCast(self.terminal.rows),
            .cols = @intCast(self.terminal.cols),
            .cursor_row = @intCast(self.terminal.screens.active.cursor.y),
            .cursor_col = @intCast(self.terminal.screens.active.cursor.x),
            .cursor_visible = self.terminal.modes.get(.cursor_visible),
            .cursor_style = cursorStyleValue(&self.terminal),
            .text = text,
        };
    }

    fn primaryScreen(self: *SessionTerminal) *ghostty_vt.Screen {
        return self.terminal.screens.get(.primary) orelse self.terminal.screens.active;
    }

    fn historyRowCount(self: *SessionTerminal) u64 {
        var count: u64 = 0;
        var row_it = self.primaryScreen().pages.rowIterator(.right_down, .{ .history = .{} }, null);
        while (row_it.next()) |_| count += 1;
        return count;
    }

    fn titleSlice(self: *const SessionTerminal) []const u8 {
        return self.title orelse "";
    }

    fn setTitleFromTerminal(self: *SessionTerminal, next_title: []const u8) !void {
        if (std.mem.eql(u8, self.titleSlice(), next_title)) return;
        const owned = try self.allocator.dupe(u8, next_title);
        if (self.title) |old| self.allocator.free(old);
        self.title = owned;
        self.title_dirty = true;
    }

    fn setDefaultForegroundColor(self: *SessionTerminal, color: u32) void {
        if (self.default_colors.foreground_color == color) return;
        self.default_colors.foreground_color = color;
        self.default_colors_dirty = true;
    }

    fn setDefaultBackgroundColor(self: *SessionTerminal, color: u32) void {
        if (self.default_colors.background_color == color) return;
        self.default_colors.background_color = color;
        self.default_colors_dirty = true;
    }

    fn setDefaultColor(self: *SessionTerminal, dynamic: ghostty_vt.color.Dynamic, color: u32) void {
        switch (dynamic) {
            .foreground => self.setDefaultForegroundColor(color),
            .background => self.setDefaultBackgroundColor(color),
            .cursor => if (terminalColorRgb(color)) |rgb| self.terminal.colors.cursor.set(rgb) else self.terminal.colors.cursor.reset(),
            else => {},
        }
    }

    fn resetDefaultColor(self: *SessionTerminal, dynamic: ghostty_vt.color.Dynamic) void {
        switch (dynamic) {
            .cursor => self.terminal.colors.cursor.reset(),
            else => self.setDefaultColor(dynamic, CellAttrs.default_color),
        }
    }

    fn colorOperation(self: *SessionTerminal, value: ghostty_vt.StreamAction.ColorOperation) !void {
        var it = value.requests.constIterator(0);
        while (it.next()) |request| {
            switch (request.*) {
                .set => |set| switch (set.target) {
                    .dynamic => |dynamic| self.setDefaultColor(dynamic, rgbTerminalColor(set.color)),
                    .palette => |idx| self.terminal.colors.palette.set(idx, set.color),
                    else => {},
                },
                .reset => |target| switch (target) {
                    .dynamic => |dynamic| self.resetDefaultColor(dynamic),
                    .palette => |idx| self.terminal.colors.palette.reset(idx),
                    else => {},
                },
                .query => |target| switch (target) {
                    .dynamic => |dynamic| try self.dynamicColorReport(dynamic, value.terminator),
                    .palette => |idx| try self.paletteColorReport(idx, value.terminator),
                    else => {},
                },
                else => {},
            }
        }
    }

    fn dynamicColorReport(self: *SessionTerminal, dynamic: ghostty_vt.color.Dynamic, terminator: ghostty_vt.osc.Terminator) !void {
        const modeled_color = switch (dynamic) {
            .foreground => self.default_colors.foreground_color,
            .background => self.default_colors.background_color,
            .cursor => if (self.terminal.colors.cursor.get()) |rgb| rgbTerminalColor(rgb) else CellAttrs.default_color,
            else => return,
        };
        const color = if (modeled_color != CellAttrs.default_color)
            modeled_color
        else switch (dynamic) {
            .foreground => self.query_default_colors.foreground_color,
            .background => self.query_default_colors.background_color,
            .cursor => self.query_default_colors.foreground_color,
            else => return,
        };
        const rgb = terminalColorRgb(color) orelse ghostty_vt.color.default[7];
        try self.queueDynamicColorReport(dynamic, rgb, terminator);
    }

    fn paletteColorReport(self: *SessionTerminal, idx: u8, terminator: ghostty_vt.osc.Terminator) !void {
        const rgb = self.terminal.colors.palette.current[idx];
        try self.queueInputResponseFmt("\x1b]4;{};rgb:{x:0>2}/{x:0>2}/{x:0>2}{s}", .{
            idx,
            rgb.r,
            rgb.g,
            rgb.b,
            oscTerminator(terminator),
        });
    }

    fn queueDynamicColorReport(
        self: *SessionTerminal,
        dynamic: ghostty_vt.color.Dynamic,
        rgb: ghostty_vt.color.RGB,
        terminator: ghostty_vt.osc.Terminator,
    ) !void {
        try self.queueInputResponseFmt("\x1b]{};rgb:{x:0>2}/{x:0>2}/{x:0>2}{s}", .{
            @intFromEnum(dynamic),
            rgb.r,
            rgb.g,
            rgb.b,
            oscTerminator(terminator),
        });
    }

    fn noteRetainedScrollbackCleared(self: *SessionTerminal) void {
        self.retained_scrollback_clear_dirty = true;
        self.reported_history_rows = 0;
        self.clearSyntheticHistory();
        self.reported_synthetic_history_rows = 0;
        self.synthetic_history_real_rows = 0;
    }

    fn noteFullReset(self: *SessionTerminal) void {
        self.noteRetainedScrollbackCleared();
        self.default_colors = .{};
        self.default_colors_dirty = true;
        self.display_clear = .{
            .mode = .complete,
            .cursor_row = @intCast(self.terminal.screens.active.cursor.y),
            .cursor_col = @intCast(self.terminal.screens.active.cursor.x),
            .protected = false,
        };
    }

    fn noteDisplayClear(self: *SessionTerminal, mode: DisplayClearMode, protected: bool) !void {
        if (mode == .above) return;
        if (self.rendered_row_count == 0) {
            self.consumeSyntheticHistoryForRealScrollback();
            try self.captureDisplayClearRowsForSyntheticHistory(mode);
            self.synthetic_history_real_rows = self.historyRowCount();
        }
        self.display_clear = .{
            .mode = mode,
            .cursor_row = @intCast(self.terminal.screens.active.cursor.y),
            .cursor_col = @intCast(self.terminal.screens.active.cursor.x),
            .protected = protected,
        };
    }

    fn captureDisplayClearRowsForSyntheticHistory(self: *SessionTerminal, mode: DisplayClearMode) !void {
        // This callback runs before Ghostty applies the screen clear. Use a
        // temporary snapshot for the rows we copy to scrollback; advancing
        // self.render_state here would make the later draw think the old rows
        // were already rendered after the clear.
        var state: RenderState = .empty;
        defer state.deinit(self.allocator);
        try state.update(self.allocator, &self.terminal);

        const row_data = state.row_data.slice();
        const row_pins = row_data.items(.pin);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_count = trimmedRowCount(row_cells);
        const cursor_row: usize = @intCast(self.terminal.screens.active.cursor.y);
        const cursor_col: usize = @intCast(self.terminal.screens.active.cursor.x);
        const start_row = switch (mode) {
            .above => return,
            .complete => 0,
            .below => if (cursor_col == 0)
                @min(cursor_row, row_count)
            else
                @min(cursor_row + 1, row_count),
        };
        var row_index: usize = start_row;
        while (row_index < row_count) : (row_index += 1) {
            try self.synthetic_history_rows.append(self.allocator, .{
                .cells = try rowCellsAlloc(self.allocator, row_cells[row_index], row_pins[row_index]),
                .width_cols = @intCast(state.cols),
                .flags = rowFlags(row_rows[row_index]),
            });
        }
        self.trimSyntheticHistory();
    }

    fn trimSyntheticHistory(self: *SessionTerminal) void {
        while (self.synthetic_history_rows.items.len > self.scrollback_row_limit) {
            var row = self.synthetic_history_rows.orderedRemove(0);
            row.deinit(self.allocator);
            if (self.reported_synthetic_history_rows > 0) self.reported_synthetic_history_rows -= 1;
        }
    }

    fn clearSyntheticHistory(self: *SessionTerminal) void {
        for (self.synthetic_history_rows.items) |*row| row.deinit(self.allocator);
        self.synthetic_history_rows.clearAndFree(self.allocator);
        self.reported_synthetic_history_rows = 0;
        self.synthetic_history_real_rows = self.historyRowCount();
    }

    fn consumeSyntheticHistoryForRealScrollback(self: *SessionTerminal) void {
        const history_rows = self.historyRowCount();
        if (history_rows < self.synthetic_history_real_rows) {
            self.synthetic_history_real_rows = history_rows;
        }
        if (self.synthetic_history_rows.items.len == 0) {
            self.synthetic_history_real_rows = history_rows;
            return;
        }
        if (history_rows <= self.synthetic_history_real_rows) return;

        const growth = history_rows - self.synthetic_history_real_rows;
        const rows_to_remove: usize = @min(
            self.synthetic_history_rows.items.len,
            if (growth > std.math.maxInt(usize)) std.math.maxInt(usize) else @as(usize, @intCast(growth)),
        );
        self.removeSyntheticRowsPrefix(rows_to_remove);
        self.synthetic_history_real_rows = history_rows;
    }

    fn removeSyntheticRowsPrefix(self: *SessionTerminal, count: usize) void {
        var removed: usize = 0;
        while (removed < count) : (removed += 1) {
            var row = self.synthetic_history_rows.orderedRemove(0);
            row.deinit(self.allocator);
        }
        self.reported_synthetic_history_rows -|= count;
    }

    fn clampReportedSyntheticHistoryRows(self: *SessionTerminal) void {
        self.reported_synthetic_history_rows = @min(
            self.reported_synthetic_history_rows,
            self.synthetic_history_rows.items.len,
        );
    }

    fn discardSyntheticRedrawRows(self: *SessionTerminal) !void {
        const start = self.reported_synthetic_history_rows;
        if (start >= self.synthetic_history_rows.items.len) return;

        if (self.syntheticRangeAllDefaultBlank(start)) {
            self.removeSyntheticRowsFrom(start);
            return;
        }

        try self.render_state.update(self.allocator, &self.terminal);
        const duplicate_suffix_start = try self.syntheticRedrawSuffixStart(start);
        var discard_start = duplicate_suffix_start;
        if (duplicate_suffix_start < self.synthetic_history_rows.items.len) {
            while (discard_start > start and rowIsDefaultBlank(self.synthetic_history_rows.items[discard_start - 1])) {
                discard_start -= 1;
            }
        }
        var index = self.synthetic_history_rows.items.len;
        while (index > start) {
            index -= 1;
            if (index < discard_start) continue;
            var row = self.synthetic_history_rows.orderedRemove(index);
            row.deinit(self.allocator);
        }
    }

    fn syntheticRangeAllDefaultBlank(self: *const SessionTerminal, start: usize) bool {
        if (start >= self.synthetic_history_rows.items.len) return false;
        for (self.synthetic_history_rows.items[start..]) |row| {
            if (!rowIsDefaultBlank(row)) return false;
        }
        return true;
    }

    fn removeSyntheticRowsFrom(self: *SessionTerminal, start: usize) void {
        var index = self.synthetic_history_rows.items.len;
        while (index > start) {
            index -= 1;
            var row = self.synthetic_history_rows.orderedRemove(index);
            row.deinit(self.allocator);
        }
    }

    fn syntheticRedrawSuffixStart(self: *SessionTerminal, start: usize) !usize {
        const row_data = self.render_state.row_data.slice();
        const row_pins = row_data.items(.pin);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const active_row_count = trimmedRowCount(row_cells);
        const synthetic_rows = self.synthetic_history_rows.items;
        const new_count = synthetic_rows.len - start;
        const max_match = @min(active_row_count, new_count);

        var match_count: usize = 0;
        while (match_count < max_match) : (match_count += 1) {
            const synthetic_index = synthetic_rows.len - match_count - 1;
            const active_index = max_match - match_count - 1;
            if (!try renderedRowIsPrefixOfState(
                self.allocator,
                synthetic_rows[synthetic_index],
                row_cells[active_index],
                row_pins[active_index],
                row_rows[active_index],
                @intCast(self.render_state.cols),
            )) break;
        }

        return synthetic_rows.len - match_count;
    }
};

const ModelTrackingHandler = struct {
    readonly: ghostty_vt.ReadonlyHandler,
    session: *SessionTerminal,

    pub fn deinit(self: *ModelTrackingHandler) void {
        self.readonly.deinit();
    }

    pub fn vt(
        self: *ModelTrackingHandler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) !void {
        switch (action) {
            .window_title => try self.session.setTitleFromTerminal(value.title),
            .color_operation => try self.session.colorOperation(value),
            .erase_display_below => try self.session.noteDisplayClear(.below, value),
            .erase_display_above => try self.session.noteDisplayClear(.above, value),
            .erase_display_complete => try self.session.noteDisplayClear(.complete, value),
            .erase_display_scrollback => self.session.noteRetainedScrollbackCleared(),
            .full_reset => self.session.noteFullReset(),
            .device_attributes => try self.session.deviceAttributes(value),
            .device_status => try self.session.deviceStatusReport(value.request),
            .request_mode => try self.session.requestMode(value.mode),
            .request_mode_unknown => try self.session.requestModeUnknown(value.mode, value.ansi),
            .kitty_keyboard_query => try self.session.kittyKeyboardQuery(),
            .size_report => try self.session.sizeReport(value),
            .xtversion => try self.session.reportXtversion(),
            .dcs_hook => try self.session.dcsHook(value),
            .dcs_put => try self.session.dcsPut(value),
            .dcs_unhook => try self.session.dcsUnhook(),
            else => {},
        }
        try self.readonly.vt(action, value);
    }
};

fn scrollbackByteLimit(row_count: u32, cols: u16) usize {
    const estimated_row_bytes = @as(usize, @max(cols, 1)) * 128;
    return std.math.mul(usize, row_count, estimated_row_bytes) catch std.math.maxInt(usize);
}

fn renderDirtyState(dirty: RenderState.Dirty) DirtyState {
    return switch (dirty) {
        .false => .none,
        .partial => .partial,
        .full => .full,
    };
}

fn trimmedRowCount(rows: []const std.MultiArrayList(RenderState.Cell)) usize {
    var count = rows.len;
    while (count > 0) : (count -= 1) {
        if (rowHasContent(rows[count - 1])) break;
    }
    return count;
}

fn rowHasContent(cells: std.MultiArrayList(RenderState.Cell)) bool {
    const cells_slice = cells.slice();
    for (cells_slice.items(.raw)) |cell| {
        if (cellRenderable(cell)) return true;
    }
    return false;
}

fn rowCellsAlloc(
    allocator: std.mem.Allocator,
    cells: std.MultiArrayList(RenderState.Cell),
    pin: ghostty_vt.Pin,
) ![]RenderedCell {
    const cells_slice = cells.slice();
    const raw_cells = cells_slice.items(.raw);
    const styles = cells_slice.items(.style);
    const graphemes = cells_slice.items(.grapheme);
    const last_index = lastRenderableCell(raw_cells) orelse return &.{};

    var result = std.ArrayList(RenderedCell).empty;
    errdefer {
        for (result.items) |cell| cell.deinit(allocator);
        result.deinit(allocator);
    }

    var index: usize = 0;
    while (index <= last_index) : (index += 1) {
        const raw = raw_cells[index];
        if (raw.wide == .spacer_tail) continue;

        try result.append(allocator, .{
            .text = try cellTextAlloc(allocator, raw, graphemes[index]),
            .display_width = @intCast(raw.gridWidth()),
            .attrs = attrsFromStyle(styleForCell(raw, styles[index])),
            .hyperlink = try hyperlinkUriAlloc(allocator, pin, index),
        });
    }

    return try result.toOwnedSlice(allocator);
}

fn rowFromPinAlloc(allocator: std.mem.Allocator, pin: ghostty_vt.Pin) !RenderedRow {
    const page = &pin.node.data;
    const row = page.getRow(pin.y);
    return .{
        .cells = try rowCellsFromPageAlloc(allocator, pin),
        .width_cols = @intCast(page.size.cols),
        .flags = rowFlags(row.*),
    };
}

fn cloneRowAlloc(allocator: std.mem.Allocator, row: RenderedRow) !RenderedRow {
    const cells = try allocator.alloc(RenderedCell, row.cells.len);
    var cells_filled: usize = 0;
    errdefer {
        for (cells[0..cells_filled]) |cell| cell.deinit(allocator);
        allocator.free(cells);
    }

    for (row.cells, 0..) |cell, index| {
        cells[index] = .{
            .text = try allocator.dupe(u8, cell.text),
            .display_width = cell.display_width,
            .attrs = cell.attrs,
            .hyperlink = if (cell.hyperlink) |uri| try allocator.dupe(u8, uri) else null,
        };
        cells_filled += 1;
    }

    return .{
        .cells = cells,
        .width_cols = row.width_cols,
        .flags = row.flags,
        .dirty = row.dirty,
    };
}

fn renderedRowMatchesState(
    allocator: std.mem.Allocator,
    expected: RenderedRow,
    cells: std.MultiArrayList(RenderState.Cell),
    pin: ghostty_vt.Pin,
    raw_row: anytype,
    width_cols: u16,
) !bool {
    if (expected.width_cols != width_cols or expected.flags != rowFlags(raw_row)) return false;
    const actual_cells = try rowCellsAlloc(allocator, cells, pin);
    defer {
        for (actual_cells) |cell| cell.deinit(allocator);
        if (actual_cells.len > 0) allocator.free(actual_cells);
    }
    return renderedCellsEqual(expected.cells, actual_cells);
}

fn renderedCellsEqual(a: []const RenderedCell, b: []const RenderedCell) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.text, right.text)) return false;
        if (left.display_width != right.display_width) return false;
        if (!left.attrs.eql(right.attrs)) return false;
        if (!optionalStringEqual(left.hyperlink, right.hyperlink)) return false;
    }
    return true;
}

fn renderedRowIsPrefixOfState(
    allocator: std.mem.Allocator,
    expected: RenderedRow,
    cells: std.MultiArrayList(RenderState.Cell),
    pin: ghostty_vt.Pin,
    raw_row: anytype,
    width_cols: u16,
) !bool {
    if (expected.width_cols != width_cols or expected.flags != rowFlags(raw_row)) return false;
    const actual_cells = try rowCellsAlloc(allocator, cells, pin);
    defer {
        for (actual_cells) |cell| cell.deinit(allocator);
        if (actual_cells.len > 0) allocator.free(actual_cells);
    }
    return renderedCellsArePrefix(expected.cells, actual_cells);
}

fn renderedCellsArePrefix(prefix: []const RenderedCell, full: []const RenderedCell) bool {
    if (prefix.len > full.len) return false;
    for (prefix, full[0..prefix.len]) |left, right| {
        if (!std.mem.eql(u8, left.text, right.text)) return false;
        if (left.display_width != right.display_width) return false;
        if (!left.attrs.eql(right.attrs)) return false;
        if (!optionalStringEqual(left.hyperlink, right.hyperlink)) return false;
    }
    return true;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| {
        const right = b orelse return false;
        return std.mem.eql(u8, left, right);
    }
    return b == null;
}

fn rowIsDefaultBlank(row: RenderedRow) bool {
    for (row.cells) |cell| {
        if (!cell.attrs.eql(.{})) return false;
        if (cell.hyperlink != null) return false;
        for (cell.text) |byte| {
            if (byte != ' ') return false;
        }
    }
    return true;
}

fn rowCellsFromPageAlloc(allocator: std.mem.Allocator, pin: ghostty_vt.Pin) ![]RenderedCell {
    const page = &pin.node.data;
    const row = page.getRow(pin.y);
    const raw_cells = page.getCells(row);
    const last_index = lastRenderableCell(raw_cells) orelse return &.{};

    var result = std.ArrayList(RenderedCell).empty;
    errdefer {
        for (result.items) |cell| cell.deinit(allocator);
        result.deinit(allocator);
    }

    var index: usize = 0;
    while (index <= last_index) : (index += 1) {
        const raw = raw_cells[index];
        if (raw.wide == .spacer_tail) continue;

        const grapheme = if (raw.hasGrapheme())
            page.lookupGrapheme(&raw_cells[index]) orelse &.{}
        else
            &.{};
        const style = if (raw.style_id > 0)
            page.styles.get(page.memory, raw.style_id).*
        else
            ghostty_vt.Style{};

        try result.append(allocator, .{
            .text = try cellTextAlloc(allocator, raw, grapheme),
            .display_width = @intCast(raw.gridWidth()),
            .attrs = attrsFromStyle(styleForCell(raw, style)),
            .hyperlink = try hyperlinkUriAlloc(allocator, pin, index),
        });
    }

    return try result.toOwnedSlice(allocator);
}

fn rowFlags(row: anytype) u16 {
    var flags: u16 = 0;
    if (row.wrap_continuation) flags |= 1 << 0;
    return flags;
}

fn lastRenderableCell(cells: []const ghostty_vt.Cell) ?usize {
    var index = cells.len;
    while (index > 0) {
        index -= 1;
        if (cellRenderable(cells[index])) return index;
    }
    return null;
}

fn cellRenderable(cell: ghostty_vt.Cell) bool {
    return cell.hasText() or
        cell.hasStyling() or
        cell.hyperlink or
        cell.content_tag == .bg_color_palette or
        cell.content_tag == .bg_color_rgb or
        cell.wide != .narrow;
}

fn cellTextAlloc(allocator: std.mem.Allocator, cell: ghostty_vt.Cell, grapheme: []const u21) ![]const u8 {
    if (!cell.hasText()) return try allocator.dupe(u8, "");

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try appendCodepoint(&result, allocator, cell.codepoint());
    if (cell.hasGrapheme()) {
        for (grapheme) |cp| try appendCodepoint(&result, allocator, cp);
    }

    return try result.toOwnedSlice(allocator);
}

fn styleForCell(cell: ghostty_vt.Cell, style: ghostty_vt.Style) ghostty_vt.Style {
    var result: ghostty_vt.Style = if (cell.style_id > 0) style else .{};
    switch (cell.content_tag) {
        .bg_color_palette => result.bg_color = .{ .palette = cell.content.color_palette },
        .bg_color_rgb => result.bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r,
            .g = cell.content.color_rgb.g,
            .b = cell.content.color_rgb.b,
        } },
        else => {},
    }
    return result;
}

fn attrsFromStyle(style: ghostty_vt.Style) CellAttrs {
    var flags: u32 = 0;
    if (style.flags.bold) flags |= 1 << 0;
    if (style.flags.faint) flags |= 1 << 1;
    if (style.flags.italic) flags |= 1 << 2;
    if (style.flags.underline != .none) {
        flags |= 1 << 3;
        flags |= @as(u32, underlineStyleValue(style.flags.underline)) << 9;
    }
    if (style.flags.blink) flags |= 1 << 4;
    if (style.flags.inverse) flags |= 1 << 5;
    if (style.flags.invisible) flags |= 1 << 6;
    if (style.flags.strikethrough) flags |= 1 << 7;
    if (style.flags.overline) flags |= 1 << 8;

    return .{
        .style_flags = flags,
        .fg_color = terminalColor(style.fg_color),
        .bg_color = terminalColor(style.bg_color),
        .underline_color = terminalColor(style.underline_color),
    };
}

fn underlineStyleValue(underline: @TypeOf((ghostty_vt.Style{}).flags.underline)) u8 {
    return switch (underline) {
        .none => 0,
        .single => 1,
        .double => 2,
        .curly => 3,
        .dotted => 4,
        .dashed => 5,
    };
}

fn terminalColor(color: ghostty_vt.Style.Color) u32 {
    return switch (color) {
        .none => CellAttrs.default_color,
        .palette => |idx| idx,
        .rgb => |rgb| rgbTerminalColor(rgb),
    };
}

fn rgbTerminalColor(rgb: ghostty_vt.color.RGB) u32 {
    return 0x01000000 |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

fn terminalColorRgb(color: u32) ?ghostty_vt.color.RGB {
    if ((color & 0xff000000) != 0x01000000) return null;
    return .{
        .r = @intCast((color >> 16) & 0xff),
        .g = @intCast((color >> 8) & 0xff),
        .b = @intCast(color & 0xff),
    };
}

fn oscTerminator(terminator: ghostty_vt.osc.Terminator) []const u8 {
    return switch (terminator) {
        .st => "\x1b\\",
        .bel => "\x07",
    };
}

fn hyperlinkUriAlloc(allocator: std.mem.Allocator, pin: ghostty_vt.Pin, x: usize) !?[]const u8 {
    const page = &pin.node.data;
    const rac = page.getRowAndCell(x, pin.y);
    if (!rac.cell.hyperlink) return null;
    const id = page.lookupHyperlink(rac.cell) orelse return null;
    const link = page.hyperlink_set.get(page.memory, id);
    return try allocator.dupe(u8, link.uri.slice(page.memory));
}

fn appendCodepoint(result: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try result.appendSlice(allocator, buf[0..len]);
}

fn cursorStyleValue(terminal: *const Terminal) u8 {
    const blinking = terminal.modes.get(.cursor_blinking);
    return switch (terminal.screens.active.cursor.cursor_style) {
        .block, .block_hollow => if (blinking) 1 else 2,
        .underline => if (blinking) 3 else 4,
        .bar => if (blinking) 5 else 6,
    };
}

pub fn smokePlainString(allocator: std.mem.Allocator) ![]const u8 {
    var terminal: Terminal = try .init(allocator, .{
        .cols = 6,
        .rows = 4,
    });
    defer terminal.deinit(allocator);

    try terminal.printString("Hello, World!");
    return terminal.plainString(allocator);
}

test "libghostty-vt accepts bytes and exposes terminal text" {
    const text = try smokePlainString(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "World") != null);
}

test "session terminal parses VT streams" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("alpha\r\n\x1b[2;1Hbeta");
    const snapshot = try terminal.plainSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot.text);

    try std.testing.expect(std.mem.indexOf(u8, snapshot.text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.text, "beta") != null);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor_row);
}

test "plain text parser boundary is false inside split CSI" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try std.testing.expect(terminal.isPlainTextParserBoundary());
    try terminal.feed("\x1b[");
    try std.testing.expect(!terminal.isPlainTextParserBoundary());
    try terminal.feed("0m");
    try std.testing.expect(terminal.isPlainTextParserBoundary());
}

test "plain text parser boundary is false after bare ESC" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try std.testing.expect(terminal.isPlainTextParserBoundary());
    try terminal.feed("\x1b");
    try std.testing.expect(!terminal.isPlainTextParserBoundary());
    try terminal.feed("c");
    try std.testing.expect(terminal.isPlainTextParserBoundary());
}

test "blank active screen has no plain text rows" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    const snapshot = try terminal.plainSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot.text);

    try std.testing.expectEqualStrings("", snapshot.text);
}

test "cleared active screen has no plain text rows" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("hello\r\nworld\x1b[2J\x1b[H");
    const snapshot = try terminal.plainSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot.text);

    try std.testing.expectEqualStrings("", snapshot.text);
}

test "leading blank row is preserved in plain snapshot" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\r\nPROMPT");
    const snapshot = try terminal.plainSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot.text);

    try std.testing.expectEqualStrings("\nPROMPT", snapshot.text);
}

test "rendered screen exposes cell style colors" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[1;31;44mX");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), screen.rows.len);
    try std.testing.expectEqual(@as(usize, 1), screen.rows[0].cells.len);
    const cell = screen.rows[0].cells[0];
    try std.testing.expectEqualStrings("X", cell.text);
    try std.testing.expect((cell.attrs.style_flags & (1 << 0)) != 0);
    try std.testing.expectEqual(@as(u32, 1), cell.attrs.fg_color);
    try std.testing.expectEqual(@as(u32, 4), cell.attrs.bg_color);
}

test "rendered screen preserves background-only cells" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[44m\x1b[2K");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), screen.rows.len);
    try std.testing.expect(screen.rows[0].cells.len > 0);
    const cell = screen.rows[0].cells[0];
    try std.testing.expectEqualStrings("", cell.text);
    try std.testing.expectEqual(@as(u8, 1), cell.display_width);
    try std.testing.expectEqual(@as(u32, 4), cell.attrs.bg_color);
}

test "rendered screen exposes OSC 8 hyperlinks" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b]8;;https://example.test/\x1b\\L\x1b]8;;\x1b\\");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), screen.rows.len);
    try std.testing.expectEqual(@as(usize, 1), screen.rows[0].cells.len);
    const uri = screen.rows[0].cells[0].hyperlink orelse return error.MissingHyperlink;
    try std.testing.expectEqualStrings("https://example.test/", uri);
}

test "session terminal enables unicode grapheme clustering" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("🇺🇸X");
    var flag_screen = try terminal.renderedScreen(std.testing.allocator);
    defer flag_screen.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 3), flag_screen.cursor_col);

    const zwj_terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer zwj_terminal.destroy();

    try zwj_terminal.feed("👩‍💻X");
    var zwj_screen = try zwj_terminal.renderedScreen(std.testing.allocator);
    defer zwj_screen.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 3), zwj_screen.cursor_col);
}

test "rendered screen exposes active screen" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("primary");
    var primary = try terminal.renderedScreen(std.testing.allocator);
    defer primary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), primary.active_screen);

    try terminal.feed("\x1b[?1049halternate");
    var alternate = try terminal.renderedScreen(std.testing.allocator);
    defer alternate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), alternate.active_screen);
}

test "rendered screen exposes terminal modes" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[?1;1003;1004;1006;2004h");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expect((screen.modes.mode_flags & TerminalModes.application_cursor_keys) != 0);
    try std.testing.expect((screen.modes.mode_flags & TerminalModes.focus_reporting) != 0);
    try std.testing.expect((screen.modes.mode_flags & TerminalModes.bracketed_paste) != 0);
    try std.testing.expectEqual(@as(u8, 3), screen.modes.mouse_tracking);
    try std.testing.expect(screen.modes.mouse_sgr);
}

test "session terminal answers basic terminal queries to the PTY" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[3;5H\x1b[6n\x1b[5n\x1b[c\x1b[?7$p");

    const responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[3;5R") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[0n") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[?62;22c") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[?7;1$y") != null);
}

test "session terminal answers complex UI startup probes to the PTY" {
    const terminal = try SessionTerminal.createWithDefaultColors(std.testing.allocator, 24, 80, 100, .{
        .foreground_color = 0x010a0b0c,
        .background_color = 0x010d0e0f,
    });
    defer terminal.destroy();

    try terminal.feed(
        "\x1b[?1002h" ++
            "\x1b[?1003h" ++
            "\x1b[?1004h" ++
            "\x1b[?1006h" ++
            "\x1b[?2004h" ++
            "\x1b]10;?\x07" ++
            "\x1b]11;?\x07" ++
            "\x1b]12;?\x07" ++
            "\x1b]4;0;?\x07" ++
            "\x1b[?2026$p" ++
            "\x1b[?2027$p" ++
            "\x1b[?u" ++
            "\x1b[>0q" ++
            "\x1bP+q4d73\x1b\\" ++
            "\x1bP$qm\x1b\\",
    );

    const responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]10;rgb:0a/0b/0c\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]11;rgb:0d/0e/0f\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]12;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]4;0;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[?2026;") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[?2027;1$y") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b[?") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1bP>|sessh " ++ config.version ++ "\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1bP0+r4D73\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1bP1$r0m\x1b\\") != null);
}

test "session terminal can drain query responses after session agent writes them" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[6n");
    try std.testing.expect(terminal.pendingInputResponses().len > 0);
    terminal.clearPendingInputResponses();
    try std.testing.expectEqual(@as(usize, 0), terminal.pendingInputResponses().len);
}

test "rendered screen exposes OSC title changes" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b]2;sessh-title-one\x1b\\");
    var first = try terminal.renderedScreen(std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sessh-title-one", first.title);
    try std.testing.expect(first.title_dirty);

    terminal.markRendered(first.rows.len);
    var clean = try terminal.renderedScreen(std.testing.allocator);
    defer clean.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sessh-title-one", clean.title);
    try std.testing.expect(!clean.title_dirty);
}

test "rendered screen exposes OSC 10 and OSC 11 default colors" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b]10;rgb:01/02/03\x1b\\");
    try terminal.feed("\x1b]11;rgb:04/05/06\x1b\\");
    var first = try terminal.renderedScreen(std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0x01010203), first.default_colors.foreground_color);
    try std.testing.expectEqual(@as(u32, 0x01040506), first.default_colors.background_color);
    try std.testing.expect(first.default_colors_dirty);

    terminal.markRendered(first.rows.len);
    var clean = try terminal.renderedScreen(std.testing.allocator);
    defer clean.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0x01010203), clean.default_colors.foreground_color);
    try std.testing.expectEqual(@as(u32, 0x01040506), clean.default_colors.background_color);
    try std.testing.expect(!clean.default_colors_dirty);

    try terminal.feed("\x1b]10;?\x1b\\\x1b]11;?\x07");
    const responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]10;rgb:01/02/03\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]11;rgb:04/05/06\x07") != null);

    try terminal.feed("\x1b]110\x1b\\\x1b]111\x1b\\");
    var reset = try terminal.renderedScreen(std.testing.allocator);
    defer reset.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, CellAttrs.default_color), reset.default_colors.foreground_color);
    try std.testing.expectEqual(@as(u32, CellAttrs.default_color), reset.default_colors.background_color);
    try std.testing.expect(reset.default_colors_dirty);
}

test "OSC 10 and OSC 11 queries use client-seeded defaults before inner overrides" {
    const terminal = try SessionTerminal.createWithDefaultColors(std.testing.allocator, 4, 20, 100, .{
        .foreground_color = 0x010a0b0c,
        .background_color = 0x010d0e0f,
    });
    defer terminal.destroy();

    var initial = try terminal.renderedScreen(std.testing.allocator);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, CellAttrs.default_color), initial.default_colors.foreground_color);
    try std.testing.expectEqual(@as(u32, CellAttrs.default_color), initial.default_colors.background_color);
    try std.testing.expect(!initial.default_colors_dirty);

    try terminal.feed("\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
    var responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]10;rgb:0a/0b/0c\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]11;rgb:0d/0e/0f\x1b\\") != null);
    terminal.clearPendingInputResponses();

    try terminal.feed("\x1b]10;rgb:01/02/03\x1b\\");
    try terminal.feed("\x1b]10;?\x1b\\");
    responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]10;rgb:01/02/03\x1b\\") != null);
    terminal.clearPendingInputResponses();

    try terminal.feed("\x1b]110\x1b\\\x1b]10;?\x1b\\");
    responses = terminal.pendingInputResponses();
    try std.testing.expect(std.mem.indexOf(u8, responses, "\x1b]10;rgb:0a/0b/0c\x1b\\") != null);
}

test "title tracking handles split OSC title sequences" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b]2;sessh-");
    try terminal.feed("title-two");
    try terminal.feed("\x07");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sessh-title-two", screen.title);
    try std.testing.expect(screen.title_dirty);
}

test "scrollback snapshot exposes retained history rows" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 3, 20, 20);
    defer terminal.destroy();

    try terminal.feed("history_01\r\nhistory_02\r\nhistory_03\r\nhistory_04\r\nhistory_05\r\n");
    var scrollback = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer scrollback.deinit(std.testing.allocator);

    try std.testing.expect(scrollback.rows.len > 0);
    var found = false;
    for (scrollback.rows) |row| {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(std.testing.allocator);
        for (row.cells) |cell| try text.appendSlice(std.testing.allocator, cell.text);
        if (std.mem.eql(u8, text.items, "history_01")) found = true;
    }
    try std.testing.expect(found);
}

test "scrollback snapshot reports absolute count past retained row limit" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 3, 20, 5);
    defer terminal.destroy();

    var i: usize = 1;
    while (i <= 16) : (i += 1) {
        var line_buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "abs_{d:0>2}\r\n", .{i});
        try terminal.feed(line);
    }

    var scrollback = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer scrollback.deinit(std.testing.allocator);

    try std.testing.expect(scrollback.rows.len <= 5);
    try std.testing.expect(scrollback.absolute_count > scrollback.rows.len);
    try std.testing.expectEqual(
        scrollback.absolute_count - @as(u64, @intCast(scrollback.rows.len)),
        scrollback.truncated_rows,
    );
}

test "clear screen followed by output commits overflow rows to scrollback" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[2J\x1b[H");
    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        var line_buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "LINE_{d:0>2}\r\n", .{i});
        try terminal.feed(line);
    }

    var scrollback = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer scrollback.deinit(std.testing.allocator);

    var found_first = false;
    for (scrollback.rows) |row| {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(std.testing.allocator);
        for (row.cells) |cell| try text.appendSlice(std.testing.allocator, cell.text);
        if (std.mem.eql(u8, text.items, "LINE_01")) found_first = true;
    }
    try std.testing.expect(found_first);
}

test "full reset clears retained and synthetic scrollback" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 100);
    defer terminal.destroy();

    try terminal.feed("\x1b[2J\x1b[HMAIN_SCREEN_MARKER\x1bcREPORT\r\n");

    var scrollback = try terminal.scrollbackDelta(std.testing.allocator);
    defer scrollback.deinit(std.testing.allocator);

    var found_marker = false;
    for (scrollback.rows) |row| {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(std.testing.allocator);
        for (row.cells) |cell| try text.appendSlice(std.testing.allocator, cell.text);
        if (std.mem.eql(u8, text.items, "MAIN_SCREEN_MARKER")) found_marker = true;
    }
    try std.testing.expect(!found_marker);

    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);
    try std.testing.expect(screen.retained_scrollback_clear_dirty);
}

test "synthetic scrollback is consumed by real scrollback growth" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 3, 20, 20);
    defer terminal.destroy();

    try terminal.feed("old_1\r\nold_2\r\nold_3\x1b[H\x1b[2J");
    var before = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer before.deinit(std.testing.allocator);

    try std.testing.expect(terminal.synthetic_history_rows.items.len > 0);
    try terminal.feed("new_1\r\nnew_2\r\nnew_3\r\nnew_4\r\nnew_5\r\nnew_6\r\n");
    var after = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer after.deinit(std.testing.allocator);

    try std.testing.expect(after.rows.len > 0);
    try std.testing.expectEqual(@as(usize, 0), terminal.synthetic_history_rows.items.len);
}

test "display clear after rendered rows does not create synthetic scrollback" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 4, 20, 20);
    defer terminal.destroy();

    try terminal.feed("old_1\r\nold_2");
    var first = try terminal.renderedScreen(std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    terminal.markRendered(first.rows.len);

    try terminal.feed("\x1b[2J\x1b[Hnew_screen");
    var scrollback = try terminal.scrollbackDelta(std.testing.allocator);
    defer scrollback.deinit(std.testing.allocator);

    for (scrollback.rows) |row| {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(std.testing.allocator);
        for (row.cells) |cell| try text.appendSlice(std.testing.allocator, cell.text);
        try std.testing.expect(!std.mem.eql(u8, text.items, "old_1"));
        try std.testing.expect(!std.mem.eql(u8, text.items, "old_2"));
    }
}

test "scrollback delta tolerates reset terminal history with pending synthetic rows" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 3, 20, 20);
    defer terminal.destroy();

    const cells = try std.testing.allocator.alloc(RenderedCell, 1);
    cells[0] = .{
        .text = try std.testing.allocator.dupe(u8, "x"),
        .display_width = 1,
        .attrs = .{},
    };
    terminal.reported_history_rows = 10;
    try terminal.synthetic_history_rows.append(std.testing.allocator, .{
        .cells = cells,
        .width_cols = 20,
        .flags = 0,
    });

    var delta = try terminal.scrollbackDelta(std.testing.allocator);
    defer delta.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), delta.rows.len);
}

test "rendered screen exposes retained scrollback clears" {
    const terminal = try SessionTerminal.create(std.testing.allocator, 3, 20, 20);
    defer terminal.destroy();

    try terminal.feed("history_01\r\nhistory_02\r\nhistory_03\r\nhistory_04\r\nhistory_05\r\n");
    var before = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expect(before.rows.len > 0);
    terminal.markScrollbackReported();

    try terminal.feed("\x1b[3J");
    var screen = try terminal.renderedScreen(std.testing.allocator);
    defer screen.deinit(std.testing.allocator);
    try std.testing.expect(screen.retained_scrollback_clear_dirty);

    var after = try terminal.scrollbackSnapshot(std.testing.allocator);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after.rows.len);
    try std.testing.expectEqual(@as(u64, 0), after.truncated_rows);

    terminal.markRendered(screen.rows.len);
    var clean = try terminal.renderedScreen(std.testing.allocator);
    defer clean.deinit(std.testing.allocator);
    try std.testing.expect(!clean.retained_scrollback_clear_dirty);
}
