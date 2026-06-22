// Publishes the role-named executables inside a daemon namespace. The daemon's
// locked namespace is the source of truth, so helper process names and symlinks
// stay matched to the running sesshd binary.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");

pub const daemon_name = socket_namespace.daemon_executable_name;
pub const bridge_name = socket_namespace.bridge_executable_name;
pub const proxy_name = socket_namespace.proxy_executable_name;
pub const terminal_remote_name = socket_namespace.terminal_remote_executable_name;
pub const proxy_remote_name = socket_namespace.proxy_remote_executable_name;

pub const NamespaceExecutables = struct {
    allocator: std.mem.Allocator,
    daemon: []u8,
    bridge: []u8,
    proxy: []u8,
    terminal_remote: []u8,
    proxy_remote: []u8,

    pub fn deinit(self: *NamespaceExecutables) void {
        self.allocator.free(self.daemon);
        self.allocator.free(self.bridge);
        self.allocator.free(self.proxy);
        self.allocator.free(self.terminal_remote);
        self.allocator.free(self.proxy_remote);
        self.* = undefined;
    }
};

/// Startup callers use this before starting a daemon. If the namespace lock is
/// busy, another daemon or daemon starter is the source of truth, so the caller
/// must not start a daemon through whatever symlink happens to be there.
pub fn installNamespaceExecutablesForDaemonStart(
    allocator: std.mem.Allocator,
    exe: []const u8,
    dir_name: []const u8,
) !?NamespaceExecutables {
    var lock = tryAcquireNamespaceLock(allocator, dir_name) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    defer lock.deinit();
    return try installNamespaceExecutablesWhileHoldingLock(allocator, exe, dir_name);
}

/// Role re-exec callers need a role path. They rewrite it only when the
/// namespace is not already owned; otherwise they use the existing path.
pub fn installNamespaceExecutablesOrUseNamespaceOwner(
    allocator: std.mem.Allocator,
    exe: []const u8,
    dir_name: []const u8,
) !NamespaceExecutables {
    if (try installNamespaceExecutablesForDaemonStart(allocator, exe, dir_name)) |executables| {
        return executables;
    }
    return namespaceExecutablePaths(allocator, dir_name);
}

/// Replace the role symlinks. The caller must already hold sesshd.lock for
/// this namespace.
pub fn installNamespaceExecutablesWhileHoldingLock(
    allocator: std.mem.Allocator,
    exe: []const u8,
    dir_name: []const u8,
) !NamespaceExecutables {
    const target = try resolveExecutablePath(allocator, exe);
    defer allocator.free(target);

    var executables = try namespaceExecutablePaths(allocator, dir_name);
    errdefer executables.deinit();

    try replaceSymlink(allocator, target, executables.daemon);
    try replaceSymlink(allocator, target, executables.bridge);
    try replaceSymlink(allocator, target, executables.proxy);
    try replaceSymlink(allocator, target, executables.terminal_remote);
    try replaceSymlink(allocator, target, executables.proxy_remote);

    return executables;
}

/// Compute the role paths without reading or writing the symlinks.
pub fn namespaceExecutablePaths(
    allocator: std.mem.Allocator,
    dir_name: []const u8,
) !NamespaceExecutables {
    const daemon_path = try socket_namespace.executablePath(allocator, dir_name, daemon_name);
    errdefer allocator.free(daemon_path);
    const bridge_path = try socket_namespace.executablePath(allocator, dir_name, bridge_name);
    errdefer allocator.free(bridge_path);
    const proxy_path = try socket_namespace.executablePath(allocator, dir_name, proxy_name);
    errdefer allocator.free(proxy_path);
    const terminal_remote_path = try socket_namespace.executablePath(allocator, dir_name, terminal_remote_name);
    errdefer allocator.free(terminal_remote_path);
    const proxy_remote_path = try socket_namespace.executablePath(allocator, dir_name, proxy_remote_name);
    errdefer allocator.free(proxy_remote_path);

    return .{
        .allocator = allocator,
        .daemon = daemon_path,
        .bridge = bridge_path,
        .proxy = proxy_path,
        .terminal_remote = terminal_remote_path,
        .proxy_remote = proxy_remote_path,
    };
}

const NamespaceLock = struct {
    file: std.fs.File,

    fn deinit(self: *NamespaceLock) void {
        self.file.close();
        self.* = undefined;
    }
};

fn tryAcquireNamespaceLock(allocator: std.mem.Allocator, dir_name: []const u8) !NamespaceLock {
    const lock_path = try socket_namespace.lockPath(allocator, dir_name);
    defer allocator.free(lock_path);
    try socket_transport.ensureSocketDir(allocator, lock_path);

    var file = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer file.close();
    try socket_transport.setCloseOnExec(file.handle);
    try posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB);
    return .{ .file = file };
}

pub fn reexec(
    allocator: std.mem.Allocator,
    executable: []const u8,
    args: []const []const u8,
) !void {
    // Re-exec through the role-named symlink so process listings show sesshd,
    // sessh-bridge, etc. Build a null-terminated argv because execvpe is the
    // final boundary before leaving Zig-owned memory behind.
    var owned_args = try allocator.alloc([:0]u8, args.len + 1);
    var initialized: usize = 0;
    defer {
        for (owned_args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(owned_args);
    }
    var argv = try allocator.allocSentinel(?[*:0]const u8, args.len + 1, null);
    defer allocator.free(argv);

    owned_args[0] = try allocator.dupeZ(u8, executable);
    initialized += 1;
    argv[0] = owned_args[0].ptr;
    for (args, 0..) |arg, i| {
        owned_args[i + 1] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[i + 1] = owned_args[i + 1].ptr;
    }

    return posix.execvpeZ(argv[0].?, argv.ptr, @ptrCast(c.environ));
}

fn replaceSymlink(allocator: std.mem.Allocator, target: []const u8, path: []const u8) !void {
    try socket_transport.ensureSocketDir(allocator, path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, c.getpid() });
    defer allocator.free(tmp_path);
    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try posix.symlink(target, tmp_path);
    try std.fs.renameAbsolute(tmp_path, path);
}

fn resolveExecutablePath(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    // Role symlinks should point at the actual sessh executable when possible.
    // Resolve PATH-relative invocations so restarting the daemon from a
    // different shell does not leave stale symlinks to an old working directory.
    if (std.mem.indexOfScalar(u8, exe, '/') != null) {
        if (std.fs.path.isAbsolute(exe)) {
            return std.fs.realpathAlloc(allocator, exe) catch allocator.dupe(u8, exe);
        }
        return std.fs.cwd().realpathAlloc(allocator, exe) catch allocator.dupe(u8, exe);
    }

    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, exe),
        else => return err,
    };
    defer allocator.free(path_env);

    var parts = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (parts.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, exe });
        defer allocator.free(candidate);
        posix.access(candidate, posix.X_OK) catch continue;
        return std.fs.realpathAlloc(allocator, candidate) catch allocator.dupe(u8, candidate);
    }

    return allocator.dupe(u8, exe);
}

test "namespace executables are written beside socket namespace" {
    const allocator = std.testing.allocator;
    const dir_name = "1.dev.exec-test";
    const daemon = try socket_namespace.executablePath(allocator, dir_name, daemon_name);
    defer allocator.free(daemon);
    try std.testing.expect(std.mem.endsWith(u8, daemon, "/1.dev.exec-test/sesshd"));
    const bridge = try socket_namespace.executablePath(allocator, dir_name, bridge_name);
    defer allocator.free(bridge);
    try std.testing.expect(std.mem.endsWith(u8, bridge, "/1.dev.exec-test/sessh-bridge"));
    const proxy = try socket_namespace.executablePath(allocator, dir_name, proxy_name);
    defer allocator.free(proxy);
    try std.testing.expect(std.mem.endsWith(u8, proxy, "/1.dev.exec-test/sessh-proxy"));
    const terminal_remote = try socket_namespace.executablePath(allocator, dir_name, terminal_remote_name);
    defer allocator.free(terminal_remote);
    try std.testing.expect(std.mem.endsWith(u8, terminal_remote, "/1.dev.exec-test/sessh-terminal-remote"));
    const proxy_remote = try socket_namespace.executablePath(allocator, dir_name, proxy_remote_name);
    defer allocator.free(proxy_remote);
    try std.testing.expect(std.mem.endsWith(u8, proxy_remote, "/1.dev.exec-test/sessh-proxy-remote"));
}

test "namespace executables are not rewritten while namespace lock is held" {
    const allocator = std.testing.allocator;
    const dir_name = "1.dev.exec-lock-test";

    var owner_lock = try tryAcquireNamespaceLock(allocator, dir_name);
    defer owner_lock.deinit();

    var executables = try installNamespaceExecutablesWhileHoldingLock(allocator, "/tmp/sessh-source-a", dir_name);
    defer {
        deleteNamespaceExecutables(executables);
        executables.deinit();
    }

    const initial_target = try readLinkAlloc(allocator, executables.daemon);
    defer allocator.free(initial_target);
    try std.testing.expectEqualStrings("/tmp/sessh-source-a", initial_target);

    const contender = try installNamespaceExecutablesForDaemonStart(allocator, "/tmp/sessh-source-b", dir_name);
    try std.testing.expectEqual(@as(?NamespaceExecutables, null), contender);

    const final_target = try readLinkAlloc(allocator, executables.daemon);
    defer allocator.free(final_target);
    try std.testing.expectEqualStrings(initial_target, final_target);
}

fn readLinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(path, &buf);
    return allocator.dupe(u8, target);
}

fn deleteNamespaceExecutables(executables: NamespaceExecutables) void {
    std.fs.deleteFileAbsolute(executables.daemon) catch {};
    std.fs.deleteFileAbsolute(executables.bridge) catch {};
    std.fs.deleteFileAbsolute(executables.proxy) catch {};
    std.fs.deleteFileAbsolute(executables.terminal_remote) catch {};
    std.fs.deleteFileAbsolute(executables.proxy_remote) catch {};
}
