// Rendering-independent diagnostics formatting. Callers choose a presentation
// mode, and this module turns connection events into overlay lines, title text,
// plain lines, or JSONL-friendly messages.
const std = @import("std");
const c = std.c;

const core_blocking = @import("../core/blocking.zig");
const client_log = @import("../core/client_log.zig");
const fixed_buffer = @import("../core/fixed_buffer.zig");
const diagnostics_jsonl = @import("jsonl.zig");
const reconnect_title = @import("../reconnect/title.zig");

pub const max_title_fallback_bytes = 512;
const TitleFallback = fixed_buffer.FixedBuffer(max_title_fallback_bytes);

pub const Presentation = enum {
    none,
    line,
    title,
    jsonl,
    overlay,
};

pub const TitleState = struct {
    blocking: ?core_blocking.Blocking = null,
    enabled: bool = false,
    fd: c.fd_t = -1,
    visible: bool = false,
    cleanup_title_fallback: TitleFallback = .{},

    pub fn init(blocking: core_blocking.Blocking, enabled: bool, fd: c.fd_t) TitleState {
        return .{
            .blocking = blocking,
            .enabled = enabled,
            .fd = fd,
        };
    }

    pub fn captureCleanupTitle(self: *TitleState, allocator: std.mem.Allocator) void {
        if (!self.enabled) return;
        const cleanup_title = std.process.getCwdAlloc(allocator) catch null;
        if (cleanup_title) |title| {
            defer allocator.free(title);
            self.cleanup_title_fallback.setTruncate(title);
        }
    }

    pub fn showRetry(self: *TitleState, delay_ms: u64) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeRetryNowTitle(blocking, self.fd, delay_ms) catch return;
        self.visible = true;
    }

    pub fn showReconnecting(self: *TitleState) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeReconnectingTitle(blocking, self.fd) catch return;
        self.visible = true;
    }

    pub fn showReconnectingNow(self: *TitleState) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeReconnectingNowTitle(blocking, self.fd) catch return;
        self.visible = true;
    }

    pub fn showConnectionReady(self: *TitleState) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeConnectionReadyTitle(blocking, self.fd) catch return;
        self.visible = true;
    }

    pub fn showSwitchCountdown(self: *TitleState, delay_ms: u64) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeSwitchCountdownTitle(blocking, self.fd, delay_ms) catch return;
        self.visible = true;
    }

    pub fn restoreAfterReconnect(self: *TitleState, app_title_present: ?bool, fallback_title: []const u8) void {
        if (!self.visible) return;
        if (app_title_present != true) {
            self.restoreTo(fallback_title);
        }
        self.visible = false;
    }

    pub fn restoreForEnd(self: *TitleState) void {
        if (!self.visible) return;
        self.restoreTo(self.cleanupTitleFallback());
        self.visible = false;
    }

    fn restoreTo(self: *TitleState, title: []const u8) void {
        if (!self.enabled or self.fd < 0) return;
        const blocking = self.blocking orelse return;
        reconnect_title.writeTitle(blocking, self.fd, title) catch {};
    }

    fn cleanupTitleFallback(self: *const TitleState) []const u8 {
        return self.cleanup_title_fallback.slice();
    }
};

pub const FormatDiagnosticOptions = struct {
    out: []u8,
    diagnostic: *const client_log.UserDiagnosticLine,
    delayed: bool,
};

pub fn formatDiagnostic(options: FormatDiagnosticOptions) usize {
    const out = options.out;
    const diagnostic = options.diagnostic;
    var stream = std.io.fixedBufferStream(out);
    const writer = stream.writer();
    if (options.delayed) {
        writer.print("{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms }) catch return stream.pos;
    } else {
        writer.print("{s}: ", .{diagnostic.tag.label()}) catch return stream.pos;
    }
    writer.writeAll(diagnostic.slice()) catch {};
    return stream.pos;
}

pub fn writeJsonlDiagnostic(blocking: core_blocking.Blocking, fd: c.fd_t, diagnostic: *const client_log.UserDiagnosticLine) !void {
    try diagnostics_jsonl.writeDiagnostic(blocking, fd, diagnostic.slice());
}

pub fn writeJsonlStatus(blocking: core_blocking.Blocking, fd: c.fd_t, message: []const u8) !void {
    try diagnostics_jsonl.writeStatus(blocking, fd, message);
}

pub const AppendOnlyRetryStatusOptions = struct {
    buf: []u8,
    delay_ms: u64,
    ctrl_r_enabled: bool,
};

pub fn appendOnlyRetryStatus(options: AppendOnlyRetryStatusOptions) ![]const u8 {
    var delay_buf: [16]u8 = undefined;
    const delay = try formatDelay(options.delay_ms, &delay_buf);
    const retry_at_unix_ms = nowUnixMs() +| options.delay_ms;
    if (options.ctrl_r_enabled) {
        return std.fmt.bufPrint(
            options.buf,
            "sessh: disconnected: Retry connecting {s} (retry_at_unix_ms={}). CTRL-R now",
            .{ delay, retry_at_unix_ms },
        );
    }
    return std.fmt.bufPrint(
        options.buf,
        "sessh: disconnected: Retry connecting {s} (retry_at_unix_ms={})",
        .{ delay, retry_at_unix_ms },
    );
}

pub fn formatDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    return reconnect_title.formatDelay(delay_ms, buf);
}

pub fn formatSwitchDelay(delay_ms: u64, buf: []u8) ![]const u8 {
    const seconds = @max(@divTrunc(delay_ms + 999, 1000), 1);
    return std.fmt.bufPrint(buf, "{}sec", .{seconds});
}

pub fn nextOverlayUpdateDelayMs(remaining_ms: u64) u64 {
    if (remaining_ms <= 1_000) return remaining_ms;
    if (remaining_ms <= 60_000) return 1_000;
    return @min(remaining_ms - 59_000, 60_000);
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

test "formatDelay uses compact reconnect labels" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("5sec", try formatDelay(5_000, &buf));
    try std.testing.expectEqualStrings("20sec", try formatDelay(20_000, &buf));
    try std.testing.expectEqualStrings("1min", try formatDelay(60_000, &buf));
    try std.testing.expectEqualStrings("10min", try formatDelay(600_000, &buf));
    try std.testing.expectEqualStrings("60sec", try formatSwitchDelay(60_000, &buf));
}

test "title state restores remote fallback title when no app title is present" {
    const blocking = core_blocking.fromTest();
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var title = TitleState.init(blocking, true, fds[1]);
    title.showRetry(5_000);
    title.restoreAfterReconnect(false, "work.blox");
    std.posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b]2;5sec retry CTRL-R\x1b\\\x1b]2;work.blox\x1b\\",
        buf[0..n],
    );
    try std.testing.expect(!title.visible);
}

test "title state leaves restored app title alone after reconnect repaint" {
    const blocking = core_blocking.fromTest();
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var title = TitleState.init(blocking, true, fds[1]);
    title.showRetry(5_000);
    title.restoreAfterReconnect(true, "work.blox");
    std.posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("\x1b]2;5sec retry CTRL-R\x1b\\", buf[0..n]);
    try std.testing.expect(!title.visible);
}

test "title state restores local cleanup title on end" {
    const blocking = core_blocking.fromTest();
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var title = TitleState.init(blocking, true, fds[1]);
    title.cleanup_title_fallback.setTruncate("/tmp/local");
    title.showRetry(5_000);
    title.restoreForEnd();
    std.posix.close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "\x1b]2;5sec retry CTRL-R\x1b\\\x1b]2;/tmp/local\x1b\\",
        buf[0..n],
    );
    try std.testing.expect(!title.visible);
}

test "reconnect overlay updates every second under one minute" {
    try std.testing.expectEqual(@as(u64, 1_000), nextOverlayUpdateDelayMs(59_000));
    try std.testing.expectEqual(@as(u64, 1_000), nextOverlayUpdateDelayMs(60_000));
    try std.testing.expectEqual(@as(u64, 2_000), nextOverlayUpdateDelayMs(61_000));
    try std.testing.expectEqual(@as(u64, 60_000), nextOverlayUpdateDelayMs(600_000));
}
