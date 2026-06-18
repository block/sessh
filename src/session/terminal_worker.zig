const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const input_translation = @import("input_translation.zig");
const io = @import("../core/io.zig");
const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const pty_process = @import("../tty/pty_process.zig");
const protocol = @import("../protocol/mod.zig");
const user_error = @import("../core/user_error.zig");
const guid_ref = @import("../core/guid.zig");
const socket_transport = @import("../transport/socket.zig");
const tty_settings = @import("../tty/settings.zig");
const vt = @import("vt.zig");
const remote_process = @import("remote_process.zig");
const attached_client_router = @import("attached_client_router.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");
const terminal_worker_render = @import("terminal_worker_render.zig");

const max_session_pty_input_queue_bytes = 16 * 1024 * 1024;
const preferred_live_output_batch_bytes = 1024;
const max_live_output_reads_per_batch = 64;
const synchronized_output_max_hold_ms: i64 = 1000;
const pty_hangup_reap_poll_ms = remote_process.pty_hangup_reap_poll_ms;
const pty_eof_exit_reap_poll_ms: i64 = 1;
const pty_eof_exit_status_grace_ms: i64 = 250;

const pb = protocol.pb;
const hpb = protocol.hpb;

const Session = terminal_worker_state.Session;
const AttachedClient = attached_client_router.AttachedClient;
const PendingWorkerClient = attached_client_router.PendingWorkerClient;
const WorkerFdWatch = attached_client_router.WorkerFdWatch;

const TerminalWorker = struct {
    session: Session = .{},
    attached_client: AttachedClient = .{},
    pending_client: PendingWorkerClient = .{},
    running: bool = true,
    monotonic_clock: ?NonSuspendingTimer = null,
    fixed_session_id: ?[]const u8 = null,
    started_session: bool = false,
};

pub const TerminalWorkerHandleKind = union(enum) {
    process: struct {
        socket_path: []u8,
        pid: c.pid_t = 0,
    },
    in_daemon: *DispatcherTerminalWorker,
};

pub const TerminalWorkerHandle = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    kind: TerminalWorkerHandleKind,

    pub fn deinit(self: *TerminalWorkerHandle, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        self.allocator.free(self.guid);
        switch (self.kind) {
            .process => |process| self.allocator.free(process.socket_path),
            .in_daemon => |worker| {
                worker.deinit(daemon_dispatcher);
                self.allocator.destroy(worker);
            },
        }
        self.* = undefined;
    }
};

const DispatcherTerminalWorker = struct {
    allocator: std.mem.Allocator,
    control: *TerminalWorkerHandle,
    terminal_worker: TerminalWorker,
    session_watch: WorkerFdWatch = .{},
    attached_watch: WorkerFdWatch = .{},
    pending_watch: WorkerFdWatch = .{},
    timer_watch_id: ?dispatcher.TimerWatchId = null,

    fn deinit(self: *DispatcherTerminalWorker, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            self.session_watch.cancel(d);
            self.attached_watch.cancel(d);
            self.pending_watch.cancel(d);
            if (self.timer_watch_id) |id| d.cancel(.{ .timer = id });
        }
        self.timer_watch_id = null;
        closeTerminalWorker(&self.terminal_worker);
        self.* = undefined;
    }

    fn connect(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher) !c.fd_t {
        if (!self.terminal_worker.running) return error.SessionNotFound;
        if (self.terminal_worker.pending_client.active) return error.PendingWorkerClientBusy;

        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        var daemon_fd: c.fd_t = fds[0];
        var worker_fd: c.fd_t = fds[1];
        errdefer {
            if (daemon_fd >= 0) _ = c.close(daemon_fd);
        }
        errdefer {
            if (worker_fd >= 0) _ = c.close(worker_fd);
        }

        try socket_transport.setCloseOnExec(daemon_fd);
        try socket_transport.setCloseOnExec(worker_fd);
        try core_fds.setNonBlocking(daemon_fd);
        try core_fds.setNonBlocking(worker_fd);

        self.terminal_worker.pending_client.start(worker_fd);
        worker_fd = -1;
        try self.updateWatches(daemon_dispatcher);
        const result = daemon_fd;
        daemon_fd = -1;
        return result;
    }

    fn updateWatches(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher) !void {
        if (!self.terminal_worker.running) {
            destroyRegisteredTerminalWorker(self.control, daemon_dispatcher);
            return;
        }

        const now_ms = terminalWorkerMonotonicMs(&self.terminal_worker);
        const session = &self.terminal_worker.session;
        if (session.alive and session.process.hasOpenPty()) {
            try self.ensureWatch(daemon_dispatcher, &self.session_watch, session.process.pty_fd, .{
                .readable = true,
                .writable = sessionHasPendingPtyInput(session),
            });
        } else {
            self.session_watch.cancel(daemon_dispatcher);
        }

        const attached_client = &self.terminal_worker.attached_client;
        if (attached_client.active) {
            const debug_unresponsive = attached_client.debug_unresponsive_until_ms > now_ms;
            try self.ensureWatch(daemon_dispatcher, &self.attached_watch, attached_client.fd, .{
                .readable = !attached_client.close_after_flush and !debug_unresponsive,
                .writable = !debug_unresponsive and attached_client.queuedBytes() > 0,
            });
        } else {
            self.attached_watch.cancel(daemon_dispatcher);
        }

        const pending_client = &self.terminal_worker.pending_client;
        if (pending_client.active) {
            try self.ensureWatch(daemon_dispatcher, &self.pending_watch, pending_client.fd, .{ .readable = true });
        } else {
            self.pending_watch.cancel(daemon_dispatcher);
        }

        try self.updateTimer(daemon_dispatcher, now_ms, nowUnixMs());
    }

    fn ensureWatch(
        self: *DispatcherTerminalWorker,
        daemon_dispatcher: *dispatcher.Dispatcher,
        watch: *WorkerFdWatch,
        fd: c.fd_t,
        events: dispatcher.FdEvents,
    ) !void {
        if (watch.id != null and watch.fd != fd) {
            watch.cancel(daemon_dispatcher);
        }
        if (watch.id) |id| {
            try daemon_dispatcher.updateFdEvents(id, events);
        } else {
            watch.id = try daemon_dispatcher.watchFd(fd, events, .{
                .ctx = self,
                .callback = handleDispatcherTerminalWorkerEvent,
            });
            watch.fd = fd;
        }
    }

    fn updateTimer(
        self: *DispatcherTerminalWorker,
        daemon_dispatcher: *dispatcher.Dispatcher,
        now_ms: i64,
        now_unix_ms: u64,
    ) !void {
        if (self.timer_watch_id) |id| daemon_dispatcher.cancel(.{ .timer = id });
        self.timer_watch_id = null;
        const timeout_ms = terminalWorkerPollTimeoutMs(&self.terminal_worker, now_ms, now_unix_ms);
        if (timeout_ms < 0) return;
        self.timer_watch_id = try daemon_dispatcher.watchTimerAfter(@intCast(timeout_ms), .{
            .ctx = self,
            .callback = handleDispatcherTerminalWorkerEvent,
        });
    }

    fn runMaintenance(self: *DispatcherTerminalWorker) void {
        runTerminalWorkerMaintenance(&self.terminal_worker);
        if (!self.terminal_worker.started_session and
            !self.terminal_worker.pending_client.active and
            !self.terminal_worker.attached_client.active and
            !self.terminal_worker.session.alive)
        {
            self.terminal_worker.running = false;
        }
    }
};

// PROCESS_GLOBAL_REGISTRY: the local daemon tracks process-isolated terminal
// remotes here so shutdown and cleanup can see whether useful remote work still
// exists. The daemon is single-threaded; mutations happen from dispatcher-owned
// callbacks.
var terminal_worker_handles: std.ArrayList(*TerminalWorkerHandle) = .empty;
const PollKind = union(enum) {
    listen,
    session,
    attached_client,
    pending_client,
};

const ExitInfo = remote_process.ExitInfo;

const terminal_worker_requests = @import("terminal_worker_requests.zig");
const SessionEnvironment = terminal_worker_requests.SessionEnvironment;
const AttachRequest = terminal_worker_requests.AttachRequest;
const RepaintRequest = terminal_worker_requests.RepaintRequest;
const ResizePayload = terminal_worker_requests.ResizePayload;
const readSessionCreateRequest = terminal_worker_requests.readSessionCreateRequest;
const resizePayloadFromMessage = terminal_worker_requests.resizePayloadFromMessage;
const attachRequestFromOpen = terminal_worker_requests.attachRequestFromOpen;
const repaintRequestFromMessage = terminal_worker_requests.repaintRequestFromMessage;

pub fn startTerminalWorkerInDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    session_guid: []const u8,
) !*TerminalWorkerHandle {
    const guid = try guid_ref.canonicalSessionGuid(allocator, session_guid);
    errdefer allocator.free(guid);

    const control = try allocator.create(TerminalWorkerHandle);
    errdefer allocator.destroy(control);
    const worker = try allocator.create(DispatcherTerminalWorker);
    errdefer allocator.destroy(worker);

    control.* = .{
        .allocator = allocator,
        .guid = guid,
        .kind = .{ .in_daemon = worker },
    };
    errdefer control.deinit(daemon_dispatcher);

    worker.* = .{
        .allocator = allocator,
        .control = control,
        .terminal_worker = .{ .fixed_session_id = guid },
    };

    try registerTerminalWorker(control);
    return control;
}

pub fn runTerminalWorkerLoop(session_guid: []const u8, listen_fd: c.fd_t) !void {
    var terminal_worker = TerminalWorker{
        .fixed_session_id = session_guid,
    };

    defer closeTerminalWorker(&terminal_worker);

    while (terminal_worker.running) {
        try terminalWorkerPollOnce(&terminal_worker, listen_fd);
        stopTerminalWorkerIfComplete(&terminal_worker);
    }
}

pub fn connectTerminalWorkerHandle(allocator: std.mem.Allocator, guid: []const u8) !c.fd_t {
    const canonical = try guid_ref.canonicalSessionGuid(allocator, guid);
    defer allocator.free(canonical);

    const control = lookupTerminalWorker(canonical) orelse return error.SessionNotFound;
    return connectTerminalWorkerHandleSocket(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forgetTerminalWorker(canonical);
            return error.SessionNotFound;
        },
        else => return err,
    };
}

pub fn connectTerminalWorker(
    allocator: std.mem.Allocator,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
    guid: []const u8,
) !c.fd_t {
    const canonical = try guid_ref.canonicalSessionGuid(allocator, guid);
    defer allocator.free(canonical);

    const control = lookupTerminalWorker(canonical) orelse return error.SessionNotFound;
    return connectTerminalWorkerControl(control, daemon_dispatcher) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forgetTerminalWorker(canonical);
            return error.SessionNotFound;
        },
        else => return err,
    };
}

pub fn connectStartedTerminalWorkerHandle(control: *TerminalWorkerHandle) !c.fd_t {
    return connectStartedTerminalWorker(control, null);
}

pub fn connectStartedTerminalWorker(
    control: *TerminalWorkerHandle,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !c.fd_t {
    return connectTerminalWorkerControl(control, daemon_dispatcher) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forgetTerminalWorker(control.guid);
            return error.SessionNotFound;
        },
        else => return err,
    };
}

pub fn destroyInDaemonTerminalWorker(control: *TerminalWorkerHandle, daemon_dispatcher: *dispatcher.Dispatcher) void {
    switch (control.kind) {
        .in_daemon => destroyRegisteredTerminalWorker(control, daemon_dispatcher),
        .process => {},
    }
}

fn connectTerminalWorkerHandleSocket(control: *const TerminalWorkerHandle) !c.fd_t {
    return switch (control.kind) {
        .process => |process| socket_transport.connectSocket(process.socket_path),
        .in_daemon => error.MissingDispatcher,
    };
}

fn connectTerminalWorkerControl(
    control: *TerminalWorkerHandle,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !c.fd_t {
    return switch (control.kind) {
        .process => connectTerminalWorkerHandleSocket(control),
        .in_daemon => |worker| worker.connect(daemon_dispatcher orelse return error.MissingDispatcher),
    };
}

pub fn requestTerminalWorkerCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    const fd = try connectTerminalWorkerHandle(allocator, guid);
    defer _ = c.close(fd);
    try protocol.sendTerminalEmulatorPayloadFrame(allocator, fd, .{ .session_hangup_request = .{} });
}

pub fn connectSingleLiveTerminalWorker(allocator: std.mem.Allocator) !c.fd_t {
    var found_guid: ?[]u8 = null;
    for (terminal_worker_handles.items) |control| {
        if (found_guid != null) {
            return error.AmbiguousSession;
        }
        found_guid = try allocator.dupe(u8, control.guid);
    }
    defer if (found_guid) |guid| allocator.free(guid);
    return connectTerminalWorkerHandle(allocator, found_guid orelse return error.SessionNotFound);
}

pub fn registerTerminalWorker(control: *TerminalWorkerHandle) !void {
    for (terminal_worker_handles.items) |existing| {
        if (std.mem.eql(u8, existing.guid, control.guid)) return error.SessionExists;
    }
    try terminal_worker_handles.append(app_allocator.allocator(), control);
}

pub fn unregisterTerminalWorker(control: *TerminalWorkerHandle) void {
    for (terminal_worker_handles.items, 0..) |existing, index| {
        if (existing == control) {
            _ = terminal_worker_handles.orderedRemove(index);
            return;
        }
    }
}

pub fn forgetTerminalWorker(guid: []const u8) void {
    for (terminal_worker_handles.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.guid, guid)) {
            const process = switch (control.kind) {
                .process => |process_value| process_value,
                .in_daemon => return,
            };
            _ = terminal_worker_handles.orderedRemove(index);
            _ = remote_process.reapPid(process.pid);
            const allocator = control.allocator;
            control.deinit(null);
            allocator.destroy(control);
            return;
        }
    }
}

pub fn activeTerminalWorkerHandleCount() usize {
    pruneExitedTerminalWorkers();
    return terminal_worker_handles.items.len;
}

fn lookupTerminalWorker(guid: []const u8) ?*TerminalWorkerHandle {
    for (terminal_worker_handles.items) |control| {
        if (std.mem.eql(u8, control.guid, guid)) return control;
    }
    return null;
}

fn pruneExitedTerminalWorkers() void {
    var index: usize = 0;
    while (index < terminal_worker_handles.items.len) {
        const control = terminal_worker_handles.items[index];
        if (terminalWorkerIsExited(control)) {
            _ = terminal_worker_handles.orderedRemove(index);
            const allocator = control.allocator;
            control.deinit(null);
            allocator.destroy(control);
            continue;
        }
        index += 1;
    }
}

fn terminalWorkerIsExited(control: *const TerminalWorkerHandle) bool {
    return switch (control.kind) {
        .process => |process| remote_process.reapPid(process.pid),
        // In-daemon workers own dispatcher watches. Their dispatcher callback
        // destroys them when the worker completes; pruning here has no
        // dispatcher to cancel those watches safely.
        .in_daemon => false,
    };
}

fn destroyRegisteredTerminalWorker(control: *TerminalWorkerHandle, daemon_dispatcher: *dispatcher.Dispatcher) void {
    unregisterTerminalWorker(control);
    const allocator = control.allocator;
    control.deinit(daemon_dispatcher);
    allocator.destroy(control);
}

fn terminalWorkerPollOnce(terminal_worker: *TerminalWorker, listen_fd: c.fd_t) !void {
    // PROCESS_EVENT_LOOP: terminal worker process. It directly polls
    // its PTY, client connection, and control fds; it is not a daemon helper
    // constructing a private Dispatcher.
    const now_ms = terminalWorkerMonotonicMs(terminal_worker);
    const now_unix_ms = nowUnixMs();
    clearExpiredDebugUnresponsiveAttachedClients(terminal_worker, now_ms);
    if (reapPtyHangupSessionIfExited(terminal_worker)) return;
    if (reapPtyEofSessionIfExited(terminal_worker, now_ms, now_unix_ms)) return;
    if (endReapedSessions(terminal_worker, now_unix_ms)) return;

    var pollfds: [4]posix.pollfd = undefined;
    var kinds: [4]PollKind = undefined;
    var count: usize = 0;

    pollfds[count] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
    kinds[count] = .listen;
    count += 1;

    if (terminal_worker.session.alive and terminal_worker.session.process.hasOpenPty()) {
        const session = &terminal_worker.session;
        var events: i16 = posix.POLL.IN;
        if (sessionHasPendingPtyInput(session)) events |= posix.POLL.OUT;
        pollfds[count] = .{ .fd = session.process.pty_fd, .events = events, .revents = 0 };
        kinds[count] = .session;
        count += 1;
    }

    if (terminal_worker.attached_client.active) {
        const attached_client = &terminal_worker.attached_client;
        const debug_unresponsive = attached_client.debug_unresponsive_until_ms > now_ms;
        var events: i16 = if (attached_client.close_after_flush or debug_unresponsive) 0 else posix.POLL.IN;
        if (!debug_unresponsive and attached_client.queuedBytes() > 0) events |= posix.POLL.OUT;
        pollfds[count] = .{ .fd = attached_client.fd, .events = events, .revents = 0 };
        kinds[count] = .attached_client;
        count += 1;
    }

    if (terminal_worker.pending_client.active) {
        const pending_client = &terminal_worker.pending_client;
        pollfds[count] = .{ .fd = pending_client.fd, .events = posix.POLL.IN, .revents = 0 };
        kinds[count] = .pending_client;
        count += 1;
    }

    _ = try posix.poll(pollfds[0..count], terminalWorkerPollTimeoutMs(terminal_worker, now_ms, now_unix_ms));
    const after_poll_ms = terminalWorkerMonotonicMs(terminal_worker);
    clearExpiredDebugUnresponsiveAttachedClients(terminal_worker, after_poll_ms);
    flushExpiredSynchronizedOutputSessions(terminal_worker, after_poll_ms);
    if (reapPtyHangupSessionIfExited(terminal_worker)) return;
    if (reapPtyEofSessionIfExited(terminal_worker, after_poll_ms, nowUnixMs())) return;
    if (endReapedSessions(terminal_worker, nowUnixMs())) return;

    for (pollfds[0..count], kinds[0..count]) |pollfd, kind| {
        if (pollfd.revents == 0) continue;
        switch (kind) {
            .listen => handleWorkerHandoffEvent(terminal_worker, listen_fd),
            .session => handleSessionPtyEvents(terminal_worker, pollfd.revents),
            .attached_client => handleAttachedClientEvents(terminal_worker, pollfd.revents),
            .pending_client => handlePendingWorkerClientEvents(terminal_worker, pollfd.revents),
        }
    }
}

fn handleDispatcherTerminalWorkerEvent(
    ctx: *anyopaque,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    event: dispatcher.Event,
) !void {
    const worker: *DispatcherTerminalWorker = @ptrCast(@alignCast(ctx));
    worker.runMaintenance();
    if (!worker.terminal_worker.running) {
        destroyRegisteredTerminalWorker(worker.control, daemon_dispatcher);
        return;
    }

    switch (event) {
        .fd => |fd_event| {
            const fd_id = switch (id) {
                .fd => |watch_id| watch_id,
                .timer => return error.UnexpectedWorkerTimerId,
            };
            if (worker.session_watch.matches(fd_id)) {
                handleSessionPtyEvents(&worker.terminal_worker, pollReventsFromDispatcherEvent(fd_event));
            } else if (worker.attached_watch.matches(fd_id)) {
                handleAttachedClientEvents(&worker.terminal_worker, pollReventsFromDispatcherEvent(fd_event));
            } else if (worker.pending_watch.matches(fd_id)) {
                handlePendingWorkerClientEvents(&worker.terminal_worker, pollReventsFromDispatcherEvent(fd_event));
            }
        },
        .timer => {
            if (worker.timer_watch_id) |timer_id| {
                switch (id) {
                    .timer => |fired| {
                        if (timer_id.index == fired.index and timer_id.generation == fired.generation) {
                            worker.timer_watch_id = null;
                        }
                    },
                    .fd => return error.UnexpectedWorkerFdId,
                }
            }
        },
    }

    worker.runMaintenance();
    if (!worker.terminal_worker.running) {
        destroyRegisteredTerminalWorker(worker.control, daemon_dispatcher);
        return;
    }
    try worker.updateWatches(daemon_dispatcher);
}

fn pollReventsFromDispatcherEvent(event: dispatcher.FdEvent) i16 {
    var revents: i16 = 0;
    if (event.readable) revents |= posix.POLL.IN;
    if (event.writable) revents |= posix.POLL.OUT;
    if (event.hangup) revents |= posix.POLL.HUP;
    if (event.error_event) revents |= posix.POLL.ERR;
    if (event.invalid) revents |= posix.POLL.NVAL;
    return revents;
}

fn runTerminalWorkerMaintenance(terminal_worker: *TerminalWorker) void {
    const now_ms = terminalWorkerMonotonicMs(terminal_worker);
    const now_unix_ms = nowUnixMs();
    clearExpiredDebugUnresponsiveAttachedClients(terminal_worker, now_ms);
    flushExpiredSynchronizedOutputSessions(terminal_worker, now_ms);
    if (!reapPtyHangupSessionIfExited(terminal_worker) and
        !reapPtyEofSessionIfExited(terminal_worker, now_ms, now_unix_ms))
    {
        _ = endReapedSessions(terminal_worker, now_unix_ms);
    }
    stopTerminalWorkerIfComplete(terminal_worker);
}

fn terminalWorkerMonotonicMs(terminal_worker: *TerminalWorker) i64 {
    if (terminal_worker.monotonic_clock == null) {
        terminal_worker.monotonic_clock = NonSuspendingTimer.start() catch return std.time.milliTimestamp();
    }
    return if (terminal_worker.monotonic_clock) |*timer|
        @intCast(timer.read() / std.time.ns_per_ms)
    else
        std.time.milliTimestamp();
}

fn clearExpiredDebugUnresponsiveAttachedClients(terminal_worker: *TerminalWorker, now_ms: i64) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    if (attached_client.debug_unresponsive_until_ms != 0 and attached_client.debug_unresponsive_until_ms <= now_ms) {
        attached_client.debug_unresponsive_until_ms = 0;
    }
}

fn terminalWorkerPollTimeoutMs(terminal_worker: *const TerminalWorker, now_ms: i64, now_unix_ms: u64) i32 {
    var timeout_ms: ?i64 = null;
    const attached_client = &terminal_worker.attached_client;
    if (attached_client.active and attached_client.debug_unresponsive_until_ms > now_ms) {
        const remaining_ms = attached_client.debug_unresponsive_until_ms - now_ms;
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    const session = &terminal_worker.session;
    if (session.alive and session.synchronized_output_since_ms != 0) {
        const elapsed_ms = now_ms - session.synchronized_output_since_ms;
        const remaining_ms = synchronized_output_max_hold_ms - elapsed_ms;
        const clamped_remaining_ms = @max(remaining_ms, 0);
        if (timeout_ms == null or clamped_remaining_ms < timeout_ms.?) timeout_ms = clamped_remaining_ms;
    }
    if (session.alive and session.process.pty_closed_for_hangup) {
        if (timeout_ms == null or pty_hangup_reap_poll_ms < timeout_ms.?) timeout_ms = pty_hangup_reap_poll_ms;
    }
    if (session.alive and session.pty_eof_wait_started_ms != 0) {
        const elapsed_ms = now_ms - session.pty_eof_wait_started_ms;
        const remaining_grace_ms = @max(pty_eof_exit_status_grace_ms - elapsed_ms, 0);
        const remaining_ms = @min(pty_eof_exit_reap_poll_ms, remaining_grace_ms);
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    if (sessionReapEnabled(session)) {
        const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
        const remaining_ms: i64 = if (deadline_ms <= now_unix_ms)
            0
        else
            @intCast(@min(deadline_ms - now_unix_ms, @as(u64, @intCast(std.math.maxInt(i64)))));
        if (timeout_ms == null or remaining_ms < timeout_ms.?) timeout_ms = remaining_ms;
    }
    const ms = timeout_ms orelse return -1;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

fn endReapedSessions(terminal_worker: *TerminalWorker, now_unix_ms: u64) bool {
    const session = &terminal_worker.session;
    if (!sessionReapEnabled(session)) return false;
    const deadline_ms = session.disconnected_at_unix_ms +| session.reap_ms;
    if (now_unix_ms < deadline_ms) return false;
    endSession(terminal_worker, 3, .{ .ended_at_unix_ms = now_unix_ms });
    return true;
}

fn sessionReapEnabled(session: *const Session) bool {
    return session.alive and
        !session.attached and
        session.disconnected_at_unix_ms != 0 and
        session.reap_ms != 0;
}

test "remote terminal process poll timeout includes reap deadline" {
    var terminal_worker = TerminalWorker{};
    terminal_worker.session = .{
        .alive = true,
        .attached = false,
        .disconnected_at_unix_ms = 1_000,
        .reap_ms = 5_000,
    };

    try std.testing.expectEqual(@as(i32, 5_000), terminalWorkerPollTimeoutMs(&terminal_worker, 0, 1_000));
    try std.testing.expectEqual(@as(i32, 1), terminalWorkerPollTimeoutMs(&terminal_worker, 0, 5_999));
    try std.testing.expectEqual(@as(i32, 0), terminalWorkerPollTimeoutMs(&terminal_worker, 0, 6_000));

    terminal_worker.session.attached = true;
    try std.testing.expectEqual(@as(i32, -1), terminalWorkerPollTimeoutMs(&terminal_worker, 0, 6_000));
}

test "remote terminal process poll timeout wakes to reap pty hangup" {
    var terminal_worker = TerminalWorker{};
    terminal_worker.session = .{
        .alive = true,
        .process = .{ .pty_closed_for_hangup = true },
    };

    try std.testing.expectEqual(@as(i32, pty_hangup_reap_poll_ms), terminalWorkerPollTimeoutMs(&terminal_worker, 0, 0));
}

test "remote terminal process poll timeout wakes while pty eof awaits exit status" {
    var terminal_worker = TerminalWorker{};
    terminal_worker.session = .{
        .alive = true,
        .pty_eof_wait_started_ms = 10,
    };

    try std.testing.expectEqual(@as(i32, pty_eof_exit_reap_poll_ms), terminalWorkerPollTimeoutMs(&terminal_worker, 10, 0));
    try std.testing.expectEqual(@as(i32, 1), terminalWorkerPollTimeoutMs(&terminal_worker, 259, 0));
    try std.testing.expectEqual(@as(i32, 0), terminalWorkerPollTimeoutMs(&terminal_worker, 260, 0));
}

fn flushExpiredSynchronizedOutputSessions(terminal_worker: *TerminalWorker, now_ms: i64) void {
    const session = &terminal_worker.session;
    if (!session.alive or session.synchronized_output_since_ms == 0) return;
    if (now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms) return;
    broadcastSessionPatch(terminal_worker);
    if (session.alive) {
        session.clearPendingPlainOutput();
        session.synchronized_output_since_ms = now_ms;
    }
}

fn handleAttachedClientEvents(terminal_worker: *TerminalWorker, revents: i16) void {
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        disconnectAttachedClient(terminal_worker);
        return;
    }
    if ((revents & posix.POLL.OUT) != 0) {
        flushAttachedClientOutput(terminal_worker);
    }
    if (!terminal_worker.attached_client.active) return;
    if (terminal_worker.attached_client.close_after_flush) return;
    if ((revents & posix.POLL.IN) != 0) {
        drainAttachedClientInput(terminal_worker);
    }
}

fn handleWorkerHandoffEvent(terminal_worker: *TerminalWorker, listen_fd: c.fd_t) void {
    const client_fd = c.accept(listen_fd, null, null);
    if (client_fd < 0) return;
    socket_transport.setCloseOnExec(client_fd) catch {
        _ = c.close(client_fd);
        return;
    };
    core_fds.setNonBlocking(client_fd) catch {
        _ = c.close(client_fd);
        return;
    };
    if (terminal_worker.pending_client.active) {
        _ = c.close(client_fd);
        return;
    }
    terminal_worker.pending_client.start(client_fd);
    drainPendingWorkerClient(terminal_worker);
}

fn handlePendingWorkerClientEvents(terminal_worker: *TerminalWorker, revents: i16) void {
    if (!terminal_worker.pending_client.active) return;
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        terminal_worker.pending_client.close();
        return;
    }
    if ((revents & posix.POLL.IN) != 0) drainPendingWorkerClient(terminal_worker);
}

fn drainPendingWorkerClient(terminal_worker: *TerminalWorker) void {
    const pending_client = &terminal_worker.pending_client;
    if (!pending_client.active) return;
    while (true) {
        var frame = switch (pending_client.reader.readReady(pending_client.fd) catch |err| {
            user_error.rolePrintLine("sessh-terminal-remote", "client error: {t}", .{err}) catch {};
            pending_client.close();
            return;
        }) {
            .blocked, .progress => return,
            .eof, .truncated_frame => {
                pending_client.close();
                return;
            },
            .frame => |frame_value| frame_value,
        };
        defer frame.deinit(app_allocator.allocator());
        switch (handlePendingWorkerClientFrame(terminal_worker, pending_client, &frame) catch |err| {
            user_error.rolePrintLine("sessh-terminal-remote", "client error: {t}", .{err}) catch {};
            pending_client.close();
            return;
        }) {
            .continue_reading => continue,
            .close => {
                pending_client.close();
                return;
            },
            .transferred_to_attached_client => return,
        }
    }
}

const PendingWorkerFrameResult = enum {
    continue_reading,
    close,
    transferred_to_attached_client,
};

fn handlePendingWorkerClientFrame(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    frame: *protocol.OwnedFrame,
) !PendingWorkerFrameResult {
    const fd = pending_client.fd;
    switch (frame.message_type) {
        .daemon_tunnel => {
            _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            return .continue_reading;
        },
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse {
                try sendError(terminal_worker, fd, "PROTOCOL_ERROR", "unexpected empty terminal stream item", "");
                return .close;
            };
            switch (item_payload) {
                .resize => return .continue_reading,
                .open => |open| return try handlePendingWorkerOpen(terminal_worker, pending_client, open),
                .debug_sever_connection_request => |request| {
                    try handleSessionClientDebugSeverConnectionRequest(terminal_worker, fd, request);
                    return .close;
                },
                .debug_unresponsive_connection_request => |request| {
                    try handleSessionClientDebugUnresponsiveConnectionRequest(terminal_worker, fd, request);
                    return .close;
                },
                .session_hangup_request => {
                    handleSessionHangupRequest(terminal_worker);
                    return .close;
                },
                else => {
                    try sendError(terminal_worker, fd, "PROTOCOL_ERROR", "unexpected first terminal stream item", "");
                    return .close;
                },
            }
        },
        else => {
            try sendError(terminal_worker, fd, "PROTOCOL_ERROR", "unexpected first action", "");
            return .close;
        },
    }
}

fn handlePendingWorkerOpen(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    open: pb.TerminalEmulatorItem.Open,
) !PendingWorkerFrameResult {
    if (open.create == null) {
        var request = try attachRequestFromOpen(open);
        defer request.deinit();
        if (request.session_guid.len == 0) return error.MissingSessionGuid;
        const session = findSession(terminal_worker, request.session_guid);
        const resolved_session = session orelse {
            try sendError(terminal_worker, pending_client.fd, "SESSION_NOT_FOUND", "session not found", "");
            return .close;
        };
        updateSessionSize(resolved_session, request.resize.rows, request.resize.cols);
        return try attachPendingWorkerClient(terminal_worker, pending_client, request.resize, request.capture_tty_transcript);
    }

    const open_payload = try protocol.encodePayload(app_allocator.allocator(), open);
    defer app_allocator.allocator().free(open_payload);
    var request = readSessionCreateRequest(open_payload) catch {
        try sendError(terminal_worker, pending_client.fd, "PROTOCOL_ERROR", "invalid terminal stream open payload", "");
        return .close;
    };
    defer request.deinit();
    _ = try createSession(
        terminal_worker,
        request.resize.rows,
        request.resize.cols,
        request.scrollback_row_count,
        request.environment,
        request.query_default_colors,
        request.session_guid,
        request.command_argv,
        request.shell_command,
        request.tty_settings,
        request.reap_ms,
    );
    return try attachPendingWorkerClient(terminal_worker, pending_client, request.resize, request.capture_tty_transcript);
}

fn attachPendingWorkerClient(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    resize: ResizePayload,
    capture_tty_transcript: bool,
) !PendingWorkerFrameResult {
    var fd = pending_client.takeFd();
    errdefer _ = c.close(fd);
    pending_client.close();
    try attachSession(terminal_worker, fd, resize, capture_tty_transcript);
    fd = -1;
    return .transferred_to_attached_client;
}

fn sendError(terminal_worker: *TerminalWorker, fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    _ = terminal_worker;
    try sendErrorFrame(fd, code, message, hint);
}

fn sendErrorFrame(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

fn flushAttachedClientOutput(terminal_worker: *TerminalWorker) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    if (attached_client.debug_unresponsive_until_ms != 0) {
        const now_ms = terminalWorkerMonotonicMs(terminal_worker);
        if (attached_client.debug_unresponsive_until_ms > now_ms) return;
        attached_client.debug_unresponsive_until_ms = 0;
    }

    while (attached_client.output_offset < attached_client.output.items.len) {
        const result = io.writeSomeNonBlocking(attached_client.fd, attached_client.output.items[attached_client.output_offset..]) catch {
            disconnectAttachedClient(terminal_worker);
            return;
        };
        switch (result) {
            .wrote => |n| {
                if (n == 0) break;
                attached_client.output_offset += n;
            },
            .would_block => return,
        }
    }

    if (attached_client.output_offset >= attached_client.output.items.len) {
        attached_client.output.clearRetainingCapacity();
        attached_client.output_offset = 0;
        if (attached_client.close_after_flush) {
            disconnectAttachedClient(terminal_worker);
        }
    }
}

fn handleSessionClientDebugSeverConnectionRequest(terminal_worker: *TerminalWorker, fd: c.fd_t, request: pb.TerminalEmulatorItem.SessionClientDebugSeverConnectionRequest) !void {
    _ = request;
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) {
        try sendError(terminal_worker, fd, "NO_ATTACHED_CLIENTS", "no attached clients", "");
        return;
    }
    disconnectAttachedClient(terminal_worker);
    try sendClientControlResponse(fd);
}

fn handleSessionClientDebugUnresponsiveConnectionRequest(terminal_worker: *TerminalWorker, fd: c.fd_t, request: pb.TerminalEmulatorItem.SessionClientDebugUnresponsiveConnectionRequest) !void {
    const seconds = if (request.seconds == 0)
        config.default_debug_unresponsive_seconds
    else
        request.seconds;
    const until_ms = terminalWorkerMonotonicMs(terminal_worker) + @as(i64, seconds) * std.time.ms_per_s;
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) {
        try sendError(terminal_worker, fd, "NO_ATTACHED_CLIENTS", "no attached clients", "");
        return;
    }
    attached_client.debug_unresponsive_until_ms = until_ms;
    try sendClientControlResponse(fd);
}

fn sendClientControlResponse(fd: c.fd_t) !void {
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), fd, .{ .session_client_control_response = .{} });
}

fn queueTtyTranscriptChunkForSession(
    terminal_worker: *TerminalWorker,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    if (attached_client.close_after_flush or !attached_client.capture_tty_transcript) return;
    terminal_worker_render.queueTtyTranscriptChunk(attached_client, stream, bytes) catch {
        disconnectAttachedClient(terminal_worker);
    };
}

fn updateSessionSize(session: *Session, rows: u16, cols: u16) void {
    const resized = session.rows != rows or session.cols != cols;
    session.rows = rows;
    session.cols = cols;
    if (session.terminal_model) |model| {
        model.resize(rows, cols) catch {};
        if (resized) terminal_worker_render.advanceScrollbackEpoch(session);
    }
    session.process.setPtySize(rows, cols);
}

fn createSession(
    terminal_worker: *TerminalWorker,
    rows: u16,
    cols: u16,
    scrollback_row_count: u32,
    session_environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    settings: ?tty_settings.Settings,
    reap_ms: u64,
) !*Session {
    if (terminal_worker.started_session or terminal_worker.session.alive or terminal_worker.attached_client.active) return error.TooManySessions;

    const terminal_model = try vt.SessionTerminal.createWithDefaultColors(
        app_allocator.allocator(),
        rows,
        cols,
        scrollback_row_count,
        query_default_colors,
    );
    errdefer terminal_model.destroy();

    if (!guid_ref.isValidSessionGuid(session_guid)) return error.InvalidSessionGuid;
    const session_guid_z = try app_allocator.allocator().dupeZ(u8, session_guid);
    defer app_allocator.allocator().free(session_guid_z);

    const process = try remote_process.Process.spawn(app_allocator.allocator(), .{
        .rows = rows,
        .cols = cols,
        .shell = session_environment.shell,
        .command_argv = command_argv,
        .shell_command = shell_command,
        .environment = session_environment.entries.items,
        .session_guid = session_guid_z,
        .add_sessh_path_to_env = true,
        .tty_settings = settings,
    });
    errdefer {
        var close_process = process;
        close_process.closePty();
    }

    const session = &terminal_worker.session;
    session.* = Session{
        .process = process,
        .terminal_model = terminal_model,
        .rows = rows,
        .cols = cols,
        .scrollback_row_count = scrollback_row_count,
        .reap_ms = reap_ms,
        .alive = true,
    };
    @memcpy(session.id[0..session_guid.len], session_guid);
    session.id_len = session_guid.len;
    terminal_worker.started_session = true;
    return session;
}

fn attachSession(
    terminal_worker: *TerminalWorker,
    client_fd: c.fd_t,
    resize: ResizePayload,
    capture_tty_transcript: bool,
) !void {
    const session = &terminal_worker.session;
    disconnectAttachedClient(terminal_worker);
    try core_fds.setNonBlocking(client_fd);

    const attached_client = &terminal_worker.attached_client;
    attached_client.* = .{
        .fd = client_fd,
        .rows = resize.rows,
        .cols = resize.cols,
        .attached_at_unix_ms = nowUnixMs(),
        .active = true,
        .reader = protocol.FrameReader.init(app_allocator.allocator()),
        .reader_initialized = true,
        .capture_tty_transcript = capture_tty_transcript,
    };
    attached_client.presentation.setViewportOffset(resize.viewport_offset);
    errdefer {
        if (attached_client.reader_initialized) attached_client.reader.deinit();
        attached_client.output.deinit(app_allocator.allocator());
        attached_client.* = AttachedClient{};
    }
    try terminal_worker_render.sendSessionAttached(attached_client, session);
    if (resize.repaint_request) |request| {
        try terminal_worker_render.sendSessionRepaintSnapshot(attached_client, session, request);
    } else {
        try terminal_worker_render.sendSessionSnapshot(attached_client, session);
    }
    refreshAttachedFlag(terminal_worker);
    flushAttachedClientOutput(terminal_worker);
}

fn updateSynchronizedOutputState(terminal_worker: *TerminalWorker, now_ms: i64) bool {
    const session = &terminal_worker.session;
    const model = session.terminal_model orelse {
        session.synchronized_output_since_ms = 0;
        return false;
    };
    if (!model.synchronizedOutputActive()) {
        session.synchronized_output_since_ms = 0;
        return false;
    }
    if (session.synchronized_output_since_ms == 0) {
        session.synchronized_output_since_ms = now_ms;
    }
    return true;
}

fn shouldDeferSynchronizedOutput(terminal_worker: *TerminalWorker, now_ms: i64) bool {
    const session = &terminal_worker.session;
    if (!updateSynchronizedOutputState(terminal_worker, now_ms)) return false;
    return now_ms - session.synchronized_output_since_ms < synchronized_output_max_hold_ms;
}

fn handleSessionPtyEvents(terminal_worker: *TerminalWorker, revents: i16) void {
    if ((revents & posix.POLL.OUT) != 0) {
        if (!flushSessionPtyInput(terminal_worker)) {
            endSessionFromPtyClose(terminal_worker);
            return;
        }
    }
    if ((revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        drainSessionOutput(terminal_worker);
    }
}

fn drainSessionOutput(terminal_worker: *TerminalWorker) void {
    const session = &terminal_worker.session;
    if (!session.alive) return;

    var context = SessionPtyDrainContext{
        .terminal_worker = terminal_worker,
    };
    const result = pty_process.drainMasterNonBlocking(
        session.process.pty_fd,
        &context,
        feedSessionPtyBytes,
        .{
            .max_reads = max_live_output_reads_per_batch,
            .max_bytes = preferred_live_output_batch_bytes,
        },
    ) catch {
        endSessionFromPtyClose(terminal_worker);
        return;
    };
    if (!session.alive) return;
    if (result.eof) {
        endSessionFromPtyEof(terminal_worker);
        return;
    }
    if (result.read_count == 0) return;

    const now_ms = terminalWorkerMonotonicMs(terminal_worker);
    if (shouldDeferSynchronizedOutput(terminal_worker, now_ms)) return;
    broadcastSessionPatch(terminal_worker);
    if (session.alive) {
        session.clearPendingPlainOutput();
        if (session.synchronized_output_since_ms != 0) {
            session.synchronized_output_since_ms = now_ms;
        }
    }
}

const SessionPtyDrainContext = struct {
    terminal_worker: *TerminalWorker,
};

fn feedSessionPtyBytes(context: *SessionPtyDrainContext, bytes: []const u8) !void {
    const terminal_worker = context.terminal_worker;
    if (!terminal_worker.session.alive) return error.SessionEndedDuringPtyDrain;

    try feedSessionOutputBytes(terminal_worker, bytes);

    const session = &terminal_worker.session;
    const model = session.terminal_model orelse return;
    const input_responses = model.pendingInputResponses();
    if (input_responses.len == 0) return;
    queueSessionPtyInput(terminal_worker, input_responses) catch return error.SessionPtyResponseWriteFailed;
    model.clearPendingInputResponses();
}

fn sessionHasPendingPtyInput(session: *const Session) bool {
    return session.pending_pty_input_offset < session.pending_pty_input.items.len;
}

fn sessionQueuedPtyInputBytes(session: *const Session) usize {
    return session.pending_pty_input.items.len - session.pending_pty_input_offset;
}

fn compactSessionPtyInput(session: *Session) void {
    if (session.pending_pty_input_offset == 0) return;
    const remaining = session.pending_pty_input.items[session.pending_pty_input_offset..];
    @memmove(session.pending_pty_input.items[0..remaining.len], remaining);
    session.pending_pty_input.items.len = remaining.len;
    session.pending_pty_input_offset = 0;
}

fn queueSessionPtyInput(terminal_worker: *TerminalWorker, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const session = &terminal_worker.session;
    if (!session.alive or !session.process.hasOpenPty()) return error.SessionPtyClosed;
    compactSessionPtyInput(session);
    if (bytes.len > max_session_pty_input_queue_bytes or
        session.pending_pty_input.items.len > max_session_pty_input_queue_bytes - bytes.len)
    {
        return error.SessionPtyInputQueueFull;
    }
    try session.pending_pty_input.appendSlice(app_allocator.allocator(), bytes);
    if (!flushSessionPtyInput(terminal_worker)) return error.SessionPtyInputWriteFailed;
}

fn flushSessionPtyInput(terminal_worker: *TerminalWorker) bool {
    const session = &terminal_worker.session;
    if (!session.alive or !session.process.hasOpenPty()) return true;
    while (sessionHasPendingPtyInput(session)) {
        const remaining = session.pending_pty_input.items[session.pending_pty_input_offset..];
        switch (session.process.writeSomeInput(remaining) catch return false) {
            .would_block => return true,
            .wrote => |n| {
                session.pending_pty_input_offset += n;
                if (session.pending_pty_input_offset == session.pending_pty_input.items.len) {
                    session.pending_pty_input.clearRetainingCapacity();
                    session.pending_pty_input_offset = 0;
                    return true;
                }
            },
        }
    }
    return true;
}

test "session PTY input queue flushes through nonblocking writes" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try core_fds.setNonBlocking(pipe[1]);

    var terminal_worker = TerminalWorker{
        .session = .{
            .process = .{ .pty_fd = pipe[1] },
            .alive = true,
        },
    };
    defer terminal_worker.session.deinit();

    try queueSessionPtyInput(&terminal_worker, "abc");
    try std.testing.expectEqual(@as(usize, 0), sessionQueuedPtyInputBytes(&terminal_worker.session));

    var out: [3]u8 = undefined;
    const n = try posix.read(pipe[0], &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", out[0..n]);
}

const RenderBarrierContext = struct {
    terminal_worker: *TerminalWorker,
};

fn handleSessionRenderBarrier(context: *anyopaque, model: *vt.SessionTerminal, barrier: vt.RenderBarrier) anyerror!void {
    _ = model;
    const barrier_context: *RenderBarrierContext = @ptrCast(@alignCast(context));
    try flushSessionRenderBarrier(barrier_context.terminal_worker, barrier);
}

fn flushSessionRenderBarrier(terminal_worker: *TerminalWorker, barrier: vt.RenderBarrier) !void {
    const session = &terminal_worker.session;
    if (!session.alive) return;
    const model = session.terminal_model orelse return;

    // A render barrier means the current VT state must be queued before the
    // following terminal transition is applied. Original-byte replay cannot
    // cross this boundary because the bytes before the barrier are already
    // inside the VT model and may not match the bytes currently buffered here.
    session.clearPendingPlainOutput();
    broadcastSessionPatch(terminal_worker);
    session.clearPendingPlainOutput();

    if (!session.alive) return;
    const scrollback_cursor = try model.scrollbackCursor();
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active or attached_client.close_after_flush) return;
    terminal_worker_render.queueRenderBarrierDraw(attached_client, session, barrier, scrollback_cursor) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    flushAttachedClientOutput(terminal_worker);
}

fn feedSessionOutputBytes(terminal_worker: *TerminalWorker, bytes: []const u8) !void {
    const session = &terminal_worker.session;
    queueTtyTranscriptChunkForSession(terminal_worker, .STREAM_INNER_OUT, bytes);
    if (session.terminal_model) |model| {
        const starts_at_boundary = model.isPlainTextParserBoundary();
        var barrier_context = RenderBarrierContext{
            .terminal_worker = terminal_worker,
        };
        const saw_render_barrier = try model.feedWithRenderBarriers(
            bytes,
            &barrier_context,
            handleSessionRenderBarrier,
        );
        if (!saw_render_barrier and hasActiveAttachedClient(terminal_worker)) {
            try session.appendPendingPlainOutput(bytes, starts_at_boundary);
        }
    }
}

fn drainAttachedClientInput(terminal_worker: *TerminalWorker) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    const session = &terminal_worker.session;
    if (!session.alive) {
        disconnectAttachedClient(terminal_worker);
        return;
    }

    var frame = switch (attached_client.reader.readReady(attached_client.fd) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    }) {
        .blocked, .progress => return,
        .eof, .truncated_frame => {
            disconnectAttachedClient(terminal_worker);
            return;
        },
        .frame => |frame_value| frame_value,
    };
    defer frame.deinit(app_allocator.allocator());

    switch (frame.message_type) {
        .client_remote => {
            var item = protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload) catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse {
                disconnectAttachedClient(terminal_worker);
                return;
            };
            switch (item_payload) {
                .input => |input| handleInputFrame(terminal_worker, input),
                .resize => |resize| handleResizeFrame(terminal_worker, resize),
                .repaint_request => |repaint| handleRepaintFrame(terminal_worker, repaint),
                .session_hangup_request => handleSessionHangupRequest(terminal_worker),
                else => {
                    attached_client.queueError("PROTOCOL_ERROR", "unexpected attached terminal stream item", "") catch {
                        disconnectAttachedClient(terminal_worker);
                        return;
                    };
                    closeAttachedClientAfterFlush(terminal_worker);
                },
            }
        },
        .daemon_tunnel => {
            _ = protocol.handleTransportControlFrame(frame.message_type, frame.payload, attached_client.fd) catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
        },
        else => {
            attached_client.queueError("PROTOCOL_ERROR", "unexpected attached message", "") catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
            closeAttachedClientAfterFlush(terminal_worker);
        },
    }
}

fn handleSessionHangupRequest(terminal_worker: *TerminalWorker) void {
    requestSessionPtyHangup(terminal_worker);
}

fn requestSessionPtyHangup(terminal_worker: *TerminalWorker) void {
    const session = &terminal_worker.session;
    if (!session.alive) {
        disconnectAttachedClient(terminal_worker);
        return;
    }

    disconnectAttachedClient(terminal_worker);
    if (session.process.hasOpenPty()) {
        session.process.closePtyForHangup();
        session.synchronized_output_since_ms = 0;
    }
    _ = reapPtyHangupSessionIfExited(terminal_worker);
}

fn reapPtyHangupSessionIfExited(terminal_worker: *TerminalWorker) bool {
    const session = &terminal_worker.session;
    if (!session.alive or !session.process.pty_closed_for_hangup) return false;
    if (session.process.pid <= 0) {
        endSessionFromPtyClose(terminal_worker);
        return true;
    }

    switch (remote_process.pollExit(session.process.pid, nowUnixMs())) {
        .exited => |exit_info| {
            endSession(terminal_worker, session.end_reason, exit_info);
            return true;
        },
        .interrupted, .running => return false,
        .failed => {
            endSessionFromPtyClose(terminal_worker);
            return true;
        },
    }
}

fn reapPtyEofSessionIfExited(terminal_worker: *TerminalWorker, now_ms: i64, now_unix_ms: u64) bool {
    const session = &terminal_worker.session;
    if (!session.alive or session.pty_eof_wait_started_ms == 0) return false;
    if (session.process.pid <= 0) {
        endSessionFromPtyClose(terminal_worker);
        return true;
    }

    switch (remote_process.pollExit(session.process.pid, now_unix_ms)) {
        .exited => |exit_info| {
            endSession(terminal_worker, session.end_reason, exit_info);
            return true;
        },
        .failed => {
            endSessionFromPtyClose(terminal_worker);
            return true;
        },
        .interrupted, .running => {
            if (now_ms - session.pty_eof_wait_started_ms >= pty_eof_exit_status_grace_ms) {
                endSessionFromPtyClose(terminal_worker);
                return true;
            }
            return false;
        },
    }
}

fn handleInputFrame(terminal_worker: *TerminalWorker, input: pb.TerminalEmulatorItem.Input) void {
    const attached_client = &terminal_worker.attached_client;
    const session = &terminal_worker.session;
    if (input.data.len == 0) return;

    if (input.input_seq != 0) {
        attached_client.queueTerminalEmulatorFrame(.{ .input_ack = .{
            .input_seq = input.input_seq,
        } }) catch {
            disconnectAttachedClient(terminal_worker);
            return;
        };
        flushAttachedClientOutput(terminal_worker);
    }

    if (session.rows != attached_client.rows or session.cols != attached_client.cols) {
        updateSessionSize(session, attached_client.rows, attached_client.cols);
    }

    var translated = std.ArrayList(u8).empty;
    defer translated.deinit(app_allocator.allocator());
    input_translation.translate(
        app_allocator.allocator(),
        &attached_client.input_pending,
        .{
            .origin = attached_client.origin,
            .terminal_modes = attached_client.presentation.terminal_modes,
            .terminal_modes_initialized = attached_client.presentation.terminal_modes_initialized,
        },
        .{
            .rows = session.rows,
            .cols = session.cols,
        },
        input.data,
        &translated,
    ) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    if (translated.items.len == 0) return;

    terminal_worker_render.queueTtyTranscriptChunk(attached_client, .STREAM_INNER_IN, translated.items) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    flushAttachedClientOutput(terminal_worker);

    queueSessionPtyInput(terminal_worker, translated.items) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
}

fn handleResizeFrame(terminal_worker: *TerminalWorker, message: pb.TerminalEmulatorItem.Resize) void {
    const attached_client = &terminal_worker.attached_client;
    const session = &terminal_worker.session;
    const resize = resizePayloadFromMessage(message) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    const reset_for_screen_repaint = resize.repaint_request != null and
        resize.repaint_request.?.scrollback_cursor == null;
    attached_client.rows = resize.rows;
    attached_client.cols = resize.cols;
    if (reset_for_screen_repaint) attached_client.presentation.resetForScreenRepaint();
    attached_client.presentation.setViewportOffset(resize.viewport_offset);
    updateSessionSize(session, resize.rows, resize.cols);
    if (resize.repaint_request) |request| {
        handleRepaintRequest(terminal_worker, request);
    }
}

fn handleRepaintFrame(terminal_worker: *TerminalWorker, message: pb.TerminalEmulatorItem.RepaintRequest) void {
    const request = repaintRequestFromMessage(message) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    handleRepaintRequest(terminal_worker, request);
}

fn handleRepaintRequest(terminal_worker: *TerminalWorker, request: RepaintRequest) void {
    const attached_client = &terminal_worker.attached_client;
    const session = &terminal_worker.session;

    const model = session.terminal_model orelse return;
    const clear_for_replace = request.scrollback_cursor != null and
        request.scrollback_cursor.?.per_epoch_cursor == 0;
    const screen_rows = terminal_worker_render.queueRepaintSnapshot(attached_client, session, request, clear_for_replace) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    model.markRendered(screen_rows);
    flushAttachedClientOutput(terminal_worker);
}

fn broadcastSessionPatch(terminal_worker: *TerminalWorker) void {
    if (!hasActiveAttachedClient(terminal_worker)) return;

    const session = &terminal_worker.session;
    const model = session.terminal_model orelse return;
    var scrollback = model.scrollbackDelta(app_allocator.allocator()) catch {
        endSessionFromPtyClose(terminal_worker);
        return;
    };
    defer scrollback.deinit(app_allocator.allocator());

    var screen = model.renderedScreen(app_allocator.allocator()) catch {
        endSessionFromPtyClose(terminal_worker);
        return;
    };
    defer screen.deinit(app_allocator.allocator());

    if (screen.dirty_state == .none and
        scrollback.rows.len == 0 and
        !screen.title_dirty and
        !screen.default_colors_dirty and
        !screen.retained_scrollback_clear_dirty and
        screen.display_clear == null)
    {
        return;
    }

    const materialize_screen_after_scrollback = scrollback.rows.len > 0 and
        model.lastRenderedRowCount() == 0 and
        screen.display_clear != null;
    const should_send_screen_draw = screen.dirty_state != .none or
        screen.title_dirty or
        screen.default_colors_dirty or
        screen.retained_scrollback_clear_dirty or
        screen.display_clear != null or
        materialize_screen_after_scrollback;
    var primary_screen: ?vt.RenderedScreen = null;
    defer if (primary_screen) |*primary| primary.deinit(app_allocator.allocator());
    if ((should_send_screen_draw or scrollback.rows.len > 0) and screen.active_screen == 1) {
        primary_screen = model.renderedPrimaryScreen(app_allocator.allocator()) catch {
            endSessionFromPtyClose(terminal_worker);
            return;
        };
    }
    if (screen.retained_scrollback_clear_dirty) terminal_worker_render.advanceScrollbackEpochForClear(session);
    var delivered = false;
    const attached_client = &terminal_worker.attached_client;
    if (attached_client.active and !attached_client.close_after_flush) {
        if (screen.retained_scrollback_clear_dirty) {
            terminal_worker_render.queueRetainedScrollbackClearDraw(attached_client, session) catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
        }
        if (scrollback.rows.len > 0) {
            terminal_worker_render.queueScrollbackRowsAndScreenDraw(
                attached_client,
                session,
                scrollback.rows,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
        } else if (should_send_screen_draw) {
            _ = terminal_worker_render.queueScreenDraw(
                attached_client,
                session,
                &screen,
                if (primary_screen) |*primary| primary else null,
                materialize_screen_after_scrollback,
                materialize_screen_after_scrollback,
                scrollback.absolute_count,
            ) catch {
                disconnectAttachedClient(terminal_worker);
                return;
            };
        }
        flushAttachedClientOutput(terminal_worker);
        if (attached_client.active) delivered = true;
    }
    if (delivered) {
        if (scrollback.rows.len > 0) model.markScrollbackReported();
        if (scrollback.rows.len > 0 or
            screen.dirty_state != .none or
            screen.title_dirty or
            screen.default_colors_dirty or
            screen.retained_scrollback_clear_dirty or
            screen.display_clear != null or
            materialize_screen_after_scrollback)
        {
            model.markRendered(screen.rows.len);
        }
    }
}

fn hasActiveAttachedClient(terminal_worker: *const TerminalWorker) bool {
    const attached_client = &terminal_worker.attached_client;
    return attached_client.active and !attached_client.close_after_flush;
}

fn sendSessionEndedToAttachedClient(terminal_worker: *TerminalWorker, reason: u8, exit_info: ExitInfo) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    terminal_worker_render.sendSessionEnded(attached_client, reason, exit_info) catch {
        disconnectAttachedClient(terminal_worker);
        return;
    };
    closeAttachedClientAfterFlush(terminal_worker);
}

fn disconnectAttachedClient(terminal_worker: *TerminalWorker) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;

    _ = c.close(attached_client.fd);
    if (attached_client.reader_initialized) attached_client.reader.deinit();
    attached_client.output.deinit(app_allocator.allocator());
    attached_client.* = AttachedClient{};
    refreshAttachedFlag(terminal_worker);
}

fn closeAttachedClientAfterFlush(terminal_worker: *TerminalWorker) void {
    const attached_client = &terminal_worker.attached_client;
    if (!attached_client.active) return;
    attached_client.close_after_flush = true;
    flushAttachedClientOutput(terminal_worker);
}

fn refreshAttachedFlag(terminal_worker: *TerminalWorker) void {
    const session = &terminal_worker.session;
    if (!session.alive) {
        session.attached = false;
        return;
    }

    const now_attached = hasActiveAttachedClient(terminal_worker);
    const was_attached = session.attached;
    session.attached = now_attached;
    if (now_attached) {
        session.disconnected_at_unix_ms = 0;
    } else if (was_attached or session.disconnected_at_unix_ms == 0) {
        session.disconnected_at_unix_ms = nowUnixMs();
    }
}

fn endSession(terminal_worker: *TerminalWorker, reason: u8, exit_info: ExitInfo) void {
    const session = &terminal_worker.session;
    if (!session.alive) return;

    broadcastSessionPatch(terminal_worker);
    session.clearPendingPlainOutput();
    session.synchronized_output_since_ms = 0;

    sendSessionEndedToAttachedClient(terminal_worker, reason, exit_info);
    session.process.closePty();
    if (session.terminal_model) |model| {
        model.destroy();
        session.terminal_model = null;
    }
    session.deinit();
    session.alive = false;
    session.attached = false;
}

fn stopTerminalWorkerIfComplete(terminal_worker: *TerminalWorker) void {
    if (terminal_worker.fixed_session_id == null or !terminal_worker.started_session) return;
    if (terminal_worker.session.alive) return;
    if (terminal_worker.attached_client.active) return;
    terminal_worker.running = false;
}

fn closeTerminalWorker(terminal_worker: *TerminalWorker) void {
    terminal_worker.pending_client.close();
    disconnectAttachedClient(terminal_worker);
    endSession(terminal_worker, 2, .{});
}

fn findSession(terminal_worker: *TerminalWorker, id: []const u8) ?*Session {
    const session = &terminal_worker.session;
    if (session.alive and
        !session.process.pty_closed_for_hangup and
        session.pty_eof_wait_started_ms == 0 and
        std.mem.eql(u8, session.idSlice(), id))
    {
        return session;
    }
    return null;
}

fn endSessionFromPtyClose(terminal_worker: *TerminalWorker) void {
    endSession(terminal_worker, terminal_worker.session.end_reason, .{ .ended_at_unix_ms = nowUnixMs() });
}

fn endSessionFromPtyEof(terminal_worker: *TerminalWorker) void {
    // Only ask for child status after PTY EOF. Exit status is useful metadata,
    // but checking it before PTY EOF can race with final terminal output that
    // still needs to be drained from the master fd.
    const now_unix_ms = nowUnixMs();
    if (remote_process.waitForExitInfo(terminal_worker.session.process.pid, now_unix_ms)) |exit_info| {
        endSession(terminal_worker, terminal_worker.session.end_reason, exit_info);
        return;
    }

    const session = &terminal_worker.session;
    broadcastSessionPatch(terminal_worker);
    if (!session.alive) return;
    session.clearPendingPlainOutput();
    session.synchronized_output_since_ms = 0;
    session.process.closePty();
    session.pty_eof_wait_started_ms = terminalWorkerMonotonicMs(terminal_worker);
}

fn nowUnixMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    if (ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
