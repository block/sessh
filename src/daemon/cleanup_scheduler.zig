const std = @import("std");

const dispatcher = @import("../core/dispatcher.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_log = @import("log.zig");
const transport_ssh = @import("../transport/ssh.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    cleanup_wakeup_interval_ms: u64,
    cleanup_retry_limit_ms: u64,
    sweep_lock: ?daemon_cleanup.SweepLock = null,
    initial_sweep_satisfied: bool = false,
    shutdown_satisfied: bool = false,

    pub fn deinit(self: *Context) void {
        self.releaseSweepLock();
    }

    pub fn maintain(self: *Context, now_ms: u64, has_local_client: bool) !bool {
        if (!self.enabled()) {
            self.releaseSweepLock();
            self.initial_sweep_satisfied = true;
            self.shutdown_satisfied = true;
            return false;
        }

        const has_records = daemon_cleanup.hasRecords(self.allocator);
        const decision = cleanupMaintenanceDecision(.{
            .has_records = has_records,
            .has_local_client = has_local_client,
            .has_lock = self.sweep_lock != null,
            .initial_sweep_satisfied = self.initial_sweep_satisfied,
            .shutdown_satisfied = self.shutdown_satisfied,
        });

        if (decision.release_without_sweep) {
            self.releaseSweepLock();
        }
        self.initial_sweep_satisfied = decision.initial_sweep_satisfied;
        self.shutdown_satisfied = decision.shutdown_satisfied;
        if (decision.acquire) {
            const acquired = try daemon_cleanup.tryAcquireSweepLock(self.allocator);
            if (acquired) |lock| {
                self.sweep_lock = lock;
            } else {
                self.shutdown_satisfied = decision.shutdown_satisfied_on_acquire_failure;
                return decision.keeps_daemon_alive;
            }
        }
        if (decision.sweep == .if_due) {
            if (self.sweep_lock == null) {
                return decision.keeps_daemon_alive;
            }
            if (self.sweep_lock) |*lock| {
                if (try daemon_cleanup.sweepDueAndMark(
                    lock,
                    self.cleanup_wakeup_interval_ms,
                    now_ms,
                )) {
                    try self.runSweep();
                }
            }
        } else if (decision.sweep == .always) {
            if (self.sweep_lock) |*lock| try daemon_cleanup.markSweepStarted(lock, now_ms);
            try self.runSweep();
            self.initial_sweep_satisfied = true;
        }
        if (decision.release_after_sweep) self.releaseSweepLock();
        return decision.keeps_daemon_alive;
    }

    fn enabled(self: *const Context) bool {
        return self.cleanup_wakeup_interval_ms > 0;
    }

    fn releaseSweepLock(self: *Context) void {
        if (self.sweep_lock) |*lock| lock.deinit();
        self.sweep_lock = null;
    }

    fn runSweep(self: *Context) !void {
        daemon_log.infof(self.allocator, "cleanup sweep started", .{});
        try daemon_cleanup.sweepRecords(
            self.allocator,
            self.cleanup_retry_limit_ms,
            self,
            cleanupRecordViaRemote,
        );
        daemon_log.infof(self.allocator, "cleanup sweep finished", .{});
    }
};

const CleanupSweepMode = enum {
    none,
    if_due,
    always,
};

const CleanupMaintenanceInput = struct {
    has_records: bool,
    has_local_client: bool,
    has_lock: bool,
    initial_sweep_satisfied: bool,
    shutdown_satisfied: bool,
};

const CleanupMaintenanceDecision = struct {
    acquire: bool = false,
    sweep: CleanupSweepMode = .none,
    release_without_sweep: bool = false,
    release_after_sweep: bool = false,
    keeps_daemon_alive: bool = false,
    initial_sweep_satisfied: bool = false,
    shutdown_satisfied: bool = false,
    shutdown_satisfied_on_acquire_failure: bool = false,
};

fn cleanupMaintenanceDecision(input: CleanupMaintenanceInput) CleanupMaintenanceDecision {
    if (!input.has_records) {
        return .{
            .release_without_sweep = input.has_lock,
            .initial_sweep_satisfied = true,
            .shutdown_satisfied = true,
        };
    }
    if (input.has_local_client) {
        if (!input.initial_sweep_satisfied) {
            return .{
                .acquire = !input.has_lock,
                .sweep = .always,
                .keeps_daemon_alive = true,
                .initial_sweep_satisfied = false,
                .shutdown_satisfied = false,
                .shutdown_satisfied_on_acquire_failure = false,
            };
        }
        return .{
            .acquire = !input.has_lock,
            .sweep = .if_due,
            .keeps_daemon_alive = true,
            .initial_sweep_satisfied = true,
            .shutdown_satisfied = false,
            .shutdown_satisfied_on_acquire_failure = false,
        };
    }
    if (input.shutdown_satisfied) {
        return .{
            .initial_sweep_satisfied = input.initial_sweep_satisfied,
            .shutdown_satisfied = true,
        };
    }
    return .{
        .acquire = !input.has_lock,
        .sweep = .always,
        .release_after_sweep = true,
        .initial_sweep_satisfied = true,
        .shutdown_satisfied = true,
        .shutdown_satisfied_on_acquire_failure = true,
    };
}

fn cleanupRecordViaRemote(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    record: daemon_cleanup.Record,
) !daemon_cleanup.CleanupResult {
    const cleanup_context: *Context = @ptrCast(@alignCast(ctx));
    daemon_log.infof(
        allocator,
        "cleanup record enqueueing remote cleanup guid={s} host={s}@{s}:{s}",
        .{ record.guid, record.remote_user, record.remote_host, record.remote_port },
    );
    try transport_ssh.enqueueCleanupRequestToRemote(allocator, cleanup_context.daemon_dispatcher, record);
    daemon_log.infof(
        allocator,
        "cleanup record remote cleanup enqueued guid={s}",
        .{record.guid},
    );
    return error.CleanupRequestEnqueued;
}

test "cleanup maintenance decisions sweep pre-existing records for live clients" {
    const decision = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = true,
        .has_lock = false,
        .initial_sweep_satisfied = false,
        .shutdown_satisfied = true,
    });
    try std.testing.expect(decision.acquire);
    try std.testing.expectEqual(CleanupSweepMode.always, decision.sweep);
    try std.testing.expect(decision.keeps_daemon_alive);
    try std.testing.expect(!decision.release_after_sweep);
    try std.testing.expect(!decision.shutdown_satisfied);
}

test "cleanup maintenance decisions hold lock for live clients after initial sweep" {
    const decision = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = true,
        .has_lock = false,
        .initial_sweep_satisfied = true,
        .shutdown_satisfied = true,
    });
    try std.testing.expect(decision.acquire);
    try std.testing.expectEqual(CleanupSweepMode.if_due, decision.sweep);
    try std.testing.expect(decision.keeps_daemon_alive);
    try std.testing.expect(!decision.release_after_sweep);
    try std.testing.expect(decision.initial_sweep_satisfied);
    try std.testing.expect(!decision.shutdown_satisfied);
}

test "cleanup maintenance decisions let idle daemon exit after one attempt" {
    const needs_attempt = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = false,
        .has_lock = false,
        .initial_sweep_satisfied = false,
        .shutdown_satisfied = false,
    });
    try std.testing.expect(needs_attempt.acquire);
    try std.testing.expectEqual(CleanupSweepMode.always, needs_attempt.sweep);
    try std.testing.expect(needs_attempt.release_after_sweep);
    try std.testing.expect(needs_attempt.shutdown_satisfied);
    try std.testing.expect(needs_attempt.shutdown_satisfied_on_acquire_failure);
    try std.testing.expect(!needs_attempt.keeps_daemon_alive);

    const already_attempted = cleanupMaintenanceDecision(.{
        .has_records = true,
        .has_local_client = false,
        .has_lock = false,
        .initial_sweep_satisfied = true,
        .shutdown_satisfied = true,
    });
    try std.testing.expect(!already_attempted.acquire);
    try std.testing.expectEqual(CleanupSweepMode.none, already_attempted.sweep);
    try std.testing.expect(already_attempted.shutdown_satisfied);
}

test "cleanup maintenance decisions release stale idle locks when no records remain" {
    const decision = cleanupMaintenanceDecision(.{
        .has_records = false,
        .has_local_client = false,
        .has_lock = true,
        .initial_sweep_satisfied = false,
        .shutdown_satisfied = false,
    });
    try std.testing.expect(decision.release_without_sweep);
    try std.testing.expectEqual(CleanupSweepMode.none, decision.sweep);
    try std.testing.expect(decision.initial_sweep_satisfied);
    try std.testing.expect(decision.shutdown_satisfied);
    try std.testing.expect(!decision.keeps_daemon_alive);
}
