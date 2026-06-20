// Reconnect overlay drawing for terminal sessions. The remote side may be
// disconnected while the overlay is visible, so drawing records enough outer
// terminal geometry to erase itself later.
const std = @import("std");

const client_log = @import("../core/client_log.zig");
const fixed_buffer = @import("../core/fixed_buffer.zig");
const client_renderer = @import("renderer.zig");
const terminal = @import("../tty/terminal.zig");

const WindowSize = terminal.WindowSize;

pub const max_diagnostic_lines = 3;
pub const max_message_bytes = 256;

pub const Align = enum {
    left,
    center,
};

pub const Line = struct {
    text: []const u8,
    alignment: Align,
};

const max_overlay_diagnostic_line_count = 1 + max_diagnostic_lines;
const max_overlay_line_count = if (max_overlay_diagnostic_line_count > terminal.escape_help_overlay_lines.len)
    max_overlay_diagnostic_line_count
else
    terminal.escape_help_overlay_lines.len;
const max_overlay_render_line_bytes = if (max_message_bytes > client_log.max_user_diagnostic_display_bytes)
    max_message_bytes
else
    client_log.max_user_diagnostic_display_bytes;
const RenderedText = fixed_buffer.FixedBuffer(max_overlay_render_line_bytes);

comptime {
    std.debug.assert(max_overlay_line_count >= terminal.escape_help_overlay_lines.len);
    for (terminal.escape_help_overlay_lines) |line| {
        std.debug.assert(max_overlay_render_line_bytes >= line.len);
    }
}

const RenderedLine = struct {
    start_col: u16 = 0,
    text: RenderedText = .{},

    fn slice(self: *const RenderedLine) []const u8 {
        return self.text.slice();
    }

    fn endCol(self: *const RenderedLine) u16 {
        return self.start_col + @as(u16, @intCast(self.text.len));
    }

    fn eql(self: *const RenderedLine, other: *const RenderedLine) bool {
        return self.start_col == other.start_col and
            std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const DrawState = struct {
    size: WindowSize,
    start_row: u16,
    line_count: u16,
    viewport_offset: u16,
    restore_viewport_offset: u16,
    scroll_top: u16,
    scroll_lines: u16,
    restores_expansion: bool = true,
    lines: [max_overlay_line_count]RenderedLine = [_]RenderedLine{.{}} ** max_overlay_line_count,
};

const OverlayLayout = struct {
    start_row: u16,
    visible_line_count: u16,
    scroll_lines: u16,
    viewport_offset: u16,
};

pub const DrawLinesOptions = struct {
    renderer: client_renderer.Renderer,
    size: WindowSize,
    viewport_offset: u16,
    previous: ?DrawState,
    lines: []const Line,
};

// Render or erase the reconnect overlay without assuming the remote terminal is
// responsive. The returned DrawState records enough outer-terminal geometry to
// clear or resize the overlay later without corrupting the user's scrollback.
pub fn drawLines(options: DrawLinesOptions) !DrawState {
    const renderer = options.renderer;
    const size = options.size;
    const viewport_offset = options.viewport_offset;
    const previous = options.previous;
    const lines = options.lines;
    const terminal_rows = normalizedTerminalRows(size.rows);
    const normalized_size = size.withRows(terminal_rows);
    if (lines.len == 0) {
        if (previous) |state| try eraseOverlayRows(renderer, state, normalized_size);
        if (previous) |state| try restoreOverlayExpansion(renderer, state, normalized_size);
        const restored_viewport_offset = if (previous) |state| clearedOverlayViewportOffset(state) else viewport_offset;
        return .{
            .size = normalized_size,
            .start_row = 0,
            .line_count = 0,
            .viewport_offset = restored_viewport_offset,
            .restore_viewport_offset = restored_viewport_offset,
            .scroll_top = restored_viewport_offset,
            .scroll_lines = 0,
        };
    }

    const layout = overlayLayoutForSize(terminal_rows, viewport_offset, lines.len);
    const clamped_viewport_offset = @min(viewport_offset, terminal_rows - 1);
    const prior_scroll_lines = if (previous) |state| state.scroll_lines else 0;
    const restore_viewport_offset = if (previous) |state| state.restore_viewport_offset else clamped_viewport_offset;
    const scroll_lines = prior_scroll_lines +| layout.scroll_lines;
    const consumes_outer_rows = layout.scroll_lines > 0 and layout.viewport_offset < restore_viewport_offset;
    const restores_expansion = (if (previous) |state| state.restores_expansion else true) and !consumes_outer_rows;
    var next_state = DrawState{
        .size = normalized_size,
        .start_row = layout.start_row,
        .line_count = layout.visible_line_count,
        .viewport_offset = layout.viewport_offset,
        .restore_viewport_offset = restore_viewport_offset,
        .scroll_top = layout.viewport_offset,
        .scroll_lines = scroll_lines,
        .restores_expansion = restores_expansion,
    };
    var row_offset: u16 = 0;
    while (row_offset < layout.visible_line_count) : (row_offset += 1) {
        next_state.lines[row_offset] = renderLine(size.cols, lines[row_offset]);
    }

    const can_update_in_place = if (previous) |state|
        layout.scroll_lines == 0 and
            state.size.eql(normalized_size) and
            state.start_row == layout.start_row
    else
        false;

    if (!can_update_in_place) {
        if (previous) |state| try eraseOverlayRows(renderer, state, normalized_size);
    }
    if (layout.scroll_lines > 0) {
        if (restores_expansion) {
            try expandOverlayRegion(renderer, .{
                .top = layout.viewport_offset,
                .rows = terminal_rows,
                .count = layout.scroll_lines,
            });
        } else {
            try expandOverlayByScrollingTerminal(renderer, terminal_rows, layout.scroll_lines);
        }
    }

    row_offset = 0;
    while (row_offset < layout.visible_line_count) : (row_offset += 1) {
        const old_line = if (can_update_in_place and row_offset < previous.?.line_count)
            previous.?.lines[row_offset]
        else
            null;
        if (old_line) |line| {
            if (next_state.lines[row_offset].eql(&line)) continue;
        }
        try drawRenderedLine(renderer, .{
            .position = terminal.top_left_position.withRow(layout.start_row + row_offset),
            .cols = size.cols,
            .line = next_state.lines[row_offset],
            .previous = old_line,
            .clear_full_row = old_line == null,
        });
    }
    if (can_update_in_place) {
        row_offset = layout.visible_line_count;
        while (row_offset < previous.?.line_count) : (row_offset += 1) {
            try eraseRenderedLine(renderer, .{
                .position = terminal.top_left_position.withRow(layout.start_row + row_offset),
                .cols = size.cols,
                .line = previous.?.lines[row_offset],
            });
        }
    }
    try renderer.restoreOverlayPresentation();
    try renderer.moveCursor(terminal.top_left_position.withRow(layout.viewport_offset));
    return next_state;
}

pub fn clearedOverlayViewportOffset(self: DrawState) u16 {
    return if (self.restores_expansion) self.restore_viewport_offset else self.viewport_offset;
}

pub fn eraseOverlayRows(renderer: client_renderer.Renderer, state: DrawState, size: WindowSize) !void {
    const terminal_rows = normalizedTerminalRows(size.rows);
    try renderer.restoreOverlayPresentation();
    var i: u16 = 0;
    while (i < state.line_count) : (i += 1) {
        const row = state.start_row +| i;
        if (row >= terminal_rows) break;
        try eraseRenderedLine(renderer, .{
            .position = terminal.top_left_position.withRow(row),
            .cols = size.cols,
            .line = state.lines[i],
        });
    }
}

const ExpandOverlayRegionOptions = struct {
    top: u16,
    rows: u16,
    count: u16,
};

fn expandOverlayRegion(renderer: client_renderer.Renderer, options: ExpandOverlayRegionOptions) !void {
    if (options.count == 0) return;
    const terminal_rows = normalizedTerminalRows(options.rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.setScrollRegion(options.top, bottom);
    try renderer.moveCursor(terminal.top_left_position.withRow(bottom));
    var i: u16 = 0;
    while (i < options.count) : (i += 1) try renderer.newline();
    try renderer.resetScrollRegion();
}

fn expandOverlayByScrollingTerminal(renderer: client_renderer.Renderer, rows: u16, count: u16) !void {
    if (count == 0) return;
    const terminal_rows = normalizedTerminalRows(rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.moveCursor(terminal.top_left_position.withRow(bottom));
    var i: u16 = 0;
    while (i < count) : (i += 1) try renderer.newline();
}

pub fn restoreOverlayExpansion(renderer: client_renderer.Renderer, state: DrawState, size: WindowSize) !void {
    if (state.scroll_lines == 0) return;
    if (!state.restores_expansion) return;
    const terminal_rows = normalizedTerminalRows(size.rows);
    if (terminal_rows != state.size.rows) return;
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.setScrollRegion(state.scroll_top, bottom);
    try renderer.moveCursor(terminal.top_left_position.withRow(state.scroll_top));
    var i: u16 = 0;
    while (i < state.scroll_lines) : (i += 1) try renderer.reverseIndex();
    try renderer.resetScrollRegion();
}

fn renderLine(cols: u16, line: Line) RenderedLine {
    const visible_len = @min(@min(line.text.len, @as(usize, cols)), max_overlay_render_line_bytes);
    const col: u16 = switch (line.alignment) {
        .left => 0,
        .center => if (cols > visible_len)
            @intCast((@as(usize, cols) - visible_len) / 2)
        else
            0,
    };
    var rendered = RenderedLine{
        .start_col = col,
    };
    const rendered_text = rendered.text.storageSlice();
    for (line.text[0..visible_len], 0..) |byte, i| {
        rendered_text[i] = overlaySafeByte(byte);
    }
    rendered.text.assumeLen(visible_len);
    return rendered;
}

const DrawRenderedLineRequest = struct {
    position: terminal.CursorPosition,
    cols: u16,
    line: RenderedLine,
    previous: ?RenderedLine,
    clear_full_row: bool,
};

fn drawRenderedLine(
    renderer: client_renderer.Renderer,
    request: DrawRenderedLineRequest,
) !void {
    // Redraw the union of old and new overlay coverage so shrinking messages do
    // not leave stale highlighted cells behind. Overlay text is inverse-video
    // status UI, not terminal application output.
    const cols = request.cols;
    const line = request.line;
    const previous = request.previous;
    const clear_full_row = request.clear_full_row;
    if (cols == 0) return;
    const line_end = line.endCol();
    var cover_start: u16 = if (clear_full_row) 0 else line.start_col;
    var cover_end: u16 = if (clear_full_row) cols else line_end;
    if (!clear_full_row) {
        if (previous) |old| {
            cover_start = @min(cover_start, old.start_col);
            cover_end = @max(cover_end, old.endCol());
        }
    }
    if (cover_end <= cover_start) return;

    try renderer.moveCursor(request.position.withCol(cover_start));
    try renderer.restoreOverlayPresentation();
    try writeSpaces(renderer, line.start_col - cover_start);
    try renderer.writeRaw("\x1b[7m");
    try renderer.writeRaw(line.slice());
    try renderer.writeRaw("\x1b[0m");
    try writeSpaces(renderer, cover_end - line_end);
}

const EraseRenderedLineOptions = struct {
    position: terminal.CursorPosition,
    cols: u16,
    line: RenderedLine,
};

fn eraseRenderedLine(renderer: client_renderer.Renderer, options: EraseRenderedLineOptions) !void {
    const line = options.line;
    const start_col = @min(line.start_col, options.cols);
    const end_col = @min(line.endCol(), options.cols);
    if (end_col <= start_col) return;
    try renderer.moveCursor(options.position.withCol(start_col));
    try renderer.restoreOverlayPresentation();
    try writeSpaces(renderer, end_col - start_col);
}

fn writeSpaces(renderer: client_renderer.Renderer, count: usize) !void {
    const spaces = "                                                                ";
    var remaining = count;
    while (remaining > 0) {
        const n = @min(remaining, spaces.len);
        try renderer.writeRaw(spaces[0..n]);
        remaining -= n;
    }
}

fn overlaySafeByte(byte: u8) u8 {
    return switch (byte) {
        ' '...'~' => byte,
        else => '?',
    };
}

fn normalizedTerminalRows(rows: u16) u16 {
    return if (rows == 0) 1 else rows;
}

fn overlayLayoutForSize(rows: u16, top_row: u16, line_count: usize) OverlayLayout {
    // Prefer drawing below the current cursor, but scroll just enough when the
    // overlay would otherwise fall off the bottom. The viewport_offset records
    // how much the underlying terminal was displaced.
    const terminal_rows = normalizedTerminalRows(rows);
    const visible_line_count: u16 = @intCast(@min(line_count, @as(usize, terminal_rows)));
    if (visible_line_count == 0) {
        const viewport_offset = @min(top_row, terminal_rows - 1);
        return .{ .start_row = viewport_offset, .visible_line_count = 0, .scroll_lines = 0, .viewport_offset = viewport_offset };
    }

    const clamped_top = @min(top_row, terminal_rows - 1);
    const preferred_start = @as(usize, clamped_top) + 1;
    const preferred_end = preferred_start + @as(usize, visible_line_count);
    if (preferred_end <= terminal_rows) {
        return .{
            .start_row = @intCast(preferred_start),
            .visible_line_count = visible_line_count,
            .scroll_lines = 0,
            .viewport_offset = clamped_top,
        };
    }

    const scroll_lines: u16 = @intCast(@min(preferred_end - terminal_rows, @as(usize, std.math.maxInt(u16))));
    const consumed_top = @min(clamped_top, scroll_lines);
    return .{
        .start_row = terminal_rows - visible_line_count,
        .visible_line_count = visible_line_count,
        .scroll_lines = scroll_lines,
        .viewport_offset = clamped_top - consumed_top,
    };
}

fn countSubstrings(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

test "reconnect overlay layout adds rows at terminal bottom" {
    const single = overlayLayoutForSize(1, 0, 1);
    try std.testing.expectEqual(@as(u16, 0), single.start_row);
    try std.testing.expectEqual(@as(u16, 1), single.visible_line_count);
    try std.testing.expectEqual(@as(u16, 1), single.scroll_lines);

    const normal = overlayLayoutForSize(24, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), normal.start_row);
    try std.testing.expectEqual(@as(u16, 0), normal.scroll_lines);

    const bottom = overlayLayoutForSize(24, 23, 1);
    try std.testing.expectEqual(@as(u16, 23), bottom.start_row);
    try std.testing.expectEqual(@as(u16, 1), bottom.scroll_lines);
    try std.testing.expectEqual(@as(u16, 22), bottom.viewport_offset);
}

test "reconnect overlay draws clipped multiline content and pads stale rows" {
    var single_row = std.ArrayList(u8).empty;
    defer single_row.deinit(std.testing.allocator);
    const single_renderer = client_renderer.Renderer.bufferedXtermCompatible(&single_row);
    _ = try drawLines(.{
        .renderer = single_renderer,
        .size = .{ .rows = 1, .cols = 8 },
        .viewport_offset = 0,
        .previous = null,
        .lines = &.{.{ .text = "single row", .alignment = .center }},
    });
    try std.testing.expect(std.mem.indexOf(u8, single_row.items, "\r\n") != null);

    var first = std.ArrayList(u8).empty;
    defer first.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&first);
    const first_state = try drawLines(.{
        .renderer = renderer,
        .size = .{ .rows = 4, .cols = 8 },
        .viewport_offset = 0,
        .previous = null,
        .lines = &.{
            .{ .text = "0123456789", .alignment = .center },
            .{ .text = "ssh: first", .alignment = .left },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, first.items, "01234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "ssh: fir") != null);
    try std.testing.expectEqual(@as(u16, 1), first_state.start_row);
    try std.testing.expectEqual(@as(u16, 2), first_state.line_count);

    var second = std.ArrayList(u8).empty;
    defer second.deinit(std.testing.allocator);
    const second_renderer = client_renderer.Renderer.bufferedXtermCompatible(&second);
    _ = try drawLines(.{
        .renderer = second_renderer,
        .size = .{ .rows = 4, .cols = 8 },
        .viewport_offset = first_state.viewport_offset,
        .previous = first_state,
        .lines = &.{.{ .text = "new", .alignment = .center }},
    });
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(second.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "new") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "ssh: fir") == null);

    var third = std.ArrayList(u8).empty;
    defer third.deinit(std.testing.allocator);
    const third_renderer = client_renderer.Renderer.bufferedXtermCompatible(&third);
    _ = try drawLines(.{
        .renderer = third_renderer,
        .size = .{ .rows = 4, .cols = 8 },
        .viewport_offset = first_state.viewport_offset,
        .previous = first_state,
        .lines = &.{
            .{ .text = "76543210", .alignment = .center },
            .{ .text = "ssh: first", .alignment = .left },
        },
    });
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(third.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, third.items, "76543210") != null);
    try std.testing.expect(std.mem.indexOf(u8, third.items, "ssh: fir") == null);
}

test "reconnect overlay restores temporary expansion within sessh-owned rows" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&drawn);
    const state = try drawLines(.{
        .renderer = renderer,
        .size = .{ .rows = 4, .cols = 16 },
        .viewport_offset = 0,
        .previous = null,
        .lines = &.{
            .{ .text = "one", .alignment = .center },
            .{ .text = "two", .alignment = .left },
            .{ .text = "three", .alignment = .left },
            .{ .text = "four", .alignment = .left },
        },
    });
    try std.testing.expectEqual(@as(u16, 1), state.scroll_lines);
    try std.testing.expect(state.restores_expansion);
    try std.testing.expectEqual(@as(u16, 0), state.restore_viewport_offset);

    var cleared = std.ArrayList(u8).empty;
    defer cleared.deinit(std.testing.allocator);
    const clear_renderer = client_renderer.Renderer.bufferedXtermCompatible(&cleared);
    try eraseOverlayRows(clear_renderer, state, .{ .rows = 4, .cols = 16 });
    try restoreOverlayExpansion(clear_renderer, state, .{ .rows = 4, .cols = 16 });
    try std.testing.expectEqual(@as(usize, 1), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\x1b[r") != null);
}

test "reconnect overlay scrolls outer rows into scrollback when expansion consumes them" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.bufferedXtermCompatible(&drawn);
    const state = try drawLines(.{
        .renderer = renderer,
        .size = .{ .rows = 4, .cols = 16 },
        .viewport_offset = 3,
        .previous = null,
        .lines = &.{
            .{ .text = "one", .alignment = .center },
            .{ .text = "two", .alignment = .left },
        },
    });
    try std.testing.expectEqual(@as(u16, 2), state.scroll_lines);
    try std.testing.expect(!state.restores_expansion);
    try std.testing.expectEqual(@as(u16, 1), state.viewport_offset);
    try std.testing.expectEqual(@as(u16, 3), state.restore_viewport_offset);
    try std.testing.expect(std.mem.indexOf(u8, drawn.items, "\x1b[2;4r") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn.items, "\x1b[4;1H\r\n\r\n") != null);

    var cleared = std.ArrayList(u8).empty;
    defer cleared.deinit(std.testing.allocator);
    const clear_renderer = client_renderer.Renderer.bufferedXtermCompatible(&cleared);
    try eraseOverlayRows(clear_renderer, state, .{ .rows = 4, .cols = 16 });
    try restoreOverlayExpansion(clear_renderer, state, .{ .rows = 4, .cols = 16 });
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expectEqual(@as(u16, 1), clearedOverlayViewportOffset(state));
}
