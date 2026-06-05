const std = @import("std");

const ssh_client = @import("ssh_client.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const sessh_args = try argsFromInternal(allocator, args);
    defer allocator.free(sessh_args);
    return ssh_client.run(allocator, sessh_args);
}

fn argsFromInternal(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], ":internal-sessh:"));

    const sessh_args = try allocator.alloc([]const u8, args.len - 1);
    sessh_args[0] = args[0];
    @memcpy(sessh_args[1..], args[2..]);
    return sessh_args;
}

test "internal sessh modality removes sentinel" {
    const rewritten = try argsFromInternal(std.testing.allocator, &.{
        "sesshmux-macos-aarch64",
        ":internal-sessh:",
        "-v",
        "example.com",
    });
    defer std.testing.allocator.free(rewritten);

    try std.testing.expectEqual(@as(usize, 3), rewritten.len);
    try std.testing.expectEqualStrings("sesshmux-macos-aarch64", rewritten[0]);
    try std.testing.expectEqualStrings("-v", rewritten[1]);
    try std.testing.expectEqualStrings("example.com", rewritten[2]);
}
