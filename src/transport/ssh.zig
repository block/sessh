const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const attached_client = @import("../session/attached_client.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
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

pub const BootstrapFailurePolicy = struct {
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
    if (!result.common.terminal_emulator_set) {
        if (file_config.terminal_emulator) |enabled| result.common.terminal_emulator = enabled;
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

/// Start the ssh transport by running the bootstrapper as the remote command.
///
/// The bootstrapper installs or finds the remote sessh binary, then execs the
/// `sessh-broker` role we send in the EXEC line.
/// Installed packages keep one executable per supported platform under
/// `libexec/sessh/<os>-<arch>/sessh`. If that layout is unavailable, upload the
/// current binary for same-platform development tests.
pub fn runRemoteNewSession(
    allocator: std.mem.Allocator,
    exe: []const u8,
    ssh_options: []const []const u8,
    host: []const u8,
    common: CommonSessionOptions,
    new: RemoteNewSession,
    failure_policy: BootstrapFailurePolicy,
) !void {
    var session_config = remoteSessionConfig(allocator, common, ssh_options) catch |err| {
        try user_error.printLine("invalid config: {t}", .{err});
        return process_exit.request(64);
    };
    defer session_config.deinit(allocator);
    client_log.setLevel(session_config.common.client_log_level);
    if (session_config.common.diagnostics_file) |path| {
        diagnostics_file.validatePath(path) catch |err| {
            try user_error.printLine("cannot open diagnostics file {s}: {t}", .{ path, err });
            return process_exit.request(1);
        };
    }

    const target = SshTarget{ .options = ssh_options, .host = host };
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0;
    const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    if (sessh_routing.shouldUseProxyStream(new, session_config.common, stdin_is_tty, stdout_is_tty)) {
        if (session_config.common.capture_tty_transcript != null) {
            try user_error.line("--capture-tty-transcript is not supported with proxy stream mode");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, exe, target, session_config.common, session_config.daemon_dir_name, new);
    }

    const shell_command = try shellCommandFromRemoteArgs(allocator, new.shell_command_args);
    defer if (shell_command) |command| allocator.free(command);

    var local_terminal_probe = attached_client.LocalTerminalProbe.start(allocator);
    defer local_terminal_probe.deinit();

    var transcript_recorder: ?tty_transcript.Recorder = null;
    try setupTranscriptRecorder(allocator, session_config.common.capture_tty_transcript, &transcript_recorder);
    defer teardownTranscriptRecorder(&transcript_recorder);

    const new_guid = try guid_ref.generateSessionGuid(allocator);
    defer allocator.free(new_guid);

    var transport = try openTerminalDaemonTransport(
        allocator,
        exe,
        target,
        session_config.common,
        session_config.daemon_dir_name,
    );

    var local_terminal = local_terminal_probe.finish();
    defer local_terminal.deinit();

    var session = attached_client.startNewSessionOnTerminalWorker(
        transport.readFd(),
        transport.writeFd(),
        session_config.common.scrollback_row_count,
        new_guid,
        new.command_argv,
        shell_command,
        session_config.disconnected_reap_ms,
        &local_terminal,
    ) catch |err| {
        if (err == error.VersionMismatch) {
            transport.close();
            if (session_config.common.capture_tty_transcript != null) {
                try user_error.line("--capture-tty-transcript requires a compatible sessh remote");
                return process_exit.request(1);
            }
            if (new.command_argv.len > 0 or shell_command != null) {
                try user_error.line("persistent command sessions require a compatible sessh remote");
                return process_exit.request(1);
            }
            try runPlainSshFallbackAfterVersionMismatch(allocator, target);
        }
        if (err == error.UnsupportedRemotePlatform and failure_policy.allow_plain_ssh_fallback) {
            transport.close();
            try runPlainSshFallback(allocator, target, null);
        }
        waitAfterTerminalWorkerAttachFailure(&transport, "start");
        if (process_exit.is(err)) return err;
        try user_error.printLine("ssh remote attach failed: {t}", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(target.host);
    try runAttachedRemoteClient(
        allocator,
        exe,
        target,
        session_config,
        &transport,
        &session,
    );
}

fn openTerminalDaemonTransport(
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    daemon_dir_name: ?[]const u8,
) !TerminalTransport {
    const fd = if (daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);

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

    try protocol.sendSshTransportAcquireFrame(allocator, fd, request);
    return .{ .fd = fd };
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
    session_config: RemoteSessionConfig,
    transport: *TerminalTransport,
    session: *attached_client.AttachedSessionState,
) !void {
    while (true) {
        const end = attached_client.runAttachedClient(
            transport.readFd(),
            transport.writeFd(),
            session,
            .{ .monitor_connection = false },
        ) catch |err| {
            waitAfterTerminalWorkerAttachFailure(transport, "attached client");
            if (process_exit.is(err)) return err;
            try user_error.printLine("ssh remote attach failed: {t}", .{err});
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
                    session_config,
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
    session_config: RemoteSessionConfig,
    transport: *TerminalTransport,
    session: *attached_client.AttachedSessionState,
) !void {
    const pending_input_at_disconnect = session.hasPendingInputAck();
    const pending_paste_like_input_at_disconnect = session.hasPendingPasteLikeInputAck();
    var diagnostics_handle = diagnostics_file.Handle.open(session_config.common.diagnostics_file) catch |err| blk: {
        client_log.userDiagnosticInfo("cannot open diagnostics file during reconnect: {t}", .{err});
        break :blk diagnostics_file.Handle{};
    };
    defer diagnostics_handle.deinit();
    const diagnostics_output_fd = if (diagnostics_handle.output_fd >= 0)
        diagnostics_handle.output_fd
    else
        posix.STDOUT_FILENO;
    const diagnostics_line_fd = if (diagnostics_handle.output_fd >= 0)
        diagnostics_handle.output_fd
    else
        posix.STDERR_FILENO;
    const diagnostics_input_fd = if (diagnostics_handle.input_fd >= 0)
        diagnostics_handle.input_fd
    else
        posix.STDIN_FILENO;
    var reconnect_ui = try client_ui.ReconnectUi.beginWithOptions(
        session.viewport_offset,
        .{
            .presentation = diagnostics_policy.terminalPresentation(
                session_config.common.filter_level,
                session_config.common.diagnostics_level,
                c.isatty(diagnostics_output_fd) != 0,
            ),
            .input_fd = diagnostics_input_fd,
            .output_fd = diagnostics_output_fd,
            .line_fd = diagnostics_line_fd,
        },
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
                return process_exit.request(0);
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
            session_config.common,
            session_config.daemon_dir_name,
        ) catch |err| switch (err) {
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
        attached_client.reconnectSessionOnTerminalWorkerCancellable(
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
                return process_exit.request(0);
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

fn waitAfterTerminalWorkerAttachFailure(transport: *TerminalTransport, stage: []const u8) void {
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    user_error.printLine("ssh remote transport closed after attach {s} failure", .{stage}) catch {};
}

fn finishHungUpSshSession(session: *attached_client.AttachedSessionState) !void {
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
}

fn finishLocalDaemonClosedSshSession(transport: *TerminalTransport, session: *attached_client.AttachedSessionState) !void {
    transport.close();
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try user_error.cleanTerminalLine("local daemon connection lost");
    try tty_transcript.finishActiveOrReport();
}

fn finishRemoteDaemonDiedSshSession(transport: *TerminalTransport, session: *attached_client.AttachedSessionState) !void {
    transport.close();
    session.restoreAttachedClientEndPresentationForExit();
    client_log.flush(2);
    try user_error.cleanTerminalLine("remote daemon died");
    try tty_transcript.finishActiveOrReport();
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
    session: *const attached_client.AttachedSessionState,
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

fn finishEndedRemoteSession(transport: *TerminalTransport, session: *attached_client.AttachedSessionState) !u8 {
    const exit_status = session.endedProcessExitCode();
    session.restoreAttachedClientEndPresentationForExit();
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
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
    exe: []const u8,
    target: SshTarget,
    bootstrap: bool,
    daemon_dir_name: ?[]const u8 = null,

    pub fn start(self: *DaemonStreamClientStarter) !DaemonStreamClientTransport {
        const fd = if (self.daemon_dir_name) |dir_name|
            try daemon_client.connectOrStartForDirName(self.allocator, self.exe, dir_name)
        else
            try daemon_client.connectOrStart(self.allocator, self.exe);
        errdefer _ = c.close(fd);

        var request = pb.ClientDaemonItem.SshTransportAcquire{
            .host = self.target.host,
            .bootstrap = self.bootstrap,
        };
        defer request.ssh_option.deinit(self.allocator);
        defer ssh_transport_acquire.deinitOwnedFields(self.allocator, &request);
        try request.ssh_option.appendSlice(self.allocator, self.target.options);
        try ssh_transport_acquire.appendCurrentSshAgent(self.allocator, &request);
        try ssh_transport_acquire.appendCurrentProcess(self.allocator, &request);

        try protocol.sendSshTransportAcquireFrame(self.allocator, fd, request);
        return .{ .fd = fd };
    }

    pub fn exitAfterInitialFailure(self: *DaemonStreamClientStarter, err: anyerror) !void {
        _ = self;
        return err;
    }
};

fn openProxyDiagnostics(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    daemon_dir_name: ?[]const u8,
) !c.fd_t {
    const fd = if (daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);
    try protocol.sendClientDaemonPayloadFrame(allocator, fd, .{ .proxy_diagnostics_open = .{
        .proxy_guid = guid,
    } });
    return fd;
}

// Proxy stream mode is for SSH features that OpenSSH must own directly, such
// as X11, agent forwarding, port forwarding, subsystems, and non-tty commands.
// The visible outer `ssh` process gets the user's original options plus a
// ProxyCommand. That ProxyCommand is a local sessh process that reconnects a
// byte-clean stream to sesshd, and the remote proxy process then opens a TCP
// connection to sshd on the remote machine.
fn runProxyStreamSsh(
    allocator: std.mem.Allocator,
    exe: []const u8,
    target: SshTarget,
    common: CommonSessionOptions,
    daemon_dir_name: ?[]const u8,
    new: RemoteNewSession,
) !noreturn {
    const remote_command_args: []const []const u8 = if (sessh_routing.hasRemoteShellCommand(new.shell_command_args))
        new.shell_command_args
    else
        &.{};
    const use_fd_pass = diagnostics_policy.isolationModeUsesDirectProxyPlacement(common.isolation_mode);
    const diagnostics_plan = if (use_fd_pass) diagnostics_policy.ProxyStreamPlan{
        .command_level = .unhygienic,
        .use_daemon_control = false,
        .wrap_visible_ssh = false,
        .client_ctrl_r = false,
    } else diagnostics_policy.proxyStreamPlan(
        target.options,
        common.filter_level,
        new.tty_request,
        remote_command_args,
        c.isatty(posix.STDIN_FILENO) != 0,
        c.isatty(posix.STDOUT_FILENO) != 0,
    );
    var diagnostics_guid: ?[]u8 = null;
    defer if (diagnostics_guid) |guid| allocator.free(guid);
    var client_control_fd: c.fd_t = -1;
    defer if (client_control_fd >= 0) posix.close(client_control_fd);
    if (diagnostics_plan.use_daemon_control) {
        diagnostics_guid = try guid_ref.generateProxyGuid(allocator);
        client_control_fd = try openProxyDiagnostics(
            allocator,
            exe,
            diagnostics_guid.?,
            daemon_dir_name,
        );
    }
    const auto_diagnostics_file = try diagnostics_policy.autoProxyDiagnosticsFile(
        allocator,
        common.diagnostics_file,
        diagnostics_plan.use_daemon_control,
        diagnostics_plan.wrap_visible_ssh,
        posix.STDIN_FILENO,
        posix.STDERR_FILENO,
    );
    defer if (auto_diagnostics_file) |path| allocator.free(path);
    const diagnostics_file_path = common.diagnostics_file orelse auto_diagnostics_file;
    const proxy_client_ctrl_r = diagnostics_plan.client_ctrl_r;
    const proxy_daemon_dir_name = daemon_dir_name orelse try daemon_socket_namespace.defaultDirName(allocator);
    defer if (daemon_dir_name == null) allocator.free(proxy_daemon_dir_name);
    try daemon_client.ensureStartedForDirName(allocator, exe, proxy_daemon_dir_name);
    var namespace_executables = try daemon_executable.namespaceExecutablePaths(allocator, proxy_daemon_dir_name);
    defer namespace_executables.deinit();

    const proxy_command_option = try proxy_command.commandOption(
        allocator,
        namespace_executables.proxy,
        target.options,
        diagnostics_guid,
        diagnostics_plan.command_level,
        common.diagnostics_level,
        proxy_client_ctrl_r,
        diagnostics_file_path,
        common.bootstrap,
        daemon_dir_name,
        use_fd_pass,
    );
    defer allocator.free(proxy_command_option);

    const default_options = defaultSshOptionsLen(target);
    const ssh_arg_count = 1 + @as(usize, if (use_fd_pass) 1 else 0) + default_options + target.options.len + 1 + remote_command_args.len;
    const ssh_args = try allocator.alloc([]const u8, ssh_arg_count);
    defer allocator.free(ssh_args);

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
    appendDefaultSshOptions(ssh_args, &index, target.default_ipqos_option);
    @memcpy(ssh_args[index .. index + target.options.len], target.options);
    index += target.options.len;
    ssh_args[index] = target.host;
    index += 1;
    @memcpy(ssh_args[index..], remote_command_args);

    if (diagnostics_plan.wrap_visible_ssh and client_control_fd >= 0) {
        const fd = client_control_fd;
        client_control_fd = -1;
        try plain_ssh.runArgvUnderLocalPty(allocator, ssh_args, fd, diagnostics_plan.client_ctrl_r, "proxy-stream");
    }
    if (diagnostics_plan.use_daemon_control and client_control_fd >= 0) {
        const fd = client_control_fd;
        client_control_fd = -1;
        try plain_ssh.runArgvWithDiagnostics(allocator, ssh_args, fd, "proxy-stream");
    }
    try plain_ssh.runArgv(allocator, ssh_args, "proxy-stream");
}

pub fn runProxyStream(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var invocation = proxy_entry.parse(allocator, args) catch |err| {
        try proxy_entry.printArgError(err);
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
        try runProxyStreamFdPass(
            allocator,
            exe,
            invocation,
            stream_target,
            proxy_guid,
            proxy_port,
        );
        return process_exit.request(0);
    }
    var starter = DaemonStreamClientStarter{
        .allocator = allocator,
        .exe = exe,
        .target = stream_target,
        .bootstrap = invocation.bootstrap,
        .daemon_dir_name = invocation.daemon_dir_name,
    };

    var diagnostics_handle = diagnostics_file.Handle.open(invocation.diagnostics_file) catch |err| {
        try io.stderrPrint(
            "sessh: proxy mode cannot open diagnostics file {s}: {t}\n",
            .{ invocation.diagnostics_file orelse "", err },
        );
        return process_exit.request(1);
    };
    defer diagnostics_handle.deinit();
    const diagnostics_output_is_tty = if (diagnostics_handle.output_fd >= 0)
        c.isatty(diagnostics_handle.output_fd) != 0
    else
        c.isatty(posix.STDERR_FILENO) != 0;
    const status_mode = diagnostics_policy.streamStatusMode(
        invocation.filter_level,
        invocation.diagnostics_level,
        invocation.diagnostics_guid != null and invocation.diagnostics_file == null,
        diagnostics_output_is_tty,
    );

    const exit_status = proxy_worker.runLocalStream(allocator, &starter, .{
        .guid = proxy_guid,
        .proxy_host = "localhost",
        .proxy_port = proxy_port,
        .source_fd = 0,
        .sink_fd = 1,
        .reconnect_input_fd = diagnostics_handle.input_fd,
        .status_mode = status_mode,
        .status_fd = if (status_mode == .line or status_mode == .status_line or status_mode == .jsonl or status_mode == .title)
            if (diagnostics_handle.output_fd >= 0) diagnostics_handle.output_fd else posix.STDERR_FILENO
        else
            -1,
        .intercept_ctrl_r = false,
        .ctrl_r_status_enabled = (invocation.client_ctrl_r and invocation.diagnostics_guid != null) or diagnostics_handle.input_fd >= 0,
        .title_fallback = invocation.host,
        .reset_on_source_eof = true,
    }) catch |err| {
        try starter.exitAfterInitialFailure(err);
        return;
    };
    return process_exit.request(exit_status);
}

fn runProxyStreamFdPass(
    allocator: std.mem.Allocator,
    exe: []const u8,
    invocation: proxy_entry.Invocation,
    stream_target: SshTarget,
    proxy_guid: []const u8,
    proxy_port: u16,
) !void {
    const daemon_fd = if (invocation.daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(allocator, exe);
    defer _ = c.close(daemon_fd);

    var transport = pb.ClientDaemonItem.SshTransportAcquire{
        .host = stream_target.host,
        .bootstrap = invocation.bootstrap,
    };
    defer transport.ssh_option.deinit(allocator);
    defer ssh_transport_acquire.deinitOwnedFields(allocator, &transport);
    try transport.ssh_option.appendSlice(allocator, stream_target.options);
    try ssh_transport_acquire.appendCurrentSshAgent(allocator, &transport);
    try ssh_transport_acquire.appendParentProcess(allocator, &transport);

    try proxy_entry.runFdPassSetup(allocator, daemon_fd, transport, proxy_guid, proxy_port);
}

fn runPlainSshFallbackAfterVersionMismatch(allocator: std.mem.Allocator, target: SshTarget) !noreturn {
    try user_error.line("existing remote sessh is incompatible; falling back to plain ssh without persistence");
    try runPlainSshFallbackArgv(allocator, target);
}

fn runPlainSshFallback(allocator: std.mem.Allocator, target: SshTarget, platform: ?Platform) !noreturn {
    if (platform) |remote_platform| {
        try user_error.printLine(
            "no matching sessh binary for remote platform {s} {s}; falling back to plain ssh without persistence",
            .{ remote_platform.os, remote_platform.arch },
        );
    } else {
        try user_error.line("remote platform is unsupported and no matching sessh binary is available; falling back to plain ssh without persistence");
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

pub fn printSshArgError(err: anyerror) !void {
    switch (err) {
        error.MissingHost => try user_error.line("missing host"),
        error.MissingScrollbackRowCount => try user_error.line("--scrollback-limit requires a value"),
        error.MissingClientLogLevel => try user_error.line("--log-level requires a value"),
        error.MissingFilterLevel => try user_error.line("--filter-level requires one of: unhygienic, hygienic, emulated"),
        error.MissingDiagnosticsLevel => try user_error.line("--diagnostics-level requires one of: overlay, status, title, line, jsonl"),
        error.MissingIsolationMode => try user_error.line("--isolation-mode requires one of: full, process, none"),
        error.MissingDiagnosticsFile => try user_error.line("--diagnostics-file requires a file path"),
        error.MissingTtyTranscriptPath => try user_error.line("--capture-tty-transcript requires a path"),
        error.MissingSshOptionValue => try user_error.line("ssh option is missing its value"),
        error.SesshOptionAfterHost => try user_error.line("sessh options must appear before HOST"),
        error.ConflictingSesshAction => try user_error.line("conflicting sessh actions"),
        error.InvalidScrollbackRowCount => try user_error.line("invalid scrollback row count"),
        error.InvalidClientLogLevel => try user_error.line("invalid log level"),
        error.InvalidFilterLevel => try user_error.line("invalid filter level; expected one of: unhygienic, hygienic, emulated"),
        error.InvalidDiagnosticsLevel => try user_error.line("invalid diagnostics level; expected one of: overlay, status, title, line, jsonl"),
        error.InvalidIsolationMode => try user_error.line("invalid isolation mode; expected one of: full, process, none"),
        error.InvalidBool => try user_error.line("expected true or false"),
        error.RemoteCommandUnsupported => try user_error.line("remote commands require -t or -tt for persistent sessions"),
        error.UnsafeSshOption => try user_error.line("ssh option is not safe for sessh transport"),
        error.UnsupportedSesshOption => try user_error.line("unsupported sessh option for ssh transport"),
        error.UnsupportedSesshCliOption => try user_error.line("unsupported sessh option"),
        error.UnsupportedSshOption => try user_error.line("unsupported ssh option for sessh transport"),
        else => try user_error.printLine("invalid ssh arguments: {t}", .{err}),
    }
}
