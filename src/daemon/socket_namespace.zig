const std = @import("std");

const config = @import("../core/config.zig");
const socket_transport = @import("../transport/socket.zig");

pub fn defaultDirName(allocator: std.mem.Allocator) ![]u8 {
    const base = try versionMajor(allocator, config.version);
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

fn versionMajor(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const core = if (std.mem.endsWith(u8, version, "-dev")) version[0 .. version.len - "-dev".len] else version;
    var parts = std.mem.splitScalar(u8, core, '.');
    const major = parts.next() orelse return error.InvalidVersion;
    if (major.len == 0) return error.InvalidVersion;
    try validateNumeric(major);
    return allocator.dupe(u8, major);
}

fn validateNumeric(value: []const u8) !void {
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidVersion;
    }
}

test "version namespace uses major only" {
    const allocator = std.testing.allocator;
    const release = try versionMajor(allocator, "1.2.3");
    defer allocator.free(release);
    try std.testing.expectEqualStrings("1", release);

    const dev = try versionMajor(allocator, "1.2.3-dev");
    defer allocator.free(dev);
    try std.testing.expectEqualStrings("1", dev);
}

test "daemon socket path is version scoped" {
    const allocator = std.testing.allocator;
    const path = try socketPath(allocator, "1.dev.abcdef12");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/1.dev.abcdef12/sesshd.sock"));
}
