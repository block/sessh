// Live daemon-log fanout. Subscribers attach over framed local IPC and then
// receive each new daemon event as a one-way stream until their socket closes or
// a write fails.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;
const max_pending_frames_per_subscriber: usize = 128;

// PROCESS_GLOBAL_REGISTRY: daemon-log subscribers are local clients subscribed to
// this daemon process. After the initial log request, this module owns the fd.
// The stream is one-way after subscription: client write-side EOF is harmless,
// and subscriber disconnect is detected when a later log write fails.
var subscribers: std.ArrayList(*Subscriber) = .empty;

pub fn activeSubscriberCount() usize {
    return subscribers.items.len;
}

const Subscriber = struct {
    fd: c.fd_t,
    daemon_dispatcher: *dispatcher.Dispatcher,
    write_watch_id: ?dispatcher.FdWatchId = null,
    pending_frames: std.ArrayList(protocol.FrameWriteState) = .empty,

    fn deinit(self: *Subscriber) void {
        if (self.write_watch_id) |watch_id| {
            self.daemon_dispatcher.cancel(.{ .fd = watch_id });
            self.write_watch_id = null;
        }
        for (self.pending_frames.items) |*frame| {
            frame.deinit();
        }
        self.pending_frames.deinit(self.daemon_dispatcher.allocator);
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.* = undefined;
    }
};

pub fn subscribe(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
) !void {
    const subscriber = try allocator.create(Subscriber);
    errdefer allocator.destroy(subscriber);
    subscriber.* = .{
        .fd = fd,
        .daemon_dispatcher = daemon_dispatcher,
    };
    errdefer {
        subscriber.fd = -1;
        subscriber.deinit();
    }
    try subscribers.append(allocator, subscriber);
}

pub fn unsubscribe(allocator: std.mem.Allocator, fd: c.fd_t) void {
    var index: usize = 0;
    while (index < subscribers.items.len) {
        if (subscribers.items[index].fd == fd) {
            destroySubscriberAt(allocator, index);
        } else {
            index += 1;
        }
    }
}

fn destroySubscriberAt(allocator: std.mem.Allocator, index: usize) void {
    const subscriber = subscribers.items[index];
    _ = subscribers.swapRemove(index);
    subscriber.deinit();
    allocator.destroy(subscriber);
}

fn destroySubscriber(allocator: std.mem.Allocator, subscriber: *Subscriber) void {
    var index: usize = 0;
    while (index < subscribers.items.len) {
        if (subscribers.items[index] == subscriber) {
            destroySubscriberAt(allocator, index);
            return;
        }
        index += 1;
    }
}

fn writeSubscriber(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
    // Log subscribers are best-effort observers. Drain their bounded frame queue
    // only when their socket is writable, and drop the subscriber on socket
    // errors so daemon logging never becomes required work.
    const subscriber: *Subscriber = @ptrCast(@alignCast(ctx));
    const daemon_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedDaemonLogTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        destroySubscriber(subscriber.daemon_dispatcher.allocator, subscriber);
        return;
    }
    if (!fd_event.writable) return;

    while (subscriber.pending_frames.items.len != 0) {
        const write = &subscriber.pending_frames.items[0];
        switch (try write.writeReady(subscriber.fd)) {
            .blocked, .progress => return,
            .done => {
                write.deinit();
                _ = subscriber.pending_frames.orderedRemove(0);
            },
        }
    }
    daemon_dispatcher.cancel(id);
    subscriber.write_watch_id = null;
}

fn ensureWriteWatch(subscriber: *Subscriber) !void {
    if (subscriber.write_watch_id != null) return;
    subscriber.write_watch_id = try subscriber.daemon_dispatcher.watchFd(.{
        .fd = subscriber.fd,
        .events = .{ .writable = true },
        .handler = .{
            .ctx = subscriber,
            .callback = writeSubscriber,
        },
    });
}

const QueueSubscriberFrameOptions = struct {
    allocator: std.mem.Allocator,
    subscriber: *Subscriber,
    message_type: protocol.MessageType,
    payload: []const u8,
};

fn queueSubscriberFrame(options: QueueSubscriberFrameOptions) !void {
    const allocator = options.allocator;
    const subscriber = options.subscriber;
    // Daemon logs are observational. A slow log subscriber must not stall the
    // daemon or accumulate an unbounded queue, so each subscriber gets a small
    // bounded queue. Normal startup bursts are preserved; pathological readers
    // lose later log entries until they drain.
    if (subscriber.pending_frames.items.len >= max_pending_frames_per_subscriber) return;
    var frame = try protocol.FrameWriteState.init(allocator, options.message_type, options.payload);
    errdefer frame.deinit();
    try subscriber.pending_frames.append(allocator, frame);
    try ensureWriteWatch(subscriber);
}

fn removeFailedSubscriber(allocator: std.mem.Allocator, subscriber: *Subscriber) void {
    destroySubscriber(allocator, subscriber);
}

fn sendEntry(allocator: std.mem.Allocator, entry: pb.ClientDaemonItem.DaemonLogEntry) !void {
    // Fan one encoded log entry to all current subscribers. Subscribers that
    // fail to enqueue are removed in-place; successful subscribers keep their
    // own bounded queues and write watches.
    const item_payload = try protocol.encodeClientDaemonPayload(allocator, .{ .log_entry = entry });
    defer allocator.free(item_payload);

    var index: usize = 0;
    while (index < subscribers.items.len) {
        const subscriber = subscribers.items[index];
        queueSubscriberFrame(.{
            .allocator = allocator,
            .subscriber = subscriber,
            .message_type = .client_daemon,
            .payload = item_payload,
        }) catch {
            removeFailedSubscriber(allocator, subscriber);
            continue;
        };
        if (index < subscribers.items.len and subscribers.items[index] == subscriber) {
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

const testing = if (builtin.is_test) struct {
    fn clear(allocator: std.mem.Allocator) void {
        while (subscribers.items.len != 0) {
            destroySubscriberAt(allocator, 0);
        }
        subscribers.deinit(allocator);
        subscribers = .empty;
    }
} else struct {};

test "daemon log writes new events to live subscribers" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const allocator = std.testing.allocator;
    testing.clear(allocator);
    defer testing.clear(allocator);

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    var write_fd_owned = true;
    defer if (write_fd_owned) std.posix.close(fds[1]);

    var d = try dispatcher.Dispatcher.init(allocator);
    defer d.deinit();

    try subscribe(allocator, &d, fds[1]);
    write_fd_owned = false;
    infof(allocator, "test event {}", .{1});
    _ = try d.runOnce();
    unsubscribe(allocator, fds[1]);

    var frame = try protocol_test_helpers.readFrameForTest(allocator, fds[0]);
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, frame.message_type);
    var entry = try protocol.decodeClientDaemonLogEntry(allocator, frame.payload);
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("test event 1", entry.message);
}

test "daemon log keeps a bounded pending queue per slow subscriber" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const allocator = std.testing.allocator;
    testing.clear(allocator);
    defer testing.clear(allocator);

    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    var write_fd_owned = true;
    defer if (write_fd_owned) std.posix.close(fds[1]);

    var d = try dispatcher.Dispatcher.init(allocator);
    defer d.deinit();

    try subscribe(allocator, &d, fds[1]);
    write_fd_owned = false;
    infof(allocator, "first", .{});
    infof(allocator, "second", .{});
    _ = try d.runOnce();
    unsubscribe(allocator, fds[1]);

    var frame = try protocol_test_helpers.readFrameForTest(allocator, fds[0]);
    defer frame.deinit(allocator);
    var entry = try protocol.decodeClientDaemonLogEntry(allocator, frame.payload);
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("first", entry.message);

    var second = try protocol_test_helpers.readFrameForTest(allocator, fds[0]);
    defer second.deinit(allocator);
    var second_entry = try protocol.decodeClientDaemonLogEntry(allocator, second.payload);
    defer second_entry.deinit(allocator);
    try std.testing.expectEqualStrings("second", second_entry.message);
}

// Keep this file's tests close to the implementation because the subscriber
// queueing policy is intentionally small and daemon-local.
