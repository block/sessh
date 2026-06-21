// Routes accepted local-daemon clients after their handshake. Each client type
// either transfers ownership to a role-specific module or gets a one-shot
// response before the generic daemon context is destroyed.
const std = @import("std");
const c = std.c;

const core_config = @import("../core/config.zig");
const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_handshake = @import("handshake.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const daemon_tunnel = @import("tunnel.zig");
const proxy_diagnostics_router = @import("../transport/proxy_diagnostics_router.zig");
const frame_write_queue = @import("../transport/frame_write_queue.zig");
const transport_ssh = @import("../transport/ssh.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

pub const RegisterAcceptedClientOptions = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    active_local_clients: *usize,
};

/// Put a newly accepted daemon client into the handshake state machine. The
/// generic router owns the fd only until it can identify a role-specific owner
/// such as pooled SSH transport, terminal session, proxy fd-pass, or log tail.
pub fn registerAcceptedClient(options: RegisterAcceptedClientOptions) !void {
    const allocator = options.allocator;
    const context = try allocator.create(ClientContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .blocking = options.blocking,
        .terminal_remote_exe = options.terminal_remote_exe,
        .proxy_remote_exe = options.proxy_remote_exe,
        .identity = options.identity,
        .active_local_clients = options.active_local_clients,
        .fd = options.client_fd,
    };
    context.initReader();
    context.initWriter();
    errdefer context.reader.deinit();
    errdefer context.writer.deinit();

    options.active_local_clients.* += 1;
    errdefer options.active_local_clients.* -= 1;

    _ = try options.daemon_dispatcher.watchFd(.{
        .fd = options.client_fd,
        .events = .{ .readable = true },
        .handler = .{
            .ctx = context,
            .callback = readDaemonClient,
        },
    });
}

const ClientStage = enum {
    waiting_peer_hello,
    waiting_peer_reply,
    waiting_request,
    daemon_log,
};

const ClientContext = struct {
    allocator: std.mem.Allocator,
    blocking: core_blocking.Blocking,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    active_local_clients: *usize,
    fd: c.fd_t,
    reader: protocol.FrameReader = undefined,
    writer: frame_write_queue.FrameWriteQueue = undefined,
    stage: ClientStage = .waiting_peer_hello,
    owns_active_count: bool = true,
    close_after_write: bool = false,

    fn initReader(self: *ClientContext) void {
        self.reader = protocol.FrameReader.init(self.allocator);
    }

    fn initWriter(self: *ClientContext) void {
        self.writer = frame_write_queue.FrameWriteQueue.init(self.allocator);
    }

    fn deinit(self: *ClientContext) void {
        self.writer.deinit();
        self.reader.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.owns_active_count) {
            self.active_local_clients.* -= 1;
            self.owns_active_count = false;
        }
        self.allocator.destroy(self);
    }
};

fn readDaemonClient(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const context: *ClientContext = @ptrCast(@alignCast(ctx));
    readDaemonClientInner(context, handler_event) catch |err| {
        daemon_log.infof(context.allocator, "client handler failed error={t}", .{err});
        closeDaemonClient(context, daemon_dispatcher, id);
    };
}

// Dispatcher callback body for the generic daemon-client fd. It drains pending
// writes before reads so protocol errors and hello replies are not stranded
// behind more input, then transfers ownership once the first real request is
// decoded.
fn readDaemonClientInner(context: *ClientContext, handler_event: dispatcher.HandlerEvent) !void {
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    switch (event) {
        .fd => |fd_event| {
            if (fd_event.error_event or fd_event.invalid) {
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            }
            if (fd_event.writable and try drainDaemonClientWrites(context, daemon_dispatcher, id)) return;
            if (context.close_after_write) return;
            if (!fd_event.readable and !fd_event.hangup) return;
        },
        .timer => return error.UnexpectedDaemonTimer,
    }

    while (true) {
        switch (try context.reader.readReady(context.fd)) {
            .blocked => return,
            .progress => continue,
            .eof => {
                if (context.stage == .daemon_log) {
                    daemon_log.infof(context.allocator, "daemon log subscriber disconnected", .{});
                } else {
                    daemon_log.infof(context.allocator, "client disconnected from daemon", .{});
                }
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            },
            .truncated_frame => {
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                const action = try handleDaemonClientFrame(context, daemon_dispatcher, .{
                    .watch_id = id,
                    .frame = &frame,
                });
                switch (action) {
                    .consumed => {
                        frame.deinit(context.allocator);
                        if (context.writer.hasPending()) {
                            try updateDaemonClientEvents(context, daemon_dispatcher, id);
                            return;
                        }
                    },
                    .close => {
                        frame.deinit(context.allocator);
                        if (context.writer.hasPending()) {
                            context.close_after_write = true;
                            try updateDaemonClientEvents(context, daemon_dispatcher, id);
                            return;
                        }
                        closeDaemonClient(context, daemon_dispatcher, id);
                        return;
                    },
                    .transferred => {
                        frame.deinit(context.allocator);
                        context.deinit();
                        return;
                    },
                }
            },
        }
    }
}

const DaemonClientFrameAction = enum {
    consumed,
    close,
    transferred,
};

const DaemonClientFrame = struct {
    watch_id: dispatcher.WatchId,
    frame: *protocol.OwnedFrame,

    fn takePassedFd(self: DaemonClientFrame) ?c.fd_t {
        const fd = self.frame.fd;
        self.frame.fd = null;
        return fd;
    }

    fn rejectPassedFd(self: DaemonClientFrame, context: *ClientContext, message: []const u8) !bool {
        var fd = core_fds.OwnedFd.init(self.takePassedFd() orelse return false);
        defer fd.deinit();
        try queueProtocolError(context, message);
        return true;
    }
};

// Advance the client protocol stage for one decoded frame. The first two stages
// perform the compatibility handshake; after that, initial request frames either
// move the fd to a specialized dispatcher owner or get rejected here.
fn handleDaemonClientFrame(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: DaemonClientFrame,
) !DaemonClientFrameAction {
    const frame = event.frame;
    switch (context.stage) {
        .waiting_peer_hello => {
            if (frame.message_type != .hello_request) {
                try queueHelloError(context, .{
                    .code = "PROTOCOL_ERROR",
                    .message = "expected HELLO_REQUEST",
                });
                return .close;
            }
            var peer_hello = try protocol.decodePayload(hpb.HelloRequest, context.allocator, frame.payload);
            defer peer_hello.deinit(context.allocator);
            if (!daemon_handshake.helloRequestIsCompatible(peer_hello)) {
                try queueHelloError(context, .{
                    .code = "VERSION_MISMATCH",
                    .message = "sesshd is incompatible with this client",
                });
                return .close;
            }
            try queueHelloOk(context);
            try queueHelloRequest(context);
            context.stage = .waiting_peer_reply;
            return .consumed;
        },
        .waiting_peer_reply => {
            switch (frame.message_type) {
                .hello_ok => {
                    var ok = try protocol.decodePayload(hpb.HelloOk, context.allocator, frame.payload);
                    defer ok.deinit(context.allocator);
                    daemon_log.infof(context.allocator, "client hello completed", .{});
                    context.stage = .waiting_request;
                    return .consumed;
                },
                .hello_error => return .close,
                else => return error.UnexpectedFrame,
            }
        },
        .waiting_request => {
            if (try dispatcherConsumesInitialRequest(context, frame)) return .consumed;
            switch (try transferInitialRequestToDispatcherOwner(context, daemon_dispatcher, event)) {
                .not_transferred => {},
                .consumed => return .consumed,
                .transferred => return .transferred,
                .close => return .close,
            }
            if (try event.rejectPassedFd(context, "unexpected passed file descriptor")) return .close;
            return if (try handleClientFrameAfterHandshake(context, daemon_dispatcher, frame.*))
                .consumed
            else
                .close;
        },
        .daemon_log => return .close,
    }
}

// Some initial frames are only meaningful after a terminal/proxy owner exists.
// Consume those quietly at the generic-router boundary so callers get a protocol
// response instead of accidentally creating a worker for a resize-only request.
fn dispatcherConsumesInitialRequest(
    context: *ClientContext,
    frame: *protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try queueProtocolError(context, "empty terminal stream item");
                return true;
            };
            switch (item_payload) {
                .resize => return true,
                else => return false,
            }
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try queueProtocolError(context, "empty client daemon item");
                return true;
            };
            switch (item_payload) {
                else => return false,
            }
        },
        else => return false,
    }
}

const TransferInitialRequestResult = enum {
    not_transferred,
    consumed,
    transferred,
    close,
};

// Some first client frames create a long-lived owner outside the generic daemon
// client router. When that happens, move the accepted fd and its first frame to
// the terminal/proxy owner and cancel the router watch so there is exactly one
// dispatcher path responsible for the connection.
fn transferInitialRequestToDispatcherOwner(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: DaemonClientFrame,
) !TransferInitialRequestResult {
    const frame = event.frame;
    if (frame.message_type == .client_remote) {
        if (try event.rejectPassedFd(context, "passed file descriptor is only valid for proxy fd-pass open")) return .close;
        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
        defer item.deinit(context.allocator);
        const item_payload = item.payload orelse return .not_transferred;
        if (item_payload == .open) {
            daemon_dispatcher.cancel(event.watch_id);
            const client_fd = context.fd;
            context.fd = -1;
            try session_daemon_handler.registerFrameWithTerminalRemoteFromDaemon(.{
                .allocator = context.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .exe = context.terminal_remote_exe,
                .frame = frame.*,
                .client_fd = client_fd,
            });
            return .transferred;
        }
        switch (item_payload) {
            .debug_sever_connection_request,
            .debug_unresponsive_connection_request,
            => {
                daemon_dispatcher.cancel(event.watch_id);
                const client_fd = context.fd;
                context.fd = -1;
                try session_daemon_handler.registerDebugFrameWithTerminalRemoteFromDaemon(.{
                    .allocator = context.allocator,
                    .daemon_dispatcher = daemon_dispatcher,
                    .frame = frame.*,
                    .client_fd = client_fd,
                });
                return .transferred;
            },
            else => {},
        }
        return .not_transferred;
    }

    if (frame.message_type == .daemon_tunnel) {
        if (try event.rejectPassedFd(context, "passed file descriptor is only valid for proxy fd-pass open")) return .close;
        if (try handleTransportControlFrameQueued(context, frame.message_type, frame.payload)) return .consumed;
        if (try handleDaemonTunnelControlFrame(context, daemon_dispatcher, frame.*)) return .consumed;
        var initial_frames = [_]protocol.OwnedFrame{frame.*};
        daemon_dispatcher.cancel(event.watch_id);
        try daemon_tunnel.registerMuxConnectionFromDaemon(context.allocator, daemon_dispatcher, .{
            .terminal_remote_exe = context.terminal_remote_exe,
            .proxy_remote_exe = context.proxy_remote_exe,
            .identity = context.identity,
            .initial_frames = initial_frames[0..],
            .fd = context.fd,
        });
        context.fd = -1;
        return .transferred;
    }

    if (frame.message_type != .client_daemon) return .not_transferred;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
    defer item.deinit(context.allocator);
    const item_payload = item.payload orelse return .not_transferred;
    switch (item_payload) {
        .ssh_transport_acquire => |request| {
            if (try event.rejectPassedFd(context, "passed file descriptor is only valid for proxy fd-pass open")) return .close;
            daemon_log.infof(context.allocator, "ssh transport requested", .{});
            daemon_dispatcher.cancel(event.watch_id);
            try transport_ssh.registerPooledSshTransportFromDaemon(.{
                .blocking = context.blocking,
                .allocator = context.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .client_fd = context.fd,
                .request = request,
            });
            context.fd = -1;
            return .transferred;
        },
        .proxy_diagnostics_open => |request| {
            if (try event.rejectPassedFd(context, "passed file descriptor is only valid for proxy fd-pass open")) return .close;
            daemon_log.infof(context.allocator, "proxy diagnostics requested guid={s}", .{request.proxy_guid});
            daemon_dispatcher.cancel(event.watch_id);
            try proxy_diagnostics_router.registerOpenFromDaemon(.{
                .allocator = context.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .fd = context.fd,
                .open = request,
            });
            context.fd = -1;
            return .transferred;
        },
        .proxy_fd_pass_open => |request| {
            var passed_fd = core_fds.OwnedFd.init(event.takePassedFd() orelse {
                try queueProtocolError(context, "proxy fd-pass open missing SCM_RIGHTS fd");
                return .close;
            });
            defer passed_fd.deinit();
            if (request.proxy) |proxy| {
                daemon_log.infof(
                    context.allocator,
                    "proxy fd-pass requested guid={s} host={s}:{d}",
                    .{ proxy.proxy_guid, proxy.proxy_host, proxy.proxy_port },
                );
            } else {
                daemon_log.infof(context.allocator, "proxy fd-pass requested without proxy details", .{});
            }
            daemon_dispatcher.cancel(event.watch_id);
            try transport_ssh.registerProxyFdPassOpenFromDaemon(.{
                .blocking = context.blocking,
                .allocator = context.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .setup_fd = context.fd,
                .raw_fd = passed_fd.take(),
                .request = request,
            });
            context.fd = -1;
            return .transferred;
        },
        .log_request => {
            if (try event.rejectPassedFd(context, "unexpected passed file descriptor")) return .close;
            daemon_dispatcher.cancel(event.watch_id);
            const log_fd = context.fd;
            try daemon_log.subscribe(context.allocator, daemon_dispatcher, log_fd);
            context.fd = -1;
            daemon_log.infof(context.allocator, "daemon log subscribed", .{});
            return .transferred;
        },
        else => return .not_transferred,
    }
}

fn closeDaemonClient(context: *ClientContext, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId) void {
    daemon_dispatcher.cancel(id);
    if (context.stage == .daemon_log and context.fd >= 0) daemon_log.unsubscribe(context.allocator, context.fd);
    context.deinit();
}

// Handle post-handshake frames that stayed with the generic router. Most
// long-lived traffic should never reach this point; this is the guardrail that
// keeps role-specific protocols from running without their owning dispatcher.
fn handleClientFrameAfterHandshake(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try queueProtocolError(context, "empty terminal stream item");
                return false;
            };
            switch (item_payload) {
                .resize => return true,
                .open => {
                    try queueProtocolError(context, "terminal stream open must be dispatcher-owned");
                    return false;
                },
                .debug_sever_connection_request,
                .debug_unresponsive_connection_request,
                => {
                    try queueProtocolError(context, "session debug must be dispatcher-owned");
                    return false;
                },
                else => {
                    try queueProtocolError(context, "unexpected terminal stream item");
                    return false;
                },
            }
        },
        .daemon_tunnel => {
            if (try handleTransportControlFrameQueued(context, frame.message_type, frame.payload)) return true;
            if (try handleDaemonTunnelControlFrame(context, daemon_dispatcher, frame)) return true;
            try queueProtocolError(context, "daemon tunnel must be dispatcher-owned");
            return false;
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try queueProtocolError(context, "empty client daemon item");
                return false;
            };
            switch (item_payload) {
                .ssh_transport_acquire => {
                    try queueProtocolError(context, "ssh transport must be dispatcher-owned");
                    return false;
                },
                .proxy_diagnostics_open => {
                    try queueProtocolError(context, "proxy diagnostics must be dispatcher-owned");
                    return false;
                },
                .proxy_fd_pass_open => {
                    try queueProtocolError(context, "proxy fd-pass open must be dispatcher-owned");
                    return false;
                },
                .log_request => {
                    try queueProtocolError(context, "daemon log must be dispatcher-owned");
                    return false;
                },
                else => {
                    try queueProtocolError(context, "unexpected client daemon item");
                    return false;
                },
            }
        },
        else => {
            try queueProtocolError(context, "sesshd does not support this request yet");
            return false;
        },
    }
}

// Cleanup requests can arrive before a full mux owner is installed. Serve those
// in-place so stale remote process records can be drained over a short-lived
// daemon tunnel control connection.
fn handleDaemonTunnelControlFrame(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, context.allocator, frame.payload);
    defer item.deinit(context.allocator);
    const payload = item.payload orelse return false;
    switch (payload) {
        .remote_process_cleanup_request => |request| {
            try daemon_cleanup.handleRemoteProcessCleanupRequestQueued(.{
                .allocator = context.allocator,
                .daemon_dispatcher = daemon_dispatcher,
                .mux_writer = &context.writer,
                .identity = context.identity,
                .request = request,
            });
            return true;
        },
        else => return false,
    }
}

fn handleTransportControlFrameQueued(context: *ClientContext, message_type: protocol.MessageType, payload: []const u8) !bool {
    switch (try protocol.decodeTransportControlFrame(context.allocator, message_type, payload) orelse return false) {
        .ping => {
            try context.writer.queueDaemonTunnelPayload(.{ .pong = .{} });
            return true;
        },
        .pong => return true,
    }
}

fn queueHelloRequest(context: *ClientContext) !void {
    const payload = try protocol.encodePayload(context.allocator, hpb.HelloRequest{
        .protocol_major = core_config.protocol_major,
        .protocol_minor = core_config.protocol_minor,
        .version = core_config.version,
    });
    defer context.allocator.free(payload);
    try context.writer.queueFrame(.hello_request, payload);
}

fn queueHelloOk(context: *ClientContext) !void {
    const payload = try protocol.encodePayload(context.allocator, hpb.HelloOk{});
    defer context.allocator.free(payload);
    try context.writer.queueFrame(.hello_ok, payload);
}

fn queueHelloError(context: *ClientContext, info: protocol.ErrorInfo) !void {
    const payload = try protocol.encodePayload(context.allocator, hpb.HelloError{
        .code = info.code,
        .message = info.message,
        .hint = info.hint,
    });
    defer context.allocator.free(payload);
    try context.writer.queueFrame(.hello_error, payload);
    context.close_after_write = true;
}

fn queueError(context: *ClientContext, info: protocol.ErrorInfo) !void {
    const payload = try protocol.encodeErrorPayload(context.allocator, info);
    defer context.allocator.free(payload);
    try context.writer.queueFrame(.error_message, payload);
    context.close_after_write = true;
}

fn queueProtocolError(context: *ClientContext, message: []const u8) !void {
    try queueError(context, .{
        .code = "PROTOCOL_ERROR",
        .message = message,
    });
}

fn drainDaemonClientWrites(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
) !bool {
    // Flush queued response frames before closing or resuming reads. This keeps
    // daemon errors/log replies ordered while still respecting socket
    // backpressure from slow foreground clients.
    if (!context.writer.hasPending()) {
        try updateDaemonClientEvents(context, daemon_dispatcher, id);
        return false;
    }
    switch (try context.writer.writeReady(context.fd)) {
        .blocked, .progress => {
            try updateDaemonClientEvents(context, daemon_dispatcher, id);
            return false;
        },
        .drained => {
            if (context.close_after_write) {
                closeDaemonClient(context, daemon_dispatcher, id);
                return true;
            }
            try updateDaemonClientEvents(context, daemon_dispatcher, id);
            return false;
        },
    }
}

fn updateDaemonClientEvents(
    context: *const ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
) !void {
    const fd_id = switch (id) {
        .fd => |fd_id| fd_id,
        .timer => return error.UnexpectedDaemonTimer,
    };
    try daemon_dispatcher.updateFdEvents(fd_id, .{
        .readable = !context.close_after_write,
        .writable = context.writer.hasPending(),
    });
}
