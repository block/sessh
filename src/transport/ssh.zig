const std = @import("std");
const c = std.c;
const posix = std.posix;

const attached_client = @import("../session/attached_client.zig");
const transport_bootstrap = @import("bootstrap.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
const proxy_control = @import("../stream/proxy_control.zig");
const sessh_cli = @import("../sessh/cli.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");
const protocol = @import("../protocol/mod.zig");
const reconnect = @import("../reconnect/mod.zig");
const plain_ssh = @import("plain_ssh.zig");
const remote_shell = @import("remote_shell.zig");
const session_registry = @import("../runtime/session_registry.zig");
const socket_transport = @import("socket.zig");
const ssh_opts = @import("ssh_options.zig");
const stream_runtime = @import("../stream/runtime.zig");
const tty_transcript = @import("../tty/transcript.zig");
const pb = protocol.pb;

const CommonSessionOptions = sessh_cli.CommonSessionOptions;

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
const directSessionBrokerCommand = remote_shell.directSessionBrokerCommand;
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
    discard,
};

const ParallelReconnectResult = reconnect.AsyncResult(RuntimeConnection);

const ParallelReconnectState = struct {
    task: reconnect.AsyncTask(RuntimeConnection) = .{},
    target: SshTarget,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    reconnect_ui: *client_ui.ReconnectUi,
    session: attached_client.RuntimeSession,
    failure_policy: BootstrapFailurePolicy,

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

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper installs or finds the remote sessh binary, then execs
/// the internal entrypoint we send in the EXEC line. For normal sessions that
/// is `:internal-session-broker:`; tty/proxy streams use `:internal-stream-broker:`.
/// Installed packages keep one binary per supported platform in libexec/sessh,
/// named `sessh-<os>-<arch>`. If that layout is unavailable, upload the
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

    const stdin_is_tty = c.isatty(0) != 0;
    if (shouldUseProxyStream(new, runtime_config.common, stdin_is_tty)) {
        if (runtime_config.common.capture_tty_transcript != null) {
            try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with proxy stream mode\n");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, exe, target, runtime_config.common, new);
    }

    const shell_command = try shellCommandFromRemoteArgs(allocator, new.shell_command_args);
    defer if (shell_command) |command| allocator.free(command);

    var artifacts_storage: ?ArtifactSet = if (runtime_config.common.bootstrap) try loadArtifactSet(allocator) else null;
    defer if (artifacts_storage) |*artifacts| artifacts.deinit();
    const artifacts = if (artifacts_storage) |*value| value else null;

    const remote_command = if (runtime_config.common.bootstrap)
        try bootstrapCommand(allocator)
    else
        try directSessionBrokerCommand(allocator);
    defer allocator.free(remote_command);

    var transcript_recorder: ?tty_transcript.Recorder = null;
    try setupTranscriptRecorder(allocator, runtime_config.common.capture_tty_transcript, &transcript_recorder);
    defer teardownTranscriptRecorder(&transcript_recorder);

    const new_guid = try session_registry.generateGuid(allocator);
    defer allocator.free(new_guid);

    var child = try startRemoteSessionBroker(
        allocator,
        target,
        artifacts,
        remote_command,
        failure_policy,
    );

    var session = attached_client.startNewSessionOnRuntime(
        child.child.stdout.?.handle,
        child.child.stdin.?.handle,
        runtime_config.common.scrollback_row_count,
        new_guid,
        new.command_argv,
        shell_command,
        runtime_config.disconnected_reap_ms,
    ) catch |err| {
        if (err == error.VersionMismatch) {
            child.closeStdin();
            _ = child.wait() catch {};
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
        waitAfterRuntimeAttachFailure(&child, "start");
        if (process_exit.is(err)) return err;
        try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(target.host);
    child.suppressSshStderr();
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
        target,
        runtime_config,
        artifacts,
        remote_command,
        failure_policy,
        &child,
        &session,
    );
}

fn startRemoteSessionBroker(
    allocator: std.mem.Allocator,
    target: SshTarget,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    failure_policy: BootstrapFailurePolicy,
) !RuntimeConnection {
    return startRuntimeConnection(
        allocator,
        target,
        artifacts,
        remote_command,
        .session_broker,
        &.{},
        false,
        null,
        false,
        null,
        null,
        failure_policy,
    );
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
    target: SshTarget,
    runtime_config: SessionRuntimeConfig,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    failure_policy: BootstrapFailurePolicy,
    child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
) !void {
    while (true) {
        const end = attached_client.runAttachedClient(
            child.child.stdout.?.handle,
            child.child.stdin.?.handle,
            session,
            .{ .monitor_connection = true },
        ) catch |err| {
            waitAfterRuntimeAttachFailure(child, "attached client");
            if (process_exit.is(err)) return err;
            try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        var race_existing_connection = false;
        switch (end) {
            .detach => {
                client_log.debug("event=detach host={s} session={s}", .{ target.host, session.idSlice() });
                child.terminate();
                try finishDetachedSshSession(allocator, runtime_config.common.overlay_args.slice(), session);
                return;
            },
            .session_ended => {
                client_log.debug("event=session_ended host={s} session={s}", .{ target.host, session.idSlice() });
                const exit_status = try finishEndedRemoteSession(child, session);
                return process_exit.request(exit_status);
            },
            .unresponsive => {
                client_log.debug("event=disconnect reason=unresponsive host={s} session={s}", .{ target.host, session.idSlice() });
                race_existing_connection = true;
            },
            .transport_closed => {
                client_log.debug("event=disconnect reason=transport_closed host={s} session={s}", .{ target.host, session.idSlice() });
                child.closeStdin();
                const term: ?std.process.Child.Term = child.wait() catch |err| blk: {
                    client_log.debug("event=transport_closed_wait_failed host={s} session={s} error={t}", .{ target.host, session.idSlice(), err });
                    break :blk null;
                };
                if (term) |value| {
                    client_log.debug("event=transport_closed_ssh_exit host={s} session={s} term={t}", .{ target.host, session.idSlice(), value });
                }
            },
        }

        const pending_input_at_disconnect = session.hasPendingInputAck();
        const pending_paste_like_input_at_disconnect = session.hasPendingPasteLikeInputAck();
        var reconnect_ui = try client_ui.ReconnectUi.beginWithPresentation(
            session.viewport_offset,
            reconnectPresentationForFilterLevel(runtime_config.common.filter_level),
        );
        var reconnect_ui_active = true;
        defer if (reconnect_ui_active) reconnect_ui.deinit();

        if (race_existing_connection) {
            switch (try raceExistingConnectionWithReconnect(
                target,
                failure_policy,
                artifacts,
                remote_command,
                child,
                session,
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
                        session,
                    ) catch |err| switch (err) {
                        error.SessionEnded => {
                            const exit_status = try finishEndedRemoteSession(child, session);
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
                    child.* = new_child;
                    session.discardPendingInputAcks();
                    session.viewport_offset = try reconnect_ui.clearOverlay();
                    attached_client.finishReconnectRepaint(child.child.stdout.?.handle, child.child.stdin.?.handle, session) catch |err| switch (err) {
                        error.SessionEnded => {
                            const exit_status = try finishEndedRemoteSession(child, session);
                            return process_exit.request(exit_status);
                        },
                        else => return err,
                    };
                    reconnect_ui.restoreTitleAfterReconnect(session.app_title_present, session.titleFallbackSlice());
                    client_log.debug("event=reconnect_success host={s} session={s} attempt=0", .{
                        target.host,
                        session.idSlice(),
                    });
                    reconnect_ui.deinit();
                    reconnect_ui_active = false;
                    continue;
                },
                .session_ended => {
                    const exit_status = try finishEndedRemoteSession(child, session);
                    return process_exit.request(exit_status);
                },
                .detach => {
                    child.terminate();
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, runtime_config.common.overlay_args.slice(), session);
                    return;
                },
                .failed => |err| {
                    client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt=0 error={t}", .{
                        target.host,
                        session.idSlice(),
                        err,
                    });
                    client_log.userDiagnosticInfo("reconnect failed: parallel: {t}", .{err});
                    child.terminate();
                },
                .disconnected => |err| {
                    client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt=0 error={t}", .{
                        target.host,
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
                target.host,
                session.idSlice(),
                reconnect_attempt,
                delay_ms,
            });
            const wait_decision = try reconnect_ui.waitForReconnect(delay_ms);
            switch (wait_decision) {
                .detach => {
                    client_log.debug("event=reconnect_detach host={s} session={s} attempt={}", .{
                        target.host,
                        session.idSlice(),
                        reconnect_attempt,
                    });
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, runtime_config.common.overlay_args.slice(), session);
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

            child.* = startRuntimeConnection(
                allocator,
                target,
                artifacts,
                remote_command,
                .session_broker,
                &.{},
                true,
                &reconnect_ui,
                true,
                null,
                null,
                failure_policy,
            ) catch |err| switch (err) {
                error.ExitRequested => return err,
                error.ReconnectDetached => {
                    finishReconnectUiForDetach(&reconnect_ui, &reconnect_ui_active);
                    try finishDetachedSshSession(allocator, runtime_config.common.overlay_args.slice(), session);
                    return;
                },
                error.OutOfMemory => return err,
                else => {
                    client_log.debug("event=reconnect_failed stage=transport host={s} session={s} attempt={} error={t}", .{
                        target.host,
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
                session,
                reconnect_ui.cancellationFlag(),
            ) catch |err| {
                child.closeStdin();
                _ = child.wait() catch {};
                switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        client_log.debug("event=reconnect_failed stage=attach host={s} session={s} attempt={} error={t}", .{
                            target.host,
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
                    try finishDetachedSshSession(allocator, runtime_config.common.overlay_args.slice(), session);
                    return;
                },
                .reconnect_now, .wait_elapsed => {},
            }

            session.discardPendingInputAcks();
            session.viewport_offset = try reconnect_ui.clearOverlay();
            attached_client.finishReconnectRepaint(
                child.child.stdout.?.handle,
                child.child.stdin.?.handle,
                session,
            ) catch |err| {
                child.closeStdin();
                _ = child.wait() catch {};
                switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        client_log.debug("event=reconnect_failed stage=repaint host={s} session={s} attempt={} error={t}", .{
                            target.host,
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
                target.host,
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

fn finishDetachedSshSession(
    allocator: std.mem.Allocator,
    overlay_args: []const []const u8,
    session: *attached_client.RuntimeSession,
) !void {
    session.restoreAttachedClientEndPresentationForExit();
    _ = allocator;
    _ = overlay_args;
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    attached_client.writeDetachOverlayForDisconnect();
}

fn finishEndedRemoteSession(
    child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
) !u8 {
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
        .hygienic => .title,
        .emulated => .overlay,
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

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
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

fn raceExistingConnectionWithReconnect(
    target: SshTarget,
    failure_policy: BootstrapFailurePolicy,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
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
            target,
            failure_policy,
            artifacts,
            remote_command,
            old_child,
            session,
            reconnect_ui,
            pending_input_at_disconnect,
            pending_paste_like_input_at_disconnect,
        );
        switch (outcome) {
            .failed => |err| {
                client_log.debug("event=reconnect_failed stage=parallel host={s} session={s} attempt={} error={t}", .{
                    target.host,
                    session.idSlice(),
                    reconnect_attempt,
                    err,
                });
                client_log.userDiagnosticInfo("reconnect failed: parallel: {t}", .{err});
                const delay_ms = reconnect.delayMs(reconnect_attempt);
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, reconnect_ui);
                client_log.debug("event=reconnect_wait_unresponsive host={s} session={s} attempt={} delay_ms={}", .{
                    target.host,
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
    target: SshTarget,
    failure_policy: BootstrapFailurePolicy,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    old_child: *RuntimeConnection,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    pending_input_at_disconnect: bool,
    pending_paste_like_input_at_disconnect: bool,
) !ReconnectRaceOutcome {
    session.viewport_offset = reconnect_ui.currentViewportOffset();
    var state = ParallelReconnectState{
        .target = target,
        .artifacts = artifacts,
        .remote_command = remote_command,
        .reconnect_ui = reconnect_ui,
        .session = session.*,
        .failure_policy = failure_policy,
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
    ready_session: *attached_client.RuntimeSession,
    session: *attached_client.RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
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
        state.target,
        state.artifacts,
        state.remote_command,
        .session_broker,
        &.{},
        true,
        state.reconnect_ui,
        false,
        null,
        null,
        state.failure_policy,
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

    const stdin_fd = connection.child.stdin.?.handle;
    if (bootstrap_entrypoint) |entrypoint| {
        artifact_set.sendExec(stdin_fd, entrypoint, exec_args, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectDetached) {
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
            if (err == error.ReconnectDetached) {
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
        if (err == error.ReconnectDetached) {
            connection.terminate();
            return err;
        }
        const term = connection.wait() catch null;
        if (bootstrap_failure_term) |term_out| term_out.* = term;
        if (batch_mode) {
            return err;
        }
        try exitAfterSshBootstrapFailure(allocator, target, term, err);
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
            try exitAfterSshBootstrapFailure(allocator, target, term, err);
        };
    }

    if (std.mem.eql(u8, line, "OK")) {
        if (exec_args.len == 0) connection.suppressSshStderr();
        return connection;
    }

    if (std.mem.startsWith(u8, line, "ERR ")) {
        connection.closeStdin();
        _ = connection.wait() catch {};
        if (isUnsupportedPlatformBootstrapError(line) and canUsePlainSshFallback(failure_policy, batch_mode, reconnect_ui)) {
            try runPlainSshFallback(allocator, target, null);
        }
        if (isUnsupportedPlatformBootstrapError(line)) {
            try exitUnsupportedPlatform(failure_policy.unsupported_action, null);
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
    target: SshTarget,
    artifacts: ?*const ArtifactSet,
    remote_command: []const u8,
    bootstrap_entrypoint: BootstrapEntrypoint,
    stream_broker_args: []const []const u8,
    stderr_mode: SshStderrMode,
    last_failure_mutex: std.Thread.Mutex = .{},
    last_failure_term: ?std.process.Child.Term = null,

    pub fn start(self: *StreamClientStarter) !StreamClientTransport {
        self.recordFailureTerm(null);
        var failure_term: ?std.process.Child.Term = null;
        const connection = startRuntimeConnection(
            self.allocator,
            self.target,
            self.artifacts,
            self.remote_command,
            self.bootstrap_entrypoint,
            self.stream_broker_args,
            true,
            null,
            false,
            self.stderr_mode,
            &failure_term,
            .{ .unsupported_action = "start a proxy stream" },
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

fn shouldUseProxyStream(new: RemoteNewSession, common: CommonSessionOptions, stdin_is_tty: bool) bool {
    if (new.command_argv.len != 0) return false;
    if (filterLevelForcesProxy(common.filter_level) or new.proxy_required) return true;
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
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    new: RemoteNewSession,
) !noreturn {
    const diagnostics_plan = proxyDiagnosticsPlan(
        target.options,
        common.filter_level,
        new.tty_request,
        new.shell_command_args,
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
        target.options,
        if (client_socket_allocation) |allocation| allocation.path else null,
        diagnostics_plan.command_level,
        diagnostics_plan.client_ctrl_r,
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
            if (!stdout_is_tty) break :blk .{
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
    const stream_broker_args = [_][]const u8{
        proxy_guid,
        "proxy",
        "1",
        "1",
        proxy_target_arg,
        invocation.port,
        "-",
    };

    const stream_target = SshTarget{
        .options = invocation.ssh_options.items,
        .host = invocation.host,
        .default_ipqos_option = default_ipqos_option,
        .resolved_host = resolved_ssh_config.hostname,
        .resolved_port = resolved_ssh_config.port,
    };
    var starter = StreamClientStarter{
        .allocator = allocator,
        .target = stream_target,
        .artifacts = &artifacts,
        .remote_command = remote_command,
        .bootstrap_entrypoint = .stream_broker,
        .stream_broker_args = stream_broker_args[0..],
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

    const exit_status = stream_runtime.runLocalStream(allocator, &starter, .{
        .guid = proxy_guid,
        .source_fd = 0,
        .sink_fd = 1,
        .status_mode = status_mode,
        .intercept_ctrl_r = false,
        .control_fd = client_control_fd,
        .ctrl_r_status_enabled = proxy_control_ctrl_r_available and client_control_fd >= 0,
        .proxy_control_output_mode = proxy_control_output_mode,
        .title_fallback = invocation.host,
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
    return shouldUseProxyStream(remoteNewFromParsedSessh(parsed), parsed.invocation.common, stdin_is_tty);
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

    const option = try proxyCommandOption(std.testing.allocator, "sessh-dev", parsed.invocation.ssh_options, "/tmp/sessh-test/c/abc", .hygienic, true);
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

test "terminal reconnect presentation follows filter level" {
    try std.testing.expectEqual(client_ui.ReconnectPresentation.none, reconnectPresentationForFilterLevel(.raw));
    try std.testing.expectEqual(client_ui.ReconnectPresentation.title, reconnectPresentationForFilterLevel(.hygienic));
    try std.testing.expectEqual(client_ui.ReconnectPresentation.overlay, reconnectPresentationForFilterLevel(.emulated));
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
