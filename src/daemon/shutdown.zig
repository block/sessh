const std = @import("std");

const dispatcher = @import("../core/dispatcher.zig");
const terminal_worker = @import("../session/terminal_worker.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");
const daemon_cleanup_scheduler = @import("cleanup_scheduler.zig");
const daemon_log = @import("log.zig");
const daemon_tunnel = @import("tunnel.zig");
const transport_ssh = @import("../transport/ssh.zig");

const daemon_idle_check_ms: u64 = 250;
const daemon_idle_shutdown_ms: u64 = 1_000;

pub const Context = struct {
    allocator: std.mem.Allocator,
    cleanup_context: *daemon_cleanup_scheduler.Context,
    active_local_clients: *usize,
    last_live_work_ms: u64,
    idle_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
};

pub fn watchIdle(context: *Context, daemon_dispatcher: *dispatcher.Dispatcher) !void {
    if (!context.idle_task.isInitialized()) {
        context.idle_task = dispatcher.timerDispatchTask(
            Context,
            context.allocator,
            context,
            checkDaemonIdle,
        );
    }
    context.idle_task.setTimerAfter(daemon_dispatcher, daemon_idle_check_ms);
    try context.idle_task.schedule(daemon_dispatcher);
}

fn checkDaemonIdle(
    idle_context: *Context,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
    _: dispatcher.TimerEvent,
) !@import("../core/dispatch_io.zig").DispatchTaskStatus {
    // sesshd should disappear when it has no clients, transports, workers, log
    // subscribers, or cleanup work. The grace window prevents rapid
    // start/stop churn between short sequential sessh invocations.
    const now_ms = daemon_dispatcher.nowMs();
    const cleanup_keeps_daemon_alive = try idle_context.cleanup_context.maintain(
        now_ms,
        if (idle_context.active_local_clients.* != 0) .present else .none,
    );
    if (daemonShouldStayAlive(.{
        .active_local_clients = idle_context.active_local_clients.*,
        .active_pooled_transports = transport_ssh.activePooledSshTransportCount(),
        .active_mux_connections = daemon_tunnel.activeMuxConnectionCount(),
        .active_terminal_workers = terminal_worker.activeTerminalWorkerHandleCount(),
        .active_proxy_workers = proxy_worker.activeProxyRemoteProcessCount(),
        .active_log_subscribers = daemon_log.activeSubscriberCount(),
        .cleanup_keeps_daemon_alive = cleanup_keeps_daemon_alive,
    })) {
        idle_context.last_live_work_ms = now_ms;
    } else if (daemonShouldStopForIdle(idle_context.last_live_work_ms, now_ms)) {
        daemon_log.infof(idle_context.allocator, "daemon idle; shutting down", .{});
        daemon_dispatcher.stop();
        return .done;
    }

    task.setTimerAfter(daemon_dispatcher, daemon_idle_check_ms);
    return .pending;
}

const LiveWorkSnapshot = struct {
    active_local_clients: usize = 0,
    active_pooled_transports: usize = 0,
    active_mux_connections: usize = 0,
    active_terminal_workers: usize = 0,
    active_proxy_workers: usize = 0,
    active_log_subscribers: usize = 0,
    cleanup_keeps_daemon_alive: bool = false,
};

fn daemonShouldStayAlive(snapshot: LiveWorkSnapshot) bool {
    return snapshot.active_local_clients != 0 or
        snapshot.active_pooled_transports != 0 or
        snapshot.active_mux_connections != 0 or
        snapshot.active_terminal_workers != 0 or
        snapshot.active_proxy_workers != 0 or
        snapshot.active_log_subscribers != 0 or
        snapshot.cleanup_keeps_daemon_alive;
}

fn daemonShouldStopForIdle(last_live_work_ms: u64, now_ms: u64) bool {
    return now_ms -| last_live_work_ms >= daemon_idle_shutdown_ms;
}

test "daemon idle shutdown uses saturating elapsed time" {
    try std.testing.expect(!daemonShouldStopForIdle(10_000, 9_999));
    try std.testing.expect(!daemonShouldStopForIdle(1_000, 1_999));
    try std.testing.expect(daemonShouldStopForIdle(1_000, 2_000));
}

test "daemon liveness snapshot exits when no useful work remains" {
    try std.testing.expect(!daemonShouldStayAlive(.{}));
}

test "daemon liveness snapshot retains pooled and remote work" {
    try std.testing.expect(daemonShouldStayAlive(.{ .active_pooled_transports = 1 }));
    try std.testing.expect(daemonShouldStayAlive(.{ .active_mux_connections = 1 }));
    try std.testing.expect(daemonShouldStayAlive(.{ .active_terminal_workers = 1 }));
    try std.testing.expect(daemonShouldStayAlive(.{ .active_proxy_workers = 1 }));
    try std.testing.expect(daemonShouldStayAlive(.{ .active_local_clients = 1 }));
    try std.testing.expect(daemonShouldStayAlive(.{ .active_log_subscribers = 1 }));
}

test "daemon liveness snapshot retains cleanup obligation" {
    try std.testing.expect(daemonShouldStayAlive(.{ .cleanup_keeps_daemon_alive = true }));
}
