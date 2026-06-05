const std = @import("std");

const mux_cli = @import("mux_cli.zig");
const mux_common = @import("mux_common.zig");
const ssh_client = @import("ssh_client.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.New {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(scratch.allocator);
    var common = mux_cli.CommonSessionOptions{};
    var host: ?[]const u8 = null;
    var command_argv: []const []const u8 = &.{};
    var eval_args = false;
    var detached = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (host == null) return error.MissingHost;
            i += 1;
            if (i >= args.len) return error.MissingCommandArgv;
            command_argv = args[i..];
            i = args.len;
        } else if (std.mem.eql(u8, arg, "--ssh-options")) {
            if (host != null) return error.SesshOptionAfterHost;
            i += 1;
            if (i >= args.len) return error.MissingSshOptions;
            try mux_cli.appendShellSplitWords(scratch, &ssh_options, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (host != null) return error.MultipleTargets;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "-")) return error.MissingHost;
            host = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--eval-args")) {
            if (host != null) return error.SesshOptionAfterHost;
            eval_args = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--detached")) {
            detached = true;
            i += 1;
        } else if (try mux_cli.parseCommonOption(args, &i, &common, .new)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else if (host == null) {
            host = arg;
            i += 1;
        } else {
            command_argv = args[i..];
            i = args.len;
        }
    }
    if (eval_args and command_argv.len == 0) return error.MissingEvalArgs;
    const resolved_host = host orelse return error.MissingHost;
    return .{
        .target = if (std.mem.eql(u8, resolved_host, ".")) .local else .{ .host = resolved_host },
        .ssh_options = try scratch.ownSshOptions(&ssh_options),
        .detached = detached,
        .eval_args = eval_args,
        .command_argv = command_argv,
        .common = common,
    };
}

pub fn appendRemoteArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), new: mux_cli.New) !void {
    try out.append(allocator, "new");
    try mux_cli.appendRemoteCommonArgs(allocator, out, new.common);
    try out.append(allocator, "--host");
    try out.append(allocator, ".");
    if (new.detached) try out.append(allocator, "--detached");
    if (new.eval_args) try out.append(allocator, "--eval-args");
    if (new.command_argv.len > 0) {
        try out.append(allocator, "--");
        try out.appendSlice(allocator, new.command_argv);
    }
}

pub fn toInvocation(new: mux_cli.New) !ssh_client.SessionInvocation {
    var parsed = try mux_common.baseInvocation(new.ssh_options, .new, new.common);
    parsed.host = switch (new.target) {
        .local => ".",
        .host => |host| host,
    };
    parsed.new_detached = new.detached;
    if (new.eval_args) {
        parsed.shell_command_args = new.command_argv;
    } else {
        parsed.command_argv = new.command_argv;
    }
    return parsed;
}

test "parse accepts explicit host option" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const new = try parse(&scratch, &.{ "--ssh-options", "-F cfg -p 2222", "--host", "test-host", "echo", "hi" });

    switch (new.target) {
        .host => |host| try std.testing.expectEqualStrings("test-host", host),
        else => return error.TestUnexpectedTarget,
    }
    try std.testing.expectEqual(@as(usize, 4), new.ssh_options.len);
    try std.testing.expectEqualStrings("-F", new.ssh_options[0]);
    try std.testing.expectEqualStrings("cfg", new.ssh_options[1]);
    try std.testing.expectEqualStrings("-p", new.ssh_options[2]);
    try std.testing.expectEqualStrings("2222", new.ssh_options[3]);
    try std.testing.expectEqual(@as(usize, 2), new.command_argv.len);
    try std.testing.expectEqualStrings("echo", new.command_argv[0]);
    try std.testing.expectEqualStrings("hi", new.command_argv[1]);
}
