const std = @import("std");

const mux_cli = @import("mux_cli.zig");
const mux_common = @import("mux_common.zig");
const session_registry = @import("session_registry.zig");
const ssh_client = @import("ssh_client.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.Kill {
    var parsed = mux_cli.CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var kill = mux_cli.Kill{};
    var request_jsons: std.ArrayList([]const u8) = .empty;
    errdefer request_jsons.deinit(scratch.allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            if (kill.current or kill.ids.len > 0 or parsed.ids.items.len > 0 or request_jsons.items.len > 0) return error.MultipleTargets;
            kill.all = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--current")) {
            if (kill.all or kill.ids.len > 0 or parsed.ids.items.len > 0 or request_jsons.items.len > 0) return error.MultipleTargets;
            kill.current = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            kill.jsonl = true;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--request=")) {
            if (kill.all or kill.current or kill.ids.len > 0 or parsed.ids.items.len > 0) return error.MultipleTargets;
            try request_jsons.append(scratch.allocator, arg["--request=".len..]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--request")) {
            if (kill.all or kill.current or kill.ids.len > 0 or parsed.ids.items.len > 0) return error.MultipleTargets;
            i += 1;
            if (i >= args.len) return error.MissingKillTarget;
            try request_jsons.append(scratch.allocator, args[i]);
            i += 1;
        } else if (try mux_cli.parseSharedOption(scratch, args, &i, &parsed, .kill)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else {
            const start = i;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "-")) i += 1;
            kill.ids = args[start..i];
        }
    }

    if (request_jsons.items.len > 0) {
        kill.owned_request_jsons = try request_jsons.toOwnedSlice(scratch.allocator);
        kill.request_jsons = kill.owned_request_jsons.?;
    } else {
        request_jsons.deinit(scratch.allocator);
    }
    kill.common = parsed.common;

    if (parsed.host) |host| {
        kill.command_target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
        try mux_cli.setKillIds(scratch, &kill, parsed.ids.items, kill.ids);
        if (!kill.all and !kill.current and kill.request_jsons.len == 0 and kill.ids.len == 0) return error.MissingKillTarget;
        kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
        return kill;
    }
    if (kill.all or kill.current or kill.request_jsons.len > 0) {
        if (parsed.ids.items.len > 0) return error.MultipleTargets;
        if (kill.ids.len > 1) return error.TooManyMuxArguments;
        if (kill.ids.len == 1) {
            const target = kill.ids[0];
            kill.command_target = if (std.mem.eql(u8, target, ".")) .local else .{ .host = target };
            kill.ids = &.{};
        } else {
            if (parsed.ssh_options.items.len > 0) return error.MissingHost;
            kill.command_target = .local;
        }
        kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
        return kill;
    }
    if (parsed.ids.items.len > 0) {
        if (kill.ids.len == 0) {
            if (parsed.ssh_options.items.len > 0) return error.MissingHost;
            kill.command_target = .local;
            try mux_cli.setKillIds(scratch, &kill, parsed.ids.items, &.{});
        } else if (std.mem.eql(u8, kill.ids[0], ".")) {
            if (parsed.ssh_options.items.len > 0) return error.MissingHost;
            kill.command_target = .local;
            try mux_cli.setKillIds(scratch, &kill, parsed.ids.items, kill.ids[1..]);
        } else if (mux_cli.looksLikeKillTarget(kill.ids[0])) {
            if (parsed.ssh_options.items.len > 0) return error.MissingHost;
            kill.command_target = .local;
            try mux_cli.setKillIds(scratch, &kill, parsed.ids.items, kill.ids);
        } else {
            kill.command_target = .{ .host = kill.ids[0] };
            try mux_cli.setKillIds(scratch, &kill, parsed.ids.items, kill.ids[1..]);
        }
        if (kill.ids.len == 0) return error.MissingKillTarget;
        kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
        return kill;
    }
    if (kill.ids.len == 0) return error.MissingKillTarget;
    if (std.mem.eql(u8, kill.ids[0], ".")) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        if (kill.ids.len == 1) return error.MissingKillTarget;
        kill.command_target = .local;
        kill.ids = kill.ids[1..];
    } else if (kill.ids.len == 1) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        kill.command_target = .{ .route_ref_or_local_id = kill.ids[0] };
    } else if (mux_cli.looksLikeKillTarget(kill.ids[0])) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        kill.command_target = .local;
    } else {
        kill.command_target = .{ .host = kill.ids[0] };
        kill.ids = kill.ids[1..];
    }
    kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    return kill;
}

pub fn appendRemoteArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), kill: mux_cli.Kill) !void {
    try out.append(allocator, "kill");
    try out.append(allocator, "--host");
    try out.append(allocator, ".");
    for (kill.ids) |id| {
        try out.append(allocator, "--id");
        try out.append(allocator, id);
    }
    try mux_cli.appendRemoteCommonArgs(allocator, out, kill.common);
    if (kill.jsonl) try out.append(allocator, "--jsonl");
    if (kill.all) try out.append(allocator, "--all");
    if (kill.current) try out.append(allocator, "--current");
    for (kill.request_jsons) |request_json| {
        try out.append(allocator, "--request");
        try out.append(allocator, request_json);
    }
}

pub fn toInvocation(
    allocator: std.mem.Allocator,
    kill: mux_cli.Kill,
    route_storage: *?session_registry.Route,
) !ssh_client.SessionInvocation {
    var parsed = try mux_common.baseInvocation(kill.ssh_options, if (kill.all) .kill_all else .kill, kill.common);
    parsed.kill_current = kill.current;
    parsed.kill_jsonl = kill.jsonl;
    parsed.kill_request_jsons = kill.request_jsons;
    switch (kill.command_target) {
        .local => {
            parsed.host = "";
            parsed.kill_ids = kill.ids;
            if (parsed.kill_ids.len > 0) parsed.kill_id = parsed.kill_ids[0];
        },
        .host => |host| {
            parsed.host = host;
            parsed.kill_ids = kill.ids;
            if (parsed.kill_ids.len > 0) parsed.kill_id = parsed.kill_ids[0];
        },
        .route_ref_or_local_id => |ref| {
            if (try mux_common.tryReadRouteForRef(allocator, route_storage, ref)) {
                mux_common.fillFromRoute(.kill, &parsed, route_storage.*.?);
            } else {
                parsed.host = "";
                parsed.kill_ids = &.{ref};
                parsed.kill_id = ref;
            }
        },
    }
    return parsed;
}

test "parse accepts ids as options" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();
    var kill = try parse(&scratch, &.{ "--id", "s1", "--id", "p1" });
    defer kill.deinit(std.testing.allocator);

    try std.testing.expectEqual(mux_cli.KillCommandTarget.local, kill.command_target);
    try std.testing.expectEqual(@as(usize, 2), kill.ids.len);
    try std.testing.expectEqualStrings("s1", kill.ids[0]);
    try std.testing.expectEqualStrings("p1", kill.ids[1]);
}

test "parse accepts command-local dot after subcommand" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();
    var kill = try parse(&scratch, &.{ ".", "s1", "p1" });
    defer kill.deinit(std.testing.allocator);

    try std.testing.expectEqual(mux_cli.KillCommandTarget.local, kill.command_target);
    try std.testing.expectEqual(@as(usize, 2), kill.ids.len);
    try std.testing.expectEqualStrings("s1", kill.ids[0]);
    try std.testing.expectEqualStrings("p1", kill.ids[1]);
}
