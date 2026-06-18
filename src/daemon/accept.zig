const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const client_router = @import("client_router.zig");
const socket_transport = @import("../transport/socket.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    terminal_remote_exe: []const u8,
    proxy_remote_exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    listen_fd: c.fd_t,
    active_local_clients: *usize,
};

pub fn acceptDaemonClient(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const accept_context: *Context = @ptrCast(@alignCast(ctx));

    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonTimer,
    };
    if (fd_event.error_event or fd_event.invalid) return error.DaemonListenFailed;
    if (!fd_event.readable) return;

    const client_fd = c.accept(accept_context.listen_fd, null, null);
    if (client_fd < 0) return;
    errdefer _ = c.close(client_fd);

    daemon_log.infof(accept_context.allocator, "client connected", .{});
    try socket_transport.setCloseOnExec(client_fd);
    try core_fds.setNonBlocking(client_fd);
    try client_router.registerAcceptedClient(
        accept_context.allocator,
        daemon_dispatcher,
        client_fd,
        .{
            .terminal_remote_exe = accept_context.terminal_remote_exe,
            .proxy_remote_exe = accept_context.proxy_remote_exe,
            .identity = accept_context.identity,
            .active_local_clients = accept_context.active_local_clients,
        },
    );
}
