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
const core_fds = @import("../core/fds.zig");
const fd_passing = @import("../core/fd_passing.zig");
const daemon_client = @import("../daemon/client.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_executable = @import("../daemon/executable.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const dispatcher = @import("../core/dispatcher.zig");
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

const pooled_ssh_transport_idle_close_ms: i32 = 60_000;
const proxy_mux_stream_id: u64 = 1;
const proxy_stream_window_bytes: u32 = 1024 * 1024;
const raw_proxy_read_buffer_len: usize = 16 * 1024;

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
const ArtifactEntry = transport_bootstrap.ArtifactEntry;
const Platform = transport_bootstrap.Platform;
const artifactFilenameForPlatform = transport_bootstrap.artifactFilenameForPlatform;
const loadArtifactSet = transport_bootstrap.loadArtifactSet;
const parseMissingPlatform = transport_bootstrap.parseMissingPlatform;
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
    daemon_dir_name: ?[]u8 = null,
    disconnected_reap_ms: u64 = config.default_disconnected_reap_ms,

    fn deinit(self: *SessionRuntimeConfig, allocator: std.mem.Allocator) void {
        if (self.daemon_dir_name) |dir_name| allocator.free(dir_name);
        self.* = undefined;
    }
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
    stderr_fd: c.fd_t = -1,

    fn closeStdin(self: *RuntimeConnection) void {
        closeChildStdin(&self.child);
    }

    fn closeStderr(self: *RuntimeConnection) void {
        if (self.stderr_fd >= 0) {
            posix.close(self.stderr_fd);
            self.stderr_fd = -1;
        }
    }

    fn wait(self: *RuntimeConnection) !std.process.Child.Term {
        return self.child.wait();
    }

    fn terminate(self: *RuntimeConnection) void {
        self.closeStdin();
        _ = self.child.kill() catch {
            _ = self.child.wait() catch {};
        };
        self.closeStderr();
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

    remote_daemon_namespace: ?[]u8 = null,

    fn deinitNamespace(self: *TerminalTransportStart, allocator: std.mem.Allocator) void {
        if (self.remote_daemon_namespace) |namespace| {
            allocator.free(namespace);
            self.remote_daemon_namespace = null;
        }
    }
};

const PooledSshTransportClientState = enum {
    pending_transport,
    opening_stream,
    active,
    done,
};

const PooledSshTransportClientKind = enum {
    unknown,
    te,
    proxy,
};

const PooledSshTransportRawWriteKind = enum {
    bootstrap_exec,
    bootstrap_upload,
};

// The pooled transport deliberately keeps one in-flight write per fd. When a
// client write is active we pause remote reads; when a remote write is active
// we pause client reads. That gives us backpressure without an unbounded queue.
const PooledSshTransportRawWrite = struct {
    bytes: []u8,
    offset: usize = 0,
    kind: PooledSshTransportRawWriteKind,

    fn remaining(self: *const PooledSshTransportRawWrite) []const u8 {
        return self.bytes[self.offset..];
    }

    fn deinit(self: *PooledSshTransportRawWrite, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const PooledSshTransportFrameWriteKind = union(enum) {
    hello_request,
    hello_ok,
    hello_error,
    pong,
    client_mux_open_envelope: struct {
        client: *PooledSshTransportClient,
        typed_open_bytes: []u8,
    },
    client_to_daemon: *PooledSshTransportClient,
    proxy_ack,
    remote_process_recorded,
    cleanup_request,
};

const PooledSshTransportFrameWrite = struct {
    frame: protocol.FrameWriteState,
    kind: PooledSshTransportFrameWriteKind,

    fn deinit(self: *PooledSshTransportFrameWrite) void {
        switch (self.kind) {
            .client_mux_open_envelope => |*open| {
                if (open.typed_open_bytes.len != 0) self.frame.allocator.free(open.typed_open_bytes);
            },
            else => {},
        }
        self.frame.deinit();
        self.* = undefined;
    }
};

const PooledSshTransportRemoteWrite = union(enum) {
    raw: PooledSshTransportRawWrite,
    frame: PooledSshTransportFrameWrite,

    fn deinit(self: *PooledSshTransportRemoteWrite, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .raw => |*raw| raw.deinit(allocator),
            .frame => |*frame| frame.deinit(),
        }
        self.* = undefined;
    }
};

const PooledSshTransportClientWriteKind = union(enum) {
    forwarded_from_daemon,
    finish_after_write: struct {
        send_hangup: bool,
    },
};

const PooledSshTransportClientFrameWrite = struct {
    frame: protocol.FrameWriteState,
    kind: PooledSshTransportClientWriteKind,

    fn deinit(self: *PooledSshTransportClientFrameWrite) void {
        self.frame.deinit();
        self.* = undefined;
    }
};

const PooledSshTransportClientRawWrite = struct {
    bytes: []u8,
    offset: usize = 0,
    kind: PooledSshTransportClientWriteKind,

    fn remaining(self: *const PooledSshTransportClientRawWrite) []const u8 {
        return self.bytes[self.offset..];
    }

    fn deinit(self: *PooledSshTransportClientRawWrite, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const PooledSshTransportClientWrite = union(enum) {
    frame: PooledSshTransportClientFrameWrite,
    raw: PooledSshTransportClientRawWrite,

    fn kind(self: *const PooledSshTransportClientWrite) PooledSshTransportClientWriteKind {
        return switch (self.*) {
            .frame => |frame| frame.kind,
            .raw => |raw| raw.kind,
        };
    }

    fn setKind(self: *PooledSshTransportClientWrite, kind_value: PooledSshTransportClientWriteKind) void {
        switch (self.*) {
            .frame => |*frame| frame.kind = kind_value,
            .raw => |*raw| raw.kind = kind_value,
        }
    }

    fn deinit(self: *PooledSshTransportClientWrite, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .frame => |*frame| frame.deinit(),
            .raw => |*raw| raw.deinit(allocator),
        }
        self.* = undefined;
    }
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

const PendingCleanupRequest = struct {
    remote: RemoteCleanupIdentity,

    fn fromRecord(allocator: std.mem.Allocator, record: daemon_cleanup.Record) !PendingCleanupRequest {
        const start_time = try allocator.dupe(u8, record.remote_start_time);
        errdefer allocator.free(start_time);
        const daemon_socket_path = try allocator.dupe(u8, record.remote_socket_path);
        errdefer allocator.free(daemon_socket_path);
        const guid = try allocator.dupe(u8, record.guid);
        errdefer allocator.free(guid);
        return .{ .remote = .{
            .pid = record.remote_pid,
            .start_time = start_time,
            .daemon_socket_path = daemon_socket_path,
            .guid = guid,
        } };
    }

    fn deinit(self: *PendingCleanupRequest, allocator: std.mem.Allocator) void {
        self.remote.deinit(allocator);
        self.* = undefined;
    }
};

const OwnedEnvironmentEntry = struct {
    name: []u8,
    value: []u8,
};

fn cloneEnvironmentEntries(
    allocator: std.mem.Allocator,
    entries: []const pb.EnvironmentEntry,
) !std.ArrayList(OwnedEnvironmentEntry) {
    var result = std.ArrayList(OwnedEnvironmentEntry).empty;
    errdefer freeEnvironmentEntries(allocator, &result);
    for (entries) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(value);
        try result.append(allocator, .{
            .name = name,
            .value = value,
        });
    }
    return result;
}

fn freeEnvironmentEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(OwnedEnvironmentEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    entries.deinit(allocator);
}

const PooledSshTransportClient = struct {
    fd: c.fd_t,
    transport: *PooledSshTransport = undefined,
    watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    write: ?PooledSshTransportClientWrite = null,
    read_paused: bool = false,
    stream_id: u64 = 0,
    local_stream_id: u64 = 0,
    kind: PooledSshTransportClientKind = .unknown,
    state: PooledSshTransportClientState = .pending_transport,
    outbound_next_offset: u64 = 0,
    inbound_next_offset: u64 = 0,
    raw_proxy: bool = false,
    raw_proxy_host: ?[]u8 = null,
    raw_proxy_port: u32 = 0,
    request_started_ms: u64 = 0,
    mux_open_sent_ms: u64 = 0,
    mux_open_ok_ms: u64 = 0,
    first_payload_ms: u64 = 0,
    startup_timing_logged: bool = false,
    session_ended: bool = false,
    done: bool = false,
    local_pid: u64 = 0,
    local_start_time: ?[]u8 = null,
    send_env: []const []const u8 = &.{},
    client_environment: std.ArrayList(OwnedEnvironmentEntry) = .empty,
    remote_cleanup: ?RemoteCleanupIdentity = null,
    proxy_guid: [session_registry.proxy_guid_len]u8 = [_]u8{0} ** session_registry.proxy_guid_len,
    proxy_guid_len: usize = 0,

    fn initReader(self: *PooledSshTransportClient, allocator: std.mem.Allocator) void {
        self.reader = protocol.FrameReader.init(allocator);
    }

    fn deinit(self: *PooledSshTransportClient, allocator: std.mem.Allocator) void {
        self.reader.deinit();
        if (self.write) |*write| write.deinit(allocator);
        if (self.local_start_time) |start_time| allocator.free(start_time);
        freeStringList(allocator, self.send_env);
        freeEnvironmentEntries(allocator, &self.client_environment);
        if (self.remote_cleanup) |*remote| remote.deinit(allocator);
        if (self.raw_proxy_host) |host| allocator.free(host);
        self.* = undefined;
    }

    fn proxyGuidSlice(self: *const PooledSshTransportClient) []const u8 {
        return self.proxy_guid[0..self.proxy_guid_len];
    }

    fn setProxyGuid(self: *PooledSshTransportClient, guid: []const u8) !void {
        if (guid.len > self.proxy_guid.len) return error.ProxyGuidTooLarge;
        @memcpy(self.proxy_guid[0..guid.len], guid);
        self.proxy_guid_len = guid.len;
    }
};

const PooledSshTransportState = enum {
    starting,
    bootstrap_writing_exec,
    bootstrap_wait_line,
    bootstrap_writing_upload,
    handshake_wait_hello_ok,
    handshake_wait_peer_hello,
    ready,
    closing,
    closed,
};

const PooledSshTransport = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    display_host: []u8,
    resolved_user: []u8,
    resolved_host: []u8,
    resolved_port: []u8,
    ssh_options: []const []const u8 = &.{},
    state: PooledSshTransportState = .starting,
    clients: std.ArrayList(*PooledSshTransportClient) = .empty,
    remote_reader: protocol.FrameReader = undefined,
    remote_watch_id: ?dispatcher.FdWatchId = null,
    stderr_watch_id: ?dispatcher.FdWatchId = null,
    stdin_watch_id: ?dispatcher.FdWatchId = null,
    idle_timer_id: ?dispatcher.TimerWatchId = null,
    connection: ?RuntimeConnection = null,
    stderr_fd: c.fd_t = -1,
    remote_daemon_namespace: ?[]u8 = null,
    next_stream_id: u64 = 1,
    bootstrap_artifacts: ?ArtifactSet = null,
    bootstrap_line: std.ArrayList(u8) = .empty,
    remote_write: ?PooledSshTransportRemoteWrite = null,
    remote_read_paused: bool = false,
    uploaded_bootstrap_artifact: bool = false,
    pending_cleanup_requests: std.ArrayList(PendingCleanupRequest) = .empty,
    cleanup_requests_in_flight: usize = 0,

    fn deinit(self: *PooledSshTransport) void {
        if (self.connection) |*connection| connection.terminate();
        self.remote_reader.deinit();
        if (self.remote_daemon_namespace) |namespace| self.allocator.free(namespace);
        if (self.stderr_fd >= 0) posix.close(self.stderr_fd);
        if (self.remote_write) |*write| write.deinit(self.allocator);
        for (self.pending_cleanup_requests.items) |*request| request.deinit(self.allocator);
        self.pending_cleanup_requests.deinit(self.allocator);
        if (self.bootstrap_artifacts) |*artifacts| artifacts.deinit();
        self.bootstrap_line.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        freeStringList(self.allocator, self.ssh_options);
        self.allocator.free(self.resolved_port);
        self.allocator.free(self.resolved_host);
        self.allocator.free(self.resolved_user);
        self.allocator.free(self.display_host);
        self.allocator.free(self.key);
        self.* = undefined;
    }
};

const PooledSshTransportAcquire = struct {
    transport: *PooledSshTransport,
    created: bool,
};

var pooled_ssh_transports: std.ArrayList(*PooledSshTransport) = .empty;
var active_pooled_ssh_transports: usize = 0;

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

var proxy_control_registrations: std.ArrayList(*ProxyControlRegistration) = .empty;

pub fn activePooledSshTransportCount() usize {
    return active_pooled_ssh_transports;
}

pub fn registerProxyControlOpenFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
    open: pb.ClientDaemonItem.ProxyControlOpen,
) !void {
    const context = try allocator.create(ProxyControlVisibleConnection);
    errdefer allocator.destroy(context);
    const guid = try session_registry.canonicalProxyGuid(allocator, open.proxy_guid);
    errdefer allocator.free(guid);
    try registerProxyControlVisible(allocator, guid, fd);
    errdefer unregisterProxyControlVisible(fd);
    try core_fds.setNonBlocking(fd);
    context.* = .{
        .allocator = allocator,
        .fd = fd,
        .guid = guid,
        .reader = protocol.FrameReader.init(allocator),
    };
    errdefer context.reader.deinit();
    context.watch_id = try daemon_dispatcher.watchFd(fd, .{ .readable = true }, .{
        .ctx = context,
        .callback = readProxyControlVisibleConnection,
    });
}

const ProxyControlVisibleConnection = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t = -1,
    guid: []u8,
    reader: protocol.FrameReader,
    watch_id: ?dispatcher.FdWatchId = null,

    fn deinit(self: *ProxyControlVisibleConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            if (self.watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        }
        self.watch_id = null;
        if (self.fd >= 0) {
            unregisterProxyControlVisible(self.fd);
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.reader.deinit();
        self.allocator.free(self.guid);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn readProxyControlVisibleConnection(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const connection: *ProxyControlVisibleConnection = @ptrCast(@alignCast(ctx));
    readProxyControlVisibleConnectionInner(connection, daemon_dispatcher, event) catch {
        connection.deinit(daemon_dispatcher);
    };
}

fn readProxyControlVisibleConnectionInner(
    connection: *ProxyControlVisibleConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedProxyControlTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        connection.deinit(daemon_dispatcher);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) connection.deinit(daemon_dispatcher);
        return;
    }
    while (true) {
        switch (try connection.reader.readReady(connection.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                connection.deinit(daemon_dispatcher);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (!try proxyControlVisibleFrameIsAllowed(connection.allocator, frame)) return error.UnexpectedProxyControlFrame;
                try forwardProxyControlToStream(connection.guid, frame);
            },
        }
    }
}

fn registerProxyControlVisible(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    const registration = try findOrCreateProxyControlRegistrationLocked(allocator, guid);
    if (registration.visible_fd >= 0 and registration.visible_fd != fd) return error.ProxyControlAlreadyOpen;
    registration.visible_fd = fd;
}

fn registerProxyControlStream(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    const registration = try findOrCreateProxyControlRegistrationLocked(allocator, guid);
    registration.stream_fd = fd;
}

fn unregisterProxyControlVisible(fd: c.fd_t) void {
    for (proxy_control_registrations.items) |registration| {
        if (registration.visible_fd == fd) registration.visible_fd = -1;
    }
    removeUnusedProxyControlRegistrationsLocked();
}

fn unregisterProxyControlStream(fd: c.fd_t) void {
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
    for (proxy_control_registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.visible_fd >= 0) return registration.visible_fd;
    }
    return null;
}

fn proxyControlStreamFd(guid: []const u8) ?c.fd_t {
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

const reconnect_ready_switch_delay_ms: u64 = 10_000;

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
    if (!result.common.isolation_mode_set) {
        if (file_config.isolation_mode) |mode| result.common.isolation_mode = mode;
    }
    if (result.common.isolation_mode == .connection) {
        result.daemon_dir_name = try daemon_socket_namespace.privateConnectionDirName(allocator);
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
    var runtime_config = remoteSessionConfig(allocator, common, ssh_options) catch |err| {
        try io.stderrPrint("sessh: invalid config: {t}\n", .{err});
        return process_exit.request(64);
    };
    defer runtime_config.deinit(allocator);
    client_log.setLevel(runtime_config.common.client_log_level);

    const target = SshTarget{ .options = ssh_options, .host = host };
    const stdin_is_tty = c.isatty(posix.STDIN_FILENO) != 0;
    const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    if (shouldUseProxyStream(new, runtime_config.common, stdin_is_tty, stdout_is_tty)) {
        if (runtime_config.common.capture_tty_transcript != null) {
            try io.writeAll(2, "sessh: --capture-tty-transcript is not supported with proxy stream mode\n");
            return process_exit.request(64);
        }
        try runProxyStreamSsh(allocator, exe, target, runtime_config.common, runtime_config.daemon_dir_name, new);
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
        runtime_config.daemon_dir_name,
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
                try io.writeAll(2, "sessh: --capture-tty-transcript requires a compatible sessh remote\n");
                return process_exit.request(1);
            }
            if (new.command_argv.len > 0 or shell_command != null) {
                try io.writeAll(2, "sessh: persistent command sessions require a compatible sessh remote\n");
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
        try io.stderrPrint("sessh: ssh remote attach failed: {t}\n", .{err});
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

pub fn registerPooledSshTransportFromDaemon(
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
        "ssh transport opening host={s} resolved={s}@{s}:{s} bootstrap={}",
        .{ target.host, target.resolved_user, target.resolved_host, target.resolved_port, acquire_request.bootstrap },
    );

    try registerPooledSshTransportClientFromDaemon(
        allocator,
        daemon_dispatcher,
        client_fd,
        target,
        acquire_request,
        resolved_target.config.send_env,
    );
}

pub fn registerProxyFdPassOpenFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    setup_fd: c.fd_t,
    raw_fd: c.fd_t,
    request: pb.ClientDaemonItem.ProxyFdPassOpen,
) !void {
    const transport_request = request.transport orelse {
        try sendDaemonTransportError(setup_fd, "PROTOCOL_ERROR", "proxy fd-pass open missing transport", "");
        return error.InvalidProxyFdPassOpen;
    };
    const proxy_open = request.proxy orelse {
        try sendDaemonTransportError(setup_fd, "PROTOCOL_ERROR", "proxy fd-pass open missing proxy details", "");
        return error.InvalidProxyFdPassOpen;
    };
    if (!session_registry.isValidProxyGuid(proxy_open.proxy_guid)) {
        try sendDaemonTransportError(setup_fd, "PROTOCOL_ERROR", "proxy fd-pass open has invalid proxy guid", "");
        return error.InvalidProxyFdPassOpen;
    }
    if (proxy_open.proxy_port == 0 or proxy_open.proxy_port > std.math.maxInt(u16)) {
        try sendDaemonTransportError(setup_fd, "PROTOCOL_ERROR", "proxy fd-pass open has invalid proxy port", "");
        return error.InvalidProxyFdPassOpen;
    }

    var resolved_target = try resolveSshTarget(allocator, transport_request.ssh_option.items, transport_request.host);
    defer resolved_target.deinit(allocator);
    var acquire_request = transport_request;
    if (acquire_request.ip_qos.len == 0) {
        if (resolved_target.config.ipqos) |ip_qos| acquire_request.ip_qos = ip_qos;
    }
    const target = resolved_target.target;
    daemon_log.infof(
        allocator,
        "proxy fd-pass opening host={s} resolved={s}@{s}:{s} guid={s}",
        .{ target.host, target.resolved_user, target.resolved_host, target.resolved_port, proxy_open.proxy_guid },
    );

    try core_fds.setNonBlocking(raw_fd);
    registerPooledRawProxyClientFromDaemon(
        allocator,
        daemon_dispatcher,
        raw_fd,
        setup_fd,
        target,
        acquire_request,
        resolved_target.config.send_env,
        proxy_open,
    ) catch |err| {
        daemon_log.infof(allocator, "proxy fd-pass setup failed guid={s} error={t}", .{ proxy_open.proxy_guid, err });
        return err;
    };

    _ = c.close(setup_fd);
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
            daemon_log.infof(allocator, "ssh transport failed host={s} error={t}", .{ target.host, err });
            try sendDaemonTransportError(
                client_fd,
                "UNSUPPORTED_REMOTE_PLATFORM",
                "remote platform is unsupported and no matching sessh binary is available",
                "",
            );
            return error.TerminalTransportStartReported;
        },
        else => {
            daemon_log.infof(allocator, "ssh transport failed host={s} error={t}", .{ target.host, err });
            if (try sendDaemonSshFailure(client_fd, allocator, target, bootstrap_failure_term)) return error.TerminalTransportStartReported;
            try sendDaemonTransportError(client_fd, "SSH_TRANSPORT_FAILED", "ssh transport failed", "");
            return err;
        },
    };

    const remote_daemon_namespace = broker_socket_dir;
    broker_socket_dir = null;
    return .{
        .connection = child,
        .remote_daemon_namespace = remote_daemon_namespace,
    };
}

fn startPooledSshTransportProcessForDaemon(
    allocator: std.mem.Allocator,
    transport: *PooledSshTransport,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    var broker_socket_dir: ?[]u8 = null;
    errdefer if (broker_socket_dir) |dir| allocator.free(dir);
    var broker_arg_storage: [1][]const u8 = undefined;
    var broker_args: []const []const u8 = broker_arg_storage[0..0];
    if (request.bootstrap) {
        transport.bootstrap_artifacts = try loadArtifactSet(allocator);
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

    var ssh_launch_environment = try envMapFromSshTransportAcquire(allocator, request);
    defer ssh_launch_environment.deinit();

    transport.connection = try spawnSshRuntimeConnection(
        allocator,
        target,
        remote_command,
        &ssh_launch_environment,
        request.bootstrap,
    );
    errdefer {
        if (transport.connection) |*connection| connection.terminate();
        transport.connection = null;
    }

    const remote_read_fd = transport.connection.?.child.stdout.?.handle;
    try setNonBlockingFd(remote_read_fd);
    try setNonBlockingFd(transport.connection.?.child.stdin.?.handle);
    transport.stderr_fd = transport.connection.?.stderr_fd;
    transport.connection.?.stderr_fd = -1;
    transport.remote_daemon_namespace = broker_socket_dir;
    broker_socket_dir = null;
}

fn registerPooledSshTransportClientFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
) !void {
    const client = try allocator.create(PooledSshTransportClient);
    errdefer allocator.destroy(client);
    var local_start_time = if (request.local_start_time.len == 0) null else try allocator.dupe(u8, request.local_start_time);
    errdefer if (local_start_time) |start_time| allocator.free(start_time);
    var send_env_copy = try cloneStringList(allocator, send_env);
    errdefer freeStringList(allocator, send_env_copy);
    var client_environment = try cloneEnvironmentEntries(allocator, request.client_environment.items);
    errdefer freeEnvironmentEntries(allocator, &client_environment);
    client.* = .{
        .fd = client_fd,
        .request_started_ms = nowUnixMs(),
        .local_pid = request.local_pid,
        .local_start_time = local_start_time,
        .send_env = send_env_copy,
        .client_environment = client_environment,
    };
    local_start_time = null;
    send_env_copy = &.{};
    client_environment = .empty;
    client.initReader(allocator);
    errdefer client.deinit(allocator);

    const acquire = try acquirePooledSshTransport(allocator, target, request, client);
    client.transport = acquire.transport;
    if (acquire.created) {
        startNewPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, client_fd, target, request) catch |err| {
            failStartingPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, client, err);
        };
    } else if (acquire.transport.state == .ready) {
        activatePendingPooledSshTransportClients(daemon_dispatcher, acquire.transport);
    }
}

fn registerPooledRawProxyClientFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    raw_fd: c.fd_t,
    setup_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
    proxy_open: pb.ProxyStreamItem.Open,
) !void {
    const client = try allocator.create(PooledSshTransportClient);
    errdefer allocator.destroy(client);
    var local_start_time = if (request.local_start_time.len == 0) null else try allocator.dupe(u8, request.local_start_time);
    errdefer if (local_start_time) |start_time| allocator.free(start_time);
    var send_env_copy = try cloneStringList(allocator, send_env);
    errdefer freeStringList(allocator, send_env_copy);
    var client_environment = try cloneEnvironmentEntries(allocator, request.client_environment.items);
    errdefer freeEnvironmentEntries(allocator, &client_environment);
    var raw_proxy_host: ?[]u8 = try allocator.dupe(u8, proxy_open.proxy_host);
    errdefer if (raw_proxy_host) |host| allocator.free(host);
    client.* = .{
        .fd = raw_fd,
        .request_started_ms = nowUnixMs(),
        .local_pid = request.local_pid,
        .local_start_time = local_start_time,
        .send_env = send_env_copy,
        .client_environment = client_environment,
        .raw_proxy = true,
        .raw_proxy_host = raw_proxy_host.?,
        .raw_proxy_port = proxy_open.proxy_port,
        .kind = .proxy,
        .local_stream_id = proxy_mux_stream_id,
    };
    local_start_time = null;
    send_env_copy = &.{};
    client_environment = .empty;
    raw_proxy_host = null;
    client.initReader(allocator);
    errdefer client.deinit(allocator);
    try client.setProxyGuid(proxy_open.proxy_guid);

    const acquire = try acquirePooledSshTransport(allocator, target, request, client);
    client.transport = acquire.transport;
    daemon_log.infof(allocator, "proxy fd-pass setup accepted guid={s}", .{proxy_open.proxy_guid});
    protocol.sendClientDaemonPayloadFrame(allocator, setup_fd, .{ .proxy_fd_pass_accepted = .{} }) catch |err| {
        daemon_log.infof(allocator, "proxy fd-pass setup ack failed guid={s} error={t}", .{ proxy_open.proxy_guid, err });
    };
    if (acquire.created) {
        startNewPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, raw_fd, target, request) catch |err| {
            failStartingPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, client, err);
        };
    } else if (acquire.transport.state == .ready) {
        activatePendingPooledSshTransportClients(daemon_dispatcher, acquire.transport);
    }
}

fn acquirePooledSshTransport(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    client: *PooledSshTransportClient,
) !PooledSshTransportAcquire {
    const acquire = try findOrCreatePooledSshTransport(allocator, target, request);
    errdefer if (acquire.created) destroyUnstartedPooledSshTransport(allocator, acquire.transport);
    try acquire.transport.clients.append(allocator, client);
    return acquire;
}

fn findOrCreatePooledSshTransport(
    allocator: std.mem.Allocator,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !PooledSshTransportAcquire {
    const key = try pooledSshTransportKey(allocator, target, request);
    errdefer allocator.free(key);

    for (pooled_ssh_transports.items) |transport| {
        if (transport.state == .closed or transport.state == .closing) continue;
        if (!std.mem.eql(u8, transport.key, key)) continue;
        allocator.free(key);
        daemon_log.infof(
            allocator,
            "pooled ssh transport reusing host={s} pool={s} remote_namespace={s}",
            .{ target.host, transport.key, transport.remote_daemon_namespace orelse "remote-default" },
        );
        return .{ .transport = transport, .created = false };
    }

    const transport = try allocator.create(PooledSshTransport);
    errdefer allocator.destroy(transport);
    transport.* = .{
        .allocator = allocator,
        .key = key,
        .display_host = try allocator.dupe(u8, target.host),
        .resolved_user = try allocator.dupe(u8, target.resolved_user),
        .resolved_host = try allocator.dupe(u8, target.resolved_host),
        .resolved_port = try allocator.dupe(u8, target.resolved_port),
        .ssh_options = try cloneStringList(allocator, target.options),
    };
    transport.remote_reader = protocol.FrameReader.init(allocator);
    errdefer transport.deinit();
    try pooled_ssh_transports.append(allocator, transport);
    active_pooled_ssh_transports += 1;
    daemon_log.infof(
        allocator,
        "pooled ssh transport creating host={s} pool={s}",
        .{ target.host, transport.key },
    );
    return .{ .transport = transport, .created = true };
}

fn destroyUnstartedPooledSshTransport(allocator: std.mem.Allocator, transport: *PooledSshTransport) void {
    removePooledSshTransport(transport);
    active_pooled_ssh_transports -= 1;
    transport.deinit();
    allocator.destroy(transport);
}

fn pooledSshTransportKey(
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

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
    }
    for (values, 0..) |value, i| {
        result[i] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len == 0) return;
    allocator.free(values);
}

fn pooledTransportTarget(transport: *const PooledSshTransport) SshTarget {
    return .{
        .options = transport.ssh_options,
        .host = transport.display_host,
        .resolved_user = transport.resolved_user,
        .resolved_host = transport.resolved_host,
        .resolved_port = transport.resolved_port,
    };
}

fn buildBootstrapExecBytes(
    allocator: std.mem.Allocator,
    artifacts: *const ArtifactSet,
    entrypoint: BootstrapEntrypoint,
    entrypoint_args: []const []const u8,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "EXEC ");
    try bytes.appendSlice(allocator, artifacts.artifact_set_id);
    for (artifacts.entries) |entry| {
        try bytes.append(allocator, ' ');
        try bytes.appendSlice(allocator, &entry.hash_hex);
    }
    try bytes.appendSlice(allocator, " -- ");
    try bytes.appendSlice(allocator, entrypoint.arg());
    for (entrypoint_args) |arg| {
        try bytes.append(allocator, ' ');
        try appendBootstrapExecArg(allocator, &bytes, arg);
    }
    try bytes.append(allocator, '\n');
    return bytes.toOwnedSlice(allocator);
}

fn appendBootstrapExecArg(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), arg: []const u8) !void {
    if (!remote_shell.needsEncodedExecArg(arg)) {
        try bytes.appendSlice(allocator, arg);
        return;
    }
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(arg.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, arg);
    try bytes.appendSlice(allocator, remote_shell.bootstrap_exec_encoded_arg_prefix);
    try bytes.appendSlice(allocator, encoded);
}

fn buildBootstrapUploadBytes(
    allocator: std.mem.Allocator,
    artifact: *const ArtifactEntry,
) ![]u8 {
    const file = try std.fs.openFileAbsolute(artifact.path, .{});
    defer file.close();
    const file_bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(file_bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file_bytes, &digest, .{});
    const actual_hash = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hash, &artifact.hash_hex)) return error.ArtifactHashMismatch;

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(file_bytes.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, file_bytes);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "UPLOAD ");
    try bytes.appendSlice(allocator, artifact.id);
    try bytes.append(allocator, ' ');
    try bytes.appendSlice(allocator, &artifact.hash_hex);
    try bytes.append(allocator, ' ');
    try bytes.appendSlice(allocator, encoded);
    try bytes.append(allocator, '\n');
    return bytes.toOwnedSlice(allocator);
}

fn startNewPooledSshTransport(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    _ = client_fd;
    try startPooledSshTransportProcessForDaemon(allocator, transport, target, request);
    errdefer {
        if (transport.remote_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            transport.remote_watch_id = null;
        }
        if (transport.stderr_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            transport.stderr_watch_id = null;
        }
        if (transport.stdin_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            transport.stdin_watch_id = null;
        }
    }
    const remote_read_fd = transport.connection.?.child.stdout.?.handle;
    transport.remote_watch_id = try daemon_dispatcher.watchFd(remote_read_fd, .{ .readable = true }, .{
        .ctx = transport,
        .callback = readPooledSshTransportRemote,
    });
    transport.stderr_watch_id = try daemon_dispatcher.watchFd(transport.stderr_fd, .{ .readable = true }, .{
        .ctx = transport,
        .callback = readPooledSshTransportStderr,
    });

    if (request.bootstrap) {
        const artifacts = if (transport.bootstrap_artifacts) |*value| value else return error.MissingBootstrapArtifacts;
        const exec_bytes = try buildBootstrapExecBytes(allocator, artifacts, .broker, if (transport.remote_daemon_namespace) |namespace| &[_][]const u8{namespace} else &.{});
        try startPooledSshTransportRemoteRawWrite(transport, daemon_dispatcher, .bootstrap_exec, exec_bytes);
        transport.state = .bootstrap_writing_exec;
    } else {
        try startPooledSshTransportHandshake(daemon_dispatcher, transport);
    }
}

fn failStartingPooledSshTransport(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    starter: *PooledSshTransportClient,
    err: anyerror,
) void {
    _ = allocator;
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client != starter or err != error.TerminalTransportStartReported) {
            _ = failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "SSH_TRANSPORT_FAILED", "ssh transport failed", "", false);
        } else {
            destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
        }
        if (index < transport.clients.items.len and transport.clients.items[index] == client) {
            index += 1;
        }
    }
    if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
}

pub fn enqueueCleanupRequestToRemote(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    record: daemon_cleanup.Record,
) !void {
    var options = [_][]const u8{ "-l", record.remote_user, "-p", record.remote_port };
    const target = SshTarget{
        .options = &options,
        .host = record.remote_host,
        .resolved_user = record.remote_user,
        .resolved_host = record.remote_host,
        .resolved_port = record.remote_port,
    };
    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = record.remote_host,
        .bootstrap = true,
    };
    defer deinitSshTransportAcquireOwnedFields(allocator, &request);
    try appendCurrentSshAgentToSshTransportAcquire(allocator, &request);

    const acquire = try findOrCreatePooledSshTransport(allocator, target, request);
    var pending = try PendingCleanupRequest.fromRecord(allocator, record);
    errdefer pending.deinit(allocator);
    try acquire.transport.pending_cleanup_requests.append(allocator, pending);
    pending = undefined;

    if (acquire.created) {
        startNewPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, -1, target, request) catch |err| {
            finishPooledSshTransport(daemon_dispatcher, acquire.transport);
            return err;
        };
    } else if (acquire.transport.state == .ready) {
        try startNextPendingCleanupRequest(daemon_dispatcher, acquire.transport);
    }
}

fn readPooledSshTransportRemote(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const transport: *PooledSshTransport = @ptrCast(@alignCast(ctx));
    readPooledSshTransportRemoteInner(transport, daemon_dispatcher, event) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
    };
}

fn readPooledSshTransportRemoteInner(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedPooledSshTransportTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) {
            notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
        }
        return;
    }

    const remote_read_fd = transport.connection.?.child.stdout.?.handle;
    switch (transport.state) {
        .bootstrap_writing_exec, .bootstrap_writing_upload => return,
        .bootstrap_wait_line => {
            try readPooledSshTransportBootstrapLine(daemon_dispatcher, transport, remote_read_fd);
            return;
        },
        .handshake_wait_hello_ok, .handshake_wait_peer_hello => {
            try readPooledSshTransportHandshake(daemon_dispatcher, transport, remote_read_fd);
            return;
        },
        .starting, .ready, .closing, .closed => {},
    }

    if (transport.remote_read_paused) return;
    while (true) {
        switch (try transport.remote_reader.readReady(remote_read_fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(transport.allocator);
                if (!try handlePooledRemoteFrame(daemon_dispatcher, transport, frame)) {
                    notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
                    return;
                }
                if (transport.remote_read_paused) return;
            },
        }
    }
}

fn readPooledSshTransportBootstrapLine(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    fd: c.fd_t,
) !void {
    while (transport.bootstrap_line.items.len < 4096) {
        var byte: [1]u8 = undefined;
        const n = c.read(fd, &byte, 1);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) {
            failPooledSshTransportBootstrapRead(daemon_dispatcher, transport, error.EndOfStream);
            return;
        }
        if (byte[0] == '\n') {
            const line = try transport.bootstrap_line.toOwnedSlice(transport.allocator);
            defer transport.allocator.free(line);
            transport.bootstrap_line = .empty;
            try handlePooledSshTransportBootstrapLine(daemon_dispatcher, transport, line);
            return;
        }
        try transport.bootstrap_line.append(transport.allocator, byte[0]);
    }
    failPooledSshTransportBootstrapRead(daemon_dispatcher, transport, error.BootstrapLineTooLong);
}

fn handlePooledSshTransportBootstrapLine(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    line: []const u8,
) !void {
    if (std.mem.eql(u8, line, "OK")) {
        if (transport.uploaded_bootstrap_artifact) {
            daemon_log.infof(transport.allocator, "bootstrap completed host={s} uploaded=true", .{transport.display_host});
        } else {
            daemon_log.infof(transport.allocator, "bootstrap skipped host={s} reason=remote_artifact_present", .{transport.display_host});
        }
        try startPooledSshTransportHandshake(daemon_dispatcher, transport);
        return;
    }

    if (std.mem.startsWith(u8, line, "MISSING ")) {
        const remote_platform = parseMissingPlatform(line) catch {
            failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapInvalidResponse, null);
            return;
        };
        const artifacts = if (transport.bootstrap_artifacts) |*value| value else {
            failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapFailed, null);
            return;
        };
        const artifact = artifacts.find(remote_platform) orelse {
            if (artifactFilenameForPlatform(remote_platform) == null) {
                for (transport.clients.items) |client| {
                    _ = failPooledSshTransportClientWithError(
                        daemon_dispatcher,
                        transport,
                        client,
                        "UNSUPPORTED_REMOTE_PLATFORM",
                        "remote platform is unsupported and no matching sessh binary is available",
                        "",
                        false,
                    );
                }
                failPooledSshTransportStartup(daemon_dispatcher, transport, error.UnsupportedRemotePlatform, null);
                return;
            }
            failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapFailed, null);
            return;
        };
        daemon_log.infof(
            transport.allocator,
            "bootstrap upload required host={s} platform={s}/{s}",
            .{ transport.display_host, remote_platform.os, remote_platform.arch },
        );
        sendPooledSshTransportConnectionEvent(daemon_dispatcher, transport, .{ .binary_bootstrapping = .{} });
        const upload = try buildBootstrapUploadBytes(transport.allocator, artifact);
        try startPooledSshTransportRemoteRawWrite(transport, daemon_dispatcher, .bootstrap_upload, upload);
        transport.state = .bootstrap_writing_upload;
        transport.uploaded_bootstrap_artifact = true;
        return;
    }

    if (std.mem.startsWith(u8, line, "ERR UNSUPPORTED_PLATFORM ")) {
        for (transport.clients.items) |client| {
            _ = failPooledSshTransportClientWithError(
                daemon_dispatcher,
                transport,
                client,
                "UNSUPPORTED_REMOTE_PLATFORM",
                "remote platform is unsupported and no matching sessh binary is available",
                "",
                false,
            );
        }
        failPooledSshTransportStartup(daemon_dispatcher, transport, error.UnsupportedRemotePlatform, null);
        return;
    }

    if (std.mem.startsWith(u8, line, "ERR ")) {
        daemon_log.infof(transport.allocator, "remote bootstrap failed host={s} line={s}", .{ transport.display_host, line });
        failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapFailed, null);
        return;
    }

    daemon_log.infof(transport.allocator, "unexpected bootstrap response host={s} line={s}", .{ transport.display_host, line });
    failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapInvalidResponse, null);
}

fn startPooledSshTransportHandshake(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    sendPooledSshTransportConnectionEvent(daemon_dispatcher, transport, .{ .daemon_connecting = .{} });
    const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .hello_request, payload, .hello_request);
}

fn readPooledSshTransportHandshake(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    fd: c.fd_t,
) !void {
    while (true) {
        switch (try transport.remote_reader.readReady(fd)) {
            .blocked, .progress => return,
            .eof, .truncated_frame => {
                failPooledSshTransportStartup(daemon_dispatcher, transport, error.EndOfStream, null);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(transport.allocator);
                try handlePooledSshTransportHandshakeFrame(daemon_dispatcher, transport, &frame);
                if (transport.state == .ready or transport.state == .closed) return;
            },
        }
    }
}

fn handlePooledSshTransportHandshakeFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    frame: *const protocol.OwnedFrame,
) !void {
    switch (transport.state) {
        .handshake_wait_hello_ok => switch (frame.message_type) {
            .hello_ok => {
                var ok = try protocol.decodePayload(protocol.hpb.HelloOk, transport.allocator, frame.payload);
                defer ok.deinit(transport.allocator);
                transport.state = .handshake_wait_peer_hello;
            },
            .hello_error => {
                failPooledSshTransportStartup(daemon_dispatcher, transport, error.VersionMismatch, null);
            },
            .daemon_tunnel => {
                _ = try handlePooledTransportControlFrame(daemon_dispatcher, transport, frame);
            },
            else => return error.UnexpectedDaemonFrame,
        },
        .handshake_wait_peer_hello => switch (frame.message_type) {
            .hello_request => {
                var peer_hello = try protocol.decodePayload(protocol.hpb.HelloRequest, transport.allocator, frame.payload);
                defer peer_hello.deinit(transport.allocator);
                if (!protocol.helloRequestIsCompatible(peer_hello, config.min_protocol_major, config.min_protocol_minor)) {
                    try startPooledSshTransportRemoteHelloError(transport, daemon_dispatcher, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
                    return;
                }
                const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloOk{});
                defer transport.allocator.free(payload);
                try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .hello_ok, payload, .hello_ok);
            },
            .daemon_tunnel => {
                _ = try handlePooledTransportControlFrame(daemon_dispatcher, transport, frame);
            },
            else => return error.UnexpectedDaemonFrame,
        },
        else => return error.UnexpectedDaemonFrame,
    }
}

fn completePooledSshTransportStartup(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    transport.state = .ready;
    daemon_log.infof(
        transport.allocator,
        "ssh transport ready host={s} remote_namespace={s}",
        .{ transport.display_host, transport.remote_daemon_namespace orelse "remote-default" },
    );
    sendPooledSshTransportConnectionEvent(daemon_dispatcher, transport, .{ .daemon_connected = .{} });
    activatePendingPooledSshTransportClients(daemon_dispatcher, transport);
    startNextPendingCleanupRequest(daemon_dispatcher, transport) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "cleanup request enqueue failed host={s} error={t}",
            .{ transport.display_host, err },
        );
    };
}

fn failPooledSshTransportStartup(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    err: anyerror,
    term: ?std.process.Child.Term,
) void {
    daemon_log.infof(transport.allocator, "ssh transport failed host={s} error={t}", .{ transport.display_host, err });
    const target = pooledTransportTarget(transport);
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        const reported = startPooledClientSshFailure(daemon_dispatcher, client, target, term) catch false;
        if (!reported and err != error.UnsupportedRemotePlatform) {
            _ = failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "SSH_TRANSPORT_FAILED", "ssh transport failed", "", false);
        } else if (!reported) {
            if (!finishPooledClientAfterCurrentWrite(client, false)) {
                destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
            }
        }
        if (index < transport.clients.items.len and transport.clients.items[index] == client) {
            index += 1;
        }
    }
    if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
}

fn failPooledSshTransportBootstrapRead(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    err: anyerror,
) void {
    const stage: []const u8 = if (transport.uploaded_bootstrap_artifact) "after upload" else "before response";
    daemon_log.infof(
        transport.allocator,
        "bootstrap failed {s} host={s} error={t}",
        .{ stage, transport.display_host, err },
    );
    if (transport.connection) |*connection| connection.closeStdin();
    _ = forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch {};
    const term = if (transport.connection) |*connection| connection.wait() catch null else null;
    _ = forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch {};
    failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapFailed, term);
}

fn sendPooledSshTransportConnectionEvent(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    event: pb.ConnectionEvent.event_union,
) void {
    var started_write = false;
    for (transport.clients.items) |client| {
        if (client.state == .done) continue;
        if (client.raw_proxy) continue;
        if (client.write != null) continue;
        startPooledClientConnectionEvent(daemon_dispatcher, client, event, .forwarded_from_daemon) catch |err| {
            daemon_log.infof(
                transport.allocator,
                "pooled ssh transport connection event dropped host={s} stream_id={} error={t}",
                .{ transport.display_host, client.stream_id, err },
            );
            continue;
        };
        started_write = true;
    }
    if (started_write) pausePooledSshTransportRemoteRead(daemon_dispatcher, transport) catch {};
}

fn readPooledSshTransportStderr(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const transport: *PooledSshTransport = @ptrCast(@alignCast(ctx));
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedPooledSshTransportTimer,
    };
    if (!fd_event.readable and !fd_event.hangup and !fd_event.error_event and !fd_event.invalid) return;
    forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport stderr failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        if (transport.stderr_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            transport.stderr_watch_id = null;
        }
    };
    if (fd_event.hangup or fd_event.error_event or fd_event.invalid) {
        if (transport.stderr_watch_id) |watch_id| {
            daemon_dispatcher.cancel(.{ .fd = watch_id });
            transport.stderr_watch_id = null;
        }
    }
}

fn writePooledSshTransportRemote(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const transport: *PooledSshTransport = @ptrCast(@alignCast(ctx));
    writePooledSshTransportRemoteInner(transport, daemon_dispatcher, event) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport remote write failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        failPooledSshTransportStartup(daemon_dispatcher, transport, err, null);
    };
}

fn writePooledSshTransportRemoteInner(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedPooledSshTransportTimer,
    };
    if (fd_event.error_event or fd_event.invalid or fd_event.hangup) return error.SshTransportWriteClosed;
    if (!fd_event.writable) return;
    const write = if (transport.remote_write) |*value| value else return;
    const fd = transport.connection.?.child.stdin.?.handle;

    const done = switch (write.*) {
        .raw => |*raw| try writePooledSshTransportRaw(fd, raw),
        .frame => |*frame| try writePooledSshTransportFrame(fd, frame),
    };
    if (!done) return;

    var completed = transport.remote_write.?;
    transport.remote_write = null;
    if (transport.stdin_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stdin_watch_id = null;
    }

    switch (completed) {
        .raw => |*raw| {
            const kind = raw.kind;
            raw.deinit(transport.allocator);
            switch (kind) {
                .bootstrap_exec, .bootstrap_upload => transport.state = .bootstrap_wait_line,
            }
        },
        .frame => |*frame| try completePooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, frame),
    }
}

fn writePooledSshTransportRaw(
    fd: c.fd_t,
    raw: *PooledSshTransportRawWrite,
) !bool {
    while (raw.remaining().len != 0) {
        const chunk = raw.remaining();
        const n = c.write(fd, chunk.ptr, chunk.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return false,
            .INTR => continue,
            else => return error.WriteFailed,
        };
        if (n == 0) return error.WriteFailed;
        const written: usize = @intCast(n);
        io.noteWrite(fd, chunk[0..written]);
        raw.offset += written;
    }
    return true;
}

fn writePooledSshTransportFrame(fd: c.fd_t, frame: *PooledSshTransportFrameWrite) !bool {
    return switch (try frame.frame.writeReady(fd)) {
        .blocked, .progress => false,
        .done => true,
    };
}

fn completePooledSshTransportRemoteFrameWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: *PooledSshTransportFrameWrite,
) !void {
    switch (frame.kind) {
        .hello_request => {
            frame.frame.deinit();
            transport.state = .handshake_wait_hello_ok;
        },
        .hello_ok => {
            frame.frame.deinit();
            completePooledSshTransportStartup(daemon_dispatcher, transport);
        },
        .hello_error => {
            frame.frame.deinit();
            failPooledSshTransportStartup(daemon_dispatcher, transport, error.VersionMismatch, null);
        },
        .pong => {
            frame.frame.deinit();
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
        .client_mux_open_envelope => |*open| {
            const typed_open_bytes = open.typed_open_bytes;
            const client = open.client;
            open.typed_open_bytes = &.{};
            frame.frame.deinit();
            try startPooledSshTransportRemoteFrameBytes(
                transport,
                daemon_dispatcher,
                typed_open_bytes,
                .{ .client_to_daemon = client },
            );
            return;
        },
        .client_to_daemon => |client| {
            frame.frame.deinit();
            if (client.state == .opening_stream) client.state = .active;
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
        .proxy_ack, .remote_process_recorded, .cleanup_request => {
            frame.frame.deinit();
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
    }
}

fn startPooledSshTransportRemoteRawWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    kind: PooledSshTransportRawWriteKind,
    bytes: []u8,
) !void {
    if (transport.remote_write != null) return error.PooledSshTransportWriteAlreadyQueued;
    errdefer transport.allocator.free(bytes);
    transport.remote_write = .{ .raw = .{ .bytes = bytes, .kind = kind } };
    try ensurePooledSshTransportRemoteWritable(transport, daemon_dispatcher);
}

fn startPooledSshTransportRemoteFrameWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    message_type: protocol.MessageType,
    payload: []const u8,
    kind: PooledSshTransportFrameWriteKind,
) !void {
    var frame = try protocol.FrameWriteState.init(transport.allocator, message_type, payload);
    errdefer frame.deinit();
    try startPooledSshTransportRemoteFrameState(transport, daemon_dispatcher, frame, kind);
}

fn startPooledSshTransportRemoteHelloError(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
) !void {
    const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloError{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .hello_error, payload, .hello_error);
}

fn startPooledSshTransportRemoteFrameBytes(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    bytes: []u8,
    kind: PooledSshTransportFrameWriteKind,
) !void {
    errdefer transport.allocator.free(bytes);
    try startPooledSshTransportRemoteFrameState(
        transport,
        daemon_dispatcher,
        .{ .allocator = transport.allocator, .bytes = bytes },
        kind,
    );
}

fn startPooledSshTransportRemoteFrameState(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.FrameWriteState,
    kind: PooledSshTransportFrameWriteKind,
) !void {
    if (transport.remote_write != null) return error.PooledSshTransportWriteAlreadyQueued;
    transport.remote_write = .{ .frame = .{ .frame = frame, .kind = kind } };
    try ensurePooledSshTransportRemoteWritable(transport, daemon_dispatcher);
}

fn ensurePooledSshTransportRemoteWritable(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    if (transport.stdin_watch_id == null) {
        transport.stdin_watch_id = try daemon_dispatcher.watchFd(transport.connection.?.child.stdin.?.handle, .{ .writable = true }, .{
            .ctx = transport,
            .callback = writePooledSshTransportRemote,
        });
    }
}

fn readPooledSshTransportClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const client: *PooledSshTransportClient = @ptrCast(@alignCast(ctx));
    const transport = client.transport;
    readPooledSshTransportClientInner(client, daemon_dispatcher, event) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport client failed host={s} pool={s} stream_id={} error={t}",
            .{ transport.display_host, transport.key, client.stream_id, err },
        );
        finishPooledSshTransportClient(daemon_dispatcher, transport, client, true);
    };
}

fn readPooledSshTransportClientInner(
    client: *PooledSshTransportClient,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const transport = client.transport;
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedPooledSshTransportTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        finishPooledSshTransportClient(daemon_dispatcher, transport, client, true);
        return;
    }
    if (fd_event.writable and client.write != null) {
        try writePooledSshTransportClient(daemon_dispatcher, transport, client);
        if (client.done) return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) finishPooledSshTransportClient(daemon_dispatcher, transport, client, true);
        return;
    }
    if (client.read_paused or transport.remote_write != null or client.write != null) {
        if (transport.remote_write != null) client.read_paused = true;
        try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
        return;
    }

    if (client.raw_proxy) {
        try readPooledRawProxyClient(daemon_dispatcher, transport, client);
        return;
    }

    while (true) {
        switch (try client.reader.readReady(client.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                finishPooledSshTransportClient(daemon_dispatcher, transport, client, true);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                const alive = try handlePooledSshTransportClientFrame(daemon_dispatcher, transport, client, &frame);
                frame.deinit(transport.allocator);
                if (!alive) return;
                if (client.read_paused or transport.remote_write != null or client.write != null) return;
            },
        }
    }
}

fn writePooledSshTransportClient(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    const write = if (client.write) |*value| value else return;
    const done = switch (write.*) {
        .frame => |*frame| switch (try frame.frame.writeReady(client.fd)) {
            .blocked, .progress => false,
            .done => true,
        },
        .raw => |*raw| try writePooledSshTransportClientRaw(client.fd, raw),
    };
    if (!done) return;

    var completed = client.write.?;
    client.write = null;
    const kind = completed.kind();
    completed.setKind(.forwarded_from_daemon);
    const completed_raw = switch (completed) {
        .raw => true,
        .frame => false,
    };
    completed.deinit(transport.allocator);
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);

    if (!pooledSshTransportHasClientWrites(transport)) {
        if (completed_raw and client.raw_proxy and client.state != .done) {
            try sendPooledRawProxyAck(daemon_dispatcher, transport, client);
        } else {
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        }
    }
    switch (kind) {
        .forwarded_from_daemon => {},
        .finish_after_write => |finish| {
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, finish.send_hangup);
        },
    }
}

fn writePooledSshTransportClientRaw(
    fd: c.fd_t,
    raw: *PooledSshTransportClientRawWrite,
) !bool {
    while (raw.remaining().len != 0) {
        const chunk = raw.remaining();
        const n = c.write(fd, chunk.ptr, chunk.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return false,
            .INTR => continue,
            else => return error.WriteFailed,
        };
        if (n == 0) return error.WriteFailed;
        const written: usize = @intCast(n);
        io.noteWrite(fd, chunk[0..written]);
        raw.offset += written;
    }
    return true;
}

fn pooledSshTransportHasClientWrites(transport: *const PooledSshTransport) bool {
    for (transport.clients.items) |client| {
        if (client.state != .done and client.write != null) return true;
    }
    return false;
}

fn readPooledRawProxyClient(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    var buf: [raw_proxy_read_buffer_len]u8 = undefined;
    while (true) {
        const n = c.read(client.fd, &buf, buf.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) {
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, true);
            return;
        }

        const bytes = buf[0..@as(usize, @intCast(n))];
        io.noteRead(client.fd, bytes);
        const offset = client.outbound_next_offset;
        const frame_bytes = try encodeMuxFrameBytes(transport.allocator, .{
            .stream_id = client.stream_id,
            .message = .{ .payload = .{
                .offset = offset,
                .item = .{ .proxy = .{ .payload = .{ .data = bytes } } },
            } },
        });
        errdefer transport.allocator.free(frame_bytes);
        client.outbound_next_offset +|= bytes.len;
        client.read_paused = true;
        try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
        try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
        try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, frame_bytes, .{ .client_to_daemon = client });
        return;
    }
}

fn sendPooledRawProxyAck(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    const payload = try encodeDaemonTunnelFramePayload(transport.allocator, .{ .mux_stream = .{
        .stream_id = client.stream_id,
        .message = .{ .ack = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = proxy_stream_window_bytes,
        } },
    } });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .proxy_ack);
}

fn sendPooledRawProxyOpenOk(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    const payload = try encodeDaemonTunnelFramePayload(transport.allocator, .{ .mux_stream = .{
        .stream_id = client.stream_id,
        .message = .{ .open_ok = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = proxy_stream_window_bytes,
        } },
    } });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .proxy_ack);
}

fn startPooledSshTransportClientFrameWrite(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    message_type: protocol.MessageType,
    payload: []const u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    if (client.write != null) return error.PooledSshTransportClientWriteAlreadyQueued;
    var frame = try protocol.FrameWriteState.init(client.transport.allocator, message_type, payload);
    errdefer frame.deinit();
    client.write = .{ .frame = .{ .frame = frame, .kind = kind } };
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
}

fn startPooledSshTransportClientRawWrite(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    bytes: []u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    if (client.write != null) return error.PooledSshTransportClientWriteAlreadyQueued;
    errdefer client.transport.allocator.free(bytes);
    client.write = .{ .raw = .{ .bytes = bytes, .kind = kind } };
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
}

fn startPooledClientConnectionEvent(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    event: pb.ConnectionEvent.event_union,
    kind: PooledSshTransportClientWriteKind,
) !void {
    const payload = try protocol.encodePayload(client.transport.allocator, pb.ClientDaemonItem{
        .payload = .{ .connection_event = .{ .event = event } },
    });
    defer client.transport.allocator.free(payload);
    try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .client_daemon, payload, kind);
}

fn startPooledClientTransportError(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    const payload = try protocol.encodePayload(client.transport.allocator, protocol.hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer client.transport.allocator.free(payload);
    try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .error_message, payload, kind);
}

fn finishPooledClientAfterCurrentWrite(client: *PooledSshTransportClient, send_hangup: bool) bool {
    if (client.write) |*write| {
        write.setKind(.{ .finish_after_write = .{ .send_hangup = send_hangup } });
        return true;
    }
    return false;
}

fn failPooledSshTransportClientWithError(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    code: []const u8,
    message: []const u8,
    hint: []const u8,
    send_hangup: bool,
) bool {
    if (finishPooledClientAfterCurrentWrite(client, send_hangup)) return false;
    startPooledClientTransportError(
        daemon_dispatcher,
        client,
        code,
        message,
        hint,
        .{ .finish_after_write = .{ .send_hangup = send_hangup } },
    ) catch {
        finishPooledSshTransportClient(daemon_dispatcher, transport, client, send_hangup);
    };
    return false;
}

fn encodeDaemonTunnelFramePayload(
    allocator: std.mem.Allocator,
    payload: pb.DaemonTunnelItem.payload_union,
) ![]u8 {
    return protocol.encodePayload(allocator, pb.DaemonTunnelItem{ .payload = payload });
}

fn encodeMuxFrameBytes(
    allocator: std.mem.Allocator,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) ![]u8 {
    const payload = try encodeDaemonTunnelFramePayload(allocator, .{ .mux_stream = mux_frame });
    defer allocator.free(payload);
    return protocol.encodeFrame(allocator, .daemon_tunnel, payload);
}

fn closeIdlePooledSshTransport(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const transport: *PooledSshTransport = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedPooledSshTransportFd,
    }
    transport.idle_timer_id = null;
    if (transport.clients.items.len != 0 or
        transport.pending_cleanup_requests.items.len != 0 or
        transport.cleanup_requests_in_flight != 0 or
        transport.state == .closed) return;
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport idle host={s} pool={s}",
        .{ transport.display_host, transport.key },
    );
    finishPooledSshTransport(daemon_dispatcher, transport);
}

fn activatePendingPooledSshTransportClients(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    if (transport.idle_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        transport.idle_timer_id = null;
    }
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client.state != .pending_transport) {
            index += 1;
            continue;
        }
        client.stream_id = transport.next_stream_id;
        transport.next_stream_id += 1;
        client.state = .opening_stream;
        if (client.raw_proxy) {
            sendPooledRawProxyMuxOpen(daemon_dispatcher, transport, client) catch {
                destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
                continue;
            };
        } else ensurePooledSshTransportClientWatch(daemon_dispatcher, client) catch {
            destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
            continue;
        };
        index += 1;
    }
}

fn schedulePooledSshTransportIdleClose(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    if (transport.state == .closed or
        transport.state == .closing or
        transport.clients.items.len != 0 or
        transport.pending_cleanup_requests.items.len != 0 or
        transport.cleanup_requests_in_flight != 0 or
        transport.remote_write != null or
        transport.idle_timer_id != null) return;
    transport.idle_timer_id = daemon_dispatcher.watchTimerAfter(@intCast(pooled_ssh_transport_idle_close_ms), .{
        .ctx = transport,
        .callback = closeIdlePooledSshTransport,
    }) catch {
        finishPooledSshTransport(daemon_dispatcher, transport);
        return;
    };
}

fn beginClosingPooledSshTransport(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    if (transport.state == .closed or transport.state == .closing) return;
    transport.state = .closing;
    if (transport.remote_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.remote_watch_id = null;
    }
    if (transport.stderr_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stderr_watch_id = null;
    }
    if (transport.stdin_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stdin_watch_id = null;
    }
    if (transport.idle_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        transport.idle_timer_id = null;
    }
    removePooledSshTransport(transport);
}

fn updatePooledSshTransportRemoteReadWatch(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    const watch_id = transport.remote_watch_id orelse return;
    try daemon_dispatcher.updateFdEvents(watch_id, .{
        .readable = !transport.remote_read_paused,
    });
}

fn pausePooledSshTransportRemoteRead(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (transport.remote_read_paused) return;
    transport.remote_read_paused = true;
    try updatePooledSshTransportRemoteReadWatch(daemon_dispatcher, transport);
}

fn resumePooledSshTransportRemoteRead(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (!transport.remote_read_paused) return;
    transport.remote_read_paused = false;
    try updatePooledSshTransportRemoteReadWatch(daemon_dispatcher, transport);
}

fn updatePooledSshTransportClientWatch(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) !void {
    const watch_id = client.watch_id orelse return;
    try daemon_dispatcher.updateFdEvents(watch_id, .{
        .readable = pooledSshTransportClientReadable(client),
        .writable = client.write != null,
    });
}

fn pooledSshTransportClientReadable(client: *const PooledSshTransportClient) bool {
    return !client.read_paused and client.write == null and switch (client.state) {
        .opening_stream, .active => true,
        .pending_transport, .done => false,
    };
}

fn ensurePooledSshTransportClientWatch(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) !void {
    if (client.watch_id) |_| {
        try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
        return;
    }
    client.watch_id = try daemon_dispatcher.watchFd(client.fd, .{
        .readable = pooledSshTransportClientReadable(client),
        .writable = client.write != null,
    }, .{
        .ctx = client,
        .callback = readPooledSshTransportClient,
    });
}

fn pausePooledSshTransportClientReads(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    for (transport.clients.items) |client| {
        if (client.state == .done or client.read_paused) continue;
        client.read_paused = true;
        try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    }
}

fn resumePooledSshTransportClientReads(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    for (transport.clients.items) |client| {
        if (client.state == .done or !client.read_paused) continue;
        client.read_paused = false;
        try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    }
}

fn handlePooledSshTransportClientFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (try handlePooledSshTransportClientControlFrame(daemon_dispatcher, client, frame)) return true;
    return switch (client.state) {
        .opening_stream => try openPooledSshTransportClientStream(daemon_dispatcher, transport, client, frame),
        .active => try forwardPooledSshTransportClientFrame(daemon_dispatcher, transport, client, frame),
        .pending_transport => true,
        .done => false,
    };
}

fn handlePooledSshTransportClientControlFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, client.transport.allocator, frame.payload);
    defer item.deinit(client.transport.allocator);
    switch (item.payload orelse return false) {
        .ping => {
            const pong_payload = try protocol.encodePayload(client.transport.allocator, pb.DaemonTunnelItem{ .payload = .{ .pong = .{} } });
            defer client.transport.allocator.free(pong_payload);
            try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .daemon_tunnel, pong_payload, .forwarded_from_daemon);
            return true;
        },
        .pong => return true,
        else => return false,
    }
}

fn openPooledSshTransportClientStream(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (frame.message_type == .daemon_tunnel) {
        try sendPooledProxyMuxOpen(daemon_dispatcher, transport, client, frame.payload);
        return true;
    }
    if (frame.message_type != .client_remote) {
        return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "expected terminal or proxy stream open", "", false);
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(transport.allocator, frame.payload);
    defer item.deinit(transport.allocator);
    const item_payload = if (item.payload) |*payload| payload else {
        return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "expected terminal stream open", "", false);
    };
    const open = switch (item_payload.*) {
        .open => |*request| request,
        else => {
            return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "expected terminal stream open", "", false);
        },
    };
    client.kind = .te;
    try appendFilteredClientEnvironmentToTerminalOpen(transport.allocator, client, open);
    try sendPooledTerminalMuxOpen(daemon_dispatcher, transport, client, open.*);
    return true;
}

fn forwardPooledSshTransportClientFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    frame: *const protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .daemon_tunnel => {
            if (client.kind != .proxy) {
                return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "unexpected proxy stream frame", "", true);
            }
            try sendPooledProxyMuxFrame(daemon_dispatcher, transport, client, frame.payload);
        },
        .client_remote => {
            if (client.kind != .te) {
                return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "unexpected terminal stream frame", "", true);
            }
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(transport.allocator, frame.payload);
            defer item.deinit(transport.allocator);
            try sendPooledTerminalMuxPayload(daemon_dispatcher, transport, client, item);
        },
        .client_daemon => {
            if (client.kind != .proxy or client.proxy_guid_len == 0) {
                return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "unexpected proxy control frame", "", true);
            }
            try forwardProxyControlFromStream(transport.allocator, client.proxyGuidSlice(), frame.*);
        },
        else => {
            return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "unexpected terminal client frame", "", true);
        },
    }
    return true;
}

fn appendFilteredClientEnvironmentToTerminalOpen(
    allocator: std.mem.Allocator,
    client: *const PooledSshTransportClient,
    open: *pb.TerminalEmulatorItem.Open,
) !void {
    if (open.create) |*create| {
        for (client.client_environment.items) |entry| {
            // SessionCreate uses SHELL as the remote runtime's login-shell
            // convention. OpenSSH SendEnv must not let the visible client's
            // SHELL choose the remote PTY child shell.
            if (std.mem.eql(u8, entry.name, "SHELL")) continue;
            if (!sendEnvAllowsName(client.send_env, entry.name)) continue;
            if (terminalCreateHasEnvironmentName(create, entry.name)) continue;
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, entry.value);
            errdefer allocator.free(value);
            try create.environment.append(allocator, .{
                .name = name,
                .value = value,
            });
        }
    }
}

fn terminalCreateHasEnvironmentName(
    create: *const pb.TerminalEmulatorItem.SessionCreate,
    name: []const u8,
) bool {
    for (create.environment.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn sendEnvAllowsName(patterns: []const []const u8, name: []const u8) bool {
    var allowed = false;
    for (patterns) |pattern| {
        if (pattern.len == 0) continue;
        const negated = pattern[0] == '-';
        const raw_pattern = if (negated) pattern[1..] else pattern;
        if (raw_pattern.len == 0) continue;
        if (sendEnvPatternMatches(raw_pattern, name)) allowed = !negated;
    }
    return allowed;
}

fn sendEnvPatternMatches(pattern: []const u8, name: []const u8) bool {
    return sendEnvPatternMatchesFrom(pattern, 0, name, 0);
}

fn sendEnvPatternMatchesFrom(pattern: []const u8, pattern_index: usize, name: []const u8, name_index: usize) bool {
    if (pattern_index == pattern.len) return name_index == name.len;
    const char = pattern[pattern_index];
    if (char == '*') {
        var index = name_index;
        while (index <= name.len) : (index += 1) {
            if (sendEnvPatternMatchesFrom(pattern, pattern_index + 1, name, index)) return true;
        }
        return false;
    }
    if (name_index == name.len) return false;
    if (char == '?' or char == name[name_index]) {
        return sendEnvPatternMatchesFrom(pattern, pattern_index + 1, name, name_index + 1);
    }
    return false;
}

fn sendPooledTerminalMuxOpen(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    request: pb.TerminalEmulatorItem.Open,
) !void {
    const typed_open_bytes = try encodeMuxFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .terminal_emulator = .{ .payload = .{ .open = request } } },
        } },
    });
    errdefer transport.allocator.free(typed_open_bytes);
    const envelope_bytes = try encodeMuxFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .open = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = 0,
        } },
    });
    errdefer transport.allocator.free(envelope_bytes);
    client.read_paused = true;
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, envelope_bytes, .{ .client_mux_open_envelope = .{
        .client = client,
        .typed_open_bytes = typed_open_bytes,
    } });
    client.outbound_next_offset +|= 1;
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledProxyMuxOpen(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    payload: []const u8,
) !void {
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(transport.allocator, payload);
    defer mux_frame.deinit(transport.allocator);
    const message = mux_frame.message orelse return error.UnexpectedDaemonFrame;
    const open = switch (message) {
        .open => |open| open,
        else => return error.UnexpectedDaemonFrame,
    };
    _ = open;
    client.kind = .proxy;
    client.local_stream_id = mux_frame.stream_id;
    mux_frame.stream_id = client.stream_id;
    const bytes = try encodeMuxFrameBytes(transport.allocator, mux_frame);
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, bytes, .{ .client_to_daemon = client });
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledRawProxyMuxOpen(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    const proxy_host = client.raw_proxy_host orelse return error.MissingProxyHost;
    const typed_open_bytes = try encodeMuxFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .proxy = .{ .payload = .{ .open = .{
                .proxy_guid = client.proxyGuidSlice(),
                .proxy_host = proxy_host,
                .proxy_port = client.raw_proxy_port,
            } } } },
        } },
    });
    errdefer transport.allocator.free(typed_open_bytes);
    const envelope_bytes = try encodeMuxFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .open = .{
            .recv_next_offset = client.inbound_next_offset,
            .receive_window_bytes = proxy_stream_window_bytes,
        } },
    });
    errdefer transport.allocator.free(envelope_bytes);
    client.read_paused = true;
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, envelope_bytes, .{ .client_mux_open_envelope = .{
        .client = client,
        .typed_open_bytes = typed_open_bytes,
    } });
    client.mux_open_sent_ms = nowUnixMs();
}

fn sendPooledProxyMuxFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    payload: []const u8,
) !void {
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(transport.allocator, payload);
    defer mux_frame.deinit(transport.allocator);
    if (mux_frame.stream_id != client.local_stream_id) return error.UnexpectedDaemonFrame;
    try maybeRegisterProxyControlStream(transport.allocator, client, mux_frame);
    mux_frame.stream_id = client.stream_id;
    const bytes = try encodeMuxFrameBytes(transport.allocator, mux_frame);
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, bytes, .{ .client_to_daemon = client });
}

fn maybeRegisterProxyControlStream(
    allocator: std.mem.Allocator,
    client: *PooledSshTransportClient,
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

fn sendPooledTerminalMuxPayload(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    item: pb.TerminalEmulatorItem,
) !void {
    const bytes = try encodeMuxFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .terminal_emulator = item },
        } },
    });
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, bytes, .{ .client_to_daemon = client });
    client.outbound_next_offset +|= 1;
}

fn handlePooledRemoteFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    frame: protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return error.UnexpectedDaemonFrame;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, transport.allocator, frame.payload);
    defer item.deinit(transport.allocator);
    const payload = item.payload orelse return error.UnexpectedDaemonFrame;
    switch (payload) {
        .remote_process_started => |started| {
            try handlePooledRemoteProcessStarted(daemon_dispatcher, transport, started);
            return true;
        },
        .remote_process_cleanup_response => |response| {
            if (transport.cleanup_requests_in_flight != 0) transport.cleanup_requests_in_flight -= 1;
            daemon_cleanup.handleRemoteProcessCleanupResponse(transport.allocator, response);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
            return true;
        },
        .mux_stream => |mux| {
            item.payload = null;
            return handlePooledRemoteMuxStreamFrame(daemon_dispatcher, transport, mux);
        },
        .ping => {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            const pong_payload = try protocol.encodePayload(transport.allocator, pb.DaemonTunnelItem{ .payload = .{ .pong = .{} } });
            defer transport.allocator.free(pong_payload);
            try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, pong_payload, .pong);
            return true;
        },
        .pong => return true,
        else => {
            daemon_log.infof(
                transport.allocator,
                "unexpected daemon tunnel payload host={s} payload={s}",
                .{ transport.display_host, @tagName(std.meta.activeTag(payload)) },
            );
            return error.UnexpectedDaemonFrame;
        },
    }
}

fn handlePooledTransportControlFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, transport.allocator, frame.payload);
    defer item.deinit(transport.allocator);
    switch (item.payload orelse return false) {
        .ping => {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            const pong_payload = try protocol.encodePayload(transport.allocator, pb.DaemonTunnelItem{ .payload = .{ .pong = .{} } });
            defer transport.allocator.free(pong_payload);
            try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, pong_payload, .pong);
            return true;
        },
        .pong => return true,
        else => return false,
    }
}

fn handlePooledRemoteMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !bool {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(transport.allocator);
    const client = findPooledSshTransportClient(transport, owned_mux_frame.stream_id) orelse return true;
    const message = owned_mux_frame.message orelse return error.UnexpectedDaemonFrame;
    if (client.kind == .proxy) {
        if (client.raw_proxy) {
            return handlePooledRemoteRawProxyMuxStreamFrame(daemon_dispatcher, transport, client, message);
        }
        switch (message) {
            .open_ok => {
                if (client.mux_open_ok_ms == 0) client.mux_open_ok_ms = nowUnixMs();
            },
            .payload => {
                if (client.first_payload_ms == 0) {
                    client.first_payload_ms = nowUnixMs();
                    logPooledSshTransportClientStartupTiming(transport, client);
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
        try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        const payload = try encodeDaemonTunnelFramePayload(transport.allocator, .{ .mux_stream = owned_mux_frame });
        defer transport.allocator.free(payload);
        try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .daemon_tunnel, payload, .forwarded_from_daemon);
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
                logPooledSshTransportClientStartupTiming(transport, client);
            }
            const item = payload.item orelse return error.UnexpectedDaemonFrame;
            const te_item = switch (item) {
                .terminal_emulator => |terminal_emulator| terminal_emulator,
                else => return error.UnexpectedDaemonFrame,
            };
            client.inbound_next_offset = @max(client.inbound_next_offset, payload.offset +| 1);
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            const client_payload = try protocol.encodePayload(transport.allocator, pb.ClientRemoteItem{ .payload = .{ .terminal_emulator = te_item } });
            defer transport.allocator.free(client_payload);
            try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .client_remote, client_payload, .forwarded_from_daemon);
            const te_payload = te_item.payload orelse return true;
            if (te_payload == .session_ended) {
                client.session_ended = true;
            }
        },
        .reset => |reset| {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startPooledClientTransportError(
                daemon_dispatcher,
                client,
                reset.code,
                reset.message,
                reset.hint orelse "",
                .{ .finish_after_write = .{ .send_hangup = false } },
            );
        },
        .eof => {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledSshTransportClientStartupTiming(transport, client);
            }
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
        },
        .open => return error.UnexpectedDaemonFrame,
    }
    return true;
}

fn handlePooledRemoteRawProxyMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    message: pb.DaemonTunnelItem.MuxStreamFrame.message_union,
) !bool {
    switch (message) {
        .open_ok => {
            if (client.mux_open_ok_ms == 0) client.mux_open_ok_ms = nowUnixMs();
        },
        .ack => {},
        .payload => |payload| {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledSshTransportClientStartupTiming(transport, client);
            }
            const item = payload.item orelse {
                daemon_log.infof(transport.allocator, "raw proxy mux payload missing item host={s} stream_id={}", .{ transport.display_host, client.stream_id });
                return error.UnexpectedDaemonFrame;
            };
            const proxy_item = switch (item) {
                .proxy => |proxy| proxy,
                else => {
                    daemon_log.infof(transport.allocator, "raw proxy mux payload has non-proxy item host={s} stream_id={}", .{ transport.display_host, client.stream_id });
                    return error.UnexpectedDaemonFrame;
                },
            };
            const proxy_payload = proxy_item.payload orelse {
                daemon_log.infof(transport.allocator, "raw proxy mux payload missing proxy payload host={s} stream_id={}", .{ transport.display_host, client.stream_id });
                return error.UnexpectedDaemonFrame;
            };
            const data = switch (proxy_payload) {
                .data => |bytes| bytes,
                else => {
                    daemon_log.infof(
                        transport.allocator,
                        "raw proxy mux payload has non-data proxy item host={s} stream_id={} item={s}",
                        .{ transport.display_host, client.stream_id, @tagName(std.meta.activeTag(proxy_payload)) },
                    );
                    return error.UnexpectedDaemonFrame;
                },
            };

            var new_data = data;
            if (payload.offset < client.inbound_next_offset) {
                const already_received: usize = @intCast(client.inbound_next_offset - payload.offset);
                if (already_received >= data.len) {
                    try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
                    try sendPooledRawProxyAck(daemon_dispatcher, transport, client);
                    return true;
                }
                new_data = data[already_received..];
            } else if (payload.offset > client.inbound_next_offset) {
                return error.StreamOffsetGap;
            }

            const owned_data = try transport.allocator.dupe(u8, new_data);
            errdefer transport.allocator.free(owned_data);
            client.inbound_next_offset +|= new_data.len;
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startPooledSshTransportClientRawWrite(daemon_dispatcher, client, owned_data, .forwarded_from_daemon);
        },
        .reset => {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledSshTransportClientStartupTiming(transport, client);
            }
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
        },
        .eof => {
            if (client.first_payload_ms == 0) {
                client.first_payload_ms = nowUnixMs();
                logPooledSshTransportClientStartupTiming(transport, client);
            }
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
        },
        .open => {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try sendPooledRawProxyOpenOk(daemon_dispatcher, transport, client);
        },
    }
    return true;
}

fn handlePooledRemoteProcessStarted(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    started: pb.DaemonTunnelItem.RemoteProcessStarted,
) !void {
    const process = started.process orelse return error.UnexpectedDaemonFrame;
    const client = findPooledSshTransportClient(transport, started.stream_id) orelse return;
    if (client.remote_cleanup) |*existing| existing.deinit(transport.allocator);
    client.remote_cleanup = try RemoteCleanupIdentity.fromProto(transport.allocator, process);
    if (client.local_pid == 0 or client.local_start_time == null) {
        daemon_log.infof(
            transport.allocator,
            "cleanup record skipped host={s} guid={s} reason=missing-local-process-identity",
            .{ transport.display_host, process.guid },
        );
        return;
    }
    daemon_cleanup.recordRemoteProcessStarted(transport.allocator, .{
        .pid = client.local_pid,
        .start_time = client.local_start_time.?,
    }, .{
        .user = transport.resolved_user,
        .host = transport.resolved_host,
        .port = transport.resolved_port,
    }, process) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "cleanup record failed host={s} guid={s} error={t}",
            .{ transport.display_host, process.guid, err },
        );
        return;
    };
    try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
    const payload = try encodeDaemonTunnelFramePayload(transport.allocator, .{ .remote_process_recorded = .{
        .stream_id = started.stream_id,
    } });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .remote_process_recorded);
    daemon_log.infof(
        transport.allocator,
        "cleanup record stored host={s} guid={s}",
        .{ transport.display_host, process.guid },
    );
}

fn startPooledRemoteProcessCleanupRequest(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    remote: RemoteCleanupIdentity,
) !void {
    const payload = try encodeDaemonTunnelFramePayload(transport.allocator, .{
        .remote_process_cleanup_request = .{ .process = remote.toProto() },
    });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .cleanup_request);
    transport.cleanup_requests_in_flight += 1;
}

fn startNextPendingCleanupRequest(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (transport.state != .ready) return;
    if (transport.remote_write != null) return;
    if (transport.pending_cleanup_requests.items.len == 0) {
        if (transport.cleanup_requests_in_flight != 0) return;
        schedulePooledSshTransportIdleClose(daemon_dispatcher, transport);
        return;
    }
    var request = transport.pending_cleanup_requests.orderedRemove(0);
    defer request.deinit(transport.allocator);
    daemon_log.infof(
        transport.allocator,
        "cleanup record queued remote cleanup host={s} guid={s}",
        .{ transport.display_host, request.remote.guid },
    );
    try startPooledRemoteProcessCleanupRequest(daemon_dispatcher, transport, request.remote);
}

fn findPooledSshTransportClient(transport: *PooledSshTransport, stream_id: u64) ?*PooledSshTransportClient {
    for (transport.clients.items) |client| {
        if (client.stream_id == stream_id and client.state != .done) return client;
    }
    return null;
}

fn finishPooledSshTransportClient(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    send_hangup: bool,
) void {
    if (client.kind == .proxy) unregisterProxyControlStream(client.fd);
    if (send_hangup and client.state == .active and transport.state != .closing and transport.state != .closed) {
        if (!client.session_ended) {
            if (client.remote_cleanup) |remote| {
                daemon_log.infof(
                    transport.allocator,
                    "client disconnected; requesting remote cleanup host={s} guid={s}",
                    .{ transport.display_host, remote.guid },
                );
                startPooledRemoteProcessCleanupRequest(daemon_dispatcher, transport, remote) catch |err| {
                    daemon_log.infof(
                        transport.allocator,
                        "client disconnect remote cleanup request deferred to sweep host={s} guid={s} error={t}",
                        .{ transport.display_host, remote.guid, err },
                    );
                };
            } else {
                daemon_log.infof(
                    transport.allocator,
                    "client disconnected before cleanup identity was recorded host={s}",
                    .{transport.display_host},
                );
            }
        }
    }
    destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
    if (transport.state == .closing) {
        if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
        return;
    }
    schedulePooledSshTransportIdleClose(daemon_dispatcher, transport);
}

fn notifyPooledSshTransportRemoteClosed(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    daemon_log.infof(transport.allocator, "ssh transport disconnected from daemon host={s}", .{transport.display_host});
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client.raw_proxy) {
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
            continue;
        }
        if (finishPooledClientAfterCurrentWrite(client, false)) {
            index += 1;
            continue;
        }
        startPooledClientConnectionEvent(
            daemon_dispatcher,
            client,
            .{ .daemon_disconnected = .{} },
            .{ .finish_after_write = .{ .send_hangup = false } },
        ) catch {
            destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
            continue;
        };
        index += 1;
    }
    if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
}

fn forwardPooledSshTransportStderr(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(transport.stderr_fd, &buf, buf.len);
        if (n < 0) {
            const errno = std.posix.errno(n);
            if (errno == .AGAIN) return;
            return error.ReadFailed;
        }
        if (n == 0) return;
        const bytes = buf[0..@intCast(n)];
        var started_write = false;
        for (transport.clients.items) |client| {
            if (client.state == .done) continue;
            if (client.raw_proxy) continue;
            if (client.write != null) continue;
            try startPooledClientConnectionEvent(daemon_dispatcher, client, .{ .ssh_stderr = .{ .data = bytes } }, .forwarded_from_daemon);
            started_write = true;
        }
        if (started_write) try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        if (@as(usize, @intCast(n)) < buf.len) return;
    }
}

fn finishPooledSshTransport(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    if (transport.state == .closed) return;
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport closed host={s} pool={s}",
        .{ transport.display_host, transport.key },
    );
    transport.state = .closed;
    if (transport.remote_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.remote_watch_id = null;
    }
    if (transport.stderr_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stderr_watch_id = null;
    }
    if (transport.stdin_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stdin_watch_id = null;
    }
    if (transport.idle_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        transport.idle_timer_id = null;
    }
    removePooledSshTransport(transport);
    while (transport.clients.items.len > 0) {
        const client = transport.clients.items[0];
        destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
    }
    active_pooled_ssh_transports -= 1;
    transport.deinit();
    transport.allocator.destroy(transport);
}

fn destroyPooledSshTransportClient(
    daemon_dispatcher: ?*dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) void {
    if (client.done) return;
    logPooledSshTransportClientStartupTiming(transport, client);
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport client finished host={s} pool={s} stream_id={}",
        .{ transport.display_host, transport.key, client.stream_id },
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
    while (index < transport.clients.items.len) : (index += 1) {
        if (transport.clients.items[index] != client) continue;
        _ = transport.clients.swapRemove(index);
        break;
    }
    if (client.fd >= 0) {
        _ = c.close(client.fd);
        client.fd = -1;
    }
    client.deinit(transport.allocator);
    transport.allocator.destroy(client);
}

fn logPooledSshTransportClientStartupTiming(transport: *PooledSshTransport, client: *PooledSshTransportClient) void {
    if (client.startup_timing_logged) return;
    client.startup_timing_logged = true;
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport client startup host={s} pool={s} stream_id={} kind={s} request_to_open_ms={} open_to_open_ok_ms={} open_ok_to_first_payload_ms={} request_to_first_payload_ms={}",
        .{
            transport.display_host,
            transport.key,
            client.stream_id,
            pooledSshTransportClientKindName(client.kind),
            elapsedMs(client.request_started_ms, client.mux_open_sent_ms),
            elapsedMs(client.mux_open_sent_ms, client.mux_open_ok_ms),
            elapsedMs(client.mux_open_ok_ms, client.first_payload_ms),
            elapsedMs(client.request_started_ms, client.first_payload_ms),
        },
    );
}

fn pooledSshTransportClientKindName(kind: PooledSshTransportClientKind) []const u8 {
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

fn removePooledSshTransport(transport: *PooledSshTransport) void {
    var index: usize = 0;
    while (index < pooled_ssh_transports.items.len) : (index += 1) {
        if (pooled_ssh_transports.items[index] != transport) continue;
        _ = pooled_ssh_transports.swapRemove(index);
        break;
    }
}

// BLOCKING_FRAME_READ: test-only helper. Production SSH transport paths keep
// persistent FrameReader state in their dispatcher-owned connection objects.
fn readFrameForTest(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked => return error.WouldBlock,
            .progress => continue,
            .frame => |frame| return frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
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
    };
    defer request.ssh_option.deinit(allocator);
    defer deinitSshTransportAcquireOwnedFields(allocator, &request);
    try request.ssh_option.appendSlice(allocator, target.options);
    try appendCurrentSshAgentToSshTransportAcquire(allocator, &request);
    try appendCurrentProcessToSshTransportAcquire(allocator, &request);
    try appendCurrentEnvironmentToSshTransportAcquire(allocator, &request);

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

fn startPooledClientSshFailure(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    target: SshTarget,
    term: ?std.process.Child.Term,
) !bool {
    const value = term orelse return false;
    switch (value) {
        .Exited => |code| {
            if (code == 0) return false;
            const message = try visibleSshFailureMessage(client.transport.allocator, target, "exitcode", code);
            defer client.transport.allocator.free(message);
            var code_buf: [64]u8 = undefined;
            const error_code = try std.fmt.bufPrint(&code_buf, "SSH_TRANSPORT_EXITED_{}", .{@min(code, 255)});
            try startPooledClientTransportError(
                daemon_dispatcher,
                client,
                error_code,
                message,
                "",
                .{ .finish_after_write = .{ .send_hangup = false } },
            );
            return true;
        },
        .Signal => |signal| {
            const message = try visibleSshFailureMessage(client.transport.allocator, target, "signal", signal);
            defer client.transport.allocator.free(message);
            try startPooledClientTransportError(
                daemon_dispatcher,
                client,
                "SSH_TRANSPORT_EXITED_255",
                message,
                "",
                .{ .finish_after_write = .{ .send_hangup = false } },
            );
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

fn appendParentProcessToSshTransportAcquire(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    const parent_pid = c.getppid();
    if (parent_pid <= 0) return error.ProcessStartTimeUnavailable;
    request.local_pid = @intCast(parent_pid);
    request.local_start_time = try daemon_identity.processStartTime(allocator, request.local_pid);
}

fn appendCurrentEnvironmentToSshTransportAcquire(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) !void {
    var index: usize = 0;
    while (c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        const name = try allocator.dupe(u8, entry[0..equals]);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry[equals + 1 ..]);
        errdefer allocator.free(value);
        try request.client_environment.append(allocator, .{
            .name = name,
            .value = value,
        });
    }
}

fn deinitSshTransportAcquireOwnedFields(
    allocator: std.mem.Allocator,
    request: *pb.ClientDaemonItem.SshTransportAcquire,
) void {
    if (request.ssh_auth_sock) |path| allocator.free(path);
    request.ssh_auth_sock = null;
    if (request.local_start_time.len != 0) allocator.free(request.local_start_time);
    request.local_start_time = "";
    for (request.client_environment.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    request.client_environment.deinit(allocator);
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
            try io.stderrPrint("sessh: ssh remote attach failed: {t}\n", .{err});
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
            runtime_config.common,
            runtime_config.daemon_dir_name,
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

fn waitAfterRuntimeAttachFailure(transport: *TerminalTransport, stage: []const u8) void {
    transport.closeStdin();
    transport.close();
    client_log.flush(2);
    io.stderrPrint("sessh: ssh remote transport closed after attach {s} failure\n", .{stage}) catch {};
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
        .unhygienic => .none,
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
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
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

fn readBootstrapLineWithSshStderr(
    allocator: std.mem.Allocator,
    stdout_fd: c.fd_t,
    stderr_fd: c.fd_t,
    client_fd: c.fd_t,
    reconnect_ui: ?*client_ui.ReconnectUi,
    poll_reconnect_input: bool,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    var stderr_open = stderr_fd >= 0;

    while (line.items.len < 4096) {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = stdout_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = if (stderr_open) stderr_fd else -1,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = try posix.poll(&pollfds, if (reconnect_ui == null) -1 else 50);
        if (reconnect_ui) |ui| {
            if (try reconnectShouldCancelForBootstrap(ui, poll_reconnect_input)) return error.ReconnectCancelled;
        }
        if (ready == 0) continue;

        if (stderr_open and pollfds[1].revents != 0) {
            stderr_open = try forwardSshStderrFromFd(stderr_fd, client_fd);
        }

        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[0].revents & posix.POLL.IN) == 0)
        {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) continue;

        var byte: [1]u8 = undefined;
        const n = c.read(stdout_fd, &byte, 1);
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

fn reconnectShouldCancelForBootstrap(reconnect_ui: *client_ui.ReconnectUi, poll_reconnect_input: bool) !bool {
    if (!poll_reconnect_input) return reconnect_ui.isCancelled();
    return reconnect_ui.pollClientHangup(0);
}

fn forwardSshStderrFromFd(fd: c.fd_t, client_fd: c.fd_t) !bool {
    if (fd < 0) return false;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return true,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return false;
        if (client_fd >= 0) {
            sendSshTransportDiagnostic(client_fd, buf[0..@intCast(n)]) catch {};
        }
    }
}

fn sendSshTransportDiagnostic(fd: c.fd_t, chunk: []const u8) !void {
    try protocol.sendSshTransportStderrFrame(app_allocator.allocator(), fd, chunk);
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
    bootstrap_status_client_fd: c.fd_t,
    env_map: ?*const std.process.EnvMap,
    bootstrap_failure_term: ?*?std.process.Child.Term,
    failure_policy: BootstrapFailurePolicy,
) !RuntimeConnection {
    if (bootstrap_failure_term) |term| term.* = null;
    var connection = try spawnSshRuntimeConnection(allocator, target, remote_command, env_map, artifacts != null);
    errdefer connection.terminate();

    var connection_returned = false;
    defer if (!connection_returned) connection.closeStderr();

    const artifact_set = artifacts orelse {
        daemon_log.infof(allocator, "bootstrap skipped host={s} reason=disabled", .{target.host});
        connection_returned = true;
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

    var line = readBootstrapLineWithSshStderr(allocator, connection.child.stdout.?.handle, connection.stderr_fd, bootstrap_status_client_fd, reconnect_ui, poll_reconnect_input) catch |err| {
        connection.closeStdin();
        if (err == error.ReconnectCancelled) {
            connection.terminate();
            return err;
        }
        const term = connection.wait() catch null;
        if (bootstrap_failure_term) |term_out| term_out.* = term;
        _ = forwardSshStderrFromFd(connection.stderr_fd, bootstrap_status_client_fd) catch {};
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
        line = readBootstrapLineWithSshStderr(allocator, connection.child.stdout.?.handle, connection.stderr_fd, bootstrap_status_client_fd, reconnect_ui, poll_reconnect_input) catch |err| {
            connection.closeStdin();
            if (err == error.ReconnectCancelled) {
                connection.terminate();
                return err;
            }
            const term = connection.wait() catch null;
            if (bootstrap_failure_term) |term_out| term_out.* = term;
            _ = forwardSshStderrFromFd(connection.stderr_fd, bootstrap_status_client_fd) catch {};
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
        connection_returned = true;
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

fn spawnSshRuntimeConnection(
    allocator: std.mem.Allocator,
    target: SshTarget,
    remote_command: []const u8,
    env_map: ?*const std.process.EnvMap,
    bootstrap: bool,
) !RuntimeConnection {
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
    daemon_log.infof(allocator, "ssh transport starting host={s} bootstrap={}", .{ target.host, bootstrap });

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = env_map;
    try child.spawn();
    daemon_log.infof(allocator, "ssh transport started host={s}", .{target.host});
    var connection = RuntimeConnection{ .child = child };
    errdefer connection.terminate();
    const stderr_file = connection.child.stderr.?;
    connection.child.stderr = null;
    connection.stderr_fd = stderr_file.handle;
    try setNonBlockingFd(connection.stderr_fd);
    return connection;
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
    daemon_dir_name: ?[]const u8,
) !c.fd_t {
    const fd = if (daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(allocator, exe);
    errdefer _ = c.close(fd);
    try protocol.sendClientDaemonPayloadFrame(allocator, fd, .{ .proxy_control_open = .{
        .proxy_guid = guid,
    } });
    return fd;
}

fn proxyStreamReconnectStatusMode(level: config.FilterLevel, has_daemon_control: bool) stream_runtime.StreamReconnectStatusMode {
    return switch (level) {
        .unhygienic => .disabled,
        .hygienic, .emulated => if (has_daemon_control) .client_control else .stderr_plain,
    };
}

fn filterLevelForcesProxy(level: config.FilterLevel) bool {
    return switch (level) {
        .unhygienic, .hygienic => true,
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
    const remote_command_args: []const []const u8 = if (hasRemoteShellCommand(new.shell_command_args))
        new.shell_command_args
    else
        &.{};
    const use_fd_pass = common.isolation_mode == .none;
    const diagnostics_plan = if (use_fd_pass) ProxyDiagnosticsPlan{
        .command_level = .unhygienic,
        .use_daemon_control = false,
        .wrap_visible_ssh = false,
        .client_ctrl_r = false,
    } else proxyDiagnosticsPlan(
        target.options,
        common.filter_level,
        new.tty_request,
        remote_command_args,
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
            daemon_dir_name,
        );
    }
    const proxy_daemon_dir_name = daemon_dir_name orelse try daemon_socket_namespace.defaultDirName(allocator);
    defer if (daemon_dir_name == null) allocator.free(proxy_daemon_dir_name);
    try daemon_client.ensureStartedForDirName(allocator, exe, proxy_daemon_dir_name);
    var runtime_executables = try daemon_executable.runtimeExecutablePaths(allocator, proxy_daemon_dir_name);
    defer runtime_executables.deinit();

    const proxy_command_option = try proxyCommandOption(
        allocator,
        runtime_executables.proxy,
        target.options,
        control_guid,
        diagnostics_plan.command_level,
        diagnostics_plan.client_ctrl_r,
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
        .unhygienic => .{
            .command_level = .unhygienic,
            .use_daemon_control = false,
            .wrap_visible_ssh = false,
            .client_ctrl_r = false,
        },
        .hygienic, .emulated => blk: {
            if (!stdin_is_tty or !stdout_is_tty) break :blk .{
                .command_level = .unhygienic,
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
    daemon_dir_name: ?[]const u8,
    use_fd_pass: bool,
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
    if (use_fd_pass) try appendShellToken(allocator, &command, "--use-fd-pass");
    try appendShellToken(allocator, &command, if (bootstrap) "--bootstrap" else "--no-bootstrap");
    if (daemon_dir_name) |dir_name| {
        try appendShellToken(allocator, &command, "--daemon-namespace");
        try appendShellToken(allocator, &command, dir_name);
    }
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
    daemon_dir_name: ?[]const u8 = null,
    control_guid: ?[]const u8 = null,
    filter_level: config.FilterLevel = .unhygienic,
    client_ctrl_r: bool = false,
    bootstrap: bool = true,
    use_fd_pass: bool = false,
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

fn runProxyStreamFdPass(
    allocator: std.mem.Allocator,
    exe: []const u8,
    invocation: ProxyStreamInvocation,
    stream_target: SshTarget,
    proxy_guid: []const u8,
    proxy_port: u16,
) !void {
    const daemon_fd = if (invocation.daemon_dir_name) |dir_name|
        try daemon_client.connectOrStartForDirName(allocator, exe, dir_name)
    else
        try daemon_client.connectOrStart(allocator, exe);
    defer _ = c.close(daemon_fd);

    var raw_pair: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw_pair) != 0) return error.SocketPairFailed;
    var daemon_raw_fd: c.fd_t = raw_pair[0];
    var ssh_raw_fd: c.fd_t = raw_pair[1];
    defer {
        if (daemon_raw_fd >= 0) _ = c.close(daemon_raw_fd);
    }
    defer {
        if (ssh_raw_fd >= 0) _ = c.close(ssh_raw_fd);
    }

    var transport = pb.ClientDaemonItem.SshTransportAcquire{
        .host = stream_target.host,
        .bootstrap = invocation.bootstrap,
    };
    defer transport.ssh_option.deinit(allocator);
    defer deinitSshTransportAcquireOwnedFields(allocator, &transport);
    try transport.ssh_option.appendSlice(allocator, stream_target.options);
    try appendCurrentSshAgentToSshTransportAcquire(allocator, &transport);
    try appendParentProcessToSshTransportAcquire(allocator, &transport);

    const payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{ .payload = .{ .proxy_fd_pass_open = .{
        .transport = transport,
        .proxy = .{
            .proxy_guid = proxy_guid,
            .proxy_host = "localhost",
            .proxy_port = proxy_port,
        },
    } } });
    defer allocator.free(payload);

    const daemon_fd_to_pass = daemon_raw_fd;
    daemon_raw_fd = -1;
    try protocol.sendFrameWithScmRightsFd(allocator, daemon_fd, .client_daemon, payload, daemon_fd_to_pass);

    try waitProxyFdPassAccepted(allocator, daemon_fd);

    const ssh_fd_to_pass = ssh_raw_fd;
    ssh_raw_fd = -1;
    try sendRawFdMessageImmediate(posix.STDOUT_FILENO, "sessh-proxy-fd", ssh_fd_to_pass);
}

fn sendRawFdMessageImmediate(sock_fd: c.fd_t, bytes: []const u8, passed_fd: c.fd_t) !void {
    var progress = fd_passing.SendBufferWithFdProgress.init(bytes, passed_fd);
    defer progress.deinit();
    while (true) {
        switch (try fd_passing.sendBufferWithFdProgress(sock_fd, &progress)) {
            .complete => return,
            .progress => continue,
            .blocked => return error.WouldBlock,
            .eof => unreachable,
        }
    }
}

fn waitProxyFdPassAccepted(allocator: std.mem.Allocator, daemon_fd: c.fd_t) !void {
    var reader = protocol.FrameReader.init(allocator);
    defer reader.deinit();
    var frame = while (true) {
        // BLOCKING_FRAME_READ: `sessh-proxy` is a short-lived foreground
        // helper. It must not hand OpenSSH the raw fd until sesshd has accepted
        // the peer fd, so this synchronous wait is the command's work.
        switch (try reader.readBlocking(daemon_fd)) {
            .blocked, .progress => continue,
            .frame => |frame| break frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    };
    defer frame.deinit(allocator);
    switch (frame.message_type) {
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
            defer item.deinit(allocator);
            switch (item.payload orelse return error.UnexpectedDaemonFrame) {
                .proxy_fd_pass_accepted => return,
                else => return error.UnexpectedDaemonFrame,
            }
        },
        .error_message => {
            var message = try protocol.decodePayload(protocol.hpb.Error, allocator, frame.payload);
            defer message.deinit(allocator);
            try io.stderrPrint("sessh-proxy: daemon rejected fd-pass proxy: {s}\n", .{message.message});
            return error.ProxyFdPassRejected;
        },
        else => return error.UnexpectedDaemonFrame,
    }
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
        } else if (std.mem.eql(u8, arg, "--daemon-namespace")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingDaemonNamespace;
            try daemon_socket_namespace.validateDirName(args[i]);
            invocation.daemon_dir_name = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--filter-level")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingFilterLevel;
            invocation.filter_level = try config.parseFilterLevel(args[i]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--use-fd-pass")) {
            invocation.use_fd_pass = true;
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
        error.MissingDaemonNamespace => try io.writeAll(2, "sessh: :internal-proxy-stream: --daemon-namespace requires a value\n"),
        error.InvalidDaemonSocketDir => try io.writeAll(2, "sessh: :internal-proxy-stream: invalid daemon namespace\n"),
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
        error.MissingFilterLevel => try io.writeAll(2, "sessh: --filter-level requires one of: unhygienic, hygienic, emulated\n"),
        error.MissingIsolationMode => try io.writeAll(2, "sessh: --isolation-mode requires one of: connection, daemon, none\n"),
        error.MissingTtyTranscriptPath => try io.writeAll(2, "sessh: --capture-tty-transcript requires a path\n"),
        error.MissingSshOptionValue => try io.writeAll(2, "sessh: ssh option is missing its value\n"),
        error.SesshOptionAfterHost => try io.writeAll(2, "sessh: sessh options must appear before HOST\n"),
        error.ConflictingSesshAction => try io.writeAll(2, "sessh: conflicting sessh actions\n"),
        error.InvalidScrollbackRowCount => try io.writeAll(2, "sessh: invalid scrollback row count\n"),
        error.InvalidClientLogLevel => try io.writeAll(2, "sessh: invalid log level\n"),
        error.InvalidFilterLevel => try io.writeAll(2, "sessh: invalid filter level; expected one of: unhygienic, hygienic, emulated\n"),
        error.InvalidIsolationMode => try io.writeAll(2, "sessh: invalid isolation mode; expected one of: connection, daemon, none\n"),
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

    const option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, "p-550e8400-e29b-41d4-a716-446655440000", .hygienic, true, true, "3.conn.test", false);
    defer std.testing.allocator.free(option);

    try std.testing.expect(std.mem.indexOf(u8, option, "sessh-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, ":internal-proxy-stream:") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%n") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%p") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "%r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--filter-level") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "hygienic") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--use-fd-pass") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--bootstrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--daemon-namespace") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "3.conn.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--control-guid") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "p-550e8400-e29b-41d4-a716-446655440000") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "--client-ctrl-r") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "-v") != null);
    try std.testing.expect(std.mem.indexOf(u8, option, "ForwardAgent=yes") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "8080:localhost:80") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-X'") == null);
    try std.testing.expect(std.mem.indexOf(u8, option, "'-tt'") == null);

    const no_bootstrap_option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, null, .unhygienic, false, false, null, false);
    defer std.testing.allocator.free(no_bootstrap_option);
    try std.testing.expect(std.mem.indexOf(u8, no_bootstrap_option, "--no-bootstrap") != null);

    const fd_pass_option = try proxyCommandOption(std.testing.allocator, "/tmp/sessh-test/sessh-proxy", parsed.invocation.ssh_options, null, .unhygienic, false, true, null, true);
    defer std.testing.allocator.free(fd_pass_option);
    try std.testing.expect(std.mem.indexOf(u8, fd_pass_option, "--use-fd-pass") != null);
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

    var visible_frame = try readFrameForTest(allocator, visible[1]);
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

    var stream_frame = try readFrameForTest(allocator, stream[1]);
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

test "sendenv matcher supports ssh wildcard and removal patterns" {
    try std.testing.expect(sendEnvAllowsName(&.{ "LANG", "LC_*" }, "LANG"));
    try std.testing.expect(sendEnvAllowsName(&.{ "LANG", "LC_*" }, "LC_CTYPE"));
    try std.testing.expect(!sendEnvAllowsName(&.{ "LANG", "LC_*" }, "SHELL"));
    try std.testing.expect(!sendEnvAllowsName(&.{ "*", "-SHELL" }, "SHELL"));
    try std.testing.expect(sendEnvAllowsName(&.{ "*", "-SHELL" }, "TERM"));
    try std.testing.expect(sendEnvAllowsName(&.{"SESSH_TEST_SENDEN?"}, "SESSH_TEST_SENDENV"));
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
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.disabled, proxyStreamReconnectStatusMode(.unhygienic, false));
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
    try std.testing.expectEqual(config.FilterLevel.unhygienic, no_stdout.command_level);
    try std.testing.expect(!no_stdout.use_daemon_control);
    try std.testing.expect(!no_stdout.wrap_visible_ssh);
    try std.testing.expect(!no_stdout.client_ctrl_r);

    const no_stdin = proxyDiagnosticsPlanForTest(parsed, false, true);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, no_stdin.command_level);
    try std.testing.expect(!no_stdin.use_daemon_control);
    try std.testing.expect(!no_stdin.wrap_visible_ssh);
    try std.testing.expect(!no_stdin.client_ctrl_r);
}

test "proxy diagnostics plan honors unhygienic level" {
    var parsed = try parseSshArgsForTest(std.testing.allocator, &.{
        "sessh",
        "--filter-level",
        "unhygienic",
        "--no-terminal-emulator",
        "example.com",
    }, .{});
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, parsed.invocation.common.filter_level);
    const plan = proxyDiagnosticsPlanForTest(parsed, true, true);
    try std.testing.expectEqual(config.FilterLevel.unhygienic, plan.command_level);
    try std.testing.expect(!plan.use_daemon_control);
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
