const std = @import("std");

const client = @import("../session/client.zig");
const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const session_registry = @import("../runtime/session_registry.zig");

pub const Invocation = struct {
    command: Command,
    owned_ssh_words: ?[][]u8 = null,
    owned_ssh_options: ?[][]const u8 = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        switch (self.command) {
            .kill => |*kill| kill.deinit(allocator),
            else => {},
        }
        if (self.owned_ssh_options) |options| allocator.free(options);
        if (self.owned_ssh_words) |words| {
            for (words) |word| allocator.free(word);
            allocator.free(words);
        }
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    new: New,
    attach: Attach,
    list: List,
    kill: Kill,
    detach: ClientControl,
    repaint: ClientControl,
    debug: Debug,
};

pub const NewTarget = union(enum) {
    local,
    host: []const u8,
};

pub const AttachTarget = union(enum) {
    latest,
    local,
    host: []const u8,
    route_ref: []const u8,
};

pub const ListTarget = union(enum) {
    local,
    host: []const u8,
};

pub const KillCommandTarget = union(enum) {
    local,
    host: []const u8,
    route_ref_or_local_id: []const u8,
};

pub const New = struct {
    target: NewTarget,
    ssh_options: []const []const u8 = &.{},
    detached: bool = false,
    eval_args: bool = false,
    command_argv: []const []const u8 = &.{},
    common: CommonSessionOptions = .{},
};

pub const Attach = struct {
    target: AttachTarget,
    id: ?[]const u8 = null,
    ssh_options: []const []const u8 = &.{},
    common: CommonSessionOptions = .{},
};

pub const List = struct {
    target: ListTarget = .local,
    ssh_options: []const []const u8 = &.{},
    refresh: bool = false,
    include_cached_routes: bool = true,
    jsonl: bool = false,
    exited: bool = false,
    all: bool = false,
    client_target: ?[]const u8 = null,
    client_option_arg: ?[]const u8 = null,
    common: CommonSessionOptions = .{},
};

pub const Kill = struct {
    command_target: KillCommandTarget = .local,
    ssh_options: []const []const u8 = &.{},
    all: bool = false,
    current: bool = false,
    jsonl: bool = false,
    ids: []const []const u8 = &.{},
    owned_ids: ?[][]const u8 = null,
    request_jsons: []const []const u8 = &.{},
    owned_request_jsons: ?[][]const u8 = null,
    common: CommonSessionOptions = .{},

    pub fn deinit(self: *Kill, allocator: std.mem.Allocator) void {
        if (self.owned_ids) |ids| allocator.free(ids);
        if (self.owned_request_jsons) |requests| allocator.free(requests);
        self.owned_ids = null;
        self.ids = &.{};
        self.owned_request_jsons = null;
        self.request_jsons = &.{};
    }
};

pub const ClientControl = struct {
    target: ListTarget = .local,
    ssh_options: []const []const u8 = &.{},
    all: bool = false,
    last_input: bool = false,
    client_guid: ?[]const u8 = null,
    session_ref: ?[]const u8 = null,
    scrollback: bool = false,
    seconds: ?[]const u8 = null,
    common: CommonSessionOptions = .{},
};

pub const Debug = struct {
    action: DebugAction,
    control: ClientControl = .{},
    seconds: ?[]const u8 = null,
};

pub const DebugAction = enum {
    sever_connection,
    unresponsive_connection,
};

pub const CommonSessionOptions = struct {
    alias: ?[]const u8 = null,
    banner_args: client.DetachBannerArgs = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    bootstrap: bool = true,
    bootstrap_set: bool = false,
    terminal_emulator: bool = true,
    terminal_emulator_set: bool = false,
    filter_level: config.FilterLevel = config.default_filter_level,
    filter_level_set: bool = false,
    capture_tty_transcript: ?[]const u8 = null,
};

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    owned_ssh_words: std.ArrayList([]u8) = .empty,
    owned_ssh_options: ?[][]const u8 = null,

    pub fn deinit(self: *Scratch) void {
        if (self.owned_ssh_options) |options| self.allocator.free(options);
        for (self.owned_ssh_words.items) |word| self.allocator.free(word);
        self.owned_ssh_words.deinit(self.allocator);
    }

    pub fn finish(self: *Scratch, invocation: Command) !Invocation {
        const owned = if (self.owned_ssh_words.items.len > 0)
            try self.owned_ssh_words.toOwnedSlice(self.allocator)
        else
            null;
        self.owned_ssh_words = .empty;
        const owned_options = self.owned_ssh_options;
        self.owned_ssh_options = null;
        return .{ .command = invocation, .owned_ssh_words = owned, .owned_ssh_options = owned_options };
    }

    pub fn ownSshOptions(self: *Scratch, options: *std.ArrayList([]const u8)) ![]const []const u8 {
        if (options.items.len == 0) return &.{};
        std.debug.assert(self.owned_ssh_options == null);
        const owned = try options.toOwnedSlice(self.allocator);
        self.owned_ssh_options = owned;
        return owned;
    }
};

pub fn appendRemoteCommonArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), common: CommonSessionOptions) !void {
    if (common.client_log_level_set) {
        try out.append(allocator, "--log-level");
        try out.append(allocator, client_log.levelName(common.client_log_level));
    }
    if (common.capture_tty_transcript) |path| {
        try out.append(allocator, "--capture-tty-transcript");
        try out.append(allocator, path);
    }
}

pub const ClientControlTarget = enum {
    default,
    all,
    last_input,
    client_guid,
};

pub fn clientControlTarget(control: ClientControl) ClientControlTarget {
    if (control.all) return .all;
    if (control.last_input) return .last_input;
    if (control.client_guid != null) return .client_guid;
    return .default;
}

pub const CommandKind = enum {
    new,
    attach,
    list,
    kill,
    client_control,
};

pub const CommandParts = struct {
    ssh_options: std.ArrayList([]const u8) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList([]const u8) = .empty,
    host: ?[]const u8 = null,
    common: CommonSessionOptions = .{},

    pub fn deinit(self: *CommandParts, allocator: std.mem.Allocator) void {
        self.ssh_options.deinit(allocator);
        self.positionals.deinit(allocator);
        self.ids.deinit(allocator);
    }
};

pub fn parseSharedParts(scratch: *Scratch, args: []const []const u8, parsed: *CommandParts, kind: CommandKind) !void {
    var i: usize = 0;
    while (i < args.len) {
        if (try parseSharedOption(scratch, args, &i, parsed, kind)) continue;
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnsupportedMuxOption;
        try parsed.positionals.append(scratch.allocator, args[i]);
        i += 1;
    }
}

pub fn parseSharedPartsWithCommandOptions(
    scratch: *Scratch,
    args: []const []const u8,
    parsed: *CommandParts,
    kind: CommandKind,
    comptime parseCommandOption: fn ([]const u8, *CommandParts, *List) anyerror!bool,
    command_options: *List,
) !void {
    var i: usize = 0;
    while (i < args.len) {
        if (try parseCommandOption(args[i], parsed, command_options)) {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--client") or std.mem.startsWith(u8, args[i], "--client=")) {
            i += if (std.mem.eql(u8, args[i], "--client")) @as(usize, 2) else @as(usize, 1);
        } else if (try parseSharedOption(scratch, args, &i, parsed, kind)) {
            continue;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            return error.UnsupportedMuxOption;
        } else {
            try parsed.positionals.append(scratch.allocator, args[i]);
            i += 1;
        }
    }
}

pub fn parseSharedOption(scratch: *Scratch, args: []const []const u8, index: *usize, parsed: *CommandParts, kind: CommandKind) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--id")) {
        if (!commandKindAllowsId(kind)) return false;
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingId;
        try parsed.ids.append(scratch.allocator, args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--host")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "-")) return error.MissingHost;
        if (parsed.host != null) return error.MultipleTargets;
        parsed.host = args[index.*];
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--ssh-options")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingSshOptions;
        try appendShellSplitWords(scratch, &parsed.ssh_options, args[index.*]);
        index.* += 1;
        return true;
    }
    return parseCommonOption(args, index, &parsed.common, kind);
}

fn commandKindAllowsId(kind: CommandKind) bool {
    return switch (kind) {
        .attach, .kill, .client_control => true,
        .new, .list => false,
    };
}

pub fn parseCommonOption(args: []const []const u8, index: *usize, common: *CommonSessionOptions, kind: CommandKind) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--log-level")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingClientLogLevel;
        common.client_log_level = try client_log.parseLevel(args[index.*]);
        common.client_log_level_set = true;
        try common.banner_args.append(arg);
        try common.banner_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
        common.capture_tty_transcript = args[index.*];
        index.* += 1;
        return true;
    }
    if (kind != .new) {
        if (std.mem.eql(u8, arg, "--alias") or
            std.mem.eql(u8, arg, "--scrollback-limit") or
            std.mem.eql(u8, arg, "--initial-scrollback") or
            std.mem.eql(u8, arg, "--bootstrap") or
            std.mem.eql(u8, arg, "--no-bootstrap") or
            std.mem.eql(u8, arg, "--terminal-emulator") or
            std.mem.eql(u8, arg, "--no-terminal-emulator") or
            std.mem.eql(u8, arg, "--filter-level"))
        {
            return error.UnsupportedMuxOption;
        }
        return false;
    }
    if (std.mem.eql(u8, arg, "--alias")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingAlias;
        if (!session_registry.isValidCustomAlias(args[index.*])) return error.InvalidAlias;
        common.alias = args[index.*];
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--scrollback-limit")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingScrollbackRowCount;
        common.scrollback_row_count = try client.parseScrollbackRowCount(args[index.*]);
        common.scrollback_row_count_set = true;
        try common.banner_args.append(arg);
        try common.banner_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--initial-scrollback")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingInitialScrollback;
        common.initial_scrollback_row_count = try client.parseInitialScrollbackRowCount(args[index.*]);
        common.initial_scrollback_row_count_set = true;
        try common.banner_args.append(arg);
        try common.banner_args.append(args[index.*]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--bootstrap")) {
        common.bootstrap = true;
        common.bootstrap_set = true;
        try common.banner_args.append(arg);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-bootstrap")) {
        common.bootstrap = false;
        common.bootstrap_set = true;
        try common.banner_args.append(arg);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--terminal-emulator")) {
        common.terminal_emulator = true;
        common.terminal_emulator_set = true;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-terminal-emulator")) {
        common.terminal_emulator = false;
        common.terminal_emulator_set = true;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--filter-level")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingFilterLevel;
        common.filter_level = try config.parseFilterLevel(args[index.*]);
        common.filter_level_set = true;
        index.* += 1;
        return true;
    }
    return false;
}

pub fn applyClientControlPositionals(control: *ClientControl, positional: []const []const u8, repaint_defaults_to_all: bool) !void {
    if (positional.len == 1) {
        if (looksLikeClientGuid(positional[0])) {
            control.client_guid = positional[0];
        } else {
            control.session_ref = positional[0];
        }
    } else if (positional.len == 2) {
        control.client_guid = positional[0];
        control.session_ref = positional[1];
    } else if (positional.len > 2) {
        return error.TooManyMuxArguments;
    }

    var explicit_targets: u8 = 0;
    if (control.all) explicit_targets += 1;
    if (control.last_input) explicit_targets += 1;
    if (control.client_guid != null) explicit_targets += 1;
    if (explicit_targets > 1) return error.MultipleTargets;
    if (repaint_defaults_to_all and !control.last_input and control.client_guid == null) control.all = true;
}

pub fn singleOptionalId(option_ids: []const []const u8, positionals: []const []const u8) !?[]const u8 {
    if (option_ids.len > 1 or positionals.len > 1) return error.TooManyMuxArguments;
    if (option_ids.len == 1 and positionals.len == 1) return error.TooManyMuxArguments;
    if (option_ids.len == 1) return option_ids[0];
    if (positionals.len == 1) return positionals[0];
    return null;
}

pub fn setKillIds(
    scratch: *Scratch,
    kill: *Kill,
    option_ids: []const []const u8,
    positional_ids: []const []const u8,
) !void {
    if (option_ids.len == 0) {
        kill.ids = positional_ids;
        return;
    }
    const owned = try scratch.allocator.alloc([]const u8, option_ids.len + positional_ids.len);
    errdefer scratch.allocator.free(owned);
    @memcpy(owned[0..option_ids.len], option_ids);
    @memcpy(owned[option_ids.len..], positional_ids);
    kill.owned_ids = owned;
    kill.ids = owned;
}

pub fn appendShellSplitWords(scratch: *Scratch, out: *std.ArrayList([]const u8), value: []const u8) !void {
    var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(scratch.allocator, value);
    defer it.deinit();
    while (it.next()) |word| {
        const owned = try scratch.allocator.dupe(u8, word);
        errdefer scratch.allocator.free(owned);
        try scratch.owned_ssh_words.append(scratch.allocator, owned);
        try out.append(scratch.allocator, owned);
    }
}

pub fn looksLikeKillTarget(value: []const u8) bool {
    return std.mem.startsWith(u8, value, session_registry.session_guid_prefix) or
        std.mem.startsWith(u8, value, session_registry.proxy_guid_prefix);
}

pub fn looksLikeClientGuid(value: []const u8) bool {
    return session_registry.isValidClientGuid(value) or std.mem.startsWith(u8, value, session_registry.client_guid_prefix);
}

pub fn parseDebugAction(value: []const u8) !DebugAction {
    if (std.mem.eql(u8, value, "sever-connection")) return .sever_connection;
    if (std.mem.eql(u8, value, "unresponsive-connection")) return .unresponsive_connection;
    return error.InvalidDebugAction;
}

pub fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}
