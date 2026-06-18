const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const core_fds = @import("../core/fds.zig");
const protocol = @import("../protocol/mod.zig");
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
    frame_reader: protocol.FrameReader,

    pub fn init(allocator: std.mem.Allocator) Reader {
        return .{ .frame_reader = protocol.FrameReader.init(allocator) };
    }

    pub fn deinit(self: *Reader) void {
        self.frame_reader.deinit();
        self.* = undefined;
    }

    pub fn readReady(self: *Reader, allocator: std.mem.Allocator, fd: c.fd_t) !ReadStatus {
        switch (try self.frame_reader.readReady(fd)) {
            .blocked => return .blocked,
            .progress => return .progress,
            .eof => return .eof,
            .truncated_frame => return .truncated_frame,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(allocator);
                return .{ .message = try messageFromFrame(allocator, frame) };
            },
        }
    }
};

pub fn writeConnectionEvent(fd: c.fd_t, event: pb.ConnectionEvent.event_union) !void {
    try protocol.sendClientDaemonConnectionEventFrame(app_allocator.allocator(), fd, event);
}

pub fn writeRetryNow(fd: c.fd_t) !void {
    try protocol.sendClientDaemonPayloadFrame(app_allocator.allocator(), fd, .{ .retry_now = .{} });
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
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);
    try core_fds.setNonBlocking(fds[1]);

    try writeConnectionEvent(fds[0], .{ .daemon_disconnected = .{
        .retry_at_local_boot_time_ms = 1234,
    } });
    try writeConnectionEvent(fds[0], .{ .ssh_stderr = .{ .data = "ssh: nope" } });
    try writeConnectionEvent(fds[0], .{ .daemon_connected = .{} });
    try writeRetryNow(fds[0]);

    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var disconnected = try readMessageForTest(&reader, std.testing.allocator, fds[1]);
    defer disconnected.deinit(std.testing.allocator);
    switch (disconnected.message.connection_event.event.?) {
        .daemon_disconnected => |event| try std.testing.expectEqual(@as(?u64, 1234), event.retry_at_local_boot_time_ms),
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var stderr = try readMessageForTest(&reader, std.testing.allocator, fds[1]);
    defer stderr.deinit(std.testing.allocator);
    switch (stderr.message.connection_event.event.?) {
        .ssh_stderr => |event| try std.testing.expectEqualStrings("ssh: nope", event.data),
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var connected = try readMessageForTest(&reader, std.testing.allocator, fds[1]);
    defer connected.deinit(std.testing.allocator);
    switch (connected.message.connection_event.event.?) {
        .daemon_connected => {},
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }

    var retry_now = try readMessageForTest(&reader, std.testing.allocator, fds[1]);
    defer retry_now.deinit(std.testing.allocator);
    try std.testing.expectEqual(Message.retry_now, retry_now.message);
}

fn readMessageForTest(reader: *Reader, allocator: std.mem.Allocator, fd: c.fd_t) !OwnedMessage {
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
