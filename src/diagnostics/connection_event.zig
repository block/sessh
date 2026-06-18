const std = @import("std");

const local_boot_time = @import("../core/local_boot_time.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const RetryReason = enum {
    disconnected,
    unresponsive,
};

pub const Action = union(enum) {
    none,
    ssh_stderr: pb.ConnectionEvent.SshStderr,
    binary_bootstrapping,
    daemon_connecting,
    daemon_connected,
    retry: Retry,
    ssh_connecting,
    ssh_connected,
};

pub const Retry = struct {
    reason: RetryReason,
    delay_ms: u64,
};

pub fn classify(event: pb.ConnectionEvent) Action {
    return switch (event.event orelse return .none) {
        .ssh_stderr => |stderr| .{ .ssh_stderr = stderr },
        .binary_bootstrapping => .binary_bootstrapping,
        .daemon_connecting => .daemon_connecting,
        .daemon_connected => .daemon_connected,
        .daemon_disconnected => |disconnected| .{ .retry = .{
            .reason = .disconnected,
            .delay_ms = retryDelayFromLocalBootDeadline(disconnected.retry_at_local_boot_time_ms),
        } },
        .unresponsive => |unresponsive| .{ .retry = .{
            .reason = .unresponsive,
            .delay_ms = retryDelayFromLocalBootDeadline(unresponsive.retry_at_local_boot_time_ms),
        } },
        .ssh_connecting => .ssh_connecting,
        .ssh_connected => .ssh_connected,
    };
}

pub fn retryDelayFromLocalBootDeadline(deadline_ms: ?u64) u64 {
    const deadline = deadline_ms orelse return 0;
    const now = local_boot_time.nowMs();
    return deadline -| now;
}

test "connection event classifier turns local boot retry deadlines into delays" {
    const deadline = local_boot_time.nowMs() + 5_000;
    const action = classify(.{ .event = .{ .daemon_disconnected = .{
        .retry_at_local_boot_time_ms = deadline,
    } } });
    switch (action) {
        .retry => |retry| {
            try std.testing.expectEqual(RetryReason.disconnected, retry.reason);
            try std.testing.expect(retry.delay_ms <= 5_000);
        },
        else => return error.ExpectedRetry,
    }
}
