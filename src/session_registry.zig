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
    route: []u8,

    pub fn deinit(self: *SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.route);
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
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    return allocateSessionDirInRoots(allocator, runtime_root, state_root);
}

pub fn allocateSessionDirInRoot(allocator: std.mem.Allocator, root: []const u8) !Allocation {
    const id = try generateGuid(allocator);
    errdefer allocator.free(id);
    var allocation = try allocateSessionDirForGuidInRoots(allocator, root, root, id);
    allocator.free(allocation.id);
    allocation.id = id;
    return allocation;
}

fn allocateSessionDirInRoots(allocator: std.mem.Allocator, runtime_root: []const u8, state_root: []const u8) !Allocation {
    const id = try generateGuid(allocator);
    errdefer allocator.free(id);
    var allocation = try allocateSessionDirForGuidInRoots(allocator, runtime_root, state_root, id);
    allocator.free(allocation.id);
    allocation.id = id;
    return allocation;
}

pub fn allocateSessionDirForGuid(allocator: std.mem.Allocator, guid: []const u8) !Allocation {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    return allocateSessionDirForGuidInRoots(allocator, runtime_root, state_root, guid);
}

pub fn allocateSessionDirForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) !Allocation {
    return allocateSessionDirForGuidInRoots(allocator, root, root, guid);
}

fn allocateSessionDirForGuidInRoots(allocator: std.mem.Allocator, runtime_root: []const u8, state_root: []const u8, guid: []const u8) !Allocation {
    try ensureRegistryRoot(allocator, runtime_root);

    const sessions_dir = try sessionsDirInRoot(allocator, runtime_root);
    defer allocator.free(sessions_dir);
    try mkdirIgnoreExists(allocator, sessions_dir);

    const canonical = try canonicalGuid(allocator, guid);
    errdefer allocator.free(canonical);
    const compact = try compactGuid(allocator, canonical);
    defer allocator.free(compact);

    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, compact });
    defer allocator.free(dir);
    switch (try mkdirSessionDir(allocator, dir)) {
        .created => {},
        .exists => {
            var existing_paths = try pathsForSessionDirInStateRoot(allocator, dir, state_root);
            errdefer existing_paths.deinit(allocator);
            if (liveHintsExist(existing_paths)) return error.SessionExists;
            return .{ .id = canonical, .paths = existing_paths };
        },
    }
    var paths = try pathsForSessionDirInStateRoot(allocator, dir, state_root);
    errdefer paths.deinit(allocator);
    return .{ .id = canonical, .paths = paths };
}

pub fn sessionsDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return sessionsDirInRoot(allocator, root);
}

pub fn sessionsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/g", .{root});
}

pub fn pathsForSessionId(allocator: std.mem.Allocator, id: []const u8) !SessionPaths {
    if (!isValidSessionId(id)) return error.InvalidSessionId;
    const sessions_dir = try sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const compact = try compactGuid(allocator, id);
    defer allocator.free(compact);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, compact });
    defer allocator.free(dir);
    return pathsForSessionDirInStateRoot(allocator, dir, state_root);
}

pub fn pathsForSessionDir(allocator: std.mem.Allocator, dir: []const u8) !SessionPaths {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    return pathsForSessionDirInStateRoot(allocator, dir, state_root);
}

fn pathsForSessionDirInStateRoot(allocator: std.mem.Allocator, dir: []const u8, state_root: []const u8) !SessionPaths {
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

    const compact = std.fs.path.basename(dir);
    const route = try std.fmt.allocPrint(allocator, "{s}/g/{s}/route", .{ state_root, compact });
    errdefer allocator.free(route);

    return .{
        .dir = dir_copy,
        .socket = socket,
        .meta = meta,
        .detached = detached,
        .compat = compat,
        .route = route,
    };
}

pub fn isValidSessionId(id: []const u8) bool {
    return isValidGuid(id) or isValidCompactGuid(id);
}

pub fn isValidGuid(guid: []const u8) bool {
    if (guid.len != 36) return false;
    for (guid, 0..) |byte, i| {
        switch (i) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => if (!std.ascii.isHex(byte)) return false,
        }
    }
    return true;
}

pub fn isValidCompactGuid(guid: []const u8) bool {
    if (guid.len != 32) return false;
    for (guid) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub fn canonicalGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidGuid(guid)) {
        const out = try allocator.alloc(u8, 36);
        for (guid, 0..) |byte, i| out[i] = std.ascii.toLower(byte);
        return out;
    }
    if (isValidCompactGuid(guid)) {
        const out = try allocator.alloc(u8, 36);
        var src: usize = 0;
        for (out, 0..) |*byte, i| {
            switch (i) {
                8, 13, 18, 23 => byte.* = '-',
                else => {
                    byte.* = std.ascii.toLower(guid[src]);
                    src += 1;
                },
            }
        }
        return out;
    }
    return error.InvalidSessionId;
}

pub fn compactGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidCompactGuid(guid)) {
        const out = try allocator.alloc(u8, 32);
        for (guid, 0..) |byte, i| out[i] = std.ascii.toLower(byte);
        return out;
    }
    if (!isValidGuid(guid)) return error.InvalidSessionId;
    var out = try allocator.alloc(u8, 32);
    var dst: usize = 0;
    for (guid) |byte| {
        if (byte == '-') continue;
        out[dst] = std.ascii.toLower(byte);
        dst += 1;
    }
    return out;
}

pub fn generateGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    return canonicalGuid(allocator, &compact);
}

pub fn writeMeta(paths: SessionPaths, agent_pid: c.pid_t, version: []const u8) !void {
    const file = try std.fs.cwd().createFile(paths.meta, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "agent_pid={}\nversion={s}\n", .{ agent_pid, version });
    try file.writeAll(text);
}

pub const Route = struct {
    bytes: []u8,
    guid: []const u8,
    primary_alias: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        allocator.free(self.ssh_options);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn writeSshRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    primary_alias: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.print("guid={s}\n", .{guid});
    try writer.print("primary_alias={s}\n", .{primary_alias});
    try writer.print("host=", .{});
    try appendHex(&text, allocator, host);
    try writer.print("\n", .{});
    for (ssh_options) |arg| {
        try writer.print("ssh_option=", .{});
        try appendHex(&text, allocator, arg);
        try writer.print("\n", .{});
    }

    const route_path = try routePathForGuid(allocator, guid);
    defer allocator.free(route_path);
    try ensureRouteDirForGuid(allocator, guid);

    const file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(text.items);
}

pub fn readRouteForRef(allocator: std.mem.Allocator, ref: []const u8) !Route {
    var paths = try pathsForRef(allocator, ref);
    defer paths.deinit(allocator);
    return readRoute(allocator, paths.route);
}

fn routePathForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const compact = try compactGuid(allocator, guid);
    defer allocator.free(compact);
    return routePathForCompactInStateRoot(allocator, state_root, compact);
}

fn routePathForCompactInStateRoot(allocator: std.mem.Allocator, state_root: []const u8, compact: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/g/{s}/route", .{ state_root, compact });
}

fn ensureRouteDirForGuid(allocator: std.mem.Allocator, guid: []const u8) !void {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    try ensureRegistryRoot(allocator, state_root);

    const state_sessions_dir = try sessionsDirInRoot(allocator, state_root);
    defer allocator.free(state_sessions_dir);
    try mkdirIgnoreExists(allocator, state_sessions_dir);

    const compact = try compactGuid(allocator, guid);
    defer allocator.free(compact);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ state_sessions_dir, compact });
    defer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);
}

pub fn readRoute(allocator: std.mem.Allocator, path: []const u8) !Route {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    errdefer allocator.free(bytes);

    var guid: ?[]const u8 = null;
    var primary_alias: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var option_count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "guid")) {
            if (!isValidGuid(value)) return error.InvalidRoute;
            guid = value;
        } else if (std.mem.eql(u8, key, "primary_alias")) {
            if (!isValidAlias(value)) return error.InvalidRoute;
            primary_alias = value;
        } else if (std.mem.eql(u8, key, "host")) {
            host = value;
        } else if (std.mem.eql(u8, key, "ssh_option")) {
            option_count += 1;
        }
    }

    var options = try allocator.alloc([]const u8, option_count);
    errdefer allocator.free(options);
    var option_index: usize = 0;
    lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "ssh_option")) {
            options[option_index] = try decodeHexInPlace(value);
            option_index += 1;
        }
    }

    return .{
        .bytes = bytes,
        .guid = guid orelse return error.InvalidRoute,
        .primary_alias = primary_alias orelse return error.InvalidRoute,
        .host = try decodeHexInPlace(host orelse return error.InvalidRoute),
        .ssh_options = options,
    };
}

pub fn createAlias(allocator: std.mem.Allocator, alias: []const u8, guid: []const u8) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createAliasInRoot(allocator, root, alias, guid);
}

pub fn createAliasInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8, guid: []const u8) !void {
    if (!isValidAlias(alias)) return error.InvalidAlias;
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    try ensureRegistryRoot(allocator, root);
    try mkdirIgnoreExists(allocator, aliases_dir);

    const compact = try compactGuid(allocator, guid);
    defer allocator.free(compact);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, alias });
    defer allocator.free(link_path);
    const target = try std.fmt.allocPrint(allocator, "../g/{s}", .{compact});
    defer allocator.free(target);
    const link_path_z = try allocator.dupeZ(u8, link_path);
    defer allocator.free(link_path_z);
    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    switch (posix.errno(c.symlink(target_z.ptr, link_path_z.ptr))) {
        .SUCCESS => return,
        .EXIST => return error.AliasExists,
        else => return error.SymlinkFailed,
    }
}

pub fn ensureAliasForGuid(allocator: std.mem.Allocator, alias: []const u8, guid: []const u8) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return ensureAliasForGuidInRoot(allocator, root, alias, guid);
}

pub fn ensureAliasForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8, guid: []const u8) !void {
    createAliasInRoot(allocator, root, alias, guid) catch |err| switch (err) {
        error.AliasExists => {
            const existing = try resolveRefToGuidInRoot(allocator, root, alias);
            defer allocator.free(existing);
            const canonical = try canonicalGuid(allocator, guid);
            defer allocator.free(canonical);
            if (!std.mem.eql(u8, existing, canonical)) return error.AliasExists;
        },
        else => return err,
    };
}

pub fn removeAlias(allocator: std.mem.Allocator, alias: []const u8) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return removeAliasInRoot(allocator, root, alias);
}

pub fn removeAliasInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8) !void {
    if (!isValidAlias(alias)) return error.InvalidAlias;
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, alias });
    defer allocator.free(link_path);
    try unlinkIfExists(link_path);
}

pub fn defaultAliasForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    return allocator.dupe(u8, canonical[0..8]);
}

pub fn createGeneratedRemoteAlias(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createGeneratedRemoteAliasInRoot(allocator, root, guid);
}

pub fn createGeneratedRemoteAliasInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    while (true) {
        var bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const alias = try std.fmt.allocPrint(allocator, "r{s}", .{&hex});
        errdefer allocator.free(alias);
        createAliasInRoot(allocator, root, alias, guid) catch |err| switch (err) {
            error.AliasExists => {
                allocator.free(alias);
                continue;
            },
            else => return err,
        };
        return alias;
    }
}

pub fn pathsForRef(allocator: std.mem.Allocator, ref: []const u8) !SessionPaths {
    if (isValidSessionId(ref)) return pathsForSessionId(allocator, ref);
    if (!isValidAlias(ref)) return error.InvalidSessionId;
    const guid = try resolveRefToGuid(allocator, ref);
    defer allocator.free(guid);
    return pathsForSessionId(allocator, guid);
}

pub fn resolveRefToGuid(allocator: std.mem.Allocator, ref: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return resolveRefToGuidInRoot(allocator, root, ref);
}

pub fn resolveRefToGuidInRoot(allocator: std.mem.Allocator, root: []const u8, ref: []const u8) ![]u8 {
    if (isValidSessionId(ref)) return canonicalGuid(allocator, ref);
    if (!isValidAlias(ref)) return error.InvalidSessionId;
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, ref });
    defer allocator.free(link_path);
    const target = try readLinkAlloc(allocator, link_path, 4096);
    defer allocator.free(target);
    const compact = std.fs.path.basename(target);
    return canonicalGuid(allocator, compact);
}

pub fn aliasesDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/alias", .{root});
}

pub fn primaryAliasForGuid(allocator: std.mem.Allocator, guid: []const u8) !?[]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    var dir = std.fs.openDirAbsolute(aliases_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    const compact = try compactGuid(allocator, guid);
    defer allocator.free(compact);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (!isValidAlias(entry.name)) continue;
        const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, entry.name });
        defer allocator.free(link_path);
        const target = readLinkAlloc(allocator, link_path, 4096) catch continue;
        defer allocator.free(target);
        if (std.mem.eql(u8, std.fs.path.basename(target), compact)) {
            return try allocator.dupe(u8, entry.name);
        }
    }
    return null;
}

pub fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > 128) return false;
    if (std.mem.eql(u8, alias, ".") or std.mem.eql(u8, alias, "..")) return false;
    if (alias[0] == '-') return false;
    if (isValidGuid(alias) or isValidCompactGuid(alias)) return false;
    for (alias) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        }
    }
    return true;
}

fn appendHex(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    try out.ensureUnusedCapacity(allocator, bytes.len * 2);
    for (bytes) |byte| {
        out.appendAssumeCapacity(alphabet[byte >> 4]);
        out.appendAssumeCapacity(alphabet[byte & 0x0f]);
    }
}

fn decodeHexInPlace(value: []const u8) ![]const u8 {
    if (value.len % 2 != 0) return error.InvalidRoute;
    const mutable: []u8 = @constCast(value);
    var dst: usize = 0;
    var src: usize = 0;
    while (src < value.len) : (src += 2) {
        const hi = std.fmt.charToDigit(value[src], 16) catch return error.InvalidRoute;
        const lo = std.fmt.charToDigit(value[src + 1], 16) catch return error.InvalidRoute;
        mutable[dst] = @intCast((hi << 4) | lo);
        dst += 1;
    }
    return mutable[0..dst];
}

fn readLinkAlloc(allocator: std.mem.Allocator, path: []const u8, max_len: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const buf = try allocator.alloc(u8, max_len);
    defer allocator.free(buf);
    const n = c.readlink(path_z.ptr, buf.ptr, buf.len);
    if (n < 0) {
        return switch (posix.errno(n)) {
            .NOENT, .NOTDIR => error.FileNotFound,
            else => error.ReadLinkFailed,
        };
    }
    return allocator.dupe(u8, buf[0..@intCast(n)]);
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

fn liveHintsExist(paths: SessionPaths) bool {
    if (std.fs.cwd().statFile(paths.socket)) |_| return true else |err| switch (err) {
        error.FileNotFound => {},
        else => return true,
    }
    _ = std.fs.cwd().statFile(paths.meta) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn unlinkIfExists(path: []const u8) !void {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);
    switch (posix.errno(c.unlink(path_z.ptr))) {
        .SUCCESS, .NOENT => return,
        else => return error.UnlinkFailed,
    }
}

test "allocates GUID session directories without reusing tombstones" {
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
    try std.testing.expect(isValidGuid(first.id));

    var second = try allocateSessionDirInRoot(allocator, root);
    defer second.deinit(allocator);
    try std.testing.expect(isValidGuid(second.id));
    try std.testing.expect(!std.mem.eql(u8, first.id, second.id));

    try writeMeta(first.paths, 12345, "0.5.0-dev");
    try std.testing.expectError(error.SessionExists, allocateSessionDirForGuidInRoot(allocator, root, first.id));
}

test "session paths use short socket components and registry side files" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "550e8400-e29b-41d4-a716-446655440000";
    var allocation = try allocateSessionDirForGuidInRoot(allocator, root, guid);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", allocation.id);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000", allocation.paths.dir);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000/s", allocation.paths.socket);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000/meta", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000/detached", allocation.paths.detached);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000/compat", allocation.paths.compat);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/g/550e8400e29b41d4a716446655440000/route", allocation.paths.route);
}

test "validates session ids and aliases" {
    try std.testing.expect(isValidSessionId("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidSessionId("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("s1"));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-44665544000z"));
    try std.testing.expect(isValidAlias("s1"));
    try std.testing.expect(isValidAlias("my-awesome-session"));
    try std.testing.expect(!isValidAlias("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidAlias("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!isValidAlias("-bad"));
    try std.testing.expect(!isValidAlias("bad/name"));
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
    try std.testing.expectEqualStrings("agent_pid=12345\nversion=0.4.0-dev\n", meta);

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
