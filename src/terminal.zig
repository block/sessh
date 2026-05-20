const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");

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

pub const Leader = union(enum) {
    none,
    ctrl: u8,
};

pub const FilterEnd = enum {
    detach,
    repaint,
    reconnect,
};

pub const FilterResult = struct {
    bytes: []const u8,
    end: ?FilterEnd = null,
};

/// Removes local sessh escape sequences from terminal input before forwarding
/// bytes to the remote PTY. This mirrors ssh's line-start `~.` escape and the
/// optional sessh leader commands.
pub const EscapeFilter = struct {
    leader_byte: ?u8 = null,
    at_line_start: bool = true,
    pending_tilde: bool = false,
    pending_leader: bool = false,

    pub fn filter(self: *EscapeFilter, input: []const u8, out: []u8) FilterResult {
        var written: usize = 0;
        for (input) |byte| {
            if (self.pending_leader) {
                self.pending_leader = false;
                if (byte == 'd' or byte == 'D') {
                    return .{ .bytes = out[0..written], .end = .detach };
                }
                if (byte == 'r' or byte == 'R') {
                    return .{ .bytes = out[0..written], .end = .repaint };
                }
                if (byte == 's' or byte == 'S') {
                    return .{ .bytes = out[0..written], .end = .reconnect };
                }
                if (self.leader_byte) |leader| {
                    out[written] = leader;
                    written += 1;
                    self.at_line_start = false;
                }
            }

            if (self.pending_tilde) {
                self.pending_tilde = false;
                if (byte == '.') return .{ .bytes = out[0..written], .end = .detach };
                out[written] = '~';
                written += 1;
                self.at_line_start = false;
            }

            if (self.at_line_start and byte == '~') {
                self.pending_tilde = true;
                continue;
            }

            if (self.leader_byte) |leader| {
                if (byte == leader) {
                    self.pending_leader = true;
                    continue;
                }
            }

            out[written] = byte;
            written += 1;
            self.at_line_start = byte == '\n' or byte == '\r';
        }

        return .{ .bytes = out[0..written] };
    }
};

pub fn leaderByte(leader: Leader) ?u8 {
    return switch (leader) {
        .none => null,
        .ctrl => |key| key & 0x1f,
    };
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
    if (c.isatty(input_fd) == 0 or c.isatty(output_fd) == 0) return .{};

    var guard = try TerminalModeGuard.enable(input_fd);
    defer guard.restore();

    try io.writeAll(output_fd, "\x1b]10;?\x1b\\\x1b]11;?\x1b\\");

    var result = DefaultColorQuery{};
    var bytes: [512]u8 = undefined;
    var len: usize = 0;
    const deadline = std.time.milliTimestamp() + 150;
    while (std.time.milliTimestamp() < deadline and (result.foreground == null or result.background == null)) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) break;
        var pollfds = [_]posix.pollfd{.{
            .fd = input_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = @intCast(@min(remaining, 25));
        const ready = try posix.poll(&pollfds, timeout);
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) continue;
        if (len == bytes.len) break;
        const n = c.read(input_fd, bytes[len..].ptr, bytes.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        parseDefaultColorResponses(bytes[0..len], &result);
    }
    return result;
}

pub fn queryCursorPosition(input_fd: c.fd_t, output_fd: c.fd_t) !?CursorPosition {
    if (c.isatty(input_fd) == 0 or c.isatty(output_fd) == 0) return null;

    var guard = try TerminalModeGuard.enable(input_fd);
    defer guard.restore();

    try io.writeAll(output_fd, "\x1b[6n");

    var bytes: [64]u8 = undefined;
    var len: usize = 0;
    const deadline = std.time.milliTimestamp() + 150;
    while (std.time.milliTimestamp() < deadline) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) break;
        var pollfds = [_]posix.pollfd{.{
            .fd = input_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = @intCast(@min(remaining, 25));
        const ready = try posix.poll(&pollfds, timeout);
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) continue;
        if (len == bytes.len) break;
        const n = c.read(input_fd, bytes[len..].ptr, bytes.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        if (parseCursorPositionResponse(bytes[0..len])) |position| return position;
    }

    return null;
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

fn parseCursorPositionResponse(bytes: []const u8) ?CursorPosition {
    var rest = bytes;
    while (std.mem.indexOf(u8, rest, "\x1b[")) |start| {
        const response = rest[start + 2 ..];
        const end = std.mem.indexOfScalar(u8, response, 'R') orelse return null;
        const body = response[0..end];
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse {
            rest = response[end + 1 ..];
            continue;
        };
        const row = std.fmt.parseInt(u16, body[0..semi], 10) catch {
            rest = response[end + 1 ..];
            continue;
        };
        const col = std.fmt.parseInt(u16, body[semi + 1 ..], 10) catch {
            rest = response[end + 1 ..];
            continue;
        };
        if (row == 0 or col == 0) return null;
        return .{ .row = row - 1, .col = col - 1 };
    }
    return null;
}

fn parseDefaultColorResponses(bytes: []const u8, result: *DefaultColorQuery) void {
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

        const content = content_and_after[0..end];
        if (std.mem.startsWith(u8, content, "10;")) {
            result.foreground = parseRgbSpec(content[3..]) orelse result.foreground;
        } else if (std.mem.startsWith(u8, content, "11;")) {
            result.background = parseRgbSpec(content[3..]) orelse result.background;
        }

        const terminator_len: usize = if (bel != null and bel.? == end) 1 else 2;
        rest = content_and_after[end + terminator_len ..];
    }
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
