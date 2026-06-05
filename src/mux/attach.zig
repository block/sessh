const std = @import("std");

const mux_cli = @import("cli.zig");
const mux_common = @import("common.zig");
const session_registry = @import("../runtime/session_registry.zig");
const ssh_client = @import("../transport/ssh.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.Attach {
    var parsed = mux_cli.CommandParts{};
    defer parsed.deinit(scratch.allocator);
    try mux_cli.parseSharedParts(scratch, args, &parsed, .attach);
    const id = try mux_cli.singleOptionalId(parsed.ids.items, parsed.positionals.items);
    if (parsed.host) |host| {
        return .{
            .target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host },
            .id = id,
            .ssh_options = try scratch.ownSshOptions(&parsed.ssh_options),
            .common = parsed.common,
        };
    }
    if (parsed.ssh_options.items.len > 0) return error.MissingHost;
    if (parsed.ids.items.len > 1 or parsed.positionals.items.len > 1) return error.TooManyMuxArguments;
    return switch (if (id == null) @as(usize, 0) else @as(usize, 1)) {
        0 => .{ .target = .latest, .common = parsed.common },
        1 => .{ .target = .{ .route_ref = id.? }, .common = parsed.common },
        else => unreachable,
    };
}

pub fn appendRemoteArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), attach: mux_cli.Attach) !void {
    try out.append(allocator, "attach");
    try out.append(allocator, "--host");
    try out.append(allocator, ".");
    if (attach.id) |id| {
        try out.append(allocator, "--id");
        try out.append(allocator, id);
    } else switch (attach.target) {
        .route_ref => |id| {
            try out.append(allocator, "--id");
            try out.append(allocator, id);
        },
        .latest, .local, .host => {},
    }
    try mux_cli.appendRemoteCommonArgs(allocator, out, attach.common);
}

pub fn toInvocation(
    allocator: std.mem.Allocator,
    attach: mux_cli.Attach,
    route_storage: *?session_registry.Route,
) !ssh_client.SessionInvocation {
    var parsed = try mux_common.baseInvocation(attach.ssh_options, .attach, attach.common);
    switch (attach.target) {
        .latest => {
            route_storage.* = (try session_registry.readLatestDetachedRouteNotAttachedByThisMachine(allocator)) orelse return parsed;
            mux_common.fillFromRoute(.attach, &parsed, route_storage.*.?);
            parsed.attach_id_from_latest_route = true;
        },
        .local => {
            parsed.host = ".";
            parsed.attach_id = attach.id;
        },
        .host => |host| {
            parsed.host = host;
            parsed.attach_id = attach.id;
        },
        .route_ref => |ref| {
            try mux_common.readRouteForRef(allocator, route_storage, ref);
            mux_common.fillFromRoute(.attach, &parsed, route_storage.*.?);
        },
    }
    return parsed;
}

test "parse keeps target inside attach command" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const attach = try parse(&scratch, &.{ "--host", ".", "s1" });

    try std.testing.expectEqual(mux_cli.AttachTarget.local, attach.target);
    try std.testing.expectEqualStrings("s1", attach.id.?);
}

test "parse accepts explicit id option" {
    var scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const attach = try parse(&scratch, &.{ "--host", "test-host", "--id", "s1" });

    switch (attach.target) {
        .host => |host| try std.testing.expectEqualStrings("test-host", host),
        else => return error.TestUnexpectedTarget,
    }
    try std.testing.expectEqualStrings("s1", attach.id.?);
}
