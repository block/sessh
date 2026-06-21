const std = @import("std");
const posix = std.posix;

const core_blocking = @import("blocking.zig");

/// Foreground, user-facing error output.
///
/// This intentionally stays separate from diagnostics/status rendering. These
/// helpers are for CLI errors and terminal-session failure messages where the
/// caller has already decided that writing directly to stderr is the right
/// foreground behavior.
pub fn line(blocking: core_blocking.Blocking, message: []const u8) !void {
    try blocking.writeAll(posix.STDERR_FILENO, "sessh: ");
    try blocking.writeAll(posix.STDERR_FILENO, message);
    try blocking.writeAll(posix.STDERR_FILENO, "\n");
}

pub fn roleLine(blocking: core_blocking.Blocking, role: []const u8, message: []const u8) !void {
    try blocking.writeAll(posix.STDERR_FILENO, role);
    try blocking.writeAll(posix.STDERR_FILENO, ": ");
    try blocking.writeAll(posix.STDERR_FILENO, message);
    try blocking.writeAll(posix.STDERR_FILENO, "\n");
}

pub fn rolePrintLine(blocking: core_blocking.Blocking, role: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try blocking.writeAll(posix.STDERR_FILENO, role);
    try blocking.writeAll(posix.STDERR_FILENO, ": ");
    try blocking.stderrPrint(fmt ++ "\n", args);
}

pub fn printLine(blocking: core_blocking.Blocking, comptime fmt: []const u8, args: anytype) !void {
    try blocking.stderrPrint("sessh: " ++ fmt ++ "\n", args);
}

pub fn cleanTerminalLine(blocking: core_blocking.Blocking, message: []const u8) !void {
    if (std.c.isatty(posix.STDERR_FILENO) != 0) {
        try blocking.writeAll(posix.STDERR_FILENO, "\n");
        try line(blocking, message);
    } else {
        try line(blocking, message);
    }
}

test "user error helpers prefix messages consistently" {
    const blocking = core_blocking.fromTest();
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const original_stderr = try posix.dup(posix.STDERR_FILENO);
    defer posix.close(original_stderr);
    try posix.dup2(fds[1], posix.STDERR_FILENO);
    defer posix.dup2(original_stderr, posix.STDERR_FILENO) catch {};

    try line(blocking, "example");
    try rolePrintLine(blocking, "sessh-role", "formatted {}", .{42});
    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("sessh: example\nsessh-role: formatted 42\n", buf[0..n]);
}
