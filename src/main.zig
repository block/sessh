const std = @import("std");
const c = std.c;
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

    const entrypoint = detectEntryPoint(args[0]);

    if (args.len == 1) return usage(0, entrypoint);
    if (hasAnyArg(args, &.{ "--help", "-h" })) return usage(0, entrypoint);
    if (hasArg(args, "--version")) {
        try io.writeAll(1, "sessh " ++ config.version ++ "\n");
        return;
    }

    if (isMuxOnlyEntryMode(args[1]) and entrypoint != .sesshmux) {
        try io.writeAll(2, "sessh: local/internal modes are only supported by sesshmux\n");
        return process_exit.request(64);
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

    return ssh_client.runMux(allocator, args);
}

const EntryPoint = enum {
    sessh,
    sesshmux,
};

fn detectEntryPoint(exe_path: []const u8) EntryPoint {
    if (c.getenv("SESSH_ENTRYPOINT")) |entrypoint_z| {
        const entrypoint = std.mem.span(entrypoint_z);
        if (std.mem.eql(u8, entrypoint, "sessh")) return .sessh;
        if (std.mem.eql(u8, entrypoint, "sesshmux")) return .sesshmux;
    }
    return if (isMuxExecutable(exe_path)) .sesshmux else .sessh;
}

fn isMuxOnlyEntryMode(arg: []const u8) bool {
    return std.mem.eql(u8, arg, ".") or std.mem.startsWith(u8, arg, ":internal-");
}

fn isMuxExecutable(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.mem.eql(u8, name, "sesshmux") or
        std.mem.eql(u8, name, "sesshmux-dev") or
        std.mem.startsWith(u8, name, "sesshmux-") or
        isSha256HexName(name);
}

fn isSha256HexName(name: []const u8) bool {
    if (name.len != 64) return false;
    for (name) |byte| {
        _ = std.fmt.charToDigit(byte, 16) catch return false;
    }
    return true;
}

test "mux-only entry modes are limited to sesshmux executable names" {
    try std.testing.expect(isMuxOnlyEntryMode(":internal-broker:"));
    try std.testing.expect(isMuxOnlyEntryMode(":internal-session-agent:"));
    try std.testing.expect(isMuxOnlyEntryMode("."));
    try std.testing.expect(!isMuxOnlyEntryMode("new"));

    try std.testing.expect(isMuxExecutable("/opt/sessh/bin/sesshmux"));
    try std.testing.expect(isMuxExecutable("/tmp/sesshmux-dev"));
    try std.testing.expect(isMuxExecutable("/opt/sessh/libexec/sessh/sesshmux-linux-x86_64"));
    try std.testing.expect(isMuxExecutable("/tmp/cache/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isMuxExecutable("/opt/sessh/bin/sessh"));
    try std.testing.expect(!isMuxExecutable("/tmp/sessh-dev"));
    try std.testing.expect(!isMuxExecutable("/tmp/cache/not-a-sha256"));
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
        \\  sesshmux list [[--ssh-options "ssh args"] HOST]
        \\  sesshmux kill [[--ssh-options "ssh args"] HOST] ID
        \\  sesshmux kill --all [[--ssh-options "ssh args"] HOST]
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
    _ = @import("session_agent.zig");
    _ = @import("relay.zig");
    _ = @import("session_registry.zig");
    _ = @import("ssh_client.zig");
    _ = @import("terminal.zig");
    _ = @import("tty_transcript.zig");
    _ = @import("vt.zig");
}
