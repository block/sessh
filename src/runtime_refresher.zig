const std = @import("std");
const c = std.c;
const posix = std.posix;

const session_registry = @import("session_registry.zig");

pub const default_refresh_interval_ms: u64 = 60 * 60 * 1000;
const sticky_bit: c.mode_t = c.S.ISVTX;

pub const RuntimeRefresher = struct {
    paths: PathSet = .{},
    refresh_interval_ms: u64 = default_refresh_interval_ms,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    stop_requested: bool = false,
    repair_signal_fd: c.fd_t = -1,
    thread: ?std.Thread = null,

    pub fn start(self: *RuntimeRefresher, allocator: std.mem.Allocator, session_paths: session_registry.SessionPaths) !void {
        try self.startWithIntervalAndRepairSignal(allocator, session_paths, default_refresh_interval_ms, -1);
    }

    pub fn startWithRepairSignal(self: *RuntimeRefresher, allocator: std.mem.Allocator, session_paths: session_registry.SessionPaths, refresh_interval_ms: u64, repair_signal_fd: c.fd_t) !void {
        try self.startWithIntervalAndRepairSignal(allocator, session_paths, refresh_interval_ms, repair_signal_fd);
    }

    fn startWithInterval(self: *RuntimeRefresher, allocator: std.mem.Allocator, session_paths: session_registry.SessionPaths, refresh_interval_ms: u64) !void {
        try self.startWithIntervalAndRepairSignal(allocator, session_paths, refresh_interval_ms, -1);
    }

    fn startWithIntervalAndRepairSignal(self: *RuntimeRefresher, allocator: std.mem.Allocator, session_paths: session_registry.SessionPaths, refresh_interval_ms: u64, repair_signal_fd: c.fd_t) !void {
        if (refresh_interval_ms == 0) return error.InvalidRefreshInterval;
        self.* = .{
            .refresh_interval_ms = refresh_interval_ms,
            .repair_signal_fd = repair_signal_fd,
        };
        self.paths = try PathSet.init(allocator, session_paths);
        errdefer {
            self.paths.deinit(allocator);
            self.* = .{};
        }

        _ = refreshPathSet(&self.paths);
        self.thread = try std.Thread.spawn(.{}, refreshThreadMain, .{self});
    }

    pub fn stopAndJoin(self: *RuntimeRefresher, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| {
            self.mutex.lock();
            self.stop_requested = true;
            self.mutex.unlock();
            self.condition.signal();
            thread.join();
            self.thread = null;
        }
        self.paths.deinit(allocator);
        self.* = .{};
    }

    fn waitForNextRefresh(self: *RuntimeRefresher) bool {
        const timeout_ns = self.refresh_interval_ms * std.time.ns_per_ms;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stop_requested) {
            self.condition.timedWait(&self.mutex, timeout_ns) catch |err| switch (err) {
                error.Timeout => return !self.stop_requested,
            };
        }
        return false;
    }
};

fn refreshThreadMain(refresher: *RuntimeRefresher) void {
    while (refresher.waitForNextRefresh()) {
        const result = refreshPathSet(&refresher.paths);
        if (result.needs_agent_repair) signalAgentRepair(refresher.repair_signal_fd);
    }
}

const PathSet = struct {
    const max_paths = 9;

    paths: [max_paths][]u8 = undefined,
    len: usize = 0,
    session_paths: session_registry.SessionPaths = undefined,
    session_paths_initialized: bool = false,

    fn init(allocator: std.mem.Allocator, session_paths: session_registry.SessionPaths) !PathSet {
        var set = PathSet{};
        errdefer set.deinit(allocator);

        set.session_paths = try cloneSessionPaths(allocator, session_paths);
        set.session_paths_initialized = true;

        const runtime_root = try runtimeRootFromSessionDir(allocator, session_paths.dir);
        defer allocator.free(runtime_root);
        try set.add(allocator, runtime_root);

        const sessions_dir = try session_registry.sessionsDirInRoot(allocator, runtime_root);
        defer allocator.free(sessions_dir);
        try set.add(allocator, sessions_dir);

        const sockets_dir = try session_registry.sessionSocketsDirInRoot(allocator, runtime_root);
        defer allocator.free(sockets_dir);
        try set.add(allocator, sockets_dir);

        try set.add(allocator, session_paths.dir);
        try set.add(allocator, session_paths.socket);
        try set.add(allocator, session_paths.agent_sock_link);
        try set.add(allocator, session_paths.meta);
        try set.add(allocator, session_paths.detached);
        try set.add(allocator, session_paths.compat);

        return set;
    }

    fn deinit(self: *PathSet, allocator: std.mem.Allocator) void {
        for (self.paths[0..self.len]) |path| allocator.free(path);
        if (self.session_paths_initialized) self.session_paths.deinit(allocator);
        self.* = .{};
    }

    fn add(self: *PathSet, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.len >= max_paths) return error.TooManyRefreshPaths;
        self.paths[self.len] = try allocator.dupe(u8, path);
        self.len += 1;
    }
};

fn cloneSessionPaths(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !session_registry.SessionPaths {
    const dir = try allocator.dupe(u8, paths.dir);
    errdefer allocator.free(dir);
    const socket = try allocator.dupe(u8, paths.socket);
    errdefer allocator.free(socket);
    const agent_sock_link = try allocator.dupe(u8, paths.agent_sock_link);
    errdefer allocator.free(agent_sock_link);
    const meta = try allocator.dupe(u8, paths.meta);
    errdefer allocator.free(meta);
    const detached = try allocator.dupe(u8, paths.detached);
    errdefer allocator.free(detached);
    const compat = try allocator.dupe(u8, paths.compat);
    errdefer allocator.free(compat);
    const route = try allocator.dupe(u8, paths.route);
    errdefer allocator.free(route);
    return .{
        .dir = dir,
        .socket = socket,
        .agent_sock_link = agent_sock_link,
        .meta = meta,
        .detached = detached,
        .compat = compat,
        .route = route,
    };
}

fn runtimeRootFromSessionDir(allocator: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    const sessions_dir = std.fs.path.dirname(session_dir) orelse return error.InvalidSessionDir;
    const runtime_root = std.fs.path.dirname(sessions_dir) orelse return error.InvalidSessionDir;
    return allocator.dupe(u8, runtime_root);
}

const RefreshResult = struct {
    needs_agent_repair: bool = false,
};

fn refreshPathSet(paths: *const PathSet) RefreshResult {
    var result = RefreshResult{
        .needs_agent_repair = pathMissing(paths.session_paths.dir) or
            pathMissing(paths.session_paths.socket) or
            pathMissing(paths.session_paths.agent_sock_link) or
            pathMissing(paths.session_paths.meta) or
            pathMissing(paths.session_paths.compat),
    };

    session_registry.ensureRuntimeLayout(std.heap.page_allocator, paths.session_paths) catch {
        result.needs_agent_repair = true;
    };

    for (paths.paths[0..paths.len]) |path| refreshPath(path);
    return result;
}

fn refreshPath(path: []const u8) void {
    const info = statNoFollow(path) catch return;
    touchNoFollow(path) catch {};
    if (c.S.ISLNK(info.mode)) return;
    setStickyBitNoFollow(path, info.mode) catch {};
}

fn signalAgentRepair(fd: c.fd_t) void {
    if (fd < 0) return;
    var byte = [_]u8{1};
    _ = c.write(fd, &byte, byte.len);
}

fn pathMissing(path: []const u8) bool {
    _ = statNoFollow(path) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return false,
    };
    return false;
}

fn touchNoFollow(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    switch (posix.errno(c.utimensat(c.AT.FDCWD, path_z.ptr, null, @intCast(c.AT.SYMLINK_NOFOLLOW)))) {
        .SUCCESS => return,
        .NOENT, .NOTDIR => return error.FileNotFound,
        else => return error.RefreshFailed,
    }
}

fn setStickyBitNoFollow(path: []const u8, mode: u32) !void {
    if ((mode & sticky_bit) != 0) return;
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const new_mode: c.mode_t = @intCast((mode & 0o7777) | sticky_bit);
    switch (posix.errno(c.fchmodat(c.AT.FDCWD, path_z.ptr, new_mode, @intCast(c.AT.SYMLINK_NOFOLLOW)))) {
        .SUCCESS => return,
        .NOENT, .NOTDIR => return error.FileNotFound,
        .OPNOTSUPP, .PERM, .ACCES => return error.StickyBitUnsupported,
        else => return error.ChmodFailed,
    }
}

const PathInfo = struct {
    mode: u32,
};

fn statNoFollow(path: []const u8) !PathInfo {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    var stat: c.Stat = undefined;
    switch (posix.errno(c.fstatat(c.AT.FDCWD, path_z.ptr, &stat, c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => return .{ .mode = stat.mode },
        .NOENT, .NOTDIR => return error.FileNotFound,
        else => return error.PathStatFailed,
    }
}

test "refresh pass marks session runtime paths sticky without following symlinks" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "zig-cache/runtime-refresher-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try session_registry.allocateSessionDirForGuidInRoot(allocator, root, "s-550e8400-e29b-41d4-a716-446655440000");
    defer allocation.deinit(allocator);

    var socket_file = try std.fs.cwd().createFile(allocation.paths.socket, .{ .mode = 0o600 });
    socket_file.close();
    var meta_file = try std.fs.cwd().createFile(allocation.paths.meta, .{ .mode = 0o600 });
    meta_file.close();
    var detached_file = try std.fs.cwd().createFile(allocation.paths.detached, .{ .mode = 0o600 });
    detached_file.close();
    const target_path = try std.fmt.allocPrint(allocator, "{s}/outside-target", .{root});
    defer allocator.free(target_path);
    var target_file = try std.fs.cwd().createFile(target_path, .{ .mode = 0o600 });
    target_file.close();
    try posix.symlink(target_path, allocation.paths.compat);

    var path_set = try PathSet.init(allocator, allocation.paths);
    defer path_set.deinit(allocator);
    _ = refreshPathSet(&path_set);

    const sessions_dir = try session_registry.sessionsDirInRoot(allocator, root);
    defer allocator.free(sessions_dir);
    const sockets_dir = try std.fmt.allocPrint(allocator, "{s}/s", .{root});
    defer allocator.free(sockets_dir);

    try std.testing.expect((try statNoFollow(root)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(sessions_dir)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(sockets_dir)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(allocation.paths.dir)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(allocation.paths.socket)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(allocation.paths.meta)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(allocation.paths.detached)).mode & sticky_bit != 0);
    try std.testing.expect((try statNoFollow(allocation.paths.agent_sock_link)).mode & sticky_bit == 0);
    try std.testing.expect((try statNoFollow(allocation.paths.compat)).mode & sticky_bit == 0);
    try std.testing.expect((try statNoFollow(target_path)).mode & sticky_bit == 0);
}

test "refresher thread can stop before its next refresh interval" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "zig-cache/runtime-refresher-thread-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try session_registry.allocateSessionDirForGuidInRoot(allocator, root, "s-550e8400-e29b-41d4-a716-446655440001");
    defer allocation.deinit(allocator);

    var refresher = RuntimeRefresher{};
    try refresher.startWithInterval(allocator, allocation.paths, 60 * 60 * 1000);
    refresher.stopAndJoin(allocator);
}
