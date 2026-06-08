const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const attached_client = @import("../session/attached_client.zig");
const transport_bootstrap = @import("bootstrap.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
const proxy_control = @import("../stream/proxy_control.zig");
const sessh_cli = @import("../sessh/cli.zig");
const config = @import("../core/config.zig");
const daemon_client = @import("../daemon/client.zig");
const daemon_executable = @import("../daemon/executable.zig");
const daemon_log = @import("../daemon/log.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const frame_forwarder = @import("frame_forwarder.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");
const protocol = @import("../protocol/mod.zig");
const plain_ssh = @import("plain_ssh.zig");
const reconnect = @import("../reconnect/mod.zig");
const remote_shell = @import("remote_shell.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("socket.zig");
const ssh_opts = @import("ssh_options.zig");
const stream_runtime = @import("../stream/runtime.zig");
const tty_transcript = @import("../tty/transcript.zig");
const pb = protocol.pb;

const CommonSessionOptions = sessh_cli.CommonSessionOptions;
const terminal_tunnel_idle_close_ms: i32 = 60_000;

pub const SshTtyRequest = ssh_opts.SshTtyRequest;
pub const ResolvedSshConfig = ssh_opts.ResolvedSshConfig;
pub const classifySshOptions = ssh_opts.classifySshOptions;
pub const resolveSshConfig = ssh_opts.resolveSshConfig;

const appendTransportSshOptions = ssh_opts.appendTransportSshOptions;
const isProxyRequiredSshFlag = ssh_opts.isProxyRequiredSshFlag;
const isProxyRequiredSshOptionWithValue = ssh_opts.isProxyRequiredSshOptionWithValue;
const isSshTtyRequestOption = ssh_opts.isSshTtyRequestOption;
const isUnsafeSshOptionWithValue = ssh_opts.isUnsafeSshOptionWithValue;
const sshConfigKey = ssh_opts.sshConfigKey;
const sshConfigKeyIs = ssh_opts.sshConfigKeyIs;
const sshConfigOptionRequiresProxy = ssh_opts.sshConfigOptionRequiresProxy;
const sshConfigValueIs = ssh_opts.sshConfigValueIs;
const sshOptionRequiresValue = ssh_opts.sshOptionRequiresValue;
const sshOptionSeparateValueIndex = ssh_opts.sshOptionSeparateValueIndex;
const transportSshOptionsLen = ssh_opts.transportSshOptionsLen;

const BootstrapEntrypoint = remote_shell.Entrypoint;
const bootstrapCommand = remote_shell.bootstrapCommand;
const directBrokerCommand = remote_shell.directBrokerCommand;
const isPlainShellArg = remote_shell.isPlainShellArg;
const joinRemoteShellCommandArgs = remote_shell.joinRemoteShellCommandArgs;
const shellCommandFromRemoteArgs = remote_shell.shellCommandFromRemoteArgs;
const shellQuote = remote_shell.shellQuote;
const shCommand = remote_shell.shCommand;

const ArtifactSet = transport_bootstrap.ArtifactSet;
const Platform = transport_bootstrap.Platform;
const artifactFilenameForPlatform = transport_bootstrap.artifactFilenameForPlatform;
const loadArtifactSet = transport_bootstrap.loadArtifactSet;
const parseMissingPlatform = transport_bootstrap.parseMissingPlatform;
const readBootstrapLine = transport_bootstrap.readBootstrapLine;
const sendUpload = transport_bootstrap.sendUpload;

const SshTarget = struct {
    options: []const []const u8,
    host: []const u8,
    default_ipqos_option: ?[]const u8 = null,
    resolved_user: []const u8 = "",
    resolved_host: []const u8 = "",
    resolved_port: []const u8 = session_registry.default_ssh_port,
};

const ResolvedSshTarget = struct {
    target: SshTarget,
    config: ResolvedSshConfig,
    default_ipqos_option: ?[]const u8 = null,

    fn deinit(self: *ResolvedSshTarget, allocator: std.mem.Allocator) void {
        if (self.default_ipqos_option) |option| allocator.free(option);
        self.config.deinit(allocator);
        self.* = undefined;
    }
};

const SessionRuntimeConfig = struct {
    common: CommonSessionOptions,
    disconnected_reap_ms: u64 = config.default_disconnected_reap_ms,
};

const RemoteNewSession = struct {
    command_argv: []const []const u8 = &.{},
    shell_command_args: []const []const u8 = &.{},
    tty_request: SshTtyRequest = .none,
    proxy_required: bool = false,
};

const BootstrapFailurePolicy = struct {
    unsupported_action: []const u8,
    allow_plain_ssh_fallback: bool = false,
    return_unsupported_error: bool = false,
    return_bootstrap_error: bool = false,
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

const TerminalTransport = struct {
    fd: c.fd_t = -1,

    fn readFd(self: *const TerminalTransport) c.fd_t {
        return self.fd;
    }

    fn writeFd(self: *const TerminalTransport) c.fd_t {
        return self.fd;
    }

    fn closeStdin(self: *TerminalTransport) void {
        if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT.WR);
    }

    fn close(self: *TerminalTransport) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    fn terminate(self: *TerminalTransport) void {
        self.close();
    }
};

const TerminalTransportStart = struct {
    connection: RuntimeConnection,
    diagnostic_fd: c.fd_t,
    diagnostic_write_fd: c.fd_t,

    remote_daemon_namespace: ?[]u8 = null,

    fn deinitNamespace(self: *TerminalTransportStart, allocator: std.mem.Allocator) void {
        if (self.remote_daemon_namespace) |namespace| {
            allocator.free(namespace);
            self.remote_daemon_namespace = null;
        }
    }
};

const PooledTerminalClientState = enum {
    pending_ready,
    handshaking,
    active,
    done,
};

const PooledTerminalClientKind = enum {
    unknown,
    te,
    proxy,
};

const PooledTerminalClient = struct {
    fd: c.fd_t,
    stream_id: u64 = 0,
    local_stream_id: u64 = 0,
    kind: PooledTerminalClientKind = .unknown,
    state: PooledTerminalClientState = .pending_ready,
    outbound_next_offset: u64 = 0,
    inbound_next_offset: u64 = 0,
    request_started_ms: u64 = 0,
    ready_sent_ms: u64 = 0,
    mux_open_sent_ms: u64 = 0,
    mux_open_ok_ms: u64 = 0,
    first_payload_ms: u64 = 0,
    startup_timing_logged: bool = false,
    session_ended: bool = false,
    done: bool = false,

    fn deinit(self: *PooledTerminalClient) void {
        self.* = undefined;
    }
};

const TerminalTunnelState = enum {
    starting,
    ready,
    closed,
};

const TerminalTunnel = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    display_host: []u8,
    resolved_user: []u8,
    resolved_host: []u8,
    resolved_port: []u8,
    state: TerminalTunnelState = .starting,
    clients: std.ArrayList(*PooledTerminalClient) = .empty,
    wake_pipe: [2]c.fd_t,
    connection: ?RuntimeConnection = null,
    diagnostic_fd: c.fd_t = -1,
    diagnostic_write_fd: c.fd_t = -1,
    remote_daemon_namespace: ?[]u8 = null,
    next_stream_id: u64 = 1,

    fn deinit(self: *TerminalTunnel) void {
        if (self.connection) |*connection| connection.terminate();
        if (self.remote_daemon_namespace) |namespace| self.allocator.free(namespace);
        if (self.diagnostic_fd >= 0) posix.close(self.diagnostic_fd);
        if (self.diagnostic_write_fd >= 0) posix.close(self.diagnostic_write_fd);
        posix.close(self.wake_pipe[0]);
        posix.close(self.wake_pipe[1]);
        self.clients.deinit(self.allocator);
        self.allocator.free(self.resolved_port);
        self.allocator.free(self.resolved_host);
        self.allocator.free(self.resolved_user);
        self.allocator.free(self.display_host);
        self.allocator.free(self.key);
        self.* = undefined;
    }
};

const TerminalTunnelAcquire = struct {
    tunnel: *TerminalTunnel,
    created: bool,
};

var terminal_pool_mutex = std.Thread.Mutex{};
var terminal_pool_condition = std.Thread.Condition{};
var terminal_tunnels: std.ArrayList(*TerminalTunnel) = .empty;
var active_terminal_tunnels: std.atomic.Value(usize) = .init(0);

pub fn activeTerminalTunnelCount() usize {
    return active_terminal_tunnels.load(.acquire);
}

fn resolveSshTarget(
    allocator: std.mem.Allocator,
    options: []const []const u8,
    host: []const u8,
) !ResolvedSshTarget {
    var resolved_config = try resolveSshConfig(allocator, options, host);
    errdefer resolved_config.deinit(allocator);
    const default_ipqos_option = try resolved_config.defaultIpQosOption(allocator);
    errdefer if (default_ipqos_option) |option| allocator.free(option);
    return .{
        .target = .{
            .options = options,
            .host = host,
            .default_ipqos_option = default_ipqos_option,
            .resolved_user = resolved_config.user,
            .resolved_host = resolved_config.hostname,
            .resolved_port = resolved_config.port,
        },
        .config = resolved_config,
        .default_ipqos_option = default_ipqos_option,
    };
}

const SshStderrMode = enum(u8) {
    forward,
    diagnostics,
    pipe,
    discard,
};

const reconnect_ready_switch_delay_ms: u64 = 10_000;

const SshStderrPump = struct {
    allocator: std.mem.Allocator,
    state: *State,
    thread: std.Thread,

    const State = struct {
        fd: c.fd_t,
        diagnostic_fd: c.fd_t,
        mode: std.atomic.Value(u8),
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    fn start(allocator: std.mem.Allocator, file: std.fs.File, mode: SshStderrMode, diagnostic_fd: c.fd_t) !SshStderrPump {
        errdefer file.close();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .fd = file.handle,
            .diagnostic_fd = diagnostic_fd,
            .mode = std.atomic.Value(u8).init(@intFromEnum(mode)),
        };

        const thread = try std.Thread.spawn(.{}, stderrPumpMain, .{state});
        return .{ .allocator = allocator, .state = state, .thread = thread };
    }

    fn suppress(self: *SshStderrPump) void {
        const current: SshStderrMode = @enumFromInt(self.state.mode.load(.acquire));
        if (current == .pipe) return;
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
            .pipe => if (state.diagnostic_fd >= 0) io.writeAll(state.diagnostic_fd, bytes) catch {},
            .discard => {},
        }
    }
}

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper installs or finds the remote sessh binary, then execs
/// the internal `:internal-broker:` entrypoint we send in the EXEC line.
/// Installed packages keep one executable per supported platform under
/// `libexec/sessh/<os>-<arch>/sessh`. If that layout is unavailable, upload the
/// current binary for same-platform development tests.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return runWithParseOptions(allocator, args);
}

fn runWithParseOptions(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var scratch = sessh_cli.Scratch{ .allocator = allocator };
    defer scratch.deinit();
    const parsed_sessh = sessh_cli.parse(&scratch, args) catch |err| {
        try printSshArgError(err);
        return process_exit.request(64);
    };
    if (std.mem.eql(u8, parsed_sessh.host, ".")) {
        try io.writeAll(2, "sessh: \".\" is not a valid ssh host\n");
        return process_exit.request(64);
    }
    return runRemoteNewSession(
        allocator,
        args[0],
        parsed_sessh.ssh_options,
        parsed_sessh.host,
        parsed_sessh.common,
        .{
            .shell_command_args = parsed_sessh.command_args,
            .tty_request = parsed_sessh.tty_request,
            .proxy_required = parsed_sessh.proxy_required,
        },
        .{
            .unsupported_action = "start a persistent sessh session",
            .allow_plain_ssh_fallback = parsed_sessh.command_args.len == 0,
        },
    );
}

fn remoteSessionConfig(
    allocator: std.mem.Allocator,
    common: CommonSessionOptions,
    ssh_options: []const []const u8,
) !SessionRuntimeConfig {
    var result = SessionRuntimeConfig{
        .common = common,
    };
    const file_config = try client_config.loadFileConfig(allocator);
    if (!result.common.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| result.common.scrollback_row_count = count;
    }
    if (!result.common.initial_scrollback_row_count_set and file_config.initial_scrollback_row_count_set) {
        result.common.initial_scrollback_row_count = file_config.initial_scrollback_row_count;
    }
    if (!result.common.bootstrap_set) {
        if (file_config.bootstrap) |enabled| result.common.bootstrap = enabled;
    }
    if (!result.common.terminal_emulator_set) {
        if (file_config.terminal_emulator) |enabled| result.common.terminal_emulator = enabled;
    }
    if (!result.common.filter_level_set) {
        if (file_config.filter_level) |level| result.common.filter_level = level;
    }
    if (file_config.disconnected_reap_ms) |ms| result.disconnected_reap_ms = ms;
    if (!result.common.client_log_level_set) {
        if (file_config.client_log_level) |level| {
            result.common.client_log_level = level;
        } else {
            result.common.client_log_level = inferredClientLogLevel(ssh_options);
        }
    }
    return result;
}

fn runRemoteNewSession(
    allocator: std.mem.Allocator,
    exe: []const u8,
    ssh_options: []const []const u8,
    host: []const u8,
    common: CommonSessionOptions,
    new: RemoteNewSession,
    failure_policy: BootstrapFailurePolicy,
) !void {
    const runtime_config = remoteSessionConfig(allocator, common, ssh_options) catch |err| {
        try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    client_log.setLevel(runtime_config.common.client_log_level);

    var resolved_target = try resolveSshTarget(allocator, ssh_options, host);
    defer resolved_target.deinit(allocator);
    const target = resolved_target.target;

    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0;
    const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    if (shouldUseProxyStream(new, runtime_config.common, stdin_is_tty, stdout_is_tty)) {
        if (runtime_config.common.capture_tty_transcript != null) {
            try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with proxy stream mode\n");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, target, runtime_config.common, new);
    }

    const shell_command = try shellCommandFromRemoteArgs(allocator, new.shell_command_args);
    defer if (shell_command) |command| allocator.free(command);

    var local_terminal_probe = attached_client.LocalTerminalProbe.start(allocator);
    defer local_terminal_probe.deinit();

    var transcript_recorder: ?tty_transcript.Recorder = null;
    try setupTranscriptRecorder(allocator, runtime_config.common.capture_tty_transcript, &transcript_recorder);
    defer teardownTranscriptRecorder(&transcript_recorder);

    const new_guid = try session_registry.generateGuid(allocator);
    defer allocator.free(new_guid);

    var transport = try openTerminalDaemonTransport(
        allocator,
        exe,
        target,
        runtime_config.common,
        false,
        failure_policy.allow_plain_ssh_fallback,
        null,
    );

    var local_terminal = local_terminal_probe.finish();
    defer local_terminal.deinit();

    var session = attached_client.startNewSessionOnRuntime(
        transport.readFd(),
        transport.writeFd(),
        runtime_config.common.scrollback_row_count,
        new_guid,
        new.command_argv,
        shell_command,
        runtime_config.disconnected_reap_ms,
        &local_terminal,
    ) catch |err| {
        if (err == error.VersionMismatch) {
            transport.close();
            if (runtime_config.common.capture_tty_transcript != null) {
                try io.writeAll(2, "sessh: --capture-tty-transcript requires a compatible sessh runtime\n");
                return process_exit.request(1);
            }
            if (new.command_argv.len > 0 or shell_command != null) {
                try io.writeAll(2, "sessh: persistent command sessions require a compatible sessh runtime\n");
                return process_exit.request(1);
            }
            try runPlainSshFallbackAfterVersionMismatch(allocator, target);
        }
        waitAfterRuntimeAttachFailure(&transport, "start");
        if (process_exit.is(err)) return err;
        try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(target.host);
    try attached_client.ensureLocalRouteForRemoteSession(
        allocator,
        &session,
        target.host,
        target.resolved_host,
        target.resolved_port,
        target.options,
    );
    try runAttachedRemoteClient(
        allocator,
        exe,
        target,
        runtime_config,
        failure_policy,
        &transport,
        &session,
    );
}

pub fn serveTerminalTransportFromDaemon(
    allocator: std.mem.Allocator,
    client_fd: c.fd_t,
    request: pb.ClientTeTransportOpen,
) !void {
    var resolved_target = try resolveSshTarget(allocator, request.ssh_option.items, request.host);
    defer resolved_target.deinit(allocator);
    const target = resolved_target.target;
    daemon_log.infof(
        allocator,
        "terminal transport opening host={s} resolved={s}@{s}:{s} bootstrap={}",
        .{ target.host, target.resolved_user, target.resolved_host, target.resolved_port, request.bootstrap },
    );

    try servePooledTerminalTransportFromDaemon(allocator, client_fd, target, request);
}

fn startTerminalTransportForDaemon(
    allocator: std.mem.Allocator,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientTeTransportOpen,
) !TerminalTransportStart {
    var artifacts_storage: ?ArtifactSet = if (request.bootstrap) try loadArtifactSet(allocator) else null;
    defer if (artifacts_storage) |*artifacts| artifacts.deinit();
    const artifacts = if (artifacts_storage) |*value| value else null;

    var broker_socket_dir: ?[]u8 = null;
    errdefer if (broker_socket_dir) |dir| allocator.free(dir);
    var broker_arg_storage: [1][]const u8 = undefined;
    var broker_args: []const []const u8 = broker_arg_storage[0..0];
    if (request.bootstrap) {
        broker_socket_dir = try daemon_socket_namespace.defaultDirName(allocator);
        broker_arg_storage[0] = broker_socket_dir.?;
        broker_args = broker_arg_storage[0..1];
        daemon_log.infof(
            allocator,
            "remote daemon namespace host={s} namespace={s} env={s}",
            .{ target.host, broker_socket_dir.?, daemon_socket_namespace.namespace_env },
        );
    }

    const remote_command = if (request.bootstrap)
        try bootstrapCommand(allocator)
    else
        try directBrokerCommand(allocator, broker_args);
    defer allocator.free(remote_command);

    const diagnostic_pipe = try posix.pipe();
    errdefer posix.close(diagnostic_pipe[0]);
    errdefer posix.close(diagnostic_pipe[1]);
    setNonBlockingFd(diagnostic_pipe[0]) catch {};
    setNonBlockingFd(diagnostic_pipe[1]) catch {};
    socket_transport.setCloseOnExec(diagnostic_pipe[0]) catch {};
    socket_transport.setCloseOnExec(diagnostic_pipe[1]) catch {};

    var client_environment = try envMapFromTransportOpen(allocator, request);
    defer client_environment.deinit();

    var bootstrap_failure_term: ?std.process.Child.Term = null;
    const child = startRuntimeConnection(
        allocator,
        target,
        artifacts,
        remote_command,
        .broker,
        broker_args,
        request.batch_mode,
        null,
        false,
        .pipe,
        diagnostic_pipe[1],
        client_fd,
        &client_environment,
        &bootstrap_failure_term,
        .{
            .unsupported_action = "start a persistent sessh session",
            .return_unsupported_error = true,
            .return_bootstrap_error = true,
        },
    ) catch |err| switch (err) {
        error.UnsupportedRemotePlatform => {
            daemon_log.infof(allocator, "terminal transport failed host={s} error={t}", .{ target.host, err });
            try sendDaemonTransportError(
                client_fd,
                "UNSUPPORTED_REMOTE_PLATFORM",
                "remote platform is unsupported and no matching sessh binary is available",
                "",
            );
            return error.TerminalTransportStartReported;
        },
        else => {
            daemon_log.infof(allocator, "terminal transport failed host={s} error={t}", .{ target.host, err });
            try frame_forwarder.forwardRawTransportDiagnostics(client_fd, diagnostic_pipe[0]);
            if (try sendDaemonSshFailure(client_fd, allocator, target, bootstrap_failure_term)) return error.TerminalTransportStartReported;
            try sendDaemonTransportError(client_fd, "SSH_TRANSPORT_FAILED", "ssh transport failed", "");
            return err;
        },
    };

    try frame_forwarder.forwardRawTransportDiagnostics(client_fd, diagnostic_pipe[0]);
    const remote_daemon_namespace = broker_socket_dir;
    broker_socket_dir = null;
    return .{
        .connection = child,
        .diagnostic_fd = diagnostic_pipe[0],
        .diagnostic_write_fd = diagnostic_pipe[1],
        .remote_daemon_namespace = remote_daemon_namespace,
    };
}

fn servePooledTerminalTransportFromDaemon(
    allocator: std.mem.Allocator,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientTeTransportOpen,
) !void {
    const client = try allocator.create(PooledTerminalClient);
    errdefer allocator.destroy(client);
    client.* = .{
        .fd = client_fd,
        .request_started_ms = nowUnixMs(),
    };
    errdefer client.deinit();

    const acquire = try acquireTerminalTunnel(allocator, target, client);
    if (acquire.created) {
        startNewTerminalTunnel(allocator, acquire.tunnel, client_fd, target, request) catch |err| {
            failStartingTerminalTunnel(allocator, acquire.tunnel, client, err);
        };
    }

    waitForPooledTerminalClientDone(client);
    client.deinit();
    allocator.destroy(client);
}

fn acquireTerminalTunnel(
    allocator: std.mem.Allocator,
    target: SshTarget,
    client: *PooledTerminalClient,
) !TerminalTunnelAcquire {
    const key = try terminalTunnelKey(allocator, target);
    errdefer allocator.free(key);

    terminal_pool_mutex.lock();
    defer terminal_pool_mutex.unlock();

    for (terminal_tunnels.items) |tunnel| {
        if (tunnel.state == .closed) continue;
        if (!std.mem.eql(u8, tunnel.key, key)) continue;
        allocator.free(key);
        try tunnel.clients.append(allocator, client);
        daemon_log.infof(
            allocator,
            "terminal transport reusing pooled ssh transport host={s} pool={s} remote_namespace={s}",
            .{ target.host, tunnel.key, tunnel.remote_daemon_namespace orelse "remote-default" },
        );
        wakeTerminalTunnel(tunnel);
        return .{ .tunnel = tunnel, .created = false };
    }

    const tunnel = try allocator.create(TerminalTunnel);
    errdefer allocator.destroy(tunnel);
    const wake_pipe = try posix.pipe();
    errdefer {
        posix.close(wake_pipe[0]);
        posix.close(wake_pipe[1]);
    }
    setNonBlockingFd(wake_pipe[0]) catch {};
    setNonBlockingFd(wake_pipe[1]) catch {};
    socket_transport.setCloseOnExec(wake_pipe[0]) catch {};
    socket_transport.setCloseOnExec(wake_pipe[1]) catch {};

    tunnel.* = .{
        .allocator = allocator,
        .key = key,
        .display_host = try allocator.dupe(u8, target.host),
        .resolved_user = try allocator.dupe(u8, target.resolved_user),
        .resolved_host = try allocator.dupe(u8, target.resolved_host),
        .resolved_port = try allocator.dupe(u8, target.resolved_port),
        .wake_pipe = wake_pipe,
    };
    errdefer tunnel.deinit();
    try tunnel.clients.append(allocator, client);
    try terminal_tunnels.append(allocator, tunnel);
    _ = active_terminal_tunnels.fetchAdd(1, .acq_rel);
    daemon_log.infof(
        allocator,
        "terminal transport creating pooled ssh transport host={s} pool={s}",
        .{ target.host, tunnel.key },
    );
    return .{ .tunnel = tunnel, .created = true };
}

fn terminalTunnelKey(allocator: std.mem.Allocator, target: SshTarget) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}@{s}:{s}",
        .{ target.resolved_user, target.resolved_host, target.resolved_port },
    );
}

fn startNewTerminalTunnel(
    allocator: std.mem.Allocator,
    tunnel: *TerminalTunnel,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientTeTransportOpen,
) !void {
    var started = try startTerminalTransportForDaemon(allocator, client_fd, target, request);
    errdefer {
        started.connection.terminate();
        posix.close(started.diagnostic_fd);
        posix.close(started.diagnostic_write_fd);
        started.deinitNamespace(allocator);
    }

    try initiatePooledRemoteDaemonHandshake(
        allocator,
        started.connection.child.stdout.?.handle,
        started.connection.child.stdin.?.handle,
    );

    terminal_pool_mutex.lock();
    tunnel.connection = started.connection;
    tunnel.diagnostic_fd = started.diagnostic_fd;
    tunnel.diagnostic_write_fd = started.diagnostic_write_fd;
    tunnel.remote_daemon_namespace = started.remote_daemon_namespace;
    started.remote_daemon_namespace = null;
    tunnel.state = .ready;
    terminal_pool_condition.broadcast();
    terminal_pool_mutex.unlock();

    daemon_log.infof(
        allocator,
        "terminal transport ready host={s} remote_namespace={s}",
        .{ target.host, tunnel.remote_daemon_namespace orelse "remote-default" },
    );
    const thread = try std.Thread.spawn(.{}, terminalTunnelThreadMain, .{tunnel});
    thread.detach();
    wakeTerminalTunnel(tunnel);
}

fn failStartingTerminalTunnel(
    allocator: std.mem.Allocator,
    tunnel: *TerminalTunnel,
    starter: *PooledTerminalClient,
    err: anyerror,
) void {
    terminal_pool_mutex.lock();
    tunnel.state = .closed;
    removeTerminalTunnelLocked(tunnel);
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        if (client != starter or err != error.TerminalTransportStartReported) {
            sendDaemonTransportError(client.fd, "SSH_TRANSPORT_FAILED", "ssh transport failed", "") catch {};
        }
        markPooledTerminalClientDoneLocked(tunnel, client);
    }
    _ = active_terminal_tunnels.fetchSub(1, .acq_rel);
    terminal_pool_condition.broadcast();
    terminal_pool_mutex.unlock();
    tunnel.deinit();
    allocator.destroy(tunnel);
}

fn waitForPooledTerminalClientDone(client: *PooledTerminalClient) void {
    terminal_pool_mutex.lock();
    defer terminal_pool_mutex.unlock();
    while (!client.done) {
        terminal_pool_condition.wait(&terminal_pool_mutex);
    }
}

fn terminalTunnelThreadMain(tunnel: *TerminalTunnel) void {
    runTerminalTunnel(tunnel) catch |err| {
        daemon_log.infof(
            tunnel.allocator,
            "terminal pooled ssh transport failed host={s} pool={s} error={t}",
            .{ tunnel.display_host, tunnel.key, err },
        );
    };
    finishTerminalTunnel(tunnel);
}

fn runTerminalTunnel(tunnel: *TerminalTunnel) !void {
    try activatePendingTerminalClients(tunnel);

    while (true) {
        var poll_clients: std.ArrayList(*PooledTerminalClient) = .empty;
        defer poll_clients.deinit(tunnel.allocator);
        {
            terminal_pool_mutex.lock();
            defer terminal_pool_mutex.unlock();
            for (tunnel.clients.items) |client| {
                if (client.state != .done and client.state != .pending_ready) {
                    try poll_clients.append(tunnel.allocator, client);
                }
            }
        }

        const remote_read_fd = tunnel.connection.?.child.stdout.?.handle;
        const poll_count = 3 + poll_clients.items.len;
        const pollfds = try tunnel.allocator.alloc(posix.pollfd, poll_count);
        defer tunnel.allocator.free(pollfds);
        pollfds[0] = .{ .fd = remote_read_fd, .events = posix.POLL.IN, .revents = 0 };
        pollfds[1] = .{ .fd = tunnel.wake_pipe[0], .events = posix.POLL.IN, .revents = 0 };
        pollfds[2] = .{ .fd = tunnel.diagnostic_fd, .events = posix.POLL.IN, .revents = 0 };
        var index: usize = 3;
        for (poll_clients.items) |client| {
            pollfds[index] = .{ .fd = client.fd, .events = posix.POLL.IN, .revents = 0 };
            index += 1;
        }

        const poll_timeout_ms: i32 = if (poll_clients.items.len == 0) terminal_tunnel_idle_close_ms else -1;
        const ready = try posix.poll(pollfds, poll_timeout_ms);
        if (ready == 0 and tryCloseIdleTerminalTunnel(tunnel)) {
            daemon_log.infof(
                tunnel.allocator,
                "terminal pooled ssh transport idle host={s} pool={s}",
                .{ tunnel.display_host, tunnel.key },
            );
            return;
        }

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            drainTerminalTunnelWake(tunnel);
            try activatePendingTerminalClients(tunnel);
        }

        if ((pollfds[2].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            try forwardPooledTerminalDiagnostics(tunnel);
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try readPooledRemoteMuxFrame(tunnel)) {
                notifyPooledTerminalRemoteClosed(tunnel);
                return;
            }
        }

        index = 3;
        for (poll_clients.items) |client| {
            const revents = pollfds[index].revents;
            index += 1;
            if ((revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) continue;
            try handlePooledTerminalClientReadable(tunnel, client);
        }
    }
}

fn tryCloseIdleTerminalTunnel(tunnel: *TerminalTunnel) bool {
    terminal_pool_mutex.lock();
    defer terminal_pool_mutex.unlock();
    if (tunnel.clients.items.len != 0) return false;
    tunnel.state = .closed;
    removeTerminalTunnelLocked(tunnel);
    return true;
}

fn activatePendingTerminalClients(tunnel: *TerminalTunnel) !void {
    terminal_pool_mutex.lock();
    defer terminal_pool_mutex.unlock();
    for (tunnel.clients.items) |client| {
        if (client.state != .pending_ready) continue;
        client.stream_id = tunnel.next_stream_id;
        tunnel.next_stream_id += 1;
        client.state = .handshaking;
        sendTerminalTransportReady(client.fd) catch {
            markPooledTerminalClientDoneLocked(tunnel, client);
            continue;
        };
        client.ready_sent_ms = nowUnixMs();
    }
    terminal_pool_condition.broadcast();
}

fn handlePooledTerminalClientReadable(tunnel: *TerminalTunnel, client: *PooledTerminalClient) !void {
    switch (client.state) {
        .handshaking => try openPooledTerminalClientStream(tunnel, client),
        .active => try forwardPooledTerminalClientFrame(tunnel, client),
        .pending_ready, .done => {},
    }
}

fn openPooledTerminalClientStream(tunnel: *TerminalTunnel, client: *PooledTerminalClient) !void {
    acceptPooledClientHandshake(tunnel.allocator, client.fd) catch |err| switch (err) {
        error.EndOfStream => {
            finishPooledTerminalClient(tunnel, client, true);
            return;
        },
        else => return err,
    };

    var frame = protocol.readFrameAlloc(tunnel.allocator, client.fd) catch |err| switch (err) {
        error.EndOfStream => {
            finishPooledTerminalClient(tunnel, client, true);
            return;
        },
        else => return err,
    };
    defer frame.deinit(tunnel.allocator);
    if (frame.message_type != .te_stream_open) {
        if (frame.message_type == .mux_stream_frame) {
            try sendPooledProxyMuxOpen(tunnel, client, frame.payload);
            client.state = .active;
            return;
        }
        try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "expected terminal or proxy stream open", "");
        finishPooledTerminalClient(tunnel, client, false);
        return;
    }
    try sendPooledTeMuxOpen(tunnel, client, frame.payload);
    client.kind = .te;
    client.state = .active;
}

fn forwardPooledTerminalClientFrame(tunnel: *TerminalTunnel, client: *PooledTerminalClient) !void {
    var frame = protocol.readFrameAlloc(tunnel.allocator, client.fd) catch |err| switch (err) {
        error.EndOfStream => {
            finishPooledTerminalClient(tunnel, client, true);
            return;
        },
        else => return err,
    };
    defer frame.deinit(tunnel.allocator);
    switch (frame.message_type) {
        .ping, .pong => {
            _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, client.fd);
        },
        .mux_stream_frame => {
            if (client.kind != .proxy) {
                try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected proxy stream frame", "");
                finishPooledTerminalClient(tunnel, client, true);
                return;
            }
            try sendPooledProxyMuxFrame(tunnel, client, frame.payload);
        },
        .te_input,
        .te_resize,
        .te_repaint_request,
        .te_session_client_debug_sever_connection_request,
        .te_session_client_debug_unresponsive_connection_request,
        .te_session_hangup_request,
        .te_stream_item,
        => {
            if (client.kind != .te) {
                try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected terminal stream frame", "");
                finishPooledTerminalClient(tunnel, client, true);
                return;
            }
            try sendPooledTeMuxPayloadFromFrame(tunnel, client, frame.message_type, frame.payload);
        },
        else => {
            try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected terminal client frame", "");
            finishPooledTerminalClient(tunnel, client, true);
        },
    }
}

fn sendPooledTeMuxOpen(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    payload: []const u8,
) !void {
    var request = try protocol.decodePayload(pb.TeStreamOpen, tunnel.allocator, payload);
    defer request.deinit(tunnel.allocator);
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .open = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = 0,
            .detail = .{ .te = request },
        } },
    });
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledProxyMuxOpen(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    payload: []const u8,
) !void {
    var mux_frame = try protocol.decodePayload(pb.MuxStreamFrame, tunnel.allocator, payload);
    defer mux_frame.deinit(tunnel.allocator);
    const message = mux_frame.message orelse return error.UnexpectedDaemonFrame;
    const open = switch (message) {
        .open => |open| open,
        else => return error.UnexpectedDaemonFrame,
    };
    const detail = open.detail orelse return error.UnexpectedDaemonFrame;
    switch (detail) {
        .proxy => {},
        else => return error.UnexpectedDaemonFrame,
    }
    client.kind = .proxy;
    client.local_stream_id = mux_frame.stream_id;
    mux_frame.stream_id = client.stream_id;
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, mux_frame);
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledProxyMuxFrame(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    payload: []const u8,
) !void {
    var mux_frame = try protocol.decodePayload(pb.MuxStreamFrame, tunnel.allocator, payload);
    defer mux_frame.deinit(tunnel.allocator);
    if (mux_frame.stream_id != client.local_stream_id) return error.UnexpectedDaemonFrame;
    mux_frame.stream_id = client.stream_id;
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, mux_frame);
}

fn sendPooledTeMuxPayloadFromFrame(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    message_type: protocol.MessageType,
    payload: []const u8,
) !void {
    var item = try protocol.teStreamItemFromFramePayload(tunnel.allocator, message_type, payload);
    defer item.deinit(tunnel.allocator);
    try sendPooledTeMuxPayload(tunnel, client, item);
}

fn sendPooledTeMuxPayload(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    item: pb.TeStreamItem,
) !void {
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .te = item },
        } },
    });
    client.outbound_next_offset +|= 1;
}

fn readPooledRemoteMuxFrame(tunnel: *TerminalTunnel) !bool {
    var frame = protocol.readFrameAlloc(tunnel.allocator, tunnel.connection.?.child.stdout.?.handle) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(tunnel.allocator);
    if (frame.message_type != .mux_stream_frame) return error.UnexpectedDaemonFrame;
    var mux_frame = try protocol.decodePayload(pb.MuxStreamFrame, tunnel.allocator, frame.payload);
    defer mux_frame.deinit(tunnel.allocator);
    const client = findPooledTerminalClient(tunnel, mux_frame.stream_id) orelse return true;
    const message = mux_frame.message orelse return error.UnexpectedDaemonFrame;
    if (client.kind == .proxy) {
        switch (message) {
            .open_ok => {
                if (client.mux_open_ok_ms == 0) client.mux_open_ok_ms = nowUnixMs();
            },
            .payload => {
                if (client.first_payload_ms == 0) {
                    client.first_payload_ms = nowUnixMs();
                    logPooledTerminalClientStartupTiming(tunnel, client);
                }
            },
            .reset => {
                if (client.first_payload_ms == 0) client.first_payload_ms = nowUnixMs();
            },
            .open, .ack => {},
        }
        mux_frame.stream_id = client.local_stream_id;
        try sendPooledMuxFrame(tunnel.allocator, client.fd, mux_frame);
        return true;
    }
    switch (message) {
        .open_ok => {
            if (client.mux_open_ok_ms == 0) client.mux_open_ok_ms = nowUnixMs();
        },
        .ack => {},
        .payload => |payload| {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledTerminalClientStartupTiming(tunnel, client);
            }
            const item = payload.item orelse return error.UnexpectedDaemonFrame;
            const te_item = switch (item) {
                .te => |te| te,
                else => return error.UnexpectedDaemonFrame,
            };
            client.inbound_next_offset = @max(client.inbound_next_offset, payload.offset +| 1);
            try protocol.sendTeStreamItemFrame(tunnel.allocator, client.fd, te_item);
            const te_payload = te_item.payload orelse return true;
            if (te_payload == .session_ended) {
                client.session_ended = true;
            }
        },
        .reset => |reset| {
            try sendDaemonTransportError(client.fd, reset.code, reset.message, reset.hint orelse "");
            finishPooledTerminalClient(tunnel, client, false);
        },
        .open => return error.UnexpectedDaemonFrame,
    }
    return true;
}

fn findPooledTerminalClient(tunnel: *TerminalTunnel, stream_id: u64) ?*PooledTerminalClient {
    terminal_pool_mutex.lock();
    defer terminal_pool_mutex.unlock();
    for (tunnel.clients.items) |client| {
        if (client.stream_id == stream_id and client.state != .done) return client;
    }
    return null;
}

fn finishPooledTerminalClient(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    send_hangup: bool,
) void {
    if (send_hangup and client.state == .active) {
        switch (client.kind) {
            .te => if (!client.session_ended) {
                daemon_log.infof(tunnel.allocator, "terminal client disconnected; requesting remote hangup host={s}", .{tunnel.display_host});
                sendPooledTeHangup(tunnel, client) catch {};
            },
            .proxy => {
                daemon_log.infof(tunnel.allocator, "proxy client disconnected; resetting remote stream host={s}", .{tunnel.display_host});
                sendPooledProxyReset(tunnel, client) catch {};
            },
            .unknown => {},
        }
    }
    terminal_pool_mutex.lock();
    markPooledTerminalClientDoneLocked(tunnel, client);
    terminal_pool_condition.broadcast();
    terminal_pool_mutex.unlock();
}

fn sendPooledTeHangup(tunnel: *TerminalTunnel, client: *PooledTerminalClient) !void {
    try sendPooledTeMuxPayload(tunnel, client, .{
        .payload = .{ .session_hangup_request = .{} },
    });
}

fn sendPooledProxyReset(tunnel: *TerminalTunnel, client: *PooledTerminalClient) !void {
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .reset = .{
            .code = "CLIENT_DISCONNECT",
            .message = "local proxy stream disconnected",
        } },
    });
}

fn notifyPooledTerminalRemoteClosed(tunnel: *TerminalTunnel) void {
    daemon_log.infof(tunnel.allocator, "ssh transport disconnected from daemon host={s}", .{tunnel.display_host});
    terminal_pool_mutex.lock();
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        sendClientTeTransportClosed(client.fd) catch {};
        markPooledTerminalClientDoneLocked(tunnel, client);
    }
    terminal_pool_condition.broadcast();
    terminal_pool_mutex.unlock();
}

fn forwardPooledTerminalDiagnostics(tunnel: *TerminalTunnel) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(tunnel.diagnostic_fd, &buf, buf.len);
        if (n < 0) {
            const errno = std.posix.errno(n);
            if (errno == .AGAIN) return;
            return error.ReadFailed;
        }
        if (n == 0) return;
        const bytes = buf[0..@intCast(n)];
        terminal_pool_mutex.lock();
        for (tunnel.clients.items) |client| {
            if (client.state == .done) continue;
            sendClientTeTransportDiagnostic(client.fd, bytes) catch {};
        }
        terminal_pool_mutex.unlock();
        if (@as(usize, @intCast(n)) < buf.len) return;
    }
}

fn sendClientTeTransportDiagnostic(fd: c.fd_t, chunk: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.ClientTeTransportDiagnostic{ .chunk = chunk });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .client_te_transport_diagnostic, payload);
}

fn sendClientTeTransportClosed(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.ClientTeTransportClosed{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .client_te_transport_closed, payload);
}

fn finishTerminalTunnel(tunnel: *TerminalTunnel) void {
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled ssh transport closed host={s} pool={s}",
        .{ tunnel.display_host, tunnel.key },
    );
    terminal_pool_mutex.lock();
    tunnel.state = .closed;
    removeTerminalTunnelLocked(tunnel);
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        markPooledTerminalClientDoneLocked(tunnel, client);
    }
    _ = active_terminal_tunnels.fetchSub(1, .acq_rel);
    terminal_pool_condition.broadcast();
    terminal_pool_mutex.unlock();
    tunnel.deinit();
    tunnel.allocator.destroy(tunnel);
}

fn markPooledTerminalClientDoneLocked(tunnel: *TerminalTunnel, client: *PooledTerminalClient) void {
    if (client.done) return;
    logPooledTerminalClientStartupTiming(tunnel, client);
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled client finished host={s} pool={s} stream_id={}",
        .{ tunnel.display_host, tunnel.key, client.stream_id },
    );
    client.state = .done;
    client.done = true;
    var index: usize = 0;
    while (index < tunnel.clients.items.len) : (index += 1) {
        if (tunnel.clients.items[index] != client) continue;
        _ = tunnel.clients.swapRemove(index);
        break;
    }
}

fn logPooledTerminalClientStartupTiming(tunnel: *TerminalTunnel, client: *PooledTerminalClient) void {
    if (client.startup_timing_logged) return;
    client.startup_timing_logged = true;
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled client startup host={s} pool={s} stream_id={} kind={s} request_to_ready_ms={} ready_to_open_ms={} open_to_open_ok_ms={} open_ok_to_first_payload_ms={} request_to_first_payload_ms={}",
        .{
            tunnel.display_host,
            tunnel.key,
            client.stream_id,
            pooledTerminalClientKindName(client.kind),
            elapsedMs(client.request_started_ms, client.ready_sent_ms),
            elapsedMs(client.ready_sent_ms, client.mux_open_sent_ms),
            elapsedMs(client.mux_open_sent_ms, client.mux_open_ok_ms),
            elapsedMs(client.mux_open_ok_ms, client.first_payload_ms),
            elapsedMs(client.request_started_ms, client.first_payload_ms),
        },
    );
}

fn pooledTerminalClientKindName(kind: PooledTerminalClientKind) []const u8 {
    return switch (kind) {
        .unknown => "unknown",
        .te => "te",
        .proxy => "proxy",
    };
}

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    if (start_ms == 0 or end_ms == 0 or end_ms < start_ms) return 0;
    return end_ms - start_ms;
}

fn removeTerminalTunnelLocked(tunnel: *TerminalTunnel) void {
    var index: usize = 0;
    while (index < terminal_tunnels.items.len) : (index += 1) {
        if (terminal_tunnels.items[index] != tunnel) continue;
        _ = terminal_tunnels.swapRemove(index);
        break;
    }
}

fn wakeTerminalTunnel(tunnel: *TerminalTunnel) void {
    const byte = [_]u8{1};
    _ = c.write(tunnel.wake_pipe[1], &byte, 1);
}

fn drainTerminalTunnelWake(tunnel: *TerminalTunnel) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = c.read(tunnel.wake_pipe[0], &buf, buf.len);
        if (n <= 0) return;
        if (@as(usize, @intCast(n)) < buf.len) return;
    }
}

fn sendPooledMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.MuxStreamFrame) !void {
    const payload = try protocol.encodePayload(allocator, message);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .mux_stream_frame, payload);
}

fn acceptPooledClientHandshake(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    var peer_hello = try readPooledHelloRequest(allocator, fd);
    defer peer_hello.deinit(allocator);
    if (!protocol.helloRequestIsCompatible(peer_hello, config.min_protocol_major, config.min_protocol_minor)) {
        try sendPooledHelloError(fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return error.VersionMismatch;
    }
    try sendPooledHelloOk(fd);
    try sendPooledHelloRequest(fd);
    var hello_error = try readPooledHelloReply(allocator, fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |_| return error.VersionMismatch;
}

fn initiatePooledRemoteDaemonHandshake(allocator: std.mem.Allocator, read_fd: c.fd_t, write_fd: c.fd_t) !void {
    try sendPooledHelloRequest(write_fd);
    var hello_error = try readPooledHelloReply(allocator, read_fd);
    defer if (hello_error) |*err| err.deinit(allocator);
    if (hello_error) |_| return error.VersionMismatch;
    var peer_hello = try readPooledHelloRequest(allocator, read_fd);
    defer peer_hello.deinit(allocator);
    if (!protocol.helloRequestIsCompatible(peer_hello, config.min_protocol_major, config.min_protocol_minor)) {
        try sendPooledHelloError(write_fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
        return error.VersionMismatch;
    }
    try sendPooledHelloOk(write_fd);
}

fn sendPooledHelloRequest(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), protocol.hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_request, payload);
}

fn sendPooledHelloOk(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), protocol.hpb.HelloOk{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_ok, payload);
}

fn sendPooledHelloError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), protocol.hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .hello_error, payload);
}

fn readPooledHelloRequest(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.hpb.HelloRequest {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_request => return protocol.decodePayload(protocol.hpb.HelloRequest, allocator, frame.payload),
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            else => return error.UnexpectedDaemonFrame,
        }
    }
}

fn readPooledHelloReply(allocator: std.mem.Allocator, fd: c.fd_t) !?protocol.hpb.HelloError {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(protocol.hpb.HelloOk, allocator, frame.payload);
                defer ok.deinit(allocator);
                return null;
            },
            .hello_error => return try protocol.decodePayload(protocol.hpb.HelloError, allocator, frame.payload),
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            else => return error.UnexpectedDaemonFrame,
        }
    }
}

fn openTerminalDaemonTransport(
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    batch_mode: bool,
    allow_plain_ssh_fallback: bool,
    reconnect_ui: ?*client_ui.ReconnectUi,
) !TerminalTransport {
    const fd = try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);

    var request = pb.ClientTeTransportOpen{
        .host = target.host,
        .bootstrap = common.bootstrap,
        .batch_mode = batch_mode,
    };
    defer request.ssh_option.deinit(allocator);
    defer deinitTransportOpenEnvironment(allocator, &request);
    try request.ssh_option.appendSlice(allocator, target.options);
    try appendCurrentEnvironmentToTransportOpen(allocator, &request);

    const payload = try protocol.encodePayload(allocator, request);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, .client_te_transport_open, payload);

    var bootstrap_status_visible = false;
    defer clearClientBootstrapStatus(&bootstrap_status_visible);

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return error.DaemonTransportClosed,
            else => return err,
        };
        defer frame.deinit(allocator);
        switch (frame.message_type) {
            .client_te_transport_ready => {
                var ready = try protocol.decodePayload(pb.ClientTeTransportReady, allocator, frame.payload);
                defer ready.deinit(allocator);
                return .{ .fd = fd };
            },
            .error_message => {
                var message = try protocol.decodePayload(protocol.hpb.Error, allocator, frame.payload);
                defer message.deinit(allocator);
                if (std.mem.eql(u8, message.code, "UNSUPPORTED_REMOTE_PLATFORM") and allow_plain_ssh_fallback) {
                    _ = c.close(fd);
                    try runPlainSshFallback(allocator, target, null);
                }
                if (reconnect_ui != null) {
                    return error.DaemonTransportFailed;
                }
                if (daemonTransportExitCode(message.code)) |exit_code| {
                    try printDaemonTransportError(message);
                    return process_exit.request(exit_code);
                }
                try printDaemonTransportError(message);
                return process_exit.request(1);
            },
            .client_te_transport_diagnostic => {
                try handleClientTeTransportDiagnostic(allocator, frame.payload, reconnect_ui, &bootstrap_status_visible);
            },
            .ping, .pong => {
                _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
            },
            else => return error.UnexpectedDaemonFrame,
        }
    }
}

fn printDaemonTransportError(message: protocol.hpb.Error) !void {
    try io.stderrPrint("sessh: {s}\n", .{message.message});
    if (message.hint) |hint| {
        if (hint.len > 0) try io.stderrPrint("{s}\n", .{hint});
    }
}

fn sendTerminalTransportReady(fd: c.fd_t) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.ClientTeTransportReady{});
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .client_te_transport_ready, payload);
}

fn sendDaemonTransportError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), protocol.hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}

fn sendDaemonSshFailure(
    fd: c.fd_t,
    allocator: std.mem.Allocator,
    target: SshTarget,
    term: ?std.process.Child.Term,
) !bool {
    const value = term orelse return false;
    switch (value) {
        .Exited => |code| {
            if (code == 0) return false;
            const message = try visibleSshFailureMessage(allocator, target, "exitcode", code);
            defer allocator.free(message);
            var code_buf: [64]u8 = undefined;
            const error_code = try std.fmt.bufPrint(&code_buf, "SSH_TRANSPORT_EXITED_{}", .{@min(code, 255)});
            try sendDaemonTransportError(fd, error_code, message, "");
            return true;
        },
        .Signal => |signal| {
            const message = try visibleSshFailureMessage(allocator, target, "signal", signal);
            defer allocator.free(message);
            try sendDaemonTransportError(fd, "SSH_TRANSPORT_EXITED_255", message, "");
            return true;
        },
        else => return false,
    }
}

fn daemonTransportExitCode(code: []const u8) ?u8 {
    const prefix = "SSH_TRANSPORT_EXITED_";
    if (!std.mem.startsWith(u8, code, prefix)) return null;
    const parsed = std.fmt.parseUnsigned(u16, code[prefix.len..], 10) catch return null;
    return @intCast(@min(parsed, 255));
}

fn handleClientTeTransportDiagnostic(
    allocator: std.mem.Allocator,
    payload: []const u8,
    reconnect_ui: ?*client_ui.ReconnectUi,
    bootstrap_status_visible: *bool,
) !void {
    var message = try protocol.decodePayload(pb.ClientTeTransportDiagnostic, allocator, payload);
    defer message.deinit(allocator);
    if (message.chunk.len == 0) return;
    if (reconnect_ui) |ui| {
        client_log.appendSshStderr(message.chunk);
        try ui.refreshOverlayIfDiagnosticsChanged();
        return;
    }
    clearClientBootstrapStatus(bootstrap_status_visible);
    try io.writeAll(2, message.chunk);
}

fn appendCurrentEnvironmentToTransportOpen(allocator: std.mem.Allocator, request: *pb.ClientTeTransportOpen) !void {
    var index: usize = 0;
    while (c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        const name = try allocator.dupe(u8, entry[0..equals]);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry[equals + 1 ..]);
        errdefer allocator.free(value);
        try request.environment.append(allocator, .{ .name = name, .value = value });
    }
}

fn deinitTransportOpenEnvironment(allocator: std.mem.Allocator, request: *pb.ClientTeTransportOpen) void {
    for (request.environment.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    request.environment.deinit(allocator);
}

fn envMapFromTransportOpen(allocator: std.mem.Allocator, request: pb.ClientTeTransportOpen) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    errdefer env.deinit();
    for (request.environment.items) |entry| {
        if (entry.name.len == 0) continue;
        try env.put(entry.name, entry.value);
    }
    return env;
}

fn setupTranscriptRecorder(
    allocator: std.mem.Allocator,
    capture_tty_transcript: ?[]const u8,
    transcript_recorder: *?tty_transcript.Recorder,
) !void {
    if (capture_tty_transcript) |path| {
        transcript_recorder.* = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder.*) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
}

fn teardownTranscriptRecorder(transcript_recorder: *?tty_transcript.Recorder) void {
    if (transcript_recorder.*) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
        transcript_recorder.* = null;
    }
}

fn runAttachedRemoteClient(
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    runtime_config: SessionRuntimeConfig,
    failure_policy: BootstrapFailurePolicy,
    transport: *TerminalTransport,
    session: *attached_client.RuntimeSession,
) !void {
    while (true) {
        const end = attached_client.runAttachedClient(
            transport.readFd(),
            transport.writeFd(),
            session,
            .{ .monitor_connection = false },
        ) catch |err| {
            waitAfterRuntimeAttachFailure(transport, "attached client");
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .session_ended => {
                client_log.debug("event=session_ended host={s} session={s}", .{ target.host, session.idSlice() });
                const exit_status = try finishEndedRemoteSession(transport, session);
                return process_exit.request(exit_status);
            },
            .client_hangup => {
                client_log.debug("event=client_hangup host={s} session={s}", .{ target.host, session.idSlice() });
                attached_client.drainLocalTransportDiagnostics(transport.readFd(), 100);
                transport.terminate();
                try finishHungUpSshSession(session);
                return;
            },
            .unresponsive => {
                client_log.debug("event=local_daemon_unresponsive host={s} session={s}", .{ target.host, session.idSlice() });
                try finishLocalDaemonClosedSshSession(transport, session);
                return process_exit.request(255);
            },
            .transport_closed => {
                client_log.debug("event=local_daemon_closed host={s} session={s}", .{ target.host, session.idSlice() });
                try finishLocalDaemonClosedSshSession(transport, session);
                return process_exit.request(255);
            },
            .remote_transport_closed => {
                client_log.debug("event=disconnect reason=remote_transport_closed host={s} session={s}", .{ target.host, session.idSlice() });
                transport.close();
                try reconnectRemoteSessionClient(
                    allocator,
                    exe,
                    target,
                    runtime_config,
                    failure_policy,
                    transport,
                    session,
                );
            },
        }
    }
}

fn reconnectRemoteSessionClient(
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    runtime_config: SessionRuntimeConfig,
    failure_policy: BootstrapFailurePolicy,
    transport: *TerminalTransport,
    session: *attached_client.RuntimeSession,
) !void {
    const pending_input_at_disconnect = session.hasPendingInputAck();
    const pending_paste_like_input_at_disconnect = session.hasPendingPasteLikeInputAck();
    var reconnect_ui = try client_ui.ReconnectUi.beginWithPresentation(
        session.viewport_offset,
        reconnectPresentationForFilterLevel(runtime_config.common.filter_level),
    );
    var reconnect_ui_active = true;
    defer if (reconnect_ui_active) reconnect_ui.deinit();

    var reconnect_attempt: usize = 0;
    while (true) {
        const delay_ms = reconnect.delayMs(reconnect_attempt);
        client_log.debug("event=reconnect_wait host={s} session={s} attempt={} delay_ms={}", .{
            target.host,
            session.idSlice(),
            reconnect_attempt,
            delay_ms,
        });
        switch (try reconnect_ui.waitForReconnect(delay_ms)) {
            .client_hangup => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishHungUpSshSession(session);
                return;
            },
            .reconnect_now, .wait_elapsed => {
                client_log.debug("event=reconnect_attempt host={s} session={s} attempt={}", .{
                    target.host,
                    session.idSlice(),
                    reconnect_attempt,
                });
            },
        }

        var replacement = openTerminalDaemonTransport(
            allocator,
            exe,
            target,
            runtime_config.common,
            true,
            failure_policy.allow_plain_ssh_fallback,
            &reconnect_ui,
        ) catch |err| switch (err) {
            error.DaemonTransportClosed => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishLocalDaemonClosedSshSession(transport, session);
                return process_exit.request(255);
            },
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure("transport", target, session, reconnect_attempt, err);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };
        var replacement_active = true;
        defer if (replacement_active) replacement.close();

        session.viewport_offset = reconnect_ui.currentViewportOffset();
        attached_client.reconnectSessionOnRuntimeCancellable(
            replacement.readFd(),
            replacement.writeFd(),
            session,
            reconnect_ui.cancellationFlag(),
        ) catch |err| switch (err) {
            error.RemoteDaemonDied => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishRemoteDaemonDiedSshSession(&replacement, session);
                return process_exit.request(255);
            },
            error.RemoteTransportClosed => {
                noteReconnectFailure("attach", target, session, reconnect_attempt, err);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure("attach", target, session, reconnect_attempt, err);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };

        switch (try waitForReconnectSwitchIfNeeded(
            &reconnect_ui,
            pending_input_at_disconnect,
            pending_paste_like_input_at_disconnect,
            false,
        )) {
            .client_hangup => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                replacement.close();
                try finishHungUpSshSession(session);
                return;
            },
            .reconnect_now, .wait_elapsed => {},
        }

        session.discardPendingInputAcks();
        session.viewport_offset = try reconnect_ui.clearOverlay();
        attached_client.finishReconnectRepaint(
            replacement.readFd(),
            replacement.writeFd(),
            session,
        ) catch |err| switch (err) {
            error.SessionEnded => {
                replacement_active = false;
                transport.* = replacement;
                const exit_status = try finishEndedRemoteSession(transport, session);
                return process_exit.request(exit_status);
            },
            error.RemoteTransportClosed => {
                noteReconnectFailure("repaint", target, session, reconnect_attempt, err);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure("repaint", target, session, reconnect_attempt, err);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };

        client_log.debug("event=reconnect_success host={s} session={s} attempt={}", .{
            target.host,
            session.idSlice(),
            reconnect_attempt,
        });
        reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
        reconnect_ui.deinit();
        reconnect_ui_active = false;
        replacement_active = false;
        transport.* = replacement;
        return;
    }
}

fn waitAfterRuntimeAttachFailure(transport: *TerminalTransport, stage: []const u8) void {
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    io.stderrPrint("sessh: ssh runtime transport closed after attach {s} failure\n", .{stage}) catch {};
}

fn finishHungUpSshSession(session: *attached_client.RuntimeSession) !void {
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
}

fn finishLocalDaemonClosedSshSession(transport: *TerminalTransport, session: *attached_client.RuntimeSession) !void {
    transport.close();
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try printTerminalErrorLine("sessh: local daemon connection lost");
    try tty_transcript.finishActiveOrReport();
}

fn finishRemoteDaemonDiedSshSession(transport: *TerminalTransport, session: *attached_client.RuntimeSession) !void {
    transport.close();
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try printTerminalErrorLine("sessh: remote daemon died");
    try tty_transcript.finishActiveOrReport();
}

fn printTerminalErrorLine(message: []const u8) !void {
    if (c.isatty(2) != 0) {
        try io.writeAll(2, "\n");
        try io.writeAll(2, message);
        try io.writeAll(2, "\n");
    } else {
        try io.stderrPrint("{s}\n", .{message});
    }
}

fn finishReconnectUi(reconnect_ui: *client_ui.ReconnectUi, active: *bool) void {
    if (!active.*) return;
    _ = reconnect_ui.clearOverlay() catch {};
    reconnect_ui.restoreTitleForEnd();
    reconnect_ui.deinit();
    active.* = false;
}

fn noteReconnectFailure(
    comptime stage: []const u8,
    target: SshTarget,
    session: *const attached_client.RuntimeSession,
    attempt: usize,
    err: anyerror,
) void {
    client_log.debug("event=reconnect_failed stage=" ++ stage ++ " host={s} session={s} attempt={} error={t}", .{
        target.host,
        session.idSlice(),
        attempt,
        err,
    });
    client_log.userDiagnosticInfo("reconnect failed: " ++ stage ++ ": {t}", .{err});
}

fn reconnectPresentationForFilterLevel(level: config.FilterLevel) client_ui.ReconnectPresentation {
    return switch (level) {
        .raw => .none,
        .hygienic => .title,
        .emulated => .overlay,
    };
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

fn finishEndedRemoteSession(transport: *TerminalTransport, session: *attached_client.RuntimeSession) !u8 {
    const exit_status = session.endedProcessExitCode();
    if (session.guidSlice().len > 0) {
        var maybe_paths: ?session_registry.SessionPaths = session_registry.pathsForSessionId(std.heap.page_allocator, session.guidSlice()) catch |err| blk: {
            client_log.debug("event=remote_session_route_cleanup_resolve_failed session={s} error={t}", .{ session.idSlice(), err });
            break :blk null;
        };
        if (maybe_paths) |*paths| {
            defer paths.deinit(std.heap.page_allocator);
            session_registry.removeEndedHints(paths.*) catch |err| {
                client_log.debug("event=remote_session_route_cleanup_failed session={s} error={t}", .{ session.idSlice(), err });
            };
        }
    }
    session.restoreAttachedClientEndPresentationForExit();
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    return exit_status;
}

fn writeBootstrapStatusBytes(client_diagnostic_fd: c.fd_t, bytes: []const u8) !void {
    if (client_diagnostic_fd >= 0) {
        const payload = try protocol.encodePayload(app_allocator.allocator(), pb.ClientTeTransportDiagnostic{
            .chunk = bytes,
        });
        defer app_allocator.allocator().free(payload);
        try protocol.sendFrame(client_diagnostic_fd, .client_te_transport_diagnostic, payload);
    } else {
        try io.writeAll(2, bytes);
    }
}

fn showClientBootstrapStatus(visible: *bool, reconnect_ui: ?*client_ui.ReconnectUi, client_diagnostic_fd: c.fd_t) !void {
    if (reconnect_ui != null or visible.*) return;
    try writeBootstrapStatusBytes(client_diagnostic_fd, "\rsessh: bootstrapping...");
    visible.* = true;
}

fn clearClientBootstrapStatusOn(visible: *bool, client_diagnostic_fd: c.fd_t) void {
    if (!visible.*) return;
    writeBootstrapStatusBytes(client_diagnostic_fd, "\r\x1b[K") catch {};
    visible.* = false;
}

fn clearClientBootstrapStatus(visible: *bool) void {
    clearClientBootstrapStatusOn(visible, -1);
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = if (@hasDecl(c.O, "NONBLOCK")) c.O.NONBLOCK else c.SOCK.NONBLOCK;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
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

fn defaultSshOptionsLen(target: SshTarget) usize {
    return if (target.default_ipqos_option == null) 0 else 1;
}

fn appendDefaultSshOptions(ssh_argv: [][]const u8, arg_index: *usize, default_ipqos_option: ?[]const u8) void {
    if (default_ipqos_option) |option| {
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
    }
}

fn startRuntimeConnection(
    allocator: std.mem.Allocator,
    target: SshTarget,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    bootstrap_entrypoint: ?BootstrapEntrypoint,
    exec_args: []const []const u8,
    batch_mode: bool,
    reconnect_ui: ?*client_ui.ReconnectUi,
    poll_reconnect_input: bool,
    stderr_mode_override: ?SshStderrMode,
    stderr_diagnostic_fd: c.fd_t,
    bootstrap_status_client_fd: c.fd_t,
    env_map: ?*const std.process.EnvMap,
    bootstrap_failure_term: ?*?std.process.Child.Term,
    failure_policy: BootstrapFailurePolicy,
) !RuntimeConnection {
    if (bootstrap_failure_term) |term| term.* = null;
    const reconnect_options: usize = if (batch_mode) 1 else 0;
    const default_options = defaultSshOptionsLen(target);
    const transport_options = transportSshOptionsLen(target.options);
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
    appendDefaultSshOptions(ssh_argv, &arg_index, target.default_ipqos_option);
    appendTransportSshOptions(ssh_argv, &arg_index, target.options);
    ssh_argv[arg_index] = "-T";
    ssh_argv[arg_index + 1] = target.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;
    daemon_log.infof(allocator, "ssh transport starting host={s} bootstrap={}", .{ target.host, artifacts != null });

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = env_map;
    try child.spawn();
    daemon_log.infof(allocator, "ssh transport started host={s}", .{target.host});
    var connection = RuntimeConnection{ .child = child };
    const stderr_file = connection.child.stderr.?;
    connection.child.stderr = null;
    const stderr_mode = stderr_mode_override orelse if (reconnect_ui == null) SshStderrMode.forward else SshStderrMode.diagnostics;
    connection.stderr_pump = SshStderrPump.start(allocator, stderr_file, stderr_mode, stderr_diagnostic_fd) catch |err| {
        connection.terminate();
        return err;
    };

    const artifact_set = artifacts orelse {
        daemon_log.infof(allocator, "bootstrap skipped host={s} reason=disabled", .{target.host});
        return connection;
    };

    const stdin_fd = connection.child.stdin.?.handle;
    if (bootstrap_entrypoint) |entrypoint| {
        artifact_set.sendExec(stdin_fd, entrypoint, exec_args, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectCancelled) {
                connection.terminate();
                return err;
            }
            const term = connection.wait() catch null;
            if (bootstrap_failure_term) |term_out| term_out.* = term;
            return err;
        };
    } else {
        artifact_set.sendExecArgs(stdin_fd, exec_args, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectCancelled) {
                connection.terminate();
                return err;
            }
            const term = connection.wait() catch null;
            if (bootstrap_failure_term) |term_out| term_out.* = term;
            return err;
        };
    }

    var line = readBootstrapLine(allocator, connection.child.stdout.?.handle, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.closeStdin();
        if (err == error.ReconnectCancelled) {
            connection.terminate();
            return err;
        }
        const term = connection.wait() catch null;
        if (bootstrap_failure_term) |term_out| term_out.* = term;
        if (batch_mode) {
            return err;
        }
        if (failure_policy.return_bootstrap_error) {
            daemon_log.infof(allocator, "bootstrap failed before response host={s} error={t}", .{ target.host, err });
            return error.SshBootstrapFailed;
        }
        try exitAfterSshBootstrapFailure(allocator, target, term, err);
    };
    defer allocator.free(line);

    var uploaded_bootstrap_artifact = false;
    if (std.mem.startsWith(u8, line, "MISSING ")) {
        const remote_platform = parseMissingPlatform(line) catch {
            connection.closeStdin();
            _ = connection.wait() catch {};
            if (failure_policy.return_bootstrap_error) {
                daemon_log.infof(allocator, "bootstrap invalid response host={s} line={s}", .{ target.host, line });
                return error.SshBootstrapInvalidResponse;
            }
            try io.stderrPrint("sessh: invalid bootstrap response: {s}\n", .{line});
            return process_exit.request(1);
        };
        const artifact = artifact_set.find(remote_platform) orelse {
            connection.closeStdin();
            _ = connection.wait() catch {};
            if (failure_policy.return_unsupported_error and artifactFilenameForPlatform(remote_platform) == null) {
                return error.UnsupportedRemotePlatform;
            }
            if (artifactFilenameForPlatform(remote_platform) == null and canUsePlainSshFallback(failure_policy, batch_mode, reconnect_ui)) {
                try runPlainSshFallback(allocator, target, remote_platform);
            }
            if (artifactFilenameForPlatform(remote_platform) == null) {
                try exitUnsupportedPlatform(failure_policy.unsupported_action, remote_platform);
            }
            try io.stderrPrint(
                "sessh: no packaged artifact is available for {s} {s}\n",
                .{ remote_platform.os, remote_platform.arch },
            );
            if (failure_policy.return_bootstrap_error) {
                daemon_log.infof(
                    allocator,
                    "bootstrap artifact unavailable host={s} platform={s}/{s}",
                    .{ target.host, remote_platform.os, remote_platform.arch },
                );
                return error.SshBootstrapFailed;
            }
            return process_exit.request(1);
        };
        daemon_log.infof(
            allocator,
            "bootstrap upload required host={s} platform={s}/{s}",
            .{ target.host, remote_platform.os, remote_platform.arch },
        );

        var bootstrap_status_visible = false;
        defer clearClientBootstrapStatusOn(&bootstrap_status_visible, bootstrap_status_client_fd);
        try showClientBootstrapStatus(&bootstrap_status_visible, reconnect_ui, bootstrap_status_client_fd);

        sendUpload(allocator, connection.child.stdin.?.handle, artifact, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectCancelled) {
                connection.terminate();
                return err;
            }
            _ = connection.wait() catch {};
            return err;
        };
        uploaded_bootstrap_artifact = true;

        allocator.free(line);
        line = readBootstrapLine(allocator, connection.child.stdout.?.handle, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectCancelled) {
                connection.terminate();
                return err;
            }
            const term = connection.wait() catch null;
            if (bootstrap_failure_term) |term_out| term_out.* = term;
            if (batch_mode) {
                return err;
            }
            if (failure_policy.return_bootstrap_error) {
                daemon_log.infof(allocator, "bootstrap failed after upload host={s} error={t}", .{ target.host, err });
                return error.SshBootstrapFailed;
            }
            try exitAfterSshBootstrapFailure(allocator, target, term, err);
        };
    }

    if (std.mem.eql(u8, line, "OK")) {
        if (uploaded_bootstrap_artifact) {
            daemon_log.infof(allocator, "bootstrap completed host={s} uploaded=true", .{target.host});
        } else {
            daemon_log.infof(allocator, "bootstrap skipped host={s} reason=remote_artifact_present", .{target.host});
        }
        if (exec_args.len == 0) connection.suppressSshStderr();
        return connection;
    }

    if (std.mem.startsWith(u8, line, "ERR ")) {
        connection.closeStdin();
        _ = connection.wait() catch {};
        if (isUnsupportedPlatformBootstrapError(line) and failure_policy.return_unsupported_error) {
            return error.UnsupportedRemotePlatform;
        }
        if (isUnsupportedPlatformBootstrapError(line) and canUsePlainSshFallback(failure_policy, batch_mode, reconnect_ui)) {
            try runPlainSshFallback(allocator, target, null);
        }
        if (isUnsupportedPlatformBootstrapError(line)) {
            try exitUnsupportedPlatform(failure_policy.unsupported_action, null);
        }
        if (failure_policy.return_bootstrap_error) {
            daemon_log.infof(allocator, "remote bootstrap failed host={s} line={s}", .{ target.host, line });
            return error.SshBootstrapFailed;
        }
        try io.stderrPrint("sessh: remote bootstrap failed: {s}\n", .{line});
        return process_exit.request(1);
    }

    connection.closeStdin();
    _ = connection.wait() catch {};
    if (failure_policy.return_bootstrap_error) {
        daemon_log.infof(allocator, "unexpected bootstrap response host={s} line={s}", .{ target.host, line });
        return error.SshBootstrapInvalidResponse;
    }
    try io.stderrPrint("sessh: unexpected bootstrap response: {s}\n", .{line});
    return process_exit.request(1);
}

fn isUnsupportedPlatformBootstrapError(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "ERR UNSUPPORTED_PLATFORM ");
}

fn canUsePlainSshFallback(
    policy: BootstrapFailurePolicy,
    batch_mode: bool,
    reconnect_ui: ?*client_ui.ReconnectUi,
) bool {
    return policy.allow_plain_ssh_fallback and
        !batch_mode and
        reconnect_ui == null;
}

fn shouldUseStreamPath(new: RemoteNewSession, common: CommonSessionOptions, stdin_is_tty: bool) bool {
    if (new.command_argv.len != 0) return false;
    if (!common.terminal_emulator) return true;
    if (!hasRemoteShellCommand(new.shell_command_args)) return false;

    // Match ssh's PTY allocation rules for remote commands. Plain
    // `ssh HOST command` does not allocate a remote tty even when local stdin is
    // a tty, so it uses the stream path. `-t` only requests a remote tty when
    // local stdin is a tty. `-tt` with local stdin still uses sessh's normal
    // terminal-emulator session path; without local stdin it stays on the
    // stream path and lets the visible outer ssh allocate the PTY.
    return switch (new.tty_request) {
        .none => true,
        .requested => !stdin_is_tty,
        .forced => !stdin_is_tty,
    };
}

const DaemonStreamClientTransport = struct {
    fd: c.fd_t,

    pub fn readFd(self: *const DaemonStreamClientTransport) c.fd_t {
        return self.fd;
    }

    pub fn writeFd(self: *const DaemonStreamClientTransport) c.fd_t {
        return self.fd;
    }

    pub fn close(self: *DaemonStreamClientTransport) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn terminate(self: *DaemonStreamClientTransport) void {
        self.close();
    }
};

const DaemonStreamClientStarter = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    bootstrap: bool,

    pub fn start(self: *DaemonStreamClientStarter) !DaemonStreamClientTransport {
        const fd = try daemon_client.connectOrStart(self.allocator, self.exe);
        errdefer _ = c.close(fd);

        var request = pb.ClientTeTransportOpen{
            .host = self.target.host,
            .bootstrap = self.bootstrap,
            .batch_mode = true,
        };
        defer request.ssh_option.deinit(self.allocator);
        defer deinitTransportOpenEnvironment(self.allocator, &request);
        try request.ssh_option.appendSlice(self.allocator, self.target.options);
        try appendCurrentEnvironmentToTransportOpen(self.allocator, &request);

        const payload = try protocol.encodePayload(self.allocator, request);
        defer self.allocator.free(payload);
        try protocol.sendFrame(fd, .client_te_transport_open, payload);

        var bootstrap_status_visible = false;
        defer clearClientBootstrapStatus(&bootstrap_status_visible);
        while (true) {
            var frame = protocol.readFrameAlloc(self.allocator, fd) catch |err| switch (err) {
                error.EndOfStream => return error.DaemonTransportClosed,
                else => return err,
            };
            defer frame.deinit(self.allocator);
            switch (frame.message_type) {
                .client_te_transport_ready => {
                    var ready = try protocol.decodePayload(pb.ClientTeTransportReady, self.allocator, frame.payload);
                    defer ready.deinit(self.allocator);
                    return .{ .fd = fd };
                },
                .client_te_transport_diagnostic => {
                    try handleClientTeTransportDiagnostic(self.allocator, frame.payload, null, &bootstrap_status_visible);
                },
                .error_message => {
                    var message = try protocol.decodePayload(protocol.hpb.Error, self.allocator, frame.payload);
                    defer message.deinit(self.allocator);
                    if (daemonTransportExitCode(message.code)) |exit_code| {
                        try printDaemonTransportError(message);
                        return process_exit.request(exit_code);
                    }
                    try printDaemonTransportError(message);
                    return error.DaemonTransportFailed;
                },
                .ping, .pong => {
                    _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd);
                },
                else => return error.UnexpectedDaemonFrame,
            }
        }
    }

    pub fn exitAfterInitialFailure(self: *DaemonStreamClientStarter, err: anyerror) !void {
        _ = self;
        return err;
    }
};

fn proxyStreamReconnectStatusMode(level: config.FilterLevel, has_client_socket: bool) stream_runtime.StreamReconnectStatusMode {
    return switch (level) {
        .raw => .disabled,
        .hygienic, .emulated => if (has_client_socket) .client_control else .stderr_plain,
    };
}

fn filterLevelForcesProxy(level: config.FilterLevel) bool {
    return switch (level) {
        .raw, .hygienic => true,
        .emulated => false,
    };
}

fn shouldUseProxyStream(new: RemoteNewSession, common: CommonSessionOptions, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    if (new.command_argv.len != 0) return false;
    if (filterLevelForcesProxy(common.filter_level) or new.proxy_required) return true;
    if ((!stdin_is_tty or !stdout_is_tty) and common.filter_level == .emulated) return true;
    if (!hasRemoteShellCommand(new.shell_command_args)) return !common.terminal_emulator;
    return shouldUseStreamPath(new, common, stdin_is_tty);
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
// byte-clean stream to a remote stream runtime, and the remote stream runtime then
// opens a TCP connection to sshd on the remote machine.
fn runProxyStreamSsh(
    allocator: std.mem.Allocator,
    target: SshTarget,
    common: CommonSessionOptions,
    new: RemoteNewSession,
) !noreturn {
    const diagnostics_plan = proxyDiagnosticsPlan(
        target.options,
        common.filter_level,
        new.tty_request,
        new.shell_command_args,
        c.isatty(posix.STDIN_FILENO) != 0,
        c.isatty(posix.STDOUT_FILENO) != 0,
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
    const daemon_dir_name = try daemon_socket_namespace.defaultDirName(allocator);
    defer allocator.free(daemon_dir_name);
    var runtime_executables = try daemon_executable.runtimeExecutablePaths(allocator, daemon_dir_name);
    defer runtime_executables.deinit();

    const proxy_command_option = try proxyCommandOption(
        allocator,
        runtime_executables.proxy,
        target.options,
        if (client_socket_allocation) |allocation| allocation.path else null,
        diagnostics_plan.command_level,
        diagnostics_plan.client_ctrl_r,
        common.bootstrap,
    );
    defer allocator.free(proxy_command_option);

    const default_options = defaultSshOptionsLen(target);
    const ssh_arg_count = 1 + default_options + target.options.len + 1 + new.shell_command_args.len;
    const ssh_args = try allocator.alloc([]const u8, ssh_arg_count);
    defer allocator.free(ssh_args);

    var index: usize = 0;
    // Put sessh's ProxyCommand first. OpenSSH gives command-line options high
    // precedence, and this keeps a user/config ProxyCommand available to the
    // inner bootstrap ssh while ensuring the outer ssh talks over our stream.
    ssh_args[index] = proxy_command_option;
    index += 1;
    appendDefaultSshOptions(ssh_args, &index, target.default_ipqos_option);
    @memcpy(ssh_args[index .. index + target.options.len], target.options);
    index += target.options.len;
    ssh_args[index] = target.host;
    index += 1;
    @memcpy(ssh_args[index..], new.shell_command_args);

    if (diagnostics_plan.wrap_visible_ssh and client_socket_listen_fd >= 0) {
        try plain_ssh.runArgvUnderLocalPty(allocator, ssh_args, client_socket_listen_fd, diagnostics_plan.client_ctrl_r, "proxy-stream");
    }
    if (diagnostics_plan.use_client_socket and client_socket_listen_fd >= 0) {
        try plain_ssh.runArgvWithDiagnosticsThread(allocator, ssh_args, client_socket_listen_fd, "proxy-stream");
    }
    try plain_ssh.runArgv(allocator, ssh_args, "proxy-stream");
}

const ProxyDiagnosticsPlan = struct {
    command_level: config.FilterLevel,
    use_client_socket: bool,
    wrap_visible_ssh: bool,
    client_ctrl_r: bool,
};

fn proxyDiagnosticsPlan(
    ssh_options: []const []const u8,
    filter_level: config.FilterLevel,
    tty_request: SshTtyRequest,
    shell_command_args: []const []const u8,
    stdin_is_tty: bool,
    stdout_is_tty: bool,
) ProxyDiagnosticsPlan {
    return switch (filter_level) {
        .raw => .{
            .command_level = .raw,
            .use_client_socket = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!stdin_is_tty or !stdout_is_tty) break :blk .{
                .command_level = .raw,
                .use_client_socket = false,
                .wrap_visible_ssh = false,
                .client_ctrl_r = false,
            };
            const wrap_visible_ssh = outerSshAllocatesTty(ssh_options, tty_request, shell_command_args, stdin_is_tty);
            break :blk .{
                .command_level = .hygienic,
                .use_client_socket = true,
                .wrap_visible_ssh = wrap_visible_ssh,
                .client_ctrl_r = wrap_visible_ssh and stdin_is_tty,
            };
        },
    };
}

fn outerSshAllocatesTty(
    ssh_options: []const []const u8,
    tty_request: SshTtyRequest,
    shell_command_args: []const []const u8,
    stdin_is_tty: bool,
) bool {
    const explicit = explicitTtyRequest(ssh_options);
    if (explicit) |request| return switch (request) {
        .none => false,
        .requested => stdin_is_tty,
        .forced => true,
    };
    return switch (tty_request) {
        .none => stdin_is_tty and shell_command_args.len == 0,
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
    ssh_options: []const []const u8,
    client_socket: ?[]const u8,
    filter_level: config.FilterLevel,
    client_ctrl_r: bool,
    bootstrap: bool,
) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try appendShellToken(allocator, &command, exe);
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
    try appendShellToken(allocator, &command, if (bootstrap) "--bootstrap" else "--no-bootstrap");
    if (client_socket) |path| {
        try appendShellToken(allocator, &command, "--client-socket");
        try appendShellToken(allocator, &command, path);
        try appendShellToken(allocator, &command, "--client-ctrl-r");
        try appendShellToken(allocator, &command, if (client_ctrl_r) "1" else "0");
    }
    try appendProxyTransportSshOptions(allocator, &command, ssh_options);

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
    bootstrap: bool = true,
    ssh_options: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ProxyStreamInvocation, allocator: std.mem.Allocator) void {
        self.ssh_options.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runProxyStream(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var invocation = parseProxyStreamInvocation(allocator, args) catch |err| {
        try printProxyStreamArgError(err);
        return process_exit.request(64);
    };
    defer invocation.deinit(allocator);

    const proxy_guid = try session_registry.generateProxyGuid(allocator);
    defer allocator.free(proxy_guid);

    if (invocation.port.len == 0) return error.InvalidProxyStreamArgs;
    const proxy_port = try std.fmt.parseInt(u16, invocation.port, 10);

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

    const stream_target = SshTarget{
        .options = invocation.ssh_options.items,
        .host = invocation.host,
        .default_ipqos_option = default_ipqos_option,
        .resolved_user = resolved_ssh_config.user,
        .resolved_host = resolved_ssh_config.hostname,
        .resolved_port = resolved_ssh_config.port,
    };
    var starter = DaemonStreamClientStarter{
        .allocator = allocator,
        .exe = exe,
        .target = stream_target,
        .bootstrap = invocation.bootstrap,
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

    const exit_status = stream_runtime.runLocalStream(allocator, &starter, .{
        .guid = proxy_guid,
        .proxy_host = "localhost",
        .proxy_port = proxy_port,
        .source_fd = 0,
        .sink_fd = 1,
        .status_mode = status_mode,
        .intercept_ctrl_r = false,
        .control_fd = client_control_fd,
        .ctrl_r_status_enabled = proxy_control_ctrl_r_available and client_control_fd >= 0,
        .proxy_control_output_mode = proxy_control_output_mode,
        .title_fallback = invocation.host,
        .reset_on_source_eof = true,
    }) catch |err| {
        try starter.exitAfterInitialFailure(err);
        return;
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
        } else if (std.mem.eql(u8, arg, "--bootstrap")) {
            invocation.bootstrap = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-bootstrap")) {
            invocation.bootstrap = false;
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

fn exitUnsupportedPlatform(action: []const u8, platform: ?Platform) !noreturn {
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

fn runPlainSshFallbackAfterVersionMismatch(allocator: std.mem.Allocator, target: SshTarget) !noreturn {
    try io.writeAll(2, "sessh: existing remote sessh is incompatible; falling back to plain ssh without persistence\n");
    try runPlainSshFallbackArgv(allocator, target);
}

fn runPlainSshFallback(allocator: std.mem.Allocator, target: SshTarget, platform: ?Platform) !noreturn {
    if (platform) |remote_platform| {
        try io.stderrPrint(
            "sessh: no matching sessh binary for remote platform {s} {s}; falling back to plain ssh without persistence\n",
            .{ remote_platform.os, remote_platform.arch },
        );
    } else {
        try io.writeAll(2, "sessh: remote platform is unsupported and no matching sessh binary is available; falling back to plain ssh without persistence\n");
    }

    try runPlainSshFallbackArgv(allocator, target);
}

fn runPlainSshFallbackArgv(allocator: std.mem.Allocator, target: SshTarget) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, target.options.len + 1);
    defer allocator.free(ssh_argv);
    @memcpy(ssh_argv[0..target.options.len], target.options);
    ssh_argv[ssh_argv.len - 1] = target.host;

    try plain_ssh.runArgv(allocator, ssh_argv, "plain-ssh-fallback");
}

fn exitAfterSshBootstrapFailure(
    allocator: std.mem.Allocator,
    target: SshTarget,
    term: ?std.process.Child.Term,
    cause: anyerror,
) !noreturn {
    client_log.flush(2);
    if (term) |value| {
        switch (value) {
            .Exited => |code| {
                if (code != 0) {
                    try writeVisibleSshCommand(allocator, target);
                    try io.stderrPrint(" failed (exitcode={})\n", .{code});
                    return process_exit.request(code);
                }
                try io.stderrPrint("sessh: ssh bootstrap ended before response ({t})\n", .{cause});
                return process_exit.request(1);
            },
            .Signal => |signal| {
                try writeVisibleSshCommand(allocator, target);
                try io.stderrPrint(" failed (signal {})\n", .{signal});
                return process_exit.request(255);
            },
            else => {
                try writeVisibleSshCommand(allocator, target);
                try io.stderrPrint(" failed ({t})\n", .{value});
                return process_exit.request(1);
            },
        }
    }

    try io.stderrPrint("sessh: ssh bootstrap failed before response: {t}\n", .{cause});
    return process_exit.request(1);
}

fn writeVisibleSshCommand(allocator: std.mem.Allocator, target: SshTarget) !void {
    try io.writeAll(2, "sessh: `ssh");
    for (target.options) |arg| {
        try io.writeAll(2, " ");
        try writeDiagnosticShellArg(allocator, arg);
    }
    try io.writeAll(2, " ");
    try writeDiagnosticShellArg(allocator, target.host);
    try io.writeAll(2, "`");
}

fn visibleSshFailureMessage(
    allocator: std.mem.Allocator,
    target: SshTarget,
    label: []const u8,
    value: anytype,
) ![]u8 {
    var message = std.ArrayList(u8).empty;
    errdefer message.deinit(allocator);
    try message.appendSlice(allocator, "`ssh");
    for (target.options) |arg| {
        try message.append(allocator, ' ');
        try appendDiagnosticShellArg(allocator, &message, arg);
    }
    try message.append(allocator, ' ');
    try appendDiagnosticShellArg(allocator, &message, target.host);
    try message.appendSlice(allocator, "` failed (");
    try message.appendSlice(allocator, label);
    try message.append(allocator, '=');
    try message.writer(allocator).print("{}", .{value});
    try message.append(allocator, ')');
    return message.toOwnedSlice(allocator);
}

fn appendDiagnosticShellArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (isPlainShellArg(arg)) {
        try out.appendSlice(allocator, arg);
        return;
    }
    const quoted = try shellQuote(allocator, arg);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
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

fn compatModeFromEnv() bool {
    const value_z = c.getenv(config.compat_env) orelse return false;
    return std.mem.eql(u8, std.mem.span(value_z), "1");
}

pub fn printSshArgError(err: anyerror) !void {
    switch (err) {
        error.MissingHost => try io.writeAll(2, "sessh: missing host\n"),
        error.MissingScrollbackRowCount => try io.writeAll(2, "sessh: --scrollback-limit requires a value\n"),
        error.MissingInitialScrollback => try io.writeAll(2, "sessh: --initial-scrollback requires a value\n"),
        error.MissingClientLogLevel => try io.writeAll(2, "sessh: --log-level requires a value\n"),
        error.MissingFilterLevel => try io.writeAll(2, "sessh: --filter-level requires one of: raw, hygienic, emulated\n"),
        error.MissingTtyTranscriptPath => try io.writeAll(2, "sessh: --capture-tty-transcript requires a path\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: ssh option is missing its value\n"),
        error.SesshOptionAfterHost => try io.writeAll(2, "sessh: sessh options must appear before HOST\n"),
        error.ConflictingSesshAction => try io.writeAll(2, "sessh: conflicting sessh actions\n"),
        error.InvalidScrollbackRowCount => try io.writeAll(2, "sessh: invalid scrollback row count\n"),
        error.InvalidInitialScrollback => try io.writeAll(2, "sessh: invalid initial scrollback\n"),
        error.InvalidClientLogLevel => try io.writeAll(2, "sessh: invalid log level\n"),
        error.InvalidFilterLevel => try io.writeAll(2, "sessh: invalid filter level; expected one of: raw, hygienic, emulated\n"),
        error.InvalidBool => try io.writeAll(2, "sessh: expected true or false\n"),
        error.RemoteCommandUnsupported => try io.writeAll(2, "sessh: remote commands require -t or -tt for persistent sessions\n"),
        error.UnsafeSshOption => try io.writeAll(2, "sessh: ssh option is not safe for sessh transport\n"),
        error.UnsupportedSesshOption => try io.writeAll(2, "sessh: unsupported sessh option for ssh transport\n"),
        error.UnsupportedSesshCliOption => try io.writeAll(2, "sessh: unsupported sessh option\n"),
        error.UnsupportedSshOption => try io.writeAll(2, "sessh: unsupported ssh option for sessh transport\n"),
        else => try io.stderrPrint("sessh: invalid ssh arguments: {t}\n", .{err}),
    }
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

const ParsedSesshForTest = struct {
    invocation: sessh_cli.Invocation,
    owned_ssh_options: ?[][]const u8 = null,

    fn deinit(self: *ParsedSesshForTest, allocator: std.mem.Allocator) void {
        if (self.owned_ssh_options) |options| allocator.free(options);
        self.* = undefined;
    }
};

fn parseSshArgsForTest(allocator: std.mem.Allocator, args: []const []const u8, _: anytype) !ParsedSesshForTest {
    var scratch = sessh_cli.Scratch{ .allocator = allocator };
    defer scratch.deinit();
    const parsed = try sessh_cli.parse(&scratch, args);
    const owned_ssh_options = scratch.owned_ssh_options;
    scratch.owned_ssh_options = null;
    return .{
        .invocation = parsed,
        .owned_ssh_options = owned_ssh_options,
    };
}

fn remoteNewFromParsedSessh(parsed: ParsedSesshForTest) RemoteNewSession {
    return .{
        .shell_command_args = parsed.invocation.command_args,
        .tty_request = parsed.invocation.tty_request,
        .proxy_required = parsed.invocation.proxy_required,
    };
}

fn shouldUseStreamPathForTest(parsed: ParsedSesshForTest, stdin_is_tty: bool) bool {
    return shouldUseStreamPath(remoteNewFromParsedSessh(parsed), parsed.invocation.common, stdin_is_tty);
}

fn shouldUseProxyStreamForTest(parsed: ParsedSesshForTest, stdin_is_tty: bool) bool {
    return shouldUseProxyStreamForTestWithStdout(parsed, stdin_is_tty, true);
}

fn shouldUseProxyStreamForTestWithStdout(parsed: ParsedSesshForTest, stdin_is_tty: bool, stdout_is_tty: bool) bool {
    return shouldUseProxyStream(remoteNewFromParsedSessh(parsed), parsed.invocation.common, stdin_is_tty, stdout_is_tty);
}

fn proxyDiagnosticsPlanForTest(parsed: ParsedSesshForTest, stdin_is_tty: bool, stdout_is_tty: bool) ProxyDiagnosticsPlan {
    return proxyDiagnosticsPlan(
        parsed.invocation.ssh_options,
        parsed.invocation.common.filter_level,
        parsed.invocation.tty_request,
        parsed.invocation.command_args,
        stdin_is_tty,
        stdout_is_tty,
    );
}

test "remote shell command detection treats empty command like OpenSSH" {
    try std.testing.expect(!hasRemoteShellCommand(&.{""}));
    try std.testing.expect(hasRemoteShellCommand(&.{"\"\""}));
    try std.testing.expect(hasRemoteShellCommand(&.{ "", "" }));
}

test "ssh verbosity maps to inferred client log level" {
    try std.testing.expectEqual(client_log.Level.warn, inferredClientLogLevel(&.{}));
    try std.testing.expectEqual(client_log.Level.info, inferredClientLogLevel(&.{"-v"}));
    try std.testing.expectEqual(client_log.Level.debug, inferredClientLogLevel(&.{"-vv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{"-vvv"}));
    try std.testing.expectEqual(client_log.Level.verbose, inferredClientLogLevel(&.{ "-vC", "-vv" }));
}

test "parseSshArgs routes OpenSSH-owned options to proxy stream mode" {
    var x11 = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-X",
        "example.com",
    }, .{});
    defer x11.deinit(std.testing.allocator);
    try std.testing.expect(x11.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(x11, true));

    var forward_agent = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-A",
        "example.com",
    }, .{});
    defer forward_agent.deinit(std.testing.allocator);
    try std.testing.expect(forward_agent.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(forward_agent, true));

    var stdin_null = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-n",
        "example.com",
    }, .{});
    defer stdin_null.deinit(std.testing.allocator);
    try std.testing.expect(stdin_null.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(stdin_null, true));

    var fork_after_auth = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-f",
        "example.com",
    }, .{});
    defer fork_after_auth.deinit(std.testing.allocator);
    try std.testing.expect(fork_after_auth.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(fork_after_auth, true));

    var forward = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-L",
        "8080:localhost:80",
        "example.com",
    }, .{});
    defer forward.deinit(std.testing.allocator);
    try std.testing.expect(forward.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(forward, true));

    var direct = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-W",
        "host:22",
        "example.com",
    }, .{});
    defer direct.deinit(std.testing.allocator);
    try std.testing.expect(direct.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(direct, true));

    var request_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-o",
        "RequestTTY=force",
        "example.com",
    }, .{});
    defer request_tty.deinit(std.testing.allocator);
    try std.testing.expect(request_tty.invocation.proxy_required);
    try std.testing.expect(shouldUseProxyStreamForTest(request_tty, true));

    var explicit = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "example.com",
    }, .{});
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.hygienic, explicit.invocation.common.filter_level);
    try std.testing.expect(explicit.invocation.common.filter_level_set);
    try std.testing.expect(shouldUseProxyStreamForTest(explicit, true));

    var explicit_disabled = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "emulated",
        "example.com",
    }, .{});
    defer explicit_disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.emulated, explicit_disabled.invocation.common.filter_level);
    try std.testing.expect(explicit_disabled.invocation.common.filter_level_set);
    try std.testing.expect(!shouldUseProxyStreamForTest(explicit_disabled, true));
}

test "proxy command keeps outer-only options off bootstrap ssh" {
    var parsed = try parseSshArgsForTest(std.testing.allocator, &.{
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
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseProxyStreamForTest(parsed, true));

    const option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, "/tmp/sessh-test/c/abc", .hygienic, true, true);
    defer std.testing.allocator.free(option);

    try std.testing.expect(std.mem.indexOf(u8, option, "sessh-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, ":internal-proxy-stream:") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%n") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%p") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--filter-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "hygienic") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--bootstrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-socket") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "/tmp/sessh-test/c/abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-ctrl-r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "-v") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "ForwardAgent=yes") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "8080:localhost:80") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-X'") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-tt'") == null);

    const no_bootstrap_option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, null, .raw, false, false);
    defer std.testing.allocator.free(no_bootstrap_option);
    try std.testing.expect(std.mem.indexOf(u8, no_bootstrap_option, "--no-bootstrap") != null);
}

test "stream routing preserves ssh remote command tty semantics" {
    var command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "example.com",
        "echo",
        "hello",
    }, .{});
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqual(SshTtyRequest.none, command.invocation.tty_request);
    try std.testing.expectEqual(@as(usize, 2), command.invocation.command_args.len);
    try std.testing.expect(shouldUseStreamPathForTest(command, false));
    try std.testing.expect(shouldUseStreamPathForTest(command, true));
    try std.testing.expect(shouldUseProxyStreamForTest(command, false));
    try std.testing.expect(shouldUseProxyStreamForTest(command, true));

    var single = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "tty",
    }, .{});
    defer single.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(single, false));
    try std.testing.expect(!shouldUseStreamPathForTest(single, true));
    try std.testing.expect(shouldUseProxyStreamForTest(single, false));
    try std.testing.expect(!shouldUseProxyStreamForTest(single, true));

    var forced = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-tt",
        "example.com",
        "tty",
    }, .{});
    defer forced.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(forced, false));
    try std.testing.expect(!shouldUseStreamPathForTest(forced, true));
    try std.testing.expect(shouldUseProxyStreamForTest(forced, false));
    try std.testing.expect(!shouldUseProxyStreamForTest(forced, true));
}

test "emulated mode falls back to proxy stream when stdin or stdout is not a tty" {
    var requested_tty_command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "-t",
        "example.com",
        "tty",
    }, .{});
    defer requested_tty_command.deinit(std.testing.allocator);
    try std.testing.expect(!shouldUseProxyStreamForTestWithStdout(requested_tty_command, true, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(requested_tty_command, false, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(requested_tty_command, true, false));

    var interactive = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "example.com",
    }, .{});
    defer interactive.deinit(std.testing.allocator);
    try std.testing.expect(!shouldUseProxyStreamForTestWithStdout(interactive, true, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(interactive, false, true));
    try std.testing.expect(shouldUseProxyStreamForTestWithStdout(interactive, true, false));
}

test "no terminal emulator forces stream path and preserves ssh tty semantics" {
    var terminal_emulator = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--terminal-emulator",
        "example.com",
    }, .{});
    defer terminal_emulator.deinit(std.testing.allocator);
    try std.testing.expect(terminal_emulator.invocation.common.terminal_emulator);
    try std.testing.expect(terminal_emulator.invocation.common.terminal_emulator_set);
    try std.testing.expect(!shouldUseStreamPathForTest(terminal_emulator, true));
    try std.testing.expect(!shouldUseStreamPathForTest(terminal_emulator, false));

    var interactive = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    defer interactive.deinit(std.testing.allocator);
    try std.testing.expect(!interactive.invocation.common.terminal_emulator);
    try std.testing.expect(interactive.invocation.common.terminal_emulator_set);
    try std.testing.expect(shouldUseStreamPathForTest(interactive, true));
    try std.testing.expect(shouldUseStreamPathForTest(interactive, false));
    try std.testing.expect(shouldUseProxyStreamForTest(interactive, true));
    try std.testing.expect(shouldUseProxyStreamForTest(interactive, false));

    var command = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
        "echo",
        "hello",
    }, .{});
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(!command.invocation.common.terminal_emulator);
    try std.testing.expect(shouldUseStreamPathForTest(command, true));
    try std.testing.expect(shouldUseProxyStreamForTest(command, true));

    var forced = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-tt",
        "example.com",
        "tty",
    }, .{});
    defer forced.deinit(std.testing.allocator);
    try std.testing.expect(!forced.invocation.common.terminal_emulator);
    try std.testing.expect(shouldUseStreamPathForTest(forced, false));
    try std.testing.expect(shouldUseProxyStreamForTest(forced, false));

    var requested_with_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-t",
        "example.com",
        "tty",
    }, .{});
    defer requested_with_tty.deinit(std.testing.allocator);
    try std.testing.expect(!requested_with_tty.invocation.common.terminal_emulator);
    try std.testing.expect(shouldUseStreamPathForTest(requested_with_tty, true));
    try std.testing.expect(shouldUseProxyStreamForTest(requested_with_tty, true));

    var requested_without_tty = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "-t",
        "example.com",
        "tty",
    }, .{});
    defer requested_without_tty.deinit(std.testing.allocator);
    try std.testing.expect(shouldUseStreamPathForTest(requested_without_tty, false));
    try std.testing.expect(shouldUseProxyStreamForTest(requested_without_tty, false));
}

test "default ssh options append resolved interactive IPQoS value" {
    var parsed = SshTarget{
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

test "proxy stream reconnect status follows filter level" {
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.disabled, proxyStreamReconnectStatusMode(.raw, false));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.stderr_plain, proxyStreamReconnectStatusMode(.hygienic, false));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.client_control, proxyStreamReconnectStatusMode(.hygienic, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.client_control, proxyStreamReconnectStatusMode(.emulated, true));
}

test "proxy diagnostics plan maps emulated to hygienic client socket" {
    var parsed = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    defer parsed.deinit(std.testing.allocator);

    const interactive = proxyDiagnosticsPlanForTest(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.hygienic, interactive.command_level);
    try std.testing.expect(interactive.use_client_socket);
    try std.testing.expect(interactive.wrap_visible_ssh);
    try std.testing.expect(interactive.client_ctrl_r);

    const no_stdout = proxyDiagnosticsPlanForTest(parsed, true, false);
    try std.testing.expectEqual(config.FilterLevel.raw, no_stdout.command_level);
    try std.testing.expect(!no_stdout.use_client_socket);
    try std.testing.expect(!no_stdout.wrap_visible_ssh);
    try std.testing.expect(!no_stdout.client_ctrl_r);

    const no_stdin = proxyDiagnosticsPlanForTest(parsed, false, true);
    try std.testing.expectEqual(config.FilterLevel.raw, no_stdin.command_level);
    try std.testing.expect(!no_stdin.use_client_socket);
    try std.testing.expect(!no_stdin.wrap_visible_ssh);
    try std.testing.expect(!no_stdin.client_ctrl_r);
}

test "proxy diagnostics plan honors raw level" {
    var raw = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "raw",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    defer raw.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.raw, raw.invocation.common.filter_level);
    const raw_plan = proxyDiagnosticsPlanForTest(raw, true, true);
    try std.testing.expectEqual(config.FilterLevel.raw, raw_plan.command_level);
    try std.testing.expect(!raw_plan.use_client_socket);
}

test "proxy diagnostics plan disables ctrl-r when visible ssh is not wrapped" {
    var parsed = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "hygienic",
        "-T",
        "example.com",
    }, .{});
    defer parsed.deinit(std.testing.allocator);

    const plan = proxyDiagnosticsPlanForTest(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.hygienic, plan.command_level);
    try std.testing.expect(plan.use_client_socket);
    try std.testing.expect(!plan.wrap_visible_ssh);
    try std.testing.expect(!plan.client_ctrl_r);
}
