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

    if (args.len == 1) return usage(0);
    if (hasAnyArg(args, &.{ "--help", "-h" })) return usage(0);
    if (hasArg(args, "--version")) {
        try io.writeAll(1, "sessh " ++ config.version ++ "\n");
        return;
    }

    if (std.mem.eql(u8, args[1], ":internal-session-agent:")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "--session-dir")) {
            try io.writeAll(2, "sessh: :internal-session-agent: requires --session-dir DIR\n");
            return process_exit.request(64);
        }
        return session_agent.runSessionAgent(args[3]);
    }

    if (std.mem.eql(u8, args[1], ":internal-host-broker:")) {
        return broker.run(allocator, args[0], args[2..]);
    }

    if (std.mem.eql(u8, args[1], ":local:")) {
        return client.run(allocator, args);
    }

    return ssh_client.runMux(allocator, args);
}

fn usage(code: u8) !void {
    const text =
        \\usage:
        \\  sessh [sessh-options] [ssh-options] HOST [-- cmd arg...]
        \\  sesshmux new [options] [--ssh-options "ssh args"] HOST [-- cmd arg...]
        \\  sesshmux attach [options] ID
        \\  sesshmux attach [options] HOST ID
        \\  sesshmux attach --host HOST [ID]
        \\  sesshmux list [--ssh-options "ssh args"] HOST
        \\  sesshmux kill [--ssh-options "ssh args"] HOST ID
        \\  sesshmux kill --all [--ssh-options "ssh args"] HOST
        \\
        \\sessh-specific options:
        \\  --alias NAME
        \\  --state-dir DIR
        \\  --leader CTRL-KEY|None
        \\  --scrollback-limit N
        \\  --initial-scrollback N
        \\  --log-level quiet|error|warn|info|debug|verbose
        \\  --capture-tty-transcript PATH.tar.gz
        \\  --bootstrap | --no-bootstrap
        \\  --force-compat
        \\
        \\sesshmux-specific options:
        \\  --ssh-options "SSH_ARGS"
        \\
    ;
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
