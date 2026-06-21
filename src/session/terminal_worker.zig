// Terminal worker lifecycle and event loop. A worker owns one remote PTY and
// headless VT model, accepts at most one visible client, and emits serialized
// screen/repaint state back through daemon-owned mux streams.
const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const core_blocking = @import("../core/blocking.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const input_translation = @import("input_translation.zig");
const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const pty_process = @import("../tty/pty_process.zig");
const protocol = @import("../protocol/mod.zig");
const user_error = @import("../core/user_error.zig");
const guid_ref = @import("../core/guid.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");
const foreground_frame_io = @import("../transport/foreground_frame_io.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const vt = @import("vt.zig");
const remote_process = @import("remote_process.zig");
const visible_client_router = @import("visible_client_router.zig");
const terminal_worker_state = @import("terminal_worker_state.zig");
const terminal_worker_render = @import("terminal_worker_render.zig");
const terminal_worker_protocol = @import("terminal_worker_protocol.zig");
const terminal_worker_lifecycle = @import("terminal_worker_lifecycle.zig");

const preferred_live_output_batch_bytes = 1024;
const max_live_output_reads_per_batch = 64;
const synchronized_output_max_hold_ms: i64 = 1000;
const pty_eof_exit_status_grace_ms: i64 = 250;
const terminal_worker_poll_timing = terminal_worker_lifecycle.PollTiming{
    .synchronized_output_max_hold_ms = synchronized_output_max_hold_ms,
    .pty_eof_exit_status_grace_ms = pty_eof_exit_status_grace_ms,
};

const pb = protocol.pb;

const Session = terminal_worker_state.Session;
const VisibleClient = visible_client_router.VisibleClient;
const PendingWorkerClient = visible_client_router.PendingWorkerClient;
const WorkerFdWatch = visible_client_router.WorkerFdWatch;
const WindowSize = terminal.WindowSize;

const TerminalWorker = struct {
    session: Session = .{},
    visible_client: VisibleClient = .{},
    pending_client: PendingWorkerClient = .{},
    running: bool = true,
    monotonic_clock: ?NonSuspendingTimer = null,
    fixed_session_id: ?[]const u8 = null,
    started_session: bool = false,
};

pub const TerminalWorkerProcessHandle = struct {
    socket_path: []u8,
    pid: c.pid_t = 0,

    fn deinit(self: *TerminalWorkerProcessHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.socket_path);
        self.* = undefined;
    }
};

pub const TerminalWorkerHandleKind = union(enum) {
    process: TerminalWorkerProcessHandle,
    in_daemon: *DispatcherTerminalWorker,
};

pub const TerminalWorkerHandle = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    kind: TerminalWorkerHandleKind,

    pub fn initOwnedProcess(allocator: std.mem.Allocator, guid: []u8, socket_path: []u8) TerminalWorkerHandle {
        return .{
            .allocator = allocator,
            .guid = guid,
            .kind = .{ .process = .{ .socket_path = socket_path } },
        };
    }

    pub fn initInDaemon(allocator: std.mem.Allocator, guid: []u8, worker: *DispatcherTerminalWorker) TerminalWorkerHandle {
        return .{
            .allocator = allocator,
            .guid = guid,
            .kind = .{ .in_daemon = worker },
        };
    }

    pub fn deinit(self: *TerminalWorkerHandle, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        self.allocator.free(self.guid);
        switch (self.kind) {
            .process => |*process| process.deinit(self.allocator),
            .in_daemon => |worker| {
                worker.deinit(daemon_dispatcher);
                self.allocator.destroy(worker);
            },
        }
        self.* = undefined;
    }

    pub fn setProcessPid(self: *TerminalWorkerHandle, pid: c.pid_t) void {
        switch (self.kind) {
            .process => |*process| process.pid = pid,
            .in_daemon => {},
        }
    }

    pub fn processSocketPath(self: *const TerminalWorkerHandle) ?[]const u8 {
        return switch (self.kind) {
            .process => |process| process.socket_path,
            .in_daemon => null,
        };
    }
};

const DispatcherTerminalWorker = struct {
    allocator: std.mem.Allocator,
    control: ?*TerminalWorkerHandle = null,
    terminal_worker: TerminalWorker,
    listen_watch: WorkerFdWatch = .{},
    session_watch: WorkerFdWatch = .{},
    visible_watch: WorkerFdWatch = .{},
    pending_watch: WorkerFdWatch = .{},
    timer_watch_id: ?dispatcher.TimerWatchId = null,

    fn deinit(self: *DispatcherTerminalWorker, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            self.listen_watch.cancel(d);
            self.session_watch.cancel(d);
            self.visible_watch.cancel(d);
            self.pending_watch.cancel(d);
            if (self.timer_watch_id) |id| d.cancel(.{ .timer = id });
        }
        self.timer_watch_id = null;
        closeTerminalWorker(&self.terminal_worker);
        self.* = undefined;
    }

    fn finish(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher) void {
        if (self.control) |control| {
            destroyRegisteredTerminalWorker(control, daemon_dispatcher);
        } else {
            daemon_dispatcher.stop();
        }
    }

    fn connect(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher) !c.fd_t {
        // Attach a daemon-side endpoint to a running worker using a socketpair.
        // The worker half becomes a pending visible client until the open frame
        // proves which client/session it belongs to.
        if (!self.terminal_worker.running) return error.SessionNotFound;
        if (self.terminal_worker.pending_client.active) return error.PendingWorkerClientBusy;

        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        var daemon_fd = core_fds.OwnedFd.init(fds[0]);
        defer daemon_fd.deinit();
        var worker_fd = core_fds.OwnedFd.init(fds[1]);
        defer worker_fd.deinit();

        try socket_transport.setCloseOnExec(daemon_fd.get());
        try socket_transport.setCloseOnExec(worker_fd.get());
        try core_fds.setNonBlocking(daemon_fd.get());
        try core_fds.setNonBlocking(worker_fd.get());

        self.terminal_worker.pending_client.start(worker_fd.take());
        try self.updateWatches(daemon_dispatcher);
        return daemon_fd.take();
    }

    /// Recompute all fd and timer interests for the worker after any state
    /// change. The worker owns three independent edges: PTY, visible client, and
    /// pending handoff client; backpressure on each edge is expressed by toggling
    /// writable/readable interest here rather than blocking in handlers.
    fn updateWatches(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher) !void {
        if (!self.terminal_worker.running) {
            self.finish(daemon_dispatcher);
            return;
        }

        const clock = terminalWorkerPollClock(&self.terminal_worker);
        const session = &self.terminal_worker.session;
        if (session.alive and session.process.hasOpenPty()) {
            try self.ensureWatch(.{
                .daemon_dispatcher = daemon_dispatcher,
                .watch = &self.session_watch,
                .fd = session.process.pty_fd,
                .events = .{
                    .readable = true,
                    .writable = session.hasPendingPtyInput(),
                },
            });
        } else {
            self.session_watch.cancel(daemon_dispatcher);
        }

        const visible_client = &self.terminal_worker.visible_client;
        if (visible_client.active) {
            const debug_unresponsive = visible_client.debug_unresponsive_until_ms > clock.monotonic_ms;
            try self.ensureWatch(.{
                .daemon_dispatcher = daemon_dispatcher,
                .watch = &self.visible_watch,
                .fd = visible_client.fd,
                .events = .{
                    .readable = !visible_client.close_after_flush and !debug_unresponsive,
                    .writable = !debug_unresponsive and visible_client.queuedBytes() > 0,
                },
            });
        } else {
            self.visible_watch.cancel(daemon_dispatcher);
        }

        const pending_client = &self.terminal_worker.pending_client;
        if (pending_client.active) {
            try self.ensureWatch(.{
                .daemon_dispatcher = daemon_dispatcher,
                .watch = &self.pending_watch,
                .fd = pending_client.fd,
                .events = pending_client.watchEvents(),
            });
        } else {
            self.pending_watch.cancel(daemon_dispatcher);
        }

        try self.updateTimer(daemon_dispatcher, clock);
    }

    const EnsureWatchOptions = struct {
        daemon_dispatcher: *dispatcher.Dispatcher,
        watch: *WorkerFdWatch,
        fd: c.fd_t,
        events: dispatcher.FdEvents,
    };

    fn ensureWatch(self: *DispatcherTerminalWorker, options: EnsureWatchOptions) !void {
        // Worker fds can change when clients reconnect. Reuse an existing watch
        // only while it still points at the same fd; otherwise cancel and
        // register a fresh dispatcher slot.
        const daemon_dispatcher = options.daemon_dispatcher;
        const watch = options.watch;
        const fd = options.fd;
        const events = options.events;
        if (watch.id != null and watch.fd != fd) {
            watch.cancel(daemon_dispatcher);
        }
        if (watch.id) |id| {
            try daemon_dispatcher.updateFdEvents(id, events);
        } else {
            watch.id = try daemon_dispatcher.watchFd(.{
                .fd = fd,
                .events = events,
                .handler = .{
                    .ctx = self,
                    .callback = handleDispatcherTerminalWorkerEvent,
                },
            });
            watch.fd = fd;
        }
    }

    fn updateTimer(
        self: *DispatcherTerminalWorker,
        daemon_dispatcher: *dispatcher.Dispatcher,
        clock: terminal_worker_lifecycle.PollClock,
    ) !void {
        if (self.timer_watch_id) |id| daemon_dispatcher.cancel(.{ .timer = id });
        self.timer_watch_id = null;
        const timeout_ms = terminalWorkerPollTimeoutMs(&self.terminal_worker, clock);
        if (timeout_ms < 0) return;
        self.timer_watch_id = try daemon_dispatcher.watchTimerAfter(@intCast(timeout_ms), .{
            .ctx = self,
            .callback = handleDispatcherTerminalWorkerEvent,
        });
    }

    fn runMaintenance(self: *DispatcherTerminalWorker) void {
        runTerminalWorkerMaintenance(&self.terminal_worker);
        const waiting_for_initial_process_client = self.listen_watch.id != null and !self.terminal_worker.started_session;
        if (!waiting_for_initial_process_client and
            !self.terminal_worker.started_session and
            !self.terminal_worker.pending_client.active and
            !self.terminal_worker.visible_client.active and
            !self.terminal_worker.session.alive)
        {
            self.terminal_worker.running = false;
        }
    }

    fn watchListenFd(self: *DispatcherTerminalWorker, daemon_dispatcher: *dispatcher.Dispatcher, listen_fd: c.fd_t) !void {
        try self.ensureWatch(.{
            .daemon_dispatcher = daemon_dispatcher,
            .watch = &self.listen_watch,
            .fd = listen_fd,
            .events = .{ .readable = true },
        });
    }
};

// PROCESS_GLOBAL_REGISTRY: the local daemon tracks process-isolated terminal
// workers here so shutdown and cleanup can see whether useful remote work still
// exists. The daemon is single-threaded; mutations happen from dispatcher-owned
// callbacks.
var terminal_worker_handles: std.ArrayList(*TerminalWorkerHandle) = .empty;
const ExitInfo = remote_process.ExitInfo;

const terminal_worker_requests = @import("terminal_worker_requests.zig");
const SessionEnvironment = terminal_worker_requests.SessionEnvironment;
const VisibleClientOpenRequest = terminal_worker_requests.VisibleClientOpenRequest;
const RepaintRequest = terminal_worker_requests.RepaintRequest;
const ResizePayload = terminal_worker_requests.ResizePayload;
const readSessionCreateRequest = terminal_worker_requests.readSessionCreateRequest;
const resizePayloadFromMessage = terminal_worker_requests.resizePayloadFromMessage;
const visibleClientOpenRequestFromOpen = terminal_worker_requests.visibleClientOpenRequestFromOpen;
const repaintRequestFromMessage = terminal_worker_requests.repaintRequestFromMessage;

pub fn startTerminalWorkerInDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    session_guid: []const u8,
) !*TerminalWorkerHandle {
    // Start a terminal worker hosted in the daemon process. The handle is the
    // daemon's registry entry; the worker state machine itself owns PTY IO and
    // visible-client handoff.
    const guid = try guid_ref.canonicalSessionGuid(allocator, session_guid);
    errdefer allocator.free(guid);

    const control = try allocator.create(TerminalWorkerHandle);
    errdefer allocator.destroy(control);
    const worker = try allocator.create(DispatcherTerminalWorker);
    errdefer allocator.destroy(worker);

    control.* = TerminalWorkerHandle.initInDaemon(allocator, guid, worker);
    errdefer control.deinit(daemon_dispatcher);

    worker.* = .{
        .allocator = allocator,
        .control = control,
        .terminal_worker = .{ .fixed_session_id = guid },
    };

    try registerTerminalWorker(control);
    return control;
}

pub fn runTerminalWorkerLoop(blocking: core_blocking.Blocking, session_guid: []const u8, listen_fd: c.fd_t) !void {
    var worker = DispatcherTerminalWorker{
        .allocator = app_allocator.allocator(),
        .terminal_worker = .{
            .fixed_session_id = session_guid,
        },
    };
    // process-isolated terminal worker. When isolation mode
    // puts the terminal worker outside sesshd, the process Dispatcher owns the
    // worker listen socket, PTY, and visible-client connection.
    const worker_dispatcher = dispatcher.get();
    defer worker.deinit(worker_dispatcher);

    try worker.watchListenFd(worker_dispatcher, listen_fd);
    try worker.updateWatches(worker_dispatcher);
    try blocking.runLoop();
}

fn connectTerminalWorkerHandle(allocator: std.mem.Allocator, guid: []const u8) !c.fd_t {
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
    try sendTerminalWorkerHangupForeground(allocator, fd);
}

fn sendTerminalWorkerHangupForeground(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    const payload = try protocol.encodeTerminalEmulatorItemPayload(allocator, .{ .payload = .{ .session_hangup_request = .{} } });
    defer allocator.free(payload);
    try foreground_frame_io.writeFrame(.{
        .allocator = allocator,
        .fd = fd,
        .message_type = .client_remote,
        .payload = payload,
    });
}

test "terminal worker cleanup sends hangup through foreground frame writer" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const fds = try protocol_test_helpers.socketPairForTest();
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    try sendTerminalWorkerHangupForeground(std.testing.allocator, fds[0]);
    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, fds[1]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_remote, frame.message_type);
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(std.testing.allocator, frame.payload);
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.TerminalEmulatorPayload{ .session_hangup_request = .{} }, item.payload.?);
}

pub fn connectSingleLiveTerminalWorker(allocator: std.mem.Allocator) !c.fd_t {
    var found_guid: ?[]const u8 = null;
    for (terminal_worker_handles.items) |control| {
        if (found_guid != null) {
            return error.AmbiguousSession;
        }
        found_guid = control.guid;
    }
    return connectTerminalWorkerHandle(allocator, found_guid orelse return error.SessionNotFound);
}

test "single live terminal worker ambiguity does not allocate a guid copy" {
    defer if (terminal_worker_handles.items.len == 0) {
        terminal_worker_handles.deinit(app_allocator.allocator());
        terminal_worker_handles = .empty;
    };

    var first = TerminalWorkerHandle.initOwnedProcess(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "s-11111111-1111-1111-1111-111111111111"),
        try std.testing.allocator.dupe(u8, "/tmp/sessh-unused-first.sock"),
    );
    try registerTerminalWorker(&first);
    defer {
        unregisterTerminalWorker(&first);
        first.deinit(null);
    }

    var second = TerminalWorkerHandle.initOwnedProcess(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "s-22222222-2222-2222-2222-222222222222"),
        try std.testing.allocator.dupe(u8, "/tmp/sessh-unused-second.sock"),
    );
    try registerTerminalWorker(&second);
    defer {
        unregisterTerminalWorker(&second);
        second.deinit(null);
    }

    try std.testing.expectError(error.AmbiguousSession, connectSingleLiveTerminalWorker(std.testing.allocator));
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

fn forgetTerminalWorker(guid: []const u8) void {
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

// Single dispatcher entry point for terminal-worker events. Each callback first
// runs maintenance to reap completed PTYs or expired timers, dispatches the
// actual fd/timer event, then recomputes watches because almost every branch can
// transfer ownership, close a client, or queue output.
fn handleDispatcherTerminalWorkerEvent(
    ctx: *anyopaque,
    handler_event: dispatcher.HandlerEvent,
) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    const worker: *DispatcherTerminalWorker = @ptrCast(@alignCast(ctx));
    worker.runMaintenance();
    if (!worker.terminal_worker.running) {
        worker.finish(daemon_dispatcher);
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
            } else if (worker.visible_watch.matches(fd_id)) {
                handleVisibleClientEvents(&worker.terminal_worker, pollReventsFromDispatcherEvent(fd_event));
            } else if (worker.pending_watch.matches(fd_id)) {
                handlePendingWorkerClientEvents(&worker.terminal_worker, pollReventsFromDispatcherEvent(fd_event));
            } else if (worker.listen_watch.matches(fd_id)) {
                if (fd_event.readable) handleWorkerHandoffEvent(&worker.terminal_worker, fd_event.fd);
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
        worker.finish(daemon_dispatcher);
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
    clearExpiredDebugUnresponsiveVisibleClients(terminal_worker, now_ms);
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

fn terminalWorkerPollClock(terminal_worker: *TerminalWorker) terminal_worker_lifecycle.PollClock {
    return .{
        .monotonic_ms = terminalWorkerMonotonicMs(terminal_worker),
        .unix_ms = nowUnixMs(),
    };
}

fn clearExpiredDebugUnresponsiveVisibleClients(terminal_worker: *TerminalWorker, now_ms: i64) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    if (visible_client.debug_unresponsive_until_ms != 0 and visible_client.debug_unresponsive_until_ms <= now_ms) {
        visible_client.debug_unresponsive_until_ms = 0;
    }
}

fn terminalWorkerPollTimeoutMs(terminal_worker: *const TerminalWorker, clock: terminal_worker_lifecycle.PollClock) i32 {
    return terminal_worker_lifecycle.pollTimeoutMs(.{
        .session = &terminal_worker.session,
        .visible_client = &terminal_worker.visible_client,
        .clock = clock,
        .timing = terminal_worker_poll_timing,
    });
}

fn endReapedSessions(terminal_worker: *TerminalWorker, now_unix_ms: u64) bool {
    const session = &terminal_worker.session;
    if (!terminal_worker_lifecycle.shouldReapDisconnected(session, now_unix_ms)) return false;
    endSession(terminal_worker, 3, .{ .ended_at_unix_ms = now_unix_ms });
    return true;
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

fn handleVisibleClientEvents(terminal_worker: *TerminalWorker, revents: i16) void {
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        disconnectVisibleClient(terminal_worker);
        return;
    }
    if ((revents & posix.POLL.OUT) != 0) {
        flushVisibleClientOutput(terminal_worker);
    }
    if (!terminal_worker.visible_client.active) return;
    if (terminal_worker.visible_client.close_after_flush) return;
    if ((revents & posix.POLL.IN) != 0) {
        drainVisibleClientInput(terminal_worker);
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
    if ((revents & posix.POLL.OUT) != 0) {
        flushPendingWorkerClientOutput(terminal_worker);
    }
    if (!terminal_worker.pending_client.active) return;
    if (terminal_worker.pending_client.close_after_flush) return;
    if ((revents & posix.POLL.IN) != 0) drainPendingWorkerClient(terminal_worker);
}

fn flushPendingWorkerClientOutput(terminal_worker: *TerminalWorker) void {
    const pending_client = &terminal_worker.pending_client;
    if (!pending_client.active) return;
    switch (pending_client.drainWrites() catch {
        pending_client.close();
        return;
    }) {
        .blocked, .progress => {},
        .drained => if (pending_client.close_after_flush) pending_client.close(),
    }
}

// Read the handshake/open frames from a newly connected client that has not yet
// become the visible client. The pending fd is either rejected, closed after a
// queued error, or transferred into visible_client once the open request matches
// an existing/new session.
fn drainPendingWorkerClient(terminal_worker: *TerminalWorker) void {
    const pending_client = &terminal_worker.pending_client;
    if (!pending_client.active) return;
    if (pending_client.close_after_flush) return;
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
                if (pending_client.hasPendingWrite()) return;
                pending_client.close();
                return;
            },
            .transferred_to_visible_client => return,
        }
    }
}

const PendingWorkerFrameResult = enum {
    continue_reading,
    close,
    transferred_to_visible_client,
};

// Interpret the first terminal-emulator item on a pending client connection.
// Only open/debug/hangup control is valid here; ordinary input/draw traffic is
// accepted only after connectPendingWorkerClient installs the visible client.
fn handlePendingWorkerClientFrame(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    frame: *protocol.OwnedFrame,
) !PendingWorkerFrameResult {
    var decoded = try terminal_worker_protocol.decodePendingClientFrame(app_allocator.allocator(), frame);
    defer decoded.deinit(app_allocator.allocator());
    switch (decoded) {
        .continue_reading => return .continue_reading,
        .transport_control => |control| {
            try handlePendingWorkerTransportControl(pending_client, control);
            return .continue_reading;
        },
        .terminal_item => |*item| {
            const item_payload = item.payload orelse {
                try sendProtocolError(pending_client, "unexpected empty terminal stream item");
                return .close;
            };
            switch (terminal_worker_protocol.classifyFirstTerminalItem(item)) {
                .resize => return .continue_reading,
                .open => return try handlePendingWorkerOpen(terminal_worker, pending_client, item_payload.open),
                .debug_sever_connection_request => {
                    try handleDebugSeverConnectionRequest(terminal_worker, pending_client);
                    return .close;
                },
                .debug_unresponsive_connection_request => {
                    try handleDebugUnresponsiveConnectionRequest(terminal_worker, pending_client, item_payload.debug_unresponsive_connection_request);
                    return .close;
                },
                .session_hangup_request => {
                    handleSessionHangupRequest(terminal_worker);
                    return .close;
                },
                .unexpected => {
                    try sendProtocolError(pending_client, "unexpected first terminal stream item");
                    return .close;
                },
            }
        },
        .unexpected_empty_terminal_item => {
            try sendProtocolError(pending_client, "unexpected empty terminal stream item");
            return .close;
        },
        .unexpected_first_terminal_item => {
            try sendProtocolError(pending_client, "unexpected first terminal stream item");
            return .close;
        },
        .unexpected_first_action => {
            try sendProtocolError(pending_client, "unexpected first action");
            return .close;
        },
    }
}

fn handlePendingWorkerTransportControl(pending_client: *PendingWorkerClient, control: protocol.TransportControl) !void {
    switch (control) {
        .ping => try pending_client.queueDaemonTunnelPayload(.{ .pong = .{} }),
        .pong => {},
    }
}

// Resolve an open request into either an attach to the worker's existing session
// or creation of the single PTY session this worker will own for its lifetime.
fn handlePendingWorkerOpen(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    open: pb.TerminalEmulatorItem.Open,
) !PendingWorkerFrameResult {
    if (open.create == null) {
        var request = try visibleClientOpenRequestFromOpen(open);
        defer request.deinit();
        if (request.session_guid.len == 0) return error.MissingSessionGuid;
        const session = findSession(terminal_worker, request.session_guid);
        const resolved_session = session orelse {
            try sendSessionNotFound(pending_client);
            return .close;
        };
        updateSessionSize(resolved_session, request.resize.size);
        return try connectPendingWorkerClient(.{
            .terminal_worker = terminal_worker,
            .pending_client = pending_client,
            .resize = request.resize,
            .capture_tty_transcript = request.capture_tty_transcript,
        });
    }

    const open_payload = try protocol.encodePayload(app_allocator.allocator(), open);
    defer app_allocator.allocator().free(open_payload);
    var request = readSessionCreateRequest(open_payload) catch {
        try sendProtocolError(pending_client, "invalid terminal stream open payload");
        return .close;
    };
    defer request.deinit();
    _ = try createSession(terminal_worker, .{
        .size = request.resize.size,
        .scrollback_row_count = request.scrollback_row_count,
        .environment = request.environment,
        .query_default_colors = request.query_default_colors,
        .session_guid = request.session_guid,
        .command_argv = request.command_argv,
        .shell_command = request.shell_command,
        .tty_settings = request.tty_settings,
        .reap_ms = request.reap_ms,
    });
    return try connectPendingWorkerClient(.{
        .terminal_worker = terminal_worker,
        .pending_client = pending_client,
        .resize = request.resize,
        .capture_tty_transcript = request.capture_tty_transcript,
    });
}

const ConnectPendingWorkerClientOptions = struct {
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    resize: ResizePayload,
    capture_tty_transcript: bool,
};

fn connectPendingWorkerClient(options: ConnectPendingWorkerClientOptions) !PendingWorkerFrameResult {
    const terminal_worker = options.terminal_worker;
    const pending_client = options.pending_client;

    var fd = core_fds.OwnedFd.init(pending_client.takeFd());
    defer fd.deinit();
    pending_client.close();
    try connectVisibleClient(.{
        .terminal_worker = terminal_worker,
        .client_fd = fd.get(),
        .resize = options.resize,
        .capture_tty_transcript = options.capture_tty_transcript,
    });
    _ = fd.take();
    return .transferred_to_visible_client;
}

fn sendError(pending_client: *PendingWorkerClient, info: protocol.ErrorInfo) !void {
    try pending_client.queueError(info);
    pending_client.close_after_flush = true;
}

fn sendProtocolError(pending_client: *PendingWorkerClient, message: []const u8) !void {
    try pending_client.queueProtocolError(message);
    pending_client.close_after_flush = true;
}

fn sendSessionNotFound(pending_client: *PendingWorkerClient) !void {
    try pending_client.queueSessionNotFound();
    pending_client.close_after_flush = true;
}

fn flushVisibleClientOutput(terminal_worker: *TerminalWorker) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    if (visible_client.debug_unresponsive_until_ms != 0) {
        const now_ms = terminalWorkerMonotonicMs(terminal_worker);
        if (visible_client.debug_unresponsive_until_ms > now_ms) return;
        visible_client.debug_unresponsive_until_ms = 0;
    }

    const status = visible_client.writer.writeReady(visible_client.fd) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    if (status == .drained) {
        if (visible_client.close_after_flush) {
            disconnectVisibleClient(terminal_worker);
        }
    }
}

fn handleDebugSeverConnectionRequest(terminal_worker: *TerminalWorker, pending_client: *PendingWorkerClient) !void {
    _ = try visibleClientForDebugControl(terminal_worker, pending_client) orelse return;
    disconnectVisibleClient(terminal_worker);
    try sendClientControlResponse(pending_client);
}

fn handleDebugUnresponsiveConnectionRequest(
    terminal_worker: *TerminalWorker,
    pending_client: *PendingWorkerClient,
    request: pb.TerminalEmulatorItem.SessionClientDebugUnresponsiveConnectionRequest,
) !void {
    const seconds = if (request.seconds == 0)
        config.default_debug_unresponsive_seconds
    else
        request.seconds;
    const until_ms = terminalWorkerMonotonicMs(terminal_worker) + @as(i64, seconds) * std.time.ms_per_s;
    const visible_client = try visibleClientForDebugControl(terminal_worker, pending_client) orelse return;
    visible_client.debug_unresponsive_until_ms = until_ms;
    try sendClientControlResponse(pending_client);
}

fn visibleClientForDebugControl(terminal_worker: *TerminalWorker, pending_client: *PendingWorkerClient) !?*VisibleClient {
    const visible_client = &terminal_worker.visible_client;
    if (visible_client.active and !visible_client.close_after_flush) return visible_client;
    try sendError(pending_client, .{
        .code = "NO_VISIBLE_CLIENT",
        .message = "no visible client connection",
    });
    return null;
}

fn sendClientControlResponse(pending_client: *PendingWorkerClient) !void {
    try pending_client.queueTerminalEmulatorFrame(.{ .session_client_control_response = .{} });
    pending_client.close_after_flush = true;
}

fn queueTtyTranscriptChunkForSession(
    terminal_worker: *TerminalWorker,
    stream: pb.TerminalEmulatorItem.TtyTranscriptChunk.Stream,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    if (visible_client.close_after_flush or !visible_client.capture_tty_transcript) return;
    terminal_worker_render.queueTtyTranscriptChunk(visible_client, stream, bytes) catch {
        disconnectVisibleClient(terminal_worker);
    };
}
fn updateSessionSize(session: *Session, size: WindowSize) void {
    const resized = !session.size.eql(size);
    session.size = size;
    if (session.terminal_model) |model| {
        model.resize(size) catch {};
        if (resized) terminal_worker_render.advanceScrollbackEpoch(session);
    }
    session.process.setPtySize(size);
}

const SessionCreateSpec = struct {
    size: WindowSize,
    scrollback_row_count: u32,
    environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    tty_settings: ?tty_settings.Settings,
    reap_ms: u64,
};

// Create the worker's one PTY-backed terminal session. The terminal model must
// be initialized before spawning so the first visible client can receive a
// coherent snapshot as soon as the process starts producing output.
fn createSession(
    terminal_worker: *TerminalWorker,
    spec: SessionCreateSpec,
) !*Session {
    if (terminal_worker.started_session or terminal_worker.session.alive or terminal_worker.visible_client.active) return error.TooManySessions;

    const terminal_model = try vt.SessionTerminal.create(.{
        .allocator = app_allocator.allocator(),
        .size = spec.size,
        .scrollback_rows = spec.scrollback_row_count,
        .query_default_colors = spec.query_default_colors,
    });
    errdefer terminal_model.destroy();

    if (!guid_ref.isValidSessionGuid(spec.session_guid)) return error.InvalidSessionGuid;
    const session_guid_z = try app_allocator.allocator().dupeZ(u8, spec.session_guid);
    defer app_allocator.allocator().free(session_guid_z);

    const process = try remote_process.Process.spawn(app_allocator.allocator(), .{
        .size = spec.size,
        .shell = spec.environment.shell,
        .command_argv = spec.command_argv,
        .shell_command = spec.shell_command,
        .environment = spec.environment.entries.items,
        .session_guid = session_guid_z,
        .add_sessh_path_to_env = true,
        .tty_settings = spec.tty_settings,
    });
    errdefer {
        var close_process = process;
        close_process.closePty();
    }

    const session = &terminal_worker.session;
    session.* = Session{
        .process = process,
        .terminal_model = terminal_model,
        .size = spec.size,
        .scrollback_row_count = spec.scrollback_row_count,
        .reap_ms = spec.reap_ms,
        .alive = true,
    };
    try session.setId(spec.session_guid);
    terminal_worker.started_session = true;
    return session;
}

const ConnectVisibleClientOptions = struct {
    terminal_worker: *TerminalWorker,
    client_fd: c.fd_t,
    resize: ResizePayload,
    capture_tty_transcript: bool,
};

// Promote a pending client fd into the active visible client. This sends
// session-ready plus either an initial snapshot or the requested repaint before
// enabling normal bidirectional traffic.
fn connectVisibleClient(options: ConnectVisibleClientOptions) !void {
    const terminal_worker = options.terminal_worker;
    const client_fd = options.client_fd;
    const resize = options.resize;
    const capture_tty_transcript = options.capture_tty_transcript;

    const session = &terminal_worker.session;
    disconnectVisibleClient(terminal_worker);
    try core_fds.setNonBlocking(client_fd);

    const visible_client = &terminal_worker.visible_client;
    visible_client.* = .{
        .fd = client_fd,
        .size = resize.size,
        .connected_at_unix_ms = nowUnixMs(),
        .active = true,
        .reader = protocol.FrameReader.init(app_allocator.allocator()),
        .reader_initialized = true,
        .writer = frame_write_queue.FrameWriteQueue.init(app_allocator.allocator()),
        .writer_initialized = true,
        .capture_tty_transcript = capture_tty_transcript,
    };
    visible_client.presentation.setViewportOffset(resize.viewport_offset);
    errdefer {
        if (visible_client.reader_initialized) visible_client.reader.deinit();
        if (visible_client.writer_initialized) visible_client.writer.deinit();
        visible_client.* = VisibleClient{};
    }
    try terminal_worker_render.sendSessionReady(visible_client, session);
    const draw_emitter = terminal_worker_render.DrawEmitter.init(visible_client, session);
    if (resize.repaint_request) |request| {
        try draw_emitter.emitRepaintSnapshot(request);
    } else {
        try draw_emitter.emitSessionSnapshot();
    }
    refreshVisibleClientConnectionState(terminal_worker);
    flushVisibleClientOutput(terminal_worker);
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
        if (!terminal_worker.session.flushPtyInput()) {
            endSessionFromPtyClose(terminal_worker);
            return;
        }
    }
    if ((revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        drainSessionOutput(terminal_worker);
    }
}

// Drain PTY output in bounded batches, feed it through the VT model, and then
// broadcast a patch unless synchronized-output mode asks us to hold updates
// briefly for an atomic redraw.
fn drainSessionOutput(terminal_worker: *TerminalWorker) void {
    const session = &terminal_worker.session;
    if (!session.alive) return;

    var context = SessionPtyDrainContext{
        .terminal_worker = terminal_worker,
    };
    const result = pty_process.drainMasterNonBlocking(.{
        .fd = session.process.pty_fd,
        .context = &context,
        .on_bytes = feedSessionPtyBytes,
        .limits = .{
            .max_reads = max_live_output_reads_per_batch,
            .max_bytes = preferred_live_output_batch_bytes,
        },
    }) catch {
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
    terminal_worker.session.queuePtyInput(input_responses) catch return error.SessionPtyResponseWriteFailed;
    model.clearPendingInputResponses();
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
    // Render barriers split PTY output around screen-mode transitions. Flush the
    // VT state before applying the transition so the visible client never draws
    // primary-screen bytes as alternate-screen bytes, or vice versa.
    const session = &terminal_worker.session;
    if (!session.alive) return;
    if (session.terminal_model == null) return;

    // A render barrier means the current VT state must be queued before the
    // following terminal transition is applied. Original-byte replay cannot
    // cross this boundary because the bytes before the barrier are already
    // inside the VT model and may not match the bytes buffered here.
    session.clearPendingPlainOutput();
    broadcastSessionPatch(terminal_worker);
    session.clearPendingPlainOutput();

    if (!session.alive) return;
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active or visible_client.close_after_flush) return;
    const draw_emitter = terminal_worker_render.DrawEmitter.init(visible_client, session);
    draw_emitter.emitRenderBarrier(barrier) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    flushVisibleClientOutput(terminal_worker);
}

fn feedSessionOutputBytes(terminal_worker: *TerminalWorker, bytes: []const u8) !void {
    // PTY output is both transcript data and terminal-model input. Plain output
    // can be replayed as raw bytes until an escape sequence or render barrier
    // forces us to switch to model-derived draw frames.
    const session = &terminal_worker.session;
    queueTtyTranscriptChunkForSession(terminal_worker, .STREAM_INNER_OUT, bytes);
    if (session.terminal_model) |model| {
        const starts_at_boundary = model.isPlainTextParserBoundary();
        var barrier_context = RenderBarrierContext{
            .terminal_worker = terminal_worker,
        };
        const saw_render_barrier = try model.feedWithRenderBarriers(.{
            .bytes = bytes,
            .context = &barrier_context,
            .callback = handleSessionRenderBarrier,
        });
        if (!saw_render_barrier and hasActiveVisibleClient(terminal_worker)) {
            try session.appendPendingPlainOutput(.{
                .bytes = bytes,
                .starts_at_boundary = starts_at_boundary,
            });
        }
    }
}

// Consume one visible-client frame and apply it to the session. Client input is
// translated through the current terminal modes before it reaches the PTY; resize
// and repaint requests update presentation state instead.
fn drainVisibleClientInput(terminal_worker: *TerminalWorker) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    const session = &terminal_worker.session;
    if (!session.alive) {
        disconnectVisibleClient(terminal_worker);
        return;
    }

    var frame = switch (visible_client.reader.readReady(visible_client.fd) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    }) {
        .blocked, .progress => return,
        .eof, .truncated_frame => {
            disconnectVisibleClient(terminal_worker);
            return;
        },
        .frame => |frame_value| frame_value,
    };
    defer frame.deinit(app_allocator.allocator());

    switch (frame.message_type) {
        .client_remote => {
            var item = protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload) catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse {
                disconnectVisibleClient(terminal_worker);
                return;
            };
            switch (item_payload) {
                .input => |input| handleInputFrame(terminal_worker, input),
                .resize => |resize| handleResizeFrame(terminal_worker, resize),
                .repaint_request => |repaint| handleRepaintFrame(terminal_worker, repaint),
                .session_hangup_request => handleSessionHangupRequest(terminal_worker),
                else => {
                    queueVisibleClientProtocolError(visible_client, "unexpected visible-client terminal item") catch {
                        disconnectVisibleClient(terminal_worker);
                        return;
                    };
                    closeVisibleClientAfterFlush(terminal_worker);
                },
            }
        },
        .daemon_tunnel => {
            const control = protocol.decodeTransportControlFrame(app_allocator.allocator(), frame.message_type, frame.payload) catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
            if (control) |transport_control| {
                handleVisibleClientTransportControl(visible_client, transport_control) catch {
                    disconnectVisibleClient(terminal_worker);
                    return;
                };
            }
        },
        else => {
            queueVisibleClientProtocolError(visible_client, "unexpected session-ready message") catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
            closeVisibleClientAfterFlush(terminal_worker);
        },
    }
}

fn queueVisibleClientProtocolError(visible_client: *VisibleClient, message: []const u8) !void {
    try visible_client.queueProtocolError(message);
}

fn handleVisibleClientTransportControl(visible_client: *VisibleClient, control: protocol.TransportControl) !void {
    switch (control) {
        .ping => try visible_client.queueDaemonTunnelPayload(.{ .pong = .{} }),
        .pong => {},
    }
}

fn handleSessionHangupRequest(terminal_worker: *TerminalWorker) void {
    requestSessionPtyHangup(terminal_worker);
}

fn requestSessionPtyHangup(terminal_worker: *TerminalWorker) void {
    const session = &terminal_worker.session;
    if (!session.alive) {
        disconnectVisibleClient(terminal_worker);
        return;
    }

    disconnectVisibleClient(terminal_worker);
    if (session.process.hasOpenPty()) {
        session.process.closePtyForHangup();
        session.synchronized_output_since_ms = 0;
    }
    _ = reapPtyHangupSessionIfExited(terminal_worker);
}

fn reapPtyHangupSessionIfExited(terminal_worker: *TerminalWorker) bool {
    // After a client hang-up closes the PTY, poll for child exit without
    // blocking the worker loop. A still-running child will be checked again by
    // the worker maintenance timer.
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

// After PTY EOF, wait briefly for process exit status so the visible client can
// report the real ssh-like status. If the child does not report in time, treat
// the closed PTY as authoritative and finish the session.
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

// Acknowledge ordered input from the visible client, translate terminal-specific
// escape reports into the inner PTY's coordinate/key protocol, and queue the
// translated bytes to the PTY writer.
fn handleInputFrame(terminal_worker: *TerminalWorker, input: pb.TerminalEmulatorItem.Input) void {
    const visible_client = &terminal_worker.visible_client;
    const session = &terminal_worker.session;
    if (input.data.len == 0) return;

    if (input.input_seq != 0) {
        visible_client.queueTerminalEmulatorFrame(.{ .input_ack = .{
            .input_seq = input.input_seq,
        } }) catch {
            disconnectVisibleClient(terminal_worker);
            return;
        };
        flushVisibleClientOutput(terminal_worker);
    }

    if (!session.size.eql(visible_client.size)) {
        updateSessionSize(session, visible_client.size);
    }

    var translated = std.ArrayList(u8).empty;
    defer translated.deinit(app_allocator.allocator());
    input_translation.translate(
        app_allocator.allocator(),
        .{
            .pending = &visible_client.input_pending,
            .mode = visible_client.inputModeState(),
            .session_size = session.size,
            .bytes = input.data,
            .out = &translated,
        },
    ) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    if (translated.items.len == 0) return;

    terminal_worker_render.queueTtyTranscriptChunk(visible_client, .STREAM_INNER_IN, translated.items) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    flushVisibleClientOutput(terminal_worker);

    terminal_worker.session.queuePtyInput(translated.items) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
}

fn handleResizeFrame(terminal_worker: *TerminalWorker, message: pb.TerminalEmulatorItem.Resize) void {
    const visible_client = &terminal_worker.visible_client;
    const session = &terminal_worker.session;
    const resize = resizePayloadFromMessage(message) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    const reset_for_screen_repaint = resize.repaint_request != null and
        resize.repaint_request.?.scrollback_cursor == null;
    visible_client.size = resize.size;
    if (reset_for_screen_repaint) visible_client.presentation.resetForScreenRepaint();
    visible_client.presentation.setViewportOffset(resize.viewport_offset);
    updateSessionSize(session, visible_client.size);
    if (resize.repaint_request) |request| {
        handleRepaintRequest(terminal_worker, request);
    }
}

fn handleRepaintFrame(terminal_worker: *TerminalWorker, message: pb.TerminalEmulatorItem.RepaintRequest) void {
    const request = repaintRequestFromMessage(message) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    handleRepaintRequest(terminal_worker, request);
}

fn handleRepaintRequest(terminal_worker: *TerminalWorker, request: RepaintRequest) void {
    const visible_client = &terminal_worker.visible_client;
    const session = &terminal_worker.session;

    const model = session.terminal_model orelse return;
    const clear_for_replace = request.scrollback_cursor != null and
        request.scrollback_cursor.?.per_epoch_cursor == 0;
    const draw_emitter = terminal_worker_render.DrawEmitter.init(visible_client, session);
    const screen_rows = draw_emitter.emitRepaint(request, clear_for_replace) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    model.markRendered(screen_rows);
    flushVisibleClientOutput(terminal_worker);
}

// Push the terminal model's latest scrollback/screen delta to the one visible
// client. Render failures mean the model can no longer produce a trustworthy
// client view, so the worker closes the client instead of sending partial state.
fn broadcastSessionPatch(terminal_worker: *TerminalWorker) void {
    if (!hasActiveVisibleClient(terminal_worker)) return;

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
    const visible_client = &terminal_worker.visible_client;
    if (visible_client.active and !visible_client.close_after_flush) {
        const draw_emitter = terminal_worker_render.DrawEmitter.init(visible_client, session);
        if (screen.retained_scrollback_clear_dirty) {
            draw_emitter.emitRetainedScrollbackClear() catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
        }
        if (scrollback.rows.len > 0) {
            draw_emitter.emitScrollbackAndScreen(.{
                .rows = scrollback.rows,
                .draw = .{
                    .screen = &screen,
                    .restore_screen = if (primary_screen) |*primary| primary else null,
                    .align_viewport = materialize_screen_after_scrollback,
                    .scrollback_cursor = scrollback.absolute_count,
                },
            }) catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
        } else if (should_send_screen_draw) {
            _ = draw_emitter.emitScreen(.{
                .materialize = materialize_screen_after_scrollback,
                .draw = .{
                    .screen = &screen,
                    .restore_screen = if (primary_screen) |*primary| primary else null,
                    .align_viewport = materialize_screen_after_scrollback,
                    .scrollback_cursor = scrollback.absolute_count,
                },
            }) catch {
                disconnectVisibleClient(terminal_worker);
                return;
            };
        }
        flushVisibleClientOutput(terminal_worker);
        if (visible_client.active) delivered = true;
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

fn hasActiveVisibleClient(terminal_worker: *const TerminalWorker) bool {
    const visible_client = &terminal_worker.visible_client;
    return visible_client.active and !visible_client.close_after_flush;
}

fn sendSessionEndedToVisibleClient(terminal_worker: *TerminalWorker, reason: u8, exit_info: ExitInfo) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    terminal_worker_render.sendSessionEnded(visible_client, reason, exit_info) catch {
        disconnectVisibleClient(terminal_worker);
        return;
    };
    closeVisibleClientAfterFlush(terminal_worker);
}

fn disconnectVisibleClient(terminal_worker: *TerminalWorker) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;

    _ = c.close(visible_client.fd);
    if (visible_client.reader_initialized) visible_client.reader.deinit();
    if (visible_client.writer_initialized) visible_client.writer.deinit();
    visible_client.* = VisibleClient{};
    refreshVisibleClientConnectionState(terminal_worker);
}

fn closeVisibleClientAfterFlush(terminal_worker: *TerminalWorker) void {
    const visible_client = &terminal_worker.visible_client;
    if (!visible_client.active) return;
    visible_client.close_after_flush = true;
    flushVisibleClientOutput(terminal_worker);
}

fn refreshVisibleClientConnectionState(terminal_worker: *TerminalWorker) void {
    terminal_worker_lifecycle.applyVisibleClientConnectionState(.{
        .session = &terminal_worker.session,
        .now_connected = hasActiveVisibleClient(terminal_worker),
        .now_unix_ms = nowUnixMs(),
    });
}

fn endSession(terminal_worker: *TerminalWorker, reason: u8, exit_info: ExitInfo) void {
    const session = &terminal_worker.session;
    if (!session.alive) return;

    broadcastSessionPatch(terminal_worker);
    session.clearPendingPlainOutput();
    session.synchronized_output_since_ms = 0;

    sendSessionEndedToVisibleClient(terminal_worker, reason, exit_info);
    session.process.closePty();
    if (session.terminal_model) |model| {
        model.destroy();
        session.terminal_model = null;
    }
    session.deinit();
    session.alive = false;
    session.visible_client_connected = false;
}

fn stopTerminalWorkerIfComplete(terminal_worker: *TerminalWorker) void {
    if (terminal_worker.fixed_session_id == null or !terminal_worker.started_session) return;
    if (terminal_worker.session.alive) return;
    if (terminal_worker.visible_client.active) return;
    terminal_worker.running = false;
}

fn closeTerminalWorker(terminal_worker: *TerminalWorker) void {
    terminal_worker.pending_client.close();
    disconnectVisibleClient(terminal_worker);
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
    // Only ask for process status after PTY EOF. Exit status is useful metadata,
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
