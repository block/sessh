const std = @import("std");

const config = @import("../core/config.zig");

const bootstrapper_script = @embedFile("../bootstrapper.sh");
pub const bootstrap_exec_encoded_arg_prefix = "b64:";

pub const Entrypoint = enum {
    broker,

    pub fn arg(self: Entrypoint) []const u8 {
        return switch (self) {
            // Role process for the daemon-to-daemon tunnel bridge. The name is
            // about brokering tunnel bytes across ssh stdio, not owning sessions.
            .broker => "sessh-broker",
        };
    }
};

/// ssh remote commands are evaluated by the remote account's login shell. Wrap
/// the embedded script so that shell only execs POSIX sh. This gives the
/// bootstrapper one shell contract to implement and test instead of inheriting
/// every possible remote login shell's behavior.
pub fn bootstrapCommand(allocator: std.mem.Allocator) ![]u8 {
    return shCommand(allocator, bootstrapper_script);
}

pub fn directBrokerCommand(allocator: std.mem.Allocator, broker_args: []const []const u8) ![]u8 {
    // `--no-bootstrap` can only assume a `sessh` executable is already on the
    // remote PATH. The bootstrapped path uses the `sessh-broker` role name;
    // this fallback enters broker mode through `sessh` itself and immediately
    // re-execs the role symlink once the remote namespace is known.
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    const client_version = try shellQuote(allocator, config.version);
    defer allocator.free(client_version);
    try script.appendSlice(allocator, "SESSH_CLIENT_VERSION=");
    try script.appendSlice(allocator, client_version);
    try script.appendSlice(allocator, " exec sessh :broker:");
    for (broker_args) |arg| {
        const quoted = try shellQuote(allocator, arg);
        defer allocator.free(quoted);
        try script.append(allocator, ' ');
        try script.appendSlice(allocator, quoted);
    }
    try script.append(allocator, '\n');
    return shCommand(allocator, script.items);
}

pub fn shCommand(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    const quoted_script = try shellQuote(allocator, script);
    defer allocator.free(quoted_script);
    return std.fmt.allocPrint(allocator, "exec /bin/sh -c {s}", .{quoted_script});
}

pub fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

pub fn isPlainShellArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', '=' => {},
            else => return false,
        }
    }
    return true;
}

pub fn needsEncodedExecArg(arg: []const u8) bool {
    return !isPlainShellArg(arg) or std.mem.startsWith(u8, arg, bootstrap_exec_encoded_arg_prefix);
}

// OpenSSH does not preserve argv for `ssh HOST cmd args...`; it joins the
// remaining local argv with spaces and lets the remote login shell interpret
// the result. The caller is responsible for only using this for that ssh-shaped
// command form.
pub fn joinRemoteShellCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args, 0..) |arg, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

pub fn shellCommandFromRemoteArgs(allocator: std.mem.Allocator, args: []const []const u8) !?[]u8 {
    if (args.len == 0) return null;
    const command = try joinRemoteShellCommandArgs(allocator, args);
    if (command.len == 0) {
        // OpenSSH treats an empty remote command as no command at all. That is
        // different from a non-empty command string such as `""`, which the
        // remote shell evaluates and typically fails to execute.
        allocator.free(command);
        return null;
    }
    return command;
}

test "bootstrap EXEC arg encoding is used for unsafe or reserved tokens" {
    try std.testing.expect(!needsEncodedExecArg("kill"));
    try std.testing.expect(!needsEncodedExecArg("--jsonl"));
    try std.testing.expect(needsEncodedExecArg("{\"guid\":\"s-1\"}"));
    try std.testing.expect(needsEncodedExecArg("b64:literal"));
}

test "shellQuote produces single-quoted shell words" {
    const quoted = try shellQuote(std.testing.allocator, "alpha ' beta");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'alpha '\\'' beta'", quoted);
}

test "joinRemoteShellCommandArgs matches ssh remote command joining" {
    const joined = try joinRemoteShellCommandArgs(std.testing.allocator, &.{ "echo", "$SESSH_TEST_HOST" });
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("echo $SESSH_TEST_HOST", joined);

    const empty = try joinRemoteShellCommandArgs(std.testing.allocator, &.{""});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const no_command = try shellCommandFromRemoteArgs(std.testing.allocator, &.{""});
    try std.testing.expectEqual(@as(?[]u8, null), no_command);

    const quoted_empty_command = try shellCommandFromRemoteArgs(std.testing.allocator, &.{"\"\""});
    defer std.testing.allocator.free(quoted_empty_command.?);
    try std.testing.expectEqualStrings("\"\"", quoted_empty_command.?);
}
