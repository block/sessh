const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const socket_transport = @import("../transport/socket.zig");
const proxy_worker = @import("proxy_worker.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 5) return error.InvalidProxyRemoteArgs;
    const listen_fd = try std.fmt.parseInt(c.fd_t, args[0], 10);
    const socket_path = args[1];
    const guid = args[2];
    const proxy_host = args[3];
    const proxy_port = try std.fmt.parseInt(u16, args[4], 10);
    core_fds.closeInheritedNonStdioFileDescriptorsExcept(listen_fd);
    socket_transport.publishSesshRuntimeDirSymlinkOnce(allocator);
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    try proxy_worker.runRemoteWorker(allocator, guid, listen_fd, proxy_host, proxy_port);
}

test "proxy worker process rejects invalid argv" {
    try std.testing.expectError(error.InvalidProxyRemoteArgs, run(std.testing.allocator, &.{}));
}
