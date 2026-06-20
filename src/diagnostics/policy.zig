// Chooses the least invasive diagnostics behavior that still matches the user's
// requested filter level and the actual stdio shape. This keeps policy separate
// from the terminal/proxy code that implements each display path.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const client_ui = @import("../session/client_ui.zig");
const posix_pty = @import("../tty/posix_pty.zig");
const ssh_opts = @import("../transport/ssh_options.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");

pub const ProxyStreamPlan = struct {
    command_level: config.FilterLevel,
    use_daemon_control: bool,
    wrap_visible_ssh: bool,
    client_ctrl_r: bool,
};

pub const ProxyStreamPlanRequest = struct {
    ssh_options: []const []const u8,
    filter_level: config.FilterLevel,
    tty_request: ssh_opts.SshTtyRequest,
    shell_command_args: []const []const u8,
    stdin_is_tty: bool,
    stdout_is_tty: bool,
};

pub const AutoProxyDiagnosticsFileRequest = struct {
    explicit_diagnostics_file: ?[]const u8,
    use_daemon_control: bool,
    wrap_visible_ssh: bool,
    stdin_fd: c.fd_t,
    stderr_fd: c.fd_t,
};

pub const TerminalPresentationRequest = struct {
    filter_level: config.FilterLevel,
    diagnostics_level: config.DiagnosticsLevel,
    diagnostics_output_is_tty: bool,
};

pub const StreamStatusModeRequest = struct {
    filter_level: config.FilterLevel,
    diagnostics_level: config.DiagnosticsLevel,
    has_daemon_control: bool,
    diagnostics_output_is_tty: bool,
};

pub fn terminalPresentation(request: TerminalPresentationRequest) client_ui.ReconnectPresentation {
    if (request.diagnostics_level == .jsonl) return .jsonl;
    if (!request.diagnostics_output_is_tty) return .line;
    return switch (request.diagnostics_level) {
        .jsonl => unreachable,
        .line => .line,
        .title => .title,
        .status => switch (request.filter_level) {
            .unhygienic => .none,
            .hygienic, .emulated => .title,
        },
        .overlay => switch (request.filter_level) {
            .unhygienic => .none,
            .hygienic => .title,
            .emulated => .overlay,
        },
    };
}

pub fn streamStatusMode(request: StreamStatusModeRequest) proxy_worker.StreamReconnectStatusMode {
    if (request.diagnostics_level == .jsonl) return .jsonl;
    if (!request.diagnostics_output_is_tty) return .line;
    if (request.diagnostics_level == .line) return .line;
    if (request.diagnostics_level == .title) return .title;
    if (request.has_daemon_control) return .client_control;
    return switch (request.filter_level) {
        .unhygienic => .disabled,
        .hygienic, .emulated => .status_line,
    };
}

pub fn proxyStreamPlan(request: ProxyStreamPlanRequest) ProxyStreamPlan {
    // Proxy mode only gets hygienic diagnostics when both visible stdio streams
    // are ttys; otherwise OpenSSH should see raw proxy bytes with no wrapper UI.
    // The outer ssh tty decision controls whether Ctrl-R can be intercepted.
    return switch (request.filter_level) {
        .unhygienic => .{
            .command_level = .unhygienic,
            .use_daemon_control = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!request.stdin_is_tty or !request.stdout_is_tty) break :blk .{
                .command_level = .unhygienic,
                .use_daemon_control = false,
                .wrap_visible_ssh = false,
                .client_ctrl_r = false,
            };
            const wrap_visible_ssh = outerSshAllocatesTty(request);
            break :blk .{
                .command_level = .hygienic,
                .use_daemon_control = true,
                .wrap_visible_ssh = wrap_visible_ssh,
                .client_ctrl_r = wrap_visible_ssh and request.stdin_is_tty,
            };
        },
    };
}

pub fn isolationModeUsesDirectProxyPlacement(mode: config.IsolationMode) bool {
    return switch (mode) {
        .full, .none => true,
        .process => false,
    };
}

pub fn autoProxyDiagnosticsFile(
    allocator: std.mem.Allocator,
    request: AutoProxyDiagnosticsFileRequest,
) !?[]u8 {
    if (request.explicit_diagnostics_file != null) return null;
    if (!request.use_daemon_control or request.wrap_visible_ssh) return null;
    if (!sameTerminalFd(request.stdin_fd, request.stderr_fd)) return null;
    return try ttyPathForFd(allocator, request.stderr_fd);
}

fn sameTerminalFd(left: c.fd_t, right: c.fd_t) bool {
    if (c.isatty(left) == 0 or c.isatty(right) == 0) return false;
    const left_stat = posix.fstat(left) catch return false;
    const right_stat = posix.fstat(right) catch return false;
    return left_stat.dev == right_stat.dev and left_stat.ino == right_stat.ino;
}

fn ttyPathForFd(allocator: std.mem.Allocator, fd: c.fd_t) !?[]u8 {
    if (c.isatty(fd) == 0) return null;
    const path = posix_pty.name(fd) orelse return null;
    return try allocator.dupe(u8, path);
}

fn outerSshAllocatesTty(request: ProxyStreamPlanRequest) bool {
    const explicit = explicitTtyRequest(request.ssh_options);
    if (explicit) |explicit_request| return switch (explicit_request) {
        .none => false,
        .requested => request.stdin_is_tty,
        .forced => true,
    };
    return switch (request.tty_request) {
        .none => request.stdin_is_tty and request.shell_command_args.len == 0,
        .requested => request.stdin_is_tty,
        .forced => true,
    };
}

fn explicitTtyRequest(options: []const []const u8) ?ssh_opts.SshTtyRequest {
    // OpenSSH has several spellings for tty allocation. `-T` disables it, one
    // `-t` requests it only with a local tty, repeated `-t` forces it, and
    // `-o RequestTTY=...` is the config-key form. Diagnostics policy needs the
    // effective request before deciding whether overlay/status UI is possible.
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

fn optionValueFromOptions(options: []const []const u8, index: usize, option_pos: usize) ?[]const u8 {
    const arg = options[index];
    if (option_pos + 1 < arg.len) return arg[option_pos + 1 ..];
    if (index + 1 >= options.len) return null;
    return options[index + 1];
}

test "stream status mode follows diagnostics level" {
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.jsonl, streamStatusMode(.{
        .filter_level = .emulated,
        .diagnostics_level = .jsonl,
        .has_daemon_control = true,
        .diagnostics_output_is_tty = true,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.line, streamStatusMode(.{
        .filter_level = .emulated,
        .diagnostics_level = .line,
        .has_daemon_control = true,
        .diagnostics_output_is_tty = true,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.line, streamStatusMode(.{
        .filter_level = .emulated,
        .diagnostics_level = .overlay,
        .has_daemon_control = true,
        .diagnostics_output_is_tty = false,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.title, streamStatusMode(.{
        .filter_level = .hygienic,
        .diagnostics_level = .title,
        .has_daemon_control = true,
        .diagnostics_output_is_tty = true,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.client_control, streamStatusMode(.{
        .filter_level = .emulated,
        .diagnostics_level = .overlay,
        .has_daemon_control = true,
        .diagnostics_output_is_tty = true,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.status_line, streamStatusMode(.{
        .filter_level = .emulated,
        .diagnostics_level = .overlay,
        .has_daemon_control = false,
        .diagnostics_output_is_tty = true,
    }));
    try std.testing.expectEqual(proxy_worker.StreamReconnectStatusMode.status_line, streamStatusMode(.{
        .filter_level = .hygienic,
        .diagnostics_level = .status,
        .has_daemon_control = false,
        .diagnostics_output_is_tty = true,
    }));
}

test "terminal presentation follows diagnostics level" {
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.overlay,
        terminalPresentation(.{
            .filter_level = .emulated,
            .diagnostics_level = .overlay,
            .diagnostics_output_is_tty = true,
        }),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.title,
        terminalPresentation(.{
            .filter_level = .emulated,
            .diagnostics_level = .status,
            .diagnostics_output_is_tty = true,
        }),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.title,
        terminalPresentation(.{
            .filter_level = .hygienic,
            .diagnostics_level = .overlay,
            .diagnostics_output_is_tty = true,
        }),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.line,
        terminalPresentation(.{
            .filter_level = .emulated,
            .diagnostics_level = .overlay,
            .diagnostics_output_is_tty = false,
        }),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.jsonl,
        terminalPresentation(.{
            .filter_level = .emulated,
            .diagnostics_level = .jsonl,
            .diagnostics_output_is_tty = false,
        }),
    );
}

test "proxy stream plan maps emulated proxy output to daemon control when stdio is tty" {
    const interactive = proxyStreamPlan(.{
        .ssh_options = &.{},
        .filter_level = .emulated,
        .tty_request = .none,
        .shell_command_args = &.{},
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expectEqual(config.FilterLevel.hygienic, interactive.command_level);
    try std.testing.expect(interactive.use_daemon_control);
    try std.testing.expect(interactive.wrap_visible_ssh);
    try std.testing.expect(interactive.client_ctrl_r);

    const no_stdout = proxyStreamPlan(.{
        .ssh_options = &.{},
        .filter_level = .emulated,
        .tty_request = .none,
        .shell_command_args = &.{},
        .stdin_is_tty = true,
        .stdout_is_tty = false,
    });
    try std.testing.expectEqual(config.FilterLevel.unhygienic, no_stdout.command_level);
    try std.testing.expect(!no_stdout.use_daemon_control);
    try std.testing.expect(!no_stdout.wrap_visible_ssh);
    try std.testing.expect(!no_stdout.client_ctrl_r);

    const no_stdin = proxyStreamPlan(.{
        .ssh_options = &.{},
        .filter_level = .emulated,
        .tty_request = .none,
        .shell_command_args = &.{},
        .stdin_is_tty = false,
        .stdout_is_tty = true,
    });
    try std.testing.expectEqual(config.FilterLevel.unhygienic, no_stdin.command_level);
    try std.testing.expect(!no_stdin.use_daemon_control);
    try std.testing.expect(!no_stdin.wrap_visible_ssh);
    try std.testing.expect(!no_stdin.client_ctrl_r);
}

test "proxy stream plan honors unhygienic level" {
    const result = proxyStreamPlan(.{
        .ssh_options = &.{},
        .filter_level = .unhygienic,
        .tty_request = .none,
        .shell_command_args = &.{},
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expectEqual(config.FilterLevel.unhygienic, result.command_level);
    try std.testing.expect(!result.use_daemon_control);
}

test "proxy stream plan disables ctrl-r when visible ssh is not wrapped" {
    const result = proxyStreamPlan(.{
        .ssh_options = &.{"-T"},
        .filter_level = .hygienic,
        .tty_request = .none,
        .shell_command_args = &.{},
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expectEqual(config.FilterLevel.hygienic, result.command_level);
    try std.testing.expect(result.use_daemon_control);
    try std.testing.expect(!result.wrap_visible_ssh);
    try std.testing.expect(!result.client_ctrl_r);
}

test "auto proxy diagnostics file only infers a matching diagnostics tty" {
    var pty = try posix_pty.open();
    defer pty.close();

    const explicit = try autoProxyDiagnosticsFile(std.testing.allocator, .{
        .explicit_diagnostics_file = "/tmp/sessh-diagnostics.log",
        .use_daemon_control = true,
        .wrap_visible_ssh = false,
        .stdin_fd = pty.slave_fd,
        .stderr_fd = pty.slave_fd,
    });
    try std.testing.expect(explicit == null);

    const wrapped = try autoProxyDiagnosticsFile(std.testing.allocator, .{
        .explicit_diagnostics_file = null,
        .use_daemon_control = true,
        .wrap_visible_ssh = true,
        .stdin_fd = pty.slave_fd,
        .stderr_fd = pty.slave_fd,
    });
    try std.testing.expect(wrapped == null);

    const no_daemon_control = try autoProxyDiagnosticsFile(std.testing.allocator, .{
        .explicit_diagnostics_file = null,
        .use_daemon_control = false,
        .wrap_visible_ssh = false,
        .stdin_fd = pty.slave_fd,
        .stderr_fd = pty.slave_fd,
    });
    try std.testing.expect(no_daemon_control == null);

    const inferred = try autoProxyDiagnosticsFile(std.testing.allocator, .{
        .explicit_diagnostics_file = null,
        .use_daemon_control = true,
        .wrap_visible_ssh = false,
        .stdin_fd = pty.slave_fd,
        .stderr_fd = pty.slave_fd,
    });
    defer if (inferred) |path| std.testing.allocator.free(path);
    const path = posix_pty.name(pty.slave_fd) orelse return error.MissingTtyName;
    try std.testing.expectEqualStrings(path, inferred.?);
}

test "diagnostics doc describes current public levels and diagnostics file behavior" {
    const doc = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/DIAGNOSTICS.md", 128 * 1024);
    defer std.testing.allocator.free(doc);

    const snippets = [_][]const u8{
        "`--diagnostics-file PATH`",
        "`diagnostics-level=overlay`",
        "`diagnostics-level=status`",
        "`diagnostics-level=title`",
        "`diagnostics-level=line`",
        "`diagnostics-level=jsonl`",
        "`diagnostics-level=jsonl` means force\nJSONL",
        "If the file does not\nexist, sessh creates it.",
    };
    for (snippets) |snippet| {
        try std.testing.expect(std.mem.indexOf(u8, doc, snippet) != null);
    }
}
