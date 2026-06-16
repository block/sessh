const std = @import("std");
const c = std.c;

const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

var subscribers: std.ArrayList(c.fd_t) = .empty;

pub fn subscribe(allocator: std.mem.Allocator, fd: c.fd_t) !void {
    try subscribers.append(allocator, fd);
}

pub fn unsubscribe(fd: c.fd_t) void {
    var index: usize = 0;
    while (index < subscribers.items.len) {
        if (subscribers.items[index] == fd) {
            _ = subscribers.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

pub fn infof(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(message);

    sendEntry(allocator, .{
        .unix_ms = std.time.milliTimestamp(),
        .message = message,
    }) catch return;
}

fn sendEntry(allocator: std.mem.Allocator, entry: pb.ClientDaemonItem.DaemonLogEntry) !void {
    const item_payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{
        .payload = .{ .log_entry = entry },
    });
    defer allocator.free(item_payload);
    const frame = try protocol.encodeFrame(allocator, .client_daemon, item_payload);
    defer allocator.free(frame);

    var index: usize = 0;
    while (index < subscribers.items.len) {
        io.writeAll(subscribers.items[index], frame) catch {
            _ = subscribers.swapRemove(index);
            continue;
        };
        index += 1;
    }
}

fn clearForTest(allocator: std.mem.Allocator) void {
    subscribers.deinit(allocator);
    subscribers = .empty;
}

test "daemon log writes new events to live subscribers" {
    const allocator = std.testing.allocator;
    clearForTest(allocator);
    defer clearForTest(allocator);

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try subscribe(allocator, fds[1]);
    infof(allocator, "test event {}", .{1});
    unsubscribe(fds[1]);

    var frame = try protocol.readFrameAlloc(allocator, fds[0]);
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, frame.message_type);
    var entry = try protocol.decodeClientDaemonLogEntry(allocator, frame.payload);
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("test event 1", entry.message);
}
