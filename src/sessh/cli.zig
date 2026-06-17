const std = @import("std");

const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const ssh_opts = @import("../transport/ssh_options.zig");

const SshTtyRequest = ssh_opts.SshTtyRequest;

pub const Invocation = struct {
    host: []const u8,
    ssh_options: []const []const u8 = &.{},
    command_args: []const []const u8 = &.{},
    tty_request: SshTtyRequest = .none,
    proxy_required: bool = false,
    common: CommonSessionOptions = .{},
};

pub const CommonSessionOptions = struct {
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    bootstrap: bool = true,
    bootstrap_set: bool = false,
    terminal_emulator: bool = true,
    terminal_emulator_set: bool = false,
    filter_level: config.FilterLevel = config.default_filter_level,
    filter_level_set: bool = false,
    isolation_mode: config.IsolationMode = config.default_isolation_mode,
    isolation_mode_set: bool = false,
    diagnostics_file: ?[]const u8 = null,
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

    fn ownSshOptions(self: *Scratch, options: *std.ArrayList([]const u8)) ![]const []const u8 {
        if (options.items.len == 0) return &.{};
        std.debug.assert(self.owned_ssh_options == null);
        const owned = try options.toOwnedSlice(self.allocator);
        self.owned_ssh_options = owned;
        return owned;
    }
};

pub fn parse(scratch: *Scratch, args: []const []const u8) !Invocation {
    if (args.len < 2) return error.MissingHost;

    var common = CommonSessionOptions{};
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(scratch.allocator);
    var tty_request: SshTtyRequest = .none;
    var proxy_required = false;

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0) return error.MissingHost;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            return finish(scratch, &ssh_options, common, args[i], args[i + 1 ..], tty_request, proxy_required);
        }

        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            return finish(scratch, &ssh_options, common, arg, args[i + 1 ..], tty_request, proxy_required);
        }

        if (isSesshLongOption(arg)) {
            try parseSesshOptionBeforeHost(args, &i, &common);
            continue;
        }

        const ssh_option_start = i;
        try ssh_opts.consumeSshOption(args, &i, &tty_request, &proxy_required);
        try ssh_options.appendSlice(scratch.allocator, args[ssh_option_start..i]);
    }

    return error.MissingHost;
}

fn finish(
    scratch: *Scratch,
    ssh_options: *std.ArrayList([]const u8),
    common: CommonSessionOptions,
    host: []const u8,
    command_args: []const []const u8,
    tty_request: SshTtyRequest,
    proxy_required: bool,
) !Invocation {
    return .{
        .host = host,
        .ssh_options = try scratch.ownSshOptions(ssh_options),
        .command_args = command_args,
        .tty_request = tty_request,
        .proxy_required = proxy_required,
        .common = common,
    };
}

fn parseSesshOptionBeforeHost(args: []const []const u8, index: *usize, common: *CommonSessionOptions) !void {
    const arg = args[index.*];
    if (isConfigOnlyDirectSesshOption(arg)) return error.UnsupportedSesshOption;

    if (std.mem.eql(u8, arg, "--log-level")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingClientLogLevel;
        common.client_log_level = try client_log.parseLevel(args[index.*]);
        common.client_log_level_set = true;
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--terminal-emulator")) {
        common.terminal_emulator = true;
        common.terminal_emulator_set = true;
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--no-terminal-emulator")) {
        common.terminal_emulator = false;
        common.terminal_emulator_set = true;
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--filter-level")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingFilterLevel;
        common.filter_level = try config.parseFilterLevel(args[index.*]);
        common.filter_level_set = true;
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--isolation-mode")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingIsolationMode;
        common.isolation_mode = try config.parseIsolationMode(args[index.*]);
        common.isolation_mode_set = true;
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--diagnostics-file")) {
        index.* += 1;
        if (index.* >= args.len or args[index.*].len == 0 or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDiagnosticsFile;
        common.diagnostics_file = args[index.*];
        index.* += 1;
    } else if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
        index.* += 1;
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
        common.capture_tty_transcript = args[index.*];
        index.* += 1;
    } else {
        return error.MissingHost;
    }
}

fn isSesshLongOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap") or
        std.mem.eql(u8, arg, "--terminal-emulator") or
        std.mem.eql(u8, arg, "--no-terminal-emulator") or
        std.mem.eql(u8, arg, "--filter-level") or
        std.mem.eql(u8, arg, "--isolation-mode") or
        std.mem.eql(u8, arg, "--diagnostics-file") or
        std.mem.eql(u8, arg, "--ssh-options") or
        std.mem.eql(u8, arg, "--capture-tty-transcript");
}

fn isConfigOnlyDirectSesshOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap") or
        std.mem.eql(u8, arg, "--ssh-options");
}

fn expectArgvEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

test "parse passes through ssh options before host" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "-F",
        "ssh_config",
        "-p2222",
        "-o",
        "BatchMode=yes",
        "-vvC",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try expectArgvEqual(&.{ "-F", "ssh_config", "-p2222", "-o", "BatchMode=yes", "-vvC" }, parsed.ssh_options);
}

test "parse accepts public sessh options before ssh options and host" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "--log-level",
        "debug",
        "-F",
        "ssh_config",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(client_log.Level.debug, parsed.common.client_log_level);
    try expectArgvEqual(&.{ "-F", "ssh_config" }, parsed.ssh_options);
}

test "parse accepts interleaved ssh and sessh options before host" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "-t",
        "--no-terminal-emulator",
        "-p",
        "2222",
        "--log-level",
        "debug",
        "example.com",
        "exit",
        "3",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(client_log.Level.debug, parsed.common.client_log_level);
    try std.testing.expect(!parsed.common.terminal_emulator);
    try std.testing.expect(parsed.common.terminal_emulator_set);
    try std.testing.expectEqual(SshTtyRequest.requested, parsed.tty_request);
    try expectArgvEqual(&.{ "-t", "-p", "2222" }, parsed.ssh_options);
    try expectArgvEqual(&.{ "exit", "3" }, parsed.command_args);
}

test "parse treats every direct post-host token as remote command" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "example.com",
        "rsync",
        "--version",
        "--no-terminal-emulator",
        "--remote-name",
        "work",
        "-t",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expect(!parsed.common.terminal_emulator_set);
    try expectArgvEqual(&.{ "rsync", "--version", "--no-terminal-emulator", "--remote-name", "work", "-t" }, parsed.command_args);
}

test "parse rejects config-only sessh options on direct ssh transport" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    try std.testing.expectError(error.UnsupportedSesshOption, parse(&scratch, &.{
        "sessh",
        "--scrollback-limit",
        "100",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshOption, parse(&scratch, &.{
        "sessh",
        "--bootstrap",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshOption, parse(&scratch, &.{
        "sessh",
        "--no-bootstrap",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshOption, parse(&scratch, &.{
        "sessh",
        "--ssh-options",
        "-F cfg",
        "example.com",
    }));
}

test "parse rejects protocol-breaking ssh options" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    try std.testing.expectError(error.UnsafeSshOption, parse(&scratch, &.{
        "sessh",
        "-G",
        "example.com",
    }));
    try std.testing.expectError(error.UnsafeSshOption, parse(&scratch, &.{
        "sessh",
        "-Q",
        "cipher",
        "example.com",
    }));
}

test "parse uses ssh tty request to preserve shell-evaluated command args" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "-t",
        "example.com",
        "echo",
        "$SESSH_TEST_HOST",
    });
    try expectArgvEqual(&.{"-t"}, parsed.ssh_options);
    try expectArgvEqual(&.{ "echo", "$SESSH_TEST_HOST" }, parsed.command_args);
    try std.testing.expectEqual(SshTtyRequest.requested, parsed.tty_request);
}

test "parse permits explicit safe config overrides" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "-oRequestTTY=no",
        "-o",
        "SessionType=default",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try expectArgvEqual(&.{ "-oRequestTTY=no", "-o", "SessionType=default" }, parsed.ssh_options);
}

test "parse treats post-host words as remote command" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "example.com",
        "attach",
        "s12",
        "--no-bootstrap",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expect(parsed.common.bootstrap);
    try std.testing.expect(!parsed.common.bootstrap_set);
    try expectArgvEqual(&.{ "attach", "s12", "--no-bootstrap" }, parsed.command_args);
}

test "parse preserves lower filter levels" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "--filter-level",
        "unhygienic",
        "-L",
        "8080:localhost:80",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, parsed.common.filter_level);
    try std.testing.expect(parsed.common.filter_level_set);
    try std.testing.expect(parsed.proxy_required);
}

test "parse preserves isolation mode" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "--isolation-mode",
        "full",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(config.IsolationMode.full, parsed.common.isolation_mode);
    try std.testing.expect(parsed.common.isolation_mode_set);
}

test "parse preserves diagnostics file" {
    var scratch = Scratch{ .allocator = std.testing.allocator };
    defer scratch.deinit();

    const parsed = try parse(&scratch, &.{
        "sessh",
        "--diagnostics-file",
        "/tmp/sessh-diagnostics.log",
        "example.com",
    });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("/tmp/sessh-diagnostics.log", parsed.common.diagnostics_file.?);
}
