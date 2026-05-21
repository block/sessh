const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");
const protocol = @import("protocol.zig");

pub fn relayFrames(stdin_fd: c.fd_t, stdout_fd: c.fd_t, agent_fd: c.fd_t) !void {
    var pollfds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = agent_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = try posix.poll(&pollfds, -1);

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(stdin_fd, agent_fd)) return;
        }
        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(agent_fd, stdout_fd)) return;
        }
    }
}

fn copyOneFrame(read_fd: c.fd_t, write_fd: c.fd_t) !bool {
    var header: [protocol.frame_header_len]u8 = undefined;
    io.readExact(read_fd, &header) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    try io.writeAll(write_fd, &header);

    var remaining = protocol.payloadLenFromHeader(&header);
    var buf: [16 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk_len = @min(remaining, buf.len);
        try io.readExact(read_fd, buf[0..chunk_len]);
        try io.writeAll(write_fd, buf[0..chunk_len]);
        remaining -= chunk_len;
    }
    return true;
}
