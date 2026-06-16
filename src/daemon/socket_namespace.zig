const std = @import("std");

const config = @import("../core/config.zig");
const socket_transport = @import("../transport/socket.zig");

pub const daemon_executable_name = "sesshd";
pub const broker_executable_name = "sessh-broker";
pub const proxy_executable_name = "sessh-proxy";
pub const terminal_remote_executable_name = "sessh-terminal-remote";
pub const proxy_remote_executable_name = "sessh-proxy-remote";
pub const socket_filename = "sesshd.sock";
pub const lock_filename = "sesshd.lock";
pub const namespace_env = "SESSH_DAEMON_NAMESPACE";

pub fn selectedDirName(allocator: std.mem.Allocator) ![]u8 {
    if (try envDirName(allocator)) |dir_name| return dir_name;
    return defaultDirName(allocator);
}

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

fn envDirName(allocator: std.mem.Allocator) !?[]u8 {
    const value = std.process.getEnvVarOwned(allocator, namespace_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(value);
    try validateDirName(value);
    return value;
}

pub fn socketPath(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    const dir = try dirPath(allocator, dir_name);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, socket_filename });
}

pub fn dirPath(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    try validateDirName(dir_name);
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, dir_name });
}

pub fn executablePath(allocator: std.mem.Allocator, dir_name: []const u8, name: []const u8) ![]u8 {
    try validateExecutableName(name);
    const dir = try dirPath(allocator, dir_name);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

pub fn lockPath(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    const dir = try dirPath(allocator, dir_name);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, lock_filename });
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

fn validateExecutableName(name: []const u8) !void {
    if (std.mem.eql(u8, name, daemon_executable_name) or
        std.mem.eql(u8, name, broker_executable_name) or
        std.mem.eql(u8, name, proxy_executable_name) or
        std.mem.eql(u8, name, terminal_remote_executable_name) or
        std.mem.eql(u8, name, proxy_remote_executable_name))
    {
        return;
    }
    return error.InvalidDaemonExecutableName;
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
