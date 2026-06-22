// Pooled daemon-to-daemon ssh transport. One OpenSSH process can carry many
// logical terminal/proxy streams, so this module owns pooling, bootstrap,
// mux-frame IO, backpressure, reconnect diagnostics, and cleanup delivery.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const transport_bootstrap = @import("bootstrap.zig");
const bootstrap_client = @import("bootstrap_client.zig");
const client_env = @import("client_environment.zig");
const config = @import("../core/config.zig");
const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_log = @import("../daemon/log.zig");
const daemon_socket_namespace = @import("../daemon/socket_namespace.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const pooled_ssh_client = @import("pooled_ssh_client.zig");
const pooled_ssh_identity = @import("pooled_ssh_identity.zig");
const pooled_ssh_model = @import("pooled_ssh_model.zig");
const pooled_ssh_registry = @import("pooled_ssh_registry.zig");
const proxy_diagnostics_router = @import("proxy_diagnostics_router.zig");
const raw_proxy_client = @import("raw_proxy_client.zig");
const remote_shell = @import("remote_shell.zig");
const ssh_failure = @import("ssh_failure.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");
const mux_tunnel = @import("mux_tunnel.zig");
const one_shot_frame_writer = @import("one_shot_frame_writer.zig");
const guid_ref = @import("../core/guid.zig");
const ssh_transport_acquire = @import("ssh_transport_acquire.zig");
const pb = protocol.pb;

const SshTarget = ssh_transport_process.Target;
const artifactFilenameForPlatform = transport_bootstrap.artifactFilenameForPlatform;
const loadArtifactSet = transport_bootstrap.loadArtifactSet;
const parseMissingPlatform = transport_bootstrap.parseMissingPlatform;
const bootstrapCommand = remote_shell.bootstrapCommand;
const directBridgeCommand = remote_shell.directBridgeCommand;

const pooled_ssh_transport_idle_close_ms: i32 = 60_000;
const bootstrap_process_exit_poll_ms: u64 = 10;
const bootstrap_process_exit_timeout_ms: u64 = 250;
const proxy_mux_stream_id: u64 = mux_tunnel.first_stream_id;
const raw_proxy_read_buffer_len: usize = 16 * 1024;

const PooledSshTransportClientState = pooled_ssh_model.ClientState;
const PooledSshTransportClientKind = pooled_ssh_model.ClientKind;
const PooledSshTransportRawWriteKind = pooled_ssh_model.RawWriteKind;
const PooledSshTransportFrameWriteKind = pooled_ssh_model.FrameWriteKind;
const PooledSshTransportRemoteWriteKind = pooled_ssh_model.RemoteWriteKind;
const PooledSshTransportClientWriteKind = pooled_ssh_model.ClientWriteKind;
const PooledSshTransportClientFrameWrites = pooled_ssh_model.ClientFrameWrites;
const RemoteCleanupIdentity = pooled_ssh_model.RemoteCleanupIdentity;
const PooledSshTransportClient = pooled_ssh_model.Client;
const PooledSshTransportClientSourceKind = pooled_ssh_model.ClientSourceKind;
const PooledSshTransportRemoteSourceKind = pooled_ssh_model.RemoteSourceKind;
const PooledSshTransportState = pooled_ssh_model.TransportState;
const PooledSshTransport = pooled_ssh_model.Transport;

pub fn activePooledSshTransportCount() usize {
    return pooled_ssh_registry.activeCount();
}

pub const RegisterPooledSshTransportOptions = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    request: pb.ClientDaemonItem.SshTransportAcquire,
};

pub const RegisterPooledTerminalDebugResult = enum {
    not_found,
    transferred,
};

pub const RegisterPooledTerminalDebugOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    frame: protocol.OwnedFrame,
};

/// Handle a local client request for an SSH transport. The daemon resolves the
/// ssh target once, folds resolved config into the acquire request, and then
/// attaches the client to a compatible pooled daemon-to-daemon tunnel.
pub fn registerPooledSshTransportFromDaemon(options: RegisterPooledSshTransportOptions) !void {
    const allocator = options.allocator;
    const daemon_dispatcher = options.daemon_dispatcher;
    const client_fd = options.client_fd;
    const request = options.request;
    var resolved_target = try pooled_ssh_identity.resolve(options.blocking, allocator, request.ssh_option.items, request.host);
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

    try registerPooledSshTransportClientFromDaemon(.{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .client_fd = client_fd,
        .target = target,
        .request = acquire_request,
        .send_env = resolved_target.config.send_env,
    });
}

const ProxyFdPassOpenRegistration = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    setup_fd: c.fd_t,
    raw_fd: c.fd_t,
    request: pb.ClientDaemonItem.ProxyFdPassOpen,
};

/// Handle ProxyUseFdPass setup from sessh-proxy. The setup socket stays framed
/// for success/error reporting; the passed fd becomes the raw byte stream that
/// OpenSSH will use after the proxy process exits.
pub fn registerProxyFdPassOpenFromDaemon(options: ProxyFdPassOpenRegistration) !void {
    const allocator = options.allocator;
    const daemon_dispatcher = options.daemon_dispatcher;
    const setup_fd = options.setup_fd;
    var raw_fd = core_fds.OwnedFd.init(options.raw_fd);
    const request = options.request;
    defer raw_fd.deinit();
    // Malformed fd-pass opens still get a framed response on the setup socket.
    // Once that one-shot writer is registered, this function returns success so
    // the daemon router transfers setup-fd ownership to the writer instead of
    // closing it through the original client context.
    const transport_request = request.transport orelse {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .fd = setup_fd,
            .code = "PROTOCOL_ERROR",
            .message = "proxy fd-pass open missing transport",
        });
        return;
    };
    const proxy_open = request.proxy orelse {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .fd = setup_fd,
            .code = "PROTOCOL_ERROR",
            .message = "proxy fd-pass open missing proxy details",
        });
        return;
    };
    if (!guid_ref.isValidProxyGuid(proxy_open.proxy_guid)) {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .fd = setup_fd,
            .code = "PROTOCOL_ERROR",
            .message = "proxy fd-pass open has invalid proxy guid",
        });
        return;
    }
    if (proxy_open.proxy_port == 0 or proxy_open.proxy_port > std.math.maxInt(u16)) {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .fd = setup_fd,
            .code = "PROTOCOL_ERROR",
            .message = "proxy fd-pass open has invalid proxy port",
        });
        return;
    }

    var resolved_target = try pooled_ssh_identity.resolve(options.blocking, allocator, transport_request.ssh_option.items, transport_request.host);
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

    try core_fds.setNonBlocking(raw_fd.get());
    registerPooledRawProxyClientFromDaemon(allocator, daemon_dispatcher, .{
        .raw_fd = raw_fd.get(),
        .setup_fd = setup_fd,
        .target = target,
        .acquire = acquire_request,
        .send_env = resolved_target.config.send_env,
        .proxy_open = proxy_open,
    }) catch |err| {
        daemon_log.infof(allocator, "proxy fd-pass setup failed guid={s} error={t}", .{ proxy_open.proxy_guid, err });
        return err;
    };
    _ = raw_fd.take();
}

const PooledTransportProcessStartOptions = struct {
    allocator: std.mem.Allocator,
    transport: *PooledSshTransport,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
};

// Spawn the OpenSSH process that carries the daemon tunnel. Bootstrap mode first
// runs the remote bootstrap script; no-bootstrap mode invokes the bridge already
// available in PATH on the remote host.
fn startPooledSshTransportProcessForDaemon(options: PooledTransportProcessStartOptions) !void {
    const allocator = options.allocator;
    const transport = options.transport;
    const target = options.target;
    const request = options.request;
    var bridge_socket_dir: ?[]u8 = null;
    errdefer if (bridge_socket_dir) |dir| allocator.free(dir);
    var bridge_arg_storage: [1][]const u8 = undefined;
    var bridge_args: []const []const u8 = bridge_arg_storage[0..0];
    if (request.bootstrap) {
        transport.bootstrap_artifacts = try loadArtifactSet(allocator);
        bridge_socket_dir = try daemon_socket_namespace.defaultDirName(allocator);
        bridge_arg_storage[0] = bridge_socket_dir.?;
        bridge_args = bridge_arg_storage[0..1];
        daemon_log.infof(
            allocator,
            "remote daemon namespace host={s} namespace={s} env={s}",
            .{ target.host, bridge_socket_dir.?, daemon_socket_namespace.namespace_env },
        );
    }

    const remote_command = if (request.bootstrap)
        try bootstrapCommand(allocator)
    else
        try directBridgeCommand(allocator, bridge_args);
    defer allocator.free(remote_command);

    var ssh_launch_environment = try ssh_transport_acquire.envMap(allocator, request);
    defer ssh_launch_environment.deinit();

    transport.connection = try ssh_transport_process.spawnSshTransportProcess(.{
        .allocator = allocator,
        .target = target,
        .remote_command = remote_command,
        .env_map = &ssh_launch_environment,
        .bootstrap = request.bootstrap,
    });
    errdefer {
        if (transport.connection) |*connection| connection.terminate();
        transport.connection = null;
    }

    const remote_read_fd = transport.connection.?.stdoutFd();
    try core_fds.setNonBlocking(remote_read_fd);
    try core_fds.setNonBlocking(transport.connection.?.stdinFd());
    transport.stderr_fd = transport.connection.?.stderr_fd;
    transport.connection.?.stderr_fd = -1;
    transport.remote_daemon_namespace = bridge_socket_dir;
    bridge_socket_dir = null;
}

const PooledClientRegistration = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
};

// Add a framed terminal/proxy client to a pooled transport, creating the
// underlying OpenSSH tunnel if this is the first compatible client.
fn registerPooledSshTransportClientFromDaemon(registration: PooledClientRegistration) !void {
    const allocator = registration.allocator;
    const request = registration.request;
    const client = try pooled_ssh_client.createFromAcquire(allocator, .{
        .fd = registration.client_fd,
        .request = request,
        .send_env = registration.send_env,
    });
    errdefer {
        client.deinit(allocator);
        allocator.destroy(client);
    }

    const acquire = try pooled_ssh_registry.acquire(.{
        .allocator = allocator,
        .target = registration.target,
        .request = request,
        .client = client,
    });
    client.transport = acquire.transport;
    if (acquire.created) {
        startNewPooledSshTransport(.{
            .allocator = allocator,
            .daemon_dispatcher = registration.daemon_dispatcher,
            .transport = acquire.transport,
            .target = registration.target,
            .request = request,
        }) catch |err| {
            failStartingPooledSshTransport(registration.daemon_dispatcher, acquire.transport, err);
        };
    } else if (acquire.transport.state == .ready) {
        activatePendingPooledSshTransportClients(registration.daemon_dispatcher, acquire.transport);
    }
}

/// Route a one-shot terminal debug/control request to the visible terminal
/// stream carried by a pooled SSH transport. The requester is a short-lived
/// daemon client, not the visible terminal client, so the response must be
/// intercepted and written back to `client_fd` instead of being forwarded to the
/// visible client.
pub fn registerPooledTerminalDebugFromDaemon(options: RegisterPooledTerminalDebugOptions) !RegisterPooledTerminalDebugResult {
    const client = switch (pooled_ssh_registry.singleActiveTerminalClient()) {
        .none => return .not_found,
        .ambiguous => {
            try sendDaemonTransportErrorAndClose(.{
                .allocator = options.allocator,
                .daemon_dispatcher = options.daemon_dispatcher,
                .fd = options.client_fd,
                .code = "SESSION_NOT_FOUND",
                .message = "session not found",
            });
            return .transferred;
        },
        .client => |client| client,
    };

    if (options.frame.message_type != .client_remote) {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = options.allocator,
            .daemon_dispatcher = options.daemon_dispatcher,
            .fd = options.client_fd,
            .code = "PROTOCOL_ERROR",
            .message = "pooled terminal debug only supports terminal frames",
        });
        return .transferred;
    }

    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(options.allocator, options.frame.payload);
    defer item.deinit(options.allocator);
    const item_payload = item.payload orelse {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = options.allocator,
            .daemon_dispatcher = options.daemon_dispatcher,
            .fd = options.client_fd,
            .code = "PROTOCOL_ERROR",
            .message = "pooled terminal debug received empty terminal item",
        });
        return .transferred;
    };
    switch (item_payload) {
        .debug_sever_connection_request,
        .debug_unresponsive_connection_request,
        => {},
        else => {
            try sendDaemonTransportErrorAndClose(.{
                .allocator = options.allocator,
                .daemon_dispatcher = options.daemon_dispatcher,
                .fd = options.client_fd,
                .code = "PROTOCOL_ERROR",
                .message = "pooled terminal debug received unsupported terminal item",
            });
            return .transferred;
        },
    }

    if (client.debug_control_fd >= 0) {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = options.allocator,
            .daemon_dispatcher = options.daemon_dispatcher,
            .fd = options.client_fd,
            .code = "DEBUG_CONTROL_BUSY",
            .message = "terminal debug request already in flight",
        });
        return .transferred;
    }
    if (client.transport.remote_write_kind != null or client.transport.stdin_sink.hasPendingWrite()) {
        try sendDaemonTransportErrorAndClose(.{
            .allocator = options.allocator,
            .daemon_dispatcher = options.daemon_dispatcher,
            .fd = options.client_fd,
            .code = "DEBUG_CONTROL_BUSY",
            .message = "shared ssh transport is busy",
        });
        return .transferred;
    }

    client.debug_control_fd = options.client_fd;
    sendPooledTerminalMuxPayload(pooledClientContext(options.daemon_dispatcher, client), item) catch |err| {
        client.debug_control_fd = -1;
        try sendDaemonTransportErrorAndClose(.{
            .allocator = options.allocator,
            .daemon_dispatcher = options.daemon_dispatcher,
            .fd = options.client_fd,
            .code = "DEBUG_CONTROL_FAILED",
            .message = @errorName(err),
        });
    };
    return .transferred;
}

const PooledRawProxyRegistration = struct {
    raw_fd: c.fd_t,
    setup_fd: c.fd_t,
    target: SshTarget,
    acquire: pb.ClientDaemonItem.SshTransportAcquire,
    send_env: []const []const u8,
    proxy_open: pb.ProxyStreamItem.Open,
};

// Add a raw fd-pass proxy client to a pooled transport. Unlike framed clients,
// this client's local fd carries raw OpenSSH proxy bytes, while setup success is
// reported separately on the one-shot setup fd.
fn registerPooledRawProxyClientFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    registration: PooledRawProxyRegistration,
) !void {
    const request = registration.acquire;
    const proxy_open = registration.proxy_open;
    const client = try pooled_ssh_client.createFromAcquire(allocator, .{
        .fd = registration.raw_fd,
        .request = request,
        .send_env = registration.send_env,
    });
    errdefer {
        client.deinit(allocator);
        allocator.destroy(client);
    }
    var raw_proxy_host: ?[]u8 = try allocator.dupe(u8, proxy_open.proxy_host);
    errdefer if (raw_proxy_host) |host| allocator.free(host);
    client.raw_proxy = raw_proxy_client.RawProxyClient.initOwned(.{
        .host = raw_proxy_host.?,
        .port = proxy_open.proxy_port,
        .setup_fd = registration.setup_fd,
    });
    client.kind = .proxy;
    client.local_stream_id = proxy_mux_stream_id;
    raw_proxy_host = null;
    try client.proxy_guid.set(proxy_open.proxy_guid);

    const acquire = try pooled_ssh_registry.acquire(.{
        .allocator = allocator,
        .target = registration.target,
        .request = request,
        .client = client,
    });
    client.transport = acquire.transport;
    if (acquire.created) {
        startNewPooledSshTransport(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .transport = acquire.transport,
            .target = registration.target,
            .request = request,
        }) catch |err| {
            failStartingPooledSshTransport(daemon_dispatcher, acquire.transport, err);
        };
    } else if (acquire.transport.state == .ready) {
        activatePendingPooledSshTransportClients(daemon_dispatcher, acquire.transport);
    }
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
        .pending_frame_writes = PooledSshTransportClientFrameWrites.init(allocator),
    };
    var open = PooledSshTransportClient{
        .fd = -1,
        .transport = &transport,
        .state = .active,
    };
    try transport.clients.append(allocator, &blocked);
    try transport.clients.append(allocator, &open);

    blocked.write_kind = .forwarded_from_daemon;

    const queued_payload = try protocol.encodeClientDaemonPayload(allocator, .{ .retry_now = .{} });
    defer allocator.free(queued_payload);
    try blocked.pending_frame_writes.appendFrame(.client_daemon, queued_payload, .forwarded_from_daemon);
    defer {
        blocked.pending_frame_writes.deinit();
    }

    try std.testing.expect(!pooledSshTransportClientReadable(&blocked));
    try std.testing.expect(pooledSshTransportClientReadable(&open));
    try std.testing.expect(pooledSshTransportHasClientWrites(&transport));
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

const PooledTransportStartOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    target: SshTarget,
    request: pb.ClientDaemonItem.SshTransportAcquire,
};

// Start a newly-created pooled transport and register the dispatcher sources
// needed for stdout frames, stderr diagnostics, and initial stdin bootstrap or
// handshake writes.
fn startNewPooledSshTransport(options: PooledTransportStartOptions) !void {
    const allocator = options.allocator;
    const daemon_dispatcher = options.daemon_dispatcher;
    const transport = options.transport;
    const target = options.target;
    const request = options.request;
    try startPooledSshTransportProcessForDaemon(.{
        .allocator = allocator,
        .transport = transport,
        .target = target,
        .request = request,
    });
    const remote_read_fd = transport.connection.?.stdoutFd();
    try ensurePooledSshTransportRemoteSource(
        daemon_dispatcher,
        transport,
        remote_read_fd,
        if (request.bootstrap) .bootstrap_byte else .frame,
    );
    try ensurePooledSshTransportStderrSource(daemon_dispatcher, transport);

    if (request.bootstrap) {
        const artifacts = if (transport.bootstrap_artifacts) |*value| value else return error.MissingBootstrapArtifacts;
        const exec_bytes = try bootstrap_client.buildExecBytes(.{
            .allocator = allocator,
            .artifacts = artifacts,
            .entrypoint = .bridge,
            .entrypoint_args = if (transport.remote_daemon_namespace) |namespace| &[_][]const u8{namespace} else &.{},
        });
        try startPooledSshTransportRemoteRawWrite(transport, daemon_dispatcher, .{ .kind = .bootstrap_exec, .bytes = exec_bytes });
        transport.state = .bootstrap_writing_exec;
    } else {
        try startPooledSshTransportHandshake(daemon_dispatcher, transport);
    }
}

fn ensurePooledSshTransportRemoteSource(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    fd: c.fd_t,
    kind: PooledSshTransportRemoteSourceKind,
) !void {
    if (transport.remote_source.isInitialized() and transport.remote_source_kind != kind) {
        transport.remote_task.deinit();
        transport.remote_source.deinit();
        transport.remote_source_kind = .none;
    }
    if (!transport.remote_source.isInitialized()) {
        transport.remote_source = switch (kind) {
            .none => return error.InvalidPooledSshTransportRemoteSource,
            // Bootstrap output is line-oriented and immediately followed by
            // framed protocol. Reading one byte at a time avoids consuming the
            // first frame bytes before we switch this fd to a FrameSource.
            .bootstrap_byte => try daemon_dispatcher.byteSource(fd, 1),
            .frame => try daemon_dispatcher.frameSource(fd),
        };
        transport.remote_source_kind = kind;
        transport.remote_task = dispatcher.dispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            readPooledSshTransportRemote,
        );
        transport.remote_task.setSourceReadiness(.any);
    }
    try updatePooledSshTransportRemoteReadSource(daemon_dispatcher, transport);
}

fn ensurePooledSshTransportStderrSource(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (!transport.stderr_source.isInitialized()) {
        transport.stderr_source = try daemon_dispatcher.byteSource(transport.stderr_fd, 4096);
        transport.stderr_task = dispatcher.dispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            readPooledSshTransportStderr,
        );
        transport.stderr_task.setSourceReadiness(.any);
        try transport.stderr_task.requireSource(transport.stderr_source);
    }
    try transport.stderr_task.schedule(daemon_dispatcher);
}

fn failStartingPooledSshTransport(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    err: anyerror,
) void {
    // Startup failure belongs to every client waiting on this pool. Notify each
    // one with a transport error before the shared SSH process is closed.
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport startup failed host={s} pool={s} error={t}",
        .{ transport.display_host, transport.key, err },
    );
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        _ = failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
            .code = "SSH_TRANSPORT_FAILED",
            .message = "ssh transport failed",
        });
        if (index < transport.clients.items.len and transport.clients.items[index] == client) {
            index += 1;
        }
    }
    if (transport.clients.items.len == 0) finishPooledSshTransport(daemon_dispatcher, transport);
}

/// Queue a cleanup request for a stale remote process, using the same pooled
/// transport machinery as user traffic. This may create a transport whose only
/// purpose is to deliver cleanup bookkeeping.
pub fn enqueueCleanupRequestToRemote(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    record: daemon_cleanup.Record,
) !void {
    var options = [_][]const u8{ "-l", record.endpoint.user, "-p", record.endpoint.port };
    const target = SshTarget{
        .options = &options,
        .host = record.endpoint.host,
        .resolved_user = record.endpoint.user,
        .resolved_host = record.endpoint.host,
        .resolved_port = record.endpoint.port,
    };
    var request = pb.ClientDaemonItem.SshTransportAcquire{
        .host = record.endpoint.host,
        .bootstrap = true,
    };
    defer ssh_transport_acquire.deinitOwnedFields(allocator, &request);
    try ssh_transport_acquire.appendCurrentSshAgent(allocator, &request);

    const acquire = try pooled_ssh_registry.findOrCreate(allocator, target, request);
    try acquire.transport.cleanup_queue.enqueueRecord(allocator, record);

    if (acquire.created) {
        startNewPooledSshTransport(.{
            .allocator = allocator,
            .daemon_dispatcher = daemon_dispatcher,
            .transport = acquire.transport,
            .target = target,
            .request = request,
        }) catch |err| {
            finishPooledSshTransport(daemon_dispatcher, acquire.transport);
            return err;
        };
    } else if (acquire.transport.state == .ready) {
        try startNextPendingCleanupRequest(daemon_dispatcher, acquire.transport);
    }
}

fn readPooledSshTransportRemote(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    _: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    readPooledSshTransportRemoteInner(transport, daemon_dispatcher) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
        return .done;
    };
    return .pending;
}

// Read from the OpenSSH stdout side of the pooled tunnel. Startup states consume
// bootstrap lines or hello frames; ready state reads multiplexed daemon frames
// until backpressure pauses remote reads.
fn readPooledSshTransportRemoteInner(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    switch (transport.state) {
        .bootstrap_writing_exec, .bootstrap_writing_upload => return,
        .bootstrap_wait_line => {
            try readPooledSshTransportBootstrapLine(daemon_dispatcher, transport);
            return;
        },
        .handshake_wait_hello_ok, .handshake_wait_peer_hello => {
            try readPooledSshTransportHandshake(daemon_dispatcher, transport);
            return;
        },
        .starting, .ready, .closing, .closed => {},
    }

    if (transport.remote_read_paused) return;
    while (true) {
        switch (transport.remote_source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                notifyPooledSshTransportRemoteClosed(daemon_dispatcher, transport);
                return;
            },
            else => return err,
        }) {
            .blocked => return,
            .eof => {
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
) !void {
    // The remote bootstrapper emits line-oriented progress before the sessh
    // framed tunnel exists. Accumulate one bounded line at a time from SSH
    // stdout, then feed it to the bootstrap state machine.
    while (transport.bootstrap_line.items.len < 4096) {
        const read = transport.remote_source.readBytes() orelse return;
        switch (read) {
            .eof => {
                failPooledSshTransportBootstrapRead(daemon_dispatcher, transport, error.EndOfStream);
                return;
            },
            .bytes => |bytes| {
                for (bytes) |byte| {
                    if (byte == '\n') {
                        const line = try transport.bootstrap_line.toOwnedSlice(transport.allocator);
                        defer transport.allocator.free(line);
                        transport.bootstrap_line = .empty;
                        try handlePooledSshTransportBootstrapLine(daemon_dispatcher, transport, line);
                        return;
                    }
                    try transport.bootstrap_line.append(transport.allocator, byte);
                    if (transport.bootstrap_line.items.len >= 4096) break;
                }
            },
        }
    }
    failPooledSshTransportBootstrapRead(daemon_dispatcher, transport, error.BootstrapLineTooLong);
}

// The remote bootstrap protocol is intentionally line-oriented until the
// daemon tunnel can begin. This handler is the boundary between that simple
// setup language and the framed sessh protocol: it either starts the daemon
// handshake, uploads the matching artifact, or fails every client waiting on
// this pooled transport.
fn handlePooledSshTransportBootstrapLine(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    line: []const u8,
) !void {
    transport.bootstrap_failure_task.cancel();
    transport.bootstrap_failure_started_ms = 0;
    transport.bootstrap_failure_error = null;

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
            failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapInvalidResponse });
            return;
        };
        const artifacts = if (transport.bootstrap_artifacts) |*value| value else {
            failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapFailed });
            return;
        };
        const artifact = artifacts.find(remote_platform) orelse {
            if (artifactFilenameForPlatform(remote_platform) == null) {
                for (transport.clients.items) |client| {
                    _ = failPooledSshTransportClientWithError(
                        pooledClientContext(daemon_dispatcher, client),
                        .{
                            .code = "UNSUPPORTED_REMOTE_PLATFORM",
                            .message = "remote platform is unsupported and no matching sessh binary is available",
                        },
                    );
                }
                failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.UnsupportedRemotePlatform });
                return;
            }
            failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapFailed });
            return;
        };
        daemon_log.infof(
            transport.allocator,
            "bootstrap upload required host={s} platform={s}/{s}",
            .{ transport.display_host, remote_platform.os, remote_platform.arch },
        );
        sendPooledSshTransportConnectionEvent(daemon_dispatcher, transport, .{ .binary_bootstrapping = .{} });
        const upload = try bootstrap_client.buildUploadBytes(transport.allocator, artifact);
        try startPooledSshTransportRemoteRawWrite(transport, daemon_dispatcher, .{ .kind = .bootstrap_upload, .bytes = upload });
        transport.state = .bootstrap_writing_upload;
        transport.uploaded_bootstrap_artifact = true;
        return;
    }

    if (std.mem.startsWith(u8, line, "ERR UNSUPPORTED_PLATFORM ")) {
        for (transport.clients.items) |client| {
            _ = failPooledSshTransportClientWithError(
                pooledClientContext(daemon_dispatcher, client),
                .{
                    .code = "UNSUPPORTED_REMOTE_PLATFORM",
                    .message = "remote platform is unsupported and no matching sessh binary is available",
                },
            );
        }
        failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.UnsupportedRemotePlatform });
        return;
    }

    if (std.mem.startsWith(u8, line, "ERR ")) {
        daemon_log.infof(transport.allocator, "remote bootstrap failed host={s} line={s}", .{ transport.display_host, line });
        failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapFailed });
        return;
    }

    daemon_log.infof(transport.allocator, "unexpected bootstrap response host={s} line={s}", .{ transport.display_host, line });
    failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapInvalidResponse });
}

fn startPooledSshTransportHandshake(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    try ensurePooledSshTransportRemoteSource(
        daemon_dispatcher,
        transport,
        transport.connection.?.stdoutFd(),
        .frame,
    );
    sendPooledSshTransportConnectionEvent(daemon_dispatcher, transport, .{ .daemon_connecting = .{} });
    const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloRequest{
        .protocol_major = config.protocol_major,
        .protocol_minor = config.protocol_minor,
        .version = config.version,
    });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .hello_request, .payload = payload, .kind = .hello_request });
}

fn readPooledSshTransportHandshake(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    // Once bootstrap has exec'd the remote bridge, stdout becomes framed sessh
    // protocol. Complete the hello exchange before activating queued logical
    // clients on the pooled transport.
    while (true) {
        switch (transport.remote_source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.EndOfStream });
                return;
            },
            else => return err,
        }) {
            .blocked => return,
            .eof => {
                failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.EndOfStream });
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

// Complete the daemon-to-daemon compatibility handshake on a pooled transport.
// The transport becomes ready only after both directions have accepted hello.
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
                failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.VersionMismatch });
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
                    try startPooledSshTransportRemoteHelloError(transport, daemon_dispatcher, .{
                        .code = "VERSION_MISMATCH",
                        .message = "sesshd is incompatible with this client",
                    });
                    return;
                }
                const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloOk{});
                defer transport.allocator.free(payload);
                try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .hello_ok, .payload = payload, .kind = .hello_ok });
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
    // The remote daemon tunnel is ready. Wake queued clients, emit connection
    // diagnostics, and then drain any cleanup work that was waiting for a live
    // transport to this host.
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

const PooledSshTransportFailure = struct {
    err: anyerror,
    term: ?std.process.Child.Term = null,
};

// Fail every client waiting on a transport that never reached ready. Where
// possible, report ssh's own exit/stderr shape so visible sessh behavior remains
// close to plain ssh.
fn failPooledSshTransportStartup(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    failure: PooledSshTransportFailure,
) void {
    const err = failure.err;
    const term = failure.term;
    daemon_log.infof(transport.allocator, "ssh transport failed host={s} error={t}", .{ transport.display_host, err });
    const target = pooledTransportTarget(transport);
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        const reported = startPooledClientSshFailure(pooledClientContext(daemon_dispatcher, client), target, term) catch false;
        if (!reported and err == error.VersionMismatch) {
            _ = failPooledSshTransportClientWithError(
                pooledClientContext(daemon_dispatcher, client),
                .{
                    .code = "VERSION_MISMATCH",
                    .message = "sesshd is incompatible with this client",
                },
            );
        } else if (!reported and err != error.UnsupportedRemotePlatform) {
            _ = failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                .code = "SSH_TRANSPORT_FAILED",
                .message = "ssh transport failed",
            });
        } else if (!reported) {
            if (!finishPooledClientAfterCurrentWrite(client, .none)) {
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
    daemon_log.infof(transport.allocator, "bootstrap read failed host={s} error={t}", .{ transport.display_host, err });
    if (pollPooledSshTransportExit(transport)) |term| {
        daemon_log.infof(transport.allocator, "bootstrap read observed ssh exit host={s}", .{transport.display_host});
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, .{ .err = err, .term = term });
        return;
    }
    schedulePooledSshTransportBootstrapExitPoll(daemon_dispatcher, transport, err);
}

fn failPooledSshTransportBootstrap(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    failure: PooledSshTransportFailure,
) void {
    const err = failure.err;
    const stage: []const u8 = if (transport.uploaded_bootstrap_artifact) "after upload" else "before response";
    daemon_log.infof(
        transport.allocator,
        "bootstrap failed {s} host={s} error={t}",
        .{ stage, transport.display_host, err },
    );
    if (transport.connection) |*connection| connection.closeStdin();
    _ = forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch {};
    failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.SshBootstrapFailed, .term = failure.term });
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
    // After bootstrap read failure, briefly poll the SSH process for its final
    // exit term so the user sees the best available failure message.
    const now_ms = daemon_dispatcher.nowMs();
    if (transport.bootstrap_failure_started_ms == 0) {
        transport.bootstrap_failure_started_ms = now_ms;
        transport.bootstrap_failure_error = err;
    }
    const elapsed_ms = now_ms -| transport.bootstrap_failure_started_ms;
    if (elapsed_ms >= bootstrap_process_exit_timeout_ms) {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, .{ .err = transport.bootstrap_failure_error orelse err });
        return;
    }
    const remaining_ms = bootstrap_process_exit_timeout_ms - elapsed_ms;
    if (!transport.bootstrap_failure_task.isInitialized()) {
        transport.bootstrap_failure_task = dispatcher.timerDispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            pollPooledSshTransportBootstrapExit,
        );
    }
    transport.bootstrap_failure_task.setTimerAfter(daemon_dispatcher, @min(bootstrap_process_exit_poll_ms, remaining_ms));
    transport.bootstrap_failure_task.schedule(daemon_dispatcher) catch {
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, .{ .err = transport.bootstrap_failure_error orelse err });
        return;
    };
}

fn schedulePooledSshTransportBootstrapExitWatch(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) void {
    // The usual bootstrap failure signal is stdout EOF, but some ssh
    // implementations and tests can exit before that pipe reports hangup to
    // poll(2). While we are waiting for the line-oriented bootstrap response,
    // poll the child too so failures still carry ssh's stderr and exit status.
    if (transport.bootstrap_failure_error != null) return;
    if (!transport.bootstrap_failure_task.isInitialized()) {
        transport.bootstrap_failure_task = dispatcher.timerDispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            pollPooledSshTransportBootstrapExit,
        );
    }
    transport.bootstrap_failure_task.setTimerAfter(daemon_dispatcher, bootstrap_process_exit_poll_ms);
    transport.bootstrap_failure_task.schedule(daemon_dispatcher) catch {};
}

fn pollPooledSshTransportBootstrapExit(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
    _: dispatcher.TimerEvent,
) !dispatch_io.DispatchTaskStatus {
    const err = transport.bootstrap_failure_error orelse {
        if (transport.state != .bootstrap_wait_line) return .done;
        if (pollPooledSshTransportExit(transport)) |term| {
            failPooledSshTransportBootstrap(daemon_dispatcher, transport, .{ .err = error.EndOfStream, .term = term });
            return .done;
        }
        task.setTimerAfter(daemon_dispatcher, bootstrap_process_exit_poll_ms);
        return .pending;
    };
    if (pollPooledSshTransportExit(transport)) |term| {
        daemon_log.infof(transport.allocator, "bootstrap exit poll observed ssh exit host={s}", .{transport.display_host});
        failPooledSshTransportBootstrap(daemon_dispatcher, transport, .{ .err = err, .term = term });
        return .done;
    }
    schedulePooledSshTransportBootstrapExitPoll(daemon_dispatcher, transport, err);
    return .pending;
}

fn sendPooledSshTransportConnectionEvent(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    event: pb.ConnectionEvent.event_union,
) void {
    // Connection events are for foreground clients, not raw fd-pass proxy
    // streams. Pause remote reads if starting those writes consumed the shared
    // write slot, preserving mux ordering.
    var started_write = false;
    for (transport.clients.items) |client| {
        if (client.state == .done) continue;
        if (client.raw_proxy != null) continue;
        if (client.write_kind != null or client.sink.hasPendingWrite()) continue;
        startPooledClientConnectionEvent(pooledClientContext(daemon_dispatcher, client), event, .forwarded_from_daemon) catch |err| {
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

fn readPooledSshTransportStderr(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    // OpenSSH stderr is diagnostic data that may arrive before, during, or after
    // mux startup. Forward what is readable, then cancel the stderr task once
    // the pipe closes.
    forwardPooledSshTransportStderr(daemon_dispatcher, transport) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport stderr failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        transport.stderr_task.cancel();
        return .done;
    };
    return if (transport.stderr_source.isInitialized()) .pending else .done;
}

fn writePooledSshTransportRemote(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    writePooledSshTransportRemoteInner(transport, daemon_dispatcher) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport remote write failed host={s} pool={s} error={t}",
            .{ transport.display_host, transport.key, err },
        );
        if (pooledSshTransportIsBootstrapping(transport)) {
            waitForBootstrapReadAfterWriteFailure(daemon_dispatcher, transport);
        } else {
            failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = err, .term = pollPooledSshTransportExit(transport) });
        }
        return .done;
    };
    return .pending;
}

fn waitForBootstrapReadAfterWriteFailure(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) void {
    transport.stdin_task.cancel();
    if (transport.remote_write_kind) |*kind| {
        kind.deinit(transport.allocator);
        transport.remote_write_kind = null;
    }
    transport.stdin_sink.deinit();
    if (transport.connection) |*connection| connection.closeStdin();
    transport.state = .bootstrap_wait_line;
    schedulePooledSshTransportBootstrapExitWatch(daemon_dispatcher, transport);
}

// Advance the single pending write to the remote daemon tunnel. There is only
// one transport-level write in flight at a time so the stream frame ordering on
// the shared SSH stdin pipe stays explicit.
fn writePooledSshTransportRemoteInner(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    if (transport.stdin_sink.takeWriteError()) |err| return err;
    if (transport.stdin_sink.hasPendingWrite()) return;

    var completed = transport.remote_write_kind.?;
    transport.remote_write_kind = null;
    transport.stdin_task.cancel();

    switch (completed) {
        .raw => |kind| {
            switch (kind) {
                .bootstrap_exec, .bootstrap_upload => {
                    transport.state = .bootstrap_wait_line;
                    schedulePooledSshTransportBootstrapExitWatch(daemon_dispatcher, transport);
                },
            }
        },
        .frame => |*frame| try completePooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, frame),
    }
}

// Apply the state transition associated with a completed remote frame write.
// See proto/sessh.proto's MuxStreamFrame comments for "mux envelope" and "typed
// payload" terminology. During stream startup, client reads stay paused until
// both the envelope open and typed open payload are on the shared tunnel.
fn completePooledSshTransportRemoteFrameWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: *PooledSshTransportFrameWriteKind,
) !void {
    switch (frame.*) {
        .hello_request => transport.state = .handshake_wait_hello_ok,
        .hello_ok => completePooledSshTransportStartup(daemon_dispatcher, transport),
        .hello_error => failPooledSshTransportStartup(daemon_dispatcher, transport, .{ .err = error.VersionMismatch }),
        .pong => {
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
        .client_mux_envelope_open => |*open| {
            const typed_open_bytes = open.typed_open_bytes;
            const client = open.client;
            open.typed_open_bytes = &.{};
            try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{
                .bytes = typed_open_bytes,
                .kind = .{ .client_to_daemon = client },
            });
            return;
        },
        .client_to_daemon => |client| {
            if (client.state == .opening_stream) client.state = .active;
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            if (!pooledSshTransportHasClientWrites(transport)) {
                try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            }
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
        .proxy_ack, .remote_process_recorded, .cleanup_request => {
            if (frame.* == .cleanup_request) {
                daemon_log.infof(
                    transport.allocator,
                    "cleanup request sent host={s} in_flight={}",
                    .{ transport.display_host, transport.cleanup_queue.inFlightCount() },
                );
            }
            try resumePooledSshTransportClientReads(daemon_dispatcher, transport);
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startNextPendingCleanupRequest(daemon_dispatcher, transport);
        },
    }
}

const PooledRemoteRawWriteRequest = struct {
    kind: PooledSshTransportRawWriteKind,
    bytes: []u8,
};

fn startPooledSshTransportRemoteRawWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    request: PooledRemoteRawWriteRequest,
) !void {
    if (transport.remote_write_kind != null) return error.PooledSshTransportWriteAlreadyQueued;
    defer transport.allocator.free(request.bytes);
    try queuePooledSshTransportRemoteBytes(transport, daemon_dispatcher, request.bytes, .{ .raw = request.kind });
}

const PooledRemoteFrameWriteRequest = struct {
    message_type: protocol.MessageType,
    payload: []const u8,
    kind: PooledSshTransportFrameWriteKind,
};

fn startPooledSshTransportRemoteFrameWrite(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    request: PooledRemoteFrameWriteRequest,
) !void {
    const frame_bytes = try protocol.encodeFrame(transport.allocator, request.message_type, request.payload);
    defer transport.allocator.free(frame_bytes);
    try queuePooledSshTransportRemoteBytes(transport, daemon_dispatcher, frame_bytes, .{ .frame = request.kind });
}

fn startPooledSshTransportRemoteHelloError(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    info: protocol.ErrorInfo,
) !void {
    const payload = try protocol.encodePayload(transport.allocator, protocol.hpb.HelloError{
        .code = info.code,
        .message = info.message,
        .hint = info.hint,
    });
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .hello_error, .payload = payload, .kind = .hello_error });
}

const PooledRemoteFrameBytesRequest = struct {
    bytes: []u8,
    kind: PooledSshTransportFrameWriteKind,
};

fn startPooledSshTransportRemoteFrameBytes(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    request: PooledRemoteFrameBytesRequest,
) !void {
    defer transport.allocator.free(request.bytes);
    try queuePooledSshTransportRemoteBytes(transport, daemon_dispatcher, request.bytes, .{ .frame = request.kind });
}

fn ensurePooledSshTransportRemoteWritable(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    min_pending_bytes: usize,
) !void {
    const max_pending_bytes = @max(dispatch_io.default_byte_sink_max_pending_bytes, min_pending_bytes);
    if (!transport.stdin_sink.isInitialized()) {
        transport.stdin_sink = try daemon_dispatcher.byteSink(.{
            .allocator = transport.allocator,
            .fd = transport.connection.?.stdinFd(),
            .max_pending_bytes = max_pending_bytes,
        });
        transport.stdin_task = dispatcher.dispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            writePooledSshTransportRemote,
        );
        transport.stdin_task.setSourceReadiness(.any);
        try transport.stdin_task.requireSink(transport.stdin_sink);
    } else {
        // Bootstrap upload is a single shell-protocol line containing the
        // base64 artifact. It can be larger than the default byte-sink bound,
        // but it is still a one-shot startup write rather than unbounded
        // steady-state buffering. Grow this sink only to the current write.
        const sink = transport.stdin_sink.byte();
        sink.max_pending_bytes = @max(sink.max_pending_bytes, max_pending_bytes);
    }
}

fn queuePooledSshTransportRemoteBytes(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    bytes: []const u8,
    kind: PooledSshTransportRemoteWriteKind,
) !void {
    if (transport.remote_write_kind != null or transport.stdin_sink.hasPendingWrite()) {
        var cleanup_kind = kind;
        cleanup_kind.deinit(transport.allocator);
        return error.PooledSshTransportWriteAlreadyQueued;
    }
    errdefer {
        if (transport.remote_write_kind) |*pending_kind| {
            pending_kind.deinit(transport.allocator);
            transport.remote_write_kind = null;
        }
    }
    try ensurePooledSshTransportRemoteWritable(transport, daemon_dispatcher, bytes.len);
    transport.remote_write_kind = kind;
    try transport.stdin_sink.writeBytes(bytes);
    try transport.stdin_task.schedule(daemon_dispatcher);
}

fn readPooledSshTransportClient(
    client: *PooledSshTransportClient,
    daemon_dispatcher: *dispatcher.Dispatcher,
    _: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    const transport = client.transport;
    readPooledSshTransportClientInner(client, daemon_dispatcher) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "pooled ssh transport client failed host={s} pool={s} stream_id={} error={t}",
            .{ transport.display_host, transport.key, client.stream_id, err },
        );
        finishPooledSshTransportClient(pooledClientContext(daemon_dispatcher, client), .send);
        return .done;
    };
    return .pending;
}

// Service one local client attached to the pool. Reads are paused whenever the
// shared remote tunnel already has an in-flight write, preserving frame order and
// giving backpressure a single place to act.
fn readPooledSshTransportClientInner(
    client: *PooledSshTransportClient,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    const transport = client.transport;
    if (client.write_kind != null and !try writePooledSshTransportClient(pooledClientContext(daemon_dispatcher, client))) return;
    if (client.read_paused or transport.remote_write_kind != null or client.write_kind != null) {
        if (transport.remote_write_kind != null) client.read_paused = true;
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
        return;
    }
    // Clients may pipeline acquire + terminal/proxy open before the pooled SSH
    // transport is ready. Do not read that open while still pending transport;
    // the pending-state handler intentionally has no remote stream to attach it
    // to yet.
    if (!pooledSshTransportClientReadable(client)) {
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
        return;
    }

    if (client.raw_proxy != null) {
        try readPooledRawProxyClient(pooledClientContext(daemon_dispatcher, client));
        return;
    }

    while (true) {
        switch (client.source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => {
                finishPooledSshTransportClient(pooledClientContext(daemon_dispatcher, client), .send);
                return;
            },
            else => return err,
        }) {
            .blocked => return,
            .eof => {
                finishPooledSshTransportClient(pooledClientContext(daemon_dispatcher, client), .send);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                const alive = try handlePooledSshTransportClientFrame(pooledClientContext(daemon_dispatcher, client), &frame);
                frame.deinit(transport.allocator);
                if (!alive) return;
                if (client.read_paused or transport.remote_write_kind != null or client.write_kind != null) return;
            },
        }
    }
}

// Advance a queued write back to one local client. Completing a client write can
// unblock remote reads or emit a raw-proxy ACK, so the caller uses the boolean to
// know whether the client survived the write.
fn writePooledSshTransportClient(ctx: PooledClientContext) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    if (client.sink.hasPendingWrite()) return true;
    const kind = client.write_kind orelse return true;
    client.write_kind = null;
    const completed_raw = client.write_is_raw;
    client.write_is_raw = false;

    switch (kind) {
        .forwarded_from_daemon => {},
        .finish_after_write => |finish| {
            finishPooledSshTransportClient(ctx, RemoteHangup.fromBool(finish.send_hangup));
            return false;
        },
    }
    if (try startNextQueuedPooledSshTransportClientFrameWrite(ctx)) {
        return true;
    }
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);

    if (!pooledSshTransportHasClientWrites(transport)) {
        if (completed_raw and client.raw_proxy != null and client.state != .done) {
            try sendPooledRawProxyAck(ctx);
        } else {
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        }
    }
    return true;
}

fn pooledSshTransportHasClientWrites(transport: *const PooledSshTransport) bool {
    for (transport.clients.items) |client| {
        if (client.state != .done and (client.write_kind != null or client.pending_frame_writes.hasPending() or client.sink.hasPendingWrite())) return true;
    }
    return false;
}

// Read raw bytes from the fd passed to OpenSSH's ProxyUseFdPass path and wrap
// them as proxy mux data with monotonically increasing outbound offsets.
fn readPooledRawProxyClient(ctx: PooledClientContext) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    while (true) {
        const read = client.source.readBytes() orelse return;
        const bytes = switch (read) {
            .bytes => |bytes| bytes,
            .eof => {
                finishPooledSshTransportClient(ctx, .send);
                return;
            },
        };
        const offset = client.outbound_next_offset;
        const frame_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(
            transport.allocator,
            protocol.proxyMuxPayloadFromPayloadFrame(client.stream_id, offset, .{ .data = bytes }),
        );
        errdefer transport.allocator.free(frame_bytes);
        client.outbound_next_offset +|= bytes.len;
        client.read_paused = true;
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
        try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
        try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{ .bytes = frame_bytes, .kind = .{ .client_to_daemon = client } });
        return;
    }
}

fn sendPooledRawProxyAck(ctx: PooledClientContext) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const payload = try mux_tunnel.encodeAckPayload(transport.allocator, client.stream_id, client.inbound_next_offset);
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = payload, .kind = .proxy_ack });
}

fn sendPooledRawProxyOpenOk(ctx: PooledClientContext) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const payload = try mux_tunnel.encodeOpenOkPayload(transport.allocator, client.stream_id, client.inbound_next_offset);
    defer transport.allocator.free(payload);
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = payload, .kind = .proxy_ack });
}

fn sendPooledRawProxyFdPassAccepted(ctx: PooledClientContext) !void {
    // Acknowledge ProxyUseFdPass setup only after the daemon has accepted the raw
    // fd and associated it with a mux stream. The setup fd is closed after this
    // one-shot response.
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const client = ctx.client;
    const setup_fd = blk: {
        if (client.raw_proxy) |*raw_proxy| {
            break :blk raw_proxy.takeSetupFd() orelse return;
        }
        return;
    };
    errdefer _ = c.close(setup_fd);

    daemon_log.infof(client.transport.allocator, "proxy fd-pass setup accepted guid={s}", .{client.proxy_guid.slice()});
    const payload = try protocol.encodeClientDaemonPayload(client.transport.allocator, .{ .proxy_fd_pass_accepted = .{} });
    defer client.transport.allocator.free(payload);
    try one_shot_frame_writer.registerFrameAndClose(.{
        .allocator = client.transport.allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .fd = setup_fd,
        .message_type = .client_daemon,
        .payload = payload,
    });
}

const PooledClientFrameWriteRequest = struct {
    message_type: protocol.MessageType,
    payload: []const u8,
    kind: PooledSshTransportClientWriteKind,
};

fn startPooledSshTransportClientFrameWrite(ctx: PooledClientContext, request: PooledClientFrameWriteRequest) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const client = ctx.client;
    if (client.write_kind != null or client.sink.hasPendingWrite()) {
        try client.pending_frame_writes.appendFrame(request.message_type, request.payload, request.kind);
        try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
        return;
    }
    try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
    try client.sink.frame().writeFrame(request.message_type, request.payload);
    client.write_kind = request.kind;
    client.write_is_raw = false;
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
}

fn startNextQueuedPooledSshTransportClientFrameWrite(ctx: PooledClientContext) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const client = ctx.client;
    if (client.write_kind != null or client.sink.hasPendingWrite()) return false;
    var next = client.pending_frame_writes.popFirst() orelse return false;
    defer next.deinit(client.transport.allocator);
    try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
    try client.sink.frame().writeFrame(next.message_type, next.payload);
    client.write_kind = next.kind;
    client.write_is_raw = false;
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    return true;
}

fn startPooledSshTransportClientRawWrite(
    ctx: PooledClientContext,
    bytes: []u8,
    kind: PooledSshTransportClientWriteKind,
) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const client = ctx.client;
    defer client.transport.allocator.free(bytes);
    if (client.write_kind != null or client.pending_frame_writes.hasPending() or client.sink.hasPendingWrite()) return error.PooledSshTransportClientWriteAlreadyQueued;
    try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
    try client.sink.byte().writeBytes(bytes);
    client.write_kind = kind;
    client.write_is_raw = true;
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
}

fn startPooledClientConnectionEvent(
    ctx: PooledClientContext,
    event: pb.ConnectionEvent.event_union,
    kind: PooledSshTransportClientWriteKind,
) !void {
    const client = ctx.client;
    const payload = try protocol.encodeConnectionEventPayload(client.transport.allocator, event);
    defer client.transport.allocator.free(payload);
    try startPooledSshTransportClientFrameWrite(ctx, .{ .message_type = .client_daemon, .payload = payload, .kind = kind });
}

const PooledClientTransportError = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8 = "",
    kind: PooledSshTransportClientWriteKind,
};

fn startPooledClientTransportError(ctx: PooledClientContext, error_info: PooledClientTransportError) !void {
    const client = ctx.client;
    const payload = try protocol.encodeErrorPayload(client.transport.allocator, .{
        .code = error_info.code,
        .message = error_info.message,
        .hint = error_info.hint,
    });
    defer client.transport.allocator.free(payload);
    try startPooledSshTransportClientFrameWrite(ctx, .{ .message_type = .error_message, .payload = payload, .kind = error_info.kind });
}

const RemoteHangup = enum {
    none,
    send,

    fn shouldSend(self: RemoteHangup) bool {
        return self == .send;
    }

    fn fromBool(send_hangup: bool) RemoteHangup {
        return if (send_hangup) .send else .none;
    }
};

fn finishPooledClientAfterCurrentWrite(client: *PooledSshTransportClient, hangup: RemoteHangup) bool {
    if (client.write_kind != null or client.sink.hasPendingWrite()) {
        client.write_kind = .{ .finish_after_write = .{ .send_hangup = hangup.shouldSend() } };
        return true;
    }
    return false;
}

const PooledClientError = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8 = "",
    // Some protocol errors must finish the current frame before telling the
    // remote side the stream is done. That preserves frame ordering while still
    // letting the failure path request a clean hang up.
    send_hangup: bool = false,
};

const PooledClientContext = struct {
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
};

fn pooledClientContext(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) PooledClientContext {
    return .{
        .daemon_dispatcher = daemon_dispatcher,
        .transport = client.transport,
        .client = client,
    };
}

fn failPooledSshTransportClientWithError(ctx: PooledClientContext, error_info: PooledClientError) bool {
    const client = ctx.client;
    const hangup = RemoteHangup.fromBool(error_info.send_hangup);
    if (finishPooledClientAfterCurrentWrite(client, hangup)) return false;
    startPooledClientTransportError(ctx, .{
        .code = error_info.code,
        .message = error_info.message,
        .hint = error_info.hint,
        .kind = .{ .finish_after_write = .{ .send_hangup = error_info.send_hangup } },
    }) catch {
        finishPooledSshTransportClient(ctx, hangup);
    };
    return false;
}

fn closeIdlePooledSshTransport(
    transport: *PooledSshTransport,
    daemon_dispatcher: *dispatcher.Dispatcher,
    task: *dispatcher.DispatchTask,
    _: dispatcher.TimerEvent,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    // Idle close is delayed so short sequential sessh invocations can reuse the
    // SSH connection. Any active client, cleanup request, or non-idle state
    // cancels the close attempt.
    if (transport.clients.items.len != 0 or
        transport.cleanup_queue.hasWork() or
        transport.state == .closed) return .done;
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport idle host={s} pool={s}",
        .{ transport.display_host, transport.key },
    );
    finishPooledSshTransport(daemon_dispatcher, transport);
    return .done;
}

// Move clients waiting on transport startup into stream-opening state once the
// pooled tunnel is ready. Each client gets a fresh remote stream id from the
// transport's pool.
fn activatePendingPooledSshTransportClients(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    transport.idle_task.cancel();
    transport.bootstrap_failure_task.cancel();
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client.state != .pending_transport) {
            index += 1;
            continue;
        }
        client.stream_id = transport.stream_ids.take();
        client.state = .opening_stream;
        client.read_paused = false;
        if (client.raw_proxy != null) {
            sendPooledRawProxyMuxOpen(pooledClientContext(daemon_dispatcher, client)) catch {
                destroyPooledSshTransportClient(daemon_dispatcher, transport, client);
                continue;
            };
        } else ensurePooledSshTransportClientSource(daemon_dispatcher, client) catch {
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
        transport.cleanup_queue.hasWork() or
        transport.remote_write_kind != null or
        transport.idle_task.isScheduled()) return;
    if (!transport.idle_task.isInitialized()) {
        transport.idle_task = dispatcher.timerDispatchTask(
            PooledSshTransport,
            transport.allocator,
            transport,
            closeIdlePooledSshTransport,
        );
    }
    transport.idle_task.setTimerAfter(daemon_dispatcher, @intCast(pooled_ssh_transport_idle_close_ms));
    transport.idle_task.schedule(daemon_dispatcher) catch {
        finishPooledSshTransport(daemon_dispatcher, transport);
        return;
    };
}

fn beginClosingPooledSshTransport(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    // Stop observing the SSH process before closing it so no further callbacks
    // race against teardown. Clients are failed/finished by the caller or close
    // path that requested this transition.
    _ = daemon_dispatcher;
    if (transport.state == .closed or transport.state == .closing) return;
    transport.state = .closing;
    transport.remote_task.cancel();
    transport.stderr_task.cancel();
    transport.stdin_task.cancel();
    transport.idle_task.cancel();
    transport.bootstrap_failure_task.cancel();
    pooled_ssh_registry.remove(transport);
}

fn updatePooledSshTransportRemoteReadSource(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (!transport.remote_source.isInitialized()) return;
    if (!transport.remote_task.isInitialized()) return;
    transport.remote_task.clearSources();
    if (!transport.remote_read_paused) try transport.remote_task.requireSource(transport.remote_source);
    if (transport.remote_task.sources.items.len == 0) {
        transport.remote_task.cancel();
    } else {
        try transport.remote_task.schedule(daemon_dispatcher);
    }
}

fn pausePooledSshTransportRemoteRead(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (transport.remote_read_paused) return;
    transport.remote_read_paused = true;
    try updatePooledSshTransportRemoteReadSource(daemon_dispatcher, transport);
}

fn resumePooledSshTransportRemoteRead(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (!transport.remote_read_paused) return;
    transport.remote_read_paused = false;
    try updatePooledSshTransportRemoteReadSource(daemon_dispatcher, transport);
}

fn updatePooledSshTransportClientSource(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) !void {
    if (!client.source.isInitialized()) return;
    if (!client.task.isInitialized()) return;
    client.task.clearSources();
    client.task.clearSinks();
    if (pooledSshTransportClientReadable(client)) try client.task.requireSource(client.source);
    if (client.write_kind != null or client.sink.hasPendingWrite()) try client.task.requireSink(client.sink);
    if (client.task.sources.items.len == 0 and client.task.sinks.items.len == 0) {
        client.task.cancel();
    } else {
        try client.task.schedule(daemon_dispatcher);
    }
}

fn pooledSshTransportClientReadable(client: *const PooledSshTransportClient) bool {
    return !client.read_paused and client.write_kind == null and !client.sink.hasPendingWrite() and switch (client.state) {
        .opening_stream, .active => true,
        .pending_transport, .done => false,
    };
}

fn desiredPooledSshTransportClientSourceKind(client: *const PooledSshTransportClient) PooledSshTransportClientSourceKind {
    return if (client.raw_proxy != null) .raw_bytes else .frame;
}

fn ensurePooledSshTransportClientSource(
    daemon_dispatcher: *dispatcher.Dispatcher,
    client: *PooledSshTransportClient,
) !void {
    // A pooled client's local fd is either framed sessh IPC or raw proxy bytes.
    // The Dispatcher owns the matching Source/Sink pair so no other state
    // machine can interleave writes to the same fd.
    const desired_kind = desiredPooledSshTransportClientSourceKind(client);
    if (client.source.isInitialized() and client.source_kind != desired_kind) {
        client.task.deinit();
        client.source.deinit();
        client.sink.deinit();
        client.source_kind = .none;
    }
    if (client.source.isInitialized()) {
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
        return;
    }
    switch (desired_kind) {
        .frame => {
            client.source = try daemon_dispatcher.frameSource(client.fd);
            errdefer client.source.deinit();
            client.sink = try daemon_dispatcher.frameSink(.{ .allocator = client.transport.allocator, .fd = client.fd });
            client.source_kind = .frame;
        },
        .raw_bytes => {
            client.source = try daemon_dispatcher.byteSource(client.fd, raw_proxy_read_buffer_len);
            errdefer client.source.deinit();
            client.sink = try daemon_dispatcher.byteSink(.{ .allocator = client.transport.allocator, .fd = client.fd });
            client.source_kind = .raw_bytes;
        },
        .none => unreachable,
    }
    client.task = dispatcher.dispatchTask(
        PooledSshTransportClient,
        client.transport.allocator,
        client,
        readPooledSshTransportClient,
    );
    client.task.setSourceReadiness(.any);
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
}

fn pausePooledSshTransportClientReads(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    for (transport.clients.items) |client| {
        if (client.state == .done or client.read_paused) continue;
        client.read_paused = true;
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    }
}

fn resumePooledSshTransportClientReads(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    for (transport.clients.items) |client| {
        if (client.state == .done or !client.read_paused) continue;
        client.read_paused = false;
        try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    }
}

fn handlePooledSshTransportClientFrame(
    ctx: PooledClientContext,
    frame: *const protocol.OwnedFrame,
) !bool {
    if (try handlePooledSshTransportClientControlFrame(ctx.daemon_dispatcher, ctx.client, frame)) return true;
    return switch (ctx.client.state) {
        .opening_stream => try openPooledSshTransportClientStream(ctx, frame),
        .active => try forwardPooledSshTransportClientFrame(ctx, frame),
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
            try startPooledSshTransportClientFrameWrite(pooledClientContext(daemon_dispatcher, client), .{ .message_type = .daemon_tunnel, .payload = pong_payload, .kind = .forwarded_from_daemon });
            return true;
        },
        .pong => return true,
        else => return false,
    }
}

// Interpret the first frame from a local client as its logical stream open. This
// sets the stream kind, injects filtered environment for terminal creates, and
// starts the mux-open sequence on the shared transport.
fn openPooledSshTransportClientStream(
    ctx: PooledClientContext,
    frame: *const protocol.OwnedFrame,
) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    if (frame.message_type == .daemon_tunnel) {
        try sendPooledProxyMuxOpen(ctx, frame.payload);
        return true;
    }
    if (frame.message_type != .client_remote) {
        return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
            .code = "PROTOCOL_ERROR",
            .message = "expected terminal or proxy stream open",
        });
    }
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(transport.allocator, frame.payload);
    defer item.deinit(transport.allocator);
    const item_payload = if (item.payload) |*payload| payload else {
        return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
            .code = "PROTOCOL_ERROR",
            .message = "expected terminal stream open",
        });
    };
    const open = switch (item_payload.*) {
        .open => |*request| request,
        else => {
            return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                .code = "PROTOCOL_ERROR",
                .message = "expected terminal stream open",
            });
        },
    };
    client.kind = .te;
    try appendFilteredClientEnvironmentToTerminalOpen(transport.allocator, client, open);
    open.isolation_mode = client.isolation_mode;
    try sendPooledTerminalMuxOpen(ctx, open.*);
    return true;
}

// Forward an active client's frames to the matching mux stream. Terminal,
// proxy, and proxy-diagnostics frames are deliberately separated so a client
// cannot switch protocols after opening its stream.
fn forwardPooledSshTransportClientFrame(
    ctx: PooledClientContext,
    frame: *const protocol.OwnedFrame,
) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    switch (frame.message_type) {
        .daemon_tunnel => {
            if (client.kind != .proxy) {
                return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                    .code = "PROTOCOL_ERROR",
                    .message = "unexpected proxy stream frame",
                    .send_hangup = true,
                });
            }
            try sendPooledProxyMuxFrame(ctx, frame.payload);
        },
        .client_remote => {
            if (client.kind != .te) {
                return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                    .code = "PROTOCOL_ERROR",
                    .message = "unexpected terminal stream frame",
                    .send_hangup = true,
                });
            }
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(transport.allocator, frame.payload);
            defer item.deinit(transport.allocator);
            try sendPooledTerminalMuxPayload(ctx, item);
        },
        .client_daemon => {
            if (client.kind != .proxy or !client.proxy_guid.isSet()) {
                return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                    .code = "PROTOCOL_ERROR",
                    .message = "unexpected proxy diagnostics frame",
                    .send_hangup = true,
                });
            }
            try proxy_diagnostics_router.forwardFromStream(.{
                .allocator = transport.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .guid = client.proxy_guid.slice(),
                .frame = frame.*,
            });
        },
        else => {
            return failPooledSshTransportClientWithError(pooledClientContext(daemon_dispatcher, client), .{
                .code = "PROTOCOL_ERROR",
                .message = "unexpected terminal client frame",
                .send_hangup = true,
            });
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
        try client_env.appendFilteredToTerminalCreate(
            allocator,
            client.client_environment.items,
            client.send_env,
            create,
        );
    }
}

// Send terminal stream startup as envelope open followed by typed open payload.
fn sendPooledTerminalMuxOpen(
    ctx: PooledClientContext,
    request: pb.TerminalEmulatorItem.Open,
) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const typed_open_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(
        transport.allocator,
        protocol.terminalMuxPayloadFromPayloadFrame(
            client.stream_id,
            client.outbound_next_offset,
            .{ .open = request },
        ),
    );
    errdefer transport.allocator.free(typed_open_bytes);
    const envelope_open_bytes = try mux_tunnel.encodeMuxEnvelopeOpenFrameBytes(transport.allocator, client.stream_id, client.inbound_next_offset);
    errdefer transport.allocator.free(envelope_open_bytes);
    client.read_paused = true;
    try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{
        .bytes = envelope_open_bytes,
        .kind = .{ .client_mux_envelope_open = .{
            .client = client,
            .typed_open_bytes = typed_open_bytes,
        } },
    });
    client.outbound_next_offset +|= 1;
    client.startup_timing.noteMuxOpenSent();
}

// Remap a framed proxy client's local stream id onto the pooled transport's
// remote stream id before sending the proxy open over the shared tunnel.
fn sendPooledProxyMuxOpen(
    ctx: PooledClientContext,
    payload: []const u8,
) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
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
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{ .bytes = bytes, .kind = .{ .client_to_daemon = client } });
    client.startup_timing.noteMuxOpenSent();
}

// Open a proxy stream for a raw fd-pass client. The local side has no framed
// proxy worker, so this builds the proxy open payload directly from raw_proxy
// metadata.
fn sendPooledRawProxyMuxOpen(ctx: PooledClientContext) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const raw_proxy = if (client.raw_proxy) |*raw_proxy| raw_proxy else return error.MissingProxyHost;
    const typed_open_bytes = try mux_tunnel.encodeMuxStreamFrameBytes(
        transport.allocator,
        protocol.proxyMuxPayloadFromPayloadFrame(client.stream_id, 0, .{ .open = .{
            .proxy_guid = client.proxy_guid.slice(),
            .proxy_host = raw_proxy.host,
            .proxy_port = raw_proxy.port,
        } }),
    );
    errdefer transport.allocator.free(typed_open_bytes);
    const envelope_open_bytes = try mux_tunnel.encodeMuxEnvelopeOpenFrameBytes(transport.allocator, client.stream_id, client.inbound_next_offset);
    errdefer transport.allocator.free(envelope_open_bytes);
    client.read_paused = true;
    try ensurePooledSshTransportClientSource(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{
        .bytes = envelope_open_bytes,
        .kind = .{ .client_mux_envelope_open = .{
            .client = client,
            .typed_open_bytes = typed_open_bytes,
        } },
    });
    client.startup_timing.noteMuxOpenSent();
}

fn sendPooledProxyMuxFrame(
    ctx: PooledClientContext,
    payload: []const u8,
) !void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(transport.allocator, payload);
    defer mux_frame.deinit(transport.allocator);
    if (mux_frame.stream_id != client.local_stream_id) return error.UnexpectedDaemonFrame;
    try maybeRegisterProxyDiagnosticsStream(transport.allocator, client, mux_frame);
    mux_frame.stream_id = client.stream_id;
    const bytes = try mux_tunnel.encodeMuxStreamFrameBytes(transport.allocator, mux_frame);
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{ .bytes = bytes, .kind = .{ .client_to_daemon = client } });
}

// The first proxy open frame carries the proxy guid used by diagnostics. Register
// that guid lazily so later client-daemon diagnostic frames can be routed back to
// this local client fd.
fn maybeRegisterProxyDiagnosticsStream(
    allocator: std.mem.Allocator,
    client: *PooledSshTransportClient,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    if (client.proxy_guid.isSet()) return;
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
    try client.proxy_guid.set(canonical);
    try proxy_diagnostics_router.registerStream(.{
        .allocator = allocator,
        .guid = canonical,
        .fd = client.fd,
        .sink = .{
            .ctx = client,
            .writeFrame = queueProxyDiagnosticsFrameToPooledClient,
        },
    });
}

fn queueProxyDiagnosticsFrameToPooledClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, frame: protocol.OwnedFrame) !void {
    const client: *PooledSshTransportClient = @ptrCast(@alignCast(ctx));
    try startPooledSshTransportClientFrameWrite(pooledClientContext(daemon_dispatcher, client), .{ .message_type = frame.message_type, .payload = frame.payload, .kind = .forwarded_from_daemon });
}

fn sendPooledTerminalMuxPayload(
    ctx: PooledClientContext,
    item: pb.TerminalEmulatorItem,
) !void {
    // Convert a client_remote terminal item into a daemon-tunnel mux payload and
    // pause client reads until that frame is accepted by the shared SSH writer.
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const bytes = try mux_tunnel.encodeMuxStreamFrameBytes(
        transport.allocator,
        protocol.terminalMuxPayloadFrame(client.stream_id, client.outbound_next_offset, item),
    );
    errdefer transport.allocator.free(bytes);
    client.read_paused = true;
    try updatePooledSshTransportClientSource(daemon_dispatcher, client);
    try pausePooledSshTransportClientReads(daemon_dispatcher, transport);
    try startPooledSshTransportRemoteFrameBytes(transport, daemon_dispatcher, .{ .bytes = bytes, .kind = .{ .client_to_daemon = client } });
    client.outbound_next_offset +|= 1;
}

// Dispatch one frame from the remote daemon. Tunnel-level cleanup/control is
// handled on the transport; mux-stream frames are routed to the client that owns
// the remote stream id.
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
            transport.cleanup_queue.noteResponse();
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
            try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = pong_payload, .kind = .pong });
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
    // Transport-control frames are tunnel-level health checks, not logical
    // stream payloads. Handle ping/pong here before stream routing tries to
    // decode the frame as terminal or proxy traffic.
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, transport.allocator, frame.payload);
    defer item.deinit(transport.allocator);
    switch (item.payload orelse return false) {
        .ping => {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            const pong_payload = try protocol.encodeDaemonTunnelPayload(transport.allocator, .{ .pong = .{} });
            defer transport.allocator.free(pong_payload);
            try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = pong_payload, .kind = .pong });
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
    const client = findPooledSshTransportClient(transport, owned_mux_frame.stream_id) orelse {
        return true;
    };
    const client_ctx = pooledClientContext(daemon_dispatcher, client);
    const message = owned_mux_frame.message orelse return error.UnexpectedDaemonFrame;
    if (client.kind == .proxy) {
        if (client.raw_proxy != null) {
            return handlePooledRemoteRawProxyMuxStreamFrame(client_ctx, message);
        }
        return handlePooledRemoteProxyMuxStreamFrame(client_ctx, &owned_mux_frame, message);
    }
    return handlePooledRemoteTerminalMuxStreamFrame(client_ctx, message);
}

fn notePooledMuxOpenOk(client: *PooledSshTransportClient) void {
    client.startup_timing.noteOpenOk();
}

fn notePooledMuxFirstPayload(transport: *PooledSshTransport, client: *PooledSshTransportClient) void {
    if (!client.startup_timing.noteFirstPayload()) return;
    logPooledSshTransportClientStartupTiming(transport, client);
}

// Forward a framed proxy stream frame back to the local proxy client after
// remapping the pooled remote stream id to the client's original local stream id.
fn handlePooledRemoteProxyMuxStreamFrame(
    ctx: PooledClientContext,
    mux_frame: *pb.DaemonTunnelItem.MuxStreamFrame,
    message: protocol.MuxStreamMessage,
) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
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
    try startPooledSshTransportClientFrameWrite(ctx, .{ .message_type = .daemon_tunnel, .payload = payload, .kind = .forwarded_from_daemon });
    return true;
}

// Forward terminal mux output to the visible client. Reset and EOF are terminal
// stream endings, while payload frames are rewrapped as client_remote messages.
fn handlePooledRemoteTerminalMuxStreamFrame(
    ctx: PooledClientContext,
    message: protocol.MuxStreamMessage,
) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    switch (message) {
        .open_ok => notePooledMuxOpenOk(client),
        .ack => {},
        .payload => |payload| try handlePooledRemoteTerminalMuxPayload(ctx, payload),
        .reset => |reset| {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try startPooledClientTransportError(ctx, .{
                .code = reset.code,
                .message = reset.message,
                .hint = reset.hint orelse "",
                .kind = .{ .finish_after_write = .{ .send_hangup = false } },
            });
        },
        .eof => {
            notePooledMuxFirstPayload(transport, client);
            if (finishPooledClientAfterCurrentWrite(client, .none)) return true;
            finishPooledSshTransportClient(ctx, .none);
        },
        .open => return error.UnexpectedDaemonFrame,
    }
    return true;
}

fn handlePooledRemoteTerminalMuxPayload(
    ctx: PooledClientContext,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
) !void {
    // Terminal mux payloads become client_remote frames for the visible client.
    // The mux offset is tracked before forwarding so reconnect can resume from
    // the correct terminal stream point.
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
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
    if (te_item.payload) |te_payload| {
        if (te_payload == .session_client_control_response and client.debug_control_fd >= 0) {
            var debug_fd = core_fds.OwnedFd.init(client.debug_control_fd);
            client.debug_control_fd = -1;
            try one_shot_frame_writer.registerFrameAndClose(.{
                .allocator = transport.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .fd = debug_fd.get(),
                .message_type = .client_remote,
                .payload = client_payload,
            });
            _ = debug_fd.take();
            try resumePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            return;
        }
    }
    try startPooledSshTransportClientFrameWrite(ctx, .{ .message_type = .client_remote, .payload = client_payload, .kind = .forwarded_from_daemon });
    if (te_item.payload) |te_payload| {
        if (te_payload == .session_ended) client.session_ended = true;
    }
}

// Apply remote proxy frames to a raw fd-pass client. Payload offsets are used to
// drop duplicated retransmits, reject gaps, and ACK only after bytes have been
// queued to the local raw fd.
fn handlePooledRemoteRawProxyMuxStreamFrame(
    ctx: PooledClientContext,
    message: protocol.MuxStreamMessage,
) !bool {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    switch (message) {
        .open_ok => {
            notePooledMuxOpenOk(client);
            try sendPooledRawProxyFdPassAccepted(ctx);
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
                    try sendPooledRawProxyAck(ctx);
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
            try startPooledSshTransportClientRawWrite(ctx, owned_data, .forwarded_from_daemon);
        },
        .reset => {
            notePooledMuxFirstPayload(transport, client);
            finishPooledSshTransportClient(ctx, .none);
        },
        .eof => {
            notePooledMuxFirstPayload(transport, client);
            if (finishPooledClientAfterCurrentWrite(client, .none)) return true;
            finishPooledSshTransportClient(ctx, .none);
        },
        .open => {
            try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
            try sendPooledRawProxyOpenOk(ctx);
        },
    }
    return true;
}

// Persist cleanup identity for the remote worker/session before acknowledging it
// to the remote daemon. If the local client dies later, this record is what lets
// another daemon ask the remote side to hang up the process.
fn handlePooledRemoteProcessStarted(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    started: pb.DaemonTunnelItem.RemoteProcessStarted,
) !void {
    const process = started.process orelse return error.UnexpectedDaemonFrame;
    const client = findPooledSshTransportClient(transport, started.stream_id) orelse return;
    if (client.remote_cleanup) |*existing| existing.deinit(transport.allocator);
    client.remote_cleanup = try RemoteCleanupIdentity.fromProto(transport.allocator, process);
    const local_cleanup = client.local_cleanup orelse {
        daemon_log.infof(
            transport.allocator,
            "cleanup record skipped host={s} guid={s} reason=missing-local-process-identity",
            .{ transport.display_host, process.guid },
        );
        return;
    };
    daemon_cleanup.recordRemoteProcessStarted(.{
        .allocator = transport.allocator,
        .local = local_cleanup,
        .endpoint = .{
            .user = transport.resolved_user,
            .host = transport.resolved_host,
            .port = transport.resolved_port,
        },
        .process = process,
    }) catch |err| {
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
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = payload, .kind = .remote_process_recorded });
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
    try startPooledSshTransportRemoteFrameWrite(transport, daemon_dispatcher, .{ .message_type = .daemon_tunnel, .payload = payload, .kind = .cleanup_request });
    transport.cleanup_queue.noteStarted();
}

// Serialize cleanup requests on the same remote write slot used by mux traffic.
// This avoids interleaving a cleanup request with a partially-written stream
// frame on the shared SSH stdin pipe.
fn startNextPendingCleanupRequest(
    daemon_dispatcher: *dispatcher.Dispatcher,
    transport: *PooledSshTransport,
) !void {
    if (transport.state != .ready) return;
    if (transport.remote_write_kind != null) return;
    var request = transport.cleanup_queue.popPending() orelse {
        if (transport.cleanup_queue.hasInFlight()) return;
        schedulePooledSshTransportIdleClose(daemon_dispatcher, transport);
        return;
    };
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
    // Cleanup requests share the pooled SSH transport with user streams. Queue
    // them behind any active write so local client teardown never blocks on a
    // remote cleanup command.
    transport.cleanup_queue.enqueueRemote(transport.allocator, remote) catch |err| {
        daemon_log.infof(
            transport.allocator,
            "client disconnect remote cleanup queue failed host={s} guid={s} error={t}",
            .{ transport.display_host, remote.guid, err },
        );
        return;
    };
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

// Finish one local client and decide whether remote cleanup is required. Normal
// terminal/proxy completion deletes the durable record; local disconnect before
// remote end sends or queues a cleanup request.
fn finishPooledSshTransportClient(ctx: PooledClientContext, hangup: RemoteHangup) void {
    const daemon_dispatcher = ctx.daemon_dispatcher;
    const transport = ctx.transport;
    const client = ctx.client;
    const send_hangup = hangup.shouldSend();

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
    if (transport.remote_write_kind == null and !pooledSshTransportHasClientWrites(transport)) {
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

// Handle loss of the pooled daemon tunnel. Clients are told the remote transport
// closed unless their current queued write can finish first; raw fd-pass clients
// are closed because OpenSSH owns that visible byte stream directly.
fn notifyPooledSshTransportRemoteClosed(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    daemon_log.infof(transport.allocator, "ssh transport disconnected from daemon host={s}", .{transport.display_host});
    beginClosingPooledSshTransport(daemon_dispatcher, transport);
    var index: usize = 0;
    while (index < transport.clients.items.len) {
        const client = transport.clients.items[index];
        if (client.raw_proxy != null) {
            finishPooledSshTransportClient(pooledClientContext(daemon_dispatcher, client), .none);
            continue;
        }
        if (finishPooledClientAfterCurrentWrite(client, .none)) {
            index += 1;
            continue;
        }
        startPooledClientConnectionEvent(
            pooledClientContext(daemon_dispatcher, client),
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
    // Fan OpenSSH stderr to visible clients as connection diagnostics. Raw
    // fd-pass proxies are excluded because their visible stream belongs directly
    // to OpenSSH.
    while (true) {
        const read = transport.stderr_source.readBytes() orelse return;
        const bytes = switch (read) {
            .bytes => |bytes| bytes,
            .eof => {
                transport.stderr_task.cancel();
                transport.stderr_source.deinit();
                return;
            },
        };
        var started_write = false;
        for (transport.clients.items) |client| {
            if (client.state == .done) continue;
            if (client.raw_proxy != null) continue;
            if (client.write_kind != null or client.sink.hasPendingWrite()) continue;
            try startPooledClientConnectionEvent(pooledClientContext(daemon_dispatcher, client), .{ .ssh_stderr = .{ .data = bytes } }, .forwarded_from_daemon);
            started_write = true;
        }
        if (started_write) try pausePooledSshTransportRemoteRead(daemon_dispatcher, transport);
        if (bytes.len < 4096) return;
        switch (try transport.stderr_source.byte().readReady()) {
            .ready, .eof => {},
            .blocked, .progress => return,
        }
    }
}

// Tear down a pooled transport and all clients still attached to it. This is the
// only path that decrements the active transport count and frees the registry
// entry.
fn finishPooledSshTransport(daemon_dispatcher: *dispatcher.Dispatcher, transport: *PooledSshTransport) void {
    _ = daemon_dispatcher;
    if (transport.state == .closed) return;
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport closed host={s} pool={s}",
        .{ transport.display_host, transport.key },
    );
    transport.state = .closed;
    transport.remote_task.cancel();
    transport.stderr_task.cancel();
    transport.stdin_task.cancel();
    transport.idle_task.cancel();
    transport.bootstrap_failure_task.cancel();
    pooled_ssh_registry.remove(transport);
    while (transport.clients.items.len > 0) {
        const client = transport.clients.items[0];
        destroyPooledSshTransportClient(null, transport, client);
    }
    pooled_ssh_registry.finishDestroy(transport);
}

fn destroyPooledSshTransportClient(
    daemon_dispatcher: ?*dispatcher.Dispatcher,
    transport: *PooledSshTransport,
    client: *PooledSshTransportClient,
) void {
    // A pooled transport can outlive any individual visible client. Destroying a
    // client therefore only removes its fd/source and stream bookkeeping; the
    // shared SSH process stays alive until idle policy closes the pool.
    if (client.done) return;
    logPooledSshTransportClientStartupTiming(transport, client);
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport client finished host={s} pool={s} stream_id={}",
        .{ transport.display_host, transport.key, client.stream_id },
    );
    _ = daemon_dispatcher;
    client.state = .done;
    client.done = true;
    client.task.cancel();
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
    if (!client.startup_timing.markLogged()) return;
    const measurements = client.startup_timing.measurements();
    daemon_log.infof(
        transport.allocator,
        "pooled ssh transport client startup host={s} pool={s} stream_id={} kind={s} request_to_open_ms={} open_to_open_ok_ms={} open_ok_to_first_payload_ms={} request_to_first_payload_ms={}",
        .{
            transport.display_host,
            transport.key,
            client.stream_id,
            pooledSshTransportClientKindName(client.kind),
            measurements.request_to_open_ms,
            measurements.open_to_open_ok_ms,
            measurements.open_ok_to_first_payload_ms,
            measurements.request_to_first_payload_ms,
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

const DaemonTransportErrorCloseOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
    code: []const u8,
    message: []const u8,
    hint: []const u8 = "",
};

fn sendDaemonTransportErrorAndClose(options: DaemonTransportErrorCloseOptions) !void {
    const payload = try protocol.encodeErrorPayload(options.allocator, .{
        .code = options.code,
        .message = options.message,
        .hint = options.hint,
    });
    defer options.allocator.free(payload);
    try one_shot_frame_writer.registerFrameAndClose(.{
        .allocator = options.allocator,
        .daemon_dispatcher = options.daemon_dispatcher,
        .fd = options.fd,
        .message_type = .error_message,
        .payload = payload,
    });
}

fn startPooledClientSshFailure(ctx: PooledClientContext, target: SshTarget, term: ?std.process.Child.Term) !bool {
    // If SSH fails before the mux tunnel is ready, surface that failure to the
    // waiting client as a daemon error frame. Once SSH exits successfully or
    // after the tunnel is established, normal stream close handling takes over.
    const client = ctx.client;
    const value = term orelse return false;
    switch (value) {
        .Exited => |code| {
            if (code == 0) return false;
            const message = try ssh_failure.visibleMessage(client.transport.allocator, target, value);
            defer client.transport.allocator.free(message);
            var code_buf: [64]u8 = undefined;
            const error_code = try std.fmt.bufPrint(&code_buf, "SSH_TRANSPORT_EXITED_{}", .{@min(code, 255)});
            try startPooledClientTransportError(ctx, .{
                .code = error_code,
                .message = message,
                .kind = .{ .finish_after_write = .{ .send_hangup = false } },
            });
            return true;
        },
        .Signal => |_| {
            const message = try ssh_failure.visibleMessage(client.transport.allocator, target, value);
            defer client.transport.allocator.free(message);
            try startPooledClientTransportError(ctx, .{
                .code = "SSH_TRANSPORT_EXITED_255",
                .message = message,
                .kind = .{ .finish_after_write = .{ .send_hangup = false } },
            });
            return true;
        },
        else => return false,
    }
}
