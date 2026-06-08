const std = @import("std");

const config = @import("../core/config.zig");
const socket_transport = @import("../transport/socket.zig");

pub fn defaultDirName(allocator: std.mem.Allocator) ![]u8 {
    const base = try std.fmt.allocPrint(allocator, "{d}", .{config.protocol_major});
    errdefer allocator.free(base);

    if (!std.mem.endsWith(u8, config.version, "-dev")) return base;
    const hash = devBuildHash() catch fallback_hash: {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(config.version, &digest, .{});
        break :fallback_hash Hash{ .hex = std.fmt.bytesToHex(digest, .lower) };
    };

    const value = try std.fmt.allocPrint(allocator, "{s}.dev.{s}", .{ base, hash.hex[0..8] });
    allocator.free(base);
    return value;
}

pub fn socketPath(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    try validateDirName(dir_name);
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}/sesshd.sock", .{ root, dir_name });
}

pub fn validateDirName(dir_name: []const u8) !void {
    if (dir_name.len == 0 or dir_name.len > 64) return error.InvalidDaemonSocketDir;
    for (dir_name) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
            else => return error.InvalidDaemonSocketDir,
        }
    }
}

const Hash = struct {
    hex: [64]u8,
};

fn devBuildHash() !Hash {
    const allocator = std.heap.page_allocator;
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    return hashFile(exe_path);
}

fn hashFile(path: []const u8) !Hash {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.heap.page_allocator, 64 * 1024 * 1024);
    defer std.heap.page_allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return .{ .hex = std.fmt.bytesToHex(digest, .lower) };
}

test "daemon socket namespace uses protocol major" {
    const allocator = std.testing.allocator;
    const dir_name = try defaultDirName(allocator);
    defer allocator.free(dir_name);

    const expected_prefix = try std.fmt.allocPrint(allocator, "{d}", .{config.protocol_major});
    defer allocator.free(expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, dir_name, expected_prefix));
    if (std.mem.endsWith(u8, config.version, "-dev")) {
        try std.testing.expect(std.mem.startsWith(u8, dir_name[expected_prefix.len..], ".dev."));
    } else {
        try std.testing.expectEqualStrings(expected_prefix, dir_name);
    }
}

test "daemon socket path is protocol scoped" {
    const allocator = std.testing.allocator;
    const dir_name = try std.fmt.allocPrint(allocator, "{d}.dev.abcdef12", .{config.protocol_major});
    defer allocator.free(dir_name);
    const path = try socketPath(allocator, dir_name);
    defer allocator.free(path);
    const suffix = try std.fmt.allocPrint(allocator, "/{s}/sesshd.sock", .{dir_name});
    defer allocator.free(suffix);
    try std.testing.expect(std.mem.endsWith(u8, path, suffix));
}
