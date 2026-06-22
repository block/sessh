// High-level ssh transport orchestration for public sessh invocations. It ties
// CLI routing, daemon startup, bootstrap policy, terminal-session clients, and
// proxy-stream OpenSSH commands together.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_blocking = @import("../core/blocking.zig");
const visible_client = @import("../session/visible_client.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
const core_fds = @import("../core/fds.zig");
const sessh_cli = @import("../sessh/cli.zig");
const sessh_routing = @import("../sessh/routing.zig");
const config = @import("../core/config.zig");
const daemon_client = @import("../daemon/client.zig");
const daemon_executable = @import("../daemon/executable.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const diagnostics_file = @import("../diagnostics/file.zig");
const diagnostics_policy = @import("../diagnostics/policy.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");
const user_error = @import("../core/user_error.zig");
const protocol = @import("../protocol/mod.zig");
const plain_ssh = @import("plain_ssh.zig");
const proxy_command = @import("proxy_command.zig");
const proxy_diagnostics_router = @import("proxy_diagnostics_router.zig");
const proxy_entry = @import("proxy_entry.zig");
const reconnect = @import("../reconnect/mod.zig");
const remote_shell = @import("remote_shell.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");
const pooled_ssh = @import("pooled_ssh.zig");
const foreground_frame_io = @import("foreground_frame_io.zig");
const guid_ref = @import("../core/guid.zig");
const ssh_transport_acquire = @import("ssh_transport_acquire.zig");
const ssh_opts = @import("ssh_options.zig");
const proxy_worker = @import("../stream/proxy_worker.zig");
const terminal = @import("../tty/terminal.zig");
const tty_transcript = @import("../tty/transcript.zig");
const pb = protocol.pb;

const CommonSessionOptions = sessh_cli.CommonSessionOptions;

pub const SshTtyRequest = ssh_opts.SshTtyRequest;
pub const classifySshOptions = ssh_opts.classifySshOptions;
pub const activePooledSshTransportCount = pooled_ssh.activePooledSshTransportCount;
pub const registerPooledSshTransportFromDaemon = pooled_ssh.registerPooledSshTransportFromDaemon;
pub const registerPooledTerminalDebugFromDaemon = pooled_ssh.registerPooledTerminalDebugFromDaemon;
pub const registerProxyFdPassOpenFromDaemon = pooled_ssh.registerProxyFdPassOpenFromDaemon;
pub const enqueueCleanupRequestToRemote = pooled_ssh.enqueueCleanupRequestToRemote;

const appendDefaultSshOptions = ssh_transport_process.appendDefaultSshOptions;
const defaultSshOptionsLen = ssh_transport_process.defaultSshOptionsLen;

const shellCommandFromRemoteArgs = remote_shell.shellCommandFromRemoteArgs;

const Platform = @import("bootstrap.zig").Platform;

const SshTarget = ssh_transport_process.Target;

const RemoteSessionConfig = struct {
    common: CommonSessionOptions,
    daemon_dir_name: ?[]u8 = null,
    disconnected_reap_ms: u64 = config.default_disconnected_reap_ms,

    fn deinit(self: *RemoteSessionConfig, allocator: std.mem.Allocator) void {
        if (self.daemon_dir_name) |dir_name| allocator.free(dir_name);
        self.* = undefined;
    }
};

pub const RemoteNewSession = sessh_routing.RemoteNewSession;

const BootstrapFailurePolicy = struct {
    allow_plain_ssh_fallback: bool = false,
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
const reconnect_ready_switch_delay_ms: u64 = 10_000;

fn remoteSessionConfig(
    allocator: std.mem.Allocator,
    common: CommonSessionOptions,
    ssh_options: []const []const u8,
) !RemoteSessionConfig {
    // Merge command-line options with sessh.env defaults. CLI values win, while
    // full isolation allocates a private daemon namespace so one connection does
    // not accidentally reuse another connection's pooled SSH transport.
    var result = RemoteSessionConfig{
        .common = common,
    };
    const file_config = try client_config.loadFileConfig(allocator);
    if (!result.common.scrollback_row_count_set) {
        if (file_config.scrollback_row_count) |count| result.common.scrollback_row_count = count;
    }
    if (!result.common.bootstrap_set) {
        if (file_config.bootstrap) |enabled| result.common.bootstrap = enabled;
    }
    if (!result.common.filter_level_set) {
        if (file_config.filter_level) |level| result.common.filter_level = level;
    }
    if (!result.common.diagnostics_level_set) {
        if (file_config.diagnostics_level) |level| result.common.diagnostics_level = level;
    }
    if (!result.common.isolation_mode_set) {
        if (file_config.isolation_mode) |mode| result.common.isolation_mode = mode;
    }
    if (result.common.isolation_mode == .full) {
        result.daemon_dir_name = try daemon_socket_namespace.privateConnectionDirName(allocator);
    }
    if (file_config.disconnected_reap_ms) |ms| result.disconnected_reap_ms = ms;
    if (!result.common.client_log_level_set) {
        if (file_config.client_log_level) |level| {
            result.common.client_log_level = level;
        } else {
            result.common.client_log_level = sessh_routing.inferredClientLogLevel(ssh_options);
        }
    }
    return result;
}

pub const RunRemoteNewSessionOptions = struct {
    blocking: core_blocking.Blocking,
    exe: []const u8,
    ssh_options: []const []const u8,
    host: []const u8,
    common: CommonSessionOptions,
    new: RemoteNewSession,
    failure_policy: BootstrapFailurePolicy,
};

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper installs or finds the remote sessh binary, then execs the
/// `sessh-bridge` role we send in the EXEC line.
/// Installed packages keep one executable per supported platform under
/// `libexec/sessh/<os>-<arch>/sessh`. If that layout is unavailable, upload the
/// current binary for same-platform development tests.
pub fn runRemoteNewSession(
    allocator: std.mem.Allocator,
    options: RunRemoteNewSessionOptions,
) !void {
    var session_config = remoteSessionConfig(allocator, options.common, options.ssh_options) catch |err| {
        try user_error.printLine(options.blocking, "invalid config: {t}", .{err});
        return process_exit.request(64);
    };
    defer session_config.deinit(allocator);
    client_log.setLevel(session_config.common.client_log_level);
    if (session_config.common.diagnostics_file) |path| {
        diagnostics_file.validatePath(path) catch |err| {
            try user_error.printLine(options.blocking, "cannot open diagnostics file {s}: {t}", .{ path, err });
            return process_exit.request(1);
        };
    }

    const target = SshTarget{ .options = options.ssh_options, .host = options.host };
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0;
    const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    if (sessh_routing.shouldUseProxyStream(.{
        .new = options.new,
        .common = session_config.common,
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
    })) {
        if (session_config.common.capture_tty_transcript != null) {
            try user_error.line(options.blocking, "--capture-tty-transcript is not supported with proxy stream mode");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(.{
            .allocator = allocator,
            .blocking = options.blocking,
            .exe = options.exe,
            .target = target,
            .common = session_config.common,
            .daemon_dir_name = session_config.daemon_dir_name,
            .new = options.new,
        });
    }

    const shell_command = try shellCommandFromRemoteArgs(allocator, options.new.shell_command_args);
    defer if (shell_command) |command| allocator.free(command);

    var local_terminal_probe = visible_client.LocalTerminalProbe.start(options.blocking);
    defer local_terminal_probe.deinit();

    var transcript_capture = TranscriptCapture{};
    try transcript_capture.start(options.blocking, allocator, session_config.common.capture_tty_transcript);
    defer transcript_capture.deinit();

    const new_guid = try guid_ref.generateSessionGuid(allocator);
    defer allocator.free(new_guid);

    var transport = try openTerminalDaemonTransport(.{
        .allocator = allocator,
        .blocking = options.blocking,
        .exe = options.exe,
        .target = target,
        .common = session_config.common,
        .daemon_dir_name = session_config.daemon_dir_name,
    });

    var local_terminal = local_terminal_probe.finish();
    defer local_terminal.deinit();

    var session = visible_client.startNewSessionOnTerminalWorker(.{
        .blocking = options.blocking,
        .worker_fds = .{
            .read = transport.readFd(),
            .write = transport.writeFd(),
        },
        .scrollback_row_count = session_config.common.scrollback_row_count,
        .session_guid = new_guid,
        .command_argv = options.new.command_argv,
        .shell_command = shell_command,
        .reap_ms = session_config.disconnected_reap_ms,
        .local_terminal = &local_terminal,
    }) catch |err| {
        if (err == error.VersionMismatch) {
            transport.close();
            if (session_config.common.capture_tty_transcript != null) {
                try user_error.line(options.blocking, "--capture-tty-transcript requires a compatible sessh remote");
                return process_exit.request(1);
            }
            if (options.new.command_argv.len > 0 or shell_command != null) {
                try user_error.line(options.blocking, "remote command recovery requires a compatible sessh remote");
                return process_exit.request(1);
            }
            try runPlainSshFallbackAfterVersionMismatch(options.blocking, allocator, target);
        }
        if (err == error.UnsupportedRemotePlatform and options.failure_policy.allow_plain_ssh_fallback) {
            transport.close();
            try runPlainSshFallback(options.blocking, allocator, target, null);
        }
        waitAfterTerminalWorkerConnectionFailure(options.blocking, &transport, "start");
        if (process_exit.is(err)) return err;
        try user_error.printLine(options.blocking, "ssh remote session failed: {t}", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(target.host);
    try runVisibleRemoteClient(.{
        .blocking = options.blocking,
        .allocator = allocator,
        .exe = options.exe,
        .target = target,
        .session_config = session_config,
        .transport = &transport,
        .session = &session,
    });
}

const TerminalDaemonTransportOpen = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    daemon_dir_name: ?[]const u8,
};

fn openTerminalDaemonTransport(options: TerminalDaemonTransportOpen) !TerminalTransport {
    // Open a local daemon IPC connection and ask it to acquire a pooled SSH
    // transport for a terminal-emulator session. The returned fd remains framed
    // client/remote protocol for the visible client.
    const allocator = options.allocator;
    const blocking = options.blocking;
    const exe = options.exe;
    const target = options.target;
    const common = options.common;
    const daemon_dir_name = options.daemon_dir_name;
    const fd = if (daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(blocking, allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(blocking, allocator, exe);
    var daemon_fd = core_fds.OwnedFd.init(fd);
    defer daemon_fd.deinit();

    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = target.host,
        .bootstrap = common.bootstrap,
        .isolation_mode = ssh_transport_acquire.protoIsolationModeForConfig(common.isolation_mode),
    };
    defer request.ssh_option.deinit(allocator);
    defer ssh_transport_acquire.deinitOwnedFields(allocator, &request);
    try request.ssh_option.appendSlice(allocator, target.options);
    try ssh_transport_acquire.appendCurrentSshAgent(allocator, &request);
    try ssh_transport_acquire.appendCurrentProcess(allocator, &request);
    try ssh_transport_acquire.appendCurrentEnvironment(allocator, &request);

    try sendClientDaemonPayloadForeground(blocking, allocator, daemon_fd.get(), .{ .ssh_transport_acquire = request });
    return .{ .fd = daemon_fd.take() };
}

const TranscriptCapture = struct {
    recorder: ?tty_transcript.Recorder = null,

    fn start(self: *TranscriptCapture, blocking: core_blocking.Blocking, allocator: std.mem.Allocator, capture_tty_transcript: ?[]const u8) !void {
        const path = capture_tty_transcript orelse return;
        self.recorder = try tty_transcript.Recorder.init(allocator, path);
        errdefer {
            if (self.recorder) |*recorder| recorder.deinit();
            self.recorder = null;
        }
        if (self.recorder) |*recorder| {
            try recorder.warnEnabled(blocking);
            tty_transcript.activate(recorder);
        }
    }

    fn deinit(self: *TranscriptCapture) void {
        if (self.recorder) |*recorder| {
            tty_transcript.deactivate();
            recorder.deinit();
            self.recorder = null;
        }
    }
};

// One visible terminal client owns one emulated session, but the daemon
// transport underneath it can be replaced during reconnect. Keep that state
// bundle explicit so reconnect paths update the live transport in one place.
const RemoteClientContext = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    session_config: RemoteSessionConfig,
    transport: *TerminalTransport,
    session: *visible_client.VisibleClientSessionState,
};

fn runVisibleRemoteClient(ctx: RemoteClientContext) !void {
    // The visible client owns terminal presentation, while the daemon transport
    // may be replaced after a remote disconnect. Loop until the session ends,
    // the local daemon fails, or reconnect swaps in a fresh transport.
    while (true) {
        const end = visible_client.runVisibleClient(
            ctx.blocking,
            .{
                .read = ctx.transport.readFd(),
                .write = ctx.transport.writeFd(),
            },
            ctx.session,
            .{ .monitor_connection = false },
        ) catch |err| {
            waitAfterTerminalWorkerConnectionFailure(ctx.blocking, ctx.transport, "visible client");
            if (process_exit.is(err)) return err;
            try user_error.printLine(ctx.blocking, "ssh remote session failed: {t}", .{err});
            return process_exit.request(1);
        };
        switch (end) {
            .session_ended => {
                client_log.debug("event=session_ended host={s} session={s}", .{ ctx.target.host, ctx.session.idSlice() });
                const exit_status = try finishEndedRemoteSession(ctx.blocking, ctx.transport, ctx.session);
                return process_exit.request(exit_status);
            },
            .client_hangup => {
                client_log.debug("event=client_hangup host={s} session={s}", .{ ctx.target.host, ctx.session.idSlice() });
                visible_client.drainLocalTransportDiagnostics(ctx.blocking, ctx.transport.readFd(), 100);
                ctx.transport.terminate();
                try finishHungUpSshSession(ctx.blocking, ctx.session);
                return;
            },
            .unresponsive => {
                client_log.debug("event=local_daemon_unresponsive host={s} session={s}", .{ ctx.target.host, ctx.session.idSlice() });
                try finishLocalDaemonClosedSshSession(ctx.blocking, ctx.transport, ctx.session);
                return process_exit.request(255);
            },
            .transport_closed => {
                client_log.debug("event=local_daemon_closed host={s} session={s}", .{ ctx.target.host, ctx.session.idSlice() });
                try finishLocalDaemonClosedSshSession(ctx.blocking, ctx.transport, ctx.session);
                return process_exit.request(255);
            },
            .remote_transport_closed => {
                client_log.debug("event=disconnect reason=remote_transport_closed host={s} session={s}", .{ ctx.target.host, ctx.session.idSlice() });
                ctx.transport.close();
                try reconnectRemoteSessionClient(ctx);
            },
        }
    }
}

// Reconnect keeps the original visible client alive while racing replacement
// daemon transports. It only switches after the new transport has connected and
// produced a repaint, so stale output from the broken connection cannot be
// applied to the user's terminal.
fn reconnectRemoteSessionClient(ctx: RemoteClientContext) !void {
    const pending_input_at_disconnect = ctx.session.hasPendingInputAck();
    const pending_paste_like_input_at_disconnect = ctx.session.hasPendingPasteLikeInputAck();
    var diagnostics_handle = diagnostics_file.Handle.open(ctx.session_config.common.diagnostics_file) catch |err| blk: {
        client_log.userDiagnosticInfo("cannot open diagnostics file during reconnect: {t}", .{err});
        break :blk diagnostics_file.Handle{};
    };
    defer diagnostics_handle.deinit();
    const diagnostics_terminal_fds = diagnostics_handle.terminalFdsOr(.{});
    const diagnostics_line_fd = diagnostics_handle.outputOr(posix.STDERR_FILENO);
    var reconnect_ui = try client_ui.ReconnectUi.beginWithOptions(
        ctx.blocking,
        ctx.session.viewport_offset,
        .{
            .presentation = diagnostics_policy.terminalPresentation(.{
                .filter_level = ctx.session_config.common.filter_level,
                .diagnostics_level = ctx.session_config.common.diagnostics_level,
                .diagnostics_output_is_tty = c.isatty(diagnostics_terminal_fds.output) != 0,
            }),
            .terminal_fds = diagnostics_terminal_fds,
            .line_fd = diagnostics_line_fd,
        },
    );
    var reconnect_ui_active = true;
    defer if (reconnect_ui_active) reconnect_ui.deinit();

    var reconnect_attempt: usize = 0;
    while (true) {
        const delay_ms = reconnect.delayMs(reconnect_attempt);
        client_log.debug("event=reconnect_wait host={s} session={s} attempt={} delay_ms={}", .{
            ctx.target.host,
            ctx.session.idSlice(),
            reconnect_attempt,
            delay_ms,
        });
        switch (try reconnect_ui.waitForReconnect(delay_ms)) {
            .client_hangup => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishHungUpSshSession(ctx.blocking, ctx.session);
                return process_exit.request(0);
            },
            .reconnect_now, .wait_elapsed => {
                client_log.debug("event=reconnect_attempt host={s} session={s} attempt={}", .{
                    ctx.target.host,
                    ctx.session.idSlice(),
                    reconnect_attempt,
                });
            },
        }

        var replacement = openTerminalDaemonTransport(.{
            .allocator = ctx.allocator,
            .blocking = ctx.blocking,
            .exe = ctx.exe,
            .target = ctx.target,
            .common = ctx.session_config.common,
            .daemon_dir_name = ctx.session_config.daemon_dir_name,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure(ctx, .{
                    .stage = .transport,
                    .attempt = reconnect_attempt,
                    .err = err,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };
        var replacement_active = true;
        defer if (replacement_active) replacement.close();

        ctx.session.viewport_offset = reconnect_ui.currentViewportOffset();
        visible_client.reconnectSessionOnTerminalWorkerCancellable(
            ctx.blocking,
            .{
                .read = replacement.readFd(),
                .write = replacement.writeFd(),
            },
            ctx.session,
            reconnect_ui.cancellationFlag(),
        ) catch |err| switch (err) {
            error.RemoteDaemonDied => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishRemoteDaemonDiedSshSession(ctx.blocking, &replacement, ctx.session);
                return process_exit.request(255);
            },
            error.RemoteTransportClosed => {
                noteReconnectFailure(ctx, .{
                    .stage = .connect,
                    .attempt = reconnect_attempt,
                    .err = err,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure(ctx, .{
                    .stage = .connect,
                    .attempt = reconnect_attempt,
                    .err = err,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };

        switch (try waitForReconnectSwitchIfNeeded(&reconnect_ui, .{
            .pending_input_at_disconnect = pending_input_at_disconnect,
            .pending_paste_like_input_at_disconnect = pending_paste_like_input_at_disconnect,
        })) {
            .client_hangup => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                replacement.close();
                try finishHungUpSshSession(ctx.blocking, ctx.session);
                return process_exit.request(0);
            },
            .reconnect_now, .wait_elapsed => {},
        }

        ctx.session.discardPendingInputAcks();
        ctx.session.viewport_offset = try reconnect_ui.clearOverlay();
        visible_client.finishReconnectRepaint(
            ctx.blocking,
            replacement.readFd(),
            ctx.session,
        ) catch |err| switch (err) {
            error.RemoteDaemonDied => {
                finishReconnectUi(&reconnect_ui, &reconnect_ui_active);
                try finishRemoteDaemonDiedSshSession(ctx.blocking, &replacement, ctx.session);
                return process_exit.request(255);
            },
            error.SessionEnded => {
                replacement_active = false;
                ctx.transport.* = replacement;
                const exit_status = try finishEndedRemoteSession(ctx.blocking, ctx.transport, ctx.session);
                return process_exit.request(exit_status);
            },
            error.RemoteTransportClosed => {
                noteReconnectFailure(ctx, .{
                    .stage = .repaint,
                    .attempt = reconnect_attempt,
                    .err = err,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
            error.OutOfMemory => return err,
            else => {
                noteReconnectFailure(ctx, .{
                    .stage = .repaint,
                    .attempt = reconnect_attempt,
                    .err = err,
                });
                reconnect_attempt = nextReconnectAttemptAfterFailure(reconnect_attempt, &reconnect_ui);
                continue;
            },
        };

        client_log.debug("event=reconnect_success host={s} session={s} attempt={}", .{
            ctx.target.host,
            ctx.session.idSlice(),
            reconnect_attempt,
        });
        reconnect_ui.restoreTitleAfterReconnect(ctx.session.app_title_present, ctx.session.titleFallbackSlice());
        reconnect_ui.deinit();
        reconnect_ui_active = false;
        replacement_active = false;
        ctx.transport.* = replacement;
        return;
    }
}

fn waitAfterTerminalWorkerConnectionFailure(blocking: core_blocking.Blocking, transport: *TerminalTransport, stage: []const u8) void {
    transport.closeStdin();
    transport.close();
    client_log.flush(blocking, posix.STDERR_FILENO);
    user_error.printLine(blocking, "ssh remote transport closed after connect {s} failure", .{stage}) catch {};
}

fn finishHungUpSshSession(blocking: core_blocking.Blocking, session: *visible_client.VisibleClientSessionState) !void {
    session.restoreVisibleClientEndPresentationForExit(blocking);
    client_log.flush(blocking, posix.STDERR_FILENO);
    try tty_transcript.finishActiveOrReport(blocking);
}

fn finishLocalDaemonClosedSshSession(blocking: core_blocking.Blocking, transport: *TerminalTransport, session: *visible_client.VisibleClientSessionState) !void {
    transport.close();
    session.restoreVisibleClientEndPresentationForExit(blocking);
    client_log.flush(blocking, posix.STDERR_FILENO);
    try user_error.cleanTerminalLine(blocking, "local daemon connection lost");
    try tty_transcript.finishActiveOrReport(blocking);
}

fn finishRemoteDaemonDiedSshSession(blocking: core_blocking.Blocking, transport: *TerminalTransport, session: *visible_client.VisibleClientSessionState) !void {
    transport.close();
    session.restoreVisibleClientEndPresentationForExit(blocking);
    client_log.flush(blocking, posix.STDERR_FILENO);
    try user_error.cleanTerminalLine(blocking, "remote daemon died");
    try tty_transcript.finishActiveOrReport(blocking);
}

fn finishReconnectUi(reconnect_ui: *client_ui.ReconnectUi, active: *bool) void {
    if (!active.*) return;
    _ = reconnect_ui.clearOverlay() catch {};
    reconnect_ui.restoreTitleForEnd();
    reconnect_ui.deinit();
    active.* = false;
}

const ReconnectFailureStage = enum {
    transport,
    connect,
    repaint,

    fn label(self: ReconnectFailureStage) []const u8 {
        return switch (self) {
            .transport => "transport",
            .connect => "connect",
            .repaint => "repaint",
        };
    }
};

const ReconnectFailure = struct {
    stage: ReconnectFailureStage,
    attempt: usize,
    err: anyerror,
};

fn noteReconnectFailure(ctx: RemoteClientContext, failure: ReconnectFailure) void {
    const stage = failure.stage.label();
    client_log.debug("event=reconnect_failed stage={s} host={s} session={s} attempt={} error={t}", .{
        stage,
        ctx.target.host,
        ctx.session.idSlice(),
        failure.attempt,
        failure.err,
    });
    client_log.userDiagnosticInfo("reconnect failed: {s}: {t}", .{ stage, failure.err });
}

fn waitForReconnectSwitchIfNeeded(
    reconnect_ui: *client_ui.ReconnectUi,
    context: client_ui.ReconnectSwitchContext,
) !client_ui.ReconnectDecision {
    if (reconnect_ui.hasReconnectAcknowledgement()) return .reconnect_now;
    const disposition = reconnect_ui.reconnectSwitchDisposition(context);
    return switch (disposition) {
        .automatic => .wait_elapsed,
        .delayed => reconnect_ui.waitForReconnectSwitchOrTimeout(reconnect_ready_switch_delay_ms),
        .manual_disconnected, .manual_unresponsive => reconnect_ui.waitForReconnectSwitch(disposition),
    };
}

fn nextReconnectAttemptAfterFailure(attempt: usize, reconnect_ui: *client_ui.ReconnectUi) usize {
    return reconnect.nextAttempt(attempt, if (reconnect_ui.consumeReconnectAcknowledgement()) .reset else .increment);
}

fn finishEndedRemoteSession(blocking: core_blocking.Blocking, transport: *TerminalTransport, session: *visible_client.VisibleClientSessionState) !u8 {
    const exit_status = session.endedProcessExitCode();
    session.restoreVisibleClientEndPresentationForExit(blocking);
    transport.closeStdin();
    transport.close();
    client_log.flush(blocking, posix.STDERR_FILENO);
    try tty_transcript.finishActiveOrReport(blocking);
    return exit_status;
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
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
    blocking: core_blocking.Blocking,
    exe: []const u8,
    target: SshTarget,
    bootstrap: bool,
    daemon_dir_name: ?[]const u8 = null,

    pub fn start(self: *DaemonStreamClientStarter) !DaemonStreamClientTransport {
        // Proxy streams use the same daemon transport acquisition path as
        // terminal sessions, but the foreground client will speak proxy-stream
        // protocol over the resulting fd.
        const fd = if (self.daemon_dir_name) |dir_name|
            try daemon_client.connectOrStartForDirName(self.blocking, self.allocator, self.exe, dir_name)
        else
            try daemon_client.connectOrStart(self.blocking, self.allocator, self.exe);
        var daemon_fd = core_fds.OwnedFd.init(fd);
        defer daemon_fd.deinit();

        var request = pb.ClientDaemonItem.SshTransportAcquire{
            .host = self.target.host,
            .bootstrap = self.bootstrap,
        };
        defer request.ssh_option.deinit(self.allocator);
        defer ssh_transport_acquire.deinitOwnedFields(self.allocator, &request);
        try request.ssh_option.appendSlice(self.allocator, self.target.options);
        try ssh_transport_acquire.appendCurrentSshAgent(self.allocator, &request);
        try ssh_transport_acquire.appendCurrentProcess(self.allocator, &request);

        try sendClientDaemonPayloadForeground(self.blocking, self.allocator, daemon_fd.get(), .{ .ssh_transport_acquire = request });
        return .{ .fd = daemon_fd.take() };
    }

    pub fn exitAfterInitialFailure(self: *DaemonStreamClientStarter, err: anyerror) !void {
        _ = self;
        return err;
    }
};

const OpenProxyDiagnosticsOptions = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    exe: []const u8,
    guid: []const u8,
    daemon_dir_name: ?[]const u8,
};

fn openProxyDiagnostics(options: OpenProxyDiagnosticsOptions) !c.fd_t {
    const allocator = options.allocator;
    const fd = if (options.daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(options.blocking, allocator, options.exe, dir_name)
    else
        try daemon_client.connectOrStart(options.blocking, allocator, options.exe);
    var daemon_fd = core_fds.OwnedFd.init(fd);
    defer daemon_fd.deinit();
    try sendClientDaemonPayloadForeground(options.blocking, allocator, daemon_fd.get(), .{ .proxy_diagnostics_open = .{
        .proxy_guid = options.guid,
    } });
    return daemon_fd.take();
}

// Proxy stream mode is for SSH features that OpenSSH must own directly, such
// as X11, agent forwarding, port forwarding, subsystems, and non-tty commands.
// The visible outer `ssh` process gets the user's original options plus a
// ProxyCommand. That ProxyCommand is a local sessh process that reconnects a
// byte-clean stream to sesshd, and the remote proxy process then opens a TCP
// connection to sshd on the remote machine.
const ProxyStreamSshOptions = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    daemon_dir_name: ?[]const u8,
    new: RemoteNewSession,
};

// Build the outer OpenSSH invocation for proxy-stream mode. The proxy command
// is where sessh reconnects and diagnoses the byte stream; this function only
// decides whether the visible ssh process should be raw, wrapped in a local
// PTY, or connected through fd-pass.
fn runProxyStreamSsh(options: ProxyStreamSshOptions) !noreturn {
    const remote_command_args: []const []const u8 = if (sessh_routing.hasRemoteShellCommand(options.new.shell_command_args))
        options.new.shell_command_args
    else
        &.{};
    const use_fd_pass = diagnostics_policy.isolationModeUsesDirectProxyPlacement(options.common.isolation_mode);
    const diagnostics_plan = if (use_fd_pass) diagnostics_policy.ProxyStreamPlan{
        .command_level = .unhygienic,
        .use_daemon_control = false,
        .wrap_visible_ssh = false,
        .client_ctrl_r = false,
    } else diagnostics_policy.proxyStreamPlan(.{
        .ssh_options = options.target.options,
        .filter_level = options.common.filter_level,
        .tty_request = options.new.tty_request,
        .shell_command_args = remote_command_args,
        .stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0,
        .stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0,
    });
    var diagnostics_guid: ?[]u8 = null;
    defer if (diagnostics_guid) |guid| options.allocator.free(guid);
    var client_control_fd = core_fds.OwnedFd{};
    defer client_control_fd.deinit();
    if (diagnostics_plan.use_daemon_control) {
        diagnostics_guid = try guid_ref.generateProxyGuid(options.allocator);
        client_control_fd = core_fds.OwnedFd.init(try openProxyDiagnostics(.{
            .allocator = options.allocator,
            .blocking = options.blocking,
            .exe = options.exe,
            .guid = diagnostics_guid.?,
            .daemon_dir_name = options.daemon_dir_name,
        }));
    }
    const auto_diagnostics_file = try diagnostics_policy.autoProxyDiagnosticsFile(
        options.allocator,
        .{
            .explicit_diagnostics_file = options.common.diagnostics_file,
            .use_daemon_control = diagnostics_plan.use_daemon_control,
            .wrap_visible_ssh = diagnostics_plan.wrap_visible_ssh,
            .stdin_fd = posix.STDIN_FILENO,
            .stderr_fd = posix.STDERR_FILENO,
        },
    );
    defer if (auto_diagnostics_file) |path| options.allocator.free(path);
    const diagnostics_file_path = options.common.diagnostics_file orelse auto_diagnostics_file;
    const proxy_client_ctrl_r = diagnostics_plan.client_ctrl_r;
    const proxy_daemon_dir_name = options.daemon_dir_name orelse try daemon_socket_namespace.defaultDirName(options.allocator);
    defer if (options.daemon_dir_name == null) options.allocator.free(proxy_daemon_dir_name);
    try daemon_client.ensureStartedForDirName(options.blocking, options.allocator, options.exe, proxy_daemon_dir_name);
    var namespace_executables = try daemon_executable.namespaceExecutablePaths(options.allocator, proxy_daemon_dir_name);
    defer namespace_executables.deinit();

    const proxy_command_option = try proxy_command.commandOption(options.allocator, .{
        .exe = namespace_executables.proxy,
        .ssh_options = options.target.options,
        .diagnostics_guid = diagnostics_guid,
        .filter_level = diagnostics_plan.command_level,
        .diagnostics_level = options.common.diagnostics_level,
        .client_ctrl_r = proxy_client_ctrl_r,
        .diagnostics_file = diagnostics_file_path,
        .bootstrap = options.common.bootstrap,
        .daemon_dir_name = options.daemon_dir_name,
        .use_fd_pass = use_fd_pass,
    });
    defer options.allocator.free(proxy_command_option);

    const default_options = defaultSshOptionsLen(options.target);
    const ssh_arg_count = 1 + @as(usize, if (use_fd_pass) 1 else 0) + default_options + options.target.options.len + 1 + remote_command_args.len;
    const ssh_args = try options.allocator.alloc([]const u8, ssh_arg_count);
    defer options.allocator.free(ssh_args);

    var index: usize = 0;
    // Put sessh's ProxyCommand first. OpenSSH gives command-line options high
    // precedence, and this keeps a user/config ProxyCommand available to the
    // inner bootstrap ssh while ensuring the outer ssh talks over our stream.
    ssh_args[index] = proxy_command_option;
    index += 1;
    if (use_fd_pass) {
        ssh_args[index] = "-oProxyUseFdPass=yes";
        index += 1;
    }
    index = appendDefaultSshOptions(ssh_args, index, options.target.default_ipqos_option);
    @memcpy(ssh_args[index .. index + options.target.options.len], options.target.options);
    index += options.target.options.len;
    ssh_args[index] = options.target.host;
    index += 1;
    @memcpy(ssh_args[index..], remote_command_args);

    if (diagnostics_plan.wrap_visible_ssh and client_control_fd.get() >= 0) {
        const fd = client_control_fd.take();
        try plain_ssh.runArgvUnderLocalPty(.{
            .blocking = options.blocking,
            .allocator = options.allocator,
            .ssh_args = ssh_args,
            .control_fd = fd,
            .client_ctrl_r = diagnostics_plan.client_ctrl_r,
            .diagnostic_name = "proxy-stream",
        });
    }
    if (diagnostics_plan.use_daemon_control and client_control_fd.get() >= 0) {
        const fd = client_control_fd.take();
        try plain_ssh.runArgvWithDiagnostics(.{
            .blocking = options.blocking,
            .allocator = options.allocator,
            .ssh_args = ssh_args,
            .control_fd = fd,
            .diagnostic_name = "proxy-stream",
        });
    }
    try plain_ssh.runArgv(options.blocking, options.allocator, ssh_args, "proxy-stream");
}

// Entry point for the generated ProxyCommand process. It parses only the
// role-shaped proxy flags, then either hands a raw fd to the shared daemon or
// runs a process-isolated proxy bridge that keeps diagnostics/control separate
// from OpenSSH's byte stream.
pub fn runProxyStream(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var invocation = proxy_entry.parse(allocator, args) catch |err| {
        try proxy_entry.printArgError(blocking, err);
        return process_exit.request(64);
    };
    defer invocation.deinit(allocator);

    const proxy_guid = try guid_ref.generateProxyGuid(allocator);
    defer allocator.free(proxy_guid);

    if (invocation.port.len == 0) return error.InvalidProxyStreamArgs;
    const proxy_port = try std.fmt.parseInt(u16, invocation.port, 10);

    try invocation.ssh_options.append(allocator, "-p");
    try invocation.ssh_options.append(allocator, invocation.port);
    if (invocation.user.len > 0) {
        try invocation.ssh_options.append(allocator, "-l");
        try invocation.ssh_options.append(allocator, invocation.user);
    }
    const stream_target = SshTarget{
        .options = invocation.ssh_options.items,
        .host = invocation.host,
    };
    if (invocation.use_fd_pass) {
        try runProxyStreamFdPass(.{
            .allocator = allocator,
            .blocking = blocking,
            .exe = exe,
            .invocation = invocation,
            .stream_target = stream_target,
            .proxy_guid = proxy_guid,
            .proxy_port = proxy_port,
        });
        return process_exit.request(0);
    }
    var starter = DaemonStreamClientStarter{
        .allocator = allocator,
        .blocking = blocking,
        .exe = exe,
        .target = stream_target,
        .bootstrap = invocation.bootstrap,
        .daemon_dir_name = invocation.daemon_dir_name,
    };

    var diagnostics_handle = diagnostics_file.Handle.open(invocation.diagnostics_file) catch |err| {
        try blocking.stderrPrint(
            "sessh: proxy mode cannot open diagnostics file {s}: {t}\n",
            .{ invocation.diagnostics_file orelse "", err },
        );
        return process_exit.request(1);
    };
    defer diagnostics_handle.deinit();
    const diagnostics_output_fd = diagnostics_handle.outputOr(posix.STDERR_FILENO);
    const diagnostics_output_is_tty = c.isatty(diagnostics_output_fd) != 0;
    const status_mode = diagnostics_policy.streamStatusMode(.{
        .filter_level = invocation.filter_level,
        .diagnostics_level = invocation.diagnostics_level,
        .has_daemon_control = invocation.diagnostics_guid != null and invocation.diagnostics_file == null,
        .diagnostics_output_is_tty = diagnostics_output_is_tty,
    });

    const exit_status = proxy_worker.runLocalStream(blocking, allocator, &starter, .{
        .guid = proxy_guid,
        .proxy_host = "localhost",
        .proxy_port = proxy_port,
        .stream_fds = .{ .source = posix.STDIN_FILENO, .sink = posix.STDOUT_FILENO },
        .reconnect_input_fd = diagnostics_handle.input_fd,
        .status_mode = status_mode,
        .status_fd = if (status_mode == .line or status_mode == .status_line or status_mode == .jsonl or status_mode == .title)
            diagnostics_output_fd
        else
            -1,
        .intercept_ctrl_r = false,
        .ctrl_r_status_enabled = (invocation.client_ctrl_r and invocation.diagnostics_guid != null) or diagnostics_handle.hasInput(),
        .title_fallback = invocation.host,
        .reset_on_source_eof = true,
    }) catch |err| {
        try starter.exitAfterInitialFailure(err);
        return;
    };
    return process_exit.request(exit_status);
}

const ProxyStreamFdPassOptions = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    exe: []const u8,
    invocation: proxy_entry.Invocation,
    stream_target: SshTarget,
    proxy_guid: []const u8,
    proxy_port: u16,
};

fn runProxyStreamFdPass(options: ProxyStreamFdPassOptions) !void {
    // fd-pass proxy mode keeps setup framed and proxy bytes raw. The proxy
    // command asks sesshd to acquire the SSH transport, passes one socketpair end
    // with SCM_RIGHTS, and gives the other end to OpenSSH.
    var daemon_fd = core_fds.OwnedFd.init(if (options.invocation.daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(options.blocking, options.allocator, options.exe, dir_name)
    else
        try daemon_client.connectOrStart(options.blocking, options.allocator, options.exe));
    defer daemon_fd.deinit();

    var transport = pb.ClientDaemonItem.SshTransportAcquire{
        .host = options.stream_target.host,
        .bootstrap = options.invocation.bootstrap,
    };
    defer transport.ssh_option.deinit(options.allocator);
    defer ssh_transport_acquire.deinitOwnedFields(options.allocator, &transport);
    try transport.ssh_option.appendSlice(options.allocator, options.stream_target.options);
    try ssh_transport_acquire.appendCurrentSshAgent(options.allocator, &transport);
    try ssh_transport_acquire.appendParentProcess(options.allocator, &transport);

    try proxy_entry.runFdPassSetup(.{
        .allocator = options.allocator,
        .blocking = options.blocking,
        .daemon_fd = daemon_fd.get(),
        .transport = transport,
        .proxy_guid = options.proxy_guid,
        .proxy_port = options.proxy_port,
    });
}

fn sendClientDaemonPayloadForeground(
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    payload: protocol.ClientDaemonPayload,
) !void {
    const encoded = try protocol.encodeClientDaemonPayload(allocator, payload);
    defer allocator.free(encoded);
    try foreground_frame_io.writeFrame(.{
        .blocking = blocking,
        .allocator = allocator,
        .fd = fd,
        .message_type = .client_daemon,
        .payload = encoded,
    });
}

fn runPlainSshFallbackAfterVersionMismatch(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, target: SshTarget) !noreturn {
    try user_error.line(blocking, "existing remote sessh is incompatible; falling back to plain ssh without sessh recovery");
    try runPlainSshFallbackArgv(blocking, allocator, target);
}

fn runPlainSshFallback(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, target: SshTarget, platform: ?Platform) !noreturn {
    if (platform) |remote_platform| {
        try user_error.printLine(
            blocking,
            "no matching sessh binary for remote platform {s} {s}; falling back to plain ssh without sessh recovery",
            .{ remote_platform.os, remote_platform.arch },
        );
    } else {
        try user_error.line(blocking, "remote platform is unsupported and no matching sessh binary is available; falling back to plain ssh without sessh recovery");
    }

    try runPlainSshFallbackArgv(blocking, allocator, target);
}

fn runPlainSshFallbackArgv(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, target: SshTarget) !noreturn {
    const ssh_argv = try allocator.alloc([]const u8, target.options.len + 1);
    defer allocator.free(ssh_argv);
    @memcpy(ssh_argv[0..target.options.len], target.options);
    ssh_argv[ssh_argv.len - 1] = target.host;

    try plain_ssh.runArgv(blocking, allocator, ssh_argv, "plain-ssh-fallback");
}

pub fn printSshArgError(blocking: core_blocking.Blocking, err: anyerror) !void {
    // Convert parser errors into ssh-shaped one-line diagnostics. The parser is
    // deliberately strict about sessh options appearing before HOST so remote
    // command arguments are not reinterpreted.
    switch (err) {
        error.MissingHost => try user_error.line(blocking, "missing host"),
        error.MissingScrollbackRowCount => try user_error.line(blocking, "--scrollback-limit requires a value"),
        error.MissingClientLogLevel => try user_error.line(blocking, "--log-level requires a value"),
        error.MissingFilterLevel => try user_error.line(blocking, "--filter-level requires one of: unhygienic, hygienic, emulated"),
        error.MissingDiagnosticsLevel => try user_error.line(blocking, "--diagnostics-level requires one of: overlay, status, title, line, jsonl"),
        error.MissingIsolationMode => try user_error.line(blocking, "--isolation-mode requires one of: full, process, none"),
        error.MissingDiagnosticsFile => try user_error.line(blocking, "--diagnostics-file requires a file path"),
        error.MissingTtyTranscriptPath => try user_error.line(blocking, "--capture-tty-transcript requires a path"),
        error.MissingSshOptionValue => try user_error.line(blocking, "ssh option is missing its value"),
        error.SesshOptionAfterHost => try user_error.line(blocking, "sessh options must appear before HOST"),
        error.ConflictingSesshAction => try user_error.line(blocking, "conflicting sessh actions"),
        error.InvalidScrollbackRowCount => try user_error.line(blocking, "invalid scrollback row count"),
        error.InvalidClientLogLevel => try user_error.line(blocking, "invalid log level"),
        error.InvalidFilterLevel => try user_error.line(blocking, "invalid filter level; expected one of: unhygienic, hygienic, emulated"),
        error.InvalidDiagnosticsLevel => try user_error.line(blocking, "invalid diagnostics level; expected one of: overlay, status, title, line, jsonl"),
        error.InvalidIsolationMode => try user_error.line(blocking, "invalid isolation mode; expected one of: full, process, none"),
        error.InvalidBool => try user_error.line(blocking, "expected true or false"),
        error.RemoteCommandUnsupported => try user_error.line(blocking, "remote command recovery requires -t or -tt"),
        error.UnsafeSshOption => try user_error.line(blocking, "ssh option is not safe for sessh transport"),
        error.UnsupportedSesshOption => try user_error.line(blocking, "unsupported sessh option for ssh transport"),
        error.UnsupportedSesshCliOption => try user_error.line(blocking, "unsupported sessh option"),
        error.UnsupportedSshOption => try user_error.line(blocking, "unsupported ssh option for sessh transport"),
        else => try user_error.printLine(blocking, "invalid ssh arguments: {t}", .{err}),
    }
}
