const std = @import("std");

const mux_attach = @import("attach.zig");
const mux_client_control = @import("client_control.zig");
const mux_cli = @import("cli.zig");
const mux_debug = @import("debug.zig");
const mux_detach = @import("detach.zig");
const mux_kill = @import("kill.zig");
const mux_list = @import("list.zig");
const mux_new = @import("new.zig");
const mux_remote_args = @import("remote_args.zig");
const mux_repaint = @import("repaint.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !mux_cli.Invocation {
    if (args.len < 2) return error.UnsupportedMuxCommand;
    var scratch = mux_cli.Scratch{ .allocator = allocator };
    errdefer scratch.deinit();

    const command = args[1];
    if (std.mem.eql(u8, command, "new")) {
        return scratch.finish(.{ .new = try mux_new.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "attach")) {
        return scratch.finish(.{ .attach = try mux_attach.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "list")) {
        return scratch.finish(.{ .list = try mux_list.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "kill")) {
        return scratch.finish(.{ .kill = try mux_kill.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "detach")) {
        return scratch.finish(.{ .detach = try mux_detach.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "repaint")) {
        return scratch.finish(.{ .repaint = try mux_repaint.parse(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "debug")) {
        return scratch.finish(.{ .debug = try mux_debug.parse(&scratch, args[2..]) });
    }
    return error.UnsupportedMuxCommand;
}

pub fn isSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "new") or
        std.mem.eql(u8, arg, "attach") or
        std.mem.eql(u8, arg, "list") or
        std.mem.eql(u8, arg, "kill") or
        std.mem.eql(u8, arg, "detach") or
        std.mem.eql(u8, arg, "repaint") or
        std.mem.eql(u8, arg, "debug");
}

pub fn remoteLocalArgs(
    allocator: std.mem.Allocator,
    original_args: []const []const u8,
    default_session_ref: ?[]const u8,
) ![]const []const u8 {
    var invocation = try parse(allocator, original_args);
    defer invocation.deinit(allocator);
    return remoteLocalArgsForCommand(allocator, invocation.command, default_session_ref, null);
}

pub fn remoteLocalArgsForCommand(
    allocator: std.mem.Allocator,
    command: mux_cli.Command,
    default_session_ref: ?[]const u8,
    route: ?*const session_registry.Route,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, "sesshmux");
    switch (command) {
        .new => |new| try mux_new.appendRemoteArgs(allocator, &out, new),
        .attach => |attach| try mux_attach.appendRemoteArgs(allocator, &out, attach),
        .list => |list| try mux_remote_args.appendList(allocator, &out, list),
        .kill => |kill| try mux_remote_args.appendKill(allocator, &out, kill, route),
        .detach => |control| try mux_client_control.appendRemoteArgs(allocator, &out, "detach", null, control, default_session_ref),
        .repaint => |control| try mux_client_control.appendRemoteArgs(allocator, &out, "repaint", null, control, default_session_ref),
        .debug => |debug| try mux_debug.appendRemoteArgs(allocator, &out, debug, default_session_ref),
    }
    return out.toOwnedSlice(allocator);
}

test "parse rejects host-first mux invocations" {
    try std.testing.expectError(error.UnsupportedMuxCommand, parse(std.testing.allocator, &.{ "sesshmux", ".", "list" }));
    try std.testing.expectError(error.UnsupportedMuxCommand, parse(std.testing.allocator, &.{ "sesshmux", "example.com", "list" }));
}

test "parse rejects raw short ssh options in mux subcommands" {
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "new", "-n", "test-host" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "attach", "-n", "--host", "test-host", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "list", "-n" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "kill", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "detach", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "repaint", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "debug", "sever-connection", "-n", "s1" }));
}

test "remote local args prepends host and id before debug action" {
    const argv = try remoteLocalArgs(std.testing.allocator, &.{
        "sesshmux-dev",
        "debug",
        "sever-connection",
        "--ssh-options",
        "-F cfg -p 2222",
        "--host",
        "test-host",
        "--last-input",
        "s1",
    }, null);
    defer std.testing.allocator.free(argv);

    try expectArgvEqual(&.{
        "sesshmux",
        "debug",
        "--host",
        ".",
        "--id",
        "s1",
        "sever-connection",
        "--last-input",
    }, argv);
}

test "remote local args appends local host when caller already parsed remote target" {
    const argv = try remoteLocalArgs(std.testing.allocator, &.{
        "sesshmux-dev",
        "debug",
        "sever-connection",
        "--last-input",
        "s1",
    }, null);
    defer std.testing.allocator.free(argv);

    try expectArgvEqual(&.{
        "sesshmux",
        "debug",
        "--host",
        ".",
        "--id",
        "s1",
        "sever-connection",
        "--last-input",
    }, argv);
}

test "remote local args applies default session ref without leaking ssh options" {
    const argv = try remoteLocalArgs(std.testing.allocator, &.{
        "sesshmux-dev",
        "debug",
        "sever-connection",
        "--ssh-options",
        "-F cfg",
        "--host",
        "test-host",
        "--last-input",
    }, "s-00000000-0000-4000-8000-000000000001");
    defer std.testing.allocator.free(argv);

    try expectArgvEqual(&.{
        "sesshmux",
        "debug",
        "--host",
        ".",
        "--id",
        "s-00000000-0000-4000-8000-000000000001",
        "sever-connection",
        "--last-input",
    }, argv);
}

test "remote local args cover list and kill public commands" {
    const list_argv = try remoteLocalArgs(std.testing.allocator, &.{
        "sesshmux-dev",
        "list",
        "--ssh-options",
        "-F cfg -p 2222",
        "--host",
        "test-host",
        "--jsonl",
        "--client=s1",
    }, null);
    defer std.testing.allocator.free(list_argv);
    try expectArgvEqual(&.{
        "sesshmux",
        "list",
        "--host",
        ".",
        "--jsonl",
        "--client=s1",
    }, list_argv);

    const request_json = "{\"guid\":\"s-00000000-0000-4000-8000-000000000001\",\"requested_age_ms\":123}";
    const kill_argv = try remoteLocalArgs(std.testing.allocator, &.{
        "sesshmux-dev",
        "kill",
        "--host",
        "test-host",
        "--jsonl",
        "--request",
        request_json,
    }, null);
    defer std.testing.allocator.free(kill_argv);
    try expectArgvEqual(&.{
        "sesshmux",
        "kill",
        "--host",
        ".",
        "--jsonl",
        "--request",
        request_json,
    }, kill_argv);
}

test "remote local args use resolved route guid for kill refs" {
    var invocation = try parse(std.testing.allocator, &.{
        "sesshmux-dev",
        "kill",
        "s-remote",
    });
    defer invocation.deinit(std.testing.allocator);
    var route = session_registry.Route{
        .guid = @constCast("s-00000000-0000-4000-8000-000000000001"),
        .session_dir = @constCast(""),
        .host_guid = @constCast(""),
        .host = @constCast("test-host"),
        .resolved_host = @constCast("test-host"),
        .port = @constCast("22"),
        .agent_version = @constCast("test"),
        .ssh_options = &.{},
        .last_known_alive = true,
        .attached_count = null,
        .last_input_at_unix_ms = null,
        .detached_at_unix_ms = null,
        .kill_requested = false,
        .tombstone_retention_ms = 0,
    };

    const argv = try remoteLocalArgsForCommand(std.testing.allocator, invocation.command, null, &route);
    defer std.testing.allocator.free(argv);
    try expectArgvEqual(&.{
        "sesshmux",
        "kill",
        "--host",
        ".",
        "--id",
        "s-00000000-0000-4000-8000-000000000001",
    }, argv);
}

fn expectArgvEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}
