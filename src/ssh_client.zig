const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const client = @import("client.zig");
const client_log = @import("client_log.zig");
const config = @import("config.zig");
const io = @import("io.zig");
const process_exit = @import("process_exit.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");
const tty_transcript = @import("tty_transcript.zig");

const bootstrapper_script = @embedFile("bootstrapper.sh");
const max_artifact_bytes = 64 * 1024 * 1024;
const max_artifact_manifest_bytes = 16 * 1024;
const artifact_manifest_filename = "artifacts.manifest";
const default_ipqos_option_prefix = "-oIPQoS=";
const ssh_config_query_max_output_bytes = 256 * 1024;
const client_list_target_help = "incoming, outgoing, session, or a guid/alias";

const ArtifactSet = struct {
    allocator: std.mem.Allocator,
    artifact_set_id: []u8,
    entries: []ArtifactEntry,

    fn deinit(self: *ArtifactSet) void {
        self.allocator.free(self.artifact_set_id);
        for (self.entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    fn sendExec(
        self: *const ArtifactSet,
        fd: c.fd_t,
        broker_args: []const []const u8,
        reconnect_ui: ?*client.ReconnectUi,
        poll_reconnect_input: bool,
    ) !void {
        try writeAllMaybeCancellable(fd, "EXEC ", reconnect_ui, poll_reconnect_input);
        try writeAllMaybeCancellable(fd, self.artifact_set_id, reconnect_ui, poll_reconnect_input);
        for (self.entries) |entry| {
            try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
            try writeAllMaybeCancellable(fd, &entry.hash_hex, reconnect_ui, poll_reconnect_input);
        }
        try writeAllMaybeCancellable(fd, " --", reconnect_ui, poll_reconnect_input);
        for (broker_args) |arg| {
            if (!isPlainShellArg(arg)) return error.UnsafeBrokerArgument;
            try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
            try writeAllMaybeCancellable(fd, arg, reconnect_ui, poll_reconnect_input);
        }
        try writeAllMaybeCancellable(fd, "\n", reconnect_ui, poll_reconnect_input);
    }

    fn find(self: *const ArtifactSet, platform: Platform) ?*const ArtifactEntry {
        for (self.entries) |*entry| {
            if (platformsEqual(entry.platform(), platform)) return entry;
        }
        return null;
    }
};

const ArtifactEntry = struct {
    id: []u8,
    os: []u8,
    arch: []u8,
    path: []u8,
    hash_hex: [64]u8,

    fn deinit(self: *ArtifactEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.os);
        allocator.free(self.arch);
        allocator.free(self.path);
        self.* = undefined;
    }

    fn platform(self: *const ArtifactEntry) Platform {
        return .{ .os = self.os, .arch = self.arch };
    }
};

const Platform = struct {
    os: []const u8,
    arch: []const u8,
};

const PackagedArtifactTarget = struct {
    os: []const u8,
    arch: []const u8,
    filename: []const u8,
};

const packaged_artifact_targets = [_]PackagedArtifactTarget{
    .{ .os = "macos", .arch = "aarch64", .filename = "sesshmux-macos-aarch64" },
    .{ .os = "macos", .arch = "x86_64", .filename = "sesshmux-macos-x86_64" },
    .{ .os = "linux", .arch = "arm32", .filename = "sesshmux-linux-arm32" },
    .{ .os = "linux", .arch = "aarch64", .filename = "sesshmux-linux-aarch64" },
    .{ .os = "linux", .arch = "x86_64", .filename = "sesshmux-linux-x86_64" },
    .{ .os = "linux", .arch = "x86", .filename = "sesshmux-linux-x86" },
    .{ .os = "linux", .arch = "riscv64", .filename = "sesshmux-linux-riscv64" },
};

const SshAction = enum {
    new,
    attach,
    list,
    kill,
    kill_all,
    detach_client,
    repaint_client,
    debug_client,
};

const ParsedSshArgs = struct {
    options: []const []const u8,
    host: []const u8,
    action: SshAction = .new,
    attach_id: ?[]const u8 = null,
    attach_session_dir: []const u8 = "",
    kill_id: ?[]const u8 = null,
    list_refresh: bool = false,
    list_jsonl: bool = false,
    list_exited: bool = false,
    list_client_target: ?[]const u8 = null,
    list_client_option_arg: ?[]const u8 = null,
    client_session_ref: ?[]const u8 = null,
    client_target: ClientTarget = .default,
    client_guid: ?[]const u8 = null,
    client_repaint_scrollback: bool = false,
    debug_client_action: ?DebugClientAction = null,
    debug_unresponsive_seconds: ?[]const u8 = null,
    command_argv: []const []const u8 = &.{},
    alias: ?[]const u8 = null,
    leader: terminal.Leader = .none,
    leader_set: bool = false,
    banner_args: client.DetachBannerArgs = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_row_count_set: bool = false,
    initial_scrollback_row_count: ?u32 = null,
    initial_scrollback_row_count_set: bool = false,
    client_log_level: client_log.Level = .warn,
    client_log_level_set: bool = false,
    bootstrap: bool = true,
    bootstrap_set: bool = false,
    force_compat: bool = false,
    default_ipqos_option: ?[]const u8 = null,
    capture_tty_transcript: ?[]const u8 = null,
};

const ClientTarget = enum {
    default,
    all,
    last_input,
    client_guid,
};

const DebugClientAction = enum {
    sever_connection,
    unresponsive_connection,
};

const CompatModeReason = enum {
    version_mismatch,
    forced,
};

const RuntimeConnection = struct {
    child: std.process.Child,
    stderr_pump: ?SshStderrPump = null,

    fn suppressSshStderr(self: *RuntimeConnection) void {
        if (self.stderr_pump) |*pump| pump.suppress();
    }

    fn closeStdin(self: *RuntimeConnection) void {
        closeChildStdin(&self.child);
    }

    fn wait(self: *RuntimeConnection) !std.process.Child.Term {
        const term = self.child.wait() catch |err| {
            self.joinStderrPump();
            return err;
        };
        self.joinStderrPump();
        return term;
    }

    fn terminate(self: *RuntimeConnection) void {
        self.closeStdin();
        _ = self.child.kill() catch {
            _ = self.child.wait() catch {};
        };
        self.joinStderrPump();
    }

    fn joinStderrPump(self: *RuntimeConnection) void {
        if (self.stderr_pump) |*pump| {
            pump.join();
            self.stderr_pump = null;
        }
    }
};

const ParallelReconnectResult = union(enum) {
    connected: RuntimeConnection,
    failed: anyerror,
};

const ParallelReconnectState = struct {
    mutex: std.Thread.Mutex = .{},
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    parsed_ssh_args: ParsedSshArgs,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    reconnect_ui: *client.ReconnectUi,
    session: client.RuntimeSession,
    result: ?ParallelReconnectResult = null,

    fn store(self: *ParallelReconnectState, result: ParallelReconnectResult) void {
        self.mutex.lock();
        self.result = result;
        self.mutex.unlock();
        self.done.store(true, .release);
    }

    fn take(self: *ParallelReconnectState) ?ParallelReconnectResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.result orelse return null;
        self.result = null;
        return result;
    }
};

const ReconnectRaceOutcome = union(enum) {
    recovered,
    reconnected: RuntimeConnection,
    session_ended,
    failed: anyerror,
    disconnected: anyerror,
    detach,
};

const reconnect_ready_switch_delay_ms: u64 = 10_000;

const SshStderrPump = struct {
    allocator: std.mem.Allocator,
    state: *State,
    thread: std.Thread,

    const State = struct {
        fd: c.fd_t,
        forward: std.atomic.Value(bool),
    };

    fn start(allocator: std.mem.Allocator, file: std.fs.File, forward: bool) !SshStderrPump {
        errdefer file.close();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .fd = file.handle,
            .forward = std.atomic.Value(bool).init(forward),
        };

        const thread = try std.Thread.spawn(.{}, stderrPumpMain, .{state});
        return .{ .allocator = allocator, .state = state, .thread = thread };
    }

    fn suppress(self: *SshStderrPump) void {
        self.state.forward.store(false, .release);
    }

    fn join(self: *SshStderrPump) void {
        self.thread.join();
        self.allocator.destroy(self.state);
    }
};

fn stderrPumpMain(state: *SshStderrPump.State) void {
    defer posix.close(state.fd);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(state.fd, &buf, buf.len);
        if (n <= 0) return;
        const bytes = buf[0..@intCast(n)];
        const forward = state.forward.load(.acquire);
        if (forward) {
            io.writeAll(2, bytes) catch {};
            continue;
        }
        client_log.appendSshStderr(bytes);
    }
}

const TranslatedMuxArgs = struct {
    allocator: std.mem.Allocator,
    args: std.ArrayList([]const u8) = .empty,
    owned_args: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TranslatedMuxArgs) void {
        for (self.owned_args.items) |arg| self.allocator.free(arg);
        self.owned_args.deinit(self.allocator);
        self.args.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *TranslatedMuxArgs, arg: []const u8) !void {
        try self.args.append(self.allocator, arg);
    }

    fn appendOwned(self: *TranslatedMuxArgs, arg: []const u8) !void {
        const owned = try self.allocator.dupe(u8, arg);
        errdefer self.allocator.free(owned);
        try self.owned_args.append(self.allocator, owned);
        try self.args.append(self.allocator, owned);
    }
};

pub fn runMux(allocator: std.mem.Allocator, args: []const []const u8, strict_command: bool) !void {
    if (args.len >= 2 and isMuxSubcommand(args[1])) {
        const invocation: MuxInvocation = if (strict_command) .sesshmux else .sessh;
        const parse_options = CliParseOptions{
            .allow_force_compat = invocation == .sesshmux and std.mem.eql(u8, args[1], "attach"),
            .allow_mux_command_words = true,
        };
        var translated = translateMuxArgsForInvocation(allocator, args, invocation) catch |err| {
            if (invocation == .sessh and shouldUsePlainSshFallbackForMuxNewArgError(args, err)) {
                try runPlainSshFallbackForMuxNewArgs(allocator, args, err);
            }
            try printSshArgError(err);
            return process_exit.request(64);
        };
        defer translated.deinit();
        return runWithParseOptions(allocator, translated.args.items, parse_options);
    }

    if (strict_command) {
        try printSshArgError(error.UnsupportedMuxCommand);
        return process_exit.request(64);
    }

    return run(allocator, args);
}

const MuxInvocation = enum {
    sessh,
    sesshmux,
};

fn isMuxSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "new") or
        std.mem.eql(u8, arg, "attach") or
        std.mem.eql(u8, arg, "list") or
        std.mem.eql(u8, arg, "kill") or
        std.mem.eql(u8, arg, "detach") or
        std.mem.eql(u8, arg, "repaint") or
        std.mem.eql(u8, arg, "debug");
}

fn translateMuxArgs(allocator: std.mem.Allocator, args: []const []const u8) !TranslatedMuxArgs {
    return translateMuxArgsForInvocation(allocator, args, .sesshmux);
}

fn translateMuxArgsForInvocation(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    invocation: MuxInvocation,
) !TranslatedMuxArgs {
    var translated = TranslatedMuxArgs{ .allocator = allocator };
    errdefer translated.deinit();
    try translated.append(args[0]);

    const command = args[1];
    if (std.mem.eql(u8, command, "new")) {
        try translateMuxNew(&translated, args[2..], invocation);
    } else if (std.mem.eql(u8, command, "attach")) {
        try translateMuxAttach(&translated, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        try translateMuxList(&translated, args[2..]);
    } else if (std.mem.eql(u8, command, "kill")) {
        try translateMuxKill(&translated, args[2..]);
    } else if (std.mem.eql(u8, command, "detach")) {
        try translateMuxClientControl(&translated, "detach", null, args[2..], false);
    } else if (std.mem.eql(u8, command, "repaint")) {
        try translateMuxClientControl(&translated, "repaint", null, args[2..], true);
    } else if (std.mem.eql(u8, command, "debug")) {
        if (args.len < 3) return error.MissingDebugAction;
        const debug_action = args[2];
        if (!std.mem.eql(u8, debug_action, "sever-connection") and
            !std.mem.eql(u8, debug_action, "unresponsive-connection")) return error.InvalidDebugAction;
        try translateMuxClientControl(&translated, "debug", debug_action, args[3..], false);
    } else {
        return error.UnsupportedMuxCommand;
    }

    return translated;
}

fn translateMuxNew(translated: *TranslatedMuxArgs, args: []const []const u8, invocation: MuxInvocation) !void {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(translated.allocator);
    var sessh_options: std.ArrayList([]const u8) = .empty;
    defer sessh_options.deinit(translated.allocator);

    var host: ?[]const u8 = null;
    var command_argv: []const []const u8 = &.{};
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
            if (invocation == .sessh) return error.UnsupportedSesshCliOption;
            if (host != null) return error.SesshOptionAfterHost;
            i += 1;
            if (i >= args.len) return error.MissingSshOptions;
            try appendShellSplitWords(translated, &ssh_options, args[i]);
            i += 1;
        } else if (isSesshLongOption(arg)) {
            if (host != null) return error.SesshOptionAfterHost;
            if (isConfigOrEnvOnlySesshOption(arg)) return error.UnsupportedSesshCliOption;
            try appendSesshOption(translated.allocator, args, &i, &sessh_options);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedMuxOption;
        } else if (host == null and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (invocation == .sesshmux) return error.UnsupportedMuxOption;
            const start = i;
            try consumeSshOption(args, &i);
            try ssh_options.appendSlice(translated.allocator, args[start..i]);
        } else if (host == null) {
            host = arg;
            i += 1;
        } else {
            return error.RemoteCommandUnsupported;
        }
    }

    const resolved_host = host orelse return error.MissingHost;
    try appendMany(translated, ssh_options.items);
    try translated.append(resolved_host);
    try appendMany(translated, sessh_options.items);
    if (command_argv.len > 0) {
        try translated.append("--");
        try appendMany(translated, command_argv);
    }
}

fn isConfigOrEnvOnlySesshOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--leader") or
        std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap");
}

fn translateMuxAttach(translated: *TranslatedMuxArgs, args: []const []const u8) !void {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(translated.allocator);
    var sessh_options: std.ArrayList([]const u8) = .empty;
    defer sessh_options.deinit(translated.allocator);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(translated.allocator);
    var host_option: ?[]const u8 = null;
    var force_compat = false;

    try parseMuxCommandOptions(translated, args, &ssh_options, &sessh_options, &positional, &host_option, false, &force_compat, null, null, null, null, null, null, null);

    if (host_option) |host| {
        if (positional.items.len > 1) return error.TooManyMuxArguments;
        try appendMany(translated, ssh_options.items);
        try translated.append(host);
        try translated.append("attach");
        if (positional.items.len == 1) try translated.append(positional.items[0]);
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 1) {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append("attach");
        try translated.append(positional.items[0]);
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 0) {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append(".");
        try translated.append("attach");
        try appendMany(translated, sessh_options.items);
    } else {
        return error.TooManyMuxArguments;
    }
}

fn translateMuxList(translated: *TranslatedMuxArgs, args: []const []const u8) !void {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(translated.allocator);
    var sessh_options: std.ArrayList([]const u8) = .empty;
    defer sessh_options.deinit(translated.allocator);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(translated.allocator);
    var host_option: ?[]const u8 = null;
    var refresh = false;
    var exited = false;

    var client_arg: ?[]const u8 = null;
    try parseMuxCommandOptions(translated, args, &ssh_options, &sessh_options, &positional, &host_option, false, null, &refresh, null, null, null, null, &exited, &client_arg);
    if (client_arg != null and (refresh or exited)) return error.UnsupportedMuxOption;
    if (host_option) |host| {
        if (positional.items.len != 0) return error.TooManyMuxArguments;
        try appendMany(translated, ssh_options.items);
        try translated.append(host);
        try translated.append("list");
        if (client_arg) |arg| try appendMuxClientListOption(translated, arg);
        if (refresh) try translated.append("--refresh");
        if (exited) try translated.append("--exited");
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 0) {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append(".");
        try translated.append("list");
        if (client_arg) |arg| try appendMuxClientListOption(translated, arg);
        if (refresh) try translated.append("--refresh");
        if (exited) try translated.append("--exited");
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 1 and std.mem.eql(u8, positional.items[0], ".")) {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append(".");
        try translated.append("list");
        try translated.append("--local-only");
        if (client_arg) |arg| try appendMuxClientListOption(translated, arg);
        if (refresh) try translated.append("--refresh");
        if (exited) try translated.append("--exited");
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 1) {
        try appendMany(translated, ssh_options.items);
        try translated.append(positional.items[0]);
        try translated.append("list");
        if (client_arg) |arg| try appendMuxClientListOption(translated, arg);
        if (refresh) try translated.append("--refresh");
        if (exited) try translated.append("--exited");
        try appendMany(translated, sessh_options.items);
    } else {
        return error.TooManyMuxArguments;
    }
}

fn appendMuxClientListOption(translated: *TranslatedMuxArgs, value_or_arg: []const u8) !void {
    if (std.mem.startsWith(u8, value_or_arg, "--client=")) {
        try translated.append(value_or_arg);
        return;
    }
    try translated.append("--client");
    try translated.append(value_or_arg);
}

fn translateMuxKill(translated: *TranslatedMuxArgs, args: []const []const u8) !void {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(translated.allocator);
    var sessh_options: std.ArrayList([]const u8) = .empty;
    defer sessh_options.deinit(translated.allocator);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(translated.allocator);
    var host_option: ?[]const u8 = null;
    var all = false;

    try parseMuxCommandOptions(translated, args, &ssh_options, &sessh_options, &positional, &host_option, false, null, null, &all, null, null, null, null, null);

    if (all) {
        if (host_option) |host| {
            if (positional.items.len != 0) return error.TooManyMuxArguments;
            try appendMany(translated, ssh_options.items);
            try translated.append(host);
            try translated.append("kill");
            try translated.append("--all");
            try appendMany(translated, sessh_options.items);
        } else if (positional.items.len == 0) {
            if (ssh_options.items.len > 0) return error.MissingHost;
            try translated.append(".");
            try translated.append("kill");
            try translated.append("--all");
            try appendMany(translated, sessh_options.items);
        } else if (positional.items.len == 1) {
            try appendMany(translated, ssh_options.items);
            try translated.append(positional.items[0]);
            try translated.append("kill");
            try translated.append("--all");
            try appendMany(translated, sessh_options.items);
        } else {
            return error.TooManyMuxArguments;
        }
        return;
    }

    if (host_option) |host| {
        if (positional.items.len != 1) return error.TooManyMuxArguments;
        try appendMany(translated, ssh_options.items);
        try translated.append(host);
        try translated.append("kill");
        try translated.append(positional.items[0]);
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 2) {
        try appendMany(translated, ssh_options.items);
        try translated.append(positional.items[0]);
        try translated.append("kill");
        try translated.append(positional.items[1]);
        try appendMany(translated, sessh_options.items);
    } else if (positional.items.len == 1) {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append("kill");
        try translated.append(positional.items[0]);
        try appendMany(translated, sessh_options.items);
    } else {
        return error.MissingKillId;
    }
}

fn translateMuxClientControl(
    translated: *TranslatedMuxArgs,
    command: []const u8,
    debug_action: ?[]const u8,
    args: []const []const u8,
    repaint_defaults_to_all: bool,
) !void {
    var ssh_options: std.ArrayList([]const u8) = .empty;
    defer ssh_options.deinit(translated.allocator);
    var sessh_options: std.ArrayList([]const u8) = .empty;
    defer sessh_options.deinit(translated.allocator);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(translated.allocator);
    var host_option: ?[]const u8 = null;
    var all = false;
    var last_input = false;
    var include_scrollback = false;
    var seconds_arg: ?[]const u8 = null;
    var client_guid: ?[]const u8 = null;

    try parseMuxCommandOptions(
        translated,
        args,
        &ssh_options,
        &sessh_options,
        &positional,
        &host_option,
        false,
        null,
        null,
        &all,
        &last_input,
        if (repaint_defaults_to_all) &include_scrollback else null,
        if (debug_action != null and std.mem.eql(u8, debug_action.?, "unresponsive-connection")) &seconds_arg else null,
        null,
        null,
    );

    var explicit_targets: u8 = 0;
    if (all) explicit_targets += 1;
    if (last_input) explicit_targets += 1;
    if (client_guid != null) explicit_targets += 1;
    if (explicit_targets > 1) return error.MultipleTargets;

    var session_ref: ?[]const u8 = null;
    if (positional.items.len == 1) {
        if (client_guid == null and !all and !last_input and looksLikeClientGuid(positional.items[0])) {
            client_guid = positional.items[0];
        } else {
            session_ref = positional.items[0];
        }
    } else if (positional.items.len == 2) {
        if (client_guid != null or all or last_input) return error.MultipleTargets;
        client_guid = positional.items[0];
        session_ref = positional.items[1];
    } else if (positional.items.len > 2) {
        return error.TooManyMuxArguments;
    }

    if (host_option) |host| {
        try appendMany(translated, ssh_options.items);
        try translated.append(host);
    } else {
        if (ssh_options.items.len > 0) return error.MissingHost;
        try translated.append(".");
    }
    try translated.append(command);
    if (debug_action) |action| try translated.append(action);
    if (all or (repaint_defaults_to_all and client_guid == null and !last_input)) {
        try translated.append("--all");
    } else if (last_input) {
        try translated.append("--last-input");
    } else if (client_guid) |guid| {
        try translated.append(guid);
    }
    if (include_scrollback) try translated.append("--scrollback");
    if (seconds_arg) |seconds| {
        try translated.append("--seconds");
        try translated.append(seconds);
    }
    if (session_ref) |ref| try translated.append(ref);
    try appendMany(translated, sessh_options.items);
}

fn looksLikeClientGuid(value: []const u8) bool {
    return session_registry.isValidClientGuid(value) or std.mem.startsWith(u8, value, session_registry.client_guid_prefix);
}

fn parseMuxCommandOptions(
    translated: *TranslatedMuxArgs,
    args: []const []const u8,
    ssh_options: *std.ArrayList([]const u8),
    sessh_options: *std.ArrayList([]const u8),
    positional: *std.ArrayList([]const u8),
    host_option: *?[]const u8,
    allow_command_argv: bool,
    force_compat_option: ?*bool,
    refresh_option: ?*bool,
    all_option: ?*bool,
    last_input_option: ?*bool,
    scrollback_option: ?*bool,
    seconds_option: ?*?[]const u8,
    exited_option: ?*bool,
    client_list_option: ?*?[]const u8,
) !void {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (!allow_command_argv) return error.UnsupportedMuxOption;
            return error.MissingCommandArgv;
        } else if (std.mem.eql(u8, arg, "--all")) {
            if (all_option) |all| {
                all.* = true;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            if (refresh_option) |refresh| {
                refresh.* = true;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--exited")) {
            if (exited_option) |exited| {
                exited.* = true;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            if (client_list_option) |client_list| {
                if (arg["--client=".len..].len == 0) return error.MissingClientListTarget;
                if (client_list.* != null) return error.MultipleTargets;
                client_list.* = arg;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--client")) {
            if (client_list_option) |client_list| {
                if (client_list.* != null) return error.MultipleTargets;
                i += 1;
                if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingClientListTarget;
                client_list.* = args[i];
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--force-compat")) {
            if (force_compat_option) |force_compat| {
                force_compat.* = true;
                try sessh_options.append(translated.allocator, arg);
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            if (last_input_option) |last_input| {
                last_input.* = true;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (scrollback_option) |scrollback| {
                scrollback.* = true;
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (seconds_option) |seconds| {
                i += 1;
                if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingDebugSeconds;
                _ = try parseDebugUnresponsiveSeconds(args[i]);
                seconds.* = args[i];
                i += 1;
            } else {
                return error.UnsupportedMuxOption;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingHost;
            host_option.* = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--ssh-options")) {
            i += 1;
            if (i >= args.len) return error.MissingSshOptions;
            try appendShellSplitWords(translated, ssh_options, args[i]);
            i += 1;
        } else if (isSesshLongOption(arg)) {
            if (isConfigOrEnvOnlySesshOption(arg)) return error.UnsupportedSesshCliOption;
            if (std.mem.eql(u8, arg, "--alias")) {
                return error.UnsupportedMuxOption;
            }
            try appendSesshOption(translated.allocator, args, &i, sessh_options);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedMuxOption;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-") and positional.items.len == 0) {
            const start = i;
            try consumeSshOption(args, &i);
            try ssh_options.appendSlice(translated.allocator, args[start..i]);
        } else {
            try positional.append(translated.allocator, arg);
            i += 1;
        }
    }
}

fn muxHostFromOptions(host_option: ?[]const u8, positional: []const []const u8, ids_after_host: usize) ![]const u8 {
    if (host_option) |host| {
        if (positional.len != ids_after_host) return error.TooManyMuxArguments;
        return host;
    }
    if (positional.len != ids_after_host + 1) {
        return if (positional.len < ids_after_host + 1) error.MissingHost else error.TooManyMuxArguments;
    }
    return positional[0];
}

fn appendSesshOption(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    out: *std.ArrayList([]const u8),
) !void {
    const arg = args[index.*];
    try out.append(allocator, arg);
    index.* += 1;
    if (sesshLongOptionRequiresValue(arg)) {
        if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return sesshLongOptionMissingValueError(arg);
        try out.append(allocator, args[index.*]);
        index.* += 1;
    }
}

fn appendMany(translated: *TranslatedMuxArgs, args: []const []const u8) !void {
    for (args) |arg| try translated.append(arg);
}

fn parseDebugUnresponsiveSeconds(value: []const u8) !u32 {
    const seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidDebugSeconds;
    if (seconds == 0) return error.InvalidDebugSeconds;
    return seconds;
}

fn appendShellSplitWords(
    translated: *TranslatedMuxArgs,
    out: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(translated.allocator, value);
    defer it.deinit();
    while (it.next()) |word| {
        const owned = try translated.allocator.dupe(u8, word);
        errdefer translated.allocator.free(owned);
        try translated.owned_args.append(translated.allocator, owned);
        try out.append(translated.allocator, owned);
    }
}

fn sesshLongOptionRequiresValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--leader") or
        std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--alias") or
        std.mem.eql(u8, arg, "--capture-tty-transcript");
}

fn sesshLongOptionMissingValueError(arg: []const u8) anyerror {
    if (std.mem.eql(u8, arg, "--leader")) return error.MissingLeader;
    if (std.mem.eql(u8, arg, "--scrollback-limit")) return error.MissingScrollbackRowCount;
    if (std.mem.eql(u8, arg, "--initial-scrollback")) return error.MissingInitialScrollback;
    if (std.mem.eql(u8, arg, "--log-level")) return error.MissingClientLogLevel;
    if (std.mem.eql(u8, arg, "--alias")) return error.MissingAlias;
    if (std.mem.eql(u8, arg, "--capture-tty-transcript")) return error.MissingTtyTranscriptPath;
    return error.UnsupportedMuxOption;
}

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper eventually execs `sesshmux :internal-broker:`, at which
/// point the normal framed runtime protocol can flow over ssh stdio. Installed
/// packages keep one binary per supported platform in libexec/sessh, named
/// `sesshmux-<os>-<arch>`. If that layout is unavailable, upload the current
/// binary for same-platform development tests.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return runWithParseOptions(allocator, args, .{});
}

const CliParseOptions = struct {
    allow_force_compat: bool = false,
    allow_mux_command_words: bool = false,
};

fn runWithParseOptions(allocator: std.mem.Allocator, args: []const []const u8, parse_options: CliParseOptions) !void {
    if (args.len >= 2 and std.mem.eql(u8, args[1], ".")) {
        return client.run(allocator, args);
    }

    var route_storage: ?session_registry.Route = null;
    defer if (route_storage) |*route| route.deinit(allocator);

    const route_ref_args = parseRouteRefArgs(allocator, args, &route_storage, parse_options) catch |err| switch (err) {
        error.SessionAlreadyExited => {
            try io.writeAll(2, "ERROR session already exited\n");
            return process_exit.request(1);
        },
        else => return err,
    };
    var parsed_ssh_args = if (route_ref_args) |parsed| parsed else parseSshArgs(args, parse_options) catch |err| {
        if (shouldUsePlainSshFallbackForArgError(args, err)) {
            try runPlainSshFallbackForUnsupportedArgs(allocator, args, err);
        }
        try printSshArgError(err);
        return process_exit.request(64);
    };
    if ((parsed_ssh_args.action == .attach or
        parsed_ssh_args.action == .list or
        parsed_ssh_args.action == .kill) and
        (parsed_ssh_args.host.len == 0 or std.mem.eql(u8, parsed_ssh_args.host, ".")))
    {
        return runLocalRouteCommand(allocator, args);
    }
    applyFileConfigToSsh(allocator, &parsed_ssh_args) catch |err| {
        try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(parsed_ssh_args.client_log_level);
    if (parsed_ssh_args.capture_tty_transcript != null and isRemoteManagementAction(parsed_ssh_args.action)) {
        try io.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }
    if (parsed_ssh_args.capture_tty_transcript != null and parsed_ssh_args.force_compat) {
        try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with --force-compat\n");
        return process_exit.request(64);
    }
    const resolved_ref_storage = try resolveLocalRefs(allocator, &parsed_ssh_args);
    defer if (resolved_ref_storage) |ref| allocator.free(ref);
    parsed_ssh_args.default_ipqos_option = try resolveDefaultIpQosOption(allocator, parsed_ssh_args.options, parsed_ssh_args.host);
    defer if (parsed_ssh_args.default_ipqos_option) |option| allocator.free(option);

    if (parsed_ssh_args.force_compat) {
        if (parsed_ssh_args.command_argv.len > 0) {
            try io.writeAll(2, "sessh: persistent command sessions are not supported with --force-compat\n");
            return process_exit.request(64);
        }
        try runRemoteCompat(allocator, parsed_ssh_args, .forced);
    }

    var artifacts_storage: ?ArtifactSet = if (parsed_ssh_args.bootstrap) try loadArtifactSet(allocator) else null;
    defer if (artifacts_storage) |*artifacts| artifacts.deinit();
    const artifacts = if (artifacts_storage) |*value| value else null;

    var broker_arg_buf: [12][]const u8 = undefined;
    const broker_args = brokerArgsForAction(parsed_ssh_args, &broker_arg_buf);
    const remote_command = if (parsed_ssh_args.bootstrap)
        try bootstrapCommand(allocator)
    else
        try directBrokerCommand(allocator, broker_args);
    defer allocator.free(remote_command);

    if (isRemoteManagementAction(parsed_ssh_args.action)) {
        const command_remote_command = if (parsed_ssh_args.bootstrap)
            remote_command
        else
            try directBrokerCommand(allocator, broker_args);
        defer if (!parsed_ssh_args.bootstrap) allocator.free(command_remote_command);
        var command_child = try startRuntimeConnection(
            allocator,
            parsed_ssh_args,
            artifacts,
            command_remote_command,
            broker_args,
            false,
            null,
            false,
        );
        const exit_status = runRemoteBrokerCommandAndForward(&command_child) catch |err| {
            command_child.closeStdin();
            _ = command_child.wait() catch {};
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: remote command failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        if (exit_status != 0) return process_exit.request(exit_status);
        if (parsed_ssh_args.action == .kill) {
            if (route_storage) |*route| {
                tombstoneLocalRouteForRemoteKill(allocator, route) catch |err| {
                    client_log.debug("event=local_kill_tombstone_failed session={s} error={t}", .{ route.guid, err });
                };
            }
        }
        return;
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (parsed_ssh_args.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    var new_guid: ?[]u8 = null;
    defer if (new_guid) |guid| allocator.free(guid);
    var new_alias: ?[]u8 = null;
    defer if (new_alias) |alias| allocator.free(alias);
    if (parsed_ssh_args.action == .new) {
        new_guid = try session_registry.generateGuid(allocator);
        if (parsed_ssh_args.alias) |alias| {
            new_alias = try allocator.dupe(u8, alias);
        } else {
            new_alias = try allocator.dupe(u8, "");
        }
    }

    var child = try startRuntimeConnection(
        allocator,
        parsed_ssh_args,
        artifacts,
        remote_command,
        broker_args,
        false,
        null,
        false,
    );

    var session = (switch (parsed_ssh_args.action) {
        .new => client.startNewSessionOnRuntime(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            parsed_ssh_args.scrollback_row_count,
            new_guid.?,
            new_alias.?,
            parsed_ssh_args.command_argv,
        ),
        .attach => client.startAttachSessionOnRuntime(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            parsed_ssh_args.attach_id orelse "",
            parsed_ssh_args.attach_session_dir,
            parsed_ssh_args.initial_scrollback_row_count,
        ),
        .list, .kill, .kill_all, .detach_client, .repaint_client, .debug_client => unreachable,
    }) catch |err| {
        if (err == error.VersionMismatch) {
            child.closeStdin();
            _ = child.wait() catch {};
            if (parsed_ssh_args.capture_tty_transcript != null) {
                try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with compat-fallback\n");
                return process_exit.request(1);
            }
            if (parsed_ssh_args.command_argv.len > 0) {
                try io.writeAll(2, "sessh: persistent command sessions require a compatible sesshmux agent\n");
                return process_exit.request(1);
            }
            try runRemoteCompat(allocator, parsed_ssh_args, .version_mismatch);
        }
        waitAfterRuntimeAttachFailure(&child, "start");
        if (process_exit.is(err)) return err;
        try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    child.suppressSshStderr();
    if (parsed_ssh_args.action == .new or parsed_ssh_args.action == .attach) {
        try client.ensureLocalRouteForRemoteSession(
            allocator,
            &session,
            parsed_ssh_args.attach_id orelse "",
            parsed_ssh_args.host,
            parsed_ssh_args.options,
        );
    }

    while (true) {
        const end = client.relayRuntimeSession(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            &session,
            parsed_ssh_args.leader,
            .{ .monitor_connection = true },
        ) catch |err| {
            waitAfterRuntimeAttachFailure(&child, "relay");
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        var race_existing_connection = false;
        switch (end) {
            .detach => {
                client_log.debug("event=detach host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                child.terminate();
                try finishDetachedSshSession(allocator, parsed_ssh_args, &session);
                return;
            },
            .session_ended => {
                client_log.debug("event=session_ended host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                try finishEndedRemoteSession(allocator, &child, &session);
                return;
            },
            .reconnect => {
                client_log.debug("event=disconnect reason=leader_sever host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                child.terminate();
            },
            .unresponsive => {
                client_log.debug("event=disconnect reason=unresponsive host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                race_existing_connection = true;
            },
            .transport_closed => {
                client_log.debug("event=disconnect reason=transport_closed host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                child.closeStdin();
                const term: ?std.process.Child.Term = child.wait() catch |err| blk: {
                    client_log.debug("event=transport_closed_wait_failed host={s} session={s} error={t}", .{ parsed_ssh_args.host, session.idSlice(), err });
                    break :blk null;
                };
                if (term) |value| {
                    client_log.debug("event=transport_closed_ssh_exit host={s} session={s} term={t}", .{ parsed_ssh_args.host, session.idSlice(), value });
                }
            },
        }

        const pending_input_at_disconnect = session.hasPendingInputAck();
        const pending_paste_like_input_at_disconnect = session.hasPendingPasteLikeInputAck();
        var reconnect_ui = try client.ReconnectUi.begin(session.viewport_offset);
        var reconnect_ui_active = true;
        defer if (reconnect_ui_active) reconnect_ui.deinit();

        if (race_existing_connection) {
            switch (try raceExistingConnectionWithReconnect(
                parsed_ssh_args,
                artifacts,
                remote_command,
                broker_args,
                &child,
                &session,
                &reconnect_ui,
                pending_input_at_disconnect,
                pending_paste_like_input_at_disconnect,
            )) {
                .recovered => {
                    session.noteUnresponsiveRecovery();
                    session.discardPendingInputAcks();
                    session.viewport_offset = try reconnect_ui.clearBanner();
                    client.repaintRuntimeSession(
                        child.child.stdout.?.handle,
                        child.child.stdin.?.handle,
                        &session,
                    ) catch |err| switch (err) {
                        error.SessionEnded => {
                            try finishEndedRemoteSession(allocator, &child, &session);
                            return;
                        },
                        else => return err,
                    };
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    continue;
                },
                .reconnected => |new_child| {
                    child.terminate();
                    child = new_child;
                    session.discardPendingInputAcks();
                    session.viewport_offset = try reconnect_ui.clearBanner();
                    client.finishReconnectRepaint(child.child.stdout.?.handle, &session) catch |err| switch (err) {
                        error.SessionEnded => {
                            try finishEndedRemoteSession(allocator, &child, &session);
                            return;
                        },
                        else => return err,
                    };
                    client_log.debug("event=reconnect_success host={s} session={s} attempt=0", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                    });
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    continue;
                },
                .session_ended => {
                    try finishEndedRemoteSession(allocator, &child, &session);
                    return;
                },
                .detach => {
                    child.terminate();
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args, &session);
                    return;
                },
                .failed => |err| {
                    client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt=0 error={t}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        err,
                    });
                    client_log.userDiagnosticInfo("reconnect failed: parallel: {t}", .{err});
                    child.terminate();
                },
                .disconnected => |err| {
                    client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt=0 error={t}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        err,
                    });
                    client_log.userDiagnosticInfo("reconnect failed: parallel: {t}", .{err});
                },
            }
        }

        var reconnect_attempt: usize = 0;
        while (true) {
            const delay_ms = reconnectDelayMs(reconnect_attempt);
            client_log.debug("event=reconnect_wait host={s} session={s} attempt={} delay_ms={}", .{
                parsed_ssh_args.host,
                session.idSlice(),
                reconnect_attempt,
                delay_ms,
            });
            switch (try reconnect_ui.waitForReconnect(delay_ms)) {
                .detach => {
                    client_log.debug("event=reconnect_detach host={s} session={s} attempt={}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args, &session);
                    return;
                },
                .reconnect_now, .wait_elapsed => {
                    client_log.debug("event=reconnect_attempt host={s} session={s} attempt={}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                },
            }

            child = startRuntimeConnection(
                allocator,
                parsed_ssh_args,
                artifacts,
                remote_command,
                broker_args,
                true,
                &reconnect_ui,
                true,
            ) catch |err| switch (err) {
                error.ExitRequested => return err,
                error.ReconnectDetached => {
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args, &session);
                    return;
                },
                error.OutOfMemory => return err,
                else => {
                    client_log.debug("event=reconnect_failed stage=transport host={s} session={s} attempt={} error={t}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                        err,
                    });
                    client_log.userDiagnosticInfo("reconnect failed: transport: {t}", .{err});
                    reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                    continue;
                },
            };

            session.viewport_offset = reconnect_ui.currentViewportOffset();
            client.reconnectSessionOnRuntimeCancellable(
                child.child.stdout.?.handle,
                child.child.stdin.?.handle,
                &session,
                reconnect_ui.cancellationFlag(),
            ) catch |err| {
                child.closeStdin();
                _ = child.wait() catch {};
                switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        client_log.debug("event=reconnect_failed stage=attach host={s} session={s} attempt={} error={t}", .{
                            parsed_ssh_args.host,
                            session.idSlice(),
                            reconnect_attempt,
                            err,
                        });
                        client_log.userDiagnosticInfo("reconnect failed: attach: {t}", .{err});
                        reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                        continue;
                    },
                }
            };

            switch (try waitForReconnectSwitchIfNeeded(
                &reconnect_ui,
                pending_input_at_disconnect,
                pending_paste_like_input_at_disconnect,
                false,
            )) {
                .detach => {
                    child.terminate();
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args, &session);
                    return;
                },
                .reconnect_now, .wait_elapsed => {},
            }

            session.discardPendingInputAcks();
            session.viewport_offset = try reconnect_ui.clearBanner();
            client.finishReconnectRepaint(
                child.child.stdout.?.handle,
                &session,
            ) catch |err| {
                child.closeStdin();
                _ = child.wait() catch {};
                switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        client_log.debug("event=reconnect_failed stage=repaint host={s} session={s} attempt={} error={t}", .{
                            parsed_ssh_args.host,
                            session.idSlice(),
                            reconnect_attempt,
                            err,
                        });
                        client_log.userDiagnosticInfo("reconnect failed: repaint: {t}", .{err});
                        reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                        continue;
                    },
                }
            };

            client_log.debug("event=reconnect_success host={s} session={s} attempt={}", .{
                parsed_ssh_args.host,
                session.idSlice(),
                reconnect_attempt,
            });
            reconnect_ui.deinit();
            reconnect_ui_active = false;
            break;
        }
    }
}

fn waitAfterRuntimeAttachFailure(child: *RuntimeConnection, stage: []const u8) void {
    child.closeStdin();
    const term = child.wait() catch |err| {
        client_log.flush(2);
        io.stderrPrint("sessh: ssh runtime wait failed after attach {s} failure: {t}\n", .{ stage, err }) catch {};
        return;
    };
    client_log.flush(2);
    io.stderrPrint("sessh: ssh runtime ended after attach {s} failure: {t}\n", .{ stage, term }) catch {};
}

fn finishDetachedSshSession(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs, session: *client.RuntimeSession) !void {
    session.restoreRelayEndPresentation();
    client.removeClientRouteHintForRemoteSession(allocator, session);
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    client.writeDetachBannerForSessionRef(parsed_ssh_args.banner_args.slice(), session.idSlice());
}

fn finishEndedRemoteSession(
    allocator: std.mem.Allocator,
    child: *RuntimeConnection,
    session: *client.RuntimeSession,
) !void {
    session.restoreRelayEndPresentation();
    client.removeClientRouteHintForRemoteSession(allocator, session);
    client.tombstoneLocalRouteForRemoteSession(allocator, session) catch |err| {
        client_log.debug("event=local_tombstone_failed session={s} error={t}", .{ session.idSlice(), err });
    };
    child.closeStdin();
    _ = child.wait() catch {};
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
}

fn finishReconnectUiForDetach(reconnect_ui: *client.ReconnectUi, active: *bool) void {
    if (!active.*) return;
    _ = reconnect_ui.clearBanner() catch {};
    reconnect_ui.deinit();
    active.* = false;
}

fn runRemoteCompat(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs, reason: CompatModeReason) !noreturn {
    if (reason == .version_mismatch) {
        try io.writeAll(2, "sessh: existing remote sessh is incompatible; falling back to compat-mode\n");
    }

    const command_script = try remoteCompatCommandScript(allocator, parsed_ssh_args);
    defer allocator.free(command_script);
    const remote_command = try shCommand(allocator, command_script);
    defer allocator.free(remote_command);

    const batch_mode = reason == .version_mismatch;
    const extra_options: usize = if (batch_mode) 1 else 0;
    const default_options = defaultSshOptionsLen(parsed_ssh_args);
    const ssh_argv = try allocator.alloc([]const u8, parsed_ssh_args.options.len + extra_options + default_options + 4);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    var arg_index: usize = 1;
    if (batch_mode) {
        ssh_argv[arg_index] = "-oBatchMode=yes";
        arg_index += 1;
    }
    appendDefaultSshOptions(ssh_argv, &arg_index, parsed_ssh_args.default_ipqos_option);
    @memcpy(ssh_argv[arg_index .. arg_index + parsed_ssh_args.options.len], parsed_ssh_args.options);
    arg_index += parsed_ssh_args.options.len;
    ssh_argv[arg_index] = compatSshTtyOption(parsed_ssh_args, c.isatty(0) != 0, c.isatty(1) != 0);
    ssh_argv[arg_index + 1] = parsed_ssh_args.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| return process_exit.request(code),
        .Signal => |signal| {
            try io.stderrPrint("sessh: remote compat-fallback ended by signal {}\n", .{signal});
            return process_exit.request(255);
        },
        else => {
            try io.stderrPrint("sessh: remote compat-fallback ended unexpectedly: {t}\n", .{term});
            return process_exit.request(255);
        },
    }
}

fn compatSshTtyOption(parsed_ssh_args: ParsedSshArgs, stdin_is_tty: bool, stdout_is_tty: bool) []const u8 {
    if (parsed_ssh_args.action == .attach and stdin_is_tty and stdout_is_tty) {
        return "-t";
    }
    return "-T";
}

fn brokerArgsForAction(parsed_ssh_args: ParsedSshArgs, buf: *[12][]const u8) []const []const u8 {
    var len: usize = 0;
    switch (parsed_ssh_args.action) {
        .new, .attach => {},
        .list => {
            buf[len] = "list";
            len += 1;
            if (parsed_ssh_args.host.len > 0) {
                buf[len] = "--host-display";
                len += 1;
                buf[len] = parsed_ssh_args.host;
                len += 1;
            }
            if (parsed_ssh_args.list_jsonl) {
                buf[len] = "--jsonl";
                len += 1;
            }
            if (parsed_ssh_args.list_client_target) |target| {
                if (parsed_ssh_args.list_client_option_arg) |client_arg| {
                    buf[len] = client_arg;
                    len += 1;
                    if (std.mem.eql(u8, client_arg, "--client")) {
                        buf[len] = target;
                        len += 1;
                    }
                } else {
                    buf[len] = "--client";
                    len += 1;
                    buf[len] = target;
                    len += 1;
                }
            }
            if (parsed_ssh_args.list_exited) {
                buf[len] = "--exited";
                len += 1;
            }
        },
        .kill => {
            buf[len] = "kill";
            len += 1;
            buf[len] = parsed_ssh_args.kill_id.?;
            len += 1;
        },
        .kill_all => {
            buf[len] = "kill";
            len += 1;
            buf[len] = "--all";
            len += 1;
        },
        .detach_client, .repaint_client, .debug_client => {
            buf[len] = switch (parsed_ssh_args.action) {
                .detach_client => "detach",
                .repaint_client => "repaint",
                .debug_client => "debug",
                else => unreachable,
            };
            len += 1;
            if (parsed_ssh_args.action == .debug_client) {
                buf[len] = switch (parsed_ssh_args.debug_client_action.?) {
                    .sever_connection => "sever-connection",
                    .unresponsive_connection => "unresponsive-connection",
                };
                len += 1;
            }
            switch (parsed_ssh_args.client_target) {
                .default => {},
                .all => {
                    buf[len] = "--all";
                    len += 1;
                },
                .last_input => {
                    buf[len] = "--last-input";
                    len += 1;
                },
                .client_guid => {
                    buf[len] = parsed_ssh_args.client_guid.?;
                    len += 1;
                },
            }
            if (parsed_ssh_args.client_repaint_scrollback) {
                buf[len] = "--scrollback";
                len += 1;
            }
            if (parsed_ssh_args.debug_unresponsive_seconds) |seconds| {
                buf[len] = "--seconds";
                len += 1;
                buf[len] = seconds;
                len += 1;
            }
            if (parsed_ssh_args.client_session_ref) |session_ref| {
                buf[len] = session_ref;
                len += 1;
            }
        },
    }
    return buf[0..len];
}

fn runRemoteBrokerCommandAndForward(connection: *RuntimeConnection) !u8 {
    connection.closeStdin();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(connection.child.stdout.?.handle, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try io.writeAll(1, buf[0..@intCast(n)]);
    }
    const term = try connection.wait();
    return switch (term) {
        .Exited => |code| @intCast(@min(code, std.math.maxInt(u8))),
        else => 1,
    };
}

fn showClientBootstrapStatus(visible: *bool, reconnect_ui: ?*client.ReconnectUi) !void {
    if (reconnect_ui != null or visible.*) return;
    try io.writeAll(2, "\rsessh: bootstrapping...");
    visible.* = true;
}

fn clearClientBootstrapStatus(visible: *bool) void {
    if (!visible.*) return;
    io.writeAll(2, "\r\x1b[K") catch {};
    visible.* = false;
}

fn tombstoneLocalRouteForRemoteKill(allocator: std.mem.Allocator, route: *const session_registry.Route) !void {
    try session_registry.writeTombstoneForRoute(allocator, route, .{
        .ended_at_unix_ms = nowUnixMs(),
        .end_reason = .killed_by_request,
        .exit_status = null,
    });
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn remoteCompatCommandScript(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs) ![]u8 {
    const local_args = try localCompatArgs(allocator, parsed_ssh_args);
    defer allocator.free(local_args);
    const compat_version = try shellQuote(allocator, config.version);
    defer allocator.free(compat_version);
    const action = compatActionName(parsed_ssh_args.action);
    const action_quoted = try shellQuote(allocator, action);
    defer allocator.free(action_quoted);
    const session_id = compatSessionId(parsed_ssh_args) orelse "";
    const session_id_quoted = try shellQuote(allocator, session_id);
    defer allocator.free(session_id_quoted);

    return std.fmt.allocPrint(allocator,
        \\set -u
        \\compat_action={s}
        \\compat_session_id={s}
        \\if [ -n "${{XDG_RUNTIME_DIR:-}}" ]; then
        \\  runtime_root=$XDG_RUNTIME_DIR
        \\else
        \\  runtime_root=/tmp/sessh-$(id -u)
        \\fi
        \\state_root=
        \\if [ -n "${{XDG_STATE_HOME:-}}" ]; then
        \\  state_root=$XDG_STATE_HOME/sessh
        \\elif [ -n "${{HOME:-}}" ]; then
        \\  state_root=$HOME/.local/state/sessh
        \\fi
        \\compact_session_id() {{
        \\  case "$1" in
        \\    s-*|S-*) printf '%s' "${{1#??}}" | tr -d '-' ;;
        \\    *) printf '%s' "$1" | tr -d '-' ;;
        \\  esac
        \\}}
        \\canonical_session_id() {{
        \\  compact=$(compact_session_id "$1")
        \\  if [ ${{#compact}} -eq 32 ]; then
        \\    case "$compact" in
        \\      *[!0123456789abcdefABCDEF]*) ;;
        \\      *) compact=$(printf '%s' "$compact" | tr 'ABCDEF' 'abcdef'); printf 's-%s-%s-%s-%s-%s\n' "$(printf '%s' "$compact" | cut -c1-8)" "$(printf '%s' "$compact" | cut -c9-12)" "$(printf '%s' "$compact" | cut -c13-16)" "$(printf '%s' "$compact" | cut -c17-20)" "$(printf '%s' "$compact" | cut -c21-32)"; return ;;
        \\    esac
        \\  fi
        \\  printf '%s\n' "$1"
        \\}}
        \\resolve_session_ref() {{
        \\  ref=$1
        \\  compact=$(compact_session_id "$ref")
        \\  if [ ${{#compact}} -eq 32 ]; then
        \\    case "$compact" in
        \\      *[!0123456789abcdefABCDEF]*) ;;
        \\      *) canonical_session_id "$compact"; return ;;
        \\    esac
        \\  fi
        \\  case "$ref" in
        \\    ""|/*|*/*|.|..) canonical_session_id "$compact"; return ;;
        \\  esac
        \\  if [ -n "$state_root" ]; then
        \\    alias_path=$state_root/alias/$ref
        \\    if [ -L "$alias_path" ]; then
        \\      target=$(readlink "$alias_path") || exit 1
        \\      canonical_session_id "$(basename "$target")"
        \\      return
        \\    fi
        \\  fi
        \\  alias_path=$runtime_root/alias/$ref
        \\  if [ -L "$alias_path" ]; then
        \\    target=$(readlink "$alias_path") || exit 1
        \\    canonical_session_id "$(basename "$target")"
        \\    return
        \\  fi
        \\  canonical_session_id "$compact"
        \\}}
        \\find_latest_session_id() {{
        \\  latest_dir=
        \\  latest_marker=$(ls -t "$runtime_root"/guid/*/detached 2>/dev/null | sed -n '1p')
        \\  if [ -n "$latest_marker" ]; then
        \\    latest_dir=$(dirname "$latest_marker")
        \\  fi
        \\  if [ -z "$latest_dir" ]; then
        \\    printf 'sessh: no detached session is available for compat-mode\n' >&2
        \\    exit 1
        \\  fi
        \\  basename "$latest_dir"
        \\}}
        \\exec_one_compat() {{
        \\  compat=$1
        \\  if [ ! -x "$compat" ]; then
        \\    printf 'sessh: session compat binary is unavailable\n' >&2
        \\    exit 1
        \\  fi
        \\  XDG_RUNTIME_DIR=$runtime_root exec "$compat" . --compat-version {s}{s}
        \\}}
        \\run_each_compat() {{
        \\  found=0
        \\  status=0
        \\  for compat in "$runtime_root"/guid/*/compat; do
        \\    [ -e "$compat" ] || continue
        \\    found=1
        \\    XDG_RUNTIME_DIR=$runtime_root "$compat" . --compat-version {s}{s}
        \\    code=$?
        \\    if [ "$code" -ne 0 ]; then
        \\      status=$code
        \\    fi
        \\  done
        \\  if [ "$found" -eq 0 ]; then
        \\    printf 'sessh: session compat binary is unavailable\n' >&2
        \\    exit 1
        \\  fi
        \\  exit "$status"
        \\}}
        \\case "$compat_action" in
        \\  attach)
        \\    if [ -z "$compat_session_id" ]; then
        \\      compat_session_id=$(find_latest_session_id)
        \\    fi
        \\    compat_session_id=$(resolve_session_ref "$compat_session_id")
        \\    exec_one_compat "$runtime_root/guid/$compat_session_id/compat"
        \\    ;;
        \\  kill)
        \\    compat_session_id=$(resolve_session_ref "$compat_session_id")
        \\    exec_one_compat "$runtime_root/guid/$compat_session_id/compat"
        \\    ;;
        \\  list|kill-all)
        \\    run_each_compat
        \\    ;;
        \\  *)
        \\    printf 'sessh: compat-mode requires an existing session\n' >&2
        \\  exit 1
        \\    ;;
        \\esac
        \\
    , .{
        action_quoted,
        session_id_quoted,
        compat_version,
        local_args,
        compat_version,
        local_args,
    });
}

fn compatActionName(action: SshAction) []const u8 {
    return switch (action) {
        .new => "new",
        .attach => "attach",
        .list => "list",
        .kill => "kill",
        .kill_all => "kill-all",
        .detach_client, .repaint_client, .debug_client => "client-command",
    };
}

fn compatSessionId(parsed_ssh_args: ParsedSshArgs) ?[]const u8 {
    return switch (parsed_ssh_args.action) {
        .attach => parsed_ssh_args.attach_id,
        .kill => parsed_ssh_args.kill_id,
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => null,
    };
}

fn localCompatArgs(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    switch (parsed_ssh_args.action) {
        .new => {},
        .attach => {
            try appendCompatArg(allocator, &out, "attach");
            if (parsed_ssh_args.attach_id) |id| try appendCompatArg(allocator, &out, id);
        },
        .list => try appendCompatArg(allocator, &out, "list"),
        .kill => {
            try appendCompatArg(allocator, &out, "kill");
            try appendCompatArg(allocator, &out, parsed_ssh_args.kill_id.?);
        },
        .kill_all => {
            try appendCompatArg(allocator, &out, "kill");
            try appendCompatArg(allocator, &out, "--all");
        },
        .detach_client, .repaint_client, .debug_client => return error.UnsupportedCompatCommand,
    }

    var leader_buf: [8]u8 = undefined;
    const leader = resolvedLeaderArg(parsed_ssh_args.leader, &leader_buf);
    try appendCompatArg(allocator, &out, "--leader");
    try appendCompatArg(allocator, &out, leader);

    var scrollback_buf: [16]u8 = undefined;
    const scrollback_count = try std.fmt.bufPrint(&scrollback_buf, "{}", .{parsed_ssh_args.scrollback_row_count});
    try appendCompatArg(allocator, &out, "--scrollback-limit");
    try appendCompatArg(allocator, &out, scrollback_count);

    var initial_scrollback_buf: [16]u8 = undefined;
    const initial_scrollback_count = if (parsed_ssh_args.initial_scrollback_row_count) |value|
        try std.fmt.bufPrint(&initial_scrollback_buf, "{}", .{value})
    else
        "-1";
    try appendCompatArg(allocator, &out, "--initial-scrollback");
    try appendCompatArg(allocator, &out, initial_scrollback_count);

    try appendCompatArg(allocator, &out, "--log-level");
    try appendCompatArg(allocator, &out, client_log.levelName(parsed_ssh_args.client_log_level));

    return out.toOwnedSlice(allocator);
}

fn appendCompatArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    const quoted = try shellQuote(allocator, arg);
    defer allocator.free(quoted);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, quoted);
}

fn resolvedLeaderArg(leader: terminal.Leader, buf: []u8) []const u8 {
    return switch (leader) {
        .none => "None",
        .ctrl => |byte| std.fmt.bufPrint(buf, "CTRL-{c}", .{byte}) catch unreachable,
    };
}

fn applyFileConfigToSsh(allocator: std.mem.Allocator, parsed: *ParsedSshArgs) !void {
    const file_config = try client.loadFileConfig(allocator);
    if (!parsed.leader_set) {
        if (file_config.leader) |leader| parsed.leader = leader;
    }
    if (!parsed.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| parsed.scrollback_row_count = count;
    }
    if (!parsed.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        parsed.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (!parsed.bootstrap_set) {
        if (file_config.bootstrap) |enabled| parsed.bootstrap = enabled;
    }
    if (!parsed.client_log_level_set) {
        if (file_config.client_log_level) |level| {
            parsed.client_log_level = level;
        } else {
            parsed.client_log_level = inferredClientLogLevel(parsed.options);
        }
    }
}

fn inferredClientLogLevel(ssh_options: []const []const u8) client_log.Level {
    const verbosity = sshVerbosity(ssh_options);
    if (verbosity >= 3) return .verbose;
    if (verbosity == 2) return .debug;
    if (verbosity == 1) return .info;
    return .warn;
}

fn sshVerbosity(ssh_options: []const []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < ssh_options.len) {
        const arg = ssh_options[i];
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-") or std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            continue;
        }

        var pos: usize = 1;
        while (pos < arg.len) : (pos += 1) {
            const option = arg[pos];
            if (option == 'v') total += 1;
            if (option == 'o' or sshOptionRequiresValue(option) or isUnsafeSshOptionWithValue(option)) {
                if (pos + 1 < arg.len) {
                    i += 1;
                } else {
                    i += 2;
                }
                break;
            }
        } else {
            i += 1;
        }
    }
    return total;
}

fn resolveDefaultIpQosOption(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) !?[]u8 {
    const value = queryInteractiveIpQos(allocator, ssh_options, host) catch |err| {
        client_log.debug("event=ipqos_query_failed host={s} error={t}", .{ host, err });
        return null;
    };
    defer allocator.free(value);
    const option: ?[]u8 = try std.fmt.allocPrint(allocator, "{s}{s}", .{ default_ipqos_option_prefix, value });
    return option;
}

fn queryInteractiveIpQos(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) ![]u8 {
    const argv = try allocator.alloc([]const u8, ssh_options.len + 3);
    defer allocator.free(argv);
    argv[0] = "ssh";
    @memcpy(argv[1 .. 1 + ssh_options.len], ssh_options);
    argv[1 + ssh_options.len] = "-G";
    argv[2 + ssh_options.len] = host;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = ssh_config_query_max_output_bytes,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.SshConfigQueryFailed,
        else => return error.SshConfigQueryFailed,
    }
    return parseInteractiveIpQos(allocator, result.stdout);
}

fn parseInteractiveIpQos(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = fields.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(key, "ipqos")) continue;
        const interactive = fields.next() orelse return error.MissingIpQos;
        return allocator.dupe(u8, interactive);
    }
    return error.MissingIpQos;
}

fn raceExistingConnectionWithReconnect(
    parsed_ssh_args: ParsedSshArgs,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    old_child: *RuntimeConnection,
    session: *client.RuntimeSession,
    reconnect_ui: *client.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    var reconnect_attempt: usize = 0;
    while (true) {
        const outcome = try raceExistingConnectionWithReconnectAttempt(
            parsed_ssh_args,
            artifacts,
            remote_command,
            broker_args,
            old_child,
            session,
            reconnect_ui,
            pending_input_at_disconnect,
            pending_paste_like_input_at_disconnect,
        );
        switch (outcome) {
            .failed => |err| {
                client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt={} error={t}", .{
                    parsed_ssh_args.host,
                    session.idSlice(),
                    reconnect_attempt,
                    err,
                });
                client_log.userDiagnosticInfo("reconnect failed: parallel: {t}", .{err});
                const delay_ms = reconnectDelayMs(reconnect_attempt);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, reconnect_ui);
                client_log.debug("event=reconnect_wait_unresponsive host={s} session={s} attempt={} delay_ms={}", .{
                    parsed_ssh_args.host,
                    session.idSlice(),
                    reconnect_attempt,
                    delay_ms,
                });
                if (try waitForUnresponsiveReconnectRetry(
                    old_child,
                    session,
                    parsed_ssh_args.leader,
                    reconnect_ui,
                    delay_ms,
                )) |retry_outcome| return retry_outcome;
            },
            .disconnected => return outcome,
            else => return outcome,
        }
    }
}

fn waitForUnresponsiveReconnectRetry(
    old_child: *RuntimeConnection,
    session: *client.RuntimeSession,
    leader: terminal.Leader,
    reconnect_ui: *client.ReconnectUi,
    delay_ms: u64,
) !?ReconnectRaceOutcome {
    var timer = try std.time.Timer.start();
    while (true) {
        const elapsed_ms = @divTrunc(timer.read(), std.time.ns_per_ms);
        if (elapsed_ms >= delay_ms) return null;

        if (try client.pollRuntimeRecovery(old_child.child.stdout.?.handle, session, 0)) |recovery| {
            switch (recovery) {
                .recovered => return .recovered,
                .session_ended => return .session_ended,
                .detach => return .detach,
                .transport_closed => {
                    old_child.closeStdin();
                    _ = old_child.wait() catch {};
                    return .{ .disconnected = error.TransportClosed };
                },
            }
        }

        const remaining_ms = delay_ms - elapsed_ms;
        const poll_ms: i32 = @intCast(@min(remaining_ms, @as(u64, 50)));
        switch (try client.pollAndForwardReconnectInput(
            old_child.child.stdout.?.handle,
            old_child.child.stdin.?.handle,
            session,
            leader,
            reconnect_ui,
            poll_ms,
        )) {
            .wait_elapsed => {},
            .detach => return .detach,
            .reconnect_now => return null,
            .transport_closed => {
                old_child.closeStdin();
                _ = old_child.wait() catch {};
                return .{ .disconnected = error.TransportClosed };
            },
        }
    }
}

fn raceExistingConnectionWithReconnectAttempt(
    parsed_ssh_args: ParsedSshArgs,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    old_child: *RuntimeConnection,
    session: *client.RuntimeSession,
    reconnect_ui: *client.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    session.viewport_offset = reconnect_ui.currentViewportOffset();
    var state = ParallelReconnectState{
        .parsed_ssh_args = parsed_ssh_args,
        .artifacts = artifacts,
        .remote_command = remote_command,
        .broker_args = broker_args,
        .reconnect_ui = reconnect_ui,
        .session = session.*,
    };
    const thread_allocator = std.heap.smp_allocator;
    var thread = try std.Thread.spawn(.{}, parallelReconnectMain, .{ &state, thread_allocator });
    var joined = false;
    defer if (!joined) {
        reconnect_ui.cancel();
        thread.join();
        cleanupParallelReconnectResult(&state);
    };
    var ready_connection: ?RuntimeConnection = null;
    defer if (ready_connection) |*connection| connection.terminate();
    var ready_session = client.RuntimeSession{};

    var old_available = true;
    while (true) {
        if (ready_connection == null and state.done.load(.acquire)) {
            joined = true;
            thread.join();
            switch (state.take().?) {
                .connected => |connection| {
                    ready_connection = connection;
                    ready_session = session.*;
                    if (!old_available) {
                        return try attachReadyReconnectConnectionAfterTransportClosed(
                            &ready_connection,
                            &ready_session,
                            session,
                            reconnect_ui,
                            pending_input_at_disconnect,
                            pending_paste_like_input_at_disconnect,
                        );
                    }
                    const disposition = reconnect_ui.reconnectSwitchDisposition(
                        pending_input_at_disconnect,
                        pending_paste_like_input_at_disconnect,
                        true,
                    );
                    if (reconnect_ui.hasReconnectAcknowledgement() or disposition == .automatic) {
                        return try attachReadyReconnectConnection(
                            &ready_connection,
                            &ready_session,
                            session,
                            reconnect_ui,
                        );
                    }
                    try reconnect_ui.showReconnectReady(disposition);
                },
                .failed => |err| {
                    if (!old_available) return .{ .disconnected = err };
                    return .{ .failed = err };
                },
            }
        }

        if (old_available) {
            if (try client.pollRuntimeRecovery(old_child.child.stdout.?.handle, session, 0)) |recovery| {
                switch (recovery) {
                    .recovered => {
                        reconnect_ui.cancel();
                        if (!joined) {
                            joined = true;
                            thread.join();
                            cleanupParallelReconnectResult(&state);
                        }
                        return .recovered;
                    },
                    .session_ended => {
                        reconnect_ui.cancel();
                        if (!joined) {
                            joined = true;
                            thread.join();
                            cleanupParallelReconnectResult(&state);
                        }
                        return .session_ended;
                    },
                    .detach => {
                        reconnect_ui.cancel();
                        if (!joined) {
                            joined = true;
                            thread.join();
                            cleanupParallelReconnectResult(&state);
                        }
                        return .detach;
                    },
                    .transport_closed => {
                        old_child.closeStdin();
                        _ = old_child.wait() catch {};
                        old_available = false;
                        if (ready_connection != null) {
                            return try attachReadyReconnectConnectionAfterTransportClosed(
                                &ready_connection,
                                &ready_session,
                                session,
                                reconnect_ui,
                                pending_input_at_disconnect,
                                pending_paste_like_input_at_disconnect,
                            );
                        }
                        try reconnect_ui.showDisconnectedReconnectInProgress();
                    },
                }
            }
            if (old_available) {
                switch (try client.pollAndForwardReconnectInput(
                    old_child.child.stdout.?.handle,
                    old_child.child.stdin.?.handle,
                    session,
                    parsed_ssh_args.leader,
                    reconnect_ui,
                    50,
                )) {
                    .wait_elapsed => {},
                    .detach => {
                        reconnect_ui.cancel();
                        if (!joined) {
                            joined = true;
                            thread.join();
                            cleanupParallelReconnectResult(&state);
                        }
                        return .detach;
                    },
                    .reconnect_now => {
                        if (ready_connection != null) {
                            return try attachReadyReconnectConnection(
                                &ready_connection,
                                &ready_session,
                                session,
                                reconnect_ui,
                            );
                        }
                    },
                    .transport_closed => {
                        old_child.closeStdin();
                        _ = old_child.wait() catch {};
                        old_available = false;
                        if (ready_connection != null) {
                            return try attachReadyReconnectConnectionAfterTransportClosed(
                                &ready_connection,
                                &ready_session,
                                session,
                                reconnect_ui,
                                pending_input_at_disconnect,
                                pending_paste_like_input_at_disconnect,
                            );
                        }
                        try reconnect_ui.showDisconnectedReconnectInProgress();
                    },
                }
            }
        } else {
            switch (try reconnect_ui.pollDecision(50)) {
                .detach => {
                    reconnect_ui.cancel();
                    if (!joined) {
                        joined = true;
                        thread.join();
                        cleanupParallelReconnectResult(&state);
                    }
                    return .detach;
                },
                .reconnect_now => {
                    if (ready_connection) |connection| {
                        session.adoptReconnectState(&ready_session);
                        ready_connection = null;
                        return .{ .reconnected = connection };
                    }
                },
                .wait_elapsed => {},
            }
        }
    }
}

fn attachReadyReconnectConnectionAfterTransportClosed(
    ready_connection: *?RuntimeConnection,
    ready_session: *client.RuntimeSession,
    session: *client.RuntimeSession,
    reconnect_ui: *client.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    switch (try waitForReconnectSwitchIfNeeded(
        reconnect_ui,
        pending_input_at_disconnect,
        pending_paste_like_input_at_disconnect,
        false,
    )) {
        .detach => return .detach,
        .reconnect_now, .wait_elapsed => {},
    }
    return attachReadyReconnectConnection(ready_connection, ready_session, session, reconnect_ui);
}

fn attachReadyReconnectConnection(
    ready_connection: *?RuntimeConnection,
    ready_session: *client.RuntimeSession,
    session: *client.RuntimeSession,
    reconnect_ui: *client.ReconnectUi,
) !ReconnectRaceOutcome {
    var connection = ready_connection.* orelse return .{ .failed = error.ReconnectNotReady };
    ready_connection.* = null;

    client.attachPreparedReconnectRuntimeCancellable(
        connection.child.stdout.?.handle,
        connection.child.stdin.?.handle,
        ready_session,
        reconnect_ui.cancellationFlag(),
    ) catch |err| {
        connection.terminate();
        return .{ .failed = err };
    };
    session.adoptReconnectState(ready_session);
    return .{ .reconnected = connection };
}

fn parallelReconnectMain(state: *ParallelReconnectState, allocator: std.mem.Allocator) void {
    var connection = startRuntimeConnection(
        allocator,
        state.parsed_ssh_args,
        state.artifacts,
        state.remote_command,
        state.broker_args,
        true,
        state.reconnect_ui,
        false,
    ) catch |err| {
        state.store(.{ .failed = err });
        return;
    };

    // Stop after Hello while racing an unresponsive transport. SessionAttach
    // would replace the still-visible old attachment before the user presses
    // Ctrl-R to switch.
    client.prepareReconnectRuntimeCancellable(
        connection.child.stdout.?.handle,
        connection.child.stdin.?.handle,
        state.reconnect_ui.cancellationFlag(),
    ) catch |err| {
        if (err == error.ReconnectDetached) {
            connection.terminate();
        } else {
            connection.closeStdin();
            _ = connection.wait() catch {};
        }
        state.store(.{ .failed = err });
        return;
    };

    state.store(.{ .connected = connection });
}

fn cleanupParallelReconnectResult(state: *ParallelReconnectState) void {
    var result = state.take() orelse return;
    switch (result) {
        .connected => |*connection| connection.terminate(),
        .failed => {},
    }
}

fn waitForReconnectSwitchIfNeeded(
    reconnect_ui: *client.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
    unresponsive: bool,
) !client.ReconnectDecision {
    if (reconnect_ui.hasReconnectAcknowledgement()) return .reconnect_now;
    const disposition = reconnect_ui.reconnectSwitchDisposition(
        pending_input_at_disconnect,
        pending_paste_like_input_at_disconnect,
        unresponsive,
    );
    return switch (disposition) {
        .automatic => .wait_elapsed,
        .delayed => reconnect_ui.waitForReconnectSwitchOrTimeout(reconnect_ready_switch_delay_ms),
        .manual_disconnected, .manual_unresponsive => reconnect_ui.waitForReconnectSwitch(disposition),
    };
}

fn nextReconnectAttemptAfterFailure(attempt: usize, reconnect_ui: *client.ReconnectUi) usize {
    return if (reconnect_ui.consumeReconnectAcknowledgement()) 0 else attempt + 1;
}

fn reconnectDelayMs(attempt: usize) u64 {
    const delays = [_]u64{
        10_000,
        20_000,
        40_000,
        80_000,
        160_000,
        320_000,
        600_000,
    };
    return if (attempt < delays.len) delays[attempt] else delays[delays.len - 1];
}

fn defaultSshOptionsLen(parsed_ssh_args: ParsedSshArgs) usize {
    return if (parsed_ssh_args.default_ipqos_option == null) 0 else 1;
}

fn appendDefaultSshOptions(ssh_argv: [][]const u8, arg_index: *usize, default_ipqos_option: ?[]const u8) void {
    if (default_ipqos_option) |option| {
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
    }
}

fn startRuntimeConnection(
    allocator: std.mem.Allocator,
    parsed_ssh_args: ParsedSshArgs,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    batch_mode: bool,
    reconnect_ui: ?*client.ReconnectUi,
    poll_reconnect_input: bool,
) !RuntimeConnection {
    const reconnect_options: usize = if (batch_mode) 1 else 0;
    const default_options = defaultSshOptionsLen(parsed_ssh_args);
    const ssh_argv = try allocator.alloc([]const u8, parsed_ssh_args.options.len + reconnect_options + default_options + 4);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    var arg_index: usize = 1;
    if (batch_mode) {
        // Reconnect must fail cleanly instead of letting ssh prompt on stdio.
        // Put this before user/config options because OpenSSH uses the first
        // value it sees for many config keys.
        ssh_argv[arg_index] = "-oBatchMode=yes";
        arg_index += 1;
    }
    appendDefaultSshOptions(ssh_argv, &arg_index, parsed_ssh_args.default_ipqos_option);
    @memcpy(ssh_argv[arg_index .. arg_index + parsed_ssh_args.options.len], parsed_ssh_args.options);
    arg_index += parsed_ssh_args.options.len;
    ssh_argv[arg_index] = "-T";
    ssh_argv[arg_index + 1] = parsed_ssh_args.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    const forward_stderr = reconnect_ui == null;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var connection = RuntimeConnection{ .child = child };
    const stderr_file = connection.child.stderr.?;
    connection.child.stderr = null;
    connection.stderr_pump = SshStderrPump.start(allocator, stderr_file, forward_stderr) catch |err| {
        connection.terminate();
        return err;
    };

    const artifact_set = artifacts orelse return connection;

    artifact_set.sendExec(connection.child.stdin.?.handle, broker_args, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.terminate();
        return err;
    };

    var line = readBootstrapLine(allocator, connection.child.stdout.?.handle, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.closeStdin();
        if (err == error.ReconnectDetached) {
            connection.terminate();
            return err;
        }
        if (batch_mode) {
            _ = connection.wait() catch {};
            return err;
        }
        const term = connection.wait() catch null;
        try exitAfterSshBootstrapFailure(allocator, parsed_ssh_args, term, err);
    };
    defer allocator.free(line);

    if (std.mem.startsWith(u8, line, "MISSING ")) {
        const remote_platform = parseMissingPlatform(line) catch {
            connection.closeStdin();
            _ = connection.wait() catch {};
            try io.stderrPrint("sessh: invalid bootstrap response: {s}\n", .{line});
            return process_exit.request(1);
        };
        const artifact = artifact_set.find(remote_platform) orelse {
            connection.closeStdin();
            _ = connection.wait() catch {};
            if (artifactFilenameForPlatform(remote_platform) == null and canUsePlainSshFallback(parsed_ssh_args, batch_mode, reconnect_ui)) {
                try runPlainSshFallback(allocator, parsed_ssh_args, remote_platform);
            }
            if (artifactFilenameForPlatform(remote_platform) == null) {
                try exitUnsupportedPlatform(parsed_ssh_args, remote_platform);
            }
            try io.stderrPrint(
                "sessh: no packaged artifact is available for {s} {s}\n",
                .{ remote_platform.os, remote_platform.arch },
            );
            return process_exit.request(1);
        };

        var bootstrap_status_visible = false;
        defer clearClientBootstrapStatus(&bootstrap_status_visible);
        try showClientBootstrapStatus(&bootstrap_status_visible, reconnect_ui);

        sendUpload(allocator, connection.child.stdin.?.handle, artifact, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectDetached) {
                connection.terminate();
                return err;
            }
            _ = connection.wait() catch {};
            return err;
        };

        allocator.free(line);
        line = readBootstrapLine(allocator, connection.child.stdout.?.handle, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectDetached) {
                connection.terminate();
                return err;
            }
            if (batch_mode) {
                _ = connection.wait() catch {};
                return err;
            }
            const term = connection.wait() catch null;
            try exitAfterSshBootstrapFailure(allocator, parsed_ssh_args, term, err);
        };
    }

    if (std.mem.eql(u8, line, "OK")) {
        if (broker_args.len == 0) connection.suppressSshStderr();
        return connection;
    }

    if (std.mem.startsWith(u8, line, "ERR ")) {
        connection.closeStdin();
        _ = connection.wait() catch {};
        if (isUnsupportedPlatformBootstrapError(line) and canUsePlainSshFallback(parsed_ssh_args, batch_mode, reconnect_ui)) {
            try runPlainSshFallback(allocator, parsed_ssh_args, null);
        }
        if (isUnsupportedPlatformBootstrapError(line)) {
            try exitUnsupportedPlatform(parsed_ssh_args, null);
        }
        try io.stderrPrint("sessh: remote bootstrap failed: {s}\n", .{line});
        return process_exit.request(1);
    }

    connection.closeStdin();
    _ = connection.wait() catch {};
    try io.stderrPrint("sessh: unexpected bootstrap response: {s}\n", .{line});
    return process_exit.request(1);
}

fn isUnsupportedPlatformBootstrapError(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "ERR UNSUPPORTED_PLATFORM ");
}

fn canUsePlainSshFallback(
    parsed_ssh_args: ParsedSshArgs,
    batch_mode: bool,
    reconnect_ui: ?*client.ReconnectUi,
) bool {
    return parsed_ssh_args.action == .new and !batch_mode and reconnect_ui == null;
}

fn shouldUsePlainSshFallbackForArgError(args: []const []const u8, err: anyerror) bool {
    switch (err) {
        error.UnsupportedSshOption,
        error.UnsafeSshOption,
        error.UnsupportedSesshOption,
        error.UnsupportedSesshCliOption,
        error.RemoteCommandUnsupported,
        => {},
        else => return false,
    }

    return !hasSesshSpecificRequest(args);
}

fn shouldUsePlainSshFallbackForMuxNewArgError(args: []const []const u8, err: anyerror) bool {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "new")) return false;
    switch (err) {
        error.UnsupportedSshOption,
        error.UnsafeSshOption,
        error.UnsupportedMuxOption,
        error.UnsupportedSesshCliOption,
        error.RemoteCommandUnsupported,
        => {},
        else => return false,
    }

    return !muxNewHasSesshSpecificRequest(args[2..]);
}

fn muxNewHasSesshSpecificRequest(args: []const []const u8) bool {
    var host_seen = false;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "--ssh-options") or isSesshLongOption(arg)) {
            return true;
        }

        if (!host_seen and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (std.mem.startsWith(u8, arg, "--")) return false;
            var pos: usize = 1;
            var consumed_value = false;
            while (pos < arg.len) : (pos += 1) {
                if (sshOptionConsumesValueForHostScan(arg[pos])) {
                    i += if (pos + 1 < arg.len) 1 else 2;
                    consumed_value = true;
                    break;
                }
            }
            if (!consumed_value) i += 1;
            continue;
        }

        if (!host_seen) host_seen = true;
        i += 1;
    }
    return false;
}

fn hasSesshSpecificRequest(args: []const []const u8) bool {
    const host_index = plainSshHostIndex(args);
    const before_host_end = host_index orelse args.len;

    var i: usize = 1;
    while (i < before_host_end) : (i += 1) {
        if (isSesshLongOption(args[i])) return true;
    }

    const host = host_index orelse return false;
    i = host + 1;
    while (i < args.len) {
        const arg = args[i];
        if (!isSesshLongOption(arg)) return false;
        return true;
    }

    return false;
}

fn plainSshHostIndex(args: []const []const u8) ?usize {
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0) return i;

        if (std.mem.eql(u8, arg, "--")) {
            return if (i + 1 < args.len) i + 1 else null;
        }

        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) return i;

        if (std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            continue;
        }

        var pos: usize = 1;
        var consumed_value = false;
        while (pos < arg.len) : (pos += 1) {
            if (sshOptionConsumesValueForHostScan(arg[pos])) {
                if (pos + 1 < arg.len) {
                    i += 1;
                } else {
                    i += 2;
                }
                consumed_value = true;
                break;
            }
        }
        if (!consumed_value) i += 1;
    }
    return null;
}

fn sshOptionConsumesValueForHostScan(option: u8) bool {
    return option == 'o' or
        sshOptionRequiresValue(option) or
        isUnsafeSshOptionWithValue(option);
}

fn exitUnsupportedPlatform(parsed_ssh_args: ParsedSshArgs, platform: ?Platform) !noreturn {
    const action = unsupportedPlatformAction(parsed_ssh_args.action);
    if (platform) |remote_platform| {
        try io.stderrPrint(
            "sessh: remote platform {s} {s} is unsupported; cannot {s}\n",
            .{ remote_platform.os, remote_platform.arch, action },
        );
    } else {
        try io.stderrPrint("sessh: remote platform is unsupported; cannot {s}\n", .{action});
    }
    return process_exit.request(1);
}

fn unsupportedPlatformAction(action: SshAction) []const u8 {
    return switch (action) {
        .new => "start a persistent sessh session",
        .attach => "attach a sessh session",
        .list => "list sessh sessions",
        .kill => "kill a sessh session",
        .kill_all => "kill all sessh sessions",
        .detach_client => "detach a sessh client",
        .repaint_client => "repaint sessh clients",
        .debug_client => "debug sessh clients",
    };
}

fn runPlainSshFallbackForUnsupportedArgs(allocator: std.mem.Allocator, args: []const []const u8, err: anyerror) !noreturn {
    try io.stderrPrint(
        "sessh: fallback to plain-ssh due to {s}; persistence disabled\n",
        .{plainSshFallbackReason(err)},
    );
    try runPlainSshArgv(allocator, args[1..], "plain-ssh-fallback");
}

fn runPlainSshFallbackForMuxNewArgs(allocator: std.mem.Allocator, args: []const []const u8, err: anyerror) !noreturn {
    try io.stderrPrint(
        "sessh: fallback to plain-ssh due to {s}; persistence disabled\n",
        .{plainSshFallbackReason(err)},
    );
    try runPlainSshArgv(allocator, args[2..], "plain-ssh-fallback");
}

fn plainSshFallbackReason(err: anyerror) []const u8 {
    return switch (err) {
        error.RemoteCommandUnsupported => "non-interactive invocation",
        error.UnsafeSshOption => "ssh option incompatible with sessh transport",
        error.UnsupportedSshOption => "unsupported ssh option",
        error.UnsupportedMuxOption => "unsupported ssh option",
        error.UnsupportedSesshOption => "unsupported post-host argument",
        error.UnsupportedSesshCliOption => "unsupported sessh option",
        else => "unsupported invocation",
    };
}

fn runPlainSshFallback(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs, platform: ?Platform) !noreturn {
    if (platform) |remote_platform| {
        try io.stderrPrint(
            "sessh: remote platform {s} {s} is unsupported; using plain-ssh-fallback without persistence\n",
            .{ remote_platform.os, remote_platform.arch },
        );
    } else {
        try io.writeAll(2, "sessh: remote platform is unsupported; using plain-ssh-fallback without persistence\n");
    }

    const ssh_argv = try allocator.alloc([]const u8, parsed_ssh_args.options.len + 1);
    defer allocator.free(ssh_argv);
    @memcpy(ssh_argv[0..parsed_ssh_args.options.len], parsed_ssh_args.options);
    ssh_argv[ssh_argv.len - 1] = parsed_ssh_args.host;

    try runPlainSshArgv(allocator, ssh_argv, "plain-ssh-fallback");
}

fn runPlainSshArgv(allocator: std.mem.Allocator, ssh_args: []const []const u8, diagnostic_name: []const u8) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| return process_exit.request(code),
        .Signal => |signal| {
            try io.stderrPrint("sessh: {s} ended by signal {}\n", .{ diagnostic_name, signal });
            return process_exit.request(255);
        },
        else => {
            try io.stderrPrint("sessh: {s} ended unexpectedly: {t}\n", .{ diagnostic_name, term });
            return process_exit.request(255);
        },
    }
}

fn exitAfterSshBootstrapFailure(
    allocator: std.mem.Allocator,
    parsed_ssh_args: ParsedSshArgs,
    term: ?std.process.Child.Term,
    cause: anyerror,
) !noreturn {
    client_log.flush(2);
    if (term) |value| {
        switch (value) {
            .Exited => |code| {
                if (code != 0) {
                    try writeVisibleSshCommand(allocator, parsed_ssh_args);
                    try io.stderrPrint(" failed (exitcode={})\n", .{code});
                    return process_exit.request(code);
                }
                try io.stderrPrint("sessh: ssh bootstrap ended before response ({t})\n", .{cause});
                return process_exit.request(1);
            },
            .Signal => |signal| {
                try writeVisibleSshCommand(allocator, parsed_ssh_args);
                try io.stderrPrint(" failed (signal {})\n", .{signal});
                return process_exit.request(255);
            },
            else => {
                try writeVisibleSshCommand(allocator, parsed_ssh_args);
                try io.stderrPrint(" failed ({t})\n", .{value});
                return process_exit.request(1);
            },
        }
    }

    try io.stderrPrint("sessh: ssh bootstrap failed before response: {t}\n", .{cause});
    return process_exit.request(1);
}

fn writeVisibleSshCommand(allocator: std.mem.Allocator, parsed_ssh_args: ParsedSshArgs) !void {
    try io.writeAll(2, "sessh: `ssh");
    for (parsed_ssh_args.options) |arg| {
        try io.writeAll(2, " ");
        try writeDiagnosticShellArg(allocator, arg);
    }
    try io.writeAll(2, " ");
    try writeDiagnosticShellArg(allocator, parsed_ssh_args.host);
    try io.writeAll(2, "`");
}

fn writeDiagnosticShellArg(allocator: std.mem.Allocator, arg: []const u8) !void {
    if (isPlainShellArg(arg)) {
        try io.writeAll(2, arg);
        return;
    }
    const quoted = try shellQuote(allocator, arg);
    defer allocator.free(quoted);
    try io.writeAll(2, quoted);
}

fn isPlainShellArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', '=' => {},
            else => return false,
        }
    }
    return true;
}

/// ssh remote commands are evaluated by the remote account's login shell. Wrap
/// the embedded script so that shell only execs POSIX sh. This gives the
/// bootstrapper one shell contract to implement and test instead of inheriting
/// every possible remote login shell's behavior.
fn bootstrapCommand(allocator: std.mem.Allocator) ![]u8 {
    return shCommand(allocator, bootstrapper_script);
}

fn directBrokerCommand(allocator: std.mem.Allocator, broker_args: []const []const u8) ![]u8 {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    try script.appendSlice(allocator, "exec sesshmux :internal-broker:");
    for (broker_args) |arg| {
        const quoted = try shellQuote(allocator, arg);
        defer allocator.free(quoted);
        try script.append(allocator, ' ');
        try script.appendSlice(allocator, quoted);
    }
    try script.append(allocator, '\n');
    return shCommand(allocator, script.items);
}

fn shCommand(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    const quoted_script = try shellQuote(allocator, script);
    defer allocator.free(quoted_script);
    return std.fmt.allocPrint(allocator, "exec /bin/sh -c {s}", .{quoted_script});
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn parseRouteRefArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    route_storage: *?session_registry.Route,
    parse_options: CliParseOptions,
) !?ParsedSshArgs {
    if (args.len < 2) return null;
    var parsed = ParsedSshArgs{ .options = &.{}, .host = "" };
    var action: ?SshAction = null;
    var ref: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "attach")) {
            if (action != null) return error.ConflictingSesshAction;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingAttachId;
            action = .attach;
            ref = args[i];
            i += 1;
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "kill")) {
            if (action != null) return error.ConflictingSesshAction;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingKillId;
            action = .kill;
            ref = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--force-compat")) {
            if (!parse_options.allow_force_compat or action == null or action.? != .attach) return null;
            parsed.force_compat = true;
            try parsed.banner_args.append(arg);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--initial-scrollback")) {
            i += 1;
            if (i >= args.len) return error.MissingInitialScrollback;
            parsed.initial_scrollback_row_count = try client.parseInitialScrollbackRowCount(args[i]);
            parsed.initial_scrollback_row_count_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--leader")) {
            i += 1;
            if (i >= args.len) return error.MissingLeader;
            parsed.leader = try client.parseLeader(args[i]);
            parsed.leader_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return error.MissingClientLogLevel;
            parsed.client_log_level = try client_log.parseLevel(args[i]);
            parsed.client_log_level_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingTtyTranscriptPath;
            parsed.capture_tty_transcript = args[i];
            i += 1;
        } else {
            return null;
        }
    }
    const resolved_ref = ref orelse return null;
    const resolved_action = action.?;
    route_storage.* = session_registry.readRouteForRef(allocator, resolved_ref) catch |err| switch (err) {
        error.FileNotFound => {
            if (session_registry.tombstoneExistsForRef(allocator, resolved_ref)) return error.SessionAlreadyExited;
            return err;
        },
        else => return err,
    };
    const route = &route_storage.*.?;
    parsed.options = route.ssh_options;
    parsed.host = route.host;
    parsed.action = resolved_action;
    switch (resolved_action) {
        .attach => {
            parsed.attach_id = route.guid;
            parsed.attach_session_dir = route.session_dir;
        },
        .kill => parsed.kill_id = route.guid,
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => unreachable,
    }
    return parsed;
}

fn runLocalRouteCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const local_args = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(local_args);
    local_args[0] = args[0];
    local_args[1] = ".";
    @memcpy(local_args[2..], args[1..]);
    return client.run(allocator, local_args);
}

fn resolveLocalRefs(allocator: std.mem.Allocator, parsed: *ParsedSshArgs) !?[]u8 {
    switch (parsed.action) {
        .attach => {
            const ref = parsed.attach_id orelse return null;
            if (ref.len == 0) return null;
            if (parsed.host.len > 0) return null;
            const guid = try session_registry.resolveRefToGuid(allocator, ref);
            parsed.attach_id = guid;
            return guid;
        },
        .kill => {
            const ref = parsed.kill_id orelse return null;
            if (parsed.host.len > 0) return null;
            const guid = session_registry.resolveRefToGuid(allocator, ref) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            parsed.kill_id = guid;
            return guid;
        },
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => return null,
    }
}

fn parseSshArgs(args: []const []const u8, parse_options: CliParseOptions) !ParsedSshArgs {
    if (args.len < 2) return error.MissingHost;

    var i: usize = 1;
    var pre_host = ParsedSshArgs{ .options = &.{}, .host = "" };
    try parseSesshOptionsBeforeHost(args, &i, &pre_host, parse_options);
    const ssh_options_start = i;

    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0) return error.MissingHost;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            var parsed = pre_host;
            parsed.options = args[ssh_options_start .. i - 1];
            parsed.host = args[i];
            i += 1;
            try parseSesshOptionsAfterHost(args, &i, &parsed, parse_options);
            return parsed;
        }

        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            var parsed = pre_host;
            parsed.options = args[ssh_options_start..i];
            parsed.host = arg;
            i += 1;
            try parseSesshOptionsAfterHost(args, &i, &parsed, parse_options);
            return parsed;
        }

        if (isSesshLongOption(arg)) return error.MissingHost;
        try consumeSshOption(args, &i);
    }

    return error.MissingHost;
}

fn parseSesshOptionsBeforeHost(args: []const []const u8, index: *usize, parsed: *ParsedSshArgs, parse_options: CliParseOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (!isSesshLongOption(arg) and !(parse_options.allow_force_compat and std.mem.eql(u8, arg, "--force-compat"))) return;

        if (std.mem.eql(u8, arg, "--leader")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingLeader;
            parsed.leader = try client.parseLeader(args[index.*]);
            parsed.leader_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback-limit")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingScrollbackRowCount;
            parsed.scrollback_row_count = try client.parseScrollbackRowCount(args[index.*]);
            parsed.scrollback_row_count_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--initial-scrollback")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingInitialScrollback;
            parsed.initial_scrollback_row_count = try client.parseInitialScrollbackRowCount(args[index.*]);
            parsed.initial_scrollback_row_count_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingClientLogLevel;
            parsed.client_log_level = try client_log.parseLevel(args[index.*]);
            parsed.client_log_level_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--alias")) {
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingAlias;
            if (!session_registry.isValidCustomAlias(args[index.*])) return error.InvalidAlias;
            parsed.alias = args[index.*];
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--bootstrap")) {
            parsed.bootstrap = true;
            parsed.bootstrap_set = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--no-bootstrap")) {
            parsed.bootstrap = false;
            parsed.bootstrap_set = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--force-compat")) {
            if (!parse_options.allow_force_compat) return error.UnsupportedSshOption;
            parsed.force_compat = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
            parsed.capture_tty_transcript = args[index.*];
            index.* += 1;
        } else {
            return error.MissingHost;
        }
    }
}

fn parseSesshOptionsAfterHost(args: []const []const u8, index: *usize, parsed: *ParsedSshArgs, parse_options: CliParseOptions) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "attach")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.action = .attach;
            index.* += 1;
            if (index.* < args.len and !std.mem.startsWith(u8, args[index.*], "--")) {
                parsed.attach_id = args[index.*];
                index.* += 1;
            }
        } else if (std.mem.eql(u8, arg, "--leader")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingLeader;
            parsed.leader = try client.parseLeader(args[index.*]);
            parsed.leader_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback-limit")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingScrollbackRowCount;
            parsed.scrollback_row_count = try client.parseScrollbackRowCount(args[index.*]);
            parsed.scrollback_row_count_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--initial-scrollback")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingInitialScrollback;
            parsed.initial_scrollback_row_count = try client.parseInitialScrollbackRowCount(args[index.*]);
            parsed.initial_scrollback_row_count_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingClientLogLevel;
            parsed.client_log_level = try client_log.parseLevel(args[index.*]);
            parsed.client_log_level_set = true;
            try parsed.banner_args.append(arg);
            try parsed.banner_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--alias")) {
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingAlias;
            if (!session_registry.isValidCustomAlias(args[index.*])) return error.InvalidAlias;
            parsed.alias = args[index.*];
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--bootstrap")) {
            parsed.bootstrap = true;
            parsed.bootstrap_set = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--no-bootstrap")) {
            parsed.bootstrap = false;
            parsed.bootstrap_set = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--force-compat")) {
            if (!parse_options.allow_force_compat) return error.UnsupportedSesshOption;
            parsed.force_compat = true;
            try parsed.banner_args.append(arg);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--capture-tty-transcript")) {
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingTtyTranscriptPath;
            parsed.capture_tty_transcript = args[index.*];
            index.* += 1;
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "list")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.action = .list;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            if (parsed.action != .list) return error.UnsupportedSesshOption;
            parsed.list_refresh = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--exited")) {
            if (parsed.action != .list) return error.UnsupportedSesshOption;
            parsed.list_exited = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            if (parsed.action == .list) {
                parsed.list_jsonl = true;
            } else {
                return error.UnsupportedSesshOption;
            }
            index.* += 1;
        } else if (std.mem.startsWith(u8, arg, "--client=")) {
            if (parsed.action != .list) return error.UnsupportedSesshOption;
            const value = arg["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            if (parsed.list_client_target != null) return error.MultipleTargets;
            parsed.list_client_target = value;
            parsed.list_client_option_arg = arg;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--client")) {
            if (parsed.action != .list) return error.UnsupportedSesshOption;
            if (parsed.list_client_target != null) return error.MultipleTargets;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingClientListTarget;
            parsed.list_client_target = args[index.*];
            parsed.list_client_option_arg = arg;
            index.* += 1;
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "kill")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            index.* += 1;
            if (index.* < args.len and std.mem.eql(u8, args[index.*], "--all")) {
                parsed.action = .kill_all;
                index.* += 1;
            } else {
                if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingKillId;
                parsed.action = .kill;
                parsed.kill_id = args[index.*];
                index.* += 1;
            }
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "detach")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.action = .detach_client;
            index.* += 1;
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "repaint")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.action = .repaint_client;
            index.* += 1;
        } else if (parse_options.allow_mux_command_words and std.mem.eql(u8, arg, "debug")) {
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.action = .debug_client;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugAction;
            if (std.mem.eql(u8, args[index.*], "sever-connection")) {
                parsed.debug_client_action = .sever_connection;
            } else if (std.mem.eql(u8, args[index.*], "unresponsive-connection")) {
                parsed.debug_client_action = .unresponsive_connection;
            } else {
                return error.InvalidDebugAction;
            }
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (parsed.action != .debug_client or parsed.debug_client_action != .unresponsive_connection) return error.UnsupportedSesshOption;
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingDebugSeconds;
            _ = try parseDebugUnresponsiveSeconds(args[index.*]);
            parsed.debug_unresponsive_seconds = args[index.*];
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--all")) {
            try setParsedClientTarget(parsed, .all, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            try setParsedClientTarget(parsed, .last_input, null);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (parsed.action != .repaint_client) return error.UnsupportedSesshOption;
            parsed.client_repaint_scrollback = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingCommandArgv;
            if (parsed.action != .new) return error.ConflictingSesshAction;
            parsed.command_argv = args[index.*..];
            index.* = args.len;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedSesshOption;
        } else if (actionSupportsParsedClientTarget(parsed.action) and parsed.client_target == .default and std.mem.startsWith(u8, arg, session_registry.client_guid_prefix)) {
            try setParsedClientTarget(parsed, .client_guid, arg);
            index.* += 1;
        } else if (actionSupportsParsedClientSessionRef(parsed.action) and parsed.client_session_ref == null) {
            parsed.client_session_ref = arg;
            index.* += 1;
        } else {
            return error.RemoteCommandUnsupported;
        }
    }
}

fn isSesshLongOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--leader") or
        std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--alias") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap") or
        std.mem.eql(u8, arg, "--capture-tty-transcript") or
        std.mem.eql(u8, arg, "--refresh") or
        std.mem.eql(u8, arg, "--exited") or
        std.mem.eql(u8, arg, "--jsonl") or
        std.mem.eql(u8, arg, "--all") or
        std.mem.eql(u8, arg, "--last-input") or
        std.mem.eql(u8, arg, "--scrollback");
}

fn isRemoteManagementAction(action: SshAction) bool {
    return switch (action) {
        .list, .kill, .kill_all, .detach_client, .repaint_client, .debug_client => true,
        .new, .attach => false,
    };
}

fn actionSupportsParsedClientTarget(action: SshAction) bool {
    return action == .detach_client or action == .repaint_client or action == .debug_client;
}

fn actionSupportsParsedClientSessionRef(action: SshAction) bool {
    return actionSupportsParsedClientTarget(action);
}

fn setParsedClientTarget(parsed: *ParsedSshArgs, target: ClientTarget, client_guid: ?[]const u8) !void {
    if (!actionSupportsParsedClientTarget(parsed.action)) return error.UnsupportedSesshOption;
    if (parsed.client_target != .default) return error.MultipleTargets;
    parsed.client_target = target;
    parsed.client_guid = client_guid;
}

fn consumeSshOption(args: []const []const u8, index: *usize) !void {
    const arg = args[index.*];
    if (std.mem.startsWith(u8, arg, "--")) return error.UnsupportedSshOption;

    var pos: usize = 1;
    while (pos < arg.len) {
        const option = arg[pos];
        if (isUnsafeSshFlag(option) or isUnsafeSshOptionWithValue(option)) {
            return error.UnsafeSshOption;
        }

        if (option == 'o') {
            const value = try optionValue(args, index, pos);
            try validateSshConfigOption(value);
            return;
        }

        if (sshOptionRequiresValue(option)) {
            _ = try optionValue(args, index, pos);
            return;
        }

        if (!isSafeSshFlag(option)) return error.UnsupportedSshOption;
        pos += 1;
    }

    index.* += 1;
}

fn optionValue(args: []const []const u8, index: *usize, option_pos: usize) ![]const u8 {
    const arg = args[index.*];
    if (option_pos + 1 < arg.len) {
        index.* += 1;
        return arg[option_pos + 1 ..];
    }

    if (index.* + 1 >= args.len) return error.MissingSshOptionValue;
    const value = args[index.* + 1];
    index.* += 2;
    return value;
}

fn isSafeSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "46AaCgKkMqsTvXxYy", option) != null;
}

fn isUnsafeSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "fGNnstV", option) != null;
}

fn sshOptionRequiresValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmPpRSw", option) != null;
}

fn isUnsafeSshOptionWithValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "OQW", option) != null;
}

fn validateSshConfigOption(raw_option: []const u8) !void {
    const key = sshConfigKey(raw_option);
    if (std.ascii.eqlIgnoreCase(key, "RemoteCommand")) return error.UnsafeSshOption;

    if (std.ascii.eqlIgnoreCase(key, "RequestTTY")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "SessionType")) {
        if (!sshConfigValueIs(raw_option, key.len, "default")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "StdinNull")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "ForkAfterAuthentication")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
}

fn sshConfigKeyIs(raw_option: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(sshConfigKey(raw_option), expected);
}

fn sshConfigKey(raw_option: []const u8) []const u8 {
    var end: usize = 0;
    while (end < raw_option.len) : (end += 1) {
        switch (raw_option[end]) {
            '=', ' ', '\t' => break,
            else => {},
        }
    }
    return raw_option[0..end];
}

fn sshConfigValueIs(raw_option: []const u8, key_len: usize, expected: []const u8) bool {
    var value_start = key_len;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    if (value_start < raw_option.len and raw_option[value_start] == '=') value_start += 1;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    return std.ascii.eqlIgnoreCase(raw_option[value_start..], expected);
}

fn printSshArgError(err: anyerror) !void {
    switch (err) {
        error.MissingHost => try io.writeAll(2, "sessh: missing host\n"),
        error.MissingAttachId => try io.writeAll(2, "sesshmux: attach requires an id in this form\n"),
        error.MissingKillId => try io.writeAll(2, "sesshmux: kill requires an id\n"),
        error.MissingAlias => try io.writeAll(2, "sessh: --alias requires a value\n"),
        error.MissingLeader => try io.writeAll(2, "sessh: --leader requires a value\n"),
        error.MissingScrollbackRowCount => try io.writeAll(2, "sessh: --scrollback-limit requires a value\n"),
        error.MissingInitialScrollback => try io.writeAll(2, "sessh: --initial-scrollback requires a value\n"),
        error.MissingClientLogLevel => try io.writeAll(2, "sessh: --log-level requires a value\n"),
        error.MissingTtyTranscriptPath => try io.writeAll(2, "sessh: --capture-tty-transcript requires a path\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: ssh option is missing its value\n"),
        error.MissingSshOptions => try io.writeAll(2, "sesshmux: --ssh-options requires a value\n"),
        error.MissingClientListTarget => try io.writeAll(2, "sesshmux: --client requires a value: " ++ client_list_target_help ++ "\n"),
        error.MissingCommandArgv => try io.writeAll(2, "sesshmux: -- requires a command argv\n"),
        error.SesshOptionAfterHost => try io.writeAll(2, "sessh: sessh options must appear before HOST\n"),
        error.TooManyMuxArguments => try io.writeAll(2, "sesshmux: too many arguments\n"),
        error.UnsupportedMuxCommand => try io.writeAll(2, "sesshmux: unsupported command\n"),
        error.UnsupportedMuxOption => try io.writeAll(2, "sesshmux: unsupported option for this command\n"),
        error.ConflictingSesshAction => try io.writeAll(2, "sessh: conflicting sessh actions\n"),
        error.DangerousLeader => try io.writeAll(2, "sessh: dangerous leader\n"),
        error.InvalidLeader => try io.writeAll(2, "sessh: invalid leader\n"),
        error.InvalidScrollbackRowCount => try io.writeAll(2, "sessh: invalid scrollback row count\n"),
        error.InvalidInitialScrollback => try io.writeAll(2, "sessh: invalid initial scrollback\n"),
        error.InvalidClientLogLevel => try io.writeAll(2, "sessh: invalid log level\n"),
        error.InvalidAlias => try io.writeAll(2, "sessh: invalid alias\n"),
        error.InvalidBool => try io.writeAll(2, "sessh: expected true or false\n"),
        error.RemoteCommandUnsupported => try io.writeAll(2, "sessh: remote commands are not supported yet\n"),
        error.UnsafeSshOption => try io.writeAll(2, "sessh: ssh option is not safe for sessh transport\n"),
        error.UnsupportedSesshOption => try io.writeAll(2, "sessh: unsupported sessh option for ssh transport\n"),
        error.UnsupportedSesshCliOption => try io.writeAll(2, "sessh: unsupported sessh option\n"),
        error.UnsupportedSshOption => try io.writeAll(2, "sessh: unsupported ssh option for sessh transport\n"),
        else => try io.stderrPrint("sessh: invalid ssh arguments: {t}\n", .{err}),
    }
}

fn loadArtifactSet(allocator: std.mem.Allocator) !ArtifactSet {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    if (isDevelopmentExecutable(exe_path)) {
        return loadDevelopmentArtifactSet(allocator, exe_path);
    }

    return loadPackagedArtifactSet(allocator, exe_path) catch |err| switch (err) {
        error.NoPackagedArtifacts => loadDevelopmentArtifactSet(allocator, exe_path),
        else => err,
    };
}

fn isDevelopmentExecutable(exe_path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(exe_path), "sesshmux-dev");
}

fn loadPackagedArtifactSet(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactSet {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExePath;
    if (try loadPackagedArtifactSetFromDir(allocator, exe_dir)) |artifact_set| {
        return artifact_set;
    }

    const prefix_dir = std.fs.path.dirname(exe_dir) orelse return error.NoPackagedArtifacts;
    const libexec_dir = try std.fs.path.join(allocator, &.{ prefix_dir, "libexec", "sessh" });
    defer allocator.free(libexec_dir);
    if (try loadPackagedArtifactSetFromDir(allocator, libexec_dir)) |artifact_set| {
        return artifact_set;
    }

    return error.NoPackagedArtifacts;
}

fn loadPackagedArtifactSetFromDir(allocator: std.mem.Allocator, artifact_dir: []const u8) !?ArtifactSet {
    if (try loadPackagedArtifactManifest(allocator, artifact_dir)) |artifact_set| {
        return artifact_set;
    }

    var found_any = false;
    for (packaged_artifact_targets) |target| {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.filename });
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        file.close();
        found_any = true;
        break;
    }
    if (!found_any) return null;

    var entries = try allocator.alloc(ArtifactEntry, packaged_artifact_targets.len);
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(allocator);
    }

    for (packaged_artifact_targets, 0..) |target, i| {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.filename });
        errdefer allocator.free(path);

        entries[i] = try loadArtifactEntryForPlatform(allocator, path, .{
            .os = target.os,
            .arch = target.arch,
        });
        allocator.free(path);
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn loadPackagedArtifactManifest(allocator: std.mem.Allocator, artifact_dir: []const u8) !?ArtifactSet {
    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_dir, artifact_manifest_filename });
    defer allocator.free(manifest_path);

    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_manifest_bytes);
    defer allocator.free(bytes);

    return try parsePackagedArtifactManifest(allocator, artifact_dir, bytes);
}

fn parsePackagedArtifactManifest(
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    bytes: []const u8,
) !ArtifactSet {
    var entries = try allocator.alloc(ArtifactEntry, packaged_artifact_targets.len);
    errdefer allocator.free(entries);
    var seen = [_]bool{false} ** packaged_artifact_targets.len;
    errdefer {
        for (seen, 0..) |entry_seen, i| {
            if (entry_seen) entries[i].deinit(allocator);
        }
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ' ');
        const filename = fields.next() orelse return error.InvalidArtifactManifest;
        const hash_hex = fields.next() orelse return error.InvalidArtifactManifest;
        if (fields.next() != null) return error.InvalidArtifactManifest;

        const target_index = packagedArtifactTargetIndex(filename) orelse return error.InvalidArtifactManifest;
        if (seen[target_index]) return error.InvalidArtifactManifest;
        const target = packaged_artifact_targets[target_index];
        if (!isLowerSha256Hex(hash_hex)) return error.InvalidArtifactManifest;

        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.filename });
        entries[target_index] = try artifactEntryFromManifest(allocator, path, target, hash_hex);
        seen[target_index] = true;
    }

    for (seen) |entry_seen| {
        if (!entry_seen) return error.InvalidArtifactManifest;
    }

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn artifactEntryFromManifest(
    allocator: std.mem.Allocator,
    path: []u8,
    target: PackagedArtifactTarget,
    hash_text: []const u8,
) !ArtifactEntry {
    errdefer allocator.free(path);

    const id = try std.fmt.allocPrint(
        allocator,
        "sessh-{s}-{s}-{s}",
        .{ config.version, target.os, target.arch },
    );
    errdefer allocator.free(id);

    const os = try allocator.dupe(u8, target.os);
    errdefer allocator.free(os);
    const arch = try allocator.dupe(u8, target.arch);
    errdefer allocator.free(arch);

    var hash_hex: [64]u8 = undefined;
    @memcpy(hash_hex[0..], hash_text);

    return .{
        .id = id,
        .os = os,
        .arch = arch,
        .path = path,
        .hash_hex = hash_hex,
    };
}

fn loadDevelopmentArtifactSet(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactSet {
    const entry = try loadCurrentArtifactEntry(allocator, exe_path);
    errdefer {
        var mutable = entry;
        mutable.deinit(allocator);
    }

    const entries = try allocator.alloc(ArtifactEntry, 1);
    entries[0] = entry;
    errdefer allocator.free(entries);

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn loadCurrentArtifactEntry(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactEntry {
    return loadArtifactEntryForPlatform(allocator, exe_path, localPlatform());
}

fn loadArtifactEntryForPlatform(
    allocator: std.mem.Allocator,
    path: []const u8,
    platform: Platform,
) !ArtifactEntry {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_bytes);
    defer allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return .{
        .id = try std.fmt.allocPrint(
            allocator,
            "sessh-{s}-{s}-{s}",
            .{ config.version, platform.os, platform.arch },
        ),
        .os = try allocator.dupe(u8, platform.os),
        .arch = try allocator.dupe(u8, platform.arch),
        .path = try allocator.dupe(u8, path),
        .hash_hex = std.fmt.bytesToHex(digest, .lower),
    };
}

fn sendUpload(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    artifact: *const ArtifactEntry,
    reconnect_ui: ?*client.ReconnectUi,
    poll_reconnect_input: bool,
) !void {
    const file = try std.fs.openFileAbsolute(artifact.path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_bytes);
    defer allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hash = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hash, &artifact.hash_hex)) return error.ArtifactHashMismatch;

    const encoded = try allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(bytes.len),
    );
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    try writeAllMaybeCancellable(fd, "UPLOAD ", reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, artifact.id, reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, &artifact.hash_hex, reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, encoded, reconnect_ui, poll_reconnect_input);
    try writeAllMaybeCancellable(fd, "\n", reconnect_ui, poll_reconnect_input);
}

fn parseMissingPlatform(line: []const u8) !Platform {
    if (!std.mem.startsWith(u8, line, "MISSING ")) return error.InvalidMissingResponse;
    var fields = std.mem.splitScalar(u8, line["MISSING ".len..], ' ');
    const os = fields.next() orelse return error.InvalidMissingResponse;
    const arch = fields.next() orelse return error.InvalidMissingResponse;
    if (fields.next() != null or os.len == 0 or arch.len == 0) return error.InvalidMissingResponse;
    return .{ .os = os, .arch = arch };
}

fn localPlatform() Platform {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => "unsupported",
    };
    const arch = switch (builtin.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm32",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => "unsupported",
    };
    return .{ .os = os, .arch = arch };
}

fn platformsEqual(a: Platform, b: Platform) bool {
    return std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.arch, b.arch);
}

fn artifactFilenameForPlatform(platform: Platform) ?[]const u8 {
    for (packaged_artifact_targets) |target| {
        if (platformsEqual(.{ .os = target.os, .arch = target.arch }, platform)) {
            return target.filename;
        }
    }
    return null;
}

fn packagedArtifactTargetIndex(filename: []const u8) ?usize {
    for (packaged_artifact_targets, 0..) |target, i| {
        if (std.mem.eql(u8, target.filename, filename)) return i;
    }
    return null;
}

fn isLowerSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}

fn writeAllMaybeCancellable(
    fd: c.fd_t,
    bytes: []const u8,
    reconnect_ui: ?*client.ReconnectUi,
    poll_reconnect_input: bool,
) !void {
    if (reconnect_ui == null) {
        try io.writeAll(fd, bytes);
        return;
    }

    var written: usize = 0;
    while (written < bytes.len) {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 50);
        if (try reconnectShouldDetach(reconnect_ui.?, poll_reconnect_input)) return error.ReconnectDetached;
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.WriteFailed;
        if ((pollfds[0].revents & posix.POLL.OUT) == 0) continue;

        const chunk_len = @min(bytes.len - written, 4096);
        const n = c.write(fd, bytes[written..].ptr, chunk_len);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn readBootstrapLine(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reconnect_ui: ?*client.ReconnectUi,
    poll_reconnect_input: bool,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (line.items.len < 4096) {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, if (reconnect_ui == null) -1 else 50);
        if (reconnect_ui) |ui| {
            if (try reconnectShouldDetach(ui, poll_reconnect_input)) return error.ReconnectDetached;
        }
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[0].revents & posix.POLL.IN) == 0)
        {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) continue;
        var byte: [1]u8 = undefined;
        const n = c.read(fd, &byte, 1);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }

    return error.BootstrapLineTooLong;
}

fn reconnectShouldDetach(reconnect_ui: *client.ReconnectUi, poll_reconnect_input: bool) !bool {
    if (!poll_reconnect_input) return reconnect_ui.isCancelled();
    return reconnect_ui.pollDetach(0);
}

test "readBootstrapLine returns the first line without the newline" {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    try io.writeAll(fds[1], "MISSING linux x86_64\nextra\n");
    const line = try readBootstrapLine(std.testing.allocator, fds[0], null, false);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("MISSING linux x86_64", line);
}

test "parseMissingPlatform parses canonical platform fields" {
    const platform = try parseMissingPlatform("MISSING macos aarch64");

    try std.testing.expectEqualStrings("macos", platform.os);
    try std.testing.expectEqualStrings("aarch64", platform.arch);
}

test "artifactFilenameForPlatform maps canonical platform fields to packaged names" {
    try std.testing.expectEqualStrings(
        "sesshmux-linux-aarch64",
        artifactFilenameForPlatform(.{ .os = "linux", .arch = "aarch64" }) orelse return error.MissingArtifactName,
    );
    try std.testing.expectEqualStrings(
        "sesshmux-macos-x86_64",
        artifactFilenameForPlatform(.{ .os = "macos", .arch = "x86_64" }) orelse return error.MissingArtifactName,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), artifactFilenameForPlatform(.{
        .os = "linux",
        .arch = "sparc",
    }));
}

test "packaged artifact manifest supplies hashes without hashing artifact contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zero_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(std.testing.allocator);
    for (packaged_artifact_targets) |target| {
        try tmp.dir.writeFile(.{ .sub_path = target.filename, .data = "x" });
        try manifest.writer(std.testing.allocator).print(
            "{s} {s}\n",
            .{ target.filename, zero_hash },
        );
    }
    try tmp.dir.writeFile(.{ .sub_path = artifact_manifest_filename, .data = manifest.items });

    const artifact_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(artifact_dir);
    var artifact_set = (try loadPackagedArtifactSetFromDir(std.testing.allocator, artifact_dir)) orelse {
        return error.MissingArtifactSet;
    };
    defer artifact_set.deinit();

    const entry = artifact_set.find(.{ .os = "linux", .arch = "x86_64" }) orelse {
        return error.MissingArtifactEntry;
    };
    try std.testing.expectEqualStrings(zero_hash, entry.hash_hex[0..]);
}

test "shellQuote produces single-quoted shell words" {
    const quoted = try shellQuote(std.testing.allocator, "alpha ' beta");
    defer std.testing.allocator.free(quoted);

    try std.testing.expectEqualStrings("'alpha '\\'' beta'", quoted);
}

test "parseSshArgs passes through ssh options before host" {
    const args = [_][]const u8{
        "sessh",
        "-F",
        "ssh_config",
        "-p2222",
        "-o",
        "BatchMode=yes",
        "-vvC",
        "example.com",
    };

    const parsed = try parseSshArgs(&args, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(usize, 6), parsed.options.len);
    try std.testing.expectEqualStrings("-F", parsed.options[0]);
    try std.testing.expectEqualStrings("ssh_config", parsed.options[1]);
    try std.testing.expectEqualStrings("-p2222", parsed.options[2]);
    try std.testing.expectEqualStrings("-o", parsed.options[3]);
    try std.testing.expectEqualStrings("BatchMode=yes", parsed.options[4]);
    try std.testing.expectEqualStrings("-vvC", parsed.options[5]);
}

test "parseSshArgs accepts sessh options before ssh options and host" {
    const parsed = try parseSshArgs(&.{
        "sessh",
        "--alias",
        "work",
        "--leader",
        "CTRL-B",
        "-F",
        "ssh_config",
        "example.com",
    }, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("work", parsed.alias.?);
    switch (parsed.leader) {
        .ctrl => |byte| try std.testing.expectEqual(@as(u8, 'B'), byte),
        .none => return error.ExpectedLeader,
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.options.len);
    try std.testing.expectEqualStrings("-F", parsed.options[0]);
    try std.testing.expectEqualStrings("ssh_config", parsed.options[1]);
}

test "ssh verbosity maps to inferred client log level" {
    try std.testing.expectEqual(client_log.Level.warn, inferredClientLogLevel(&.{}));
    try std.testing.expectEqual(client_log.Level.info, inferredClientLogLevel(&.{"-v"}));
    try std.testing.expectEqual(client_log.Level.debug, inferredClientLogLevel(&.{"-vv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{"-vvv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{ "-vC", "-vv" }));
}

test "parseSshArgs rejects protocol-breaking ssh options" {
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(&.{
        "sessh",
        "-tt",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(&.{
        "sessh",
        "-n",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(&.{
        "sessh",
        "-W",
        "host:22",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(&.{
        "sessh",
        "-o",
        "RequestTTY=force",
        "example.com",
    }, .{}));
}

test "plain ssh fallback is allowed for transport-incompatible plain ssh invocations" {
    try std.testing.expect(shouldUsePlainSshFallbackForArgError(&.{
        "sessh",
        "-N",
        "example.com",
    }, error.UnsafeSshOption));
    try std.testing.expect(!shouldUsePlainSshFallbackForArgError(&.{
        "sessh",
        "-N",
        "example.com",
        "--alias",
        "s1",
    }, error.UnsafeSshOption));
    try std.testing.expect(shouldUsePlainSshFallbackForMuxNewArgError(&.{
        "sessh",
        "new",
        "-N",
        "example.com",
    }, error.UnsafeSshOption));
    try std.testing.expect(shouldUsePlainSshFallbackForMuxNewArgError(&.{
        "sessh",
        "new",
        "--force-compat",
        "example.com",
    }, error.UnsupportedMuxOption));
    try std.testing.expect(shouldUsePlainSshFallbackForMuxNewArgError(&.{
        "sessh",
        "new",
        "example.com",
        "echo",
        "hello",
    }, error.RemoteCommandUnsupported));
    try std.testing.expect(!shouldUsePlainSshFallbackForMuxNewArgError(&.{
        "sessh",
        "new",
        "--alias",
        "s1",
        "-N",
        "example.com",
    }, error.UnsafeSshOption));
    try std.testing.expect(!shouldUsePlainSshFallbackForMuxNewArgError(&.{
        "sessh",
        "attach",
        "-N",
        "example.com",
        "s1",
    }, error.UnsafeSshOption));
}

test "parseSshArgs permits explicit safe config overrides" {
    const parsed = try parseSshArgs(&.{
        "sessh",
        "-oRequestTTY=no",
        "-o",
        "SessionType=default",
        "example.com",
    }, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(usize, 3), parsed.options.len);
}

test "default ssh options append resolved interactive IPQoS value" {
    var parsed = ParsedSshArgs{
        .options = &.{},
        .host = "example.com",
        .default_ipqos_option = "-oIPQoS=af21",
    };
    try std.testing.expectEqual(@as(usize, 1), defaultSshOptionsLen(parsed));

    var argv: [4][]const u8 = undefined;
    var index: usize = 0;
    appendDefaultSshOptions(&argv, &index, parsed.default_ipqos_option);
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqualStrings("-oIPQoS=af21", argv[0]);

    parsed.default_ipqos_option = null;
    try std.testing.expectEqual(@as(usize, 0), defaultSshOptionsLen(parsed));
}

test "parseInteractiveIpQos returns first configured value" {
    const value = try parseInteractiveIpQos(std.testing.allocator,
        \\hostname example.com
        \\ipqos ef cs0
        \\user tomm
        \\
    );
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("ef", value);
}

test "parseSshArgs accepts translated attach options after host" {
    const parsed = try parseSshArgs(&.{
        "sesshmux",
        "-F",
        "ssh_config",
        "example.com",
        "attach",
        "s12",
        "--leader",
        "CTRL-B",
        "--scrollback-limit",
        "42",
        "--initial-scrollback",
        "0",
        "--log-level",
        "debug",
        "--bootstrap",
    }, .{ .allow_mux_command_words = true });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.len);
    try std.testing.expectEqual(SshAction.attach, parsed.action);
    try std.testing.expectEqualStrings("s12", parsed.attach_id.?);
    switch (parsed.leader) {
        .ctrl => |byte| try std.testing.expectEqual(@as(u8, 'B'), byte),
        .none => return error.ExpectedLeader,
    }
    try std.testing.expectEqual(@as(usize, 9), parsed.banner_args.len);
    try std.testing.expectEqualStrings("--leader", parsed.banner_args.buf[0]);
    try std.testing.expectEqualStrings("CTRL-B", parsed.banner_args.buf[1]);
    try std.testing.expectEqualStrings("--scrollback-limit", parsed.banner_args.buf[2]);
    try std.testing.expectEqualStrings("42", parsed.banner_args.buf[3]);
    try std.testing.expectEqualStrings("--initial-scrollback", parsed.banner_args.buf[4]);
    try std.testing.expectEqualStrings("0", parsed.banner_args.buf[5]);
    try std.testing.expectEqualStrings("--log-level", parsed.banner_args.buf[6]);
    try std.testing.expectEqualStrings("debug", parsed.banner_args.buf[7]);
    try std.testing.expectEqualStrings("--bootstrap", parsed.banner_args.buf[8]);
    try std.testing.expectEqual(@as(u32, 42), parsed.scrollback_row_count);
    try std.testing.expectEqual(@as(?u32, 0), parsed.initial_scrollback_row_count);
    try std.testing.expectEqual(client_log.Level.debug, parsed.client_log_level);
    try std.testing.expect(parsed.client_log_level_set);
    try std.testing.expect(parsed.bootstrap);
    try std.testing.expect(parsed.bootstrap_set);
}

test "parseSshArgs accepts force compat only for translated mux attach" {
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(&.{
        "sesshmux",
        "example.com",
        "attach",
        "s12",
        "--force-compat",
    }, .{ .allow_mux_command_words = true }));

    const parsed = try parseSshArgs(&.{
        "sesshmux",
        "example.com",
        "attach",
        "s12",
        "--force-compat",
    }, .{ .allow_force_compat = true, .allow_mux_command_words = true });

    try std.testing.expectEqual(SshAction.attach, parsed.action);
    try std.testing.expect(parsed.force_compat);
    try std.testing.expectEqual(@as(usize, 1), parsed.banner_args.len);
    try std.testing.expectEqualStrings("--force-compat", parsed.banner_args.buf[0]);
}

test "parseSshArgs accepts no bootstrap shorthand after host" {
    const parsed = try parseSshArgs(&.{
        "sesshmux",
        "example.com",
        "attach",
        "s12",
        "--no-bootstrap",
    }, .{ .allow_mux_command_words = true });

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(SshAction.attach, parsed.action);
    try std.testing.expectEqualStrings("s12", parsed.attach_id.?);
    try std.testing.expect(!parsed.bootstrap);
    try std.testing.expect(parsed.bootstrap_set);
    try std.testing.expectEqual(@as(usize, 1), parsed.banner_args.len);
    try std.testing.expectEqualStrings("--no-bootstrap", parsed.banner_args.buf[0]);
}

test "parseSshArgs accepts attach without an id after host" {
    const parsed = try parseSshArgs(&.{
        "sesshmux",
        "example.com",
        "attach",
        "--scrollback-limit",
        "100",
    }, .{ .allow_mux_command_words = true });

    try std.testing.expectEqual(SshAction.attach, parsed.action);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.attach_id);
    try std.testing.expectEqual(@as(u32, 100), parsed.scrollback_row_count);
}

test "parseSshArgs accepts translated remote session commands after host" {
    const list = try parseSshArgs(&.{ "sesshmux", "example.com", "list" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.list, list.action);

    const refresh_list = try parseSshArgs(&.{ "sesshmux", "example.com", "list", "--refresh" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.list, refresh_list.action);
    try std.testing.expect(refresh_list.list_refresh);

    const exited_list = try parseSshArgs(&.{ "sesshmux", "example.com", "list", "--exited", "--jsonl" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.list, exited_list.action);
    try std.testing.expect(exited_list.list_exited);
    try std.testing.expect(exited_list.list_jsonl);

    const client_list = try parseSshArgs(&.{ "sesshmux", "example.com", "list", "--client=s1", "--jsonl" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.list, client_list.action);
    try std.testing.expectEqualStrings("s1", client_list.list_client_target.?);
    try std.testing.expectEqualStrings("--client=s1", client_list.list_client_option_arg.?);
    try std.testing.expect(client_list.list_jsonl);

    const client_list_spaced = try parseSshArgs(&.{ "sesshmux", "example.com", "list", "--client", "s1", "--jsonl" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.list, client_list_spaced.action);
    try std.testing.expectEqualStrings("s1", client_list_spaced.list_client_target.?);
    try std.testing.expectEqualStrings("--client", client_list_spaced.list_client_option_arg.?);
    try std.testing.expect(client_list_spaced.list_jsonl);

    const kill = try parseSshArgs(&.{ "sesshmux", "example.com", "kill", "s1" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.kill, kill.action);
    try std.testing.expectEqualStrings("s1", kill.kill_id.?);

    const kill_all = try parseSshArgs(&.{ "sesshmux", "example.com", "kill", "--all" }, .{ .allow_mux_command_words = true });
    try std.testing.expectEqual(SshAction.kill_all, kill_all.action);
}

test "brokerArgsForAction uses broker subcommands" {
    var buf: [12][]const u8 = undefined;

    try expectArgvEqual(&.{ "list", "--host-display", "example.com" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .list,
    }, &buf));
    try expectArgvEqual(&.{ "list", "--host-display", "example.com", "--jsonl" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
    }, &buf));
    try expectArgvEqual(&.{ "list", "--host-display", "example.com", "--jsonl", "--exited" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_exited = true,
    }, &buf));

    try expectArgvEqual(&.{ "kill", "s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .kill,
        .kill_id = "s1",
    }, &buf));

    try expectArgvEqual(&.{ "kill", "--all" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .kill_all,
    }, &buf));

    try expectArgvEqual(&.{ "list", "--host-display", "example.com", "--jsonl", "--client=s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_client_target = "s1",
        .list_client_option_arg = "--client=s1",
    }, &buf));

    try expectArgvEqual(&.{ "list", "--host-display", "example.com", "--jsonl", "--client", "s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_client_target = "s1",
        .list_client_option_arg = "--client",
    }, &buf));

    try expectArgvEqual(&.{ "debug", "unresponsive-connection", "c1", "s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .debug_client_action = .unresponsive_connection,
        .client_target = .client_guid,
        .client_guid = "c1",
        .client_session_ref = "s1",
    }, &buf));

    try expectArgvEqual(&.{ "detach", "c1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .detach_client,
        .client_target = .client_guid,
        .client_guid = "c1",
    }, &buf));

    try expectArgvEqual(&.{ "debug", "unresponsive-connection", "--last-input", "--seconds", "3", "s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .debug_client_action = .unresponsive_connection,
        .debug_unresponsive_seconds = "3",
        .client_target = .last_input,
        .client_session_ref = "s1",
    }, &buf));

    try expectArgvEqual(&.{ "repaint", "--last-input", "--scrollback", "s1" }, brokerArgsForAction(.{
        .options = &.{},
        .host = "example.com",
        .action = .repaint_client,
        .client_target = .last_input,
        .client_repaint_scrollback = true,
        .client_session_ref = "s1",
    }, &buf));
}

test "parseSshArgs accepts persistent command argv after delimiter" {
    const parsed = try parseSshArgs(&.{
        "sessh",
        "example.com",
        "--alias",
        "work",
        "--",
        "top",
        "-H",
    }, .{});

    try std.testing.expectEqual(SshAction.new, parsed.action);
    try std.testing.expectEqualStrings("work", parsed.alias.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.command_argv.len);
    try std.testing.expectEqualStrings("top", parsed.command_argv[0]);
    try std.testing.expectEqualStrings("-H", parsed.command_argv[1]);
}

test "parseSshArgs rejects custom aliases with reserved typed prefix shape" {
    try std.testing.expectError(error.InvalidAlias, parseSshArgs(&.{
        "sessh",
        "example.com",
        "--alias",
        "s-deadbeef",
    }, .{}));
    try std.testing.expectError(error.InvalidAlias, parseSshArgs(&.{
        "sessh",
        "example.com",
        "--alias",
        "x-anything",
    }, .{}));
}

test "translateMuxArgs maps new command to ssh-shaped invocation" {
    var translated = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--ssh-options",
        "-F cfg -o 'ProxyJump bastion'",
        "--alias",
        "work",
        "example.com",
        "--",
        "top",
        "-H",
    });
    defer translated.deinit();

    try expectArgvEqual(&.{
        "sesshmux",
        "-F",
        "cfg",
        "-o",
        "ProxyJump bastion",
        "example.com",
        "--alias",
        "work",
        "--",
        "top",
        "-H",
    }, translated.args.items);

    try std.testing.expectError(error.UnsupportedMuxOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "-tt",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedMuxOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "-F",
        "cfg",
        "example.com",
    }));
}

test "translateMuxArgs allows ssh-style options only for sessh invocation" {
    var translated = try translateMuxArgsForInvocation(std.testing.allocator, &.{
        "sessh",
        "new",
        "-F",
        "cfg",
        "-o",
        "ProxyJump bastion",
        "example.com",
    }, .sessh);
    defer translated.deinit();

    try expectArgvEqual(&.{
        "sessh",
        "-F",
        "cfg",
        "-o",
        "ProxyJump bastion",
        "example.com",
    }, translated.args.items);

    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgsForInvocation(std.testing.allocator, &.{
        "sessh",
        "new",
        "--ssh-options",
        "-F cfg",
        "example.com",
    }, .sessh));
}

test "translateMuxArgs rejects sessh options after host" {
    try std.testing.expectError(error.SesshOptionAfterHost, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "example.com",
        "--leader",
        "CTRL-B",
    }));
}

test "translateMuxArgs rejects config and env only options" {
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--leader",
        "CTRL-B",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--scrollback-limit",
        "100",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--initial-scrollback",
        "0",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--bootstrap",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--no-bootstrap",
        "example.com",
    }));
    try std.testing.expectError(error.UnsupportedSesshCliOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--leader",
        "CTRL-B",
        "s1",
    }));
}

test "translateMuxArgs maps local and host-qualified attach" {
    var latest_local = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
    });
    defer latest_local.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "attach" }, latest_local.args.items);

    var local = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "s1",
    });
    defer local.deinit();
    try expectArgvEqual(&.{ "sesshmux", "attach", "s1" }, local.args.items);

    var remote = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--ssh-options",
        "-F cfg",
        "--host",
        "example.com",
        "s1",
    });
    defer remote.deinit();
    try expectArgvEqual(&.{ "sesshmux", "-F", "cfg", "example.com", "attach", "s1" }, remote.args.items);

    var remote_latest = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--host",
        "example.com",
    });
    defer remote_latest.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "attach" }, remote_latest.args.items);

    var remote_force_compat = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "--force-compat",
        "--host",
        "example.com",
        "s1",
    });
    defer remote_force_compat.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "attach", "s1", "--force-compat" }, remote_force_compat.args.items);

    try std.testing.expectError(error.TooManyMuxArguments, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "attach",
        "example.com",
        "s1",
    }));

    try std.testing.expectError(error.UnsupportedMuxOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "new",
        "--force-compat",
        "example.com",
    }));
}

test "translateMuxArgs maps explicit local list" {
    var default_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
    });
    defer default_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list" }, default_local_list.args.items);

    var local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        ".",
    });
    defer local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--local-only" }, local_list.args.items);

    var refresh_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--refresh",
    });
    defer refresh_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--refresh" }, refresh_local_list.args.items);

    var refresh_explicit_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--refresh",
        ".",
    });
    defer refresh_explicit_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--local-only", "--refresh" }, refresh_explicit_local_list.args.items);

    var refresh_remote_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--refresh",
        "example.com",
    });
    defer refresh_remote_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "list", "--refresh" }, refresh_remote_list.args.items);

    var jsonl_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--jsonl",
    });
    defer jsonl_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--jsonl" }, jsonl_local_list.args.items);

    var jsonl_remote_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--refresh",
        "--jsonl",
        "example.com",
    });
    defer jsonl_remote_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "list", "--refresh", "--jsonl" }, jsonl_remote_list.args.items);

    var exited_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--exited",
        "--jsonl",
    });
    defer exited_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--exited", "--jsonl" }, exited_local_list.args.items);

    var exited_explicit_local_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--exited",
        ".",
    });
    defer exited_explicit_local_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--local-only", "--exited" }, exited_explicit_local_list.args.items);
}

test "translateMuxArgs maps kill and kill all" {
    var local_kill = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "s1",
    });
    defer local_kill.deinit();
    try expectArgvEqual(&.{ "sesshmux", "kill", "s1" }, local_kill.args.items);

    var kill = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--host",
        "example.com",
        "s1",
    });
    defer kill.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "kill", "s1" }, kill.args.items);

    var kill_all = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--all",
        "--ssh-options",
        "-F cfg",
        "example.com",
    });
    defer kill_all.deinit();
    try expectArgvEqual(&.{ "sesshmux", "-F", "cfg", "example.com", "kill", "--all" }, kill_all.args.items);

    var default_local_kill_all = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--all",
    });
    defer default_local_kill_all.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "kill", "--all" }, default_local_kill_all.args.items);

    var local_kill_all = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "kill",
        "--all",
        ".",
    });
    defer local_kill_all.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "kill", "--all" }, local_kill_all.args.items);
}

test "translateMuxArgs maps client management commands" {
    const client_guid = "c-11111111-1111-1111-1111-111111111111";

    var client_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--jsonl",
        "--client=s1",
    });
    defer client_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--client=s1", "--jsonl" }, client_list.args.items);

    var current_client_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--jsonl",
        "--client=session",
    });
    defer current_client_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--client=session", "--jsonl" }, current_client_list.args.items);

    var spaced_current_client_list = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "list",
        "--jsonl",
        "--client",
        "session",
    });
    defer spaced_current_client_list.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "list", "--client", "session", "--jsonl" }, spaced_current_client_list.args.items);

    var detach_last = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "detach",
        "--last-input",
    });
    defer detach_last.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "detach", "--last-input" }, detach_last.args.items);

    var detach_client = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "detach",
        client_guid,
        "s1",
    });
    defer detach_client.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "detach", client_guid, "s1" }, detach_client.args.items);

    var detach_client_without_session = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "detach",
        client_guid,
    });
    defer detach_client_without_session.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "detach", client_guid }, detach_client_without_session.args.items);

    var repaint_all = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "repaint",
    });
    defer repaint_all.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "repaint", "--all" }, repaint_all.args.items);

    var repaint_scrollback = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "repaint",
        "--scrollback",
        "--last-input",
        "s1",
    });
    defer repaint_scrollback.deinit();
    try expectArgvEqual(&.{ "sesshmux", ".", "repaint", "--last-input", "--scrollback", "s1" }, repaint_scrollback.args.items);

    var remote_debug = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "debug",
        "sever-connection",
        "--host",
        "example.com",
        "--last-input",
        "s1",
    });
    defer remote_debug.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "debug", "sever-connection", "--last-input", "s1" }, remote_debug.args.items);

    var remote_debug_unresponsive_seconds = try translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "debug",
        "unresponsive-connection",
        "--host",
        "example.com",
        "--seconds",
        "3",
        "--last-input",
        "s1",
    });
    defer remote_debug_unresponsive_seconds.deinit();
    try expectArgvEqual(&.{ "sesshmux", "example.com", "debug", "unresponsive-connection", "--last-input", "--seconds", "3", "s1" }, remote_debug_unresponsive_seconds.args.items);

    try std.testing.expectError(error.UnsupportedMuxOption, translateMuxArgs(std.testing.allocator, &.{
        "sesshmux",
        "debug",
        "sever-connection",
        "--seconds",
        "3",
    }));
}

fn expectArgvEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

test "sesshmux-dev uses development artifact upload" {
    try std.testing.expect(isDevelopmentExecutable("/tmp/sesshmux-dev"));
    try std.testing.expect(isDevelopmentExecutable("/tmp/build/bin/sesshmux-dev"));
    try std.testing.expect(!isDevelopmentExecutable("/tmp/sessh-dev"));
    try std.testing.expect(!isDevelopmentExecutable("/tmp/build/bin/sessh"));
    try std.testing.expect(!isDevelopmentExecutable("/tmp/libexec/sessh/sesshmux-macos-aarch64"));
}

test "reconnectDelayMs follows the documented backoff schedule" {
    try std.testing.expectEqual(@as(u64, 10_000), reconnectDelayMs(0));
    try std.testing.expectEqual(@as(u64, 20_000), reconnectDelayMs(1));
    try std.testing.expectEqual(@as(u64, 40_000), reconnectDelayMs(2));
    try std.testing.expectEqual(@as(u64, 80_000), reconnectDelayMs(3));
    try std.testing.expectEqual(@as(u64, 160_000), reconnectDelayMs(4));
    try std.testing.expectEqual(@as(u64, 320_000), reconnectDelayMs(5));
    try std.testing.expectEqual(@as(u64, 600_000), reconnectDelayMs(6));
    try std.testing.expectEqual(@as(u64, 600_000), reconnectDelayMs(7));
}

test "parseSshArgs rejects remote commands for now" {
    try std.testing.expectError(error.RemoteCommandUnsupported, parseSshArgs(&.{
        "sessh",
        "example.com",
        "uname",
    }, .{}));
}
