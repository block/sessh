const std = @import("std");
const posix = std.posix;

const app_allocator = @import("core/app_allocator.zig");
const config = @import("core/config.zig");
const io = @import("core/io.zig");
const mux = @import("mux/mod.zig");
const mux_force_compat = @import("mux/force_compat.zig");
const process_exit = @import("core/process_exit.zig");
const session_agent = @import("session/agent.zig");
const session_broker = @import("session/broker.zig");
const stream_agent = @import("stream/agent.zig");
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
        const sessh_args = try argsFromInternalSessh(allocator, args);
        defer allocator.free(sessh_args);
        return transport_ssh.run(allocator, sessh_args);
    }

    if (std.mem.eql(u8, args[1], ":internal-session-agent:")) {
        const agent_args = args[2..];
        if (agent_args.len != 2 or !std.mem.eql(u8, agent_args[0], "--session-dir")) {
            try io.writeAll(2, "sessh: :internal-session-agent: requires --session-dir DIR\n");
            return process_exit.request(64);
        }
        return session_agent.runSessionAgent(agent_args[1]);
    }

    if (std.mem.eql(u8, args[1], ":internal-session-broker:")) {
        return session_broker.run(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-control:")) {
        if (args[2..].len != 0) {
            try io.writeAll(2, "sessh: :internal-control: does not accept arguments\n");
            return process_exit.request(64);
        }
        return session_broker.runControl(allocator);
    }

    if (std.mem.eql(u8, args[1], ":internal-stream-broker:")) {
        return stream_agent.runBroker(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-stream-agent:")) {
        return stream_agent.runAgent(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":internal-proxy-stream:")) {
        return transport_ssh.runProxyStream(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], "force-compat")) {
        return mux_force_compat.run(allocator, args[2..]);
    }

    return mux.run(allocator, args);
}

fn argsFromInternalSessh(allocator: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], ":internal-sessh:"));

    const sessh_args = try allocator.alloc([]const u8, args.len - 1);
    sessh_args[0] = args[0];
    @memcpy(sessh_args[1..], args[2..]);
    return sessh_args;
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

test "version label follows entrypoint" {
    try std.testing.expectEqualStrings("sessh", entrypointName(.sessh));
    try std.testing.expectEqualStrings("sesshmux", entrypointName(.sesshmux));
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

test "internal sessh modality removes sentinel" {
    const rewritten = try argsFromInternalSessh(std.testing.allocator, &.{
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

fn usage(code: u8, entrypoint: EntryPoint) !void {
    const text = switch (entrypoint) {
        .sessh =>
        \\usage:
        \\  sessh [ssh-option ...] destination [command argument ...]
        \\
        \\sessh wraps ssh, making sessions persistent and automatically
        \\reconnecting when ssh drops.
        \\
        \\sessh supports ssh-style escape controls. `ENTER ~ d` detaches the
        \\local client and leaves the session running. `ENTER ~ .` requests
        \\that the session be killed, then detaches immediately.
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
        \\  sesshmux kill [--jsonl] [[--ssh-options "ssh args"] HOST] ID...
        \\  sesshmux kill [--jsonl] --all [[--ssh-options "ssh args"] HOST]
        \\  sesshmux detach [--all|--last-input|CLIENT_GUID] [ID]
        \\  sesshmux repaint [--scrollback] [--last-input|CLIENT_GUID] [ID]
        \\  sesshmux debug sever-connection|unresponsive-connection [--seconds N] [--all|--last-input|CLIENT_GUID] [ID]
        \\
        \\local target:
        \\  Use . as HOST to operate on local sessions.
        \\
        \\common options:
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
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--filter-level") or
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
    _ = @import("core/io.zig");
    _ = @import("core/process_exit.zig");
    _ = @import("core/shell.zig");
    _ = @import("mux/attach.zig");
    _ = @import("mux/cli.zig");
    _ = @import("mux/client_control_args.zig");
    _ = @import("mux/client_control.zig");
    _ = @import("mux/common.zig");
    _ = @import("mux/debug.zig");
    _ = @import("mux/detach.zig");
    _ = @import("mux/force_compat.zig");
    _ = @import("mux/kill.zig");
    _ = @import("mux/list.zig");
    _ = @import("mux/local.zig");
    _ = @import("mux/mod.zig");
    _ = @import("mux/new.zig");
    _ = @import("mux/parser.zig");
    _ = @import("mux/repaint.zig");
    _ = @import("mux/routed.zig");
    _ = @import("protocol/mod.zig");
    _ = @import("reconnect/control.zig");
    _ = @import("reconnect/mod.zig");
    _ = @import("reconnect/title.zig");
    _ = @import("runtime/list_format.zig");
    _ = @import("runtime/route_commands.zig");
    _ = @import("runtime/refresher.zig");
    _ = @import("runtime/session_registry.zig");
    _ = @import("session/attached_client.zig");
    _ = @import("session/attach.zig");
    _ = @import("session/agent.zig");
    _ = @import("session/broker.zig");
    _ = @import("session/client_config.zig");
    _ = @import("session/client_ui.zig");
    _ = @import("session/local_broker.zig");
    _ = @import("session/new.zig");
    _ = @import("session/renderer.zig");
    _ = @import("session/vt.zig");
    _ = @import("stream/agent.zig");
    _ = @import("stream/proxy_control.zig");
    _ = @import("tty/pty_process.zig");
    _ = @import("tty/settings.zig");
    _ = @import("tty/terminal.zig");
    _ = @import("tty/transcript.zig");
    _ = @import("transport/artifact_manifest.zig");
    _ = @import("transport/frame_forwarder.zig");
    _ = @import("transport/socket.zig");
    _ = @import("transport/ssh.zig");
}
