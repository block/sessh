const std = @import("std");

const mux_parser = @import("parser.zig");
const process_exit = @import("../core/process_exit.zig");
const ssh_client = @import("../transport/ssh.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2 or !mux_parser.isSubcommand(args[1])) {
        try ssh_client.printSshArgError(error.UnsupportedMuxCommand);
        return process_exit.request(64);
    }

    var parsed = mux_parser.parse(allocator, args) catch |err| {
        try ssh_client.printSshArgError(err);
        return process_exit.request(64);
    };
    defer parsed.deinit(allocator);

    return ssh_client.runMuxCommand(allocator, args, parsed.command);
}
