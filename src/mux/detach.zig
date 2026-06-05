const std = @import("std");

const mux_cli = @import("cli.zig");
const mux_client_control = @import("client_control.zig");
const ssh_client = @import("../transport/ssh.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.ClientControl {
    return mux_client_control.parse(scratch, args, false, null);
}

pub fn appendRemoteArgs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    control: mux_cli.ClientControl,
    default_session_ref: ?[]const u8,
) !void {
    return mux_client_control.appendRemoteArgs(allocator, out, "detach", null, control, default_session_ref);
}

pub fn toInvocation(control: mux_cli.ClientControl) !ssh_client.SessionInvocation {
    return mux_client_control.toInvocation(.detach_client, control, null);
}
