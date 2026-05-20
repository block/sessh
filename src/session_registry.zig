const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const socket_transport = @import("socket_transport.zig");

pub const SessionPaths = struct {
    dir: []u8,
    socket: []u8,
    meta: []u8,
    detached: []u8,
    compat: []u8,

    pub fn deinit(self: *SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.compat);
        allocator.free(self.detached);
        allocator.free(self.meta);
        allocator.free(self.socket);
        allocator.free(self.dir);
        self.* = undefined;
    }
};

pub const Allocation = struct {
    id: []u8,
    paths: SessionPaths,

    pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub fn allocateSessionDir(allocator: std.mem.Allocator) !Allocation {
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return allocateSessionDirInRoot(allocator, root);
}

pub fn allocateSessionDirInRoot(allocator: std.mem.Allocator, root: []const u8) !Allocation {
    try ensureRegistryRoot(allocator, root);

    const sessions_dir = try sessionsDirInRoot(allocator, root);
    defer allocator.free(sessions_dir);
    try mkdirIgnoreExists(allocator, sessions_dir);

    var next_id: u64 = 1;
    while (true) : (next_id += 1) {
        const id = try std.fmt.allocPrint(allocator, "s{}", .{next_id});
        errdefer allocator.free(id);

        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, id });
        errdefer allocator.free(dir);
        switch (try mkdirSessionDir(allocator, dir)) {
            .created => {
                var paths = try pathsForSessionDir(allocator, dir);
                errdefer paths.deinit(allocator);
                allocator.free(dir);
                return .{ .id = id, .paths = paths };
            },
            .exists => {
                allocator.free(dir);
                allocator.free(id);
                continue;
            },
        }
    }
}

pub fn sessionsDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return sessionsDirInRoot(allocator, root);
}

pub fn sessionsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/s", .{root});
}

pub fn pathsForSessionId(allocator: std.mem.Allocator, id: []const u8) !SessionPaths {
    if (!isValidSessionId(id)) return error.InvalidSessionId;
    const sessions_dir = try sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, id });
    defer allocator.free(dir);
    return pathsForSessionDir(allocator, dir);
}

pub fn pathsForSessionDir(allocator: std.mem.Allocator, dir: []const u8) !SessionPaths {
    const dir_copy = try allocator.dupe(u8, dir);
    errdefer allocator.free(dir_copy);

    const socket = try std.fmt.allocPrint(allocator, "{s}/s", .{dir});
    errdefer allocator.free(socket);

    const meta = try std.fmt.allocPrint(allocator, "{s}/meta", .{dir});
    errdefer allocator.free(meta);

    const detached = try std.fmt.allocPrint(allocator, "{s}/detached", .{dir});
    errdefer allocator.free(detached);

    const compat = try std.fmt.allocPrint(allocator, "{s}/compat", .{dir});
    errdefer allocator.free(compat);

    return .{
        .dir = dir_copy,
        .socket = socket,
        .meta = meta,
        .detached = detached,
        .compat = compat,
    };
}

pub fn isValidSessionId(id: []const u8) bool {
    if (id.len < 2 or id[0] != 's') return false;
    for (id[1..]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

pub fn writeMeta(paths: SessionPaths, pid: c.pid_t, version: []const u8) !void {
    const file = try std.fs.cwd().createFile(paths.meta, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "pid={}\nversion={s}\n", .{ pid, version });
    try file.writeAll(text);
}

pub fn markDetached(paths: SessionPaths) !void {
    const file = try std.fs.cwd().createFile(paths.detached, .{ .truncate = true, .mode = 0o600 });
    file.close();
}

pub fn markAttached(paths: SessionPaths) !void {
    try unlinkIfExists(paths.detached);
}

/// Remove stale discovery hints after the caller has already decided the
/// socket is stale. Keep the session directory as the id tombstone.
pub fn removeStaleHints(paths: SessionPaths) !void {
    try unlinkIfExists(paths.socket);
    try unlinkIfExists(paths.compat);
}

/// Clean shutdown removes live discovery hints while preserving the session
/// directory as the id tombstone.
pub fn removeEndedHints(paths: SessionPaths) !void {
    try unlinkIfExists(paths.socket);
    try unlinkIfExists(paths.compat);
    try unlinkIfExists(paths.detached);
}

const MkdirSessionResult = enum { created, exists };

fn ensureRegistryRoot(allocator: std.mem.Allocator, root: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, root, '/')) |slash| {
        if (slash > 0) try std.fs.cwd().makePath(root[0..slash]);
    }
    try mkdirIgnoreExists(allocator, root);
}

fn mkdirIgnoreExists(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    switch (posix.errno(c.mkdir(path_z.ptr, 0o700))) {
        .SUCCESS, .EXIST => return,
        else => return error.MkdirFailed,
    }
}

fn mkdirSessionDir(allocator: std.mem.Allocator, path: []const u8) !MkdirSessionResult {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return switch (posix.errno(c.mkdir(path_z.ptr, 0o700))) {
        .SUCCESS => .created,
        .EXIST => .exists,
        else => error.MkdirFailed,
    };
}

fn unlinkIfExists(path: []const u8) !void {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);
    switch (posix.errno(c.unlink(path_z.ptr))) {
        .SUCCESS, .NOENT => return,
        else => return error.UnlinkFailed,
    }
}

test "allocates session directories without reusing tombstones" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(
        allocator,
        "zig-cache/session-registry-test-{}",
        .{c.getpid()},
    );
    defer allocator.free(root);

    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var first = try allocateSessionDirInRoot(allocator, root);
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("s1", first.id);

    var second = try allocateSessionDirInRoot(allocator, root);
    defer second.deinit(allocator);
    try std.testing.expectEqualStrings("s2", second.id);

    // Leaving s1/s2 in place reserves those ids, even after the agent exits.
    var third = try allocateSessionDirInRoot(allocator, root);
    defer third.deinit(allocator);
    try std.testing.expectEqualStrings("s3", third.id);
}

test "session paths use short socket components and registry side files" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try allocateSessionDirInRoot(allocator, root);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/s1", allocation.paths.dir);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/s1/s", allocation.paths.socket);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/s1/meta", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/s1/detached", allocation.paths.detached);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/s1/compat", allocation.paths.compat);
}

test "validates session ids" {
    try std.testing.expect(isValidSessionId("s1"));
    try std.testing.expect(isValidSessionId("s12345"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("1"));
    try std.testing.expect(!isValidSessionId("s"));
    try std.testing.expect(!isValidSessionId("s1/compat"));
    try std.testing.expect(!isValidSessionId("sx"));
}

test "registry writes meta and tracks detached marker" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-state-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try allocateSessionDirInRoot(allocator, root);
    defer allocation.deinit(allocator);

    try writeMeta(allocation.paths, 12345, "0.4.0-dev");
    const meta = try std.fs.cwd().readFileAlloc(allocator, allocation.paths.meta, 1024);
    defer allocator.free(meta);
    try std.testing.expectEqualStrings("pid=12345\nversion=0.4.0-dev\n", meta);

    try markDetached(allocation.paths);
    _ = try std.fs.cwd().statFile(allocation.paths.detached);
    try markAttached(allocation.paths);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.detached));
}

test "stale hint cleanup leaves session tombstone" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-stale-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try allocateSessionDirInRoot(allocator, root);
    defer allocation.deinit(allocator);

    var socket_file = try std.fs.cwd().createFile(allocation.paths.socket, .{});
    socket_file.close();
    var compat_file = try std.fs.cwd().createFile(allocation.paths.compat, .{});
    compat_file.close();

    try removeStaleHints(allocation.paths);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.socket));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.compat));
    _ = try std.fs.cwd().statFile(allocation.paths.dir);
}

test "ended hint cleanup removes detached marker and leaves tombstone" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-ended-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try allocateSessionDirInRoot(allocator, root);
    defer allocation.deinit(allocator);

    var socket_file = try std.fs.cwd().createFile(allocation.paths.socket, .{});
    socket_file.close();
    var compat_file = try std.fs.cwd().createFile(allocation.paths.compat, .{});
    compat_file.close();
    try markDetached(allocation.paths);

    try removeEndedHints(allocation.paths);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.socket));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.compat));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.detached));
    _ = try std.fs.cwd().statFile(allocation.paths.dir);
}
