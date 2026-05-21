const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const client_log = @import("client_log.zig");
const client_renderer = @import("client_renderer.zig");
const io_helpers = @import("io.zig");
const protocol = @import("protocol.zig");
const process_exit = @import("process_exit.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;
const WindowSize = terminal.WindowSize;
const Leader = terminal.Leader;

const LocalAction = enum {
    new,
    attach,
    list,
    kill,
    kill_all,
};

const LocalOptions = struct {
    action: LocalAction = .new,
    action_set: bool = false,
    attach_id: ?[]const u8 = null,
    kill_id: ?[]const u8 = null,
    leader: Leader = .none,
    leader_set: bool = false,
    banner_args: DetachBannerArgs = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    compat_version: ?[]const u8 = null,
};

pub const DetachBannerArgs = struct {
    buf: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *DetachBannerArgs, arg: []const u8) !void {
        if (self.len >= self.buf.len) return error.TooManyDetachBannerArgs;
        self.buf[self.len] = arg;
        self.len += 1;
    }

    pub fn slice(self: *const DetachBannerArgs) []const []const u8 {
        return self.buf[0..self.len];
    }
};

pub const FileConfig = struct {
    leader: ?Leader = null,
    scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    client_log_level: ?client_log.Level = null,
    bootstrap: ?bool = null,
};

pub fn loadFileConfig(allocator: std.mem.Allocator) !FileConfig {
    const maybe_path = try configPath(allocator);
    const path = maybe_path orelse return .{};
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(bytes);
    return parseEnvConfig(bytes);
}

fn configPath(allocator: std.mem.Allocator) !?[]u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |xdg_z| {
        const xdg = std.mem.span(xdg_z);
        if (xdg.len > 0) {
            const path = try std.fs.path.join(allocator, &.{ xdg, "sessh", "sessh.env" });
            return path;
        }
    }
    if (c.getenv("HOME")) |home_z| {
        const home = std.mem.span(home_z);
        if (home.len > 0) {
            const path = try std.fs.path.join(allocator, &.{ home, ".config", "sessh", "sessh.env" });
            return path;
        }
    }
    return null;
}

fn parseEnvConfig(bytes: []const u8) !FileConfig {
    var parsed = FileConfig{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        var line = trimEnv(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = trimEnv(line["export ".len..]);

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = trimEnv(line[0..eq]);
        const value = unquoteEnvValue(trimEnv(line[eq + 1 ..])) catch return error.InvalidConfigValue;
        if (key.len == 0) return error.InvalidConfigLine;

        if (keyMatches(key, "leader")) {
            parsed.leader = try parseLeader(value);
        } else if (keyMatches(key, "scrollback-limit")) {
            parsed.scrollback_row_count = try parseScrollbackRowCount(value);
        } else if (keyMatches(key, "initial-scrollback")) {
            parsed.initial_scrollback_row_count = try parseInitialScrollbackRowCount(value);
            parsed.initial_scrollback_row_count_set = true;
        } else if (keyMatches(key, "client-log-level")) {
            parsed.client_log_level = try client_log.parseLevel(value);
        } else if (keyMatches(key, "bootstrap")) {
            parsed.bootstrap = try parseBool(value);
        } else {
            return error.UnknownConfigKey;
        }
    }
    return parsed;
}

fn trimEnv(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}

fn unquoteEnvValue(value: []const u8) ![]const u8 {
    if (value.len < 2) return value;
    const first = value[0];
    const last = value[value.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return value[1 .. value.len - 1];
    if (first == '"' or first == '\'' or last == '"' or last == '\'') return error.InvalidConfigValue;
    return value;
}

fn keyMatches(key: []const u8, canonical: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(key, canonical)) return true;
    var normalized_buf: [64]u8 = undefined;
    if (key.len > normalized_buf.len) return false;
    for (key, 0..) |byte, i| {
        normalized_buf[i] = if (byte == '_') '-' else std.ascii.toLower(byte);
    }
    return std.mem.eql(u8, normalized_buf[0..key.len], canonical);
}

pub fn parseScrollbackRowCount(value: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidScrollbackRowCount;
    if (parsed == 0) return error.InvalidScrollbackRowCount;
    return parsed;
}

pub fn parseInitialScrollbackRowCount(value: []const u8) !?u32 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidInitialScrollback;
    if (parsed == -1) return null;
    if (parsed < 0 or parsed > std.math.maxInt(u32)) return error.InvalidInitialScrollback;
    return @intCast(parsed);
}

pub fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or
        std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "no"))
    {
        return false;
    }
    return error.InvalidBool;
}

const ErrorPayload = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

pub const RelayEnd = enum {
    detach,
    reconnect,
    unresponsive,
    transport_closed,
    session_ended,
};

pub const ReconnectDecision = enum {
    wait_elapsed,
    reconnect_now,
    abort,
};

pub const RuntimeRecovery = enum {
    recovered,
    transport_closed,
    session_ended,
};

pub const ConnectionResult = enum {
    recovered,
    reconnected,
};

pub const RelayOptions = struct {
    monitor_connection: bool = false,
};

const input_chunk_bytes = 1024;
const ping_min_interval_ms: i64 = 1_000;
const initial_responsiveness_timeout_ms: i64 = 2_000;
const min_responsiveness_timeout_ms: i64 = 1_000;
const max_responsiveness_timeout_ms: i64 = 15_000;

const ConnectionMonitor = struct {
    enabled: bool = false,
    pending_ping_seq: ?u64 = null,
    deferred_ping: bool = false,
    ping_sent_ms: i64 = 0,
    last_ping_sent_ms: ?i64 = null,
    any_response_wait_started_ms: ?i64 = null,
    smoothed_rtt_ms: ?i64 = null,
    rtt_variance_ms: i64 = 0,

    fn afterInput(self: *ConnectionMonitor, write_fd: c.fd_t) !void {
        if (!self.enabled) return;
        const now = std.time.milliTimestamp();
        try self.afterInputAt(write_fd, now);
    }

    fn afterInputAt(self: *ConnectionMonitor, write_fd: c.fd_t, now: i64) !void {
        if (!self.enabled) return;
        if (self.any_response_wait_started_ms == null) {
            self.any_response_wait_started_ms = now;
        }
        if (self.pending_ping_seq == null and self.canSendPing(now)) {
            self.pending_ping_seq = try sendPingRequest(write_fd);
            self.ping_sent_ms = now;
            self.last_ping_sent_ms = now;
            self.deferred_ping = false;
        } else if (self.pending_ping_seq == null) {
            self.deferred_ping = true;
        }
    }

    fn canSendPing(self: *const ConnectionMonitor, now: i64) bool {
        const last = self.last_ping_sent_ms orelse return true;
        return now - last >= ping_min_interval_ms;
    }

    fn maybeSendDeferredPing(self: *ConnectionMonitor, write_fd: c.fd_t) !void {
        if (!self.enabled) return;
        try self.maybeSendDeferredPingAt(write_fd, std.time.milliTimestamp());
    }

    fn maybeSendDeferredPingAt(self: *ConnectionMonitor, write_fd: c.fd_t, now: i64) !void {
        if (!self.deferred_ping or self.pending_ping_seq != null or !self.canSendPing(now)) return;
        self.pending_ping_seq = try sendPingRequest(write_fd);
        self.ping_sent_ms = now;
        self.last_ping_sent_ms = now;
        self.any_response_wait_started_ms = now;
        self.deferred_ping = false;
    }

    fn noteInboundFrame(self: *ConnectionMonitor) void {
        self.any_response_wait_started_ms = null;
        self.deferred_ping = false;
    }

    fn handlePingResponse(self: *ConnectionMonitor, payload: []const u8) !void {
        var response = try protocol.decodePayload(pb.PingResponse, app_allocator.allocator(), payload);
        defer response.deinit(app_allocator.allocator());
        const pending_seq = self.pending_ping_seq orelse return;
        if (response.request_seq_number != pending_seq) return;
        const rtt_ms = @max(std.time.milliTimestamp() - self.ping_sent_ms, 0);
        self.pending_ping_seq = null;
        self.updateRtt(rtt_ms);
    }

    fn updateRtt(self: *ConnectionMonitor, rtt_ms: i64) void {
        if (self.smoothed_rtt_ms) |srtt| {
            const delta = if (rtt_ms > srtt) rtt_ms - srtt else srtt - rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(3 * self.rtt_variance_ms + delta, 4), 1);
            self.smoothed_rtt_ms = @divTrunc(7 * srtt + rtt_ms, 8);
        } else {
            self.smoothed_rtt_ms = rtt_ms;
            self.rtt_variance_ms = @max(@divTrunc(rtt_ms, 2), 1);
        }
    }

    fn pollTimeoutMs(self: *const ConnectionMonitor) i32 {
        if (!self.enabled) return 100;
        if (self.deferred_ping and self.pending_ping_seq == null) {
            const last = self.last_ping_sent_ms orelse return 0;
            const until_ping = ping_min_interval_ms - (std.time.milliTimestamp() - last);
            if (until_ping <= 0) return 0;
            return @intCast(@min(@as(i64, 100), until_ping));
        }
        const started = self.any_response_wait_started_ms orelse return 100;
        const elapsed = std.time.milliTimestamp() - started;
        const remaining = self.responsivenessTimeoutMs() - elapsed;
        if (remaining <= 0) return 0;
        return @intCast(@min(@as(i64, 100), remaining));
    }

    fn isUnresponsive(self: *const ConnectionMonitor) bool {
        if (!self.enabled) return false;
        if (self.deferred_ping and self.pending_ping_seq == null) return false;
        const started = self.any_response_wait_started_ms orelse return false;
        return std.time.milliTimestamp() - started >= self.responsivenessTimeoutMs();
    }

    fn responsivenessTimeoutMs(self: *const ConnectionMonitor) i64 {
        // TCP-style adaptive timeout: smoothed RTT plus variance, bounded so a
        // single retransmit-scale delay does not immediately force reconnect.
        const timeout = if (self.smoothed_rtt_ms) |srtt|
            srtt + 4 * self.rtt_variance_ms
        else
            initial_responsiveness_timeout_ms;
        return @min(max_responsiveness_timeout_ms, @max(min_responsiveness_timeout_ms, timeout));
    }
};

pub const ScrollbackCursor = struct {
    epoch: u64 = 0,
    seen_rows: u64 = 0,
};

pub const RuntimeSession = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    scrollback_cursor: ScrollbackCursor = .{},
    origin_row: ?u16 = null,
    cursor_row: u16 = 0,
    relay_end_restore: std.ArrayList(u8) = .empty,

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const ReconnectUi = struct {
    const reconnected_banner_ms = 500;

    mode_guard: terminal.TerminalModeGuard,
    escape_filter: terminal.EscapeFilter = .{ .at_line_start = false },
    buffered_input: std.ArrayList(u8) = .empty,
    origin_row: ?u16 = null,
    banner_row: ?u16 = null,
    cursor_hidden: bool = false,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn begin(origin_row: ?u16, cursor_row: u16) !ReconnectUi {
        const resolved_origin_row = reconnectOriginRow(origin_row, cursor_row);
        var ui = ReconnectUi{ .mode_guard = try terminal.TerminalModeGuard.enable(0) };
        ui.origin_row = resolved_origin_row;
        try ui.hideCursor();
        return ui;
    }

    pub fn deinit(self: *ReconnectUi) void {
        self.showCursor() catch {};
        self.buffered_input.deinit(app_allocator.allocator());
        self.mode_guard.restore();
    }

    pub fn waitForReconnect(self: *ReconnectUi, delay_ms: u64) !ReconnectDecision {
        try self.drawBanner(delay_ms);
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(delay_ms));
        var next_banner_update = std.time.milliTimestamp() + @as(i64, @intCast(nextBannerUpdateDelayMs(delay_ms)));

        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) {
                try self.drawStaticBanner("--- sessh: reconnecting... CTRL-C aborts ---");
                return .wait_elapsed;
            }

            const next_wake = @min(deadline, next_banner_update);
            const wait_ms: i32 = @intCast(@min(next_wake - now, @as(i64, std.math.maxInt(i32))));
            switch (try self.pollInput(wait_ms)) {
                .abort => return .abort,
                .reconnect_now => {
                    try self.drawStaticBanner("--- sessh: reconnecting... CTRL-C aborts ---");
                    return .reconnect_now;
                },
                .wait_elapsed => {},
            }

            const after_poll = std.time.milliTimestamp();
            if (after_poll >= next_banner_update and after_poll < deadline) {
                const remaining_ms: u64 = @intCast(deadline - after_poll);
                try self.drawBanner(remaining_ms);
                next_banner_update = after_poll + @as(i64, @intCast(nextBannerUpdateDelayMs(remaining_ms)));
            }
        }
    }

    pub fn showConnectionUnresponsive(self: *ReconnectUi) !void {
        try self.drawStaticBanner("--- sessh: connection unresponsive - attempting reconnect ---");
    }

    pub fn pollAbort(self: *ReconnectUi, timeout_ms: i32) !bool {
        if (self.isCancelled()) return true;
        return switch (try self.pollInput(timeout_ms)) {
            .abort => true,
            .reconnect_now, .wait_elapsed => false,
        };
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

    fn pollInput(self: *ReconnectUi, timeout_ms: i32) !ReconnectDecision {
        var pollfds = [_]posix.pollfd{.{
            .fd = 0,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, timeout_ms);
        if (ready == 0) return .wait_elapsed;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .abort;
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(0, &input, input.len);
        if (n <= 0) return .abort;

        for (input[0..@intCast(n)]) |byte| {
            if (byte == 0x03) return .abort;
            if (byte == ' ') return .reconnect_now;

            const one = [_]u8{byte};
            const result = self.escape_filter.filter(&one, &filtered);
            try self.buffered_input.appendSlice(app_allocator.allocator(), result.bytes);
            if (result.end) |end| {
                if (end == .detach) return .abort;
            }
        }
        return .wait_elapsed;
    }

    pub fn flushBufferedInput(self: *ReconnectUi, write_fd: c.fd_t) !void {
        if (self.escape_filter.pending_tilde) {
            try self.buffered_input.append(app_allocator.allocator(), '~');
            self.escape_filter.pending_tilde = false;
        }
        if (self.buffered_input.items.len == 0) return;
        try sendInput(write_fd, self.buffered_input.items);
        self.buffered_input.clearRetainingCapacity();
    }

    pub fn clearBanner(self: *ReconnectUi) !void {
        if (c.isatty(1) == 0) return;
        const origin = self.origin_row orelse return;
        const banner = self.banner_row orelse return;
        const renderer = client_renderer.Renderer.init(1);
        try renderer.moveCursor(banner, 0);
        try renderer.clearLine();
        try renderer.moveCursor(origin, 0);
    }

    pub fn showReconnectedBriefly(self: *ReconnectUi) !void {
        try self.showConnectionResultBriefly(.reconnected);
    }

    pub fn showConnectionResultBriefly(self: *ReconnectUi, result: ConnectionResult) !void {
        const message = switch (result) {
            .recovered => "--- sessh: connection recovered. SPACE to dismiss or wait 500ms ---",
            .reconnected => "--- sessh: reconnected. SPACE to dismiss or wait 500ms ---",
        };
        try self.drawStaticBanner(message);
        try self.waitForDismiss(reconnected_banner_ms);
    }

    fn drawBanner(self: *ReconnectUi, delay_ms: u64) !void {
        var delay_buf: [16]u8 = undefined;
        const delay = try formatDelay(delay_ms, &delay_buf);
        var message_buf: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(
            &message_buf,
            "--- sessh: disconnected. Retry in {s}. SPACE retries now. CTRL-C aborts ---",
            .{delay},
        );
        try self.drawStaticBanner(message);
    }

    fn drawStaticBanner(self: *ReconnectUi, message: []const u8) !void {
        if (c.isatty(1) == 0) {
            try io_helpers.writeAll(1, "\r\n");
            try io_helpers.writeAll(1, message);
            try io_helpers.writeAll(1, "\r\n");
            return;
        }

        const size = terminal.currentWindowSize();
        const top_row = self.origin_row orelse 0;
        const banner_row = bannerRowForSize(size.rows, top_row);
        const visible_message = if (message.len > size.cols) message[0..size.cols] else message;
        const col: u16 = if (size.cols > visible_message.len)
            @intCast((@as(usize, size.cols) - visible_message.len) / 2)
        else
            0;

        const renderer = client_renderer.Renderer.init(1);
        self.banner_row = banner_row;
        try renderer.moveCursor(banner_row, col);
        try renderer.clearLine();
        try io_helpers.writeAll(1, "\x1b[7m");
        try io_helpers.writeAll(1, visible_message);
        try io_helpers.writeAll(1, "\x1b[0m");
        try renderer.moveCursor(top_row, 0);
    }

    fn waitForDismiss(self: *ReconnectUi, timeout_ms: u64) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) return;
            const wait_ms: i32 = @intCast(@min(deadline - now, @as(i64, std.math.maxInt(i32))));
            if (try self.pollDismissInput(wait_ms)) return;
        }
    }

    fn pollDismissInput(self: *ReconnectUi, timeout_ms: i32) !bool {
        var pollfds = [_]posix.pollfd{.{
            .fd = 0,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, timeout_ms);
        if (ready == 0) return false;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return true;
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return false;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(0, &input, input.len);
        if (n <= 0) return true;

        for (input[0..@intCast(n)]) |byte| {
            if (byte == ' ') return true;

            const one = [_]u8{byte};
            const result = self.escape_filter.filter(&one, &filtered);
            try self.buffered_input.appendSlice(app_allocator.allocator(), result.bytes);
        }
        return false;
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
};

fn bannerRowForSize(rows: u16, top_row: u16) u16 {
    if (rows <= 1) return 0;
    return @min(top_row +| 1, rows - 1);
}

fn formatDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    const seconds = @max(@divTrunc(delay_ms + 999, 1000), 1);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{}sec", .{seconds});
    const minutes = @divTrunc(seconds + 59, 60);
    return std.fmt.bufPrint(buf, "{}min", .{minutes});
}

fn nextBannerUpdateDelayMs(remaining_ms: u64) u64 {
    if (remaining_ms <= 1_000) return remaining_ms;
    if (remaining_ms <= 60_000) return 1_000;
    return @min(remaining_ms - 59_000, 60_000);
}

const DrawPayload = struct {
    scrollback_epoch: u64,
    scroll_count: u64,
    cursor_row: u16,
    draw_bytes: []const u8,
    request_seq_number: ?u64,
    relay_end_restore_bytes: ?[]const u8,
};

fn reconnectOriginRow(origin_row: ?u16, cursor_row: u16) ?u16 {
    const position = terminal.queryCursorPosition(0, 1) catch null;
    if (position) |value| {
        if (value.row >= cursor_row) return value.row - cursor_row;
    }
    return origin_row;
}

test "parseEnvConfig accepts sessh env keys" {
    const parsed = try parseEnvConfig(
        \\leader=CTRL-B
        \\scrollback-limit=42
        \\initial-scrollback=0
        \\client-log-level=debug
        \\bootstrap=false
        \\
    );

    switch (parsed.leader.?) {
        .ctrl => |byte| try std.testing.expectEqual(@as(u8, 'B'), byte),
        .none => return error.ExpectedLeader,
    }
    try std.testing.expectEqual(@as(?u32, 42), parsed.scrollback_row_count);
    try std.testing.expect(parsed.initial_scrollback_row_count_set);
    try std.testing.expectEqual(@as(?u32, 0), parsed.initial_scrollback_row_count);
    try std.testing.expectEqual(@as(?client_log.Level, .debug), parsed.client_log_level);
    try std.testing.expectEqual(@as(?bool, false), parsed.bootstrap);
}

test "parseEnvConfig maps initial scrollback minus one to all retained rows" {
    const parsed = try parseEnvConfig("INITIAL_SCROLLBACK=-1\n");

    try std.testing.expect(parsed.initial_scrollback_row_count_set);
    try std.testing.expectEqual(@as(?u32, null), parsed.initial_scrollback_row_count);
}

test "formatDelay uses compact reconnect labels" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("5sec", try formatDelay(5_000, &buf));
    try std.testing.expectEqualStrings("20sec", try formatDelay(20_000, &buf));
    try std.testing.expectEqualStrings("1min", try formatDelay(60_000, &buf));
    try std.testing.expectEqualStrings("10min", try formatDelay(600_000, &buf));
}

test "reconnect banner row handles single-line terminals" {
    try std.testing.expectEqual(@as(u16, 0), bannerRowForSize(1, 0));
    try std.testing.expectEqual(@as(u16, 1), bannerRowForSize(24, 0));
    try std.testing.expectEqual(@as(u16, 23), bannerRowForSize(24, 23));
}

test "reconnect banner updates every second under one minute" {
    try std.testing.expectEqual(@as(u64, 1_000), nextBannerUpdateDelayMs(59_000));
    try std.testing.expectEqual(@as(u64, 1_000), nextBannerUpdateDelayMs(60_000));
    try std.testing.expectEqual(@as(u64, 2_000), nextBannerUpdateDelayMs(61_000));
    try std.testing.expectEqual(@as(u64, 60_000), nextBannerUpdateDelayMs(600_000));
}

test "connection monitor defers rate-limited ping and starts responsiveness wait" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var monitor = ConnectionMonitor{
        .enabled = true,
        .last_ping_sent_ms = 1_000,
    };

    try monitor.afterInputAt(fds[1], 1_100);
    try std.testing.expectEqual(@as(?u64, null), monitor.pending_ping_seq);
    try std.testing.expect(monitor.deferred_ping);
    try std.testing.expectEqual(@as(?i64, 1_100), monitor.any_response_wait_started_ms);
    try std.testing.expect(!monitor.isUnresponsive());

    try monitor.maybeSendDeferredPingAt(fds[1], 2_000);
    const pending = monitor.pending_ping_seq orelse return error.ExpectedPendingPing;
    try std.testing.expect(!monitor.deferred_ping);
    try std.testing.expectEqual(@as(?i64, 2_000), monitor.any_response_wait_started_ms);

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(pending, frame.seq);
    try std.testing.expect(frame.knownMessageType() == .FRAME_TYPE_PING_REQUEST);
}

test "cancelled reconnect frame read returns without input" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ReconnectAborted, readFrameAllocMaybeCancelled(fds[0], &cancelled));
}

test "recovery polling stores relay-end restore bytes from draw" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.relay_end_restore.deinit(app_allocator.allocator());

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Draw{
        .scrollback_epoch = 1,
        .scroll_count = 0,
        .cursor_row = 0,
        .draw_bytes = "",
        .relay_end_restore_bytes = "restore-primary",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .FRAME_TYPE_DRAW, payload);

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.relay_end_restore.items);
}

/// Implements the public `sessh :local:` path. This is both the local testing
/// transport and the same broker/agent flow used by ssh after bootstrap.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var options = parseLocalOptions(args) catch |err| {
        try io_helpers.stderrPrint("sessh: invalid :local: arguments: {t}\n", .{err});
        return process_exit.request(64);
    };
    applyFileConfigToLocal(allocator, &options) catch |err| {
        try io_helpers.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(options.client_log_level);

    return runBrokerClient(allocator, args, options);
}

fn runBrokerClient(allocator: std.mem.Allocator, args: []const []const u8, options: LocalOptions) !void {
    switch (options.action) {
        .list => {
            var child = try startLocalBroker(allocator, args[0]);
            var child_done = false;
            defer if (!child_done) terminateChild(&child);
            try runtimeHandshake(child.stdout.?.handle, child.stdin.?.handle);
            const exit_status = try runCommandAndForward(child.stdout.?.handle, child.stdin.?.handle, &.{"list"});
            closeChildStdin(&child);
            _ = child.wait() catch {};
            child_done = true;
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var child = try startLocalBroker(allocator, args[0]);
            var child_done = false;
            defer if (!child_done) terminateChild(&child);
            try runtimeHandshake(child.stdout.?.handle, child.stdin.?.handle);
            const exit_status = try runCommandAndForward(child.stdout.?.handle, child.stdin.?.handle, &.{ "kill", options.kill_id.? });
            closeChildStdin(&child);
            _ = child.wait() catch {};
            child_done = true;
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill_all => {
            var child = try startLocalBroker(allocator, args[0]);
            var child_done = false;
            defer if (!child_done) terminateChild(&child);
            try runtimeHandshake(child.stdout.?.handle, child.stdin.?.handle);
            const exit_status = try runCommandAndForward(child.stdout.?.handle, child.stdin.?.handle, &.{"kill-all"});
            closeChildStdin(&child);
            _ = child.wait() catch {};
            child_done = true;
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .new, .attach => {},
    }

    var child = try startLocalBroker(allocator, args[0]);
    var session = (switch (options.action) {
        .new => startNewSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, options.scrollback_row_count),
        .attach => startAttachSessionOnRuntime(
            child.stdout.?.handle,
            child.stdin.?.handle,
            options.attach_id orelse "",
            options.initial_scrollback_row_count,
        ),
        .list, .kill, .kill_all => unreachable,
    }) catch |err| {
        if (process_exit.is(err)) return err;
        terminateChild(&child);
        try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };

    while (true) {
        const end = relayRuntimeSession(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            options.leader,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                terminateChild(&child);
                writeDetachBannerForTarget(&.{}, ":local:", options.banner_args.slice(), session.idSlice());
                return;
            },
            .session_ended => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                return;
            },
            .reconnect => {
                terminateChild(&child);
            },
            .unresponsive => {
                terminateChild(&child);
            },
            .transport_closed => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!sessionExistsViaBroker(allocator, args[0], session.idSlice())) {
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\nsessh: reconnecting; type <enter>~. to abort\r\n");
        child = startLocalBroker(allocator, args[0]) catch |err| {
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn startLocalBroker(allocator: std.mem.Allocator, exe: []const u8) !std.process.Child {
    const argv = [_][]const u8{ exe, ":internal-host-broker:" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn sessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8, session_id: []const u8) bool {
    var child = startLocalBroker(allocator, exe) catch return false;
    var child_done = false;
    defer if (!child_done) terminateChild(&child);

    runtimeHandshake(child.stdout.?.handle, child.stdin.?.handle) catch return false;
    sendCommandRequest(child.stdin.?.handle, &.{"list"}) catch return false;

    var frame = protocol.readFrameAlloc(app_allocator.allocator(), child.stdout.?.handle) catch return false;
    defer frame.deinit(app_allocator.allocator());
    if (frame.knownMessageType() != .FRAME_TYPE_COMMAND_RESPONSE) return false;
    const response = parseCommandResponse(frame.payload) catch return false;
    defer freeCommandResponse(response);

    closeChildStdin(&child);
    _ = child.wait() catch {};
    child_done = true;
    return response.exit_status == 0 and listContainsSession(response.stdout, session_id);
}

fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}

fn parseLocalOptions(args: []const []const u8) !LocalOptions {
    var options = LocalOptions{};
    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            try setAction(&options, .list);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--kill-all") or std.mem.eql(u8, arg, "--killall")) {
            try setAction(&options, .kill_all);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--attach")) {
            try setAction(&options, .attach);
            i += 1;
            if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
                options.attach_id = args[i];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--kill")) {
            try setAction(&options, .kill);
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingKillId;
            options.kill_id = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--leader")) {
            i += 1;
            if (i >= args.len) return error.MissingLeader;
            options.leader = try parseLeader(args[i]);
            options.leader_set = true;
            try options.banner_args.append(arg);
            try options.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback-limit")) {
            i += 1;
            if (i >= args.len) return error.MissingScrollbackRowCount;
            options.scrollback_row_count = try parseScrollbackRowCount(args[i]);
            options.scrollback_row_count_set = true;
            try options.banner_args.append(arg);
            try options.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--initial-scrollback")) {
            i += 1;
            if (i >= args.len) return error.MissingInitialScrollback;
            options.initial_scrollback_row_count = try parseInitialScrollbackRowCount(args[i]);
            options.initial_scrollback_row_count_set = true;
            try options.banner_args.append(arg);
            try options.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return error.MissingClientLogLevel;
            options.client_log_level = try client_log.parseLevel(args[i]);
            options.client_log_level_set = true;
            try options.banner_args.append(arg);
            try options.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--compat-version")) {
            i += 1;
            if (i >= args.len) return error.MissingCompatVersion;
            options.compat_version = args[i];
            i += 1;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn applyFileConfigToLocal(allocator: std.mem.Allocator, options: *LocalOptions) !void {
    const file_config = try loadFileConfig(allocator);
    if (!options.leader_set) {
        if (file_config.leader) |leader| options.leader = leader;
    }
    if (!options.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| options.scrollback_row_count = count;
    }
    if (!options.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        options.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (!options.client_log_level_set) {
        if (file_config.client_log_level) |level| options.client_log_level = level;
    }
}

fn setAction(options: *LocalOptions, action: LocalAction) !void {
    if (options.action_set) return error.MultipleActions;
    options.action = action;
    options.action_set = true;
}

pub fn parseLeader(value: []const u8) !Leader {
    if (std.ascii.eqlIgnoreCase(value, "None")) return .none;
    if (!std.ascii.startsWithIgnoreCase(value, "CTRL-")) return error.InvalidLeader;

    const key = value["CTRL-".len..];
    if (key.len != 1) return error.InvalidLeader;
    const upper = std.ascii.toUpper(key[0]);
    if (upper == 'C' or upper == 'D' or upper == 'Z' or upper == '\\') return error.DangerousLeader;
    if (upper >= '@' and upper <= '_') return .{ .ctrl = upper };
    return error.InvalidLeader;
}

test "parseLeader accepts case-insensitive spelling" {
    switch (try parseLeader("ctrl-b")) {
        .ctrl => |byte| try std.testing.expectEqual(@as(u8, 'B'), byte),
        .none => return error.ExpectedLeader,
    }

    switch (try parseLeader("Ctrl-B")) {
        .ctrl => |byte| try std.testing.expectEqual(@as(u8, 'B'), byte),
        .none => return error.ExpectedLeader,
    }

    try std.testing.expectEqual(Leader.none, try parseLeader("none"));
}

pub fn runCommandOnRuntime(read_fd: c.fd_t, write_fd: c.fd_t, argv: []const []const u8) !u8 {
    try runtimeHandshake(read_fd, write_fd);
    return runCommandAndForward(read_fd, write_fd, argv);
}

pub fn startNewSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
) !RuntimeSession {
    const origin_row = querySessionOriginRow();
    try runtimeHandshake(read_fd, write_fd);
    try sendResize(write_fd, terminal.currentWindowSize());
    try sendSessionNew(write_fd, scrollback_row_count);
    var session = try readRuntimeSession(read_fd);
    session.origin_row = origin_row;
    return session;
}

pub fn startAttachSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    attach_id: []const u8,
    initial_scrollback_row_count: ?u32,
) !RuntimeSession {
    const origin_row = querySessionOriginRow();
    try runtimeHandshake(read_fd, write_fd);
    try sendResize(write_fd, terminal.currentWindowSize());
    try sendSessionAttach(write_fd, attach_id, initial_scrollback_row_count, null);
    var session = try readRuntimeSession(read_fd);
    session.origin_row = origin_row;
    return session;
}

pub fn reconnectSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, null);
}

pub fn reconnectSessionOnRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: *const std.atomic.Value(bool),
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, cancelled);
}

fn reconnectSessionOnRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    try runtimeHandshakeInner(read_fd, write_fd, cancelled);
    try sendResize(write_fd, terminal.currentWindowSize());
    try sendSessionAttach(write_fd, session.idSlice(), null, session.scrollback_cursor);

    var id_buf: [64]u8 = undefined;
    const attached_id = try readAttachedSessionIdInner(read_fd, &id_buf, cancelled);
    if (!std.mem.eql(u8, attached_id, session.idSlice())) return error.UnexpectedSessionId;
}

pub fn relayRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    leader: Leader,
    options: RelayOptions,
) !RelayEnd {
    return relayInteractive(
        read_fd,
        write_fd,
        session.idSlice(),
        leader,
        &session.scrollback_cursor,
        &session.cursor_row,
        &session.relay_end_restore,
        options,
    );
}

pub fn pollRuntimeRecovery(
    read_fd: c.fd_t,
    session: *RuntimeSession,
    timeout_ms: i32,
) !?RuntimeRecovery {
    var pollfds = [_]posix.pollfd{.{
        .fd = read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return null;
    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
        (pollfds[0].revents & posix.POLL.IN) == 0)
    {
        return .transport_closed;
    }
    if ((pollfds[0].revents & posix.POLL.IN) == 0) return null;

    var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .known => |message_type| switch (message_type) {
            .FRAME_TYPE_DRAW => {
                try handleDrawFrame(frame.payload, &session.relay_end_restore, &session.scrollback_cursor, &session.cursor_row);
                return .recovered;
            },
            .FRAME_TYPE_PING_RESPONSE => return .recovered,
            .FRAME_TYPE_SESSION_ENDED => {
                _ = finishRelay(.session_ended, &session.relay_end_restore);
                return .session_ended;
            },
            .FRAME_TYPE_ERROR => {
                try printErrorPayload(frame.payload);
                _ = finishRelay(.session_ended, &session.relay_end_restore);
                return .session_ended;
            },
            .FRAME_TYPE_UNRECOGNIZED => return null,
            else => return error.UnexpectedFrame,
        },
        .unknown => return null,
    }
}

pub fn writeDetachBannerForTarget(ssh_options: []const []const u8, target: []const u8, sessh_options: []const []const u8, session_id: []const u8) void {
    if (c.isatty(1) == 0) return;
    writeDetachBannerForTargetInner(ssh_options, target, sessh_options, session_id) catch {};
}

fn writeDetachBannerForTargetInner(ssh_options: []const []const u8, target: []const u8, sessh_options: []const []const u8, session_id: []const u8) !void {
    try io_helpers.writeAll(1, "--- sessh: detached. To re-attach: `");
    try writeShellArg(1, "sessh");
    for (ssh_options) |arg| {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, arg);
    }
    try io_helpers.writeAll(1, " ");
    try writeShellArg(1, target);
    for (sessh_options) |arg| {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, arg);
    }
    try io_helpers.writeAll(1, " --attach ");
    try writeShellArg(1, session_id);
    try io_helpers.writeAll(1, "` ---\r\n");
}

fn writeShellArg(fd: c.fd_t, arg: []const u8) !void {
    if (arg.len == 0) {
        try io_helpers.writeAll(fd, "''");
        return;
    }
    if (isPlainShellArg(arg)) {
        try io_helpers.writeAll(fd, arg);
        return;
    }
    try io_helpers.writeAll(fd, "'");
    for (arg) |byte| {
        if (byte == '\'') {
            try io_helpers.writeAll(fd, "'\\''");
        } else {
            var one = [_]u8{byte};
            try io_helpers.writeAll(fd, &one);
        }
    }
    try io_helpers.writeAll(fd, "'");
}

fn isPlainShellArg(arg: []const u8) bool {
    for (arg) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', '=' => {},
            else => return false,
        }
    }
    return true;
}

fn readRuntimeSession(read_fd: c.fd_t) !RuntimeSession {
    var session = RuntimeSession{};
    const session_id = try readAttachedSessionId(read_fd, &session.id);
    session.id_len = session_id.len;
    return session;
}

fn querySessionOriginRow() ?u16 {
    const position = terminal.queryCursorPosition(0, 1) catch return null;
    return if (position) |value| value.row else null;
}

fn readAttachedSessionId(conn: c.fd_t, session_id_buf: []u8) ![]const u8 {
    return readAttachedSessionIdInner(conn, session_id_buf, null);
}

fn readAttachedSessionIdInner(
    conn: c.fd_t,
    session_id_buf: []u8,
    cancelled: ?*const std.atomic.Value(bool),
) ![]const u8 {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(conn, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_ERROR => {
                    const parsed = try parseErrorPayload(frame.payload);
                    if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                        freeErrorPayload(parsed);
                        return error.VersionMismatch;
                    }
                    try printParsedError(parsed);
                    return process_exit.request(1);
                },
                .FRAME_TYPE_SESSION_ATTACHED => {
                    var attached = try protocol.decodePayload(pb.SessionAttached, app_allocator.allocator(), frame.payload);
                    defer attached.deinit(app_allocator.allocator());
                    const id = attached.session_id;
                    if (id.len == 0) return error.PayloadTooShort;
                    if (id.len > session_id_buf.len) return error.SessionIdTooLong;
                    @memcpy(session_id_buf[0..id.len], id);
                    return session_id_buf[0..id.len];
                },
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(conn, frame.seq, raw);
                continue;
            },
        }
    }
}

fn readFrameAllocMaybeCancelled(
    fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !protocol.OwnedFrame {
    const flag = cancelled orelse return protocol.readFrameAlloc(app_allocator.allocator(), fd);
    while (true) {
        if (flag.load(.acquire)) return error.ReconnectAborted;
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 50);
        if (flag.load(.acquire)) return error.ReconnectAborted;
        if (ready == 0) continue;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) {
            return protocol.readFrameAlloc(app_allocator.allocator(), fd);
        }
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            return error.EndOfStream;
        }
    }
}

pub fn runtimeHandshake(read_fd: c.fd_t, write_fd: c.fd_t) !void {
    try runtimeHandshakeInner(read_fd, write_fd, null);
}

fn runtimeHandshakeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    try sendHelloRequest(write_fd);
    var hello_error = try readHelloReply(read_fd, write_fd, cancelled);
    defer if (hello_error) |*err| err.deinit(app_allocator.allocator());
    if (hello_error) |err| {
        const parsed = errorPayloadFromHelloError(err);
        if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) return error.VersionMismatch;
        try printBorrowedError(parsed);
        return process_exit.request(1);
    }

    var peer_hello = try readHelloRequest(read_fd, write_fd, cancelled);
    defer peer_hello.deinit(app_allocator.allocator());
    if (helloRequestIsCompatible(peer_hello)) {
        try sendHelloOk(write_fd);
    } else {
        try sendHelloError(write_fd, "VERSION_MISMATCH", "existing remote sessh is incompatible with this client", "");
        return error.VersionMismatch;
    }
}

fn sendHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_REQUEST, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_OK, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .FRAME_TYPE_HELLO_ERROR, payload);
}

fn readHelloReply(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !?hpb.HelloError {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_OK => {
                    var ok = try protocol.decodePayload(hpb.HelloOk, app_allocator.allocator(), frame.payload);
                    defer ok.deinit(app_allocator.allocator());
                    return null;
                },
                .FRAME_TYPE_HELLO_ERROR => {
                    const err = try protocol.decodePayload(hpb.HelloError, app_allocator.allocator(), frame.payload);
                    return err;
                },
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(write_fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn readHelloRequest(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !hpb.HelloRequest {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_HELLO_REQUEST => return protocol.decodePayload(hpb.HelloRequest, app_allocator.allocator(), frame.payload),
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => {
                    try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                    return error.UnexpectedFrame;
                },
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(write_fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return hello.protocol_major == config.protocol_major and
        hello.protocol_minor >= config.protocol_minor and
        std.mem.eql(u8, hello.version, config.version);
}

fn errorPayloadFromHelloError(response_error: hpb.HelloError) ErrorPayload {
    return .{
        .code = response_error.code,
        .message = response_error.message,
        .hint = response_error.hint orelse "",
    };
}

const CommandResponse = struct {
    exit_status: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn sendCommandRequest(conn: c.fd_t, argv: []const []const u8) !void {
    var message = pb.CommandRequest{};
    defer message.argv.deinit(app_allocator.allocator());
    for (argv) |arg| try message.argv.append(app_allocator.allocator(), arg);
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .FRAME_TYPE_COMMAND_REQUEST, payload);
}

fn parseCommandResponse(payload: []const u8) !CommandResponse {
    var message = try protocol.decodePayload(pb.CommandResponse, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    if (message.exit_status > std.math.maxInt(u8)) return error.IntOutOfRange;
    return .{
        .exit_status = @intCast(message.exit_status),
        .stdout = try app_allocator.allocator().dupe(u8, message.stdout),
        .stderr = try app_allocator.allocator().dupe(u8, message.stderr),
    };
}

fn freeCommandResponse(response: CommandResponse) void {
    app_allocator.allocator().free(response.stdout);
    app_allocator.allocator().free(response.stderr);
}

fn runCommandAndForward(read_fd: c.fd_t, write_fd: c.fd_t, argv: []const []const u8) !u8 {
    try sendCommandRequest(write_fd, argv);
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), read_fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_ERROR => {
                    const parsed = try parseErrorPayload(frame.payload);
                    if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                        freeErrorPayload(parsed);
                        return error.VersionMismatch;
                    }
                    try printParsedError(parsed);
                    return 1;
                },
                .FRAME_TYPE_COMMAND_RESPONSE => {
                    const response = try parseCommandResponse(frame.payload);
                    defer freeCommandResponse(response);
                    if (response.stdout.len > 0) try io_helpers.writeAll(1, response.stdout);
                    if (response.stderr.len > 0) try io_helpers.writeAll(2, response.stderr);
                    return response.exit_status;
                },
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(write_fd, frame.seq, raw);
                continue;
            },
        }
    }
}

fn sendSessionNew(conn: c.fd_t, scrollback_row_count: u32) !void {
    var message = pb.SessionNew{
        .scrollback_row_limit = scrollback_row_count,
    };
    defer message.environment.deinit(app_allocator.allocator());
    const default_colors = queryDefaultColorsForSession();
    message.query_default_colors = .{
        .foreground_color = default_colors.foreground_color,
        .background_color = default_colors.background_color,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .FRAME_TYPE_SESSION_NEW, payload);
}

const ProtocolDefaultColors = struct {
    foreground_color: u32 = 0xffffffff,
    background_color: u32 = 0xffffffff,
};

fn queryDefaultColorsForSession() ProtocolDefaultColors {
    const queried = terminal.queryDefaultColors(0, 1) catch return .{};
    return .{
        .foreground_color = protocolColorFromRgb(queried.foreground),
        .background_color = protocolColorFromRgb(queried.background),
    };
}

fn protocolColorFromRgb(rgb: ?terminal.Rgb) u32 {
    const value = rgb orelse return 0xffffffff;
    return 0x01000000 |
        (@as(u32, value.r) << 16) |
        (@as(u32, value.g) << 8) |
        @as(u32, value.b);
}

fn sendSessionAttach(
    conn: c.fd_t,
    session_id: []const u8,
    initial_scrollback_row_count: ?u32,
    reconnect_cursor: ?ScrollbackCursor,
) !void {
    const cursor_message: ?pb.ScrollbackCursor = if (reconnect_cursor) |cursor| .{
        .scrollback_epoch = cursor.epoch,
        .seen_scrollback_rows = cursor.seen_rows,
    } else null;
    const message = pb.SessionAttach{
        .session_id = if (session_id.len == 0) null else session_id,
        .initial_scrollback_row_count = initial_scrollback_row_count,
        .reconnect_cursor = cursor_message,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .FRAME_TYPE_SESSION_ATTACH, payload);
}

fn readSessionEndedOrError(conn: c.fd_t) !bool {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), conn);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .known => |message_type| switch (message_type) {
                .FRAME_TYPE_ERROR => {
                    try printErrorPayload(frame.payload);
                    return true;
                },
                .FRAME_TYPE_SESSION_ENDED => return false,
                .FRAME_TYPE_UNRECOGNIZED => continue,
                else => return error.UnexpectedFrame,
            },
            .unknown => |raw| {
                try sendUnrecognizedFrame(conn, frame.seq, raw);
                continue;
            },
        }
    }
}

fn printErrorPayload(payload: []const u8) !void {
    try printParsedError(try parseErrorPayload(payload));
}

fn parseErrorPayload(payload: []const u8) !ErrorPayload {
    var decoded = try protocol.decodePayload(hpb.Error, app_allocator.allocator(), payload);
    defer decoded.deinit(app_allocator.allocator());
    return .{
        .code = try app_allocator.allocator().dupe(u8, decoded.code),
        .message = try app_allocator.allocator().dupe(u8, decoded.message),
        .hint = try app_allocator.allocator().dupe(u8, decoded.hint orelse ""),
    };
}

fn printParsedError(parsed: ErrorPayload) !void {
    defer freeErrorPayload(parsed);
    try printBorrowedError(parsed);
}

fn printBorrowedError(parsed: ErrorPayload) !void {
    try io_helpers.writeAll(2, "ERROR ");
    try io_helpers.writeAll(2, parsed.message);
    try io_helpers.writeAll(2, "\n");
    if (parsed.hint.len > 0) {
        try io_helpers.writeAll(2, parsed.hint);
        try io_helpers.writeAll(2, "\n");
    }
}

fn freeErrorPayload(parsed: ErrorPayload) void {
    app_allocator.allocator().free(parsed.code);
    app_allocator.allocator().free(parsed.message);
    app_allocator.allocator().free(parsed.hint);
}

fn listContainsSession(stdout: []const u8, session_id: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], session_id)) return true;
    }
    return false;
}

fn relayInteractive(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_id: []const u8,
    leader: Leader,
    scrollback_cursor: *ScrollbackCursor,
    cursor_row: ?*u16,
    relay_end_restore: *std.ArrayList(u8),
    options: RelayOptions,
) !RelayEnd {
    var mode_guard = try terminal.TerminalModeGuard.enable(0);
    defer mode_guard.restore();
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    defer if (cleanup_title) |title| app_allocator.allocator().free(title);
    var presentation_guard = if (cleanup_title) |title|
        client_renderer.PresentationGuard.initWithCleanupTitle(1, title)
    else
        client_renderer.PresentationGuard.init(1);
    defer presentation_guard.restore();

    const end = try relayTerminal(
        0,
        read_fd,
        write_fd,
        session_id,
        leader,
        &presentation_guard,
        scrollback_cursor,
        cursor_row,
        relay_end_restore,
        options,
    );
    if (end == .detach) writeDetachBoundary();
    return end;
}

fn relayTerminal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_id: []const u8,
    leader: Leader,
    presentation_guard: *client_renderer.PresentationGuard,
    scrollback_cursor: *ScrollbackCursor,
    cursor_row: ?*u16,
    relay_end_restore: *std.ArrayList(u8),
    options: RelayOptions,
) !RelayEnd {
    var pollfds = [_]posix.pollfd{
        .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    var buf: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    var escape_filter = terminal.EscapeFilter{ .leader_byte = terminal.leaderByte(leader) };
    var last_size = terminal.currentWindowSize();
    var connection_monitor = ConnectionMonitor{ .enabled = options.monitor_connection };
    _ = presentation_guard;

    while (true) {
        try connection_monitor.maybeSendDeferredPing(write_fd);
        _ = try posix.poll(&pollfds, connection_monitor.pollTimeoutMs());
        try connection_monitor.maybeSendDeferredPing(write_fd);
        maybeSendResize(write_fd, &last_size);

        if (connection_monitor.isUnresponsive()) {
            return .unresponsive;
        }

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
            defer frame.deinit(app_allocator.allocator());
            connection_monitor.noteInboundFrame();
            switch (frame.message_type) {
                .known => |message_type| switch (message_type) {
                    .FRAME_TYPE_DRAW => {
                        try handleDrawFrame(frame.payload, relay_end_restore, scrollback_cursor, cursor_row);
                    },
                    .FRAME_TYPE_PING_RESPONSE => try connection_monitor.handlePingResponse(frame.payload),
                    .FRAME_TYPE_SESSION_ENDED => return finishRelay(.session_ended, relay_end_restore),
                    .FRAME_TYPE_ERROR => {
                        try printErrorPayload(frame.payload);
                        return finishRelay(.session_ended, relay_end_restore);
                    },
                    .FRAME_TYPE_UNRECOGNIZED => {},
                    else => return error.UnexpectedFrame,
                },
                .unknown => |raw| try sendUnrecognizedFrame(write_fd, frame.seq, raw),
            }
        }
        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishRelay(requestSessionDetach(read_fd, write_fd, session_id), relay_end_restore);
            const result = escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) {
                try sendInputChunks(write_fd, result.bytes);
                try connection_monitor.afterInput(write_fd);
            }
            if (result.end) |end| switch (end) {
                .detach => return finishRelay(requestSessionDetach(read_fd, write_fd, session_id), relay_end_restore),
                .repaint => sendRepaint(write_fd, true) catch return .transport_closed,
                .reconnect => return .reconnect,
            };
        }
    }
}

fn finishRelay(end: RelayEnd, relay_end_restore: ?*const std.ArrayList(u8)) RelayEnd {
    if (end == .detach or end == .session_ended) {
        if (relay_end_restore) |restore| {
            if (restore.items.len > 0) io_helpers.writeAll(1, restore.items) catch {};
        }
    }
    return end;
}

fn requestSessionDetach(read_fd: c.fd_t, write_fd: c.fd_t, session_id: []const u8) RelayEnd {
    _ = read_fd;
    _ = write_fd;
    _ = session_id;
    return .detach;
}

fn writeDetachBoundary() void {
    if (c.isatty(1) == 0) return;
    io_helpers.writeAll(1, "\r\n") catch {};
}

fn handleDrawFrame(
    payload: []const u8,
    relay_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    cursor_row: ?*u16,
) !void {
    const draw = try parseDrawPayload(payload);
    defer freeDrawPayload(draw);
    try io_helpers.writeAll(1, draw.draw_bytes);
    if (relay_end_restore) |target| {
        if (draw.relay_end_restore_bytes) |restore| {
            target.clearRetainingCapacity();
            try target.appendSlice(app_allocator.allocator(), restore);
        }
    }
    if (scrollback_cursor.epoch != draw.scrollback_epoch) {
        scrollback_cursor.epoch = draw.scrollback_epoch;
        scrollback_cursor.seen_rows = 0;
    }
    scrollback_cursor.seen_rows +|= draw.scroll_count;
    if (cursor_row) |row| row.* = draw.cursor_row;
}

fn parseDrawPayload(payload: []const u8) !DrawPayload {
    var message = try protocol.decodePayload(pb.Draw, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    if (message.cursor_row > std.math.maxInt(u16)) return error.IntOutOfRange;
    return .{
        .scrollback_epoch = message.scrollback_epoch,
        .scroll_count = message.scroll_count,
        .cursor_row = @intCast(message.cursor_row),
        .draw_bytes = try app_allocator.allocator().dupe(u8, message.draw_bytes),
        .request_seq_number = message.request_seq_number,
        .relay_end_restore_bytes = if (message.relay_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.relay_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
}

fn maybeSendResize(socket_fd: c.fd_t, last_size: *WindowSize) void {
    const size = terminal.currentWindowSize();
    if (size.rows == last_size.rows and size.cols == last_size.cols) return;
    last_size.* = size;
    sendResize(socket_fd, size) catch {};
}

fn sendResize(socket_fd: c.fd_t, size: WindowSize) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Resize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_RESIZE, payload);
}

fn sendRepaint(socket_fd: c.fd_t, include_scrollback: bool) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Repaint{ .include_scrollback = include_scrollback });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_REPAINT, payload);
}

fn sendInput(socket_fd: c.fd_t, bytes: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Input{ .data = bytes });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_INPUT, payload);
}

fn sendPingRequest(socket_fd: c.fd_t) !u64 {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.PingRequest{});
    defer app_allocator.allocator().free(payload);
    return protocol.sendFrameWithAllocatedSeq(socket_fd, .FRAME_TYPE_PING_REQUEST, payload);
}

fn sendUnrecognizedFrame(socket_fd: c.fd_t, seq: u64, frame_type: u32) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.UnrecognizedFrame{
        .seq = seq,
        .frame_type = frame_type,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_UNRECOGNIZED, payload);
}

fn sendInputChunks(socket_fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + input_chunk_bytes, bytes.len);
        try sendInput(socket_fd, bytes[offset..end]);
        offset = end;
    }
}
