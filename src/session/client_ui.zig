const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const client_log = @import("../core/client_log.zig");
const core_fds = @import("../core/fds.zig");
const client_renderer = @import("renderer.zig");
const connection_event = @import("../diagnostics/connection_event.zig");
const diagnostics_display = @import("../diagnostics/display.zig");
const reconnect_input = @import("../diagnostics/reconnect_input.zig");
const io_helpers = @import("../core/io.zig");
const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const overlay = @import("overlay.zig");
const protocol = @import("../protocol/mod.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect_title = @import("../reconnect/title.zig");
const terminal = @import("../tty/terminal.zig");

const WindowSize = terminal.WindowSize;
const pb = protocol.pb;
pub const OverlayLine = overlay.Line;
pub const OverlayDrawState = overlay.DrawState;
pub const drawOverlayLines = overlay.drawLines;
pub const clearedOverlayViewportOffset = overlay.clearedOverlayViewportOffset;
pub const eraseOverlayRows = overlay.eraseOverlayRows;
pub const restoreOverlayExpansion = overlay.restoreOverlayExpansion;

pub const ReconnectPresentation = diagnostics_display.Presentation;
pub const ReconnectDecision = reconnect_input.Decision;

pub const ReconnectSwitchDisposition = enum {
    automatic,
    delayed,
    manual_disconnected,
    manual_unresponsive,
};

pub const ReconnectUiOptions = struct {
    presentation: ReconnectPresentation = .overlay,
    input_fd: c.fd_t = posix.STDIN_FILENO,
    output_fd: c.fd_t = posix.STDOUT_FILENO,
    line_fd: c.fd_t = posix.STDERR_FILENO,
};

const OverlayDiagnosticLine = struct {
    bytes: [client_log.max_user_diagnostic_display_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const OverlayDiagnosticLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ReconnectUi = struct {
    const max_diagnostic_overlay_lines = overlay.max_diagnostic_lines;
    const max_overlay_message_bytes = overlay.max_message_bytes;
    mode_guard: terminal.TerminalModeGuard,
    viewport_offset: u16 = 0,
    overlay_state: ?OverlayDrawState = null,
    overlay_message: [max_overlay_message_bytes]u8 = undefined,
    overlay_message_len: usize = 0,
    diagnostic_notify_read_fd: c.fd_t = -1,
    diagnostic_notify_write_fd: c.fd_t = -1,
    clock: NonSuspendingTimer = undefined,
    diagnostic_cursor: u64 = 0,
    live_diagnostic_start_seq: u64 = 0,
    rendered_diagnostic_seq: u64 = 0,
    diagnostic_lines: [max_diagnostic_overlay_lines]OverlayDiagnosticLine = [_]OverlayDiagnosticLine{.{}} ** max_diagnostic_overlay_lines,
    diagnostic_line_count: usize = 0,
    cursor_hidden: bool = false,
    reconnect_input_state: reconnect_input.State = .{},
    cancelled: bool = false,
    input_fd: c.fd_t = posix.STDIN_FILENO,
    output_fd: c.fd_t = posix.STDOUT_FILENO,
    line_fd: c.fd_t = posix.STDERR_FILENO,
    title_state: diagnostics_display.TitleState = .{},
    presentation: ReconnectPresentation = .overlay,
    last_size: WindowSize = .{},
    resize_generation: u64 = 0,
    forwarded_resize_generation: u64 = 0,
    append_only_retry_announced: bool = false,

    pub fn begin(viewport_offset: i32) !ReconnectUi {
        return beginWithPresentation(viewport_offset, .overlay);
    }

    pub fn beginWithPresentation(viewport_offset: i32, presentation: ReconnectPresentation) !ReconnectUi {
        return beginWithOptions(viewport_offset, .{ .presentation = presentation });
    }

    pub fn beginWithOptions(viewport_offset: i32, options: ReconnectUiOptions) !ReconnectUi {
        const title_enabled = (options.presentation == .overlay or options.presentation == .title) and c.isatty(options.output_fd) != 0;
        var ui = ReconnectUi{
            .mode_guard = try terminal.TerminalModeGuard.enable(options.input_fd),
            .clock = try NonSuspendingTimer.start(),
            .input_fd = options.input_fd,
            .output_fd = options.output_fd,
            .line_fd = options.line_fd,
            .title_state = diagnostics_display.TitleState.init(title_enabled, options.output_fd),
            .presentation = options.presentation,
            .last_size = terminal.currentWindowSize(),
        };
        errdefer ui.mode_guard.restore();
        ui.viewport_offset = if (viewport_offset > 0) @intCast(viewport_offset) else 0;
        ui.title_state.captureCleanupTitle(app_allocator.allocator());
        ui.diagnostic_cursor = client_log.displayedUserDiagnosticSeq();
        ui.live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq();
        ui.rendered_diagnostic_seq = ui.diagnostic_cursor;
        const notify_pipe = try posix.pipe();
        ui.diagnostic_notify_read_fd = notify_pipe[0];
        ui.diagnostic_notify_write_fd = notify_pipe[1];
        errdefer {
            posix.close(ui.diagnostic_notify_read_fd);
            posix.close(ui.diagnostic_notify_write_fd);
        }
        try core_fds.setNonBlocking(ui.diagnostic_notify_read_fd);
        try core_fds.setNonBlocking(ui.diagnostic_notify_write_fd);
        client_log.registerUserDiagnosticNotifier(ui.diagnostic_notify_write_fd);
        errdefer client_log.unregisterUserDiagnosticNotifier(ui.diagnostic_notify_write_fd);
        try ui.consumeDiagnostics();
        if (options.presentation == .overlay) try ui.hideCursor();
        return ui;
    }

    pub fn deinit(self: *ReconnectUi) void {
        self.reconnect_input_state.clearDisconnectedInputFlash(self.output_fd) catch {};
        self.restoreTitleForEnd();
        if (self.diagnostic_notify_write_fd >= 0) {
            client_log.unregisterUserDiagnosticNotifier(self.diagnostic_notify_write_fd);
            posix.close(self.diagnostic_notify_write_fd);
            self.diagnostic_notify_write_fd = -1;
        }
        if (self.diagnostic_notify_read_fd >= 0) {
            posix.close(self.diagnostic_notify_read_fd);
            self.diagnostic_notify_read_fd = -1;
        }
        self.showCursor() catch {};
        self.mode_guard.restore();
    }

    pub fn waitForReconnect(self: *ReconnectUi, delay_ms: u64) !ReconnectDecision {
        self.append_only_retry_announced = false;
        try self.drawReconnectOverlay(delay_ms);
        var timer = try NonSuspendingTimer.start();
        var next_overlay_update_ms = diagnostics_display.nextOverlayUpdateDelayMs(delay_ms);

        while (true) {
            const elapsed_ms = elapsedTimerMs(&timer);
            if (elapsed_ms >= delay_ms) {
                self.showReconnectingTitle();
                try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{}));
                return .wait_elapsed;
            }

            const next_wake_ms = @min(delay_ms, next_overlay_update_ms);
            const wait_ms: i32 = @intCast(@min(next_wake_ms - elapsed_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
            const decision = try self.pollInput(wait_ms);
            try self.refreshForResize();
            try self.refreshOverlayIfDiagnosticsChanged();
            switch (decision) {
                .client_hangup => return decision,
                .reconnect_now => {
                    self.showReconnectingTitle();
                    try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{}));
                    return .reconnect_now;
                },
                .wait_elapsed => {},
            }

            const after_poll_ms = elapsedTimerMs(&timer);
            if (after_poll_ms >= next_overlay_update_ms and after_poll_ms < delay_ms) {
                const remaining_ms = delay_ms - after_poll_ms;
                try self.drawReconnectOverlay(remaining_ms);
                next_overlay_update_ms = after_poll_ms + diagnostics_display.nextOverlayUpdateDelayMs(remaining_ms);
            }
        }
    }

    pub fn showDisconnectedReconnectInProgress(self: *ReconnectUi) !void {
        self.showReconnectingTitle();
        try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{}));
    }

    pub fn showUnresponsiveReconnectInProgressTitle(self: *ReconnectUi) void {
        self.showReconnectingNowTitle();
    }

    pub fn showReconnectReady(self: *ReconnectUi, disposition: ReconnectSwitchDisposition) !void {
        self.showConnectionReadyTitle();
        try self.drawReconnectReadyOverlay(disposition, 0);
    }

    pub fn handleConnectionEvent(self: *ReconnectUi, event: pb.ConnectionEvent) !void {
        switch (connection_event.classify(event)) {
            .ssh_stderr => |stderr| {
                client_log.appendSshStderr(stderr.data);
                try self.refreshOverlayIfDiagnosticsChanged();
            },
            .binary_bootstrapping => try self.drawStaticOverlay("sessh: bootstrapping..."),
            .daemon_connecting => try self.showDisconnectedReconnectInProgress(),
            .daemon_connected => _ = try self.clearOverlay(),
            .retry => |retry| try self.drawReconnectOverlay(retry.delay_ms),
            .ssh_connecting, .ssh_connected, .none => {},
        }
    }

    pub fn hasReconnectAcknowledgement(self: *const ReconnectUi) bool {
        return self.reconnect_input_state.hasReconnectAcknowledgement();
    }

    pub fn consumeReconnectAcknowledgement(self: *ReconnectUi) bool {
        return self.reconnect_input_state.consumeReconnectAcknowledgement();
    }

    pub fn reconnectSwitchDisposition(
        self: *const ReconnectUi,
        pending_input_at_disconnect: bool,
        pending_paste_like_input_at_disconnect: bool,
        unresponsive: bool,
    ) ReconnectSwitchDisposition {
        if (unresponsive) return .manual_unresponsive;
        if (pending_paste_like_input_at_disconnect) return .manual_disconnected;
        if (pending_input_at_disconnect or self.reconnect_input_state.input_during_disconnect) return .delayed;
        return .automatic;
    }

    pub fn waitForReconnectSwitch(self: *ReconnectUi, disposition: ReconnectSwitchDisposition) !ReconnectDecision {
        if (self.hasReconnectAcknowledgement()) return .reconnect_now;
        try self.showReconnectReady(disposition);
        while (true) {
            switch (try self.pollDecision(-1)) {
                .client_hangup => |decision| return decision,
                .reconnect_now => return .reconnect_now,
                .wait_elapsed => {},
            }
        }
    }

    pub fn waitForReconnectSwitchOrTimeout(self: *ReconnectUi, delay_ms: u64) !ReconnectDecision {
        if (self.hasReconnectAcknowledgement()) return .reconnect_now;
        try self.drawReconnectReadyOverlay(.delayed, delay_ms);
        var timer = try NonSuspendingTimer.start();
        var next_overlay_update_ms = diagnostics_display.nextOverlayUpdateDelayMs(delay_ms);

        while (true) {
            const elapsed_ms = elapsedTimerMs(&timer);
            if (elapsed_ms >= delay_ms) return .wait_elapsed;

            const next_wake_ms = @min(delay_ms, next_overlay_update_ms);
            const wait_ms: i32 = @intCast(@min(next_wake_ms - elapsed_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
            switch (try self.pollDecision(wait_ms)) {
                .client_hangup => |decision| return decision,
                .reconnect_now => return .reconnect_now,
                .wait_elapsed => {},
            }

            const after_poll_ms = elapsedTimerMs(&timer);
            if (after_poll_ms >= next_overlay_update_ms and after_poll_ms < delay_ms) {
                const remaining_ms = delay_ms - after_poll_ms;
                try self.drawReconnectReadyOverlay(.delayed, remaining_ms);
                next_overlay_update_ms = after_poll_ms + diagnostics_display.nextOverlayUpdateDelayMs(remaining_ms);
            }
        }
    }

    pub fn pollClientHangup(self: *ReconnectUi, timeout_ms: i32) !bool {
        const decision = try self.pollDecision(timeout_ms);
        return switch (decision) {
            .client_hangup => true,
            .reconnect_now, .wait_elapsed => false,
        };
    }

    pub fn pollDecision(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        if (self.isCancelled()) return .client_hangup;
        try self.refreshDisconnectedInputFlash();
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        const decision = try self.pollInput(timeout_ms);
        try self.refreshDisconnectedInputFlash();
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        return decision;
    }

    pub fn cancel(self: *ReconnectUi) void {
        self.cancelled = true;
    }

    pub fn isCancelled(self: *ReconnectUi) bool {
        return self.cancelled;
    }

    pub fn cancellationFlag(self: *const ReconnectUi) *const bool {
        return &self.cancelled;
    }

    pub fn consumeResizeForWorker(self: *ReconnectUi) bool {
        if (self.forwarded_resize_generation == self.resize_generation) return false;
        self.forwarded_resize_generation = self.resize_generation;
        return true;
    }

    pub fn refreshForResize(self: *ReconnectUi) !void {
        const size = terminal.currentWindowSize();
        if (size.rows == self.last_size.rows and size.cols == self.last_size.cols) return;
        self.last_size = size;
        self.resize_generation +%= 1;
        if (self.resize_generation == 0) self.resize_generation = 1;
        if (self.presentation != .overlay or c.isatty(self.output_fd) == 0) return;

        const renderer = client_renderer.Renderer.init(self.output_fd);
        try renderer.restorePresentation(terminal.queryInitialKittyKeyboardFlags(self.input_fd, self.output_fd));
        try renderer.clearVisible();
        self.overlay_state = null;
        self.viewport_offset = 0;
        if (self.overlay_message_len > 0) try self.drawCurrentOverlay();
    }

    fn pollInput(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        return self.reconnect_input_state.poll(
            self.input_fd,
            self.output_fd,
            self.diagnostic_notify_read_fd,
            timeout_ms,
            self.presentation == .overlay,
            self.nowMs(),
        );
    }

    fn refreshDisconnectedInputFlash(self: *ReconnectUi) !void {
        try self.reconnect_input_state.refreshDisconnectedInputFlash(self.output_fd, self.nowMs());
    }

    fn nowMs(self: *ReconnectUi) u64 {
        return self.clock.read() / std.time.ns_per_ms;
    }

    pub fn clearOverlay(self: *ReconnectUi) !i32 {
        if (self.presentation != .overlay) return @intCast(self.viewport_offset);
        if (c.isatty(self.output_fd) == 0) return @intCast(self.viewport_offset);
        const state = self.overlay_state orelse return @intCast(self.viewport_offset);
        const renderer = client_renderer.Renderer.init(self.output_fd);
        const size = terminal.currentWindowSize();
        try eraseOverlayRows(renderer, state, size.rows, size.cols);
        try restoreOverlayExpansion(renderer, state, size.rows);
        self.viewport_offset = clearedOverlayViewportOffset(state);
        self.overlay_state = null;
        try renderer.moveCursor(self.viewport_offset, 0);
        return @intCast(self.viewport_offset);
    }

    pub fn currentViewportOffset(self: *const ReconnectUi) i32 {
        return @intCast(self.viewport_offset);
    }

    fn drawReconnectOverlay(self: *ReconnectUi, delay_ms: u64) !void {
        self.showRetryTitle(delay_ms);
        if (self.appendOnlyPresentation()) {
            if (self.append_only_retry_announced) return;
            self.append_only_retry_announced = true;
            var message_buf: [192]u8 = undefined;
            const message = try diagnostics_display.appendOnlyRetryStatus(&message_buf, delay_ms, true);
            try self.drawStaticOverlay(message);
            return;
        }
        var status_buf: [96]u8 = undefined;
        const status = try reconnect_title.retryStatus(
            &status_buf,
            delay_ms,
            .{ .ctrl_r = true },
        );
        var message_buf: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buf, "--- {s} ---", .{status});
        try self.drawStaticOverlay(message);
    }

    fn drawReconnectReadyOverlay(self: *ReconnectUi, disposition: ReconnectSwitchDisposition, delay_ms: u64) !void {
        if (disposition == .delayed) self.showSwitchCountdownTitle(delay_ms);
        var message_buf: [128]u8 = undefined;
        const message = switch (disposition) {
            .delayed => blk: {
                var delay_buf: [16]u8 = undefined;
                const delay = try diagnostics_display.formatSwitchDelay(delay_ms, &delay_buf);
                break :blk try std.fmt.bufPrint(
                    &message_buf,
                    "--- sessh: disconnected: Connection ready. Switch {s}. CTRL-R now ---",
                    .{delay},
                );
            },
            .manual_disconnected => "--- sessh: disconnected: Connection ready. CTRL-R switch ---",
            .manual_unresponsive => "--- sessh: unresponsive: Connection ready. CTRL-R switch ---",
            .automatic => "--- sessh: disconnected: Connection ready. CTRL-R switch ---",
        };
        try self.drawStaticOverlay(message);
    }

    fn drawStaticOverlay(self: *ReconnectUi, message: []const u8) !void {
        const copy_len = @min(message.len, self.overlay_message.len);
        @memcpy(self.overlay_message[0..copy_len], message[0..copy_len]);
        self.overlay_message_len = copy_len;
        try self.consumeDiagnostics();
        try self.drawCurrentOverlay();
    }

    fn drawReconnectStaticOverlay(self: *ReconnectUi, status: []const u8) !void {
        var message_buf: [max_overlay_message_bytes]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buf, "--- {s} ---", .{status});
        try self.drawStaticOverlay(message);
    }

    fn drawCurrentOverlay(self: *ReconnectUi) !void {
        const message = self.overlay_message[0..self.overlay_message_len];
        switch (self.presentation) {
            .none, .title => return,
            .jsonl => {
                try diagnostics_display.writeJsonlStatus(self.line_fd, message);
                return;
            },
            .line => {
                try io_helpers.writeAll(self.line_fd, message);
                try io_helpers.writeAll(self.line_fd, "\r\n");
                return;
            },
            .overlay => {},
        }

        if (c.isatty(self.output_fd) == 0) {
            try io_helpers.writeAll(self.output_fd, "\r\n");
            try io_helpers.writeAll(self.output_fd, message);
            try io_helpers.writeAll(self.output_fd, "\r\n");
            for (self.diagnostic_lines[0..self.diagnostic_line_count]) |*line| {
                if (line.len == 0) continue;
                try io_helpers.writeAll(self.output_fd, line.slice());
                try io_helpers.writeAll(self.output_fd, "\r\n");
            }
            return;
        }

        const size = terminal.currentWindowSize();
        self.last_size = size;
        const max_visible_diagnostic_lines: usize = if (size.rows > 1)
            @min(max_diagnostic_overlay_lines, @as(usize, size.rows - 1))
        else
            0;
        const diagnostic_start = if (self.diagnostic_line_count > max_visible_diagnostic_lines)
            self.diagnostic_line_count - max_visible_diagnostic_lines
        else
            0;
        var overlay_lines: [1 + max_diagnostic_overlay_lines]OverlayLine = undefined;
        var overlay_line_count: usize = 0;
        overlay_lines[overlay_line_count] = .{ .text = message, .alignment = .center };
        overlay_line_count += 1;
        for (self.diagnostic_lines[diagnostic_start..self.diagnostic_line_count]) |*line| {
            overlay_lines[overlay_line_count] = .{ .text = line.slice(), .alignment = .left };
            overlay_line_count += 1;
        }
        const renderer = client_renderer.Renderer.init(self.output_fd);
        const state = try drawOverlayLines(renderer, size, self.viewport_offset, self.overlay_state, overlay_lines[0..overlay_line_count]);
        self.viewport_offset = state.viewport_offset;
        self.overlay_state = state;
    }

    pub fn refreshOverlayIfDiagnosticsChanged(self: *ReconnectUi) !void {
        if (self.overlay_message_len == 0) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;
        try self.consumeDiagnostics();
        if (self.appendOnlyPresentation()) return;
        try self.drawCurrentOverlay();
    }

    fn appendOnlyPresentation(self: *const ReconnectUi) bool {
        return self.presentation == .line or self.presentation == .jsonl;
    }

    fn consumeDiagnostics(self: *ReconnectUi) !void {
        var diagnostics = [_]client_log.UserDiagnosticLine{.{}} ** max_diagnostic_overlay_lines;
        const new_cursor = client_log.copyUserDiagnosticsSince(self.diagnostic_cursor, &diagnostics);
        if (new_cursor == self.diagnostic_cursor) {
            self.rendered_diagnostic_seq = new_cursor;
            return;
        }

        for (&diagnostics) |*diagnostic| {
            if (diagnostic.seq == 0) continue;
            switch (self.presentation) {
                .overlay => self.appendDiagnosticLine(diagnostic),
                .line => self.writePlainDiagnosticLine(diagnostic),
                .jsonl => self.writeJsonlDiagnostic(diagnostic),
                .title, .none => {},
            }
        }
        self.diagnostic_cursor = new_cursor;
        self.rendered_diagnostic_seq = new_cursor;
        client_log.markUserDiagnosticsDisplayedThrough(new_cursor);
    }

    fn writePlainDiagnosticLine(self: *ReconnectUi, diagnostic: *const client_log.UserDiagnosticLine) void {
        const delayed = diagnostic.seq <= self.live_diagnostic_start_seq;
        var line_buf: [client_log.max_user_diagnostic_display_bytes]u8 = undefined;
        const len = diagnostics_display.formatDiagnostic(line_buf[0..], diagnostic, delayed);
        io_helpers.writeAll(self.line_fd, line_buf[0..len]) catch return;
        io_helpers.writeAll(self.line_fd, "\r\n") catch {};
    }

    fn writeJsonlDiagnostic(self: *ReconnectUi, diagnostic: *const client_log.UserDiagnosticLine) void {
        diagnostics_display.writeJsonlDiagnostic(self.line_fd, diagnostic) catch return;
    }

    fn appendDiagnosticLine(self: *ReconnectUi, diagnostic: *const client_log.UserDiagnosticLine) void {
        if (self.diagnostic_line_count == self.diagnostic_lines.len) {
            var i: usize = 1;
            while (i < self.diagnostic_lines.len) : (i += 1) self.diagnostic_lines[i - 1] = self.diagnostic_lines[i];
            self.diagnostic_line_count -= 1;
        }
        const delayed = diagnostic.seq <= self.live_diagnostic_start_seq;
        const target = &self.diagnostic_lines[self.diagnostic_line_count];
        target.len = diagnostics_display.formatDiagnostic(target.bytes[0..], diagnostic, delayed);
        self.diagnostic_line_count += 1;
    }

    fn hideCursor(self: *ReconnectUi) !void {
        if (c.isatty(self.output_fd) == 0) return;
        try io_helpers.writeAll(self.output_fd, "\x1b[?25l");
        self.cursor_hidden = true;
    }

    fn showCursor(self: *ReconnectUi) !void {
        if (!self.cursor_hidden) return;
        self.cursor_hidden = false;
        try io_helpers.writeAll(self.output_fd, "\x1b[?25h");
    }

    pub fn restoreTitleAfterReconnect(self: *ReconnectUi, app_title_present: ?bool, fallback_title: []const u8) void {
        self.title_state.restoreAfterReconnect(app_title_present, fallback_title);
    }

    pub fn restoreTitleForEnd(self: *ReconnectUi) void {
        self.title_state.restoreForEnd();
    }

    fn showRetryTitle(self: *ReconnectUi, delay_ms: u64) void {
        self.title_state.showRetry(delay_ms);
    }

    fn showReconnectingTitle(self: *ReconnectUi) void {
        self.title_state.showReconnecting();
    }

    fn showReconnectingNowTitle(self: *ReconnectUi) void {
        self.title_state.showReconnectingNow();
    }

    fn showConnectionReadyTitle(self: *ReconnectUi) void {
        self.title_state.showConnectionReady();
    }

    fn showSwitchCountdownTitle(self: *ReconnectUi, delay_ms: u64) void {
        self.title_state.showSwitchCountdown(delay_ms);
    }
};

fn elapsedTimerMs(timer: *NonSuspendingTimer) u64 {
    return timer.read() / std.time.ns_per_ms;
}

test "ReconnectUi records resize event for terminal worker forwarding" {
    var ui = ReconnectUi{
        .mode_guard = undefined,
        .presentation = .none,
        .last_size = .{ .rows = 0, .cols = 0 },
    };

    try ui.refreshForResize();
    try std.testing.expect(ui.resize_generation != 0);
    try std.testing.expect(ui.consumeResizeForWorker());
    try std.testing.expect(!ui.consumeResizeForWorker());
}

test "ReconnectUi writes append-only diagnostics to configured line fd" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var ui = ReconnectUi{
        .mode_guard = undefined,
        .presentation = .line,
        .line_fd = fds[1],
        .input_fd = -1,
        .output_fd = -1,
    };
    try ui.drawReconnectOverlay(53_000);
    try ui.drawReconnectOverlay(52_000);
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [128]u8 = undefined;
        const n = c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "Retry connecting"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "retry_at_unix_ms=") != null);
}

test "ReconnectUi reads reconnect controls from configured input fd" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try io_helpers.writeAll(fds[1], &.{reconnect_control.ctrl_r});

    var ui = ReconnectUi{
        .mode_guard = undefined,
        .presentation = .none,
        .input_fd = fds[0],
        .output_fd = -1,
        .line_fd = -1,
    };

    try std.testing.expectEqual(ReconnectDecision.reconnect_now, try ui.pollDecision(0));
    try std.testing.expect(ui.hasReconnectAcknowledgement());
}

test "reconnect switch disposition distinguishes typing paste and unresponsive" {
    var ui = ReconnectUi{ .mode_guard = undefined };
    try std.testing.expectEqual(
        ReconnectSwitchDisposition.automatic,
        ui.reconnectSwitchDisposition(false, false, false),
    );
    try std.testing.expectEqual(
        ReconnectSwitchDisposition.delayed,
        ui.reconnectSwitchDisposition(true, false, false),
    );
    ui.reconnect_input_state.input_during_disconnect = true;
    try std.testing.expectEqual(
        ReconnectSwitchDisposition.delayed,
        ui.reconnectSwitchDisposition(false, false, false),
    );
    try std.testing.expectEqual(
        ReconnectSwitchDisposition.manual_disconnected,
        ui.reconnectSwitchDisposition(false, true, false),
    );
    try std.testing.expectEqual(
        ReconnectSwitchDisposition.manual_unresponsive,
        ui.reconnectSwitchDisposition(false, false, true),
    );
}
