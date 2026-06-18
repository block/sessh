const std = @import("std");

const config = @import("../core/config.zig");
const remote_shell = @import("remote_shell.zig");
const sessh_cli = @import("../sessh/cli.zig");
const ssh_opts = @import("ssh_options.zig");

pub fn commandOption(
    allocator: std.mem.Allocator,
    exe: []const u8,
    ssh_options: []const []const u8,
    diagnostics_guid: ?[]const u8,
    filter_level: config.FilterLevel,
    diagnostics_level: config.DiagnosticsLevel,
    client_ctrl_r: bool,
    diagnostics_file: ?[]const u8,
    bootstrap: bool,
    daemon_dir_name: ?[]const u8,
    use_fd_pass: bool,
) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try appendShellToken(allocator, &command, exe);
    try appendShellToken(allocator, &command, "--host");
    // Use the original host token so the inner ssh sees the same Host block.
    // `%h` is already resolved to HostName and can lose alias-scoped options.
    try appendShellToken(allocator, &command, "%n");
    try appendShellToken(allocator, &command, "--port");
    try appendShellToken(allocator, &command, "%p");
    try appendShellToken(allocator, &command, "--user");
    try appendShellToken(allocator, &command, "%r");
    try appendShellToken(allocator, &command, "--filter-level");
    try appendShellToken(allocator, &command, filter_level.label());
    try appendShellToken(allocator, &command, "--diagnostics-level");
    try appendShellToken(allocator, &command, diagnostics_level.label());
    if (use_fd_pass) try appendShellToken(allocator, &command, "--use-fd-pass");
    if (diagnostics_file) |path| {
        try appendShellToken(allocator, &command, "--diagnostics-file");
        try appendShellToken(allocator, &command, path);
    }
    try appendShellToken(allocator, &command, if (bootstrap) "--bootstrap" else "--no-bootstrap");
    if (daemon_dir_name) |dir_name| {
        try appendShellToken(allocator, &command, "--daemon-namespace");
        try appendShellToken(allocator, &command, dir_name);
    }
    if (diagnostics_guid) |guid| {
        try appendShellToken(allocator, &command, "--diagnostics-guid");
        try appendShellToken(allocator, &command, guid);
        try appendShellToken(allocator, &command, "--client-ctrl-r");
        try appendShellToken(allocator, &command, if (client_ctrl_r) "1" else "0");
    }
    try appendProxyTransportSshOptions(allocator, &command, ssh_options);

    return std.fmt.allocPrint(allocator, "-oProxyCommand={s}", .{command.items});
}

fn appendProxyTransportSshOptions(
    allocator: std.mem.Allocator,
    command: *std.ArrayList(u8),
    options: []const []const u8,
) !void {
    var i: usize = 0;
    while (i < options.len) {
        const value_index = ssh_opts.sshOptionSeparateValueIndex(options, i);
        if (ssh_opts.isSshTtyRequestOption(options[i])) {
            i += 1;
            continue;
        }
        if (sshOptionRequiresOuterProxy(options, i)) {
            i = if (value_index) |index| index + 1 else i + 1;
            continue;
        }

        try appendShellToken(allocator, command, "--ssh-option");
        try appendShellToken(allocator, command, options[i]);
        if (value_index) |index| {
            try appendShellToken(allocator, command, "--ssh-option");
            try appendShellToken(allocator, command, options[index]);
            i = index + 1;
        } else {
            i += 1;
        }
    }
}

fn sshOptionRequiresOuterProxy(options: []const []const u8, index: usize) bool {
    const arg = options[index];
    if (arg.len < 2 or arg[0] != '-' or std.mem.startsWith(u8, arg, "--")) return false;

    var pos: usize = 1;
    while (pos < arg.len) : (pos += 1) {
        const option = arg[pos];
        if (ssh_opts.isProxyRequiredSshFlag(option) or ssh_opts.isProxyRequiredSshOptionWithValue(option)) return true;
        if (option == 'o') {
            const value = optionValueFromOptions(options, index, pos) orelse return false;
            return ssh_opts.sshConfigOptionRequiresProxy(value) catch false;
        }
        if (ssh_opts.sshOptionRequiresValue(option) or ssh_opts.isUnsafeSshOptionWithValue(option)) return false;
    }
    return false;
}

fn optionValueFromOptions(options: []const []const u8, index: usize, option_pos: usize) ?[]const u8 {
    const arg = options[index];
    if (option_pos + 1 < arg.len) return arg[option_pos + 1 ..];
    if (index + 1 >= options.len) return null;
    return options[index + 1];
}

fn appendShellToken(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, ' ');
    const quoted = try remote_shell.shellQuote(allocator, value);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

test "proxy command keeps outer-only options off bootstrap ssh" {
    var scratch = sessh_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();
    const parsed = try sessh_cli.parse(&scratch, &.{
        "sessh",
        "-X",
        "-tt",
        "-L",
        "8080:localhost:80",
        "-o",
        "ForwardAgent=yes",
        "-o",
        "BatchMode=yes",
        "-v",
        "example.com",
    });
    try std.testing.expect(parsed.proxy_required);

    const option = try commandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.ssh_options, "p-550e8400-e29b-41d4-a716-446655440000", .hygienic, .status, true, "/dev/ttys001", true, "3.conn.test", false);
    defer std.testing.allocator.free(option);

    try std.testing.expect(std.mem.indexOf(u8, option, "sessh-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, ":proxy:") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%n") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%p") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--filter-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "hygienic") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--diagnostics-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--use-fd-pass") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--diagnostics-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "/dev/ttys001") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--bootstrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--daemon-namespace") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "3.conn.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--diagnostics-guid") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "p-550e8400-e29b-41d4-a716-446655440000") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-ctrl-r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "-v") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "ForwardAgent=yes") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "8080:localhost:80") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-X'") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-tt'") == null);

    const no_bootstrap_option = try commandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.ssh_options, null, .unhygienic, .overlay, false, null, false, null, false);
    defer std.testing.allocator.free(no_bootstrap_option);
    try std.testing.expect(std.mem.indexOf(u8, no_bootstrap_option, "--no-bootstrap") != null);

    const fd_pass_option = try commandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.ssh_options, null, .unhygienic, .overlay, false, null, true, null, true);
    defer std.testing.allocator.free(fd_pass_option);
    try std.testing.expect(std.mem.indexOf(u8, fd_pass_option, "--use-fd-pass") != null);
}
