const std = @import("std");
const c = std.c;

const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const dispatcher = @import("../core/dispatcher.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const client_router = @import("client_router.zig");
const socket_transport = @import("../transport/socket.zig");

pub const Context = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    listen_fd: c.fd_t,
    active_local_clients: *usize,
    listen_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    listen_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
};

/// Accept one local daemon client and hand it to the protocol router.
/// The accept callback deliberately does no client protocol work so the daemon
/// listener remains responsive while individual clients progress independently.
pub fn acceptDaemonClient(
    accept_context: *Context,
    daemon_dispatcher: *dispatcher.Dispatcher,
    _: *dispatcher.DispatchTask,
    fd_event: dispatcher.FdEvent,
) !dispatch_io.DispatchTaskStatus {
    if (fd_event.error_event or fd_event.invalid) return error.DaemonListenFailed;
    if (!fd_event.readable) return .pending;

    const client_fd = c.accept(accept_context.listen_fd, null, null);
    if (client_fd < 0) return .pending;
    var owned_client_fd = core_fds.OwnedFd.init(client_fd);
    defer owned_client_fd.deinit();

    daemon_log.infof(accept_context.allocator, "client connected", .{});
    try socket_transport.setCloseOnExec(owned_client_fd.get());
    try core_fds.setNonBlocking(owned_client_fd.get());
    try client_router.registerAcceptedClient(.{
        .allocator = accept_context.allocator,
        .blocking = accept_context.blocking,
        .daemon_dispatcher = daemon_dispatcher,
        .client_fd = owned_client_fd.get(),
        .terminal_remote_exe = accept_context.terminal_remote_exe,
        .proxy_remote_exe = accept_context.proxy_remote_exe,
        .identity = accept_context.identity,
        .active_local_clients = accept_context.active_local_clients,
    });
    _ = owned_client_fd.take();
    return .pending;
}
