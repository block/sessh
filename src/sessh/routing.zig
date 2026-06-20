const std = @import("std");

const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const sessh_cli = @import("cli.zig");
const ssh_opts = @import("../transport/ssh_options.zig");

const CommonSessionOptions = sessh_cli.CommonSessionOptions;
const SshTtyRequest = ssh_opts.SshTtyRequest;

pub const RemoteNewSession = struct {
    command_argv: []const []const u8 = &.{},
    shell_command_args: []const []const u8 = &.{},
    tty_request: SshTtyRequest = .none,
    proxy_required: bool = false,
};

pub const ProxyStreamDecisionRequest = struct {
    new: RemoteNewSession,
    common: CommonSessionOptions,
    stdin_is_tty: bool,
    stdout_is_tty: bool,
};

pub fn inferredClientLogLevel(ssh_options: []const []const u8) client_log.Level {
    const verbosity = sshVerbosity(ssh_options);
    if (verbosity >= 3) return .verbose;
    if (verbosity == 2) return .debug;
    if (verbosity == 1) return .info;
    return .warn;
}

fn sshVerbosity(ssh_options: []const []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < ssh_options.len) {
        const arg = ssh_options[i];
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-") or std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            continue;
        }

        var pos: usize = 1;
        while (pos < arg.len) : (pos += 1) {
            const option = arg[pos];
            if (option == 'v') total += 1;
            if (option == 'o' or ssh_opts.sshOptionRequiresValue(option) or ssh_opts.isUnsafeSshOptionWithValue(option)) {
                if (pos + 1 < arg.len) {
                    i += 1;
                } else {
                    i += 2;
                }
                break;
            }
        } else {
            i += 1;
        }
    }
    return total;
}

pub fn shouldUseStreamPath(new: RemoteNewSession, stdin_is_tty: bool) bool {
    if (new.command_argv.len != 0) return false;
    if (!hasRemoteShellCommand(new.shell_command_args)) return false;

    // Match ssh's PTY allocation rules for remote commands. Plain
    // `ssh HOST command` does not allocate a remote tty even when local stdin is
    // a tty, so it uses the stream path. `-t` only requests a remote tty when
    // local stdin is a tty. `-tt` with local stdin still uses sessh's default
    // emulated session path; without local stdin it stays on the stream path
    // and lets the visible outer ssh allocate the PTY.
    return switch (new.tty_request) {
        .none => true,
        .requested => !stdin_is_tty,
        .forced => !stdin_is_tty,
    };
}

fn filterLevelForcesProxy(level: config.FilterLevel) bool {
    return switch (level) {
        .unhygienic, .hygienic => true,
        .emulated => false,
    };
}

pub fn shouldUseProxyStream(request: ProxyStreamDecisionRequest) bool {
    if (request.new.command_argv.len != 0) return false;
    if (filterLevelForcesProxy(request.common.filter_level) or request.new.proxy_required) return true;
    if ((!request.stdin_is_tty or !request.stdout_is_tty) and request.common.filter_level == .emulated) return true;
    if (!hasRemoteShellCommand(request.new.shell_command_args)) return false;
    return shouldUseStreamPath(request.new, request.stdin_is_tty);
}

pub fn hasRemoteShellCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (args.len > 1) return true;
    return args[0].len > 0;
}
