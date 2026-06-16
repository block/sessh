const std = @import("std");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const protocol = @import("../protocol/mod.zig");
const session_runtime = @import("../session/runtime.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("../transport/socket.zig");
const stream_runtime = @import("../stream/runtime.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

pub const LocalProcessIdentity = struct {
    pid: u64,
    start_time: []const u8,
};

pub const RemoteEndpoint = struct {
    user: []const u8,
    host: []const u8,
    port: []const u8,
};

pub const Record = struct {
    guid: []const u8,
    local_pid: u64,
    local_start_time: []const u8,
    remote_user: []const u8,
    remote_host: []const u8,
    remote_port: []const u8,
    remote_pid: u64,
    remote_start_time: []const u8,
    remote_socket_path: []const u8,
};

const RecordJson = struct {
    local_pid: u64,
    local_start_time: []const u8,
    remote_user: []const u8,
    remote_host: []const u8,
    remote_port: []const u8,
    remote_pid: u64,
    remote_start_time: []const u8,
    remote_socket_path: []const u8,
};

pub const CleanupResult = enum {
    cleaned,
    missing,
};

pub const SweepCleanFn = *const fn (*anyopaque, std.mem.Allocator, Record) anyerror!CleanupResult;

pub const SweepLock = struct {
    file: std.fs.File,

    pub fn deinit(self: *SweepLock) void {
        std.posix.flock(self.file.handle, std.posix.LOCK.UN) catch {};
        self.file.close();
        self.* = undefined;
    }
};

pub fn currentLocalProcessIdentity(allocator: std.mem.Allocator) !LocalProcessIdentity {
    const pid: u64 = @intCast(c.getpid());
    return .{
        .pid = pid,
        .start_time = try daemon_identity.processStartTime(allocator, pid),
    };
}

pub fn makeRemoteProcessIdentity(
    identity: daemon_identity.DaemonIdentity,
    guid: []const u8,
) pb.DaemonTunnelItem.RemoteProcessIdentity {
    return .{
        .pid = identity.pid,
        .start_time = identity.start_time,
        .daemon_socket_path = identity.socket_path,
        .guid = guid,
    };
}

pub fn recordRemoteProcessStarted(
    allocator: std.mem.Allocator,
    local: LocalProcessIdentity,
    endpoint: RemoteEndpoint,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
) !void {
    try validateGuidForFile(process.guid);
    const record = Record{
        .guid = process.guid,
        .local_pid = local.pid,
        .local_start_time = local.start_time,
        .remote_user = endpoint.user,
        .remote_host = endpoint.host,
        .remote_port = endpoint.port,
        .remote_pid = process.pid,
        .remote_start_time = process.start_time,
        .remote_socket_path = process.daemon_socket_path,
    };
    try writeRecord(allocator, record);
}

pub fn deleteRecordByGuid(allocator: std.mem.Allocator, guid: []const u8) void {
    const path = recordPath(allocator, guid) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

pub fn sendRemoteProcessStarted(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
) !void {
    try protocol.sendDaemonTunnelPayloadFrame(allocator, fd, .{ .remote_process_started = .{
        .stream_id = stream_id,
        .process = process,
    } });
}

pub fn sendRemoteProcessRecorded(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
) !void {
    try protocol.sendDaemonTunnelPayloadFrame(allocator, fd, .{ .remote_process_recorded = .{
        .stream_id = stream_id,
    } });
}

pub fn sendRemoteProcessCleanupRequest(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
) !void {
    try protocol.sendDaemonTunnelPayloadFrame(allocator, fd, .{ .remote_process_cleanup_request = .{
        .process = process,
    } });
}

pub fn handleRemoteProcessCleanupRequest(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    identity: daemon_identity.DaemonIdentity,
    request: pb.DaemonTunnelItem.RemoteProcessCleanupRequest,
) !void {
    const process = request.process orelse return error.UnexpectedFrame;
    const result = cleanupRemoteProcess(allocator, identity, process) catch .missing;
    try sendRemoteProcessCleanupResponse(allocator, fd, process, result);
}

pub fn handleRemoteProcessCleanupResponse(
    allocator: std.mem.Allocator,
    response: pb.DaemonTunnelItem.RemoteProcessCleanupResponse,
) void {
    const process = response.process orelse return;
    deleteRecordByGuid(allocator, process.guid);
}

pub fn tryAcquireSweepLock(
    allocator: std.mem.Allocator,
) !?SweepLock {
    const path = try sweepLockPath(allocator);
    defer allocator.free(path);
    try socket_transport.ensureSocketDir(allocator, path);

    var file = try std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer file.close();
    try socket_transport.setCloseOnExec(file.handle);

    posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => {
            file.close();
            return null;
        },
        else => return err,
    };
    errdefer posix.flock(file.handle, posix.LOCK.UN) catch {};

    return .{ .file = file };
}

pub fn sweepDueAndMark(
    lock: *SweepLock,
    wakeup_interval_ms: u64,
    now_ms: u64,
) !bool {
    const stat = try lock.file.stat();
    const last_ms = if (stat.size == 0) 0 else fileMtimeUnixMs(stat);
    if (wakeup_interval_ms > 0 and last_ms > 0 and now_ms -| last_ms < wakeup_interval_ms) {
        return false;
    }
    try markSweepStarted(lock, now_ms);
    return true;
}

pub fn markSweepStarted(
    lock: *SweepLock,
    now_ms: u64,
) !void {
    try lock.file.setEndPos(0);
    try lock.file.seekTo(0);
    var line: [32]u8 = undefined;
    const len = try std.fmt.bufPrint(&line, "{}\n", .{now_ms});
    try lock.file.writeAll(len);
    try lock.file.sync();
}

pub fn sweepRecords(
    allocator: std.mem.Allocator,
    cleanup_retry_limit_ms: u64,
    context: *anyopaque,
    clean_fn: SweepCleanFn,
) !void {
    const procs_dir = procsDir(allocator) catch |err| switch (err) {
        error.MissingStateHome => return,
        else => return err,
    };
    defer allocator.free(procs_dir);

    var dir = std.fs.openDirAbsolute(procs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        const guid = guidFromRecordFilename(entry.name) catch continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ procs_dir, entry.name });
        defer allocator.free(path);
        try sweepRecordPath(allocator, path, guid, cleanup_retry_limit_ms, context, clean_fn);
    }
}

pub fn hasRecords(allocator: std.mem.Allocator) bool {
    const procs_dir = procsDir(allocator) catch return false;
    defer allocator.free(procs_dir);
    var dir = std.fs.openDirAbsolute(procs_dir, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iterator = dir.iterate();
    while (iterator.next() catch return false) |entry| {
        if (entry.kind != .file) continue;
        _ = guidFromRecordFilename(entry.name) catch continue;
        return true;
    }
    return false;
}

fn cleanupRemoteProcess(
    allocator: std.mem.Allocator,
    identity: daemon_identity.DaemonIdentity,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
) !CleanupResult {
    if (process.guid.len == 0) return .missing;
    if (process.pid == identity.pid) {
        if (!std.mem.eql(u8, process.start_time, identity.start_time)) return .missing;
        if (std.mem.eql(u8, process.daemon_socket_path, identity.socket_path)) {
            return cleanupGuidOnCurrentDaemon(allocator, process.guid);
        }
    }

    if (!std.mem.eql(u8, process.daemon_socket_path, identity.socket_path)) {
        if (forwardCleanupToDaemonSocket(allocator, process.daemon_socket_path, process)) |result| return result else |_| {}
    }

    if (!daemon_identity.processIdentityMatches(allocator, process.pid, process.start_time)) return .missing;
    posix.kill(@intCast(process.pid), posix.SIG.HUP) catch return .missing;
    daemon_log.infof(allocator, "cleanup signaled remote process guid={s} pid={}", .{ process.guid, process.pid });
    return .cleaned;
}

fn cleanupGuidOnCurrentDaemon(allocator: std.mem.Allocator, guid: []const u8) !CleanupResult {
    if (std.mem.startsWith(u8, guid, "s-")) {
        session_runtime.requestTerminalRemoteCleanup(allocator, guid) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => return .missing,
            else => return err,
        };
        daemon_log.infof(allocator, "cleanup hung up terminal session guid={s}", .{guid});
        return .cleaned;
    }
    if (std.mem.startsWith(u8, guid, "p-")) {
        stream_runtime.requestProxyRemoteCleanup(allocator, guid) catch |err| switch (err) {
            error.StreamNotFound, error.InvalidProxyId => return .missing,
            else => return err,
        };
        daemon_log.infof(allocator, "cleanup closed proxy stream guid={s}", .{guid});
        return .cleaned;
    }
    return .missing;
}

fn forwardCleanupToDaemonSocket(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
) !CleanupResult {
    const fd = try socket_transport.connectSocket(socket_path);
    defer _ = c.close(fd);
    try initiateDaemonSocketHandshake(allocator, fd);
    try sendRemoteProcessCleanupRequest(allocator, fd, process);
    while (true) {
        var frame = try readFrameBlocking(allocator, fd);
        defer frame.deinit(allocator);
        if (frame.message_type != .daemon_tunnel) return error.UnexpectedFrame;
        var item = try protocol.decodePayload(pb.DaemonTunnelItem, allocator, frame.payload);
        defer item.deinit(allocator);
        const payload = item.payload orelse return error.UnexpectedFrame;
        switch (payload) {
            .remote_process_cleanup_response => |response| {
                const response_process = response.process orelse return error.UnexpectedFrame;
                if (!std.mem.eql(u8, response_process.guid, process.guid)) return error.UnexpectedFrame;
                const result = response.result orelse return error.UnexpectedFrame;
                return switch (result) {
                    .cleaned => .cleaned,
                    .missing => .missing,
                };
            },
            .ping => continue,
            else => return error.UnexpectedFrame,
        }
    }
}

fn sendRemoteProcessCleanupResponse(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
    result: CleanupResult,
) !void {
    const result_payload: pb.DaemonTunnelItem.RemoteProcessCleanupResponse.result_union = switch (result) {
        .cleaned => .{ .cleaned = .{} },
        .missing => .{ .missing = .{} },
    };
    try protocol.sendDaemonTunnelPayloadFrame(allocator, fd, .{ .remote_process_cleanup_response = .{
        .process = process,
        .result = result_payload,
    } });
}

fn initiateDaemonSocketHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    const hello_payload = try protocol.encodePayload(allocator, hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer allocator.free(hello_payload);
    try protocol.sendFrame(fd, .hello_request, hello_payload);

    var frame = try readFrameBlocking(allocator, fd);
    defer frame.deinit(allocator);
    switch (frame.message_type) {
        .hello_ok => {
            var ok = try protocol.decodePayload(hpb.HelloOk, allocator, frame.payload);
            defer ok.deinit(allocator);
        },
        .hello_error => return error.VersionMismatch,
        else => return error.UnexpectedFrame,
    }
}

// Use only for the bounded cleanup request/response exchange. Cleanup is still
// synchronous today; daemon-owned sockets use dispatcher read state.
fn readFrameBlocking(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked => return error.WouldBlock,
            .progress => continue,
            .frame => |frame| return frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
}

fn writeRecord(allocator: std.mem.Allocator, record: Record) !void {
    const procs_dir = try ensureProcsDir(allocator);
    defer allocator.free(procs_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ procs_dir, record.guid });
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, c.getpid() });
    defer allocator.free(tmp_path);

    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(recordJsonFromRecord(record), .{}, &json_writer.writer);
    try json_writer.writer.writeByte('\n');
    const bytes = try json_writer.toOwnedSlice();
    defer allocator.free(bytes);

    var file = try std.fs.createFileAbsolute(tmp_path, .{
        .read = false,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.renameAbsolute(tmp_path, path);
}

fn recordJsonFromRecord(record: Record) RecordJson {
    return .{
        .local_pid = record.local_pid,
        .local_start_time = record.local_start_time,
        .remote_user = record.remote_user,
        .remote_host = record.remote_host,
        .remote_port = record.remote_port,
        .remote_pid = record.remote_pid,
        .remote_start_time = record.remote_start_time,
        .remote_socket_path = record.remote_socket_path,
    };
}

fn ensureProcsDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    try ensurePrivateDir(allocator, root);

    const procs_dir = try procsDir(allocator);
    errdefer allocator.free(procs_dir);
    try ensurePrivateDir(allocator, procs_dir);
    return procs_dir;
}

fn ensurePrivateDir(allocator: std.mem.Allocator, dir: []const u8) !void {
    const marker = try std.fmt.allocPrint(allocator, "{s}/.dir", .{dir});
    defer allocator.free(marker);
    try socket_transport.ensureSocketDir(allocator, marker);
}

fn procsDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/procs", .{root});
}

fn recordPath(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    try validateGuidForFile(guid);
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/procs/{s}.json", .{ root, guid });
}

fn validateGuidForFile(guid: []const u8) !void {
    if (guid.len == 0) return error.InvalidGuid;
    if (std.mem.indexOfAny(u8, guid, "/\x00") != null) return error.InvalidGuid;
    if (!session_registry.isValidGuid(guid)) return error.InvalidGuid;
}

fn guidFromRecordFilename(filename: []const u8) ![]const u8 {
    const suffix = ".json";
    if (!std.mem.endsWith(u8, filename, suffix)) return error.InvalidGuid;
    const guid = filename[0 .. filename.len - suffix.len];
    try validateGuidForFile(guid);
    return guid;
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn fileMtimeUnixMs(stat: std.fs.File.Stat) u64 {
    if (stat.mtime <= 0) return 0;
    const mtime_ms = @divFloor(stat.mtime, std.time.ns_per_ms);
    return std.math.cast(u64, mtime_ms) orelse std.math.maxInt(u64);
}

fn sweepRecordPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    guid: []const u8,
    cleanup_retry_limit_ms: u64,
    context: *anyopaque,
    clean_fn: SweepCleanFn,
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(RecordJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const persisted = parsed.value;
    const record = Record{
        .guid = guid,
        .local_pid = persisted.local_pid,
        .local_start_time = persisted.local_start_time,
        .remote_user = persisted.remote_user,
        .remote_host = persisted.remote_host,
        .remote_port = persisted.remote_port,
        .remote_pid = persisted.remote_pid,
        .remote_start_time = persisted.remote_start_time,
        .remote_socket_path = persisted.remote_socket_path,
    };

    if (daemon_identity.processIdentityMatches(allocator, record.local_pid, record.local_start_time)) return;

    const now_ms = nowUnixMs();
    const record_mtime_unix_ms = fileMtimeUnixMs(stat);
    if (cleanup_retry_limit_ms > 0 and record_mtime_unix_ms > 0 and now_ms -| record_mtime_unix_ms >= cleanup_retry_limit_ms) {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const result = clean_fn(context, allocator, record) catch return;
    switch (result) {
        .cleaned, .missing => std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        },
    }
}

fn sweepLockPath(allocator: std.mem.Allocator) ![]u8 {
    const root = try socket_transport.stateRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/cleanup-sweep", .{root});
}

test "record path rejects path separators" {
    try std.testing.expectError(error.InvalidGuid, validateGuidForFile("s-nope/nope"));
}

test "record filename provides cleanup guid" {
    try std.testing.expectEqualStrings(
        "s-550e8400-e29b-41d4-a716-446655440000",
        try guidFromRecordFilename("s-550e8400-e29b-41d4-a716-446655440000.json"),
    );
    try std.testing.expectError(error.InvalidGuid, guidFromRecordFilename("s-nope/nope.json"));
    try std.testing.expectError(error.InvalidGuid, guidFromRecordFilename("s-550e8400-e29b-41d4-a716-446655440000"));
}

test "cleanup record JSON omits filename-owned identity and age fields" {
    var json_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(recordJsonFromRecord(.{
        .guid = "s-550e8400-e29b-41d4-a716-446655440000",
        .local_pid = 12,
        .local_start_time = "local-start",
        .remote_user = "user",
        .remote_host = "host",
        .remote_port = "22",
        .remote_pid = 34,
        .remote_start_time = "remote-start",
        .remote_socket_path = "/tmp/sesshd.sock",
    }), .{}, &json_writer.writer);
    const bytes = try json_writer.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "guid") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "recorded_at_unix_ms") == null);
    var parsed = try std.json.parseFromSlice(RecordJson, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 12), parsed.value.local_pid);
    try std.testing.expectEqualStrings("/tmp/sesshd.sock", parsed.value.remote_socket_path);
}

test "cleanup sweep lock mtime throttles repeated sweeps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("cleanup-sweep", .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    var lock = SweepLock{ .file = file };
    defer lock.deinit();

    const now_ms = nowUnixMs();
    try std.testing.expect(try sweepDueAndMark(&lock, 60_000, now_ms));
    try std.testing.expect(!(try sweepDueAndMark(&lock, 60_000, now_ms + 1)));
}
