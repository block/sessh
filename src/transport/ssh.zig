const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const attached_client = @import("../session/attached_client.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
const mux_routed = @import("../mux/routed.zig");
const proxy_control = @import("../stream/proxy_control.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");
const protocol = @import("../protocol/mod.zig");
const pty_process = @import("../tty/pty_process.zig");
const reconnect = @import("../reconnect/mod.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect_title = @import("../reconnect/title.zig");
const route_commands = @import("../runtime/route_commands.zig");
const session_attach = @import("../session/attach.zig");
const session_new = @import("../session/new.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("socket.zig");
const stream_agent = @import("../stream/agent.zig");
const terminal = @import("../tty/terminal.zig");
const tty_settings = @import("../tty/settings.zig");
const tty_transcript = @import("../tty/transcript.zig");
const pb = protocol.pb;

const bootstrapper_script = @embedFile("../bootstrapper.sh");
const max_artifact_bytes = 64 * 1024 * 1024;
const max_artifact_manifest_bytes = 16 * 1024;
const artifact_manifest_filename = "artifacts.manifest";
const default_ipqos_option_prefix = "-oIPQoS=";
const ssh_config_query_max_output_bytes = 256 * 1024;
const client_list_target_help = "incoming, outgoing, session, or a guid";
const bootstrap_exec_encoded_arg_prefix = "b64:";

const BootstrapEntrypoint = enum {
    session_broker,
    stream_broker,
    control,

    fn arg(self: BootstrapEntrypoint) []const u8 {
        return switch (self) {
            .session_broker => ":internal-session-broker:",
            .stream_broker => ":internal-stream-broker:",
            .control => ":internal-control:",
        };
    }
};

pub const SshTtyRequest = enum {
    none,
    requested,
    forced,
};

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
        entrypoint: BootstrapEntrypoint,
        broker_args: []const []const u8,
        reconnect_ui: ?*client_ui.ReconnectUi,
        poll_reconnect_input: bool,
    ) !void {
        try writeAllMaybeCancellable(fd, "EXEC ", reconnect_ui, poll_reconnect_input);
        try writeAllMaybeCancellable(fd, self.artifact_set_id, reconnect_ui, poll_reconnect_input);
        for (self.entries) |entry| {
            try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
            try writeAllMaybeCancellable(fd, &entry.hash_hex, reconnect_ui, poll_reconnect_input);
        }
        try writeAllMaybeCancellable(fd, " --", reconnect_ui, poll_reconnect_input);
        try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
        try writeAllMaybeCancellable(fd, entrypoint.arg(), reconnect_ui, poll_reconnect_input);
        for (broker_args) |arg| {
            try writeAllMaybeCancellable(fd, " ", reconnect_ui, poll_reconnect_input);
            try self.writeExecArg(fd, arg, reconnect_ui, poll_reconnect_input);
        }
        try writeAllMaybeCancellable(fd, "\n", reconnect_ui, poll_reconnect_input);
    }

    fn writeExecArg(
        self: *const ArtifactSet,
        fd: c.fd_t,
        arg: []const u8,
        reconnect_ui: ?*client_ui.ReconnectUi,
        poll_reconnect_input: bool,
    ) !void {
        if (!needsEncodedExecArg(arg)) {
            try writeAllMaybeCancellable(fd, arg, reconnect_ui, poll_reconnect_input);
            return;
        }

        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(arg.len));
        defer self.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, arg);
        try writeAllMaybeCancellable(fd, bootstrap_exec_encoded_arg_prefix, reconnect_ui, poll_reconnect_input);
        try writeAllMaybeCancellable(fd, encoded, reconnect_ui, poll_reconnect_input);
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

pub const SessionAction = enum {
    new,
    attach,
    list,
    kill,
    kill_all,
    detach_client,
    repaint_client,
    debug_client,
};

pub const SessionInvocation = struct {
    options: []const []const u8,
    owned_options: ?[][]const u8 = null,
    host: []const u8,
    action: SessionAction = .new,
    attach_id: ?[]const u8 = null,
    attach_id_from_latest_route: bool = false,
    attach_session_dir: []const u8 = "",
    kill_id: ?[]const u8 = null,
    kill_ids: []const []const u8 = &.{},
    kill_current: bool = false,
    kill_jsonl: bool = false,
    kill_request_jsons: []const []const u8 = &.{},
    owned_kill_request_jsons: ?[][]const u8 = null,
    list_refresh: bool = false,
    list_include_cached_routes: bool = true,
    list_jsonl: bool = false,
    list_exited: bool = false,
    list_all: bool = false,
    list_client_target: ?[]const u8 = null,
    list_client_option_arg: ?[]const u8 = null,
    client_session_ref: ?[]const u8 = null,
    client_target: ClientTarget = .default,
    client_guid: ?[]const u8 = null,
    client_repaint_scrollback: bool = false,
    debug_client_action: ?DebugClientAction = null,
    debug_unresponsive_seconds: ?[]const u8 = null,
    new_detached: bool = false,
    command_argv: []const []const u8 = &.{},
    shell_command_args: []const []const u8 = &.{},
    tty_request: SshTtyRequest = .none,
    overlay_args: client_ui.DetachOverlayArgs = .{},
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
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    proxy_required: bool = false,
    default_ipqos_option: ?[]const u8 = null,
    resolved_host: []const u8 = "",
    resolved_port: []const u8 = session_registry.default_pending_port,
    capture_tty_transcript: ?[]const u8 = null,
    remote_local_args: []const []const u8 = &.{},

    pub fn deinit(self: *SessionInvocation, allocator: std.mem.Allocator) void {
        if (self.owned_options) |options| {
            allocator.free(options);
            self.owned_options = null;
            self.options = &.{};
        }
        if (self.owned_kill_request_jsons) |requests| {
            allocator.free(requests);
            self.owned_kill_request_jsons = null;
            self.kill_request_jsons = &.{};
        }
    }
};

pub const ClientTarget = enum {
    default,
    all,
    last_input,
    client_guid,
};

pub const DebugClientAction = enum {
    sever_connection,
    unresponsive_connection,
};

pub const CompatModeReason = enum {
    version_mismatch,
    forced,
};

pub const CompatTransport = struct {
    options: []const []const u8,
    host: []const u8,
    default_ipqos_option: ?[]const u8 = null,
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

const RemoteControlRunner = struct {
    allocator: std.mem.Allocator,
    bootstrap: bool,
    artifacts: ?ArtifactSet = null,
    active: ?Active = null,
    next_request_id: u64 = 1,

    const Active = struct {
        key: []u8,
        connection: RuntimeConnection,

        fn deinit(self: *Active, allocator: std.mem.Allocator) void {
            self.connection.closeStdin();
            _ = self.connection.wait() catch {};
            allocator.free(self.key);
            self.* = undefined;
        }
    };

    fn init(allocator: std.mem.Allocator) !RemoteControlRunner {
        const file_config = try client_config.loadFileConfig(allocator);
        const bootstrap = file_config.bootstrap orelse true;
        return initWithBootstrap(allocator, bootstrap);
    }

    fn initWithBootstrap(allocator: std.mem.Allocator, bootstrap: bool) !RemoteControlRunner {
        return .{
            .allocator = allocator,
            .bootstrap = bootstrap,
            .artifacts = if (bootstrap) try loadArtifactSet(allocator) else null,
        };
    }

    fn deinit(self: *RemoteControlRunner) void {
        if (self.active) |*active| active.deinit(self.allocator);
        self.active = null;
        if (self.artifacts) |*artifacts| artifacts.deinit();
        self.* = undefined;
    }

    fn interface(self: *RemoteControlRunner) route_commands.RemoteCommandRunner {
        return .{
            .context = self,
            .runFn = runOpaque,
        };
    }

    fn runOpaque(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) anyerror!route_commands.RemoteCommandResult {
        const self: *RemoteControlRunner = @ptrCast(@alignCast(context));
        return self.run(allocator, host, ssh_options, argv);
    }

    fn run(
        self: *RemoteControlRunner,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) !route_commands.RemoteCommandResult {
        const active = try self.activeFor(host, ssh_options);
        const request_id = self.next_request_id;
        self.next_request_id +%= 1;
        try sendRunRequest(allocator, active.connection.child.stdin.?.handle, request_id, argv);
        return readRunResponse(allocator, active.connection.child.stdout.?.handle, active.connection.child.stdin.?.handle, request_id);
    }

    fn activeFor(self: *RemoteControlRunner, host: []const u8, ssh_options: []const []const u8) !*Active {
        const key = try remoteControlKey(self.allocator, host, ssh_options);
        errdefer self.allocator.free(key);
        if (self.active) |*active| {
            if (std.mem.eql(u8, active.key, key)) {
                self.allocator.free(key);
                return active;
            }
            active.deinit(self.allocator);
            self.active = null;
        }

        var parsed = SessionInvocation{
            .host = host,
            .options = ssh_options,
            .bootstrap = self.bootstrap,
        };
        var resolved_ssh_config = try resolveSshConfig(self.allocator, parsed.options, parsed.host);
        defer resolved_ssh_config.deinit(self.allocator);
        parsed.default_ipqos_option = try resolved_ssh_config.defaultIpQosOption(self.allocator);
        defer if (parsed.default_ipqos_option) |option| self.allocator.free(option);
        parsed.resolved_host = resolved_ssh_config.hostname;
        parsed.resolved_port = resolved_ssh_config.port;

        const remote_command = if (self.bootstrap)
            try bootstrapCommand(self.allocator)
        else
            try directControlCommand(self.allocator);
        defer self.allocator.free(remote_command);

        var connection = try startRuntimeConnection(
            self.allocator,
            parsed,
            if (self.artifacts) |*artifacts| artifacts else null,
            remote_command,
            .control,
            &.{},
            true,
            null,
            false,
            .diagnostics,
            null,
        );
        errdefer connection.terminate();
        try attached_client.runtimeHandshake(connection.child.stdout.?.handle, connection.child.stdin.?.handle);

        self.active = .{
            .key = key,
            .connection = connection,
        };
        return &self.active.?;
    }
};

fn remoteControlKey(allocator: std.mem.Allocator, host: []const u8, ssh_options: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, host);
    try out.append(allocator, 0);
    for (ssh_options) |option| {
        try out.appendSlice(allocator, option);
        try out.append(allocator, 0);
    }
    return out.toOwnedSlice(allocator);
}

fn sendRunRequest(allocator: std.mem.Allocator, fd: c.fd_t, request_id: u64, argv: []const []const u8) !void {
    var request = pb.RunRequest{
        .request_id = request_id,
    };
    defer request.deinit(allocator);
    for (argv) |arg| {
        const owned = try allocator.dupe(u8, arg);
        errdefer allocator.free(owned);
        try request.argv.append(allocator, owned);
    }

    const payload = try protocol.encodePayload(allocator, request);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .run_request, payload);
}

fn readRunResponse(
    allocator: std.mem.Allocator,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    request_id: u64,
) !route_commands.RemoteCommandResult {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, read_fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .run_response => {
                var response = try protocol.decodePayload(pb.RunResponse, allocator, frame.payload);
                defer response.deinit(allocator);
                if (response.request_id != request_id) return error.UnexpectedRunResponse;
                const stdout = try allocator.dupe(u8, response.stdout);
                errdefer allocator.free(stdout);
                const stderr = try allocator.dupe(u8, response.stderr);
                errdefer allocator.free(stderr);
                return .{
                    .stdout = stdout,
                    .stderr = stderr,
                    .exit_code = @intCast(@min(@max(response.exit_code, 0), std.math.maxInt(u8))),
                };
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, write_fd);
            },
            else => return error.UnexpectedFrame,
        }
    }
}

const SshStderrMode = enum(u8) {
    forward,
    diagnostics,
    discard,
};

const ParallelReconnectResult = reconnect.AsyncResult(RuntimeConnection);

const ParallelReconnectState = struct {
    task: reconnect.AsyncTask(RuntimeConnection) = .{},
    parsed_ssh_args: SessionInvocation,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    bootstrap_entrypoint: BootstrapEntrypoint,
    broker_args: []const []const u8,
    reconnect_ui: *client_ui.ReconnectUi,
    session: attached_client.RuntimeSession,

    fn store(self: *ParallelReconnectState, result: ParallelReconnectResult) void {
        self.task.store(result);
    }

    fn isDone(self: *const ParallelReconnectState) bool {
        return self.task.isDone();
    }

    fn take(self: *ParallelReconnectState) ?ParallelReconnectResult {
        return self.task.take();
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
        mode: std.atomic.Value(u8),
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    fn start(allocator: std.mem.Allocator, file: std.fs.File, mode: SshStderrMode) !SshStderrPump {
        errdefer file.close();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .fd = file.handle,
            .mode = std.atomic.Value(u8).init(@intFromEnum(mode)),
        };

        const thread = try std.Thread.spawn(.{}, stderrPumpMain, .{state});
        return .{ .allocator = allocator, .state = state, .thread = thread };
    }

    fn suppress(self: *SshStderrPump) void {
        self.state.mode.store(@intFromEnum(SshStderrMode.diagnostics), .release);
    }

    fn join(self: *SshStderrPump) void {
        self.state.stop.store(true, .release);
        self.thread.join();
        self.allocator.destroy(self.state);
    }
};

fn stderrPumpMain(state: *SshStderrPump.State) void {
    defer posix.close(state.fd);
    var buf: [4096]u8 = undefined;
    while (true) {
        if (state.stop.load(.acquire)) return;
        var pollfds = [_]posix.pollfd{.{
            .fd = state.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&pollfds, 100) catch return;
        if (state.stop.load(.acquire)) return;
        if (ready == 0) continue;
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return;
        const n = c.read(state.fd, &buf, buf.len);
        if (n <= 0) return;
        const bytes = buf[0..@intCast(n)];
        const mode: SshStderrMode = @enumFromInt(state.mode.load(.acquire));
        switch (mode) {
            .forward => io.writeAll(2, bytes) catch {},
            .diagnostics => client_log.appendSshStderr(bytes),
            .discard => {},
        }
    }
}

pub fn classifySshOptions(
    options: []const []const u8,
    tty_request: *SshTtyRequest,
    proxy_required: *bool,
) !void {
    var i: usize = 0;
    while (i < options.len) {
        try consumeSshOption(options, &i, tty_request, proxy_required);
    }
}

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper installs or finds the remote sesshmux binary, then execs
/// the internal entrypoint we send in the EXEC line. For normal sessions that
/// is `:internal-session-broker:`; tty/proxy streams use `:internal-stream-broker:`.
/// Installed packages keep one binary per supported platform in libexec/sessh,
/// named `sesshmux-<os>-<arch>`. If that layout is unavailable, upload the
/// current binary for same-platform development tests.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return runWithParseOptions(allocator, args);
}

const CliParseOptions = struct {};

fn runWithParseOptions(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var route_storage: ?session_registry.Route = null;
    defer if (route_storage) |*route| route.deinit(allocator);

    var parsed_ssh_args = parseSshArgs(allocator, args, .{}) catch |err| {
        try printSshArgError(err);
        return process_exit.request(64);
    };
    defer parsed_ssh_args.deinit(allocator);
    return runInvocation(allocator, args, &parsed_ssh_args, &route_storage, false);
}

pub fn runInvocation(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    parsed_ssh_args: *SessionInvocation,
    route_storage: *?session_registry.Route,
    mux_command_mode: bool,
) !void {
    if (!mux_command_mode and
        parsed_ssh_args.action == .new and
        std.mem.eql(u8, parsed_ssh_args.host, "."))
    {
        try io.writeAll(2, "sessh: \".\" is not a valid ssh host\n");
        return process_exit.request(64);
    }
    if (mux_command_mode and
        parsed_ssh_args.action == .new and
        std.mem.eql(u8, parsed_ssh_args.host, "."))
    {
        applyFileConfigToLocalMux(allocator, parsed_ssh_args) catch |err| {
            try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
            return process_exit.request(64);
        };
        client_log.setLevel(parsed_ssh_args.client_log_level);
        if (parsed_ssh_args.terminal_emulator_set and !parsed_ssh_args.terminal_emulator) {
            try io.writeAll(2, "sesshmux: new . requires terminal-emulator mode\n");
            return process_exit.request(64);
        }
        if (parsed_ssh_args.filter_level_set and filterLevelForcesProxy(parsed_ssh_args.filter_level)) {
            try io.writeAll(2, "sesshmux: new . does not support proxy stream filter levels\n");
            return process_exit.request(64);
        }
        const shell_command = try shellCommandFromRemoteArgs(allocator, parsed_ssh_args.shell_command_args);
        defer if (shell_command) |command| allocator.free(command);
        return session_new.runLocal(allocator, .{
            .exe = args[0],
            .new_detached = parsed_ssh_args.new_detached,
            .scrollback_row_count = parsed_ssh_args.scrollback_row_count,
            .overlay_args = parsed_ssh_args.overlay_args.slice(),
            .capture_tty_transcript = parsed_ssh_args.capture_tty_transcript,
            .command_argv = parsed_ssh_args.command_argv,
            .shell_command = shell_command,
            .reap_ms = parsed_ssh_args.reap_ms,
            .tombstone_retention_ms = parsed_ssh_args.tombstone_retention_ms,
        });
    }
    if ((parsed_ssh_args.action == .attach or isOneShotBrokerCommandAction(parsed_ssh_args.action)) and
        (parsed_ssh_args.host.len == 0 or std.mem.eql(u8, parsed_ssh_args.host, ".")))
    {
        applyFileConfigToLocalMux(allocator, parsed_ssh_args) catch |err| {
            try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
            return process_exit.request(64);
        };
        client_log.setLevel(parsed_ssh_args.client_log_level);
        if (parsed_ssh_args.action == .attach) return session_attach.runLocal(allocator, .{
            .exe = args[0],
            .session_ref = parsed_ssh_args.attach_id,
            .session_dir = parsed_ssh_args.attach_session_dir,
            .initial_scrollback_row_count = parsed_ssh_args.initial_scrollback_row_count,
            .overlay_args = parsed_ssh_args.overlay_args.slice(),
            .capture_tty_transcript = parsed_ssh_args.capture_tty_transcript,
            .compat_mode = compatModeFromEnv(),
        });
        if (parsed_ssh_args.action == .list and parsed_ssh_args.list_client_target == null) {
            var remote_control_runner: ?RemoteControlRunner = if (parsed_ssh_args.list_refresh and parsed_ssh_args.list_include_cached_routes)
                try RemoteControlRunner.init(allocator)
            else
                null;
            defer if (remote_control_runner) |*runner| runner.deinit();
            var remote_runner_interface: ?route_commands.RemoteCommandRunner = if (remote_control_runner) |*runner|
                runner.interface()
            else
                null;
            const exit_status = try route_commands.runLocalListCommand(
                allocator,
                args[0],
                &.{},
                parsed_ssh_args.list_refresh,
                parsed_ssh_args.list_include_cached_routes,
                parsed_ssh_args.list_jsonl,
                parsed_ssh_args.list_exited,
                parsed_ssh_args.list_all,
                if (remote_runner_interface) |*runner| runner else null,
            );
            if (exit_status != 0) return process_exit.request(exit_status);
            return;
        }
        return mux_routed.runInvocation(allocator, args[0], parsed_ssh_args.*);
    }
    applyFileConfigToSsh(allocator, parsed_ssh_args) catch |err| {
        try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(parsed_ssh_args.client_log_level);
    if (parsed_ssh_args.new_detached) {
        if (parsed_ssh_args.capture_tty_transcript != null) {
            try io.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n");
            return process_exit.request(64);
        }
        if (!parsed_ssh_args.terminal_emulator) {
            try io.writeAll(2, "sesshmux: new --detached requires terminal-emulator mode\n");
            return process_exit.request(64);
        }
        if (filterLevelForcesProxy(parsed_ssh_args.filter_level) or parsed_ssh_args.proxy_required) {
            try io.writeAll(2, "sesshmux: new --detached does not support proxy stream mode\n");
            return process_exit.request(64);
        }
    }
    if (parsed_ssh_args.action != .new and (filterLevelForcesProxy(parsed_ssh_args.filter_level) or parsed_ssh_args.proxy_required)) {
        try io.writeAll(2, "sessh: proxy stream mode is only supported for new sessions\n");
        return process_exit.request(64);
    }
    if (parsed_ssh_args.capture_tty_transcript != null and isOneShotBrokerCommandAction(parsed_ssh_args.action)) {
        try io.writeAll(2, "sessh: --capture-tty-transcript is only supported for new and attach sessions\n");
        return process_exit.request(64);
    }
    const resolved_ref_storage = try resolveLocalRefs(allocator, parsed_ssh_args);
    defer if (resolved_ref_storage) |ref| allocator.free(ref);
    var resolved_ssh_config = try resolveSshConfig(allocator, parsed_ssh_args.options, parsed_ssh_args.host);
    defer resolved_ssh_config.deinit(allocator);
    parsed_ssh_args.default_ipqos_option = try resolved_ssh_config.defaultIpQosOption(allocator);
    defer if (parsed_ssh_args.default_ipqos_option) |option| allocator.free(option);
    parsed_ssh_args.resolved_host = resolved_ssh_config.hostname;
    parsed_ssh_args.resolved_port = resolved_ssh_config.port;

    const stdin_is_tty = c.isatty(0) != 0;
    if (shouldUseProxyStream(parsed_ssh_args.*, stdin_is_tty)) {
        if (parsed_ssh_args.capture_tty_transcript != null) {
            try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with proxy stream mode\n");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, args[0], parsed_ssh_args.*);
    }

    if (isRemoteClientControlAction(parsed_ssh_args.*)) {
        return runRemoteMuxClientControlCommand(allocator, parsed_ssh_args.*);
    }

    const shell_command = try shellCommandFromRemoteArgs(allocator, parsed_ssh_args.shell_command_args);
    defer if (shell_command) |command| allocator.free(command);

    var artifacts_storage: ?ArtifactSet = if (parsed_ssh_args.bootstrap) try loadArtifactSet(allocator) else null;
    defer if (artifacts_storage) |*artifacts| artifacts.deinit();
    const artifacts = if (artifacts_storage) |*value| value else null;

    const broker_args = try brokerArgsForAction(allocator, parsed_ssh_args.*);
    defer allocator.free(broker_args);
    const remote_command = if (parsed_ssh_args.bootstrap)
        try bootstrapCommand(allocator)
    else
        try directBrokerCommand(allocator, broker_args);
    defer allocator.free(remote_command);

    if (isOneShotBrokerCommandAction(parsed_ssh_args.action)) {
        const command_remote_command = if (parsed_ssh_args.bootstrap)
            remote_command
        else
            try directBrokerCommand(allocator, broker_args);
        defer if (!parsed_ssh_args.bootstrap) allocator.free(command_remote_command);
        var command_child = try startRuntimeConnection(
            allocator,
            parsed_ssh_args.*,
            artifacts,
            command_remote_command,
            .session_broker,
            broker_args,
            false,
            null,
            false,
            null,
            null,
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
            if (route_storage.*) |*route| {
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
    if (parsed_ssh_args.action == .new) {
        new_guid = try session_registry.generateGuid(allocator);
    }

    var child = try startRuntimeConnection(
        allocator,
        parsed_ssh_args.*,
        artifacts,
        remote_command,
        .session_broker,
        broker_args,
        false,
        null,
        false,
        null,
        null,
    );

    if (parsed_ssh_args.action == .new and parsed_ssh_args.new_detached) {
        var created = attached_client.createSessionOnRuntime(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            parsed_ssh_args.scrollback_row_count,
            new_guid.?,
            parsed_ssh_args.command_argv,
            shell_command,
            parsed_ssh_args.host,
            parsed_ssh_args.reap_ms,
            parsed_ssh_args.tombstone_retention_ms,
        ) catch |err| {
            if (err == error.VersionMismatch) {
                child.closeStdin();
                _ = child.wait() catch {};
                try io.writeAll(2, "sesshmux: new --detached requires a compatible sesshmux agent\n");
                return process_exit.request(1);
            }
            waitAfterRuntimeAttachFailure(&child, "create");
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: ssh runtime create failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        defer created.deinit();
        child.suppressSshStderr();
        try attached_client.ensureLocalRouteForCreatedRemoteSession(
            allocator,
            &created,
            parsed_ssh_args.host,
            parsed_ssh_args.resolved_host,
            parsed_ssh_args.resolved_port,
            parsed_ssh_args.options,
            parsed_ssh_args.tombstone_retention_ms,
        );
        session_registry.markRouteDetachedNow(allocator, created.guid) catch |err| {
            client_log.debug("event=remote_route_detached_mark_failed session={s} error={t}", .{ created.guid, err });
        };
        child.closeStdin();
        _ = child.wait() catch {};
        var created_buf: [128]u8 = undefined;
        const created_line = try std.fmt.bufPrint(&created_buf, "CREATED {s}\n", .{created.guid});
        try io.writeAll(1, created_line);
        return;
    }

    var session = (switch (parsed_ssh_args.action) {
        .new => attached_client.startNewSessionOnRuntime(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            parsed_ssh_args.scrollback_row_count,
            new_guid.?,
            parsed_ssh_args.command_argv,
            shell_command,
            parsed_ssh_args.host,
            parsed_ssh_args.reap_ms,
            parsed_ssh_args.tombstone_retention_ms,
        ),
        .attach => attached_client.startAttachSessionOnRuntime(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            parsed_ssh_args.attach_id orelse "",
            parsed_ssh_args.attach_session_dir,
            parsed_ssh_args.initial_scrollback_row_count,
            parsed_ssh_args.host,
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
            if (parsed_ssh_args.command_argv.len > 0 or shell_command != null) {
                try io.writeAll(2, "sessh: persistent command sessions require a compatible sesshmux agent\n");
                return process_exit.request(1);
            }
            try runRemoteCompat(allocator, parsed_ssh_args.*, .version_mismatch);
        }
        waitAfterRuntimeAttachFailure(&child, "start");
        if (process_exit.is(err)) return err;
        try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(parsed_ssh_args.host);
    child.suppressSshStderr();
    if (parsed_ssh_args.action == .new or parsed_ssh_args.action == .attach) {
        try attached_client.ensureLocalRouteForRemoteSession(
            allocator,
            &session,
            parsed_ssh_args.attach_id orelse "",
            parsed_ssh_args.host,
            parsed_ssh_args.resolved_host,
            parsed_ssh_args.resolved_port,
            parsed_ssh_args.options,
            parsed_ssh_args.tombstone_retention_ms,
        );
    }

    while (true) {
        const end = attached_client.runAttachedClient(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            &session,
            .{ .monitor_connection = true },
        ) catch |err| {
            waitAfterRuntimeAttachFailure(&child, "attached client");
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        var race_existing_connection = false;
        switch (end) {
            .detach => {
                client_log.debug("event=detach host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                child.terminate();
                try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                return;
            },
            .kill_detach => {
                client_log.debug("event=kill_detach host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                route_commands.spawnRemoteKillJsonl(allocator, args[0], parsed_ssh_args.host, parsed_ssh_args.options, &.{session.guidSlice()});
                child.terminate();
                try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                return;
            },
            .kill_wait => {
                client_log.debug("event=kill_wait host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                const killed = try route_commands.runRemoteKillJsonlAndProcess(allocator, args[0], parsed_ssh_args.host, parsed_ssh_args.options, &.{session.guidSlice()}, session.guidSlice());
                child.terminate();
                if (!killed) return process_exit.request(1);
                session.ended_tombstone_details = .{
                    .ended_at_unix_ms = nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                return process_exit.request(0);
            },
            .session_ended => {
                client_log.debug("event=session_ended host={s} session={s}", .{ parsed_ssh_args.host, session.idSlice() });
                const exit_status = try finishEndedRemoteSession(allocator, &child, &session);
                return process_exit.request(exit_status);
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
        var reconnect_ui = try client_ui.ReconnectUi.beginWithPresentation(
            session.viewport_offset,
            reconnectPresentationForFilterLevel(parsed_ssh_args.filter_level),
        );
        var reconnect_ui_active = true;
        defer if (reconnect_ui_active) reconnect_ui.deinit();

        if (race_existing_connection and session.kill_requested) {
            child.terminate();
        } else if (race_existing_connection) {
            switch (try raceExistingConnectionWithReconnect(
                parsed_ssh_args.*,
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
                    session.viewport_offset = try reconnect_ui.clearOverlay();
                    attached_client.repaintRuntimeSession(
                        child.child.stdout.?.handle,
                        child.child.stdin.?.handle,
                        &session,
                    ) catch |err| switch (err) {
                        error.SessionEnded => {
                            const exit_status = try finishEndedRemoteSession(allocator, &child, &session);
                            return process_exit.request(exit_status);
                        },
                        else => return err,
                    };
                    reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    continue;
                },
                .reconnected => |new_child| {
                    child.terminate();
                    child = new_child;
                    session.discardPendingInputAcks();
                    session.viewport_offset = try reconnect_ui.clearOverlay();
                    attached_client.finishReconnectRepaint(child.child.stdout.?.handle, child.child.stdin.?.handle, &session) catch |err| switch (err) {
                        error.SessionEnded => {
                            const exit_status = try finishEndedRemoteSession(allocator, &child, &session);
                            return process_exit.request(exit_status);
                        },
                        else => return err,
                    };
                    reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
                    client_log.debug("event=reconnect_success host={s} session={s} attempt=0", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                    });
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    continue;
                },
                .session_ended => {
                    const exit_status = try finishEndedRemoteSession(allocator, &child, &session);
                    return process_exit.request(exit_status);
                },
                .detach => {
                    child.terminate();
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
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
            const delay_ms = reconnect.delayMs(reconnect_attempt);
            client_log.debug("event=reconnect_wait host={s} session={s} attempt={} delay_ms={}", .{
                parsed_ssh_args.host,
                session.idSlice(),
                reconnect_attempt,
                delay_ms,
            });
            const wait_decision = if (session.kill_requested)
                try reconnect_ui.waitForKillConfirmation(delay_ms)
            else
                try reconnect_ui.waitForReconnect(delay_ms);
            switch (wait_decision) {
                .detach => {
                    client_log.debug("event=reconnect_detach host={s} session={s} attempt={}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                    return;
                },
                .kill_detach => {
                    attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                    client_log.debug("event=reconnect_kill_detach host={s} session={s} attempt={}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                    return;
                },
                .kill_wait => {
                    attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                    client_log.debug("event=reconnect_kill_wait host={s} session={s} attempt={}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                },
                .reconnect_now, .wait_elapsed => {
                    if (session.kill_requested) {
                        client_log.debug("event=kill_reconnect_attempt host={s} session={s} attempt={}", .{
                            parsed_ssh_args.host,
                            session.idSlice(),
                            reconnect_attempt,
                        });
                    } else {
                        client_log.debug("event=reconnect_attempt host={s} session={s} attempt={}", .{
                            parsed_ssh_args.host,
                            session.idSlice(),
                            reconnect_attempt,
                        });
                    }
                },
            }

            if (session.kill_requested) {
                const killed = route_commands.runRemoteKillJsonlAndProcess(
                    allocator,
                    args[0],
                    parsed_ssh_args.host,
                    parsed_ssh_args.options,
                    &.{session.guidSlice()},
                    session.guidSlice(),
                ) catch |err| {
                    client_log.debug("event=kill_failed stage=command host={s} session={s} attempt={} error={t}", .{
                        parsed_ssh_args.host,
                        session.idSlice(),
                        reconnect_attempt,
                        err,
                    });
                    client_log.userDiagnosticInfo("kill failed: command: {t}", .{err});
                    reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                    continue;
                };
                if (killed) {
                    reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    return process_exit.request(0);
                }
                client_log.debug("event=kill_failed stage=command host={s} session={s} attempt={} error=NotKilled", .{
                    parsed_ssh_args.host,
                    session.idSlice(),
                    reconnect_attempt,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            }

            child = startRuntimeConnection(
                allocator,
                parsed_ssh_args.*,
                artifacts,
                remote_command,
                .session_broker,
                broker_args,
                true,
                &reconnect_ui,
                true,
                null,
                null,
            ) catch |err| switch (err) {
                error.ExitRequested => return err,
                error.ReconnectDetached => {
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
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
            attached_client.reconnectSessionOnRuntimeCancellable(
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
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                    return;
                },
                .kill_detach => {
                    attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                    route_commands.spawnRemoteKillJsonl(allocator, args[0], parsed_ssh_args.host, parsed_ssh_args.options, &.{session.guidSlice()});
                    child.terminate();
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, parsed_ssh_args.*, &session);
                    return;
                },
                .kill_wait => {
                    attached_client.recordRuntimeSessionKillRequested(allocator, parsed_ssh_args.host, &session);
                    const killed = try route_commands.runRemoteKillJsonlAndProcess(allocator, args[0], parsed_ssh_args.host, parsed_ssh_args.options, &.{session.guidSlice()}, session.guidSlice());
                    child.terminate();
                    if (!killed) return process_exit.request(1);
                    reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    return process_exit.request(0);
                },
                .reconnect_now, .wait_elapsed => {},
            }

            session.discardPendingInputAcks();
            session.viewport_offset = try reconnect_ui.clearOverlay();
            attached_client.finishReconnectRepaint(
                child.child.stdout.?.handle,
                child.child.stdin.?.handle,
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
            reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
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

fn finishDetachedSshSession(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation, session: *attached_client.RuntimeSession) !void {
    session.restoreAttachedClientEndPresentationForExit();
    attached_client.markRouteDetachedForSession(allocator, session);
    attached_client.removeClientRouteHintForRemoteSession(allocator, session);
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    attached_client.writeDetachOverlayForSessionRef(parsed_ssh_args.overlay_args.slice(), session.idSlice());
    if (session.kill_requested) attached_client.writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
}

fn finishEndedRemoteSession(
    allocator: std.mem.Allocator,
    child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
) !u8 {
    const exit_status = session.endedProcessExitCode();
    session.restoreAttachedClientEndPresentationForExit();
    attached_client.removeClientRouteHintForRemoteSession(allocator, session);
    attached_client.tombstoneLocalRouteForRemoteSession(allocator, session) catch |err| {
        client_log.debug("event=local_tombstone_failed session={s} error={t}", .{ session.idSlice(), err });
    };
    child.closeStdin();
    _ = child.wait() catch {};
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    return exit_status;
}

fn finishReconnectUiForDetach(reconnect_ui: *client_ui.ReconnectUi, active: *bool) void {
    if (!active.*) return;
    _ = reconnect_ui.clearOverlay() catch {};
    reconnect_ui.restoreTitleForDetach();
    reconnect_ui.deinit();
    active.* = false;
}

fn reconnectPresentationForFilterLevel(level: config.FilterLevel) client_ui.ReconnectPresentation {
    return switch (level) {
        .raw => .none,
        .unhygienic => .stderr_plain,
        .hygienic => .title,
        .emulated => .overlay,
    };
}

fn runRemoteCompat(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation, reason: CompatModeReason) !noreturn {
    if (reason == .version_mismatch) {
        try io.writeAll(2, "sessh: existing remote sessh is incompatible; falling back to compat-mode\n");
    }

    const command_script = try remoteCompatCommandScript(allocator, parsed_ssh_args);
    defer allocator.free(command_script);

    const tty_option = compatSshTtyOption(parsed_ssh_args, c.isatty(0) != 0, c.isatty(1) != 0);
    try runRemoteCompatCommandScript(allocator, parsed_ssh_args, command_script, reason, tty_option);
}

fn runRemoteCompatCommandScript(
    allocator: std.mem.Allocator,
    parsed_ssh_args: SessionInvocation,
    command_script: []const u8,
    reason: CompatModeReason,
    tty_option: []const u8,
) !noreturn {
    return runRemoteCompatCommandScriptForTransport(allocator, .{
        .options = parsed_ssh_args.options,
        .host = parsed_ssh_args.host,
        .default_ipqos_option = parsed_ssh_args.default_ipqos_option,
    }, command_script, reason, tty_option);
}

pub fn runRemoteCompatCommandScriptForTransport(
    allocator: std.mem.Allocator,
    transport: CompatTransport,
    command_script: []const u8,
    reason: CompatModeReason,
    tty_option: []const u8,
) !noreturn {
    const remote_command = try shCommand(allocator, command_script);
    defer allocator.free(remote_command);

    const batch_mode = reason == .version_mismatch;
    const extra_options: usize = if (batch_mode) 1 else 0;
    const default_options: usize = if (transport.default_ipqos_option != null) 1 else 0;
    const transport_options = transportSshOptionsLen(transport.options);
    const ssh_argv = try allocator.alloc([]const u8, transport_options + extra_options + default_options + 4);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    var arg_index: usize = 1;
    if (batch_mode) {
        ssh_argv[arg_index] = "-oBatchMode=yes";
        arg_index += 1;
    }
    appendDefaultSshOptions(ssh_argv, &arg_index, transport.default_ipqos_option);
    appendTransportSshOptions(ssh_argv, &arg_index, transport.options);
    ssh_argv[arg_index] = tty_option;
    ssh_argv[arg_index + 1] = transport.host;
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

fn compatSshTtyOption(parsed_ssh_args: SessionInvocation, stdin_is_tty: bool, stdout_is_tty: bool) []const u8 {
    if (parsed_ssh_args.action == .attach and stdin_is_tty and stdout_is_tty) {
        return "-t";
    }
    return "-T";
}

pub fn compatSshTtyOptionForLocalArgs(args: []const []const u8, stdin_is_tty: bool, stdout_is_tty: bool) []const u8 {
    if (!stdin_is_tty or !stdout_is_tty) return "-T";

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--log-level")) {
            i += 1;
            if (i < args.len) i += 1;
            continue;
        }
        return if (std.mem.eql(u8, args[i], "attach")) "-t" else "-T";
    }
    return "-T";
}

fn brokerArgsForAction(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    switch (parsed_ssh_args.action) {
        .new, .attach => {},
        .list => {
            try args.append(allocator, "list");
            if (parsed_ssh_args.host.len > 0) {
                try args.append(allocator, "--host-display");
                try args.append(allocator, parsed_ssh_args.host);
            }
            if (parsed_ssh_args.list_jsonl) {
                try args.append(allocator, "--jsonl");
            }
            if (parsed_ssh_args.list_all) {
                try args.append(allocator, "--all");
            }
            if (parsed_ssh_args.list_client_target) |target| {
                if (parsed_ssh_args.list_client_option_arg) |client_arg| {
                    try args.append(allocator, client_arg);
                    if (std.mem.eql(u8, client_arg, "--client")) {
                        try args.append(allocator, target);
                    }
                } else {
                    try args.append(allocator, "--client");
                    try args.append(allocator, target);
                }
            }
            if (parsed_ssh_args.list_exited) {
                try args.append(allocator, "--exited");
            }
        },
        .kill => {
            try args.append(allocator, "kill");
            if (parsed_ssh_args.kill_jsonl) try args.append(allocator, "--jsonl");
            for (parsed_ssh_args.kill_request_jsons) |request_json| {
                try args.append(allocator, "--request");
                try args.append(allocator, request_json);
            }
            if (parsed_ssh_args.kill_current) {
                try args.append(allocator, "--current");
            } else {
                try args.appendSlice(allocator, parsed_ssh_args.kill_ids);
            }
        },
        .kill_all => {
            try args.append(allocator, "kill");
            if (parsed_ssh_args.kill_jsonl) try args.append(allocator, "--jsonl");
            try args.append(allocator, "--all");
        },
        .detach_client, .repaint_client, .debug_client => {
            try args.append(allocator, switch (parsed_ssh_args.action) {
                .detach_client => "detach",
                .repaint_client => "repaint",
                .debug_client => "debug",
                else => unreachable,
            });
            if (parsed_ssh_args.action == .debug_client) {
                try args.append(allocator, switch (parsed_ssh_args.debug_client_action.?) {
                    .sever_connection => "sever-connection",
                    .unresponsive_connection => "unresponsive-connection",
                });
            }
            switch (parsed_ssh_args.client_target) {
                .default => {},
                .all => try args.append(allocator, "--all"),
                .last_input => try args.append(allocator, "--last-input"),
                .client_guid => try args.append(allocator, parsed_ssh_args.client_guid.?),
            }
            if (parsed_ssh_args.client_repaint_scrollback) {
                try args.append(allocator, "--scrollback");
            }
            if (parsed_ssh_args.debug_unresponsive_seconds) |seconds| {
                try args.append(allocator, "--seconds");
                try args.append(allocator, seconds);
            }
            if (parsed_ssh_args.client_session_ref) |session_ref| {
                try args.append(allocator, session_ref);
            }
        },
    }
    return args.toOwnedSlice(allocator);
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

fn showClientBootstrapStatus(visible: *bool, reconnect_ui: ?*client_ui.ReconnectUi) !void {
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

fn remoteCompatCommandScript(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation) ![]u8 {
    const local_args = try localCompatArgs(allocator, parsed_ssh_args);
    defer allocator.free(local_args);
    const action = compatActionName(parsed_ssh_args.action);
    const session_id = compatSessionId(parsed_ssh_args) orelse "";
    return remoteCompatCommandScriptFor(allocator, action, session_id, local_args);
}

pub fn remoteCompatCommandScriptFor(
    allocator: std.mem.Allocator,
    action: []const u8,
    session_id: []const u8,
    local_args: []const u8,
) ![]u8 {
    const client_version = try shellQuote(allocator, config.version);
    defer allocator.free(client_version);
    const action_quoted = try shellQuote(allocator, action);
    defer allocator.free(action_quoted);
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
        \\resolve_session_prefix() {{
        \\  prefix=$(printf '%s' "$1" | tr 'ABCDEF' 'abcdef')
        \\  match=
        \\  for base in "$runtime_root" "$state_root"; do
        \\    [ -n "$base" ] || continue
        \\    for dir in "$base"/guid/s-*; do
        \\      [ -d "$dir" ] || continue
        \\      name=$(basename "$dir")
        \\      compact=$(compact_session_id "$name" | tr 'ABCDEF' 'abcdef')
        \\      case "$compact" in
        \\        "$prefix"*) ;;
        \\        *) continue ;;
        \\      esac
        \\      if [ -n "$match" ] && [ "$match" != "$name" ]; then
        \\        printf 'sesshmux: session id is ambiguous\n' >&2
        \\        exit 1
        \\      fi
        \\      match=$name
        \\    done
        \\  done
        \\  if [ -n "$match" ]; then
        \\    printf '%s\n' "$match"
        \\    return
        \\  fi
        \\  canonical_session_id "$1"
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
        \\  if [ ${{#compact}} -gt 0 ] && [ ${{#compact}} -lt 32 ]; then
        \\    case "$compact" in
        \\      *[!0123456789abcdefABCDEF]*) ;;
        \\      *) resolve_session_prefix "$compact"; return ;;
        \\    esac
        \\  fi
        \\  case "$ref" in
        \\    ""|/*|*/*|.|..) canonical_session_id "$compact"; return ;;
        \\  esac
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
        \\  session_guid=$(basename "$(dirname "$compat")")
        \\  compat_target=$compat
        \\  if [ -L "$compat" ]; then
        \\    compat_target=$(readlink "$compat") || exit 1
        \\  fi
        \\  case "$(basename "$compat_target")" in
        \\    # sesshmux owns the public mux command parser, so give it the
        \\    # command directly. Older combined sessh-style compat binaries
        \\    # still need "." to force a local route.
        \\    sesshmux*) XDG_RUNTIME_DIR=$runtime_root SESSH_GUID="$session_guid" SESSH_CLIENT_VERSION={s} SESSH_COMPAT=1 exec "$compat"{s} ;;
        \\    *) XDG_RUNTIME_DIR=$runtime_root SESSH_GUID="$session_guid" SESSH_CLIENT_VERSION={s} SESSH_COMPAT=1 exec "$compat" .{s} ;;
        \\  esac
        \\}}
        \\run_one_compat() {{
        \\  compat=$1
        \\  session_guid=$(basename "$(dirname "$compat")")
        \\  compat_target=$compat
        \\  if [ -L "$compat" ]; then
        \\    compat_target=$(readlink "$compat") || exit 1
        \\  fi
        \\  case "$(basename "$compat_target")" in
        \\    # sesshmux owns the public mux command parser, so give it the
        \\    # command directly. Older combined sessh-style compat binaries
        \\    # still need "." to force a local route.
        \\    sesshmux*) XDG_RUNTIME_DIR=$runtime_root SESSH_GUID="$session_guid" SESSH_CLIENT_VERSION={s} SESSH_COMPAT=1 "$compat"{s} ;;
        \\    *) XDG_RUNTIME_DIR=$runtime_root SESSH_GUID="$session_guid" SESSH_CLIENT_VERSION={s} SESSH_COMPAT=1 "$compat" .{s} ;;
        \\  esac
        \\}}
        \\run_each_compat() {{
        \\  found=0
        \\  status=0
        \\  for compat in "$runtime_root"/guid/*/compat; do
        \\    [ -e "$compat" ] || continue
        \\    found=1
        \\    run_one_compat "$compat"
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
        \\  force-compat)
        \\    if [ -z "$compat_session_id" ]; then
        \\      printf 'sesshmux: force-compat requires a session id\n' >&2
        \\      exit 64
        \\    fi
        \\    compat_session_id=$(resolve_session_ref "$compat_session_id")
        \\    exec_one_compat "$runtime_root/guid/$compat_session_id/compat"
        \\    ;;
        \\  attach)
        \\    if [ -z "$compat_session_id" ]; then
        \\      compat_session_id=$(find_latest_session_id)
        \\    fi
        \\    compat_session_id=$(resolve_session_ref "$compat_session_id")
        \\    exec_one_compat "$runtime_root/guid/$compat_session_id/compat"
        \\    ;;
        \\  kill)
        \\    if [ -z "$compat_session_id" ]; then
        \\      compat_session_id=${{SESSH_GUID:-}}
        \\    fi
        \\    if [ -z "$compat_session_id" ]; then
        \\      printf 'sesshmux: --current requires $SESSH_GUID\n' >&2
        \\      exit 64
        \\    fi
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
        client_version,
        local_args,
        client_version,
        local_args,
        client_version,
        local_args,
        client_version,
        local_args,
    });
}

fn compatActionName(action: SessionAction) []const u8 {
    return switch (action) {
        .new => "new",
        .attach => "attach",
        .list => "list",
        .kill => "kill",
        .kill_all => "kill-all",
        .detach_client, .repaint_client, .debug_client => "client-command",
    };
}

fn compatSessionId(parsed_ssh_args: SessionInvocation) ?[]const u8 {
    return switch (parsed_ssh_args.action) {
        .attach => parsed_ssh_args.attach_id,
        .kill => if (parsed_ssh_args.kill_ids.len == 1) parsed_ssh_args.kill_ids[0] else parsed_ssh_args.kill_id,
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => null,
    };
}

fn localCompatArgs(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation) ![]u8 {
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
            if (parsed_ssh_args.kill_ids.len > 0) {
                if (parsed_ssh_args.kill_ids.len != 1) return error.UnsupportedCompatCommand;
                try appendCompatArg(allocator, &out, parsed_ssh_args.kill_ids[0]);
            } else if (parsed_ssh_args.kill_current) {
                try appendCompatArg(allocator, &out, "--current");
            } else {
                return error.MissingKillTarget;
            }
        },
        .kill_all => {
            try appendCompatArg(allocator, &out, "kill");
            try appendCompatArg(allocator, &out, "--all");
        },
        .detach_client, .repaint_client, .debug_client => return error.UnsupportedCompatCommand,
    }

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

fn applyFileConfigToSsh(allocator: std.mem.Allocator, parsed: *SessionInvocation) !void {
    const file_config = try client_config.loadFileConfig(allocator);
    if (!parsed.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| parsed.scrollback_row_count = count;
    }
    if (!parsed.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        parsed.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (!parsed.bootstrap_set) {
        if (file_config.bootstrap) |enabled| parsed.bootstrap = enabled;
    }
    if (!parsed.terminal_emulator_set) {
        if (file_config.terminal_emulator) |enabled| parsed.terminal_emulator = enabled;
    }
    if (!parsed.filter_level_set) {
        if (file_config.filter_level) |level| parsed.filter_level = level;
    }
    if (file_config.reap_ms) |ms| parsed.reap_ms = ms;
    if (file_config.tombstone_retention_ms) |ms| parsed.tombstone_retention_ms = ms;
    if (!parsed.client_log_level_set) {
        if (file_config.client_log_level) |level| {
            parsed.client_log_level = level;
        } else {
            parsed.client_log_level = inferredClientLogLevel(parsed.options);
        }
    }
}

// Local mux commands have no ssh transport, so ssh-only config such as
// `terminal-emulator` and `filter-level` must not change their execution path.
// Apply only the fields that already make sense for local mux sessions.
fn applyFileConfigToLocalMux(allocator: std.mem.Allocator, parsed: *SessionInvocation) !void {
    const file_config = try client_config.loadFileConfig(allocator);
    if (!parsed.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| parsed.scrollback_row_count = count;
    }
    if (!parsed.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        parsed.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (file_config.reap_ms) |ms| parsed.reap_ms = ms;
    if (file_config.tombstone_retention_ms) |ms| parsed.tombstone_retention_ms = ms;
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

pub const ResolvedSshConfig = struct {
    hostname: []u8,
    port: []u8,
    ipqos: ?[]u8 = null,

    pub fn deinit(self: *ResolvedSshConfig, allocator: std.mem.Allocator) void {
        if (self.ipqos) |value| allocator.free(value);
        allocator.free(self.port);
        allocator.free(self.hostname);
        self.* = undefined;
    }

    pub fn defaultIpQosOption(self: *const ResolvedSshConfig, allocator: std.mem.Allocator) !?[]u8 {
        const value = self.ipqos orelse return null;
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ default_ipqos_option_prefix, value });
    }
};

pub fn resolveSshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) !ResolvedSshConfig {
    const output = querySshConfig(allocator, ssh_options, host) catch |err| {
        client_log.debug("event=ssh_config_query_failed host={s} error={t}", .{ host, err });
        return fallbackResolvedSshConfig(allocator, ssh_options, host);
    };
    defer allocator.free(output);
    return parseSshConfig(allocator, output, ssh_options, host) catch |err| {
        client_log.debug("event=ssh_config_parse_failed host={s} error={t}", .{ host, err });
        return fallbackResolvedSshConfig(allocator, ssh_options, host);
    };
}

fn fallbackResolvedSshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) !ResolvedSshConfig {
    const explicit_port = explicitSshPort(ssh_options) orelse session_registry.default_pending_port;
    return .{
        .hostname = try allocator.dupe(u8, host),
        .port = try allocator.dupe(u8, explicit_port),
        .ipqos = null,
    };
}

fn querySshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) ![]u8 {
    const transport_options = transportSshOptionsLen(ssh_options);
    const argv = try allocator.alloc([]const u8, transport_options + 3);
    defer allocator.free(argv);
    argv[0] = "ssh";
    var arg_index: usize = 1;
    appendTransportSshOptions(argv, &arg_index, ssh_options);
    argv[arg_index] = "-G";
    argv[arg_index + 1] = host;

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
    return try allocator.dupe(u8, result.stdout);
}

fn parseSshConfig(allocator: std.mem.Allocator, output: []const u8, ssh_options: []const []const u8, fallback_host: []const u8) !ResolvedSshConfig {
    var hostname: ?[]u8 = null;
    var port: ?[]u8 = null;
    var ipqos: ?[]u8 = null;
    errdefer {
        if (hostname) |value| allocator.free(value);
        if (port) |value| allocator.free(value);
        if (ipqos) |value| allocator.free(value);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = fields.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(key, "hostname")) {
            const value = fields.next() orelse continue;
            if (hostname) |old| allocator.free(old);
            hostname = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "port")) {
            const value = fields.next() orelse continue;
            if (!isValidSshPort(value)) continue;
            if (port) |old| allocator.free(old);
            port = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "ipqos")) {
            const interactive = fields.next() orelse continue;
            if (ipqos) |old| allocator.free(old);
            ipqos = try allocator.dupe(u8, interactive);
        }
    }
    if (hostname == null) hostname = try allocator.dupe(u8, fallback_host);
    if (port == null) {
        const explicit_port = explicitSshPort(ssh_options) orelse session_registry.default_pending_port;
        port = try allocator.dupe(u8, explicit_port);
    }
    return .{
        .hostname = hostname.?,
        .port = port.?,
        .ipqos = ipqos,
    };
}

fn explicitSshPort(ssh_options: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < ssh_options.len) : (i += 1) {
        const option = ssh_options[i];
        if (std.mem.eql(u8, option, "-p")) {
            if (i + 1 < ssh_options.len and isValidSshPort(ssh_options[i + 1])) return ssh_options[i + 1];
            continue;
        }
        if (std.mem.startsWith(u8, option, "-p") and option.len > 2) {
            const value = option[2..];
            if (isValidSshPort(value)) return value;
            continue;
        }
        if (std.mem.eql(u8, option, "-o")) {
            if (i + 1 < ssh_options.len) {
                if (sshConfigOptionValue(ssh_options[i + 1], "Port")) |value| {
                    if (isValidSshPort(value)) return value;
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, option, "-o") and option.len > 2) {
            if (sshConfigOptionValue(option[2..], "Port")) |value| {
                if (isValidSshPort(value)) return value;
            }
        }
    }
    return null;
}

fn isValidSshPort(value: []const u8) bool {
    if (value.len == 0) return false;
    const port = std.fmt.parseInt(u16, value, 10) catch return false;
    return port != 0;
}

fn sshConfigOptionValue(raw_option: []const u8, expected_key: []const u8) ?[]const u8 {
    const key = sshConfigKey(raw_option);
    if (!std.ascii.eqlIgnoreCase(key, expected_key)) return null;
    var value_start = key.len;
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
    if (value_start >= raw_option.len) return null;
    return raw_option[value_start..];
}

fn raceExistingConnectionWithReconnect(
    parsed_ssh_args: SessionInvocation,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    old_child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    reconnect_ui.showUnresponsiveReconnectInProgressTitle();
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
                const delay_ms = reconnect.delayMs(reconnect_attempt);
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
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    delay_ms: u64,
) !?ReconnectRaceOutcome {
    var timer = try std.time.Timer.start();
    while (true) {
        const elapsed_ms = @divTrunc(timer.read(), std.time.ns_per_ms);
        if (elapsed_ms >= delay_ms) return null;

        if (try attached_client.pollRuntimeRecovery(old_child.child.stdout.?.handle, session, 0)) |recovery| {
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
        switch (try attached_client.pollAndForwardReconnectInput(
            old_child.child.stdout.?.handle,
            old_child.child.stdin.?.handle,
            session,
            reconnect_ui,
            poll_ms,
        )) {
            .wait_elapsed => {},
            .detach => return .detach,
            .kill_detach => return .detach,
            .kill_wait => return null,
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
    parsed_ssh_args: SessionInvocation,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    broker_args: []const []const u8,
    old_child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    session.viewport_offset = reconnect_ui.currentViewportOffset();
    var state = ParallelReconnectState{
        .parsed_ssh_args = parsed_ssh_args,
        .artifacts = artifacts,
        .remote_command = remote_command,
        .bootstrap_entrypoint = .session_broker,
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
    var ready_session = attached_client.RuntimeSession{};

    var old_available = true;
    while (true) {
        if (ready_connection == null and state.isDone()) {
            joined = true;
            thread.join();
            switch (state.take().?) {
                .ready => |connection| {
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
                            parsed_ssh_args.host,
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
            if (try attached_client.pollRuntimeRecovery(old_child.child.stdout.?.handle, session, 0)) |recovery| {
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
                                parsed_ssh_args.host,
                            );
                        }
                        try reconnect_ui.showDisconnectedReconnectInProgress();
                    },
                }
            }
            if (old_available) {
                switch (try attached_client.pollAndForwardReconnectInput(
                    old_child.child.stdout.?.handle,
                    old_child.child.stdin.?.handle,
                    session,
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
                    .kill_detach => {
                        attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, parsed_ssh_args.host, session);
                        reconnect_ui.cancel();
                        if (!joined) {
                            joined = true;
                            thread.join();
                            cleanupParallelReconnectResult(&state);
                        }
                        return .detach;
                    },
                    .kill_wait => {
                        attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, parsed_ssh_args.host, session);
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
                                parsed_ssh_args.host,
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
                .kill_detach => {
                    attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, parsed_ssh_args.host, session);
                    reconnect_ui.cancel();
                    if (!joined) {
                        joined = true;
                        thread.join();
                        cleanupParallelReconnectResult(&state);
                    }
                    return .detach;
                },
                .kill_wait => {
                    attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, parsed_ssh_args.host, session);
                    if (ready_connection) |connection| {
                        ready_connection = null;
                        return .{ .reconnected = connection };
                    }
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
    ready_session: *attached_client.RuntimeSession,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
    host: []const u8,
) !ReconnectRaceOutcome {
    switch (try waitForReconnectSwitchIfNeeded(
        reconnect_ui,
        pending_input_at_disconnect,
        pending_paste_like_input_at_disconnect,
        false,
    )) {
        .detach => return .detach,
        .kill_detach => {
            attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, host, session);
            return .detach;
        },
        .kill_wait => attached_client.recordRuntimeSessionKillRequested(std.heap.smp_allocator, host, session),
        .reconnect_now, .wait_elapsed => {},
    }
    return attachReadyReconnectConnection(ready_connection, ready_session, session, reconnect_ui);
}

fn attachReadyReconnectConnection(
    ready_connection: *?RuntimeConnection,
    ready_session: *attached_client.RuntimeSession,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
) !ReconnectRaceOutcome {
    var connection = ready_connection.* orelse return .{ .failed = error.ReconnectNotReady };
    ready_connection.* = null;

    attached_client.attachPreparedReconnectRuntimeCancellable(
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
        state.bootstrap_entrypoint,
        state.broker_args,
        true,
        state.reconnect_ui,
        false,
        null,
        null,
    ) catch |err| {
        state.store(.{ .failed = err });
        return;
    };

    // Stop after Hello while racing an unresponsive transport. SessionAttach
    // would replace the still-visible old attached client before the user presses
    // Ctrl-R to switch.
    attached_client.prepareReconnectRuntimeCancellable(
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

    state.store(.{ .ready = connection });
}

fn cleanupParallelReconnectResult(state: *ParallelReconnectState) void {
    var result = state.take() orelse return;
    switch (result) {
        .ready => |*connection| connection.terminate(),
        .failed => {},
    }
}

fn waitForReconnectSwitchIfNeeded(
    reconnect_ui: *client_ui.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
    unresponsive: bool,
) !client_ui.ReconnectDecision {
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

fn nextReconnectAttemptAfterFailure(attempt: usize, reconnect_ui: *client_ui.ReconnectUi) usize {
    return reconnect.nextAttempt(attempt, reconnect_ui.consumeReconnectAcknowledgement());
}

fn defaultSshOptionsLen(parsed_ssh_args: SessionInvocation) usize {
    return if (parsed_ssh_args.default_ipqos_option == null) 0 else 1;
}

fn appendDefaultSshOptions(ssh_argv: [][]const u8, arg_index: *usize, default_ipqos_option: ?[]const u8) void {
    if (default_ipqos_option) |option| {
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
    }
}

fn transportSshOptionsLen(options: []const []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < options.len) : (i += 1) {
        const option = options[i];
        if (isSshTtyRequestOption(option)) continue;
        len += 1;
        if (sshOptionSeparateValueIndex(options, i)) |value_index| {
            len += 1;
            i = value_index;
        }
    }
    return len;
}

// The runtime transport always uses `ssh -T` because sessh owns the PTY
// protocol. User-provided `-t`/`-tt` only decides whether ssh-shaped remote
// command args are accepted, so those options must not be forwarded to the
// transport ssh invocation.
fn appendTransportSshOptions(ssh_argv: [][]const u8, arg_index: *usize, options: []const []const u8) void {
    var i: usize = 0;
    while (i < options.len) : (i += 1) {
        const option = options[i];
        if (isSshTtyRequestOption(option)) continue;
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
        if (sshOptionSeparateValueIndex(options, i)) |value_index| {
            ssh_argv[arg_index.*] = options[value_index];
            arg_index.* += 1;
            i = value_index;
        }
    }
}

fn sshOptionSeparateValueIndex(options: []const []const u8, index: usize) ?usize {
    const arg = options[index];
    if (arg.len < 2 or arg[0] != '-' or std.mem.startsWith(u8, arg, "--")) return null;
    var pos: usize = 1;
    while (pos < arg.len) : (pos += 1) {
        if (!sshOptionConsumesValueForHostScan(arg[pos])) continue;
        return if (pos + 1 < arg.len or index + 1 >= options.len) null else index + 1;
    }
    return null;
}

fn startRuntimeConnection(
    allocator: std.mem.Allocator,
    parsed_ssh_args: SessionInvocation,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    bootstrap_entrypoint: BootstrapEntrypoint,
    broker_args: []const []const u8,
    batch_mode: bool,
    reconnect_ui: ?*client_ui.ReconnectUi,
    poll_reconnect_input: bool,
    stderr_mode_override: ?SshStderrMode,
    bootstrap_failure_term: ?*?std.process.Child.Term,
) !RuntimeConnection {
    if (bootstrap_failure_term) |term| term.* = null;
    const reconnect_options: usize = if (batch_mode) 1 else 0;
    const default_options = defaultSshOptionsLen(parsed_ssh_args);
    const transport_options = transportSshOptionsLen(parsed_ssh_args.options);
    const ssh_argv = try allocator.alloc([]const u8, transport_options + reconnect_options + default_options + 4);
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
    appendTransportSshOptions(ssh_argv, &arg_index, parsed_ssh_args.options);
    ssh_argv[arg_index] = "-T";
    ssh_argv[arg_index + 1] = parsed_ssh_args.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var connection = RuntimeConnection{ .child = child };
    const stderr_file = connection.child.stderr.?;
    connection.child.stderr = null;
    const stderr_mode = stderr_mode_override orelse if (reconnect_ui == null) SshStderrMode.forward else SshStderrMode.diagnostics;
    connection.stderr_pump = SshStderrPump.start(allocator, stderr_file, stderr_mode) catch |err| {
        connection.terminate();
        return err;
    };

    const artifact_set = artifacts orelse return connection;

    artifact_set.sendExec(connection.child.stdin.?.handle, bootstrap_entrypoint, broker_args, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.closeStdin();
        if (err == error.ReconnectDetached) {
            connection.terminate();
            return err;
        }
        const term = connection.wait() catch null;
        if (bootstrap_failure_term) |term_out| term_out.* = term;
        return err;
    };

    var line = readBootstrapLine(allocator, connection.child.stdout.?.handle, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.closeStdin();
        if (err == error.ReconnectDetached) {
            connection.terminate();
            return err;
        }
        const term = connection.wait() catch null;
        if (bootstrap_failure_term) |term_out| term_out.* = term;
        if (batch_mode) {
            return err;
        }
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
            const term = connection.wait() catch null;
            if (bootstrap_failure_term) |term_out| term_out.* = term;
            if (batch_mode) {
                return err;
            }
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
    parsed_ssh_args: SessionInvocation,
    batch_mode: bool,
    reconnect_ui: ?*client_ui.ReconnectUi,
) bool {
    return parsed_ssh_args.action == .new and
        parsed_ssh_args.command_argv.len == 0 and
        parsed_ssh_args.shell_command_args.len == 0 and
        !batch_mode and
        reconnect_ui == null;
}

fn shouldUseStreamPath(parsed_ssh_args: SessionInvocation, stdin_is_tty: bool) bool {
    if (parsed_ssh_args.action != .new) return false;
    if (parsed_ssh_args.command_argv.len != 0) return false;
    if (!parsed_ssh_args.terminal_emulator) return true;
    if (!hasRemoteShellCommand(parsed_ssh_args.shell_command_args)) return false;

    // Match ssh's PTY allocation rules for remote commands. Plain
    // `ssh HOST command` does not allocate a remote tty even when local stdin is
    // a tty, so it uses the stream path. `-t` only requests a remote tty when
    // local stdin is a tty. `-tt` with local stdin still uses sessh's normal
    // terminal-emulator session path; without local stdin it stays on the
    // stream path and lets the visible outer ssh allocate the PTY.
    return switch (parsed_ssh_args.tty_request) {
        .none => true,
        .requested => !stdin_is_tty,
        .forced => !stdin_is_tty,
    };
}

const StreamClientTransport = struct {
    connection: RuntimeConnection,

    pub fn readFd(self: *const StreamClientTransport) c.fd_t {
        return self.connection.child.stdout.?.handle;
    }

    pub fn writeFd(self: *const StreamClientTransport) c.fd_t {
        return self.connection.child.stdin.?.handle;
    }

    pub fn close(self: *StreamClientTransport) void {
        self.connection.closeStdin();
        _ = self.connection.wait() catch {};
    }

    pub fn terminate(self: *StreamClientTransport) void {
        self.connection.terminate();
    }
};

const StreamClientStarter = struct {
    allocator: std.mem.Allocator,
    parsed_ssh_args: SessionInvocation,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    bootstrap_entrypoint: BootstrapEntrypoint,
    broker_args: []const []const u8,
    stderr_mode: SshStderrMode,
    last_failure_mutex: std.Thread.Mutex = .{},
    last_failure_term: ?std.process.Child.Term = null,

    pub fn start(self: *StreamClientStarter) !StreamClientTransport {
        self.recordFailureTerm(null);
        var failure_term: ?std.process.Child.Term = null;
        const connection = startRuntimeConnection(
            self.allocator,
            self.parsed_ssh_args,
            self.artifacts,
            self.remote_command,
            self.bootstrap_entrypoint,
            self.broker_args,
            true,
            null,
            false,
            self.stderr_mode,
            &failure_term,
        ) catch |err| {
            self.recordFailureTerm(failure_term);
            return err;
        };
        return .{ .connection = connection };
    }

    pub fn exitAfterInitialFailure(self: *StreamClientStarter, err: anyerror) !void {
        const term = self.takeFailureTerm();
        if (term) |value| {
            switch (value) {
                .Exited => |code| {
                    if (code != 0) return process_exit.request(code);
                    return err;
                },
                .Signal => return process_exit.request(255),
                else => return process_exit.request(255),
            }
        }
        return err;
    }

    fn recordFailureTerm(self: *StreamClientStarter, term: ?std.process.Child.Term) void {
        self.last_failure_mutex.lock();
        self.last_failure_term = term;
        self.last_failure_mutex.unlock();
    }

    fn takeFailureTerm(self: *StreamClientStarter) ?std.process.Child.Term {
        self.last_failure_mutex.lock();
        defer self.last_failure_mutex.unlock();
        const term = self.last_failure_term;
        self.last_failure_term = null;
        return term;
    }
};

fn proxyStreamReconnectStatusMode(level: config.FilterLevel, has_client_socket: bool) stream_agent.StreamReconnectStatusMode {
    return switch (level) {
        .raw => .disabled,
        .unhygienic => .stderr_plain,
        .hygienic, .emulated => if (has_client_socket) .client_control else .stderr_plain,
    };
}

fn filterLevelForcesProxy(level: config.FilterLevel) bool {
    return switch (level) {
        .raw, .unhygienic, .hygienic => true,
        .emulated => false,
    };
}

fn shouldUseProxyStream(parsed_ssh_args: SessionInvocation, stdin_is_tty: bool) bool {
    if (parsed_ssh_args.action != .new) return false;
    if (parsed_ssh_args.command_argv.len != 0) return false;
    if (filterLevelForcesProxy(parsed_ssh_args.filter_level) or parsed_ssh_args.proxy_required) return true;
    if (!hasRemoteShellCommand(parsed_ssh_args.shell_command_args)) return !parsed_ssh_args.terminal_emulator;
    return shouldUseStreamPath(parsed_ssh_args, stdin_is_tty);
}

fn hasRemoteShellCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    if (args.len > 1) return true;
    return args[0].len > 0;
}

// Proxy stream mode is for SSH features that OpenSSH must own directly, such
// as X11, agent forwarding, port forwarding, subsystems, and non-tty commands.
// The visible outer `ssh` process gets the user's original options plus a
// ProxyCommand. That ProxyCommand is a local sessh process that reconnects a
// byte-clean stream to a remote stream agent, and the remote stream agent then
// opens a TCP connection to sshd on the remote machine.
fn runProxyStreamSsh(allocator: std.mem.Allocator, exe: []const u8, parsed_ssh_args: SessionInvocation) !noreturn {
    const diagnostics_plan = proxyDiagnosticsPlan(
        parsed_ssh_args,
        c.isatty(0) != 0,
        c.isatty(1) != 0,
    );
    var client_socket_guid: ?[]u8 = null;
    defer if (client_socket_guid) |guid| allocator.free(guid);
    var client_socket_allocation: ?session_registry.SocketPathAllocation = null;
    defer if (client_socket_allocation) |*allocation| allocation.deinit(allocator);
    var client_socket_listen_fd: c.fd_t = -1;
    defer if (client_socket_listen_fd >= 0) posix.close(client_socket_listen_fd);
    if (diagnostics_plan.use_client_socket) {
        const runtime_root = try socket_transport.runtimeRoot(allocator);
        defer allocator.free(runtime_root);
        client_socket_guid = try session_registry.generateProxyGuid(allocator);
        client_socket_allocation = try session_registry.allocateClientSocketPathForGuidInRoot(allocator, runtime_root, client_socket_guid.?);
        client_socket_listen_fd = try socket_transport.listenSocket(client_socket_allocation.?.path);
    }
    defer if (client_socket_allocation) |allocation| {
        std.fs.deleteFileAbsolute(allocation.path) catch {};
    };

    const proxy_command_option = try proxyCommandOption(
        allocator,
        exe,
        parsed_ssh_args,
        if (client_socket_allocation) |allocation| allocation.path else null,
        diagnostics_plan.command_level,
        diagnostics_plan.client_ctrl_r,
    );
    defer allocator.free(proxy_command_option);

    const default_options = defaultSshOptionsLen(parsed_ssh_args);
    const ssh_arg_count = 1 + default_options + parsed_ssh_args.options.len + 1 + parsed_ssh_args.shell_command_args.len;
    const ssh_args = try allocator.alloc([]const u8, ssh_arg_count);
    defer allocator.free(ssh_args);

    var index: usize = 0;
    // Put sessh's ProxyCommand first. OpenSSH gives command-line options high
    // precedence, and this keeps a user/config ProxyCommand available to the
    // inner bootstrap ssh while ensuring the outer ssh talks over our stream.
    ssh_args[index] = proxy_command_option;
    index += 1;
    appendDefaultSshOptions(ssh_args, &index, parsed_ssh_args.default_ipqos_option);
    @memcpy(ssh_args[index .. index + parsed_ssh_args.options.len], parsed_ssh_args.options);
    index += parsed_ssh_args.options.len;
    ssh_args[index] = parsed_ssh_args.host;
    index += 1;
    @memcpy(ssh_args[index..], parsed_ssh_args.shell_command_args);

    if (diagnostics_plan.wrap_visible_ssh and client_socket_listen_fd >= 0) {
        try runPlainSshArgvUnderLocalPty(allocator, ssh_args, client_socket_listen_fd, diagnostics_plan.client_ctrl_r, "proxy-stream");
    }
    if (diagnostics_plan.use_client_socket and client_socket_listen_fd >= 0) {
        try runPlainSshArgvWithDiagnosticsThread(allocator, ssh_args, client_socket_listen_fd, "proxy-stream");
    }
    try runPlainSshArgv(allocator, ssh_args, "proxy-stream");
}

const ProxyDiagnosticsPlan = struct {
    command_level: config.FilterLevel,
    use_client_socket: bool,
    wrap_visible_ssh: bool,
    client_ctrl_r: bool,
};

fn proxyDiagnosticsPlan(parsed_ssh_args: SessionInvocation, stdin_is_tty: bool, stdout_is_tty: bool) ProxyDiagnosticsPlan {
    return switch (parsed_ssh_args.filter_level) {
        .raw => .{
            .command_level = .raw,
            .use_client_socket = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .unhygienic => .{
            .command_level = .unhygienic,
            .use_client_socket = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!stdout_is_tty) break :blk .{
                .command_level = .unhygienic,
                .use_client_socket = false,
                .wrap_visible_ssh = false,
                .client_ctrl_r = false,
            };
            const wrap_visible_ssh = outerSshAllocatesTty(parsed_ssh_args, stdin_is_tty);
            break :blk .{
                .command_level = .hygienic,
                .use_client_socket = true,
                .wrap_visible_ssh = wrap_visible_ssh,
                .client_ctrl_r = wrap_visible_ssh and stdin_is_tty,
            };
        },
    };
}

fn outerSshAllocatesTty(parsed_ssh_args: SessionInvocation, stdin_is_tty: bool) bool {
    const explicit = explicitTtyRequest(parsed_ssh_args.options);
    if (explicit) |request| return switch (request) {
        .none => false,
        .requested => stdin_is_tty,
        .forced => true,
    };
    return switch (parsed_ssh_args.tty_request) {
        .none => stdin_is_tty and parsed_ssh_args.shell_command_args.len == 0,
        .requested => stdin_is_tty,
        .forced => true,
    };
}

fn explicitTtyRequest(options: []const []const u8) ?SshTtyRequest {
    var result: ?SshTtyRequest = null;
    var i: usize = 0;
    while (i < options.len) {
        const arg = options[i];
        if (std.mem.startsWith(u8, arg, "--") or arg.len < 2 or arg[0] != '-') {
            i += 1;
            continue;
        }
        var pos: usize = 1;
        while (pos < arg.len) {
            const option = arg[pos];
            if (option == 'T') {
                result = .none;
                pos += 1;
                continue;
            }
            if (option == 't') {
                if (result != null and result.? == .requested) {
                    result = .forced;
                } else if (result == null or result.? != .forced) {
                    result = .requested;
                }
                pos += 1;
                continue;
            }
            if (option == 'o') {
                const value = optionValueFromOptions(options, i, pos) orelse return result;
                if (sshConfigKeyIs(value, "RequestTTY")) {
                    const key = sshConfigKey(value);
                    if (sshConfigValueIs(value, key.len, "no")) {
                        result = .none;
                    } else if (sshConfigValueIs(value, key.len, "force")) {
                        result = .forced;
                    } else if (sshConfigValueIs(value, key.len, "yes")) {
                        result = .requested;
                    }
                }
                i = if (pos + 1 < arg.len) i + 1 else i + 2;
                break;
            }
            if (sshOptionRequiresValue(option) or isUnsafeSshOptionWithValue(option) or isProxyRequiredSshOptionWithValue(option)) {
                i = if (pos + 1 < arg.len) i + 1 else i + 2;
                break;
            }
            pos += 1;
        } else {
            i += 1;
        }
    }
    return result;
}

fn proxyCommandOption(
    allocator: std.mem.Allocator,
    exe: []const u8,
    parsed_ssh_args: SessionInvocation,
    client_socket: ?[]const u8,
    filter_level: config.FilterLevel,
    client_ctrl_r: bool,
) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try appendShellToken(allocator, &command, exe);
    try appendShellToken(allocator, &command, ":internal-proxy-stream:");
    try appendShellToken(allocator, &command, "--host");
    // Use the original host token so the inner ssh sees the same Host block.
    // `%h` is already resolved to HostName and can lose alias-scoped options.
    try appendShellToken(allocator, &command, "%n");
    try appendShellToken(allocator, &command, "--port");
    try appendShellToken(allocator, &command, "%p");
    try appendShellToken(allocator, &command, "--user");
    try appendShellToken(allocator, &command, "%r");
    try appendShellToken(allocator, &command, "--filter-level");
    try appendShellToken(allocator, &command, filter_level.label());
    if (client_socket) |path| {
        try appendShellToken(allocator, &command, "--client-socket");
        try appendShellToken(allocator, &command, path);
        try appendShellToken(allocator, &command, "--client-ctrl-r");
        try appendShellToken(allocator, &command, if (client_ctrl_r) "1" else "0");
    }
    try appendProxyTransportSshOptions(allocator, &command, parsed_ssh_args.options);

    return std.fmt.allocPrint(allocator, "-oProxyCommand={s}", .{command.items});
}

fn appendProxyTransportSshOptions(
    allocator: std.mem.Allocator,
    command: *std.ArrayList(u8),
    options: []const []const u8,
) !void {
    var i: usize = 0;
    while (i < options.len) {
        const value_index = sshOptionSeparateValueIndex(options, i);
        if (isSshTtyRequestOption(options[i])) {
            i += 1;
            continue;
        }
        if (sshOptionRequiresOuterProxy(options, i)) {
            i = if (value_index) |index| index + 1 else i + 1;
            continue;
        }

        try appendShellToken(allocator, command, "--ssh-option");
        try appendShellToken(allocator, command, options[i]);
        if (value_index) |index| {
            try appendShellToken(allocator, command, "--ssh-option");
            try appendShellToken(allocator, command, options[index]);
            i = index + 1;
        } else {
            i += 1;
        }
    }
}

fn sshOptionRequiresOuterProxy(options: []const []const u8, index: usize) bool {
    const arg = options[index];
    if (arg.len < 2 or arg[0] != '-' or std.mem.startsWith(u8, arg, "--")) return false;

    var pos: usize = 1;
    while (pos < arg.len) : (pos += 1) {
        const option = arg[pos];
        if (isProxyRequiredSshFlag(option) or isProxyRequiredSshOptionWithValue(option)) return true;
        if (option == 'o') {
            const value = optionValueFromOptions(options, index, pos) orelse return false;
            return sshConfigOptionRequiresProxy(value) catch false;
        }
        if (sshOptionRequiresValue(option) or isUnsafeSshOptionWithValue(option)) return false;
    }
    return false;
}

fn optionValueFromOptions(options: []const []const u8, index: usize, option_pos: usize) ?[]const u8 {
    const arg = options[index];
    if (option_pos + 1 < arg.len) return arg[option_pos + 1 ..];
    if (index + 1 >= options.len) return null;
    return options[index + 1];
}

const ProxyStreamInvocation = struct {
    host: []const u8,
    port: []const u8,
    user: []const u8 = "",
    client_socket: ?[]const u8 = null,
    filter_level: config.FilterLevel = .raw,
    client_ctrl_r: bool = false,
    ssh_options: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ProxyStreamInvocation, allocator: std.mem.Allocator) void {
        self.ssh_options.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runProxyStream(allocator: std.mem.Allocator, _: []const u8, args: []const []const u8) !void {
    var invocation = parseProxyStreamInvocation(allocator, args) catch |err| {
        try printProxyStreamArgError(err);
        return process_exit.request(64);
    };
    defer invocation.deinit(allocator);

    const proxy_guid = try session_registry.generateProxyGuid(allocator);
    defer allocator.free(proxy_guid);
    session_registry.writeOutgoingProxyHint(allocator, proxy_guid) catch |err| {
        client_log.debug("event=outgoing_proxy_hint_write_failed proxy={s} error={t}", .{ proxy_guid, err });
    };
    defer session_registry.removeOutgoingProxyHint(allocator, proxy_guid) catch |err| {
        client_log.debug("event=outgoing_proxy_hint_remove_failed proxy={s} error={t}", .{ proxy_guid, err });
    };

    if (invocation.port.len == 0) return error.InvalidProxyStreamArgs;
    _ = try std.fmt.parseInt(u16, invocation.port, 10);

    try invocation.ssh_options.append(allocator, "-p");
    try invocation.ssh_options.append(allocator, invocation.port);
    if (invocation.user.len > 0) {
        try invocation.ssh_options.append(allocator, "-l");
        try invocation.ssh_options.append(allocator, invocation.user);
    }
    var resolved_ssh_config = try resolveSshConfig(allocator, invocation.ssh_options.items, invocation.host);
    defer resolved_ssh_config.deinit(allocator);
    const default_ipqos_option = try resolved_ssh_config.defaultIpQosOption(allocator);
    defer if (default_ipqos_option) |option| allocator.free(option);

    var artifacts = try loadArtifactSet(allocator);
    defer artifacts.deinit();
    const remote_command = try bootstrapCommand(allocator);
    defer allocator.free(remote_command);

    const proxy_target_arg = try encodeBase64Arg(allocator, "localhost");
    defer allocator.free(proxy_target_arg);
    const broker_args = [_][]const u8{
        proxy_guid,
        "proxy",
        "1",
        "1",
        proxy_target_arg,
        invocation.port,
        "-",
    };

    const parsed_transport_args = SessionInvocation{
        .options = invocation.ssh_options.items,
        .host = invocation.host,
        .default_ipqos_option = default_ipqos_option,
        .resolved_host = resolved_ssh_config.hostname,
        .resolved_port = resolved_ssh_config.port,
    };
    var starter = StreamClientStarter{
        .allocator = allocator,
        .parsed_ssh_args = parsed_transport_args,
        .artifacts = &artifacts,
        .remote_command = remote_command,
        .bootstrap_entrypoint = .stream_broker,
        .broker_args = broker_args[0..],
        .stderr_mode = .forward,
    };

    var client_control_fd: c.fd_t = -1;
    var proxy_control_output_mode: proxy_control.OutputMode = .none;
    var proxy_control_ctrl_r_available = false;
    if (invocation.client_socket) |path| {
        client_control_fd = socket_transport.connectSocket(path) catch |err| blk: {
            client_log.userDiagnosticInfo("proxy control socket unavailable: {t}", .{err});
            break :blk -1;
        };
        if (client_control_fd >= 0) {
            const capabilities = proxy_control.clientHandshake(allocator, client_control_fd) catch |err| blk: {
                client_log.userDiagnosticInfo("proxy control unavailable: {t}", .{err});
                posix.close(client_control_fd);
                client_control_fd = -1;
                break :blk null;
            };
            if (capabilities) |payload| {
                proxy_control_output_mode = payload.output_mode;
                proxy_control_ctrl_r_available = payload.ctrl_r_available;
            }
        }
    }
    defer if (client_control_fd >= 0) posix.close(client_control_fd);
    const status_mode = proxyStreamReconnectStatusMode(
        invocation.filter_level,
        client_control_fd >= 0 and proxy_control_output_mode != .none,
    );

    const exit_status = stream_agent.runLocalStream(allocator, &starter, .{
        .source_fd = 0,
        .sink_fd = 1,
        .status_mode = status_mode,
        .intercept_ctrl_r = false,
        .control_fd = client_control_fd,
        .ctrl_r_status_enabled = proxy_control_ctrl_r_available and client_control_fd >= 0,
        .proxy_control_output_mode = proxy_control_output_mode,
        .title_fallback = invocation.host,
        .pending_kill_host = resolved_ssh_config.hostname,
        .pending_kill_port = resolved_ssh_config.port,
        .pending_kill_guid = proxy_guid,
    }) catch |err| {
        session_registry.removeOutgoingProxyHint(allocator, proxy_guid) catch |remove_err| {
            client_log.debug("event=outgoing_proxy_hint_remove_failed proxy={s} error={t}", .{ proxy_guid, remove_err });
        };
        try starter.exitAfterInitialFailure(err);
        return;
    };
    session_registry.removeOutgoingProxyHint(allocator, proxy_guid) catch |err| {
        client_log.debug("event=outgoing_proxy_hint_remove_failed proxy={s} error={t}", .{ proxy_guid, err });
    };
    return process_exit.request(exit_status);
}

fn parseProxyStreamInvocation(allocator: std.mem.Allocator, args: []const []const u8) !ProxyStreamInvocation {
    var invocation = ProxyStreamInvocation{
        .host = "",
        .port = "",
    };
    errdefer invocation.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingProxyHost;
            invocation.host = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingProxyPort;
            _ = try std.fmt.parseInt(u16, args[i], 10);
            invocation.port = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) return error.MissingProxyUser;
            invocation.user = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--ssh-option")) {
            i += 1;
            if (i >= args.len) return error.MissingSshOptionValue;
            try invocation.ssh_options.append(allocator, args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-socket")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingClientSocket;
            invocation.client_socket = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--filter-level")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingFilterLevel;
            invocation.filter_level = try config.parseFilterLevel(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-ctrl-r")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingClientCtrlR;
            invocation.client_ctrl_r = parseProxyBool(args[i]) catch return error.InvalidClientCtrlR;
            i += 1;
        } else {
            return error.InvalidProxyStreamArgs;
        }
    }

    if (invocation.host.len == 0) return error.MissingProxyHost;
    if (invocation.port.len == 0) return error.MissingProxyPort;
    return invocation;
}

fn printProxyStreamArgError(err: anyerror) !void {
    switch (err) {
        error.MissingProxyHost => try io.writeAll(2, "sessh: :internal-proxy-stream: requires --host HOST\n"),
        error.MissingProxyPort => try io.writeAll(2, "sessh: :internal-proxy-stream: requires --port PORT\n"),
        error.MissingProxyUser => try io.writeAll(2, "sessh: :internal-proxy-stream: --user requires a value\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: :internal-proxy-stream: --ssh-option requires a value\n"),
        error.MissingClientSocket => try io.writeAll(2, "sessh: :internal-proxy-stream: --client-socket requires a path\n"),
        error.MissingFilterLevel => try io.writeAll(2, "sessh: :internal-proxy-stream: --filter-level requires a value\n"),
        error.InvalidFilterLevel => try io.writeAll(2, "sessh: :internal-proxy-stream: invalid filter level\n"),
        error.MissingClientCtrlR => try io.writeAll(2, "sessh: :internal-proxy-stream: --client-ctrl-r requires a value\n"),
        error.InvalidClientCtrlR => try io.writeAll(2, "sessh: :internal-proxy-stream: --client-ctrl-r must be 0 or 1\n"),
        else => try io.stderrPrint("sessh: invalid :internal-proxy-stream: arguments: {t}\n", .{err}),
    }
}

fn parseProxyBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBool;
}

fn encodeBase64Arg(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn appendShellToken(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, ' ');
    const quoted = try shellQuote(allocator, value);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

fn sshOptionConsumesValueForHostScan(option: u8) bool {
    return option == 'o' or
        sshOptionRequiresValue(option) or
        isUnsafeSshOptionWithValue(option);
}

fn exitUnsupportedPlatform(parsed_ssh_args: SessionInvocation, platform: ?Platform) !noreturn {
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

fn unsupportedPlatformAction(action: SessionAction) []const u8 {
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

fn runPlainSshFallback(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation, platform: ?Platform) !noreturn {
    if (platform) |remote_platform| {
        try io.stderrPrint(
            "sessh: no matching sessh binary for remote platform {s} {s}; falling back to plain ssh without persistence\n",
            .{ remote_platform.os, remote_platform.arch },
        );
    } else {
        try io.writeAll(2, "sessh: remote platform is unsupported and no matching sessh binary is available; falling back to plain ssh without persistence\n");
    }

    const ssh_argv = try allocator.alloc([]const u8, parsed_ssh_args.options.len + 1);
    defer allocator.free(ssh_argv);
    @memcpy(ssh_argv[0..parsed_ssh_args.options.len], parsed_ssh_args.options);
    ssh_argv[ssh_argv.len - 1] = parsed_ssh_args.host;

    try runPlainSshArgv(allocator, ssh_argv, "plain-ssh-fallback");
}

const ProxyClientControl = struct {
    const max_title_bytes = 128;
    const max_status_bytes = 192;
    const max_cleanup_title_bytes = 512;

    control_fd: c.fd_t = -1,
    title_tracker: stream_agent.TerminalTitleTracker = .{},
    pending_title: [max_title_bytes]u8 = undefined,
    pending_title_len: usize = 0,
    status_line: [max_status_bytes]u8 = undefined,
    status_line_len: usize = 0,
    cleanup_title: [max_cleanup_title_bytes]u8 = [_]u8{0} ** max_cleanup_title_bytes,
    cleanup_title_len: usize = 0,
    title_visible: bool = false,
    status_visible: bool = false,
    intercept_requested: bool = false,
    ctrl_r_allowed: bool = false,
    output_mode: proxy_control.OutputMode = .update,
    onscreen_status: bool = false,

    fn init(allocator: std.mem.Allocator, ctrl_r_allowed: bool, onscreen_status: bool) ProxyClientControl {
        var diagnostics = ProxyClientControl{
            .ctrl_r_allowed = ctrl_r_allowed,
            .onscreen_status = onscreen_status,
        };
        const cwd = std.process.getCwdAlloc(allocator) catch null;
        if (cwd) |title| {
            defer allocator.free(title);
            diagnostics.cleanup_title_len = copyBytes(&diagnostics.cleanup_title, title);
        }
        return diagnostics;
    }

    fn setControlFd(self: *ProxyClientControl, fd: c.fd_t) void {
        if (self.control_fd >= 0) posix.close(self.control_fd);
        self.control_fd = fd;
        proxy_control.serverHandshake(std.heap.smp_allocator, fd, .{
            .output_mode = self.output_mode,
            .ctrl_r_available = self.ctrl_r_allowed,
        }) catch {
            self.closeControl();
            return;
        };
        setNonBlockingFd(fd) catch {};
    }

    fn closeControl(self: *ProxyClientControl) void {
        if (self.control_fd >= 0) {
            posix.close(self.control_fd);
            self.control_fd = -1;
        }
    }

    fn observeOutput(self: *ProxyClientControl, bytes: []const u8) void {
        self.title_tracker.observe(bytes);
        self.flushPendingTitle();
    }

    fn readControl(self: *ProxyClientControl) void {
        if (self.control_fd < 0) return;
        var message = proxy_control.readMessage(std.heap.smp_allocator, self.control_fd) catch {
            self.closeControl();
            return;
        };
        defer message.deinit(std.heap.smp_allocator);
        self.handleMessage(message.message);
    }

    fn handleMessage(self: *ProxyClientControl, message: proxy_control.Message) void {
        switch (message) {
            .diagnostic => |diagnostic| self.handleDiagnostic(diagnostic),
            .ctrl_r => {},
        }
    }

    fn handleDiagnostic(self: *ProxyClientControl, diagnostic: proxy_control.Diagnostic) void {
        if (diagnostic.update) |line| {
            self.showUpdate(line);
        } else if (diagnostic.diagnostic_line == null) {
            self.clearUpdate();
        }
        if (diagnostic.diagnostic_line) |line| self.showDiagnostic(line);
        self.intercept_requested = diagnostic.intercept_ctrl_r;
    }

    fn shouldInterceptCtrlR(self: *const ProxyClientControl) bool {
        return self.ctrl_r_allowed and self.intercept_requested and self.control_fd >= 0;
    }

    fn sendCtrlR(self: *ProxyClientControl) void {
        if (self.control_fd < 0) return;
        proxy_control.writeCtrlR(self.control_fd) catch {};
    }

    fn showUpdate(self: *ProxyClientControl, line: []const u8) void {
        self.showTitle(line);
        self.showStatus(line);
    }

    fn showStatus(self: *ProxyClientControl, line: []const u8) void {
        self.status_line_len = copyBytes(&self.status_line, line);
        if (!self.onscreen_status) return;
        self.status_visible = true;
        self.redrawStatusLine();
    }

    fn showDiagnostic(self: *ProxyClientControl, line: []const u8) void {
        if (!self.onscreen_status) return;
        if (self.status_visible) io.writeAll(2, "\r\x1b[K") catch {};
        io.writeAll(2, line) catch {};
        io.writeAll(2, "\r\n") catch {};
        if (self.status_visible) self.redrawStatusLine();
    }

    fn showTitle(self: *ProxyClientControl, title: []const u8) void {
        self.pending_title_len = copyBytes(&self.pending_title, title);
        self.flushPendingTitle();
    }

    fn flushPendingTitle(self: *ProxyClientControl) void {
        if (self.pending_title_len == 0) return;
        if (!self.title_tracker.safeForLocalTitle()) return;
        reconnect_title.writeTitle(1, self.pending_title[0..self.pending_title_len]) catch return;
        self.title_visible = true;
        self.pending_title_len = 0;
    }

    fn clear(self: *ProxyClientControl) void {
        self.intercept_requested = false;
        self.clearUpdate();
    }

    fn clearUpdate(self: *ProxyClientControl) void {
        self.pending_title_len = 0;
        if (self.onscreen_status and self.status_visible) {
            io.writeAll(2, "\r\x1b[K") catch {};
            self.status_visible = false;
        }
        self.restoreTitle();
    }

    fn restoreTitle(self: *ProxyClientControl) void {
        if (!self.title_visible) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.cleanup_title[0..self.cleanup_title_len];
        reconnect_title.writeTitle(1, title) catch {};
        self.title_visible = false;
    }

    fn redrawStatusLine(self: *ProxyClientControl) void {
        if (!self.status_visible) return;
        io.writeAll(2, "\r\x1b[K") catch {};
        io.writeAll(2, self.status_line[0..self.status_line_len]) catch {};
    }
};

fn copyBytes(dest: []u8, source: []const u8) usize {
    const len = @min(dest.len, source.len);
    @memcpy(dest[0..len], source[0..len]);
    return len;
}

const DiagnosticsThreadState = struct {
    listen_fd: c.fd_t,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn diagnosticsThreadMain(state: *DiagnosticsThreadState, allocator: std.mem.Allocator) void {
    var diagnostics = ProxyClientControl.init(allocator, false, true);
    defer {
        diagnostics.clear();
        diagnostics.closeControl();
    }

    while (!state.done.load(.acquire)) {
        var pollfds: [2]posix.pollfd = undefined;
        var count: usize = 0;
        pollfds[count] = .{ .fd = state.listen_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
        var control_index: ?usize = null;
        if (diagnostics.control_fd >= 0) {
            control_index = count;
            pollfds[count] = .{ .fd = diagnostics.control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
            count += 1;
        }
        _ = posix.poll(pollfds[0..count], 100) catch continue;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) {
            const fd = c.accept(state.listen_fd, null, null);
            if (fd >= 0) diagnostics.setControlFd(fd);
        }
        if (control_index) |index| {
            if (pollfds[index].revents != 0) diagnostics.readControl();
        }
    }
}

fn runPlainSshArgvWithDiagnosticsThread(
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    client_socket_listen_fd: c.fd_t,
    diagnostic_name: []const u8,
) !noreturn {
    var state = DiagnosticsThreadState{ .listen_fd = client_socket_listen_fd };
    const thread_allocator = std.heap.smp_allocator;
    var thread = try std.Thread.spawn(.{}, diagnosticsThreadMain, .{ &state, thread_allocator });
    var joined = false;
    defer if (!joined) {
        state.done.store(true, .release);
        thread.join();
    };

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
    state.done.store(true, .release);
    thread.join();
    joined = true;
    return exitAfterPlainSshTerm(term, diagnostic_name);
}

fn runPlainSshArgvUnderLocalPty(
    allocator: std.mem.Allocator,
    ssh_args: []const []const u8,
    client_socket_listen_fd: c.fd_t,
    client_ctrl_r: bool,
    diagnostic_name: []const u8,
) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, ssh_args.len + 1);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    @memcpy(ssh_argv[1..], ssh_args);

    var size = terminal.currentWindowSize();
    var captured_tty_settings: ?tty_settings.Settings = try tty_settings.capture(allocator, 0, .{});
    defer if (captured_tty_settings) |*settings| settings.deinit(allocator);

    var child = try pty_process.spawn(allocator, .{
        .rows = size.rows,
        .cols = size.cols,
        .command_argv = ssh_argv,
        .tty_settings = if (captured_tty_settings) |settings| settings else null,
    });
    defer child.terminate();

    var mode_guard = try terminal.TerminalModeGuard.enable(0);
    defer mode_guard.restore();

    var stdin_flags_guard = try FdStatusFlagsGuard.setNonBlocking(0);
    defer stdin_flags_guard.restore();
    setNonBlockingFd(child.master_fd) catch {};

    var diagnostics = ProxyClientControl.init(allocator, client_ctrl_r, false);
    defer {
        diagnostics.clear();
        diagnostics.closeControl();
    }

    while (true) {
        refreshLocalPtySize(child.master_fd, &size);

        var pollfds: [3]posix.pollfd = undefined;
        var count: usize = 0;
        const pty_index = count;
        pollfds[count] = .{ .fd = child.master_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
        const stdin_index = count;
        pollfds[count] = .{ .fd = 0, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
        var control_index: ?usize = null;
        const control_fd = if (diagnostics.control_fd >= 0) diagnostics.control_fd else client_socket_listen_fd;
        control_index = count;
        pollfds[count] = .{ .fd = control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;

        _ = posix.poll(pollfds[0..count], -1) catch continue;
        refreshLocalPtySize(child.master_fd, &size);

        if ((pollfds[pty_index].revents & posix.POLL.IN) != 0) {
            var buf: [8192]u8 = undefined;
            switch (try pty_process.readMaster(child.master_fd, &buf)) {
                .bytes => |bytes| {
                    diagnostics.observeOutput(bytes);
                    try io.writeAll(1, bytes);
                },
                .would_block => {},
                .eof => {
                    const term = child.wait();
                    child.closeMaster();
                    diagnostics.clear();
                    return exitAfterLocalPtySshTerm(term, diagnostic_name, &mode_guard, &stdin_flags_guard);
                },
            }
        }
        if ((pollfds[pty_index].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[pty_index].revents & posix.POLL.IN) == 0)
        {
            const term = child.wait();
            child.closeMaster();
            diagnostics.clear();
            return exitAfterLocalPtySshTerm(term, diagnostic_name, &mode_guard, &stdin_flags_guard);
        }

        if ((pollfds[stdin_index].revents & posix.POLL.IN) != 0) {
            var input: [4096]u8 = undefined;
            const n = c.read(0, &input, input.len);
            if (n > 0) {
                const bytes = input[0..@intCast(n)];
                try writePtyInput(child.master_fd, bytes, &diagnostics);
            }
        }

        if (control_index) |index| {
            if (pollfds[index].revents != 0) {
                if (diagnostics.control_fd >= 0) {
                    diagnostics.readControl();
                } else {
                    const fd = c.accept(client_socket_listen_fd, null, null);
                    if (fd >= 0) diagnostics.setControlFd(fd);
                }
            }
        }
    }
}

fn exitAfterLocalPtySshTerm(
    term: std.process.Child.Term,
    diagnostic_name: []const u8,
    mode_guard: *terminal.TerminalModeGuard,
    stdin_flags_guard: *FdStatusFlagsGuard,
) !noreturn {
    stdin_flags_guard.restore();
    mode_guard.restore();
    return exitAfterPlainSshTerm(term, diagnostic_name);
}

fn refreshLocalPtySize(pty_fd: c.fd_t, size: *terminal.WindowSize) void {
    const current_size = terminal.currentWindowSize();
    if (current_size.rows == size.rows and current_size.cols == size.cols) return;
    _ = terminal.setPtySize(pty_fd, current_size.rows, current_size.cols);
    size.* = current_size;
}

fn writePtyInput(pty_fd: c.fd_t, bytes: []const u8, diagnostics: *ProxyClientControl) !void {
    if (!diagnostics.shouldInterceptCtrlR()) {
        try io.writeAll(pty_fd, bytes);
        return;
    }
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != reconnect_control.ctrl_r) continue;
        if (index > start) try io.writeAll(pty_fd, bytes[start..index]);
        diagnostics.sendCtrlR();
        start = index + 1;
    }
    if (start < bytes.len) try io.writeAll(pty_fd, bytes[start..]);
}

fn exitAfterPlainSshTerm(term: std.process.Child.Term, diagnostic_name: []const u8) !noreturn {
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

fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

const FdStatusFlagsGuard = struct {
    fd: c.fd_t,
    original: c_int,
    active: bool = false,

    // We use F_SETFL to put stdin into non-blocking mode so that we can
    // process IO across multiple file descriptors without additional threads.
    // But the open file description of stdin is shared with the invoking
    // shell, so we need to restore it prior to exiting. Otherwise the shell
    // might get EAGAIN instead of waiting for input, which could cause all
    // kinds of problems.
    fn setNonBlocking(fd: c.fd_t) !FdStatusFlagsGuard {
        const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.FcntlFailed;
        const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
        if ((flags & nonblocking_flag) != 0) return .{ .fd = fd, .original = flags };
        if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
        return .{ .fd = fd, .original = flags, .active = true };
    }

    fn restore(self: *FdStatusFlagsGuard) void {
        if (!self.active) return;
        _ = c.fcntl(self.fd, c.F.SETFL, self.original);
        self.active = false;
    }
};

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
    return exitAfterPlainSshTerm(term, diagnostic_name);
}

fn exitAfterSshBootstrapFailure(
    allocator: std.mem.Allocator,
    parsed_ssh_args: SessionInvocation,
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

fn writeVisibleSshCommand(allocator: std.mem.Allocator, parsed_ssh_args: SessionInvocation) !void {
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

fn needsEncodedExecArg(arg: []const u8) bool {
    return !isPlainShellArg(arg) or std.mem.startsWith(u8, arg, bootstrap_exec_encoded_arg_prefix);
}

test "bootstrap EXEC arg encoding is used for unsafe or reserved tokens" {
    try std.testing.expect(!needsEncodedExecArg("kill"));
    try std.testing.expect(!needsEncodedExecArg("--jsonl"));
    try std.testing.expect(needsEncodedExecArg("{\"guid\":\"s-1\"}"));
    try std.testing.expect(needsEncodedExecArg("b64:literal"));
}

// OpenSSH does not preserve argv for `ssh HOST cmd args...`; it joins the
// remaining local argv with spaces and lets the remote login shell interpret
// the result. The caller is responsible for only using this for that ssh-shaped
// command form. `sesshmux new HOST cmd args...` uses command_argv instead.
fn joinRemoteShellCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args, 0..) |arg, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn shellCommandFromRemoteArgs(allocator: std.mem.Allocator, args: []const []const u8) !?[]u8 {
    if (args.len == 0) return null;
    const command = try joinRemoteShellCommandArgs(allocator, args);
    if (command.len == 0) {
        // OpenSSH treats an empty remote command as no command at all. That is
        // different from a non-empty command string such as `""`, which the
        // remote shell evaluates and typically fails to execute.
        allocator.free(command);
        return null;
    }
    return command;
}

/// ssh remote commands are evaluated by the remote account's login shell. Wrap
/// the embedded script so that shell only execs POSIX sh. This gives the
/// bootstrapper one shell contract to implement and test instead of inheriting
/// every possible remote login shell's behavior.
fn bootstrapCommand(allocator: std.mem.Allocator) ![]u8 {
    return shCommand(allocator, bootstrapper_script);
}

fn directBrokerCommand(allocator: std.mem.Allocator, broker_args: []const []const u8) ![]u8 {
    return directEntrypointCommand(allocator, .session_broker, broker_args);
}

fn directControlCommand(allocator: std.mem.Allocator) ![]u8 {
    return directEntrypointCommand(allocator, .control, &.{});
}

fn directEntrypointCommand(
    allocator: std.mem.Allocator,
    entrypoint: BootstrapEntrypoint,
    entrypoint_args: []const []const u8,
) ![]u8 {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    const client_version = try shellQuote(allocator, config.version);
    defer allocator.free(client_version);
    try script.appendSlice(allocator, "SESSH_CLIENT_VERSION=");
    try script.appendSlice(allocator, client_version);
    try script.appendSlice(allocator, " exec sesshmux ");
    try script.appendSlice(allocator, entrypoint.arg());
    for (entrypoint_args) |arg| {
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

fn compatModeFromEnv() bool {
    const value_z = c.getenv(config.compat_env) orelse return false;
    return std.mem.eql(u8, std.mem.span(value_z), "1");
}

fn resolveLocalRefs(allocator: std.mem.Allocator, parsed: *SessionInvocation) !?[]u8 {
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
            if (parsed.kill_ids.len != 1) return null;
            if (parsed.host.len > 0) return null;
            const guid = session_registry.resolveRefToGuid(allocator, ref) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            parsed.kill_id = guid;
            parsed.kill_ids = &.{guid};
            return guid;
        },
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => return null,
    }
}

fn parseSshArgs(allocator: std.mem.Allocator, args: []const []const u8, _: CliParseOptions) !SessionInvocation {
    if (args.len < 2) return error.MissingHost;

    var i: usize = 1;
    var pre_host = SessionInvocation{ .options = &.{}, .host = "" };
    try parseSesshOptionsBeforeHost(args, &i, &pre_host);
    const ssh_options_start = i;
    // ssh allows options before the host, and sessh has its own pre-host
    // options. If users interleave them, keep only real ssh options in the
    // transport option list so sessh-only flags are not forwarded to ssh.
    var pending_ssh_options_start = i;
    var mixed_ssh_options: std.ArrayList([]const u8) = .empty;
    var has_mixed_ssh_options = false;
    errdefer mixed_ssh_options.deinit(allocator);

    while (i < args.len) {
        const arg = args[i];
        if (arg.len == 0) return error.MissingHost;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            var parsed = pre_host;
            try finishParsedSshOptions(
                allocator,
                &parsed,
                args,
                ssh_options_start,
                i - 1,
                pending_ssh_options_start,
                i - 1,
                &mixed_ssh_options,
                has_mixed_ssh_options,
            );
            parsed.host = args[i];
            i += 1;
            errdefer parsed.deinit(allocator);
            parseSesshOptionsAfterHost(args, &i, &parsed);
            return parsed;
        }

        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            var parsed = pre_host;
            try finishParsedSshOptions(
                allocator,
                &parsed,
                args,
                ssh_options_start,
                i,
                pending_ssh_options_start,
                i,
                &mixed_ssh_options,
                has_mixed_ssh_options,
            );
            parsed.host = arg;
            i += 1;
            errdefer parsed.deinit(allocator);
            parseSesshOptionsAfterHost(args, &i, &parsed);
            return parsed;
        }

        if (isSesshLongOption(arg)) {
            if (!has_mixed_ssh_options) {
                has_mixed_ssh_options = true;
                try mixed_ssh_options.appendSlice(allocator, args[ssh_options_start..i]);
            } else {
                try mixed_ssh_options.appendSlice(allocator, args[pending_ssh_options_start..i]);
            }
            try parseSesshOptionsBeforeHost(args, &i, &pre_host);
            pending_ssh_options_start = i;
            continue;
        }
        const ssh_option_start = i;
        try consumeSshOption(args, &i, &pre_host.tty_request, &pre_host.proxy_required);
        if (has_mixed_ssh_options) {
            try mixed_ssh_options.appendSlice(allocator, args[ssh_option_start..i]);
            pending_ssh_options_start = i;
        }
    }

    return error.MissingHost;
}

fn finishParsedSshOptions(
    allocator: std.mem.Allocator,
    parsed: *SessionInvocation,
    args: []const []const u8,
    contiguous_start: usize,
    contiguous_end: usize,
    pending_start: usize,
    pending_end: usize,
    mixed_ssh_options: *std.ArrayList([]const u8),
    has_mixed_ssh_options: bool,
) !void {
    if (!has_mixed_ssh_options) {
        parsed.options = args[contiguous_start..contiguous_end];
        return;
    }

    try mixed_ssh_options.appendSlice(allocator, args[pending_start..pending_end]);
    const owned = try mixed_ssh_options.toOwnedSlice(allocator);
    parsed.owned_options = owned;
    parsed.options = owned;
}

fn parseSesshOptionsBeforeHost(args: []const []const u8, index: *usize, parsed: *SessionInvocation) !void {
    while (index.* < args.len) {
        const arg = args[index.*];
        if (!isSesshLongOption(arg)) return;
        if (isConfigOnlyDirectSesshOption(arg)) return error.UnsupportedSesshOption;

        if (std.mem.eql(u8, arg, "--log-level")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingClientLogLevel;
            parsed.client_log_level = try client_log.parseLevel(args[index.*]);
            parsed.client_log_level_set = true;
            try parsed.overlay_args.append(arg);
            try parsed.overlay_args.append(args[index.*]);
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--terminal-emulator")) {
            parsed.terminal_emulator = true;
            parsed.terminal_emulator_set = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--no-terminal-emulator")) {
            parsed.terminal_emulator = false;
            parsed.terminal_emulator_set = true;
            index.* += 1;
        } else if (std.mem.eql(u8, arg, "--filter-level")) {
            index.* += 1;
            if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingFilterLevel;
            parsed.filter_level = try config.parseFilterLevel(args[index.*]);
            parsed.filter_level_set = true;
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

// Direct `sessh` follows ssh's command-line boundary: the first non-option
// token is the host, and every later token is part of the remote command.
fn parseSesshOptionsAfterHost(args: []const []const u8, index: *usize, parsed: *SessionInvocation) void {
    if (index.* < args.len) {
        parsed.shell_command_args = args[index.*..];
        index.* = args.len;
    }
}

fn isSesshLongOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--log-level") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap") or
        std.mem.eql(u8, arg, "--terminal-emulator") or
        std.mem.eql(u8, arg, "--no-terminal-emulator") or
        std.mem.eql(u8, arg, "--filter-level") or
        std.mem.eql(u8, arg, "--ssh-options") or
        std.mem.eql(u8, arg, "--capture-tty-transcript");
}

fn isConfigOnlyDirectSesshOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--scrollback-limit") or
        std.mem.eql(u8, arg, "--initial-scrollback") or
        std.mem.eql(u8, arg, "--bootstrap") or
        std.mem.eql(u8, arg, "--no-bootstrap") or
        std.mem.eql(u8, arg, "--ssh-options");
}

fn isOneShotBrokerCommandAction(action: SessionAction) bool {
    return switch (action) {
        .list,
        .kill,
        .kill_all,
        .detach_client,
        .repaint_client,
        .debug_client,
        => true,
        .new, .attach => false,
    };
}

fn isClientControlAction(action: SessionAction) bool {
    return switch (action) {
        .detach_client, .repaint_client, .debug_client => true,
        .new, .attach, .list, .kill, .kill_all => false,
    };
}

fn isRemoteClientControlAction(parsed: SessionInvocation) bool {
    return isClientControlAction(parsed.action) and
        parsed.host.len > 0 and
        !std.mem.eql(u8, parsed.host, ".");
}

fn runRemoteMuxClientControlCommand(
    allocator: std.mem.Allocator,
    parsed: SessionInvocation,
) !void {
    const argv = parsed.remote_local_args;
    if (argv.len == 0) return error.MissingRemoteLocalArgs;

    var runner = try RemoteControlRunner.initWithBootstrap(allocator, parsed.bootstrap);
    defer runner.deinit();
    var result = try runner.run(allocator, parsed.host, parsed.options, argv);
    defer result.deinit(allocator);

    if (result.stdout.len > 0) try io.writeAll(1, result.stdout);
    if (result.stderr.len > 0) try io.writeAll(2, result.stderr);
    if (result.exit_code != 0) return process_exit.request(result.exit_code);
}

fn consumeSshOption(
    args: []const []const u8,
    index: *usize,
    tty_request: *SshTtyRequest,
    proxy_required: *bool,
) !void {
    const arg = args[index.*];
    if (std.mem.startsWith(u8, arg, "--")) return error.UnsupportedSshOption;

    if (sshTtyRequestCount(arg)) |count| {
        noteSshTtyRequest(tty_request, count);
        index.* += 1;
        return;
    }

    var pos: usize = 1;
    while (pos < arg.len) {
        const option = arg[pos];
        if (isProxyRequiredSshFlag(option)) {
            proxy_required.* = true;
            pos += 1;
            continue;
        }
        if (isProxyRequiredSshOptionWithValue(option)) {
            _ = try optionValue(args, index, pos);
            proxy_required.* = true;
            return;
        }
        if (isUnsafeSshFlag(option) or isUnsafeSshOptionWithValue(option)) {
            return error.UnsafeSshOption;
        }

        if (option == 'o') {
            const value = try optionValue(args, index, pos);
            if (try sshConfigOptionRequiresProxy(value)) {
                proxy_required.* = true;
            } else {
                try validateSshConfigOption(value);
            }
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

fn isSshTtyRequestOption(arg: []const u8) bool {
    return sshTtyRequestCount(arg) != null;
}

fn sshTtyRequestCount(arg: []const u8) ?usize {
    if (arg.len < 2 or arg[0] != '-') return null;
    for (arg[1..]) |byte| {
        if (byte != 't') return null;
    }
    return arg.len - 1;
}

fn noteSshTtyRequest(tty_request: *SshTtyRequest, count: usize) void {
    if (count >= 2 or tty_request.* == .requested) {
        tty_request.* = .forced;
    } else if (count == 1 and tty_request.* == .none) {
        tty_request.* = .requested;
    }
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
    return std.mem.indexOfScalar(u8, "46CgKkqsTv", option) != null;
}

fn isUnsafeSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "GtV", option) != null;
}

fn sshOptionRequiresValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmOPpRSwW", option) != null;
}

fn isUnsafeSshOptionWithValue(option: u8) bool {
    return option == 'Q';
}

fn isProxyRequiredSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "AafMNsXxYyn", option) != null;
}

fn isProxyRequiredSshOptionWithValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "DLORWw", option) != null;
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

fn sshConfigOptionRequiresProxy(raw_option: []const u8) !bool {
    const key = sshConfigKey(raw_option);
    if (sshConfigKeyIs(raw_option, "RemoteCommand")) return true;
    if (sshConfigKeyIs(raw_option, "ForwardAgent")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForwardX11")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForwardX11Trusted")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "LocalForward")) return true;
    if (sshConfigKeyIs(raw_option, "RemoteForward")) return true;
    if (sshConfigKeyIs(raw_option, "DynamicForward")) return true;
    if (sshConfigKeyIs(raw_option, "StreamLocalBindUnlink")) return true;
    if (sshConfigKeyIs(raw_option, "StreamLocalForward")) return true;
    if (sshConfigKeyIs(raw_option, "ClearAllForwardings")) return true;
    if (sshConfigKeyIs(raw_option, "PermitLocalCommand")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "RequestTTY")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "SessionType")) return !sshConfigValueIs(raw_option, key.len, "default");
    if (sshConfigKeyIs(raw_option, "StdinNull")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForkAfterAuthentication")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "Tunnel")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "TunnelDevice")) return true;
    return false;
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

pub fn printSshArgError(err: anyerror) !void {
    switch (err) {
        error.MissingHost => try io.writeAll(2, "sessh: missing host\n"),
        error.MissingAttachId => try io.writeAll(2, "sesshmux: attach requires an id in this form\n"),
        error.MissingKillTarget => try io.writeAll(2, "sesshmux: kill requires --all, a guid, or --current\n"),
        error.MissingKillId => try io.writeAll(2, "sesshmux: kill requires an id\n"),
        error.MissingScrollbackRowCount => try io.writeAll(2, "sessh: --scrollback-limit requires a value\n"),
        error.MissingInitialScrollback => try io.writeAll(2, "sessh: --initial-scrollback requires a value\n"),
        error.MissingClientLogLevel => try io.writeAll(2, "sessh: --log-level requires a value\n"),
        error.MissingFilterLevel => try io.writeAll(2, "sessh: --filter-level requires one of: raw, unhygienic, hygienic, emulated\n"),
        error.MissingTtyTranscriptPath => try io.writeAll(2, "sessh: --capture-tty-transcript requires a path\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: ssh option is missing its value\n"),
        error.MissingSshOptions => try io.writeAll(2, "sesshmux: --ssh-options requires a value\n"),
        error.MissingId => try io.writeAll(2, "sesshmux: --id requires a value\n"),
        error.MissingClientListTarget => try io.writeAll(2, "sesshmux: --client requires a value: " ++ client_list_target_help ++ "\n"),
        error.MissingCommandArgv => try io.writeAll(2, "sesshmux: -- requires a command argv\n"),
        error.MissingEvalArgs => try io.writeAll(2, "sesshmux: --eval-args requires command args\n"),
        error.SesshOptionAfterHost => try io.writeAll(2, "sessh: sessh options must appear before HOST\n"),
        error.TooManyMuxArguments => try io.writeAll(2, "sesshmux: too many arguments\n"),
        error.UnsupportedMuxCommand => try io.writeAll(2, "sesshmux: unsupported command\n"),
        error.UnsupportedMuxOption => try io.writeAll(2, "sesshmux: unsupported option for this command\n"),
        error.ConflictingSesshAction => try io.writeAll(2, "sessh: conflicting sessh actions\n"),
        error.InvalidScrollbackRowCount => try io.writeAll(2, "sessh: invalid scrollback row count\n"),
        error.InvalidInitialScrollback => try io.writeAll(2, "sessh: invalid initial scrollback\n"),
        error.InvalidClientLogLevel => try io.writeAll(2, "sessh: invalid log level\n"),
        error.InvalidFilterLevel => try io.writeAll(2, "sessh: invalid filter level; expected one of: raw, unhygienic, hygienic, emulated\n"),
        error.InvalidBool => try io.writeAll(2, "sessh: expected true or false\n"),
        error.RemoteCommandUnsupported => try io.writeAll(2, "sessh: remote commands require -t or -tt for persistent sessions\n"),
        error.UnsafeSshOption => try io.writeAll(2, "sessh: ssh option is not safe for sessh transport\n"),
        error.UnsupportedSesshOption => try io.writeAll(2, "sessh: unsupported sessh option for ssh transport\n"),
        error.UnsupportedSesshCliOption => try io.writeAll(2, "sessh: unsupported sessh option\n"),
        error.UnsupportedSshOption => try io.writeAll(2, "sessh: unsupported ssh option for sessh transport\n"),
        error.SessionAlreadyExited => try io.writeAll(2, "ERROR session already exited\n"),
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
    reconnect_ui: ?*client_ui.ReconnectUi,
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
    reconnect_ui: ?*client_ui.ReconnectUi,
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
    reconnect_ui: ?*client_ui.ReconnectUi,
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

fn reconnectShouldDetach(reconnect_ui: *client_ui.ReconnectUi, poll_reconnect_input: bool) !bool {
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

test "joinRemoteShellCommandArgs matches ssh remote command joining" {
    const joined = try joinRemoteShellCommandArgs(std.testing.allocator, &.{ "echo", "$SESSH_TEST_HOST" });
    defer std.testing.allocator.free(joined);

    try std.testing.expectEqualStrings("echo $SESSH_TEST_HOST", joined);

    const empty = try joinRemoteShellCommandArgs(std.testing.allocator, &.{""});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    try std.testing.expect(!hasRemoteShellCommand(&.{""}));
    try std.testing.expect(hasRemoteShellCommand(&.{"\"\""}));
    try std.testing.expect(hasRemoteShellCommand(&.{ "", "" }));

    const no_command = try shellCommandFromRemoteArgs(std.testing.allocator, &.{""});
    try std.testing.expectEqual(@as(?[]u8, null), no_command);

    const quoted_empty_command = try shellCommandFromRemoteArgs(std.testing.allocator, &.{"\"\""});
    defer std.testing.allocator.free(quoted_empty_command.?);
    try std.testing.expectEqualStrings("\"\"", quoted_empty_command.?);
}

test "transport ssh option filtering only removes tty request options" {
    const options = &.{ "-F", "-tt", "-t", "-p2222", "-o", "BatchMode=yes" };
    var out: [5][]const u8 = undefined;
    var index: usize = 0;

    try std.testing.expectEqual(@as(usize, 5), transportSshOptionsLen(options));
    appendTransportSshOptions(out[0..], &index, options);

    try expectArgvEqual(&.{ "-F", "-tt", "-p2222", "-o", "BatchMode=yes" }, out[0..index]);
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

    const parsed = try parseSshArgs(std.testing.allocator, &args, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(usize, 6), parsed.options.len);
    try std.testing.expectEqualStrings("-F", parsed.options[0]);
    try std.testing.expectEqualStrings("ssh_config", parsed.options[1]);
    try std.testing.expectEqualStrings("-p2222", parsed.options[2]);
    try std.testing.expectEqualStrings("-o", parsed.options[3]);
    try std.testing.expectEqualStrings("BatchMode=yes", parsed.options[4]);
    try std.testing.expectEqualStrings("-vvC", parsed.options[5]);
}

test "parseSshArgs accepts public sessh options before ssh options and host" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--log-level",
        "debug",
        "-F",
        "ssh_config",
        "example.com",
    }, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(client_log.Level.debug, parsed.client_log_level);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.len);
    try std.testing.expectEqualStrings("-F", parsed.options[0]);
    try std.testing.expectEqualStrings("ssh_config", parsed.options[1]);
}

test "parseSshArgs accepts interleaved ssh and sessh options before host" {
    var parsed = try parseSshArgs(std.testing.allocator, &.{
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
    }, .{});
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(client_log.Level.debug, parsed.client_log_level);
    try std.testing.expect(!parsed.terminal_emulator);
    try std.testing.expect(parsed.terminal_emulator_set);
    try std.testing.expectEqual(SshTtyRequest.requested, parsed.tty_request);
    try expectArgvEqual(&.{ "-t", "-p", "2222" }, parsed.options);
    try expectArgvEqual(&.{ "exit", "3" }, parsed.shell_command_args);
}

test "parseSshArgs treats every direct post-host token as remote command" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "rsync",
        "--version",
        "--no-terminal-emulator",
        "--remote-name",
        "work",
        "-t",
    }, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(SessionAction.new, parsed.action);
    try std.testing.expect(!parsed.terminal_emulator_set);
    try expectArgvEqual(&.{ "rsync", "--version", "--no-terminal-emulator", "--remote-name", "work", "-t" }, parsed.shell_command_args);
}

test "parseSshArgs rejects config-only sessh options on direct ssh transport" {
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--scrollback-limit",
        "100",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--initial-scrollback",
        "0",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--bootstrap",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-bootstrap",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsupportedSesshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--ssh-options",
        "-F cfg",
        "example.com",
    }, .{}));
}

test "ssh verbosity maps to inferred client log level" {
    try std.testing.expectEqual(client_log.Level.warn, inferredClientLogLevel(&.{}));
    try std.testing.expectEqual(client_log.Level.info, inferredClientLogLevel(&.{"-v"}));
    try std.testing.expectEqual(client_log.Level.debug, inferredClientLogLevel(&.{"-vv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{"-vvv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{ "-vC", "-vv" }));
}

test "parseSshArgs rejects protocol-breaking ssh options" {
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-G",
        "example.com",
    }, .{}));
    try std.testing.expectError(error.UnsafeSshOption, parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-Q",
        "cipher",
        "example.com",
    }, .{}));
}

test "parseSshArgs routes OpenSSH-owned options to proxy stream mode" {
    const x11 = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-X",
        "example.com",
    }, .{});
    try std.testing.expect(x11.proxy_required);
    try std.testing.expect(shouldUseProxyStream(x11, true));

    const agent = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-A",
        "example.com",
    }, .{});
    try std.testing.expect(agent.proxy_required);
    try std.testing.expect(shouldUseProxyStream(agent, true));

    const stdin_null = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-n",
        "example.com",
    }, .{});
    try std.testing.expect(stdin_null.proxy_required);
    try std.testing.expect(shouldUseProxyStream(stdin_null, true));

    const fork_after_auth = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-f",
        "example.com",
    }, .{});
    try std.testing.expect(fork_after_auth.proxy_required);
    try std.testing.expect(shouldUseProxyStream(fork_after_auth, true));

    const forward = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-L",
        "8080:localhost:80",
        "example.com",
    }, .{});
    try std.testing.expect(forward.proxy_required);
    try std.testing.expect(shouldUseProxyStream(forward, true));

    const direct = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-W",
        "host:22",
        "example.com",
    }, .{});
    try std.testing.expect(direct.proxy_required);
    try std.testing.expect(shouldUseProxyStream(direct, true));

    const request_tty = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-o",
        "RequestTTY=force",
        "example.com",
    }, .{});
    try std.testing.expect(request_tty.proxy_required);
    try std.testing.expect(shouldUseProxyStream(request_tty, true));

    const explicit = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "example.com",
    }, .{});
    try std.testing.expectEqual(config.FilterLevel.hygienic, explicit.filter_level);
    try std.testing.expect(explicit.filter_level_set);
    try std.testing.expect(shouldUseProxyStream(explicit, true));

    const explicit_disabled = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "emulated",
        "example.com",
    }, .{});
    try std.testing.expectEqual(config.FilterLevel.emulated, explicit_disabled.filter_level);
    try std.testing.expect(explicit_disabled.filter_level_set);
    try std.testing.expect(!shouldUseProxyStream(explicit_disabled, true));
}

test "proxy command keeps outer-only options off bootstrap ssh" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-X",
        "-tt",
        "-L",
        "8080:localhost:80",
        "-o",
        "ForwardAgent=yes",
        "-o",
        "BatchMode=yes",
        "-v",
        "example.com",
    }, .{});
    try std.testing.expect(shouldUseProxyStream(parsed, true));

    const option = try proxyCommandOption(std.testing.allocator, "sesshmux-dev", parsed, "/tmp/sessh-test/c/abc", .hygienic, true);
    defer std.testing.allocator.free(option);

    try std.testing.expect(std.mem.indexOf(u8, option, ":internal-proxy-stream:") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%n") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%p") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--filter-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "hygienic") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-socket") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "/tmp/sessh-test/c/abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-ctrl-r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "-v") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "ForwardAgent=yes") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "8080:localhost:80") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-X'") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-tt'") == null);
}

test "parseSshArgs uses ssh tty request to enable shell-evaluated commands" {
    const single = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "echo",
        "$SESSH_TEST_HOST",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.requested, single.tty_request);
    try std.testing.expectEqual(@as(usize, 2), single.shell_command_args.len);
    try std.testing.expectEqualStrings("echo", single.shell_command_args[0]);
    try std.testing.expectEqualStrings("$SESSH_TEST_HOST", single.shell_command_args[1]);

    const forced = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-tt",
        "example.com",
        "uname",
        "-a",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.forced, forced.tty_request);
    try std.testing.expectEqual(@as(usize, 2), forced.shell_command_args.len);
    try std.testing.expectEqualStrings("uname", forced.shell_command_args[0]);
    try std.testing.expectEqualStrings("-a", forced.shell_command_args[1]);

    const repeated = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-t",
        "-t",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.forced, repeated.tty_request);

    const empty = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.requested, empty.tty_request);
    try std.testing.expectEqual(@as(usize, 1), empty.shell_command_args.len);
    try std.testing.expectEqualStrings("", empty.shell_command_args[0]);
    try std.testing.expect(!shouldUseStreamPath(empty, false));
    try std.testing.expect(!shouldUseProxyStream(empty, false));
}

test "stream routing preserves ssh remote command tty semantics" {
    const command = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "echo",
        "hello",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.none, command.tty_request);
    try std.testing.expectEqual(@as(usize, 2), command.shell_command_args.len);
    try std.testing.expect(shouldUseStreamPath(command, false));
    try std.testing.expect(shouldUseStreamPath(command, true));
    try std.testing.expect(shouldUseProxyStream(command, false));
    try std.testing.expect(shouldUseProxyStream(command, true));

    const single = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expect(shouldUseStreamPath(single, false));
    try std.testing.expect(!shouldUseStreamPath(single, true));
    try std.testing.expect(shouldUseProxyStream(single, false));
    try std.testing.expect(!shouldUseProxyStream(single, true));

    const forced = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "-tt",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expect(shouldUseStreamPath(forced, false));
    try std.testing.expect(!shouldUseStreamPath(forced, true));
    try std.testing.expect(shouldUseProxyStream(forced, false));
    try std.testing.expect(!shouldUseProxyStream(forced, true));
}

test "no terminal emulator forces stream path and preserves ssh tty semantics" {
    const terminal_emulator = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--terminal-emulator",
        "example.com",
    }, .{});
    try std.testing.expect(terminal_emulator.terminal_emulator);
    try std.testing.expect(terminal_emulator.terminal_emulator_set);
    try std.testing.expect(!shouldUseStreamPath(terminal_emulator, true));
    try std.testing.expect(!shouldUseStreamPath(terminal_emulator, false));

    const interactive = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    try std.testing.expect(!interactive.terminal_emulator);
    try std.testing.expect(interactive.terminal_emulator_set);
    try std.testing.expect(shouldUseStreamPath(interactive, true));
    try std.testing.expect(shouldUseStreamPath(interactive, false));
    try std.testing.expect(shouldUseProxyStream(interactive, true));
    try std.testing.expect(shouldUseProxyStream(interactive, false));

    const command = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
        "echo",
        "hello",
    }, .{});
    try std.testing.expect(!command.terminal_emulator);
    try std.testing.expect(shouldUseStreamPath(command, true));
    try std.testing.expect(shouldUseProxyStream(command, true));

    const forced = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-tt",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expect(!forced.terminal_emulator);
    try std.testing.expect(shouldUseStreamPath(forced, false));
    try std.testing.expect(shouldUseProxyStream(forced, false));

    const requested_with_tty = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-t",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expect(!requested_with_tty.terminal_emulator);
    try std.testing.expect(shouldUseStreamPath(requested_with_tty, true));
    try std.testing.expect(shouldUseProxyStream(requested_with_tty, true));

    const requested_without_tty = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-t",
        "example.com",
        "tty",
    }, .{});
    try std.testing.expect(shouldUseStreamPath(requested_without_tty, false));
    try std.testing.expect(shouldUseProxyStream(requested_without_tty, false));
}

test "parseSshArgs permits explicit safe config overrides" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
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
    var parsed = SessionInvocation{
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

test "parseSshConfig returns resolved endpoint and first configured ipqos value" {
    var resolved = try parseSshConfig(std.testing.allocator,
        \\hostname example.com
        \\port 2200
        \\ipqos ef cs0
        \\user tomm
        \\
    , &.{}, "alias");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example.com", resolved.hostname);
    try std.testing.expectEqualStrings("2200", resolved.port);
    try std.testing.expectEqualStrings("ef", resolved.ipqos.?);
}

test "parseSshConfig defaults endpoint fields" {
    var resolved = try parseSshConfig(std.testing.allocator,
        \\user tomm
        \\
    , &.{ "-p", "2022" }, "alias");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alias", resolved.hostname);
    try std.testing.expectEqualStrings("2022", resolved.port);
    try std.testing.expectEqual(@as(?[]u8, null), resolved.ipqos);
}

test "explicitSshPort parses common ssh port options" {
    try std.testing.expectEqualStrings("2022", explicitSshPort(&.{ "-p", "2022" }).?);
    try std.testing.expectEqualStrings("2023", explicitSshPort(&.{"-p2023"}).?);
    try std.testing.expectEqualStrings("2024", explicitSshPort(&.{ "-o", "Port=2024" }).?);
    try std.testing.expectEqualStrings("2025", explicitSshPort(&.{"-oPort 2025"}).?);
    try std.testing.expectEqual(@as(?[]const u8, null), explicitSshPort(&.{"-p0"}));
}

test "parseSshArgs treats post-host mux words as remote command" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "attach",
        "s12",
        "--no-bootstrap",
    }, .{});

    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(SessionAction.new, parsed.action);
    try std.testing.expect(parsed.bootstrap);
    try std.testing.expect(!parsed.bootstrap_set);
    try expectArgvEqual(&.{ "attach", "s12", "--no-bootstrap" }, parsed.shell_command_args);
}

test "brokerArgsForAction uses broker subcommands" {
    try expectBrokerArgs(&.{ "list", "--host-display", "example.com" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
    });
    try expectBrokerArgs(&.{ "list", "--host-display", "example.com", "--jsonl" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
    });
    try expectBrokerArgs(&.{ "list", "--host-display", "example.com", "--jsonl", "--all" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_all = true,
    });
    try expectBrokerArgs(&.{ "list", "--host-display", "example.com", "--jsonl", "--exited" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_exited = true,
    });

    try expectBrokerArgs(&.{ "kill", "s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .kill,
        .kill_id = "s1",
        .kill_ids = &.{"s1"},
    });

    try expectBrokerArgs(&.{ "kill", "--jsonl", "s1", "p1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .kill,
        .kill_id = "s1",
        .kill_ids = &.{ "s1", "p1" },
        .kill_jsonl = true,
    });

    const request_json = "{\"guid\":\"s-00000000-0000-4000-8000-000000000001\",\"requested_age_ms\":123}";
    try expectBrokerArgs(&.{ "kill", "--jsonl", "--request", request_json }, .{
        .options = &.{},
        .host = "example.com",
        .action = .kill,
        .kill_jsonl = true,
        .kill_request_jsons = &.{request_json},
    });

    try expectBrokerArgs(&.{ "kill", "--current" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .kill,
        .kill_current = true,
    });

    try expectBrokerArgs(&.{ "kill", "--all" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .kill_all,
    });

    try expectBrokerArgs(&.{ "list", "--host-display", "example.com", "--jsonl", "--client=s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_client_target = "s1",
        .list_client_option_arg = "--client=s1",
    });

    try expectBrokerArgs(&.{ "list", "--host-display", "example.com", "--jsonl", "--client", "s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .list,
        .list_jsonl = true,
        .list_client_target = "s1",
        .list_client_option_arg = "--client",
    });

    try expectBrokerArgs(&.{ "debug", "unresponsive-connection", "c1", "s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .debug_client_action = .unresponsive_connection,
        .client_target = .client_guid,
        .client_guid = "c1",
        .client_session_ref = "s1",
    });

    try expectBrokerArgs(&.{ "detach", "c1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .detach_client,
        .client_target = .client_guid,
        .client_guid = "c1",
    });

    try expectBrokerArgs(&.{ "debug", "unresponsive-connection", "--last-input", "--seconds", "3", "s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .debug_client_action = .unresponsive_connection,
        .debug_unresponsive_seconds = "3",
        .client_target = .last_input,
        .client_session_ref = "s1",
    });

    try expectBrokerArgs(&.{ "repaint", "--last-input", "--scrollback", "s1" }, .{
        .options = &.{},
        .host = "example.com",
        .action = .repaint_client,
        .client_target = .last_input,
        .client_repaint_scrollback = true,
        .client_session_ref = "s1",
    });
}

fn expectBrokerArgs(expected: []const []const u8, parsed: SessionInvocation) !void {
    const actual = try brokerArgsForAction(std.testing.allocator, parsed);
    defer std.testing.allocator.free(actual);
    try expectArgvEqual(expected, actual);
}

test "proxy stream reconnect status follows filter level" {
    try std.testing.expectEqual(stream_agent.StreamReconnectStatusMode.disabled, proxyStreamReconnectStatusMode(.raw, false));
    try std.testing.expectEqual(stream_agent.StreamReconnectStatusMode.stderr_plain, proxyStreamReconnectStatusMode(.unhygienic, false));
    try std.testing.expectEqual(stream_agent.StreamReconnectStatusMode.stderr_plain, proxyStreamReconnectStatusMode(.hygienic, false));
    try std.testing.expectEqual(stream_agent.StreamReconnectStatusMode.client_control, proxyStreamReconnectStatusMode(.hygienic, true));
    try std.testing.expectEqual(stream_agent.StreamReconnectStatusMode.client_control, proxyStreamReconnectStatusMode(.emulated, true));
}

test "terminal reconnect presentation follows filter level" {
    try std.testing.expectEqual(client_ui.ReconnectPresentation.none, reconnectPresentationForFilterLevel(.raw));
    try std.testing.expectEqual(client_ui.ReconnectPresentation.stderr_plain, reconnectPresentationForFilterLevel(.unhygienic));
    try std.testing.expectEqual(client_ui.ReconnectPresentation.title, reconnectPresentationForFilterLevel(.hygienic));
    try std.testing.expectEqual(client_ui.ReconnectPresentation.overlay, reconnectPresentationForFilterLevel(.emulated));
}

test "proxy diagnostics plan maps emulated to hygienic client socket" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
    }, .{});

    const interactive = proxyDiagnosticsPlan(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.hygienic, interactive.command_level);
    try std.testing.expect(interactive.use_client_socket);
    try std.testing.expect(interactive.wrap_visible_ssh);
    try std.testing.expect(interactive.client_ctrl_r);

    const no_stdout = proxyDiagnosticsPlan(parsed, true, false);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, no_stdout.command_level);
    try std.testing.expect(!no_stdout.use_client_socket);
    try std.testing.expect(!no_stdout.wrap_visible_ssh);
    try std.testing.expect(!no_stdout.client_ctrl_r);
}

test "proxy diagnostics plan honors raw and unhygienic levels" {
    const raw = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "raw",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    try std.testing.expectEqual(config.FilterLevel.raw, raw.filter_level);
    const raw_plan = proxyDiagnosticsPlan(raw, true, true);
    try std.testing.expectEqual(config.FilterLevel.raw, raw_plan.command_level);
    try std.testing.expect(!raw_plan.use_client_socket);

    const unhygienic = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "unhygienic",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    try std.testing.expectEqual(config.FilterLevel.unhygienic, unhygienic.filter_level);
    const noisy_plan = proxyDiagnosticsPlan(unhygienic, true, true);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, noisy_plan.command_level);
    try std.testing.expect(!noisy_plan.use_client_socket);
}

test "proxy diagnostics plan disables ctrl-r when visible ssh is not wrapped" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "-T",
        "example.com",
    }, .{});

    const plan = proxyDiagnosticsPlan(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.hygienic, plan.command_level);
    try std.testing.expect(plan.use_client_socket);
    try std.testing.expect(!plan.wrap_visible_ssh);
    try std.testing.expect(!plan.client_ctrl_r);
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

test "parseSshArgs accepts ssh-style remote commands without a tty request" {
    const parsed = try parseSshArgs(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "uname",
    }, .{});
    try std.testing.expectEqual(SshTtyRequest.none, parsed.tty_request);
    try std.testing.expectEqual(@as(usize, 1), parsed.shell_command_args.len);
    try std.testing.expectEqualStrings("uname", parsed.shell_command_args[0]);
}
