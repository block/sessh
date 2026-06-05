const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const client_log = @import("../core/client_log.zig");
const client_renderer = @import("renderer.zig");
const io_helpers = @import("../core/io.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect_title = @import("../reconnect/title.zig");
const terminal = @import("../tty/terminal.zig");

const WindowSize = terminal.WindowSize;

pub const DetachOverlayArgs = struct {
    buf: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *DetachOverlayArgs, arg: []const u8) !void {
        if (self.len >= self.buf.len) return error.TooManyDetachOverlayArgs;
        self.buf[self.len] = arg;
        self.len += 1;
    }

    pub fn slice(self: *const DetachOverlayArgs) []const []const u8 {
        return self.buf[0..self.len];
    }
};

fn copyTitleFallback(dest: []u8, title: []const u8) usize {
    const len = @min(dest.len, title.len);
    @memcpy(dest[0..len], title[0..len]);
    return len;
}

pub const ReconnectPresentation = enum {
    none,
    stderr_plain,
    title,
    overlay,
};

pub const ReconnectDecision = enum {
    wait_elapsed,
    reconnect_now,
    detach,
    kill_detach,
    kill_wait,
};

pub const ReconnectSwitchDisposition = enum {
    automatic,
    delayed,
    manual_disconnected,
    manual_unresponsive,
};

pub const ReconnectUi = struct {
    const max_diagnostic_overlay_lines = 3;
    const max_overlay_message_bytes = 256;
    const max_title_fallback_bytes = 512;

    mode_guard: terminal.TerminalModeGuard,
    viewport_offset: u16 = 0,
    overlay_state: ?OverlayDrawState = null,
    overlay_message: [max_overlay_message_bytes]u8 = undefined,
    overlay_message_len: usize = 0,
    diagnostic_notify_read_fd: c.fd_t = -1,
    diagnostic_notify_write_fd: c.fd_t = -1,
    diagnostic_cursor: u64 = 0,
    live_diagnostic_start_seq: u64 = 0,
    rendered_diagnostic_seq: u64 = 0,
    diagnostic_lines: [max_diagnostic_overlay_lines]OverlayDiagnosticLine = [_]OverlayDiagnosticLine{.{}} ** max_diagnostic_overlay_lines,
    diagnostic_line_count: usize = 0,
    cursor_hidden: bool = false,
    reconnect_acknowledged: bool = false,
    input_during_disconnect: bool = false,
    kill_escape_filter: terminal.EscapeFilter = .{},
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    title_enabled: bool = false,
    title_fd: c.fd_t = 1,
    title_visible: bool = false,
    presentation: ReconnectPresentation = .overlay,
    cleanup_title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    cleanup_title_fallback_len: usize = 0,
    last_size: WindowSize = .{},
    resize_generation: u64 = 0,
    forwarded_resize_generation: u64 = 0,

    pub fn begin(viewport_offset: i32) !ReconnectUi {
        return beginWithPresentation(viewport_offset, .overlay);
    }

    pub fn beginWithPresentation(viewport_offset: i32, presentation: ReconnectPresentation) !ReconnectUi {
        var ui = ReconnectUi{
            .mode_guard = try terminal.TerminalModeGuard.enable(0),
            .title_enabled = (presentation == .overlay or presentation == .title) and c.isatty(1) != 0,
            .presentation = presentation,
            .last_size = terminal.currentWindowSize(),
        };
        errdefer ui.mode_guard.restore();
        ui.viewport_offset = if (viewport_offset > 0) @intCast(viewport_offset) else 0;
        if (ui.title_enabled) {
            const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
            if (cleanup_title) |title| {
                defer app_allocator.allocator().free(title);
                ui.cleanup_title_fallback_len = copyTitleFallback(&ui.cleanup_title_fallback, title);
            }
        }
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
        try setNonBlocking(ui.diagnostic_notify_read_fd);
        try setNonBlocking(ui.diagnostic_notify_write_fd);
        client_log.registerUserDiagnosticNotifier(ui.diagnostic_notify_write_fd);
        errdefer client_log.unregisterUserDiagnosticNotifier(ui.diagnostic_notify_write_fd);
        try ui.consumeDiagnostics();
        if (presentation == .overlay) try ui.hideCursor();
        return ui;
    }

    pub fn deinit(self: *ReconnectUi) void {
        self.restoreTitleForDetach();
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
        try self.drawReconnectOverlay(delay_ms);
        var timer = try std.time.Timer.start();
        var next_overlay_update_ms = nextOverlayUpdateDelayMs(delay_ms);

        while (true) {
            const elapsed_ms = elapsedTimerMs(&timer);
            if (elapsed_ms >= delay_ms) {
                self.showReconnectingTitle();
                try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
                return .wait_elapsed;
            }

            const next_wake_ms = @min(delay_ms, next_overlay_update_ms);
            const wait_ms: i32 = @intCast(@min(next_wake_ms - elapsed_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
            const decision = try self.pollInput(wait_ms);
            try self.refreshForResize();
            try self.refreshOverlayIfDiagnosticsChanged();
            switch (decision) {
                .detach, .kill_detach, .kill_wait => return decision,
                .reconnect_now => {
                    self.showReconnectingTitle();
                    try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
                    return .reconnect_now;
                },
                .wait_elapsed => {},
            }

            const after_poll_ms = elapsedTimerMs(&timer);
            if (after_poll_ms >= next_overlay_update_ms and after_poll_ms < delay_ms) {
                const remaining_ms = delay_ms - after_poll_ms;
                try self.drawReconnectOverlay(remaining_ms);
                next_overlay_update_ms = after_poll_ms + nextOverlayUpdateDelayMs(remaining_ms);
            }
        }
    }

    pub fn showDisconnectedReconnectInProgress(self: *ReconnectUi) !void {
        self.showReconnectingTitle();
        try self.drawReconnectStaticOverlay(reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
    }

    pub fn showKillingRemoteSession(self: *ReconnectUi) !void {
        self.showKillingTitle();
        try self.drawStaticOverlay("--- Killing remote session. ~. to detach immediately ---");
    }

    pub fn waitForKillConfirmation(self: *ReconnectUi, delay_ms: u64) !ReconnectDecision {
        try self.showKillingRemoteSession();
        var timer = try std.time.Timer.start();
        while (true) {
            const elapsed_ms = elapsedTimerMs(&timer);
            if (elapsed_ms >= delay_ms) return .wait_elapsed;
            const wait_ms: i32 = @intCast(@min(delay_ms - elapsed_ms, @as(u64, 50)));
            switch (try self.pollKillingDecision(wait_ms)) {
                .detach, .kill_detach, .kill_wait => |decision| return decision,
                .reconnect_now => unreachable,
                .wait_elapsed => {},
            }
        }
    }

    pub fn showUnresponsiveReconnectInProgressTitle(self: *ReconnectUi) void {
        self.showReconnectingNowTitle();
    }

    pub fn showReconnectReady(self: *ReconnectUi, disposition: ReconnectSwitchDisposition) !void {
        self.showConnectionReadyTitle();
        try self.drawReconnectReadyOverlay(disposition, 0);
    }

    pub fn hasReconnectAcknowledgement(self: *const ReconnectUi) bool {
        return self.reconnect_acknowledged;
    }

    pub fn consumeReconnectAcknowledgement(self: *ReconnectUi) bool {
        const acknowledged = self.reconnect_acknowledged;
        self.reconnect_acknowledged = false;
        return acknowledged;
    }

    pub fn reconnectSwitchDisposition(
        self: *const ReconnectUi,
        pending_input_at_disconnect: bool,
        pending_paste_like_input_at_disconnect: bool,
        unresponsive: bool,
    ) ReconnectSwitchDisposition {
        if (unresponsive) return .manual_unresponsive;
        if (pending_paste_like_input_at_disconnect) return .manual_disconnected;
        if (pending_input_at_disconnect or self.input_during_disconnect) return .delayed;
        return .automatic;
    }

    pub fn waitForReconnectSwitch(self: *ReconnectUi, disposition: ReconnectSwitchDisposition) !ReconnectDecision {
        if (self.hasReconnectAcknowledgement()) return .reconnect_now;
        try self.showReconnectReady(disposition);
        while (true) {
            switch (try self.pollDecision(-1)) {
                .detach, .kill_detach, .kill_wait => |decision| return decision,
                .reconnect_now => return .reconnect_now,
                .wait_elapsed => {},
            }
        }
    }

    pub fn waitForReconnectSwitchOrTimeout(self: *ReconnectUi, delay_ms: u64) !ReconnectDecision {
        if (self.hasReconnectAcknowledgement()) return .reconnect_now;
        try self.drawReconnectReadyOverlay(.delayed, delay_ms);
        var timer = try std.time.Timer.start();
        var next_overlay_update_ms = nextOverlayUpdateDelayMs(delay_ms);

        while (true) {
            const elapsed_ms = elapsedTimerMs(&timer);
            if (elapsed_ms >= delay_ms) return .wait_elapsed;

            const next_wake_ms = @min(delay_ms, next_overlay_update_ms);
            const wait_ms: i32 = @intCast(@min(next_wake_ms - elapsed_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
            switch (try self.pollDecision(wait_ms)) {
                .detach, .kill_detach, .kill_wait => |decision| return decision,
                .reconnect_now => return .reconnect_now,
                .wait_elapsed => {},
            }

            const after_poll_ms = elapsedTimerMs(&timer);
            if (after_poll_ms >= next_overlay_update_ms and after_poll_ms < delay_ms) {
                const remaining_ms = delay_ms - after_poll_ms;
                try self.drawReconnectReadyOverlay(.delayed, remaining_ms);
                next_overlay_update_ms = after_poll_ms + nextOverlayUpdateDelayMs(remaining_ms);
            }
        }
    }

    pub fn pollDetach(self: *ReconnectUi, timeout_ms: i32) !bool {
        const decision = try self.pollDecision(timeout_ms);
        return switch (decision) {
            .detach, .kill_detach, .kill_wait => true,
            .reconnect_now, .wait_elapsed => false,
        };
    }

    pub fn pollDecision(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        if (self.isCancelled()) return .detach;
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        const decision = try self.pollInput(timeout_ms);
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        return decision;
    }

    pub fn pollKillingDecision(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        if (self.isCancelled()) return .detach;
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        const decision = try self.pollKillingInput(timeout_ms);
        try self.refreshForResize();
        try self.refreshOverlayIfDiagnosticsChanged();
        return decision;
    }

    pub fn cancel(self: *ReconnectUi) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *ReconnectUi) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancellationFlag(self: *const ReconnectUi) *const std.atomic.Value(bool) {
        return &self.cancelled;
    }

    pub fn consumeResizeForRuntime(self: *ReconnectUi) bool {
        if (self.forwarded_resize_generation == self.resize_generation) return false;
        self.forwarded_resize_generation = self.resize_generation;
        return true;
    }

    fn effectivePollTimeout(self: *const ReconnectUi, timeout_ms: i32) i32 {
        if (timeout_ms >= 0) return timeout_ms;
        if (self.presentation != .overlay) return timeout_ms;
        return 250;
    }

    pub fn refreshForResize(self: *ReconnectUi) !void {
        const size = terminal.currentWindowSize();
        if (size.rows == self.last_size.rows and size.cols == self.last_size.cols) return;
        self.last_size = size;
        self.resize_generation +%= 1;
        if (self.resize_generation == 0) self.resize_generation = 1;
        if (self.presentation != .overlay or c.isatty(1) == 0) return;

        const renderer = client_renderer.Renderer.init(1);
        try renderer.restorePresentation(queryInitialKittyKeyboardFlags());
        try renderer.clearVisible();
        self.overlay_state = null;
        self.viewport_offset = 0;
        if (self.overlay_message_len > 0) try self.drawCurrentOverlay();
    }

    fn pollInput(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = 0,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.diagnostic_notify_read_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const poll_count: usize = if (self.diagnostic_notify_read_fd >= 0) 2 else 1;
        const ready = try posix.poll(pollfds[0..poll_count], self.effectivePollTimeout(timeout_ms));
        if (ready == 0) return .wait_elapsed;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .detach;
        if (poll_count > 1 and (pollfds[1].revents & posix.POLL.IN) != 0) {
            self.drainDiagnosticNotifier();
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(0, &input, input.len);
        if (n <= 0) return .detach;
        io_helpers.noteRead(0, input[0..@intCast(n)]);

        const bytes = input[0..@intCast(n)];
        switch (reconnect_control.scanInput(bytes, .{ .ctrl_c_detaches = true })) {
            .detach => return .detach,
            .reconnect_now => {
                self.reconnect_acknowledged = true;
                return .reconnect_now;
            },
            .none => {},
        }
        const result = self.kill_escape_filter.filter(bytes, &filtered);
        if (result.end) |end| switch (end) {
            .detach => return .detach,
            .kill => return .kill_detach,
            .kill_wait => return .kill_wait,
            .help => {},
            .repaint => {},
        };
        if (bytes.len > 0) {
            self.input_during_disconnect = true;
            try self.alertDisconnectedInput();
        }
        return .wait_elapsed;
    }

    fn pollKillingInput(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = 0,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.diagnostic_notify_read_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const poll_count: usize = if (self.diagnostic_notify_read_fd >= 0) 2 else 1;
        const ready = try posix.poll(pollfds[0..poll_count], self.effectivePollTimeout(timeout_ms));
        if (ready == 0) return .wait_elapsed;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .detach;
        if (poll_count > 1 and (pollfds[1].revents & posix.POLL.IN) != 0) {
            self.drainDiagnosticNotifier();
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(0, &input, input.len);
        if (n <= 0) return .detach;
        const bytes = input[0..@intCast(n)];
        io_helpers.noteRead(0, bytes);
        const result = self.kill_escape_filter.filter(bytes, &filtered);
        if (result.end) |end| switch (end) {
            .detach, .kill => return .detach,
            .kill_wait => return .kill_wait,
            .help => {},
            .repaint => {},
        };
        if (bytes.len > 0) try self.alertDisconnectedInput();
        return .wait_elapsed;
    }

    fn alertDisconnectedInput(self: *ReconnectUi) !void {
        _ = self;
        try io_helpers.writeAll(1, "\x07");
        if (c.isatty(1) == 0) return;
        try io_helpers.writeAll(1, "\x1b[?5h");
        defer io_helpers.writeAll(1, "\x1b[?5l") catch {};
        std.Thread.sleep(35 * std.time.ns_per_ms);
    }

    pub fn clearOverlay(self: *ReconnectUi) !i32 {
        if (self.presentation != .overlay) return @intCast(self.viewport_offset);
        if (c.isatty(1) == 0) return @intCast(self.viewport_offset);
        const state = self.overlay_state orelse return @intCast(self.viewport_offset);
        const renderer = client_renderer.Renderer.init(1);
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
        var status_buf: [96]u8 = undefined;
        const status = try reconnect_title.retryStatus(
            &status_buf,
            delay_ms,
            .{ .ctrl_r = true, .ctrl_c_detach = true },
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
                const delay = try formatSwitchDelay(delay_ms, &delay_buf);
                break :blk try std.fmt.bufPrint(
                    &message_buf,
                    "--- sessh: disconnected: Connection ready. Switch {s}. CTRL-R now. CTRL-C detach ---",
                    .{delay},
                );
            },
            .manual_disconnected => "--- sessh: disconnected: Connection ready. CTRL-R switch. CTRL-C detach ---",
            .manual_unresponsive => "--- sessh: unresponsive: Connection ready. CTRL-R switch. CTRL-C detach ---",
            .automatic => "--- sessh: disconnected: Connection ready. CTRL-R switch. CTRL-C detach ---",
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
            .stderr_plain => {
                try io_helpers.writeAll(2, message);
                try io_helpers.writeAll(2, "\r\n");
                return;
            },
            .overlay => {},
        }

        if (c.isatty(1) == 0) {
            try io_helpers.writeAll(1, "\r\n");
            try io_helpers.writeAll(1, message);
            try io_helpers.writeAll(1, "\r\n");
            for (self.diagnostic_lines[0..self.diagnostic_line_count]) |*line| {
                if (line.len == 0) continue;
                try io_helpers.writeAll(1, line.slice());
                try io_helpers.writeAll(1, "\r\n");
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
        const renderer = client_renderer.Renderer.init(1);
        const state = try drawOverlayLines(renderer, size, self.viewport_offset, self.overlay_state, overlay_lines[0..overlay_line_count]);
        self.viewport_offset = state.viewport_offset;
        self.overlay_state = state;
    }

    pub fn refreshOverlayIfDiagnosticsChanged(self: *ReconnectUi) !void {
        if (self.overlay_message_len == 0) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;
        try self.consumeDiagnostics();
        try self.drawCurrentOverlay();
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
                .stderr_plain => self.writePlainDiagnosticLine(diagnostic),
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
        const len = formatOverlayDiagnostic(line_buf[0..], diagnostic, delayed);
        io_helpers.writeAll(2, line_buf[0..len]) catch return;
        io_helpers.writeAll(2, "\r\n") catch {};
    }

    fn appendDiagnosticLine(self: *ReconnectUi, diagnostic: *const client_log.UserDiagnosticLine) void {
        if (self.diagnostic_line_count == self.diagnostic_lines.len) {
            var i: usize = 1;
            while (i < self.diagnostic_lines.len) : (i += 1) self.diagnostic_lines[i - 1] = self.diagnostic_lines[i];
            self.diagnostic_line_count -= 1;
        }
        const delayed = diagnostic.seq <= self.live_diagnostic_start_seq;
        const target = &self.diagnostic_lines[self.diagnostic_line_count];
        target.len = formatOverlayDiagnostic(target.bytes[0..], diagnostic, delayed);
        self.diagnostic_line_count += 1;
    }

    fn drainDiagnosticNotifier(self: *ReconnectUi) void {
        if (self.diagnostic_notify_read_fd < 0) return;
        var buf: [128]u8 = undefined;
        while (true) {
            const n = c.read(self.diagnostic_notify_read_fd, &buf, buf.len);
            if (n > 0) continue;
            if (n == 0) return;
            switch (posix.errno(n)) {
                .AGAIN => return,
                .INTR => continue,
                else => return,
            }
        }
    }

    fn hideCursor(self: *ReconnectUi) !void {
        if (c.isatty(1) == 0) return;
        try io_helpers.writeAll(1, "\x1b[?25l");
        self.cursor_hidden = true;
    }

    fn showCursor(self: *ReconnectUi) !void {
        if (!self.cursor_hidden) return;
        self.cursor_hidden = false;
        try io_helpers.writeAll(1, "\x1b[?25h");
    }

    pub fn restoreTitleAfterReconnect(self: *ReconnectUi, app_title_present: ?bool, fallback_title: []const u8) void {
        if (!self.title_visible) return;
        if (app_title_present != true) {
            self.restoreTitleTo(fallback_title);
        }
        self.title_visible = false;
    }

    pub fn restoreTitleForDetach(self: *ReconnectUi) void {
        if (!self.title_visible) return;
        self.restoreTitleTo(self.cleanupTitleFallback());
        self.title_visible = false;
    }

    fn showRetryTitle(self: *ReconnectUi, delay_ms: u64) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeRetryNowTitle(self.title_fd, delay_ms) catch return;
        self.title_visible = true;
    }

    fn showReconnectingTitle(self: *ReconnectUi) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeReconnectingTitle(self.title_fd) catch return;
        self.title_visible = true;
    }

    fn showReconnectingNowTitle(self: *ReconnectUi) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeReconnectingNowTitle(self.title_fd) catch return;
        self.title_visible = true;
    }

    fn showConnectionReadyTitle(self: *ReconnectUi) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeConnectionReadyTitle(self.title_fd) catch return;
        self.title_visible = true;
    }

    fn showKillingTitle(self: *ReconnectUi) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeTitle(self.title_fd, "killing remote session") catch return;
        self.title_visible = true;
    }

    fn showSwitchCountdownTitle(self: *ReconnectUi, delay_ms: u64) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeSwitchCountdownTitle(self.title_fd, delay_ms) catch return;
        self.title_visible = true;
    }

    fn restoreTitleTo(self: *ReconnectUi, title: []const u8) void {
        if (!self.title_enabled or self.title_fd < 0) return;
        reconnect_title.writeTitle(self.title_fd, title) catch {};
    }

    fn cleanupTitleFallback(self: *const ReconnectUi) []const u8 {
        return self.cleanup_title_fallback[0..self.cleanup_title_fallback_len];
    }
};

pub const OverlayAlign = enum {
    left,
    center,
};

pub const OverlayLine = struct {
    text: []const u8,
    alignment: OverlayAlign,
};

const OverlayDiagnosticLine = struct {
    bytes: [client_log.max_user_diagnostic_display_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const OverlayDiagnosticLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

const max_overlay_diagnostic_line_count = 1 + ReconnectUi.max_diagnostic_overlay_lines;
const max_overlay_line_count = if (max_overlay_diagnostic_line_count > terminal.escape_help_overlay_lines.len)
    max_overlay_diagnostic_line_count
else
    terminal.escape_help_overlay_lines.len;
const max_overlay_render_line_bytes = if (ReconnectUi.max_overlay_message_bytes > client_log.max_user_diagnostic_display_bytes)
    ReconnectUi.max_overlay_message_bytes
else
    client_log.max_user_diagnostic_display_bytes;

comptime {
    std.debug.assert(max_overlay_line_count >= terminal.escape_help_overlay_lines.len);
    for (terminal.escape_help_overlay_lines) |line| {
        std.debug.assert(max_overlay_render_line_bytes >= line.len);
    }
}

const RenderedOverlayLine = struct {
    start_col: u16 = 0,
    len: u16 = 0,
    bytes: [max_overlay_render_line_bytes]u8 = undefined,

    fn slice(self: *const RenderedOverlayLine) []const u8 {
        return self.bytes[0..self.len];
    }

    fn endCol(self: *const RenderedOverlayLine) u16 {
        return self.start_col + self.len;
    }

    fn eql(self: *const RenderedOverlayLine, other: *const RenderedOverlayLine) bool {
        return self.start_col == other.start_col and
            self.len == other.len and
            std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const OverlayDrawState = struct {
    rows: u16,
    cols: u16,
    start_row: u16,
    line_count: u16,
    viewport_offset: u16,
    restore_viewport_offset: u16,
    scroll_top: u16,
    scroll_lines: u16,
    restores_expansion: bool = true,
    lines: [max_overlay_line_count]RenderedOverlayLine = [_]RenderedOverlayLine{.{}} ** max_overlay_line_count,
};

const OverlayLayout = struct {
    start_row: u16,
    visible_line_count: u16,
    scroll_lines: u16,
    viewport_offset: u16,
};

pub fn drawOverlayLines(
    renderer: client_renderer.Renderer,
    size: WindowSize,
    viewport_offset: u16,
    previous: ?OverlayDrawState,
    lines: []const OverlayLine,
) !OverlayDrawState {
    const terminal_rows = normalizedTerminalRows(size.rows);
    if (lines.len == 0) {
        if (previous) |state| try eraseOverlayRows(renderer, state, terminal_rows, size.cols);
        if (previous) |state| try restoreOverlayExpansion(renderer, state, terminal_rows);
        const restored_viewport_offset = if (previous) |state| clearedOverlayViewportOffset(state) else viewport_offset;
        return .{
            .rows = terminal_rows,
            .cols = size.cols,
            .start_row = 0,
            .line_count = 0,
            .viewport_offset = restored_viewport_offset,
            .restore_viewport_offset = restored_viewport_offset,
            .scroll_top = restored_viewport_offset,
            .scroll_lines = 0,
        };
    }

    const layout = overlayLayoutForSize(terminal_rows, viewport_offset, lines.len);
    const clamped_viewport_offset = @min(viewport_offset, terminal_rows - 1);
    const prior_scroll_lines = if (previous) |state| state.scroll_lines else 0;
    const restore_viewport_offset = if (previous) |state| state.restore_viewport_offset else clamped_viewport_offset;
    const scroll_lines = prior_scroll_lines +| layout.scroll_lines;
    const consumes_outer_rows = layout.scroll_lines > 0 and layout.viewport_offset < restore_viewport_offset;
    const restores_expansion = (if (previous) |state| state.restores_expansion else true) and !consumes_outer_rows;
    var next_state = OverlayDrawState{
        .rows = terminal_rows,
        .cols = size.cols,
        .start_row = layout.start_row,
        .line_count = layout.visible_line_count,
        .viewport_offset = layout.viewport_offset,
        .restore_viewport_offset = restore_viewport_offset,
        .scroll_top = layout.viewport_offset,
        .scroll_lines = scroll_lines,
        .restores_expansion = restores_expansion,
    };
    var row_offset: u16 = 0;
    while (row_offset < layout.visible_line_count) : (row_offset += 1) {
        next_state.lines[row_offset] = renderOverlayLine(size.cols, lines[row_offset]);
    }

    const can_update_in_place = if (previous) |state|
        layout.scroll_lines == 0 and
            state.rows == terminal_rows and
            state.cols == size.cols and
            state.start_row == layout.start_row
    else
        false;

    if (!can_update_in_place) {
        if (previous) |state| try eraseOverlayRows(renderer, state, terminal_rows, size.cols);
    }
    if (layout.scroll_lines > 0) {
        if (restores_expansion) {
            try expandOverlayRegion(renderer, layout.viewport_offset, terminal_rows, layout.scroll_lines);
        } else {
            try expandOverlayByScrollingTerminal(renderer, terminal_rows, layout.scroll_lines);
        }
    }

    row_offset = 0;
    while (row_offset < layout.visible_line_count) : (row_offset += 1) {
        const old_line = if (can_update_in_place and row_offset < previous.?.line_count)
            previous.?.lines[row_offset]
        else
            null;
        if (old_line) |line| {
            if (next_state.lines[row_offset].eql(&line)) continue;
        }
        try drawRenderedOverlayLine(
            renderer,
            layout.start_row + row_offset,
            size.cols,
            next_state.lines[row_offset],
            old_line,
            old_line == null,
        );
    }
    if (can_update_in_place) {
        row_offset = layout.visible_line_count;
        while (row_offset < previous.?.line_count) : (row_offset += 1) {
            try eraseRenderedOverlayLine(renderer, layout.start_row + row_offset, size.cols, previous.?.lines[row_offset]);
        }
    }
    try renderer.restoreOverlayPresentation();
    try renderer.moveCursor(layout.viewport_offset, 0);
    return next_state;
}

pub fn clearedOverlayViewportOffset(self: OverlayDrawState) u16 {
    return if (self.restores_expansion) self.restore_viewport_offset else self.viewport_offset;
}

pub fn eraseOverlayRows(renderer: client_renderer.Renderer, state: OverlayDrawState, rows: u16, cols: u16) !void {
    const terminal_rows = normalizedTerminalRows(rows);
    try renderer.restoreOverlayPresentation();
    var i: u16 = 0;
    while (i < state.line_count) : (i += 1) {
        const row = state.start_row +| i;
        if (row >= terminal_rows) break;
        try eraseRenderedOverlayLine(renderer, row, cols, state.lines[i]);
    }
}

fn expandOverlayRegion(renderer: client_renderer.Renderer, top: u16, rows: u16, count: u16) !void {
    if (count == 0) return;
    const terminal_rows = normalizedTerminalRows(rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.setScrollRegion(top, bottom);
    try renderer.moveCursor(bottom, 0);
    var i: u16 = 0;
    while (i < count) : (i += 1) try renderer.newline();
    try renderer.resetScrollRegion();
}

fn expandOverlayByScrollingTerminal(renderer: client_renderer.Renderer, rows: u16, count: u16) !void {
    if (count == 0) return;
    const terminal_rows = normalizedTerminalRows(rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.moveCursor(bottom, 0);
    var i: u16 = 0;
    while (i < count) : (i += 1) try renderer.newline();
}

pub fn restoreOverlayExpansion(renderer: client_renderer.Renderer, state: OverlayDrawState, rows: u16) !void {
    if (state.scroll_lines == 0) return;
    if (!state.restores_expansion) return;
    const terminal_rows = normalizedTerminalRows(rows);
    if (terminal_rows != state.rows) return;
    const bottom = terminal_rows - 1;
    try renderer.restoreOverlayPresentation();
    try renderer.setScrollRegion(state.scroll_top, bottom);
    try renderer.moveCursor(state.scroll_top, 0);
    var i: u16 = 0;
    while (i < state.scroll_lines) : (i += 1) try renderer.reverseIndex();
    try renderer.resetScrollRegion();
}

fn renderOverlayLine(cols: u16, line: OverlayLine) RenderedOverlayLine {
    const visible_len = @min(@min(line.text.len, @as(usize, cols)), max_overlay_render_line_bytes);
    const col: u16 = switch (line.alignment) {
        .left => 0,
        .center => if (cols > visible_len)
            @intCast((@as(usize, cols) - visible_len) / 2)
        else
            0,
    };
    var rendered = RenderedOverlayLine{
        .start_col = col,
        .len = @intCast(visible_len),
    };
    for (line.text[0..visible_len], 0..) |byte, i| {
        rendered.bytes[i] = overlaySafeByte(byte);
    }
    return rendered;
}

fn drawRenderedOverlayLine(
    renderer: client_renderer.Renderer,
    row: u16,
    cols: u16,
    line: RenderedOverlayLine,
    previous: ?RenderedOverlayLine,
    clear_full_row: bool,
) !void {
    if (cols == 0) return;
    const line_end = line.endCol();
    var cover_start: u16 = if (clear_full_row) 0 else line.start_col;
    var cover_end: u16 = if (clear_full_row) cols else line_end;
    if (!clear_full_row) {
        if (previous) |old| {
            cover_start = @min(cover_start, old.start_col);
            cover_end = @max(cover_end, old.endCol());
        }
    }
    if (cover_end <= cover_start) return;

    try renderer.moveCursor(row, cover_start);
    try renderer.restoreOverlayPresentation();
    try writeSpaces(renderer, line.start_col - cover_start);
    try renderer.writeRaw("\x1b[7m");
    try renderer.writeRaw(line.slice());
    try renderer.writeRaw("\x1b[0m");
    try writeSpaces(renderer, cover_end - line_end);
}

fn eraseRenderedOverlayLine(renderer: client_renderer.Renderer, row: u16, cols: u16, line: RenderedOverlayLine) !void {
    const start_col = @min(line.start_col, cols);
    const end_col = @min(line.endCol(), cols);
    if (end_col <= start_col) return;
    try renderer.moveCursor(row, start_col);
    try renderer.restoreOverlayPresentation();
    try writeSpaces(renderer, end_col - start_col);
}

fn writeSpaces(renderer: client_renderer.Renderer, count: usize) !void {
    const spaces = "                                                                ";
    var remaining = count;
    while (remaining > 0) {
        const n = @min(remaining, spaces.len);
        try renderer.writeRaw(spaces[0..n]);
        remaining -= n;
    }
}

fn overlaySafeByte(byte: u8) u8 {
    return switch (byte) {
        ' '...'~' => byte,
        else => '?',
    };
}

fn normalizedTerminalRows(rows: u16) u16 {
    return if (rows == 0) 1 else rows;
}

fn overlayLayoutForSize(rows: u16, top_row: u16, line_count: usize) OverlayLayout {
    const terminal_rows = normalizedTerminalRows(rows);
    const visible_line_count: u16 = @intCast(@min(line_count, @as(usize, terminal_rows)));
    if (visible_line_count == 0) {
        const viewport_offset = @min(top_row, terminal_rows - 1);
        return .{ .start_row = viewport_offset, .visible_line_count = 0, .scroll_lines = 0, .viewport_offset = viewport_offset };
    }

    const clamped_top = @min(top_row, terminal_rows - 1);
    const preferred_start = @as(usize, clamped_top) + 1;
    const preferred_end = preferred_start + @as(usize, visible_line_count);
    if (preferred_end <= terminal_rows) {
        return .{
            .start_row = @intCast(preferred_start),
            .visible_line_count = visible_line_count,
            .scroll_lines = 0,
            .viewport_offset = clamped_top,
        };
    }

    const scroll_lines: u16 = @intCast(@min(preferred_end - terminal_rows, @as(usize, std.math.maxInt(u16))));
    const consumed_top = @min(clamped_top, scroll_lines);
    return .{
        .start_row = terminal_rows - visible_line_count,
        .visible_line_count = visible_line_count,
        .scroll_lines = scroll_lines,
        .viewport_offset = clamped_top - consumed_top,
    };
}

fn countSubstrings(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

fn formatOverlayDiagnostic(
    out: []u8,
    diagnostic: *const client_log.UserDiagnosticLine,
    delayed: bool,
) usize {
    var stream = std.io.fixedBufferStream(out);
    const writer = stream.writer();
    if (delayed) {
        writer.print("{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms }) catch return stream.pos;
    } else {
        writer.print("{s}: ", .{diagnostic.tag.label()}) catch return stream.pos;
    }
    writer.writeAll(diagnostic.slice()) catch {};
    return stream.pos;
}

fn setNonBlocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

var cached_initial_kitty_keyboard_flags: ?u5 = null;

pub fn queryInitialKittyKeyboardFlags() u5 {
    if (cached_initial_kitty_keyboard_flags) |flags| return flags;

    // Reconnects keep using the same outer terminal. Querying it again after
    // the reconnect overlay clears can race with typed-ahead input and consume
    // those bytes as probe responses.
    const flags = (terminal.queryKittyKeyboardFlags(0, 1) catch null) orelse 0;
    cached_initial_kitty_keyboard_flags = flags;
    return flags;
}

fn formatDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    return reconnect_title.formatDelay(delay_ms, buf);
}

fn formatSwitchDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    const seconds = @max(@divTrunc(delay_ms + 999, 1000), 1);
    return std.fmt.bufPrint(buf, "{}sec", .{seconds});
}

fn nextOverlayUpdateDelayMs(remaining_ms: u64) u64 {
    if (remaining_ms <= 1_000) return remaining_ms;
    if (remaining_ms <= 60_000) return 1_000;
    return @min(remaining_ms - 59_000, 60_000);
}

fn elapsedTimerMs(timer: *std.time.Timer) u64 {
    return timer.read() / std.time.ns_per_ms;
}
test "formatDelay uses compact reconnect labels" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("5sec", try formatDelay(5_000, &buf));
    try std.testing.expectEqualStrings("20sec", try formatDelay(20_000, &buf));
    try std.testing.expectEqualStrings("1min", try formatDelay(60_000, &buf));
    try std.testing.expectEqualStrings("10min", try formatDelay(600_000, &buf));
    try std.testing.expectEqualStrings("60sec", try formatSwitchDelay(60_000, &buf));
}

test "ReconnectUi restores remote fallback title when no app title is present" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var ui = ReconnectUi{
        .mode_guard = undefined,
        .title_enabled = true,
        .title_fd = fds[1],
    };
    ui.showRetryTitle(5_000);
    ui.restoreTitleAfterReconnect(false, "work.blox");
    posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b]2;5sec retry CTRL-R\x1b\\\x1b]2;work.blox\x1b\\",
        buf[0..n],
    );
    try std.testing.expect(!ui.title_visible);
}

test "ReconnectUi leaves restored app title alone after reconnect repaint" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var ui = ReconnectUi{
        .mode_guard = undefined,
        .title_enabled = true,
        .title_fd = fds[1],
    };
    ui.showRetryTitle(5_000);
    ui.restoreTitleAfterReconnect(true, "work.blox");
    posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("\x1b]2;5sec retry CTRL-R\x1b\\", buf[0..n]);
    try std.testing.expect(!ui.title_visible);
}

test "ReconnectUi restores local cleanup title on detach" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var ui = ReconnectUi{
        .mode_guard = undefined,
        .title_enabled = true,
        .title_fd = fds[1],
    };
    ui.cleanup_title_fallback_len = copyTitleFallback(&ui.cleanup_title_fallback, "/tmp/local");
    ui.showRetryTitle(5_000);
    ui.restoreTitleForDetach();
    posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b]2;5sec retry CTRL-R\x1b\\\x1b]2;/tmp/local\x1b\\",
        buf[0..n],
    );
    try std.testing.expect(!ui.title_visible);
}

test "ReconnectUi records resize event for runtime forwarding" {
    var ui = ReconnectUi{
        .mode_guard = undefined,
        .presentation = .none,
        .last_size = .{ .rows = 0, .cols = 0 },
    };

    try ui.refreshForResize();
    try std.testing.expect(ui.resize_generation != 0);
    try std.testing.expect(ui.consumeResizeForRuntime());
    try std.testing.expect(!ui.consumeResizeForRuntime());
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
    ui.input_during_disconnect = true;
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

test "reconnect overlay layout adds rows at terminal bottom" {
    const single = overlayLayoutForSize(1, 0, 1);
    try std.testing.expectEqual(@as(u16, 0), single.start_row);
    try std.testing.expectEqual(@as(u16, 1), single.visible_line_count);
    try std.testing.expectEqual(@as(u16, 1), single.scroll_lines);

    const normal = overlayLayoutForSize(24, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), normal.start_row);
    try std.testing.expectEqual(@as(u16, 0), normal.scroll_lines);

    const bottom = overlayLayoutForSize(24, 23, 1);
    try std.testing.expectEqual(@as(u16, 23), bottom.start_row);
    try std.testing.expectEqual(@as(u16, 1), bottom.scroll_lines);
    try std.testing.expectEqual(@as(u16, 22), bottom.viewport_offset);
}

test "reconnect overlay draws clipped multiline content and pads stale rows" {
    var single_row = std.ArrayList(u8).empty;
    defer single_row.deinit(std.testing.allocator);
    const single_renderer = client_renderer.Renderer.buffered(&single_row, .{ .kind = .xterm_compatible });
    _ = try drawOverlayLines(
        single_renderer,
        .{ .rows = 1, .cols = 8 },
        0,
        null,
        &.{.{ .text = "single row", .alignment = .center }},
    );
    try std.testing.expect(std.mem.indexOf(u8, single_row.items, "\r\n") != null);

    var first = std.ArrayList(u8).empty;
    defer first.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.buffered(&first, .{ .kind = .xterm_compatible });
    const first_state = try drawOverlayLines(
        renderer,
        .{ .rows = 4, .cols = 8 },
        0,
        null,
        &.{
            .{ .text = "0123456789", .alignment = .center },
            .{ .text = "ssh: first", .alignment = .left },
        },
    );
    try std.testing.expect(std.mem.indexOf(u8, first.items, "01234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "ssh: fir") != null);
    try std.testing.expectEqual(@as(u16, 1), first_state.start_row);
    try std.testing.expectEqual(@as(u16, 2), first_state.line_count);

    var second = std.ArrayList(u8).empty;
    defer second.deinit(std.testing.allocator);
    const second_renderer = client_renderer.Renderer.buffered(&second, .{ .kind = .xterm_compatible });
    _ = try drawOverlayLines(
        second_renderer,
        .{ .rows = 4, .cols = 8 },
        first_state.viewport_offset,
        first_state,
        &.{.{ .text = "new", .alignment = .center }},
    );
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(second.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "new") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "ssh: fir") == null);

    var third = std.ArrayList(u8).empty;
    defer third.deinit(std.testing.allocator);
    const third_renderer = client_renderer.Renderer.buffered(&third, .{ .kind = .xterm_compatible });
    _ = try drawOverlayLines(
        third_renderer,
        .{ .rows = 4, .cols = 8 },
        first_state.viewport_offset,
        first_state,
        &.{
            .{ .text = "76543210", .alignment = .center },
            .{ .text = "ssh: first", .alignment = .left },
        },
    );
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(third.items, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, third.items, "76543210") != null);
    try std.testing.expect(std.mem.indexOf(u8, third.items, "ssh: fir") == null);
}

test "reconnect overlay restores temporary expansion within sessh-owned rows" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.buffered(&drawn, .{ .kind = .xterm_compatible });
    const state = try drawOverlayLines(
        renderer,
        .{ .rows = 4, .cols = 16 },
        0,
        null,
        &.{
            .{ .text = "one", .alignment = .center },
            .{ .text = "two", .alignment = .left },
            .{ .text = "three", .alignment = .left },
            .{ .text = "four", .alignment = .left },
        },
    );
    try std.testing.expectEqual(@as(u16, 1), state.scroll_lines);
    try std.testing.expect(state.restores_expansion);
    try std.testing.expectEqual(@as(u16, 0), state.restore_viewport_offset);

    var cleared = std.ArrayList(u8).empty;
    defer cleared.deinit(std.testing.allocator);
    const clear_renderer = client_renderer.Renderer.buffered(&cleared, .{ .kind = .xterm_compatible });
    try eraseOverlayRows(clear_renderer, state, 4, 16);
    try restoreOverlayExpansion(clear_renderer, state, 4);
    try std.testing.expectEqual(@as(usize, 1), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\x1b[r") != null);
}

test "reconnect overlay scrolls outer rows into scrollback when expansion consumes them" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.buffered(&drawn, .{ .kind = .xterm_compatible });
    const state = try drawOverlayLines(
        renderer,
        .{ .rows = 4, .cols = 16 },
        3,
        null,
        &.{
            .{ .text = "one", .alignment = .center },
            .{ .text = "two", .alignment = .left },
        },
    );
    try std.testing.expectEqual(@as(u16, 2), state.scroll_lines);
    try std.testing.expect(!state.restores_expansion);
    try std.testing.expectEqual(@as(u16, 1), state.viewport_offset);
    try std.testing.expectEqual(@as(u16, 3), state.restore_viewport_offset);
    try std.testing.expect(std.mem.indexOf(u8, drawn.items, "\x1b[2;4r") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn.items, "\x1b[4;1H\r\n\r\n") != null);

    var cleared = std.ArrayList(u8).empty;
    defer cleared.deinit(std.testing.allocator);
    const clear_renderer = client_renderer.Renderer.buffered(&cleared, .{ .kind = .xterm_compatible });
    try eraseOverlayRows(clear_renderer, state, 4, 16);
    try restoreOverlayExpansion(clear_renderer, state, 4);
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expectEqual(@as(u16, 1), clearedOverlayViewportOffset(state));
}

test "reconnect overlay updates every second under one minute" {
    try std.testing.expectEqual(@as(u64, 1_000), nextOverlayUpdateDelayMs(59_000));
    try std.testing.expectEqual(@as(u64, 1_000), nextOverlayUpdateDelayMs(60_000));
    try std.testing.expectEqual(@as(u64, 2_000), nextOverlayUpdateDelayMs(61_000));
    try std.testing.expectEqual(@as(u64, 60_000), nextOverlayUpdateDelayMs(600_000));
}
