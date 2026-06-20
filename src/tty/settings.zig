// Portable representation of terminal modes passed between local probes and
// spawned PTYs. It translates the subset sessh cares about into termios changes
// without exposing platform-specific constants to session code.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

extern "c" fn cfgetispeed(termios_p: *const posix.termios) posix.speed_t;
extern "c" fn cfgetospeed(termios_p: *const posix.termios) posix.speed_t;
extern "c" fn cfsetispeed(termios_p: *posix.termios, speed: posix.speed_t) c_int;
extern "c" fn cfsetospeed(termios_p: *posix.termios, speed: posix.speed_t) c_int;

// SSH's `pty-req` channel request does not send native termios structs. It
// sends a list of terminal-mode opcodes defined by RFC 4254 section 8: opcode
// 0 terminates the list, 128/129 carry input/output baud rates, and the
// numbered mode tables below are the wire numbers OpenSSH uses for POSIX
// control characters and flags.
pub const op_end = 0;
pub const op_ispeed = 128;
pub const op_ospeed = 129;

pub const Mode = struct {
    opcode: u8,
    value: u32,
};

pub const Settings = struct {
    term: ?[]const u8 = null,
    modes: []const Mode = &.{},

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.term) |term| allocator.free(term);
        allocator.free(self.modes);
        self.* = undefined;
    }
};

pub const TermCapture = enum {
    include,
    omit,
};

const CharMode = struct {
    name: []const u8,
    opcode: u8,
};

const FlagMode = struct {
    name: []const u8,
    opcode: u8,
};

const char_modes = [_]CharMode{
    .{ .name = "INTR", .opcode = 1 },
    .{ .name = "QUIT", .opcode = 2 },
    .{ .name = "ERASE", .opcode = 3 },
    .{ .name = "KILL", .opcode = 4 },
    .{ .name = "EOF", .opcode = 5 },
    .{ .name = "EOL", .opcode = 6 },
    .{ .name = "EOL2", .opcode = 7 },
    .{ .name = "START", .opcode = 8 },
    .{ .name = "STOP", .opcode = 9 },
    .{ .name = "SUSP", .opcode = 10 },
    .{ .name = "DSUSP", .opcode = 11 },
    .{ .name = "REPRINT", .opcode = 12 },
    .{ .name = "WERASE", .opcode = 13 },
    .{ .name = "LNEXT", .opcode = 14 },
    .{ .name = "FLUSH", .opcode = 15 },
    .{ .name = "SWTCH", .opcode = 16 },
    .{ .name = "STATUS", .opcode = 17 },
    .{ .name = "DISCARD", .opcode = 18 },
};

const iflag_modes = [_]FlagMode{
    .{ .name = "IGNPAR", .opcode = 30 },
    .{ .name = "PARMRK", .opcode = 31 },
    .{ .name = "INPCK", .opcode = 32 },
    .{ .name = "ISTRIP", .opcode = 33 },
    .{ .name = "INLCR", .opcode = 34 },
    .{ .name = "IGNCR", .opcode = 35 },
    .{ .name = "ICRNL", .opcode = 36 },
    .{ .name = "IUCLC", .opcode = 37 },
    .{ .name = "IXON", .opcode = 38 },
    .{ .name = "IXANY", .opcode = 39 },
    .{ .name = "IXOFF", .opcode = 40 },
    .{ .name = "IMAXBEL", .opcode = 41 },
    .{ .name = "IUTF8", .opcode = 42 },
};

const lflag_modes = [_]FlagMode{
    .{ .name = "ISIG", .opcode = 50 },
    .{ .name = "ICANON", .opcode = 51 },
    .{ .name = "XCASE", .opcode = 52 },
    .{ .name = "ECHO", .opcode = 53 },
    .{ .name = "ECHOE", .opcode = 54 },
    .{ .name = "ECHOK", .opcode = 55 },
    .{ .name = "ECHONL", .opcode = 56 },
    .{ .name = "NOFLSH", .opcode = 57 },
    .{ .name = "TOSTOP", .opcode = 58 },
    .{ .name = "IEXTEN", .opcode = 59 },
    .{ .name = "ECHOCTL", .opcode = 60 },
    .{ .name = "ECHOKE", .opcode = 61 },
    .{ .name = "PENDIN", .opcode = 62 },
};

const oflag_modes = [_]FlagMode{
    .{ .name = "OPOST", .opcode = 70 },
    .{ .name = "OLCUC", .opcode = 71 },
    .{ .name = "ONLCR", .opcode = 72 },
    .{ .name = "OCRNL", .opcode = 73 },
    .{ .name = "ONOCR", .opcode = 74 },
    .{ .name = "ONLRET", .opcode = 75 },
};

const cflag_modes = [_]FlagMode{
    .{ .name = "PARENB", .opcode = 92 },
    .{ .name = "PARODD", .opcode = 93 },
};

const SpeedPair = struct {
    name: []const u8,
    baud: u32,
};

const speed_pairs = [_]SpeedPair{
    .{ .name = "B0", .baud = 0 },
    .{ .name = "B50", .baud = 50 },
    .{ .name = "B75", .baud = 75 },
    .{ .name = "B110", .baud = 110 },
    .{ .name = "B134", .baud = 134 },
    .{ .name = "B150", .baud = 150 },
    .{ .name = "B200", .baud = 200 },
    .{ .name = "B300", .baud = 300 },
    .{ .name = "B600", .baud = 600 },
    .{ .name = "B1200", .baud = 1200 },
    .{ .name = "B1800", .baud = 1800 },
    .{ .name = "B2400", .baud = 2400 },
    .{ .name = "B4800", .baud = 4800 },
    .{ .name = "B9600", .baud = 9600 },
    .{ .name = "B19200", .baud = 19200 },
    .{ .name = "B38400", .baud = 38400 },
    .{ .name = "B7200", .baud = 7200 },
    .{ .name = "B14400", .baud = 14400 },
    .{ .name = "B28800", .baud = 28800 },
    .{ .name = "B57600", .baud = 57600 },
    .{ .name = "B76800", .baud = 76800 },
    .{ .name = "B115200", .baud = 115200 },
    .{ .name = "B230400", .baud = 230400 },
    .{ .name = "B460800", .baud = 460800 },
    .{ .name = "B500000", .baud = 500000 },
    .{ .name = "B576000", .baud = 576000 },
    .{ .name = "B921600", .baud = 921600 },
    .{ .name = "B1000000", .baud = 1000000 },
    .{ .name = "B1152000", .baud = 1152000 },
    .{ .name = "B1500000", .baud = 1500000 },
    .{ .name = "B2000000", .baud = 2000000 },
    .{ .name = "B2500000", .baud = 2500000 },
    .{ .name = "B3000000", .baud = 3000000 },
    .{ .name = "B3500000", .baud = 3500000 },
    .{ .name = "B4000000", .baud = 4000000 },
};

/// Capture the same kind of portable PTY metadata OpenSSH sends in pty-req:
/// optional TERM plus opcode/value tty modes. The local tty may be macOS and
/// the remote may be Linux, so this must never copy the native termios bytes
/// directly.
pub fn capture(allocator: std.mem.Allocator, fd: c.fd_t, term_capture: TermCapture) !?Settings {
    var settings = Settings{
        .term = if (term_capture == .include) try captureTerm(allocator) else null,
    };
    errdefer settings.deinit(allocator);

    if (c.isatty(fd) != 0) {
        const termios = try posix.tcgetattr(fd);
        settings.modes = try modesFromTermios(allocator, termios);
    }

    if (settings.term == null and settings.modes.len == 0) return null;
    return settings;
}

fn captureTerm(allocator: std.mem.Allocator) !?[]u8 {
    const term_z = c.getenv("TERM") orelse return null;
    return try allocator.dupe(u8, std.mem.span(term_z));
}

fn modesFromTermios(allocator: std.mem.Allocator, termios: posix.termios) ![]Mode {
    // Capture local termios into SSH pty-req mode opcodes so the remote PTY can
    // inherit line discipline and control characters without sharing native
    // struct layouts across platforms.
    var modes: std.ArrayList(Mode) = .empty;
    errdefer modes.deinit(allocator);

    try modes.append(allocator, .{ .opcode = op_ospeed, .value = speedToBaud(cfgetospeed(&termios)) });
    try modes.append(allocator, .{ .opcode = op_ispeed, .value = speedToBaud(cfgetispeed(&termios)) });

    const writer = ModeWriter{ .modes = &modes, .allocator = allocator };
    inline for (char_modes) |mode| try writer.appendChar(termios, mode);
    inline for (iflag_modes) |mode| try writer.appendFlag(termios.iflag, mode);
    inline for (lflag_modes) |mode| try writer.appendFlag(termios.lflag, mode);
    inline for (oflag_modes) |mode| try writer.appendFlag(termios.oflag, mode);
    // Character size is encoded as the SSH CS7/CS8 opcodes, not as the native
    // CSIZE bitmask. That keeps the captured mode list portable across OSes.
    try modes.append(allocator, .{ .opcode = 90, .value = @intFromBool(termios.cflag.CSIZE == .CS7) });
    try modes.append(allocator, .{ .opcode = 91, .value = @intFromBool(termios.cflag.CSIZE == .CS8) });
    inline for (cflag_modes) |mode| try writer.appendFlag(termios.cflag, mode);

    return modes.toOwnedSlice(allocator);
}

pub fn applyToFd(settings: Settings, fd: c.fd_t) !void {
    var termios = try posix.tcgetattr(fd);
    applyToTermios(settings, &termios);
    try posix.tcsetattr(fd, .NOW, termios);
}

fn applyToTermios(settings: Settings, termios: *posix.termios) void {
    for (settings.modes) |mode| applyMode(termios, mode.opcode, mode.value);
}

fn encodeModes(allocator: std.mem.Allocator, modes: []const Mode) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (modes) |mode| {
        try out.append(allocator, mode.opcode);
        try appendU32(&out, allocator, mode.value);
    }
    try out.append(allocator, op_end);
    return out.toOwnedSlice(allocator);
}

fn decodeModes(allocator: std.mem.Allocator, bytes: []const u8) ![]Mode {
    var modes: std.ArrayList(Mode) = .empty;
    errdefer modes.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const opcode = bytes[i];
        i += 1;
        if (opcode == op_end) return modes.toOwnedSlice(allocator);
        if (opcode >= 160) return modes.toOwnedSlice(allocator);
        if (i + 4 > bytes.len) return error.InvalidTtyModeBytes;
        try modes.append(allocator, .{
            .opcode = opcode,
            .value = readU32(bytes[i..][0..4]),
        });
        i += 4;
    }
    return error.InvalidTtyModeBytes;
}

const ModeWriter = struct {
    modes: *std.ArrayList(Mode),
    allocator: std.mem.Allocator,

    fn appendChar(self: ModeWriter, termios: posix.termios, comptime mode: CharMode) !void {
        if (comptime !enumHasField(posix.V, mode.name)) return;
        const index = @intFromEnum(@field(posix.V, mode.name));
        try self.modes.append(self.allocator, .{
            .opcode = mode.opcode,
            .value = encodeControlChar(@intCast(termios.cc[index])),
        });
    }

    fn appendFlag(self: ModeWriter, flags: anytype, comptime mode: FlagMode) !void {
        if (comptime !@hasField(@TypeOf(flags), mode.name)) return;
        try self.modes.append(self.allocator, .{
            .opcode = mode.opcode,
            .value = @intFromBool(@field(flags, mode.name)),
        });
    }
};

fn applyMode(termios: *posix.termios, opcode: u8, value: u32) void {
    // Reverse RFC 4254/OpenSSH pty-req mode opcodes back onto the local
    // platform's termios shape. Unknown or unsupported opcodes are ignored like
    // OpenSSH does, which matters when client and remote platforms expose
    // different tty knobs.
    switch (opcode) {
        op_ispeed => setInputSpeed(termios, value),
        op_ospeed => setOutputSpeed(termios, value),
        1 => setControlChar(termios, "INTR", value),
        2 => setControlChar(termios, "QUIT", value),
        3 => setControlChar(termios, "ERASE", value),
        4 => setControlChar(termios, "KILL", value),
        5 => setControlChar(termios, "EOF", value),
        6 => setControlChar(termios, "EOL", value),
        7 => setControlChar(termios, "EOL2", value),
        8 => setControlChar(termios, "START", value),
        9 => setControlChar(termios, "STOP", value),
        10 => setControlChar(termios, "SUSP", value),
        11 => setControlChar(termios, "DSUSP", value),
        12 => setControlChar(termios, "REPRINT", value),
        13 => setControlChar(termios, "WERASE", value),
        14 => setControlChar(termios, "LNEXT", value),
        15 => setControlChar(termios, "FLUSH", value),
        16 => setControlChar(termios, "SWTCH", value),
        17 => setControlChar(termios, "STATUS", value),
        18 => setControlChar(termios, "DISCARD", value),
        30 => setFlag(&termios.iflag, "IGNPAR", value),
        31 => setFlag(&termios.iflag, "PARMRK", value),
        32 => setFlag(&termios.iflag, "INPCK", value),
        33 => setFlag(&termios.iflag, "ISTRIP", value),
        34 => setFlag(&termios.iflag, "INLCR", value),
        35 => setFlag(&termios.iflag, "IGNCR", value),
        36 => setFlag(&termios.iflag, "ICRNL", value),
        37 => setFlag(&termios.iflag, "IUCLC", value),
        38 => setFlag(&termios.iflag, "IXON", value),
        39 => setFlag(&termios.iflag, "IXANY", value),
        40 => setFlag(&termios.iflag, "IXOFF", value),
        41 => setFlag(&termios.iflag, "IMAXBEL", value),
        42 => setFlag(&termios.iflag, "IUTF8", value),
        50 => setFlag(&termios.lflag, "ISIG", value),
        51 => setFlag(&termios.lflag, "ICANON", value),
        52 => setFlag(&termios.lflag, "XCASE", value),
        53 => setFlag(&termios.lflag, "ECHO", value),
        54 => setFlag(&termios.lflag, "ECHOE", value),
        55 => setFlag(&termios.lflag, "ECHOK", value),
        56 => setFlag(&termios.lflag, "ECHONL", value),
        57 => setFlag(&termios.lflag, "NOFLSH", value),
        58 => setFlag(&termios.lflag, "TOSTOP", value),
        59 => setFlag(&termios.lflag, "IEXTEN", value),
        60 => setFlag(&termios.lflag, "ECHOCTL", value),
        61 => setFlag(&termios.lflag, "ECHOKE", value),
        62 => setFlag(&termios.lflag, "PENDIN", value),
        70 => setFlag(&termios.oflag, "OPOST", value),
        71 => setFlag(&termios.oflag, "OLCUC", value),
        72 => setFlag(&termios.oflag, "ONLCR", value),
        73 => setFlag(&termios.oflag, "OCRNL", value),
        74 => setFlag(&termios.oflag, "ONOCR", value),
        75 => setFlag(&termios.oflag, "ONLRET", value),
        90 => {
            if (value != 0) termios.cflag.CSIZE = .CS7;
        },
        91 => {
            if (value != 0) termios.cflag.CSIZE = .CS8;
        },
        92 => setFlag(&termios.cflag, "PARENB", value),
        93 => setFlag(&termios.cflag, "PARODD", value),
        else => {},
    }
}

fn setControlChar(termios: *posix.termios, comptime name: []const u8, value: u32) void {
    if (comptime !enumHasField(posix.V, name)) return;
    const index = @intFromEnum(@field(posix.V, name));
    termios.cc[index] = @intCast(decodeControlChar(value));
}

fn setFlag(flags: anytype, comptime name: []const u8, value: u32) void {
    const Flags = @TypeOf(flags.*);
    if (comptime !@hasField(Flags, name)) return;
    @field(flags.*, name) = value != 0;
}

fn encodeControlChar(value: u8) u32 {
    return if (value == posixVdisable()) 255 else value;
}

fn decodeControlChar(value: u32) u8 {
    return if (value == 255) posixVdisable() else @intCast(@min(value, 255));
}

fn posixVdisable() u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd => 0xff,
        else => 0,
    };
}

fn setInputSpeed(termios: *posix.termios, baud: u32) void {
    _ = cfsetispeed(termios, baudToSpeed(baud));
}

fn setOutputSpeed(termios: *posix.termios, baud: u32) void {
    _ = cfsetospeed(termios, baudToSpeed(baud));
}

fn speedToBaud(speed: posix.speed_t) u32 {
    inline for (speed_pairs) |pair| {
        if (comptime enumHasField(posix.speed_t, pair.name)) {
            if (speed == @field(posix.speed_t, pair.name)) return pair.baud;
        }
    }
    return 9600;
}

fn baudToSpeed(baud: u32) posix.speed_t {
    inline for (speed_pairs) |pair| {
        if (pair.baud == baud) {
            if (comptime enumHasField(posix.speed_t, pair.name)) return @field(posix.speed_t, pair.name);
        }
    }
    return @field(posix.speed_t, "B9600");
}

fn enumHasField(comptime T: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try out.append(allocator, @intCast((value >> 24) & 0xff));
    try out.append(allocator, @intCast((value >> 16) & 0xff));
    try out.append(allocator, @intCast((value >> 8) & 0xff));
    try out.append(allocator, @intCast(value & 0xff));
}

fn readU32(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

test "portable tty modes encode and decode like SSH terminal modes" {
    const modes = [_]Mode{
        .{ .opcode = op_ospeed, .value = 9600 },
        .{ .opcode = op_ispeed, .value = 9600 },
        .{ .opcode = 53, .value = 0 },
    };
    const encoded = try encodeModes(std.testing.allocator, &modes);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 16), encoded.len);
    try std.testing.expectEqual(@as(u8, op_ospeed), encoded[0]);
    try std.testing.expectEqual(@as(u8, op_end), encoded[15]);

    const decoded = try decodeModes(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Mode, &modes, decoded);
}
