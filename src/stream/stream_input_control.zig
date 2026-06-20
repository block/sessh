const std = @import("std");

const reconnect_control = @import("../reconnect/control.zig");
const terminal = @import("../tty/terminal.zig");

const filter_scratch_bytes = 16 * 1024;

pub const StreamControlAction = enum {
    none,
    reconnect,
    disconnect,
    help,
    interrupt,
};

pub const StreamInputControl = struct {
    enabled: bool,
    escape_enabled: bool = false,
    status_visible: bool = false,
    reconnect_requested: bool = false,
    disconnect_requested: bool = false,
    help_requested: bool = false,
    escape_filter: terminal.EscapeFilter = .{},

    pub fn filter(self: *StreamInputControl, bytes: []const u8, out: []u8) []const u8 {
        var input = bytes;
        var scratch: [filter_scratch_bytes]u8 = undefined;
        if (self.escape_enabled) {
            const result = self.escape_filter.filter(bytes, &scratch);
            if (result.end) |end| switch (end) {
                .disconnect => self.disconnect_requested = true,
                .help => self.help_requested = true,
                .repaint => {},
            };
            input = result.bytes;
        }

        if (!self.enabled or !self.status_visible) {
            @memcpy(out[0..input.len], input);
            return out[0..input.len];
        }
        var written: usize = 0;
        for (input) |byte| {
            if (byte == reconnect_control.ctrl_r) {
                self.reconnect_requested = true;
                continue;
            }
            out[written] = byte;
            written += 1;
        }
        return out[0..written];
    }

    pub fn observeControlOnly(self: *StreamInputControl, bytes: []const u8) void {
        var input = bytes;
        var scratch: [filter_scratch_bytes]u8 = undefined;
        if (self.escape_enabled) {
            const result = self.escape_filter.filter(bytes, &scratch);
            if (result.end) |end| switch (end) {
                .disconnect => self.disconnect_requested = true,
                .help => self.help_requested = true,
                .repaint => {},
            };
            input = result.bytes;
        }

        if (!self.enabled or !self.status_visible) return;
        for (input) |byte| {
            if (byte == reconnect_control.ctrl_r) self.reconnect_requested = true;
        }
    }

    pub fn consumeAction(self: *StreamInputControl) StreamControlAction {
        if (self.disconnect_requested) {
            self.disconnect_requested = false;
            self.reconnect_requested = false;
            self.help_requested = false;
            return .disconnect;
        }
        if (self.help_requested) {
            self.help_requested = false;
            return .help;
        }
        const requested = self.reconnect_requested;
        self.reconnect_requested = false;
        return if (requested) .reconnect else .none;
    }
};

test "stream input control intercepts only reconnect UI controls" {
    var control = StreamInputControl{
        .enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("ab", control.filter("a\x12b", &out));
    try std.testing.expectEqual(StreamControlAction.reconnect, control.consumeAction());

    try std.testing.expectEqualStrings("\x03", control.filter("\x03", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());

    control.status_visible = false;
    try std.testing.expectEqualStrings("\x12", control.filter("\x12", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}

test "stream control-only input never forwards bytes" {
    var control = StreamInputControl{
        .enabled = true,
        .status_visible = true,
    };

    control.observeControlOnly("a\x12b");
    try std.testing.expectEqual(StreamControlAction.reconnect, control.consumeAction());

    control.observeControlOnly("abc");
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());

    control.status_visible = false;
    control.observeControlOnly("\x12");
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}

test "stream input control uses ssh disconnect escape for proxy streams" {
    var control = StreamInputControl{
        .enabled = true,
        .escape_enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("", control.filter("~.", &out));
    try std.testing.expectEqual(StreamControlAction.disconnect, control.consumeAction());

    try std.testing.expectEqualStrings("~k", control.filter("~k", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}

test "stream input control supports ssh help and doubled tilde escapes" {
    var control = StreamInputControl{
        .enabled = true,
        .escape_enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("", control.filter("~?", &out));
    try std.testing.expectEqual(StreamControlAction.help, control.consumeAction());

    try std.testing.expectEqualStrings("~hello", control.filter("~~hello", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}
