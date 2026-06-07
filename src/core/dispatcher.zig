const std = @import("std");
const c = std.c;
const posix = std.posix;

/// A small single-threaded event dispatcher built on `poll(2)`.
///
/// File-descriptor watches are persistent and level-triggered. Timer watches are
/// one-shot: the dispatcher folds the nearest deadline into the next poll timeout,
/// then dispatches expired timers after poll returns. That keeps the
/// implementation portable without timerfd/kqueue-specific code. The pollfd
/// storage is cached and rebuilt only when fd watches change.
pub const WatchId = u64;

pub const FdEvents = struct {
    readable: bool = false,
    writable: bool = false,
};

pub const FdWatch = struct {
    fd: c.fd_t,
    events: FdEvents,
};

pub const TimerWatch = struct {
    deadline_ms: u64,
};

pub const WatchSource = union(enum) {
    fd: FdWatch,
    timer: TimerWatch,
};

pub const FdEvent = struct {
    fd: c.fd_t,
    readable: bool = false,
    writable: bool = false,
    hangup: bool = false,
    error_event: bool = false,
    invalid: bool = false,
};

pub const TimerEvent = struct {
    deadline_ms: u64,
    fired_at_ms: u64,
};

pub const Event = union(enum) {
    fd: FdEvent,
    timer: TimerEvent,
};

pub const Handler = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, *Dispatcher, WatchId, Event) anyerror!void,
};

const Watch = struct {
    id: WatchId,
    source: WatchSource,
    handler: Handler,
    active: bool = true,
};

const PendingEvent = struct {
    id: WatchId,
    event: Event,
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    clock: std.time.Timer,
    watches: std.ArrayList(Watch) = .empty,
    pollfds: std.ArrayList(posix.pollfd) = .empty,
    poll_watch_ids: std.ArrayList(WatchId) = .empty,
    pending_events: std.ArrayList(PendingEvent) = .empty,
    next_id: WatchId = 1,
    running: bool = false,
    poll_cache_dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        return .{
            .allocator = allocator,
            .clock = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.pending_events.deinit(self.allocator);
        self.poll_watch_ids.deinit(self.allocator);
        self.pollfds.deinit(self.allocator);
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nowMs(self: *Dispatcher) u64 {
        return @intCast(self.clock.read() / std.time.ns_per_ms);
    }

    pub fn watch(self: *Dispatcher, source: WatchSource, handler: Handler) !WatchId {
        const id = self.next_id;
        self.next_id += 1;
        try self.watches.append(self.allocator, .{
            .id = id,
            .source = source,
            .handler = handler,
        });
        switch (source) {
            .fd => self.poll_cache_dirty = true,
            .timer => {},
        }
        return id;
    }

    pub fn watchFd(
        self: *Dispatcher,
        fd: c.fd_t,
        events: FdEvents,
        handler: Handler,
    ) !WatchId {
        return self.watch(.{ .fd = .{ .fd = fd, .events = events } }, handler);
    }

    pub fn watchTimerAt(
        self: *Dispatcher,
        deadline_ms: u64,
        handler: Handler,
    ) !WatchId {
        return self.watch(.{ .timer = .{ .deadline_ms = deadline_ms } }, handler);
    }

    pub fn watchTimerAfter(
        self: *Dispatcher,
        delay_ms: u64,
        handler: Handler,
    ) !WatchId {
        return self.watchTimerAt(self.nowMs() +| delay_ms, handler);
    }

    pub fn cancel(self: *Dispatcher, id: WatchId) void {
        if (self.findWatchIndex(id)) |index| {
            const watch_entry = &self.watches.items[index];
            if (!watch_entry.active) return;
            switch (watch_entry.source) {
                .fd => self.poll_cache_dirty = true,
                .timer => {},
            }
            watch_entry.active = false;
        }
    }

    pub fn stop(self: *Dispatcher) void {
        self.running = false;
    }

    pub fn run(self: *Dispatcher) !void {
        self.running = true;
        while (self.running and self.activeWatchCount() != 0) {
            _ = try self.runOnce();
        }
    }

    pub fn runOnce(self: *Dispatcher) !usize {
        self.compactInactive();
        if (self.watches.items.len == 0) return 0;

        const now_before_poll = self.nowMs();
        try self.ensurePollCache();

        var nearest_deadline: ?u64 = null;
        for (self.watches.items) |watch_entry| {
            if (!watch_entry.active) continue;
            switch (watch_entry.source) {
                .fd => {},
                .timer => |timer| {
                    if (nearest_deadline == null or timer.deadline_ms < nearest_deadline.?) {
                        nearest_deadline = timer.deadline_ms;
                    }
                },
            }
        }

        const timeout_ms = pollTimeoutMs(now_before_poll, nearest_deadline);
        if (self.pollfds.items.len == 0 and timeout_ms < 0) return 0;
        for (self.pollfds.items) |*pollfd| pollfd.revents = 0;
        const ready = try posix.poll(self.pollfds.items, timeout_ms);
        const now_after_poll = self.nowMs();

        self.pending_events.clearRetainingCapacity();

        if (ready > 0) {
            for (self.pollfds.items, self.poll_watch_ids.items) |pollfd, watch_id| {
                if (pollfd.revents == 0) continue;
                const fd_watch = self.fdWatchForId(watch_id) orelse continue;
                const event = fdEventFromRevents(fd_watch.fd, pollfd.revents);
                try self.pending_events.append(self.allocator, .{
                    .id = watch_id,
                    .event = .{ .fd = event },
                });
            }
        }

        for (self.watches.items) |*watch_entry| {
            if (!watch_entry.active) continue;
            switch (watch_entry.source) {
                .timer => |timer| {
                    if (timer.deadline_ms <= now_after_poll) {
                        try self.pending_events.append(self.allocator, .{
                            .id = watch_entry.id,
                            .event = .{ .timer = .{
                                .deadline_ms = timer.deadline_ms,
                                .fired_at_ms = now_after_poll,
                            } },
                        });
                    }
                },
                .fd => {},
            }
        }

        var dispatched: usize = 0;
        for (self.pending_events.items) |pending_event| {
            const handler = self.handlerForId(pending_event.id) orelse continue;
            try handler.callback(handler.ctx, self, pending_event.id, pending_event.event);
            switch (pending_event.event) {
                .timer => self.cancel(pending_event.id),
                .fd => {},
            }
            dispatched += 1;
        }
        self.compactInactive();
        return dispatched;
    }

    fn ensurePollCache(self: *Dispatcher) !void {
        if (!self.poll_cache_dirty) return;

        self.pollfds.clearRetainingCapacity();
        self.poll_watch_ids.clearRetainingCapacity();
        for (self.watches.items) |watch_entry| {
            if (!watch_entry.active) continue;
            switch (watch_entry.source) {
                .fd => |fd_watch| {
                    try self.pollfds.append(self.allocator, .{
                        .fd = fd_watch.fd,
                        .events = pollEvents(fd_watch.events),
                        .revents = 0,
                    });
                    try self.poll_watch_ids.append(self.allocator, watch_entry.id);
                },
                .timer => {},
            }
        }
        self.poll_cache_dirty = false;
    }

    fn findWatchIndex(self: *const Dispatcher, id: WatchId) ?usize {
        for (self.watches.items, 0..) |watch_entry, index| {
            if (watch_entry.id == id) return index;
        }
        return null;
    }

    fn handlerForId(self: *const Dispatcher, id: WatchId) ?Handler {
        const index = self.findWatchIndex(id) orelse return null;
        const watch_entry = self.watches.items[index];
        if (!watch_entry.active) return null;
        return watch_entry.handler;
    }

    fn fdWatchForId(self: *const Dispatcher, id: WatchId) ?FdWatch {
        const index = self.findWatchIndex(id) orelse return null;
        const watch_entry = self.watches.items[index];
        if (!watch_entry.active) return null;
        return switch (watch_entry.source) {
            .fd => |fd_watch| fd_watch,
            .timer => null,
        };
    }

    fn activeWatchCount(self: *const Dispatcher) usize {
        var count: usize = 0;
        for (self.watches.items) |watch_entry| {
            if (watch_entry.active) count += 1;
        }
        return count;
    }

    fn compactInactive(self: *Dispatcher) void {
        var write_index: usize = 0;
        for (self.watches.items) |watch_entry| {
            if (!watch_entry.active) continue;
            self.watches.items[write_index] = watch_entry;
            write_index += 1;
        }
        self.watches.shrinkRetainingCapacity(write_index);
    }
};

fn pollEvents(events: FdEvents) i16 {
    var result: i16 = 0;
    if (events.readable) result |= posix.POLL.IN;
    if (events.writable) result |= posix.POLL.OUT;
    return result;
}

fn fdEventFromRevents(fd: c.fd_t, revents: i16) FdEvent {
    return .{
        .fd = fd,
        .readable = (revents & posix.POLL.IN) != 0,
        .writable = (revents & posix.POLL.OUT) != 0,
        .hangup = (revents & posix.POLL.HUP) != 0,
        .error_event = (revents & posix.POLL.ERR) != 0,
        .invalid = (revents & posix.POLL.NVAL) != 0,
    };
}

fn pollTimeoutMs(now_ms: u64, nearest_deadline: ?u64) i32 {
    const deadline = nearest_deadline orelse return -1;
    if (deadline <= now_ms) return 0;
    return @intCast(@min(deadline - now_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

test "dispatcher fires timer watch" {
    const Context = struct {
        fired: bool = false,

        fn onTimer(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .timer => self.fired = true,
                .fd => return error.UnexpectedFdEvent,
            }
            dispatcher.stop();
        }
    };

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{};
    _ = try dispatcher.watchTimerAfter(1, .{ .ctx = &context, .callback = Context.onTimer });
    try dispatcher.run();
    try std.testing.expect(context.fired);
}

test "dispatcher dispatches fd readability and supports cancellation" {
    const Context = struct {
        fd: c.fd_t,
        read_byte: u8 = 0,

        fn onReadable(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .fd => |fd_event| {
                    if (!fd_event.readable) return error.ExpectedReadable;
                    var buf: [1]u8 = undefined;
                    const n = c.read(self.fd, &buf, 1);
                    if (n != 1) return error.ReadFailed;
                    self.read_byte = buf[0];
                    dispatcher.cancel(id);
                    dispatcher.stop();
                },
                .timer => return error.UnexpectedTimerEvent,
            }
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{ .fd = fds[0] };
    _ = try dispatcher.watchFd(fds[0], .{ .readable = true }, .{ .ctx = &context, .callback = Context.onReadable });
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    try dispatcher.run();
    try std.testing.expectEqual(@as(u8, 'x'), context.read_byte);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.watches.items.len);
}

test "dispatcher keeps fd poll cache stable until fd watches change" {
    const Context = struct {
        fd: c.fd_t,
        count: usize = 0,

        fn onReadable(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .fd => |fd_event| {
                    if (!fd_event.readable) return error.ExpectedReadable;
                    var buf: [1]u8 = undefined;
                    const n = c.read(self.fd, &buf, 1);
                    if (n != 1) return error.ReadFailed;
                    self.count += 1;
                    if (self.count == 2) dispatcher.cancel(id);
                },
                .timer => return error.UnexpectedTimerEvent,
            }
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{ .fd = fds[0] };
    _ = try dispatcher.watchFd(fds[0], .{ .readable = true }, .{ .ctx = &context, .callback = Context.onReadable });

    try std.testing.expect(dispatcher.poll_cache_dirty);
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    try std.testing.expectEqual(@as(usize, 1), try dispatcher.runOnce());
    try std.testing.expect(!dispatcher.poll_cache_dirty);

    const pollfds_capacity = dispatcher.pollfds.capacity;
    const poll_watch_ids_capacity = dispatcher.poll_watch_ids.capacity;
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "y"));
    try std.testing.expectEqual(@as(usize, 1), try dispatcher.runOnce());
    try std.testing.expectEqual(pollfds_capacity, dispatcher.pollfds.capacity);
    try std.testing.expectEqual(poll_watch_ids_capacity, dispatcher.poll_watch_ids.capacity);
    try std.testing.expect(dispatcher.poll_cache_dirty);
    try std.testing.expectEqual(@as(usize, 2), context.count);
}

test "dispatcher cancelled timer does not fire" {
    const Context = struct {
        fired: bool = false,

        fn onTimer(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = dispatcher;
            _ = id;
            _ = event;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired = true;
        }
    };

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{};
    const id = try dispatcher.watchTimerAfter(0, .{ .ctx = &context, .callback = Context.onTimer });
    dispatcher.cancel(id);
    try std.testing.expectEqual(@as(usize, 0), try dispatcher.runOnce());
    try std.testing.expect(!context.fired);
}
