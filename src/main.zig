const std = @import("std");
const posix = std.posix;

const app_allocator = @import("core/app_allocator.zig");
const config = @import("core/config.zig");
const daemon = @import("daemon/mod.zig");
const daemon_client = @import("daemon/client.zig");
const io = @import("core/io.zig");
const process_exit = @import("core/process_exit.zig");
const session_runtime = @import("session/runtime.zig");
const session_runtime_process = @import("session/runtime_process.zig");
const stream_runtime = @import("stream/runtime.zig");
const terminal = @import("tty/terminal.zig");
const transport_ssh = @import("transport/ssh.zig");

pub fn main() !void {
    terminal.setSigpipe(posix.SIG.IGN);

    runMain() catch |err| {
        app_allocator.deinit();
        if (process_exit.is(err)) {
            const exit_code = process_exit.code();
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
        std.debug.print("sessh: error: {t}\n", .{err});
        std.process.exit(1);
    };
    app_allocator.deinit();
}

fn runMain() !void {
    const allocator = app_allocator.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = try allocator.alloc([]const u8, argv.len);
    defer allocator.free(args);
    for (argv, 0..) |arg, i| args[i] = arg;

    const exe_name = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, exe_name, "sesshd")) {
        return daemon.run(allocator, args[0], args[1..]);
    }
    if (std.mem.eql(u8, exe_name, "sessh-broker")) {
        return daemon.forwardBrokerToDaemon(allocator, args[0], args[1..]);
    }
    if (std.mem.eql(u8, exe_name, "sessh-proxy")) {
        return transport_ssh.runProxyStream(allocator, args[0], args[1..]);
    }
    if (std.mem.eql(u8, exe_name, "sessh-terminal-remote")) {
        return session_runtime_process.run(allocator, args[1..]);
    }
    if (std.mem.eql(u8, exe_name, "sessh-proxy-remote")) {
        return stream_runtime.runProxyRemoteProcess(allocator, args[1..]);
    }

    if (args.len == 1) return usage(0);

    if (std.mem.eql(u8, args[1], ":daemon:")) {
        return daemon.reexecDaemonOrRun(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":broker:")) {
        return daemon.reexecBrokerOrForward(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":proxy:")) {
        return transport_ssh.runProxyStream(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":terminal-remote:")) {
        return session_runtime_process.run(allocator, args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":proxy-remote:")) {
        return stream_runtime.runProxyRemoteProcess(allocator, args[2..]);
    }

    if (topLevelArgIs(args, &.{ "--help", "-h" })) return usage(0);
    if (topLevelArgIs(args, &.{"--version"}) or sesshShortVersionRequested(args)) {
        try io.writeAll(posix.STDOUT_FILENO, "sessh " ++ config.version ++ "\n");
        return;
    }
    if (topLevelArgIs(args, &.{"--daemon-log"})) return daemon_client.printDaemonLog(allocator, args[0]);

    return transport_ssh.run(allocator, args);
}

test "sessh top-level options do not match remote command arguments" {
    try std.testing.expect(topLevelArgIs(&.{ "sessh-dev", "--version" }, &.{"--version"}));
    try std.testing.expect(topLevelArgIs(&.{ "sessh-dev", "--daemon-log" }, &.{"--daemon-log"}));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "-V" }));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "-vV", "example.com" }));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "--no-terminal-emulator", "-V", "example.com" }));
    try std.testing.expect(!topLevelArgIs(&.{ "sessh-dev", "example.com", "--version" }, &.{"--version"}));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sessh-dev", "example.com", "-V" }));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sessh-dev", "-F", "-V", "example.com" }));
}

fn usage(code: u8) !void {
    const text =
        \\usage:
        \\  sessh [ssh-option ...] destination [command argument ...]
        \\  sessh --daemon-log
        \\  SESSH_DAEMON_NAMESPACE=<namespace> sessh --daemon-log
        \\
        \\sessh wraps ssh, making sessions persistent and automatically
        \\reconnecting when ssh drops.
        \\
        \\See the user manual for advanced usage:
        \\  https://github.com/block/sessh/blob/main/docs/USER_MANUAL.md
        \\
    ;
    try io.writeAll(if (code == 0) posix.STDOUT_FILENO else posix.STDERR_FILENO, text);
    return process_exit.request(code);
}

fn topLevelArgIs(args: []const []const u8, needles: []const []const u8) bool {
    const index: usize = 1;
    if (args.len != index + 1) return false;
    for (needles) |needle| {
        if (std.mem.eql(u8, args[index], needle)) return true;
    }
    return false;
}

// `ssh -V` is a pre-host option that exits before any connection attempt. Scan
// only that pre-host region; after the host, `-V` is remote command text. The
// value-skipping keeps cases such as `sessh -F -V host` from treating the
// config filename as a version request.
fn sesshShortVersionRequested(args: []const []const u8) bool {
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (arg.len == 0) return false;
        if (std.mem.eql(u8, arg, "--")) return false;
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) return false;
        if (std.mem.eql(u8, arg, "-V")) return true;

        if (std.mem.startsWith(u8, arg, "--")) {
            index += if (sesshLongOptionConsumesValue(arg)) 2 else 1;
            continue;
        }

        var pos: usize = 1;
        var consumed_value = false;
        while (pos < arg.len) : (pos += 1) {
            const option = arg[pos];
            if (option == 'V') return true;
            if (sshShortOptionConsumesValueForVersionScan(option)) {
                index += if (pos + 1 < arg.len) 1 else 2;
                consumed_value = true;
                break;
            }
        }
        if (!consumed_value) index += 1;
    }
    return false;
}

fn sesshLongOptionConsumesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--filter-level") or
        std.mem.eql(u8, arg, "--isolation-mode") or
        std.mem.eql(u8, arg, "--ssh-options") or
        std.mem.eql(u8, arg, "--capture-tty-transcript");
}

fn sshShortOptionConsumesValueForVersionScan(option: u8) bool {
    return std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmOPpRSwWQ", option) != null;
}

test {
    _ = @import("core/app_allocator.zig");
    _ = @import("core/client_log.zig");
    _ = @import("core/config.zig");
    _ = @import("core/dispatcher.zig");
    _ = @import("core/fd_passing.zig");
    _ = @import("core/io.zig");
    _ = @import("core/local_boot_time.zig");
    _ = @import("core/non_suspending_timer.zig");
    _ = @import("core/process_exit.zig");
    _ = @import("core/shell.zig");
    _ = @import("daemon/client.zig");
    _ = @import("daemon/executable.zig");
    _ = @import("daemon/log.zig");
    _ = @import("daemon/mod.zig");
    _ = @import("protocol/mod.zig");
    _ = @import("reconnect/control.zig");
    _ = @import("reconnect/mod.zig");
    _ = @import("reconnect/title.zig");
    _ = @import("runtime/session_registry.zig");
    _ = @import("sessh/cli.zig");
    _ = @import("session/attached_client.zig");
    _ = @import("session/runtime.zig");
    _ = @import("session/daemon_handler.zig");
    _ = @import("session/client_config.zig");
    _ = @import("session/client_ui.zig");
    _ = @import("session/renderer.zig");
    _ = @import("session/vt.zig");
    _ = @import("stream/runtime.zig");
    _ = @import("stream/proxy_control.zig");
    _ = @import("tty/pty_process.zig");
    _ = @import("tty/settings.zig");
    _ = @import("tty/terminal.zig");
    _ = @import("tty/transcript.zig");
    _ = @import("transport/artifact_manifest.zig");
    _ = @import("transport/bootstrap.zig");
    _ = @import("transport/frame_forwarder.zig");
    _ = @import("transport/plain_ssh.zig");
    _ = @import("transport/remote_shell.zig");
    _ = @import("transport/socket.zig");
    _ = @import("transport/ssh_options.zig");
    _ = @import("transport/ssh.zig");
}
