const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const io = @import("../core/io.zig");
const local_boot_time = @import("../core/local_boot_time.zig");
const process_exit = @import("../core/process_exit.zig");
const user_error = @import("../core/user_error.zig");
const proxy_diagnostics = @import("../stream/proxy_diagnostics_channel.zig");
const protocol = @import("../protocol/mod.zig");
const pty_process = @import("../tty/pty_process.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect_title = @import("../reconnect/title.zig");
const status_output = @import("../stream/status_output.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");

// POSIX WNOHANG. Zig exposes this through platform-specific constants, but the
// numeric value is stable on our supported Unix targets and keeps the C
// waitpid(2) call auditable here.
const wait_nohang: c_int = 1;
const child_wait_poll_ms: u64 = 100;

const ProxyClientControl = struct {
    const max_title_bytes = 128;
    const max_status_bytes = 192;
    const max_cleanup_title_bytes = 512;

    control_fd: c.fd_t = -1,
    control_reader: proxy_diagnostics.Reader,
    title_tracker: status_output.TerminalTitleTracker = .{},
    pending_title: [max_title_bytes]u8 = undefined,
    pending_title_len: usize = 0,
    status_line: [max_status_bytes]u8 = undefined,
    status_line_len: usize = 0,
    cleanup_title: [max_cleanup_title_bytes]u8 = [_]u8{0} ** max_cleanup_title_bytes,
    cleanup_title_len: usize = 0,
    title_visible: bool = false,
    status_visible: bool = false,
    intercept_requested: bool = false,
    ctrl_r_allowed: bool = false,
    onscreen_status: bool = false,

    fn init(allocator: std.mem.Allocator, ctrl_r_allowed: bool, onscreen_status: bool) ProxyClientControl {
        var diagnostics = ProxyClientControl{
            .control_reader = proxy_diagnostics.Reader.init(allocator),
            .ctrl_r_allowed = ctrl_r_allowed,
            .onscreen_status = onscreen_status,
        };
        const cwd = std.process.getCwdAlloc(allocator) catch null;
        if (cwd) |title| {
            defer allocator.free(title);
            diagnostics.cleanup_title_len = copyBytes(&diagnostics.cleanup_title, title);
        }
        return diagnostics;
    }

    fn deinit(self: *ProxyClientControl) void {
        self.closeControl();
        self.control_reader.deinit();
        self.* = undefined;
    }

    fn setControlFd(self: *ProxyClientControl, fd: c.fd_t) void {
        if (self.control_fd >= 0) posix.close(self.control_fd);
        self.control_fd = fd;
        core_fds.setNonBlocking(fd) catch {};
    }

    fn closeControl(self: *ProxyClientControl) void {
        if (self.control_fd >= 0) {
            posix.close(self.control_fd);
            self.control_fd = -1;
        }
    }

    fn observeOutput(self: *ProxyClientControl, bytes: []const u8) void {
        self.title_tracker.observe(bytes);
        self.flushPendingTitle();
    }

    fn readControl(self: *ProxyClientControl) void {
        if (self.control_fd < 0) return;
        const allocator = app_allocator.allocator();
        while (true) {
            var message = switch (self.control_reader.readReady(allocator, self.control_fd) catch {
                self.closeControl();
                return;
            }) {
                .blocked, .progress => return,
                .eof, .truncated_frame => {
                    self.closeControl();
                    return;
                },
                .message => |value| value,
            };
            defer message.deinit(allocator);
            self.handleMessage(message.message);
        }
    }

    fn handleMessage(self: *ProxyClientControl, message: proxy_diagnostics.Message) void {
        switch (message) {
            .connection_event => |event| self.handleConnectionEvent(event),
            .retry_now => {},
        }
    }

    fn handleConnectionEvent(self: *ProxyClientControl, event: protocol.pb.ConnectionEvent) void {
        switch (event.event orelse return) {
            .ssh_connecting => self.showUpdate("sessh: connecting..."),
            .ssh_connected => {},
            .ssh_stderr => |stderr| self.showDiagnostic(stderr.data),
            .binary_bootstrapping => self.showUpdate("sessh: bootstrapping..."),
            .daemon_connecting => {
                self.showUpdate(reconnect_title.reconnectingStatus(.{ .ctrl_r = self.ctrl_r_allowed }));
                self.intercept_requested = self.ctrl_r_allowed;
            },
            .daemon_connected => self.clear(),
            .daemon_disconnected => |disconnected| {
                var line: [96]u8 = undefined;
                const delay_ms = retryDelayFromLocalBootDeadline(disconnected.retry_at_local_boot_time_ms);
                const message = reconnect_title.retryStatus(&line, delay_ms, .{ .ctrl_r = self.ctrl_r_allowed }) catch return;
                self.showUpdate(message);
                self.intercept_requested = self.ctrl_r_allowed;
            },
            .unresponsive => |unresponsive| {
                var line: [96]u8 = undefined;
                const delay_ms = retryDelayFromLocalBootDeadline(unresponsive.retry_at_local_boot_time_ms);
                const message = reconnect_title.retryStatus(&line, delay_ms, .{ .ctrl_r = self.ctrl_r_allowed }) catch return;
                self.showUpdate(message);
                self.intercept_requested = self.ctrl_r_allowed;
            },
        }
    }

    fn shouldInterceptCtrlR(self: *const ProxyClientControl) bool {
        return self.ctrl_r_allowed and self.intercept_requested and self.control_fd >= 0;
    }

    fn sendCtrlR(self: *ProxyClientControl) void {
        if (self.control_fd < 0) return;
        proxy_diagnostics.writeRetryNow(self.control_fd) catch {};
    }

    fn showUpdate(self: *ProxyClientControl, line: []const u8) void {
        self.showTitle(line);
        self.showStatus(line);
    }

    fn showStatus(self: *ProxyClientControl, line: []const u8) void {
        self.status_line_len = copyBytes(&self.status_line, line);
        if (!self.onscreen_status) return;
        self.status_visible = true;
        self.redrawStatusLine();
    }

    fn showDiagnostic(self: *ProxyClientControl, line: []const u8) void {
        if (!self.onscreen_status) return;
        if (self.status_visible) io.writeAll(2, "\r\x1b[K") catch {};
        io.writeAll(2, line) catch {};
        io.writeAll(2, "\r\n") catch {};
        if (self.status_visible) self.redrawStatusLine();
    }

    fn showTitle(self: *ProxyClientControl, title: []const u8) void {
        self.pending_title_len = copyBytes(&self.pending_title, title);
        self.flushPendingTitle();
    }

    fn flushPendingTitle(self: *ProxyClientControl) void {
        if (self.pending_title_len == 0) return;
        if (!self.title_tracker.safeForLocalTitle()) return;
        reconnect_title.writeTitle(1, self.pending_title[0..self.pending_title_len]) catch return;
        self.title_visible = true;
        self.pending_title_len = 0;
    }

    fn clear(self: *ProxyClientControl) void {
        self.intercept_requested = false;
        self.clearUpdate();
    }

    fn clearUpdate(self: *ProxyClientControl) void {
        self.pending_title_len = 0;
        if (self.onscreen_status and self.status_visible) {
            io.writeAll(2, "\r\x1b[K") catch {};
            self.status_visible = false;
        }
        self.restoreTitle();
    }

    fn restoreTitle(self: *ProxyClientControl) void {
        if (!self.title_visible) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.cleanup_title[0..self.cleanup_title_len];
        reconnect_title.writeTitle(1, title) catch {};
        self.title_visible = false;
    }

    fn redrawStatusLine(self: *ProxyClientControl) void {
        if (!self.status_visible) return;
        io.writeAll(2, "\r\x1b[K") catch {};
        io.writeAll(2, self.status_line[0..self.status_line_len]) catch {};
    }
};

fn retryDelayFromLocalBootDeadline(deadline_ms: ?u64) u64 {
    const deadline = deadline_ms orelse return 0;
    const now = local_boot_time.nowMs();
    return deadline -| now;
}

fn copyBytes(dest: []u8, source: []const u8) usize {
    const len = @min(dest.len, source.len);
    @memcpy(dest[0..len], source[0..len]);
    return len;
}

pub fn runArgvWithDiagnostics(
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    control_fd: c.fd_t,
    diagnostic_name: []const u8,
) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var diagnostics = ProxyClientControl.init(allocator, false, true);
    if (control_fd >= 0) diagnostics.setControlFd(control_fd);
    defer {
        diagnostics.clear();
        diagnostics.deinit();
    }

    const child_pid: c.pid_t = @intCast(child.id);
    const term = waitForChildAndDiagnostics(child_pid, &diagnostics);
    return exitAfterTerm(term, diagnostic_name);
}

fn waitForChildAndDiagnostics(pid: c.pid_t, diagnostics: *ProxyClientControl) std.process.Child.Term {
    var context = ChildDiagnosticsWait.init(pid, diagnostics) catch return .{ .Unknown = 0 };
    defer context.deinit();
    context.run() catch return .{ .Unknown = 0 };
    return context.term orelse .{ .Unknown = 0 };
}

const ChildDiagnosticsWait = struct {
    wait_dispatcher: dispatcher.Dispatcher,
    pid: c.pid_t,
    diagnostics: *ProxyClientControl,
    control_watch_id: ?dispatcher.FdWatchId = null,
    timer_watch_id: ?dispatcher.TimerWatchId = null,
    term: ?std.process.Child.Term = null,

    fn init(pid: c.pid_t, diagnostics: *ProxyClientControl) !ChildDiagnosticsWait {
        return .{
            .wait_dispatcher = try dispatcher.Dispatcher.init(app_allocator.allocator()),
            .pid = pid,
            .diagnostics = diagnostics,
        };
    }

    fn deinit(self: *ChildDiagnosticsWait) void {
        self.wait_dispatcher.deinit();
    }

    fn run(self: *ChildDiagnosticsWait) !void {
        if (checkChildExit(self.pid)) |term| {
            self.term = term;
            return;
        }
        if (self.diagnostics.control_fd >= 0) {
            self.control_watch_id = try self.wait_dispatcher.watchFd(self.diagnostics.control_fd, .{ .readable = true }, .{
                .ctx = self,
                .callback = handleChildDiagnosticsWaitEvent,
            });
        }
        try self.armTimer();
        try self.wait_dispatcher.run();
    }

    fn armTimer(self: *ChildDiagnosticsWait) !void {
        self.timer_watch_id = try self.wait_dispatcher.watchTimerAfter(child_wait_poll_ms, .{
            .ctx = self,
            .callback = handleChildDiagnosticsWaitEvent,
        });
    }
};

fn handleChildDiagnosticsWaitEvent(
    ctx: *anyopaque,
    d: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    event: dispatcher.Event,
) !void {
    const wait: *ChildDiagnosticsWait = @ptrCast(@alignCast(ctx));
    switch (event) {
        .fd => |fd_event| {
            if (!plainSshFdWatchMatches(id, wait.control_watch_id)) return;
            if (fd_event.readable or fd_event.hangup or fd_event.error_event or fd_event.invalid) {
                wait.diagnostics.readControl();
                if (wait.diagnostics.control_fd < 0) {
                    if (wait.control_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
                    wait.control_watch_id = null;
                }
            }
        },
        .timer => {
            if (!plainSshTimerWatchMatches(id, wait.timer_watch_id)) return;
            wait.timer_watch_id = null;
            if (checkChildExit(wait.pid)) |term| {
                wait.term = term;
                wait.wait_dispatcher.stop();
            } else {
                try wait.armTimer();
            }
        },
    }
}

fn plainSshFdWatchMatches(id: dispatcher.WatchId, expected: ?dispatcher.FdWatchId) bool {
    const expected_id = expected orelse return false;
    const fd_id = switch (id) {
        .fd => |fd| fd,
        .timer => return false,
    };
    return fd_id.index == expected_id.index and fd_id.generation == expected_id.generation;
}

fn plainSshTimerWatchMatches(id: dispatcher.WatchId, expected: ?dispatcher.TimerWatchId) bool {
    const expected_id = expected orelse return false;
    const timer_id = switch (id) {
        .timer => |timer| timer,
        .fd => return false,
    };
    return timer_id.index == expected_id.index and timer_id.generation == expected_id.generation;
}

fn checkChildExit(pid: c.pid_t) ?std.process.Child.Term {
    while (true) {
        var status: c_int = 0;
        const result = c.waitpid(pid, &status, wait_nohang);
        if (result == pid) return pty_process.waitStatusToTerm(@bitCast(status));
        if (result == 0) return null;
        if (result < 0) switch (posix.errno(result)) {
            .INTR => continue,
            else => return .{ .Unknown = 0 },
        };
    }
}

pub fn runArgvUnderLocalPty(
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    control_fd: c.fd_t,
    client_ctrl_r: bool,
    diagnostic_name: []const u8,
) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var size = terminal.currentWindowSize();
    var captured_tty_settings: ?tty_settings.Settings = try tty_settings.capture(allocator, posix.STDIN_FILENO, .{});
    defer if (captured_tty_settings) |*settings| settings.deinit(allocator);

    var child = try pty_process.spawn(allocator, .{
        .rows = size.rows,
        .cols = size.cols,
        .command_argv = ssh_argv,
        .tty_settings = if (captured_tty_settings) |settings| settings else null,
    });
    defer child.terminate();

    var mode_guard = try terminal.TerminalModeGuard.enable(posix.STDIN_FILENO);
    defer mode_guard.restore();

    var stdin_flags_guard = try core_fds.StatusFlagsGuard.setNonBlocking(posix.STDIN_FILENO);
    defer stdin_flags_guard.restore();
    core_fds.setNonBlocking(child.master_fd) catch {};

    var diagnostics = ProxyClientControl.init(allocator, client_ctrl_r, false);
    if (control_fd >= 0) diagnostics.setControlFd(control_fd);
    defer {
        diagnostics.clear();
        diagnostics.deinit();
    }

    while (true) {
        refreshLocalPtySize(child.master_fd, &size);
        var poll = LocalPtyRelayPoll.init(child.master_fd, diagnostics.control_fd) catch continue;
        defer poll.deinit();
        poll.run() catch continue;
        refreshLocalPtySize(child.master_fd, &size);

        if (if (poll.pty_event) |event| event.readable else false) {
            var buf: [8192]u8 = undefined;
            switch (try pty_process.readMaster(child.master_fd, &buf)) {
                .bytes => |bytes| {
                    diagnostics.observeOutput(bytes);
                    try io.writeAll(posix.STDOUT_FILENO, bytes);
                },
                .would_block => {},
                .eof => {
                    const term = child.wait();
                    child.closeMaster();
                    diagnostics.clear();
                    return exitAfterLocalPtyTerm(term, diagnostic_name, &mode_guard, &stdin_flags_guard);
                },
            }
        }
        if (poll.pty_event) |event| {
            if ((event.hangup or event.error_event or event.invalid) and !event.readable) {
                const term = child.wait();
                child.closeMaster();
                diagnostics.clear();
                return exitAfterLocalPtyTerm(term, diagnostic_name, &mode_guard, &stdin_flags_guard);
            }
        }

        if (if (poll.stdin_event) |event| event.readable else false) {
            var input: [4096]u8 = undefined;
            const n = c.read(posix.STDIN_FILENO, &input, input.len);
            if (n > 0) {
                const bytes = input[0..@intCast(n)];
                try writePtyInput(child.master_fd, bytes, &diagnostics);
            }
        }

        if (poll.control_event != null) {
            diagnostics.readControl();
        }
    }
}

const LocalPtyRelayPoll = struct {
    relay_dispatcher: dispatcher.Dispatcher,
    pty_fd: c.fd_t,
    control_fd: c.fd_t,
    pty_watch_id: ?dispatcher.FdWatchId = null,
    stdin_watch_id: ?dispatcher.FdWatchId = null,
    control_watch_id: ?dispatcher.FdWatchId = null,
    pty_event: ?dispatcher.FdEvent = null,
    stdin_event: ?dispatcher.FdEvent = null,
    control_event: ?dispatcher.FdEvent = null,

    fn init(pty_fd: c.fd_t, control_fd: c.fd_t) !LocalPtyRelayPoll {
        return .{
            .relay_dispatcher = try dispatcher.Dispatcher.init(app_allocator.allocator()),
            .pty_fd = pty_fd,
            .control_fd = control_fd,
        };
    }

    fn deinit(self: *LocalPtyRelayPoll) void {
        self.relay_dispatcher.deinit();
    }

    fn run(self: *LocalPtyRelayPoll) !void {
        self.pty_watch_id = try self.relay_dispatcher.watchFd(self.pty_fd, .{ .readable = true }, .{
            .ctx = self,
            .callback = handleLocalPtyRelayPollEvent,
        });
        self.stdin_watch_id = try self.relay_dispatcher.watchFd(posix.STDIN_FILENO, .{ .readable = true }, .{
            .ctx = self,
            .callback = handleLocalPtyRelayPollEvent,
        });
        if (self.control_fd >= 0) {
            self.control_watch_id = try self.relay_dispatcher.watchFd(self.control_fd, .{ .readable = true }, .{
                .ctx = self,
                .callback = handleLocalPtyRelayPollEvent,
            });
        }
        try self.relay_dispatcher.run();
    }

    fn noteFdEvent(self: *LocalPtyRelayPoll, id: dispatcher.WatchId, event: dispatcher.FdEvent) void {
        if (plainSshFdWatchMatches(id, self.pty_watch_id)) {
            self.pty_event = event;
        } else if (plainSshFdWatchMatches(id, self.stdin_watch_id)) {
            self.stdin_event = event;
        } else if (plainSshFdWatchMatches(id, self.control_watch_id)) {
            self.control_event = event;
        }
    }
};

fn handleLocalPtyRelayPollEvent(
    ctx: *anyopaque,
    _: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    event: dispatcher.Event,
) !void {
    const poll: *LocalPtyRelayPoll = @ptrCast(@alignCast(ctx));
    switch (event) {
        .fd => |fd_event| {
            poll.noteFdEvent(id, fd_event);
            poll.relay_dispatcher.stop();
        },
        .timer => {},
    }
}

fn exitAfterLocalPtyTerm(
    term: std.process.Child.Term,
    diagnostic_name: []const u8,
    mode_guard: *terminal.TerminalModeGuard,
    stdin_flags_guard: *core_fds.StatusFlagsGuard,
) !noreturn {
    stdin_flags_guard.restore();
    mode_guard.restore();
    return exitAfterTerm(term, diagnostic_name);
}

fn refreshLocalPtySize(pty_fd: c.fd_t, size: *terminal.WindowSize) void {
    const current_size = terminal.currentWindowSize();
    if (current_size.rows == size.rows and current_size.cols == size.cols) return;
    _ = terminal.setPtySize(pty_fd, current_size.rows, current_size.cols);
    size.* = current_size;
}

fn writePtyInput(pty_fd: c.fd_t, bytes: []const u8, diagnostics: *ProxyClientControl) !void {
    if (!diagnostics.shouldInterceptCtrlR()) {
        try io.writeAll(pty_fd, bytes);
        return;
    }
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != reconnect_control.ctrl_r) continue;
        if (index > start) try io.writeAll(pty_fd, bytes[start..index]);
        diagnostics.sendCtrlR();
        start = index + 1;
    }
    if (start < bytes.len) try io.writeAll(pty_fd, bytes[start..]);
}

fn exitAfterTerm(term: std.process.Child.Term, diagnostic_name: []const u8) !noreturn {
    switch (term) {
        .Exited => |code| return process_exit.request(code),
        .Signal => |signal| {
            try user_error.printLine("{s} ended by signal {}", .{ diagnostic_name, signal });
            return process_exit.request(255);
        },
        else => {
            try user_error.printLine("{s} ended unexpectedly: {t}", .{ diagnostic_name, term });
            return process_exit.request(255);
        },
    }
}

pub fn runArgv(allocator: std.mem.Allocator, ssh_args: []const []const u8, diagnostic_name: []const u8) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    return exitAfterTerm(term, diagnostic_name);
}
