const std = @import("std");

const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const routing = @import("routing.zig");
const sessh_cli = @import("cli.zig");
const ssh_opts = @import("../transport/ssh_options.zig");

const SshTtyRequest = ssh_opts.SshTtyRequest;

const ParsedSesshForTest = struct {
    invocation: sessh_cli.Invocation,
    owned_ssh_options: ?[][]const u8 = null,

    fn deinit(self: *ParsedSesshForTest, allocator: std.mem.Allocator) void {
        if (self.owned_ssh_options) |options| allocator.free(options);
        self.* = undefined;
    }
};

fn parseSshArgsForTest(allocator: std.mem.Allocator, args: []const []const u8) !ParsedSesshForTest {
    var scratch = sessh_cli.Scratch{ .allocator = allocator };
    defer scratch.deinit();
    const parsed = try sessh_cli.parse(&scratch, args);
    const owned_ssh_options = scratch.owned_ssh_options;
    scratch.owned_ssh_options = null;
    return .{
        .invocation = parsed,
        .owned_ssh_options = owned_ssh_options,
    };
}

fn remoteNewFromParsedSessh(parsed: ParsedSesshForTest) routing.RemoteNewSession {
    return .{
        .shell_command_args = parsed.invocation.command_args,
        .tty_request = parsed.invocation.tty_request,
        .proxy_required = parsed.invocation.proxy_required,
    };
}

fn shouldUseStreamPathForTest(parsed: ParsedSesshForTest, stdin_is_tty: bool) bool {
    return routing.shouldUseStreamPath(remoteNewFromParsedSessh(parsed), stdin_is_tty);
}

fn shouldUseProxyStreamForTest(parsed: ParsedSesshForTest, stdin_is_tty: bool) bool {
    return shouldUseProxyStreamForTestWithStdout(parsed, stdin_is_tty, true);
}

fn shouldUseProxyStreamForTestWithStdout(parsed: ParsedSesshForTest, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    return routing.shouldUseProxyStream(.{
        .new = remoteNewFromParsedSessh(parsed),
        .common = parsed.invocation.common,
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
    });
}

test "remote shell command detection treats empty command like OpenSSH" {
    try std.testing.expect(!routing.hasRemoteShellCommand(&.{""}));
    try std.testing.expect(routing.hasRemoteShellCommand(&.{"\"\""}));
    try std.testing.expect(routing.hasRemoteShellCommand(&.{ "", "" }));
}

test "ssh verbosity maps to inferred client log level" {
    try std.testing.expectEqual(client_log.Level.warn, routing.inferredClientLogLevel(&.{}));
    try std.testing.expectEqual(client_log.Level.info, routing.inferredClientLogLevel(&.{"-v"}));
    try std.testing.expectEqual(client_log.Level.debug, routing.inferredClientLogLevel(&.{"-vv"}));
    try std.testing.expectEqual(client_log.Level.verbose, routing.inferredClientLogLevel(&.{"-vvv"}));
    try std.testing.expectEqual(client_log.Level.verbose, routing.inferredClientLogLevel(&.{ "-vC", "-vv" }));
}

test "parseSshArgs selects proxy stream mode for OpenSSH-owned options" {
    var x11 = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-X",
        "example.com",
    });
    defer x11.deinit(std.testing.allocator);
    try std.testing.expect(x11.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(x11, true));

    var forward_agent = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-A",
        "example.com",
    });
    defer forward_agent.deinit(std.testing.allocator);
    try std.testing.expect(forward_agent.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(forward_agent, true));

    var stdin_null = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-n",
        "example.com",
    });
    defer stdin_null.deinit(std.testing.allocator);
    try std.testing.expect(stdin_null.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(stdin_null, true));

    var fork_after_auth = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-f",
        "example.com",
    });
    defer fork_after_auth.deinit(std.testing.allocator);
    try std.testing.expect(fork_after_auth.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(fork_after_auth, true));

    var forward = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-L",
        "8080:localhost:80",
        "example.com",
    });
    defer forward.deinit(std.testing.allocator);
    try std.testing.expect(forward.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(forward, true));

    var direct = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-W",
        "host:22",
        "example.com",
    });
    defer direct.deinit(std.testing.allocator);
    try std.testing.expect(direct.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(direct, true));

    var request_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-o",
        "RequestTTY=force",
        "example.com",
    });
    defer request_tty.deinit(std.testing.allocator);
    try std.testing.expect(request_tty.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(request_tty, true));

    var explicit = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "example.com",
    });
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.hygienic, explicit.invocation.common.filter_level);
    try std.testing.expect(explicit.invocation.common.filter_level_set);
    try std.testing.expect(shouldUseProxyStreamForTest(explicit, true));

    var explicit_disabled = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "emulated",
        "example.com",
    });
    defer explicit_disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.emulated, explicit_disabled.invocation.common.filter_level);
    try std.testing.expect(explicit_disabled.invocation.common.filter_level_set);
    try std.testing.expect(!shouldUseProxyStreamForTest(explicit_disabled, true));
}

test "stream routing preserves ssh remote command tty semantics" {
    var command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "echo",
        "hello",
    });
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqual(SshTtyRequest.none, command.invocation.tty_request);
    try std.testing.expectEqual(@as(usize, 2), command.invocation.command_args.len);
    try std.testing.expect(shouldUseStreamPathForTest(command, false));
    try std.testing.expect(shouldUseStreamPathForTest(command, true));
    try std.testing.expect(shouldUseProxyStreamForTest(command, false));
    try std.testing.expect(shouldUseProxyStreamForTest(command, true));

    var single = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "tty",
    });
    defer single.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(single, false));
    try std.testing.expect(!shouldUseStreamPathForTest(single, true));
    try std.testing.expect(shouldUseProxyStreamForTest(single, false));
    try std.testing.expect(!shouldUseProxyStreamForTest(single, true));

    var forced = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-tt",
        "example.com",
        "tty",
    });
    defer forced.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(forced, false));
    try std.testing.expect(!shouldUseStreamPathForTest(forced, true));
    try std.testing.expect(shouldUseProxyStreamForTest(forced, false));
    try std.testing.expect(!shouldUseProxyStreamForTest(forced, true));
}

test "emulated mode falls back to proxy stream when stdin or stdout is not a tty" {
    var requested_tty_command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "tty",
    });
    defer requested_tty_command.deinit(std.testing.allocator);
    try std.testing.expect(!shouldUseProxyStreamForTestWithStdout(requested_tty_command, true, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(requested_tty_command, false, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(requested_tty_command, true, false));

    var interactive = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "example.com",
    });
    defer interactive.deinit(std.testing.allocator);
    try std.testing.expect(!shouldUseProxyStreamForTestWithStdout(interactive, true, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(interactive, false, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(interactive, true, false));
}

test "hygienic filter level forces proxy path and preserves ssh tty semantics" {
    var interactive = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "example.com",
    });
    defer interactive.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.hygienic, interactive.invocation.common.filter_level);
    try std.testing.expect(interactive.invocation.common.filter_level_set);
    try std.testing.expect(!shouldUseStreamPathForTest(interactive, true));
    try std.testing.expect(!shouldUseStreamPathForTest(interactive, false));
    try std.testing.expect(shouldUseProxyStreamForTest(interactive, true));
    try std.testing.expect(shouldUseProxyStreamForTest(interactive, false));

    var command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "example.com",
        "echo",
        "hello",
    });
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(command, true));
    try std.testing.expect(shouldUseProxyStreamForTest(command, true));

    var forced = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "-tt",
        "example.com",
        "tty",
    });
    defer forced.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(forced, false));
    try std.testing.expect(shouldUseProxyStreamForTest(forced, false));

    var requested_with_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "-t",
        "example.com",
        "tty",
    });
    defer requested_with_tty.deinit(std.testing.allocator);
    try std.testing.expect(!shouldUseStreamPathForTest(requested_with_tty, true));
    try std.testing.expect(shouldUseProxyStreamForTest(requested_with_tty, true));

    var requested_without_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "-t",
        "example.com",
        "tty",
    });
    defer requested_without_tty.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(requested_without_tty, false));
    try std.testing.expect(shouldUseProxyStreamForTest(requested_without_tty, false));
}
