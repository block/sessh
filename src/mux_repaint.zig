const std = @import("std");

const mux_cli = @import("mux_cli.zig");
const mux_client_control = @import("mux_client_control.zig");
const ssh_client = @import("ssh_client.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.ClientControl {
    return mux_client_control.parse(scratch, args, true, null);
}

pub fn appendRemoteArgs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    control: mux_cli.ClientControl,
    default_session_ref: ?[]const u8,
) !void {
    return mux_client_control.appendRemoteArgs(allocator, out, "repaint", null, control, default_session_ref);
}

pub fn toInvocation(control: mux_cli.ClientControl) !ssh_client.SessionInvocation {
    return mux_client_control.toInvocation(.repaint_client, control, null);
}
