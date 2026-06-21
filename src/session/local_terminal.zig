const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_blocking = @import("../core/blocking.zig");
const client_log = @import("../core/client_log.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");

const unknown_viewport_offset: i32 = -1;

pub const ProtocolDefaultColors = struct {
    foreground_color: u32 = 0xffffffff,
    background_color: u32 = 0xffffffff,
};

pub const State = struct {
    size: terminal.WindowSize = .{},
    cursor_position: ?terminal.CursorPosition = null,
    viewport_offset: ?i32 = null,
    default_colors: ProtocolDefaultColors = .{},
    tty_settings: ?tty_settings.Settings = null,
    initial_kitty_keyboard_flags: u5 = 0,

    pub fn deinit(self: *State) void {
        if (self.tty_settings) |*settings| settings.deinit(app_allocator.allocator());
        self.* = .{};
    }
};

pub const Probe = struct {
    blocking: core_blocking.Blocking,
    state: ?State = null,

    pub fn start(blocking: core_blocking.Blocking) Probe {
        return .{
            .blocking = blocking,
            .state = capture(blocking),
        };
    }

    pub fn finish(self: *Probe) State {
        const state = self.state orelse return capture(self.blocking);
        self.state = null;
        return state;
    }

    pub fn deinit(self: *Probe) void {
        if (self.state == null) return;
        var state = self.finish();
        state.deinit();
    }
};

pub fn capture(blocking: core_blocking.Blocking) State {
    // Capture everything the remote terminal worker needs from the visible
    // terminal before the session starts. The worker gets tty modes, size,
    // cursor/viewport position, default colors, and initial kitty keyboard flags.
    var state = State{
        .size = terminal.currentWindowSize(),
    };
    // The normal sessh path runs a terminal emulator on the remote side. Copy
    // portable line-discipline modes, but keep TERM tied to that emulator
    // contract instead of leaking the outer terminal's TERM.
    state.tty_settings = tty_settings.capture(app_allocator.allocator(), posix.STDIN_FILENO, .omit) catch |err| blk: {
        client_log.debug("event=tty_settings_capture_failed error={t}", .{err});
        break :blk null;
    };

    if (c.isatty(posix.STDIN_FILENO) == 0 or c.isatty(posix.STDOUT_FILENO) == 0) return state;

    const probe = terminal.queryTerminalProbe(blocking, .{}) catch {
        state.viewport_offset = unknown_viewport_offset;
        return state;
    };
    state.cursor_position = probe.cursor_position;
    state.viewport_offset = initialViewportOffsetFromCursorPosition(probe.cursor_position);
    state.default_colors = protocolDefaultColorsFromQuery(probe.default_colors);
    state.initial_kitty_keyboard_flags = probe.kitty_keyboard_flags orelse 0;
    return state;
}

fn initialViewportOffsetFromCursorPosition(position: ?terminal.CursorPosition) ?i32 {
    return if (position) |value| @as(i32, @intCast(value.row)) else unknown_viewport_offset;
}

fn protocolDefaultColorsFromQuery(queried: terminal.DefaultColorQuery) ProtocolDefaultColors {
    return .{
        .foreground_color = protocolColorFromRgb(queried.foreground),
        .background_color = protocolColorFromRgb(queried.background),
    };
}

fn protocolColorFromRgb(rgb: ?terminal.Rgb) u32 {
    const value = rgb orelse return 0xffffffff;
    return 0x01000000 |
        (@as(u32, value.r) << 16) |
        (@as(u32, value.g) << 8) |
        @as(u32, value.b);
}

test "initial viewport offset marks missing cursor response unknown" {
    try std.testing.expectEqual(@as(?i32, unknown_viewport_offset), initialViewportOffsetFromCursorPosition(null));
    try std.testing.expectEqual(@as(?i32, 4), initialViewportOffsetFromCursorPosition(.{ .row = 4, .col = 12 }));
}
