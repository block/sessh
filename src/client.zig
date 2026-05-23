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
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");

const pb = protocol.pb;
const hpb = protocol.hpb;
const WindowSize = terminal.WindowSize;
const Leader = terminal.Leader;

var next_repaint_request_seq: u64 = 1;
var next_ping_request_seq: u64 = 1;

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
    alias: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
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
    pending_ping_request_seq: ?u64 = null,
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
        if (self.pending_ping_request_seq == null and self.canSendPing(now)) {
            self.pending_ping_request_seq = try sendPingRequest(write_fd);
            self.ping_sent_ms = now;
            self.last_ping_sent_ms = now;
            self.deferred_ping = false;
        } else if (self.pending_ping_request_seq == null) {
            self.deferred_ping = true;
        }
    }

    fn canSendPing(self: *const ConnectionMonitor, now: i64) bool {
        const last = self.last_ping_sent_ms orelse return true;
        return now - last >= ping_min_interval_ms;
    }

    fn maybeSendPing(self: *ConnectionMonitor, write_fd: c.fd_t) !void {
        if (!self.enabled) return;
        try self.maybeSendPingAt(write_fd, std.time.milliTimestamp());
    }

    fn maybeSendPingAt(self: *ConnectionMonitor, write_fd: c.fd_t, now: i64) !void {
        if (self.pending_ping_request_seq != null or !self.canSendPing(now)) return;
        self.pending_ping_request_seq = try sendPingRequest(write_fd);
        self.ping_sent_ms = now;
        self.last_ping_sent_ms = now;
        self.any_response_wait_started_ms = now;
        self.deferred_ping = false;
    }

    fn noteInboundFrame(self: *ConnectionMonitor) void {
        self.pending_ping_request_seq = null;
        self.any_response_wait_started_ms = null;
        self.deferred_ping = false;
    }

    fn handlePingResponse(self: *ConnectionMonitor, payload: []const u8) !void {
        var response = try protocol.decodePayload(pb.PingResponse, app_allocator.allocator(), payload);
        defer response.deinit(app_allocator.allocator());
        const pending_seq = self.pending_ping_request_seq;
        if (pending_seq != null and response.ping_request_seq == pending_seq.?) {
            const rtt_ms = @max(std.time.milliTimestamp() - self.ping_sent_ms, 0);
            self.updateRtt(rtt_ms);
        }
        self.pending_ping_request_seq = null;
        self.any_response_wait_started_ms = null;
        self.deferred_ping = false;
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
        if (self.deferred_ping and self.pending_ping_request_seq == null) {
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
        return self.isUnresponsiveAt(std.time.milliTimestamp());
    }

    fn isUnresponsiveAt(self: *const ConnectionMonitor, now: i64) bool {
        if (!self.enabled) return false;
        if (self.deferred_ping and self.pending_ping_request_seq == null) return false;
        const started = self.any_response_wait_started_ms orelse return false;
        return now - started >= self.responsivenessTimeoutMs();
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

const max_scrollback_cursor_bytes = 64;

pub const ScrollbackCursor = struct {
    bytes: [max_scrollback_cursor_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ScrollbackCursor) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *ScrollbackCursor, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len) return error.ScrollbackCursorTooLarge;
        @memcpy(self.bytes[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

const PendingRepaint = struct {
    repaint_request_seq: u64 = 0,

    fn active(self: PendingRepaint) bool {
        return self.repaint_request_seq != 0;
    }

    fn start(self: *PendingRepaint) u64 {
        self.repaint_request_seq = allocateRepaintRequestSeq();
        return self.repaint_request_seq;
    }

    fn matches(self: PendingRepaint, repaint_request_seq: u64) bool {
        return self.repaint_request_seq == repaint_request_seq;
    }

    fn clear(self: *PendingRepaint) void {
        self.repaint_request_seq = 0;
    }
};

/// Client-side state carried across runtime transports for one attached session.
pub const RuntimeSession = struct {
    guid: [36]u8 = [_]u8{0} ** 36,
    guid_len: usize = 0,
    primary_alias: [128]u8 = [_]u8{0} ** 128,
    primary_alias_len: usize = 0,
    scrollback_cursor: ScrollbackCursor = .{},
    viewport_offset: i32 = 0,
    /// Latest outstanding RepaintRequest sequence. Older responses are stale.
    pending_repaint: PendingRepaint = .{},
    relay_end_restore: std.ArrayList(u8) = .empty,

    pub fn adoptReconnectState(self: *RuntimeSession, reconnected: *const RuntimeSession) void {
        self.pending_repaint = reconnected.pending_repaint;
    }

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        if (self.primary_alias_len > 0) return self.primary_alias[0..self.primary_alias_len];
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const RuntimeSession) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn setIdentity(self: *RuntimeSession, guid: []const u8) !void {
        if (guid.len > self.guid.len) return error.SessionGuidTooLarge;
        @memcpy(self.guid[0..guid.len], guid);
        self.guid_len = guid.len;
        self.primary_alias_len = 0;

        const alias = (try session_registry.primaryAliasForGuid(app_allocator.allocator(), guid)) orelse return;
        defer app_allocator.allocator().free(alias);
        if (alias.len > self.primary_alias.len) return error.SessionAliasTooLarge;
        @memcpy(self.primary_alias[0..alias.len], alias);
        self.primary_alias_len = alias.len;
    }
};

pub const ReconnectUi = struct {
    const reconnected_banner_ms = 500;

    mode_guard: terminal.TerminalModeGuard,
    escape_filter: terminal.EscapeFilter = .{ .at_line_start = false },
    buffered_input: std.ArrayList(u8) = .empty,
    viewport_offset: u16 = 0,
    banner_row: ?u16 = null,
    cursor_hidden: bool = false,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn begin(viewport_offset: i32) !ReconnectUi {
        var ui = ReconnectUi{ .mode_guard = try terminal.TerminalModeGuard.enable(0) };
        ui.viewport_offset = if (viewport_offset > 0) @intCast(viewport_offset) else 0;
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
        const banner = self.banner_row orelse return;
        const renderer = client_renderer.Renderer.init(1);
        try renderer.moveCursor(banner, 0);
        try renderer.clearLine();
        try renderer.moveCursor(self.viewport_offset, 0);
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
        const top_row = self.viewport_offset;
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
    scrollback_cursor: []const u8,
    viewport_offset: i32,
    draw_bytes: []const u8,
    relay_end_restore_bytes: ?[]const u8,
};

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
    try std.testing.expectEqual(@as(?u64, null), monitor.pending_ping_request_seq);
    try std.testing.expect(monitor.deferred_ping);
    try std.testing.expectEqual(@as(?i64, 1_100), monitor.any_response_wait_started_ms);
    try std.testing.expect(!monitor.isUnresponsive());

    try monitor.maybeSendPingAt(fds[1], 2_000);
    const pending = monitor.pending_ping_request_seq orelse return error.ExpectedPendingPing;
    try std.testing.expect(!monitor.deferred_ping);
    try std.testing.expectEqual(@as(?i64, 2_000), monitor.any_response_wait_started_ms);

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.ping_request, frame.message_type);
    var request = try protocol.decodePayload(pb.PingRequest, std.testing.allocator, frame.payload);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(pending, request.ping_request_seq);
}

test "connection monitor probes idle connections" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var monitor = ConnectionMonitor{ .enabled = true };

    try monitor.maybeSendPingAt(fds[1], 1_000);
    const pending = monitor.pending_ping_request_seq orelse return error.ExpectedPendingPing;
    try std.testing.expectEqual(@as(?i64, 1_000), monitor.any_response_wait_started_ms);
    try std.testing.expect(!monitor.isUnresponsiveAt(2_999));
    try std.testing.expect(monitor.isUnresponsiveAt(3_000));

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.ping_request, frame.message_type);
    var request = try protocol.decodePayload(pb.PingRequest, std.testing.allocator, frame.payload);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(pending, request.ping_request_seq);
}

test "connection monitor treats any inbound frame as ping response progress" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var monitor = ConnectionMonitor{ .enabled = true };

    try monitor.afterInputAt(fds[1], 1_000);
    _ = monitor.pending_ping_request_seq orelse return error.ExpectedPendingPing;

    monitor.noteInboundFrame();
    try std.testing.expectEqual(@as(?u64, null), monitor.pending_ping_request_seq);
    try std.testing.expectEqual(@as(?i64, null), monitor.any_response_wait_started_ms);

    try monitor.maybeSendPingAt(fds[1], 2_000);
    try std.testing.expect(monitor.pending_ping_request_seq != null);
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
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .relay_end_restore_bytes = "restore-primary",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .draw, payload);

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.relay_end_restore.items);
}

test "recovery polling ignores draw while repaint is outstanding" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{ .pending_repaint = .{ .repaint_request_seq = 7 } };
    defer session.relay_end_restore.deinit(app_allocator.allocator());

    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Draw{
        .scrollback_cursor = "stale-cursor",
        .viewport_offset = 3,
        .draw_bytes = "",
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fds[1], .draw, payload);

    try std.testing.expectEqual(@as(?RuntimeRecovery, null), try pollRuntimeRecovery(fds[0], &session, 0));
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);
    try std.testing.expect(session.pending_repaint.active());
}

test "repaint response applies only latest outstanding request" {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintResponse{
        .repaint_request_seq = 7,
        .draw = .{
            .scrollback_cursor = "cursor-v7",
            .viewport_offset = 4,
            .draw_bytes = "",
            .relay_end_restore_bytes = "restore-v7",
        },
    });
    defer app_allocator.allocator().free(payload);

    var restore = std.ArrayList(u8).empty;
    defer restore.deinit(app_allocator.allocator());
    var cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var no_pending = PendingRepaint{};
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &no_pending));
    try std.testing.expectEqual(@as(usize, 0), cursor.len);
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);

    var older_pending = PendingRepaint{ .repaint_request_seq = 8 };
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &older_pending));
    try std.testing.expectEqual(@as(u64, 8), older_pending.repaint_request_seq);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    var matching_pending = PendingRepaint{ .repaint_request_seq = 7 };
    try std.testing.expect(try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &matching_pending));
    try std.testing.expect(!matching_pending.active());
    try std.testing.expectEqualStrings("cursor-v7", cursor.slice());
    try std.testing.expectEqual(@as(i32, 4), viewport_offset);
    try std.testing.expectEqualStrings("restore-v7", restore.items);
}

test "reconnect waits for repaint response before returning" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 77;

    const hello_ok = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(hello_ok);
    try protocol.sendFrame(remote_to_client[1], .hello_ok, hello_ok);

    const hello_request = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(hello_request);
    try protocol.sendFrame(remote_to_client[1], .hello_request, hello_request);

    const session_attached = try protocol.encodePayload(app_allocator.allocator(), pb.SessionAttached{});
    defer app_allocator.allocator().free(session_attached);
    try protocol.sendFrame(remote_to_client[1], .session_attached, session_attached);

    const repaint_response = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintResponse{
        .repaint_request_seq = 77,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 5,
            .draw_bytes = "",
        },
    });
    defer app_allocator.allocator().free(repaint_response);
    try protocol.sendFrame(remote_to_client[1], .repaint_response, repaint_response);

    var session = RuntimeSession{};
    defer session.relay_end_restore.deinit(app_allocator.allocator());
    try session.scrollback_cursor.set("old-cursor");

    try reconnectSessionOnRuntime(remote_to_client[0], client_to_remote[1], &session);

    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 5), session.viewport_offset);
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
    if (options.state_dir) |dir| socket_transport.setRuntimeRootOverride(dir);

    return runBrokerClient(allocator, args, options);
}

fn runBrokerClient(allocator: std.mem.Allocator, args: []const []const u8, options: LocalOptions) !void {
    var broker_arg_buf: [2][]const u8 = undefined;
    const state_broker_args = brokerStateArgs(options, &broker_arg_buf);
    switch (options.action) {
        .list => {
            var command_args_buf: [3][]const u8 = undefined;
            const command_args = appendBrokerCommand(state_broker_args, "--list", null, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var command_args_buf: [4][]const u8 = undefined;
            const command_args = appendBrokerCommand(state_broker_args, "--kill", options.kill_id.?, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill_all => {
            var command_args_buf: [3][]const u8 = undefined;
            const command_args = appendBrokerCommand(state_broker_args, "--kill-all", null, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .new, .attach => {},
    }

    var generated_guid: ?[]u8 = null;
    defer if (generated_guid) |guid| allocator.free(guid);
    var generated_alias: ?[]u8 = null;
    defer if (generated_alias) |alias| allocator.free(alias);
    var attach_guid: ?[]u8 = null;
    defer if (attach_guid) |guid| allocator.free(guid);

    if (options.action == .new) {
        generated_guid = try session_registry.generateGuid(allocator);
        if (options.alias) |alias| {
            try session_registry.createAlias(allocator, alias, generated_guid.?);
            generated_alias = try allocator.dupe(u8, alias);
        } else {
            generated_alias = try session_registry.createGeneratedAlias(allocator, generated_guid.?);
        }
    } else if (options.attach_id) |ref| {
        attach_guid = try session_registry.resolveRefToGuid(allocator, ref);
    }

    var child = try startLocalBroker(allocator, args[0], state_broker_args);
    var session = (switch (options.action) {
        .new => startNewSessionOnRuntime(
            child.stdout.?.handle,
            child.stdin.?.handle,
            options.scrollback_row_count,
            generated_guid.?,
        ),
        .attach => startAttachSessionOnRuntime(
            child.stdout.?.handle,
            child.stdin.?.handle,
            attach_guid orelse "",
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
                if (!anySessionExistsViaBroker(allocator, args[0])) {
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\nsessh: reconnecting; type <enter>~. to abort\r\n");
        child = startLocalBroker(allocator, args[0], state_broker_args) catch |err| {
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

fn brokerStateArgs(options: LocalOptions, buf: *[2][]const u8) []const []const u8 {
    if (options.state_dir) |dir| {
        buf[0] = "--state-dir";
        buf[1] = dir;
        return buf[0..2];
    }
    return buf[0..0];
}

fn appendBrokerCommand(
    state_args: []const []const u8,
    command: []const u8,
    value: ?[]const u8,
    buf: [][]const u8,
) []const []const u8 {
    @memcpy(buf[0..state_args.len], state_args);
    buf[state_args.len] = command;
    if (value) |arg| {
        buf[state_args.len + 1] = arg;
        return buf[0 .. state_args.len + 2];
    }
    return buf[0 .. state_args.len + 1];
}

fn startLocalBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !std.process.Child {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-host-broker:";
    @memcpy(argv[2..], broker_args);
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn runLocalBrokerCommand(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) !u8 {
    const argv = try allocator.alloc([]const u8, 2 + broker_args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-host-broker:";
    @memcpy(argv[2..], broker_args);

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn sessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8, session_id: []const u8) bool {
    return brokerListMatches(allocator, exe, session_id);
}

fn anySessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8) bool {
    return brokerListMatches(allocator, exe, null);
}

fn brokerListMatches(allocator: std.mem.Allocator, exe: []const u8, session_id: ?[]const u8) bool {
    const argv = [_][]const u8{ exe, ":internal-host-broker:", "--list" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    if (session_id) |id| return listContainsSession(result.stdout, id);
    return listHasAnySession(result.stdout);
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
        } else if (std.mem.eql(u8, arg, "--alias")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingAlias;
            if (!session_registry.isValidAlias(args[i])) return error.InvalidAlias;
            options.alias = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingStateDir;
            options.state_dir = args[i];
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

pub fn startNewSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
    session_guid: []const u8,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    try sendSessionNew(write_fd, terminal.currentWindowSize(), scrollback_row_count, viewport_offset, session_guid);
    var session = try readRuntimeSession(read_fd);
    session.viewport_offset = viewport_offset orelse 0;
    return session;
}

pub fn startAttachSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_guid: []const u8,
    initial_scrollback_row_count: ?u32,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    const repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), viewport_offset, initial_scrollback_row_count, null, session_guid);
    var session = try readRuntimeSession(read_fd);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn reconnectSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, null, true);
}

pub fn reconnectSessionOnRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: *const std.atomic.Value(bool),
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, cancelled, false);
}

fn reconnectSessionOnRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
    wait_for_repaint: bool,
) !void {
    try runtimeHandshakeInner(read_fd, write_fd, cancelled);
    session.pending_repaint.repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), nonZeroViewportOffset(session.viewport_offset), null, &session.scrollback_cursor, session.guidSlice());
    try readSessionAttachedInner(read_fd, cancelled);
    if (wait_for_repaint) try finishReconnectRepaintInner(read_fd, session, cancelled);
}

pub fn finishReconnectRepaint(
    read_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try finishReconnectRepaintInner(read_fd, session, null);
}

pub fn repaintRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try sendScreenRepaint(write_fd, &session.pending_repaint);
    try finishReconnectRepaint(read_fd, session);
}

fn finishReconnectRepaintInner(
    read_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    while (session.pending_repaint.active()) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .draw => {},
            .repaint_response => {
                _ = try handleRepaintResponseFrame(
                    frame.payload,
                    &session.relay_end_restore,
                    &session.scrollback_cursor,
                    &session.viewport_offset,
                    &session.pending_repaint,
                );
            },
            .ping_response => {},
            .session_ended => return error.SessionEnded,
            .error_message => {
                try printErrorPayload(frame.payload);
                return error.RemoteError;
            },
            else => return error.UnexpectedFrame,
        }
    }
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
        leader,
        &session.scrollback_cursor,
        &session.viewport_offset,
        &session.pending_repaint,
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
        .draw => {
            if (session.pending_repaint.active()) return null;
            try handleDrawFrame(frame.payload, &session.relay_end_restore, &session.scrollback_cursor, &session.viewport_offset);
            return .recovered;
        },
        .repaint_response => {
            const applied = try handleRepaintResponseFrame(
                frame.payload,
                &session.relay_end_restore,
                &session.scrollback_cursor,
                &session.viewport_offset,
                &session.pending_repaint,
            );
            return if (applied) .recovered else null;
        },
        .ping_response => return .recovered,
        .session_ended => {
            _ = finishRelay(.session_ended, &session.relay_end_restore);
            return .session_ended;
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            _ = finishRelay(.session_ended, &session.relay_end_restore);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

pub fn writeDetachBannerForTarget(ssh_options: []const []const u8, target: []const u8, sessh_options: []const []const u8, session_id: []const u8) void {
    if (c.isatty(1) == 0) return;
    writeDetachBannerForTargetInner(ssh_options, target, sessh_options, session_id) catch {};
}

pub fn writeDetachBannerForSessionRef(sessh_options: []const []const u8, session_ref: []const u8) void {
    if (c.isatty(1) == 0) return;
    writeDetachBannerForSessionRefInner(sessh_options, session_ref) catch {};
}

fn writeDetachBannerForSessionRefInner(sessh_options: []const []const u8, session_ref: []const u8) !void {
    try io_helpers.writeAll(1, "--- sessh: detached. To re-attach: `");
    try writeShellArg(1, "sessh");
    for (sessh_options) |arg| {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, arg);
    }
    try io_helpers.writeAll(1, " --attach");
    if (session_ref.len > 0) {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, session_ref);
    }
    try io_helpers.writeAll(1, "` ---\r\n");
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
    try io_helpers.writeAll(1, " --attach");
    if (session_id.len > 0) {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, session_id);
    }
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
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), read_fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
                if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                    freeErrorPayload(parsed);
                    return error.VersionMismatch;
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .session_attached => {
                var attached = try protocol.decodePayload(pb.SessionAttached, app_allocator.allocator(), frame.payload);
                defer attached.deinit(app_allocator.allocator());
                var session = RuntimeSession{};
                try session.setIdentity(attached.session_guid);
                return session;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn queryInitialViewportOffset() ?i32 {
    const position = terminal.queryCursorPosition(0, 1) catch return null;
    return if (position) |value| @intCast(value.row) else null;
}

fn nonZeroViewportOffset(viewport_offset: i32) ?i32 {
    return if (viewport_offset == 0) null else viewport_offset;
}

fn readSessionAttached(conn: c.fd_t) !void {
    return readSessionAttachedInner(conn, null);
}

fn readSessionAttachedInner(
    conn: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(conn, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
                if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
                    freeErrorPayload(parsed);
                    return error.VersionMismatch;
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .session_attached => {
                var attached = try protocol.decodePayload(pb.SessionAttached, app_allocator.allocator(), frame.payload);
                defer attached.deinit(app_allocator.allocator());
                return;
            },
            else => return error.UnexpectedFrame,
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
    var hello_error = try readHelloReply(read_fd, cancelled);
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
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}

fn readHelloReply(
    read_fd: c.fd_t,
    cancelled: ?*const std.atomic.Value(bool),
) !?hpb.HelloError {
    while (true) {
        var frame = try readFrameAllocMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(hpb.HelloOk, app_allocator.allocator(), frame.payload);
                defer ok.deinit(app_allocator.allocator());
                return null;
            },
            .hello_error => {
                const err = try protocol.decodePayload(hpb.HelloError, app_allocator.allocator(), frame.payload);
                return err;
            },
            else => return error.UnexpectedFrame,
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
            .hello_request => return protocol.decodePayload(hpb.HelloRequest, app_allocator.allocator(), frame.payload),
            else => {
                try sendHelloError(write_fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return error.UnexpectedFrame;
            },
        }
    }
}

fn helloRequestIsCompatible(hello: hpb.HelloRequest) bool {
    return protocol.helloRequestIsCompatible(hello, config.protocol_major, config.protocol_minor, config.version);
}

fn errorPayloadFromHelloError(response_error: hpb.HelloError) ErrorPayload {
    return .{
        .code = response_error.code,
        .message = response_error.message,
        .hint = response_error.hint orelse "",
    };
}

fn sendSessionNew(
    conn: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    viewport_offset: ?i32,
    session_guid: []const u8,
) !void {
    var message = pb.SessionNew{
        .resize = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
            .viewport_offset = viewport_offset,
        },
        .scrollback_row_limit = scrollback_row_count,
        .session_guid = session_guid,
    };
    defer message.environment.deinit(app_allocator.allocator());
    const default_colors = queryDefaultColorsForSession();
    message.query_default_colors = .{
        .foreground_color = default_colors.foreground_color,
        .background_color = default_colors.background_color,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .session_new, payload);
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
    size: WindowSize,
    viewport_offset: ?i32,
    initial_scrollback_row_count: ?u32,
    reconnect_cursor: ?*const ScrollbackCursor,
    session_guid: []const u8,
) !u64 {
    const repaint_request_seq = allocateRepaintRequestSeq();
    const message = pb.SessionAttach{
        .resize = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
            .viewport_offset = viewport_offset,
            .repaint_request = if (reconnect_cursor) |cursor| .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = cursor.slice(),
            } else .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = if (initial_scrollback_row_count != null and initial_scrollback_row_count.? == 0)
                    null
                else
                    "",
                .initial_scrollback_rows = initial_scrollback_row_count,
            },
        },
        .session_guid = session_guid,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .session_attach, payload);
    return repaint_request_seq;
}

fn readSessionEndedOrError(conn: c.fd_t) !bool {
    while (true) {
        var frame = try protocol.readFrameAlloc(app_allocator.allocator(), conn);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                try printErrorPayload(frame.payload);
                return true;
            },
            .session_ended => return false,
            else => return error.UnexpectedFrame,
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

fn listHasAnySession(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len != 0) return true;
    }
    return false;
}

fn relayInteractive(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    leader: Leader,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
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
        leader,
        &presentation_guard,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
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
    leader: Leader,
    presentation_guard: *client_renderer.PresentationGuard,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
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
        try connection_monitor.maybeSendPing(write_fd);
        _ = try posix.poll(&pollfds, connection_monitor.pollTimeoutMs());
        try connection_monitor.maybeSendPing(write_fd);
        maybeSendResize(write_fd, &last_size, scrollback_cursor, viewport_offset, pending_repaint);

        if (connection_monitor.isUnresponsive()) {
            return .unresponsive;
        }

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
            defer frame.deinit(app_allocator.allocator());
            switch (frame.message_type) {
                .draw => {
                    connection_monitor.noteInboundFrame();
                    if (!pending_repaint.active()) {
                        try handleDrawFrame(frame.payload, relay_end_restore, scrollback_cursor, viewport_offset);
                    }
                },
                .repaint_response => {
                    connection_monitor.noteInboundFrame();
                    _ = try handleRepaintResponseFrame(
                        frame.payload,
                        relay_end_restore,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                    );
                },
                .ping_response => try connection_monitor.handlePingResponse(frame.payload),
                .session_ended => {
                    connection_monitor.noteInboundFrame();
                    return finishRelay(.session_ended, relay_end_restore);
                },
                .error_message => {
                    connection_monitor.noteInboundFrame();
                    try printErrorPayload(frame.payload);
                    return finishRelay(.session_ended, relay_end_restore);
                },
                else => return error.UnexpectedFrame,
            }
        }
        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishRelay(requestSessionDetach(read_fd, write_fd), relay_end_restore);
            const result = escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) {
                try sendInputChunks(write_fd, result.bytes);
                try connection_monitor.afterInput(write_fd);
            }
            if (result.end) |end| switch (end) {
                .detach => return finishRelay(requestSessionDetach(read_fd, write_fd), relay_end_restore),
                .repaint => sendRepaint(write_fd, "", pending_repaint) catch return .transport_closed,
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

fn requestSessionDetach(read_fd: c.fd_t, write_fd: c.fd_t) RelayEnd {
    _ = read_fd;
    _ = write_fd;
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
    viewport_offset: *i32,
) !void {
    const draw = try parseDrawPayload(payload);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, relay_end_restore, scrollback_cursor, viewport_offset);
}

fn handleRepaintResponseFrame(
    payload: []const u8,
    relay_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
) !bool {
    var response = try protocol.decodePayload(pb.RepaintResponse, app_allocator.allocator(), payload);
    defer response.deinit(app_allocator.allocator());
    if (!pending_repaint.active() or !pending_repaint.matches(response.repaint_request_seq)) return false;
    const response_draw = response.draw orelse return error.MissingDraw;
    const draw = try drawPayloadFromMessage(response_draw);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, relay_end_restore, scrollback_cursor, viewport_offset);
    pending_repaint.clear();
    return true;
}

fn handleDrawPayload(
    draw: DrawPayload,
    relay_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
) !void {
    try io_helpers.writeAll(1, draw.draw_bytes);
    if (relay_end_restore) |target| {
        if (draw.relay_end_restore_bytes) |restore| {
            target.clearRetainingCapacity();
            try target.appendSlice(app_allocator.allocator(), restore);
        }
    }
    try scrollback_cursor.set(draw.scrollback_cursor);
    viewport_offset.* = draw.viewport_offset;
}

fn parseDrawPayload(payload: []const u8) !DrawPayload {
    var message = try protocol.decodePayload(pb.Draw, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return drawPayloadFromMessage(message);
}

fn drawPayloadFromMessage(message: pb.Draw) !DrawPayload {
    if (message.viewport_offset) |offset| {
        if (offset < -1) return error.InvalidViewportOffset;
        if (offset > std.math.maxInt(u16)) return error.IntOutOfRange;
    }
    if (message.scrollback_cursor.len == 0) return error.MissingScrollbackCursor;
    return .{
        .scrollback_cursor = try app_allocator.allocator().dupe(u8, message.scrollback_cursor),
        .viewport_offset = message.viewport_offset orelse 0,
        .draw_bytes = try app_allocator.allocator().dupe(u8, message.draw_bytes),
        .relay_end_restore_bytes = if (message.relay_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.scrollback_cursor);
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.relay_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
}

fn maybeSendResize(
    socket_fd: c.fd_t,
    last_size: *WindowSize,
    scrollback_cursor: *const ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
) void {
    const size = terminal.currentWindowSize();
    if (size.rows == last_size.rows and size.cols == last_size.cols) return;
    last_size.* = size;
    const resize_viewport_offset: i32 = if (viewport_offset.* == 0) 0 else -1;
    viewport_offset.* = resize_viewport_offset;
    sendResizeWithRepaint(socket_fd, size, scrollback_cursor, resize_viewport_offset, pending_repaint) catch {
        pending_repaint.clear();
    };
}

fn sendResize(socket_fd: c.fd_t, size: WindowSize) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Resize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .resize, payload);
}

fn sendResizeWithRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
    scrollback_cursor: *const ScrollbackCursor,
    viewport_offset: i32,
    pending_repaint: *PendingRepaint,
) !void {
    const repaint_request_seq = pending_repaint.start();
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Resize{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
        .viewport_offset = nonZeroViewportOffset(viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
            .scrollback_cursor = scrollback_cursor.slice(),
        },
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .resize, payload);
}

fn sendRepaint(socket_fd: c.fd_t, scrollback_cursor: []const u8, pending_repaint: *PendingRepaint) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintRequest{
        .repaint_request_seq = pending_repaint.start(),
        .scrollback_cursor = scrollback_cursor,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .repaint_request, payload);
}

fn sendScreenRepaint(socket_fd: c.fd_t, pending_repaint: *PendingRepaint) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintRequest{
        .repaint_request_seq = pending_repaint.start(),
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .repaint_request, payload);
}

fn allocateRepaintRequestSeq() u64 {
    const seq = next_repaint_request_seq;
    next_repaint_request_seq +%= 1;
    if (next_repaint_request_seq == 0) next_repaint_request_seq = 1;
    return seq;
}

fn sendInput(socket_fd: c.fd_t, bytes: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Input{ .data = bytes });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .input, payload);
}

fn sendPingRequest(socket_fd: c.fd_t) !u64 {
    const ping_request_seq = allocatePingRequestSeq();
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.PingRequest{
        .ping_request_seq = ping_request_seq,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .ping_request, payload);
    return ping_request_seq;
}

fn allocatePingRequestSeq() u64 {
    const seq = next_ping_request_seq;
    next_ping_request_seq +%= 1;
    if (next_ping_request_seq == 0) next_ping_request_seq = 1;
    return seq;
}

fn sendInputChunks(socket_fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + input_chunk_bytes, bytes.len);
        try sendInput(socket_fd, bytes[offset..end]);
        offset = end;
    }
}
