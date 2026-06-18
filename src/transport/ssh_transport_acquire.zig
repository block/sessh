const std = @import("std");
const c = std.c;

const config = @import("../core/config.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub fn protoIsolationModeForConfig(mode: config.IsolationMode) pb.IsolationMode {
    return switch (mode) {
        .full => .ISOLATION_MODE_FULL,
        .process => .ISOLATION_MODE_PROCESS,
        .none => .ISOLATION_MODE_NONE,
    };
}

pub fn protoIsolationModeFromAcquire(request: pb.ClientDaemonItem.SshTransportAcquire) pb.IsolationMode {
    return switch (request.isolation_mode) {
        .ISOLATION_MODE_FULL => .ISOLATION_MODE_FULL,
        .ISOLATION_MODE_NONE => .ISOLATION_MODE_NONE,
        else => .ISOLATION_MODE_PROCESS,
    };
}

pub fn appendCurrentSshAgent(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    request.ssh_auth_sock = std.process.getEnvVarOwned(allocator, "SSH_AUTH_SOCK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

pub fn appendCurrentProcess(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    const local = try daemon_cleanup.currentLocalProcessIdentity(allocator);
    request.local_pid = local.pid;
    request.local_start_time = local.start_time;
}

pub fn appendParentProcess(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    const parent_pid = c.getppid();
    if (parent_pid <= 0) return error.ProcessStartTimeUnavailable;
    request.local_pid = @intCast(parent_pid);
    request.local_start_time = try daemon_identity.processStartTime(allocator, request.local_pid);
}

pub fn appendCurrentEnvironment(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    var index: usize = 0;
    while (c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        const name = try allocator.dupe(u8, entry[0..equals]);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry[equals + 1 ..]);
        errdefer allocator.free(value);
        try request.client_environment.append(allocator, .{
            .name = name,
            .value = value,
        });
    }
}

pub fn deinitOwnedFields(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) void {
    if (request.ssh_auth_sock) |path| allocator.free(path);
    request.ssh_auth_sock = null;
    if (request.local_start_time.len != 0) allocator.free(request.local_start_time);
    request.local_start_time = "";
    for (request.client_environment.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    request.client_environment.deinit(allocator);
}

pub fn envMap(
    allocator: std.mem.Allocator,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    if (request.ssh_auth_sock) |path| {
        try env.put("SSH_AUTH_SOCK", path);
    } else {
        env.remove("SSH_AUTH_SOCK");
    }
    return env;
}
