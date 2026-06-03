const std = @import("std");
const posix = std.posix;

const app_allocator = @import("app_allocator.zig");
const broker = @import("broker.zig");
const client = @import("client.zig");
const config = @import("config.zig");
const io = @import("io.zig");
const process_exit = @import("process_exit.zig");
const session_agent = @import("session_agent.zig");
const ssh_client = @import("ssh_client.zig");
const stream_agent = @import("stream_agent.zig");
const terminal = @import("terminal.zig");

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

    const entrypoint: EntryPoint = if (args.len >= 2 and std.mem.eql(u8, args[1], ":internal-sessh:")) .sessh else .sesshmux;

    if (args.len == 1) return usage(0, entrypoint);
    if (entrypoint == .sessh and args.len == 2) return usage(0, entrypoint);
    if (topLevelArgIs(args, entrypoint, &.{ "--help", "-h" })) return usage(0, entrypoint);
    if (topLevelArgIs(args, entrypoint, &.{"--version"}) or sesshShortVersionRequested(args, entrypoint)) {
        try io.writeAll(1, entrypointName(entrypoint));
        try io.writeAll(1, " " ++ config.version ++ "\n");
        return;
    }

    if (entrypoint == .sessh) {
        const sessh_args = try sesshArgsFromInternal(allocator, args);
        defer allocator.free(sessh_args);
        return ssh_client.run(allocator, sessh_args);
    }

    if (std.mem.eql(u8, args[1], ":internal-session-agent:")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--session-dir")) {
            try io.writeAll(2, "sessh: :internal-session-agent: requires --session-dir DIR\n");
            return process_exit.request(64);
        }
        return session_agent.runSessionAgent(args[3]);
    }

    if (std.mem.eql(u8, args[1], ":internal-session-broker:")) {
        return broker.run(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-stream-broker:")) {
        return stream_agent.runBroker(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-stream-agent:")) {
        return stream_agent.runAgent(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-proxy-stream:")) {
        return ssh_client.runProxyStream(allocator, args[0], args[2..]);
    }

    return ssh_client.runMux(allocator, args, true);
}

const EntryPoint = enum {
    sessh,
    sesshmux,
};

fn entrypointName(entrypoint: EntryPoint) []const u8 {
    return switch (entrypoint) {
        .sessh => "sessh",
        .sesshmux => "sesshmux",
    };
}

fn sesshArgsFromInternal(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], ":internal-sessh:"));

    const sessh_args = try allocator.alloc([]const u8, args.len - 1);
    sessh_args[0] = args[0];
    @memcpy(sessh_args[1..], args[2..]);
    return sessh_args;
}

test "version label follows entrypoint" {
    try std.testing.expectEqualStrings("sessh", entrypointName(.sessh));
    try std.testing.expectEqualStrings("sesshmux", entrypointName(.sesshmux));
}

test "internal sessh modality removes sentinel" {
    const rewritten = try sesshArgsFromInternal(std.testing.allocator, &.{
        "sesshmux-macos-aarch64",
        ":internal-sessh:",
        "-v",
        "example.com",
    });
    defer std.testing.allocator.free(rewritten);

    try std.testing.expectEqual(@as(usize, 3), rewritten.len);
    try std.testing.expectEqualStrings("sesshmux-macos-aarch64", rewritten[0]);
    try std.testing.expectEqualStrings("-v", rewritten[1]);
    try std.testing.expectEqualStrings("example.com", rewritten[2]);
}

test "sessh top-level options do not match remote command arguments" {
    try std.testing.expect(topLevelArgIs(&.{ "sesshmux-dev", ":internal-sessh:", "--version" }, .sessh, &.{"--version"}));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sesshmux-dev", ":internal-sessh:", "-V" }, .sessh));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sesshmux-dev", ":internal-sessh:", "-vV", "example.com" }, .sessh));
    try std.testing.expect(sesshShortVersionRequested(&.{ "sesshmux-dev", ":internal-sessh:", "--no-terminal-emulator", "-V", "example.com" }, .sessh));
    try std.testing.expect(!topLevelArgIs(&.{ "sesshmux-dev", ":internal-sessh:", "example.com", "--version" }, .sessh, &.{"--version"}));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sesshmux-dev", ":internal-sessh:", "example.com", "-V" }, .sessh));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sesshmux-dev", ":internal-sessh:", "-F", "-V", "example.com" }, .sessh));
    try std.testing.expect(topLevelArgIs(&.{ "sesshmux-dev", "--version" }, .sesshmux, &.{"--version"}));
    try std.testing.expect(!topLevelArgIs(&.{ "sesshmux-dev", "list", "--version" }, .sesshmux, &.{"--version"}));
    try std.testing.expect(!sesshShortVersionRequested(&.{ "sesshmux-dev", "-V" }, .sesshmux));
}

fn usage(code: u8, entrypoint: EntryPoint) !void {
    const text = switch (entrypoint) {
        .sessh =>
        \\usage:
        \\  sessh [ssh-option ...] destination [command argument ...]
        \\
        \\sessh wraps ssh, making sessions persistent and automatically
        \\reconnecting when ssh drops.
        \\
        \\sessh changes the meaning of `ENTER ~ .`: It detaches the local client
        \\but leaves the session running, printing the session ID to stderr.
        \\After detach you may run one of the following:
        \\  sesshmux attach ID
        \\  sesshmux kill ID
        \\
        \\See the user manual for advanced usage:
        \\  https://github.com/block/sessh/blob/main/docs/USER_MANUAL.md
        \\
        ,
        .sesshmux =>
        \\usage:
        \\  sesshmux new [options] [--ssh-options "ssh args"] HOST [-- cmd arg...]
        \\  sesshmux attach [options] [[--ssh-options "ssh args"] --host HOST] [ID]
        \\  sesshmux force-compat [[--ssh-options "ssh args"] --host HOST] ID command [arg...]
        \\  sesshmux list [--refresh] [--exited] [--jsonl] [[--ssh-options "ssh args"] HOST]
        \\  sesshmux list --client incoming|outgoing|session|ID [--jsonl] [[--ssh-options "ssh args"] HOST]
        \\  sesshmux kill [[--ssh-options "ssh args"] HOST] ID
        \\  sesshmux kill --all [[--ssh-options "ssh args"] HOST]
        \\  sesshmux detach [--all|--last-input|CLIENT_GUID] [ID]
        \\  sesshmux repaint [--scrollback] [--last-input|CLIENT_GUID] [ID]
        \\  sesshmux debug sever-connection|unresponsive-connection [--seconds N] [--all|--last-input|CLIENT_GUID] [ID]
        \\
        \\local target:
        \\  Use . as HOST to operate on local sessions.
        \\
        \\common options:
        \\  --alias NAME
        \\  --ssh-options "SSH_ARGS"
        \\
        \\See the user manual for advanced usage:
        \\  https://github.com/block/sessh/blob/main/docs/USER_MANUAL.md
        \\
    };
    try io.writeAll(if (code == 0) 1 else 2, text);
    return process_exit.request(code);
}

fn topLevelArgIs(args: []const []const u8, entrypoint: EntryPoint, needles: []const []const u8) bool {
    const index: usize = switch (entrypoint) {
        .sessh => 2,
        .sesshmux => 1,
    };
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
fn sesshShortVersionRequested(args: []const []const u8, entrypoint: EntryPoint) bool {
    if (entrypoint != .sessh) return false;

    var index: usize = 2;
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
    return std.mem.eql(u8, arg, "--leader") or
        std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--alias") or
        std.mem.eql(u8, arg, "--connection-diagnostics") or
        std.mem.eql(u8, arg, "--ssh-options") or
        std.mem.eql(u8, arg, "--capture-tty-transcript");
}

fn sshShortOptionConsumesValueForVersionScan(option: u8) bool {
    return std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmOPpRSwWQ", option) != null;
}

test {
    _ = @import("app_allocator.zig");
    _ = @import("broker.zig");
    _ = @import("proxy_control.zig");
    _ = @import("client_renderer.zig");
    _ = @import("pty_process.zig");
    _ = @import("process_exit.zig");
    _ = @import("runtime_refresher.zig");
    _ = @import("session_agent.zig");
    _ = @import("relay.zig");
    _ = @import("session_registry.zig");
    _ = @import("ssh_client.zig");
    _ = @import("stream_agent.zig");
    _ = @import("terminal.zig");
    _ = @import("tty_settings.zig");
    _ = @import("tty_transcript.zig");
    _ = @import("vt.zig");
}
