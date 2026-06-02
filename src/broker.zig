const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const io = @import("io.zig");
const list_format = @import("list_format.zig");
const process_exit = @import("process_exit.zig");
const protocol = @import("protocol.zig");
const relay = @import("relay.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

const command_timeout_ms: i64 = 2_000;
const command_poll_ms: u64 = 20;
const client_list_target_help = "incoming, outgoing, session, or a guid/alias";

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    socket_transport.publishRuntimeRootSymlinkOnce(allocator);

    if (args.len > 0) return runCommandArgs(allocator, args);

    const handshake_result = try acceptRuntimeHandshake(allocator, 0, 1);
    if (handshake_result == .mismatch) return;

    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, 0);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .resize => continue,
            .session_attach => {
                const agent_fd = connectAgentForAttach(allocator, frame.payload) catch |err| switch (err) {
                    error.NoSessions => {
                        try sendError(1, "SESSION_NOT_FOUND", "no sessions", "");
                        return;
                    },
                    error.SessionRefNotLocal => {
                        try sendError(1, "SESSION_REF_NOT_LOCAL", "session reference resolves to another host", "");
                        return;
                    },
                    error.SessionAlreadyExited => {
                        try sendError(1, "SESSION_ALREADY_EXITED", "session already exited", "");
                        return;
                    },
                    error.InvalidSessionId, error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
                        try sendError(1, "SESSION_NOT_FOUND", "session not found", "");
                        return;
                    },
                    else => return err,
                };
                defer _ = c.close(agent_fd);
                try attachAgentAndRelay(allocator, agent_fd, frame.payload);
                return;
            },
            .session_create => {
                const agent_fd = startSessionAgentAndConnect(allocator, exe, frame.payload) catch |err| switch (err) {
                    error.AliasExists => {
                        try sendError(1, "ALIAS_EXISTS", "session alias already exists", "");
                        return;
                    },
                    error.InvalidAlias => {
                        try sendError(1, "INVALID_ALIAS", "invalid session alias", "");
                        return;
                    },
                    else => return err,
                };
                defer _ = c.close(agent_fd);
                try createSessionAndRelay(allocator, agent_fd, frame.payload);
                return;
            },
            else => {
                try sendError(1, "PROTOCOL_ERROR", "broker only supports SESSION_CREATE or SESSION_ATTACH in this mode", "");
                return;
            },
        }
    }
}

fn runCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        const options = parseListOptions(args) catch |err| {
            if (err == error.MissingClientListTarget) {
                return finishCommand(64, "", "ERROR --client requires a value: " ++ client_list_target_help ++ "\n");
            }
            return finishCommand(64, "", "ERROR usage: list [--host-display HOST] [--jsonl] [--all] [--exited] [--local-only] [--client incoming|outgoing|session|ID]\n");
        };
        const exit_status = if (options.client_selector == .none)
            try listAgents(allocator, options)
        else
            try listClients(allocator, options);
        return process_exit.request(exit_status);
    }
    if (std.mem.eql(u8, command, "kill")) {
        if (args.len == 1) {
            return finishCommand(64, "", "ERROR kill requires --all, a guid, or --current\n");
        }
        if (args.len != 2) return finishCommand(64, "", "ERROR usage: kill --all | kill ID | kill --current\n");
        if (std.mem.eql(u8, args[1], "--all")) return killAllAgents(allocator);
        if (std.mem.eql(u8, args[1], "--current")) return killCurrentAgent(allocator);
        if (std.mem.startsWith(u8, args[1], "--")) return finishCommand(64, "", "ERROR usage: kill --all | kill ID | kill --current\n");
        return killOneAgent(allocator, args[1]);
    }
    if (isClientControlCommandName(command)) {
        const client_command = parseClientControlCommand(args) catch return finishCommand(64, "", "ERROR usage: detach|repaint|debug [options] ID\n");
        return runClientControlCommand(allocator, client_command);
    }
    return finishCommand(64, "", "ERROR unknown broker command\n");
}

fn isClientControlCommandName(command: []const u8) bool {
    return std.mem.eql(u8, command, "detach") or
        std.mem.eql(u8, command, "repaint") or
        std.mem.eql(u8, command, "debug");
}

fn finishCommand(exit_status: u8, stdout: []const u8, stderr: []const u8) !void {
    if (stdout.len > 0) try io.writeAll(1, stdout);
    if (stderr.len > 0) try io.writeAll(2, stderr);
    return process_exit.request(exit_status);
}

const ListFormat = enum {
    table,
    jsonl,
};

const ListMode = enum {
    live,
    exited,
};

const ClientListSelector = union(enum) {
    none,
    incoming,
    outgoing,
    session,
    session_ref: []const u8,
    client_ref: []const u8,
};

const ListOptions = struct {
    host_display: []const u8 = ".",
    format: ListFormat = .table,
    mode: ListMode = .live,
    all: bool = false,
    local_only: bool = false,
    client_selector: ClientListSelector = .none,
};

const ClientControlTarget = struct {
    kind: pb.ClientControlTargetKind,
    client_guid: []const u8 = "",

    fn proto(self: ClientControlTarget) pb.ClientControlTarget {
        return .{
            .target_kind = self.kind,
            .client_guid = self.client_guid,
        };
    }
};

const ClientDetachCommand = struct {
    session_ref: ?[]const u8,
    target: ClientControlTarget,
};

const ClientRepaintCommand = struct {
    session_ref: ?[]const u8,
    target: ClientControlTarget,
    include_scrollback: bool = false,
};

const ClientDebugSeverConnectionCommand = struct {
    session_ref: ?[]const u8,
    target: ClientControlTarget,
};

const ClientDebugUnresponsiveConnectionCommand = struct {
    session_ref: ?[]const u8,
    target: ClientControlTarget,
    seconds: u32 = config.default_debug_unresponsive_seconds,
};

const ClientControlCommand = union(enum) {
    detach: ClientDetachCommand,
    repaint: ClientRepaintCommand,
    debug_sever_connection: ClientDebugSeverConnectionCommand,
    debug_unresponsive_connection: ClientDebugUnresponsiveConnectionCommand,

    fn sessionRef(self: ClientControlCommand) ?[]const u8 {
        return switch (self) {
            inline else => |command| command.session_ref,
        };
    }

    fn target(self: ClientControlCommand) ClientControlTarget {
        return switch (self) {
            inline else => |command| command.target,
        };
    }

    fn resultVerb(self: ClientControlCommand) []const u8 {
        return switch (self) {
            .detach => "DETACHED",
            .repaint => "REPAINTED",
            .debug_sever_connection => "SEVERED",
            .debug_unresponsive_connection => "UNRESPONSIVE",
        };
    }
};

fn parseListOptions(args: []const []const u8) !ListOptions {
    var options = ListOptions{};
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--host-display")) {
            i += 1;
            if (i >= args.len) return error.MissingHostDisplay;
            options.host_display = args[i];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--jsonl")) {
            options.format = .jsonl;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            options.all = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--exited")) {
            options.mode = .exited;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--local-only")) {
            options.local_only = true;
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--client=")) {
            if (options.client_selector != .none) return error.InvalidListArgs;
            const value = args[i]["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            options.client_selector = parseClientListSelector(value);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--client")) {
            if (options.client_selector != .none) return error.InvalidListArgs;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingClientListTarget;
            options.client_selector = parseClientListSelector(args[i]);
            i += 1;
        } else {
            return error.InvalidListArgs;
        }
    }
    if (options.client_selector != .none and (options.mode == .exited or options.local_only)) return error.InvalidListArgs;
    if (options.all and (options.mode == .exited or options.client_selector != .none)) return error.InvalidListArgs;
    return options;
}

fn parseClientListSelector(value: []const u8) ClientListSelector {
    if (std.mem.eql(u8, value, "incoming")) return .incoming;
    if (std.mem.eql(u8, value, "outgoing")) return .outgoing;
    if (std.mem.eql(u8, value, "session")) return .session;
    if (std.mem.startsWith(u8, value, session_registry.client_guid_prefix)) return .{ .client_ref = value };
    return .{ .session_ref = value };
}

fn parseClientControlCommand(args: []const []const u8) !ClientControlCommand {
    const command = args[0];
    var i: usize = 1;
    const command_kind: enum { detach, repaint, debug_sever_connection, debug_unresponsive_connection } =
        if (std.mem.eql(u8, command, "detach"))
            .detach
        else if (std.mem.eql(u8, command, "repaint"))
            .repaint
        else if (std.mem.eql(u8, command, "debug")) blk: {
            if (i >= args.len) return error.MissingDebugAction;
            const debug_action = args[i];
            i += 1;
            if (std.mem.eql(u8, debug_action, "sever-connection")) {
                break :blk .debug_sever_connection;
            } else if (std.mem.eql(u8, debug_action, "unresponsive-connection")) {
                break :blk .debug_unresponsive_connection;
            } else {
                return error.InvalidDebugAction;
            }
        } else return error.InvalidClientControlCommand;

    var target_kind: pb.ClientControlTargetKind = if (command_kind == .repaint)
        .CLIENT_CONTROL_TARGET_KIND_ALL
    else
        .CLIENT_CONTROL_TARGET_KIND_DEFAULT;
    var explicit_target = false;
    var client_guid: []const u8 = "";
    var include_scrollback = false;
    var debug_unresponsive_seconds: u32 = config.default_debug_unresponsive_seconds;
    var session_ref: ?[]const u8 = null;

    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--all")) {
            if (explicit_target) return error.MultipleTargets;
            explicit_target = true;
            target_kind = .CLIENT_CONTROL_TARGET_KIND_ALL;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--last-input")) {
            if (explicit_target) return error.MultipleTargets;
            explicit_target = true;
            target_kind = .CLIENT_CONTROL_TARGET_KIND_LAST_INPUT;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--scrollback")) {
            if (command_kind != .repaint) return error.UnsupportedClientControlArgs;
            include_scrollback = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seconds")) {
            if (command_kind != .debug_unresponsive_connection) return error.UnsupportedClientControlArgs;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingDebugSeconds;
            debug_unresponsive_seconds = try parseDebugUnresponsiveSeconds(args[i]);
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            return error.InvalidClientControlArgs;
        } else if (!explicit_target and std.mem.startsWith(u8, args[i], session_registry.client_guid_prefix)) {
            explicit_target = true;
            client_guid = args[i];
            target_kind = .CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID;
            i += 1;
        } else if (session_ref == null) {
            session_ref = args[i];
            i += 1;
        } else {
            return error.InvalidClientControlArgs;
        }
    }

    const target = ClientControlTarget{
        .kind = target_kind,
        .client_guid = client_guid,
    };
    const resolved_session_ref = session_ref orelse blk: {
        if (target.kind == .CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID) break :blk null;
        return error.MissingSessionRef;
    };
    return switch (command_kind) {
        .detach => .{ .detach = .{
            .session_ref = resolved_session_ref,
            .target = target,
        } },
        .repaint => .{ .repaint = .{
            .session_ref = resolved_session_ref,
            .target = target,
            .include_scrollback = include_scrollback,
        } },
        .debug_sever_connection => .{ .debug_sever_connection = .{
            .session_ref = resolved_session_ref,
            .target = target,
        } },
        .debug_unresponsive_connection => .{ .debug_unresponsive_connection = .{
            .session_ref = resolved_session_ref,
            .target = target,
            .seconds = debug_unresponsive_seconds,
        } },
    };
}

fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}

fn listAgents(allocator: std.mem.Allocator, options: ListOptions) !u8 {
    try session_registry.cleanupExpiredTombstones(allocator, nowUnixMs());
    if (options.all) return listAllAgents(allocator, options);
    if (options.mode == .exited) return listExitedAgents(allocator, options);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    const writer = stdout.writer(allocator);
    if (options.format == .table) try list_format.writeHeader(writer);
    const now_ms = nowUnixMs();

    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try io.writeAll(1, stdout.items);
            return 0;
        },
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        defer paths.deinit(allocator);
        var meta = session_registry.readMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            tombstoneRouteForDeadLocalSession(allocator, paths, now_ms) catch {};
            session_registry.removeStaleHints(paths) catch {};
            continue;
        }
        const guid = session_registry.canonicalGuid(allocator, entry.name) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer allocator.free(guid);
        const display_id = (try session_registry.primaryAliasForGuid(allocator, guid)) orelse try session_registry.shortSessionGuid(allocator, guid);
        defer allocator.free(display_id);

        const live = querySessionListLiveStatus(allocator, paths) catch null;
        switch (options.format) {
            .table => {
                var attached_buf: [32]u8 = undefined;
                var input_buf: [32]u8 = undefined;
                const attached = formatAttachedCount(&attached_buf, if (live) |status| status.attached_count else null);
                const input = try formatOptionalRelativeUnixMs(&input_buf, now_ms, if (live) |status| status.last_input_at_unix_ms else null);
                try list_format.writeRow(writer, display_id, attached, input, options.host_display, meta.version);
            },
            .jsonl => try list_format.writeJsonlRow(
                writer,
                display_id,
                options.host_display,
                meta.version,
                guid,
                if (live) |status| status.attached_count else null,
                if (live) |status| status.last_input_at_unix_ms else null,
            ),
        }
    }

    try io.writeAll(1, stdout.items);
    return 0;
}

fn listAllAgents(allocator: std.mem.Allocator, options: ListOptions) !u8 {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const state_root = try socket_transport.stateRoot(allocator);
    defer allocator.free(state_root);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    try writeAllRowsFromRoots(allocator, stdout.writer(allocator), options, runtime_root, state_root);
    try io.writeAll(1, stdout.items);
    return 0;
}

fn writeAllRowsFromRoots(
    allocator: std.mem.Allocator,
    writer: anytype,
    options: ListOptions,
    runtime_root: []const u8,
    state_root: []const u8,
) !void {
    if (options.format == .table) try list_format.writeAllHeader(writer);
    const now_ms = nowUnixMs();
    try writeRuntimeGuidAllRows(allocator, writer, options, runtime_root, now_ms);
    if (!options.local_only) try writeRemoteSessionAllRows(allocator, writer, options, state_root, now_ms);
}

fn writeRuntimeGuidAllRows(
    allocator: std.mem.Allocator,
    writer: anytype,
    options: ListOptions,
    runtime_root: []const u8,
    now_ms: u64,
) !void {
    const guid_root = try session_registry.sessionsDirInRoot(allocator, runtime_root);
    defer allocator.free(guid_root);
    var dir = std.fs.openDirAbsolute(guid_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        const entry_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guid_root, entry.name });
        defer allocator.free(entry_dir);
        const display_id = session_registry.shortRuntimeGuid(allocator, entry.name) catch continue;
        defer allocator.free(display_id);
        const info = if (std.mem.eql(u8, options.host_display, "."))
            ""
        else
            try std.fmt.allocPrint(allocator, "host={s}", .{options.host_display});
        defer if (!std.mem.eql(u8, options.host_display, ".")) allocator.free(info);
        for (session_registry.runtimeGuidMetaFilenamesForGuid(entry.name)) |filename| {
            const meta_path = try session_registry.runtimeGuidMetaPathForFilenameInDir(allocator, entry_dir, filename);
            defer allocator.free(meta_path);
            const meta = session_registry.readRuntimeGuidMeta(allocator, meta_path) catch continue;
            try writeAllIdentityRow(
                writer,
                options.format,
                now_ms,
                display_id,
                entry.name,
                session_registry.runtimeGuidTypeName(meta.guid_type),
                meta.created_at_unix_ms,
                info,
            );
        }
    }
}

fn writeRemoteSessionAllRows(
    allocator: std.mem.Allocator,
    writer: anytype,
    options: ListOptions,
    state_root: []const u8,
    now_ms: u64,
) !void {
    const state_sessions_dir = try std.fmt.allocPrint(allocator, "{s}/guid", .{state_root});
    defer allocator.free(state_sessions_dir);
    var dir = std.fs.openDirAbsolute(state_sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        const route_path = try std.fmt.allocPrint(allocator, "{s}/{s}/route.json", .{ state_sessions_dir, entry.name });
        defer allocator.free(route_path);
        var route = session_registry.readRoute(allocator, route_path) catch continue;
        defer route.deinit(allocator);
        if (route.host.len == 0 or std.mem.eql(u8, route.host, ".") or !route.last_known_alive) continue;

        const info = try std.fmt.allocPrint(allocator, "host={s} version={s}", .{ route.host, route.agent_version });
        defer allocator.free(info);
        const display_id = try session_registry.shortSessionGuid(allocator, route.guid);
        defer allocator.free(display_id);
        try writeAllIdentityRow(writer, options.format, now_ms, display_id, route.guid, "remote-session", null, info);
    }
}

fn writeAllIdentityRow(
    writer: anytype,
    format: ListFormat,
    now_ms: u64,
    id: []const u8,
    guid: []const u8,
    type_name: []const u8,
    created_at_unix_ms: ?u64,
    info: []const u8,
) !void {
    switch (format) {
        .table => {
            var created_buf: [32]u8 = undefined;
            const created = if (created_at_unix_ms) |ts| try formatRelativeUnixMs(&created_buf, now_ms, ts) else "???";
            try list_format.writeAllRow(writer, id, type_name, created, info);
        },
        .jsonl => try list_format.writeAllJsonlRow(writer, id, guid, type_name, created_at_unix_ms, info),
    }
}

fn tombstoneRouteForDeadLocalSession(allocator: std.mem.Allocator, paths: session_registry.SessionPaths, now_ms: u64) !void {
    var route = session_registry.readRoute(allocator, paths.route) catch return;
    defer route.deinit(allocator);
    try session_registry.writeTombstoneForRoute(allocator, &route, .{
        .ended_at_unix_ms = now_ms,
        .end_reason = .unknown,
        .exit_status = null,
    });
}

fn listExitedAgents(allocator: std.mem.Allocator, options: ListOptions) !u8 {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    const writer = stdout.writer(allocator);
    if (options.format == .table) try list_format.writeExitedHeader(writer);
    const now_ms = nowUnixMs();

    const tombstones_dir = try session_registry.tombstonesDir(allocator);
    defer allocator.free(tombstones_dir);
    var dir = std.fs.openDirAbsolute(tombstones_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try io.writeAll(1, stdout.items);
            return 0;
        },
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tombstones_dir, entry.name });
        defer allocator.free(path);
        var tombstone = session_registry.readTombstone(allocator, path) catch continue;
        defer tombstone.deinit(allocator);
        if (options.local_only and tombstone.host.len > 0 and !std.mem.eql(u8, tombstone.host, ".")) continue;

        const display_id = try tombstoneDisplayId(allocator, &tombstone);
        defer allocator.free(display_id);

        switch (options.format) {
            .table => {
                var ended_buf: [32]u8 = undefined;
                var status_buf: [32]u8 = undefined;
                const ended = try formatRelativeUnixMs(&ended_buf, now_ms, tombstone.ended_at_unix_ms);
                const status = formatTombstoneStatus(&status_buf, &tombstone);
                try list_format.writeExitedRow(writer, display_id, ended, tombstone.host, status, tombstone.agent_version);
            },
            .jsonl => try list_format.writeExitedJsonlRow(
                writer,
                display_id,
                tombstone.aliases,
                tombstone.host,
                tombstone.agent_version,
                tombstone.guid,
                tombstone.ended_at_unix_ms,
                session_registry.tombstoneEndReasonName(tombstone.end_reason),
                if (tombstone.exit_status) |status| .{
                    .kind = session_registry.tombstoneExitStatusKindName(status.kind),
                    .status = status.status,
                } else null,
            ),
        }
    }

    try io.writeAll(1, stdout.items);
    return 0;
}

fn tombstoneDisplayId(allocator: std.mem.Allocator, tombstone: *const session_registry.Tombstone) ![]u8 {
    if (tombstone.primary_alias.len > 0) return allocator.dupe(u8, tombstone.primary_alias);
    if (tombstone.aliases.len > 0) return allocator.dupe(u8, tombstone.aliases[0]);
    return session_registry.shortSessionGuid(allocator, tombstone.guid);
}

fn formatTombstoneStatus(buf: []u8, tombstone: *const session_registry.Tombstone) []const u8 {
    if (tombstone.end_reason == .killed_by_request) return "KILLED";
    if (tombstone.exit_status) |status| {
        return switch (status.kind) {
            .exited => std.fmt.bufPrint(buf, "EXIT {}", .{status.status}) catch "UNKNOWN",
            .signalled => std.fmt.bufPrint(buf, "SIGNAL {}", .{status.status}) catch "UNKNOWN",
        };
    }
    return "UNKNOWN";
}

fn querySessionListLiveStatus(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !session_registry.RouteLiveStatus {
    var state = try querySessionLiveState(allocator, paths);
    defer state.deinit(allocator);
    return .{
        .attached_count = @intCast(state.attached_clients.items.len),
        .last_input_at_unix_ms = state.last_input_at_unix_ms,
        .detached_at_unix_ms = state.detached_at_unix_ms,
    };
}

fn listClients(allocator: std.mem.Allocator, options: ListOptions) !u8 {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    const writer = stdout.writer(allocator);
    if (options.format == .table) try writeClientTableHeader(writer);

    const exit_status = switch (options.client_selector) {
        .none => unreachable,
        .incoming => try listIncomingClients(allocator, writer, options),
        .outgoing => try listOutgoingClients(allocator, writer, options),
        .session => blk: {
            const session_ref = std.process.getEnvVarOwned(allocator, "SESSH_GUID") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    try io.writeAll(2, "ERROR --client=session requires $SESSH_GUID\n");
                    return 1;
                },
                else => return err,
            };
            defer allocator.free(session_ref);
            break :blk try listClientsForSessionRef(allocator, writer, options, session_ref);
        },
        .session_ref => |session_ref| try listClientsForSessionRef(allocator, writer, options, session_ref),
        .client_ref => |client_ref| try listClientByRef(allocator, writer, options, client_ref),
    };
    if (exit_status == 0 and stdout.items.len > 0) try io.writeAll(1, stdout.items);
    return exit_status;
}

fn listClientsForSessionRef(allocator: std.mem.Allocator, writer: anytype, options: ListOptions, session_ref: []const u8) !u8 {
    var paths = pathsForLocalSessionRef(allocator, session_ref) catch |err| switch (err) {
        error.SessionAlreadyExited => {
            try io.writeAll(2, "ERROR session already exited\n");
            return 1;
        },
        error.InvalidSessionId, error.FileNotFound, error.SessionRefNotLocal => {
            try writeClientListSessionNotFound(session_ref);
            return 1;
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    return listClientsForSessionPaths(allocator, writer, options, paths);
}

fn writeClientListSessionNotFound(session_ref: []const u8) !void {
    try io.stderrPrint(
        "ERROR session not found for --client {s}; expected: {s}\n",
        .{ session_ref, client_list_target_help },
    );
}

fn listClientsForSessionPaths(allocator: std.mem.Allocator, writer: anytype, options: ListOptions, paths: session_registry.SessionPaths) !u8 {
    var meta = session_registry.readMeta(allocator, paths) catch {
        session_registry.removeStaleHints(paths) catch {};
        try io.writeAll(2, "ERROR session not found\n");
        return 1;
    };
    defer meta.deinit(allocator);
    if (!processExists(meta.agent_pid)) {
        session_registry.removeStaleHints(paths) catch {};
        try io.writeAll(2, "ERROR session not found\n");
        return 1;
    }

    var state = querySessionLiveState(allocator, paths) catch |err| {
        try writeCommandErrorForAgentFailure(err);
        return 1;
    };
    defer state.deinit(allocator);
    std.mem.sort(pb.AttachedClient, state.attached_clients.items, {}, attachedClientSortLessThan);

    const session_guid = std.fs.path.basename(paths.dir);
    const display_id = (try session_registry.primaryAliasForGuid(allocator, session_guid)) orelse try session_registry.shortSessionGuid(allocator, session_guid);
    defer allocator.free(display_id);
    try writeClientRows(writer, options.format, display_id, session_guid, options.host_display, state.attached_clients.items, null);
    return 0;
}

fn listIncomingClients(allocator: std.mem.Allocator, writer: anytype, options: ListOptions) !u8 {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        defer paths.deinit(allocator);
        _ = try listClientsForSessionPaths(allocator, writer, options, paths);
    }
    return 0;
}

fn listClientByRef(allocator: std.mem.Allocator, writer: anytype, options: ListOptions, client_ref: []const u8) !u8 {
    const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, client_ref) catch |err| switch (err) {
        error.InvalidClientId => {
            try io.writeAll(2, "ERROR invalid client target\n");
            return 64;
        },
        error.AmbiguousClientId => {
            try io.writeAll(2, "ERROR client target is ambiguous\n");
            return 1;
        },
        error.FileNotFound => {
            try io.writeAll(2, "ERROR client not found\n");
            return 1;
        },
        else => return err,
    };
    defer allocator.free(socket_path);

    var state = querySessionLiveStateFromSocketPath(allocator, socket_path) catch |err| {
        try writeCommandErrorForAgentFailure(err);
        return 1;
    };
    defer state.deinit(allocator);
    std.mem.sort(pb.AttachedClient, state.attached_clients.items, {}, attachedClientSortLessThan);

    const session_guid = try sessionGuidFromClientAgentSocketHint(allocator, socket_path);
    defer allocator.free(session_guid);
    const display_id = (try session_registry.primaryAliasForGuid(allocator, session_guid)) orelse try session_registry.shortSessionGuid(allocator, session_guid);
    defer allocator.free(display_id);
    try writeClientRows(writer, options.format, display_id, session_guid, options.host_display, state.attached_clients.items, client_ref);
    return 0;
}

fn listOutgoingClients(allocator: std.mem.Allocator, writer: anytype, options: ListOptions) !u8 {
    const runtime_root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(runtime_root);
    const client_root = try session_registry.clientHintsDirInRoot(allocator, runtime_root);
    defer allocator.free(client_root);
    var dir = std.fs.openDirAbsolute(client_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidClientGuid(entry.name)) continue;
        const route_path = try std.fmt.allocPrint(allocator, "{s}/{s}/route.json", .{ client_root, entry.name });
        defer allocator.free(route_path);
        var route = session_registry.readRoute(allocator, route_path) catch continue;
        defer route.deinit(allocator);
        try writeCachedClientRow(writer, options.format, route.primary_alias, route.guid, route.host, entry.name, route.agent_version);
    }
    return 0;
}

fn writeClientTableHeader(writer: anytype) !void {
    try writePadded(writer, "CLIENT", list_format.id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "SESSION", list_format.id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "HOST", list_format.host_width);
    try writer.writeAll("  ");
    try writePadded(writer, "ATTACHED", list_format.attached_width);
    try writer.writeAll("  ");
    try writePadded(writer, "INPUT", list_format.input_width);
    try writer.writeAll("  ");
    try writer.writeAll("SIZE\n");
}

fn writeClientRows(
    writer: anytype,
    format: ListFormat,
    session_display_id: []const u8,
    session_guid: []const u8,
    host_display: []const u8,
    clients: []const pb.AttachedClient,
    client_filter_ref: ?[]const u8,
) !void {
    switch (format) {
        .table => {
            const now_ms = nowUnixMs();
            for (clients) |client_info| {
                if (client_filter_ref) |ref| {
                    if (!(try clientRefMatchesGuid(ref, client_info.client_guid))) continue;
                }
                try writeClientTableRow(writer, now_ms, session_display_id, host_display, client_info);
            }
        },
        .jsonl => {
            for (clients) |client_info| {
                if (client_filter_ref) |ref| {
                    if (!(try clientRefMatchesGuid(ref, client_info.client_guid))) continue;
                }
                try writeClientJsonlRow(writer, session_display_id, session_guid, host_display, client_info);
            }
        },
    }
}

fn writeClientTableRow(
    writer: anytype,
    now_ms: u64,
    session_display_id: []const u8,
    host_display: []const u8,
    client_info: pb.AttachedClient,
) !void {
    const client_id = try session_registry.shortClientGuid(app_allocator.allocator(), client_info.client_guid);
    defer app_allocator.allocator().free(client_id);
    var attached_buf: [32]u8 = undefined;
    var input_buf: [32]u8 = undefined;
    var size_buf: [24]u8 = undefined;
    const attached = try formatRelativeUnixMs(&attached_buf, now_ms, client_info.attached_at_unix_ms);
    const input = try formatOptionalRelativeUnixMs(&input_buf, now_ms, client_info.last_input_at_unix_ms);
    const size = if (client_info.terminal_size) |size_value|
        try std.fmt.bufPrint(&size_buf, "{}x{}", .{ size_value.terminal_rows, size_value.terminal_cols })
    else
        "unknown";
    try writePadded(writer, client_id, list_format.id_width);
    try writer.writeAll("  ");
    try writePadded(writer, session_display_id, list_format.id_width);
    try writer.writeAll("  ");
    try writePadded(writer, host_display, list_format.host_width);
    try writer.writeAll("  ");
    try writePadded(writer, attached, list_format.attached_width);
    try writer.writeAll("  ");
    try writePadded(writer, input, list_format.input_width);
    try writer.writeAll("  ");
    try writer.writeAll(size);
    try writer.writeAll("\n");
}

fn writeClientJsonlRow(
    writer: anytype,
    session_display_id: []const u8,
    session_guid: []const u8,
    host_display: []const u8,
    client_info: pb.AttachedClient,
) !void {
    try writer.writeAll("{\"client_guid\":");
    try writeJsonString(writer, client_info.client_guid);
    try writer.writeAll(",\"session_id\":");
    try writeJsonString(writer, session_display_id);
    try writer.writeAll(",\"session_guid\":");
    try writeJsonString(writer, session_guid);
    try writer.writeAll(",\"host\":");
    try writeJsonString(writer, host_display);
    try writer.print(",\"attached_at_unix_ms\":{}", .{client_info.attached_at_unix_ms});
    try writer.writeAll(",\"last_input_at_unix_ms\":");
    if (client_info.last_input_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"terminal_size\":");
    if (client_info.terminal_size) |size_value| {
        try writer.print(
            "{{\"terminal_rows\":{},\"terminal_cols\":{}}}",
            .{ size_value.terminal_rows, size_value.terminal_cols },
        );
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

fn writeCachedClientRow(
    writer: anytype,
    format: ListFormat,
    session_display_id: []const u8,
    session_guid: []const u8,
    host: []const u8,
    client_guid: []const u8,
    version: []const u8,
) !void {
    switch (format) {
        .table => {
            const client_id = try session_registry.shortClientGuid(app_allocator.allocator(), client_guid);
            defer app_allocator.allocator().free(client_id);
            try writePadded(writer, client_id, list_format.id_width);
            try writer.writeAll("  ");
            try writePadded(writer, session_display_id, list_format.id_width);
            try writer.writeAll("  ");
            try writePadded(writer, host, list_format.host_width);
            try writer.writeAll("  ");
            try writePadded(writer, "???", list_format.attached_width);
            try writer.writeAll("  ");
            try writePadded(writer, "???", list_format.input_width);
            try writer.writeAll("  ");
            try writer.writeAll("unknown");
            try writer.writeAll("\n");
        },
        .jsonl => {
            try writer.writeAll("{\"client_guid\":");
            try writeJsonString(writer, client_guid);
            try writer.writeAll(",\"session_id\":");
            try writeJsonString(writer, session_display_id);
            try writer.writeAll(",\"session_guid\":");
            try writeJsonString(writer, session_guid);
            try writer.writeAll(",\"host\":");
            try writeJsonString(writer, host);
            try writer.writeAll(",\"attached_at_unix_ms\":null,\"last_input_at_unix_ms\":null,\"terminal_size\":null");
            try writer.writeAll(",\"version\":");
            try writeJsonString(writer, version);
            try writer.writeAll("}\n");
        },
    }
}

fn clientRefMatchesGuid(ref: []const u8, guid: []const u8) !bool {
    if (std.mem.eql(u8, ref, guid)) return true;
    if (!std.mem.startsWith(u8, ref, session_registry.client_guid_prefix)) return false;
    const compact = try session_registry.compactClientGuid(app_allocator.allocator(), guid);
    defer app_allocator.allocator().free(compact);
    var ref_compact_buf: [session_registry.compact_guid_len]u8 = undefined;
    var ref_compact_len: usize = 0;
    for (ref[session_registry.client_guid_prefix.len..]) |byte| {
        if (byte == '-') continue;
        if (!std.ascii.isHex(byte) or ref_compact_len >= ref_compact_buf.len) return false;
        ref_compact_buf[ref_compact_len] = std.ascii.toLower(byte);
        ref_compact_len += 1;
    }
    if (ref_compact_len == 0) return false;
    return std.mem.startsWith(u8, compact, ref_compact_buf[0..ref_compact_len]);
}

fn sessionGuidFromClientAgentSocketHint(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const target = try readLinkAlloc(allocator, socket_path, 4096);
    defer allocator.free(target);
    const dirname = std.fs.path.dirname(target) orelse return error.InvalidSocketPath;
    const basename = std.fs.path.basename(dirname);
    return session_registry.canonicalGuid(allocator, basename);
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

fn runClientControlCommand(allocator: std.mem.Allocator, command: ClientControlCommand) !void {
    var response = if (command.sessionRef()) |session_ref|
        try runClientControlCommandForSessionRef(allocator, session_ref, command)
    else
        try runClientControlCommandForClientGuid(allocator, command);
    defer response.deinit(allocator);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    const writer = stdout.writer(allocator);
    const verb = command.resultVerb();
    for (response.affected_client_guid.items) |client_guid| {
        try writer.print("{s} {s}\n", .{ verb, client_guid });
    }
    return finishCommand(0, stdout.items, "");
}

fn runClientControlCommandForSessionRef(
    allocator: std.mem.Allocator,
    session_ref: []const u8,
    command: ClientControlCommand,
) !pb.SessionClientControlResponse {
    var paths = pathsForLocalSessionRef(allocator, session_ref) catch |err| switch (err) {
        error.SessionAlreadyExited => {
            return finishClientControlCommand(1, "", "ERROR session already exited\n");
        },
        error.InvalidSessionId, error.FileNotFound, error.SessionRefNotLocal => {
            return finishClientControlCommand(1, "", "ERROR session not found\n");
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    var meta = session_registry.readMeta(allocator, paths) catch {
        session_registry.removeStaleHints(paths) catch {};
        return finishClientControlCommand(1, "", "ERROR session not found\n");
    };
    defer meta.deinit(allocator);
    if (!processExists(meta.agent_pid)) {
        session_registry.removeStaleHints(paths) catch {};
        return finishClientControlCommand(1, "", "ERROR session not found\n");
    }

    return sendSessionClientControlRequest(allocator, paths, command) catch |err| {
        try writeCommandErrorForAgentFailure(err);
        return process_exit.request(1);
    };
}

fn runClientControlCommandForClientGuid(
    allocator: std.mem.Allocator,
    command: ClientControlCommand,
) !pb.SessionClientControlResponse {
    const target = command.target();
    if (target.kind != .CLIENT_CONTROL_TARGET_KIND_CLIENT_GUID) return finishClientControlCommand(1, "", "ERROR invalid client target\n");
    const socket_path = session_registry.clientAgentSocketPathForClientGuid(allocator, target.client_guid) catch |err| switch (err) {
        error.InvalidClientId => return finishClientControlCommand(1, "", "ERROR invalid client target\n"),
        error.AmbiguousClientId => return finishClientControlCommand(1, "", "ERROR client target is ambiguous\n"),
        error.FileNotFound => return finishClientControlCommand(1, "", "ERROR client not found\n"),
        else => return err,
    };
    defer allocator.free(socket_path);

    return sendSessionClientControlRequestToSocketPath(allocator, socket_path, command) catch |err| switch (err) {
        error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {
            return finishClientControlCommand(1, "", "ERROR client not found\n");
        },
        else => {
            try writeCommandErrorForAgentFailure(err);
            return process_exit.request(1);
        },
    };
}

fn finishClientControlCommand(exit_status: u8, stdout: []const u8, stderr: []const u8) !pb.SessionClientControlResponse {
    try finishCommand(exit_status, stdout, stderr);
    unreachable;
}

fn attachedClientSortLessThan(_: void, a: pb.AttachedClient, b: pb.AttachedClient) bool {
    const a_input = a.last_input_at_unix_ms orelse 0;
    const b_input = b.last_input_at_unix_ms orelse 0;
    if (a_input != b_input) return a_input > b_input;
    if (a.attached_at_unix_ms != b.attached_at_unix_ms) return a.attached_at_unix_ms > b.attached_at_unix_ms;
    return std.mem.lessThan(u8, a.client_guid, b.client_guid);
}

fn formatAttachedCount(buf: []u8, attached_count: ?u32) []const u8 {
    if (attached_count) |count| return std.fmt.bufPrint(buf, "{}", .{count}) catch "???";
    return "???";
}

fn formatOptionalRelativeUnixMs(buf: []u8, now_ms: u64, ts_ms: ?u64) ![]const u8 {
    if (ts_ms) |ts| return formatRelativeUnixMs(buf, now_ms, ts);
    return "never";
}

fn writePadded(writer: anytype, value: []const u8, width: usize) !void {
    try writer.writeAll(value);
    if (value.len >= width) return;
    for (0..(width - value.len)) |_| try writer.writeByte(' ');
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn formatRelativeUnixMs(buf: []u8, now_ms: u64, ts_ms: u64) ![]const u8 {
    const delta_ms = now_ms -| ts_ms;
    const seconds = delta_ms / std.time.ms_per_s;
    if (seconds < 60) return std.fmt.bufPrint(buf, "{}s ago", .{seconds});
    const minutes = seconds / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{}m ago", .{minutes});
    const hours = minutes / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{}h ago", .{hours});
    return std.fmt.bufPrint(buf, "{}d ago", .{hours / 24});
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn sendSessionClientControlRequest(
    allocator: std.mem.Allocator,
    paths: session_registry.SessionPaths,
    command: ClientControlCommand,
) !pb.SessionClientControlResponse {
    return sendSessionClientControlRequestToSocketPath(allocator, paths.socket, command);
}

fn sendSessionClientControlRequestToSocketPath(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    command: ClientControlCommand,
) !pb.SessionClientControlResponse {
    const fd = try socket_transport.connectSocket(socket_path);
    defer _ = c.close(fd);

    try initiateRuntimeHandshake(allocator, fd);
    const frame_type, const payload = try encodeClientControlRequest(allocator, command);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, frame_type, payload);

    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    switch (frame.message_type) {
        .session_client_control_response => return protocol.decodePayload(pb.SessionClientControlResponse, allocator, frame.payload),
        .error_message => {
            var message = try protocol.decodePayload(hpb.Error, allocator, frame.payload);
            defer message.deinit(allocator);
            try io.stderrPrint("ERROR {s}\n", .{message.message});
            return error.AgentRejectedClientControl;
        },
        else => return error.UnexpectedFrame,
    }
}

fn encodeClientControlRequest(
    allocator: std.mem.Allocator,
    command: ClientControlCommand,
) !struct { protocol.MessageType, []u8 } {
    return switch (command) {
        .detach => |detach| .{
            .session_client_detach_request,
            try protocol.encodePayload(allocator, pb.SessionClientDetachRequest{
                .target = detach.target.proto(),
            }),
        },
        .repaint => |repaint| .{
            .session_client_repaint_request,
            try protocol.encodePayload(allocator, pb.SessionClientRepaintRequest{
                .target = repaint.target.proto(),
                .include_scrollback = repaint.include_scrollback,
            }),
        },
        .debug_sever_connection => |debug| .{
            .session_client_debug_sever_connection_request,
            try protocol.encodePayload(allocator, pb.SessionClientDebugSeverConnectionRequest{
                .target = debug.target.proto(),
            }),
        },
        .debug_unresponsive_connection => |debug| .{
            .session_client_debug_unresponsive_connection_request,
            try protocol.encodePayload(allocator, pb.SessionClientDebugUnresponsiveConnectionRequest{
                .target = debug.target.proto(),
                .seconds = debug.seconds,
            }),
        },
    };
}

fn writeCommandErrorForAgentFailure(err: anyerror) !void {
    const message = switch (err) {
        error.AgentRejectedClientControl => "",
        error.SessionLiveStateUnavailable => "ERROR session state unavailable\n",
        error.VersionMismatch => "ERROR session agent is incompatible\n",
        error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => "ERROR session not found\n",
        else => "ERROR session command failed\n",
    };
    if (message.len == 0) return;
    try io.writeAll(2, message);
}

fn killOneAgent(allocator: std.mem.Allocator, session_id: []const u8) !void {
    var paths = pathsForLocalSessionRef(allocator, session_id) catch |err| switch (err) {
        error.SessionAlreadyExited => {
            return finishCommand(1, "", "ERROR session already exited\n");
        },
        error.InvalidSessionId, error.FileNotFound, error.SessionRefNotLocal => {
            return finishCommand(1, "", "ERROR session not found\n");
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    var meta = session_registry.readMeta(allocator, paths) catch {
        session_registry.removeStaleHints(paths) catch {};
        return finishCommand(1, "", "ERROR session not found\n");
    };
    defer meta.deinit(allocator);
    if (!processExists(meta.agent_pid)) {
        session_registry.removeStaleHints(paths) catch {};
        return finishCommand(1, "", "ERROR session not found\n");
    }
    if (!std.mem.eql(u8, meta.version, config.version)) {
        const session_guid = std.fs.path.basename(paths.dir);
        const exit_status = try runCompatCommand(allocator, paths, session_guid, &.{ "kill", session_guid });
        return process_exit.request(exit_status);
    }
    if (!terminateAgent(meta.agent_pid)) {
        return finishCommand(1, "", "ERROR failed to kill session agent\n");
    }
    var stdout_buf: [128]u8 = undefined;
    const stdout = try std.fmt.bufPrint(&stdout_buf, "ENDED {s}\n", .{session_id});
    return finishCommand(0, stdout, "");
}

fn killCurrentAgent(allocator: std.mem.Allocator) !void {
    const session_id = std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return finishCommand(64, "", "ERROR --current requires $SESSH_GUID\n"),
        else => return err,
    };
    defer allocator.free(session_id);
    return killOneAgent(allocator, session_id);
}

const KillTarget = struct {
    id: []u8,
    agent_pid: c.pid_t,
};

fn killAllAgents(allocator: std.mem.Allocator) !void {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return finishCommand(0, "KILLING_ALL\n", ""),
        else => return err,
    };
    defer dir.close();

    var targets: std.ArrayList(KillTarget) = .empty;
    defer {
        for (targets.items) |target| allocator.free(target.id);
        targets.deinit(allocator);
    }

    var exit_status: u8 = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        defer paths.deinit(allocator);
        var meta = session_registry.readMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            tombstoneRouteForDeadLocalSession(allocator, paths, nowUnixMs()) catch {};
            session_registry.removeStaleHints(paths) catch {};
            continue;
        }
        if (!std.mem.eql(u8, meta.version, config.version)) {
            const compat_status = try runCompatCommand(allocator, paths, entry.name, &.{ "kill", entry.name });
            if (compat_status != 0) exit_status = compat_status;
            continue;
        }
        try targets.append(allocator, .{
            .id = try allocator.dupe(u8, entry.name),
            .agent_pid = meta.agent_pid,
        });
    }

    for (targets.items) |target| {
        if (!signalProcess(target.agent_pid, c.SIG.TERM) and processExists(target.agent_pid)) {
            try io.writeAll(2, "ERROR failed to signal session agent\n");
            exit_status = 1;
        }
    }
    waitForAgents(targets.items, command_timeout_ms);
    for (targets.items) |target| {
        if (!processExists(target.agent_pid)) continue;
        _ = signalProcess(target.agent_pid, c.SIG.KILL);
        exit_status = 1;
    }
    waitForAgents(targets.items, 500);
    try io.writeAll(1, "KILLING_ALL\n");
    return process_exit.request(exit_status);
}

fn processExists(pid: c.pid_t) bool {
    posix.kill(pid, 0) catch return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn signalProcess(pid: c.pid_t, signal: u8) bool {
    posix.kill(pid, signal) catch return false;
    return true;
}

fn terminateAgent(pid: c.pid_t) bool {
    if (!signalProcess(pid, c.SIG.TERM) and processExists(pid)) return false;
    if (waitForAgentExit(pid, command_timeout_ms)) return true;
    _ = signalProcess(pid, c.SIG.KILL);
    return waitForAgentExit(pid, 500);
}

fn waitForAgents(targets: []const KillTarget, timeout_ms: i64) void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        var any_alive = false;
        for (targets) |target| {
            if (processExists(target.agent_pid)) {
                any_alive = true;
                break;
            }
        }
        if (!any_alive or std.time.milliTimestamp() >= deadline) return;
        std.Thread.sleep(command_poll_ms * std.time.ns_per_ms);
    }
}

fn waitForAgentExit(pid: c.pid_t, timeout_ms: i64) bool {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (processExists(pid)) {
        if (std.time.milliTimestamp() >= deadline) return false;
        std.Thread.sleep(command_poll_ms * std.time.ns_per_ms);
    }
    return true;
}

fn runCompatCommand(allocator: std.mem.Allocator, paths: session_registry.SessionPaths, session_id: []const u8, args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 2 + args.len);
    defer allocator.free(argv);
    argv[0] = paths.compat;
    argv[1] = ".";
    @memcpy(argv[2..], args);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put(config.session_guid_env, session_id);
    try env_map.put(config.client_version_env, config.version);
    try env_map.put(config.compat_env, "1");

    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn connectAgentForAttach(allocator: std.mem.Allocator, payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.SessionAttach, allocator, payload);
    defer request.deinit(allocator);
    var paths = if (request.session_dir.len > 0) blk: {
        if (!std.mem.startsWith(u8, request.session_dir, "/")) return error.InvalidSessionDir;
        break :blk try session_registry.pathsForSessionDir(allocator, request.session_dir);
    } else if (request.session_ref.len > 0)
        try pathsForLocalSessionRef(allocator, request.session_ref)
    else
        (try mostRecentAgent(allocator)) orelse return error.NoSessions;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
}

fn pathsForLocalSessionRef(allocator: std.mem.Allocator, ref: []const u8) !session_registry.SessionPaths {
    if (!session_registry.isValidSessionRef(ref)) return error.InvalidSessionId;
    const guid = session_registry.resolveRefToGuid(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => {
            if (session_registry.tombstoneExistsForRef(allocator, ref)) return error.SessionAlreadyExited;
            return err;
        },
        else => return err,
    };
    defer allocator.free(guid);

    var route = session_registry.readRouteForRef(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (session_registry.tombstoneExistsForRef(allocator, ref) or
                session_registry.tombstoneExistsForRef(allocator, guid)) return error.SessionAlreadyExited;
            break :blk null;
        },
        else => return err,
    };
    if (route) |*value| {
        defer value.deinit(allocator);
        if (value.session_dir.len > 0) {
            var routed_paths = try session_registry.pathsForSessionDir(allocator, value.session_dir);
            errdefer routed_paths.deinit(allocator);
            if (fileExists(routed_paths.meta) or value.host.len == 0 or std.mem.eql(u8, value.host, ".")) return routed_paths;
            return error.SessionRefNotLocal;
        }
        if (value.host.len > 0 and !std.mem.eql(u8, value.host, ".")) {
            var current_paths = try session_registry.pathsForSessionId(allocator, guid);
            errdefer current_paths.deinit(allocator);
            if (!fileExists(current_paths.meta)) return error.SessionRefNotLocal;
            return current_paths;
        }
    }

    var paths = try session_registry.pathsForSessionId(allocator, guid);
    errdefer paths.deinit(allocator);
    if (fileExists(paths.route) and !fileExists(paths.meta)) return error.SessionRefNotLocal;
    return paths;
}

fn mostRecentAgent(allocator: std.mem.Allocator) !?session_registry.SessionPaths {
    const sessions_dir = try session_registry.sessionsDir(allocator);
    defer allocator.free(sessions_dir);
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var selected: ?session_registry.SessionPaths = null;
    var selected_detached_ts: u64 = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !session_registry.isValidSessionId(entry.name)) continue;
        var paths = try session_registry.pathsForSessionId(allocator, entry.name);
        errdefer paths.deinit(allocator);
        _ = statAbsolute(paths.socket) catch |err| switch (err) {
            error.FileNotFound => {
                paths.deinit(allocator);
                continue;
            },
            else => return err,
        };
        var meta = session_registry.readMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            paths.deinit(allocator);
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            session_registry.removeStaleHints(paths) catch {};
            paths.deinit(allocator);
            continue;
        }
        const maybe_detached_ts: ?u64 = querySessionLiveStateDetachedAt(allocator, paths) catch blk: {
            break :blk legacyDetachedMarkerTimestampMs(allocator, paths) catch null;
        };
        const detached_ts = maybe_detached_ts orelse {
            paths.deinit(allocator);
            continue;
        };
        if (selected == null or detached_ts > selected_detached_ts) {
            if (selected) |*old| old.deinit(allocator);
            selected = paths;
            selected_detached_ts = detached_ts;
        } else {
            paths.deinit(allocator);
        }
    }
    return selected;
}

fn querySessionLiveStateDetachedAt(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !?u64 {
    var state = try querySessionLiveState(allocator, paths);
    defer state.deinit(allocator);
    return state.detached_at_unix_ms;
}

fn querySessionLiveState(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !pb.SessionLiveState {
    return querySessionLiveStateFromSocketPath(allocator, paths.socket);
}

fn querySessionLiveStateFromSocketPath(allocator: std.mem.Allocator, socket_path: []const u8) !pb.SessionLiveState {
    const fd = try socket_transport.connectSocket(socket_path);
    defer _ = c.close(fd);

    try initiateRuntimeHandshake(allocator, fd);

    const query_payload = try protocol.encodePayload(allocator, pb.SessionLiveStateQuery{});
    defer allocator.free(query_payload);
    try protocol.sendFrame(fd, .session_live_state_query, query_payload);

    var frame = try protocol.readFrameAlloc(allocator, fd);
    defer frame.deinit(allocator);
    switch (frame.message_type) {
        .session_live_state => return protocol.decodePayload(pb.SessionLiveState, allocator, frame.payload),
        .error_message => return error.SessionLiveStateUnavailable,
        else => return error.UnexpectedFrame,
    }
}

fn legacyDetachedMarkerTimestampMs(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !?u64 {
    const marker = try std.fmt.allocPrint(allocator, "{s}/detached", .{paths.dir});
    defer allocator.free(marker);
    const stat = std.fs.cwd().statFile(marker) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.mtime <= 0) return 0;
    return @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    return std.fs.cwd().statFile(path);
}

fn startSessionAgentAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_create_payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.SessionCreate, allocator, session_create_payload);
    defer request.deinit(allocator);
    if (request.session_alias.len > 0) {
        if (!session_registry.isValidAlias(request.session_alias)) return error.InvalidAlias;
        if (!try session_registry.aliasAvailableForGuid(allocator, request.session_alias, request.session_guid)) return error.AliasExists;
    }
    var allocation = if (request.session_guid.len > 0)
        try session_registry.allocateSessionDirForGuid(allocator, request.session_guid)
    else
        try session_registry.allocateSessionDir(allocator);
    defer allocation.deinit(allocator);

    const argv = [_][]const u8{
        exe,
        ":internal-session-agent:",
        "--session-dir",
        allocation.paths.dir,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (socket_transport.connectSocket(allocation.paths.socket)) |fd| return fd else |err| switch (err) {
            error.ConnectFailed, error.SocketPathMissing, error.SocketDirMissing => {},
            else => return err,
        }
        io.sleepMillis(20);
    }
    return error.SessionAgentDidNotStart;
}

fn createSessionAndRelay(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_create_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .session_create, session_create_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn attachAgentAndRelay(
    allocator: std.mem.Allocator,
    agent_fd: c.fd_t,
    session_attach_payload: []const u8,
) !void {
    initiateRuntimeHandshake(allocator, agent_fd) catch |err| switch (err) {
        error.VersionMismatch => {
            try sendError(1, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
            return;
        },
        else => return err,
    };
    try protocol.sendFrame(agent_fd, .session_attach, session_attach_payload);
    try relay.relayFrames(0, 1, agent_fd);
}

fn errorIsVersionMismatch(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var message = try protocol.decodePayload(hpb.Error, allocator, payload);
    defer message.deinit(allocator);
    return std.mem.eql(u8, message.code, "VERSION_MISMATCH");
}

const HandshakeResult = enum {
    accepted,
    mismatch,
};

fn acceptRuntimeHandshake(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !HandshakeResult {
    var peer_hello = try readHelloRequest(allocator, read_fd, write_fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(write_fd, "VERSION_MISMATCH", "broker is incompatible with this client", "");
        return .mismatch;
    }
    try sendHelloOk(write_fd);
    try sendHelloRequest(write_fd);
    var hello_error = try readHelloReply(allocator, read_fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.HandshakeFailed;
    }
    return .accepted;
}

fn initiateRuntimeHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try sendHelloRequest(fd);
    var hello_error = try readHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |err| {
        if (std.mem.eql(u8, err.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        return error.AgentHandshakeFailed;
    }
    var peer_hello = try readHelloRequest(allocator, fd, fd);
    defer peer_hello.deinit(allocator);
    if (!helloRequestIsCompatible(peer_hello)) {
        try sendHelloError(fd, "VERSION_MISMATCH", "existing session agent is incompatible with this client", "Use the session agent's matching sessh binary through compat-mode");
        return error.VersionMismatch;
    }
    try sendHelloOk(fd);
}

fn readHelloRequest(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, allocator, frame.payload),
            else => {
                try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn readHelloReply(allocator: std.mem.Allocator, read_fd: c.fd_t) !?hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
                defer ok.deinit(allocator);
                return null;
            },
            .hello_error => {
                const err = try protocol.decodePayload(hpb.HelloError, allocator, frame.payload);
                return err;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.min_protocol_major, config.min_protocol_minor);
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

test "list all rows include runtime metadata and cached remote sessions" {
    const allocator = std.testing.allocator;
    const runtime_root = try std.fmt.allocPrint(allocator, "/tmp/sessh-broker-all-runtime-test-{}", .{c.getpid()});
    defer allocator.free(runtime_root);
    const state_root = try std.fmt.allocPrint(allocator, "/tmp/sessh-broker-all-state-test-{}", .{c.getpid()});
    defer allocator.free(state_root);
    std.fs.cwd().deleteTree(runtime_root) catch {};
    std.fs.cwd().deleteTree(state_root) catch {};
    defer std.fs.cwd().deleteTree(runtime_root) catch {};
    defer std.fs.cwd().deleteTree(state_root) catch {};

    const local_guid = "s-11111111-1111-4111-8111-111111111111";
    const client_guid = "c-22222222-2222-4222-8222-222222222222";
    const remote_guid = "s-33333333-3333-4333-8333-333333333333";
    const stream_guid = "r-44444444-4444-4444-8444-444444444444";
    const local_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ runtime_root, local_guid });
    defer allocator.free(local_dir);
    const client_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ runtime_root, client_guid });
    defer allocator.free(client_dir);
    const stream_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ runtime_root, stream_guid });
    defer allocator.free(stream_dir);
    try std.fs.cwd().makePath(local_dir);
    try std.fs.cwd().makePath(client_dir);
    try std.fs.cwd().makePath(stream_dir);

    const local_meta = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{local_dir});
    defer allocator.free(local_meta);
    const incoming_client_meta = try std.fmt.allocPrint(allocator, "{s}/incoming-meta.json", .{client_dir});
    defer allocator.free(incoming_client_meta);
    const outgoing_client_meta = try std.fmt.allocPrint(allocator, "{s}/outgoing-meta.json", .{client_dir});
    defer allocator.free(outgoing_client_meta);
    const stream_meta = try std.fmt.allocPrint(allocator, "{s}/outgoing-meta.json", .{stream_dir});
    defer allocator.free(stream_meta);
    try writeTestFile(local_meta, "{\"type\":\"local-session\",\"created_at_unix_ms\":1000}\n");
    try writeTestFile(incoming_client_meta, "{\"type\":\"incoming-client\",\"created_at_unix_ms\":1500}\n");
    try writeTestFile(outgoing_client_meta, "{\"type\":\"outgoing-client\",\"created_at_unix_ms\":2000}\n");
    try writeTestFile(stream_meta, "{\"type\":\"outgoing-stream\",\"created_at_unix_ms\":3000}\n");

    const remote_route_dir = try std.fmt.allocPrint(allocator, "{s}/guid/{s}", .{ state_root, remote_guid });
    defer allocator.free(remote_route_dir);
    try std.fs.cwd().makePath(remote_route_dir);
    const remote_route_path = try std.fmt.allocPrint(allocator, "{s}/route.json", .{remote_route_dir});
    defer allocator.free(remote_route_path);
    try writeTestFile(
        remote_route_path,
        "{\"guid\":\"s-33333333-3333-4333-8333-333333333333\",\"primary_alias\":\"s-33333333\",\"session_dir\":\"/tmp/remote/guid/s-33333333-3333-4333-8333-333333333333\",\"host\":\"work.example\",\"agent_version\":\"0.6.0-test\",\"alive\":true,\"attached_count\":null,\"last_input_at_unix_ms\":null,\"ssh_options\":[]}\n",
    );

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeAllRowsFromRoots(allocator, out.writer(allocator), .{ .format = .jsonl, .all = true }, runtime_root, state_root);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"s-11111111\",\"guid\":\"s-11111111-1111-4111-8111-111111111111\",\"type\":\"local-session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"c-22222222\",\"guid\":\"c-22222222-2222-4222-8222-222222222222\",\"type\":\"incoming-client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"c-22222222\",\"guid\":\"c-22222222-2222-4222-8222-222222222222\",\"type\":\"outgoing-client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"r-44444444\",\"guid\":\"r-44444444-4444-4444-8444-444444444444\",\"type\":\"outgoing-stream\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":\"s-33333333\",\"guid\":\"s-33333333-3333-4333-8333-333333333333\",\"type\":\"remote-session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "host=work.example version=0.6.0-test") != null);

    out.clearRetainingCapacity();
    try writeAllRowsFromRoots(allocator, out.writer(allocator), .{ .format = .jsonl, .all = true, .local_only = true }, runtime_root, state_root);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"remote-session\"") == null);

    out.clearRetainingCapacity();
    try writeAllRowsFromRoots(allocator, out.writer(allocator), .{ .format = .table, .all = true, .local_only = true }, runtime_root, state_root);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "s-11111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "s-11111111-1111-4111-8111-111111111111") == null);
}

fn writeTestFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    errdefer file.close();
    try file.writeAll(contents);
    file.close();
}
