// Decoders and encoders for requests sent to a terminal worker. The worker loop
// receives explicit request structs while this module handles raw protobuf
// fields.
const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const guid_ref = @import("../core/guid.zig");
const protocol = @import("../protocol/mod.zig");
const pty_process = @import("../tty/pty_process.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const vt = @import("vt.zig");

const pb = protocol.pb;
const WindowSize = terminal.WindowSize;

pub const SessionEnvironment = struct {
    shell: ?[]const u8 = null,
    entries: std.ArrayList(pty_process.EnvironmentEntry) = .empty,

    pub fn deinit(self: *SessionEnvironment) void {
        if (self.shell) |shell| app_allocator.allocator().free(shell);
        for (self.entries.items) |entry| {
            app_allocator.allocator().free(entry.name);
            app_allocator.allocator().free(entry.value);
        }
        self.entries.deinit(app_allocator.allocator());
        self.* = .{};
    }
};

pub const VisibleClientOpenRequest = struct {
    resize: ResizePayload,
    session_guid: []u8,
    capture_tty_transcript: bool,

    pub fn deinit(self: *VisibleClientOpenRequest) void {
        app_allocator.allocator().free(self.session_guid);
        self.* = undefined;
    }
};

const SessionCreateRequest = struct {
    resize: ResizePayload,
    scrollback_row_count: u32,
    environment: SessionEnvironment,
    query_default_colors: vt.DefaultColors,
    session_guid: []u8,
    command_argv: [][]u8,
    shell_command: ?[]u8,
    tty_settings: ?tty_settings.Settings,
    reap_ms: u64,
    capture_tty_transcript: bool,

    pub fn deinit(self: *SessionCreateRequest) void {
        app_allocator.allocator().free(self.session_guid);
        for (self.command_argv) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(self.command_argv);
        if (self.shell_command) |shell_command| app_allocator.allocator().free(shell_command);
        if (self.tty_settings) |*settings| settings.deinit(app_allocator.allocator());
        self.environment.deinit();
        self.* = undefined;
    }
};

pub const RepaintRequest = struct {
    repaint_request_seq: u64,
    scrollback_cursor: ?ScrollbackCursor,
};

pub const ScrollbackCursor = struct {
    epoch: u64,
    per_epoch_cursor: u64,
};

pub const encoded_scrollback_cursor_len = 16;

pub const ResizePayload = struct {
    size: WindowSize,
    viewport_offset: ?i32,
    repaint_request: ?RepaintRequest,
};

fn readDefaultColorValue(color: u32) !u32 {
    if (color == vt.CellAttrs.default_color) return color;
    if ((color & 0xff000000) == 0x01000000) return color;
    return error.InvalidDefaultColor;
}

pub fn encodeScrollbackCursor(epoch: u64, per_epoch_cursor: u64) [encoded_scrollback_cursor_len]u8 {
    var out: [encoded_scrollback_cursor_len]u8 = undefined;
    writeU64BigEndian(out[0..8], epoch);
    writeU64BigEndian(out[8..16], per_epoch_cursor);
    return out;
}

fn decodeScrollbackCursor(bytes: []const u8) !ScrollbackCursor {
    if (bytes.len == 0) return .{ .epoch = 0, .per_epoch_cursor = 0 };
    if (bytes.len != encoded_scrollback_cursor_len) return error.InvalidScrollbackCursor;
    return .{
        .epoch = readU64BigEndian(bytes[0..8]),
        .per_epoch_cursor = readU64BigEndian(bytes[8..16]),
    };
}

fn writeU64BigEndian(bytes: []u8, value: u64) void {
    bytes[0] = @intCast((value >> 56) & 0xff);
    bytes[1] = @intCast((value >> 48) & 0xff);
    bytes[2] = @intCast((value >> 40) & 0xff);
    bytes[3] = @intCast((value >> 32) & 0xff);
    bytes[4] = @intCast((value >> 24) & 0xff);
    bytes[5] = @intCast((value >> 16) & 0xff);
    bytes[6] = @intCast((value >> 8) & 0xff);
    bytes[7] = @intCast(value & 0xff);
}

fn readU64BigEndian(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        @as(u64, bytes[7]);
}

pub fn readSessionCreateRequest(payload: []const u8) !SessionCreateRequest {
    // Convert the protobuf open payload into owned worker state. The visible
    // client may disappear after this frame is processed, so argv, environment,
    // tty settings, and terminal probe results must no longer borrow from the
    // decoded protobuf arena.
    var open = try protocol.decodePayload(pb.TerminalEmulatorItem.Open, app_allocator.allocator(), payload);
    defer open.deinit(app_allocator.allocator());
    const message = open.create orelse return error.MissingSessionCreate;
    const resize = open.resize orelse return error.MissingResize;
    if (!guid_ref.isValidSessionGuid(open.session_guid)) return error.InvalidSessionGuid;
    var environment = SessionEnvironment{};
    errdefer environment.deinit();
    var query_default_colors = vt.DefaultColors{};
    var request_tty_settings: ?tty_settings.Settings = null;
    errdefer if (request_tty_settings) |*settings| settings.deinit(app_allocator.allocator());

    for (message.environment.items) |entry| {
        try applySessionEnvironmentEntry(&environment, entry);
    }
    if (message.query_default_colors) |colors| {
        query_default_colors = try readDefaultColors(colors);
    }
    if (message.tty_settings) |settings| {
        request_tty_settings = try readTtySettings(settings);
    }
    var source_argv: []const []const u8 = &.{};
    var shell_command: ?[]const u8 = null;
    if (message.command) |command| switch (command) {
        .exec_command => |exec| source_argv = exec.argv.items,
        .shell_command => |shell| shell_command = shell.command,
    };

    const command_argv = try app_allocator.allocator().alloc([]u8, source_argv.len);
    var command_argv_initialized: usize = 0;
    errdefer {
        for (command_argv[0..command_argv_initialized]) |arg| app_allocator.allocator().free(arg);
        app_allocator.allocator().free(command_argv);
    }
    for (source_argv, 0..) |arg, i| {
        if (arg.len == 0) return error.InvalidCommandArgv;
        command_argv[i] = try app_allocator.allocator().dupe(u8, arg);
        command_argv_initialized += 1;
    }

    return .{
        .resize = try resizePayloadFromMessage(resize),
        .scrollback_row_count = message.scrollback_row_limit,
        .environment = environment,
        .query_default_colors = query_default_colors,
        .session_guid = try app_allocator.allocator().dupe(u8, open.session_guid),
        .command_argv = command_argv,
        .shell_command = if (shell_command) |command|
            try app_allocator.allocator().dupe(u8, command)
        else
            null,
        .tty_settings = request_tty_settings,
        .reap_ms = message.reap_ms,
        .capture_tty_transcript = open.capture_tty_transcript,
    };
}

fn readTtySettings(message: pb.TerminalEmulatorItem.SessionCreate.TtySettings) !tty_settings.Settings {
    var modes = try app_allocator.allocator().alloc(tty_settings.Mode, message.tty_mode.items.len);
    errdefer app_allocator.allocator().free(modes);
    for (message.tty_mode.items, 0..) |mode, i| {
        if (mode.opcode > std.math.maxInt(u8)) return error.InvalidTtySettings;
        modes[i] = .{
            .opcode = @intCast(mode.opcode),
            .value = mode.value,
        };
    }

    return .{
        .term = if (message.term) |term|
            try app_allocator.allocator().dupe(u8, term)
        else
            null,
        .modes = modes,
    };
}

fn applySessionEnvironmentEntry(environment: *SessionEnvironment, entry: pb.EnvironmentEntry) !void {
    if (!isValidEnvironmentEntry(entry)) return error.InvalidEnvironmentEntry;
    if (sessionEnvironmentHasEntry(environment, entry.name)) return;

    const name = try app_allocator.allocator().dupeZ(u8, entry.name);
    errdefer app_allocator.allocator().free(name);
    const value = try app_allocator.allocator().dupeZ(u8, entry.value);
    errdefer app_allocator.allocator().free(value);
    try environment.entries.append(app_allocator.allocator(), .{
        .name = name,
        .value = value,
    });

    if (std.mem.eql(u8, entry.name, "SHELL") and entry.value.len > 0 and environment.shell == null) {
        environment.shell = try app_allocator.allocator().dupe(u8, entry.value);
    }
}

fn sessionEnvironmentHasEntry(environment: *const SessionEnvironment, name: []const u8) bool {
    for (environment.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn isValidEnvironmentEntry(entry: pb.EnvironmentEntry) bool {
    return isValidEnvironmentName(entry.name) and
        std.mem.indexOfScalar(u8, entry.value, 0) == null;
}

fn isValidEnvironmentName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfScalar(u8, name, '=') == null and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

fn readDefaultColors(colors: pb.TerminalEmulatorItem.SessionCreate.DefaultColors) !vt.DefaultColors {
    return .{
        .foreground_color = try readDefaultColorValue(colors.foreground_color),
        .background_color = try readDefaultColorValue(colors.background_color),
    };
}

pub fn resizePayloadFromMessage(message: pb.TerminalEmulatorItem.Resize) !ResizePayload {
    if (message.terminal_rows > std.math.maxInt(u16) or
        message.terminal_cols > std.math.maxInt(u16))
    {
        return error.IntOutOfRange;
    }
    if (message.viewport_offset) |offset| {
        if (offset < -1) return error.InvalidViewportOffset;
        if (offset > std.math.maxInt(u16)) return error.IntOutOfRange;
    }
    return .{
        .size = .{
            .rows = @intCast(message.terminal_rows),
            .cols = @intCast(message.terminal_cols),
        },
        .viewport_offset = message.viewport_offset,
        .repaint_request = if (message.repaint_request) |repaint| try repaintRequestFromMessage(repaint) else null,
    };
}

pub fn visibleClientOpenRequestFromOpen(message: pb.TerminalEmulatorItem.Open) !VisibleClientOpenRequest {
    const resize = message.resize orelse return error.MissingResize;
    if (message.session_guid.len > 0 and !guid_ref.isValidSessionGuid(message.session_guid)) return error.InvalidSessionGuid;
    return .{
        .resize = try resizePayloadFromMessage(resize),
        .session_guid = try app_allocator.allocator().dupe(u8, message.session_guid),
        .capture_tty_transcript = message.capture_tty_transcript,
    };
}

pub fn repaintRequestFromMessage(message: pb.TerminalEmulatorItem.RepaintRequest) !RepaintRequest {
    return .{
        .repaint_request_seq = message.repaint_request_seq,
        .scrollback_cursor = if (message.scrollback_cursor) |cursor|
            try decodeScrollbackCursor(cursor)
        else
            null,
    };
}

test "resize payload decodes protobuf dimensions into window size" {
    const payload = try resizePayloadFromMessage(.{
        .terminal_rows = 33,
        .terminal_cols = 120,
        .viewport_offset = 4,
        .repaint_request = .{ .repaint_request_seq = 7 },
    });

    try std.testing.expectEqual(WindowSize{ .rows = 33, .cols = 120 }, payload.size);
    try std.testing.expectEqual(@as(?i32, 4), payload.viewport_offset);
    try std.testing.expectEqual(@as(u64, 7), payload.repaint_request.?.repaint_request_seq);
}

test "resize payload rejects impossible viewport offsets" {
    try std.testing.expectError(error.InvalidViewportOffset, resizePayloadFromMessage(.{
        .terminal_rows = 24,
        .terminal_cols = 80,
        .viewport_offset = -2,
    }));
}
