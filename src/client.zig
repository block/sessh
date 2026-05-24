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
const tty_transcript = @import("tty_transcript.zig");

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
    runtime_dir: ?[]const u8 = null,
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
    capture_tty_transcript: ?[]const u8 = null,
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

const CreatedSession = struct {
    guid: []u8,
    alias: []u8,

    fn deinit(self: *CreatedSession, allocator: std.mem.Allocator) void {
        allocator.free(self.alias);
        allocator.free(self.guid);
        self.* = undefined;
    }
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
    guid: [session_registry.session_guid_len]u8 = [_]u8{0} ** session_registry.session_guid_len,
    guid_len: usize = 0,
    client_guid: [session_registry.client_guid_len]u8 = [_]u8{0} ** session_registry.client_guid_len,
    client_guid_len: usize = 0,
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

    pub fn deinit(self: *RuntimeSession) void {
        self.relay_end_restore.deinit(app_allocator.allocator());
        self.relay_end_restore = .empty;
    }

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        if (self.primary_alias_len > 0) return self.primary_alias[0..self.primary_alias_len];
        return self.guidSlice();
    }

    pub fn guidSlice(self: *const RuntimeSession) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn clientGuidSlice(self: *const RuntimeSession) []const u8 {
        return self.client_guid[0..self.client_guid_len];
    }

    pub fn ensureClientGuid(self: *RuntimeSession) ![]const u8 {
        if (self.client_guid_len == 0) {
            const generated = try session_registry.generateClientGuid(app_allocator.allocator());
            defer app_allocator.allocator().free(generated);
            try self.setClientGuid(generated);
        }
        return self.clientGuidSlice();
    }

    pub fn setClientGuid(self: *RuntimeSession, client_guid: []const u8) !void {
        if (!session_registry.isValidClientGuid(client_guid)) return error.InvalidClientGuid;
        if (client_guid.len > self.client_guid.len) return error.ClientGuidTooLarge;
        @memcpy(self.client_guid[0..client_guid.len], client_guid);
        self.client_guid_len = client_guid.len;
    }

    pub fn setIdentity(self: *RuntimeSession, guid: []const u8) !void {
        return self.setIdentityWithAlias(guid, "");
    }

    pub fn setIdentityWithAlias(self: *RuntimeSession, guid: []const u8, alias: []const u8) !void {
        if (guid.len > self.guid.len) return error.SessionGuidTooLarge;
        @memcpy(self.guid[0..guid.len], guid);
        self.guid_len = guid.len;
        self.primary_alias_len = 0;
        tty_transcript.setSessionGuid(guid);

        if (alias.len > 0) {
            try self.setPrimaryAlias(alias);
            return;
        }

        const local_alias = (try session_registry.primaryAliasForGuid(app_allocator.allocator(), guid)) orelse return;
        defer app_allocator.allocator().free(local_alias);
        try self.setPrimaryAlias(local_alias);
    }

    fn setPrimaryAlias(self: *RuntimeSession, alias: []const u8) !void {
        if (alias.len > self.primary_alias.len) return error.SessionAliasTooLarge;
        @memcpy(self.primary_alias[0..alias.len], alias);
        self.primary_alias_len = alias.len;
    }
};

pub const ReconnectUi = struct {
    const reconnected_banner_ms = 500;
    const max_diagnostic_banner_lines = 3;
    const max_banner_message_bytes = 256;

    mode_guard: terminal.TerminalModeGuard,
    escape_filter: terminal.EscapeFilter = .{ .at_line_start = false },
    buffered_input: std.ArrayList(u8) = .empty,
    viewport_offset: u16 = 0,
    banner_state: ?BannerDrawState = null,
    banner_message: [max_banner_message_bytes]u8 = undefined,
    banner_message_len: usize = 0,
    diagnostic_notify_read_fd: c.fd_t = -1,
    diagnostic_notify_write_fd: c.fd_t = -1,
    diagnostic_cursor: u64 = 0,
    live_diagnostic_start_seq: u64 = 0,
    rendered_diagnostic_seq: u64 = 0,
    diagnostic_lines: [max_diagnostic_banner_lines]BannerDiagnosticLine = [_]BannerDiagnosticLine{.{}} ** max_diagnostic_banner_lines,
    diagnostic_line_count: usize = 0,
    cursor_hidden: bool = false,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn begin(viewport_offset: i32) !ReconnectUi {
        var ui = ReconnectUi{ .mode_guard = try terminal.TerminalModeGuard.enable(0) };
        errdefer ui.mode_guard.restore();
        ui.viewport_offset = if (viewport_offset > 0) @intCast(viewport_offset) else 0;
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
        try ui.hideCursor();
        return ui;
    }

    pub fn deinit(self: *ReconnectUi) void {
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
            const decision = try self.pollInput(wait_ms);
            try self.refreshBannerIfDiagnosticsChanged();
            switch (decision) {
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
        try self.refreshBannerIfDiagnosticsChanged();
        const decision = try self.pollInput(timeout_ms);
        try self.refreshBannerIfDiagnosticsChanged();
        return switch (decision) {
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
        const ready = try posix.poll(pollfds[0..poll_count], timeout_ms);
        if (ready == 0) return .wait_elapsed;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .abort;
        if (poll_count > 1 and (pollfds[1].revents & posix.POLL.IN) != 0) {
            self.drainDiagnosticNotifier();
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(0, &input, input.len);
        if (n <= 0) return .abort;
        io_helpers.noteRead(0, input[0..@intCast(n)]);

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

    pub fn clearBanner(self: *ReconnectUi) !i32 {
        if (c.isatty(1) == 0) return @intCast(self.viewport_offset);
        const banner = self.banner_state orelse return @intCast(self.viewport_offset);
        const renderer = client_renderer.Renderer.init(1);
        const size = terminal.currentWindowSize();
        try eraseBannerRows(renderer, banner, size.rows, size.cols);
        try restoreBannerExpansion(renderer, banner, size.rows);
        self.viewport_offset = clearedViewportOffset(banner);
        self.banner_state = null;
        try renderer.moveCursor(self.viewport_offset, 0);
        return @intCast(self.viewport_offset);
    }

    pub fn currentViewportOffset(self: *const ReconnectUi) i32 {
        return @intCast(self.viewport_offset);
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
        const copy_len = @min(message.len, self.banner_message.len);
        @memcpy(self.banner_message[0..copy_len], message[0..copy_len]);
        self.banner_message_len = copy_len;
        try self.consumeDiagnostics();
        try self.drawCurrentBanner();
    }

    fn drawCurrentBanner(self: *ReconnectUi) !void {
        const message = self.banner_message[0..self.banner_message_len];

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
        const max_visible_diagnostic_lines: usize = if (size.rows > 1)
            @min(max_diagnostic_banner_lines, @as(usize, size.rows - 1))
        else
            0;
        const diagnostic_start = if (self.diagnostic_line_count > max_visible_diagnostic_lines)
            self.diagnostic_line_count - max_visible_diagnostic_lines
        else
            0;
        var banner_lines: [1 + max_diagnostic_banner_lines]BannerLine = undefined;
        var banner_line_count: usize = 0;
        banner_lines[banner_line_count] = .{ .text = message, .alignment = .center };
        banner_line_count += 1;
        for (self.diagnostic_lines[diagnostic_start..self.diagnostic_line_count]) |*line| {
            banner_lines[banner_line_count] = .{ .text = line.slice(), .alignment = .left };
            banner_line_count += 1;
        }
        const renderer = client_renderer.Renderer.init(1);
        const state = try drawBannerLines(renderer, size, self.viewport_offset, self.banner_state, banner_lines[0..banner_line_count]);
        self.viewport_offset = state.viewport_offset;
        self.banner_state = state;
    }

    fn refreshBannerIfDiagnosticsChanged(self: *ReconnectUi) !void {
        if (self.banner_message_len == 0) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;
        try self.consumeDiagnostics();
        try self.drawCurrentBanner();
    }

    fn consumeDiagnostics(self: *ReconnectUi) !void {
        var diagnostics = [_]client_log.UserDiagnosticLine{.{}} ** max_diagnostic_banner_lines;
        const new_cursor = client_log.copyUserDiagnosticsSince(self.diagnostic_cursor, &diagnostics);
        if (new_cursor == self.diagnostic_cursor) {
            self.rendered_diagnostic_seq = new_cursor;
            return;
        }

        for (&diagnostics) |*diagnostic| {
            if (diagnostic.seq == 0) continue;
            self.appendDiagnosticLine(diagnostic);
        }
        self.diagnostic_cursor = new_cursor;
        self.rendered_diagnostic_seq = new_cursor;
        client_log.markUserDiagnosticsDisplayedThrough(new_cursor);
    }

    fn appendDiagnosticLine(self: *ReconnectUi, diagnostic: *const client_log.UserDiagnosticLine) void {
        if (self.diagnostic_line_count == self.diagnostic_lines.len) {
            var i: usize = 1;
            while (i < self.diagnostic_lines.len) : (i += 1) self.diagnostic_lines[i - 1] = self.diagnostic_lines[i];
            self.diagnostic_line_count -= 1;
        }
        const delayed = diagnostic.seq <= self.live_diagnostic_start_seq;
        const target = &self.diagnostic_lines[self.diagnostic_line_count];
        target.len = formatBannerDiagnostic(target.bytes[0..], diagnostic, delayed);
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

    fn waitForDismiss(self: *ReconnectUi, timeout_ms: u64) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) return;
            const wait_ms: i32 = @intCast(@min(deadline - now, @as(i64, std.math.maxInt(i32))));
            try self.refreshBannerIfDiagnosticsChanged();
            if (try self.pollDismissInput(wait_ms)) return;
            try self.refreshBannerIfDiagnosticsChanged();
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
        io_helpers.noteRead(0, input[0..@intCast(n)]);

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

const BannerAlign = enum {
    left,
    center,
};

const BannerLine = struct {
    text: []const u8,
    alignment: BannerAlign,
};

const BannerDiagnosticLine = struct {
    bytes: [client_log.max_user_diagnostic_display_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const BannerDiagnosticLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

const max_banner_line_count = 1 + ReconnectUi.max_diagnostic_banner_lines;
const max_banner_render_line_bytes = if (ReconnectUi.max_banner_message_bytes > client_log.max_user_diagnostic_display_bytes)
    ReconnectUi.max_banner_message_bytes
else
    client_log.max_user_diagnostic_display_bytes;

const RenderedBannerLine = struct {
    start_col: u16 = 0,
    len: u16 = 0,
    bytes: [max_banner_render_line_bytes]u8 = undefined,

    fn slice(self: *const RenderedBannerLine) []const u8 {
        return self.bytes[0..self.len];
    }

    fn endCol(self: *const RenderedBannerLine) u16 {
        return self.start_col + self.len;
    }

    fn eql(self: *const RenderedBannerLine, other: *const RenderedBannerLine) bool {
        return self.start_col == other.start_col and
            self.len == other.len and
            std.mem.eql(u8, self.slice(), other.slice());
    }
};

const BannerDrawState = struct {
    rows: u16,
    cols: u16,
    start_row: u16,
    line_count: u16,
    viewport_offset: u16,
    restore_viewport_offset: u16,
    scroll_top: u16,
    scroll_lines: u16,
    restores_expansion: bool = true,
    lines: [max_banner_line_count]RenderedBannerLine = [_]RenderedBannerLine{.{}} ** max_banner_line_count,
};

const BannerLayout = struct {
    start_row: u16,
    visible_line_count: u16,
    scroll_lines: u16,
    viewport_offset: u16,
};

fn drawBannerLines(
    renderer: client_renderer.Renderer,
    size: WindowSize,
    viewport_offset: u16,
    previous: ?BannerDrawState,
    lines: []const BannerLine,
) !BannerDrawState {
    const terminal_rows = normalizedTerminalRows(size.rows);
    if (lines.len == 0) {
        if (previous) |state| try eraseBannerRows(renderer, state, terminal_rows, size.cols);
        if (previous) |state| try restoreBannerExpansion(renderer, state, terminal_rows);
        const restored_viewport_offset = if (previous) |state| clearedViewportOffset(state) else viewport_offset;
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

    const layout = bannerLayoutForSize(terminal_rows, viewport_offset, lines.len);
    const clamped_viewport_offset = @min(viewport_offset, terminal_rows - 1);
    const prior_scroll_lines = if (previous) |state| state.scroll_lines else 0;
    const restore_viewport_offset = if (previous) |state| state.restore_viewport_offset else clamped_viewport_offset;
    const scroll_lines = prior_scroll_lines +| layout.scroll_lines;
    const consumes_outer_rows = layout.scroll_lines > 0 and layout.viewport_offset < restore_viewport_offset;
    const restores_expansion = (if (previous) |state| state.restores_expansion else true) and !consumes_outer_rows;
    var next_state = BannerDrawState{
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
        next_state.lines[row_offset] = renderBannerLine(size.cols, lines[row_offset]);
    }

    const can_update_in_place = if (previous) |state|
        layout.scroll_lines == 0 and
            state.rows == terminal_rows and
            state.cols == size.cols and
            state.start_row == layout.start_row
    else
        false;

    if (!can_update_in_place) {
        if (previous) |state| try eraseBannerRows(renderer, state, terminal_rows, size.cols);
    }
    if (layout.scroll_lines > 0) {
        if (restores_expansion) {
            try expandBannerRegion(renderer, layout.viewport_offset, terminal_rows, layout.scroll_lines);
        } else {
            try expandBannerByScrollingTerminal(renderer, terminal_rows, layout.scroll_lines);
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
        try drawRenderedBannerLine(
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
            try eraseRenderedBannerLine(renderer, layout.start_row + row_offset, size.cols, previous.?.lines[row_offset]);
        }
    }
    try renderer.restoreBannerPresentation();
    try renderer.moveCursor(layout.viewport_offset, 0);
    return next_state;
}

fn clearedViewportOffset(self: BannerDrawState) u16 {
    return if (self.restores_expansion) self.restore_viewport_offset else self.viewport_offset;
}

fn eraseBannerRows(renderer: client_renderer.Renderer, state: BannerDrawState, rows: u16, cols: u16) !void {
    const terminal_rows = normalizedTerminalRows(rows);
    try renderer.restoreBannerPresentation();
    var i: u16 = 0;
    while (i < state.line_count) : (i += 1) {
        const row = state.start_row +| i;
        if (row >= terminal_rows) break;
        try eraseRenderedBannerLine(renderer, row, cols, state.lines[i]);
    }
}

fn expandBannerRegion(renderer: client_renderer.Renderer, top: u16, rows: u16, count: u16) !void {
    if (count == 0) return;
    const terminal_rows = normalizedTerminalRows(rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreBannerPresentation();
    try renderer.setScrollRegion(top, bottom);
    try renderer.moveCursor(bottom, 0);
    var i: u16 = 0;
    while (i < count) : (i += 1) try renderer.newline();
    try renderer.resetScrollRegion();
}

fn expandBannerByScrollingTerminal(renderer: client_renderer.Renderer, rows: u16, count: u16) !void {
    if (count == 0) return;
    const terminal_rows = normalizedTerminalRows(rows);
    const bottom = terminal_rows - 1;
    try renderer.restoreBannerPresentation();
    try renderer.moveCursor(bottom, 0);
    var i: u16 = 0;
    while (i < count) : (i += 1) try renderer.newline();
}

fn restoreBannerExpansion(renderer: client_renderer.Renderer, state: BannerDrawState, rows: u16) !void {
    if (state.scroll_lines == 0) return;
    if (!state.restores_expansion) return;
    const terminal_rows = normalizedTerminalRows(rows);
    if (terminal_rows != state.rows) return;
    const bottom = terminal_rows - 1;
    try renderer.restoreBannerPresentation();
    try renderer.setScrollRegion(state.scroll_top, bottom);
    try renderer.moveCursor(state.scroll_top, 0);
    var i: u16 = 0;
    while (i < state.scroll_lines) : (i += 1) try renderer.reverseIndex();
    try renderer.resetScrollRegion();
}

fn renderBannerLine(cols: u16, line: BannerLine) RenderedBannerLine {
    const visible_len = @min(@min(line.text.len, @as(usize, cols)), max_banner_render_line_bytes);
    const col: u16 = switch (line.alignment) {
        .left => 0,
        .center => if (cols > visible_len)
            @intCast((@as(usize, cols) - visible_len) / 2)
        else
            0,
    };
    var rendered = RenderedBannerLine{
        .start_col = col,
        .len = @intCast(visible_len),
    };
    for (line.text[0..visible_len], 0..) |byte, i| {
        rendered.bytes[i] = bannerSafeByte(byte);
    }
    return rendered;
}

fn drawRenderedBannerLine(
    renderer: client_renderer.Renderer,
    row: u16,
    cols: u16,
    line: RenderedBannerLine,
    previous: ?RenderedBannerLine,
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
    try renderer.restoreBannerPresentation();
    try writeSpaces(renderer, line.start_col - cover_start);
    try renderer.writeRaw("\x1b[7m");
    try renderer.writeRaw(line.slice());
    try renderer.writeRaw("\x1b[0m");
    try writeSpaces(renderer, cover_end - line_end);
}

fn eraseRenderedBannerLine(renderer: client_renderer.Renderer, row: u16, cols: u16, line: RenderedBannerLine) !void {
    const start_col = @min(line.start_col, cols);
    const end_col = @min(line.endCol(), cols);
    if (end_col <= start_col) return;
    try renderer.moveCursor(row, start_col);
    try renderer.restoreBannerPresentation();
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

fn bannerSafeByte(byte: u8) u8 {
    return switch (byte) {
        ' '...'~' => byte,
        else => '?',
    };
}

fn normalizedTerminalRows(rows: u16) u16 {
    return if (rows == 0) 1 else rows;
}

fn bannerLayoutForSize(rows: u16, top_row: u16, line_count: usize) BannerLayout {
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

fn formatBannerDiagnostic(
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

test "reconnect banner layout adds rows at terminal bottom" {
    const single = bannerLayoutForSize(1, 0, 1);
    try std.testing.expectEqual(@as(u16, 0), single.start_row);
    try std.testing.expectEqual(@as(u16, 1), single.visible_line_count);
    try std.testing.expectEqual(@as(u16, 1), single.scroll_lines);

    const normal = bannerLayoutForSize(24, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), normal.start_row);
    try std.testing.expectEqual(@as(u16, 0), normal.scroll_lines);

    const bottom = bannerLayoutForSize(24, 23, 1);
    try std.testing.expectEqual(@as(u16, 23), bottom.start_row);
    try std.testing.expectEqual(@as(u16, 1), bottom.scroll_lines);
    try std.testing.expectEqual(@as(u16, 22), bottom.viewport_offset);
}

test "reconnect banner draws clipped multiline content and pads stale rows" {
    var single_row = std.ArrayList(u8).empty;
    defer single_row.deinit(std.testing.allocator);
    const single_renderer = client_renderer.Renderer.buffered(&single_row, .{ .kind = .xterm_compatible });
    _ = try drawBannerLines(
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
    const first_state = try drawBannerLines(
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
    _ = try drawBannerLines(
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
    _ = try drawBannerLines(
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

test "reconnect banner restores temporary expansion within sessh-owned rows" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.buffered(&drawn, .{ .kind = .xterm_compatible });
    const state = try drawBannerLines(
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
    try eraseBannerRows(clear_renderer, state, 4, 16);
    try restoreBannerExpansion(clear_renderer, state, 4);
    try std.testing.expectEqual(@as(usize, 1), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\x1b[r") != null);
}

test "reconnect banner scrolls outer rows into scrollback when expansion consumes them" {
    var drawn = std.ArrayList(u8).empty;
    defer drawn.deinit(std.testing.allocator);
    const renderer = client_renderer.Renderer.buffered(&drawn, .{ .kind = .xterm_compatible });
    const state = try drawBannerLines(
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
    try eraseBannerRows(clear_renderer, state, 4, 16);
    try restoreBannerExpansion(clear_renderer, state, 4);
    try std.testing.expectEqual(@as(usize, 0), countSubstrings(cleared.items, "\x1bM"));
    try std.testing.expectEqual(@as(u16, 1), clearedViewportOffset(state));
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

test "runtime repaint after local ui requests screen-only repaint" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    next_repaint_request_seq = 91;

    const repaint_response = try protocol.encodePayload(app_allocator.allocator(), pb.RepaintResponse{
        .repaint_request_seq = 91,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 6,
            .draw_bytes = "",
        },
    });
    defer app_allocator.allocator().free(repaint_response);
    try protocol.sendFrame(remote_to_client[1], .repaint_response, repaint_response);

    var session = RuntimeSession{};
    defer session.relay_end_restore.deinit(app_allocator.allocator());
    try session.scrollback_cursor.set("old-cursor");
    session.viewport_offset = 5;

    try repaintRuntimeSession(remote_to_client[0], client_to_remote[1], &session);

    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), client_to_remote[0]);
    defer frame.deinit(app_allocator.allocator());
    try std.testing.expectEqual(protocol.MessageType.resize, frame.message_type);
    var resize = try protocol.decodePayload(pb.Resize, app_allocator.allocator(), frame.payload);
    defer resize.deinit(app_allocator.allocator());
    try std.testing.expectEqual(@as(u32, 24), resize.terminal_rows);
    try std.testing.expectEqual(@as(u32, 80), resize.terminal_cols);
    try std.testing.expectEqual(@as(?i32, 5), resize.viewport_offset);
    const repaint = resize.repaint_request orelse return error.ExpectedRepaintRequest;
    try std.testing.expectEqual(@as(u64, 91), repaint.repaint_request_seq);
    try std.testing.expect(repaint.scrollback_cursor == null);
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 6), session.viewport_offset);
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
    if (options.runtime_dir) |dir| socket_transport.setRuntimeRootOverride(dir);

    return runBrokerClient(allocator, args, options);
}

fn runBrokerClient(allocator: std.mem.Allocator, args: []const []const u8, options: LocalOptions) !void {
    if (options.capture_tty_transcript != null and options.action != .new and options.action != .attach) {
        try io_helpers.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }

    var broker_arg_buf: [2][]const u8 = undefined;
    const runtime_broker_args = brokerRuntimeArgs(options, &broker_arg_buf);
    switch (options.action) {
        .list => {
            var command_args_buf: [3][]const u8 = undefined;
            const command_args = appendBrokerCommand(runtime_broker_args, "--list", null, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill => {
            var command_args_buf: [4][]const u8 = undefined;
            const command_args = appendBrokerCommand(runtime_broker_args, "--kill", options.kill_id.?, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .kill_all => {
            var command_args_buf: [3][]const u8 = undefined;
            const command_args = appendBrokerCommand(runtime_broker_args, "--kill-all", null, &command_args_buf);
            const exit_status = try runLocalBrokerCommand(allocator, args[0], command_args);
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        },
        .new, .attach => {},
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (options.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    var generated_guid: ?[]u8 = null;
    defer if (generated_guid) |guid| allocator.free(guid);
    var generated_alias: ?[]u8 = null;
    defer if (generated_alias) |alias| allocator.free(alias);
    var local_alias_created = false;

    if (options.action == .new) {
        if (options.alias) |alias| {
            generated_guid = try session_registry.generateGuid(allocator);
            generated_alias = try allocator.dupe(u8, alias);
        } else {
            const identity = try session_registry.generateGuidWithDefaultAlias(allocator);
            generated_guid = identity.guid;
            generated_alias = identity.alias;
        }
    }

    var child = try startLocalBroker(allocator, args[0], runtime_broker_args);
    var session = (switch (options.action) {
        .new => startNewSessionOnRuntime(
            child.stdout.?.handle,
            child.stdin.?.handle,
            options.scrollback_row_count,
            generated_guid.?,
            generated_alias.?,
            &.{},
        ),
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
    defer session.deinit();
    if (options.action == .new) {
        try session_registry.ensureAliasForGuid(allocator, session.idSlice(), session.guidSlice());
        local_alias_created = true;
    }

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
            if (local_alias_created) session_registry.removeAlias(allocator, session.idSlice()) catch {};
            try io_helpers.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                writeDetachBannerForTarget(&.{}, ":local:", options.banner_args.slice(), session.idSlice());
                return;
            },
            .session_ended => {
                closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
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
                if (!anySessionExistsViaBroker(allocator, args[0], runtime_broker_args)) {
                    try io_helpers.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io_helpers.writeAll(2, "\r\nsessh: reconnecting; type <enter>~. to abort\r\n");
        child = startLocalBroker(allocator, args[0], runtime_broker_args) catch |err| {
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            terminateChild(&child);
            if (local_alias_created) session_registry.removeAlias(allocator, session.idSlice()) catch {};
            try io_helpers.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}

fn brokerRuntimeArgs(options: LocalOptions, buf: *[2][]const u8) []const []const u8 {
    if (options.runtime_dir) |dir| {
        buf[0] = "--runtime-dir";
        buf[1] = dir;
        return buf[0..2];
    }
    return buf[0..0];
}

fn appendBrokerCommand(
    runtime_args: []const []const u8,
    command: []const u8,
    value: ?[]const u8,
    buf: [][]const u8,
) []const []const u8 {
    @memcpy(buf[0..runtime_args.len], runtime_args);
    buf[runtime_args.len] = command;
    if (value) |arg| {
        buf[runtime_args.len + 1] = arg;
        return buf[0 .. runtime_args.len + 2];
    }
    return buf[0 .. runtime_args.len + 1];
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

fn anySessionExistsViaBroker(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8) bool {
    return brokerListMatches(allocator, exe, broker_args, null);
}

fn brokerListMatches(allocator: std.mem.Allocator, exe: []const u8, broker_args: []const []const u8, session_id: ?[]const u8) bool {
    const argv = allocator.alloc([]const u8, 3 + broker_args.len) catch return false;
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-host-broker:";
    @memcpy(argv[2 .. 2 + broker_args.len], broker_args);
    argv[2 + broker_args.len] = "--list";
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
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
        } else if (std.mem.eql(u8, arg, "--kill-all")) {
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
            if (!session_registry.isValidCustomAlias(args[i])) return error.InvalidAlias;
            options.alias = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--runtime-dir")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingRuntimeDir;
            options.runtime_dir = args[i];
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
        } else if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingTtyTranscriptPath;
            options.capture_tty_transcript = args[i];
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
    session_alias: []const u8,
    command_argv: []const []const u8,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    const size = terminal.currentWindowSize();
    var created = try sendSessionCreateAndReadCreated(read_fd, write_fd, size, scrollback_row_count, session_guid, session_alias, command_argv);
    defer created.deinit(app_allocator.allocator());
    const client_guid = try session_registry.generateClientGuid(app_allocator.allocator());
    defer app_allocator.allocator().free(client_guid);
    const repaint_request_seq = try sendSessionAttach(write_fd, size, viewport_offset, null, null, created.guid, client_guid);
    var session = try readRuntimeSession(read_fd);
    try session.setClientGuid(client_guid);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn startAttachSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session_ref: []const u8,
    initial_scrollback_row_count: ?u32,
) !RuntimeSession {
    const viewport_offset = queryInitialViewportOffset();
    try runtimeHandshake(read_fd, write_fd);
    const client_guid = try session_registry.generateClientGuid(app_allocator.allocator());
    defer app_allocator.allocator().free(client_guid);
    const repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), viewport_offset, initial_scrollback_row_count, null, session_ref, client_guid);
    var session = try readRuntimeSession(read_fd);
    try session.setClientGuid(client_guid);
    session.viewport_offset = viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    return session;
}

pub fn ensureLocalRouteForRemoteSession(
    allocator: std.mem.Allocator,
    session: *const RuntimeSession,
    requested_ref: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
) !void {
    if (session.guidSlice().len == 0) return;
    const alias = try localAliasForRemoteSession(allocator, session, requested_ref);
    defer allocator.free(alias);
    try session_registry.ensureAliasForGuid(allocator, alias, session.guidSlice());
    try session_registry.writeSshRoute(
        allocator,
        session.guidSlice(),
        alias,
        host,
        ssh_options,
    );
}

fn localAliasForRemoteSession(allocator: std.mem.Allocator, session: *const RuntimeSession, requested_ref: []const u8) ![]u8 {
    if (requested_ref.len > 0 and
        !session_registry.isValidSessionId(requested_ref) and
        session_registry.isValidAlias(requested_ref))
    {
        return allocator.dupe(u8, requested_ref);
    }
    if (session.idSlice().len > 0 and
        !session_registry.isValidSessionId(session.idSlice()) and
        session_registry.isValidAlias(session.idSlice()))
    {
        return allocator.dupe(u8, session.idSlice());
    }
    return session_registry.createGeneratedRemoteAlias(allocator, session.guidSlice());
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
    const client_guid = try session.ensureClientGuid();
    session.pending_repaint.repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), nonZeroViewportOffset(session.viewport_offset), null, &session.scrollback_cursor, session.guidSlice(), client_guid);
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
    try sendResizeScreenRepaint(write_fd, terminal.currentWindowSize(), session.viewport_offset, &session.pending_repaint);
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
            .tty_transcript_chunk => try handleTtyTranscriptChunkFrame(frame.payload),
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
        .tty_transcript_chunk => {
            try handleTtyTranscriptChunkFrame(frame.payload);
            return .recovered;
        },
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
    _ = ssh_options;
    _ = target;
    _ = sessh_options;
    writeDetachBannerForSessionRefInner(session_id) catch {};
}

pub fn writeDetachBannerForSessionRef(sessh_options: []const []const u8, session_ref: []const u8) void {
    if (c.isatty(1) == 0) return;
    _ = sessh_options;
    writeDetachBannerForSessionRefInner(session_ref) catch {};
}

fn writeDetachBannerForSessionRefInner(session_ref: []const u8) !void {
    try io_helpers.writeAll(1, "--- sessh: detached. Re-attach with: ");
    try writeShellArg(1, "sesshmux");
    try io_helpers.writeAll(1, " ");
    try writeShellArg(1, "attach");
    if (session_ref.len > 0) {
        try io_helpers.writeAll(1, " ");
        try writeShellArg(1, session_ref);
    }
    try io_helpers.writeAll(1, " ---\r\n");
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
                try session.setIdentityWithAlias(attached.session_guid, attached.session_alias);
                return session;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readSessionCreated(read_fd: c.fd_t) !CreatedSession {
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
            .session_created => {
                var created = try protocol.decodePayload(pb.SessionCreated, app_allocator.allocator(), frame.payload);
                defer created.deinit(app_allocator.allocator());
                return .{
                    .guid = try app_allocator.allocator().dupe(u8, created.session_guid),
                    .alias = try app_allocator.allocator().dupe(u8, created.session_alias),
                };
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

fn sendSessionCreateAndReadCreated(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    session_guid: []const u8,
    session_alias: []const u8,
    command_argv: []const []const u8,
) !CreatedSession {
    try sendSessionCreate(write_fd, size, scrollback_row_count, session_guid, session_alias, command_argv);
    return readSessionCreated(read_fd);
}

fn sendSessionCreate(
    conn: c.fd_t,
    size: WindowSize,
    scrollback_row_count: u32,
    session_guid: []const u8,
    session_alias: []const u8,
    command_argv: []const []const u8,
) !void {
    var message = pb.SessionCreate{
        .terminal_size = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
        },
        .scrollback_row_limit = scrollback_row_count,
        .session_guid = session_guid,
        .session_alias = session_alias,
    };
    defer message.environment.deinit(app_allocator.allocator());
    defer message.command_argv.deinit(app_allocator.allocator());
    try message.command_argv.appendSlice(app_allocator.allocator(), command_argv);
    const default_colors = queryDefaultColorsForSession();
    message.query_default_colors = .{
        .foreground_color = default_colors.foreground_color,
        .background_color = default_colors.background_color,
    };
    const payload = try protocol.encodePayload(app_allocator.allocator(), message);
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(conn, .session_create, payload);
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
    session_ref: []const u8,
    client_guid: []const u8,
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
        .session_ref = session_ref,
        .capture_tty_transcript = tty_transcript.enabled(),
        .client_guid = client_guid,
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
                .tty_transcript_chunk => {
                    connection_monitor.noteInboundFrame();
                    try handleTtyTranscriptChunkFrame(frame.payload);
                },
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
            io_helpers.noteRead(input_fd, buf[0..@intCast(n)]);
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

fn handleTtyTranscriptChunkFrame(payload: []const u8) !void {
    var chunk = try protocol.decodePayload(pb.TtyTranscriptChunk, app_allocator.allocator(), payload);
    defer chunk.deinit(app_allocator.allocator());
    switch (chunk.stream) {
        .TTY_TRANSCRIPT_STREAM_INNER_IN => tty_transcript.recordInnerIn(chunk.data),
        .TTY_TRANSCRIPT_STREAM_INNER_OUT => tty_transcript.recordInnerOut(chunk.data),
        .TTY_TRANSCRIPT_STREAM_UNSPECIFIED => {},
        _ => {},
    }
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

fn sendResizeScreenRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
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
