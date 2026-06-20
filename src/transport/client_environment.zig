const std = @import("std");

const protocol = @import("../protocol/mod.zig");
const send_env_filter = @import("send_env.zig");

const pb = protocol.pb;

pub const OwnedEntry = struct {
    name: []u8,
    value: []u8,
};

pub const List = std.ArrayList(OwnedEntry);

pub fn clone(allocator: std.mem.Allocator, entries: []const pb.EnvironmentEntry) !List {
    var result = List.empty;
    errdefer deinit(allocator, &result);
    for (entries) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(value);
        try result.append(allocator, .{
            .name = name,
            .value = value,
        });
    }
    return result;
}

pub fn deinit(allocator: std.mem.Allocator, entries: *List) void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    entries.deinit(allocator);
}

pub fn appendFilteredToTerminalCreate(
    allocator: std.mem.Allocator,
    entries: []const OwnedEntry,
    send_env: []const []const u8,
    create: *pb.TerminalEmulatorItem.SessionCreate,
) !void {
    // Apply OpenSSH SendEnv-style filtering to the captured visible-client
    // environment before it becomes terminal-worker state. Existing explicit
    // entries win over forwarded environment variables.
    for (entries) |entry| {
        // SessionCreate uses SHELL as the remote terminal worker's login shell
        // convention. OpenSSH SendEnv must not let the visible client's SHELL
        // choose the requested remote shell.
        if (std.mem.eql(u8, entry.name, "SHELL")) continue;
        if (!send_env_filter.allowsName(send_env, entry.name)) continue;
        if (terminalCreateHasEnvironmentName(create, entry.name)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(value);
        try create.environment.append(allocator, .{
            .name = name,
            .value = value,
        });
    }
}

fn terminalCreateHasEnvironmentName(
    create: *const pb.TerminalEmulatorItem.SessionCreate,
    name: []const u8,
) bool {
    for (create.environment.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "clone owns entry names and values" {
    const allocator = std.testing.allocator;
    var source = std.ArrayList(pb.EnvironmentEntry).empty;
    defer source.deinit(allocator);
    try source.append(allocator, .{ .name = "SESSH_ENV", .value = "value" });

    var entries = try clone(allocator, source.items);
    defer deinit(allocator, &entries);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("SESSH_ENV", entries.items[0].name);
    try std.testing.expectEqualStrings("value", entries.items[0].value);
    try std.testing.expect(entries.items[0].name.ptr != source.items[0].name.ptr);
    try std.testing.expect(entries.items[0].value.ptr != source.items[0].value.ptr);
}

test "appendFilteredToTerminalCreate applies SendEnv and preserves create-owned values" {
    const allocator = std.testing.allocator;
    var source = std.ArrayList(pb.EnvironmentEntry).empty;
    defer source.deinit(allocator);
    try source.append(allocator, .{ .name = "LANG", .value = "en_US.UTF-8" });
    try source.append(allocator, .{ .name = "SHELL", .value = "/bin/zsh" });
    try source.append(allocator, .{ .name = "BLOCKED", .value = "no" });
    try source.append(allocator, .{ .name = "EXISTING", .value = "client" });

    var entries = try clone(allocator, source.items);
    defer deinit(allocator, &entries);

    var create = pb.TerminalEmulatorItem.SessionCreate{};
    defer {
        for (create.environment.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        create.environment.deinit(allocator);
    }
    try create.environment.append(allocator, .{
        .name = try allocator.dupe(u8, "EXISTING"),
        .value = try allocator.dupe(u8, "remote"),
    });

    try appendFilteredToTerminalCreate(allocator, entries.items, &.{ "LANG", "SHELL", "EXISTING" }, &create);

    try std.testing.expectEqual(@as(usize, 2), create.environment.items.len);
    try std.testing.expectEqualStrings("EXISTING", create.environment.items[0].name);
    try std.testing.expectEqualStrings("remote", create.environment.items[0].value);
    try std.testing.expectEqualStrings("LANG", create.environment.items[1].name);
    try std.testing.expectEqualStrings("en_US.UTF-8", create.environment.items[1].value);
    try std.testing.expect(create.environment.items[1].name.ptr != entries.items[0].name.ptr);
    try std.testing.expect(create.environment.items[1].value.ptr != entries.items[0].value.ptr);
}
