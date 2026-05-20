const std = @import("std");
const app_allocator = @import("app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("config.zig");
const client_renderer = @import("client_renderer.zig");
const io_helpers = @import("io.zig");
const protocol = @import("protocol.zig");
const process_exit = @import("process_exit.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");

const pb = protocol.pb;
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
    transport_closed,
    session_ended,
};

pub const ReconnectDecision = enum {
    wait_elapsed,
    reconnect_now,
    abort,
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

    pub fn idSlice(self: *const RuntimeSession) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const ReconnectUi = struct {
    mode_guard: terminal.TerminalModeGuard,
    escape_filter: terminal.EscapeFilter = .{ .at_line_start = false },
    buffered_input: std.ArrayList(u8) = .empty,
    origin_row: ?u16 = null,
    banner_row: ?u16 = null,
    cursor_hidden: bool = false,

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
        var next_banner_update = std.time.milliTimestamp() + 60_000;

        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) return .wait_elapsed;

            const next_wake = @min(deadline, next_banner_update);
            const wait_ms: i32 = @intCast(@min(next_wake - now, @as(i64, std.math.maxInt(i32))));
            switch (try self.pollInput(wait_ms)) {
                .abort => return .abort,
                .reconnect_now => return .reconnect_now,
                .wait_elapsed => {},
            }

            const after_poll = std.time.milliTimestamp();
            if (after_poll >= next_banner_update and after_poll < deadline) {
                try self.drawBanner(@intCast(deadline - after_poll));
                next_banner_update = after_poll + 60_000;
            }
        }
    }

    pub fn pollAbort(self: *ReconnectUi, timeout_ms: i32) !bool {
        return switch (try self.pollInput(timeout_ms)) {
            .abort => true,
            .reconnect_now, .wait_elapsed => false,
        };
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

    fn drawBanner(self: *ReconnectUi, delay_ms: u64) !void {
        var delay_buf: [16]u8 = undefined;
        const delay = try formatDelay(delay_ms, &delay_buf);
        var message_buf: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(
            &message_buf,
            "--- sessh: disconnected. Retry in {s}. SPACE retries now. CTRL-C aborts ---",
            .{delay},
        );
        if (c.isatty(1) == 0) {
            try io_helpers.writeAll(1, "\r\n");
            try io_helpers.writeAll(1, message);
            try io_helpers.writeAll(1, "\r\n");
            return;
        }

        const size = terminal.currentWindowSize();
        const top_row = self.origin_row orelse 0;
        const banner_row = if (size.rows > 1)
            @min(top_row +| 1, size.rows - 1)
        else
            @as(u16, 0);
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

fn formatDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    const seconds = @max(@divTrunc(delay_ms + 999, 1000), 1);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{}sec", .{seconds});
    const minutes = @divTrunc(seconds + 59, 60);
    return std.fmt.bufPrint(buf, "{}min", .{minutes});
}

const DrawPayload = struct {
    scrollback_epoch: u64,
    scroll_count: u64,
    cursor_row: u16,
    bytes: []const u8,
    cleanup_after: ?[]const u8,
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
    if (frame.message_type != .FRAME_TYPE_COMMAND_RESPONSE) return false;
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
    try runtimeHandshake(read_fd, write_fd);
    try sendResize(write_fd, terminal.currentWindowSize());
    try sendSessionAttach(write_fd, session.idSlice(), null, session.scrollback_cursor);

    var id_buf: [64]u8 = undefined;
    const attached_id = try readAttachedSessionId(read_fd, &id_buf);
    if (!std.mem.eql(u8, attached_id, session.idSlice())) return error.UnexpectedSessionId;
}

pub fn relayRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    leader: Leader,
) !RelayEnd {
    return relayInteractive(read_fd, write_fd, session.idSlice(), leader, &session.scrollback_cursor, &session.cursor_row);
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
    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), conn);
    defer frame.deinit(app_allocator.allocator());
    if (frame.message_type == .FRAME_TYPE_ERROR) {
        const parsed = try parseErrorPayload(frame.payload);
        if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
            freeErrorPayload(parsed);
            return error.VersionMismatch;
        }
        try printParsedError(parsed);
        return process_exit.request(1);
    }
    if (frame.message_type != .FRAME_TYPE_SESSION_ATTACHED) return error.UnexpectedFrame;

    var attached = try protocol.decodePayload(pb.SessionAttached, app_allocator.allocator(), frame.payload);
    defer attached.deinit(app_allocator.allocator());
    const id = attached.session_id;
    if (id.len == 0) return error.PayloadTooShort;
    if (id.len > session_id_buf.len) return error.SessionIdTooLong;
    @memcpy(session_id_buf[0..id.len], id);
    return session_id_buf[0..id.len];
}

pub fn runtimeHandshake(read_fd: c.fd_t, write_fd: c.fd_t) !void {
    const hello_payload = try protocol.encodePayload(app_allocator.allocator(), pb.Hello{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(hello_payload);
    try protocol.sendFrame(write_fd, .FRAME_TYPE_HELLO, hello_payload);

    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), read_fd);
    defer frame.deinit(app_allocator.allocator());
    if (frame.message_type == .FRAME_TYPE_ERROR) {
        const parsed = try parseErrorPayload(frame.payload);
        if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
            freeErrorPayload(parsed);
            return error.VersionMismatch;
        }
        try printParsedError(parsed);
        return process_exit.request(1);
    }
    if (frame.message_type != .FRAME_TYPE_HELLO_OK) return error.UnexpectedFrame;

    var peer_hello = try protocol.decodePayload(pb.Hello, app_allocator.allocator(), frame.payload);
    defer peer_hello.deinit(app_allocator.allocator());
    if (peer_hello.protocol_major != config.protocol_major or
        peer_hello.protocol_minor != config.protocol_minor or
        !std.mem.eql(u8, peer_hello.version, config.version))
    {
        try io_helpers.writeAll(2, "ERROR existing remote sessh is incompatible with this client\n");
        return process_exit.request(1);
    }
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
    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), read_fd);
    defer frame.deinit(app_allocator.allocator());
    if (frame.message_type == .FRAME_TYPE_ERROR) {
        const parsed = try parseErrorPayload(frame.payload);
        if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
            freeErrorPayload(parsed);
            return error.VersionMismatch;
        }
        try printParsedError(parsed);
        return 1;
    }
    if (frame.message_type != .FRAME_TYPE_COMMAND_RESPONSE) return error.UnexpectedFrame;
    const response = try parseCommandResponse(frame.payload);
    defer freeCommandResponse(response);
    if (response.stdout.len > 0) try io_helpers.writeAll(1, response.stdout);
    if (response.stderr.len > 0) try io_helpers.writeAll(2, response.stderr);
    return response.exit_status;
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
    var frame = try protocol.readFrameAlloc(app_allocator.allocator(), conn);
    defer frame.deinit(app_allocator.allocator());
    if (frame.message_type == .FRAME_TYPE_ERROR) {
        try printErrorPayload(frame.payload);
        return true;
    }
    if (frame.message_type != .FRAME_TYPE_SESSION_ENDED) return error.UnexpectedFrame;
    return false;
}

fn printErrorPayload(payload: []const u8) !void {
    try printParsedError(try parseErrorPayload(payload));
}

fn parseErrorPayload(payload: []const u8) !ErrorPayload {
    var message = try protocol.decodePayload(pb.Error, app_allocator.allocator(), payload);
    defer message.deinit(app_allocator.allocator());
    return .{
        .code = try app_allocator.allocator().dupe(u8, message.code),
        .message = try app_allocator.allocator().dupe(u8, message.message),
        .hint = try app_allocator.allocator().dupe(u8, message.hint),
    };
}

fn printParsedError(parsed: ErrorPayload) !void {
    defer freeErrorPayload(parsed);
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

    const end = try relayTerminal(0, read_fd, write_fd, session_id, leader, &presentation_guard, scrollback_cursor, cursor_row);
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
) !RelayEnd {
    var pollfds = [_]posix.pollfd{
        .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    var buf: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    var escape_filter = terminal.EscapeFilter{ .leader_byte = terminal.leaderByte(leader) };
    var last_size = terminal.currentWindowSize();
    var pending_cleanup = std.ArrayList(u8).empty;
    defer pending_cleanup.deinit(app_allocator.allocator());
    _ = presentation_guard;

    while (true) {
        _ = try posix.poll(&pollfds, 100);
        maybeSendResize(write_fd, &last_size);

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishRelay(requestSessionDetach(read_fd, write_fd, session_id), &pending_cleanup);
            const result = escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) try sendInput(write_fd, result.bytes);
            if (result.end) |end| switch (end) {
                .detach => return finishRelay(requestSessionDetach(read_fd, write_fd, session_id), &pending_cleanup),
                .repaint => sendRepaint(write_fd) catch return .transport_closed,
                .reconnect => return .reconnect,
            };
        }
        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var frame = protocol.readFrameAlloc(app_allocator.allocator(), read_fd) catch return .transport_closed;
            defer frame.deinit(app_allocator.allocator());
            switch (frame.message_type) {
                .FRAME_TYPE_DRAW => try handleDrawFrame(frame.payload, &pending_cleanup, scrollback_cursor, cursor_row),
                .FRAME_TYPE_SESSION_ENDED => return finishRelay(.session_ended, &pending_cleanup),
                .FRAME_TYPE_ERROR => {
                    try printErrorPayload(frame.payload);
                    return finishRelay(.session_ended, &pending_cleanup);
                },
                else => return error.UnexpectedFrame,
            }
        }
    }
}

fn finishRelay(end: RelayEnd, pending_cleanup: *const std.ArrayList(u8)) RelayEnd {
    if ((end == .detach or end == .session_ended) and pending_cleanup.items.len > 0) {
        io_helpers.writeAll(1, pending_cleanup.items) catch {};
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
    pending_cleanup: *std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    cursor_row: ?*u16,
) !void {
    const draw = try parseDrawPayload(payload);
    defer freeDrawPayload(draw);
    try io_helpers.writeAll(1, draw.bytes);
    if (draw.cleanup_after) |cleanup| {
        pending_cleanup.clearRetainingCapacity();
        try pending_cleanup.appendSlice(app_allocator.allocator(), cleanup);
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
        .bytes = try app_allocator.allocator().dupe(u8, message.bytes),
        .cleanup_after = if (message.cleanup_after) |cleanup|
            try app_allocator.allocator().dupe(u8, cleanup)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.bytes);
    if (draw.cleanup_after) |cleanup| app_allocator.allocator().free(cleanup);
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

fn sendRepaint(socket_fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Repaint{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_REPAINT, payload);
}

fn sendInput(socket_fd: c.fd_t, bytes: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.Input{ .data = bytes });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(socket_fd, .FRAME_TYPE_INPUT, payload);
}
