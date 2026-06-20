const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");

pub const RawProxyClient = struct {
    host: []u8,
    port: u32,
    setup_fd: core_fds.OwnedFd,

    pub const InitOwned = struct {
        host: []u8,
        port: u32,
        setup_fd: c.fd_t,
    };

    pub fn initOwned(options: InitOwned) RawProxyClient {
        return .{
            .host = options.host,
            .port = options.port,
            .setup_fd = core_fds.OwnedFd.init(options.setup_fd),
        };
    }

    pub fn deinit(self: *RawProxyClient, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        self.setup_fd.deinit();
        self.* = undefined;
    }

    pub fn takeSetupFd(self: *RawProxyClient) ?c.fd_t {
        const fd = self.setup_fd.take();
        return if (fd >= 0) fd else null;
    }
};

test "taking setup fd transfers close responsibility" {
    const pipe_fds = try posix.pipe();
    var read_end = core_fds.OwnedFd.init(pipe_fds[0]);
    defer read_end.deinit();

    const host = try std.testing.allocator.dupe(u8, "proxy.example");
    var client = RawProxyClient.initOwned(.{
        .host = host,
        .port = 443,
        .setup_fd = pipe_fds[1],
    });
    defer client.deinit(std.testing.allocator);

    const setup_fd = client.takeSetupFd() orelse return error.ExpectedSetupFd;
    defer posix.close(setup_fd);
    try std.testing.expect(client.takeSetupFd() == null);

    const byte = [_]u8{'x'};
    try std.testing.expectEqual(@as(isize, 1), c.write(setup_fd, &byte, byte.len));
    var out: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), c.read(read_end.get(), &out, out.len));
    try std.testing.expectEqual(@as(u8, 'x'), out[0]);
}
