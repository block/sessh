const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const socket_transport = @import("../transport/socket.zig");

pub const guid_body_len = 36;
pub const compact_guid_len = 32;
pub const session_guid_prefix = "s-";
pub const proxy_guid_prefix = "p-";
pub const session_guid_len = session_guid_prefix.len + guid_body_len;
pub const proxy_guid_len = proxy_guid_prefix.len + guid_body_len;
pub const short_guid_hex_len = 8;
pub const default_ssh_port = "22";

pub const SessionPaths = struct {
    dir: []u8,
    meta: []u8,
    compat: []u8,
    route: []u8,

    pub fn deinit(self: *SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.route);
        allocator.free(self.compat);
        allocator.free(self.meta);
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

    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, canonical });
    defer allocator.free(dir);
    switch (try mkdirSessionDir(allocator, dir)) {
        .created => {},
        .exists => {
            var existing_paths = try pathsForSessionDirInStateRoot(allocator, dir, state_root);
            errdefer existing_paths.deinit(allocator);
            if (runtimeHintsExist(existing_paths)) return error.SessionExists;
            existing_paths.deinit(allocator);
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

pub fn stateSessionsDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return stateSessionsDirInRoot(allocator, root);
}

pub fn sessionsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/guid", .{root});
}

fn stateSessionsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/guid", .{root});
}

pub fn clientSocketsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/c", .{root});
}

pub fn ensureRuntimeLayout(allocator: std.mem.Allocator, paths: SessionPaths) !void {
    const sessions_dir = std.fs.path.dirname(paths.dir) orelse return error.InvalidSessionDir;
    const runtime_root = std.fs.path.dirname(sessions_dir) orelse return error.InvalidSessionDir;
    try ensureRegistryRoot(allocator, runtime_root);
    try mkdirIgnoreExists(allocator, sessions_dir);
    try mkdirIgnoreExists(allocator, paths.dir);
}

pub fn pathsForSessionId(allocator: std.mem.Allocator, id: []const u8) !SessionPaths {
    if (!isValidSessionId(id)) return error.InvalidSessionId;
    const sessions_dir = try sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const canonical = try canonicalGuid(allocator, id);
    defer allocator.free(canonical);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, canonical });
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

    const meta = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{dir});
    errdefer allocator.free(meta);

    const compat = try std.fmt.allocPrint(allocator, "{s}/compat", .{dir});
    errdefer allocator.free(compat);

    const canonical = try canonicalGuid(allocator, std.fs.path.basename(dir));
    defer allocator.free(canonical);
    const route = try routePathForGuidInStateRoot(allocator, state_root, canonical);
    errdefer allocator.free(route);

    return .{
        .dir = dir_copy,
        .meta = meta,
        .compat = compat,
        .route = route,
    };
}

pub fn isValidSessionId(id: []const u8) bool {
    return isValidSessionGuid(id) or isValidCompactGuid(id);
}

fn isValidGuidBody(guid: []const u8) bool {
    if (guid.len != guid_body_len) return false;
    for (guid, 0..) |byte, i| {
        switch (i) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => if (!std.ascii.isHex(byte)) return false,
        }
    }
    return true;
}

pub fn isValidSessionGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, session_guid_prefix) and
        isValidGuidBody(guid[session_guid_prefix.len..]);
}

pub fn isValidProxyGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, proxy_guid_prefix) and
        isValidGuidBody(guid[proxy_guid_prefix.len..]);
}

pub fn isValidGuid(guid: []const u8) bool {
    return isValidSessionGuid(guid) or isValidProxyGuid(guid);
}

pub fn isValidCompactGuid(guid: []const u8) bool {
    if (guid.len != compact_guid_len) return false;
    for (guid) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub fn canonicalGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidSessionGuid(guid)) {
        const out = try allocator.alloc(u8, session_guid_len);
        out[0] = session_guid_prefix[0];
        out[1] = session_guid_prefix[1];
        for (guid[session_guid_prefix.len..], 0..) |byte, i| {
            out[session_guid_prefix.len + i] = std.ascii.toLower(byte);
        }
        return out;
    }
    if (isValidCompactGuid(guid)) {
        const out = try allocator.alloc(u8, session_guid_len);
        out[0] = session_guid_prefix[0];
        out[1] = session_guid_prefix[1];
        var src: usize = 0;
        for (out[session_guid_prefix.len..], 0..) |*byte, i| {
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

pub fn canonicalProxyGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidProxyGuid(guid)) return error.InvalidProxyId;
    const out = try allocator.alloc(u8, proxy_guid_len);
    out[0] = proxy_guid_prefix[0];
    out[1] = proxy_guid_prefix[1];
    for (guid[proxy_guid_prefix.len..], 0..) |byte, i| {
        out[proxy_guid_prefix.len + i] = std.ascii.toLower(byte);
    }
    return out;
}

pub fn compactGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidCompactGuid(guid)) {
        const out = try allocator.alloc(u8, compact_guid_len);
        for (guid, 0..) |byte, i| out[i] = std.ascii.toLower(byte);
        return out;
    }
    if (!isValidSessionGuid(guid)) return error.InvalidSessionId;
    var out = try allocator.alloc(u8, compact_guid_len);
    var dst: usize = 0;
    for (guid[session_guid_prefix.len..]) |byte| {
        if (byte == '-') continue;
        out[dst] = std.ascii.toLower(byte);
        dst += 1;
    }
    return out;
}

pub fn compactProxyGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidProxyGuid(guid)) return error.InvalidProxyId;
    var out = try allocator.alloc(u8, compact_guid_len);
    var dst: usize = 0;
    for (guid[proxy_guid_prefix.len..]) |byte| {
        if (byte == '-') continue;
        out[dst] = std.ascii.toLower(byte);
        dst += 1;
    }
    return out;
}

fn compactRuntimeGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidSessionGuid(guid) or isValidCompactGuid(guid)) return compactGuid(allocator, guid);
    if (isValidProxyGuid(guid)) return compactProxyGuid(allocator, guid);
    return error.InvalidSessionId;
}

pub fn generateGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    return canonicalGuid(allocator, &compact);
}

pub fn generateProxyGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    const session_guid = try canonicalGuid(allocator, &compact);
    defer allocator.free(session_guid);

    const out = try allocator.alloc(u8, proxy_guid_len);
    out[0] = proxy_guid_prefix[0];
    out[1] = proxy_guid_prefix[1];
    @memcpy(out[proxy_guid_prefix.len..], session_guid[session_guid_prefix.len..]);
    return out;
}

pub fn writeMeta(paths: SessionPaths, runtime_pid: c.pid_t, version: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app_allocator.allocator());
    const writer = text.writer(app_allocator.allocator());
    const created_at_unix_ms = sessionMetaCreatedAtUnixMs(app_allocator.allocator(), paths.meta);
    try writer.print(
        "{{\"type\":{f},\"created_at_unix_ms\":{},\"runtime_pid\":{},\"version\":{f}}}\n",
        .{
            std.json.fmt("local-session", .{}),
            created_at_unix_ms,
            runtime_pid,
            std.json.fmt(version, .{}),
        },
    );
    try writeAtomicFile(paths.meta, text.items);
}

fn sessionMetaCreatedAtUnixMs(allocator: std.mem.Allocator, path: []const u8) u64 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return currentUnixMs();
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return currentUnixMs();
    defer parsed.deinit();
    const object = jsonObject(parsed.value) catch return currentUnixMs();
    return (jsonOptionalU64(object, "created_at_unix_ms") catch return currentUnixMs()) orelse currentUnixMs();
}

fn currentUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

pub const Route = struct {
    guid: []u8,
    session_dir: []u8,
    host: []u8,
    resolved_host: []u8,
    port: []u8,
    runtime_version: []u8,
    ssh_options: []const []const u8,
    last_known_alive: bool,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.ssh_options) |option| allocator.free(option);
        allocator.free(self.ssh_options);
        allocator.free(self.runtime_version);
        allocator.free(self.port);
        allocator.free(self.resolved_host);
        allocator.free(self.host);
        allocator.free(self.session_dir);
        allocator.free(self.guid);
        self.* = undefined;
    }
};

pub fn writeSshRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    session_dir: []const u8,
    host: []const u8,
    resolved_host: []const u8,
    port: []const u8,
    ssh_options: []const []const u8,
    runtime_version: []const u8,
) !void {
    return writeRoute(allocator, guid, session_dir, host, ssh_options, .{
        .port = port,
        .resolved_host = resolved_host,
        .runtime_version = runtime_version,
    });
}

pub fn writeLocalRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    session_dir: []const u8,
    runtime_version: []const u8,
) !void {
    return writeRoute(allocator, guid, session_dir, ".", &.{}, .{
        .runtime_version = runtime_version,
    });
}

const RouteStatus = struct {
    last_known_alive: bool = true,
    port: []const u8 = default_ssh_port,
    resolved_host: []const u8 = "",
    runtime_version: []const u8 = "",
};

fn writeRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    session_dir: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    status: RouteStatus,
) !void {
    if (!isAbsolutePath(session_dir)) return error.InvalidSessionDir;
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    const resolved_host = if (status.resolved_host.len == 0) host else status.resolved_host;
    try writer.print(
        "{{\"guid\":{f},\"session_dir\":{f},\"host\":{f},\"resolved_host\":{f},\"port\":{f},\"runtime_version\":{f},\"alive\":{},\"ssh_options\":[",
        .{
            std.json.fmt(canonical, .{}),
            std.json.fmt(session_dir, .{}),
            std.json.fmt(host, .{}),
            std.json.fmt(resolved_host, .{}),
            std.json.fmt(status.port, .{}),
            std.json.fmt(status.runtime_version, .{}),
            status.last_known_alive,
        },
    );
    for (ssh_options, 0..) |arg, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{f}", .{std.json.fmt(arg, .{})});
    }
    try writer.writeAll("]}\n");

    const route_path = try routePathForGuidInStateRoot(allocator, state_root, canonical);
    defer allocator.free(route_path);
    try ensureRouteDirForGuid(allocator, canonical);

    try writeAtomicFile(route_path, text.items);
}

fn routePathForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    return routePathForGuidInStateRoot(allocator, state_root, canonical);
}

fn routePathForGuidInStateRoot(allocator: std.mem.Allocator, state_root: []const u8, guid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/guid/{s}/route.json", .{ state_root, guid });
}

fn ensureRouteDirForGuid(allocator: std.mem.Allocator, guid: []const u8) !void {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    try ensureRegistryRoot(allocator, state_root);

    const state_sessions_dir = try stateSessionsDirInRoot(allocator, state_root);
    defer allocator.free(state_sessions_dir);
    try mkdirIgnoreExists(allocator, state_sessions_dir);

    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ state_sessions_dir, canonical });
    defer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);
}

pub fn readRoute(allocator: std.mem.Allocator, path: []const u8) !Route {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);

    const guid_value = try jsonRequiredString(object, "guid");
    if (!isValidSessionGuid(guid_value)) return error.InvalidRoute;
    const guid = try allocator.dupe(u8, guid_value);
    errdefer allocator.free(guid);

    const session_dir_value = jsonOptionalString(object, "session_dir") orelse "";
    if (session_dir_value.len > 0 and !isAbsolutePath(session_dir_value)) return error.InvalidRoute;
    const session_dir = try allocator.dupe(u8, session_dir_value);
    errdefer allocator.free(session_dir);

    const host = try allocator.dupe(u8, jsonOptionalString(object, "host") orelse "");
    errdefer allocator.free(host);

    const resolved_host = try allocator.dupe(u8, jsonOptionalString(object, "resolved_host") orelse host);
    errdefer allocator.free(resolved_host);

    const port_value = jsonOptionalString(object, "port") orelse default_ssh_port;
    if (!isValidSshPort(port_value)) return error.InvalidRoute;
    const port = try allocator.dupe(u8, port_value);
    errdefer allocator.free(port);

    const runtime_version_value = jsonOptionalString(object, "runtime_version") orelse "";
    const runtime_version = try allocator.dupe(u8, runtime_version_value);
    errdefer allocator.free(runtime_version);

    const options = try jsonStringArrayField(allocator, object, "ssh_options");
    errdefer freeStringArray(allocator, options);

    return .{
        .guid = guid,
        .session_dir = session_dir,
        .host = host,
        .resolved_host = resolved_host,
        .port = port,
        .runtime_version = runtime_version,
        .ssh_options = options,
        .last_known_alive = (try jsonOptionalBool(object, "alive")) orelse true,
    };
}

fn jsonObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJson,
    };
}

fn jsonRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return jsonOptionalString(object, key) orelse error.InvalidJson;
}

fn jsonOptionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonOptionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidJson,
    };
}

fn jsonOptionalU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidJson;
            break :blk @intCast(integer);
        },
        else => error.InvalidJson,
    };
}

fn jsonStringArrayField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return try allocator.alloc([]const u8, 0);
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidJson,
    };
    var out = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
    }
    for (array.items, 0..) |item, i| {
        const string = switch (item) {
            .string => |string| string,
            else => return error.InvalidJson,
        };
        out[i] = try allocator.dupe(u8, string);
        initialized += 1;
    }
    return out;
}

fn isValidSshPort(port: []const u8) bool {
    if (port.len == 0) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value != 0;
}

fn freeStringArray(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn writeAtomicFile(path: []const u8, contents: []const u8) !void {
    const allocator = app_allocator.allocator();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, c.getpid() });
    defer allocator.free(tmp_path);
    try unlinkIfExists(tmp_path);
    errdefer unlinkIfExists(tmp_path) catch {};

    {
        var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
        errdefer file.close();
        try file.writeAll(contents);
        file.close();
    }

    const tmp_path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(tmp_path_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    switch (posix.errno(c.rename(tmp_path_z.ptr, path_z.ptr))) {
        .SUCCESS => return,
        else => return error.RenameFailed,
    }
}

fn isAbsolutePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/");
}

pub const SocketPathAllocation = struct {
    name: []u8,
    path: []u8,

    pub fn deinit(self: *SocketPathAllocation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub fn allocateClientSocketPathForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) !SocketPathAllocation {
    const socket_dir = try clientSocketsDirInRoot(allocator, root);
    defer allocator.free(socket_dir);
    return allocateSocketPathForGuidInDir(allocator, socket_dir, guid);
}

fn allocateSocketPathForGuidInDir(allocator: std.mem.Allocator, socket_dir: []const u8, guid: []const u8) !SocketPathAllocation {
    const compact = try compactRuntimeGuid(allocator, guid);
    defer allocator.free(compact);
    const compact_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ socket_dir, compact });
    errdefer allocator.free(compact_path);
    if (socketPathFits(compact_path) and !try pathExists(compact_path)) {
        return .{
            .name = try allocator.dupe(u8, compact),
            .path = compact_path,
        };
    }
    allocator.free(compact_path);

    if (socket_dir.len + 1 >= maxUnixSocketPathLen()) return error.SocketPathTooLong;
    const hex_len = maxUnixSocketPathLen() - socket_dir.len - 1;
    if (hex_len < 8) return error.SocketPathTooLong;

    var attempts: usize = 0;
    while (attempts < 4096) : (attempts += 1) {
        const name = try randomHex(allocator, hex_len);
        errdefer allocator.free(name);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ socket_dir, name });
        errdefer allocator.free(path);
        if (!try pathExists(path)) {
            return .{ .name = name, .path = path };
        }
        allocator.free(path);
        allocator.free(name);
    }
    return error.SocketNameExhausted;
}

fn randomHex(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, (len + 1) / 2);
    defer allocator.free(bytes);
    std.crypto.random.bytes(bytes);

    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, len);
    for (out, 0..) |*byte, i| {
        const raw = bytes[i / 2];
        const nibble = if ((i % 2) == 0) raw >> 4 else raw & 0x0f;
        byte.* = alphabet[nibble];
    }
    return out;
}

fn maxUnixSocketPathLen() usize {
    const addr: c.sockaddr.un = undefined;
    return addr.path.len - 1;
}

fn socketPathFits(path: []const u8) bool {
    return path.len <= maxUnixSocketPathLen();
}

fn pathExists(path: []const u8) !bool {
    _ = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Clean shutdown removes both the live route and runtime files.
pub fn removeEndedHints(paths: SessionPaths) !void {
    try unlinkIfExists(paths.route);
    try removeRuntimeSessionFiles(paths);
    const route_dir = std.fs.path.dirname(paths.route) orelse return;
    try removeDirIfEmpty(route_dir);
}

fn removeRuntimeSessionFiles(paths: SessionPaths) !void {
    try unlinkIfExists(paths.compat);
    try unlinkIfExists(paths.meta);

    const runtime_log = try std.fmt.allocPrint(app_allocator.allocator(), "{s}/runtime.log", .{paths.dir});
    defer app_allocator.allocator().free(runtime_log);
    try unlinkIfExists(runtime_log);

    try removeDirIfEmpty(paths.dir);
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

fn runtimeHintsExist(paths: SessionPaths) bool {
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

fn removeDirIfEmpty(path: []const u8) !void {
    const path_z = try app_allocator.allocator().dupeZ(u8, path);
    defer app_allocator.allocator().free(path_z);
    switch (posix.errno(c.rmdir(path_z.ptr))) {
        .SUCCESS, .NOENT => return,
        .NOTEMPTY => return error.DirNotEmpty,
        else => return error.RemoveDirFailed,
    }
}

test "refuses GUID session directories with runtime metadata" {
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

test "session paths use guid session directories" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    var allocation = try allocateSessionDirForGuidInRoot(allocator, root, guid);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", allocation.id);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000", allocation.paths.dir);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/meta.json", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/compat", allocation.paths.compat);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/route.json", allocation.paths.route);
}

test "client socket paths use client socket directory" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/client-socket-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "p-550e8400-e29b-41d4-a716-446655440000";
    var allocation = try allocateClientSocketPathForGuidInRoot(allocator, root, guid);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings("550e8400e29b41d4a716446655440000", allocation.name);
    try std.testing.expectEqualStrings("zig-cache/client-socket-path-test/c/550e8400e29b41d4a716446655440000", allocation.path);
}

test "validates session and proxy ids" {
    try std.testing.expect(isValidSessionId("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidSessionId("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(isValidSessionGuid("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidProxyGuid("p-550e8400-e29b-41d4-a716-446655440000"));
    const generated_proxy = try generateProxyGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_proxy);
    try std.testing.expect(isValidProxyGuid(generated_proxy));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId("x-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("s1"));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-44665544000z"));
}

test "route json persists absolute session directories" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/sessh-route-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    const route_path = try std.fmt.allocPrint(allocator, "{s}/route.json", .{root});
    defer allocator.free(route_path);
    const session_dir = "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000";

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.writer(allocator).print(
        "{{\"guid\":\"s-550e8400-e29b-41d4-a716-446655440000\",\"session_dir\":{f},\"host\":\"work.example\",\"runtime_version\":\"0.5.0-test\",\"alive\":true,\"ssh_options\":[\"-F\"]}}\n",
        .{std.json.fmt(session_dir, .{})},
    );
    const file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(text.items);
    file.close();

    var route = try readRoute(allocator, route_path);
    defer route.deinit(allocator);
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", route.guid);
    try std.testing.expectEqualStrings(session_dir, route.session_dir);
    try std.testing.expectEqualStrings("work.example", route.host);
    try std.testing.expectEqualStrings("0.5.0-test", route.runtime_version);
    try std.testing.expect(route.last_known_alive);
    try std.testing.expectEqual(@as(usize, 1), route.ssh_options.len);
    try std.testing.expectEqualStrings("-F", route.ssh_options[0]);
}
