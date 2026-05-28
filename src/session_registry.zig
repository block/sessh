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
pub const generated_alias_hex_len = 8;
pub const generated_alias_len = session_guid_prefix.len + generated_alias_hex_len;
pub const tombstone_retention_ms: u64 = 7 * 24 * 60 * 60 * 1000;

pub const SessionPaths = struct {
    dir: []u8,
    socket: []u8,
    agent_sock_link: []u8,
    meta: []u8,
    compat: []u8,
    route: []u8,

    pub fn deinit(self: *SessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.route);
        allocator.free(self.compat);
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
            if (runtimeHintsExist(existing_paths)) return error.SessionExists;
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

pub fn sessionSocketsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/s", .{root});
}

pub fn ensureRuntimeLayout(allocator: std.mem.Allocator, paths: SessionPaths) !void {
    const sessions_dir = std.fs.path.dirname(paths.dir) orelse return error.InvalidSessionDir;
    const runtime_root = std.fs.path.dirname(sessions_dir) orelse return error.InvalidSessionDir;
    try ensureRegistryRoot(allocator, runtime_root);
    try mkdirIgnoreExists(allocator, sessions_dir);

    const socket_dir = std.fs.path.dirname(paths.socket) orelse return error.InvalidSocketPath;
    try mkdirIgnoreExists(allocator, socket_dir);
    try mkdirIgnoreExists(allocator, paths.dir);

    try ensureAgentSocketLinkForSocketPath(allocator, paths.agent_sock_link, paths.socket);
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
        .socket = socket_copy,
        .agent_sock_link = agent_sock_link,
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

pub fn isValidSessionRef(ref: []const u8) bool {
    return isValidSessionId(ref) or isValidSessionGuidPrefix(ref) or isValidAlias(ref);
}

pub fn isValidSessionGuidPrefix(ref: []const u8) bool {
    return compactGuidPrefix(ref, session_guid_prefix) != null;
}

pub fn isValidClientGuidPrefix(ref: []const u8) bool {
    return compactGuidPrefix(ref, client_guid_prefix) != null;
}

const CompactGuidPrefix = struct {
    bytes: [compact_guid_len]u8 = [_]u8{0} ** compact_guid_len,
    len: usize = 0,

    fn slice(self: *const CompactGuidPrefix) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn compactGuidPrefix(ref: []const u8, prefix: []const u8) ?CompactGuidPrefix {
    if (!std.mem.startsWith(u8, ref, prefix)) return null;
    const body = ref[prefix.len..];
    if (body.len == 0) return null;
    if (body.len <= compact_guid_len) {
        var out = CompactGuidPrefix{};
        for (body) |byte| {
            if (!std.ascii.isHex(byte)) {
                out.len = 0;
                break;
            }
            out.bytes[out.len] = std.ascii.toLower(byte);
            out.len += 1;
        }
        if (out.len == body.len) return out;
    }

    if (body.len >= guid_body_len) return null;
    var out = CompactGuidPrefix{};
    for (body, 0..) |byte, i| {
        switch (i) {
            8, 13, 18, 23 => {
                if (byte != '-') return null;
            },
            else => {
                if (!std.ascii.isHex(byte)) return null;
                out.bytes[out.len] = std.ascii.toLower(byte);
                out.len += 1;
            },
        }
    }
    if (out.len == 0) return null;
    return out;
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

pub fn compactClientGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidClientGuid(guid)) return error.InvalidClientId;
    var out = try allocator.alloc(u8, compact_guid_len);
    var dst: usize = 0;
    for (guid[client_guid_prefix.len..]) |byte| {
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
    var attempts: usize = 0;
    while (attempts < 4096) : (attempts += 1) {
        const guid = try generateGuid(allocator);
        errdefer allocator.free(guid);
        const alias = availableDefaultAliasForGuidInRoot(allocator, root, guid) catch |err| switch (err) {
            error.AliasExists => {
                allocator.free(guid);
                continue;
            },
            else => return err,
        };
        return .{ .guid = guid, .alias = alias };
    }
    return error.DefaultAliasExhausted;
}

pub fn createDefaultAliasForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createDefaultAliasForGuidInRoot(allocator, root, guid);
}

pub fn createDefaultAliasForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    const alias = try defaultAliasForGuid(allocator, guid);
    errdefer allocator.free(alias);
    try ensureAliasForGuidInRoot(allocator, root, alias, guid);
    return alias;
}

fn availableDefaultAliasForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    const alias = try defaultAliasForGuid(allocator, guid);
    errdefer allocator.free(alias);
    if (try aliasAvailableForGuidInRoot(allocator, root, alias, guid)) return alias;
    return error.AliasExists;
}

fn generateGuidWithDefaultAliasFromCandidatesInRoot(allocator: std.mem.Allocator, root: []const u8, candidates: []const []const u8) !GeneratedIdentity {
    for (candidates) |candidate| {
        const guid = try canonicalGuid(allocator, candidate);
        errdefer allocator.free(guid);
        const alias = availableDefaultAliasForGuidInRoot(allocator, root, guid) catch |err| switch (err) {
            error.AliasExists => {
                allocator.free(guid);
                continue;
            },
            else => return err,
        };
        return .{ .guid = guid, .alias = alias };
    }
    return error.DefaultAliasExhausted;
}

pub const Meta = struct {
    agent_pid: c.pid_t,
    version: []u8,

    pub fn deinit(self: *Meta, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        self.* = undefined;
    }
};

pub fn writeMeta(paths: SessionPaths, agent_pid: c.pid_t, version: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app_allocator.allocator());
    const writer = text.writer(app_allocator.allocator());
    try writer.print("{{\"agent_pid\":{},\"version\":{f}}}\n", .{ agent_pid, std.json.fmt(version, .{}) });
    try writeAtomicFile(paths.meta, text.items);
}

pub fn readMeta(allocator: std.mem.Allocator, paths: SessionPaths) !Meta {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, paths.meta, 4096);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);
    const pid_value = object.get("agent_pid") orelse return error.InvalidSessionMeta;
    const agent_pid = try jsonPid(pid_value);
    const version = try allocator.dupe(u8, try jsonRequiredString(object, "version"));
    errdefer allocator.free(version);
    return .{
        .agent_pid = agent_pid,
        .version = version,
    };
}

pub const Route = struct {
    guid: []u8,
    primary_alias: []u8,
    session_dir: []u8,
    host: []u8,
    agent_version: []u8,
    ssh_options: []const []const u8,
    last_known_alive: bool,
    attached_count: ?u32,
    last_input_at_unix_ms: ?u64,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.ssh_options) |option| allocator.free(option);
        allocator.free(self.ssh_options);
        allocator.free(self.agent_version);
        allocator.free(self.host);
        allocator.free(self.session_dir);
        allocator.free(self.primary_alias);
        allocator.free(self.guid);
        self.* = undefined;
    }
};

pub const TombstoneEndReason = enum {
    unknown,
    process_exited,
    killed_by_request,
    agent_shutdown,
};

pub const TombstoneExitStatusKind = enum {
    exited,
    signalled,
};

pub const TombstoneExitStatus = struct {
    kind: TombstoneExitStatusKind,
    status: i32,
};

pub const TombstoneDetails = struct {
    ended_at_unix_ms: u64,
    end_reason: TombstoneEndReason = .unknown,
    exit_status: ?TombstoneExitStatus = null,
};

pub const Tombstone = struct {
    guid: []u8,
    primary_alias: []u8,
    aliases: []const []const u8,
    session_dir: []u8,
    host: []u8,
    agent_version: []u8,
    ended_at_unix_ms: u64,
    end_reason: TombstoneEndReason,
    exit_status: ?TombstoneExitStatus,

    pub fn deinit(self: *Tombstone, allocator: std.mem.Allocator) void {
        freeStringArray(allocator, self.aliases);
        allocator.free(self.agent_version);
        allocator.free(self.host);
        allocator.free(self.session_dir);
        allocator.free(self.primary_alias);
        allocator.free(self.guid);
        self.* = undefined;
    }
};

pub fn tombstoneEndReasonName(reason: TombstoneEndReason) []const u8 {
    return switch (reason) {
        .unknown => "unknown",
        .process_exited => "process_exited",
        .killed_by_request => "killed_by_request",
        .agent_shutdown => "agent_shutdown",
    };
}

pub fn tombstoneEndReasonFromName(value: []const u8) !TombstoneEndReason {
    if (std.mem.eql(u8, value, "unknown")) return .unknown;
    if (std.mem.eql(u8, value, "process_exited")) return .process_exited;
    if (std.mem.eql(u8, value, "killed_by_request")) return .killed_by_request;
    if (std.mem.eql(u8, value, "agent_shutdown")) return .agent_shutdown;
    return error.InvalidTombstone;
}

pub fn tombstoneExitStatusKindName(kind: TombstoneExitStatusKind) []const u8 {
    return switch (kind) {
        .exited => "exited",
        .signalled => "signalled",
    };
}

pub fn tombstoneExitStatusKindFromName(value: []const u8) !TombstoneExitStatusKind {
    if (std.mem.eql(u8, value, "exited")) return .exited;
    if (std.mem.eql(u8, value, "signalled")) return .signalled;
    return error.InvalidTombstone;
}

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
    attached_count: ?u32 = null,
    last_input_at_unix_ms: ?u64 = null,
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
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);
    const tombstone_path = try tombstonePathForGuidInRoot(allocator, state_root, canonical);
    defer allocator.free(tombstone_path);
    if (try pathExists(tombstone_path)) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.print(
        "{{\"guid\":{f},\"primary_alias\":{f},\"session_dir\":{f},\"host\":{f},\"agent_version\":{f},\"alive\":{},\"attached_count\":",
        .{
            std.json.fmt(canonical, .{}),
            std.json.fmt(primary_alias, .{}),
            std.json.fmt(session_dir, .{}),
            std.json.fmt(host, .{}),
            std.json.fmt(status.agent_version, .{}),
            status.last_known_alive,
        },
    );
    if (status.attached_count) |count| {
        try writer.print("{}", .{count});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"last_input_at_unix_ms\":");
    if (status.last_input_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"ssh_options\":[");
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

pub const RouteLiveStatus = struct {
    attached_count: ?u32 = null,
    last_input_at_unix_ms: ?u64 = null,
};

pub fn updateRouteStatus(allocator: std.mem.Allocator, guid: []const u8, last_known_alive: bool, agent_version: ?[]const u8, live_status: ?RouteLiveStatus) !void {
    var route = try readRouteForRef(allocator, guid);
    defer route.deinit(allocator);
    const live: RouteLiveStatus = live_status orelse .{
        .attached_count = route.attached_count,
        .last_input_at_unix_ms = route.last_input_at_unix_ms,
    };
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
            .attached_count = live.attached_count,
            .last_input_at_unix_ms = live.last_input_at_unix_ms,
        },
    );
}

pub fn writeTombstoneForRoute(allocator: std.mem.Allocator, route: *const Route, details: TombstoneDetails) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return writeTombstoneForRouteInRoot(allocator, root, route, details);
}

fn writeTombstoneForRouteInRoot(allocator: std.mem.Allocator, root: []const u8, route: *const Route, details: TombstoneDetails) !void {
    const canonical = try canonicalGuid(allocator, route.guid);
    defer allocator.free(canonical);

    const aliases = try aliasesForGuidInRoot(allocator, root, canonical);
    defer freeStringArray(allocator, aliases);

    try ensureTombstoneDir(allocator, root);
    const path = try tombstonePathForGuidInRoot(allocator, root, canonical);
    defer allocator.free(path);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.print(
        "{{\"guid\":{f},\"primary_alias\":{f},\"aliases\":[",
        .{
            std.json.fmt(canonical, .{}),
            std.json.fmt(route.primary_alias, .{}),
        },
    );
    for (aliases, 0..) |alias, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{f}", .{std.json.fmt(alias, .{})});
    }
    try writer.print(
        "],\"session_dir\":{f},\"host\":{f},\"agent_version\":{f},\"ended_at_unix_ms\":{},\"end_reason\":{f},\"exit_status\":",
        .{
            std.json.fmt(route.session_dir, .{}),
            std.json.fmt(route.host, .{}),
            std.json.fmt(route.agent_version, .{}),
            details.ended_at_unix_ms,
            std.json.fmt(tombstoneEndReasonName(details.end_reason), .{}),
        },
    );
    if (details.exit_status) |status| {
        try writer.print(
            "{{\"kind\":{f},\"status\":{}}}",
            .{ std.json.fmt(tombstoneExitStatusKindName(status.kind), .{}), status.status },
        );
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");

    try writeAtomicFile(path, text.items);

    const route_path = try routePathForGuidInStateRoot(allocator, root, canonical);
    defer allocator.free(route_path);
    try unlinkIfExists(route_path);
    try removeAliasesForGuidInRoot(allocator, root, canonical, aliases);
}

pub fn readTombstoneForRef(allocator: std.mem.Allocator, ref: []const u8) !Tombstone {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    const guid = try resolveTombstoneRefToGuidInRoot(allocator, root, ref);
    defer allocator.free(guid);
    const path = try tombstonePathForGuidInRoot(allocator, root, guid);
    defer allocator.free(path);
    return readTombstone(allocator, path);
}

pub fn tombstoneExistsForRef(allocator: std.mem.Allocator, ref: []const u8) bool {
    var tombstone = readTombstoneForRef(allocator, ref) catch return false;
    tombstone.deinit(allocator);
    return true;
}

pub fn readTombstone(allocator: std.mem.Allocator, path: []const u8) !Tombstone {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);

    const guid_value = try jsonRequiredString(object, "guid");
    if (!isValidSessionGuid(guid_value)) return error.InvalidTombstone;
    const guid = try allocator.dupe(u8, guid_value);
    errdefer allocator.free(guid);

    const primary_alias_value = jsonOptionalString(object, "primary_alias") orelse "";
    if (primary_alias_value.len > 0 and !isValidAlias(primary_alias_value)) return error.InvalidTombstone;
    const primary_alias = try allocator.dupe(u8, primary_alias_value);
    errdefer allocator.free(primary_alias);

    const aliases = try jsonStringArrayField(allocator, object, "aliases");
    errdefer freeStringArray(allocator, aliases);
    for (aliases) |alias| {
        if (!isValidAlias(alias)) return error.InvalidTombstone;
    }

    const session_dir_value = jsonOptionalString(object, "session_dir") orelse "";
    if (session_dir_value.len > 0 and !isAbsolutePath(session_dir_value)) return error.InvalidTombstone;
    const session_dir = try allocator.dupe(u8, session_dir_value);
    errdefer allocator.free(session_dir);

    const host = try allocator.dupe(u8, jsonOptionalString(object, "host") orelse "");
    errdefer allocator.free(host);

    const agent_version = try allocator.dupe(u8, jsonOptionalString(object, "agent_version") orelse "");
    errdefer allocator.free(agent_version);

    const ended_at_unix_ms = try jsonRequiredU64(object, "ended_at_unix_ms");
    const end_reason = try tombstoneEndReasonFromName(jsonOptionalString(object, "end_reason") orelse "unknown");
    const exit_status = try jsonOptionalTombstoneExitStatus(object, "exit_status");

    return .{
        .guid = guid,
        .primary_alias = primary_alias,
        .aliases = aliases,
        .session_dir = session_dir,
        .host = host,
        .agent_version = agent_version,
        .ended_at_unix_ms = ended_at_unix_ms,
        .end_reason = end_reason,
        .exit_status = exit_status,
    };
}

pub fn cleanupExpiredTombstones(allocator: std.mem.Allocator, now_ms: u64) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return cleanupExpiredTombstonesInRoot(allocator, root, now_ms);
}

fn cleanupExpiredTombstonesInRoot(allocator: std.mem.Allocator, root: []const u8, now_ms: u64) !void {
    const dir_path = try tombstonesDirInRoot(allocator, root);
    defer allocator.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const guid = tombstoneGuidFromFilename(allocator, entry.name) catch continue;
        defer allocator.free(guid);
        const path = try tombstonePathForGuidInRoot(allocator, root, guid);
        defer allocator.free(path);
        var tombstone = readTombstone(allocator, path) catch continue;
        defer tombstone.deinit(allocator);
        if (now_ms < tombstone.ended_at_unix_ms or now_ms - tombstone.ended_at_unix_ms < tombstone_retention_ms) continue;
        try removeRecordedAliasesForTombstoneInRoot(allocator, root, &tombstone);
        try unlinkIfExists(path);
    }
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
    return std.fmt.allocPrint(allocator, "{s}/guid/{s}/route.json", .{ state_root, guid });
}

pub fn tombstonesDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return tombstonesDirInRoot(allocator, root);
}

fn tombstonesDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tombstone", .{root});
}

fn tombstonePathForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    return std.fmt.allocPrint(allocator, "{s}/tombstone/{s}.json", .{ root, canonical });
}

fn ensureTombstoneDir(allocator: std.mem.Allocator, root: []const u8) !void {
    try ensureRegistryRoot(allocator, root);
    const dir = try tombstonesDirInRoot(allocator, root);
    defer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);
}

fn tombstoneGuidFromFilename(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, filename, ".json")) return error.InvalidTombstone;
    const guid = filename[0 .. filename.len - ".json".len];
    if (!isValidSessionGuid(guid)) return error.InvalidTombstone;
    return allocator.dupe(u8, guid);
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

fn resolveTombstoneRefToGuidInRoot(allocator: std.mem.Allocator, root: []const u8, ref: []const u8) ![]u8 {
    if (isValidSessionId(ref)) return canonicalGuid(allocator, ref);
    if (isValidAlias(ref)) {
        return resolveAliasToGuidInRoot(allocator, root, ref) catch |err| switch (err) {
            error.FileNotFound => {
                return findTombstoneGuidForAliasInRoot(allocator, root, ref) catch |alias_err| switch (alias_err) {
                    error.FileNotFound => {
                        if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
                            return resolveTombstoneGuidPrefixInRoot(allocator, root, prefix.slice());
                        }
                        return err;
                    },
                    else => return alias_err,
                };
            },
            else => return err,
        };
    }
    if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
        return resolveTombstoneGuidPrefixInRoot(allocator, root, prefix.slice());
    }
    return error.InvalidSessionId;
}

fn findTombstoneGuidForAliasInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8) ![]u8 {
    const dir_path = try tombstonesDirInRoot(allocator, root);
    defer allocator.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();

    var match: ?[]u8 = null;
    errdefer if (match) |guid| allocator.free(guid);
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(path);
        var tombstone = readTombstone(allocator, path) catch continue;
        defer tombstone.deinit(allocator);
        for (tombstone.aliases) |candidate| {
            if (!std.mem.eql(u8, candidate, alias)) continue;
            if (match != null) return error.AmbiguousSessionId;
            match = try allocator.dupe(u8, tombstone.guid);
            break;
        }
    }
    return match orelse error.FileNotFound;
}

fn resolveTombstoneGuidPrefixInRoot(allocator: std.mem.Allocator, root: []const u8, prefix: []const u8) ![]u8 {
    const dir_path = try tombstonesDirInRoot(allocator, root);
    defer allocator.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();

    var match: ?[]u8 = null;
    errdefer if (match) |guid| allocator.free(guid);
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const guid = tombstoneGuidFromFilename(allocator, entry.name) catch continue;
        defer allocator.free(guid);
        const compact = try compactGuid(allocator, guid);
        defer allocator.free(compact);
        if (!std.mem.startsWith(u8, compact, prefix)) continue;
        if (match != null) return error.AmbiguousSessionId;
        match = try allocator.dupe(u8, guid);
    }
    return match orelse error.FileNotFound;
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

    const primary_alias_value = try jsonRequiredString(object, "primary_alias");
    if (!isValidAlias(primary_alias_value)) return error.InvalidRoute;
    const primary_alias = try allocator.dupe(u8, primary_alias_value);
    errdefer allocator.free(primary_alias);

    const session_dir_value = jsonOptionalString(object, "session_dir") orelse "";
    if (session_dir_value.len > 0 and !isAbsolutePath(session_dir_value)) return error.InvalidRoute;
    const session_dir = try allocator.dupe(u8, session_dir_value);
    errdefer allocator.free(session_dir);

    const host = try allocator.dupe(u8, jsonOptionalString(object, "host") orelse "");
    errdefer allocator.free(host);

    const agent_version = try allocator.dupe(u8, jsonOptionalString(object, "agent_version") orelse "");
    errdefer allocator.free(agent_version);

    const attached_count = if (try jsonOptionalU64(object, "attached_count")) |count| blk: {
        if (count > std.math.maxInt(u32)) return error.InvalidRoute;
        break :blk @as(u32, @intCast(count));
    } else null;

    const options = try jsonStringArrayField(allocator, object, "ssh_options");
    errdefer freeStringArray(allocator, options);

    return .{
        .guid = guid,
        .primary_alias = primary_alias,
        .session_dir = session_dir,
        .host = host,
        .agent_version = agent_version,
        .ssh_options = options,
        .last_known_alive = (try jsonOptionalBool(object, "alive")) orelse true,
        .attached_count = attached_count,
        .last_input_at_unix_ms = try jsonOptionalU64(object, "last_input_at_unix_ms"),
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

fn jsonRequiredU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    return (try jsonOptionalU64(object, key)) orelse error.InvalidJson;
}

fn jsonOptionalI32(object: std.json.ObjectMap, key: []const u8) !?i32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < std.math.minInt(i32) or integer > std.math.maxInt(i32)) return error.InvalidJson;
            break :blk @as(i32, @intCast(integer));
        },
        else => error.InvalidJson,
    };
}

fn jsonOptionalTombstoneExitStatus(object: std.json.ObjectMap, key: []const u8) !?TombstoneExitStatus {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .object => |status_object| .{
            .kind = try tombstoneExitStatusKindFromName(try jsonRequiredString(status_object, "kind")),
            .status = (try jsonOptionalI32(status_object, "status")) orelse return error.InvalidTombstone,
        },
        else => error.InvalidTombstone,
    };
}

fn jsonPid(value: std.json.Value) !c.pid_t {
    return switch (value) {
        .integer => |integer| blk: {
            if (integer <= 0 or integer > std.math.maxInt(c.pid_t)) return error.InvalidSessionMeta;
            break :blk @intCast(integer);
        },
        else => error.InvalidSessionMeta,
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

fn removeRecordedAliasesForTombstoneInRoot(allocator: std.mem.Allocator, root: []const u8, tombstone: *const Tombstone) !void {
    return removeAliasesForGuidInRoot(allocator, root, tombstone.guid, tombstone.aliases);
}

fn removeAliasesForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8, aliases: []const []const u8) !void {
    for (aliases) |alias| {
        const resolved = resolveRefToGuidInRoot(allocator, root, alias) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(resolved);
        if (!std.mem.eql(u8, resolved, guid)) continue;
        try removeAliasInRoot(allocator, root, alias);
    }
}

pub fn defaultAliasForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortSessionGuid(allocator, guid);
}

fn defaultAliasForGuidLen(allocator: std.mem.Allocator, guid: []const u8, hex_len: usize) ![]u8 {
    if (hex_len != generated_alias_hex_len) return error.InvalidAliasLength;
    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);
    const compact = try compactGuid(allocator, canonical);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "s-{s}", .{compact[0..hex_len]});
}

pub fn shortSessionGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortTypedGuid(allocator, guid, session_guid_prefix);
}

pub fn shortClientGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortTypedGuid(allocator, guid, client_guid_prefix);
}

fn shortTypedGuid(allocator: std.mem.Allocator, guid: []const u8, prefix: []const u8) ![]u8 {
    const compact = if (std.mem.eql(u8, prefix, session_guid_prefix))
        try compactGuid(allocator, guid)
    else
        try compactClientGuid(allocator, guid);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, compact[0..generated_alias_hex_len] });
}

pub fn createGeneratedRemoteAlias(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return createGeneratedRemoteAliasInRoot(allocator, root, guid);
}

pub fn createGeneratedRemoteAliasInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 4096) : (attempts += 1) {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const alias = try std.fmt.allocPrint(allocator, "a-{s}", .{hex[0..generated_alias_hex_len]});
        errdefer allocator.free(alias);
        if (try createAliasCandidateInRoot(allocator, root, alias, guid)) return alias;
        allocator.free(alias);
    }
    return error.GeneratedAliasExhausted;
}

fn createGeneratedAliasFromHexCandidatesInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8, candidates: []const []const u8) ![]u8 {
    for (candidates) |candidate| {
        if (candidate.len < generated_alias_hex_len) return error.InvalidAliasLength;
        const alias = try std.fmt.allocPrint(allocator, "a-{s}", .{candidate[0..generated_alias_hex_len]});
        errdefer allocator.free(alias);
        if (try createAliasCandidateInRoot(allocator, root, alias, guid)) return alias;
        allocator.free(alias);
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
    if (!isValidSessionGuidPrefix(ref) and !isValidAlias(ref)) return error.InvalidSessionId;
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
    if (isValidAlias(ref)) {
        return resolveAliasToGuidInRoot(allocator, root, ref) catch |err| switch (err) {
            error.FileNotFound => {
                if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
                    return resolveSessionGuidPrefixInRoot(allocator, root, prefix.slice());
                }
                return err;
            },
            else => return err,
        };
    }
    if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
        return resolveSessionGuidPrefixInRoot(allocator, root, prefix.slice());
    }
    return error.InvalidSessionId;
}

fn resolveAliasToGuidInRoot(allocator: std.mem.Allocator, root: []const u8, alias: []const u8) ![]u8 {
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, alias });
    defer allocator.free(link_path);
    const target = try readLinkAlloc(allocator, link_path, 4096);
    defer allocator.free(target);
    const compact = std.fs.path.basename(target);
    return canonicalGuid(allocator, compact);
}

fn resolveSessionGuidPrefixInRoot(allocator: std.mem.Allocator, root: []const u8, prefix: []const u8) ![]u8 {
    const sessions_dir = try stateSessionsDirInRoot(allocator, root);
    defer allocator.free(sessions_dir);
    var dir = if (std.fs.path.isAbsolute(sessions_dir))
        std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        }
    else
        std.fs.cwd().openDir(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
    defer dir.close();

    var match: ?[]u8 = null;
    errdefer if (match) |guid| allocator.free(guid);
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !isValidSessionGuid(entry.name)) continue;
        const compact = try compactGuid(allocator, entry.name);
        defer allocator.free(compact);
        if (!std.mem.startsWith(u8, compact, prefix)) continue;
        if (match != null) return error.AmbiguousSessionId;
        match = try canonicalGuid(allocator, entry.name);
    }
    return match orelse error.FileNotFound;
}

pub fn aliasesDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/alias", .{root});
}

pub fn aliasesForGuid(allocator: std.mem.Allocator, guid: []const u8) ![]const []const u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return aliasesForGuidInRoot(allocator, root, guid);
}

fn aliasesForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) ![]const []const u8 {
    const aliases_dir = try aliasesDirInRoot(allocator, root);
    defer allocator.free(aliases_dir);
    var dir = std.fs.openDirAbsolute(aliases_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close();

    const canonical = try canonicalGuid(allocator, guid);
    defer allocator.free(canonical);

    var aliases: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (aliases.items) |alias| allocator.free(alias);
        aliases.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (!isValidAlias(entry.name)) continue;
        const link_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ aliases_dir, entry.name });
        defer allocator.free(link_path);
        const target = readLinkAlloc(allocator, link_path, 4096) catch continue;
        defer allocator.free(target);
        const target_guid = canonicalGuid(allocator, std.fs.path.basename(target)) catch continue;
        defer allocator.free(target_guid);
        if (!std.mem.eql(u8, target_guid, canonical)) continue;
        try aliases.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, aliases.items, {}, stringSliceLessThan);
    return aliases.toOwnedSlice(allocator);
}

fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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
        if (alias.len != generated_alias_len) return false;
    } else if (std.mem.startsWith(u8, alias, "a-")) {
        if (alias.len != generated_alias_len) return false;
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

fn ensureAgentSocketLinkForSocketPath(allocator: std.mem.Allocator, link_path: []const u8, socket_path: []const u8) !void {
    const socket_name = std.fs.path.basename(socket_path);
    const expected_target = try std.fmt.allocPrint(allocator, "../../s/{s}", .{socket_name});
    defer allocator.free(expected_target);

    const existing_target = readLinkAlloc(allocator, link_path, 4096) catch |err| switch (err) {
        error.FileNotFound => {
            try installAgentSocketLink(allocator, link_path, socket_name);
            return;
        },
        else => return err,
    };
    defer allocator.free(existing_target);

    if (std.mem.eql(u8, existing_target, expected_target)) return;
    try unlinkIfExists(link_path);
    try installAgentSocketLink(allocator, link_path, socket_name);
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

/// Remove stale runtime files after the caller has already decided the session
/// is not alive.
pub fn removeStaleHints(paths: SessionPaths) !void {
    try removeRuntimeSessionFiles(paths);
}

/// Clean shutdown removes runtime files. Durable routes/aliases live in the
/// state directory, not in XDG_RUNTIME_DIR.
pub fn removeEndedHints(paths: SessionPaths) !void {
    try removeRuntimeSessionFiles(paths);
}

fn removeRuntimeSessionFiles(paths: SessionPaths) !void {
    try unlinkIfExists(paths.socket);
    try unlinkIfExists(paths.agent_sock_link);
    try unlinkIfExists(paths.compat);
    try unlinkIfExists(paths.meta);

    const agent_log = try std.fmt.allocPrint(app_allocator.allocator(), "{s}/agent.log", .{paths.dir});
    defer app_allocator.allocator().free(agent_log);
    try unlinkIfExists(agent_log);

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
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/meta.json", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/compat", allocation.paths.compat);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/route.json", allocation.paths.route);

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
    try std.testing.expect(isValidSessionGuidPrefix("s-5"));
    try std.testing.expect(isValidSessionGuidPrefix("s-550e8400"));
    try std.testing.expect(isValidSessionGuidPrefix("s-550e8400-e"));
    try std.testing.expect(isValidClientGuidPrefix("c-550e8400"));
    try std.testing.expect(isValidAlias("s1"));
    try std.testing.expect(isValidAlias("my-awesome-session"));
    try std.testing.expect(!isValidAlias("s-550e"));
    try std.testing.expect(!isValidAlias("s-550e8"));
    try std.testing.expect(isValidAlias("s-550e8400"));
    try std.testing.expect(isValidAlias("a-550e8400"));
    try std.testing.expect(!isValidAlias("a-550e8400a"));
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
    try std.testing.expectEqualStrings("s-550e8400", default_alias);
    try std.testing.expect(isValidAlias(default_alias));
    try std.testing.expect(!isValidCustomAlias(default_alias));
}

test "default alias availability detects generated alias collisions" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-default-alias-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const first_guid = "s-550e0000-e29b-41d4-a716-446655440000";
    const second_guid = "s-550e0000-e29b-41d4-a716-446655440001";
    const alias = try defaultAliasForGuid(allocator, first_guid);
    defer allocator.free(alias);
    try std.testing.expectEqualStrings("s-550e0000", alias);
    try createAliasInRoot(allocator, root, alias, first_guid);

    try std.testing.expect(try aliasAvailableForGuidInRoot(allocator, root, alias, first_guid));
    try std.testing.expect(!try aliasAvailableForGuidInRoot(allocator, root, alias, second_guid));
}

test "guid default alias generation retries colliding generated aliases" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-default-alias-retry-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const existing_guid = "s-550e1111-e29b-41d4-a716-446655440001";
    try createAliasInRoot(allocator, root, "s-550e1111", existing_guid);

    var identity = try generateGuidWithDefaultAliasFromCandidatesInRoot(allocator, root, &.{
        "s-550e1111-e29b-41d4-a716-446655440000",
        "s-550e2222-e29b-41d4-a716-446655440000",
    });
    defer identity.deinit(allocator);

    try std.testing.expectEqualStrings("s-550e2222-e29b-41d4-a716-446655440000", identity.guid);
    try std.testing.expectEqualStrings("s-550e2222", identity.alias);
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

    try std.testing.expectEqualStrings("a-feed1234", alias);
    const resolved = try resolveRefToGuidInRoot(allocator, root, alias);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(new_guid, resolved);
}

test "unique session guid prefixes resolve through state sessions" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-prefix-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const first_guid = "s-51111111-e29b-41d4-a716-446655440000";
    const second_guid = "s-62222222-e29b-41d4-a716-446655440000";
    const first_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ root, first_guid });
    defer allocator.free(first_dir);
    const second_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ root, second_guid });
    defer allocator.free(second_dir);
    try std.fs.cwd().makePath(first_dir);
    try std.fs.cwd().makePath(second_dir);

    const resolved = try resolveRefToGuidInRoot(allocator, root, "s-5");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(first_guid, resolved);

    try std.testing.expectError(error.FileNotFound, resolveRefToGuidInRoot(allocator, root, "s-7"));
}

test "ambiguous session guid prefixes are rejected" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-ambiguous-prefix-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const first_guid = "s-51111111-e29b-41d4-a716-446655440000";
    const second_guid = "s-52222222-e29b-41d4-a716-446655440000";
    const first_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ root, first_guid });
    defer allocator.free(first_dir);
    const second_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ root, second_guid });
    defer allocator.free(second_dir);
    try std.fs.cwd().makePath(first_dir);
    try std.fs.cwd().makePath(second_dir);

    try std.testing.expectError(error.AmbiguousSessionId, resolveRefToGuidInRoot(allocator, root, "s-5"));
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
        "{{\"guid\":\"s-550e8400-e29b-41d4-a716-446655440000\",\"primary_alias\":\"s-550e8400\",\"session_dir\":{f},\"host\":\"work.example\",\"agent_version\":\"0.5.0-test\",\"alive\":true,\"attached_count\":2,\"last_input_at_unix_ms\":1234,\"ssh_options\":[\"-F\"]}}\n",
        .{std.json.fmt(session_dir, .{})},
    );
    const file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(text.items);
    file.close();

    var route = try readRoute(allocator, route_path);
    defer route.deinit(allocator);
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", route.guid);
    try std.testing.expectEqualStrings("s-550e8400", route.primary_alias);
    try std.testing.expectEqualStrings(session_dir, route.session_dir);
    try std.testing.expectEqualStrings("work.example", route.host);
    try std.testing.expectEqualStrings("0.5.0-test", route.agent_version);
    try std.testing.expect(route.last_known_alive);
    try std.testing.expectEqual(@as(?u32, 2), route.attached_count);
    try std.testing.expectEqual(@as(?u64, 1234), route.last_input_at_unix_ms);
    try std.testing.expectEqual(@as(usize, 1), route.ssh_options.len);
    try std.testing.expectEqualStrings("-F", route.ssh_options[0]);
}

test "tombstone snapshots aliases, removes route, and releases aliases" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/sessh-tombstone-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    const route_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ root, guid });
    defer allocator.free(route_dir);
    try std.fs.cwd().makePath(route_dir);
    const route_path = try routePathForGuidInStateRoot(allocator, root, guid);
    defer allocator.free(route_path);
    var route_file = try std.fs.cwd().createFile(route_path, .{ .truncate = true, .mode = 0o600 });
    route_file.close();

    try createAliasInRoot(allocator, root, "beta", guid);
    try createAliasInRoot(allocator, root, "alpha", guid);
    try createAliasInRoot(allocator, root, "other", "s-11111111-1111-4111-8111-111111111111");

    var route = Route{
        .guid = try allocator.dupe(u8, guid),
        .primary_alias = try allocator.dupe(u8, "alpha"),
        .session_dir = try allocator.dupe(u8, "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000"),
        .host = try allocator.dupe(u8, "work.example"),
        .agent_version = try allocator.dupe(u8, "0.5.0-test"),
        .ssh_options = try allocator.alloc([]const u8, 0),
        .last_known_alive = true,
        .attached_count = null,
        .last_input_at_unix_ms = null,
    };
    defer route.deinit(allocator);

    try writeTombstoneForRouteInRoot(allocator, root, &route, .{
        .ended_at_unix_ms = 1234,
        .end_reason = .process_exited,
        .exit_status = .{ .kind = .exited, .status = 7 },
    });

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(route_path));

    const tombstone_path = try tombstonePathForGuidInRoot(allocator, root, guid);
    defer allocator.free(tombstone_path);
    var tombstone = try readTombstone(allocator, tombstone_path);
    defer tombstone.deinit(allocator);
    try std.testing.expectEqualStrings(guid, tombstone.guid);
    try std.testing.expectEqualStrings("alpha", tombstone.primary_alias);
    try std.testing.expectEqual(@as(usize, 2), tombstone.aliases.len);
    try std.testing.expectEqualStrings("alpha", tombstone.aliases[0]);
    try std.testing.expectEqualStrings("beta", tombstone.aliases[1]);
    try std.testing.expectEqual(@as(u64, 1234), tombstone.ended_at_unix_ms);
    try std.testing.expectEqual(TombstoneEndReason.process_exited, tombstone.end_reason);
    try std.testing.expectEqual(TombstoneExitStatusKind.exited, tombstone.exit_status.?.kind);
    try std.testing.expectEqual(@as(i32, 7), tombstone.exit_status.?.status);

    try std.testing.expectError(error.FileNotFound, resolveRefToGuidInRoot(allocator, root, "alpha"));
    try std.testing.expectError(error.FileNotFound, resolveRefToGuidInRoot(allocator, root, "beta"));
    const other = try resolveRefToGuidInRoot(allocator, root, "other");
    defer allocator.free(other);
    try std.testing.expectEqualStrings("s-11111111-1111-4111-8111-111111111111", other);

    const alias_guid = try resolveTombstoneRefToGuidInRoot(allocator, root, "alpha");
    defer allocator.free(alias_guid);
    try std.testing.expectEqualStrings(guid, alias_guid);
    try createAliasInRoot(allocator, root, "alpha", "s-22222222-2222-4222-8222-222222222222");
}

test "expired tombstone cleanup removes only recorded aliases" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/sessh-tombstone-expiry-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";
    try createAliasInRoot(allocator, root, "recorded", guid);

    var route = Route{
        .guid = try allocator.dupe(u8, guid),
        .primary_alias = try allocator.dupe(u8, "recorded"),
        .session_dir = try allocator.dupe(u8, "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000"),
        .host = try allocator.dupe(u8, "."),
        .agent_version = try allocator.dupe(u8, "0.5.0-test"),
        .ssh_options = try allocator.alloc([]const u8, 0),
        .last_known_alive = true,
        .attached_count = null,
        .last_input_at_unix_ms = null,
    };
    defer route.deinit(allocator);

    try writeTombstoneForRouteInRoot(allocator, root, &route, .{
        .ended_at_unix_ms = 100,
        .end_reason = .killed_by_request,
        .exit_status = null,
    });
    try createAliasInRoot(allocator, root, "late", guid);

    try cleanupExpiredTombstonesInRoot(allocator, root, 100 + tombstone_retention_ms - 1);
    const retained_path = try tombstonePathForGuidInRoot(allocator, root, guid);
    defer allocator.free(retained_path);
    _ = try std.fs.cwd().statFile(retained_path);

    try cleanupExpiredTombstonesInRoot(allocator, root, 100 + tombstone_retention_ms);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(retained_path));
    try std.testing.expectError(error.FileNotFound, resolveRefToGuidInRoot(allocator, root, "recorded"));
    const late = try resolveRefToGuidInRoot(allocator, root, "late");
    defer allocator.free(late);
    try std.testing.expectEqualStrings(guid, late);
}

test "registry writes json metadata" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/session-registry-state-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    var allocation = try allocateSessionDirInRoot(allocator, root);
    defer allocation.deinit(allocator);

    try writeMeta(allocation.paths, 12345, "0.4.0-dev");
    var meta = try readMeta(allocator, allocation.paths);
    defer meta.deinit(allocator);
    try std.testing.expectEqual(@as(c.pid_t, 12345), meta.agent_pid);
    try std.testing.expectEqualStrings("0.4.0-dev", meta.version);
}

test "stale cleanup removes runtime session directory" {
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
    try writeMeta(allocation.paths, 12345, "0.5.0-dev");

    try removeStaleHints(allocation.paths);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.socket));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.compat));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.meta));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.dir));
}

test "ended cleanup removes runtime session directory" {
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
    try writeMeta(allocation.paths, 12345, "0.5.0-dev");
    const agent_log = try std.fmt.allocPrint(allocator, "{s}/agent.log", .{allocation.paths.dir});
    defer allocator.free(agent_log);
    var log_file = try std.fs.cwd().createFile(agent_log, .{});
    log_file.close();

    try removeEndedHints(allocation.paths);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.socket));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.compat));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.meta));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(agent_log));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(allocation.paths.dir));
}
