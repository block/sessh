const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const transport_bootstrap = @import("bootstrap.zig");
const bootstrap_client = @import("bootstrap_client.zig");
const cleanup_identity = @import("../session/cleanup_identity.zig");
const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_log = @import("../daemon/log.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const dispatcher = @import("../core/dispatcher.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");
const proxy_diagnostics_router = @import("proxy_diagnostics_router.zig");
const remote_shell = @import("remote_shell.zig");
const send_env_filter = @import("send_env.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");
const mux_tunnel = @import("mux_tunnel.zig");
const guid_ref = @import("../core/guid.zig");
const ssh_transport_acquire = @import("ssh_transport_acquire.zig");
const ssh_opts = @import("ssh_options.zig");
const pb = protocol.pb;

const SshTarget = ssh_transport_process.Target;
const SshTransportProcess = ssh_transport_process.SshTransportProcess;
const ArtifactSet = transport_bootstrap.ArtifactSet;
const artifactFilenameForPlatform = transport_bootstrap.artifactFilenameForPlatform;
const loadArtifactSet = transport_bootstrap.loadArtifactSet;
const parseMissingPlatform = transport_bootstrap.parseMissingPlatform;
const isPlainShellArg = remote_shell.isPlainShellArg;
const shellQuote = remote_shell.shellQuote;
const bootstrapCommand = remote_shell.bootstrapCommand;
const directBrokerCommand = remote_shell.directBrokerCommand;
const ResolvedSshConfig = ssh_opts.ResolvedSshConfig;
const resolveSshConfig = ssh_opts.resolveSshConfig;

const pooled_ssh_transport_idle_close_ms: i32 = 60_000;
const bootstrap_child_exit_poll_ms: u64 = 10;
const bootstrap_child_exit_timeout_ms: u64 = 250;
const proxy_mux_stream_id: u64 = mux_tunnel.first_stream_id;
const raw_proxy_read_buffer_len: usize = 16 * 1024;

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
// Mux fairness comes from the dispatcher rotating ready fd dispatch order: when
// several client streams have data, each completed remote write gives the next
// ready client a turn instead of permanently favoring the lowest poll slot.
const PooledSshTransportRawWrite = mux_tunnel.TaggedRawWrite(PooledSshTransportRawWriteKind);

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

const PooledSshTransportClientFrameWrite = mux_tunnel.TaggedFrameWrite(PooledSshTransportClientWriteKind);
const PooledSshTransportClientFrameWriteQueue = mux_tunnel.TaggedFrameWriteQueue(PooledSshTransportClientWriteKind);

const PooledSshTransportClientRawWrite = mux_tunnel.TaggedRawWrite(PooledSshTransportClientWriteKind);

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

const RemoteCleanupIdentity = cleanup_identity.Remote;
const PendingCleanupRequest = cleanup_identity.PendingRequest;

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
    pending_frame_writes: PooledSshTransportClientFrameWriteQueue = undefined,
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
    raw_proxy_setup_fd: c.fd_t = -1,
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
    isolation_mode: pb.IsolationMode = .ISOLATION_MODE_PROCESS,
    remote_cleanup: ?RemoteCleanupIdentity = null,
    proxy_guid: [guid_ref.proxy_guid_len]u8 = [_]u8{0} ** guid_ref.proxy_guid_len,
    proxy_guid_len: usize = 0,

    fn initReader(self: *PooledSshTransportClient, allocator: std.mem.Allocator) void {
        self.reader = protocol.FrameReader.init(allocator);
        self.pending_frame_writes = PooledSshTransportClientFrameWriteQueue.init(allocator);
    }

    fn deinit(self: *PooledSshTransportClient, allocator: std.mem.Allocator) void {
        self.reader.deinit();
        if (self.write) |*write| write.deinit(allocator);
        self.pending_frame_writes.deinit();
        if (self.local_start_time) |start_time| allocator.free(start_time);
        freeStringList(allocator, self.send_env);
        freeEnvironmentEntries(allocator, &self.client_environment);
        if (self.remote_cleanup) |*remote| remote.deinit(allocator);
        if (self.raw_proxy_host) |host| allocator.free(host);
        if (self.raw_proxy_setup_fd >= 0) {
            _ = c.close(self.raw_proxy_setup_fd);
            self.raw_proxy_setup_fd = -1;
        }
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
    bootstrap_failure_timer_id: ?dispatcher.TimerWatchId = null,
    bootstrap_failure_started_ms: u64 = 0,
    bootstrap_failure_error: ?anyerror = null,
    connection: ?SshTransportProcess = null,
    stderr_fd: c.fd_t = -1,
    remote_daemon_namespace: ?[]u8 = null,
    stream_ids: mux_tunnel.StreamIdAllocator = .{},
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

// PROCESS_GLOBAL_REGISTRY: the local daemon owns the pooled ssh transports for
// its process. This registry is what lets later clients share an existing
// daemon-to-daemon tunnel and lets idle shutdown know whether pooled work
// remains.
var pooled_ssh_transports: std.ArrayList(*PooledSshTransport) = .empty;
var active_pooled_ssh_transports: usize = 0;

pub fn activePooledSshTransportCount() usize {
    return active_pooled_ssh_transports;
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
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
    if (!guid_ref.isValidProxyGuid(proxy_open.proxy_guid)) {
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
    registerPooledRawProxyClientFromDaemon(allocator, daemon_dispatcher, .{
        .raw_fd = raw_fd,
        .setup_fd = setup_fd,
        .target = target,
        .acquire = acquire_request,
        .send_env = resolved_target.config.send_env,
        .proxy_open = proxy_open,
    }) catch |err| {
        daemon_log.infof(allocator, "proxy fd-pass setup failed guid={s} error={t}", .{ proxy_open.proxy_guid, err });
        return err;
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

    var ssh_launch_environment = try ssh_transport_acquire.envMap(allocator, request);
    defer ssh_launch_environment.deinit();

    transport.connection = try ssh_transport_process.spawnSshTransportProcess(
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
    try core_fds.setNonBlocking(remote_read_fd);
    try core_fds.setNonBlocking(transport.connection.?.child.stdin.?.handle);
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
        .isolation_mode = ssh_transport_acquire.protoIsolationModeFromAcquire(request),
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

const PooledRawProxyRegistration = struct {
    raw_fd: c.fd_t,
    setup_fd: c.fd_t,
    target: SshTarget,
    acquire: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
    proxy_open: pb.ProxyStreamItem.Open,
};

fn registerPooledRawProxyClientFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    registration: PooledRawProxyRegistration,
) !void {
    const request = registration.acquire;
    const proxy_open = registration.proxy_open;
    const client = try allocator.create(PooledSshTransportClient);
    errdefer allocator.destroy(client);
    var local_start_time = if (request.local_start_time.len == 0) null else try allocator.dupe(u8, request.local_start_time);
    errdefer if (local_start_time) |start_time| allocator.free(start_time);
    var send_env_copy = try cloneStringList(allocator, registration.send_env);
    errdefer freeStringList(allocator, send_env_copy);
    var client_environment = try cloneEnvironmentEntries(allocator, request.client_environment.items);
    errdefer freeEnvironmentEntries(allocator, &client_environment);
    var raw_proxy_host: ?[]u8 = try allocator.dupe(u8, proxy_open.proxy_host);
    errdefer if (raw_proxy_host) |host| allocator.free(host);
    client.* = .{
        .fd = registration.raw_fd,
        .request_started_ms = nowUnixMs(),
        .local_pid = request.local_pid,
        .local_start_time = local_start_time,
        .send_env = send_env_copy,
        .client_environment = client_environment,
        .raw_proxy = true,
        .raw_proxy_host = raw_proxy_host.?,
        .raw_proxy_port = proxy_open.proxy_port,
        .raw_proxy_setup_fd = registration.setup_fd,
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

    const acquire = try acquirePooledSshTransport(allocator, registration.target, request, client);
    client.transport = acquire.transport;
    if (acquire.created) {
        startNewPooledSshTransport(allocator, daemon_dispatcher, acquire.transport, registration.raw_fd, registration.target, request) catch |err| {
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

test "pooled ssh transport key includes only transport identity fields" {
    const allocator = std.testing.allocator;
    const target = SshTarget{
        .options = &.{"-oProxyCommand=ignored"},
        .host = "alias-name",
        .resolved_user = "user",
        .resolved_host = "host.example",
        .resolved_port = "2222",
    };

    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = "alias-name",
        .bootstrap = true,
        .ssh_auth_sock = "/tmp/agent-a",
        .ip_qos = "af21",
        .local_pid = 100,
        .local_start_time = "start-a",
        .isolation_mode = .ISOLATION_MODE_PROCESS,
    };
    defer request.ssh_option.deinit(allocator);
    defer request.client_environment.deinit(allocator);
    try request.ssh_option.append(allocator, "-oCompression=yes");
    try request.client_environment.append(allocator, .{ .name = "SESSH_TEST", .value = "a" });

    const base = try pooledSshTransportKey(allocator, target, request);
    defer allocator.free(base);

    var ignored_changed = request;
    ignored_changed.ssh_auth_sock = "/tmp/agent-b";
    ignored_changed.local_pid = 200;
    ignored_changed.local_start_time = "start-b";
    ignored_changed.isolation_mode = .ISOLATION_MODE_NONE;
    ignored_changed.ssh_option.items[0] = "-oCompression=no";
    ignored_changed.client_environment.items[0] = .{ .name = "SESSH_TEST", .value = "b" };
    const same = try pooledSshTransportKey(allocator, target, ignored_changed);
    defer allocator.free(same);
    try std.testing.expectEqualStrings(base, same);

    var ipqos_changed = request;
    ipqos_changed.ip_qos = "ef";
    const different_ipqos = try pooledSshTransportKey(allocator, target, ipqos_changed);
    defer allocator.free(different_ipqos);
    try std.testing.expect(!std.mem.eql(u8, base, different_ipqos));

    var bootstrap_changed = request;
    bootstrap_changed.bootstrap = false;
    const different_bootstrap = try pooledSshTransportKey(allocator, target, bootstrap_changed);
    defer allocator.free(different_bootstrap);
    try std.testing.expect(!std.mem.eql(u8, base, different_bootstrap));

    const different_resolved_host = try pooledSshTransportKey(allocator, .{
        .options = target.options,
        .host = target.host,
        .resolved_user = target.resolved_user,
        .resolved_host = "other.example",
        .resolved_port = target.resolved_port,
    }, request);
    defer allocator.free(different_resolved_host);
    try std.testing.expect(!std.mem.eql(u8, base, different_resolved_host));
}

test "pooled mux backpressure is per logical stream" {
    const allocator = std.testing.allocator;
    const key = try allocator.dupe(u8, "key");
    defer allocator.free(key);
    const display_host = try allocator.dupe(u8, "host");
    defer allocator.free(display_host);
    const resolved_user = try allocator.dupe(u8, "user");
    defer allocator.free(resolved_user);
    const resolved_host = try allocator.dupe(u8, "host");
    defer allocator.free(resolved_host);
    const resolved_port = try allocator.dupe(u8, "22");
    defer allocator.free(resolved_port);

    var transport = PooledSshTransport{
        .allocator = allocator,
        .key = key,
        .display_host = display_host,
        .resolved_user = resolved_user,
        .resolved_host = resolved_host,
        .resolved_port = resolved_port,
    };
    defer transport.clients.deinit(allocator);

    var blocked = PooledSshTransportClient{
        .fd = -1,
        .transport = &transport,
        .state = .active,
        .pending_frame_writes = PooledSshTransportClientFrameWriteQueue.init(allocator),
    };
    var open = PooledSshTransportClient{
        .fd = -1,
        .transport = &transport,
        .state = .active,
    };
    try transport.clients.append(allocator, &blocked);
    try transport.clients.append(allocator, &open);

    const active_payload = try protocol.encodeClientDaemonPayload(allocator, .{ .log_request = .{} });
    defer allocator.free(active_payload);
    var active_frame = try protocol.FrameWriteState.init(allocator, .client_daemon, active_payload);
    errdefer active_frame.deinit();
    blocked.write = .{ .frame = .{ .frame = active_frame, .kind = .forwarded_from_daemon } };
    defer {
        if (blocked.write) |*write| write.deinit(allocator);
    }

    const queued_payload = try protocol.encodeClientDaemonPayload(allocator, .{ .retry_now = .{} });
    defer allocator.free(queued_payload);
    var queued_frame = try protocol.FrameWriteState.init(allocator, .client_daemon, queued_payload);
    errdefer queued_frame.deinit();
    try blocked.pending_frame_writes.appendWrite(.{ .frame = queued_frame, .kind = .forwarded_from_daemon });
    defer {
        blocked.pending_frame_writes.deinit();
    }

    try std.testing.expect(!pooledSshTransportClientReadable(&blocked));
    try std.testing.expect(pooledSshTransportClientReadable(&open));
    try std.testing.expect(pooledSshTransportHasClientWrites(&transport));
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
        const exec_bytes = try bootstrap_client.buildExecBytes(allocator, artifacts, .broker, if (transport.remote_daemon_namespace) |namespace| &[_][]const u8{namespace} else &.{});
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
    _ = starter;
    daemon_log.infof(
        allocator,
        "pooled ssh transport startup failed host={s} pool={s} error={t}",
        .{ transport.display_host, transport.key, err },
    );
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        _ = failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "SSH_TRANSPORT_FAILED", "ssh transport failed", "", false);
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
    defer ssh_transport_acquire.deinitOwnedFields(allocator, &request);
    try ssh_transport_acquire.appendCurrentSshAgent(allocator, &request);

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
        const upload = try bootstrap_client.buildUploadBytes(transport.allocator, artifact);
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
        "pooled ssh transport remote hello completed host={s} pool={s}",
        .{ transport.display_host, transport.key },
    );
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
        if (!reported and err == error.VersionMismatch) {
            _ = failPooledSshTransportClientWithError(
                daemon_dispatcher,
                transport,
                client,
                "VERSION_MISMATCH",
                "sesshd is incompatible with this client",
                "",
                false,
            );
        } else if (!reported and err != error.UnsupportedRemotePlatform) {
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
    if (pollPooledSshTransportExit(transport)) |term| {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, err, term);
        return;
    }
    schedulePooledSshTransportBootstrapExitPoll(daemon_dispatcher, transport, err);
}

fn failPooledSshTransportBootstrap(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    err: anyerror,
    term: ?std.process.Child.Term,
) void {
    const stage: []const u8 = if (transport.uploaded_bootstrap_artifact) "after upload" else "before response";
    daemon_log.infof(
        transport.allocator,
        "bootstrap failed {s} host={s} error={t}",
        .{ stage, transport.display_host, err },
    );
    if (transport.connection) |*connection| connection.closeStdin();
    _ = forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch {};
    failPooledSshTransportStartup(daemon_dispatcher, transport, error.SshBootstrapFailed, term);
}

fn pooledSshTransportIsBootstrapping(transport: *const PooledSshTransport) bool {
    return switch (transport.state) {
        .bootstrap_writing_exec,
        .bootstrap_writing_upload,
        .bootstrap_wait_line,
        => true,
        else => false,
    };
}

fn pollPooledSshTransportExit(transport: *PooledSshTransport) ?std.process.Child.Term {
    if (transport.connection) |*connection| return connection.pollExit();
    return null;
}

fn schedulePooledSshTransportBootstrapExitPoll(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    err: anyerror,
) void {
    if (transport.bootstrap_failure_timer_id != null) return;
    const now_ms = daemon_dispatcher.nowMs();
    if (transport.bootstrap_failure_started_ms == 0) {
        transport.bootstrap_failure_started_ms = now_ms;
        transport.bootstrap_failure_error = err;
    }
    const elapsed_ms = now_ms -| transport.bootstrap_failure_started_ms;
    if (elapsed_ms >= bootstrap_child_exit_timeout_ms) {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, transport.bootstrap_failure_error orelse err, null);
        return;
    }
    const remaining_ms = bootstrap_child_exit_timeout_ms - elapsed_ms;
    transport.bootstrap_failure_timer_id = daemon_dispatcher.watchTimerAfter(@min(bootstrap_child_exit_poll_ms, remaining_ms), .{
        .ctx = transport,
        .callback = pollPooledSshTransportBootstrapExit,
    }) catch {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, transport.bootstrap_failure_error orelse err, null);
        return;
    };
}

fn pollPooledSshTransportBootstrapExit(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const transport: *PooledSshTransport = @ptrCast(@alignCast(ctx));
    switch (event) {
        .timer => {},
        .fd => return error.UnexpectedPooledSshTransportFdEvent,
    }
    transport.bootstrap_failure_timer_id = null;
    const err = transport.bootstrap_failure_error orelse error.SshBootstrapFailed;
    if (pollPooledSshTransportExit(transport)) |term| {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, err, term);
        return;
    }
    schedulePooledSshTransportBootstrapExitPoll(daemon_dispatcher, transport, err);
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
        if (pooledSshTransportIsBootstrapping(transport)) {
            waitForBootstrapReadAfterWriteFailure(daemon_dispatcher, transport);
        } else {
            failPooledSshTransportStartup(daemon_dispatcher, transport, err, pollPooledSshTransportExit(transport));
        }
    };
}

fn waitForBootstrapReadAfterWriteFailure(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) void {
    if (transport.stdin_watch_id) |watch_id| {
        daemon_dispatcher.cancel(.{ .fd = watch_id });
        transport.stdin_watch_id = null;
    }
    if (transport.remote_write) |*write| {
        write.deinit(transport.allocator);
        transport.remote_write = null;
    }
    if (transport.connection) |*connection| connection.closeStdin();
    transport.state = .bootstrap_wait_line;
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
        .raw => |*raw| try raw.writeReady(fd),
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
            if (frame.kind == .cleanup_request) {
                daemon_log.infof(
                    transport.allocator,
                    "cleanup request sent host={s} in_flight={}",
                    .{ transport.display_host, transport.cleanup_requests_in_flight },
                );
            }
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
        if (!try writePooledSshTransportClient(daemon_dispatcher, transport, client)) return;
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
) !bool {
    const write = if (client.write) |*value| value else return true;
    const done = switch (write.*) {
        .frame => |*frame| switch (try frame.frame.writeReady(client.fd)) {
            .blocked, .progress => false,
            .done => true,
        },
        .raw => |*raw| try raw.writeReady(client.fd),
    };
    if (!done) return true;

    var completed = client.write.?;
    client.write = null;
    const kind = completed.kind();
    completed.setKind(.forwarded_from_daemon);
    const completed_raw = switch (completed) {
        .raw => true,
        .frame => false,
    };
    completed.deinit(transport.allocator);

    switch (kind) {
        .forwarded_from_daemon => {},
        .finish_after_write => |finish| {
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, finish.send_hangup);
            return false;
        },
    }
    if (try startNextQueuedPooledSshTransportClientFrameWrite(daemon_dispatcher, client)) {
        return true;
    }
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);

    if (!pooledSshTransportHasClientWrites(transport)) {
        if (completed_raw and client.raw_proxy and client.state != .done) {
            try sendPooledRawProxyAck(daemon_dispatcher, transport, client);
        } else {
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        }
    }
    return true;
}

fn pooledSshTransportHasClientWrites(transport: *const PooledSshTransport) bool {
    for (transport.clients.items) |client| {
        if (client.state != .done and (client.write != null or client.pending_frame_writes.hasPending())) return true;
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
        const frame_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, .{
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
    const payload = try mux_tunnel.encodeAckPayload(transport.allocator, client.stream_id, client.inbound_next_offset);
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .proxy_ack);
}

fn sendPooledRawProxyOpenOk(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) !void {
    const payload = try mux_tunnel.encodeOpenOkPayload(transport.allocator, client.stream_id, client.inbound_next_offset);
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .daemon_tunnel, payload, .proxy_ack);
}

fn sendPooledRawProxyFdPassAccepted(client: *PooledSshTransportClient) !void {
    if (client.raw_proxy_setup_fd < 0) return;
    const setup_fd = client.raw_proxy_setup_fd;
    client.raw_proxy_setup_fd = -1;
    defer _ = c.close(setup_fd);

    daemon_log.infof(client.transport.allocator, "proxy fd-pass setup accepted guid={s}", .{client.proxyGuidSlice()});
    protocol.sendClientDaemonPayloadFrame(client.transport.allocator, setup_fd, .{ .proxy_fd_pass_accepted = .{} }) catch |err| {
        daemon_log.infof(
            client.transport.allocator,
            "proxy fd-pass setup ack failed guid={s} error={t}",
            .{ client.proxyGuidSlice(), err },
        );
    };
}

fn startPooledSshTransportClientFrameWrite(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    message_type: protocol.MessageType,
    payload: []const u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    var frame = try protocol.FrameWriteState.init(client.transport.allocator, message_type, payload);
    errdefer frame.deinit();
    if (client.write != null) {
        try client.pending_frame_writes.appendWrite(.{ .frame = frame, .kind = kind });
        try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
        return;
    }
    client.write = .{ .frame = .{ .frame = frame, .kind = kind } };
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
}

fn startNextQueuedPooledSshTransportClientFrameWrite(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) !bool {
    if (client.write != null) return false;
    const next = client.pending_frame_writes.popFirst() orelse return false;
    client.write = .{ .frame = next };
    try ensurePooledSshTransportClientWatch(daemon_dispatcher, client);
    return true;
}

fn startPooledSshTransportClientRawWrite(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
    bytes: []u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    if (client.write != null or client.pending_frame_writes.hasPending()) return error.PooledSshTransportClientWriteAlreadyQueued;
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
    const payload = try protocol.encodeConnectionEventPayload(client.transport.allocator, event);
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
    const payload = try protocol.encodeErrorPayload(client.transport.allocator, code, message, hint);
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
    if (transport.bootstrap_failure_timer_id) |timer_id| {
        daemon_dispatcher.cancel(.{ .timer = timer_id });
        transport.bootstrap_failure_timer_id = null;
    }
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client.state != .pending_transport) {
            index += 1;
            continue;
        }
        client.stream_id = transport.stream_ids.take();
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
            const pong_payload = try protocol.encodeDaemonTunnelPayload(client.transport.allocator, .{ .pong = .{} });
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
    open.isolation_mode = client.isolation_mode;
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
                return failPooledSshTransportClientWithError(daemon_dispatcher, transport, client, "PROTOCOL_ERROR", "unexpected proxy diagnostics frame", "", true);
            }
            try proxy_diagnostics_router.forwardFromStream(transport.allocator, daemon_dispatcher, client.proxyGuidSlice(), frame.*);
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
            // SessionCreate uses SHELL as the remote terminal worker's login shell
            // convention. OpenSSH SendEnv must not let the visible client's
            // SHELL choose the remote PTY child shell.
            if (std.mem.eql(u8, entry.name, "SHELL")) continue;
            if (!send_env_filter.allowsName(client.send_env, entry.name)) continue;
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

fn sendPooledTerminalMuxOpen(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    request: pb.TerminalEmulatorItem.Open,
) !void {
    const typed_open_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, .{
        .stream_id = client.stream_id,
        .message = .{ .payload = .{
            .offset = client.outbound_next_offset,
            .item = .{ .terminal_emulator = .{ .payload = .{ .open = request } } },
        } },
    });
    errdefer transport.allocator.free(typed_open_bytes);
    const envelope_bytes = try mux_tunnel.encodeOpenEnvelopeBytes(transport.allocator, client.stream_id, client.inbound_next_offset);
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
    const bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, mux_frame);
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
    const typed_open_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, .{
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
    const envelope_bytes = try mux_tunnel.encodeOpenEnvelopeBytes(transport.allocator, client.stream_id, client.inbound_next_offset);
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
    try maybeRegisterProxyDiagnosticsStream(transport.allocator, client, mux_frame);
    mux_frame.stream_id = client.stream_id;
    const bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, mux_frame);
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientWatch(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, bytes, .{ .client_to_daemon = client });
}

fn maybeRegisterProxyDiagnosticsStream(
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
    const canonical = try guid_ref.canonicalProxyGuid(allocator, open.proxy_guid);
    defer allocator.free(canonical);
    try client.setProxyGuid(canonical);
    try proxy_diagnostics_router.registerStream(allocator, canonical, client.fd, .{
        .ctx = client,
        .queueFrame = queueProxyDiagnosticsFrameToPooledClient,
    });
}

fn queueProxyDiagnosticsFrameToPooledClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, frame: protocol.OwnedFrame) !void {
    const client: *PooledSshTransportClient = @ptrCast(@alignCast(ctx));
    try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, frame.message_type, frame.payload, .forwarded_from_daemon);
}

fn sendPooledTerminalMuxPayload(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    item: pb.TerminalEmulatorItem,
) !void {
    const bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, .{
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
            if (response.process) |process| {
                daemon_log.infof(
                    transport.allocator,
                    "cleanup response received host={s} guid={s}",
                    .{ transport.display_host, process.guid },
                );
            }
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
            const pong_payload = try protocol.encodeDaemonTunnelPayload(transport.allocator, .{ .pong = .{} });
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
            const pong_payload = try protocol.encodeDaemonTunnelPayload(transport.allocator, .{ .pong = .{} });
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
        return handlePooledRemoteProxyMuxStreamFrame(daemon_dispatcher, transport, client, &owned_mux_frame, message);
    }
    return handlePooledRemoteTerminalMuxStreamFrame(daemon_dispatcher, transport, client, message);
}

fn notePooledMuxOpenOk(client: *PooledSshTransportClient) void {
    if (client.mux_open_ok_ms == 0) client.mux_open_ok_ms = nowUnixMs();
}

fn notePooledMuxFirstPayload(transport: *PooledSshTransport, client: *PooledSshTransportClient) void {
    if (client.first_payload_ms != 0) return;
    client.first_payload_ms = nowUnixMs();
    logPooledSshTransportClientStartupTiming(transport, client);
}

fn handlePooledRemoteProxyMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    mux_frame: *pb.DaemonTunnelItem.MuxStreamFrame,
    message: protocol.MuxStreamMessage,
) !bool {
    switch (message) {
        .open_ok => {
            notePooledMuxOpenOk(client);
        },
        .payload => {
            notePooledMuxFirstPayload(transport, client);
        },
        .reset => {
            notePooledMuxFirstPayload(transport, client);
            daemon_log.infof(
                transport.allocator,
                "pooled proxy stream reset host={s} stream_id={}",
                .{ transport.display_host, client.stream_id },
            );
        },
        .eof => {
            notePooledMuxFirstPayload(transport, client);
            daemon_log.infof(
                transport.allocator,
                "pooled proxy stream eof host={s} stream_id={}",
                .{ transport.display_host, client.stream_id },
            );
        },
        .open, .ack => {},
    }
    mux_frame.stream_id = client.local_stream_id;
    try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
    const payload = try mux_tunnel.encodeMuxStreamPayload(transport.allocator, mux_frame.*);
    defer transport.allocator.free(payload);
    try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .daemon_tunnel, payload, .forwarded_from_daemon);
    return true;
}

fn handlePooledRemoteTerminalMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    message: protocol.MuxStreamMessage,
) !bool {
    switch (message) {
        .open_ok => notePooledMuxOpenOk(client),
        .ack => {},
        .payload => |payload| try handlePooledRemoteTerminalMuxPayload(daemon_dispatcher, transport, client, payload),
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
            notePooledMuxFirstPayload(transport, client);
            if (finishPooledClientAfterCurrentWrite(client, false)) return true;
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
        },
        .open => return error.UnexpectedDaemonFrame,
    }
    return true;
}

fn handlePooledRemoteTerminalMuxPayload(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
) !void {
    notePooledMuxFirstPayload(transport, client);
    const item = payload.item orelse return error.UnexpectedDaemonFrame;
    const te_item = switch (item) {
        .terminal_emulator => |terminal_emulator| terminal_emulator,
        else => return error.UnexpectedDaemonFrame,
    };
    client.inbound_next_offset = @max(client.inbound_next_offset, payload.offset +| 1);
    try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
    const client_payload = try protocol.encodeTerminalEmulatorItemPayload(transport.allocator, te_item);
    defer transport.allocator.free(client_payload);
    try startPooledSshTransportClientFrameWrite(daemon_dispatcher, client, .client_remote, client_payload, .forwarded_from_daemon);
    const te_payload = te_item.payload orelse return;
    if (te_payload == .session_ended) {
        client.session_ended = true;
    }
}

fn handlePooledRemoteRawProxyMuxStreamFrame(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
    message: protocol.MuxStreamMessage,
) !bool {
    switch (message) {
        .open_ok => {
            notePooledMuxOpenOk(client);
            try sendPooledRawProxyFdPassAccepted(client);
        },
        .ack => {},
        .payload => |payload| {
            notePooledMuxFirstPayload(transport, client);
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
            notePooledMuxFirstPayload(transport, client);
            finishPooledSshTransportClient(daemon_dispatcher, transport, client, false);
        },
        .eof => {
            notePooledMuxFirstPayload(transport, client);
            if (finishPooledClientAfterCurrentWrite(client, false)) return true;
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
    const payload = try mux_tunnel.encodeDaemonTunnelPayload(transport.allocator, .{ .remote_process_recorded = .{
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
    daemon_log.infof(
        transport.allocator,
        "cleanup request sending host={s} guid={s}",
        .{ transport.display_host, remote.guid },
    );
    const payload = try mux_tunnel.encodeDaemonTunnelPayload(transport.allocator, .{
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

fn queuePendingRemoteCleanupRequest(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    remote: RemoteCleanupIdentity,
) void {
    var pending = PendingCleanupRequest.fromRemote(transport.allocator, remote) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "client disconnect remote cleanup queue failed host={s} guid={s} error={t}",
            .{ transport.display_host, remote.guid, err },
        );
        return;
    };
    errdefer pending.deinit(transport.allocator);
    transport.pending_cleanup_requests.append(transport.allocator, pending) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "client disconnect remote cleanup queue failed host={s} guid={s} error={t}",
            .{ transport.display_host, remote.guid, err },
        );
        return;
    };
    pending = undefined;
    startNextPendingCleanupRequest(daemon_dispatcher, transport) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "client disconnect remote cleanup request queued host={s} guid={s} wait_reason={t}",
            .{ transport.display_host, remote.guid, err },
        );
    };
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
    if (client.kind == .proxy) proxy_diagnostics_router.unregisterStream(client.fd);
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
                        "client disconnect remote cleanup request queued host={s} guid={s} error={t}",
                        .{ transport.display_host, remote.guid, err },
                    );
                    queuePendingRemoteCleanupRequest(daemon_dispatcher, transport, remote);
                };
            } else {
                daemon_log.infof(
                    transport.allocator,
                    "client disconnected before cleanup identity was recorded host={s}",
                    .{transport.display_host},
                );
            }
        }
    } else if (!send_hangup) {
        if (client.remote_cleanup) |remote| {
            daemon_cleanup.deleteRecordByGuid(transport.allocator, remote.guid);
        }
    }
    destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
    if (transport.state == .closing) {
        if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
        return;
    }
    if (transport.remote_write == null and !pooledSshTransportHasClientWrites(transport)) {
        resumePooledSshTransportRemoteRead(daemon_dispatcher, transport) catch |err| {
            daemon_log.infof(
                transport.allocator,
                "pooled ssh transport remote read resume failed host={s} pool={s} error={t}",
                .{ transport.display_host, transport.key, err },
            );
        };
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
    const allocator = transport.allocator;
    transport.deinit();
    allocator.destroy(transport);
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

fn sendDaemonTransportError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    try protocol.sendErrorFrame(app_allocator.allocator(), fd, code, message, hint);
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
