// Data model for pooled daemon-to-daemon SSH transports. Behavior stays in
// pooled_ssh.zig; this module owns the state structs, write-state unions, and
// teardown logic shared by the transport and each attached logical client.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const cleanup_identity = @import("../session/cleanup_identity.zig");
const client_env = @import("client_environment.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const cleanup_queue_mod = @import("../daemon/cleanup_queue.zig");
const dispatcher = @import("../core/dispatcher.zig");
const guid_ref = @import("../core/guid.zig");
const mux_tunnel = @import("mux_tunnel.zig");
const protocol = @import("../protocol/mod.zig");
const raw_proxy_client = @import("raw_proxy_client.zig");
const ssh_transport_process = @import("ssh_transport_process.zig");
const string_list = @import("../core/string_list.zig");

const pb = protocol.pb;

const ArtifactSet = @import("bootstrap.zig").ArtifactSet;
const PooledClientStartupTiming = @import("pooled_client_startup_timing.zig").PooledClientStartupTiming;
const RawProxyClient = raw_proxy_client.RawProxyClient;
const SshTransportProcess = ssh_transport_process.SshTransportProcess;
pub const RemoteCleanupIdentity = cleanup_identity.Remote;
pub const max_client_pending_frame_payload_bytes: usize = 4 * 1024 * 1024;

pub const ClientState = enum {
    pending_transport,
    opening_stream,
    active,
    done,
};

pub const ClientKind = enum {
    unknown,
    te,
    proxy,
};

pub const ClientSourceKind = enum {
    none,
    frame,
    raw_bytes,
};

pub const RawWriteKind = enum {
    bootstrap_exec,
    bootstrap_upload,
};

pub const FrameWriteKind = union(enum) {
    hello_request,
    hello_ok,
    hello_error,
    pong,
    client_mux_envelope_open: struct {
        client: *Client,
        typed_open_bytes: []u8,
    },
    client_to_daemon: *Client,
    proxy_ack,
    remote_process_recorded,
    cleanup_request,
};

pub const RemoteWriteKind = union(enum) {
    raw: RawWriteKind,
    frame: FrameWriteKind,

    pub fn deinit(self: *RemoteWriteKind, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .raw => {},
            .frame => |*frame| switch (frame.*) {
                .client_mux_envelope_open => |*open| {
                    if (open.typed_open_bytes.len != 0) allocator.free(open.typed_open_bytes);
                },
                else => {},
            },
        }
        self.* = undefined;
    }
};

pub const ClientWriteKind = union(enum) {
    forwarded_from_daemon,
    finish_after_write: struct {
        send_hangup: bool,
    },
};

pub const ClientFrameWrites = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Entry) = .empty,
    pending_payload_bytes: usize = 0,

    pub const Entry = struct {
        message_type: protocol.MessageType,
        payload: []u8,
        kind: ClientWriteKind,

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator) ClientFrameWrites {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ClientFrameWrites) void {
        for (self.pending.items) |*entry| entry.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasPending(self: *const ClientFrameWrites) bool {
        return self.pending.items.len != 0;
    }

    pub fn pendingBytes(self: *const ClientFrameWrites) usize {
        return self.pending_payload_bytes;
    }

    pub fn appendFrame(
        self: *ClientFrameWrites,
        message_type: protocol.MessageType,
        payload: []const u8,
        kind: ClientWriteKind,
    ) !void {
        if (payload.len > max_client_pending_frame_payload_bytes or
            self.pending_payload_bytes > max_client_pending_frame_payload_bytes - payload.len)
        {
            return error.FrameSinkFull;
        }
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        try self.pending.append(self.allocator, .{
            .message_type = message_type,
            .payload = owned_payload,
            .kind = kind,
        });
        self.pending_payload_bytes += payload.len;
    }

    pub fn popFirst(self: *ClientFrameWrites) ?Entry {
        if (self.pending.items.len == 0) return null;
        const entry = self.pending.orderedRemove(0);
        self.pending_payload_bytes -= entry.payload.len;
        return entry;
    }
};

test "pooled client frame queue enforces bounded pending payload bytes" {
    var queue = ClientFrameWrites.init(std.testing.allocator);
    defer queue.deinit();

    const payload = try std.testing.allocator.alloc(u8, max_client_pending_frame_payload_bytes);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try queue.appendFrame(.client_daemon, payload, .forwarded_from_daemon);
    try std.testing.expectEqual(max_client_pending_frame_payload_bytes, queue.pendingBytes());
    try std.testing.expectError(error.FrameSinkFull, queue.appendFrame(.client_daemon, "x", .forwarded_from_daemon));

    var entry = queue.popFirst() orelse return error.ExpectedQueuedFrame;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), queue.pendingBytes());
}

// One local client attached to a pooled daemon-to-daemon SSH transport.
//
// For terminal and process-isolated proxy clients, `fd` speaks framed sessh
// protocol with the local daemon. For fd-pass proxy clients, `fd` carries raw
// OpenSSH proxy bytes and `raw_proxy` stores the one-shot setup response fd.
// In both cases the client maps to exactly one mux stream on `transport`.
pub const Client = struct {
    fd: c.fd_t,
    transport: *Transport = undefined,
    source_kind: ClientSourceKind = .none,
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    write_kind: ?ClientWriteKind = null,
    write_is_raw: bool = false,
    pending_frame_writes: ClientFrameWrites = undefined,
    read_paused: bool = false,
    stream_id: u64 = 0,
    local_stream_id: u64 = 0,
    kind: ClientKind = .unknown,
    state: ClientState = .pending_transport,
    outbound_next_offset: u64 = 0,
    inbound_next_offset: u64 = 0,
    raw_proxy: ?RawProxyClient = null,
    startup_timing: PooledClientStartupTiming = .{},
    session_ended: bool = false,
    done: bool = false,
    local_cleanup: ?daemon_cleanup.LocalProcessIdentity = null,
    send_env: []const []const u8 = &.{},
    client_environment: client_env.List = .empty,
    isolation_mode: pb.IsolationMode = .ISOLATION_MODE_PROCESS,
    remote_cleanup: ?RemoteCleanupIdentity = null,
    proxy_guid: guid_ref.FixedProxyGuid = .{},
    /// One-shot debug/control requester waiting for the remote terminal worker
    /// to acknowledge a debug action such as "sever this visible client". This
    /// fd is not the visible client; it is the short-lived harness/debug socket
    /// that sent the control request to the local daemon.
    debug_control_fd: c.fd_t = -1,

    pub fn initReader(self: *Client, allocator: std.mem.Allocator) void {
        self.pending_frame_writes = ClientFrameWrites.init(allocator);
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.task.deinit();
        self.source.deinit();
        self.sink.deinit();
        self.pending_frame_writes.deinit();
        if (self.local_cleanup) |*local| local.deinit(allocator);
        string_list.freeOwned(allocator, self.send_env);
        client_env.deinit(allocator, &self.client_environment);
        if (self.remote_cleanup) |*remote| remote.deinit(allocator);
        if (self.raw_proxy) |*raw_proxy| raw_proxy.deinit(allocator);
        if (self.debug_control_fd >= 0) posix.close(self.debug_control_fd);
        self.* = undefined;
    }
};

// Lifecycle of the underlying OpenSSH process that carries the daemon tunnel.
// Bootstrap states write shell/script bytes before any sessh frames exist;
// handshake states exchange sessh hellos; ready means logical clients may open
// mux streams.
pub const TransportState = enum {
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

pub const RemoteSourceKind = enum {
    none,
    bootstrap_byte,
    frame,
};

// Shared SSH transport to one resolved user/host/port/config key.
//
// `remote_*` fields describe the daemon-to-daemon framed tunnel. `clients` are
// local terminal/proxy clients waiting for or using logical mux streams on that
// tunnel. `remote_write` is the single in-flight write to the SSH process; it is
// what turns backpressure into read-pausing instead of queue growth.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    display_host: []u8,
    resolved_user: []u8,
    resolved_host: []u8,
    resolved_port: []u8,
    ssh_options: []const []const u8 = &.{},
    state: TransportState = .starting,
    clients: std.ArrayList(*Client) = .empty,
    remote_source_kind: RemoteSourceKind = .none,
    remote_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    remote_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    stderr_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    stderr_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    stdin_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    stdin_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    idle_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    bootstrap_failure_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    bootstrap_failure_started_ms: u64 = 0,
    bootstrap_failure_error: ?anyerror = null,
    connection: ?SshTransportProcess = null,
    stderr_fd: c.fd_t = -1,
    remote_daemon_namespace: ?[]u8 = null,
    stream_ids: mux_tunnel.StreamIdAllocator = .{},
    bootstrap_artifacts: ?ArtifactSet = null,
    bootstrap_line: std.ArrayList(u8) = .empty,
    remote_write_kind: ?RemoteWriteKind = null,
    remote_read_paused: bool = false,
    uploaded_bootstrap_artifact: bool = false,
    cleanup_queue: cleanup_queue_mod.Queue = .{},

    pub fn deinit(self: *Transport) void {
        self.remote_task.deinit();
        self.remote_source.deinit();
        self.stderr_task.deinit();
        self.stderr_source.deinit();
        self.stdin_task.deinit();
        self.stdin_sink.deinit();
        self.idle_task.deinit();
        self.bootstrap_failure_task.deinit();
        if (self.connection) |*connection| connection.terminate();
        if (self.remote_daemon_namespace) |namespace| self.allocator.free(namespace);
        if (self.stderr_fd >= 0) posix.close(self.stderr_fd);
        if (self.remote_write_kind) |*kind| kind.deinit(self.allocator);
        self.cleanup_queue.deinit(self.allocator);
        if (self.bootstrap_artifacts) |*artifacts| artifacts.deinit();
        self.bootstrap_line.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        string_list.freeOwned(self.allocator, self.ssh_options);
        self.allocator.free(self.resolved_port);
        self.allocator.free(self.resolved_host);
        self.allocator.free(self.resolved_user);
        self.allocator.free(self.display_host);
        self.allocator.free(self.key);
        self.* = undefined;
    }
};

pub const Acquire = struct {
    transport: *Transport,
    created: bool,
};
