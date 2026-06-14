const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const attached_client = @import("../session/attached_client.zig");
const transport_bootstrap = @import("bootstrap.zig");
const client_config = @import("../session/client_config.zig");
const client_log = @import("../core/client_log.zig");
const client_ui = @import("../session/client_ui.zig");
const sessh_cli = @import("../sessh/cli.zig");
const config = @import("../core/config.zig");
const daemon_client = @import("../daemon/client.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_executable = @import("../daemon/executable.zig");
const daemon_log = @import("../daemon/log.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const dispatcher = @import("../core/dispatcher.zig");
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
    pending_tunnel,
    opening_stream,
    active,
    done,
};

const PooledTerminalClientKind = enum {
    unknown,
    te,
    proxy,
};

const RemoteCleanupIdentity = struct {
    pid: u64,
    start_time: []u8,
    daemon_socket_path: []u8,
    guid: []u8,

    fn fromProto(allocator: std.mem.Allocator, process: pb.DaemonTunnelItem.RemoteProcessIdentity) !RemoteCleanupIdentity {
        return .{
            .pid = process.pid,
            .start_time = try allocator.dupe(u8, process.start_time),
            .daemon_socket_path = try allocator.dupe(u8, process.daemon_socket_path),
            .guid = try allocator.dupe(u8, process.guid),
        };
    }

    fn deinit(self: *RemoteCleanupIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.start_time);
        allocator.free(self.daemon_socket_path);
        allocator.free(self.guid);
        self.* = undefined;
    }

    fn toProto(self: RemoteCleanupIdentity) pb.DaemonTunnelItem.RemoteProcessIdentity {
        return .{
            .pid = self.pid,
            .start_time = self.start_time,
            .daemon_socket_path = self.daemon_socket_path,
            .guid = self.guid,
        };
    }
};

const PooledTerminalClient = struct {
    fd: c.fd_t,
    tunnel: *TerminalTunnel = undefined,
    watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    stream_id: u64 = 0,
    local_stream_id: u64 = 0,
    kind: PooledTerminalClientKind = .unknown,
    state: PooledTerminalClientState = .pending_tunnel,
    outbound_next_offset: u64 = 0,
    inbound_next_offset: u64 = 0,
    request_started_ms: u64 = 0,
    mux_open_sent_ms: u64 = 0,
    mux_open_ok_ms: u64 = 0,
    first_payload_ms: u64 = 0,
    startup_timing_logged: bool = false,
    session_ended: bool = false,
    done: bool = false,
    local_pid: u64 = 0,
    local_start_time: ?[]u8 = null,
    remote_cleanup: ?RemoteCleanupIdentity = null,
    proxy_guid: [session_registry.proxy_guid_len]u8 = [_]u8{0} ** session_registry.proxy_guid_len,
    proxy_guid_len: usize = 0,

    fn initReader(self: *PooledTerminalClient, allocator: std.mem.Allocator) void {
        self.reader = protocol.FrameReader.init(allocator);
    }

    fn deinit(self: *PooledTerminalClient, allocator: std.mem.Allocator) void {
        self.reader.deinit();
        if (self.local_start_time) |start_time| allocator.free(start_time);
        if (self.remote_cleanup) |*remote| remote.deinit(allocator);
        self.* = undefined;
    }

    fn proxyGuidSlice(self: *const PooledTerminalClient) []const u8 {
        return self.proxy_guid[0..self.proxy_guid_len];
    }

    fn setProxyGuid(self: *PooledTerminalClient, guid: []const u8) !void {
        if (guid.len > self.proxy_guid.len) return error.ProxyGuidTooLarge;
        @memcpy(self.proxy_guid[0..guid.len], guid);
        self.proxy_guid_len = guid.len;
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
    remote_reader: protocol.FrameReader = undefined,
    remote_watch_id: ?dispatcher.FdWatchId = null,
    diagnostic_watch_id: ?dispatcher.FdWatchId = null,
    idle_timer_id: ?dispatcher.TimerWatchId = null,
    connection: ?RuntimeConnection = null,
    diagnostic_fd: c.fd_t = -1,
    diagnostic_write_fd: c.fd_t = -1,
    remote_daemon_namespace: ?[]u8 = null,
    next_stream_id: u64 = 1,

    fn deinit(self: *TerminalTunnel) void {
        if (self.connection) |*connection| connection.terminate();
        self.remote_reader.deinit();
        if (self.remote_daemon_namespace) |namespace| self.allocator.free(namespace);
        if (self.diagnostic_fd >= 0) posix.close(self.diagnostic_fd);
        if (self.diagnostic_write_fd >= 0) posix.close(self.diagnostic_write_fd);
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

var terminal_tunnels: std.ArrayList(*TerminalTunnel) = .empty;
var active_terminal_tunnels: std.atomic.Value(usize) = .init(0);

const ProxyControlRegistration = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    visible_fd: c.fd_t = -1,
    stream_fd: c.fd_t = -1,

    fn deinit(self: *ProxyControlRegistration) void {
        self.allocator.free(self.guid);
        self.* = undefined;
    }
};

var proxy_control_mutex = std.Thread.Mutex{};
var proxy_control_registrations: std.ArrayList(*ProxyControlRegistration) = .empty;

pub fn activeTerminalTunnelCount() usize {
    return active_terminal_tunnels.load(.acquire);
}

pub fn serveProxyControlOpen(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    open: pb.ClientDaemonItem.ProxyControlOpen,
) !void {
    const guid = try session_registry.canonicalProxyGuid(allocator, open.proxy_guid);
    defer allocator.free(guid);

    try registerProxyControlVisible(allocator, guid, fd);
    defer unregisterProxyControlVisible(fd);

    while (true) {
        var frame = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit(allocator);
        if (!try proxyControlVisibleFrameIsAllowed(allocator, frame)) return error.UnexpectedProxyControlFrame;
        try forwardProxyControlToStream(guid, frame);
    }
}

fn registerProxyControlVisible(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    const registration = try findOrCreateProxyControlRegistrationLocked(allocator, guid);
    if (registration.visible_fd >= 0 and registration.visible_fd != fd) return error.ProxyControlAlreadyOpen;
    registration.visible_fd = fd;
}

fn registerProxyControlStream(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    const registration = try findOrCreateProxyControlRegistrationLocked(allocator, guid);
    registration.stream_fd = fd;
}

fn unregisterProxyControlVisible(fd: c.fd_t) void {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    for (proxy_control_registrations.items) |registration| {
        if (registration.visible_fd == fd) registration.visible_fd = -1;
    }
    removeUnusedProxyControlRegistrationsLocked();
}

fn unregisterProxyControlStream(fd: c.fd_t) void {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    for (proxy_control_registrations.items) |registration| {
        if (registration.stream_fd == fd) registration.stream_fd = -1;
    }
    removeUnusedProxyControlRegistrationsLocked();
}

fn findOrCreateProxyControlRegistrationLocked(allocator: std.mem.Allocator, guid: []const u8) !*ProxyControlRegistration {
    for (proxy_control_registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid)) return registration;
    }
    const registration = try allocator.create(ProxyControlRegistration);
    errdefer allocator.destroy(registration);
    registration.* = .{
        .allocator = allocator,
        .guid = try allocator.dupe(u8, guid),
    };
    errdefer registration.deinit();
    try proxy_control_registrations.append(allocator, registration);
    return registration;
}

fn removeUnusedProxyControlRegistrationsLocked() void {
    var index: usize = 0;
    while (index < proxy_control_registrations.items.len) {
        const registration = proxy_control_registrations.items[index];
        if (registration.visible_fd >= 0 or registration.stream_fd >= 0) {
            index += 1;
            continue;
        }
        _ = proxy_control_registrations.swapRemove(index);
        const allocator = registration.allocator;
        registration.deinit();
        allocator.destroy(registration);
    }
}

fn proxyControlVisibleFrameIsAllowed(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !bool {
    if (frame.message_type != .client_daemon) return false;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    return switch (item.payload orelse return false) {
        .retry_now => true,
        else => false,
    };
}

fn forwardProxyControlToStream(guid: []const u8, frame: protocol.OwnedFrame) !void {
    const stream_fd = proxyControlStreamFd(guid) orelse return;
    protocol.sendFrame(stream_fd, frame.message_type, frame.payload) catch |err| {
        unregisterProxyControlStream(stream_fd);
        return err;
    };
}

fn forwardProxyControlFromStream(allocator: std.mem.Allocator, guid: []const u8, frame: protocol.OwnedFrame) !void {
    if (!try proxyControlStreamFrameIsAllowed(allocator, frame)) return error.UnexpectedProxyControlFrame;
    const visible_fd = proxyControlVisibleFd(guid) orelse return;
    protocol.sendFrame(visible_fd, frame.message_type, frame.payload) catch |err| {
        unregisterProxyControlVisible(visible_fd);
        return err;
    };
}

fn proxyControlStreamFrameIsAllowed(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !bool {
    if (frame.message_type != .client_daemon) return false;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    return switch (item.payload orelse return false) {
        .connection_event => true,
        else => false,
    };
}

fn proxyControlVisibleFd(guid: []const u8) ?c.fd_t {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    for (proxy_control_registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.visible_fd >= 0) return registration.visible_fd;
    }
    return null;
}

fn proxyControlStreamFd(guid: []const u8) ?c.fd_t {
    proxy_control_mutex.lock();
    defer proxy_control_mutex.unlock();
    for (proxy_control_registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.stream_fd >= 0) return registration.stream_fd;
    }
    return null;
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

    const target = SshTarget{ .options = ssh_options, .host = host };
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0;
    const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    if (shouldUseProxyStream(new, runtime_config.common, stdin_is_tty, stdout_is_tty)) {
        if (runtime_config.common.capture_tty_transcript != null) {
            try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with proxy stream mode\n");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, exe, target, runtime_config.common, new);
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
        if (err == error.UnsupportedRemotePlatform and failure_policy.allow_plain_ssh_fallback) {
            transport.close();
            try runPlainSshFallback(allocator, target, null);
        }
        waitAfterRuntimeAttachFailure(&transport, "start");
        if (process_exit.is(err)) return err;
        try io.stderrPrint("sessh: ssh runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    session.setTitleFallback(target.host);
    try runAttachedRemoteClient(
        allocator,
        exe,
        target,
        runtime_config,
        &transport,
        &session,
    );
}

pub fn registerTerminalTransportFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    var resolved_target = try resolveSshTarget(allocator, request.ssh_option.items, request.host);
    defer resolved_target.deinit(allocator);
    var acquire_request = request;
    if (acquire_request.ip_qos.len == 0) {
        if (resolved_target.config.ipqos) |ip_qos| acquire_request.ip_qos = ip_qos;
    }
    const target = resolved_target.target;
    daemon_log.infof(
        allocator,
        "terminal transport opening host={s} resolved={s}@{s}:{s} bootstrap={}",
        .{ target.host, target.resolved_user, target.resolved_host, target.resolved_port, acquire_request.bootstrap },
    );

    try registerPooledTerminalTransportFromDaemon(allocator, daemon_dispatcher, client_fd, target, acquire_request);
}

fn startTerminalTransportForDaemon(
    allocator: std.mem.Allocator,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
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

    var ssh_launch_environment = try envMapFromSshTransportAcquire(allocator, request);
    defer ssh_launch_environment.deinit();

    var bootstrap_failure_term: ?std.process.Child.Term = null;
    const child = startRuntimeConnection(
        allocator,
        target,
        artifacts,
        remote_command,
        .broker,
        broker_args,
        null,
        false,
        .pipe,
        diagnostic_pipe[1],
        client_fd,
        &ssh_launch_environment,
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

fn registerPooledTerminalTransportFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    const client = try allocator.create(PooledTerminalClient);
    errdefer allocator.destroy(client);
    client.* = .{
        .fd = client_fd,
        .request_started_ms = nowUnixMs(),
        .local_pid = request.local_pid,
        .local_start_time = if (request.local_start_time.len == 0) null else try allocator.dupe(u8, request.local_start_time),
    };
    client.initReader(allocator);
    errdefer client.deinit(allocator);

    const acquire = try acquireTerminalTunnel(allocator, target, request, client);
    client.tunnel = acquire.tunnel;
    if (acquire.created) {
        startNewTerminalTunnel(allocator, daemon_dispatcher, acquire.tunnel, client_fd, target, request) catch |err| {
            failStartingTerminalTunnel(allocator, acquire.tunnel, client, err);
        };
    } else if (acquire.tunnel.state == .ready) {
        activatePendingTerminalClients(daemon_dispatcher, acquire.tunnel);
    }
}

fn acquireTerminalTunnel(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    client: *PooledTerminalClient,
) !TerminalTunnelAcquire {
    const key = try terminalTunnelKey(allocator, target, request);
    errdefer allocator.free(key);

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
        return .{ .tunnel = tunnel, .created = false };
    }

    const tunnel = try allocator.create(TerminalTunnel);
    errdefer allocator.destroy(tunnel);
    tunnel.* = .{
        .allocator = allocator,
        .key = key,
        .display_host = try allocator.dupe(u8, target.host),
        .resolved_user = try allocator.dupe(u8, target.resolved_user),
        .resolved_host = try allocator.dupe(u8, target.resolved_host),
        .resolved_port = try allocator.dupe(u8, target.resolved_port),
    };
    tunnel.remote_reader = protocol.FrameReader.init(allocator);
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

fn terminalTunnelKey(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) ![]u8 {
    var key = std.ArrayList(u8).empty;
    errdefer key.deinit(allocator);
    try appendPoolKeyPart(allocator, &key, target.resolved_user);
    try appendPoolKeyPart(allocator, &key, target.resolved_host);
    try appendPoolKeyPart(allocator, &key, target.resolved_port);
    try key.writer(allocator).print("bootstrap={}|", .{request.bootstrap});
    try key.appendSlice(allocator, "ipqos=");
    try appendPoolKeyPart(allocator, &key, request.ip_qos);
    return key.toOwnedSlice(allocator);
}

fn appendPoolKeyPart(allocator: std.mem.Allocator, key: *std.ArrayList(u8), value: []const u8) !void {
    try key.writer(allocator).print("{}:", .{value.len});
    try key.appendSlice(allocator, value);
    try key.append(allocator, '|');
}

fn startNewTerminalTunnel(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
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
    const remote_read_fd = started.connection.child.stdout.?.handle;
    try setNonBlockingFd(remote_read_fd);

    tunnel.connection = started.connection;
    tunnel.diagnostic_fd = started.diagnostic_fd;
    tunnel.diagnostic_write_fd = started.diagnostic_write_fd;
    tunnel.remote_daemon_namespace = started.remote_daemon_namespace;
    started.remote_daemon_namespace = null;
    tunnel.state = .ready;
    errdefer {
        if (tunnel.remote_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            tunnel.remote_watch_id = null;
        }
        if (tunnel.diagnostic_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            tunnel.diagnostic_watch_id = null;
        }
    }
    tunnel.remote_watch_id = try daemon_dispatcher.watchFd(remote_read_fd, .{ .readable = true }, .{
        .ctx = tunnel,
        .callback = readTerminalTunnelRemote,
    });
    tunnel.diagnostic_watch_id = try daemon_dispatcher.watchFd(tunnel.diagnostic_fd, .{ .readable = true }, .{
        .ctx = tunnel,
        .callback = readTerminalTunnelDiagnostics,
    });

    daemon_log.infof(
        allocator,
        "terminal transport ready host={s} remote_namespace={s}",
        .{ target.host, tunnel.remote_daemon_namespace orelse "remote-default" },
    );
    activatePendingTerminalClients(daemon_dispatcher, tunnel);
}

fn failStartingTerminalTunnel(
    allocator: std.mem.Allocator,
    tunnel: *TerminalTunnel,
    starter: *PooledTerminalClient,
    err: anyerror,
) void {
    tunnel.state = .closed;
    removeTerminalTunnelLocked(tunnel);
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        if (client != starter or err != error.TerminalTransportStartReported) {
            sendDaemonTransportError(client.fd, "SSH_TRANSPORT_FAILED", "ssh transport failed", "") catch {};
        }
        destroyPooledTerminalClient(null, tunnel, client);
    }
    _ = active_terminal_tunnels.fetchSub(1, .acq_rel);
    tunnel.deinit();
    allocator.destroy(tunnel);
}

pub fn sendCleanupRequestToRemote(
    allocator: std.mem.Allocator,
    record: daemon_cleanup.Record,
) !daemon_cleanup.CleanupResult {
    var options = [_][]const u8{ "-l", record.remote_user, "-p", record.remote_port };
    const target = SshTarget{
        .options = &options,
        .host = record.remote_host,
        .resolved_user = record.remote_user,
        .resolved_host = record.remote_host,
        .resolved_port = record.remote_port,
    };
    var dummy: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &dummy) != 0) return error.SocketPairFailed;
    defer {
        posix.close(dummy[0]);
        posix.close(dummy[1]);
    }

    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = record.remote_host,
        .bootstrap = true,
    };
    defer deinitSshTransportAcquireOwnedFields(allocator, &request);
    try appendCurrentSshAgentToSshTransportAcquire(allocator, &request);

    var started = try startTerminalTransportForDaemon(allocator, dummy[1], target, request);
    defer {
        started.connection.terminate();
        if (started.diagnostic_fd >= 0) posix.close(started.diagnostic_fd);
        if (started.diagnostic_write_fd >= 0) posix.close(started.diagnostic_write_fd);
        started.deinitNamespace(allocator);
    }

    const read_fd = started.connection.child.stdout.?.handle;
    const write_fd = started.connection.child.stdin.?.handle;
    try initiatePooledRemoteDaemonHandshake(allocator, read_fd, write_fd);
    try daemon_cleanup.sendRemoteProcessCleanupRequest(allocator, write_fd, .{
        .pid = record.remote_pid,
        .start_time = record.remote_start_time,
        .daemon_socket_path = record.remote_socket_path,
        .guid = record.guid,
    });
    return readCleanupResponseForGuid(allocator, read_fd, record.guid);
}

fn readCleanupResponseForGuid(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    guid: []const u8,
) !daemon_cleanup.CleanupResult {
    while (true) {
        var frame = try protocol.readFrameAlloc(allocator, fd);
        defer frame.deinit(allocator);
        if (frame.message_type != .daemon_tunnel) return error.UnexpectedDaemonFrame;
        var item = try protocol.decodePayload(pb.DaemonTunnelItem, allocator, frame.payload);
        defer item.deinit(allocator);
        const payload = item.payload orelse return error.UnexpectedDaemonFrame;
        switch (payload) {
            .remote_process_cleanup_response => |response| {
                const process = response.process orelse return error.UnexpectedDaemonFrame;
                if (!std.mem.eql(u8, process.guid, guid)) return error.UnexpectedDaemonFrame;
                const result = response.result orelse return error.UnexpectedDaemonFrame;
                return switch (result) {
                    .cleaned => .cleaned,
                    .missing => .missing,
                };
            },
            .ping, .pong => continue,
            else => return error.UnexpectedDaemonFrame,
        }
    }
}

fn readTerminalTunnelRemote(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const tunnel: *TerminalTunnel = @ptrCast(@alignCast(ctx));
    readTerminalTunnelRemoteInner(tunnel, daemon_dispatcher, event) catch |err| {
        daemon_log.infof(
            tunnel.allocator,
            "terminal pooled ssh transport failed host={s} pool={s} error={t}",
            .{ tunnel.display_host, tunnel.key, err },
        );
        notifyPooledTerminalRemoteClosed(daemon_dispatcher, tunnel);
        finishTerminalTunnel(daemon_dispatcher, tunnel);
    };
}

fn readTerminalTunnelRemoteInner(
    tunnel: *TerminalTunnel,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedTerminalTunnelTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        notifyPooledTerminalRemoteClosed(daemon_dispatcher, tunnel);
        finishTerminalTunnel(daemon_dispatcher, tunnel);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) {
            notifyPooledTerminalRemoteClosed(daemon_dispatcher, tunnel);
            finishTerminalTunnel(daemon_dispatcher, tunnel);
        }
        return;
    }

    const remote_read_fd = tunnel.connection.?.child.stdout.?.handle;
    while (true) {
        switch (try tunnel.remote_reader.readReady(remote_read_fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                notifyPooledTerminalRemoteClosed(daemon_dispatcher, tunnel);
                finishTerminalTunnel(daemon_dispatcher, tunnel);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(tunnel.allocator);
                if (!try handlePooledRemoteFrame(daemon_dispatcher, tunnel, frame)) {
                    notifyPooledTerminalRemoteClosed(daemon_dispatcher, tunnel);
                    finishTerminalTunnel(daemon_dispatcher, tunnel);
                    return;
                }
            },
        }
    }
}

fn readTerminalTunnelDiagnostics(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const tunnel: *TerminalTunnel = @ptrCast(@alignCast(ctx));
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedTerminalTunnelTimer,
    };
    if (!fd_event.readable and !fd_event.hangup and !fd_event.error_event and !fd_event.invalid) return;
    forwardPooledTerminalDiagnostics(tunnel) catch |err| {
        daemon_log.infof(
            tunnel.allocator,
            "terminal pooled ssh diagnostics failed host={s} pool={s} error={t}",
            .{ tunnel.display_host, tunnel.key, err },
        );
        if (tunnel.diagnostic_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            tunnel.diagnostic_watch_id = null;
        }
    };
    if (fd_event.hangup or fd_event.error_event or fd_event.invalid) {
        if (tunnel.diagnostic_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            tunnel.diagnostic_watch_id = null;
        }
    }
}

fn readPooledTerminalClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const client: *PooledTerminalClient = @ptrCast(@alignCast(ctx));
    const tunnel = client.tunnel;
    readPooledTerminalClientInner(client, daemon_dispatcher, event) catch |err| {
        daemon_log.infof(
            tunnel.allocator,
            "terminal pooled client failed host={s} pool={s} stream_id={} error={t}",
            .{ tunnel.display_host, tunnel.key, client.stream_id, err },
        );
        finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
    };
}

fn readPooledTerminalClientInner(
    client: *PooledTerminalClient,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const tunnel = client.tunnel;
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedTerminalTunnelTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
        return;
    }

    while (true) {
        switch (try client.reader.readReady(client.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                const alive = try handlePooledTerminalClientFrame(daemon_dispatcher, tunnel, client, &frame);
                frame.deinit(tunnel.allocator);
                if (!alive) return;
            },
        }
    }
}

fn closeIdleTerminalTunnel(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const tunnel: *TerminalTunnel = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedTerminalTunnelFd,
    }
    tunnel.idle_timer_id = null;
    if (tunnel.clients.items.len != 0 or tunnel.state == .closed) return;
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled ssh transport idle host={s} pool={s}",
        .{ tunnel.display_host, tunnel.key },
    );
    finishTerminalTunnel(daemon_dispatcher, tunnel);
}

fn activatePendingTerminalClients(daemon_dispatcher: *dispatcher.Dispatcher, tunnel: *TerminalTunnel) void {
    if (tunnel.idle_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        tunnel.idle_timer_id = null;
    }
    var index: usize = 0;
    while (index < tunnel.clients.items.len) {
        const client = tunnel.clients.items[index];
        if (client.state != .pending_tunnel) {
            index += 1;
            continue;
        }
        client.stream_id = tunnel.next_stream_id;
        tunnel.next_stream_id += 1;
        client.state = .opening_stream;
        client.watch_id = daemon_dispatcher.watchFd(client.fd, .{ .readable = true }, .{
            .ctx = client,
            .callback = readPooledTerminalClient,
        }) catch {
            sendDaemonTransportError(client.fd, "INTERNAL_ERROR", "failed to watch terminal transport client", "") catch {};
            destroyPooledTerminalClient(daemon_dispatcher, tunnel, client);
            continue;
        };
        index += 1;
    }
}

fn scheduleTerminalTunnelIdleClose(daemon_dispatcher: *dispatcher.Dispatcher, tunnel: *TerminalTunnel) void {
    if (tunnel.state == .closed or tunnel.clients.items.len != 0 or tunnel.idle_timer_id != null) return;
    tunnel.idle_timer_id = daemon_dispatcher.watchTimerAfter(@intCast(terminal_tunnel_idle_close_ms), .{
        .ctx = tunnel,
        .callback = closeIdleTerminalTunnel,
    }) catch {
        finishTerminalTunnel(daemon_dispatcher, tunnel);
        return;
    };
}

fn handlePooledTerminalClientFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    return switch (client.state) {
        .opening_stream => try openPooledTerminalClientStream(daemon_dispatcher, tunnel, client, frame),
        .active => try forwardPooledTerminalClientFrame(daemon_dispatcher, tunnel, client, frame),
        .pending_tunnel => true,
        .done => false,
    };
}

fn openPooledTerminalClientStream(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (frame.message_type == .daemon_tunnel) {
        try sendPooledProxyMuxOpen(tunnel, client, frame.payload);
        client.state = .active;
        return true;
    }
    if (frame.message_type != .client_remote) {
        try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "expected terminal or proxy stream open", "");
        finishPooledTerminalClient(daemon_dispatcher, tunnel, client, false);
        return false;
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(tunnel.allocator, frame.payload);
    defer item.deinit(tunnel.allocator);
    const item_payload = item.payload orelse {
        try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "expected terminal stream open", "");
        finishPooledTerminalClient(daemon_dispatcher, tunnel, client, false);
        return false;
    };
    const open = switch (item_payload) {
        .open => |request| request,
        else => {
            try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "expected terminal stream open", "");
            finishPooledTerminalClient(daemon_dispatcher, tunnel, client, false);
            return false;
        },
    };
    try sendPooledTeMuxOpen(tunnel, client, open);
    client.kind = .te;
    client.state = .active;
    return true;
}

fn forwardPooledTerminalClientFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .daemon_tunnel => {
            if (client.kind != .proxy) {
                try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected proxy stream frame", "");
                finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
                return false;
            }
            try sendPooledProxyMuxFrame(tunnel, client, frame.payload);
        },
        .client_remote => {
            if (client.kind != .te) {
                try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected terminal stream frame", "");
                finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
                return false;
            }
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(tunnel.allocator, frame.payload);
            defer item.deinit(tunnel.allocator);
            try sendPooledTeMuxPayload(tunnel, client, item);
        },
        .client_daemon => {
            if (client.kind != .proxy or client.proxy_guid_len == 0) {
                try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected proxy control frame", "");
                finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
                return false;
            }
            try forwardProxyControlFromStream(tunnel.allocator, client.proxyGuidSlice(), frame.*);
        },
        else => {
            try sendDaemonTransportError(client.fd, "PROTOCOL_ERROR", "unexpected terminal client frame", "");
            finishPooledTerminalClient(daemon_dispatcher, tunnel, client, true);
            return false;
        },
    }
    return true;
}

fn sendPooledTeMuxOpen(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    request: pb.TerminalEmulatorItem.Open,
) !void {
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .open = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = 0,
        } },
    });
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .terminal_emulator = .{ .payload = .{ .open = request } } },
        } },
    });
    client.outbound_next_offset +|= 1;
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledProxyMuxOpen(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    payload: []const u8,
) !void {
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(tunnel.allocator, payload);
    defer mux_frame.deinit(tunnel.allocator);
    const message = mux_frame.message orelse return error.UnexpectedDaemonFrame;
    const open = switch (message) {
        .open => |open| open,
        else => return error.UnexpectedDaemonFrame,
    };
    _ = open;
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
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(tunnel.allocator, payload);
    defer mux_frame.deinit(tunnel.allocator);
    if (mux_frame.stream_id != client.local_stream_id) return error.UnexpectedDaemonFrame;
    try maybeRegisterProxyControlStream(tunnel.allocator, client, mux_frame);
    mux_frame.stream_id = client.stream_id;
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, mux_frame);
}

fn maybeRegisterProxyControlStream(
    allocator: std.mem.Allocator,
    client: *PooledTerminalClient,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    if (client.proxy_guid_len != 0) return;
    const message = mux_frame.message orelse return;
    const payload = switch (message) {
        .payload => |payload| payload,
        else => return,
    };
    const item = payload.item orelse return;
    const proxy = switch (item) {
        .proxy => |proxy_item| proxy_item,
        else => return,
    };
    const proxy_payload = proxy.payload orelse return;
    const open = switch (proxy_payload) {
        .open => |open| open,
        else => return,
    };
    const canonical = try session_registry.canonicalProxyGuid(allocator, open.proxy_guid);
    defer allocator.free(canonical);
    try client.setProxyGuid(canonical);
    try registerProxyControlStream(allocator, canonical, client.fd);
}

fn sendPooledTeMuxPayload(
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    item: pb.TerminalEmulatorItem,
) !void {
    try sendPooledMuxFrame(tunnel.allocator, tunnel.connection.?.child.stdin.?.handle, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .terminal_emulator = item },
        } },
    });
    client.outbound_next_offset +|= 1;
}

fn handlePooledRemoteFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    frame: protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return error.UnexpectedDaemonFrame;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, tunnel.allocator, frame.payload);
    defer item.deinit(tunnel.allocator);
    const payload = item.payload orelse return error.UnexpectedDaemonFrame;
    switch (payload) {
        .remote_process_started => |started| {
            try handlePooledRemoteProcessStarted(tunnel, started);
            return true;
        },
        .remote_process_cleanup_response => |response| {
            daemon_cleanup.handleRemoteProcessCleanupResponse(tunnel.allocator, response);
            return true;
        },
        .mux_stream => |mux| {
            item.payload = null;
            return handlePooledRemoteMuxStreamFrame(daemon_dispatcher, tunnel, mux);
        },
        .ping, .pong => return true,
        else => return error.UnexpectedDaemonFrame,
    }
}

fn handlePooledRemoteMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !bool {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(tunnel.allocator);
    const client = findPooledTerminalClient(tunnel, owned_mux_frame.stream_id) orelse return true;
    const message = owned_mux_frame.message orelse return error.UnexpectedDaemonFrame;
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
            .eof => {
                if (client.first_payload_ms == 0) client.first_payload_ms = nowUnixMs();
            },
            .open, .ack => {},
        }
        owned_mux_frame.stream_id = client.local_stream_id;
        try sendPooledMuxFrame(tunnel.allocator, client.fd, owned_mux_frame);
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
                .terminal_emulator => |terminal_emulator| terminal_emulator,
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
            finishPooledTerminalClient(daemon_dispatcher, tunnel, client, false);
        },
        .eof => {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledTerminalClientStartupTiming(tunnel, client);
            }
            finishPooledTerminalClient(daemon_dispatcher, tunnel, client, false);
        },
        .open => return error.UnexpectedDaemonFrame,
    }
    return true;
}

fn handlePooledRemoteProcessStarted(
    tunnel: *TerminalTunnel,
    started: pb.DaemonTunnelItem.RemoteProcessStarted,
) !void {
    const process = started.process orelse return error.UnexpectedDaemonFrame;
    const client = findPooledTerminalClient(tunnel, started.stream_id) orelse return;
    if (client.remote_cleanup) |*existing| existing.deinit(tunnel.allocator);
    client.remote_cleanup = try RemoteCleanupIdentity.fromProto(tunnel.allocator, process);
    if (client.local_pid == 0 or client.local_start_time == null) {
        daemon_log.infof(
            tunnel.allocator,
            "cleanup record skipped host={s} guid={s} reason=missing-local-process-identity",
            .{ tunnel.display_host, process.guid },
        );
        return;
    }
    daemon_cleanup.recordRemoteProcessStarted(tunnel.allocator, .{
        .pid = client.local_pid,
        .start_time = client.local_start_time.?,
    }, .{
        .user = tunnel.resolved_user,
        .host = tunnel.resolved_host,
        .port = tunnel.resolved_port,
    }, process) catch |err| {
        daemon_log.infof(
            tunnel.allocator,
            "cleanup record failed host={s} guid={s} error={t}",
            .{ tunnel.display_host, process.guid, err },
        );
        return;
    };
    try daemon_cleanup.sendRemoteProcessRecorded(
        tunnel.allocator,
        tunnel.connection.?.child.stdin.?.handle,
        started.stream_id,
    );
    daemon_log.infof(
        tunnel.allocator,
        "cleanup record stored host={s} guid={s}",
        .{ tunnel.display_host, process.guid },
    );
}

fn findPooledTerminalClient(tunnel: *TerminalTunnel, stream_id: u64) ?*PooledTerminalClient {
    for (tunnel.clients.items) |client| {
        if (client.stream_id == stream_id and client.state != .done) return client;
    }
    return null;
}

fn finishPooledTerminalClient(
    daemon_dispatcher: *dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
    send_hangup: bool,
) void {
    if (client.kind == .proxy) unregisterProxyControlStream(client.fd);
    if (send_hangup and client.state == .active) {
        if (!client.session_ended) {
            if (client.remote_cleanup) |remote| {
                daemon_log.infof(
                    tunnel.allocator,
                    "client disconnected; requesting remote cleanup host={s} guid={s}",
                    .{ tunnel.display_host, remote.guid },
                );
                daemon_cleanup.sendRemoteProcessCleanupRequest(
                    tunnel.allocator,
                    tunnel.connection.?.child.stdin.?.handle,
                    remote.toProto(),
                ) catch {};
            } else {
                daemon_log.infof(
                    tunnel.allocator,
                    "client disconnected before cleanup identity was recorded host={s}",
                    .{tunnel.display_host},
                );
            }
        }
    }
    destroyPooledTerminalClient(daemon_dispatcher, tunnel, client);
    scheduleTerminalTunnelIdleClose(daemon_dispatcher, tunnel);
}

fn notifyPooledTerminalRemoteClosed(daemon_dispatcher: *dispatcher.Dispatcher, tunnel: *TerminalTunnel) void {
    daemon_log.infof(tunnel.allocator, "ssh transport disconnected from daemon host={s}", .{tunnel.display_host});
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        sendSshTransportClosed(client.fd) catch {};
        destroyPooledTerminalClient(daemon_dispatcher, tunnel, client);
    }
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
        for (tunnel.clients.items) |client| {
            if (client.state == .done) continue;
            sendSshTransportDiagnostic(client.fd, bytes) catch {};
        }
        if (@as(usize, @intCast(n)) < buf.len) return;
    }
}

fn sendSshTransportDiagnostic(fd: c.fd_t, chunk: []const u8) !void {
    try protocol.sendSshTransportStderrFrame(app_allocator.allocator(), fd, chunk);
}

fn sendSshTransportClosed(fd: c.fd_t) !void {
    try protocol.sendSshTransportClosedFrame(app_allocator.allocator(), fd);
}

fn finishTerminalTunnel(daemon_dispatcher: *dispatcher.Dispatcher, tunnel: *TerminalTunnel) void {
    if (tunnel.state == .closed) return;
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled ssh transport closed host={s} pool={s}",
        .{ tunnel.display_host, tunnel.key },
    );
    tunnel.state = .closed;
    if (tunnel.remote_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        tunnel.remote_watch_id = null;
    }
    if (tunnel.diagnostic_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        tunnel.diagnostic_watch_id = null;
    }
    if (tunnel.idle_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        tunnel.idle_timer_id = null;
    }
    removeTerminalTunnelLocked(tunnel);
    while (tunnel.clients.items.len > 0) {
        const client = tunnel.clients.items[0];
        destroyPooledTerminalClient(daemon_dispatcher, tunnel, client);
    }
    _ = active_terminal_tunnels.fetchSub(1, .acq_rel);
    tunnel.deinit();
    tunnel.allocator.destroy(tunnel);
}

fn destroyPooledTerminalClient(
    daemon_dispatcher: ?*dispatcher.Dispatcher,
    tunnel: *TerminalTunnel,
    client: *PooledTerminalClient,
) void {
    if (client.done) return;
    logPooledTerminalClientStartupTiming(tunnel, client);
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled client finished host={s} pool={s} stream_id={}",
        .{ tunnel.display_host, tunnel.key, client.stream_id },
    );
    client.state = .done;
    client.done = true;
    if (client.watch_id) |watch_id| {
        // The dispatcher may already be dispatching this watch. Cancelling it is
        // still useful because it prevents future events for the same fd slot.
        // The current callback returns immediately after destroying the client.
        if (daemon_dispatcher) |d| d.cancel(.{ .fd = watch_id });
        client.watch_id = null;
    }
    var index: usize = 0;
    while (index < tunnel.clients.items.len) : (index += 1) {
        if (tunnel.clients.items[index] != client) continue;
        _ = tunnel.clients.swapRemove(index);
        break;
    }
    if (client.fd >= 0) {
        _ = c.close(client.fd);
        client.fd = -1;
    }
    client.deinit(tunnel.allocator);
    tunnel.allocator.destroy(client);
}

fn logPooledTerminalClientStartupTiming(tunnel: *TerminalTunnel, client: *PooledTerminalClient) void {
    if (client.startup_timing_logged) return;
    client.startup_timing_logged = true;
    daemon_log.infof(
        tunnel.allocator,
        "terminal pooled client startup host={s} pool={s} stream_id={} kind={s} request_to_open_ms={} open_to_open_ok_ms={} open_ok_to_first_payload_ms={} request_to_first_payload_ms={}",
        .{
            tunnel.display_host,
            tunnel.key,
            client.stream_id,
            pooledTerminalClientKindName(client.kind),
            elapsedMs(client.request_started_ms, client.mux_open_sent_ms),
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

fn sendPooledMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, message);
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
            .daemon_tunnel => {
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
            .daemon_tunnel => {
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
) !TerminalTransport {
    const fd = try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);

    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = target.host,
        .bootstrap = common.bootstrap,
    };
    defer request.ssh_option.deinit(allocator);
    defer deinitSshTransportAcquireOwnedFields(allocator, &request);
    try request.ssh_option.appendSlice(allocator, target.options);
    try appendCurrentSshAgentToSshTransportAcquire(allocator, &request);
    try appendCurrentProcessToSshTransportAcquire(allocator, &request);

    try protocol.sendSshTransportAcquireFrame(allocator, fd, request);
    return .{ .fd = fd };
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

fn appendCurrentSshAgentToSshTransportAcquire(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    request.ssh_auth_sock = std.process.getEnvVarOwned(allocator, "SSH_AUTH_SOCK") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn appendCurrentProcessToSshTransportAcquire(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    const local = try daemon_cleanup.currentLocalProcessIdentity(allocator);
    request.local_pid = local.pid;
    request.local_start_time = local.start_time;
}

fn deinitSshTransportAcquireOwnedFields(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) void {
    if (request.ssh_auth_sock) |path| allocator.free(path);
    request.ssh_auth_sock = null;
    if (request.local_start_time.len != 0) allocator.free(request.local_start_time);
    request.local_start_time = "";
}

fn envMapFromSshTransportAcquire(
    allocator: std.mem.Allocator,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    if (request.ssh_auth_sock) |path| {
        try env.put("SSH_AUTH_SOCK", path);
    } else {
        env.remove("SSH_AUTH_SOCK");
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
    session.restoreAttachedClientEndPresentationForExit();
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    try tty_transcript.finishActiveOrReport();
    return exit_status;
}

const BootstrapStatus = enum {
    started,
    finished,
};

fn bootstrapStatusBytes(status: BootstrapStatus) []const u8 {
    return switch (status) {
        .started => "\rsessh: bootstrapping...",
        .finished => "\r\x1b[K",
    };
}

fn sendBootstrapStatus(client_status_fd: c.fd_t, status: BootstrapStatus) !void {
    if (client_status_fd >= 0) {
        switch (status) {
            .started => try protocol.sendSshTransportBinaryBootstrappingFrame(app_allocator.allocator(), client_status_fd),
            .finished => try protocol.sendSshTransportDaemonConnectingFrame(app_allocator.allocator(), client_status_fd),
        }
    } else {
        try io.writeAll(2, bootstrapStatusBytes(status));
    }
}

fn showClientBootstrapStatus(visible: *bool, reconnect_ui: ?*client_ui.ReconnectUi, client_status_fd: c.fd_t) !void {
    if (reconnect_ui != null or visible.*) return;
    try sendBootstrapStatus(client_status_fd, .started);
    visible.* = true;
}

fn clearClientBootstrapStatusOn(visible: *bool, client_status_fd: c.fd_t) void {
    if (!visible.*) return;
    sendBootstrapStatus(client_status_fd, .finished) catch {};
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
    const batch_mode_options: usize = 1;
    const default_options = defaultSshOptionsLen(target);
    const transport_options = transportSshOptionsLen(target.options);
    const ssh_argv = try allocator.alloc([]const u8, transport_options + batch_mode_options + default_options + 4);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    var arg_index: usize = 1;
    // Daemon-owned ssh transports must fail cleanly instead of prompting on
    // stdio. Put this before user/config options because OpenSSH uses the first
    // value it sees for many config keys.
    ssh_argv[arg_index] = "-oBatchMode=yes";
    arg_index += 1;
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
            if (artifactFilenameForPlatform(remote_platform) == null and canUsePlainSshFallback(failure_policy, reconnect_ui)) {
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
        if (isUnsupportedPlatformBootstrapError(line) and canUsePlainSshFallback(failure_policy, reconnect_ui)) {
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
    reconnect_ui: ?*client_ui.ReconnectUi,
) bool {
    return policy.allow_plain_ssh_fallback and
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

        var request = pb.ClientDaemonItem.SshTransportAcquire{
            .host = self.target.host,
            .bootstrap = self.bootstrap,
        };
        defer request.ssh_option.deinit(self.allocator);
        defer deinitSshTransportAcquireOwnedFields(self.allocator, &request);
        try request.ssh_option.appendSlice(self.allocator, self.target.options);
        try appendCurrentSshAgentToSshTransportAcquire(self.allocator, &request);
        try appendCurrentProcessToSshTransportAcquire(self.allocator, &request);

        try protocol.sendSshTransportAcquireFrame(self.allocator, fd, request);
        return .{ .fd = fd };
    }

    pub fn exitAfterInitialFailure(self: *DaemonStreamClientStarter, err: anyerror) !void {
        _ = self;
        return err;
    }
};

fn openProxyControl(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
) !c.fd_t {
    const fd = try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);
    try protocol.sendClientDaemonPayloadFrame(allocator, fd, .{ .proxy_control_open = .{
        .proxy_guid = guid,
    } });
    return fd;
}

fn proxyStreamReconnectStatusMode(level: config.FilterLevel, has_daemon_control: bool) stream_runtime.StreamReconnectStatusMode {
    return switch (level) {
        .raw => .disabled,
        .hygienic, .emulated => if (has_daemon_control) .client_control else .stderr_plain,
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
        c.isatty(posix.STDIN_FILENO) != 0,
        c.isatty(posix.STDOUT_FILENO) != 0,
    );
    var control_guid: ?[]u8 = null;
    defer if (control_guid) |guid| allocator.free(guid);
    var client_control_fd: c.fd_t = -1;
    defer if (client_control_fd >= 0) posix.close(client_control_fd);
    if (diagnostics_plan.use_daemon_control) {
        control_guid = try session_registry.generateProxyGuid(allocator);
        client_control_fd = try openProxyControl(
            allocator,
            exe,
            control_guid.?,
        );
    }
    const daemon_dir_name = try daemon_socket_namespace.defaultDirName(allocator);
    defer allocator.free(daemon_dir_name);
    var runtime_executables = try daemon_executable.runtimeExecutablePaths(allocator, daemon_dir_name);
    defer runtime_executables.deinit();

    const proxy_command_option = try proxyCommandOption(
        allocator,
        runtime_executables.proxy,
        target.options,
        control_guid,
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

    if (diagnostics_plan.wrap_visible_ssh and client_control_fd >= 0) {
        const fd = client_control_fd;
        client_control_fd = -1;
        try plain_ssh.runArgvUnderLocalPty(allocator, ssh_args, fd, diagnostics_plan.client_ctrl_r, "proxy-stream");
    }
    if (diagnostics_plan.use_daemon_control and client_control_fd >= 0) {
        const fd = client_control_fd;
        client_control_fd = -1;
        try plain_ssh.runArgvWithDiagnosticsThread(allocator, ssh_args, fd, "proxy-stream");
    }
    try plain_ssh.runArgv(allocator, ssh_args, "proxy-stream");
}

const ProxyDiagnosticsPlan = struct {
    command_level: config.FilterLevel,
    use_daemon_control: bool,
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
            .use_daemon_control = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!stdin_is_tty or !stdout_is_tty) break :blk .{
                .command_level = .raw,
                .use_daemon_control = false,
                .wrap_visible_ssh = false,
                .client_ctrl_r = false,
            };
            const wrap_visible_ssh = outerSshAllocatesTty(ssh_options, tty_request, shell_command_args, stdin_is_tty);
            break :blk .{
                .command_level = .hygienic,
                .use_daemon_control = true,
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
    control_guid: ?[]const u8,
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
    if (control_guid) |guid| {
        try appendShellToken(allocator, &command, "--control-guid");
        try appendShellToken(allocator, &command, guid);
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
    control_guid: ?[]const u8 = null,
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
    const stream_target = SshTarget{
        .options = invocation.ssh_options.items,
        .host = invocation.host,
    };
    var starter = DaemonStreamClientStarter{
        .allocator = allocator,
        .exe = exe,
        .target = stream_target,
        .bootstrap = invocation.bootstrap,
    };

    const status_mode = proxyStreamReconnectStatusMode(
        invocation.filter_level,
        invocation.control_guid != null,
    );

    const exit_status = stream_runtime.runLocalStream(allocator, &starter, .{
        .guid = proxy_guid,
        .proxy_host = "localhost",
        .proxy_port = proxy_port,
        .source_fd = 0,
        .sink_fd = 1,
        .status_mode = status_mode,
        .intercept_ctrl_r = false,
        .ctrl_r_status_enabled = invocation.client_ctrl_r and invocation.control_guid != null,
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
        } else if (std.mem.eql(u8, arg, "--control-guid")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingProxyControlGuid;
            if (!session_registry.isValidProxyGuid(args[i])) return error.InvalidProxyControlGuid;
            invocation.control_guid = args[i];
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
        error.MissingProxyControlGuid => try io.writeAll(2, "sessh: :internal-proxy-stream: --control-guid requires a p-guid\n"),
        error.InvalidProxyControlGuid => try io.writeAll(2, "sessh: :internal-proxy-stream: --control-guid requires a valid p-guid\n"),
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
        error.MissingClientLogLevel => try io.writeAll(2, "sessh: --log-level requires a value\n"),
        error.MissingFilterLevel => try io.writeAll(2, "sessh: --filter-level requires one of: raw, hygienic, emulated\n"),
        error.MissingTtyTranscriptPath => try io.writeAll(2, "sessh: --capture-tty-transcript requires a path\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: ssh option is missing its value\n"),
        error.SesshOptionAfterHost => try io.writeAll(2, "sessh: sessh options must appear before HOST\n"),
        error.ConflictingSesshAction => try io.writeAll(2, "sessh: conflicting sessh actions\n"),
        error.InvalidScrollbackRowCount => try io.writeAll(2, "sessh: invalid scrollback row count\n"),
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

    const option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, "p-550e8400-e29b-41d4-a716-446655440000", .hygienic, true, true);
    defer std.testing.allocator.free(option);

    try std.testing.expect(std.mem.indexOf(u8, option, "sessh-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, ":internal-proxy-stream:") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%n") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%p") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--filter-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "hygienic") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--bootstrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--control-guid") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "p-550e8400-e29b-41d4-a716-446655440000") != null);
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

test "proxy control registry routes diagnostics and retry by proxy guid" {
    const allocator = std.testing.allocator;
    const guid = "p-550e8400-e29b-41d4-a716-446655440000";

    var visible: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &visible) != 0) return error.SocketPairFailed;
    defer _ = c.close(visible[0]);
    defer _ = c.close(visible[1]);

    var stream: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &stream) != 0) return error.SocketPairFailed;
    defer _ = c.close(stream[0]);
    defer _ = c.close(stream[1]);

    defer {
        unregisterProxyControlVisible(visible[0]);
        unregisterProxyControlStream(stream[0]);
        proxy_control_registrations.deinit(allocator);
        proxy_control_registrations = .empty;
    }

    try registerProxyControlVisible(allocator, guid, visible[0]);
    try registerProxyControlStream(allocator, guid, stream[0]);

    const stderr_payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{ .payload = .{
        .connection_event = .{ .event = .{ .ssh_stderr = .{ .data = "proxy stderr line" } } },
    } });
    defer allocator.free(stderr_payload);
    try forwardProxyControlFromStream(allocator, guid, .{
        .message_type = .client_daemon,
        .payload = stderr_payload,
    });

    var visible_frame = try protocol.readFrameAlloc(allocator, visible[1]);
    defer visible_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, visible_frame.message_type);
    var visible_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, visible_frame.payload);
    defer visible_item.deinit(allocator);
    const event = switch (visible_item.payload orelse return error.MissingProxyControlPayload) {
        .connection_event => |event| event,
        else => return error.UnexpectedProxyControlFrame,
    };
    const stderr = switch (event.event orelse return error.MissingProxyControlPayload) {
        .ssh_stderr => |stderr| stderr,
        else => return error.UnexpectedProxyControlFrame,
    };
    try std.testing.expectEqualStrings("proxy stderr line", stderr.data);

    const retry_payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{ .payload = .{
        .retry_now = .{},
    } });
    defer allocator.free(retry_payload);
    try forwardProxyControlToStream(guid, .{
        .message_type = .client_daemon,
        .payload = retry_payload,
    });

    var stream_frame = try protocol.readFrameAlloc(allocator, stream[1]);
    defer stream_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, stream_frame.message_type);
    var stream_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, stream_frame.payload);
    defer stream_item.deinit(allocator);
    switch (stream_item.payload orelse return error.MissingProxyControlPayload) {
        .retry_now => {},
        else => return error.UnexpectedProxyControlFrame,
    }
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

test "proxy diagnostics plan maps emulated to daemon control" {
    var parsed = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    defer parsed.deinit(std.testing.allocator);

    const interactive = proxyDiagnosticsPlanForTest(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.hygienic, interactive.command_level);
    try std.testing.expect(interactive.use_daemon_control);
    try std.testing.expect(interactive.wrap_visible_ssh);
    try std.testing.expect(interactive.client_ctrl_r);

    const no_stdout = proxyDiagnosticsPlanForTest(parsed, true, false);
    try std.testing.expectEqual(config.FilterLevel.raw, no_stdout.command_level);
    try std.testing.expect(!no_stdout.use_daemon_control);
    try std.testing.expect(!no_stdout.wrap_visible_ssh);
    try std.testing.expect(!no_stdout.client_ctrl_r);

    const no_stdin = proxyDiagnosticsPlanForTest(parsed, false, true);
    try std.testing.expectEqual(config.FilterLevel.raw, no_stdin.command_level);
    try std.testing.expect(!no_stdin.use_daemon_control);
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
    try std.testing.expect(!raw_plan.use_daemon_control);
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
    try std.testing.expect(plan.use_daemon_control);
    try std.testing.expect(!plan.wrap_visible_ssh);
    try std.testing.expect(!plan.client_ctrl_r);
}
