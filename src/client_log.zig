const std = @import("std");
const c = std.c;

const io = @import("io.zig");

const max_entries = 256;
const max_entry_bytes = 1024;
const truncated_suffix = "... [truncated]";

pub const Level = enum(u8) {
    verbose = 10,
    debug = 20,
    info = 30,
    warn = 40,
    err = 50,
    quiet = 255,
};

const Entry = struct {
    ts_ms: u64,
    level: Level,
    bytes: [max_entry_bytes]u8,
    len: usize,
    flushed: bool,
};

var mutex: std.Thread.Mutex = .{};
var configured_level: Level = .warn;
var entries: [max_entries]Entry = undefined;
var next_entry: usize = 0;
var entry_count: usize = 0;

pub fn setLevel(level: Level) void {
    mutex.lock();
    defer mutex.unlock();
    configured_level = level;
}

pub fn parseLevel(value: []const u8) !Level {
    if (std.ascii.eqlIgnoreCase(value, "quiet")) return .quiet;
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "verbose")) return .verbose;
    return error.InvalidClientLogLevel;
}

pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .verbose => "verbose",
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
        .quiet => "quiet",
    };
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    append(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    append(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    append(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    append(.debug, fmt, args);
}

pub fn verbose(comptime fmt: []const u8, args: anytype) void {
    append(.verbose, fmt, args);
}

fn append(level: Level, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(level != .quiet);
    var body_buf: [max_entry_bytes]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, fmt, args) catch return;

    mutex.lock();
    defer mutex.unlock();
    appendMessageLocked(level, body);
}

pub fn appendSshStderr(bytes: []const u8, forwarded: bool) void {
    mutex.lock();
    defer mutex.unlock();

    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
        var line = bytes[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        appendSshStderrLineLocked(line);
        line_start = if (line_end < bytes.len) line_end + 1 else line_end;
    }

    if (forwarded) flushLocked(2) catch {};
}

pub fn flush(fd: c.fd_t) void {
    mutex.lock();
    defer mutex.unlock();
    flushLocked(fd) catch {};
}

fn appendSshStderrLineLocked(line: []const u8) void {
    var message: [max_entry_bytes]u8 = undefined;
    const prefix = "ssh stderr: ";
    @memcpy(message[0..prefix.len], prefix);

    var len = prefix.len;
    for (line) |byte| {
        if (len >= message.len) break;
        message[len] = printableLogByte(byte);
        len += 1;
    }
    appendMessageLocked(.warn, message[0..len]);
}

fn printableLogByte(byte: u8) u8 {
    return switch (byte) {
        '\t', ' '...'~' => byte,
        else => '?',
    };
}

fn appendMessageLocked(level: Level, message: []const u8) void {
    appendMessageLockedWithFlushed(level, message, false);
}

fn appendMessageLockedWithFlushed(level: Level, message: []const u8, flushed: bool) void {
    std.debug.assert(level != .quiet);
    const idx = next_entry;
    entries[idx].ts_ms = nowUnixMs();
    entries[idx].level = level;
    entries[idx].flushed = flushed;

    const max_plain_bytes = if (message.len > max_entry_bytes and max_entry_bytes > truncated_suffix.len)
        max_entry_bytes - truncated_suffix.len
    else
        max_entry_bytes;
    const copy_len = @min(message.len, max_plain_bytes);
    @memcpy(entries[idx].bytes[0..copy_len], message[0..copy_len]);
    entries[idx].len = copy_len;
    if (message.len > copy_len and entries[idx].len + truncated_suffix.len <= max_entry_bytes) {
        @memcpy(entries[idx].bytes[entries[idx].len .. entries[idx].len + truncated_suffix.len], truncated_suffix);
        entries[idx].len += truncated_suffix.len;
    }

    next_entry = (next_entry + 1) % max_entries;
    if (entry_count < max_entries) entry_count += 1;
}

fn flushLocked(fd: c.fd_t) !void {
    const oldest = oldestEntryIndex();
    var offset: usize = 0;
    while (offset < entry_count) : (offset += 1) {
        const idx = (oldest + offset) % max_entries;
        if (entries[idx].flushed) continue;
        entries[idx].flushed = true;
        if (!shouldDisplay(entries[idx].level)) continue;
        try writeEntry(fd, &entries[idx]);
    }
}

fn oldestEntryIndex() usize {
    return if (entry_count < max_entries) 0 else next_entry;
}

fn shouldDisplay(level: Level) bool {
    if (configured_level == .quiet) return false;
    return @intFromEnum(level) >= @intFromEnum(configured_level);
}

fn writeEntry(fd: c.fd_t, entry: *const Entry) !void {
    var prefix_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_buf,
        "sessh: log ts_ms={} level={s} ",
        .{ entry.ts_ms, levelName(entry.level) },
    );
    try io.writeAll(fd, prefix);
    try io.writeAll(fd, entry.bytes[0..entry.len]);
    try io.writeAll(fd, "\n");
}

fn nowUnixMs() u64 {
    const ts = std.time.milliTimestamp();
    if (ts < 0) return 0;
    return @intCast(ts);
}

test "parseLevel accepts supported client log levels" {
    try std.testing.expectEqual(Level.quiet, try parseLevel("quiet"));
    try std.testing.expectEqual(Level.err, try parseLevel("error"));
    try std.testing.expectEqual(Level.warn, try parseLevel("warn"));
    try std.testing.expectEqual(Level.info, try parseLevel("INFO"));
    try std.testing.expectEqual(Level.debug, try parseLevel("debug"));
    try std.testing.expectEqual(Level.verbose, try parseLevel("verbose"));
    try std.testing.expectError(error.InvalidClientLogLevel, parseLevel("trace"));
}

test "level ordering follows conventional severity order" {
    try std.testing.expect(@intFromEnum(Level.verbose) < @intFromEnum(Level.debug));
    try std.testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try std.testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.warn));
    try std.testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
}
