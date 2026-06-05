const std = @import("std");

const app_allocator = @import("../core/app_allocator.zig");

const config = @import("../core/config.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub fn start(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !std.process.Child {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

pub fn runCommand(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2..], broker_args);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(config.client_version_env, config.version);

    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

pub fn anySessionExists(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) bool {
    return brokerListMatches(allocator, exe, broker_args, null);
}

pub fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

pub fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}

fn brokerListMatches(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8, session_id: ?[]const u8) bool {
    const argv = allocator.alloc([]const u8, 4 + broker_args.len) catch return false;
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    @memcpy(argv[2 .. 2 + broker_args.len], broker_args);
    argv[2 + broker_args.len] = "list";
    argv[3 + broker_args.len] = "--jsonl";
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (session_id) |id| return listContainsSession(result.stdout, id);
    return listHasAnySession(result.stdout);
}

fn listContainsSession(stdout: []const u8, session_id: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, app_allocator.allocator(), line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const id = jsonStringField(object, "id") orelse "";
        const guid = jsonStringField(object, "guid") orelse "";
        if (std.mem.eql(u8, id, session_id) or std.mem.eql(u8, guid, session_id)) return true;
    }
    return false;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn listHasAnySession(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) return true;
    }
    return false;
}
