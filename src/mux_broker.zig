const std = @import("std");

const broker = @import("broker.zig");
const io = @import("io.zig");
const process_exit = @import("process_exit.zig");

pub fn runSessionBroker(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return broker.run(allocator, exe, args);
}

pub fn runControl(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 0) {
        try io.writeAll(2, "sessh: :internal-control: does not accept arguments\n");
        return process_exit.request(64);
    }
    return broker.runControl(allocator);
}
