const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const daemon_log = @import("../daemon/log.zig");
const protocol = @import("../protocol/mod.zig");

pub const ClientCloseAction = enum {
    none,
};

pub const ClientDiagnosticForwarding = struct {
    notify_read_fd: c.fd_t = -1,
    notify_remote_close: bool = false,
    log_context: LogContext = .{},
};

pub const LogContext = struct {
    host: []const u8 = "",
};

pub fn forwardFrames(stdin_fd: c.fd_t, stdout_fd: c.fd_t, runtime_fd: c.fd_t) !void {
    return forwardFramesBetween(stdin_fd, stdout_fd, runtime_fd, runtime_fd);
}

pub fn forwardFramesBetween(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    runtime_read_fd: c.fd_t,
    runtime_write_fd: c.fd_t,
) !void {
    return forwardFramesBetweenWithClientCloseAction(
        client_read_fd,
        client_write_fd,
        runtime_read_fd,
        runtime_write_fd,
        .none,
    );
}

pub fn forwardFramesBetweenWithClientCloseAction(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    runtime_read_fd: c.fd_t,
    runtime_write_fd: c.fd_t,
    client_close_action: ClientCloseAction,
) !void {
    return forwardFramesBetweenWithClientCloseActionAndDiagnostics(
        client_read_fd,
        client_write_fd,
        runtime_read_fd,
        runtime_write_fd,
        client_close_action,
        .{},
    );
}

pub fn forwardFramesBetweenWithClientCloseActionAndDiagnostics(
    client_read_fd: c.fd_t,
    client_write_fd: c.fd_t,
    runtime_read_fd: c.fd_t,
    runtime_write_fd: c.fd_t,
    client_close_action: ClientCloseAction,
    diagnostics: ClientDiagnosticForwarding,
) !void {
    defer {
        _ = c.shutdown(client_read_fd, c.SHUT.WR);
        if (client_write_fd != client_read_fd) _ = c.shutdown(client_write_fd, c.SHUT.WR);
        _ = c.shutdown(runtime_write_fd, c.SHUT.WR);
    }

    while (true) {
        var pollfds: [3]posix.pollfd = undefined;
        var count: usize = 0;
        const client_index = count;
        pollfds[count] = .{ .fd = client_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
        const runtime_index = count;
        pollfds[count] = .{ .fd = runtime_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
        var diagnostic_index: ?usize = null;
        if (diagnostics.notify_read_fd >= 0) {
            diagnostic_index = count;
            pollfds[count] = .{ .fd = diagnostics.notify_read_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        _ = try posix.poll(pollfds[0..count], -1);

        if (diagnostic_index) |index| {
            if ((pollfds[index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                try forwardRawTransportDiagnostics(client_write_fd, diagnostics.notify_read_fd);
            }
        }
        if ((pollfds[client_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(client_read_fd, runtime_write_fd)) {
                try handleClientClose(runtime_write_fd, client_close_action, diagnostics.log_context);
                return;
            }
        }
        if ((pollfds[runtime_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (!try copyOneFrame(runtime_read_fd, client_write_fd)) {
                logDaemonEvent(diagnostics.log_context, "ssh transport disconnected from daemon");
                if (diagnostics.notify_remote_close) try sendSshTransportClosed(client_write_fd);
                return;
            }
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

fn handleClientClose(runtime_write_fd: c.fd_t, action: ClientCloseAction, log_context: LogContext) !void {
    _ = runtime_write_fd;
    _ = log_context;
    switch (action) {
        .none => {},
    }
}

fn logDaemonEvent(log_context: LogContext, message: []const u8) void {
    if (log_context.host.len == 0) {
        daemon_log.infof(std.heap.page_allocator, "{s}", .{message});
    } else {
        daemon_log.infof(std.heap.page_allocator, "{s} host={s}", .{ message, log_context.host });
    }
}

fn logDaemonEventFmt(log_context: LogContext, comptime fmt: []const u8, args: anytype) void {
    if (log_context.host.len == 0) {
        daemon_log.infof(std.heap.page_allocator, fmt, args);
    } else {
        const message = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(message);
        daemon_log.infof(std.heap.page_allocator, "{s} host={s}", .{ message, log_context.host });
    }
}

pub fn forwardRawTransportDiagnostics(fd: c.fd_t, diagnostic_read_fd: c.fd_t) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var pollfds = [_]posix.pollfd{.{
            .fd = diagnostic_read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 0);
        if (ready == 0 or (pollfds[0].revents & posix.POLL.IN) == 0) return;

        const n = c.read(diagnostic_read_fd, &buf, buf.len);
        if (n <= 0) return;
        const chunk = buf[0..@intCast(n)];
        try protocol.sendSshTransportStderrFrame(std.heap.page_allocator, fd, chunk);
        if (chunk.len < buf.len) return;
    }
}

fn sendSshTransportClosed(fd: c.fd_t) !void {
    try protocol.sendSshTransportClosedFrame(std.heap.page_allocator, fd);
}
