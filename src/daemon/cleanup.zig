// Persistent cleanup records for remote worker processes. The fast path asks
// the paired daemon to hang up work immediately; these records are the fallback
// that survives a local client, daemon, or laptop crash.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const protocol = @import("../protocol/mod.zig");
const terminal_worker = @import("../session/terminal_worker.zig");
const guid_ref = @import("../core/guid.zig");
const socket_transport = @import("../transport/socket.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");

const pb = protocol.pb;

pub const LocalProcessIdentity = struct {
    pid: u64,
    start_time: []const u8,

    pub fn clone(allocator: std.mem.Allocator, identity: LocalProcessIdentity) !LocalProcessIdentity {
        return .{
            .pid = identity.pid,
            .start_time = try allocator.dupe(u8, identity.start_time),
        };
    }

    pub fn deinit(self: *LocalProcessIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.start_time);
        self.* = undefined;
    }
};

pub const RemoteProcessIdentity = struct {
    pid: u64,
    start_time: []const u8,
    socket_path: []const u8,

    pub fn clone(allocator: std.mem.Allocator, identity: RemoteProcessIdentity) !RemoteProcessIdentity {
        const start_time = try allocator.dupe(u8, identity.start_time);
        errdefer allocator.free(start_time);
        const socket_path = try allocator.dupe(u8, identity.socket_path);
        errdefer allocator.free(socket_path);
        return .{
            .pid = identity.pid,
            .start_time = start_time,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *RemoteProcessIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.start_time);
        allocator.free(self.socket_path);
        self.* = undefined;
    }

    pub fn fromProto(process: pb.DaemonTunnelItem.RemoteProcessIdentity) RemoteProcessIdentity {
        return .{
            .pid = process.pid,
            .start_time = process.start_time,
            .socket_path = process.daemon_socket_path,
        };
    }

    pub fn fromDaemonIdentity(identity: daemon_identity.DaemonIdentity) RemoteProcessIdentity {
        return .{
            .pid = identity.pid,
            .start_time = identity.start_time,
            .socket_path = identity.socket_path,
        };
    }

    pub fn toProto(self: RemoteProcessIdentity, guid: []const u8) pb.DaemonTunnelItem.RemoteProcessIdentity {
        return .{
            .pid = self.pid,
            .start_time = self.start_time,
            .daemon_socket_path = self.socket_path,
            .guid = guid,
        };
    }
};

pub const RemoteEndpoint = struct {
    user: []const u8,
    host: []const u8,
    port: []const u8,
};

// Persistent cleanup records bind the local owner identity to the remote
// endpoint and remote process identity. The local identity prevents a later
// process that reused the same pid from causing cleanup, while the remote pid
// and start token prevent us from hanging up an unrelated process after reboot
// or pid reuse.
pub const Record = struct {
    guid: []const u8,
    local: LocalProcessIdentity,
    endpoint: RemoteEndpoint,
    remote: RemoteProcessIdentity,
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
    return RemoteProcessIdentity.fromDaemonIdentity(identity).toProto(guid);
}

pub const RecordRemoteProcessStartedOptions = struct {
    allocator: std.mem.Allocator,
    local: LocalProcessIdentity,
    endpoint: RemoteEndpoint,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
};

pub fn recordRemoteProcessStarted(options: RecordRemoteProcessStartedOptions) !void {
    const allocator = options.allocator;
    const local = options.local;
    const endpoint = options.endpoint;
    const process = options.process;
    try validateGuidForFile(process.guid);
    const record = Record{
        .guid = process.guid,
        .local = local,
        .endpoint = endpoint,
        .remote = RemoteProcessIdentity.fromProto(process),
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

pub const RemoteProcessCleanupRequestQueuedOptions = struct {
    allocator: std.mem.Allocator,
    mux_writer: *frame_write_queue.FrameWriteQueue,
    identity: daemon_identity.DaemonIdentity,
    request: pb.DaemonTunnelItem.RemoteProcessCleanupRequest,
};

pub fn handleRemoteProcessCleanupRequestQueued(options: RemoteProcessCleanupRequestQueuedOptions) !void {
    const allocator = options.allocator;
    const mux_writer = options.mux_writer;
    const identity = options.identity;
    const request = options.request;
    const process = request.process orelse return error.UnexpectedFrame;
    const result = cleanupRemoteProcess(allocator, identity, process) catch .missing;
    try queueRemoteProcessCleanupResponse(mux_writer, process, result);
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
    return tryAcquireSweepLockPath(allocator, path);
}

// Try to become the one daemon doing the periodic stale-record sweep. This is a
// non-blocking flock: if another daemon holds it, this daemon just skips the
// sweep and stays responsive to its own clients.
fn tryAcquireSweepLockPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?SweepLock {
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

pub const SweepRecordsOptions = struct {
    allocator: std.mem.Allocator,
    cleanup_retry_limit_ms: u64,
    context: *anyopaque,
    clean_fn: SweepCleanFn,
};

/// Scan durable remote-process records and ask the supplied cleaner to clean up
/// records whose local process is no longer alive. Records are one file per guid
/// so normal process startup can publish cleanup state with an atomic rename
/// instead of contending on one append log.
pub fn sweepRecords(options: SweepRecordsOptions) !void {
    const allocator = options.allocator;
    const cleanup_retry_limit_ms = options.cleanup_retry_limit_ms;
    const context = options.context;
    const clean_fn = options.clean_fn;
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
        try sweepRecordPath(.{
            .allocator = allocator,
            .path = path,
            .guid = guid,
            .cleanup_retry_limit_ms = cleanup_retry_limit_ms,
            .context = context,
            .clean_fn = clean_fn,
        });
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

    if (!daemon_identity.processIdentityMatches(allocator, process.pid, process.start_time)) return .missing;
    posix.kill(@intCast(process.pid), posix.SIG.HUP) catch return .missing;
    daemon_log.infof(allocator, "cleanup signaled remote process guid={s} pid={}", .{ process.guid, process.pid });
    return .cleaned;
}

fn cleanupGuidOnCurrentDaemon(allocator: std.mem.Allocator, guid: []const u8) !CleanupResult {
    if (std.mem.startsWith(u8, guid, "s-")) {
        terminal_worker.requestTerminalWorkerCleanup(allocator, guid) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => return .missing,
            else => return err,
        };
        daemon_log.infof(allocator, "cleanup hung up terminal session guid={s}", .{guid});
        return .cleaned;
    }
    if (std.mem.startsWith(u8, guid, "p-")) {
        proxy_worker.requestProxyRemoteCleanup(allocator, guid) catch |err| switch (err) {
            error.StreamNotFound, error.InvalidProxyId => return .missing,
            else => return err,
        };
        daemon_log.infof(allocator, "cleanup closed proxy stream guid={s}", .{guid});
        return .cleaned;
    }
    return .missing;
}

fn queueRemoteProcessCleanupResponse(
    mux_writer: *frame_write_queue.FrameWriteQueue,
    process: pb.DaemonTunnelItem.RemoteProcessIdentity,
    result: CleanupResult,
) !void {
    const result_payload: pb.DaemonTunnelItem.RemoteProcessCleanupResponse.result_union = switch (result) {
        .cleaned => .{ .cleaned = .{} },
        .missing => .{ .missing = .{} },
    };
    try mux_writer.queueDaemonTunnelPayload(.{ .remote_process_cleanup_response = .{
        .process = process,
        .result = result_payload,
    } });
}

fn writeRecord(allocator: std.mem.Allocator, record: Record) !void {
    const procs_dir = try ensureProcsDir(allocator);
    defer allocator.free(procs_dir);
    try writeRecordInProcsDir(allocator, procs_dir, record);
}

// Persist a cleanup record with write+fsync+rename so a crash cannot leave a
// partially-written JSON file with a valid final name.
fn writeRecordInProcsDir(allocator: std.mem.Allocator, procs_dir: []const u8, record: Record) !void {
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
        .local_pid = record.local.pid,
        .local_start_time = record.local.start_time,
        .remote_user = record.endpoint.user,
        .remote_host = record.endpoint.host,
        .remote_port = record.endpoint.port,
        .remote_pid = record.remote.pid,
        .remote_start_time = record.remote.start_time,
        .remote_socket_path = record.remote.socket_path,
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
    if (!guid_ref.isValidGuid(guid)) return error.InvalidGuid;
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

const SweepRecordOptions = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    guid: []const u8,
    cleanup_retry_limit_ms: u64,
    context: *anyopaque,
    clean_fn: SweepCleanFn,
};

// Evaluate one durable cleanup record. The local process identity prevents pid
// reuse from triggering cleanup of a live session, and record mtime is the retry
// age so old records can be abandoned without rewriting them on every sweep.
fn sweepRecordPath(options: SweepRecordOptions) !void {
    const allocator = options.allocator;
    const path = options.path;
    const guid = options.guid;
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
        .local = .{
            .pid = persisted.local_pid,
            .start_time = persisted.local_start_time,
        },
        .endpoint = .{
            .user = persisted.remote_user,
            .host = persisted.remote_host,
            .port = persisted.remote_port,
        },
        .remote = .{
            .pid = persisted.remote_pid,
            .start_time = persisted.remote_start_time,
            .socket_path = persisted.remote_socket_path,
        },
    };

    if (daemon_identity.processIdentityMatches(allocator, record.local.pid, record.local.start_time)) return;

    // The record's mtime is the retry-age clock. The JSON payload describes
    // the remote process identity, while the filesystem timestamp lets cleanup
    // abandon stale records without rewriting them during normal retries.
    const now_ms = nowUnixMs();
    const record_mtime_unix_ms = fileMtimeUnixMs(stat);
    if (options.cleanup_retry_limit_ms > 0 and record_mtime_unix_ms > 0 and now_ms -| record_mtime_unix_ms >= options.cleanup_retry_limit_ms) {
        daemon_log.infof(allocator, "cleanup record expired guid={s}", .{guid});
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const result = options.clean_fn(options.context, allocator, record) catch return;
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

test "local process identity clone owns start time" {
    const borrowed = LocalProcessIdentity{
        .pid = 42,
        .start_time = "local-start",
    };

    var owned = try LocalProcessIdentity.clone(std.testing.allocator, borrowed);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(borrowed.pid, owned.pid);
    try std.testing.expectEqualStrings(borrowed.start_time, owned.start_time);
    try std.testing.expect(borrowed.start_time.ptr != owned.start_time.ptr);
}

test "remote process identity clone owns string fields" {
    const borrowed = RemoteProcessIdentity{
        .pid = 43,
        .start_time = "remote-start",
        .socket_path = "/tmp/sesshd.sock",
    };

    var owned = try RemoteProcessIdentity.clone(std.testing.allocator, borrowed);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(borrowed.pid, owned.pid);
    try std.testing.expectEqualStrings(borrowed.start_time, owned.start_time);
    try std.testing.expectEqualStrings(borrowed.socket_path, owned.socket_path);
    try std.testing.expect(borrowed.start_time.ptr != owned.start_time.ptr);
    try std.testing.expect(borrowed.socket_path.ptr != owned.socket_path.ptr);
}

test "daemon identity maps to cleanup protocol identity" {
    const process = makeRemoteProcessIdentity(.{
        .pid = 44,
        .start_time = "daemon-start",
        .socket_path = "/tmp/daemon.sock",
    }, "s-550e8400-e29b-41d4-a716-446655440000");

    try std.testing.expectEqual(@as(u64, 44), process.pid);
    try std.testing.expectEqualStrings("daemon-start", process.start_time);
    try std.testing.expectEqualStrings("/tmp/daemon.sock", process.daemon_socket_path);
    try std.testing.expectEqualStrings("s-550e8400-e29b-41d4-a716-446655440000", process.guid);
}

test "record filename provides cleanup guid" {
    try std.testing.expectEqualStrings(
        "s-550e8400-e29b-41d4-a716-446655440000",
        try guidFromRecordFilename("s-550e8400-e29b-41d4-a716-446655440000.json"),
    );
    try std.testing.expectEqualStrings(
        "p-550e8400-e29b-41d4-a716-446655440000",
        try guidFromRecordFilename("p-550e8400-e29b-41d4-a716-446655440000.json"),
    );
    try std.testing.expectError(error.InvalidGuid, guidFromRecordFilename("s-nope/nope.json"));
    try std.testing.expectError(error.InvalidGuid, guidFromRecordFilename("s-550e8400-e29b-41d4-a716-446655440000"));
}

test "cleanup record JSON omits filename-owned identity and age fields" {
    var json_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(recordJsonFromRecord(.{
        .guid = "s-550e8400-e29b-41d4-a716-446655440000",
        .local = .{
            .pid = 12,
            .start_time = "local-start",
        },
        .endpoint = .{
            .user = "user",
            .host = "host",
            .port = "22",
        },
        .remote = .{
            .pid = 34,
            .start_time = "remote-start",
            .socket_path = "/tmp/sesshd.sock",
        },
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

test "cleanup record writer uses filename identity for session and proxy resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const procs_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(procs_dir);

    const session_guid = "s-550e8400-e29b-41d4-a716-446655440000";
    const proxy_guid = "p-550e8400-e29b-41d4-a716-446655440000";

    try writeRecordInProcsDir(allocator, procs_dir, .{
        .guid = session_guid,
        .local = .{
            .pid = 12,
            .start_time = "local-start",
        },
        .endpoint = .{
            .user = "user",
            .host = "host",
            .port = "22",
        },
        .remote = .{
            .pid = 34,
            .start_time = "remote-start",
            .socket_path = "/tmp/session.sock",
        },
    });
    try writeRecordInProcsDir(allocator, procs_dir, .{
        .guid = proxy_guid,
        .local = .{
            .pid = 56,
            .start_time = "proxy-local-start",
        },
        .endpoint = .{
            .user = "proxy-user",
            .host = "proxy-host",
            .port = "2222",
        },
        .remote = .{
            .pid = 78,
            .start_time = "proxy-remote-start",
            .socket_path = "/tmp/proxy.sock",
        },
    });

    const session_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ procs_dir, session_guid });
    defer allocator.free(session_path);
    const proxy_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ procs_dir, proxy_guid });
    defer allocator.free(proxy_path);

    const session_bytes = try std.fs.cwd().readFileAlloc(allocator, session_path, 64 * 1024);
    defer allocator.free(session_bytes);
    const proxy_bytes = try std.fs.cwd().readFileAlloc(allocator, proxy_path, 64 * 1024);
    defer allocator.free(proxy_bytes);

    for ([_][]const u8{ session_bytes, proxy_bytes }) |bytes| {
        try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"guid\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "recorded_at_unix_ms") == null);
    }

    var parsed_session = try std.json.parseFromSlice(RecordJson, allocator, session_bytes, .{});
    defer parsed_session.deinit();
    try std.testing.expectEqual(@as(u64, 12), parsed_session.value.local_pid);
    try std.testing.expectEqualStrings("/tmp/session.sock", parsed_session.value.remote_socket_path);

    var parsed_proxy = try std.json.parseFromSlice(RecordJson, allocator, proxy_bytes, .{});
    defer parsed_proxy.deinit();
    try std.testing.expectEqual(@as(u64, 56), parsed_proxy.value.local_pid);
    try std.testing.expectEqualStrings("proxy-host", parsed_proxy.value.remote_host);
    try std.testing.expectEqualStrings("/tmp/proxy.sock", parsed_proxy.value.remote_socket_path);

    const session_file = try std.fs.openFileAbsolute(session_path, .{});
    defer session_file.close();
    const stat = try session_file.stat();
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));

    var dir = try std.fs.openDirAbsolute(procs_dir, .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".tmp.") != null) {
            return error.LeftoverCleanupRecordTempFile;
        }
    }
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

test "cleanup sweep lock prevents duplicate sweep owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const tmp_path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(tmp_path_z);
    if (c.chmod(tmp_path_z.ptr, 0o700) != 0) return error.ChmodFailed;
    const lock_path = try std.fs.path.join(allocator, &.{ tmp_path, "cleanup-sweep" });
    defer allocator.free(lock_path);

    var first = (try tryAcquireSweepLockPath(allocator, lock_path)) orelse return error.ExpectedSweepLock;
    defer first.deinit();
    const second = try tryAcquireSweepLockPath(allocator, lock_path);
    try std.testing.expect(second == null);
}

test "expired cleanup record is deleted without invoking remote cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const record_path = try std.fs.path.join(allocator, &.{ tmp_path, "p-550e8400-e29b-41d4-a716-446655440000.json" });
    defer allocator.free(record_path);

    const file = try tmp.dir.createFile("p-550e8400-e29b-41d4-a716-446655440000.json", .{});
    try file.writeAll(
        \\{"local_pid":99999999,"local_start_time":"missing-local","remote_user":"user","remote_host":"host","remote_port":"22","remote_pid":99999998,"remote_start_time":"missing-remote","remote_socket_path":"/tmp/sesshd.sock"}
        \\
    );

    const old_ns = std.time.nanoTimestamp() - 2 * std.time.ns_per_s;
    try file.updateTimes(old_ns, old_ns);
    file.close();

    var invoked = false;
    try sweepRecordPath(.{
        .allocator = allocator,
        .path = record_path,
        .guid = "p-550e8400-e29b-41d4-a716-446655440000",
        .cleanup_retry_limit_ms = 1,
        .context = &invoked,
        .clean_fn = testing.sweepCleanMarksInvoked,
    });

    try std.testing.expect(!invoked);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(record_path, .{}));
}

test "cleanup sweep skips live local owner and deletes missing dead owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const procs_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(procs_dir);

    const local = try currentLocalProcessIdentity(allocator);
    defer allocator.free(local.start_time);

    const live_guid = "s-550e8400-e29b-41d4-a716-446655440000";
    const dead_guid = "p-550e8400-e29b-41d4-a716-446655440000";
    try writeRecordInProcsDir(allocator, procs_dir, .{
        .guid = live_guid,
        .local = local,
        .endpoint = .{
            .user = "user",
            .host = "host",
            .port = "22",
        },
        .remote = .{
            .pid = 34,
            .start_time = "remote-start",
            .socket_path = "/tmp/live.sock",
        },
    });
    try writeRecordInProcsDir(allocator, procs_dir, .{
        .guid = dead_guid,
        .local = .{
            .pid = 99999999,
            .start_time = "missing-local",
        },
        .endpoint = .{
            .user = "user",
            .host = "host",
            .port = "22",
        },
        .remote = .{
            .pid = 99999998,
            .start_time = "missing-remote",
            .socket_path = "/tmp/dead.sock",
        },
    });

    const live_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ procs_dir, live_guid });
    defer allocator.free(live_path);
    const dead_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ procs_dir, dead_guid });
    defer allocator.free(dead_path);

    var context = testing.SweepContext{};
    try sweepRecordPath(.{
        .allocator = allocator,
        .path = live_path,
        .guid = live_guid,
        .cleanup_retry_limit_ms = 0,
        .context = &context,
        .clean_fn = testing.sweepCleanReturnsMissing,
    });
    try std.testing.expectEqual(@as(usize, 0), context.invocations);
    {
        const file = try std.fs.openFileAbsolute(live_path, .{});
        file.close();
    }

    try sweepRecordPath(.{
        .allocator = allocator,
        .path = dead_path,
        .guid = dead_guid,
        .cleanup_retry_limit_ms = 0,
        .context = &context,
        .clean_fn = testing.sweepCleanReturnsMissing,
    });
    try std.testing.expectEqual(@as(usize, 1), context.invocations);
    try std.testing.expectEqualStrings(dead_guid, context.last_guid.?);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(dead_path, .{}));
}

const testing = if (builtin.is_test) struct {
    const SweepContext = struct {
        invocations: usize = 0,
        last_guid: ?[]const u8 = null,
    };

    fn sweepCleanReturnsMissing(ctx: *anyopaque, allocator: std.mem.Allocator, record: Record) !CleanupResult {
        _ = allocator;
        const context: *SweepContext = @ptrCast(@alignCast(ctx));
        context.invocations += 1;
        context.last_guid = record.guid;
        return .missing;
    }

    fn sweepCleanMarksInvoked(ctx: *anyopaque, allocator: std.mem.Allocator, record: Record) !CleanupResult {
        _ = allocator;
        _ = record;
        const invoked: *bool = @ptrCast(@alignCast(ctx));
        invoked.* = true;
        return .cleaned;
    }
} else struct {};
