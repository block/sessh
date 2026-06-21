// In-process logging used by foreground clients and daemons for operator-facing
// diagnostics. It keeps bounded recent history so long-running processes can
// stream useful events without turning logs into another unbounded queue.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const core_blocking = @import("blocking.zig");
const fixed_buffer = @import("fixed_buffer.zig");

const max_entries = 256;
const max_entry_bytes = 1024;
const max_user_diagnostics = 256;
pub const max_user_diagnostic_display_bytes = max_entry_bytes + 96;
const truncated_suffix = "... [truncated]";
const LogMessage = fixed_buffer.FixedBuffer(max_entry_bytes);

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
    message: LogMessage,
    flushed: bool,
};

pub const DiagnosticTag = enum(u8) {
    ssh,
    sessh,

    pub fn label(self: DiagnosticTag) []const u8 {
        return switch (self) {
            .ssh => "ssh",
            .sessh => "sessh",
        };
    }
};

const UserDiagnostic = struct {
    seq: u64,
    ts_ms: u64,
    level: Level,
    tag: DiagnosticTag,
    message: LogMessage,
};

pub const UserDiagnosticLine = struct {
    seq: u64 = 0,
    ts_ms: u64 = 0,
    level: Level = .warn,
    tag: DiagnosticTag = .sessh,
    message: LogMessage = .{},

    pub fn slice(self: *const UserDiagnosticLine) []const u8 {
        return self.message.slice();
    }
};

// PROCESS_GLOBAL_REGISTRY: diagnostics are produced by transport, reconnect,
// and visible-client code in the same single-threaded process. This module is
// their rendezvous point, so callers do not thread a log object through every
// protocol/UI callback.
var configured_level: Level = .warn;
var entries: [max_entries]Entry = undefined;
var next_entry: usize = 0;
var entry_count: usize = 0;
var diagnostics: [max_user_diagnostics]UserDiagnostic = undefined;
var next_diagnostic: usize = 0;
var diagnostic_count: usize = 0;
var next_diagnostic_seq: u64 = 0;
var displayed_diagnostic_seq: u64 = 0;
var diagnostic_notify_fd: c.fd_t = -1;

pub fn setLevel(level: Level) void {
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

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    append(.debug, fmt, args);
}

fn append(level: Level, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(level != .quiet);
    var body_buf: [max_entry_bytes]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, fmt, args) catch return;

    appendMessage(level, body);
}

pub fn appendSshStderr(bytes: []const u8) void {
    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
        var line = bytes[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        appendUserDiagnostic(.warn, .ssh, line);
        line_start = if (line_end < bytes.len) line_end + 1 else line_end;
    }
}

pub fn flush(blocking: core_blocking.Blocking, fd: c.fd_t) void {
    flushUserDiagnostics(blocking, fd) catch {};
    flushEntries(blocking, fd) catch {};
}

pub fn userDiagnosticInfo(comptime fmt: []const u8, args: anytype) void {
    userDiagnosticLevel(.info, fmt, args);
}

fn userDiagnosticLevel(level: Level, comptime fmt: []const u8, args: anytype) void {
    var body_buf: [max_entry_bytes]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, fmt, args) catch return;

    appendUserDiagnostic(level, .sessh, body);
}

pub fn currentUserDiagnosticSeq() u64 {
    return next_diagnostic_seq;
}

pub fn displayedUserDiagnosticSeq() u64 {
    return displayed_diagnostic_seq;
}

pub fn markUserDiagnosticsDisplayedThrough(seq: u64) void {
    displayed_diagnostic_seq = @max(displayed_diagnostic_seq, seq);
}

pub fn copyUserDiagnosticsSince(since_seq: u64, out: []UserDiagnosticLine) u64 {
    // Copy only diagnostics newer than the caller's sequence number, preserving
    // the most recent entries that fit in `out`. The returned sequence lets UI
    // callers later ask for "anything since the last display pass".
    var count: usize = 0;
    const oldest = oldestDiagnosticIndex();
    var offset: usize = 0;
    while (offset < diagnostic_count) : (offset += 1) {
        const idx = (oldest + offset) % max_user_diagnostics;
        const diagnostic = &diagnostics[idx];
        if (diagnostic.seq <= since_seq) continue;
        if (!shouldDisplay(diagnostic.level)) continue;
        if (out.len == 0) continue;
        if (count == out.len) {
            var i: usize = 1;
            while (i < out.len) : (i += 1) out[i - 1] = out[i];
            count -= 1;
        }
        out[count].seq = diagnostic.seq;
        out[count].ts_ms = diagnostic.ts_ms;
        out[count].level = diagnostic.level;
        out[count].tag = diagnostic.tag;
        out[count].message = diagnostic.message;
        count += 1;
    }
    return next_diagnostic_seq;
}

pub fn registerNonBlockingUserDiagnosticNotifier(fd: c.fd_t) void {
    diagnostic_notify_fd = fd;
}

pub fn unregisterNonBlockingUserDiagnosticNotifier(fd: c.fd_t) void {
    if (diagnostic_notify_fd == fd) diagnostic_notify_fd = -1;
}

fn appendUserDiagnostic(level: Level, tag: DiagnosticTag, message: []const u8) void {
    next_diagnostic_seq +%= 1;
    if (next_diagnostic_seq == 0) next_diagnostic_seq = 1;

    const idx = next_diagnostic;
    diagnostics[idx].seq = next_diagnostic_seq;
    diagnostics[idx].ts_ms = nowUnixMs();
    diagnostics[idx].level = level;
    diagnostics[idx].tag = tag;
    setSanitizedMessage(&diagnostics[idx].message, message);

    next_diagnostic = (next_diagnostic + 1) % max_user_diagnostics;
    if (diagnostic_count < max_user_diagnostics) diagnostic_count += 1;
    notifyUserDiagnostic();
}

fn notifyUserDiagnostic() void {
    const fd = diagnostic_notify_fd;
    if (fd < 0) return;
    // The notifier is only a wakeup edge for the visible-client event loop; the
    // ring buffer above is the durable state. The fd is registered as
    // nonblocking, so a full pipe can drop this byte without losing diagnostics.
    var byte = [_]u8{1};
    const n = c.write(fd, &byte, byte.len);
    if (n <= 0) return;
}

fn truncatedPlainByteLimit(capacity: usize, source_len: usize) usize {
    return if (source_len > capacity and capacity > truncated_suffix.len)
        capacity - truncated_suffix.len
    else
        capacity;
}

fn appendTruncatedSuffix(out: *LogMessage) void {
    const storage = out.storageSlice();
    if (out.len + truncated_suffix.len > storage.len) return;
    @memcpy(storage[out.len .. out.len + truncated_suffix.len], truncated_suffix);
    out.assumeLen(out.len + truncated_suffix.len);
}

fn setSanitizedMessage(out: *LogMessage, message: []const u8) void {
    const storage = out.storageSlice();
    const max_plain_bytes = truncatedPlainByteLimit(storage.len, message.len);
    var len: usize = 0;
    while (len < max_plain_bytes and len < message.len) : (len += 1) {
        storage[len] = printableLogByte(message[len]);
    }
    out.assumeLen(len);
    if (message.len > len) appendTruncatedSuffix(out);
}

fn setLogMessage(out: *LogMessage, message: []const u8) void {
    const storage = out.storageSlice();
    const max_plain_bytes = truncatedPlainByteLimit(storage.len, message.len);
    const copy_len = @min(message.len, max_plain_bytes);
    @memcpy(storage[0..copy_len], message[0..copy_len]);
    out.assumeLen(copy_len);
    if (message.len > copy_len) appendTruncatedSuffix(out);
}

fn printableLogByte(byte: u8) u8 {
    return switch (byte) {
        '\t', ' '...'~' => byte,
        else => '?',
    };
}

fn appendMessage(level: Level, message: []const u8) void {
    std.debug.assert(level != .quiet);
    const idx = next_entry;
    entries[idx].ts_ms = nowUnixMs();
    entries[idx].level = level;
    entries[idx].flushed = false;
    setLogMessage(&entries[idx].message, message);

    next_entry = (next_entry + 1) % max_entries;
    if (entry_count < max_entries) entry_count += 1;
}

fn flushEntries(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
    const oldest = oldestEntryIndex();
    var offset: usize = 0;
    while (offset < entry_count) : (offset += 1) {
        const idx = (oldest + offset) % max_entries;
        if (entries[idx].flushed) continue;
        entries[idx].flushed = true;
        if (!shouldDisplay(entries[idx].level)) continue;
        try writeEntry(blocking, fd, &entries[idx]);
    }
}

fn oldestEntryIndex() usize {
    return if (entry_count < max_entries) 0 else next_entry;
}

fn oldestDiagnosticIndex() usize {
    return if (diagnostic_count < max_user_diagnostics) 0 else next_diagnostic;
}

fn shouldDisplay(level: Level) bool {
    if (configured_level == .quiet) return false;
    return @intFromEnum(level) >= @intFromEnum(configured_level);
}

fn flushUserDiagnostics(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
    const oldest = oldestDiagnosticIndex();
    var offset: usize = 0;
    var displayed = displayed_diagnostic_seq;
    while (offset < diagnostic_count) : (offset += 1) {
        const idx = (oldest + offset) % max_user_diagnostics;
        const diagnostic = &diagnostics[idx];
        if (diagnostic.seq <= displayed_diagnostic_seq) continue;
        if (shouldDisplay(diagnostic.level)) {
            try writeDelayedUserDiagnostic(blocking, fd, diagnostic);
        }
        displayed = @max(displayed, diagnostic.seq);
    }
    displayed_diagnostic_seq = displayed;
}

fn writeDelayedUserDiagnostic(blocking: core_blocking.Blocking, fd: c.fd_t, diagnostic: *const UserDiagnostic) !void {
    var prefix_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms });
    try blocking.writeAll(fd, prefix);
    try blocking.writeAll(fd, diagnostic.message.slice());
    try blocking.writeAll(fd, "\r\n");
}

fn writeEntry(blocking: core_blocking.Blocking, fd: c.fd_t, entry: *const Entry) !void {
    var prefix_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_buf,
        "sessh ts_ms={}: ",
        .{entry.ts_ms},
    );
    try blocking.writeAll(fd, prefix);
    try blocking.writeAll(fd, entry.message.slice());
    try blocking.writeAll(fd, "\r\n");
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

test "log message helpers truncate with suffix and sanitize diagnostics" {
    var oversized = [_]u8{'x'} ** (max_entry_bytes + 1);

    var log_message = LogMessage{};
    setLogMessage(&log_message, oversized[0..]);
    try std.testing.expectEqual(@as(usize, max_entry_bytes), log_message.slice().len);
    try std.testing.expect(std.mem.endsWith(u8, log_message.slice(), truncated_suffix));

    var diagnostic_message = LogMessage{};
    setSanitizedMessage(&diagnostic_message, "\x1b[31m");
    try std.testing.expectEqualStrings("?[31m", diagnostic_message.slice());
}

const testing = if (builtin.is_test) struct {
    fn reset() void {
        configured_level = .warn;
        next_entry = 0;
        entry_count = 0;
        next_diagnostic = 0;
        diagnostic_count = 0;
        next_diagnostic_seq = 0;
        displayed_diagnostic_seq = 0;
        diagnostic_notify_fd = -1;
    }
} else struct {};

test "user diagnostics are sanitized and limited" {
    testing.reset();
    appendSshStderr("one\nbad\x1b[31m\nthree\nfour");

    var lines: [3]UserDiagnosticLine = undefined;
    const seq = copyUserDiagnosticsSince(0, &lines);

    try std.testing.expectEqual(@as(u64, 4), seq);
    try std.testing.expectEqual(DiagnosticTag.ssh, lines[0].tag);
    try std.testing.expectEqualStrings("bad?[31m", lines[0].slice());
    try std.testing.expectEqualStrings("three", lines[1].slice());
    try std.testing.expectEqualStrings("four", lines[2].slice());
}

test "info user diagnostics are hidden by default" {
    testing.reset();
    userDiagnosticInfo("hidden reconnect failure", .{});

    var hidden_lines = [_]UserDiagnosticLine{.{}} ** 1;
    const hidden_seq = copyUserDiagnosticsSince(0, &hidden_lines);
    try std.testing.expectEqual(@as(u64, 1), hidden_seq);
    try std.testing.expectEqual(@as(u64, 0), hidden_lines[0].seq);

    testing.reset();
    setLevel(.info);
    userDiagnosticInfo("visible reconnect failure", .{});

    var visible_lines = [_]UserDiagnosticLine{.{}} ** 1;
    const visible_seq = copyUserDiagnosticsSince(0, &visible_lines);
    try std.testing.expectEqual(@as(u64, 1), visible_seq);
    try std.testing.expectEqual(@as(u64, 1), visible_lines[0].seq);
    try std.testing.expectEqual(Level.info, visible_lines[0].level);
    try std.testing.expectEqualStrings("visible reconnect failure", visible_lines[0].slice());
}
