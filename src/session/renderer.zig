const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");

pub const CursorStyle = enum(u8) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const CellAttrs = struct {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    underline_style: UnderlineStyle = .single,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
};

pub const UnderlineStyle = enum(u8) {
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

pub const TerminalModes = struct {
    mode_flags: u32 = 0,
    mouse_tracking: MouseTracking = .disabled,
    mouse_sgr: bool = false,
    kitty_keyboard_flags: u5 = 0,

    pub const insert_mode: u32 = 1 << 0;
    pub const origin_mode: u32 = 1 << 1;
    pub const auto_wrap: u32 = 1 << 2;
    pub const application_cursor_keys: u32 = 1 << 3;
    pub const focus_reporting: u32 = 1 << 4;
    pub const bracketed_paste: u32 = 1 << 5;

    pub fn eql(self: TerminalModes, other: TerminalModes) bool {
        return self.mode_flags == other.mode_flags and
            self.mouse_tracking == other.mouse_tracking and
            self.mouse_sgr == other.mouse_sgr and
            self.kitty_keyboard_flags == other.kitty_keyboard_flags;
    }
};

pub const DefaultColors = struct {
    foreground: Color = .default,
    background: Color = .default,

    pub fn eql(self: DefaultColors, other: DefaultColors) bool {
        return colorEqual(self.foreground, other.foreground) and
            colorEqual(self.background, other.background);
    }

    pub fn isDefault(self: DefaultColors) bool {
        return colorEqual(self.foreground, .default) and
            colorEqual(self.background, .default);
    }
};

pub const MouseTracking = enum(u8) {
    disabled = 0,
    normal = 1,
    button = 2,
    any = 3,
};

pub const Cell = struct {
    text: []const u8,
    display_width: u8 = 1,
    attrs: CellAttrs = .{},
    hyperlink: ?[]const u8 = null,
};

pub const Row = struct {
    cells: []const Cell,
};

pub const Snapshot = struct {
    rows: []const Row,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool = true,
    cursor_style: CursorStyle = .default,
};

pub const Capabilities = struct {
    kind: Kind,

    pub const Kind = enum {
        xterm_compatible,
        dumb,
    };

    /// This is the terminfo boundary for the client renderer. Today it selects
    /// a conservative built-in xterm-compatible capability set because sessh is
    /// targeting modern xterm-family terminals first. The rest of the client
    /// should stay behind this boundary so a real terminfo-backed resolver can
    /// replace this later without changing session logic.
    pub fn detect(term: ?[]const u8) Capabilities {
        const value = term orelse return .{ .kind = .dumb };
        if (value.len == 0 or std.mem.eql(u8, value, "dumb")) return .{ .kind = .dumb };
        return .{ .kind = .xterm_compatible };
    }

    pub fn detectFromEnv() Capabilities {
        const term_z = c.getenv("TERM") orelse return detect(null);
        return detect(std.mem.span(term_z));
    }

    pub fn supportsRendering(self: Capabilities) bool {
        return self.kind != .dumb;
    }
};

pub const Renderer = struct {
    output: Output,
    caps: Capabilities,

    const Output = union(enum) {
        fd: c.fd_t,
        buffer: *std.ArrayList(u8),
    };

    pub fn init(fd: c.fd_t) Renderer {
        return .{ .output = .{ .fd = fd }, .caps = Capabilities.detectFromEnv() };
    }

    pub fn withCapabilities(fd: c.fd_t, caps: Capabilities) Renderer {
        return .{ .output = .{ .fd = fd }, .caps = caps };
    }

    pub fn buffered(buffer: *std.ArrayList(u8), caps: Capabilities) Renderer {
        return .{ .output = .{ .buffer = buffer }, .caps = caps };
    }

    pub fn restorePresentation(self: Renderer, kitty_keyboard_flags: u5) !void {
        if (!self.caps.supportsRendering()) return;
        try self.restoreOverlayPresentation();
        try self.disableMouseTracking();
        try self.setPrivateMode(1, false);
        try self.write("\x1b[?1004l");
        try self.write("\x1b[?2004l");
        try self.setKittyKeyboardFlags(kitty_keyboard_flags);
        try self.write("\x1b[?25h");
        try self.setCursorStyle(.default);
    }

    pub fn restoreOverlayPresentation(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return;
        try self.setHyperlink(null);
        try self.write("\x1b[0m");
    }

    pub fn clearScrollback(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[3J");
    }

    pub fn clearForReplace(self: Renderer) !void {
        try self.clearVisible();
        try self.clearScrollback();
    }

    pub fn clearVisible(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[2J");
        try self.moveCursor(0, 0);
    }

    pub fn enterAlternateScreen(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[?1049h");
    }

    pub fn leaveAlternateScreen(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[?1049l");
    }

    pub fn repaintSnapshot(self: Renderer, snapshot: Snapshot) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[?25l");
        try self.clearForReplace();
        for (snapshot.rows, 0..) |row, row_index| {
            if (row_index > 0) try self.write("\r\n");
            try self.renderRow(row);
        }
        try self.write("\x1b[0m");
        try self.moveCursor(snapshot.cursor_row, snapshot.cursor_col);
        if (snapshot.cursor_visible) {
            try self.write("\x1b[?25h");
        } else {
            try self.write("\x1b[?25l");
        }
        try self.setCursorStyle(snapshot.cursor_style);
    }

    pub fn repaintPlainText(
        self: Renderer,
        text: []const u8,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
        cursor_style: CursorStyle,
    ) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[?25l");
        try self.clearForReplace();

        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try self.write("\r\n");
            first = false;
            try self.write(line);
        }

        try self.write("\x1b[0m");
        try self.moveCursor(cursor_row, cursor_col);
        if (cursor_visible) {
            try self.write("\x1b[?25h");
        } else {
            try self.write("\x1b[?25l");
        }
        try self.setCursorStyle(cursor_style);
    }

    pub fn appendPlainText(self: Renderer, text: []const u8) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;

        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try self.write("\r\n");
            first = false;
            try self.write(line);
        }
    }

    pub fn carriageReturn(self: Renderer) !void {
        try self.write("\r");
    }

    pub fn newline(self: Renderer) !void {
        try self.write("\r\n");
    }

    pub fn reverseIndex(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1bM");
    }

    pub fn clearLine(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[2K");
    }

    pub fn setScrollRegion(self: Renderer, top: u16, bottom: u16) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{};{}r", .{ top + 1, bottom + 1 });
        try self.write(seq);
    }

    pub fn resetScrollRegion(self: Renderer) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b[r");
    }

    pub fn cursorUp(self: Renderer, count: u16) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        if (count == 0) return;
        var buf: [24]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{}A", .{count});
        try self.write(seq);
    }

    pub fn cursorDown(self: Renderer, count: u16) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        if (count == 0) return;
        var buf: [24]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{}B", .{count});
        try self.write(seq);
    }

    pub fn cursorRight(self: Renderer, count: u16) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        if (count == 0) return;
        var buf: [24]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{}C", .{count});
        try self.write(seq);
    }

    pub fn setCursorVisible(self: Renderer, visible: bool) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write(if (visible) "\x1b[?25h" else "\x1b[?25l");
    }

    pub fn writeRaw(self: Renderer, bytes: []const u8) !void {
        try self.write(bytes);
    }

    pub fn renderRow(self: Renderer, row: Row) !void {
        var current = CellAttrs{};
        var current_hyperlink: ?[]const u8 = null;
        var text_run = std.ArrayList(u8).empty;
        defer text_run.deinit(app_allocator.allocator());

        try self.applyAttrs(current);
        for (row.cells) |cell| {
            if (!optionalStringEqual(current_hyperlink, cell.hyperlink)) {
                try self.flushTextRun(&text_run);
                try self.setHyperlink(cell.hyperlink);
                current_hyperlink = cell.hyperlink;
            }
            if (!attrsEqual(current, cell.attrs)) {
                try self.flushTextRun(&text_run);
                try self.applyAttrs(cell.attrs);
                current = cell.attrs;
            }
            try text_run.appendSlice(app_allocator.allocator(), cell.text);
            if (cell.text.len == 0 and cell.display_width > 0) {
                var i: u8 = 0;
                while (i < cell.display_width) : (i += 1) try text_run.append(app_allocator.allocator(), ' ');
            }
        }
        try self.flushTextRun(&text_run);
        if (current_hyperlink != null) try self.setHyperlink(null);
        try self.write("\x1b[0m");
    }

    pub fn moveCursor(self: Renderer, row: u16, col: u16) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row + 1, col + 1 });
        try self.write(seq);
    }

    pub fn setCursorStyle(self: Renderer, style: CursorStyle) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        var buf: [16]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{} q", .{@intFromEnum(style)});
        try self.write(seq);
    }

    pub fn setTitle(self: Renderer, title: []const u8) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.write("\x1b]2;");
        try self.writeSanitizedOscText(title);
        try self.write("\x1b\\");
    }

    pub fn applyDefaultColors(self: Renderer, colors: DefaultColors) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;
        try self.applyDefaultColor(10, colors.foreground);
        try self.applyDefaultColor(11, colors.background);
    }

    pub fn applyTerminalModes(self: Renderer, modes: TerminalModes) !void {
        if (!self.caps.supportsRendering()) return error.UnsupportedTerminal;

        try self.setPrivateMode(1000, false);
        try self.setPrivateMode(1002, false);
        try self.setPrivateMode(1003, false);
        switch (modes.mouse_tracking) {
            .disabled => {},
            .normal => try self.setPrivateMode(1000, true),
            .button => try self.setPrivateMode(1002, true),
            .any => try self.setPrivateMode(1003, true),
        }
        try self.setPrivateMode(1006, modes.mouse_sgr);
        try self.setPrivateMode(1, (modes.mode_flags & TerminalModes.application_cursor_keys) != 0);
        try self.setPrivateMode(1004, (modes.mode_flags & TerminalModes.focus_reporting) != 0);
        try self.setPrivateMode(2004, (modes.mode_flags & TerminalModes.bracketed_paste) != 0);
        try self.setKittyKeyboardFlags(modes.kitty_keyboard_flags);
    }

    fn disableMouseTracking(self: Renderer) !void {
        try self.write("\x1b[?1000l");
        try self.write("\x1b[?1002l");
        try self.write("\x1b[?1003l");
        try self.write("\x1b[?1006l");
        try self.write("\x1b[?1015l");
    }

    fn setPrivateMode(self: Renderer, mode: u16, enabled: bool) !void {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[?{}{s}", .{ mode, if (enabled) "h" else "l" });
        try self.write(seq);
    }

    fn setKittyKeyboardFlags(self: Renderer, flags: u5) !void {
        var buf: [16]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[={}u", .{flags});
        try self.write(seq);
    }

    pub fn resetDefaultColors(self: Renderer) !void {
        try self.write("\x1b]110\x1b\\");
        try self.write("\x1b]111\x1b\\");
    }

    fn applyDefaultColor(self: Renderer, osc: u8, color: Color) !void {
        switch (color) {
            .default => {
                var buf: [16]u8 = undefined;
                const reset_osc: u16 = if (osc == 10) 110 else 111;
                const seq = try std.fmt.bufPrint(&buf, "\x1b]{}\x1b\\", .{reset_osc});
                try self.write(seq);
            },
            .rgb => |rgb| {
                var buf: [40]u8 = undefined;
                const seq = try std.fmt.bufPrint(
                    &buf,
                    "\x1b]{};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                    .{ osc, rgb.r, rgb.g, rgb.b },
                );
                try self.write(seq);
            },
            .indexed => return error.UnsupportedDefaultColor,
        }
    }

    fn setHyperlink(self: Renderer, uri: ?[]const u8) !void {
        try self.write("\x1b]8;;");
        if (uri) |value| try self.write(value);
        try self.write("\x1b\\");
    }

    fn writeSanitizedOscText(self: Renderer, value: []const u8) !void {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (value) |byte| {
            const safe_byte: u8 = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
            buf[len] = safe_byte;
            len += 1;
            if (len == buf.len) {
                try self.write(buf[0..len]);
                len = 0;
            }
        }
        if (len > 0) try self.write(buf[0..len]);
    }

    fn applyAttrs(self: Renderer, attrs: CellAttrs) !void {
        try self.write("\x1b[0m");
        if (attrs.bold) try self.write("\x1b[1m");
        if (attrs.faint) try self.write("\x1b[2m");
        if (attrs.italic) try self.write("\x1b[3m");
        if (attrs.underline) try self.applyUnderline(attrs.underline_style);
        if (attrs.blink) try self.write("\x1b[5m");
        if (attrs.inverse) try self.write("\x1b[7m");
        if (attrs.hidden) try self.write("\x1b[8m");
        if (attrs.strikethrough) try self.write("\x1b[9m");
        if (attrs.overline) try self.write("\x1b[53m");
        try self.applyColor(38, attrs.fg);
        try self.applyColor(48, attrs.bg);
        try self.applyColor(58, attrs.underline_color);
    }

    fn applyUnderline(self: Renderer, style: UnderlineStyle) !void {
        switch (style) {
            .single => try self.write("\x1b[4m"),
            .double => try self.write("\x1b[4:2m"),
            .curly => try self.write("\x1b[4:3m"),
            .dotted => try self.write("\x1b[4:4m"),
            .dashed => try self.write("\x1b[4:5m"),
        }
    }

    fn flushTextRun(self: Renderer, text_run: *std.ArrayList(u8)) !void {
        if (text_run.items.len == 0) return;
        try self.write(text_run.items);
        text_run.clearRetainingCapacity();
    }

    fn applyColor(self: Renderer, prefix: u8, color: Color) !void {
        switch (color) {
            .default => {},
            .indexed => |index| {
                var buf: [24]u8 = undefined;
                const sgr_code = if ((prefix == 38 or prefix == 48) and index < 8)
                    @as(u16, if (prefix == 38) 30 else 40) + index
                else if ((prefix == 38 or prefix == 48) and index < 16)
                    @as(u16, if (prefix == 38) 90 else 100) + (index - 8)
                else
                    null;
                const seq = if (sgr_code) |code|
                    try std.fmt.bufPrint(&buf, "\x1b[{}m", .{code})
                else
                    try std.fmt.bufPrint(&buf, "\x1b[{};5;{}m", .{ prefix, index });
                try self.write(seq);
            },
            .rgb => |rgb| {
                var buf: [32]u8 = undefined;
                const seq = try std.fmt.bufPrint(&buf, "\x1b[{};2;{};{};{}m", .{ prefix, rgb.r, rgb.g, rgb.b });
                try self.write(seq);
            },
        }
    }

    fn write(self: Renderer, bytes: []const u8) !void {
        switch (self.output) {
            .fd => |fd| try io.writeAll(fd, bytes),
            .buffer => |buffer| try buffer.appendSlice(app_allocator.allocator(), bytes),
        }
    }
};

pub const PresentationGuard = struct {
    renderer: Renderer,
    cleanup_title: ?[]const u8 = null,
    initial_kitty_keyboard_flags: u5 = 0,
    alternate_screen_active: bool = false,
    active: bool = true,

    pub fn init(fd: c.fd_t) PresentationGuard {
        return .{ .renderer = Renderer.init(fd) };
    }

    pub fn initWithInitialKittyKeyboardFlags(fd: c.fd_t, initial_kitty_keyboard_flags: u5) PresentationGuard {
        return .{ .renderer = Renderer.init(fd), .initial_kitty_keyboard_flags = initial_kitty_keyboard_flags };
    }

    pub fn initWithCleanupTitle(fd: c.fd_t, cleanup_title: []const u8) PresentationGuard {
        return .{ .renderer = Renderer.init(fd), .cleanup_title = cleanup_title };
    }

    pub fn initWithCleanupTitleAndInitialKittyKeyboardFlags(
        fd: c.fd_t,
        cleanup_title: []const u8,
        initial_kitty_keyboard_flags: u5,
    ) PresentationGuard {
        return .{
            .renderer = Renderer.init(fd),
            .cleanup_title = cleanup_title,
            .initial_kitty_keyboard_flags = initial_kitty_keyboard_flags,
        };
    }

    pub fn withCapabilities(fd: c.fd_t, caps: Capabilities) PresentationGuard {
        return .{ .renderer = Renderer.withCapabilities(fd, caps) };
    }

    pub fn withCapabilitiesAndInitialKittyKeyboardFlags(
        fd: c.fd_t,
        caps: Capabilities,
        initial_kitty_keyboard_flags: u5,
    ) PresentationGuard {
        return .{
            .renderer = Renderer.withCapabilities(fd, caps),
            .initial_kitty_keyboard_flags = initial_kitty_keyboard_flags,
        };
    }

    pub fn withCapabilitiesAndCleanupTitle(fd: c.fd_t, caps: Capabilities, cleanup_title: []const u8) PresentationGuard {
        return .{
            .renderer = Renderer.withCapabilities(fd, caps),
            .cleanup_title = cleanup_title,
        };
    }

    pub fn enterAlternateScreen(self: *PresentationGuard) !void {
        if (self.alternate_screen_active) return;
        try self.renderer.enterAlternateScreen();
        self.alternate_screen_active = true;
    }

    pub fn leaveAlternateScreen(self: *PresentationGuard) !void {
        if (!self.alternate_screen_active) return;
        try self.renderer.leaveAlternateScreen();
        self.alternate_screen_active = false;
    }

    pub fn restore(self: *PresentationGuard) void {
        if (!self.active) return;
        self.leaveAlternateScreen() catch {};
        self.renderer.restorePresentation(self.initial_kitty_keyboard_flags) catch {};
        if (self.cleanup_title) |title| self.renderer.setTitle(title) catch {};
        self.active = false;
    }
};

fn attrsEqual(a: CellAttrs, b: CellAttrs) bool {
    return a.bold == b.bold and
        a.faint == b.faint and
        a.italic == b.italic and
        a.underline == b.underline and
        a.underline_style == b.underline_style and
        a.blink == b.blink and
        a.inverse == b.inverse and
        a.hidden == b.hidden and
        a.strikethrough == b.strikethrough and
        a.overline == b.overline and
        colorEqual(a.fg, b.fg) and
        colorEqual(a.bg, b.bg) and
        colorEqual(a.underline_color, b.underline_color);
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn colorEqual(a: Color, b: Color) bool {
    return switch (a) {
        .default => switch (b) {
            .default => true,
            else => false,
        },
        .indexed => |a_index| switch (b) {
            .indexed => |b_index| a_index == b_index,
            else => false,
        },
        .rgb => |a_rgb| switch (b) {
            .rgb => |b_rgb| a_rgb.r == b_rgb.r and a_rgb.g == b_rgb.g and a_rgb.b == b_rgb.b,
            else => false,
        },
    };
}

test "capability detection rejects dumb terminals" {
    try std.testing.expect(!Capabilities.detect(null).supportsRendering());
    try std.testing.expect(!Capabilities.detect("").supportsRendering());
    try std.testing.expect(!Capabilities.detect("dumb").supportsRendering());
    try std.testing.expect(Capabilities.detect("xterm-256color").supportsRendering());
}

test "cell attribute equality includes color payloads" {
    try std.testing.expect(attrsEqual(.{}, .{}));
    try std.testing.expect(!attrsEqual(.{ .bold = true }, .{}));
    try std.testing.expect(attrsEqual(.{ .fg = .{ .indexed = 2 } }, .{ .fg = .{ .indexed = 2 } }));
    try std.testing.expect(!attrsEqual(.{ .fg = .{ .indexed = 2 } }, .{ .fg = .{ .indexed = 3 } }));
    try std.testing.expect(attrsEqual(
        .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
        .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
    ));
}

test "render row emits style and color sequences" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    const cells = [_]Cell{.{
        .text = "X",
        .attrs = .{
            .bold = true,
            .fg = .{ .indexed = 1 },
            .bg = .{ .rgb = .{ .r = 2, .g = 3, .b = 4 } },
        },
    }};
    try renderer.renderRow(.{ .cells = &cells });

    var buf: [256]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b[0m\x1b[0m\x1b[1m\x1b[31m\x1b[48;2;2;3;4mX\x1b[0m",
        buf[0..len],
    );
}

test "render row wraps hyperlink cells in OSC 8" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    const cells = [_]Cell{.{
        .text = "link",
        .hyperlink = "https://example.test/",
    }};
    try renderer.renderRow(.{ .cells = &cells });

    var buf: [256]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b[0m\x1b]8;;https://example.test/\x1b\\link\x1b]8;;\x1b\\\x1b[0m",
        buf[0..len],
    );
}

test "set title emits an OSC title sequence" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.setTitle("/tmp/sessh-title");
    posix.close(fds[1]);

    var buf: [256]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("\x1b]2;/tmp/sessh-title\x1b\\", buf[0..len]);
}

test "default colors emit OSC 10 and OSC 11 sequences" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.applyDefaultColors(.{
        .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .background = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } },
    });
    try renderer.resetDefaultColors();
    posix.close(fds[1]);

    var buf: [256]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b]10;rgb:01/02/03\x1b\\\x1b]11;rgb:04/05/06\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\",
        buf[0..len],
    );
}

test "clear scrollback emits only retained scrollback clear" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.clearScrollback();
    posix.close(fds[1]);

    var buf: [64]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("\x1b[3J", buf[0..len]);
}

test "restore presentation does not clear or swap the screen" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.restorePresentation(0);

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3J") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049l") == null);
}

test "restore presentation resets every modeled local terminal side effect" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.restorePresentation(0);

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1015l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=0u") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?25h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[0 q") != null);
}

test "restore presentation restores initial kitty keyboard flags" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.restorePresentation(7);

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=7u") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=0u") == null);
}

test "restore state presentation preserves input and event modes" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.restoreOverlayPresentation();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1004l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004l") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=0u") == null);
}

test "presentation guard restores cleanup title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = PresentationGuard.withCapabilitiesAndCleanupTitle(
        fds[1],
        .{ .kind = .xterm_compatible },
        "/Users/tomm/Development/sessh",
    );
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]2;/Users/tomm/Development/sessh\x1b\\") != null);
}

test "presentation guard restores captured kitty keyboard flags" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = PresentationGuard.withCapabilitiesAndInitialKittyKeyboardFlags(
        fds[1],
        .{ .kind = .xterm_compatible },
        3,
    );
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=3u") != null);
}

test "presentation guard leaves alternate screen only when it entered it" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = PresentationGuard.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try guard.enterAlternateScreen();
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049l") != null);
}

test "presentation guard does not leave alternate screen when it did not enter it" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = PresentationGuard.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049l") == null);
}

test "apply terminal modes enables input and event modes" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.applyTerminalModes(.{
        .mode_flags = TerminalModes.application_cursor_keys |
            TerminalModes.focus_reporting |
            TerminalModes.bracketed_paste,
        .mouse_tracking = .normal,
        .mouse_sgr = true,
        .kitty_keyboard_flags = 7,
    });
    posix.close(fds[1]);

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1004h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=7u") != null);
}

test "apply terminal modes disables input and event modes" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    const renderer = Renderer.withCapabilities(fds[1], .{ .kind = .xterm_compatible });
    try renderer.applyTerminalModes(.{});
    posix.close(fds[1]);

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=0u") != null);
}
