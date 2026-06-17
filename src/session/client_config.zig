const std = @import("std");
const c = std.c;

const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");

pub const FileConfig = struct {
    scrollback_row_count: ?u32 = null,
    client_log_level: ?client_log.Level = null,
    bootstrap: ?bool = null,
    terminal_emulator: ?bool = null,
    filter_level: ?config.FilterLevel = null,
    isolation_mode: ?config.IsolationMode = null,
    cleanup_wakeup_interval_ms: ?u64 = null,
    cleanup_retry_limit_ms: ?u64 = null,
    disconnected_reap_ms: ?u64 = null,
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

        if (keyMatches(key, "scrollback-limit")) {
            parsed.scrollback_row_count = try parseScrollbackRowCount(value);
        } else if (keyMatches(key, "client-log-level")) {
            parsed.client_log_level = try client_log.parseLevel(value);
        } else if (keyMatches(key, "bootstrap")) {
            parsed.bootstrap = try parseBool(value);
        } else if (keyMatches(key, "terminal-emulator")) {
            parsed.terminal_emulator = try parseBool(value);
        } else if (keyMatches(key, "filter-level")) {
            parsed.filter_level = try config.parseFilterLevel(value);
        } else if (keyMatches(key, "isolation-mode")) {
            parsed.isolation_mode = try config.parseIsolationMode(value);
        } else if (keyMatches(key, "cleanup-wakeup-interval-hours")) {
            parsed.cleanup_wakeup_interval_ms = try parseHoursMs(value, error.InvalidCleanupWakeupIntervalHours);
        } else if (keyMatches(key, "cleanup-retry-limit-hours")) {
            parsed.cleanup_retry_limit_ms = try parseHoursMs(value, error.InvalidCleanupRetryLimitHours);
        } else if (keyMatches(key, "disconnected-reap-hours")) {
            parsed.disconnected_reap_ms = try parseHoursMs(value, error.InvalidDisconnectedReapHours);
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

fn parseHoursMs(value: []const u8, invalid_error: anyerror) !u64 {
    const parsed = std.fmt.parseFloat(f64, value) catch return invalid_error;
    if (parsed != parsed) return invalid_error;
    if (parsed <= 0) return 0;
    if (parsed > 1.0e9) return invalid_error;
    const ms = @ceil(parsed * @as(f64, @floatFromInt(config.hour_ms)));
    if (ms < 1) return 1;
    return @intFromFloat(ms);
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

test "parseEnvConfig accepts sessh env keys" {
    const parsed = try parseEnvConfig(
        \\# comment
        \\scrollback-limit=42
        \\client-log-level=debug
        \\bootstrap=false
        \\terminal-emulator=no
        \\filter-level=hygienic
        \\isolation-mode=full
        \\cleanup-wakeup-interval-hours=0.25
        \\cleanup-retry-limit-hours=2
        \\disconnected-reap-hours=1.5
        \\
    );
    try std.testing.expectEqual(@as(?u32, 42), parsed.scrollback_row_count);
    try std.testing.expectEqual(@as(?client_log.Level, .debug), parsed.client_log_level);
    try std.testing.expectEqual(@as(?bool, false), parsed.bootstrap);
    try std.testing.expectEqual(@as(?bool, false), parsed.terminal_emulator);
    try std.testing.expectEqual(@as(?config.FilterLevel, .hygienic), parsed.filter_level);
    try std.testing.expectEqual(@as(?config.IsolationMode, .full), parsed.isolation_mode);
    try std.testing.expectEqual(@as(?u64, 900_000), parsed.cleanup_wakeup_interval_ms);
    try std.testing.expectEqual(@as(?u64, 7_200_000), parsed.cleanup_retry_limit_ms);
    try std.testing.expectEqual(@as(?u64, 5_400_000), parsed.disconnected_reap_ms);
}

test "parseEnvConfig maps non-positive disconnected reap hours to disabled" {
    const negative = try parseEnvConfig("disconnected-reap-hours=-1\n");
    try std.testing.expectEqual(@as(?u64, 0), negative.disconnected_reap_ms);

    const zero = try parseEnvConfig("disconnected_reap_hours=0\n");
    try std.testing.expectEqual(@as(?u64, 0), zero.disconnected_reap_ms);
}
