const std = @import("std");

const ssh_client = @import("ssh_client.zig");

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return ssh_client.runProxyStream(allocator, exe, args);
}
