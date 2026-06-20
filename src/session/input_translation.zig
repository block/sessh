const std = @import("std");

const fixed_buffer = @import("../core/fixed_buffer.zig");
const terminal = @import("../tty/terminal.zig");

const TerminalModes = terminal.TerminalModes;
const WindowSize = terminal.WindowSize;

pub const PendingInput = fixed_buffer.FixedBuffer(128);

pub const ModeState = struct {
    origin: ?terminal.Position = null,
    terminal_modes: TerminalModes = .{},
    terminal_modes_initialized: bool = false,
};

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

pub const TranslateOptions = struct {
    pending: *PendingInput,
    mode: ModeState,
    session_size: WindowSize,
    bytes: []const u8,
    out: *std.ArrayList(u8),
};

// Translate local terminal input from outer-terminal coordinates into the
// remote PTY's coordinate space. Most bytes pass through unchanged; mouse
// reports are held until complete because partial escape sequences cannot be
// safely rewritten or forwarded as text.
pub fn translate(
    allocator: std.mem.Allocator,
    options: TranslateOptions,
) !void {
    const pending = options.pending;
    const mode = options.mode;
    const session_size = options.session_size;
    const bytes = options.bytes;
    const out = options.out;
    if (!localInputParserActive(mode)) {
        if (!pending.isEmpty()) {
            try out.appendSlice(allocator, pending.slice());
            pending.clear();
        }
        try out.appendSlice(allocator, bytes);
        return;
    }

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    if (!pending.isEmpty()) {
        try input.appendSlice(allocator, pending.slice());
        pending.clear();
    }
    try input.appendSlice(allocator, bytes);

    var index: usize = 0;
    while (index < input.items.len) {
        if (input.items[index] != 0x1b) {
            try out.append(allocator, input.items[index]);
            index += 1;
            continue;
        }

        if (mode.terminal_modes_initialized) {
            switch (parseSgrMouseReport(input.items, index)) {
                .complete => |report| {
                    if (sgrMouseActive(mode)) {
                        try appendTranslatedSgrMouseReport(.{
                            .allocator = allocator,
                            .mode = mode,
                            .session_size = session_size,
                            .report = report,
                            .out = out,
                        });
                    }
                    index = report.end;
                    continue;
                },
                .incomplete => {
                    if (sgrMouseActive(mode)) {
                        try savePendingInput(.{
                            .allocator = allocator,
                            .pending_input = pending,
                            .pending_bytes = input.items[index..],
                            .out = out,
                        });
                        return;
                    }
                },
                .not_mouse => {},
            }
        }

        switch (parseFocusReport(input.items, index)) {
            .complete => |report| {
                if (focusReportingActive(mode)) {
                    try out.appendSlice(allocator, input.items[index..report.end]);
                }
                index = report.end;
                continue;
            },
            .incomplete => {
                if (focusReportingActive(mode)) {
                    try savePendingInput(.{
                        .allocator = allocator,
                        .pending_input = pending,
                        .pending_bytes = input.items[index..],
                        .out = out,
                    });
                    return;
                }
            },
            .not_focus => {},
        }

        if (kittyKeyboardActive(mode)) {
            switch (parseXtermModifiedKey(input.items, index)) {
                .complete => |key| {
                    try appendKittyKeyboardKey(allocator, key, out);
                    index = key.end;
                    continue;
                },
                .incomplete => {
                    try savePendingInput(.{
                        .allocator = allocator,
                        .pending_input = pending,
                        .pending_bytes = input.items[index..],
                        .out = out,
                    });
                    return;
                },
                .not_modified => {},
            }
        }

        try out.append(allocator, input.items[index]);
        index += 1;
    }
}

const SavePendingInputOptions = struct {
    allocator: std.mem.Allocator,
    pending_input: *PendingInput,
    pending_bytes: []const u8,
    out: *std.ArrayList(u8),
};

fn savePendingInput(options: SavePendingInputOptions) !void {
    const allocator = options.allocator;
    const pending_input = options.pending_input;
    const pending = options.pending_bytes;
    const out = options.out;
    pending_input.set(pending) catch |err| switch (err) {
        error.FixedBufferTooLarge => try out.appendSlice(allocator, pending),
    };
}

fn localInputParserActive(mode: ModeState) bool {
    return mode.terminal_modes_initialized;
}

fn sgrMouseActive(mode: ModeState) bool {
    return mode.terminal_modes_initialized and
        mode.terminal_modes.mouse_tracking != .disabled and
        mode.terminal_modes.mouse_sgr;
}

fn kittyKeyboardActive(mode: ModeState) bool {
    return mode.terminal_modes_initialized and
        mode.terminal_modes.kitty_keyboard_flags != 0;
}

fn focusReportingActive(mode: ModeState) bool {
    return mode.terminal_modes_initialized and
        (mode.terminal_modes.mode_flags & TerminalModes.focus_reporting) != 0;
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

fn appendKittyKeyboardKey(
    allocator: std.mem.Allocator,
    key: XtermModifiedKey,
    out: *std.ArrayList(u8),
) !void {
    var buf: [32]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&buf, "\x1b[{};{}u", .{ key.key_code, key.modifier });
    try out.appendSlice(allocator, encoded);
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

const TranslatedSgrMouseReportOptions = struct {
    allocator: std.mem.Allocator,
    mode: ModeState,
    session_size: WindowSize,
    report: SgrMouseReport,
    out: *std.ArrayList(u8),
};

fn appendTranslatedSgrMouseReport(options: TranslatedSgrMouseReportOptions) !void {
    const allocator = options.allocator;
    const mode = options.mode;
    const session_size = options.session_size;
    const report = options.report;
    const out = options.out;
    const origin = mode.origin orelse return;
    if (report.row <= origin.row or report.col <= origin.col) return;

    const inner_row = report.row - origin.row;
    const inner_col = report.col - origin.col;
    if (inner_row == 0 or inner_col == 0) return;
    if (inner_row > session_size.rows or inner_col > session_size.cols) return;

    var buf: [64]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &buf,
        "\x1b[<{};{};{}{c}",
        .{ report.button, inner_col, inner_row, report.suffix },
    );
    try out.appendSlice(allocator, encoded);
}

test "SGR mouse input is translated from outer to inner coordinates" {
    var pending = PendingInput{};
    const mode = ModeState{
        .origin = terminal.top_left_position.withRow(4),
        .terminal_modes = .{ .mouse_tracking = .normal, .mouse_sgr = true },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[<0;12;5M",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[<0;12;1M", out.items);

    out.clearRetainingCapacity();
    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[<0;12;3M",
        .out = &out,
    });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "SGR mouse input is dropped when mouse reporting is inactive" {
    var pending = PendingInput{};
    const mode = ModeState{
        .origin = terminal.top_left_position.withRow(4),
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[<0;12;5M",
        .out = &out,
    });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "focus reports are forwarded only while focus reporting is active" {
    var pending = PendingInput{};
    var mode = ModeState{ .terminal_modes_initialized = true };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[I",
        .out = &out,
    });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    mode.terminal_modes.mode_flags = TerminalModes.focus_reporting;
    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[O",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[O", out.items);
}

test "xterm modified key input is translated to kitty when kitty keyboard is active" {
    var pending = PendingInput{};
    const mode = ModeState{
        .terminal_modes = .{ .kitty_keyboard_flags = 7 },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[27;2;13~",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "split xterm modified key input is held and translated after completion" {
    var pending = PendingInput{};
    const mode = ModeState{
        .terminal_modes = .{ .kitty_keyboard_flags = 7 },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[27;2;",
        .out = &out,
    });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(!pending.isEmpty());

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "13~",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[13;2u", out.items);
}

test "xterm modified key input passes through when kitty keyboard is inactive" {
    var pending = PendingInput{};
    const mode = ModeState{};
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[27;2;13~",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[27;2;13~", out.items);
}

test "non-xterm CSI input passes through when kitty keyboard is active" {
    var pending = PendingInput{};
    const mode = ModeState{
        .terminal_modes = .{ .kitty_keyboard_flags = 7 },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b[A",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b[A", out.items);
}

test "plain enter input is not synthesized as kitty when kitty keyboard is active" {
    var pending = PendingInput{};
    const mode = ModeState{
        .terminal_modes = .{ .kitty_keyboard_flags = 7 },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\r",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\r", out.items);
}

test "bare escape is not held by kitty keyboard translation" {
    var pending = PendingInput{};
    const mode = ModeState{
        .terminal_modes = .{ .kitty_keyboard_flags = 7 },
        .terminal_modes_initialized = true,
    };
    const session = WindowSize{ .rows = 24, .cols = 80 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try translate(std.testing.allocator, .{
        .pending = &pending,
        .mode = mode,
        .session_size = session,
        .bytes = "\x1b",
        .out = &out,
    });
    try std.testing.expectEqualStrings("\x1b", out.items);
    try std.testing.expect(pending.isEmpty());
}
