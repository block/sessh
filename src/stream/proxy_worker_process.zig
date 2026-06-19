const std = @import("std");

const proxy_worker = @import("proxy_worker.zig");
const worker_process = @import("../core/worker_process.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var listener = try worker_process.prepareInheritedListener(allocator, .{
        .args = args,
        .expected_arg_count = 5,
        .invalid_args_error = error.InvalidProxyRemoteArgs,
    });
    defer listener.deinit();
    const guid = args[2];
    const proxy_host = args[3];
    const proxy_port = try std.fmt.parseInt(u16, args[4], 10);

    try proxy_worker.runRemoteWorker(allocator, guid, listener.fd, proxy_host, proxy_port);
}

test "proxy worker process rejects invalid argv" {
    try std.testing.expectError(error.InvalidProxyRemoteArgs, run(std.testing.allocator, &.{}));
}
