const std = @import("std");
const c = std.c;

const io = @import("io.zig");

const max_entries = 256;
const max_entry_bytes = 1024;
const max_user_diagnostics = 256;
pub const max_user_diagnostic_display_bytes = max_entry_bytes + 96;
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
    bytes: [max_entry_bytes]u8,
    len: usize,
};

pub const UserDiagnosticLine = struct {
    seq: u64 = 0,
    ts_ms: u64 = 0,
    level: Level = .warn,
    tag: DiagnosticTag = .sessh,
    bytes: [max_entry_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const UserDiagnosticLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

var mutex: std.Thread.Mutex = .{};
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

pub fn appendSshStderr(bytes: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
        var line = bytes[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        appendUserDiagnosticLocked(.warn, .ssh, line);
        line_start = if (line_end < bytes.len) line_end + 1 else line_end;
    }
}

pub fn flush(fd: c.fd_t) void {
    mutex.lock();
    defer mutex.unlock();
    flushUserDiagnosticsLocked(fd, true) catch {};
    flushLocked(fd) catch {};
}

pub fn userDiagnostic(comptime fmt: []const u8, args: anytype) void {
    userDiagnosticLevel(.warn, fmt, args);
}

pub fn userDiagnosticInfo(comptime fmt: []const u8, args: anytype) void {
    userDiagnosticLevel(.info, fmt, args);
}

fn userDiagnosticLevel(level: Level, comptime fmt: []const u8, args: anytype) void {
    var body_buf: [max_entry_bytes]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, fmt, args) catch return;

    mutex.lock();
    defer mutex.unlock();
    appendUserDiagnosticLocked(level, .sessh, body);
}

pub fn currentUserDiagnosticSeq() u64 {
    mutex.lock();
    defer mutex.unlock();
    return next_diagnostic_seq;
}

pub fn displayedUserDiagnosticSeq() u64 {
    mutex.lock();
    defer mutex.unlock();
    return displayed_diagnostic_seq;
}

pub fn markUserDiagnosticsDisplayedThrough(seq: u64) void {
    mutex.lock();
    defer mutex.unlock();
    displayed_diagnostic_seq = @max(displayed_diagnostic_seq, seq);
}

pub fn copyUserDiagnosticsSince(since_seq: u64, out: []UserDiagnosticLine) u64 {
    mutex.lock();
    defer mutex.unlock();

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
        @memcpy(out[count].bytes[0..diagnostic.len], diagnostic.bytes[0..diagnostic.len]);
        out[count].len = diagnostic.len;
        count += 1;
    }
    return next_diagnostic_seq;
}

pub fn registerUserDiagnosticNotifier(fd: c.fd_t) void {
    mutex.lock();
    defer mutex.unlock();
    diagnostic_notify_fd = fd;
}

pub fn unregisterUserDiagnosticNotifier(fd: c.fd_t) void {
    mutex.lock();
    defer mutex.unlock();
    if (diagnostic_notify_fd == fd) diagnostic_notify_fd = -1;
}

fn appendUserDiagnosticLocked(level: Level, tag: DiagnosticTag, message: []const u8) void {
    next_diagnostic_seq +%= 1;
    if (next_diagnostic_seq == 0) next_diagnostic_seq = 1;

    const idx = next_diagnostic;
    diagnostics[idx].seq = next_diagnostic_seq;
    diagnostics[idx].ts_ms = nowUnixMs();
    diagnostics[idx].level = level;
    diagnostics[idx].tag = tag;
    diagnostics[idx].len = copySanitizedMessage(&diagnostics[idx].bytes, message);

    next_diagnostic = (next_diagnostic + 1) % max_user_diagnostics;
    if (diagnostic_count < max_user_diagnostics) diagnostic_count += 1;
    notifyUserDiagnosticLocked();
}

fn notifyUserDiagnosticLocked() void {
    const fd = diagnostic_notify_fd;
    if (fd < 0) return;
    var byte = [_]u8{1};
    const n = c.write(fd, &byte, byte.len);
    if (n <= 0) return;
}

fn copySanitizedMessage(out: *[max_entry_bytes]u8, message: []const u8) usize {
    const max_plain_bytes = if (message.len > max_entry_bytes and max_entry_bytes > truncated_suffix.len)
        max_entry_bytes - truncated_suffix.len
    else
        max_entry_bytes;
    var len: usize = 0;
    while (len < max_plain_bytes and len < message.len) : (len += 1) {
        out[len] = printableLogByte(message[len]);
    }
    if (message.len > len and len + truncated_suffix.len <= max_entry_bytes) {
        @memcpy(out[len .. len + truncated_suffix.len], truncated_suffix);
        len += truncated_suffix.len;
    }
    return len;
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

fn oldestDiagnosticIndex() usize {
    return if (diagnostic_count < max_user_diagnostics) 0 else next_diagnostic;
}

fn shouldDisplay(level: Level) bool {
    if (configured_level == .quiet) return false;
    return @intFromEnum(level) >= @intFromEnum(configured_level);
}

fn flushUserDiagnosticsLocked(fd: c.fd_t, delayed: bool) !void {
    const oldest = oldestDiagnosticIndex();
    var offset: usize = 0;
    var displayed = displayed_diagnostic_seq;
    while (offset < diagnostic_count) : (offset += 1) {
        const idx = (oldest + offset) % max_user_diagnostics;
        const diagnostic = &diagnostics[idx];
        if (diagnostic.seq <= displayed_diagnostic_seq) continue;
        if (shouldDisplay(diagnostic.level)) try writeUserDiagnostic(fd, diagnostic, delayed);
        displayed = @max(displayed, diagnostic.seq);
    }
    displayed_diagnostic_seq = displayed;
}

fn writeUserDiagnostic(fd: c.fd_t, diagnostic: *const UserDiagnostic, delayed: bool) !void {
    var prefix_buf: [96]u8 = undefined;
    const prefix = if (delayed)
        try std.fmt.bufPrint(&prefix_buf, "{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms })
    else
        try std.fmt.bufPrint(&prefix_buf, "{s}: ", .{diagnostic.tag.label()});
    try io.writeAll(fd, prefix);
    try io.writeAll(fd, diagnostic.bytes[0..diagnostic.len]);
    try io.writeAll(fd, "\r\n");
}

fn writeEntry(fd: c.fd_t, entry: *const Entry) !void {
    var prefix_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_buf,
        "sessh ts_ms={}: ",
        .{entry.ts_ms},
    );
    try io.writeAll(fd, prefix);
    try io.writeAll(fd, entry.bytes[0..entry.len]);
    try io.writeAll(fd, "\r\n");
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

fn resetForTest() void {
    mutex.lock();
    defer mutex.unlock();
    configured_level = .warn;
    next_entry = 0;
    entry_count = 0;
    next_diagnostic = 0;
    diagnostic_count = 0;
    next_diagnostic_seq = 0;
    displayed_diagnostic_seq = 0;
    diagnostic_notify_fd = -1;
}

test "user diagnostics are sanitized and limited" {
    resetForTest();
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
    resetForTest();
    userDiagnosticInfo("hidden reconnect failure", .{});

    var hidden_lines = [_]UserDiagnosticLine{.{}} ** 1;
    const hidden_seq = copyUserDiagnosticsSince(0, &hidden_lines);
    try std.testing.expectEqual(@as(u64, 1), hidden_seq);
    try std.testing.expectEqual(@as(u64, 0), hidden_lines[0].seq);

    resetForTest();
    setLevel(.info);
    userDiagnosticInfo("visible reconnect failure", .{});

    var visible_lines = [_]UserDiagnosticLine{.{}} ** 1;
    const visible_seq = copyUserDiagnosticsSince(0, &visible_lines);
    try std.testing.expectEqual(@as(u64, 1), visible_seq);
    try std.testing.expectEqual(@as(u64, 1), visible_lines[0].seq);
    try std.testing.expectEqual(Level.info, visible_lines[0].level);
    try std.testing.expectEqualStrings("visible reconnect failure", visible_lines[0].slice());
}
