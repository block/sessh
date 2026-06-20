const std = @import("std");

const process_exit = @import("../core/process_exit.zig");
const transport_ssh = @import("../transport/ssh.zig");
const user_error = @import("../core/user_error.zig");
const sessh_cli = @import("cli.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Public sessh is an ssh-shaped CLI adapter. After parsing, all real work
    // goes through the transport/session path that owns daemon startup,
    // bootstrap, proxy routing, and terminal emulation.
    var scratch = sessh_cli.Scratch{ .allocator = allocator };
    defer scratch.deinit();
    const parsed = sessh_cli.parse(&scratch, args) catch |err| {
        try transport_ssh.printSshArgError(err);
        return process_exit.request(64);
    };
    if (std.mem.eql(u8, parsed.host, ".")) {
        try user_error.line("\".\" is not a valid ssh host");
        return process_exit.request(64);
    }

    return transport_ssh.runRemoteNewSession(allocator, .{
        .exe = args[0],
        .ssh_options = parsed.ssh_options,
        .host = parsed.host,
        .common = parsed.common,
        .new = .{
            .shell_command_args = parsed.command_args,
            .tty_request = parsed.tty_request,
            .proxy_required = parsed.proxy_required,
        },
        .failure_policy = .{
            .allow_plain_ssh_fallback = parsed.command_args.len == 0,
        },
    });
}
