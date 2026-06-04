const std = @import("std");

const client = @import("client.zig");
const client_log = @import("client_log.zig");
const config = @import("config.zig");
const session_registry = @import("session_registry.zig");

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
    request_jsons: []const []const u8 = &.{},
    owned_request_jsons: ?[][]const u8 = null,
    common: CommonSessionOptions = .{},

    fn deinit(self: *Kill, allocator: std.mem.Allocator) void {
        if (self.owned_request_jsons) |requests| allocator.free(requests);
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

const Scratch = struct {
    allocator: std.mem.Allocator,
    owned_ssh_words: std.ArrayList([]u8) = .empty,
    owned_ssh_options: ?[][]const u8 = null,

    fn deinit(self: *Scratch) void {
        if (self.owned_ssh_options) |options| self.allocator.free(options);
        for (self.owned_ssh_words.items) |word| self.allocator.free(word);
        self.owned_ssh_words.deinit(self.allocator);
    }

    fn finish(self: *Scratch, invocation: Command) !Invocation {
        const owned = if (self.owned_ssh_words.items.len > 0)
            try self.owned_ssh_words.toOwnedSlice(self.allocator)
        else
            null;
        self.owned_ssh_words = .empty;
        const owned_options = self.owned_ssh_options;
        self.owned_ssh_options = null;
        return .{ .command = invocation, .owned_ssh_words = owned, .owned_ssh_options = owned_options };
    }

    fn ownSshOptions(self: *Scratch, options: *std.ArrayList([]const u8)) ![]const []const u8 {
        if (options.items.len == 0) return &.{};
        std.debug.assert(self.owned_ssh_options == null);
        const owned = try options.toOwnedSlice(self.allocator);
        self.owned_ssh_options = owned;
        return owned;
    }
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Invocation {
    if (args.len < 2) return error.UnsupportedMuxCommand;
    var scratch = Scratch{ .allocator = allocator };
    errdefer scratch.deinit();

    const command = args[1];
    if (std.mem.eql(u8, command, "new")) {
        return scratch.finish(.{ .new = try parseNew(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "attach")) {
        return scratch.finish(.{ .attach = try parseAttach(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "list")) {
        return scratch.finish(.{ .list = try parseList(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "kill")) {
        return scratch.finish(.{ .kill = try parseKill(&scratch, args[2..]) });
    } else if (std.mem.eql(u8, command, "detach")) {
        return scratch.finish(.{ .detach = try parseClientControl(&scratch, args[2..], false, null) });
    } else if (std.mem.eql(u8, command, "repaint")) {
        return scratch.finish(.{ .repaint = try parseClientControl(&scratch, args[2..], true, null) });
    } else if (std.mem.eql(u8, command, "debug")) {
        return scratch.finish(.{ .debug = try parseDebug(&scratch, args[2..]) });
    }
    return error.UnsupportedMuxCommand;
}

pub fn isSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "new") or
        std.mem.eql(u8, arg, "attach") or
        std.mem.eql(u8, arg, "list") or
        std.mem.eql(u8, arg, "kill") or
        std.mem.eql(u8, arg, "detach") or
        std.mem.eql(u8, arg, "repaint") or
        std.mem.eql(u8, arg, "debug");
}

fn parseNew(scratch: *Scratch, args: []const []const u8) !New {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(scratch.allocator);
    var common = CommonSessionOptions{};
    var host: ?[]const u8 = null;
    var command_argv: []const []const u8 = &.{};
    var eval_args = false;
    var detached = false;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (host == null) return error.MissingHost;
            i += 1;
            if (i >= args.len) return error.MissingCommandArgv;
            command_argv = args[i..];
            i = args.len;
        } else if (std.mem.eql(u8, arg, "--ssh-options")) {
            if (host != null) return error.SesshOptionAfterHost;
            i += 1;
            if (i >= args.len) return error.MissingSshOptions;
            try appendShellSplitWords(scratch, &ssh_options, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (host != null) return error.MultipleTargets;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "-")) return error.MissingHost;
            host = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--eval-args")) {
            if (host != null) return error.SesshOptionAfterHost;
            eval_args = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--detached")) {
            detached = true;
            i += 1;
        } else if (try parseCommonOption(args, &i, &common, .new)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else if (host == null) {
            host = arg;
            i += 1;
        } else {
            command_argv = args[i..];
            i = args.len;
        }
    }
    if (eval_args and command_argv.len == 0) return error.MissingEvalArgs;
    const resolved_host = host orelse return error.MissingHost;
    return .{
        .target = if (std.mem.eql(u8, resolved_host, ".")) .local else .{ .host = resolved_host },
        .ssh_options = try scratch.ownSshOptions(&ssh_options),
        .detached = detached,
        .eval_args = eval_args,
        .command_argv = command_argv,
        .common = common,
    };
}

fn parseAttach(scratch: *Scratch, args: []const []const u8) !Attach {
    var parsed = CommandParts{};
    defer parsed.deinit(scratch.allocator);
    try parseSharedParts(scratch, args, &parsed, .attach);
    if (parsed.host) |host| {
        if (parsed.positionals.items.len > 1) return error.TooManyMuxArguments;
        return .{
            .target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host },
            .id = if (parsed.positionals.items.len == 1) parsed.positionals.items[0] else null,
            .ssh_options = try scratch.ownSshOptions(&parsed.ssh_options),
            .common = parsed.common,
        };
    }
    if (parsed.ssh_options.items.len > 0) return error.MissingHost;
    return switch (parsed.positionals.items.len) {
        0 => .{ .target = .latest, .common = parsed.common },
        1 => .{ .target = .{ .route_ref = parsed.positionals.items[0] }, .common = parsed.common },
        else => error.TooManyMuxArguments,
    };
}

fn parseList(scratch: *Scratch, args: []const []const u8) !List {
    var parsed = CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var list = List{};
    try parseSharedPartsWithCommandOptions(scratch, args, &parsed, .list, struct {
        fn parse(arg: []const u8, parser: *CommandParts, out: *List) !bool {
            _ = parser;
            if (std.mem.eql(u8, arg, "--refresh")) {
                out.refresh = true;
            } else if (std.mem.eql(u8, arg, "--exited")) {
                out.exited = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                out.all = true;
            } else if (std.mem.eql(u8, arg, "--jsonl")) {
                out.jsonl = true;
            } else {
                return false;
            }
            return true;
        }
    }.parse, &list);

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.startsWith(u8, args[i], "--client=")) {
            const value = args[i]["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            if (list.client_target != null) return error.MultipleTargets;
            list.client_target = value;
            list.client_option_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--client")) {
            if (list.client_target != null) return error.MultipleTargets;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "-")) return error.MissingClientListTarget;
            list.client_target = args[i];
            list.client_option_arg = "--client";
        }
        i += 1;
    }

    list.common = parsed.common;
    if (parsed.host) |host| {
        if (parsed.positionals.items.len != 0) return error.TooManyMuxArguments;
        list.target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
        if (std.mem.eql(u8, host, ".")) list.include_cached_routes = false;
    } else if (parsed.positionals.items.len == 0) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        list.target = .local;
    } else if (parsed.positionals.items.len == 1) {
        const target = parsed.positionals.items[0];
        list.target = if (std.mem.eql(u8, target, ".")) .local else .{ .host = target };
        if (std.mem.eql(u8, target, ".")) list.include_cached_routes = false;
    } else {
        return error.TooManyMuxArguments;
    }
    if (list.all and (list.exited or list.client_target != null)) return error.UnsupportedMuxOption;
    if (list.client_target != null and (list.refresh or list.exited or !list.include_cached_routes)) return error.UnsupportedMuxOption;
    list.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    return list;
}

fn parseKill(scratch: *Scratch, args: []const []const u8) !Kill {
    var parsed = CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var kill = Kill{};
    var request_jsons: std.ArrayList([]const u8) = .empty;
    errdefer request_jsons.deinit(scratch.allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            if (kill.current or kill.ids.len > 0 or request_jsons.items.len > 0) return error.MultipleTargets;
            kill.all = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--current")) {
            if (kill.all or kill.ids.len > 0 or request_jsons.items.len > 0) return error.MultipleTargets;
            kill.current = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            kill.jsonl = true;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--request=")) {
            if (kill.all or kill.current or kill.ids.len > 0) return error.MultipleTargets;
            try request_jsons.append(scratch.allocator, arg["--request=".len..]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--request")) {
            if (kill.all or kill.current or kill.ids.len > 0) return error.MultipleTargets;
            i += 1;
            if (i >= args.len) return error.MissingKillTarget;
            try request_jsons.append(scratch.allocator, args[i]);
            i += 1;
        } else if (try parseSharedOption(scratch, args, &i, &parsed, .kill)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else {
            const start = i;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "-")) i += 1;
            kill.ids = args[start..i];
        }
    }

    if (request_jsons.items.len > 0) {
        kill.owned_request_jsons = try request_jsons.toOwnedSlice(scratch.allocator);
        kill.request_jsons = kill.owned_request_jsons.?;
    } else {
        request_jsons.deinit(scratch.allocator);
    }
    kill.common = parsed.common;

    if (parsed.host) |host| {
        kill.command_target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
        if (!kill.all and !kill.current and kill.request_jsons.len == 0 and kill.ids.len == 0) return error.MissingKillTarget;
        kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
        return kill;
    }
    if (kill.all or kill.current or kill.request_jsons.len > 0) {
        if (kill.ids.len > 1) return error.TooManyMuxArguments;
        if (kill.ids.len == 1) {
            const target = kill.ids[0];
            kill.command_target = if (std.mem.eql(u8, target, ".")) .local else .{ .host = target };
            kill.ids = &.{};
        } else {
            if (parsed.ssh_options.items.len > 0) return error.MissingHost;
            kill.command_target = .local;
        }
        kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
        return kill;
    }
    if (kill.ids.len == 0) return error.MissingKillTarget;
    if (std.mem.eql(u8, kill.ids[0], ".")) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        if (kill.ids.len == 1) return error.MissingKillTarget;
        kill.command_target = .local;
        kill.ids = kill.ids[1..];
    } else if (kill.ids.len == 1) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        kill.command_target = .{ .route_ref_or_local_id = kill.ids[0] };
    } else if (looksLikeKillTarget(kill.ids[0])) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        kill.command_target = .local;
    } else {
        kill.command_target = .{ .host = kill.ids[0] };
        kill.ids = kill.ids[1..];
    }
    kill.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    return kill;
}

fn parseDebug(scratch: *Scratch, args: []const []const u8) !Debug {
    if (args.len == 0 or std.mem.startsWith(u8, args[0], "--")) return error.MissingDebugAction;
    const action: DebugAction = if (std.mem.eql(u8, args[0], "sever-connection"))
        .sever_connection
    else if (std.mem.eql(u8, args[0], "unresponsive-connection"))
        .unresponsive_connection
    else
        return error.InvalidDebugAction;
    var debug = Debug{
        .action = action,
        .control = try parseClientControl(scratch, args[1..], false, action),
    };
    debug.seconds = debug.control.seconds;
    return debug;
}

fn parseClientControl(scratch: *Scratch, args: []const []const u8, repaint_defaults_to_all: bool, debug_action: ?DebugAction) !ClientControl {
    var parsed = CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var control = ClientControl{};
    var seconds: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            control.all = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            control.last_input = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (!repaint_defaults_to_all) return error.UnsupportedMuxOption;
            control.scrollback = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (debug_action != .unresponsive_connection) return error.UnsupportedMuxOption;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingDebugSeconds;
            _ = try parseDebugUnresponsiveSeconds(args[i]);
            seconds = args[i];
            i += 1;
        } else if (try parseSharedOption(scratch, args, &i, &parsed, .client_control)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else {
            try parsed.positionals.append(scratch.allocator, arg);
            i += 1;
        }
    }
    control.common = parsed.common;
    if (parsed.host) |host| {
        control.target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
    } else if (parsed.ssh_options.items.len > 0) {
        return error.MissingHost;
    }
    if (parsed.positionals.items.len > 0 and std.mem.eql(u8, parsed.positionals.items[0], ".")) {
        if (control.target != .local) return error.TooManyMuxArguments;
        _ = parsed.positionals.orderedRemove(0);
    }
    try applyClientControlPositionals(&control, parsed.positionals.items, repaint_defaults_to_all);
    control.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    control.seconds = seconds;
    return control;
}

const CommandKind = enum {
    new,
    attach,
    list,
    kill,
    client_control,
};

const CommandParts = struct {
    ssh_options: std.ArrayList([]const u8) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    host: ?[]const u8 = null,
    common: CommonSessionOptions = .{},

    fn deinit(self: *CommandParts, allocator: std.mem.Allocator) void {
        self.ssh_options.deinit(allocator);
        self.positionals.deinit(allocator);
    }
};

fn parseSharedParts(scratch: *Scratch, args: []const []const u8, parsed: *CommandParts, kind: CommandKind) !void {
    var i: usize = 0;
    while (i < args.len) {
        if (try parseSharedOption(scratch, args, &i, parsed, kind)) continue;
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnsupportedMuxOption;
        try parsed.positionals.append(scratch.allocator, args[i]);
        i += 1;
    }
}

fn parseSharedPartsWithCommandOptions(
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

fn parseSharedOption(scratch: *Scratch, args: []const []const u8, index: *usize, parsed: *CommandParts, kind: CommandKind) !bool {
    const arg = args[index.*];
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

fn parseCommonOption(args: []const []const u8, index: *usize, common: *CommonSessionOptions, kind: CommandKind) !bool {
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

fn applyClientControlPositionals(control: *ClientControl, positional: []const []const u8, repaint_defaults_to_all: bool) !void {
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

fn appendShellSplitWords(scratch: *Scratch, out: *std.ArrayList([]const u8), value: []const u8) !void {
    var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(scratch.allocator, value);
    defer it.deinit();
    while (it.next()) |word| {
        const owned = try scratch.allocator.dupe(u8, word);
        errdefer scratch.allocator.free(owned);
        try scratch.owned_ssh_words.append(scratch.allocator, owned);
        try out.append(scratch.allocator, owned);
    }
}

fn looksLikeKillTarget(value: []const u8) bool {
    return std.mem.startsWith(u8, value, session_registry.session_guid_prefix) or
        std.mem.startsWith(u8, value, session_registry.proxy_guid_prefix);
}

fn looksLikeClientGuid(value: []const u8) bool {
    return session_registry.isValidClientGuid(value) or std.mem.startsWith(u8, value, session_registry.client_guid_prefix);
}

fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}

test "parse rejects host-first mux invocations" {
    try std.testing.expectError(error.UnsupportedMuxCommand, parse(std.testing.allocator, &.{ "sesshmux", ".", "list" }));
    try std.testing.expectError(error.UnsupportedMuxCommand, parse(std.testing.allocator, &.{ "sesshmux", "example.com", "list" }));
}

test "parse rejects raw short ssh options in mux subcommands" {
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "new", "-n", "test-host" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "attach", "-n", "--host", "test-host", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "list", "-n" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "kill", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "detach", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "repaint", "-n", "s1" }));
    try std.testing.expectError(error.UnsupportedMuxOption, parse(std.testing.allocator, &.{ "sesshmux", "debug", "sever-connection", "-n", "s1" }));
}

test "parse new accepts explicit host option" {
    var invocation = try parse(std.testing.allocator, &.{ "sesshmux", "new", "--ssh-options", "-F cfg -p 2222", "--host", "test-host", "echo", "hi" });
    defer invocation.deinit(std.testing.allocator);

    switch (invocation.command) {
        .new => |new| {
            switch (new.target) {
                .host => |host| try std.testing.expectEqualStrings("test-host", host),
                else => return error.TestUnexpectedTarget,
            }
            try std.testing.expectEqual(@as(usize, 4), new.ssh_options.len);
            try std.testing.expectEqualStrings("-F", new.ssh_options[0]);
            try std.testing.expectEqualStrings("cfg", new.ssh_options[1]);
            try std.testing.expectEqualStrings("-p", new.ssh_options[2]);
            try std.testing.expectEqualStrings("2222", new.ssh_options[3]);
            try std.testing.expectEqual(@as(usize, 2), new.command_argv.len);
            try std.testing.expectEqualStrings("echo", new.command_argv[0]);
            try std.testing.expectEqualStrings("hi", new.command_argv[1]);
        },
        else => return error.TestUnexpectedCommand,
    }
}

test "parse attach keeps target inside attach command" {
    var invocation = try parse(std.testing.allocator, &.{ "sesshmux", "attach", "--host", ".", "s1" });
    defer invocation.deinit(std.testing.allocator);

    switch (invocation.command) {
        .attach => |attach| {
            try std.testing.expectEqual(AttachTarget.local, attach.target);
            try std.testing.expectEqualStrings("s1", attach.id.?);
        },
        else => return error.TestUnexpectedCommand,
    }
}

test "parse list dot is explicit local-only target" {
    var positional = try parse(std.testing.allocator, &.{ "sesshmux", "list", "." });
    defer positional.deinit(std.testing.allocator);
    switch (positional.command) {
        .list => |list| {
            try std.testing.expectEqual(ListTarget.local, list.target);
            try std.testing.expect(!list.include_cached_routes);
        },
        else => return error.TestUnexpectedCommand,
    }

    var host_option = try parse(std.testing.allocator, &.{ "sesshmux", "list", "--host", "." });
    defer host_option.deinit(std.testing.allocator);
    switch (host_option.command) {
        .list => |list| {
            try std.testing.expectEqual(ListTarget.local, list.target);
            try std.testing.expect(!list.include_cached_routes);
        },
        else => return error.TestUnexpectedCommand,
    }
}

test "parse kill accepts command-local dot after subcommand" {
    var invocation = try parse(std.testing.allocator, &.{ "sesshmux", "kill", ".", "s1", "p1" });
    defer invocation.deinit(std.testing.allocator);

    switch (invocation.command) {
        .kill => |kill| {
            try std.testing.expectEqual(KillCommandTarget.local, kill.command_target);
            try std.testing.expectEqual(@as(usize, 2), kill.ids.len);
            try std.testing.expectEqualStrings("s1", kill.ids[0]);
            try std.testing.expectEqualStrings("p1", kill.ids[1]);
        },
        else => return error.TestUnexpectedCommand,
    }
}
