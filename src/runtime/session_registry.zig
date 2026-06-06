const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const socket_transport = @import("../transport/socket.zig");

pub const guid_body_len = 36;
pub const compact_guid_len = 32;
pub const session_guid_prefix = "s-";
pub const client_guid_prefix = "c-";
pub const proxy_guid_prefix = "p-";
pub const host_guid_prefix = "h-";
pub const session_guid_len = session_guid_prefix.len + guid_body_len;
pub const client_guid_len = client_guid_prefix.len + guid_body_len;
pub const proxy_guid_len = proxy_guid_prefix.len + guid_body_len;
pub const host_guid_len = host_guid_prefix.len + guid_body_len;
pub const short_guid_hex_len = 8;
pub const default_ssh_port = "22";

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

/// Runtime socket identity for anything addressed by a top-level typed GUID.
/// The real Unix socket lives in `runtime/a` to keep paths short; the GUID
/// directory contains the stable `agent.sock` symlink used by lookup code.
pub const RuntimeAgentSocketPaths = struct {
    dir: []u8,
    socket: []u8,
    agent_sock_link: []u8,
    meta: []u8,

    pub fn deinit(self: *RuntimeAgentSocketPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.meta);
        allocator.free(self.agent_sock_link);
        allocator.free(self.socket);
        allocator.free(self.dir);
        self.* = undefined;
    }

    pub fn removeRuntimeFiles(self: RuntimeAgentSocketPaths) void {
        unlinkIfExists(self.socket) catch {};
        unlinkIfExists(self.agent_sock_link) catch {};
        unlinkIfExists(self.meta) catch {};
        removeDirIfEmpty(self.dir) catch {};
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

    const socket_dir = try agentSocketsDirInRoot(allocator, runtime_root);
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

pub fn agentSocketsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/a", .{root});
}

pub fn clientSocketsDirInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/c", .{root});
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

pub fn isValidProxyGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, proxy_guid_prefix) and
        isValidGuidBody(guid[proxy_guid_prefix.len..]);
}

pub fn isValidHostGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, host_guid_prefix) and
        isValidGuidBody(guid[host_guid_prefix.len..]);
}

pub fn isValidGuid(guid: []const u8) bool {
    return isValidSessionGuid(guid) or isValidClientGuid(guid) or isValidProxyGuid(guid) or isValidHostGuid(guid);
}

pub fn isValidCompactGuid(guid: []const u8) bool {
    if (guid.len != compact_guid_len) return false;
    for (guid) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub fn isValidSessionRef(ref: []const u8) bool {
    return isValidSessionId(ref) or isValidSessionGuidPrefix(ref);
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

pub fn canonicalHostGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidHostGuid(guid)) return error.InvalidHostId;
    const out = try allocator.alloc(u8, host_guid_len);
    out[0] = host_guid_prefix[0];
    out[1] = host_guid_prefix[1];
    for (guid[host_guid_prefix.len..], 0..) |byte, i| {
        out[host_guid_prefix.len + i] = std.ascii.toLower(byte);
    }
    return out;
}

fn canonicalRuntimeGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidSessionGuid(guid) or isValidCompactGuid(guid)) return canonicalGuid(allocator, guid);
    if (isValidClientGuid(guid)) return canonicalClientGuid(allocator, guid);
    if (isValidProxyGuid(guid)) return canonicalProxyGuid(allocator, guid);
    return error.InvalidSessionId;
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
    if (isValidClientGuid(guid)) return compactClientGuid(allocator, guid);
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

pub fn generateHostGuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);
    const session_guid = try canonicalGuid(allocator, &compact);
    defer allocator.free(session_guid);

    const out = try allocator.alloc(u8, host_guid_len);
    out[0] = host_guid_prefix[0];
    out[1] = host_guid_prefix[1];
    @memcpy(out[host_guid_prefix.len..], session_guid[session_guid_prefix.len..]);
    return out;
}

pub const Meta = struct {
    agent_pid: c.pid_t,
    version: []u8,

    pub fn deinit(self: *Meta, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        self.* = undefined;
    }
};

pub const RuntimeGuidType = enum {
    incoming_client,
    outgoing_client,
    local_session,
    incoming_proxy,
    outgoing_proxy,
};

pub fn runtimeGuidTypeName(guid_type: RuntimeGuidType) []const u8 {
    return switch (guid_type) {
        .incoming_client => "incoming-client",
        .outgoing_client => "outgoing-client",
        .local_session => "local-session",
        .incoming_proxy => "incoming-proxy",
        .outgoing_proxy => "outgoing-proxy",
    };
}

const runtime_guid_session_meta_filenames = [_][]const u8{"meta.json"};
const runtime_guid_directional_meta_filenames = [_][]const u8{
    "incoming-meta.json",
    "outgoing-meta.json",
};
const runtime_guid_empty_meta_filenames = [_][]const u8{};

pub fn runtimeGuidMetaFilenamesForGuid(guid: []const u8) []const []const u8 {
    if (isValidSessionGuid(guid)) return runtime_guid_session_meta_filenames[0..];
    if (isValidClientGuid(guid) or isValidProxyGuid(guid)) return runtime_guid_directional_meta_filenames[0..];
    return runtime_guid_empty_meta_filenames[0..];
}

// Client and reconnectable-stream GUID directories can exist on both sides of
// a connection at once. Each side owns one directional metadata file so teardown
// can remove its own record without clobbering the other side's record.
fn runtimeGuidMetaFilenameForType(guid_type: RuntimeGuidType) []const u8 {
    return switch (guid_type) {
        .local_session => "meta.json",
        .incoming_client, .incoming_proxy => "incoming-meta.json",
        .outgoing_client, .outgoing_proxy => "outgoing-meta.json",
    };
}

fn runtimeGuidTypeFromName(value: []const u8) !RuntimeGuidType {
    if (std.mem.eql(u8, value, "incoming-client")) return .incoming_client;
    if (std.mem.eql(u8, value, "outgoing-client")) return .outgoing_client;
    if (std.mem.eql(u8, value, "local-session")) return .local_session;
    if (std.mem.eql(u8, value, "incoming-proxy")) return .incoming_proxy;
    if (std.mem.eql(u8, value, "outgoing-proxy")) return .outgoing_proxy;
    return error.InvalidRuntimeGuidMeta;
}

pub const RuntimeGuidMeta = struct {
    guid_type: RuntimeGuidType,
    created_at_unix_ms: ?u64,
    agent_pid: ?c.pid_t = null,
};

pub fn writeMeta(paths: SessionPaths, agent_pid: c.pid_t, version: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app_allocator.allocator());
    const writer = text.writer(app_allocator.allocator());
    const created_at_unix_ms = runtimeGuidMetaCreatedAtUnixMs(app_allocator.allocator(), paths.meta);
    try writer.print(
        "{{\"type\":{f},\"created_at_unix_ms\":{},\"agent_pid\":{},\"version\":{f}}}\n",
        .{
            std.json.fmt(runtimeGuidTypeName(.local_session), .{}),
            created_at_unix_ms,
            agent_pid,
            std.json.fmt(version, .{}),
        },
    );
    try writeAtomicFile(paths.meta, text.items);
}

fn writeRuntimeGuidMetaInDir(allocator: std.mem.Allocator, dir: []const u8, guid_type: RuntimeGuidType) !void {
    const path = try runtimeGuidMetaPathForTypeInDir(allocator, dir, guid_type);
    defer allocator.free(path);
    try writeRuntimeGuidMetaPath(allocator, path, guid_type);
}

fn writeRuntimeGuidMetaPath(allocator: std.mem.Allocator, path: []const u8, guid_type: RuntimeGuidType) !void {
    return writeRuntimeGuidMetaPathWithPid(allocator, path, guid_type, null);
}

fn writeRuntimeGuidMetaPathWithPid(allocator: std.mem.Allocator, path: []const u8, guid_type: RuntimeGuidType, agent_pid: ?c.pid_t) !void {
    const created_at_unix_ms = runtimeGuidMetaCreatedAtUnixMs(allocator, path);
    const existing_agent_pid = if (agent_pid == null) blk: {
        const meta = readRuntimeGuidMeta(allocator, path) catch break :blk null;
        break :blk meta.agent_pid;
    } else null;
    const output_agent_pid = agent_pid orelse existing_agent_pid;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.print("{{\"type\":{f},\"created_at_unix_ms\":{}", .{
        std.json.fmt(runtimeGuidTypeName(guid_type), .{}),
        created_at_unix_ms,
    });
    if (output_agent_pid) |pid| try writer.print(",\"agent_pid\":{}", .{pid});
    try writer.writeAll("}\n");
    try writeAtomicFile(path, text.items);
}

fn runtimeGuidMetaCreatedAtUnixMs(allocator: std.mem.Allocator, path: []const u8) u64 {
    const meta = readRuntimeGuidMeta(allocator, path) catch return currentUnixMs();
    return meta.created_at_unix_ms orelse currentUnixMs();
}

fn removeRuntimeGuidMetaInDir(allocator: std.mem.Allocator, dir: []const u8, guid_type: RuntimeGuidType) !void {
    const meta_path = try runtimeGuidMetaPathForTypeInDir(allocator, dir, guid_type);
    defer allocator.free(meta_path);
    try unlinkIfExists(meta_path);
    removeDirIfEmpty(dir) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
}

fn currentUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

pub fn readRuntimeGuidMeta(allocator: std.mem.Allocator, path: []const u8) !RuntimeGuidMeta {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);
    const guid_type = try runtimeGuidTypeFromName(try jsonRequiredString(object, "type"));
    return .{
        .guid_type = guid_type,
        .created_at_unix_ms = try jsonOptionalU64(object, "created_at_unix_ms"),
        .agent_pid = if (object.get("agent_pid")) |value| try jsonPid(value) else null,
    };
}

pub fn ensureHostGuid(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return ensureHostGuidInRoot(allocator, root);
}

fn ensureHostGuidInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    try ensureRegistryRoot(allocator, root);

    const lock_path = try hostGuidLockPathInRoot(allocator, root);
    defer allocator.free(lock_path);
    var lock = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
        .lock = .exclusive,
    });
    defer {
        lock.unlock();
        lock.close();
    }

    const path = try hostGuidPathInRoot(allocator, root);
    defer allocator.free(path);
    if (readHostGuidFile(allocator, path)) |guid| return guid else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const generated = try generateHostGuid(allocator);
    defer allocator.free(generated);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.writer(allocator).print("{{\"guid\":{f}}}\n", .{std.json.fmt(generated, .{})});
    try writeAtomicFile(path, text.items);
    return readHostGuidFile(allocator, path);
}

fn readHostGuidFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value);
    const guid_value = try jsonRequiredString(object, "guid");
    return canonicalHostGuid(allocator, guid_value);
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
    session_dir: []u8,
    host_guid: []u8,
    host: []u8,
    resolved_host: []u8,
    port: []u8,
    agent_version: []u8,
    ssh_options: []const []const u8,
    last_known_alive: bool,
    tombstone_retention_ms: u64,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        for (self.ssh_options) |option| allocator.free(option);
        allocator.free(self.ssh_options);
        allocator.free(self.agent_version);
        allocator.free(self.port);
        allocator.free(self.resolved_host);
        allocator.free(self.host);
        allocator.free(self.host_guid);
        allocator.free(self.session_dir);
        allocator.free(self.guid);
        self.* = undefined;
    }
};

pub const TombstoneEndReason = enum {
    unknown,
    process_exited,
    killed_by_request,
    agent_shutdown,
    reaped,
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
    session_dir: []u8,
    host: []u8,
    agent_version: []u8,
    ended_at_unix_ms: u64,
    expires_at_unix_ms: ?u64,
    end_reason: TombstoneEndReason,
    exit_status: ?TombstoneExitStatus,

    pub fn deinit(self: *Tombstone, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_version);
        allocator.free(self.host);
        allocator.free(self.session_dir);
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
        .reaped => "reaped",
    };
}

pub fn tombstoneEndReasonFromName(value: []const u8) !TombstoneEndReason {
    if (std.mem.eql(u8, value, "unknown")) return .unknown;
    if (std.mem.eql(u8, value, "process_exited")) return .process_exited;
    if (std.mem.eql(u8, value, "killed_by_request")) return .killed_by_request;
    if (std.mem.eql(u8, value, "agent_shutdown")) return .agent_shutdown;
    if (std.mem.eql(u8, value, "reaped")) return .reaped;
    if (std.mem.eql(u8, value, "disconnected_timeout")) return .reaped;
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
    session_dir: []const u8,
    host_guid: []const u8,
    host: []const u8,
    resolved_host: []const u8,
    port: []const u8,
    ssh_options: []const []const u8,
    agent_version: []const u8,
    tombstone_retention_ms: u64,
) !void {
    return writeRoute(allocator, guid, session_dir, host, ssh_options, .{
        .host_guid = host_guid,
        .port = port,
        .resolved_host = resolved_host,
        .agent_version = agent_version,
        .tombstone_retention_ms = tombstone_retention_ms,
    });
}

pub fn writeLocalRoute(
    allocator: std.mem.Allocator,
    guid: []const u8,
    session_dir: []const u8,
    agent_version: []const u8,
    tombstone_retention_ms: u64,
) !void {
    return writeRoute(allocator, guid, session_dir, ".", &.{}, .{
        .agent_version = agent_version,
        .tombstone_retention_ms = tombstone_retention_ms,
    });
}

const RouteStatus = struct {
    last_known_alive: bool = true,
    host_guid: []const u8 = "",
    port: []const u8 = default_ssh_port,
    resolved_host: []const u8 = "",
    agent_version: []const u8 = "",
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
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
    const tombstone_path = try tombstonePathForGuidInRoot(allocator, state_root, canonical);
    defer allocator.free(tombstone_path);
    if (try pathExists(tombstone_path)) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    const resolved_host = if (status.resolved_host.len == 0) host else status.resolved_host;
    if (status.host_guid.len != 0 and !isValidHostGuid(status.host_guid)) return error.InvalidHostId;
    try writer.print(
        "{{\"guid\":{f},\"session_dir\":{f},\"host_guid\":{f},\"host\":{f},\"resolved_host\":{f},\"port\":{f},\"agent_version\":{f},\"alive\":{},\"tombstone_retention_ms\":{},\"ssh_options\":[",
        .{
            std.json.fmt(canonical, .{}),
            std.json.fmt(session_dir, .{}),
            std.json.fmt(status.host_guid, .{}),
            std.json.fmt(host, .{}),
            std.json.fmt(resolved_host, .{}),
            std.json.fmt(status.port, .{}),
            std.json.fmt(status.agent_version, .{}),
            status.last_known_alive,
            status.tombstone_retention_ms,
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

pub fn writeTombstoneForRoute(allocator: std.mem.Allocator, route: *const Route, details: TombstoneDetails) !void {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return writeTombstoneForRouteInRoot(allocator, root, route, details);
}

fn writeTombstoneForRouteInRoot(allocator: std.mem.Allocator, root: []const u8, route: *const Route, details: TombstoneDetails) !void {
    const canonical = try canonicalGuid(allocator, route.guid);
    defer allocator.free(canonical);

    try ensureTombstoneDir(allocator, root);
    const path = try tombstonePathForGuidInRoot(allocator, root, canonical);
    defer allocator.free(path);
    const expires_at_unix_ms: ?u64 = if (route.tombstone_retention_ms == 0)
        null
    else
        details.ended_at_unix_ms +| route.tombstone_retention_ms;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const writer = text.writer(allocator);
    try writer.print(
        "{{\"guid\":{f},\"session_dir\":{f},\"host\":{f},\"agent_version\":{f},\"ended_at_unix_ms\":{},\"expires_at_unix_ms\":",
        .{
            std.json.fmt(canonical, .{}),
            std.json.fmt(route.session_dir, .{}),
            std.json.fmt(route.host, .{}),
            std.json.fmt(route.agent_version, .{}),
            details.ended_at_unix_ms,
        },
    );
    if (expires_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"end_reason\":{f},\"exit_status\":", .{std.json.fmt(tombstoneEndReasonName(details.end_reason), .{})});
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

    const session_dir_value = jsonOptionalString(object, "session_dir") orelse "";
    if (session_dir_value.len > 0 and !isAbsolutePath(session_dir_value)) return error.InvalidTombstone;
    const session_dir = try allocator.dupe(u8, session_dir_value);
    errdefer allocator.free(session_dir);

    const host = try allocator.dupe(u8, jsonOptionalString(object, "host") orelse "");
    errdefer allocator.free(host);

    const agent_version = try allocator.dupe(u8, jsonOptionalString(object, "agent_version") orelse "");
    errdefer allocator.free(agent_version);

    const ended_at_unix_ms = try jsonRequiredU64(object, "ended_at_unix_ms");
    const expires_at_unix_ms = try tombstoneExpiryFromJson(object, ended_at_unix_ms);
    const end_reason = try tombstoneEndReasonFromName(jsonOptionalString(object, "end_reason") orelse "unknown");
    const exit_status = try jsonOptionalTombstoneExitStatus(object, "exit_status");

    return .{
        .guid = guid,
        .session_dir = session_dir,
        .host = host,
        .agent_version = agent_version,
        .ended_at_unix_ms = ended_at_unix_ms,
        .expires_at_unix_ms = expires_at_unix_ms,
        .end_reason = end_reason,
        .exit_status = exit_status,
    };
}

fn tombstoneExpiryFromJson(object: std.json.ObjectMap, ended_at_unix_ms: u64) !?u64 {
    const value = object.get("expires_at_unix_ms") orelse return ended_at_unix_ms +| config.default_tombstone_retention_ms;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidTombstone;
            break :blk @as(u64, @intCast(integer));
        },
        else => error.InvalidTombstone,
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
        const expires_at = tombstone.expires_at_unix_ms orelse continue;
        if (now_ms < expires_at) continue;
        try unlinkIfExists(path);
    }
}

pub fn readRouteForRef(allocator: std.mem.Allocator, ref: []const u8) !Route {
    var paths = try pathsForRef(allocator, ref);
    defer paths.deinit(allocator);
    return readRoute(allocator, paths.route);
}

pub fn runtimeAgentSocketPathsForGuid(allocator: std.mem.Allocator, guid: []const u8) !RuntimeAgentSocketPaths {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    return runtimeAgentSocketPathsForGuidInRoot(allocator, runtime_root, guid);
}

pub fn writeRuntimeAgentPidForGuid(allocator: std.mem.Allocator, guid: []const u8, agent_pid: c.pid_t) !void {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const canonical = try canonicalRuntimeGuid(allocator, guid);
    defer allocator.free(canonical);
    const guid_root = try sessionsDirInRoot(allocator, runtime_root);
    defer allocator.free(guid_root);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guid_root, canonical });
    defer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);
    const incoming_meta_type = runtimeIncomingMetaTypeForGuid(canonical);
    const meta = try runtimeGuidMetaPathForTypeInDir(allocator, dir, incoming_meta_type);
    defer allocator.free(meta);
    try writeRuntimeGuidMetaPathWithPid(allocator, meta, incoming_meta_type, agent_pid);
}

pub fn writeOutgoingProxyHint(allocator: std.mem.Allocator, guid: []const u8) !void {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    return writeOutgoingProxyHintInRoot(allocator, runtime_root, guid);
}

fn writeOutgoingProxyHintInRoot(allocator: std.mem.Allocator, runtime_root: []const u8, guid: []const u8) !void {
    return writeDirectionalRuntimeGuidHintInRoot(allocator, runtime_root, guid, .outgoing_proxy);
}

fn writeDirectionalRuntimeGuidHintInRoot(
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    guid: []const u8,
    guid_type: RuntimeGuidType,
) !void {
    try ensureRegistryRoot(allocator, runtime_root);
    const guid_root = try sessionsDirInRoot(allocator, runtime_root);
    defer allocator.free(guid_root);
    try mkdirIgnoreExists(allocator, guid_root);

    const canonical = try canonicalRuntimeGuid(allocator, guid);
    defer allocator.free(canonical);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guid_root, canonical });
    defer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);
    try writeRuntimeGuidMetaInDir(allocator, dir, guid_type);
}

pub fn removeOutgoingProxyHint(allocator: std.mem.Allocator, guid: []const u8) !void {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    return removeOutgoingProxyHintInRoot(allocator, runtime_root, guid);
}

fn removeOutgoingProxyHintInRoot(allocator: std.mem.Allocator, runtime_root: []const u8, guid: []const u8) !void {
    return removeDirectionalRuntimeGuidHintInRoot(allocator, runtime_root, guid, .outgoing_proxy);
}

fn removeDirectionalRuntimeGuidHintInRoot(
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    guid: []const u8,
    guid_type: RuntimeGuidType,
) !void {
    const canonical = try canonicalRuntimeGuid(allocator, guid);
    defer allocator.free(canonical);
    const dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ runtime_root, canonical });
    defer allocator.free(dir);
    try removeRuntimeGuidMetaInDir(allocator, dir, guid_type);
}

pub fn runtimeAgentSocketPathsForGuidInRoot(
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    guid: []const u8,
) !RuntimeAgentSocketPaths {
    try ensureRegistryRoot(allocator, runtime_root);

    const guid_root = try sessionsDirInRoot(allocator, runtime_root);
    defer allocator.free(guid_root);
    try mkdirIgnoreExists(allocator, guid_root);

    const canonical = try canonicalRuntimeGuid(allocator, guid);
    defer allocator.free(canonical);

    const socket_root = try agentSocketsDirInRoot(allocator, runtime_root);
    defer allocator.free(socket_root);
    try mkdirIgnoreExists(allocator, socket_root);

    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guid_root, canonical });
    errdefer allocator.free(dir);
    try mkdirIgnoreExists(allocator, dir);

    const agent_sock_link = try agentSocketLinkPath(allocator, dir);
    errdefer allocator.free(agent_sock_link);

    const incoming_meta_type = runtimeIncomingMetaTypeForGuid(canonical);
    const meta = try runtimeGuidMetaPathForTypeInDir(allocator, dir, incoming_meta_type);
    errdefer allocator.free(meta);

    const socket = socketPathFromAgentSocketLink(allocator, dir, agent_sock_link) catch |err| switch (err) {
        error.FileNotFound => blk: {
            var socket_allocation = try allocateRuntimeAgentSocketPathForGuidInRoot(allocator, runtime_root, canonical);
            errdefer socket_allocation.deinit(allocator);
            try installAgentSocketLink(allocator, agent_sock_link, socket_allocation.name);
            allocator.free(socket_allocation.name);
            break :blk socket_allocation.path;
        },
        else => return err,
    };
    errdefer allocator.free(socket);
    try writeRuntimeGuidMetaPath(allocator, meta, incoming_meta_type);

    return .{
        .dir = dir,
        .socket = socket,
        .agent_sock_link = agent_sock_link,
        .meta = meta,
    };
}

fn runtimeIncomingMetaTypeForGuid(guid: []const u8) RuntimeGuidType {
    if (isValidProxyGuid(guid)) return .incoming_proxy;
    if (isValidClientGuid(guid)) return .incoming_client;
    return .local_session;
}

pub fn runtimeGuidMetaPathInDir(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/meta.json", .{dir});
}

pub fn runtimeGuidMetaPathForTypeInDir(allocator: std.mem.Allocator, dir: []const u8, guid_type: RuntimeGuidType) ![]u8 {
    return runtimeGuidMetaPathForFilenameInDir(allocator, dir, runtimeGuidMetaFilenameForType(guid_type));
}

pub fn runtimeGuidMetaPathForFilenameInDir(allocator: std.mem.Allocator, dir: []const u8, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
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

fn hostGuidPathInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/host.json", .{root});
}

fn hostGuidLockPathInRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/host.lock", .{root});
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
    if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
        return resolveTombstoneGuidPrefixInRoot(allocator, root, prefix.slice());
    }
    return error.InvalidSessionId;
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

    const session_dir_value = jsonOptionalString(object, "session_dir") orelse "";
    if (session_dir_value.len > 0 and !isAbsolutePath(session_dir_value)) return error.InvalidRoute;
    const session_dir = try allocator.dupe(u8, session_dir_value);
    errdefer allocator.free(session_dir);

    const host_guid_value = jsonOptionalString(object, "host_guid") orelse "";
    if (host_guid_value.len != 0 and !isValidHostGuid(host_guid_value)) return error.InvalidRoute;
    const host_guid = try allocator.dupe(u8, host_guid_value);
    errdefer allocator.free(host_guid);

    const host = try allocator.dupe(u8, jsonOptionalString(object, "host") orelse "");
    errdefer allocator.free(host);

    const resolved_host = try allocator.dupe(u8, jsonOptionalString(object, "resolved_host") orelse host);
    errdefer allocator.free(resolved_host);

    const port_value = jsonOptionalString(object, "port") orelse default_ssh_port;
    if (!isValidSshPort(port_value)) return error.InvalidRoute;
    const port = try allocator.dupe(u8, port_value);
    errdefer allocator.free(port);

    const agent_version = try allocator.dupe(u8, jsonOptionalString(object, "agent_version") orelse "");
    errdefer allocator.free(agent_version);

    const options = try jsonStringArrayField(allocator, object, "ssh_options");
    errdefer freeStringArray(allocator, options);

    return .{
        .guid = guid,
        .session_dir = session_dir,
        .host_guid = host_guid,
        .host = host,
        .resolved_host = resolved_host,
        .port = port,
        .agent_version = agent_version,
        .ssh_options = options,
        .last_known_alive = (try jsonOptionalBool(object, "alive")) orelse true,
        .tombstone_retention_ms = (try jsonOptionalU64(object, "tombstone_retention_ms")) orelse config.default_tombstone_retention_ms,
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

pub fn shortSessionGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortTypedGuid(allocator, guid, session_guid_prefix);
}

pub fn shortClientGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortTypedGuid(allocator, guid, client_guid_prefix);
}

pub fn shortProxyGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    return shortTypedGuid(allocator, guid, proxy_guid_prefix);
}

pub fn shortRuntimeGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidSessionGuid(guid)) return shortSessionGuid(allocator, guid);
    if (isValidClientGuid(guid)) return shortClientGuid(allocator, guid);
    if (isValidProxyGuid(guid)) return shortProxyGuid(allocator, guid);
    return error.InvalidGuid;
}

fn shortTypedGuid(allocator: std.mem.Allocator, guid: []const u8, prefix: []const u8) ![]u8 {
    const compact = if (std.mem.eql(u8, prefix, session_guid_prefix))
        try compactGuid(allocator, guid)
    else if (std.mem.eql(u8, prefix, proxy_guid_prefix))
        try compactProxyGuid(allocator, guid)
    else
        try compactClientGuid(allocator, guid);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, compact[0..short_guid_hex_len] });
}

pub fn pathsForRef(allocator: std.mem.Allocator, ref: []const u8) !SessionPaths {
    if (isValidSessionId(ref)) return pathsForSessionId(allocator, ref);
    if (!isValidSessionGuidPrefix(ref)) return error.InvalidSessionId;
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
    if (compactGuidPrefix(ref, session_guid_prefix)) |prefix| {
        return resolveSessionGuidPrefixInRoot(allocator, root, prefix.slice());
    }
    return error.InvalidSessionId;
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

pub const SocketPathAllocation = struct {
    name: []u8,
    path: []u8,

    pub fn deinit(self: *SocketPathAllocation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

fn allocateSocketPathForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) !SocketPathAllocation {
    const socket_dir = try agentSocketsDirInRoot(allocator, root);
    defer allocator.free(socket_dir);
    return allocateSocketPathForGuidInDir(allocator, socket_dir, guid);
}

fn allocateRuntimeAgentSocketPathForGuidInRoot(allocator: std.mem.Allocator, root: []const u8, guid: []const u8) !SocketPathAllocation {
    const socket_dir = try agentSocketsDirInRoot(allocator, root);
    defer allocator.free(socket_dir);
    return allocateSocketPathForGuidInDir(allocator, socket_dir, guid);
}

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

fn agentSocketLinkPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/agent.sock", .{dir});
}

fn installAgentSocketLink(allocator: std.mem.Allocator, link_path: []const u8, socket_name: []const u8) !void {
    const target = try std.fmt.allocPrint(allocator, "../../a/{s}", .{socket_name});
    defer allocator.free(target);
    return installSymlinkReplacing(allocator, link_path, target);
}

fn installSymlinkReplacing(allocator: std.mem.Allocator, link_path: []const u8, target: []const u8) !void {
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
    const expected_target = try std.fmt.allocPrint(allocator, "../../a/{s}", .{socket_name});
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
    if (std.mem.startsWith(u8, target, "../../a/")) {
        const guid_dir = std.fs.path.dirname(dir) orelse return error.InvalidSessionDir;
        const root = std.fs.path.dirname(guid_dir) orelse return error.InvalidSessionDir;
        const socket_name = target["../../a/".len..];
        return std.fmt.allocPrint(allocator, "{s}/a/{s}", .{ root, socket_name });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target });
}

/// Remove stale runtime files after the caller has already decided the session
/// is not alive.
pub fn removeStaleHints(paths: SessionPaths) !void {
    try removeRuntimeSessionFiles(paths);
}

/// Clean shutdown removes runtime files. Durable routes live in the
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

fn expectRuntimeGuidMetaType(allocator: std.mem.Allocator, path: []const u8, expected: RuntimeGuidType) !u64 {
    const meta = try readRuntimeGuidMeta(allocator, path);
    try std.testing.expectEqual(expected, meta.guid_type);
    const created_at_unix_ms = meta.created_at_unix_ms orelse return error.MissingCreatedAt;
    try std.testing.expect(created_at_unix_ms > 0);
    return created_at_unix_ms;
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
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/a/550e8400e29b41d4a716446655440000", allocation.paths.socket);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/agent.sock", allocation.paths.agent_sock_link);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/meta.json", allocation.paths.meta);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/compat", allocation.paths.compat);
    try std.testing.expectEqualStrings("zig-cache/session-registry-path-test/guid/s-550e8400-e29b-41d4-a716-446655440000/route.json", allocation.paths.route);

    const link_target = try readLinkAlloc(allocator, allocation.paths.agent_sock_link, 4096);
    defer allocator.free(link_target);
    try std.testing.expectEqualStrings("../../a/550e8400e29b41d4a716446655440000", link_target);
}

test "long runtime roots use random socket names when compact guid does not fit" {
    const allocator = std.testing.allocator;
    const prefix = "zig-cache/session-registry-long-root-";
    const root_len = maxUnixSocketPathLen() - "/a/".len - 16;
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
    const expected_target = try std.fmt.allocPrint(allocator, "../../a/{s}", .{socket_name});
    defer allocator.free(expected_target);
    try std.testing.expectEqualStrings(expected_target, link_target);
}

test "runtime agent socket paths use typed guid directories and socket directory" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/runtime-agent-socket-path-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "p-550e8400-e29b-41d4-a716-446655440000";
    var paths = try runtimeAgentSocketPathsForGuidInRoot(allocator, root, guid);
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("zig-cache/runtime-agent-socket-path-test/guid/p-550e8400-e29b-41d4-a716-446655440000", paths.dir);
    try std.testing.expectEqualStrings("zig-cache/runtime-agent-socket-path-test/a/550e8400e29b41d4a716446655440000", paths.socket);
    try std.testing.expectEqualStrings("zig-cache/runtime-agent-socket-path-test/guid/p-550e8400-e29b-41d4-a716-446655440000/agent.sock", paths.agent_sock_link);
    try std.testing.expectEqualStrings("zig-cache/runtime-agent-socket-path-test/guid/p-550e8400-e29b-41d4-a716-446655440000/incoming-meta.json", paths.meta);
    const created_at_unix_ms = try expectRuntimeGuidMetaType(allocator, paths.meta, .incoming_proxy);

    const link_target = try readLinkAlloc(allocator, paths.agent_sock_link, 4096);
    defer allocator.free(link_target);
    try std.testing.expectEqualStrings("../../a/550e8400e29b41d4a716446655440000", link_target);

    var again = try runtimeAgentSocketPathsForGuidInRoot(allocator, root, guid);
    defer again.deinit(allocator);
    try std.testing.expectEqualStrings(paths.socket, again.socket);
    try std.testing.expectEqual(created_at_unix_ms, try expectRuntimeGuidMetaType(allocator, again.meta, .incoming_proxy));

    paths.removeRuntimeFiles();
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(paths.meta));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(paths.dir));
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

test "outgoing proxy hints use proxy runtime metadata without stealing incoming proxy cleanup" {
    const allocator = std.testing.allocator;
    const root = "zig-cache/outgoing-proxy-hint-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "p-550e8400-e29b-41d4-a716-446655440000";
    const dir = "zig-cache/outgoing-proxy-hint-test/guid/p-550e8400-e29b-41d4-a716-446655440000";
    const incoming_meta_path = "zig-cache/outgoing-proxy-hint-test/guid/p-550e8400-e29b-41d4-a716-446655440000/incoming-meta.json";
    const outgoing_meta_path = "zig-cache/outgoing-proxy-hint-test/guid/p-550e8400-e29b-41d4-a716-446655440000/outgoing-meta.json";

    try writeOutgoingProxyHintInRoot(allocator, root, guid);
    _ = try expectRuntimeGuidMetaType(allocator, outgoing_meta_path, .outgoing_proxy);
    try removeOutgoingProxyHintInRoot(allocator, root, guid);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(outgoing_meta_path));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(dir));

    try writeOutgoingProxyHintInRoot(allocator, root, guid);
    var incoming = try runtimeAgentSocketPathsForGuidInRoot(allocator, root, guid);
    defer incoming.deinit(allocator);
    _ = try expectRuntimeGuidMetaType(allocator, incoming_meta_path, .incoming_proxy);
    _ = try expectRuntimeGuidMetaType(allocator, outgoing_meta_path, .outgoing_proxy);

    try removeOutgoingProxyHintInRoot(allocator, root, guid);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(outgoing_meta_path));
    _ = try expectRuntimeGuidMetaType(allocator, incoming_meta_path, .incoming_proxy);
    incoming.removeRuntimeFiles();
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(dir));
}

test "validates session ids and short typed prefixes" {
    try std.testing.expect(isValidSessionId("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidSessionId("550e8400e29b41d4a716446655440000"));
    try std.testing.expect(isValidSessionGuid("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidClientGuid("c-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidProxyGuid("p-550e8400-e29b-41d4-a716-446655440000"));
    const generated_client = try generateClientGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_client);
    try std.testing.expect(isValidClientGuid(generated_client));
    const generated_proxy = try generateProxyGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_proxy);
    try std.testing.expect(isValidProxyGuid(generated_proxy));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId("c-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("s1"));
    try std.testing.expect(!isValidSessionId("550e8400-e29b-41d4-a716-44665544000z"));
    try std.testing.expect(isValidSessionGuidPrefix("s-5"));
    try std.testing.expect(isValidSessionGuidPrefix("s-550e8400"));
    try std.testing.expect(isValidSessionGuidPrefix("s-550e8400-e"));
    try std.testing.expect(isValidClientGuidPrefix("c-550e8400"));

    const short_session = try shortSessionGuid(std.testing.allocator, "s-550e8400-e29b-41d4-a716-446655440000");
    defer std.testing.allocator.free(short_session);
    try std.testing.expectEqualStrings("s-550e8400", short_session);
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
        "{{\"guid\":\"s-550e8400-e29b-41d4-a716-446655440000\",\"session_dir\":{f},\"host\":\"work.example\",\"agent_version\":\"0.5.0-test\",\"alive\":true,\"ssh_options\":[\"-F\"]}}\n",
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
    try std.testing.expectEqualStrings("0.5.0-test", route.agent_version);
    try std.testing.expect(route.last_known_alive);
    try std.testing.expectEqual(@as(usize, 1), route.ssh_options.len);
    try std.testing.expectEqualStrings("-F", route.ssh_options[0]);
}

test "tombstone snapshots route details and removes route" {
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

    var route = Route{
        .guid = try allocator.dupe(u8, guid),
        .session_dir = try allocator.dupe(u8, "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000"),
        .host_guid = try allocator.dupe(u8, "h-550e8400-e29b-41d4-a716-446655440001"),
        .host = try allocator.dupe(u8, "work.example"),
        .resolved_host = try allocator.dupe(u8, "resolved.example"),
        .port = try allocator.dupe(u8, default_ssh_port),
        .agent_version = try allocator.dupe(u8, "0.5.0-test"),
        .ssh_options = try allocator.alloc([]const u8, 0),
        .last_known_alive = true,
        .tombstone_retention_ms = 500,
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
    try std.testing.expectEqualStrings("work.example", tombstone.host);
    try std.testing.expectEqual(@as(u64, 1234), tombstone.ended_at_unix_ms);
    try std.testing.expectEqual(TombstoneEndReason.process_exited, tombstone.end_reason);
    try std.testing.expectEqual(TombstoneExitStatusKind.exited, tombstone.exit_status.?.kind);
    try std.testing.expectEqual(@as(i32, 7), tombstone.exit_status.?.status);

    const short_guid = try resolveTombstoneRefToGuidInRoot(allocator, root, "s-550e8400");
    defer allocator.free(short_guid);
    try std.testing.expectEqualStrings(guid, short_guid);
}

test "expired tombstone cleanup removes tombstone" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/sessh-tombstone-expiry-test-{}", .{c.getpid()});
    defer allocator.free(root);
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    const guid = "s-550e8400-e29b-41d4-a716-446655440000";

    var route = Route{
        .guid = try allocator.dupe(u8, guid),
        .session_dir = try allocator.dupe(u8, "/tmp/sessh-runtime-test/guid/s-550e8400-e29b-41d4-a716-446655440000"),
        .host_guid = try allocator.dupe(u8, ""),
        .host = try allocator.dupe(u8, "."),
        .resolved_host = try allocator.dupe(u8, "."),
        .port = try allocator.dupe(u8, default_ssh_port),
        .agent_version = try allocator.dupe(u8, "0.5.0-test"),
        .ssh_options = try allocator.alloc([]const u8, 0),
        .last_known_alive = true,
        .tombstone_retention_ms = 500,
    };
    defer route.deinit(allocator);

    try writeTombstoneForRouteInRoot(allocator, root, &route, .{
        .ended_at_unix_ms = 100,
        .end_reason = .killed_by_request,
        .exit_status = null,
    });

    try cleanupExpiredTombstonesInRoot(allocator, root, 599);
    const retained_path = try tombstonePathForGuidInRoot(allocator, root, guid);
    defer allocator.free(retained_path);
    _ = try std.fs.cwd().statFile(retained_path);

    try cleanupExpiredTombstonesInRoot(allocator, root, 600);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(retained_path));
    try std.testing.expectError(error.FileNotFound, resolveTombstoneRefToGuidInRoot(allocator, root, "s-550e8400"));
}
