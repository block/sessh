const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

pub const WindowSize = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const DefaultColorQuery = struct {
    foreground: ?Rgb = null,
    background: ?Rgb = null,
};

pub const CursorPosition = struct {
    row: u16,
    col: u16,
};

const terminal_query_timeout_ms: i64 = 150;
const terminal_query_poll_ms: i64 = 25;
const kitty_keyboard_query = "\x1b[?u";
const terminal_probe_request =
    kitty_keyboard_query ++
    "\x1b]60;?\x1b\\" ++
    "\x1b[6n" ++
    "\x1b]10;?\x1b\\" ++
    "\x1b]11;?\x1b\\";

pub const TerminalProbe = struct {
    cursor_position: ?CursorPosition = null,
    default_colors: DefaultColorQuery = .{},
    kitty_keyboard_flags: ?u5 = null,
    allowed_features_answered: bool = false,
    color_ops_allowed: ?bool = null,

    fn complete(self: TerminalProbe) bool {
        const have_cursor = self.cursor_position != null;
        const have_colors = self.default_colors.foreground != null and self.default_colors.background != null;
        if (have_cursor and have_colors) return true;
        if (have_cursor and self.color_ops_allowed != null and !self.color_ops_allowed.?) return true;
        return false;
    }
};

var cached_probe: ?TerminalProbe = null;
var cached_probe_input_fd: c.fd_t = -1;
var cached_probe_output_fd: c.fd_t = -1;

pub const FilterEnd = enum {
    disconnect,
    help,
    repaint,
};

pub const FilterResult = struct {
    bytes: []const u8,
    end: ?FilterEnd = null,
};

pub const escape_help_lines = [_][]const u8{
    "Supported escape sequences:",
    "~.  disconnect",
    "~p  repaint",
    "~?  show this help",
    "~~  send ~",
};

pub const escape_help_overlay_lines = [_][]const u8{
    "Supported escape sequences. Any key to dismiss",
    "~.  disconnect",
    "~p  repaint",
    "~?  show this help",
    "~~  send ~",
};

/// Removes local sessh escape sequences from terminal input before forwarding
/// bytes to the remote PTY. These are ssh-style line-start escapes so input
/// such as `~r`, which OpenSSH already owns, still reaches the remote side.
pub const EscapeFilter = struct {
    at_line_start: bool = true,
    pending_tilde: bool = false,

    pub fn filter(self: *EscapeFilter, input: []const u8, out: []u8) FilterResult {
        var written: usize = 0;
        for (input, 0..) |byte, index| {
            if (self.pending_tilde) {
                self.pending_tilde = false;
                if (byte == '.') return .{ .bytes = out[0..written], .end = .disconnect };
                if (byte == 'p') return .{ .bytes = out[0..written], .end = .repaint };
                if (byte == '?') return .{ .bytes = out[0..written], .end = .help };
                if (byte == '~') {
                    out[written] = '~';
                    written += 1;
                    self.at_line_start = false;
                    continue;
                }
                out[written] = '~';
                written += 1;
                self.at_line_start = false;
            }

            if ((self.at_line_start or index == 0) and byte == '~') {
                self.pending_tilde = true;
                continue;
            }

            out[written] = byte;
            written += 1;
            self.at_line_start = byte == '\n' or byte == '\r';
        }

        return .{ .bytes = out[0..written] };
    }
};

test "EscapeFilter handles ssh line-start escapes" {
    var filter = EscapeFilter{};
    var out: [16]u8 = undefined;

    var result = filter.filter("~.", &out);
    try std.testing.expectEqualStrings("", result.bytes);
    try std.testing.expectEqual(FilterEnd.disconnect, result.end.?);

    filter = .{};
    result = filter.filter("~p", &out);
    try std.testing.expectEqualStrings("", result.bytes);
    try std.testing.expectEqual(FilterEnd.repaint, result.end.?);

    filter = .{};
    result = filter.filter("~?", &out);
    try std.testing.expectEqualStrings("", result.bytes);
    try std.testing.expectEqual(FilterEnd.help, result.end.?);

    filter = .{};
    result = filter.filter("\r~?", &out);
    try std.testing.expectEqualStrings("\r", result.bytes);
    try std.testing.expectEqual(FilterEnd.help, result.end.?);

    filter = .{};
    result = filter.filter("~~hello", &out);
    try std.testing.expectEqualStrings("~hello", result.bytes);
    try std.testing.expectEqual(@as(?FilterEnd, null), result.end);

    filter = .{};
    result = filter.filter("x~?", &out);
    try std.testing.expectEqualStrings("x~?", result.bytes);
    try std.testing.expectEqual(@as(?FilterEnd, null), result.end);

    filter = .{};
    result = filter.filter("~r", &out);
    try std.testing.expectEqualStrings("~r", result.bytes);
    try std.testing.expectEqual(@as(?FilterEnd, null), result.end);

    filter = .{ .at_line_start = false };
    result = filter.filter("~.\n", &out);
    try std.testing.expectEqualStrings("", result.bytes);
    try std.testing.expectEqual(FilterEnd.disconnect, result.end.?);
}

/// Restores local tty mode even when the remote PTY leaves itself in raw/no-echo
/// mode. This is one of sessh's explicit sharp-edge fixes over plain ssh.
pub const TerminalModeGuard = struct {
    fd: c.fd_t,
    original: ?posix.termios = null,

    pub fn enable(fd: c.fd_t) !TerminalModeGuard {
        var guard = TerminalModeGuard{ .fd = fd };
        if (c.isatty(fd) == 0) return guard;

        const original = try posix.tcgetattr(fd);
        var raw = original;
        makeRaw(&raw);
        try posix.tcsetattr(fd, .NOW, raw);
        guard.original = original;
        return guard;
    }

    pub fn restore(self: *TerminalModeGuard) void {
        const original = self.original orelse return;
        posix.tcsetattr(self.fd, .NOW, original) catch {};
        self.original = null;
    }
};

pub fn setSigpipe(handler: ?posix.Sigaction.handler_fn) void {
    const action = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &action, null);
}

pub fn currentWindowSize() WindowSize {
    if (getWindowSize(1)) |size| return size;
    if (getWindowSize(0)) |size| return size;
    return .{};
}

pub fn queryDefaultColors(input_fd: c.fd_t, output_fd: c.fd_t) !DefaultColorQuery {
    return (try queryTerminalProbe(input_fd, output_fd)).default_colors;
}

pub fn queryCursorPosition(input_fd: c.fd_t, output_fd: c.fd_t) !?CursorPosition {
    return (try queryTerminalProbe(input_fd, output_fd)).cursor_position;
}

pub fn queryKittyKeyboardFlags(input_fd: c.fd_t, output_fd: c.fd_t) !?u5 {
    if (cached_probe != null and
        cached_probe_input_fd == input_fd and
        cached_probe_output_fd == output_fd and
        cached_probe.?.kitty_keyboard_flags != null)
    {
        return cached_probe.?.kitty_keyboard_flags;
    }

    var probe = TerminalProbe{};
    if (c.isatty(input_fd) == 0 or c.isatty(output_fd) == 0) return null;

    var guard = try TerminalModeGuard.enable(input_fd);
    defer guard.restore();

    try io.writeAll(output_fd, kitty_keyboard_query);
    try readTerminalProbeResponses(input_fd, &probe, .kitty_keyboard_flags);
    mergeCachedProbe(input_fd, output_fd, probe);
    return probe.kitty_keyboard_flags;
}

const InitialKittyKeyboardFlags = struct {
    input_fd: c.fd_t,
    output_fd: c.fd_t,
    flags: u5,
};

var cached_initial_kitty_keyboard_flags: ?InitialKittyKeyboardFlags = null;

pub fn queryInitialKittyKeyboardFlags(input_fd: c.fd_t, output_fd: c.fd_t) u5 {
    if (cached_initial_kitty_keyboard_flags) |cached| {
        if (cached.input_fd == input_fd and cached.output_fd == output_fd) return cached.flags;
    }

    // Reconnects keep using the same outer terminal. Querying it again after
    // the reconnect overlay clears can race with typed-ahead input and consume
    // those bytes as probe responses.
    const flags = (queryKittyKeyboardFlags(input_fd, output_fd) catch null) orelse 0;
    cached_initial_kitty_keyboard_flags = .{
        .input_fd = input_fd,
        .output_fd = output_fd,
        .flags = flags,
    };
    return flags;
}

pub fn queryTerminalProbe(input_fd: c.fd_t, output_fd: c.fd_t) !TerminalProbe {
    if (cached_probe != null and cached_probe_input_fd == input_fd and cached_probe_output_fd == output_fd) return cached_probe.?;
    var probe = TerminalProbe{};
    if (c.isatty(input_fd) == 0 or c.isatty(output_fd) == 0) return probe;

    var guard = try TerminalModeGuard.enable(input_fd);
    defer guard.restore();

    try io.writeAll(output_fd, terminal_probe_request);

    try readTerminalProbeResponses(input_fd, &probe, .complete);

    cached_probe = probe;
    cached_probe_input_fd = input_fd;
    cached_probe_output_fd = output_fd;
    return probe;
}

const ProbeReadTarget = enum {
    complete,
    kitty_keyboard_flags,
};

fn readTerminalProbeResponses(input_fd: c.fd_t, probe: *TerminalProbe, target: ProbeReadTarget) !void {
    var bytes: [512]u8 = undefined;
    var len: usize = 0;
    const deadline = std.time.milliTimestamp() + terminal_query_timeout_ms;
    // BLOCKING_POLL: foreground local-terminal probe. It runs before the
    // visible client enters its main attached-client loop and has no daemon
    // dispatcher work to service.
    while (std.time.milliTimestamp() < deadline) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) break;
        var pollfds = [_]posix.pollfd{.{
            .fd = input_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = @intCast(@min(remaining, terminal_query_poll_ms));
        const ready = try posix.poll(&pollfds, timeout);
        if (ready == 0) continue;
        if ((pollfds[0].revents & posix.POLL.IN) == 0) {
            if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) break;
            continue;
        }
        if (len == bytes.len) break;
        const n = posix.read(input_fd, bytes[len..]) catch |err| switch (err) {
            error.WouldBlock, error.InputOutput => break,
            else => return err,
        };
        if (n == 0) break;
        io.noteRead(input_fd, bytes[len..][0..n]);
        len += n;
        parseTerminalProbeResponses(bytes[0..len], probe);
        switch (target) {
            .complete => if (probe.complete()) break,
            .kitty_keyboard_flags => if (probe.kitty_keyboard_flags != null) break,
        }
    }
}

fn mergeCachedProbe(input_fd: c.fd_t, output_fd: c.fd_t, probe: TerminalProbe) void {
    if (!probeHasData(probe)) return;
    if (cached_probe == null or
        cached_probe_input_fd != input_fd or
        cached_probe_output_fd != output_fd)
    {
        cached_probe = probe;
        cached_probe_input_fd = input_fd;
        cached_probe_output_fd = output_fd;
        return;
    }

    var merged = cached_probe.?;
    if (probe.cursor_position != null) merged.cursor_position = probe.cursor_position;
    if (probe.default_colors.foreground != null) merged.default_colors.foreground = probe.default_colors.foreground;
    if (probe.default_colors.background != null) merged.default_colors.background = probe.default_colors.background;
    if (probe.kitty_keyboard_flags != null) merged.kitty_keyboard_flags = probe.kitty_keyboard_flags;
    if (probe.allowed_features_answered) merged.allowed_features_answered = true;
    if (probe.color_ops_allowed != null) merged.color_ops_allowed = probe.color_ops_allowed;
    cached_probe = merged;
}

fn probeHasData(probe: TerminalProbe) bool {
    return probe.cursor_position != null or
        probe.default_colors.foreground != null or
        probe.default_colors.background != null or
        probe.kitty_keyboard_flags != null or
        probe.allowed_features_answered or
        probe.color_ops_allowed != null;
}

pub fn setPtySize(fd: c.fd_t, rows: u16, cols: u16) bool {
    const request = ioctlSetWinszRequest() orelse return false;

    var size = c.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    return ioctl(fd, request, &size) == 0;
}

fn makeRaw(term: *posix.termios) void {
    term.iflag.BRKINT = false;
    term.iflag.ICRNL = false;
    term.iflag.INPCK = false;
    term.iflag.ISTRIP = false;
    term.iflag.IXON = false;

    term.oflag.OPOST = false;

    term.cflag.CSIZE = .CS8;
    term.cflag.PARENB = false;

    term.lflag.ECHO = false;
    term.lflag.ICANON = false;
    term.lflag.IEXTEN = false;
    term.lflag.ISIG = false;

    term.cc[@intFromEnum(posix.V.MIN)] = 1;
    term.cc[@intFromEnum(posix.V.TIME)] = 0;
}

fn getWindowSize(fd: c.fd_t) ?WindowSize {
    if (c.isatty(fd) == 0) return null;
    if (!@hasDecl(c.T, "IOCGWINSZ")) return null;

    var size = c.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = ioctl(fd, ioctlRequest(c.T.IOCGWINSZ), &size);
    if (rc != 0 or size.row == 0 or size.col == 0) return null;
    return .{ .rows = size.row, .cols = size.col };
}

fn ioctlRequest(value: anytype) c_ulong {
    return @intCast(value);
}

fn ioctlSetWinszRequest() ?c_ulong {
    if (@hasDecl(c.T, "IOCSWINSZ")) return ioctlRequest(c.T.IOCSWINSZ);
    return switch (builtin.os.tag) {
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => ioctlRequest(0x80087467),
        else => null,
    };
}

fn csiFinalIndex(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, index| {
        if (byte >= 0x40 and byte <= 0x7e) return index;
    }
    return null;
}

fn parseCursorPositionResponse(bytes: []const u8) ?CursorPosition {
    var rest = bytes;
    while (std.mem.indexOf(u8, rest, "\x1b[")) |start| {
        const response = rest[start + 2 ..];
        const end = csiFinalIndex(response) orelse return null;
        const final = response[end];
        const body = response[0..end];
        rest = response[end + 1 ..];
        if (final != 'R') continue;
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse {
            continue;
        };
        const row = std.fmt.parseInt(u16, body[0..semi], 10) catch {
            continue;
        };
        const col = std.fmt.parseInt(u16, body[semi + 1 ..], 10) catch {
            continue;
        };
        if (row == 0 or col == 0) return null;
        return .{ .row = row - 1, .col = col - 1 };
    }
    return null;
}

fn parseTerminalProbeResponses(bytes: []const u8, probe: *TerminalProbe) void {
    if (probe.cursor_position == null) probe.cursor_position = parseCursorPositionResponse(bytes);
    if (probe.kitty_keyboard_flags == null) probe.kitty_keyboard_flags = parseKittyKeyboardFlagsResponse(bytes);
    parseOscProbeResponses(bytes, probe);
}

fn parseKittyKeyboardFlagsResponse(bytes: []const u8) ?u5 {
    var rest = bytes;
    while (std.mem.indexOf(u8, rest, "\x1b[")) |start| {
        const response = rest[start + 2 ..];
        const end = csiFinalIndex(response) orelse return null;
        const final = response[end];
        const body = response[0..end];
        rest = response[end + 1 ..];
        if (final != 'u' or !std.mem.startsWith(u8, body, "?")) continue;
        const value = std.fmt.parseInt(u8, body[1..], 10) catch continue;
        if (value <= std.math.maxInt(u5)) return @intCast(value);
    }
    return null;
}

fn parseOscProbeResponses(bytes: []const u8, probe: *TerminalProbe) void {
    var rest = bytes;
    while (std.mem.indexOf(u8, rest, "\x1b]")) |start| {
        const content_start = start + 2;
        const content_and_after = rest[content_start..];
        const bel = std.mem.indexOfScalar(u8, content_and_after, '\x07');
        const st = std.mem.indexOf(u8, content_and_after, "\x1b\\");
        const end = if (bel) |bel_index|
            if (st) |st_index| @min(bel_index, st_index) else bel_index
        else if (st) |st_index|
            st_index
        else
            return;

        parseOscProbeContent(content_and_after[0..end], probe);

        const terminator_len: usize = if (bel != null and bel.? == end) 1 else 2;
        rest = content_and_after[end + terminator_len ..];
    }
}

fn parseOscProbeContent(content: []const u8, probe: *TerminalProbe) void {
    if (std.mem.startsWith(u8, content, "10;")) {
        probe.default_colors.foreground = parseRgbSpec(content[3..]) orelse probe.default_colors.foreground;
    } else if (std.mem.startsWith(u8, content, "11;")) {
        probe.default_colors.background = parseRgbSpec(content[3..]) orelse probe.default_colors.background;
    } else if (std.mem.startsWith(u8, content, "60;")) {
        probe.allowed_features_answered = true;
        probe.color_ops_allowed = featureListContains(content[3..], "allowColorOps");
    }
}

fn featureListContains(list: []const u8, name: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, list, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(token, name)) return true;
    }
    return false;
}

fn parseDefaultColorResponses(bytes: []const u8, result: *DefaultColorQuery) void {
    var probe = TerminalProbe{ .default_colors = result.* };
    parseOscProbeResponses(bytes, &probe);
    result.* = probe.default_colors;
}

fn parseRgbSpec(spec: []const u8) ?Rgb {
    if (!std.mem.startsWith(u8, spec, "rgb:")) return null;
    var channels = std.mem.splitScalar(u8, spec[4..], '/');
    const r = parseRgbChannel(channels.next() orelse return null) orelse return null;
    const g = parseRgbChannel(channels.next() orelse return null) orelse return null;
    const b = parseRgbChannel(channels.next() orelse return null) orelse return null;
    if (channels.next() != null) return null;
    return .{ .r = r, .g = g, .b = b };
}

fn parseRgbChannel(hex: []const u8) ?u8 {
    if (hex.len == 0 or hex.len > 4) return null;
    const value = std.fmt.parseInt(u32, hex, 16) catch return null;
    const max = (@as(u32, 1) << @intCast(hex.len * 4)) - 1;
    return @intCast((value * 255 + max / 2) / max);
}

test "default color response parser handles OSC 10 and OSC 11" {
    var result = DefaultColorQuery{};
    parseDefaultColorResponses(
        "noise\x1b]10;rgb:ffff/eeee/dddd\x1b\\more\x1b]11;rgb:01/23/45\x07",
        &result,
    );

    try std.testing.expectEqual(Rgb{ .r = 255, .g = 238, .b = 221 }, result.foreground.?);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 35, .b = 69 }, result.background.?);
}

test "terminal probe parser handles batched allowed features, cursor, and color responses" {
    var probe = TerminalProbe{};
    parseTerminalProbeResponses(
        "\x1b]60;allowTitleOps,allowColorOps\x1b\\" ++
            "\x1b[?7u" ++
            "\x1b[7;9R" ++
            "\x1b]10;rgb:0a/0b/0c\x1b\\" ++
            "\x1b]11;rgb:0d/0e/0f\x1b\\",
        &probe,
    );

    try std.testing.expect(probe.allowed_features_answered);
    try std.testing.expect(probe.color_ops_allowed.?);
    try std.testing.expectEqual(@as(u5, 7), probe.kitty_keyboard_flags.?);
    try std.testing.expectEqual(CursorPosition{ .row = 6, .col = 8 }, probe.cursor_position.?);
    try std.testing.expectEqual(Rgb{ .r = 10, .g = 11, .b = 12 }, probe.default_colors.foreground.?);
    try std.testing.expectEqual(Rgb{ .r = 13, .g = 14, .b = 15 }, probe.default_colors.background.?);
    try std.testing.expect(probe.complete());
}

test "terminal probe parser ignores invalid kitty keyboard flags" {
    var probe = TerminalProbe{};
    parseTerminalProbeResponses("\x1b[?64u\x1b[?abcu\x1b[?31u", &probe);

    try std.testing.expectEqual(@as(u5, 31), probe.kitty_keyboard_flags.?);
}

test "terminal probe parser treats answered allowed features without color ops as complete after cursor" {
    var probe = TerminalProbe{};
    parseTerminalProbeResponses("\x1b]60;allowTitleOps\x1b\\\x1b[2;3R", &probe);

    try std.testing.expect(probe.allowed_features_answered);
    try std.testing.expect(!probe.color_ops_allowed.?);
    try std.testing.expectEqual(CursorPosition{ .row = 1, .col = 2 }, probe.cursor_position.?);
    try std.testing.expect(probe.default_colors.foreground == null);
    try std.testing.expect(probe.default_colors.background == null);
    try std.testing.expect(probe.complete());
}
