// Framed diagnostics/control channel between a visible proxy client and the
// process-isolated proxy byte stream. The raw OpenSSH bytes stay elsewhere; this
// channel only carries reconnect status and retry requests.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const foreground_frame_io = @import("../transport/foreground_frame_io.zig");
const pb = protocol.pb;

pub const Message = union(enum) {
    connection_event: pb.ConnectionEvent,
    retry_now,
};

pub const OwnedMessage = struct {
    message: Message,

    pub fn deinit(self: *OwnedMessage, allocator: std.mem.Allocator) void {
        switch (self.message) {
            .connection_event => |*event| event.deinit(allocator),
            .retry_now => {},
        }
        self.* = undefined;
    }
};

pub const ReadStatus = union(enum) {
    blocked,
    progress,
    eof,
    truncated_frame,
    message: OwnedMessage,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    frame_source: dispatcher.Source = dispatcher.Source.uninitialized(),

    pub fn init(allocator: std.mem.Allocator) Reader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Reader) void {
        self.frame_source.deinit();
        self.* = undefined;
    }

    fn ensureFrameSource(self: *Reader, fd: c.fd_t) !void {
        if (self.frame_source.isInitialized()) {
            if (self.frame_source.frame().fd != fd) @panic("proxy diagnostics Reader reused for a different fd");
            return;
        }
        self.frame_source = try dispatcher.get().frameSource(fd);
    }

    pub fn source(self: *Reader, fd: c.fd_t) !dispatcher.Source {
        try self.ensureFrameSource(fd);
        return self.frame_source;
    }

    pub fn readReady(self: *Reader, allocator: std.mem.Allocator, fd: c.fd_t) !ReadStatus {
        try self.ensureFrameSource(fd);
        switch (self.frame_source.readFrame() catch |err| switch (err) {
            error.TruncatedFrame => return .truncated_frame,
            else => return err,
        }) {
            .blocked => return .blocked,
            .eof => return .eof,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(allocator);
                return .{ .message = try messageFromFrame(allocator, frame) };
            },
        }
    }
};

// Proxy control paths do not own a dispatcher watch for the diagnostics fd. The
// caller waits for this one frame to flush, but the write itself still advances
// through FrameWriteState so backpressure is explicit rather than hidden inside
// a raw writeAll helper.
pub fn writeConnectionEventForeground(blocking: core_blocking.Blocking, fd: c.fd_t, event: pb.ConnectionEvent.event_union) !void {
    const payload = try protocol.encodeConnectionEventPayload(app_allocator.allocator(), event);
    defer app_allocator.allocator().free(payload);
    try foreground_frame_io.writeFrame(.{
        .blocking = blocking,
        .allocator = app_allocator.allocator(),
        .fd = fd,
        .message_type = .client_daemon,
        .payload = payload,
    });
}

// Same foreground-only contract as writeConnectionEventForeground.
pub fn writeRetryNowForeground(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
    const payload = try protocol.encodeClientDaemonPayload(app_allocator.allocator(), .{ .retry_now = .{} });
    defer app_allocator.allocator().free(payload);
    try foreground_frame_io.writeFrame(.{
        .blocking = blocking,
        .allocator = app_allocator.allocator(),
        .fd = fd,
        .message_type = .client_daemon,
        .payload = payload,
    });
}

fn messageFromFrame(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !OwnedMessage {
    if (frame.message_type != .client_daemon) return error.UnexpectedProxyDiagnosticsFrame;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    const item_payload = item.payload orelse return error.UnexpectedProxyDiagnosticsFrame;
    return switch (item_payload) {
        .connection_event => |event| blk: {
            break :blk OwnedMessage{ .message = .{ .connection_event = try event.dupe(allocator) } };
        },
        .retry_now => OwnedMessage{ .message = .retry_now },
        else => error.UnexpectedProxyDiagnosticsFrame,
    };
}

test "proxy diagnostics uses client daemon frames" {
    const TestReader = struct {
        fn readMessage(reader: *Reader, allocator: std.mem.Allocator, fd: c.fd_t) !OwnedMessage {
            while (true) {
                switch (try reader.readReady(allocator, fd)) {
                    .blocked => return error.WouldBlock,
                    .progress => continue,
                    .message => |message| return message,
                    .eof => return error.EndOfStream,
                    .truncated_frame => return error.TruncatedFrame,
                }
            }
        }
    };

    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);
    try core_fds.setNonBlocking(fds[1]);
    try dispatcher.initGlobal(std.testing.allocator);
    defer dispatcher.deinitGlobal();

    const blocking = core_blocking.fromTest();

    try writeConnectionEventForeground(blocking, fds[0], .{ .daemon_disconnected = .{
        .retry_at_local_boot_time_ms = 1234,
    } });
    try writeConnectionEventForeground(blocking, fds[0], .{ .ssh_stderr = .{ .data = "ssh: nope" } });
    try writeConnectionEventForeground(blocking, fds[0], .{ .daemon_connected = .{} });
    try writeRetryNowForeground(blocking, fds[0]);

    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var disconnected = try TestReader.readMessage(&reader, std.testing.allocator, fds[1]);
    defer disconnected.deinit(std.testing.allocator);
    switch (disconnected.message.connection_event.event.?) {
        .daemon_disconnected => |event| try std.testing.expectEqual(@as(?u64, 1234), event.retry_at_local_boot_time_ms),
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var stderr = try TestReader.readMessage(&reader, std.testing.allocator, fds[1]);
    defer stderr.deinit(std.testing.allocator);
    switch (stderr.message.connection_event.event.?) {
        .ssh_stderr => |event| try std.testing.expectEqualStrings("ssh: nope", event.data),
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var connected = try TestReader.readMessage(&reader, std.testing.allocator, fds[1]);
    defer connected.deinit(std.testing.allocator);
    switch (connected.message.connection_event.event.?) {
        .daemon_connected => {},
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var retry_now = try TestReader.readMessage(&reader, std.testing.allocator, fds[1]);
    defer retry_now.deinit(std.testing.allocator);
    try std.testing.expectEqual(Message.retry_now, retry_now.message);
}
