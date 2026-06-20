const std = @import("std");

const remote_shell = @import("remote_shell.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");

const SshTarget = ssh_transport_process.Target;

pub fn visibleMessage(
    allocator: std.mem.Allocator,
    target: SshTarget,
    term: std.process.Child.Term,
) ![]u8 {
    var message = std.ArrayList(u8).empty;
    errdefer message.deinit(allocator);
    try message.appendSlice(allocator, "`ssh");
    for (target.options) |arg| {
        try message.append(allocator, ' ');
        try appendShellArg(allocator, &message, arg);
    }
    try message.append(allocator, ' ');
    try appendShellArg(allocator, &message, target.host);
    try message.appendSlice(allocator, "` failed (");
    switch (term) {
        .Exited => |code| try message.writer(allocator).print("exitcode={}", .{code}),
        .Signal => |signal| try message.writer(allocator).print("signal={}", .{signal}),
        else => unreachable,
    }
    try message.append(allocator, ')');
    return message.toOwnedSlice(allocator);
}

fn appendShellArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (remote_shell.isPlainShellArg(arg)) {
        try out.appendSlice(allocator, arg);
        return;
    }
    const quoted = try remote_shell.shellQuote(allocator, arg);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

test "visibleMessage formats ssh argv and exit status" {
    const allocator = std.testing.allocator;
    const message = try visibleMessage(allocator, .{
        .options = &.{ "-vvv", "-oProxyCommand=echo hi" },
        .host = "test-host",
    }, .{ .Exited = 255 });
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "`ssh -vvv '-oProxyCommand=echo hi' test-host` failed (exitcode=255)",
        message,
    );
}

test "visibleMessage formats signal status" {
    const allocator = std.testing.allocator;
    const message = try visibleMessage(allocator, .{
        .options = &.{},
        .host = "test host",
    }, .{ .Signal = 9 });
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "`ssh 'test host'` failed (signal=9)",
        message,
    );
}
