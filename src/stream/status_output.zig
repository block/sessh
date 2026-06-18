const std = @import("std");
const c = std.c;
const posix = std.posix;

const client_log = @import("../core/client_log.zig");
const core_fds = @import("../core/fds.zig");
const connection_event = @import("../diagnostics/connection_event.zig");
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

pub const TerminalTitleTracker = struct {
    const max_title_bytes = 512;
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
    osc_command: [8]u8 = [_]u8{0} ** 8,
    osc_command_len: usize = 0,
    tracking_title: bool = false,
    title: [max_title_bytes]u8 = [_]u8{0} ** max_title_bytes,
    title_len: usize = 0,
    title_present: bool = false,
    pending_title: [max_title_bytes]u8 = [_]u8{0} ** max_title_bytes,
    pending_title_len: usize = 0,
    csi_bytes: [32]u8 = [_]u8{0} ** 32,
    csi_len: usize = 0,
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
        return self.title[0..self.title_len];
    }

    fn observeByte(self: *TerminalTitleTracker, byte: u8) void {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) self.state = .escape;
            },
            .escape => switch (byte) {
                '[' => {
                    self.state = .csi;
                    self.csi_len = 0;
                },
                ']' => {
                    self.state = .osc_command;
                    self.osc_command_len = 0;
                    self.tracking_title = false;
                    self.pending_title_len = 0;
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
                } else if (self.csi_len < self.csi_bytes.len) {
                    self.csi_bytes[self.csi_len] = byte;
                    self.csi_len += 1;
                }
            },
            .osc_command => {
                if (byte == 0x07) {
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                } else if (byte == ';') {
                    self.tracking_title = self.isTitleCommand();
                    self.pending_title_len = 0;
                    self.state = .osc_text;
                } else if (self.osc_command_len < self.osc_command.len) {
                    self.osc_command[self.osc_command_len] = byte;
                    self.osc_command_len += 1;
                }
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
        const command = self.osc_command[0..self.osc_command_len];
        return std.mem.eql(u8, command, "0") or std.mem.eql(u8, command, "2");
    }

    fn appendPendingTitle(self: *TerminalTitleTracker, byte: u8) void {
        if (!self.tracking_title) return;
        if (self.pending_title_len >= self.pending_title.len) return;
        self.pending_title[self.pending_title_len] = byte;
        self.pending_title_len += 1;
    }

    fn finishOsc(self: *TerminalTitleTracker) void {
        if (!self.tracking_title) return;
        @memcpy(self.title[0..self.pending_title_len], self.pending_title[0..self.pending_title_len]);
        self.title_len = self.pending_title_len;
        self.title_present = true;
    }

    fn finishCsi(self: *TerminalTitleTracker, final_byte: u8) void {
        const params = self.csi_bytes[0..self.csi_len];
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

    fd: c.fd_t,
    mode: Mode,
    line: [96]u8 = undefined,
    line_len: usize = 0,
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
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,

    pub fn init(
        mode: Mode,
        ctrl_r_enabled: bool,
        title_fallback: []const u8,
        status_fd: c.fd_t,
    ) Status {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = Status{
            .fd = if (status_fd >= 0) status_fd else switch (mode) {
                .title => 1,
                .line, .status_line, .jsonl => 2,
                .client_control, .disabled => -1,
            },
            .mode = mode,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
        status.title_fallback_len = copyTitle(&status.title_fallback, title_fallback);
        return status;
    }

    pub fn initForTest(fd: c.fd_t, mode: Mode, ctrl_r_enabled: bool, title_fallback: []const u8) Status {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = Status{
            .fd = fd,
            .mode = mode,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
        status.title_fallback_len = copyTitle(&status.title_fallback, title_fallback);
        return status;
    }

    pub fn deinit(self: *Status) void {
        self.clear();
    }

    pub fn setFd(self: *Status, fd: c.fd_t) void {
        self.fd = fd;
    }

    pub fn showRetry(self: *Status, delay_ms: u64) void {
        const message = reconnect_title.retryStatus(&self.line, delay_ms, .{
            .ctrl_r = self.ctrl_r_enabled,
        }) catch return;
        self.line_len = message.len;
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
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
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
                    io.writeAll(self.fd, "sessh: bootstrapping...") catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                },
                .status_line => {
                    @memcpy(self.line[0.."sessh: bootstrapping...".len], "sessh: bootstrapping...");
                    self.line_len = "sessh: bootstrapping...".len;
                    self.connection_status_active = true;
                    self.writeStatusLine();
                },
                .jsonl => self.writeJsonlConnectionEvent(.{ .binary_bootstrapping = .{} }),
                .client_control => proxy_diagnostics.writeConnectionEvent(self.fd, .{ .binary_bootstrapping = .{} }) catch return,
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
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\r\n") catch return;
    }

    fn writeStatusLine(self: *Status) void {
        if (self.mode != .status_line or self.fd < 0) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, "\r\x1b[K") catch return;
        io.writeAll(self.fd, message) catch return;
        self.status_line_visible = true;
    }

    fn clearStatusLine(self: *Status) void {
        if (self.mode != .status_line or self.fd < 0 or !self.status_line_visible) return;
        io.writeAll(self.fd, "\r\x1b[K") catch return;
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
        diagnostics_jsonl.writeRetryScheduled(self.fd, nowUnixMs() +| delay_ms) catch return;
    }

    fn writeJsonlConnectionEvent(self: *Status, event: pb.ConnectionEvent.event_union) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        diagnostics_jsonl.writeConnectionEvent(self.fd, event) catch return;
    }

    fn writeTitleRetry(self: *Status, delay_ms: u64) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeRetryNowTitle(self.fd, delay_ms) catch return;
        } else {
            reconnect_title.writeRetryTitle(self.fd, delay_ms) catch return;
        }
        self.title_visible = true;
    }

    fn writeTitleReconnecting(self: *Status) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeReconnectingNowTitle(self.fd) catch return;
        } else {
            reconnect_title.writeReconnectingTitle(self.fd) catch return;
        }
        self.title_visible = true;
    }

    fn writeClientRetry(self: *Status, delay_ms: u64) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEvent(self.fd, .{ .daemon_disconnected = .{
            .retry_at_local_boot_time_ms = local_boot_time.nowMs() +| delay_ms,
        } }) catch return;
    }

    fn writeClientReconnecting(self: *Status) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEvent(self.fd, .{ .daemon_connecting = .{} }) catch return;
    }

    fn writeClientClear(self: *Status) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_diagnostics.writeConnectionEvent(self.fd, .{ .daemon_connected = .{} }) catch return;
    }

    fn canWriteTitle(self: *const Status) bool {
        return self.mode == .title and self.fd >= 0 and self.title_tracker.safeForLocalTitle();
    }

    fn restoreTitle(self: *Status) void {
        if (!self.title_visible or self.mode != .title or self.fd < 0) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.title_fallback[0..self.title_fallback_len];
        reconnect_title.writeTitle(self.fd, title) catch {};
        self.title_visible = false;
    }

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
            const line = formatDiagnosticLine(
                &line_buf,
                diagnostic,
                diagnostic.seq <= self.live_diagnostic_start_seq,
            ) catch continue;
            switch (self.mode) {
                .status_line => {
                    self.clearStatusLine();
                    io.writeAll(self.fd, line) catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                    if (self.connection_status_active) self.writeStatusLine();
                },
                .line => {
                    io.writeAll(self.fd, line) catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                },
                .jsonl => self.writeJsonlDiagnostic(line),
                .client_control => proxy_diagnostics.writeConnectionEvent(self.fd, .{ .ssh_stderr = .{ .data = line } }) catch return,
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
        io.writeAll(self.fd, "\r\n") catch return;
        inline for (terminal.escape_help_lines) |line| {
            io.writeAll(self.fd, line) catch return;
            io.writeAll(self.fd, "\r\n") catch return;
        }
    }

    fn writeJsonlDiagnostic(self: *Status, line: []const u8) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        diagnostics_jsonl.writeDiagnostic(self.fd, line) catch return;
    }
};

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn copyTitle(dest: []u8, title: []const u8) usize {
    const len = @min(dest.len, title.len);
    @memcpy(dest[0..len], title[0..len]);
    return len;
}

fn formatDiagnosticLine(
    out: []u8,
    diagnostic: *const client_log.UserDiagnosticLine,
    delayed: bool,
) ![]const u8 {
    const prefix = if (delayed)
        try std.fmt.bufPrint(out, "{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms })
    else
        try std.fmt.bufPrint(out, "{s}: ", .{diagnostic.tag.label()});
    const message = diagnostic.slice();
    if (prefix.len + message.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[prefix.len .. prefix.len + message.len], message);
    return out[0 .. prefix.len + message.len];
}

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

test "stream reconnect status uses plain stderr lines" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .line, false, "");
    status.showRetry(1_000);
    status.showRetry(500);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
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

    var status = Status.initForTest(fds[1], .status_line, false, "");
    status.showRetry(2_000);
    status.showRetry(1_000);
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\x1b[Ksessh: disconnected: Retry connecting 2sec") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\x1b[Ksessh: disconnected: Retry connecting 1sec") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\r\x1b[K"));
}

test "stream reconnect status emits one jsonl retry per wait" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .jsonl, false, "");
    status.handleConnectionEvent(.{ .event = .{ .daemon_disconnected = .{} } });
    status.handleConnectionEvent(.{ .event = .{ .unresponsive = .{} } });
    status.handleConnectionEvent(.{ .event = .{ .ssh_stderr = .{ .data = "ssh: noisy\n" } } });
    status.handleConnectionEvent(.{ .event = .{ .daemon_connecting = .{} } });
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
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

    var status = Status.initForTest(fds[1], .disabled, true, "test-host");
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

    var status = Status.initForTest(fds[1], .client_control, true, "");
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

    var status = Status.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound("\x1b]2;remote");
    status.observeInbound("-title\x1b\\");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;remote-title\x1b\\",
        output,
    );
}

test "stream reconnect status uses fallback title when app set none" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .title, true, "test-host");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output,
    );
}

test "stream reconnect status skips title while terminal parser is unsafe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .title, true, "test-host");
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

    var status = Status.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound("\x1b]2;partial-title");
    status.showEscapeHelp();

    var empty_buf: [16]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &empty_buf));

    status.observeInbound("\x1b\\");
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Supported escape sequences") != null);
}

test "stream reconnect status treats synchronized update as unsafe for title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound("\x1b[?2026h");
    status.showRetry(10_000);
    status.clear();
    status.observeInbound("\x1b[?2026l");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output,
    );
}

test "stream reconnect status renders ssh diagnostics before status" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = Status.initForTest(fds[1], .line, false, "");
    client_log.appendSshStderr("control sequence: \x1b[31mred\n");
    status.showRetry(1_000);
    status.clear();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
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
    var status = Status.initForTest(fds[1], .line, false, "");
    status.showRetry(1_000);
    client_log.appendSshStderr("connection failed\n");
    status.flushDiagnostics();
    posix.close(fds[1]);

    const output = try readAllFromFd(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "sessh: disconnected: Retry connecting 1sec\r\n" ++
            "ssh: connection failed\r\n",
        output,
    );
}
