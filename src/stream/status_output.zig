// User-visible diagnostics for proxy streams. It tracks enough terminal escape
// state to separate reconnect status from application bytes when possible, and
// falls back to append-only lines or JSONL when the output shape requires it.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const client_log = @import("../core/client_log.zig");
const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const fixed_buffer = @import("../core/fixed_buffer.zig");
const connection_event = @import("../diagnostics/connection_event.zig");
const diagnostics_display = @import("../diagnostics/display.zig");
const diagnostics_jsonl = @import("../diagnostics/jsonl.zig");
const io = @import("../core/io.zig");
const local_boot_time = @import("../core/local_boot_time.zig");
const protocol = @import("../protocol/mod.zig");
const proxy_diagnostics = @import("proxy_diagnostics_channel.zig");
const reconnect_title = @import("../reconnect/title.zig");
const terminal = @import("../tty/terminal.zig");
const pb = protocol.pb;

pub const Mode = enum {
    disabled,
    line,
    status_line,
    title,
    jsonl,
    client_control,
};

// Tracks just enough terminal grammar to know when sessh can safely write local
// reconnect status into the same terminal stream as application output.
//
// CSI means Control Sequence Introducer: ESC [ ... final-byte. We watch CSI
// `?2026h`/`?2026l` because those enter/leave synchronized-output mode, where a
// terminal may buffer title changes until the update ends.
//
// OSC means Operating System Command: ESC ] command ; text BEL/ST. OSC 0 and
// OSC 2 set the terminal/window title; tracking them lets sessh restore the app
// title after temporarily showing reconnect status in title mode.
//
// Other string-like escape families such as DCS are skipped until their
// terminator so local UI is not injected into the middle of application control
// bytes.
pub const TerminalTitleTracker = struct {
    const max_title_bytes = 512;
    const OscCommand = fixed_buffer.FixedBuffer(8);
    const Title = fixed_buffer.FixedBuffer(max_title_bytes);
    const CsiBytes = fixed_buffer.FixedBuffer(32);
    const State = enum {
        ground,
        escape,
        csi,
        osc_command,
        osc_text,
        osc_escape,
        string,
        string_escape,
    };

    state: State = .ground,
    osc_command: OscCommand = .{},
    tracking_title: bool = false,
    title: Title = .{},
    title_present: bool = false,
    pending_title: Title = .{},
    csi_bytes: CsiBytes = .{},
    synchronized_update_active: bool = false,

    pub fn observe(self: *TerminalTitleTracker, bytes: []const u8) void {
        for (bytes) |byte| self.observeByte(byte);
    }

    pub fn safeForLocalTitle(self: *const TerminalTitleTracker) bool {
        // A finished `CSI ? 2026 h` leaves the parser in ground state, but the
        // terminal is still inside a synchronized update. Title changes made
        // there can be held back by the terminal until the matching `l`, so the
        // reconnect UI treats that interval as unsafe too.
        return self.state == .ground and !self.synchronized_update_active;
    }

    pub fn titlePresent(self: *const TerminalTitleTracker) bool {
        return self.title_present;
    }

    pub fn titleSlice(self: *const TerminalTitleTracker) []const u8 {
        return self.title.slice();
    }

    // Incrementally parse just enough terminal output to know when local title
    // diagnostics are safe. We do not emulate the whole terminal here; we only
    // avoid writing OSC title updates in the middle of a remote CSI/OSC/string
    // sequence and keep track of the app's latest OSC title.
    fn observeByte(self: *TerminalTitleTracker, byte: u8) void {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) self.state = .escape;
            },
            .escape => switch (byte) {
                '[' => {
                    self.state = .csi;
                    self.csi_bytes.clear();
                },
                ']' => {
                    self.state = .osc_command;
                    self.osc_command.clear();
                    self.tracking_title = false;
                    self.pending_title.clear();
                },
                'P', '^', '_', 'X' => self.state = .string,
                else => self.state = .ground,
            },
            .csi => {
                if (byte == 0x1b) {
                    self.state = .escape;
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    self.finishCsi(byte);
                    self.state = .ground;
                } else _ = self.csi_bytes.appendByteIfRoom(byte);
            },
            .osc_command => {
                if (byte == 0x07) {
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                } else if (byte == ';') {
                    self.tracking_title = self.isTitleCommand();
                    self.pending_title.clear();
                    self.state = .osc_text;
                } else _ = self.osc_command.appendByteIfRoom(byte);
            },
            .osc_text => {
                if (byte == 0x07) {
                    self.finishOsc();
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                } else {
                    self.appendPendingTitle(byte);
                }
            },
            .osc_escape => {
                if (byte == '\\') {
                    self.finishOsc();
                    self.state = .ground;
                } else {
                    self.appendPendingTitle(0x1b);
                    self.appendPendingTitle(byte);
                    self.state = .osc_text;
                }
            },
            .string => {
                if (byte == 0x1b) self.state = .string_escape;
            },
            .string_escape => {
                self.state = if (byte == '\\') .ground else .string;
            },
        }
    }

    fn isTitleCommand(self: *const TerminalTitleTracker) bool {
        const command = self.osc_command.slice();
        return std.mem.eql(u8, command, "0") or std.mem.eql(u8, command, "2");
    }

    fn appendPendingTitle(self: *TerminalTitleTracker, byte: u8) void {
        if (!self.tracking_title) return;
        _ = self.pending_title.appendByteIfRoom(byte);
    }

    fn finishOsc(self: *TerminalTitleTracker) void {
        if (!self.tracking_title) return;
        self.title.setTruncate(self.pending_title.slice());
        self.title_present = true;
    }

    fn finishCsi(self: *TerminalTitleTracker, final_byte: u8) void {
        const params = self.csi_bytes.slice();
        if (std.mem.eql(u8, params, "?2026")) {
            if (final_byte == 'h') self.synchronized_update_active = true;
            if (final_byte == 'l') self.synchronized_update_active = false;
        }
    }
};

// Stream reconnect UI must keep application bytes clean. When stdout is a
// terminal a caller may use the window title for reconnect status; otherwise it
// may allow append-only stderr lines. Title mode tracks app OSC titles in the
// byte stream so reconnect status can be restored without inventing a second UI
// channel.
pub const Status = struct {
    const max_diagnostic_lines = 3;
    const max_title_fallback_bytes = 512;
    const Line = fixed_buffer.FixedBuffer(96);
    const TitleFallback = fixed_buffer.FixedBuffer(max_title_fallback_bytes);
    pub const InitOptions = struct {
        blocking: core_blocking.Blocking,
        mode: Mode,
        ctrl_r_enabled: bool = false,
        title_fallback: []const u8 = "",
        status_fd: c.fd_t = -1,
    };

    blocking: core_blocking.Blocking,
    fd: c.fd_t,
    mode: Mode,
    line: Line = .{},
    ctrl_r_enabled: bool,
    diagnostic_cursor: u64,
    live_diagnostic_start_seq: u64,
    rendered_diagnostic_seq: u64,
    title_visible: bool = false,
    status_line_visible: bool = false,
    connection_status_active: bool = false,
    append_only_retry_announced: bool = false,
    escape_help_pending: bool = false,
    title_tracker: TerminalTitleTracker = .{},
    title_fallback: TitleFallback = .{},

    pub fn init(options: InitOptions) Status {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = Status{
            .blocking = options.blocking,
            .fd = if (options.status_fd >= 0) options.status_fd else switch (options.mode) {
                .title => posix.STDOUT_FILENO,
                .line, .status_line, .jsonl => posix.STDERR_FILENO,
                .client_control, .disabled => -1,
            },
            .mode = options.mode,
            .ctrl_r_enabled = options.ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
        status.title_fallback.setTruncate(options.title_fallback);
        return status;
    }

    pub fn deinit(self: *Status) void {
        self.clear();
    }

    pub fn setFd(self: *Status, fd: c.fd_t) void {
        self.fd = fd;
    }

    pub fn showRetry(self: *Status, delay_ms: u64) void {
        const message = reconnect_title.retryStatus(self.line.storageSlice(), delay_ms, .{
            .ctrl_r = self.ctrl_r_enabled,
        }) catch return;
        self.line.assumeLen(message.len);
        self.connection_status_active = true;
        self.refreshDiagnostics();
        self.writeTitleRetry(delay_ms);
        self.writeStatusLine();
        self.writeAppendOnlyRetry(delay_ms);
        self.writeClientRetry(delay_ms);
    }

    pub fn showReconnecting(self: *Status) void {
        const message = reconnect_title.reconnectingStatus(.{
            .ctrl_r = self.ctrl_r_enabled,
        });
        self.line.setTruncate(message);
        self.connection_status_active = true;
        self.append_only_retry_announced = false;
        self.refreshDiagnostics();
        self.writeTitleReconnecting();
        self.writeStatusLine();
        self.writePlainStatusLine();
        self.writeJsonlConnectionEvent(.{ .daemon_connecting = .{} });
        self.writeClientReconnecting();
    }

    pub fn clear(self: *Status) void {
        const had_connection_status = self.connection_status_active;
        self.connection_status_active = false;
        self.append_only_retry_announced = false;
        self.refreshDiagnostics();
        self.clearStatusLine();
        self.restoreTitle();
        if (had_connection_status) {
            self.writeJsonlConnectionEvent(.{ .daemon_connected = .{} });
            self.writeClientClear();
        }
    }

    pub fn flushDiagnostics(self: *Status) void {
        self.refreshDiagnostics();
    }

    pub fn showEscapeHelp(self: *Status) void {
        // Direct proxy diagnostics may share a terminal with raw remote output.
        // If the parser says we are inside a control sequence, defer local help
        // text until a safe point so we do not corrupt the user's terminal.
        switch (self.mode) {
            .title => {
                if (!self.canWriteTitle()) {
                    // Direct stream UI shares the terminal with remote output.
                    // If the remote stream is mid-control-sequence, wait until
                    // the parser reaches a safe point before writing local help.
                    self.escape_help_pending = true;
                    return;
                }
                self.writeEscapeHelpText();
            },
            .line => self.writeEscapeHelpText(),
            .status_line => {
                self.clearStatusLine();
                self.writeEscapeHelpText();
                if (self.connection_status_active) self.writeStatusLine();
            },
            .jsonl => {},
            .client_control => {},
            .disabled => {},
        }
    }

    /// Apply one connection diagnostic event to the configured output mode. Title
    /// mode waits for terminal safe-points; line/jsonl modes are append-only; the
    /// client-control mode forwards structured events to the visible client.
    pub fn handleConnectionEvent(self: *Status, event: pb.ConnectionEvent) void {
        switch (connection_event.classify(event)) {
            .ssh_stderr => |stderr| {
                client_log.appendSshStderr(stderr.data);
                if (self.mode == .jsonl) {
                    self.writeJsonlConnectionEvent(.{ .ssh_stderr = stderr });
                } else {
                    self.refreshDiagnostics();
                }
            },
            .binary_bootstrapping => switch (self.mode) {
                .line => {
                    self.blocking.writeAll(self.fd, "sessh: bootstrapping...") catch return;
                    self.blocking.writeAll(self.fd, "\r\n") catch return;
                },
                .status_line => {
                    self.line.setTruncate("sessh: bootstrapping...");
                    self.connection_status_active = true;
                    self.writeStatusLine();
                },
                .jsonl => self.writeJsonlConnectionEvent(.{ .binary_bootstrapping = .{} }),
                .client_control => proxy_diagnostics.writeConnectionEventForeground(self.blocking, self.fd, .{ .binary_bootstrapping = .{} }) catch return,
                .title, .disabled => {},
            },
            .daemon_connecting => self.showReconnecting(),
            .daemon_connected => self.clear(),
            .retry => |retry| {
                if (event.event) |event_payload| self.writeJsonlConnectionEvent(event_payload);
                self.showRetry(retry.delay_ms);
            },
            .ssh_connecting => self.writeJsonlConnectionEvent(.{ .ssh_connecting = .{} }),
            .ssh_connected => self.writeJsonlConnectionEvent(.{ .ssh_connected = .{} }),
            .none => {},
        }
    }

    pub fn observeInbound(self: *Status, bytes: []const u8) void {
        if (self.mode != .title) return;
        self.title_tracker.observe(bytes);
        if (self.escape_help_pending and self.canWriteTitle()) self.writeEscapeHelpText();
    }

    fn writePlainStatusLine(self: *Status) void {
        if (self.mode != .line) return;
        const message = self.line.slice();
        self.blocking.writeAll(self.fd, message) catch return;
        self.blocking.writeAll(self.fd, "\r\n") catch return;
    }

    fn writeStatusLine(self: *Status) void {
        if (self.mode != .status_line or self.fd < 0) return;
        const message = self.line.slice();
        self.blocking.writeAll(self.fd, "\r\x1b[K") catch return;
        self.blocking.writeAll(self.fd, message) catch return;
        self.status_line_visible = true;
    }

    fn clearStatusLine(self: *Status) void {
        if (self.mode != .status_line or self.fd < 0 or !self.status_line_visible) return;
        self.blocking.writeAll(self.fd, "\r\x1b[K") catch return;
        self.status_line_visible = false;
    }

    fn writeAppendOnlyRetry(self: *Status, delay_ms: u64) void {
        switch (self.mode) {
            .line, .jsonl => {},
            else => return,
        }
        if (self.append_only_retry_announced) return;
        self.append_only_retry_announced = true;
        switch (self.mode) {
            .line => self.writePlainStatusLine(),
            .jsonl => self.writeJsonlRetry(delay_ms),
            else => unreachable,
        }
    }

    fn writeJsonlRetry(self: *Status, delay_ms: u64) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        diagnostics_jsonl.writeRetryScheduled(self.blocking, self.fd, nowUnixMs() +| delay_ms) catch return;
    }

    fn writeJsonlConnectionEvent(self: *Status, event: pb.ConnectionEvent.event_union) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        diagnostics_jsonl.writeConnectionEvent(self.blocking, self.fd, event) catch return;
    }

    fn writeTitleRetry(self: *Status, delay_ms: u64) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeRetryNowTitle(self.blocking, self.fd, delay_ms) catch return;
        } else {
            reconnect_title.writeRetryTitle(self.blocking, self.fd, delay_ms) catch return;
        }
        self.title_visible = true;
    }

    fn writeTitleReconnecting(self: *Status) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeReconnectingNowTitle(self.blocking, self.fd) catch return;
        } else {
            reconnect_title.writeReconnectingTitle(self.blocking, self.fd) catch return;
        }
        self.title_visible = true;
    }

    fn writeClientRetry(self: *Status, delay_ms: u64) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEventForeground(self.blocking, self.fd, .{ .daemon_disconnected = .{
            .retry_at_local_boot_time_ms = local_boot_time.nowMs() +| delay_ms,
        } }) catch return;
    }

    fn writeClientReconnecting(self: *Status) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEventForeground(self.blocking, self.fd, .{ .daemon_connecting = .{} }) catch return;
    }

    fn writeClientClear(self: *Status) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEventForeground(self.blocking, self.fd, .{ .daemon_connected = .{} }) catch return;
    }

    fn canWriteTitle(self: *const Status) bool {
        return self.mode == .title and self.fd >= 0 and self.title_tracker.safeForLocalTitle();
    }

    fn restoreTitle(self: *Status) void {
        if (!self.title_visible or self.mode != .title or self.fd < 0) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.title_fallback.slice();
        reconnect_title.writeTitle(self.blocking, self.fd, title) catch {};
        self.title_visible = false;
    }

    // Flush newly buffered ssh stderr/user diagnostics into modes that can show
    // diagnostic text. In status-line mode, each diagnostic is printed above the
    // active status line and then the status line is redrawn.
    fn refreshDiagnostics(self: *Status) void {
        if (self.mode != .line and self.mode != .status_line and self.mode != .client_control and self.mode != .jsonl) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;

        var diagnostics = [_]client_log.UserDiagnosticLine{.{}} ** max_diagnostic_lines;
        const new_cursor = client_log.copyUserDiagnosticsSince(self.diagnostic_cursor, &diagnostics);
        if (new_cursor == self.diagnostic_cursor) {
            self.rendered_diagnostic_seq = new_cursor;
            return;
        }

        for (&diagnostics) |*diagnostic| {
            if (diagnostic.seq == 0) continue;

            var line_buf: [client_log.max_user_diagnostic_display_bytes]u8 = undefined;
            const line_len = diagnostics_display.formatDiagnostic(.{
                .out = &line_buf,
                .diagnostic = diagnostic,
                .delayed = diagnostic.seq <= self.live_diagnostic_start_seq,
            });
            const line = line_buf[0..line_len];
            switch (self.mode) {
                .status_line => {
                    self.clearStatusLine();
                    self.blocking.writeAll(self.fd, line) catch return;
                    self.blocking.writeAll(self.fd, "\r\n") catch return;
                    if (self.connection_status_active) self.writeStatusLine();
                },
                .line => {
                    self.blocking.writeAll(self.fd, line) catch return;
                    self.blocking.writeAll(self.fd, "\r\n") catch return;
                },
                .jsonl => self.writeJsonlDiagnostic(line),
                .client_control => proxy_diagnostics.writeConnectionEventForeground(self.blocking, self.fd, .{ .ssh_stderr = .{ .data = line } }) catch return,
                .title, .disabled => unreachable,
            }
        }

        self.diagnostic_cursor = new_cursor;
        self.rendered_diagnostic_seq = new_cursor;
        client_log.markUserDiagnosticsDisplayedThrough(new_cursor);
    }

    fn writeEscapeHelpText(self: *Status) void {
        if (self.fd < 0) return;
        self.escape_help_pending = false;
        self.blocking.writeAll(self.fd, "\r\n") catch return;
        inline for (terminal.escape_help_lines) |line| {
            self.blocking.writeAll(self.fd, line) catch return;
            self.blocking.writeAll(self.fd, "\r\n") catch return;
        }
    }

    fn writeJsonlDiagnostic(self: *Status, line: []const u8) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        diagnostics_jsonl.writeDiagnostic(self.blocking, self.fd, line) catch return;
    }
};

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

const testing = if (builtin.is_test) struct {
    fn readAllFromFd(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        while (true) {
            var buf: [128]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            try output.appendSlice(allocator, buf[0..@intCast(n)]);
        }
        return try output.toOwnedSlice(allocator);
    }
} else struct {};

test "stream reconnect status uses plain stderr lines" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{ .blocking = core_blocking.fromTest(), .status_fd = fds[1], .mode = .line });
    status.showRetry(1_000);
    status.showRetry(500);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Retry connecting 1sec\r\n" ++
            "sessh: disconnected: Reconnecting...\r\n",
        output,
    );
}

test "stream reconnect status line redraws in place" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{ .blocking = core_blocking.fromTest(), .status_fd = fds[1], .mode = .status_line });
    status.showRetry(2_000);
    status.showRetry(1_000);
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\x1b[Ksessh: disconnected: Retry connecting 2sec") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\x1b[Ksessh: disconnected: Retry connecting 1sec") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\r\x1b[K"));
}

test "stream reconnect status emits one jsonl retry per wait" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{ .blocking = core_blocking.fromTest(), .status_fd = fds[1], .mode = .jsonl });
    status.handleConnectionEvent(.{ .event = .{ .daemon_disconnected = .{} } });
    status.handleConnectionEvent(.{ .event = .{ .unresponsive = .{} } });
    status.handleConnectionEvent(.{ .event = .{ .ssh_stderr = .{ .data = "ssh: noisy\n" } } });
    status.handleConnectionEvent(.{ .event = .{ .daemon_connecting = .{} } });
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"daemon_disconnected\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"unresponsive\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"ssh_stderr\""));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"ssh: noisy\\n\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"retry_scheduled\""));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"retry_at_unix_ms\":") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"daemon_connecting\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\"event\":\"daemon_connected\""));
}

test "disabled stream reconnect status emits no UI" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .disabled,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.showRetry(1_000);
    status.showReconnecting();
    status.showEscapeHelp();
    status.clear();
    posix.close(fds[1]);

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "stream reconnect status emits client control messages" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    try core_fds.setNonBlocking(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .client_control,
        .ctrl_r_enabled = true,
    });
    status.showRetry(1_000);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    var saw_disconnected = false;
    var saw_reconnecting = false;
    var saw_connected = false;
    var reader = proxy_diagnostics.Reader.init(std.testing.allocator);
    defer reader.deinit();
    while (true) {
        var message = switch (try reader.readReady(std.testing.allocator, fds[0])) {
            .blocked, .progress => continue,
            .eof => break,
            .truncated_frame => return error.TruncatedFrame,
            .message => |message| message,
        };
        defer message.deinit(std.testing.allocator);

        switch (message.message) {
            .connection_event => |event| {
                switch (event.event orelse continue) {
                    .daemon_disconnected => |disconnected| {
                        try std.testing.expect(disconnected.retry_at_local_boot_time_ms != null);
                        saw_disconnected = true;
                    },
                    .daemon_connecting => saw_reconnecting = true,
                    .daemon_connected => saw_connected = true,
                    else => {},
                }
            },
            .retry_now => {},
        }
    }

    try std.testing.expect(saw_disconnected);
    try std.testing.expect(saw_reconnecting);
    try std.testing.expect(saw_connected);
}

test "stream reconnect status restores tracked application title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .title,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.observeInbound("\x1b]2;remote");
    status.observeInbound("-title\x1b\\");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;remote-title\x1b\\",
        output,
    );
}

test "stream reconnect status uses fallback title when app set none" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .title,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output,
    );
}

test "stream reconnect status skips title while terminal parser is unsafe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .title,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.observeInbound("\x1b]2;partial-title");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "stream escape help waits for terminal parser safe point" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    try core_fds.setNonBlocking(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .title,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.observeInbound("\x1b]2;partial-title");
    status.showEscapeHelp();

    var empty_buf: [16]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &empty_buf));

    status.observeInbound("\x1b\\");
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Supported escape sequences") != null);
}

test "stream reconnect status treats synchronized update as unsafe for title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{
        .blocking = core_blocking.fromTest(),
        .status_fd = fds[1],
        .mode = .title,
        .ctrl_r_enabled = true,
        .title_fallback = "test-host",
    });
    status.observeInbound("\x1b[?2026h");
    status.showRetry(10_000);
    status.clear();
    status.observeInbound("\x1b[?2026l");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output,
    );
}

test "stream reconnect status renders ssh diagnostics before status" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.init(.{ .blocking = core_blocking.fromTest(), .status_fd = fds[1], .mode = .line });
    client_log.appendSshStderr("control sequence: \x1b[31mred\n");
    status.showRetry(1_000);
    status.clear();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "ssh: control sequence: ?[31mred\r\n" ++
            "sessh: disconnected: Retry connecting 1sec\r\n",
        output,
    );
}

test "stream reconnect status appends diagnostics after status line" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());
    var status = Status.init(.{ .blocking = core_blocking.fromTest(), .status_fd = fds[1], .mode = .line });
    status.showRetry(1_000);
    client_log.appendSshStderr("connection failed\n");
    status.flushDiagnostics();
    posix.close(fds[1]);

    const output = try testing.readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Retry connecting 1sec\r\n" ++
            "ssh: connection failed\r\n",
        output,
    );
}
