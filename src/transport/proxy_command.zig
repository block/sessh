const std = @import("std");

const config = @import("../core/config.zig");
const remote_shell = @import("remote_shell.zig");
const ssh_opts = @import("ssh_options.zig");
const stream_runtime = @import("../stream/runtime.zig");

pub const DiagnosticsPlan = struct {
    command_level: config.FilterLevel,
    use_daemon_control: bool,
    wrap_visible_ssh: bool,
    client_ctrl_r: bool,
};

pub fn reconnectStatusMode(level: config.FilterLevel, has_daemon_control: bool) stream_runtime.StreamReconnectStatusMode {
    return switch (level) {
        .unhygienic => .disabled,
        .hygienic, .emulated => if (has_daemon_control) .client_control else .stderr_plain,
    };
}

pub fn diagnosticsPlan(
    ssh_options: []const []const u8,
    filter_level: config.FilterLevel,
    tty_request: ssh_opts.SshTtyRequest,
    shell_command_args: []const []const u8,
    stdin_is_tty: bool,
    stdout_is_tty: bool,
) DiagnosticsPlan {
    return switch (filter_level) {
        .unhygienic => .{
            .command_level = .unhygienic,
            .use_daemon_control = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!stdin_is_tty or !stdout_is_tty) break :blk .{
                .command_level = .unhygienic,
                .use_daemon_control = false,
                .wrap_visible_ssh = false,
                .client_ctrl_r = false,
            };
            const wrap_visible_ssh = outerSshAllocatesTty(ssh_options, tty_request, shell_command_args, stdin_is_tty);
            break :blk .{
                .command_level = .hygienic,
                .use_daemon_control = true,
                .wrap_visible_ssh = wrap_visible_ssh,
                .client_ctrl_r = wrap_visible_ssh and stdin_is_tty,
            };
        },
    };
}

pub fn isolationModeUsesDirectPlacement(mode: config.IsolationMode) bool {
    return switch (mode) {
        .full, .none => true,
        .process => false,
    };
}

fn outerSshAllocatesTty(
    ssh_options: []const []const u8,
    tty_request: ssh_opts.SshTtyRequest,
    shell_command_args: []const []const u8,
    stdin_is_tty: bool,
) bool {
    const explicit = explicitTtyRequest(ssh_options);
    if (explicit) |request| return switch (request) {
        .none => false,
        .requested => stdin_is_tty,
        .forced => true,
    };
    return switch (tty_request) {
        .none => stdin_is_tty and shell_command_args.len == 0,
        .requested => stdin_is_tty,
        .forced => true,
    };
}

fn explicitTtyRequest(options: []const []const u8) ?ssh_opts.SshTtyRequest {
    var result: ?ssh_opts.SshTtyRequest = null;
    var i: usize = 0;
    while (i < options.len) {
        const arg = options[i];
        if (std.mem.startsWith(u8, arg, "--") or arg.len < 2 or arg[0] != '-') {
            i += 1;
            continue;
        }
        var pos: usize = 1;
        while (pos < arg.len) {
            const option = arg[pos];
            if (option == 'T') {
                result = .none;
                pos += 1;
                continue;
            }
            if (option == 't') {
                if (result != null and result.? == .requested) {
                    result = .forced;
                } else if (result == null or result.? != .forced) {
                    result = .requested;
                }
                pos += 1;
                continue;
            }
            if (option == 'o') {
                const value = optionValueFromOptions(options, i, pos) orelse return result;
                if (ssh_opts.sshConfigKeyIs(value, "RequestTTY")) {
                    const key = ssh_opts.sshConfigKey(value);
                    if (ssh_opts.sshConfigValueIs(value, key.len, "no")) {
                        result = .none;
                    } else if (ssh_opts.sshConfigValueIs(value, key.len, "force")) {
                        result = .forced;
                    } else if (ssh_opts.sshConfigValueIs(value, key.len, "yes")) {
                        result = .requested;
                    }
                }
                i = if (pos + 1 < arg.len) i + 1 else i + 2;
                break;
            }
            if (ssh_opts.sshOptionRequiresValue(option) or ssh_opts.isUnsafeSshOptionWithValue(option) or ssh_opts.isProxyRequiredSshOptionWithValue(option)) {
                i = if (pos + 1 < arg.len) i + 1 else i + 2;
                break;
            }
            pos += 1;
        } else {
            i += 1;
        }
    }
    return result;
}

pub fn commandOption(
    allocator: std.mem.Allocator,
    exe: []const u8,
    ssh_options: []const []const u8,
    control_guid: ?[]const u8,
    filter_level: config.FilterLevel,
    client_ctrl_r: bool,
    stdin_from_stderr: bool,
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
    if (use_fd_pass) try appendShellToken(allocator, &command, "--use-fd-pass");
    if (stdin_from_stderr) try appendShellToken(allocator, &command, "--stdin-from-stderr");
    try appendShellToken(allocator, &command, if (bootstrap) "--bootstrap" else "--no-bootstrap");
    if (daemon_dir_name) |dir_name| {
        try appendShellToken(allocator, &command, "--daemon-namespace");
        try appendShellToken(allocator, &command, dir_name);
    }
    if (control_guid) |guid| {
        try appendShellToken(allocator, &command, "--control-guid");
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
