const std = @import("std");
const c = std.c;

const io = @import("../core/io.zig");

/// Shared title-bar status helpers for reconnect UI.
///
/// Normal sessh reconnects and no-terminal-emulator reconnects have different
/// places they can draw text, but the title-bar wording and OSC title escaping
/// should stay identical. These helpers only write temporary local status; the
/// caller still decides what title is safe to restore afterward.
pub fn formatDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    const seconds = @max(@divTrunc(delay_ms + 999, 1000), 1);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{}sec", .{seconds});
    const minutes = @divTrunc(seconds + 59, 60);
    return std.fmt.bufPrint(buf, "{}min", .{minutes});
}

pub const Controls = struct {
    ctrl_r: bool = false,
    ctrl_c_detach: bool = false,
};

pub fn retryStatus(buf: []u8, delay_ms: u64, controls: Controls) ![]const u8 {
    var delay_buf: [16]u8 = undefined;
    const delay = try formatDelay(delay_ms, &delay_buf);
    if (controls.ctrl_r and controls.ctrl_c_detach) {
        return std.fmt.bufPrint(buf, "sessh: disconnected: Retry connecting {s}. CTRL-R now. CTRL-C detach", .{delay});
    }
    if (controls.ctrl_r) {
        return std.fmt.bufPrint(buf, "sessh: disconnected: Retry connecting {s}. CTRL-R now", .{delay});
    }
    if (controls.ctrl_c_detach) {
        return std.fmt.bufPrint(buf, "sessh: disconnected: Retry connecting {s}. CTRL-C detach", .{delay});
    }
    return std.fmt.bufPrint(buf, "sessh: disconnected: Retry connecting {s}", .{delay});
}

pub fn reconnectingStatus(controls: Controls) []const u8 {
    if (controls.ctrl_r and controls.ctrl_c_detach) return "sessh: disconnected: Reconnecting... CTRL-R now. CTRL-C detach";
    if (controls.ctrl_r) return "sessh: disconnected: Reconnecting... CTRL-R now";
    if (controls.ctrl_c_detach) return "sessh: disconnected: Reconnecting... CTRL-C detach";
    return "sessh: disconnected: Reconnecting...";
}

pub fn writeRetryTitle(fd: c.fd_t, delay_ms: u64) !void {
    var title_buf: [48]u8 = undefined;
    const title = try retryTitle(delay_ms, &title_buf);
    try writeTitle(fd, title);
}

pub fn writeRetryNowTitle(fd: c.fd_t, delay_ms: u64) !void {
    var title_buf: [48]u8 = undefined;
    const title = try retryNowTitle(delay_ms, &title_buf);
    try writeTitle(fd, title);
}

pub fn writeReconnectingTitle(fd: c.fd_t) !void {
    try writeTitle(fd, "reconnecting");
}

pub fn writeReconnectingNowTitle(fd: c.fd_t) !void {
    try writeTitle(fd, "reconnecting CTRL-R");
}

pub fn writeConnectionReadyTitle(fd: c.fd_t) !void {
    try writeTitle(fd, "connection ready");
}

pub fn writeSwitchCountdownTitle(fd: c.fd_t, delay_ms: u64) !void {
    var title_buf: [48]u8 = undefined;
    const title = try switchCountdownTitle(delay_ms, &title_buf);
    try writeTitle(fd, title);
}

pub fn retryTitle(delay_ms: u64, buf: []u8) ![]const u8 {
    var delay_buf: [16]u8 = undefined;
    const delay = try formatDelay(delay_ms, &delay_buf);
    return std.fmt.bufPrint(buf, "{s} until retry connect", .{delay});
}

pub fn retryNowTitle(delay_ms: u64, buf: []u8) ![]const u8 {
    var delay_buf: [16]u8 = undefined;
    const delay = try formatDelay(delay_ms, &delay_buf);
    return std.fmt.bufPrint(buf, "{s} retry CTRL-R", .{delay});
}

pub fn switchCountdownTitle(delay_ms: u64, buf: []u8) ![]const u8 {
    var delay_buf: [16]u8 = undefined;
    const delay = try formatDelay(delay_ms, &delay_buf);
    return std.fmt.bufPrint(buf, "{s} until switch", .{delay});
}

pub fn writeTitle(fd: c.fd_t, title: []const u8) !void {
    try io.writeAll(fd, "\x1b]2;");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (title) |byte| {
        buf[len] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        len += 1;
        if (len == buf.len) {
            try io.writeAll(fd, buf[0..len]);
            len = 0;
        }
    }
    if (len > 0) try io.writeAll(fd, buf[0..len]);
    try io.writeAll(fd, "\x1b\\");
}

test "retry title uses compact reconnect delay" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("5sec until retry connect", try retryTitle(5_000, &buf));
    try std.testing.expectEqualStrings("1min until retry connect", try retryTitle(60_000, &buf));
    try std.testing.expectEqualStrings("5sec retry CTRL-R", try retryNowTitle(5_000, &buf));
    try std.testing.expectEqualStrings("1min retry CTRL-R", try retryNowTitle(60_000, &buf));
}

test "retry status includes available controls" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Retry connecting 5sec. CTRL-R now. CTRL-C detach",
        try retryStatus(&buf, 5_000, .{ .ctrl_r = true, .ctrl_c_detach = true }),
    );
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Retry connecting 5sec. CTRL-R now",
        try retryStatus(&buf, 5_000, .{ .ctrl_r = true }),
    );
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Reconnecting... CTRL-R now. CTRL-C detach",
        reconnectingStatus(.{ .ctrl_r = true, .ctrl_c_detach = true }),
    );
}

test "writeTitle sanitizes control bytes" {
    const posix = std.posix;
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try writeTitle(fds[1], "a\nb\x7fc");

    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("\x1b]2;a b c\x1b\\", buf[0..n]);
}
