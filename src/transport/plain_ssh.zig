// Plain OpenSSH fallback and foreground PTY wrapper. These paths preserve
// ssh-shaped behavior for cases that bypass daemon transport, while still
// applying the requested diagnostics policy.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_fds = @import("../core/fds.zig");
const fixed_buffer = @import("../core/fixed_buffer.zig");
const io = @import("../core/io.zig");
const local_boot_time = @import("../core/local_boot_time.zig");
const poll_sets = @import("../core/poll_set.zig");
const process_exit = @import("../core/process_exit.zig");
const process_wait = @import("../core/waitpid.zig");
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

const ssh_process_wait_poll_ms: u64 = 100;

const ProxyClientControl = struct {
    const max_title_bytes = 128;
    const max_status_bytes = 192;
    const max_cleanup_title_bytes = 512;
    const Title = fixed_buffer.FixedBuffer(max_title_bytes);
    const StatusLine = fixed_buffer.FixedBuffer(max_status_bytes);
    const CleanupTitle = fixed_buffer.FixedBuffer(max_cleanup_title_bytes);

    control_fd: c.fd_t = -1,
    control_reader: proxy_diagnostics.Reader,
    title_tracker: status_output.TerminalTitleTracker = .{},
    pending_title: Title = .{},
    status_line: StatusLine = .{},
    cleanup_title: CleanupTitle = .{},
    title_visible: bool = false,
    status_visible: bool = false,
    intercept_requested: bool = false,
    ctrl_r_allowed: bool = false,
    onscreen_status: bool = false,

    const InitOptions = struct {
        allocator: std.mem.Allocator,
        ctrl_r_allowed: bool = false,
        onscreen_status: bool = false,
    };

    fn init(options: InitOptions) ProxyClientControl {
        var diagnostics = ProxyClientControl{
            .control_reader = proxy_diagnostics.Reader.init(options.allocator),
            .ctrl_r_allowed = options.ctrl_r_allowed,
            .onscreen_status = options.onscreen_status,
        };
        const cwd = std.process.getCwdAlloc(options.allocator) catch null;
        if (cwd) |title| {
            defer options.allocator.free(title);
            diagnostics.cleanup_title.setTruncate(title);
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
        // Plain ssh fallback still receives daemon-style connection diagnostics.
        // Translate them into stderr/status/title updates without attempting to
        // participate in sessh's mux or reconnect protocol.
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
        proxy_diagnostics.writeRetryNowForeground(self.control_fd) catch {};
    }

    fn showUpdate(self: *ProxyClientControl, line: []const u8) void {
        self.showTitle(line);
        self.showStatus(line);
    }

    fn showStatus(self: *ProxyClientControl, line: []const u8) void {
        self.status_line.setTruncate(line);
        if (!self.onscreen_status) return;
        self.status_visible = true;
        self.redrawStatusLine();
    }

    fn showDiagnostic(self: *ProxyClientControl, line: []const u8) void {
        if (!self.onscreen_status) return;
        if (self.status_visible) io.writeAll(posix.STDERR_FILENO, "\r\x1b[K") catch {};
        io.writeAll(posix.STDERR_FILENO, line) catch {};
        io.writeAll(posix.STDERR_FILENO, "\r\n") catch {};
        if (self.status_visible) self.redrawStatusLine();
    }

    fn showTitle(self: *ProxyClientControl, title: []const u8) void {
        self.pending_title.setTruncate(title);
        self.flushPendingTitle();
    }

    fn flushPendingTitle(self: *ProxyClientControl) void {
        if (self.pending_title.isEmpty()) return;
        if (!self.title_tracker.safeForLocalTitle()) return;
        reconnect_title.writeTitle(posix.STDOUT_FILENO, self.pending_title.slice()) catch return;
        self.title_visible = true;
        self.pending_title.clear();
    }

    fn clear(self: *ProxyClientControl) void {
        self.intercept_requested = false;
        self.clearUpdate();
    }

    fn clearUpdate(self: *ProxyClientControl) void {
        self.pending_title.clear();
        if (self.onscreen_status and self.status_visible) {
            io.writeAll(posix.STDERR_FILENO, "\r\x1b[K") catch {};
            self.status_visible = false;
        }
        self.restoreTitle();
    }

    fn restoreTitle(self: *ProxyClientControl) void {
        if (!self.title_visible) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.cleanup_title.slice();
        reconnect_title.writeTitle(posix.STDOUT_FILENO, title) catch {};
        self.title_visible = false;
    }

    fn redrawStatusLine(self: *ProxyClientControl) void {
        if (!self.status_visible) return;
        io.writeAll(posix.STDERR_FILENO, "\r\x1b[K") catch {};
        io.writeAll(posix.STDERR_FILENO, self.status_line.slice()) catch {};
    }
};

fn retryDelayFromLocalBootDeadline(deadline_ms: ?u64) u64 {
    const deadline = deadline_ms orelse return 0;
    const now = local_boot_time.nowMs();
    return deadline -| now;
}

pub const RunArgvWithDiagnosticsOptions = struct {
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    control_fd: c.fd_t,
    diagnostic_name: []const u8,
};

pub fn runArgvWithDiagnostics(options: RunArgvWithDiagnosticsOptions) !noreturn {
    // Run a visible OpenSSH command while a side-channel control fd updates
    // diagnostics. ssh owns stdio; sessh only mirrors important connection
    // status and exits with ssh's resulting status.
    const allocator = options.allocator;
    const ssh_args = options.ssh_args;
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var ssh_process = std.process.Child.init(ssh_argv, allocator);
    ssh_process.expand_arg0 = .expand;
    ssh_process.stdin_behavior = .Inherit;
    ssh_process.stdout_behavior = .Inherit;
    ssh_process.stderr_behavior = .Inherit;
    try ssh_process.spawn();

    var diagnostics = ProxyClientControl.init(.{
        .allocator = allocator,
        .onscreen_status = true,
    });
    if (options.control_fd >= 0) diagnostics.setControlFd(options.control_fd);
    defer {
        diagnostics.clear();
        diagnostics.deinit();
    }

    const ssh_pid: c.pid_t = @intCast(ssh_process.id);
    const term = waitForSshProcessAndDiagnostics(ssh_pid, &diagnostics);
    return exitAfterTerm(term, options.diagnostic_name);
}

fn waitForSshProcessAndDiagnostics(pid: c.pid_t, diagnostics: *ProxyClientControl) std.process.Child.Term {
    var context = SshProcessDiagnosticsWait.init(pid, diagnostics);
    defer context.deinit();
    context.run() catch return .{ .Unknown = 0 };
    return context.term orelse .{ .Unknown = 0 };
}

const PlainSshFdEvent = struct {
    fd: c.fd_t,
    readable: bool = false,
    writable: bool = false,
    hangup: bool = false,
    error_event: bool = false,
    invalid: bool = false,
};

fn plainSshFdEventFromRevents(fd: c.fd_t, revents: i16) PlainSshFdEvent {
    return .{
        .fd = fd,
        .readable = (revents & posix.POLL.IN) != 0,
        .writable = (revents & posix.POLL.OUT) != 0,
        .hangup = (revents & posix.POLL.HUP) != 0,
        .error_event = (revents & posix.POLL.ERR) != 0,
        .invalid = (revents & posix.POLL.NVAL) != 0,
    };
}

const SshProcessDiagnosticsWait = struct {
    pid: c.pid_t,
    diagnostics: *ProxyClientControl,
    term: ?std.process.Child.Term = null,

    fn init(pid: c.pid_t, diagnostics: *ProxyClientControl) SshProcessDiagnosticsWait {
        return .{
            .pid = pid,
            .diagnostics = diagnostics,
        };
    }

    fn deinit(_: *SshProcessDiagnosticsWait) void {}

    fn run(self: *SshProcessDiagnosticsWait) !void {
        // foreground plain-ssh fallback wait. The loop owns
        // only the ssh process status timer and optional diagnostics fd; it
        // does not run inside sesshd or a pooled transport.
        while (true) {
            if (checkSshProcessExit(self.pid)) |term| {
                self.term = term;
                return;
            }
            var pollfds = [_]posix.pollfd{.{
                .fd = self.diagnostics.control_fd,
                .events = if (self.diagnostics.control_fd >= 0) posix.POLL.IN else 0,
                .revents = 0,
            }};
            _ = try posix.poll(pollfds[0..], ssh_process_wait_poll_ms);
            if (pollfds[0].revents != 0) {
                const event = plainSshFdEventFromRevents(pollfds[0].fd, pollfds[0].revents);
                if (event.readable or event.hangup or event.error_event or event.invalid) {
                    self.diagnostics.readControl();
                }
            }
        }
    }
};

fn checkSshProcessExit(pid: c.pid_t) ?std.process.Child.Term {
    while (true) {
        var status: c_int = 0;
        const result = c.waitpid(pid, &status, process_wait.nohang);
        if (result == pid) return process_wait.termFromStatus(@bitCast(status));
        if (result == 0) return null;
        if (result < 0) switch (posix.errno(result)) {
            .INTR => continue,
            else => return .{ .Unknown = 0 },
        };
    }
}

pub const LocalPtyArgvOptions = struct {
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    control_fd: c.fd_t,
    client_ctrl_r: bool,
    diagnostic_name: []const u8,
};

// Run ssh under a local PTY when sessh needs to preserve tty-shaped ssh
// behavior while still filtering diagnostics. This process owns the visible
// terminal, so it can block in its foreground relay loop without starving any
// daemon-owned work.
pub fn runArgvUnderLocalPty(options: LocalPtyArgvOptions) !noreturn {
    const allocator = options.allocator;
    const ssh_args = options.ssh_args;
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var size = terminal.currentWindowSize();
    var captured_tty_settings: ?tty_settings.Settings = try tty_settings.capture(allocator, posix.STDIN_FILENO, .include);
    defer if (captured_tty_settings) |*settings| settings.deinit(allocator);

    var local_pty = try pty_process.spawn(allocator, .{
        .size = size,
        .command_argv = ssh_argv,
        .tty_settings = if (captured_tty_settings) |settings| settings else null,
    });
    defer local_pty.terminate();

    var mode_guard = try terminal.TerminalModeGuard.enable(posix.STDIN_FILENO);
    defer mode_guard.restore();

    var stdin_flags_guard = try core_fds.StatusFlagsGuard.setNonBlocking(posix.STDIN_FILENO);
    defer stdin_flags_guard.restore();
    var presentation_state = LocalPtyPresentationState{
        .mode_guard = &mode_guard,
        .stdin_flags_guard = &stdin_flags_guard,
    };
    core_fds.setNonBlocking(local_pty.master_fd) catch {};

    var diagnostics = ProxyClientControl.init(.{
        .allocator = allocator,
        .ctrl_r_allowed = options.client_ctrl_r,
    });
    if (options.control_fd >= 0) diagnostics.setControlFd(options.control_fd);
    defer {
        diagnostics.clear();
        diagnostics.deinit();
    }

    // this foreground process is only relaying the local
    // PTY, user input, and diagnostics for one visible ssh invocation.
    while (true) {
        refreshLocalPtySize(local_pty.master_fd, &size);
        var poll = LocalPtyRelayPoll.init(local_pty.master_fd, diagnostics.control_fd);
        defer poll.deinit();
        poll.run() catch continue;
        refreshLocalPtySize(local_pty.master_fd, &size);

        if (if (poll.pty_event) |event| event.readable else false) {
            var buf: [8192]u8 = undefined;
            switch (try pty_process.readMaster(local_pty.master_fd, &buf)) {
                .bytes => |bytes| {
                    diagnostics.observeOutput(bytes);
                    try io.writeAll(posix.STDOUT_FILENO, bytes);
                },
                .would_block => {},
                .eof => {
                    // foreground local-PTY relay exit. The PTY
                    // has closed and this process is only collecting ssh status.
                    const term = local_pty.wait();
                    local_pty.closeMaster();
                    diagnostics.clear();
                    return exitAfterLocalPtyTerm(term, options.diagnostic_name, &presentation_state);
                },
            }
        }
        if (poll.pty_event) |event| {
            if ((event.hangup or event.error_event or event.invalid) and !event.readable) {
                // foreground local-PTY relay exit. The PTY has
                // closed and this process is only collecting ssh status.
                const term = local_pty.wait();
                local_pty.closeMaster();
                diagnostics.clear();
                return exitAfterLocalPtyTerm(term, options.diagnostic_name, &presentation_state);
            }
        }

        if (if (poll.stdin_event) |event| event.readable else false) {
            var input: [4096]u8 = undefined;
            const n = c.read(posix.STDIN_FILENO, &input, input.len);
            if (n > 0) {
                const bytes = input[0..@intCast(n)];
                try writePtyInput(local_pty.master_fd, bytes, &diagnostics);
            }
        }

        if (poll.control_event != null) {
            diagnostics.readControl();
        }
    }
}

const LocalPtyRelayPoll = struct {
    pty_fd: c.fd_t,
    control_fd: c.fd_t,
    pty_event: ?PlainSshFdEvent = null,
    stdin_event: ?PlainSshFdEvent = null,
    control_event: ?PlainSshFdEvent = null,

    fn init(pty_fd: c.fd_t, control_fd: c.fd_t) LocalPtyRelayPoll {
        return .{
            .pty_fd = pty_fd,
            .control_fd = control_fd,
        };
    }

    fn deinit(_: *LocalPtyRelayPoll) void {}

    fn run(self: *LocalPtyRelayPoll) !void {
        // foreground local-PTY relay; no daemon work is
        // serviced by this process while this loop is running.
        var poll_set = LocalPtyRelayPollSet{};
        poll_set.add(self.pty_fd, posix.POLL.IN, .pty);
        poll_set.add(posix.STDIN_FILENO, posix.POLL.IN, .stdin);
        if (self.control_fd >= 0) {
            poll_set.add(self.control_fd, posix.POLL.IN, .control);
        }
        _ = try posix.poll(poll_set.fdSlice(), -1);
        for (poll_set.fdSlice(), poll_set.kindSlice()) |pollfd, kind| {
            if (pollfd.revents == 0) continue;
            const event = plainSshFdEventFromRevents(pollfd.fd, pollfd.revents);
            switch (kind) {
                .pty => self.pty_event = event,
                .stdin => self.stdin_event = event,
                .control => self.control_event = event,
            }
        }
    }
};

const LocalPtyRelayPollKind = enum {
    pty,
    stdin,
    control,
};

const LocalPtyRelayPollSet = poll_sets.PollSet(LocalPtyRelayPollKind, 3);

const LocalPtyPresentationState = struct {
    mode_guard: *terminal.TerminalModeGuard,
    stdin_flags_guard: *core_fds.StatusFlagsGuard,

    fn restore(self: LocalPtyPresentationState) void {
        self.stdin_flags_guard.restore();
        self.mode_guard.restore();
    }
};

fn exitAfterLocalPtyTerm(
    term: std.process.Child.Term,
    diagnostic_name: []const u8,
    presentation_state: *LocalPtyPresentationState,
) !noreturn {
    presentation_state.restore();
    return exitAfterTerm(term, diagnostic_name);
}

fn refreshLocalPtySize(pty_fd: c.fd_t, size: *terminal.WindowSize) void {
    const current_size = terminal.currentWindowSize();
    if (current_size.eql(size.*)) return;
    _ = terminal.setPtySize(pty_fd, current_size);
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

    var ssh_process = std.process.Child.init(ssh_argv, allocator);
    ssh_process.expand_arg0 = .expand;
    ssh_process.stdin_behavior = .Inherit;
    ssh_process.stdout_behavior = .Inherit;
    ssh_process.stderr_behavior = .Inherit;
    try ssh_process.spawn();

    // foreground plain-ssh path. At this point the spawned
    // `ssh` process owns the user-visible session and there is no sessh daemon
    // workload in this process to keep responsive.
    const term = try ssh_process.wait();
    return exitAfterTerm(term, diagnostic_name);
}
