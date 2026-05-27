const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const socket_transport = @import("socket_transport.zig");

pub const guid_body_len = 36;
pub const compact_guid_len = 32;
pub const session_guid_prefix = "s-";
pub const client_guid_prefix = "c-";
pub const session_guid_len = session_guid_prefix.len + guid_body_len;
pub const client_guid_len = client_guid_prefix.len + guid_body_len;
pub const default_alias_hex_len = 4;

pub const SessionPaths = struct {
    dir: []u8,
    socket: []u8,
    agent_sock_link: []u8,
    meta: []u8,
    detached: []u8,
    compat: []u8,
    route: []u8,

    pub fn deinit(self: *SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.route);
        allocator.free(self.compat);
        allocator.free(self.detached);
        allocator.free(self.meta);
        allocator.free(self.agent_sock_link);
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

pub const GeneratedIdentity = struct {
    guid: []u8,
    alias: []u8,

    pub fn deinit(self: *GeneratedIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.alias);
        allocator.free(self.guid);
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

    const socket_dir = try sessionSocketsDirInRoot(allocator, runtime_root);
    defer allocator.free(socket_dir);
    try mkdirIgnoreExists(allocator, socket_dir);

    const canonical = try canonicalGuid(allocator, guid);
    errdefer allocator.free(canonical);

    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, canonical });
    defer allocator.free(dir);
    switch (try mkdirSessionDir(allocator, dir)) {
        .created => {},
        .exists => {
            var existing_paths = try pathsForSessionDirInStateRoot(allocator, dir, state_root);
            errdefer existing_paths.deinit(allocator);
            if (liveHintsExist(existing_paths)) return error.SessionExists;
            existing_paths.deinit(allocator);
        },
    }

    var socket_allocation = try allocateSocketPathForGuidInRoot(allocator, runtime_root, canonical);
    defer socket_allocation.deinit(allocator);
    const link = try agentSocketLinkPath(allocator, dir);
    defer allocator.free(link);
    try installAgentSocketLink(allocator, link, socket_allocation.name);

    var paths = try pathsForSessionDirWithSocketInStateRoot(allocator, dir, socket_allocation.path, state_root);
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

fn sessionSocketsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/s", .{root});
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
    const agent_sock_link = try agentSocketLinkPath(allocator, dir);
    errdefer allocator.free(agent_sock_link);
    const socket = socketPathFromAgentSocketLink(allocator, dir, agent_sock_link) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, agent_sock_link),
        else => return err,
    };
    defer allocator.free(socket);
    return pathsForSessionDirWithSocketAndLinkInStateRoot(allocator, dir, socket, agent_sock_link, state_root);
}

fn pathsForSessionDirWithSocketInStateRoot(allocator: std.mem.Allocator, dir: []const u8, socket: []const u8, state_root: []const u8) !SessionPaths {
    const agent_sock_link = try agentSocketLinkPath(allocator, dir);
    errdefer allocator.free(agent_sock_link);
    return pathsForSessionDirWithSocketAndLinkInStateRoot(allocator, dir, socket, agent_sock_link, state_root);
}

fn pathsForSessionDirWithSocketAndLinkInStateRoot(allocator: std.mem.Allocator, dir: []const u8, socket: []const u8, agent_sock_link: []u8, state_root: []const u8) !SessionPaths {
    const dir_copy = try allocator.dupe(u8, dir);
    errdefer allocator.free(dir_copy);

    const socket_copy = try allocator.dupe(u8, socket);
    errdefer allocator.free(socket_copy);

    const meta = try std.fmt.allocPrint(allocator, "{s}/meta", .{dir});
    errdefer allocator.free(meta);

    const detached = try std.fmt.allocPrint(allocator, "{s}/detached", .{dir});
    errdefer allocator.free(detached);

    const compat = try std.fmt.allocPrint(allocator, "{s}/compat", .{dir});
    errdefer allocator.free(compat);

    const canonical = try canonicalGuid(allocator, std.fs.path.basename(dir));
    defer allocator.free(canonical);
    const route = try routePathForGuidInStateRoot(allocator, state_root, canonical);
    errdefer allocator.free(route);

    return .{
        .dir = dir_copy,
        .socket = socket_copy,
        .agent_sock_link = agent_sock_link,
        .meta = meta,
        .detached = detached,
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

pub fn isValidClientGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, client_guid_prefix) and
        isValidGuidBody(guid[client_guid_prefix.len..]);
}

pub fn isValidGuid(guid: []const u8) bool {
    return isValidSessionGuid(guid) or isValidClientGuid(guid);
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

pub fn canonicalClientGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidClientGuid(guid)) return error.InvalidClientId;
    const out = try allocator.alloc(u8, client_guid_len);
    out[0] = client_guid_prefix[0];
    out[1] = client_guid_prefix[1];
    for (guid[client_guid_prefix.len..], 0..) |byte, i| {
        out[client_guid_prefix.len + i] = std.ascii.toLower(byte);
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

pub fn generateGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    return canonicalGuid(allocator, &compact);
}

pub fn generateClientGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    const session_guid = try canonicalGuid(allocator, &compact);
    defer allocator.free(session_guid);

    const out = try allocator.alloc(u8, client_guid_len);
    out[0] = client_guid_prefix[0];
    out[1] = client_guid_prefix[1];
    @memcpy(out[client_guid_prefix.len..], session_guid[session_guid_prefix.len..]);
    return out;
}

pub fn generateGuidWithDefaultAlias(allocator: std.mem.Allocator) !GeneratedIdentity {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return generateGuidWithDefaultAliasInRoot(allocator, root);
}

pub fn generateGuidWithDefaultAliasInRoot(allocator: std.mem.Allocator, root: []const u8) !GeneratedIdentity {
    const guid = try generateGuid(allocator);
    errdefer allocator.free(guid);
    const alias = try availableDefaultAliasForGuidInRoot(allocator, root, guid);
    return .{ .guid = guid, .alias = alias };
}

pub fn createDefaultAliasForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createDefaultAliasForGuidInRoot(allocator, root, guid);
}

pub fn createDefaultAliasForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    var hex_len: usize = default_alias_hex_len;
    while (hex_len <= compact_guid_len) : (hex_len += 1) {
        const alias = try defaultAliasForGuidLen(allocator, guid, hex_len);
        errdefer allocator.free(alias);
        ensureAliasForGuidInRoot(allocator, root, alias, guid) catch |err| switch (err) {
            error.AliasExists => {
                allocator.free(alias);
                continue;
            },
            else => return err,
        };
        return alias;
    }
    return error.DefaultAliasExhausted;
}

fn availableDefaultAliasForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    var hex_len: usize = default_alias_hex_len;
    while (hex_len <= compact_guid_len) : (hex_len += 1) {
        const alias = try defaultAliasForGuidLen(allocator, guid, hex_len);
        errdefer allocator.free(alias);
        if (try aliasAvailableForGuidInRoot(allocator, root, alias, guid)) return alias;
        allocator.free(alias);
    }
    return error.DefaultAliasExhausted;
}

fn generateGuidWithDefaultAliasFromCandidatesInRoot(allocator: std.mem.Allocator, root: []const u8, candidates: []const []const u8) !GeneratedIdentity {
    for (candidates) |candidate| {
        const guid = try canonicalGuid(allocator, candidate);
        errdefer allocator.free(guid);
        const alias = try availableDefaultAliasForGuidInRoot(allocator, root, guid);
        return .{ .guid = guid, .alias = alias };
    }
    return error.DefaultAliasExhausted;
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
    session_dir: []const u8,
    host: []const u8,
    agent_version: []const u8,
    ssh_options: []const []const u8,
    last_known_alive: bool,

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
    session_dir: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    agent_version: []const u8,
) !void {
    return writeRoute(allocator, guid, primary_alias, session_dir, host, ssh_options, .{ .agent_version = agent_version });
}

pub fn writeLocalRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    primary_alias: []const u8,
    session_dir: []const u8,
    agent_version: []const u8,
) !void {
    return writeRoute(allocator, guid, primary_alias, session_dir, ".", &.{}, .{ .agent_version = agent_version });
}

const RouteStatus = struct {
    last_known_alive: bool = true,
    agent_version: []const u8 = "",
};

fn writeRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    primary_alias: []const u8,
    session_dir: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    status: RouteStatus,
) !void {
    if (!isAbsolutePath(session_dir)) return error.InvalidSessionDir;
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writeRouteField(writer, "guid", canonical);
    try writeRouteField(writer, "primary_alias", primary_alias);
    try writeRouteField(writer, "session_dir", session_dir);
    try writeRouteField(writer, "host", host);
    try writeRouteField(writer, "agent_version", status.agent_version);
    try writer.print("alive={s}\n", .{if (status.last_known_alive) "1" else "0"});
    for (ssh_options) |arg| {
        try writeRouteField(writer, "ssh_option", arg);
    }

    const route_path = try routePathForGuid(allocator, canonical);
    defer allocator.free(route_path);
    try ensureRouteDirForGuid(allocator, canonical);

    const file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(text.items);
}

pub fn updateRouteStatus(allocator: std.mem.Allocator, guid: []const u8, last_known_alive: bool, agent_version: ?[]const u8) !void {
    var route = try readRouteForRef(allocator, guid);
    defer route.deinit(allocator);
    try writeRoute(
        allocator,
        route.guid,
        route.primary_alias,
        route.session_dir,
        route.host,
        route.ssh_options,
        .{
            .last_known_alive = last_known_alive,
            .agent_version = agent_version orelse route.agent_version,
        },
    );
}

pub fn readRouteForRef(allocator: std.mem.Allocator, ref: []const u8) !Route {
    var paths = try pathsForRef(allocator, ref);
    defer paths.deinit(allocator);
    return readRoute(allocator, paths.route);
}

fn routePathForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    return routePathForGuidInStateRoot(allocator, state_root, canonical);
}

fn routePathForGuidInStateRoot(allocator: std.mem.Allocator, state_root: []const u8, guid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/guid/{s}/route", .{ state_root, guid });
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
    errdefer allocator.free(bytes);

    var guid: ?[]const u8 = null;
    var primary_alias: ?[]const u8 = null;
    var session_dir: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var agent_version: []const u8 = "";
    var last_known_alive = true;
    var option_count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "guid")) {
            if (!isValidSessionGuid(value)) return error.InvalidRoute;
            guid = value;
        } else if (std.mem.eql(u8, key, "primary_alias")) {
            if (!isValidAlias(value)) return error.InvalidRoute;
            primary_alias = value;
        } else if (std.mem.eql(u8, key, "session_dir")) {
            session_dir = value;
        } else if (std.mem.eql(u8, key, "host")) {
            host = value;
        } else if (std.mem.eql(u8, key, "agent_version")) {
            agent_version = value;
        } else if (std.mem.eql(u8, key, "alive")) {
            last_known_alive = try parseRouteAlive(value);
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
            options[option_index] = value;
            option_index += 1;
        }
    }

    const plain_session_dir = session_dir orelse "";
    if (plain_session_dir.len > 0 and !isAbsolutePath(plain_session_dir)) return error.InvalidRoute;
    const plain_host = host orelse "";

    return .{
        .bytes = bytes,
        .guid = guid orelse return error.InvalidRoute,
        .primary_alias = primary_alias orelse return error.InvalidRoute,
        .session_dir = plain_session_dir,
        .host = plain_host,
        .agent_version = agent_version,
        .ssh_options = options,
        .last_known_alive = last_known_alive,
    };
}

fn writeRouteField(writer: anytype, key: []const u8, value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidRouteValue;
    try writer.print("{s}={s}\n", .{ key, value });
}

fn parseRouteAlive(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no")) return false;
    return error.InvalidRoute;
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

    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, alias });
    defer allocator.free(link_path);
    const target = try std.fmt.allocPrint(allocator, "../guid/{s}", .{canonical});
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

pub fn aliasAvailableForGuid(allocator: std.mem.Allocator, alias: []const u8, guid: []const u8) !bool {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return aliasAvailableForGuidInRoot(allocator, root, alias, guid);
}

pub fn aliasAvailableForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8, guid: []const u8) !bool {
    const existing = resolveRefToGuidInRoot(allocator, root, alias) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer allocator.free(existing);
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    return std.mem.eql(u8, existing, canonical);
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
    return defaultAliasForGuidLen(allocator, guid, default_alias_hex_len);
}

fn defaultAliasForGuidLen(allocator: std.mem.Allocator, guid: []const u8, hex_len: usize) ![]u8 {
    if (hex_len < default_alias_hex_len or hex_len > compact_guid_len) return error.InvalidAliasLength;
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    const compact = try compactGuid(allocator, canonical);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "s-{s}", .{compact[0..hex_len]});
}

pub fn createGeneratedRemoteAlias(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createGeneratedRemoteAliasInRoot(allocator, root, guid);
}

pub fn createGeneratedRemoteAliasInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    var alias_hex_len: usize = 8;
    while (alias_hex_len <= compact_guid_len) : (alias_hex_len += 1) {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const alias = try std.fmt.allocPrint(allocator, "a-{s}", .{hex[0..alias_hex_len]});
        errdefer allocator.free(alias);
        if (try createAliasCandidateInRoot(allocator, root, alias, guid)) return alias;
        allocator.free(alias);
    }
    return error.GeneratedAliasExhausted;
}

fn createGeneratedAliasFromHexCandidatesInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8, candidates: []const []const u8) ![]u8 {
    var alias_hex_len: usize = 8;
    for (candidates) |candidate| {
        if (candidate.len < alias_hex_len) return error.InvalidAliasLength;
        const alias = try std.fmt.allocPrint(allocator, "a-{s}", .{candidate[0..alias_hex_len]});
        errdefer allocator.free(alias);
        if (try createAliasCandidateInRoot(allocator, root, alias, guid)) return alias;
        allocator.free(alias);
        alias_hex_len += 1;
        if (alias_hex_len > compact_guid_len) break;
    }
    return error.GeneratedAliasExhausted;
}

fn createAliasCandidateInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8, guid: []const u8) !bool {
    createAliasInRoot(allocator, root, alias, guid) catch |err| switch (err) {
        error.AliasExists => return false,
        else => return err,
    };
    return true;
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

    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (!isValidAlias(entry.name)) continue;
        const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, entry.name });
        defer allocator.free(link_path);
        const target = readLinkAlloc(allocator, link_path, 4096) catch continue;
        defer allocator.free(target);
        const target_guid = canonicalGuid(allocator, std.fs.path.basename(target)) catch continue;
        defer allocator.free(target_guid);
        if (std.mem.eql(u8, target_guid, canonical)) {
            return try allocator.dupe(u8, entry.name);
        }
    }
    return null;
}

pub fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > 128) return false;
    if (std.mem.eql(u8, alias, ".") or std.mem.eql(u8, alias, "..")) return false;
    if (alias[0] == '-') return false;
    if (isValidGuidBody(alias) or
        isValidGuid(alias) or
        isValidCompactGuid(alias) or
        isReservedGuidLikeAlias(alias)) return false;
    if (alias.len >= 2 and alias[1] == '-' and !isValidGeneratedAlias(alias)) return false;
    for (alias) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        }
    }
    return true;
}

pub fn isValidCustomAlias(alias: []const u8) bool {
    if (!isValidAlias(alias)) return false;
    if (alias[0] == '-') return false;
    if (alias.len >= 2 and alias[1] == '-') return false;
    return true;
}

fn isValidGeneratedAlias(alias: []const u8) bool {
    if (std.mem.startsWith(u8, alias, "s-")) {
        if (alias.len < 2 + default_alias_hex_len or alias.len > 2 + compact_guid_len) return false;
    } else if (std.mem.startsWith(u8, alias, "a-")) {
        if (alias.len < 10 or alias.len > 2 + compact_guid_len) return false;
    } else {
        return false;
    }
    for (alias[2..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isReservedGuidLikeAlias(alias: []const u8) bool {
    if (alias.len < 3) return false;
    if (!std.ascii.isAlphabetic(alias[0]) or alias[1] != '-') return false;
    const body = alias[2..];
    return isValidGuidBody(body) or isValidCompactGuid(body);
}

fn isAbsolutePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/");
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

const SocketPathAllocation = struct {
    name: []u8,
    path: []u8,

    fn deinit(self: *SocketPathAllocation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

fn allocateSocketPathForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) !SocketPathAllocation {
    const socket_dir = try sessionSocketsDirInRoot(allocator, root);
    defer allocator.free(socket_dir);

    const compact = try compactGuid(allocator, guid);
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

fn agentSocketLinkPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/agent.sock", .{dir});
}

fn installAgentSocketLink(allocator: std.mem.Allocator, link_path: []const u8, socket_name: []const u8) !void {
    const target = try std.fmt.allocPrint(allocator, "../../s/{s}", .{socket_name});
    defer allocator.free(target);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ link_path, c.getpid() });
    defer allocator.free(tmp_path);

    std.fs.cwd().deleteFile(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    const tmp_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(tmp_z);
    switch (posix.errno(c.symlink(target_z.ptr, tmp_z.ptr))) {
        .SUCCESS => {},
        .EXIST => return error.SymlinkFailed,
        else => return error.SymlinkFailed,
    }

    const link_z = try allocator.dupeZ(u8, link_path);
    defer allocator.free(link_z);
    switch (posix.errno(c.rename(tmp_z.ptr, link_z.ptr))) {
        .SUCCESS => return,
        else => return error.RenameFailed,
    }
}

fn socketPathFromAgentSocketLink(allocator: std.mem.Allocator, dir: []const u8, link_path: []const u8) ![]u8 {
    const target = try readLinkAlloc(allocator, link_path, 4096);
    defer allocator.free(target);
    if (isAbsolutePath(target)) return allocator.dupe(u8, target);
    if (std.mem.startsWith(u8, target, "../../s/")) {
        const guid_dir = std.fs.path.dirname(dir) orelse return error.InvalidSessionDir;
        const root = std.fs.path.dirname(guid_dir) orelse return error.InvalidSessionDir;
        return std.fmt.allocPrint(allocator, "{s}/s/{s}", .{ root, target["../../s/".len..] });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target });
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
    try unlinkIfExists(paths.agent_sock_link);
    try unlinkIfExists(paths.compat);
}

/// Clean shutdown removes live discovery hints while preserving the session
/// directory as the id tombstone.
pub fn removeEndedHints(paths: SessionPaths) !void {
    try unlinkIfExists(paths.socket);
    try unlinkIfExists(paths.agent_sock_link);
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

test "session paths use guid session directories and separate socket directory" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    var allocation = try allocateSessionDirForGuidInRoot(allocator, root, guid);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", allocation.id);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000", allocation.paths.dir);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/s/550e8400e29b41d4a716446655440000", allocation.paths.socket);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/agent.sock", allocation.paths.agent_sock_link);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/meta", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/detached", allocation.paths.detached);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/compat", allocation.paths.compat);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/route", allocation.paths.route);

    const link_target = try readLinkAlloc(allocator, allocation.paths.agent_sock_link, 4096);
    defer allocator.free(link_target);
    try std.testing.expectEqualStrings("../../s/550e8400e29b41d4a716446655440000", link_target);
}

test "long runtime roots use random socket names when compact guid does not fit" {
    const allocator = std.testing.allocator;
    const prefix = "zig-cache/session-registry-long-root-";
    const root_len = maxUnixSocketPathLen() - "/s/".len - 16;
    try std.testing.expect(root_len > prefix.len);

    const root = try allocator.alloc(u8, root_len);
    defer allocator.free(root);
    @memcpy(root[0..prefix.len], prefix);
    @memset(root[prefix.len..], 'x');

    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    var allocation = try allocateSessionDirForGuidInRoot(allocator, root, guid);
    defer allocation.deinit(allocator);

    try std.testing.expectEqualStrings(guid, allocation.id);
    try std.testing.expectEqualStrings(root, allocation.paths.dir[0..root.len]);
    try std.testing.expect(std.mem.endsWith(u8, allocation.paths.dir, "/guid/s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(allocation.paths.socket.len <= maxUnixSocketPathLen());
    const socket_name = std.fs.path.basename(allocation.paths.socket);
    try std.testing.expectEqual(@as(usize, 16), socket_name.len);
    try std.testing.expect(!std.mem.eql(u8, socket_name, "550e8400e29b41d4a716446655440000"));

    const link_target = try readLinkAlloc(allocator, allocation.paths.agent_sock_link, 4096);
    defer allocator.free(link_target);
    const expected_target = try std.fmt.allocPrint(allocator, "../../s/{s}", .{socket_name});
    defer allocator.free(expected_target);
    try std.testing.expectEqualStrings(expected_target, link_target);
}

test "validates session ids and aliases" {
    try std.testing.expect(isValidSessionId("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidSessionId("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(isValidSessionGuid("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidClientGuid("c-550e8400-e29b-41d4-a716-446655440000"));
    const generated_client = try generateClientGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_client);
    try std.testing.expect(isValidClientGuid(generated_client));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId("c-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("s1"));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-44665544000z"));
    try std.testing.expect(isValidAlias("s1"));
    try std.testing.expect(isValidAlias("my-awesome-session"));
    try std.testing.expect(isValidAlias("s-550e"));
    try std.testing.expect(isValidAlias("s-550e8"));
    try std.testing.expect(isValidAlias("s-550e8400"));
    try std.testing.expect(isValidAlias("a-550e8400"));
    try std.testing.expect(isValidAlias("a-550e8400a"));
    try std.testing.expect(!isValidAlias("s-not-hex"));
    try std.testing.expect(!isValidAlias("a-not-hex"));
    try std.testing.expect(!isValidAlias("x-anything"));
    try std.testing.expect(isValidCustomAlias("s1"));
    try std.testing.expect(isValidCustomAlias("my-awesome-session"));
    try std.testing.expect(!isValidCustomAlias("-bad"));
    try std.testing.expect(!isValidCustomAlias("s-550e"));
    try std.testing.expect(!isValidCustomAlias("a-550e8400"));
    try std.testing.expect(!isValidCustomAlias("x-anything"));
    try std.testing.expect(!isValidAlias("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidAlias("c-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidAlias("x-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidAlias("x-550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!isValidAlias("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidAlias("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!isValidAlias("-bad"));
    try std.testing.expect(!isValidAlias("bad/name"));

    const default_alias = try defaultAliasForGuid(std.testing.allocator, "s-550e8400-e29b-41d4-a716-446655440000");
    defer std.testing.allocator.free(default_alias);
    try std.testing.expectEqualStrings("s-550e", default_alias);
    try std.testing.expect(isValidAlias(default_alias));
    try std.testing.expect(!isValidCustomAlias(default_alias));
}

test "default alias availability detects short alias collisions" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-default-alias-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const first_guid = "s-550e0000-e29b-41d4-a716-446655440000";
    const second_guid = "s-550e1111-e29b-41d4-a716-446655440000";
    const alias = try defaultAliasForGuid(allocator, first_guid);
    defer allocator.free(alias);
    try std.testing.expectEqualStrings("s-550e", alias);
    try createAliasInRoot(allocator, root, alias, first_guid);

    try std.testing.expect(try aliasAvailableForGuidInRoot(allocator, root, alias, first_guid));
    try std.testing.expect(!try aliasAvailableForGuidInRoot(allocator, root, alias, second_guid));
}

test "guid default alias generation retries colliding short prefixes" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-default-alias-retry-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const existing_guid = "s-550e0000-e29b-41d4-a716-446655440000";
    try createAliasInRoot(allocator, root, "s-550e", existing_guid);
    try createAliasInRoot(allocator, root, "s-550e1", existing_guid);

    var identity = try generateGuidWithDefaultAliasFromCandidatesInRoot(allocator, root, &.{
        "s-550e1111-e29b-41d4-a716-446655440000",
    });
    defer identity.deinit(allocator);

    try std.testing.expectEqualStrings("s-550e1111-e29b-41d4-a716-446655440000", identity.guid);
    try std.testing.expectEqualStrings("s-550e11", identity.alias);
}

test "random generated aliases retry collisions" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-generated-alias-retry-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const existing_guid = "s-11110000-e29b-41d4-a716-446655440000";
    const new_guid = "s-22220000-e29b-41d4-a716-446655440000";
    try createAliasInRoot(allocator, root, "a-deadbeef", existing_guid);

    const alias = try createGeneratedAliasFromHexCandidatesInRoot(allocator, root, new_guid, &.{
        "deadbeef000000000000000000000000",
        "feed1234500000000000000000000000",
    });
    defer allocator.free(alias);

    try std.testing.expectEqualStrings("a-feed12345", alias);
    const resolved = try resolveRefToGuidInRoot(allocator, root, alias);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(new_guid, resolved);
}

test "route files persist absolute session directories" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/sessh-route-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);

    const route_path = try std.fmt.allocPrint(allocator, "{s}/route", .{root});
    defer allocator.free(route_path);
    const session_dir = "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000";

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.writeAll("guid=s-550e8400-e29b-41d4-a716-446655440000\n");
    try writer.writeAll("primary_alias=s-550e\n");
    try writer.writeAll("session_dir=");
    try writer.writeAll(session_dir);
    try writer.writeAll("\n");
    try writer.writeAll("host=work.example\n");
    try writer.writeAll("agent_version=0.5.0-test\n");
    try writer.writeAll("ssh_option=-F\n");

    const file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(text.items);
    file.close();

    var route = try readRoute(allocator, route_path);
    defer route.deinit(allocator);
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", route.guid);
    try std.testing.expectEqualStrings("s-550e", route.primary_alias);
    try std.testing.expectEqualStrings(session_dir, route.session_dir);
    try std.testing.expectEqualStrings("work.example", route.host);
    try std.testing.expectEqualStrings("0.5.0-test", route.agent_version);
    try std.testing.expect(route.last_known_alive);
    try std.testing.expectEqual(@as(usize, 1), route.ssh_options.len);
    try std.testing.expectEqualStrings("-F", route.ssh_options[0]);
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
