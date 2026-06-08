const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;

var runtime_root_symlink_published = false;

/// Runtime root for live sockets and daemon-owned files. Keep this path short:
/// Unix-domain socket paths have tight platform limits.
pub fn runtimeRoot(allocator: std.mem.Allocator) ![]u8 {
    if (envVar("XDG_RUNTIME_DIR")) |root| return runtimeRootForXdg(allocator, root);
    return runtimeRootFor(allocator, c.getuid());
}

fn runtimeRootFor(allocator: std.mem.Allocator, uid: c.uid_t) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/sessh-{}", .{uid});
}

fn runtimeRootForXdg(allocator: std.mem.Allocator, xdg_runtime_dir: []const u8) ![]u8 {
    return allocator.dupe(u8, xdg_runtime_dir);
}

/// Persistent client-side registry for remote routes.
pub fn stateRoot(allocator: std.mem.Allocator) ![]u8 {
    if (c.getenv("XDG_STATE_HOME")) |state_z| {
        const state = std.mem.span(state_z);
        if (state.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/sessh", .{state});
        }
    }
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.span(home_z);
        if (home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/.local/state/sessh", .{home});
        }
    }
    return error.MissingStateHome;
}

pub fn cacheRoot(allocator: std.mem.Allocator) ![]u8 {
    if (c.getenv("XDG_CACHE_HOME")) |cache_z| {
        const cache = std.mem.span(cache_z);
        if (cache.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/sessh", .{cache});
        }
    }
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.span(home_z);
        if (home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/.cache/sessh", .{home});
        }
    }
    return error.MissingCacheHome;
}

pub fn cachedArtifactPath(allocator: std.mem.Allocator, artifact_set_id: []const u8, hash_hex: []const u8) ![]u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/bin/{s}/{s}/sessh", .{ root, artifact_set_id, hash_hex });
}

pub fn publishRuntimeRootSymlinkOnce(allocator: std.mem.Allocator) void {
    if (runtime_root_symlink_published) return;
    const root = runtimeRoot(allocator) catch return;
    defer allocator.free(root);
    publishRuntimeRootSymlink(allocator, root) catch return;
    runtime_root_symlink_published = true;
}

fn publishRuntimeRootSymlink(allocator: std.mem.Allocator, runtime_root: []const u8) !void {
    const root = cacheRoot(allocator) catch |err| switch (err) {
        error.MissingCacheHome => return,
        else => return err,
    };
    defer allocator.free(root);

    try std.fs.cwd().makePath(root);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/runtime_dir", .{root});
    defer allocator.free(link_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ link_path, c.getpid() });
    defer allocator.free(tmp_path);

    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try posix.symlink(runtime_root, tmp_path);
    try std.fs.renameAbsolute(tmp_path, link_path);
}

pub fn listenSocket(path: []const u8) !c.fd_t {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);

    try ensureSocketDir(app_allocator.allocator(), path);
    try removeStaleSocketIfSafe(path_z.ptr);

    const fd = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    try setCloseOnExec(fd);

    var addr = unixAddr(path) catch return error.SocketPathTooLong;
    const len = sockaddrLen(@TypeOf(addr), path.len);
    if (c.bind(fd, @ptrCast(&addr), len) != 0) return error.BindFailed;
    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    return fd;
}

pub fn connectSocket(path: []const u8) !c.fd_t {
    try validateSocketDir(path);

    const fd = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    try setCloseOnExec(fd);

    var addr = try unixAddr(path);
    const len = sockaddrLen(@TypeOf(addr), path.len);
    if (c.connect(fd, @ptrCast(&addr), len) != 0) {
        const path_z = try app_allocator.allocator().dupeZ(u8, path);
        defer app_allocator.allocator().free(path_z);
        const info = pathInfoZ(path_z.ptr) catch return error.SocketPathMissing;
        if (!c.S.ISSOCK(info.mode)) return error.UnsafeSocketPath;
        if (info.uid != c.getuid()) return error.UnsafeSocketOwner;
        return error.ConnectFailed;
    }
    return fd;
}

pub fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const close_on_exec_flag = @as(c_int, @intCast(c.FD_CLOEXEC));
    if ((flags & close_on_exec_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFD, flags | close_on_exec_flag) < 0) return error.FcntlFailed;
}

pub fn ensureSocketDir(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, socket_path, '/') orelse return;
    const dir = socket_path[0..slash];
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |parent_slash| {
        const parent = dir[0..parent_slash];
        if (parent.len > 0) try mkdirIgnoreExists(allocator, parent);
    }
    try mkdirIgnoreExists(allocator, dir);
    try validateOwnedPrivateDir(dir);
}

fn mkdirIgnoreExists(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    switch (posix.errno(c.mkdir(path_z.ptr, 0o700))) {
        .SUCCESS, .EXIST => return,
        else => return error.MkdirFailed,
    }
}

fn validateSocketDir(socket_path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, socket_path, '/') orelse return error.SocketDirMissing;
    const dir = socket_path[0..slash];
    if (dir.len == 0) return error.SocketDirMissing;
    try validateOwnedPrivateDir(dir);
}

fn validateOwnedPrivateDir(path: []const u8) !void {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);

    const info = pathInfoZ(path_z.ptr) catch return error.SocketDirMissing;
    if (!c.S.ISDIR(info.mode)) return error.SocketDirNotDirectory;
    if (info.uid != c.getuid()) return error.UnsafeSocketDirOwner;
    if ((info.mode & 0o077) != 0) return error.UnsafeSocketDirPermissions;
}

fn removeStaleSocketIfSafe(path_z: [*:0]const u8) !void {
    const info = pathInfoZ(path_z) catch return;
    if (!c.S.ISSOCK(info.mode)) return error.UnsafeSocketPath;
    if (info.uid != c.getuid()) return error.UnsafeSocketOwner;
    switch (posix.errno(c.unlink(path_z))) {
        .SUCCESS, .NOENT => return,
        else => return error.UnlinkFailed,
    }
}

const PathInfo = struct {
    uid: c.uid_t,
    mode: u32,
};

fn pathInfoZ(path_z: [*:0]const u8) !PathInfo {
    return switch (builtin.os.tag) {
        .linux => pathInfoLinux(path_z),
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => pathInfoFstatat(path_z),
        else => error.UnsupportedSocketPlatform,
    };
}

fn pathInfoLinux(path_z: [*:0]const u8) !PathInfo {
    const linux = std.os.linux;
    var statx: linux.Statx = undefined;
    switch (linux.E.init(linux.statx(linux.AT.FDCWD, path_z, linux.AT.SYMLINK_NOFOLLOW, linux.STATX_BASIC_STATS, &statx))) {
        .SUCCESS => return .{ .uid = statx.uid, .mode = statx.mode },
        .NOENT, .NOTDIR => return error.PathNotFound,
        else => return error.PathStatFailed,
    }
}

fn pathInfoFstatat(path_z: [*:0]const u8) !PathInfo {
    var stat: c.Stat = undefined;
    switch (posix.errno(c.fstatat(c.AT.FDCWD, path_z, &stat, c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => return .{ .uid = stat.uid, .mode = stat.mode },
        .NOENT, .NOTDIR => return error.PathNotFound,
        else => return error.PathStatFailed,
    }
}

fn unixAddr(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    if (@hasField(c.sockaddr.un, "len")) addr.len = @sizeOf(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    return addr;
}

fn sockaddrLen(comptime T: type, path_len: usize) c.socklen_t {
    return @intCast(@offsetOf(T, "path") + path_len + 1);
}

fn envVar(name: [*:0]const u8) ?[]const u8 {
    const value_z = c.getenv(name) orelse return null;
    const value = std.mem.span(value_z);
    if (value.len == 0) return null;
    return value;
}

test "runtime root uses fixed tmp fallback" {
    const allocator = std.testing.allocator;
    const fallback_root = try runtimeRootFor(allocator, 501);
    defer allocator.free(fallback_root);
    try std.testing.expectEqualStrings("/tmp/sessh-501", fallback_root);
}

test "xdg runtime root is used directly" {
    const allocator = std.testing.allocator;

    const short = try runtimeRootForXdg(allocator, "/run/user/501");
    defer allocator.free(short);
    try std.testing.expectEqualStrings("/run/user/501", short);

    const too_long = try allocator.alloc(u8, 256);
    defer allocator.free(too_long);
    @memset(too_long, 'x');
    const long = try runtimeRootForXdg(allocator, too_long);
    defer allocator.free(long);
    try std.testing.expectEqualStrings(too_long, long);
}
