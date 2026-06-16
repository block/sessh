const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const local_boot_time = @import("../core/local_boot_time.zig");
const process_exit = @import("../core/process_exit.zig");
const proxy_control = @import("../stream/proxy_control.zig");
const protocol = @import("../protocol/mod.zig");
const pty_process = @import("../tty/pty_process.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect_title = @import("../reconnect/title.zig");
const stream_runtime = @import("../stream/runtime.zig");
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
    control_reader: proxy_control.Reader,
    title_tracker: stream_runtime.TerminalTitleTracker = .{},
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
            .control_reader = proxy_control.Reader.init(allocator),
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
        setNonBlockingFd(fd) catch {};
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
        while (true) {
            var message = switch (self.control_reader.readReady(std.heap.smp_allocator, self.control_fd) catch {
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
            defer message.deinit(std.heap.smp_allocator);
            self.handleMessage(message.message);
        }
    }

    fn handleMessage(self: *ProxyClientControl, message: proxy_control.Message) void {
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
        proxy_control.writeRetryNow(self.control_fd) catch {};
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
    while (true) {
        if (checkChildExit(pid)) |term| return term;

        var pollfds: [1]posix.pollfd = undefined;
        const fds = if (diagnostics.control_fd >= 0) blk: {
            pollfds[0] = .{
                .fd = diagnostics.control_fd,
                .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                .revents = 0,
            };
            break :blk pollfds[0..1];
        } else pollfds[0..0];

        const ready = posix.poll(fds, child_wait_poll_ms) catch return .{ .Unknown = 0 };
        if (ready == 0) continue;
        if (diagnostics.control_fd >= 0 and pollfds[0].revents != 0) {
            diagnostics.readControl();
        }
    }
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

    var stdin_flags_guard = try FdStatusFlagsGuard.setNonBlocking(posix.STDIN_FILENO);
    defer stdin_flags_guard.restore();
    setNonBlockingFd(child.master_fd) catch {};

    var diagnostics = ProxyClientControl.init(allocator, client_ctrl_r, false);
    if (control_fd >= 0) diagnostics.setControlFd(control_fd);
    defer {
        diagnostics.clear();
        diagnostics.deinit();
    }

    while (true) {
        refreshLocalPtySize(child.master_fd, &size);

        var pollfds: [3]posix.pollfd = undefined;
        var count: usize = 0;
        const pty_index = count;
        pollfds[count] = .{ .fd = child.master_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
        const stdin_index = count;
        pollfds[count] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
        var control_index: ?usize = null;
        if (diagnostics.control_fd >= 0) {
            control_index = count;
            pollfds[count] = .{ .fd = diagnostics.control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
            count += 1;
        }

        _ = posix.poll(pollfds[0..count], -1) catch continue;
        refreshLocalPtySize(child.master_fd, &size);

        if ((pollfds[pty_index].revents & posix.POLL.IN) != 0) {
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
        if ((pollfds[pty_index].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[pty_index].revents & posix.POLL.IN) == 0)
        {
            const term = child.wait();
            child.closeMaster();
            diagnostics.clear();
            return exitAfterLocalPtyTerm(term, diagnostic_name, &mode_guard, &stdin_flags_guard);
        }

        if ((pollfds[stdin_index].revents & posix.POLL.IN) != 0) {
            var input: [4096]u8 = undefined;
            const n = c.read(posix.STDIN_FILENO, &input, input.len);
            if (n > 0) {
                const bytes = input[0..@intCast(n)];
                try writePtyInput(child.master_fd, bytes, &diagnostics);
            }
        }

        if (control_index) |index| {
            if (pollfds[index].revents != 0) {
                diagnostics.readControl();
            }
        }
    }
}

fn exitAfterLocalPtyTerm(
    term: std.process.Child.Term,
    diagnostic_name: []const u8,
    mode_guard: *terminal.TerminalModeGuard,
    stdin_flags_guard: *FdStatusFlagsGuard,
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
            try io.stderrPrint("sessh: {s} ended by signal {}\n", .{ diagnostic_name, signal });
            return process_exit.request(255);
        },
        else => {
            try io.stderrPrint("sessh: {s} ended unexpectedly: {t}\n", .{ diagnostic_name, term });
            return process_exit.request(255);
        },
    }
}

fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

const FdStatusFlagsGuard = struct {
    fd: c.fd_t,
    original: c_int,
    active: bool = false,

    // We use F_SETFL to put stdin into non-blocking mode so that we can
    // process IO across multiple file descriptors without additional threads.
    // But the open file description of stdin is shared with the invoking
    // shell, so we need to restore it prior to exiting. Otherwise the shell
    // might get EAGAIN instead of waiting for input, which could cause all
    // kinds of problems.
    fn setNonBlocking(fd: c.fd_t) !FdStatusFlagsGuard {
        const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.FcntlFailed;
        const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
        if ((flags & nonblocking_flag) != 0) return .{ .fd = fd, .original = flags };
        if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
        return .{ .fd = fd, .original = flags, .active = true };
    }

    fn restore(self: *FdStatusFlagsGuard) void {
        if (!self.active) return;
        _ = c.fcntl(self.fd, c.F.SETFL, self.original);
        self.active = false;
    }
};

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
