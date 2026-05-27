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
        return err;
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
    if (hasAnyArg(args, &.{ "--help", "-h" })) return usage(0, entrypoint);
    if (hasArg(args, "--version")) {
        try io.writeAll(1, entrypointName(entrypoint));
        try io.writeAll(1, " " ++ config.version ++ "\n");
        return;
    }

    if (entrypoint == .sessh) {
        const sessh_args = try sesshArgsFromInternal(allocator, args);
        defer allocator.free(sessh_args);
        return ssh_client.runMux(allocator, sessh_args, false);
    }

    if (std.mem.eql(u8, args[1], ":internal-session-agent:")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--session-dir")) {
            try io.writeAll(2, "sessh: :internal-session-agent: requires --session-dir DIR\n");
            return process_exit.request(64);
        }
        return session_agent.runSessionAgent(args[3]);
    }

    if (std.mem.eql(u8, args[1], ":internal-broker:")) {
        return broker.run(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ".")) {
        return client.run(allocator, args);
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

    const sessh_args = try allocator.alloc([]const u8, args.len);
    sessh_args[0] = args[0];
    sessh_args[1] = "new";
    @memcpy(sessh_args[2..], args[2..]);
    return sessh_args;
}

test "version label follows entrypoint" {
    try std.testing.expectEqualStrings("sessh", entrypointName(.sessh));
    try std.testing.expectEqualStrings("sesshmux", entrypointName(.sesshmux));
}

test "internal sessh modality maps to mux new command" {
    const rewritten = try sesshArgsFromInternal(std.testing.allocator, &.{
        "sesshmux-macos-aarch64",
        ":internal-sessh:",
        "-v",
        "example.com",
    });
    defer std.testing.allocator.free(rewritten);

    try std.testing.expectEqual(@as(usize, 4), rewritten.len);
    try std.testing.expectEqualStrings("sesshmux-macos-aarch64", rewritten[0]);
    try std.testing.expectEqualStrings("new", rewritten[1]);
    try std.testing.expectEqualStrings("-v", rewritten[2]);
    try std.testing.expectEqualStrings("example.com", rewritten[3]);
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
        \\  sesshmux list [--refresh] [--jsonl] [[--ssh-options "ssh args"] HOST]
        \\  sesshmux kill [[--ssh-options "ssh args"] HOST] ID
        \\  sesshmux kill --all [[--ssh-options "ssh args"] HOST]
        \\  sesshmux list-clients [--jsonl] [ID]
        \\  sesshmux detach [--all|--last-input|CLIENT_GUID] [ID]
        \\  sesshmux repaint [--scrollback] [--last-input|CLIENT_GUID] [ID]
        \\  sesshmux debug sever-connection|unresponsive-connection [--all|--last-input|CLIENT_GUID] [ID]
        \\
        \\local target:
        \\  Use . as HOST to operate on local sessions.
        \\
        \\common options:
        \\  --alias NAME
        \\  --leader CTRL-KEY|None
        \\  --runtime-dir DIR
        \\  --ssh-options "SSH_ARGS"
        \\
        \\See the user manual for advanced usage:
        \\  https://github.com/block/sessh/blob/main/docs/USER_MANUAL.md
        \\
    };
    try io.writeAll(if (code == 0) 1 else 2, text);
    return process_exit.request(code);
}

fn hasAnyArg(args: []const []const u8, needles: []const []const u8) bool {
    for (args) |arg| {
        for (needles) |needle| {
            if (std.mem.eql(u8, arg, needle)) return true;
        }
    }
    return false;
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    return hasAnyArg(args, &.{needle});
}

test {
    _ = @import("app_allocator.zig");
    _ = @import("broker.zig");
    _ = @import("client_renderer.zig");
    _ = @import("process_exit.zig");
    _ = @import("runtime_refresher.zig");
    _ = @import("session_agent.zig");
    _ = @import("relay.zig");
    _ = @import("session_registry.zig");
    _ = @import("ssh_client.zig");
    _ = @import("terminal.zig");
    _ = @import("tty_transcript.zig");
    _ = @import("vt.zig");
}
