const std = @import("std");
const posix = std.posix;

const app_allocator = @import("core/app_allocator.zig");
const config = @import("core/config.zig");
const daemon = @import("daemon/mod.zig");
const daemon_client = @import("daemon/client.zig");
const io = @import("core/io.zig");
const process_exit = @import("core/process_exit.zig");
const user_error = @import("core/user_error.zig");
const terminal_worker = @import("session/terminal_worker.zig");
const terminal_worker_process = @import("session/terminal_worker_process.zig");
const sessh_run = @import("sessh/run.zig");
const proxy_worker = @import("stream/proxy_worker.zig");
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
        user_error.printLine("error: {t}", .{err}) catch {};
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
        return terminal_worker_process.run(allocator, args[1..]);
    }
    if (std.mem.eql(u8, exe_name, "sessh-proxy-remote")) {
        return proxy_worker.runProxyRemoteProcess(allocator, args[1..]);
    }

    if (args.len == 1) return usage(0);

    if (std.mem.eql(u8, args[1], ":daemon:")) {
        return daemon.reexecDaemonOrRun(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":broker:")) {
        return daemon.reexecBrokerOrForward(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":terminal-remote:")) {
        return terminal_worker_process.run(allocator, args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":proxy-remote:")) {
        return proxy_worker.runProxyRemoteProcess(allocator, args[2..]);
    }

    if (topLevelArgIs(args, &.{ "--help", "-h" })) return usage(0);
    if (topLevelArgIs(args, &.{"--version"}) or sesshShortVersionRequested(args)) {
        try io.writeAll(posix.STDOUT_FILENO, "sessh " ++ config.version ++ "\n");
        return;
    }
    if (topLevelArgIs(args, &.{"--daemon-log"})) return daemon_client.printDaemonLog(allocator, args[0]);

    return sessh_run.run(allocator, args);
}

test "sessh top-level options do not match remote command arguments" {
    try std.testing.expect(topLevelArgIs(&.{ "sessh-dev", "--version" }, &.{"--version"}));
    try std.testing.expect(topLevelArgIs(&.{ "sessh-dev", "--daemon-log" }, &.{"--daemon-log"}));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "-V" }));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "-vV", "example.com" }));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "--no-terminal-emulator", "-V", "example.com" }));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sessh-dev", "--diagnostics-file", "/tmp/sessh.log", "-V", "example.com" }));
    try std.testing.expect(!topLevelArgIs(&.{ "sessh-dev", "example.com", "--version" }, &.{"--version"}));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sessh-dev", "example.com", "-V" }));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sessh-dev", "-F", "-V", "example.com" }));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sessh-dev", "--diagnostics-file", "-V", "example.com" }));
}

test "user manual documents public usage options and config defaults" {
    const manual = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/USER_MANUAL.md", 256 * 1024);
    defer std.testing.allocator.free(manual);

    const expected_snippets = [_][]const u8{
        "sessh [ssh-option ...] destination [command [argument ...]]",
        "`--log-level quiet|error|warn|info|debug|verbose`",
        "`--terminal-emulator` / `--no-terminal-emulator`",
        "`--filter-level unhygienic|hygienic|emulated`",
        "`--diagnostics-level overlay|status|title|line|jsonl`",
        "`--isolation-mode full|process|none`",
        "`--diagnostics-file PATH`",
        "`--capture-tty-transcript PATH.tar.gz`",
        "`--daemon-log`",
        "scrollback-limit=2000",
        "client-log-level=warn",
        "bootstrap=true",
        "terminal-emulator=true",
        "filter-level=emulated",
        "diagnostics-level=overlay",
        "isolation-mode=process",
        "cleanup-wakeup-interval-hours=1",
        "cleanup-retry-limit-hours=168",
        "disconnected-reap-hours=168",
    };
    for (expected_snippets) |snippet| {
        try std.testing.expect(std.mem.indexOf(u8, manual, snippet) != null);
    }
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
        std.mem.eql(u8, arg, "--diagnostics-level") or
        std.mem.eql(u8, arg, "--isolation-mode") or
        std.mem.eql(u8, arg, "--diagnostics-file") or
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
    _ = @import("core/guid.zig");
    _ = @import("core/io.zig");
    _ = @import("core/local_boot_time.zig");
    _ = @import("core/non_suspending_timer.zig");
    _ = @import("core/process_exit.zig");
    _ = @import("core/shell.zig");
    _ = @import("core/user_error.zig");
    _ = @import("daemon/accept.zig");
    _ = @import("daemon/client_router.zig");
    _ = @import("daemon/client.zig");
    _ = @import("daemon/cleanup.zig");
    _ = @import("daemon/cleanup_scheduler.zig");
    _ = @import("daemon/executable.zig");
    _ = @import("daemon/log.zig");
    _ = @import("daemon/mod.zig");
    _ = @import("daemon/shutdown.zig");
    _ = @import("daemon/tunnel.zig");
    _ = @import("diagnostics/display.zig");
    _ = @import("diagnostics/file.zig");
    _ = @import("diagnostics/jsonl.zig");
    _ = @import("diagnostics/policy.zig");
    _ = @import("diagnostics/reconnect_input.zig");
    _ = @import("protocol/frame.zig");
    _ = @import("protocol/handshake.zig");
    _ = @import("protocol/mod.zig");
    _ = @import("protocol/test_helpers.zig");
    _ = @import("protocol/typed_send.zig");
    _ = @import("reconnect/control.zig");
    _ = @import("reconnect/mod.zig");
    _ = @import("reconnect/title.zig");
    _ = @import("sessh/cli.zig");
    _ = @import("sessh/routing.zig");
    _ = @import("sessh/routing_tests.zig");
    _ = @import("session/attached_client.zig");
    _ = @import("session/terminal_worker.zig");
    _ = @import("session/terminal_worker_requests.zig");
    _ = @import("session/attached_client_presentation.zig");
    _ = @import("session/daemon_handler.zig");
    _ = @import("session/client_config.zig");
    _ = @import("session/client_ui.zig");
    _ = @import("session/connection_monitor.zig");
    _ = @import("session/error_payload.zig");
    _ = @import("session/input_ack.zig");
    _ = @import("session/input_translation.zig");
    _ = @import("session/local_terminal.zig");
    _ = @import("session/overlay.zig");
    _ = @import("session/presentation_guard.zig");
    _ = @import("session/repaint.zig");
    _ = @import("session/renderer.zig");
    _ = @import("session/vt.zig");
    _ = @import("sessh/run.zig");
    _ = @import("stream/mux_proxy.zig");
    _ = @import("stream/proxy_worker.zig");
    _ = @import("stream/raw_bridge.zig");
    _ = @import("stream/status_output.zig");
    _ = @import("stream/proxy_diagnostics_channel.zig");
    _ = @import("stream/proxy_remote.zig");
    _ = @import("tty/pty_process.zig");
    _ = @import("tty/settings.zig");
    _ = @import("tty/terminal.zig");
    _ = @import("tty/transcript.zig");
    _ = @import("transport/artifact_manifest.zig");
    _ = @import("transport/bootstrap.zig");
    _ = @import("transport/bootstrap_client.zig");
    _ = @import("transport/frame_forwarder.zig");
    _ = @import("transport/plain_ssh.zig");
    _ = @import("transport/pooled_ssh.zig");
    _ = @import("transport/proxy_entry.zig");
    _ = @import("transport/remote_shell.zig");
    _ = @import("transport/send_env.zig");
    _ = @import("transport/socket.zig");
    _ = @import("transport/ssh_transport_process.zig");
    _ = @import("transport/ssh_options.zig");
    _ = @import("transport/ssh_transport_acquire.zig");
    _ = @import("transport/ssh.zig");
}
