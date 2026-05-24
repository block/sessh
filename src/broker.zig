const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const io = @import("io.zig");
const process_exit = @import("process_exit.zig");
const protocol = @import("protocol.zig");
const relay = @import("relay.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;

const command_timeout_ms: i64 = 2_000;
const command_poll_ms: u64 = 20;

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    const command_args = try applyBrokerOptions(args);
    socket_transport.publishRuntimeRootSymlinkOnce(allocator);

    if (command_args.len > 0) return runCommandArgs(allocator, command_args);

    const handshake_result = try acceptRuntimeHandshake(allocator, 0, 1);
    if (handshake_result == .mismatch) return;

    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, 0);
        errdefer frame.deinit(allocator);
        switch (frame.message_type) {
            .resize => {
                frame.deinit(allocator);
                continue;
            },
            .session_attach => {
                defer frame.deinit(allocator);
                const agent_fd = connectAgentForAttach(allocator, frame.payload) catch |err| switch (err) {
                    error.NoSessions => {
                        try sendError(1, "SESSION_NOT_FOUND", "no sessions", "");
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
                defer frame.deinit(allocator);
                const agent_fd = try startSessionAgentAndConnect(allocator, exe, frame.payload);
                defer _ = c.close(agent_fd);
                try createSessionAndRelay(allocator, agent_fd, frame.payload);
                return;
            },
            else => {
                defer frame.deinit(allocator);
                try sendError(1, "PROTOCOL_ERROR", "broker only supports SESSION_CREATE or SESSION_ATTACH in this mode", "");
                return;
            },
        }
    }
}

fn applyBrokerOptions(args: []const []const u8) ![]const []const u8 {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--state-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingStateDir;
            socket_transport.setRuntimeRootOverride(args[i]);
            i += 1;
            continue;
        }
        break;
    }
    return args[i..];
}

fn runCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const command = args[0];
    if (std.mem.eql(u8, command, "--list")) {
        if (args.len != 1) return finishCommand(64, "", "ERROR usage: --list\n");
        const exit_status = try listAgents(allocator);
        return process_exit.request(exit_status);
    }
    if (std.mem.eql(u8, command, "--kill")) {
        if (args.len != 2) return finishCommand(64, "", "ERROR usage: --kill ID\n");
        return killOneAgent(allocator, args[1]);
    }
    if (std.mem.eql(u8, command, "--kill-all") or std.mem.eql(u8, command, "--killall")) {
        if (args.len != 1) return finishCommand(64, "", "ERROR usage: --kill-all\n");
        return killAllAgents(allocator);
    }
    return finishCommand(64, "", "ERROR unknown broker command\n");
}

fn finishCommand(exit_status: u8, stdout: []const u8, stderr: []const u8) !void {
    if (stdout.len > 0) try io.writeAll(1, stdout);
    if (stderr.len > 0) try io.writeAll(2, stderr);
    return process_exit.request(exit_status);
}

fn listAgents(allocator: std.mem.Allocator) !u8 {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    try stdout.appendSlice(allocator, "ID\tATTACHED\tAGENT_PID\n");

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
        var meta = readSessionMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        }
        const guid = session_registry.canonicalGuid(allocator, entry.name) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer allocator.free(guid);
        const display_id = (try session_registry.primaryAliasForGuid(allocator, guid)) orelse try allocator.dupe(u8, guid);
        defer allocator.free(display_id);
        try stdout.writer(allocator).print("{s}\t{s}\t{}\n", .{
            display_id,
            if (fileExists(paths.detached)) "no" else "yes",
            meta.agent_pid,
        });
    }

    try io.writeAll(1, stdout.items);
    return 0;
}

fn killOneAgent(allocator: std.mem.Allocator, session_id: []const u8) !void {
    var paths = session_registry.pathsForRef(allocator, session_id) catch |err| switch (err) {
        error.InvalidSessionId, error.FileNotFound => {
            return finishCommand(1, "", "ERROR session not found\n");
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    var meta = readSessionMeta(allocator, paths) catch {
        session_registry.removeStaleHints(paths) catch {};
        return finishCommand(1, "", "ERROR session not found\n");
    };
    defer meta.deinit(allocator);
    if (!processExists(meta.agent_pid)) {
        session_registry.removeStaleHints(paths) catch {};
        return finishCommand(1, "", "ERROR session not found\n");
    }
    if (!std.mem.eql(u8, meta.version, config.version)) {
        const exit_status = try runCompatCommand(allocator, paths, &.{ "--kill", session_id });
        return process_exit.request(exit_status);
    }
    if (!terminateAgent(meta.agent_pid)) {
        return finishCommand(1, "", "ERROR failed to kill session agent\n");
    }
    var stdout_buf: [128]u8 = undefined;
    const stdout = try std.fmt.bufPrint(&stdout_buf, "ENDED {s}\n", .{session_id});
    return finishCommand(0, stdout, "");
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
        var meta = readSessionMeta(allocator, paths) catch {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        };
        defer meta.deinit(allocator);
        if (!processExists(meta.agent_pid)) {
            session_registry.removeStaleHints(paths) catch {};
            continue;
        }
        if (!std.mem.eql(u8, meta.version, config.version)) {
            const compat_status = try runCompatCommand(allocator, paths, &.{ "--kill", entry.name });
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

const SessionMeta = struct {
    bytes: []u8,
    agent_pid: c.pid_t,
    version: []const u8,

    fn deinit(self: *SessionMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn readSessionMeta(allocator: std.mem.Allocator, paths: session_registry.SessionPaths) !SessionMeta {
    const file = try std.fs.openFileAbsolute(paths.meta, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 4096);
    errdefer allocator.free(bytes);

    var agent_pid: ?c.pid_t = null;
    var version: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "agent_pid")) {
            agent_pid = try parsePid(value);
        } else if (std.mem.eql(u8, key, "version")) {
            version = value;
        }
    }
    return .{
        .bytes = bytes,
        .agent_pid = agent_pid orelse return error.InvalidSessionMeta,
        .version = version orelse return error.InvalidSessionMeta,
    };
}

fn parsePid(value: []const u8) !c.pid_t {
    const parsed = try std.fmt.parseInt(i64, value, 10);
    if (parsed <= 0 or parsed > std.math.maxInt(c.pid_t)) return error.InvalidSessionMeta;
    return @intCast(parsed);
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

fn runCompatCommand(allocator: std.mem.Allocator, paths: session_registry.SessionPaths, args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 4 + args.len);
    defer allocator.free(argv);
    argv[0] = paths.compat;
    argv[1] = ":local:";
    argv[2] = "--compat-version";
    argv[3] = config.version;
    @memcpy(argv[4..], args);

    var child = std.process.Child.init(argv, allocator);
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
    var paths = if (request.session_guid.len > 0)
        try session_registry.pathsForSessionId(allocator, request.session_guid)
    else
        (try mostRecentAgent(allocator)) orelse return error.NoSessions;
    defer paths.deinit(allocator);
    return socket_transport.connectSocket(paths.socket);
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
    var selected_mtime: i128 = std.math.minInt(i128);
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
        const stat = statAbsolute(paths.meta) catch {
            paths.deinit(allocator);
            continue;
        };
        if (selected == null or stat.mtime > selected_mtime) {
            if (selected) |*old| old.deinit(allocator);
            selected = paths;
            selected_mtime = stat.mtime;
        } else {
            paths.deinit(allocator);
        }
    }
    return selected;
}

fn statAbsolute(path: []const u8) !std.fs.File.Stat {
    return std.fs.cwd().statFile(path);
}

fn startSessionAgentAndConnect(allocator: std.mem.Allocator, exe: []const u8, session_create_payload: []const u8) !c.fd_t {
    var request = try protocol.decodePayload(pb.SessionCreate, allocator, session_create_payload);
    defer request.deinit(allocator);
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
    return protocol.helloRequestIsCompatible(hello, config.protocol_major, config.protocol_minor, config.version);
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
