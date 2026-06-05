const std = @import("std");

const stream_agent = @import("stream_agent.zig");

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return stream_agent.runBroker(allocator, exe, args);
}
