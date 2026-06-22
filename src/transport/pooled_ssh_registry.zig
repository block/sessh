// Process-global registry for pooled SSH transports. A local sesshd owns one
// registry: clients use it to reuse compatible daemon-to-daemon tunnels, and
// daemon shutdown uses its active count to decide whether pooled work remains.
const std = @import("std");

const daemon_log = @import("../daemon/log.zig");
const pooled_ssh_identity = @import("pooled_ssh_identity.zig");
const pooled_ssh_model = @import("pooled_ssh_model.zig");
const protocol = @import("../protocol/mod.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");
const string_list = @import("../core/string_list.zig");

const pb = protocol.pb;

const Client = pooled_ssh_model.Client;
const Transport = pooled_ssh_model.Transport;
const Acquire = pooled_ssh_model.Acquire;
const SshTarget = ssh_transport_process.Target;

var transports: std.ArrayList(*Transport) = .empty;
var active_transports: usize = 0;

pub fn activeCount() usize {
    return active_transports;
}

pub const SingleTerminalClient = union(enum) {
    none,
    ambiguous,
    client: *Client,
};

/// Find the one live terminal stream currently owned by the pooled transport
/// registry. The debug harness uses this to simulate a broken SSH connection
/// without knowing the generated session id. Matching the old terminal-worker
/// helper, multiple candidates are treated as ambiguous rather than guessing.
pub fn singleActiveTerminalClient() SingleTerminalClient {
    var found: ?*Client = null;
    for (transports.items) |transport| {
        if (transport.state == .closed or transport.state == .closing) continue;
        for (transport.clients.items) |client| {
            if (client.state != .active or client.kind != .te or client.done) continue;
            if (found != null) return .ambiguous;
            found = client;
        }
    }
    return if (found) |client| .{ .client = client } else .none;
}

pub const AcquireOptions = struct {
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    client: *Client,
};

pub fn acquire(options: AcquireOptions) !Acquire {
    const allocator = options.allocator;
    const result = try findOrCreate(allocator, options.target, options.request);
    errdefer if (result.created) destroyUnstarted(allocator, result.transport);
    try result.transport.clients.append(allocator, options.client);
    return result;
}

// Look up a live pooled transport by the conservative reuse key. Closed/closing
// transports are skipped so a new client never attaches to a tunnel that is
// already delivering failure or cleanup events.
pub fn findOrCreate(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !Acquire {
    const key = try pooled_ssh_identity.key(allocator, target, request);
    errdefer allocator.free(key);

    for (transports.items) |transport| {
        if (transport.state == .closed or transport.state == .closing) continue;
        if (!std.mem.eql(u8, transport.key, key)) continue;
        allocator.free(key);
        daemon_log.infof(
            allocator,
            "pooled ssh transport reusing host={s} pool={s} remote_namespace={s}",
            .{ target.host, transport.key, transport.remote_daemon_namespace orelse "remote-default" },
        );
        return .{ .transport = transport, .created = false };
    }

    const transport = try allocator.create(Transport);
    errdefer allocator.destroy(transport);
    transport.* = .{
        .allocator = allocator,
        .key = key,
        .display_host = try allocator.dupe(u8, target.host),
        .resolved_user = try allocator.dupe(u8, target.resolved_user),
        .resolved_host = try allocator.dupe(u8, target.resolved_host),
        .resolved_port = try allocator.dupe(u8, target.resolved_port),
        .ssh_options = try string_list.cloneOwned(allocator, target.options),
    };
    errdefer transport.deinit();
    try transports.append(allocator, transport);
    active_transports += 1;
    daemon_log.infof(
        allocator,
        "pooled ssh transport creating host={s} pool={s}",
        .{ target.host, transport.key },
    );
    return .{ .transport = transport, .created = true };
}

pub fn destroyUnstarted(allocator: std.mem.Allocator, transport: *Transport) void {
    remove(transport);
    active_transports -= 1;
    transport.deinit();
    allocator.destroy(transport);
}

pub fn finishDestroy(transport: *Transport) void {
    active_transports -= 1;
    const allocator = transport.allocator;
    transport.deinit();
    allocator.destroy(transport);
}

pub fn remove(transport: *Transport) void {
    var index: usize = 0;
    while (index < transports.items.len) : (index += 1) {
        if (transports.items[index] != transport) continue;
        _ = transports.swapRemove(index);
        break;
    }
}
