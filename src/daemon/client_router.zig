const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const session_daemon_handler = @import("../session/daemon_handler.zig");
const daemon_cleanup = @import("cleanup.zig");
const daemon_handshake = @import("handshake.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const daemon_tunnel = @import("tunnel.zig");
const proxy_diagnostics_router = @import("../transport/proxy_diagnostics_router.zig");
const transport_ssh = @import("../transport/ssh.zig");

const hpb = protocol.hpb;
const pb = protocol.pb;

pub const AcceptedClientConfig = struct {
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    active_local_clients: *usize,
};

pub fn registerAcceptedClient(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    client_fd: c.fd_t,
    config: AcceptedClientConfig,
) !void {
    const context = try allocator.create(ClientContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .terminal_remote_exe = config.terminal_remote_exe,
        .proxy_remote_exe = config.proxy_remote_exe,
        .identity = config.identity,
        .active_local_clients = config.active_local_clients,
        .fd = client_fd,
    };
    context.initReader();
    errdefer context.reader.deinit();

    config.active_local_clients.* += 1;
    errdefer config.active_local_clients.* -= 1;

    _ = try daemon_dispatcher.watchFd(client_fd, .{ .readable = true }, .{
        .ctx = context,
        .callback = readDaemonClient,
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
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    active_local_clients: *usize,
    fd: c.fd_t,
    reader: protocol.FrameReader = undefined,
    stage: ClientStage = .waiting_peer_hello,
    owns_active_count: bool = true,

    fn initReader(self: *ClientContext) void {
        self.reader = protocol.FrameReader.init(self.allocator);
    }

    fn deinit(self: *ClientContext) void {
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

fn readDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    const context: *ClientContext = @ptrCast(@alignCast(ctx));
    readDaemonClientInner(context, daemon_dispatcher, id, event) catch |err| {
        daemon_log.infof(context.allocator, "client handler failed error={t}", .{err});
        closeDaemonClient(context, daemon_dispatcher, id);
    };
}

fn readDaemonClientInner(context: *ClientContext, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    switch (event) {
        .fd => |fd_event| {
            if (fd_event.error_event or fd_event.invalid) {
                closeDaemonClient(context, daemon_dispatcher, id);
                return;
            }
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
                const action = try handleDaemonClientFrame(context, daemon_dispatcher, id, &frame, &frame.fd);
                switch (action) {
                    .consumed => frame.deinit(context.allocator),
                    .close => {
                        frame.deinit(context.allocator);
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

fn handleDaemonClientFrame(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    frame: *protocol.OwnedFrame,
    frame_fd: *?c.fd_t,
) !DaemonClientFrameAction {
    switch (context.stage) {
        .waiting_peer_hello => {
            if (frame.message_type != .hello_request) {
                try daemon_handshake.sendHelloError(context.fd, "PROTOCOL_ERROR", "expected HELLO_REQUEST", "");
                return .close;
            }
            var peer_hello = try protocol.decodePayload(hpb.HelloRequest, context.allocator, frame.payload);
            defer peer_hello.deinit(context.allocator);
            if (!daemon_handshake.helloRequestIsCompatible(peer_hello)) {
                try daemon_handshake.sendHelloError(context.fd, "VERSION_MISMATCH", "sesshd is incompatible with this client", "");
                return .close;
            }
            try daemon_handshake.sendHelloOk(context.fd);
            try daemon_handshake.sendHelloRequest(context.fd);
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
            if (try dispatcherConsumesInitialRequest(context, daemon_dispatcher, frame)) return .consumed;
            switch (try transferInitialRequestToDispatcherOwner(context, daemon_dispatcher, id, frame, frame_fd)) {
                .not_transferred => {},
                .consumed => return .consumed,
                .transferred => return .transferred,
                .close => return .close,
            }
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "unexpected passed file descriptor", "");
                return .close;
            }
            return if (try handleClientFrameAfterHandshake(context.allocator, context.terminal_remote_exe, context.identity, context.fd, frame.*))
                .consumed
            else
                .close;
        },
        .daemon_log => return .close,
    }
}

fn dispatcherConsumesInitialRequest(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    frame: *protocol.OwnedFrame,
) !bool {
    _ = daemon_dispatcher;
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
            defer item.deinit(context.allocator);
            const item_payload = item.payload orelse {
                try sendError(context.fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
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
                try sendError(context.fd, "PROTOCOL_ERROR", "empty client daemon item", "");
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

fn transferInitialRequestToDispatcherOwner(
    context: *ClientContext,
    daemon_dispatcher: *dispatcher.Dispatcher,
    id: dispatcher.WatchId,
    frame: *protocol.OwnedFrame,
    frame_fd: *?c.fd_t,
) !TransferInitialRequestResult {
    if (frame.message_type == .client_remote) {
        if (frame_fd.*) |passed_fd| {
            frame_fd.* = null;
            _ = c.close(passed_fd);
            try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
            return .close;
        }
        var item = try protocol.decodeClientRemoteTerminalEmulatorItem(context.allocator, frame.payload);
        defer item.deinit(context.allocator);
        const item_payload = item.payload orelse return .not_transferred;
        if (item_payload == .open) {
            daemon_dispatcher.cancel(id);
            const client_fd = context.fd;
            context.fd = -1;
            try session_daemon_handler.registerFrameWithTerminalRemoteFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.terminal_remote_exe,
                frame.*,
                client_fd,
            );
            return .transferred;
        }
        switch (item_payload) {
            .debug_sever_connection_request,
            .debug_unresponsive_connection_request,
            => {
                daemon_dispatcher.cancel(id);
                const client_fd = context.fd;
                context.fd = -1;
                try session_daemon_handler.registerDebugFrameWithTerminalRemoteFromDaemon(
                    context.allocator,
                    daemon_dispatcher,
                    frame.*,
                    client_fd,
                );
                return .transferred;
            },
            else => {},
        }
        return .not_transferred;
    }

    if (frame.message_type == .daemon_tunnel) {
        if (frame_fd.*) |passed_fd| {
            frame_fd.* = null;
            _ = c.close(passed_fd);
            try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
            return .close;
        }
        if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, context.fd)) return .consumed;
        if (try handleDaemonTunnelControlFrame(context.allocator, context.identity, frame.*, context.fd)) return .consumed;
        var initial_frames = [_]protocol.OwnedFrame{frame.*};
        daemon_dispatcher.cancel(id);
        try daemon_tunnel.registerMuxConnectionFromDaemon(
            context.allocator,
            daemon_dispatcher,
            context.terminal_remote_exe,
            context.proxy_remote_exe,
            context.identity,
            initial_frames[0..],
            context.fd,
        );
        context.fd = -1;
        return .transferred;
    }

    if (frame.message_type != .client_daemon) return .not_transferred;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, context.allocator, frame.payload);
    defer item.deinit(context.allocator);
    const item_payload = item.payload orelse return .not_transferred;
    switch (item_payload) {
        .ssh_transport_acquire => |request| {
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
                return .close;
            }
            daemon_log.infof(context.allocator, "ssh transport requested", .{});
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerPooledSshTransportFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        .proxy_diagnostics_open => |request| {
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "passed file descriptor is only valid for proxy fd-pass open", "");
                return .close;
            }
            daemon_log.infof(context.allocator, "proxy diagnostics requested guid={s}", .{request.proxy_guid});
            daemon_dispatcher.cancel(id);
            try proxy_diagnostics_router.registerOpenFromDaemon(context.allocator, daemon_dispatcher, context.fd, request);
            context.fd = -1;
            return .transferred;
        },
        .proxy_fd_pass_open => |request| {
            const passed_fd = frame_fd.* orelse {
                try sendError(context.fd, "PROTOCOL_ERROR", "proxy fd-pass open missing SCM_RIGHTS fd", "");
                return .close;
            };
            frame_fd.* = null;
            errdefer _ = c.close(passed_fd);
            if (request.proxy) |proxy| {
                daemon_log.infof(
                    context.allocator,
                    "proxy fd-pass requested guid={s} host={s}:{d}",
                    .{ proxy.proxy_guid, proxy.proxy_host, proxy.proxy_port },
                );
            } else {
                daemon_log.infof(context.allocator, "proxy fd-pass requested without proxy details", .{});
            }
            daemon_dispatcher.cancel(id);
            try transport_ssh.registerProxyFdPassOpenFromDaemon(
                context.allocator,
                daemon_dispatcher,
                context.fd,
                passed_fd,
                request,
            );
            context.fd = -1;
            return .transferred;
        },
        .log_request => {
            if (frame_fd.*) |passed_fd| {
                frame_fd.* = null;
                _ = c.close(passed_fd);
                try sendError(context.fd, "PROTOCOL_ERROR", "unexpected passed file descriptor", "");
                return .close;
            }
            daemon_dispatcher.cancel(id);
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

fn handleClientFrameAfterHandshake(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    fd: c.fd_t,
    frame: protocol.OwnedFrame,
) !bool {
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
            defer item.deinit(allocator);
            const item_payload = item.payload orelse {
                try sendError(fd, "PROTOCOL_ERROR", "empty terminal stream item", "");
                return false;
            };
            switch (item_payload) {
                .resize => return true,
                .open => {
                    _ = exe;
                    try sendError(fd, "PROTOCOL_ERROR", "terminal stream open must be dispatcher-owned", "");
                    return false;
                },
                .debug_sever_connection_request,
                .debug_unresponsive_connection_request,
                => {
                    try sendError(fd, "PROTOCOL_ERROR", "session debug must be dispatcher-owned", "");
                    return false;
                },
                else => {
                    try sendError(fd, "PROTOCOL_ERROR", "unexpected terminal stream item", "");
                    return false;
                },
            }
        },
        .daemon_tunnel => {
            if (try protocol.handleTransportControlFrame(frame.message_type, frame.payload, fd)) return true;
            if (try handleDaemonTunnelControlFrame(allocator, identity, frame, fd)) return true;
            try sendError(fd, "PROTOCOL_ERROR", "daemon tunnel must be dispatcher-owned", "");
            return false;
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
            defer item.deinit(allocator);
            const item_payload = item.payload orelse {
                try sendError(fd, "PROTOCOL_ERROR", "empty client daemon item", "");
                return false;
            };
            switch (item_payload) {
                .ssh_transport_acquire => |request| {
                    _ = request;
                    try sendError(fd, "PROTOCOL_ERROR", "ssh transport must be dispatcher-owned", "");
                    return false;
                },
                .proxy_diagnostics_open => {
                    try sendError(fd, "PROTOCOL_ERROR", "proxy diagnostics must be dispatcher-owned", "");
                    return false;
                },
                .proxy_fd_pass_open => {
                    try sendError(fd, "PROTOCOL_ERROR", "proxy fd-pass open must be dispatcher-owned", "");
                    return false;
                },
                .log_request => {
                    try sendError(fd, "PROTOCOL_ERROR", "daemon log must be dispatcher-owned", "");
                    return false;
                },
                else => {
                    try sendError(fd, "PROTOCOL_ERROR", "unexpected client daemon item", "");
                    return false;
                },
            }
        },
        else => {
            try sendError(fd, "PROTOCOL_ERROR", "sesshd does not support this request yet", "");
            return false;
        },
    }
}

fn handleDaemonTunnelControlFrame(
    allocator: std.mem.Allocator,
    identity: daemon_identity.DaemonIdentity,
    frame: protocol.OwnedFrame,
    fd: c.fd_t,
) !bool {
    if (frame.message_type != .daemon_tunnel) return false;
    var item = try protocol.decodePayload(pb.DaemonTunnelItem, allocator, frame.payload);
    defer item.deinit(allocator);
    const payload = item.payload orelse return false;
    switch (payload) {
        .remote_process_cleanup_request => |request| {
            try daemon_cleanup.handleRemoteProcessCleanupRequest(allocator, fd, identity, request);
            return true;
        },
        else => return false,
    }
}

fn sendError(fd: c.fd_t, code: []const u8, message: []const u8, hint: []const u8) !void {
    const payload = try protocol.encodePayload(app_allocator.allocator(), hpb.Error{
        .code = code,
        .message = message,
        .hint = hint,
    });
    defer app_allocator.allocator().free(payload);
    try protocol.sendFrame(fd, .error_message, payload);
}
