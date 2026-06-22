// Client construction for pooled SSH transports. The caller decides which
// pooled transport to attach to; this module owns duplicating acquire-request
// state so a client can safely outlive the short-lived daemon IPC request.
const std = @import("std");
const c = std.c;

const client_env = @import("client_environment.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const pooled_ssh_model = @import("pooled_ssh_model.zig");
const protocol = @import("../protocol/mod.zig");
const ssh_transport_acquire = @import("ssh_transport_acquire.zig");
const string_list = @import("../core/string_list.zig");

const pb = protocol.pb;

const Client = pooled_ssh_model.Client;

pub const CreateOptions = struct {
    fd: c.fd_t,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
};

pub fn createFromAcquire(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !*Client {
    const request = options.request;
    const client = try allocator.create(Client);
    errdefer allocator.destroy(client);

    var local_cleanup = try localCleanupIdentityFromAcquire(allocator, request);
    errdefer if (local_cleanup) |*local| local.deinit(allocator);
    var send_env_copy = try string_list.cloneOwned(allocator, options.send_env);
    errdefer string_list.freeOwned(allocator, send_env_copy);
    var client_environment = try client_env.clone(allocator, request.client_environment.items);
    errdefer client_env.deinit(allocator, &client_environment);

    client.* = .{
        .fd = options.fd,
        .startup_timing = .startedNow(),
        .local_cleanup = local_cleanup,
        .send_env = send_env_copy,
        .client_environment = client_environment,
        .isolation_mode = ssh_transport_acquire.protoIsolationModeFromAcquire(request),
    };
    local_cleanup = null;
    send_env_copy = &.{};
    client_environment = .empty;
    client.initReader(allocator);
    return client;
}

fn localCleanupIdentityFromAcquire(
    allocator: std.mem.Allocator,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !?daemon_cleanup.LocalProcessIdentity {
    if (request.local_pid == 0 or request.local_start_time.len == 0) return null;
    return try daemon_cleanup.LocalProcessIdentity.clone(allocator, .{
        .pid = request.local_pid,
        .start_time = request.local_start_time,
    });
}

test "pooled client creation owns acquire-derived fields" {
    const allocator = std.testing.allocator;
    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = "host",
        .local_pid = 123,
        .local_start_time = "start-token",
        .isolation_mode = .ISOLATION_MODE_FULL,
    };
    defer request.client_environment.deinit(allocator);
    try request.client_environment.append(allocator, .{
        .name = "SESSH_ENV",
        .value = "value",
    });
    const send_env = [_][]const u8{"SESSH_*"};

    const client = try createFromAcquire(allocator, .{
        .fd = -1,
        .request = request,
        .send_env = &send_env,
    });
    defer {
        client.deinit(allocator);
        allocator.destroy(client);
    }

    const local_cleanup = client.local_cleanup.?;
    try std.testing.expectEqual(@as(u64, 123), local_cleanup.pid);
    try std.testing.expectEqual(pb.IsolationMode.ISOLATION_MODE_FULL, client.isolation_mode);
    try std.testing.expectEqualStrings("start-token", local_cleanup.start_time);
    try std.testing.expect(local_cleanup.start_time.ptr != request.local_start_time.ptr);
    try std.testing.expectEqual(@as(usize, 1), client.send_env.len);
    try std.testing.expectEqualStrings("SESSH_*", client.send_env[0]);
    try std.testing.expect(client.send_env[0].ptr != send_env[0].ptr);
    try std.testing.expectEqual(@as(usize, 1), client.client_environment.items.len);
    try std.testing.expectEqualStrings("SESSH_ENV", client.client_environment.items[0].name);
    try std.testing.expectEqualStrings("value", client.client_environment.items[0].value);
    try std.testing.expect(client.client_environment.items[0].name.ptr != request.client_environment.items[0].name.ptr);
    try std.testing.expect(client.client_environment.items[0].value.ptr != request.client_environment.items[0].value.ptr);
}
