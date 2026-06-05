const std = @import("std");

const io = @import("io.zig");
const process_exit = @import("process_exit.zig");
const session_agent = @import("session_agent.zig");

pub fn run(args: []const []const u8) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--session-dir")) {
        try io.writeAll(2, "sessh: :internal-session-agent: requires --session-dir DIR\n");
        return process_exit.request(64);
    }
    return session_agent.runSessionAgent(args[1]);
}
