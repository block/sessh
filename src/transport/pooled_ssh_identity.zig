const std = @import("std");

const protocol = @import("../protocol/mod.zig");
const ssh_options = @import("ssh_options.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");

const pb = protocol.pb;

pub const SshTarget = ssh_transport_process.Target;

pub const ResolvedTarget = struct {
    target: SshTarget,
    config: ssh_options.ResolvedSshConfig,

    pub fn deinit(self: *ResolvedTarget, allocator: std.mem.Allocator) void {
        if (self.target.default_ipqos_option) |option| allocator.free(option);
        self.target.default_ipqos_option = null;
        self.config.deinit(allocator);
        self.* = undefined;
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    options: []const []const u8,
    host: []const u8,
) !ResolvedTarget {
    var resolved_config = try ssh_options.resolveSshConfig(allocator, options, host);
    errdefer resolved_config.deinit(allocator);
    const default_ipqos_option = try resolved_config.defaultIpQosOption(allocator);
    errdefer if (default_ipqos_option) |option| allocator.free(option);
    return .{
        .target = .{
            .options = options,
            .host = host,
            .default_ipqos_option = default_ipqos_option,
            .resolved_user = resolved_config.user,
            .resolved_host = resolved_config.hostname,
            .resolved_port = resolved_config.port,
        },
        .config = resolved_config,
    };
}

pub fn key(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendKeyPart(allocator, &result, target.resolved_user);
    try appendKeyPart(allocator, &result, target.resolved_host);
    try appendKeyPart(allocator, &result, target.resolved_port);
    try result.writer(allocator).print("bootstrap={}|", .{request.bootstrap});
    try result.appendSlice(allocator, "ipqos=");
    try appendKeyPart(allocator, &result, request.ip_qos);
    return result.toOwnedSlice(allocator);
}

fn appendKeyPart(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: []const u8) !void {
    try result.writer(allocator).print("{}:", .{value.len});
    try result.appendSlice(allocator, value);
    try result.append(allocator, '|');
}

test "pooled ssh transport key includes only transport identity fields" {
    const allocator = std.testing.allocator;
    const target = SshTarget{
        .options = &.{"-oProxyCommand=ignored"},
        .host = "alias-name",
        .resolved_user = "user",
        .resolved_host = "host.example",
        .resolved_port = "2222",
    };

    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = "alias-name",
        .bootstrap = true,
        .ssh_auth_sock = "/tmp/agent-a",
        .ip_qos = "af21",
        .local_pid = 100,
        .local_start_time = "start-a",
        .isolation_mode = .ISOLATION_MODE_PROCESS,
    };
    defer request.ssh_option.deinit(allocator);
    defer request.client_environment.deinit(allocator);
    try request.ssh_option.append(allocator, "-oCompression=yes");
    try request.client_environment.append(allocator, .{ .name = "SESSH_TEST", .value = "a" });

    const base = try key(allocator, target, request);
    defer allocator.free(base);

    var ignored_changed = request;
    ignored_changed.ssh_auth_sock = "/tmp/agent-b";
    ignored_changed.local_pid = 200;
    ignored_changed.local_start_time = "start-b";
    ignored_changed.isolation_mode = .ISOLATION_MODE_NONE;
    ignored_changed.ssh_option.items[0] = "-oCompression=no";
    ignored_changed.client_environment.items[0] = .{ .name = "SESSH_TEST", .value = "b" };
    const same = try key(allocator, target, ignored_changed);
    defer allocator.free(same);
    try std.testing.expectEqualStrings(base, same);

    var ipqos_changed = request;
    ipqos_changed.ip_qos = "ef";
    const different_ipqos = try key(allocator, target, ipqos_changed);
    defer allocator.free(different_ipqos);
    try std.testing.expect(!std.mem.eql(u8, base, different_ipqos));

    var bootstrap_changed = request;
    bootstrap_changed.bootstrap = false;
    const different_bootstrap = try key(allocator, target, bootstrap_changed);
    defer allocator.free(different_bootstrap);
    try std.testing.expect(!std.mem.eql(u8, base, different_bootstrap));

    const different_resolved_host = try key(allocator, .{
        .options = target.options,
        .host = target.host,
        .resolved_user = target.resolved_user,
        .resolved_host = "other.example",
        .resolved_port = target.resolved_port,
    }, request);
    defer allocator.free(different_resolved_host);
    try std.testing.expect(!std.mem.eql(u8, base, different_resolved_host));
}
