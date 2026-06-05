const std = @import("std");

const client_log = @import("../core/client_log.zig");
const io_helpers = @import("../core/io.zig");
const list_format = @import("list_format.zig");
const runtime_commands = @import("commands.zig");
const session_registry = @import("session_registry.zig");
const shell = @import("../core/shell.zig");

pub const RemoteCommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *RemoteCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr);
        allocator.free(self.stdout);
        self.* = undefined;
    }
};

pub const RemoteCommandRunner = struct {
    context: *anyopaque,
    runFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) anyerror!RemoteCommandResult,

    pub fn run(
        self: *RemoteCommandRunner,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) !RemoteCommandResult {
        return self.runFn(self.context, allocator, host, ssh_options, argv);
    }
};

pub fn runLocalListCommand(
    allocator: std.mem.Allocator,
    exe: []const u8,
    refresh: bool,
    include_cached_routes: bool,
    jsonl: bool,
    exited: bool,
    all: bool,
    remote_runner: ?*RemoteCommandRunner,
) !u8 {
    if (include_cached_routes and refresh) try refreshCachedRemoteRoutes(allocator, exe, remote_runner);

    const exit_status = try runtime_commands.runListCommand(allocator, .{
        .format = if (jsonl) .jsonl else .table,
        .mode = if (exited) .exited else .live,
        .all = all,
        .local_only = (all or exited) and !include_cached_routes,
    });
    if (exit_status != 0) return exit_status;
    if (include_cached_routes and !exited and !all) {
        const appended_cached_routes = try appendCachedRemoteRouteRows(allocator, jsonl);
        if (appended_cached_routes and !refresh) {
            try io_helpers.writeAll(2, "sessh: cached remote session status may be out of date; run `sesshmux list --refresh` to update\n");
        }
    }
    return 0;
}

fn appendCachedRemoteRouteRows(allocator: std.mem.Allocator, jsonl: bool) !bool {
    var routes: std.ArrayList(session_registry.Route) = .empty;
    defer {
        for (routes.items) |*route| route.deinit(allocator);
        routes.deinit(allocator);
    }
    try loadCachedRemoteRoutes(allocator, &routes, true);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    for (routes.items) |route| {
        var input_buf: [32]u8 = undefined;
        const input = try formatRouteInput(&input_buf, route.last_input_at_unix_ms);
        var attached_buf: [32]u8 = undefined;
        const attached = formatRouteAttachedCount(&attached_buf, route.attached_count);
        const display_id = try session_registry.shortSessionGuid(allocator, route.guid);
        defer allocator.free(display_id);
        if (jsonl) {
            try list_format.writeJsonlRow(
                writer,
                display_id,
                route.host,
                route.agent_version,
                route.guid,
                route.attached_count,
                route.last_input_at_unix_ms,
            );
        } else {
            try list_format.writeRow(writer, display_id, attached, input, route.host, route.agent_version);
        }
    }
    if (out.items.len > 0) try io_helpers.writeAll(1, out.items);
    return routes.items.len > 0;
}

fn formatRouteAttachedCount(buf: []u8, attached_count: ?u32) []const u8 {
    if (attached_count) |count| return std.fmt.bufPrint(buf, "{}", .{count}) catch "???";
    return "???";
}

fn formatRouteInput(buf: []u8, last_input_at_unix_ms: ?u64) ![]const u8 {
    const ts = last_input_at_unix_ms orelse return "???";
    return formatRelativeUnixMs(buf, nowUnixMs(), ts);
}

fn formatRelativeUnixMs(buf: []u8, now_ms: u64, ts_ms: u64) ![]const u8 {
    const delta_ms = now_ms -| ts_ms;
    const seconds = delta_ms / std.time.ms_per_s;
    if (seconds < 60) return std.fmt.bufPrint(buf, "{}s ago", .{seconds});
    const minutes = seconds / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{}m ago", .{minutes});
    const hours = minutes / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{}h ago", .{hours});
    return std.fmt.bufPrint(buf, "{}d ago", .{hours / 24});
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn loadCachedRemoteRoutes(allocator: std.mem.Allocator, routes: *std.ArrayList(session_registry.Route), alive_only: bool) !void {
    const state_sessions_dir = try session_registry.stateSessionsDir(allocator);
    defer allocator.free(state_sessions_dir);
    var dir = std.fs.openDirAbsolute(state_sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        const route_path = try std.fmt.allocPrint(allocator, "{s}/{s}/route.json", .{ state_sessions_dir, entry.name });
        defer allocator.free(route_path);
        var route = session_registry.readRoute(allocator, route_path) catch continue;
        errdefer route.deinit(allocator);
        if (route.host.len == 0 or std.mem.eql(u8, route.host, ".") or (alive_only and !route.last_known_alive)) {
            route.deinit(allocator);
            continue;
        }
        try routes.append(allocator, route);
    }
}

fn refreshCachedRemoteRoutes(allocator: std.mem.Allocator, exe: []const u8, remote_runner: ?*RemoteCommandRunner) !void {
    var routes: std.ArrayList(session_registry.Route) = .empty;
    defer {
        for (routes.items) |*route| route.deinit(allocator);
        routes.deinit(allocator);
    }
    try loadCachedRemoteRoutes(allocator, &routes, true);

    for (routes.items, 0..) |*route, i| {
        if (routeConnectionWasAlreadyRefreshed(routes.items[0..i], route)) continue;
        const stdout = queryRemoteRouteList(allocator, exe, remote_runner, route, false, false) catch |err| {
            try io_helpers.stderrPrint("sessh: list refresh failed for {s}: {t}\n", .{ route.host, err });
            continue;
        };
        defer allocator.free(stdout);
        for (routes.items) |*candidate| {
            if (!sameRouteConnection(route, candidate)) continue;
            if (!try cachedRouteStillExists(allocator, candidate.guid)) continue;
            const remote_status = try remoteListStatusForGuid(allocator, stdout, candidate.guid);
            defer if (remote_status) |status| allocator.free(status.version);
            if (remote_status) |status| {
                try session_registry.updateRouteStatus(
                    allocator,
                    candidate.guid,
                    true,
                    status.version,
                    .{
                        .attached_count = status.attached_count,
                        .last_input_at_unix_ms = status.last_input_at_unix_ms,
                    },
                );
            }
        }
        try drainPendingRemoteRequests(allocator, exe, remote_runner, route.host, route.ssh_options, route.host_guid);
        for (routes.items) |*candidate| {
            if (!sameRouteConnection(route, candidate)) continue;
            if (!try cachedRouteStillExists(allocator, candidate.guid)) continue;
            const remote_status = try remoteListStatusForGuid(allocator, stdout, candidate.guid);
            defer if (remote_status) |status| allocator.free(status.version);
            if (remote_status != null) continue;
            try session_registry.writeTombstoneForRoute(
                allocator,
                candidate,
                .{
                    .ended_at_unix_ms = nowUnixMs(),
                    .end_reason = .unknown,
                    .exit_status = null,
                },
            );
        }
    }
    try refreshPendingKillsWithoutCachedRoute(allocator, exe, remote_runner, routes.items);
}

fn cachedRouteStillExists(allocator: std.mem.Allocator, guid: []const u8) !bool {
    var route = session_registry.readRouteForRef(allocator, guid) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    route.deinit(allocator);
    return true;
}

fn routeConnectionWasAlreadyRefreshed(previous: []const session_registry.Route, route: *const session_registry.Route) bool {
    for (previous) |*candidate| {
        if (sameRouteConnection(candidate, route)) return true;
    }
    return false;
}

fn sameRouteConnection(a: *const session_registry.Route, b: *const session_registry.Route) bool {
    if (a.host_guid.len != 0 and b.host_guid.len != 0) {
        return std.mem.eql(u8, a.host_guid, b.host_guid);
    }
    if (!std.mem.eql(u8, a.host, b.host)) return false;
    if (a.ssh_options.len != b.ssh_options.len) return false;
    for (a.ssh_options, b.ssh_options) |a_option, b_option| {
        if (!std.mem.eql(u8, a_option, b_option)) return false;
    }
    return true;
}

fn refreshPendingKillsWithoutCachedRoute(
    allocator: std.mem.Allocator,
    exe: []const u8,
    remote_runner: ?*RemoteCommandRunner,
    routes: []const session_registry.Route,
) !void {
    var pending_hosts = try session_registry.readPendingKillHosts(allocator);
    defer pending_hosts.deinit(allocator);
    for (pending_hosts.hosts) |host| {
        if (hostMatchesAnyRoute(routes, host.guid)) continue;
        var ssh_options: [2][]const u8 = undefined;
        const options = if (std.mem.eql(u8, host.port, session_registry.default_pending_port))
            &.{}
        else blk: {
            ssh_options = .{ "-p", host.port };
            break :blk ssh_options[0..];
        };
        try drainPendingRemoteRequests(allocator, exe, remote_runner, host.name, options, host.guid);
    }
}

fn hostMatchesAnyRoute(routes: []const session_registry.Route, host_guid: []const u8) bool {
    for (routes) |*route| {
        if (std.mem.eql(u8, route.host_guid, host_guid)) return true;
    }
    return false;
}

fn queryRemoteRouteList(
    allocator: std.mem.Allocator,
    exe: []const u8,
    remote_runner: ?*RemoteCommandRunner,
    route: *const session_registry.Route,
    exited: bool,
    all: bool,
) ![]u8 {
    return queryRemoteHostList(allocator, exe, remote_runner, route.host, route.ssh_options, exited, all);
}

fn queryRemoteHostList(
    allocator: std.mem.Allocator,
    exe: []const u8,
    remote_runner: ?*RemoteCommandRunner,
    host: []const u8,
    ssh_options: []const []const u8,
    exited: bool,
    all: bool,
) ![]u8 {
    if (remote_runner) |runner| {
        const extra_args: usize = 5 + (if (exited) @as(usize, 1) else 0) + (if (all) @as(usize, 1) else 0);
        const argv = try allocator.alloc([]const u8, extra_args);
        defer allocator.free(argv);
        argv[0] = "sesshmux";
        argv[1] = "list";
        argv[2] = "--host";
        argv[3] = ".";
        argv[4] = "--jsonl";
        var arg_index: usize = 5;
        if (exited) {
            argv[arg_index] = "--exited";
            arg_index += 1;
        }
        if (all) {
            argv[arg_index] = "--all";
            arg_index += 1;
        }
        var result = try runner.run(allocator, host, ssh_options, argv);
        errdefer result.deinit(allocator);
        if (result.exit_code == 0) {
            allocator.free(result.stderr);
            return result.stdout;
        }
        if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
        return error.RemoteListFailed;
    }

    const extra_args: usize = (if (exited) @as(usize, 1) else 0) +
        (if (all) @as(usize, 1) else 0);
    const ssh_options_arg = if (ssh_options.len > 0) try shell.joinArgs(allocator, ssh_options) else null;
    defer if (ssh_options_arg) |value| allocator.free(value);
    const ssh_option_args: usize = if (ssh_options_arg != null) 2 else 0;
    const argv = try allocator.alloc([]const u8, 2 + ssh_option_args + 2 + extra_args);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = "list";
    var arg_index: usize = 2;
    if (ssh_options_arg) |value| {
        argv[arg_index] = "--ssh-options";
        arg_index += 1;
        argv[arg_index] = value;
        arg_index += 1;
    }
    argv[arg_index] = host;
    arg_index += 1;
    argv[arg_index] = "--jsonl";
    arg_index += 1;
    if (exited) {
        argv[arg_index] = "--exited";
        arg_index += 1;
    }
    if (all) {
        argv[arg_index] = "--all";
        arg_index += 1;
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
            if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
            return error.RemoteListFailed;
        },
        else => return error.RemoteListFailed,
    }
}

fn queryRemoteHostKillJsonl(
    allocator: std.mem.Allocator,
    exe: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    targets: []const []const u8,
) ![]u8 {
    return queryRemoteHostKillJsonlWithRequests(allocator, exe, null, host, ssh_options, targets, &.{});
}

pub fn drainPendingRemoteRequests(
    allocator: std.mem.Allocator,
    exe: []const u8,
    remote_runner: ?*RemoteCommandRunner,
    host: []const u8,
    ssh_options: []const []const u8,
    pending_host_guid: []const u8,
) !void {
    if (host.len == 0 or std.mem.eql(u8, host, ".")) return;
    if (pending_host_guid.len == 0) return;
    var lock = (try session_registry.tryLockPendingKillsForHost(allocator, pending_host_guid)) orelse return;
    defer lock.deinit();
    var pending = try lock.read();
    defer pending.deinit(allocator);
    if (pending.entries.len == 0) {
        try lock.cleanupIfEmpty();
        return;
    }

    var request_jsons: std.ArrayList([]const u8) = .empty;
    defer {
        for (request_jsons.items) |json| allocator.free(json);
        request_jsons.deinit(allocator);
    }
    const now_ms = nowUnixMs();
    for (pending.entries) |*entry| {
        if (!std.mem.eql(u8, entry.type_name, "kill")) continue;
        if (entry.guid.len == 0) continue;
        const requested_age_ms: u64 = if (now_ms >= entry.requested_at_unix_ms) now_ms - entry.requested_at_unix_ms else 0;
        try request_jsons.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{{\"guid\":{f},\"requested_age_ms\":{}}}",
            .{ std.json.fmt(entry.guid, .{}), requested_age_ms },
        ));
    }
    if (request_jsons.items.len == 0) return;

    const stdout = queryRemoteHostKillJsonlWithRequests(allocator, exe, remote_runner, host, ssh_options, &.{}, request_jsons.items) catch |err| {
        try io_helpers.stderrPrint("sessh: pending cleanup failed for {s}: {t}\n", .{ host, err });
        return;
    };
    defer allocator.free(stdout);

    var handled: std.ArrayList([]const u8) = .empty;
    defer handled.deinit(allocator);
    try processKillJsonlForPendingDrain(allocator, host, stdout, &pending, &handled);
    if (handled.items.len == 0) return;
    try lock.removeHandled(&pending, handled.items);
}

fn queryRemoteHostKillJsonlWithRequests(
    allocator: std.mem.Allocator,
    exe: []const u8,
    remote_runner: ?*RemoteCommandRunner,
    host: []const u8,
    ssh_options: []const []const u8,
    targets: []const []const u8,
    request_jsons: []const []const u8,
) ![]u8 {
    if (remote_runner) |runner| {
        const request_args = request_jsons.len * 2;
        const argv = try allocator.alloc([]const u8, 5 + request_args + targets.len);
        defer allocator.free(argv);
        argv[0] = "sesshmux";
        argv[1] = "kill";
        argv[2] = "--host";
        argv[3] = ".";
        argv[4] = "--jsonl";
        var arg_index: usize = 5;
        for (request_jsons) |request_json| {
            argv[arg_index] = "--request";
            arg_index += 1;
            argv[arg_index] = request_json;
            arg_index += 1;
        }
        @memcpy(argv[arg_index..], targets);

        var result = try runner.run(allocator, host, ssh_options, argv);
        errdefer result.deinit(allocator);
        if (result.exit_code == 0 or result.stdout.len > 0) {
            allocator.free(result.stderr);
            return result.stdout;
        }
        if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
        return error.RemoteKillFailed;
    }

    const ssh_options_arg = if (ssh_options.len > 0) try shell.joinArgs(allocator, ssh_options) else null;
    defer if (ssh_options_arg) |value| allocator.free(value);
    const ssh_option_args: usize = if (ssh_options_arg != null) 2 else 0;
    const request_args = request_jsons.len * 2;
    const argv = try allocator.alloc([]const u8, 2 + ssh_option_args + 1 + 1 + request_args + targets.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = "kill";
    var arg_index: usize = 2;
    if (ssh_options_arg) |value| {
        argv[arg_index] = "--ssh-options";
        arg_index += 1;
        argv[arg_index] = value;
        arg_index += 1;
    }
    argv[arg_index] = host;
    arg_index += 1;
    argv[arg_index] = "--jsonl";
    arg_index += 1;
    for (request_jsons) |request_json| {
        argv[arg_index] = "--request";
        arg_index += 1;
        argv[arg_index] = request_json;
        arg_index += 1;
    }
    @memcpy(argv[arg_index..], targets);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
        .expand_arg0 = .expand,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0 or result.stdout.len > 0) return result.stdout;
            if (result.stderr.len > 0) try io_helpers.writeAll(2, result.stderr);
            return error.RemoteKillFailed;
        },
        else => return error.RemoteKillFailed,
    }
}

pub fn runRemoteKillJsonlAndProcess(
    allocator: std.mem.Allocator,
    exe: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    targets: []const []const u8,
    expected_guid: ?[]const u8,
) !bool {
    const stdout = try queryRemoteHostKillJsonl(allocator, exe, host, ssh_options, targets);
    defer allocator.free(stdout);
    return processKillJsonl(allocator, host, stdout, expected_guid);
}

pub fn spawnRemoteKillJsonl(
    allocator: std.mem.Allocator,
    exe: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    targets: []const []const u8,
) void {
    const ssh_options_arg = if (ssh_options.len > 0) shell.joinArgs(allocator, ssh_options) catch return else null;
    defer if (ssh_options_arg) |value| allocator.free(value);
    const ssh_option_args: usize = if (ssh_options_arg != null) 2 else 0;
    const argv = allocator.alloc([]const u8, 2 + ssh_option_args + 1 + 1 + targets.len) catch return;
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = "kill";
    var arg_index: usize = 2;
    if (ssh_options_arg) |value| {
        argv[arg_index] = "--ssh-options";
        arg_index += 1;
        argv[arg_index] = value;
        arg_index += 1;
    }
    argv[arg_index] = host;
    arg_index += 1;
    argv[arg_index] = "--jsonl";
    arg_index += 1;
    @memcpy(argv[arg_index..], targets);

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
}

pub fn runLocalKillJsonlAndProcess(
    allocator: std.mem.Allocator,
    targets: []const []const u8,
    expected_guid: ?[]const u8,
) !bool {
    const results = try runtime_commands.killTargetsForJsonl(allocator, targets);
    defer allocator.free(results);
    return processKillResults(allocator, ".", results, expected_guid);
}

pub fn requestLocalKillNoWait(allocator: std.mem.Allocator, targets: []const []const u8) void {
    runtime_commands.requestKillTargetsNoWait(allocator, targets);
}

fn processRemoteKillJsonl(allocator: std.mem.Allocator, host: []const u8, stdout: []const u8) !void {
    _ = try processKillJsonl(allocator, host, stdout, null);
}

fn processKillJsonlForPendingDrain(
    allocator: std.mem.Allocator,
    host: []const u8,
    stdout: []const u8,
    pending: *const session_registry.PendingKills,
    handled: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const guid = jsonStringField(object, "guid") orelse continue;
        const status = jsonStringField(object, "status") orelse continue;
        const entry = pendingKillEntryForGuid(pending, guid) orelse continue;
        if (std.mem.eql(u8, status, "killed") or std.mem.eql(u8, status, "missing")) {
            try handled.append(allocator, entry.guid);
            if (session_registry.isValidSessionGuid(entry.guid)) {
                tombstoneLocalRouteForPendingKill(allocator, entry.guid, .{
                    .ended_at_unix_ms = (try jsonU64Field(object, "ended_at_unix_ms")) orelse pendingKillFallbackEndedAt(entry),
                    .end_reason = .killed_by_request,
                }) catch |err| {
                    client_log.debug("event=pending_kill_tombstone_failed host={s} session={s} error={t}", .{ host, entry.guid, err });
                };
            }
        } else if (std.mem.eql(u8, status, "skipped")) {
            try handled.append(allocator, entry.guid);
        } else if (std.mem.eql(u8, status, "failure")) {
            const reason = jsonStringField(object, "reason") orelse "unknown";
            client_log.userDiagnosticInfo("pending kill failed for {s}: {s}", .{ guid, reason });
        }
    }
}

fn tombstoneLocalRouteForPendingKill(allocator: std.mem.Allocator, guid: []const u8, details: session_registry.TombstoneDetails) !void {
    var route = session_registry.readRouteForRef(allocator, guid) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer route.deinit(allocator);
    try session_registry.writeTombstoneForRoute(allocator, &route, details);
}

fn pendingKillEntryForGuid(pending: *const session_registry.PendingKills, guid: []const u8) ?*const session_registry.PendingKillEntry {
    for (pending.entries) |*entry| {
        if (std.mem.eql(u8, entry.type_name, "kill") and std.mem.eql(u8, entry.guid, guid)) return entry;
    }
    return null;
}

fn pendingKillFallbackEndedAt(entry: *const session_registry.PendingKillEntry) u64 {
    return if (entry.requested_at_unix_ms == 0) nowUnixMs() else entry.requested_at_unix_ms;
}

fn processKillJsonl(allocator: std.mem.Allocator, host: []const u8, stdout: []const u8, expected_guid: ?[]const u8) !bool {
    var expected_seen = expected_guid == null;
    var expected_succeeded = expected_guid == null;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const guid = jsonStringField(object, "guid") orelse continue;
        const status = jsonStringField(object, "status") orelse continue;
        const matches_expected = if (expected_guid) |expected| std.mem.eql(u8, expected, guid) else false;
        if (matches_expected) expected_seen = true;
        if (std.mem.eql(u8, status, "killed") or std.mem.eql(u8, status, "missing")) {
            if (matches_expected) expected_succeeded = true;
            if (session_registry.isValidSessionGuid(guid)) {
                tombstoneLocalRouteForPendingKill(allocator, guid, .{
                    .ended_at_unix_ms = (try jsonU64Field(object, "ended_at_unix_ms")) orelse nowUnixMs(),
                    .end_reason = .killed_by_request,
                }) catch |err| {
                    client_log.debug("event=pending_kill_tombstone_failed host={s} session={s} error={t}", .{ host, guid, err });
                };
            }
            try removePendingKillForResult(allocator, guid);
        } else if (std.mem.eql(u8, status, "skipped")) {
            if (matches_expected) expected_succeeded = true;
            try removePendingKillForResult(allocator, guid);
        } else if (std.mem.eql(u8, status, "failure")) {
            const reason = jsonStringField(object, "reason") orelse "unknown";
            client_log.userDiagnosticInfo("pending kill failed for {s}: {s}", .{ guid, reason });
        }
    }
    return expected_seen and expected_succeeded;
}

fn processKillResults(
    allocator: std.mem.Allocator,
    host: []const u8,
    results: []const runtime_commands.KillResult,
    expected_guid: ?[]const u8,
) !bool {
    var expected_seen = expected_guid == null;
    var expected_succeeded = expected_guid == null;
    for (results) |result| {
        const matches_expected = if (expected_guid) |expected| std.mem.eql(u8, expected, result.guid) else false;
        if (matches_expected) expected_seen = true;
        switch (result.status) {
            .killed, .missing => {
                if (matches_expected) expected_succeeded = true;
                if (session_registry.isValidSessionGuid(result.guid)) {
                    tombstoneLocalRouteForPendingKill(allocator, result.guid, .{
                        .ended_at_unix_ms = result.ended_at_unix_ms orelse nowUnixMs(),
                        .end_reason = .killed_by_request,
                    }) catch |err| {
                        client_log.debug("event=pending_kill_tombstone_failed host={s} session={s} error={t}", .{ host, result.guid, err });
                    };
                }
                try removePendingKillForResult(allocator, result.guid);
            },
            .skipped => {
                if (matches_expected) expected_succeeded = true;
                try removePendingKillForResult(allocator, result.guid);
            },
            .failure => {
                const reason = if (result.reason.len == 0) "unknown" else result.reason;
                client_log.userDiagnosticInfo("pending kill failed for {s}: {s}", .{ result.guid, reason });
            },
        }
    }
    return expected_seen and expected_succeeded;
}

fn removePendingKillForResult(allocator: std.mem.Allocator, guid: []const u8) !void {
    var route = session_registry.readRouteForRef(allocator, guid) catch null;
    defer if (route) |*value| value.deinit(allocator);
    const pending_host_guid = if (route) |*value| value.host_guid else return;
    if (pending_host_guid.len == 0) return;
    try session_registry.removePendingKill(allocator, pending_host_guid, guid);
}

const RemoteListStatus = struct {
    version: []u8,
    attached_count: ?u32,
    last_input_at_unix_ms: ?u64,
};

fn remoteListStatusForGuid(allocator: std.mem.Allocator, stdout: []const u8, guid: []const u8) !?RemoteListStatus {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const row_guid = jsonStringField(object, "guid") orelse continue;
        if (!std.mem.eql(u8, row_guid, guid)) continue;
        const version = jsonStringField(object, "version") orelse "";
        const attached_count = if (try jsonU64Field(object, "attached_count")) |count| blk: {
            if (count > std.math.maxInt(u32)) break :blk null;
            break :blk @as(?u32, @intCast(count));
        } else null;
        return .{
            .version = try allocator.dupe(u8, version),
            .attached_count = attached_count,
            .last_input_at_unix_ms = try jsonU64Field(object, "last_input_at_unix_ms"),
        };
    }
    return null;
}

fn remoteTombstoneForGuid(allocator: std.mem.Allocator, stdout: []const u8, guid: []const u8) !?session_registry.TombstoneDetails {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        const row_guid = jsonStringField(object, "guid") orelse continue;
        if (!std.mem.eql(u8, row_guid, guid)) continue;
        const ended_at_unix_ms = (try jsonU64Field(object, "ended_at_unix_ms")) orelse return null;
        const end_reason = session_registry.tombstoneEndReasonFromName(jsonStringField(object, "end_reason") orelse "unknown") catch .unknown;
        return .{
            .ended_at_unix_ms = ended_at_unix_ms,
            .end_reason = end_reason,
            .exit_status = try jsonTombstoneExitStatusField(object, "exit_status"),
        };
    }
    return null;
}

fn remoteListVersionForGuid(allocator: std.mem.Allocator, stdout: []const u8, guid: []const u8) !?[]u8 {
    const status = try remoteListStatusForGuid(allocator, stdout, guid);
    if (status) |value| return value.version;
    return null;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonU64Field(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidJson;
            break :blk @intCast(integer);
        },
        else => null,
    };
}

fn jsonI32Field(object: std.json.ObjectMap, key: []const u8) !?i32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32)) return error.InvalidJson;
            break :blk @as(i32, @intCast(integer));
        },
        else => null,
    };
}

fn jsonTombstoneExitStatusField(object: std.json.ObjectMap, key: []const u8) !?session_registry.TombstoneExitStatus {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .object => |status_object| blk: {
            const kind_name = jsonStringField(status_object, "kind") orelse return error.InvalidJson;
            const status = (try jsonI32Field(status_object, "status")) orelse return error.InvalidJson;
            break :blk .{
                .kind = try session_registry.tombstoneExitStatusKindFromName(kind_name),
                .status = status,
            };
        },
        else => null,
    };
}

test "remoteListVersionForGuid reads jsonl rows" {
    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    const stdout =
        \\{"id":"s-550e8400","host":"example.com","version":"0.5.0-dev","guid":"s-550e8400-e29b-41d4-a716-446655440000","attached_count":2,"last_input_at_unix_ms":1234}
        \\s-550e8400  2         0s ago    example.com                 0.5.0-dev
        \\
    ;

    const version = (try remoteListVersionForGuid(std.testing.allocator, stdout, guid)) orelse return error.MissingVersion;
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("0.5.0-dev", version);
    const status = (try remoteListStatusForGuid(std.testing.allocator, stdout, guid)) orelse return error.MissingStatus;
    defer std.testing.allocator.free(status.version);
    try std.testing.expectEqual(@as(?u32, 2), status.attached_count);
    try std.testing.expectEqual(@as(?u64, 1234), status.last_input_at_unix_ms);
    try std.testing.expect(try remoteListVersionForGuid(std.testing.allocator, stdout, "s-00000000-0000-4000-8000-000000000000") == null);
}

test "remoteTombstoneForGuid reads exited jsonl rows" {
    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    const stdout =
        \\{"id":"s-550e8400","host":"example.com","version":"0.5.0-dev","guid":"s-550e8400-e29b-41d4-a716-446655440000","ended_at_unix_ms":1234,"end_reason":"process_exited","exit_status":{"kind":"exited","status":7}}
        \\
    ;

    const tombstone = (try remoteTombstoneForGuid(std.testing.allocator, stdout, guid)) orelse return error.MissingTombstone;
    try std.testing.expectEqual(@as(u64, 1234), tombstone.ended_at_unix_ms);
    try std.testing.expectEqual(session_registry.TombstoneEndReason.process_exited, tombstone.end_reason);
    try std.testing.expectEqual(session_registry.TombstoneExitStatusKind.exited, tombstone.exit_status.?.kind);
    try std.testing.expectEqual(@as(i32, 7), tombstone.exit_status.?.status);
    try std.testing.expect(try remoteTombstoneForGuid(std.testing.allocator, stdout, "s-00000000-0000-4000-8000-000000000000") == null);
}
