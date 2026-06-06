const std = @import("std");

const mux_cli = @import("cli.zig");
const mux_client_control = @import("client_control.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.Debug {
    var parsed = mux_cli.CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var control = mux_cli.ClientControl{};
    var seconds: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) {
        if (try mux_cli.parseSharedOption(scratch, args, &i, &parsed, .client_control)) continue;
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnsupportedMuxOption;
        break;
    }
    if (i >= args.len) return error.MissingDebugAction;
    const action = try mux_cli.parseDebugAction(args[i]);
    i += 1;
    try mux_client_control.parseTail(scratch, args, &i, &parsed, &control, false, action, &seconds);
    try mux_client_control.finish(scratch, &parsed, &control, false, seconds);
    var debug = mux_cli.Debug{
        .action = action,
        .control = control,
    };
    debug.seconds = debug.control.seconds;
    return debug;
}

pub fn appendRemoteArgs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    debug: mux_cli.Debug,
    default_session_ref: ?[]const u8,
) !void {
    return mux_client_control.appendRemoteArgs(allocator, out, "debug", debug.action, debug.control, default_session_ref);
}

test "parse accepts host and id before action" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const debug = try parse(&scratch, &.{ "--host", "test-host", "--id", "s1", "sever-connection", "--last-input" });

    try std.testing.expectEqual(mux_cli.DebugAction.sever_connection, debug.action);
    switch (debug.control.target) {
        .host => |host| try std.testing.expectEqualStrings("test-host", host),
        else => return error.TestUnexpectedTarget,
    }
    try std.testing.expect(debug.control.last_input);
    try std.testing.expectEqualStrings("s1", debug.control.session_ref.?);
}
