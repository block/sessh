const std = @import("std");
const c = std.c;
const posix = std.posix;

/// A small single-threaded event dispatcher built on `poll(2)`.
///
/// File-descriptor watches are persistent and level-triggered. Timer watches are
/// one-shot: the dispatcher folds the nearest deadline into the next poll timeout,
/// then dispatches expired timers after poll returns. That keeps the
/// implementation portable without timerfd/kqueue-specific code. The pollfd
/// storage is kept dense for `poll(2)`, while watch handles point at stable
/// slots in `watches`.
///
/// `WatchId` uses a slot index plus a generation. The index gives O(1) lookup;
/// the generation rejects stale handles after a slot has been canceled and
/// reused for another watch.
pub const WatchId = struct {
    index: usize,
    generation: u64,
};

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
    generation: u64 = 0,
    active: bool = false,
    source: WatchSource = undefined,
    handler: Handler = undefined,
    poll_index: ?usize = null,
};

const PendingEvent = struct {
    id: WatchId,
    event: Event,
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    clock: std.time.Timer,
    watches: std.ArrayList(Watch) = .empty,
    free_watches: std.ArrayList(usize) = .empty,
    pollfds: std.ArrayList(posix.pollfd) = .empty,
    poll_watch_ids: std.ArrayList(WatchId) = .empty,
    pending_events: std.ArrayList(PendingEvent) = .empty,
    active_count: usize = 0,
    running: bool = false,

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
        self.free_watches.deinit(self.allocator);
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nowMs(self: *Dispatcher) u64 {
        return @intCast(self.clock.read() / std.time.ns_per_ms);
    }

    pub fn watch(self: *Dispatcher, source: WatchSource, handler: Handler) !WatchId {
        const reused = self.free_watches.items.len != 0;
        const index = if (reused) self.free_watches.items[self.free_watches.items.len - 1] else self.watches.items.len;
        if (!reused) {
            try self.free_watches.ensureTotalCapacity(self.allocator, index + 1);
        }
        const generation = if (reused) self.watches.items[index].generation else 0;
        const id: WatchId = .{
            .index = index,
            .generation = generation,
        };

        var poll_index: ?usize = null;
        switch (source) {
            .fd => |fd_watch| {
                poll_index = self.pollfds.items.len;
                try self.pollfds.append(self.allocator, .{
                    .fd = fd_watch.fd,
                    .events = pollEvents(fd_watch.events),
                    .revents = 0,
                });
                errdefer _ = self.pollfds.pop();
                try self.poll_watch_ids.append(self.allocator, id);
                errdefer _ = self.poll_watch_ids.pop();
            },
            .timer => {},
        }

        if (reused) {
            _ = self.free_watches.pop();
        } else {
            try self.watches.append(self.allocator, .{});
        }

        self.watches.items[index] = .{
            .generation = generation,
            .active = true,
            .source = source,
            .handler = handler,
            .poll_index = poll_index,
        };
        self.active_count += 1;
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
        const index = self.indexForId(id) orelse return;
        const poll_index = switch (self.watches.items[index].source) {
            .fd => self.watches.items[index].poll_index.?,
            .timer => null,
        };
        if (poll_index) |fd_poll_index| {
            self.removePollIndex(fd_poll_index);
        }

        const watch_entry = &self.watches.items[index];
        watch_entry.active = false;
        watch_entry.generation += 1;
        watch_entry.poll_index = null;
        self.active_count -= 1;
        self.free_watches.appendAssumeCapacity(index);
    }

    pub fn updateFdEvents(self: *Dispatcher, id: WatchId, events: FdEvents) !void {
        const watch_entry = self.watchForId(id) orelse return error.UnknownWatch;

        switch (watch_entry.source) {
            .fd => |*fd_watch| {
                fd_watch.events = events;
                const poll_index = watch_entry.poll_index.?;
                self.pollfds.items[poll_index].events = pollEvents(events);
                self.pollfds.items[poll_index].revents = 0;
            },
            .timer => return error.NotFdWatch,
        }
    }

    pub fn stop(self: *Dispatcher) void {
        self.running = false;
    }

    pub fn run(self: *Dispatcher) !void {
        self.running = true;
        while (self.running and self.active_count != 0) {
            _ = try self.runOnce();
        }
    }

    pub fn runOnce(self: *Dispatcher) !usize {
        if (self.active_count == 0) return 0;

        const now_before_poll = self.nowMs();

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

        for (self.watches.items, 0..) |*watch_entry, index| {
            if (!watch_entry.active) continue;
            switch (watch_entry.source) {
                .timer => |timer| {
                    if (timer.deadline_ms <= now_after_poll) {
                        try self.pending_events.append(self.allocator, .{
                            .id = self.watchIdForIndex(index),
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
        return dispatched;
    }

    fn watchIdForIndex(self: *const Dispatcher, index: usize) WatchId {
        const watch_entry = self.watches.items[index];
        return .{
            .index = index,
            .generation = watch_entry.generation,
        };
    }

    fn handlerForId(self: *const Dispatcher, id: WatchId) ?Handler {
        const watch_entry = self.watchForIdConst(id) orelse return null;
        return watch_entry.handler;
    }

    fn fdWatchForId(self: *const Dispatcher, id: WatchId) ?FdWatch {
        const watch_entry = self.watchForIdConst(id) orelse return null;
        return switch (watch_entry.source) {
            .fd => |fd_watch| fd_watch,
            .timer => null,
        };
    }

    fn indexForId(self: *const Dispatcher, id: WatchId) ?usize {
        if (id.index >= self.watches.items.len) return null;
        const watch_entry = self.watches.items[id.index];
        if (!watch_entry.active) return null;
        if (watch_entry.generation != id.generation) return null;
        return id.index;
    }

    fn watchForId(self: *Dispatcher, id: WatchId) ?*Watch {
        const index = self.indexForId(id) orelse return null;
        return &self.watches.items[index];
    }

    fn watchForIdConst(self: *const Dispatcher, id: WatchId) ?*const Watch {
        const index = self.indexForId(id) orelse return null;
        return &self.watches.items[index];
    }

    fn removePollIndex(self: *Dispatcher, poll_index: usize) void {
        const last_index = self.pollfds.items.len - 1;
        if (poll_index != last_index) {
            self.pollfds.items[poll_index] = self.pollfds.items[last_index];
            const moved_id = self.poll_watch_ids.items[last_index];
            self.poll_watch_ids.items[poll_index] = moved_id;
            const moved_watch = self.watchForId(moved_id).?;
            moved_watch.poll_index = poll_index;
        }
        _ = self.pollfds.pop();
        _ = self.poll_watch_ids.pop();
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
    try std.testing.expectEqual(@as(usize, 0), dispatcher.active_count);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pollfds.items.len);
    try std.testing.expectEqual(@as(usize, 1), dispatcher.free_watches.items.len);
}

test "dispatcher keeps dense poll storage stable until fd watch is cancelled" {
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

    try std.testing.expectEqual(@as(usize, 1), dispatcher.pollfds.items.len);
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    try std.testing.expectEqual(@as(usize, 1), try dispatcher.runOnce());

    const pollfds_capacity = dispatcher.pollfds.capacity;
    const poll_watch_ids_capacity = dispatcher.poll_watch_ids.capacity;
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "y"));
    try std.testing.expectEqual(@as(usize, 1), try dispatcher.runOnce());
    try std.testing.expectEqual(pollfds_capacity, dispatcher.pollfds.capacity);
    try std.testing.expectEqual(poll_watch_ids_capacity, dispatcher.poll_watch_ids.capacity);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pollfds.items.len);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.poll_watch_ids.items.len);
    try std.testing.expectEqual(@as(usize, 2), context.count);
}

test "dispatcher updates fd events in-place" {
    const Context = struct {
        fd: c.fd_t,
        read_byte: u8 = 0,

        fn onReadable(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = id;
            _ = dispatcher;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .fd => |fd_event| {
                    if (!fd_event.readable) return error.ExpectedReadable;
                    var buf: [1]u8 = undefined;
                    const n = c.read(self.fd, &buf, 1);
                    if (n != 1) return error.ReadFailed;
                    self.read_byte = buf[0];
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
    const id = try dispatcher.watchFd(fds[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });

    try std.testing.expectEqual(@as(i16, 0), dispatcher.pollfds.items[0].events);
    const pollfds_capacity = dispatcher.pollfds.capacity;
    const poll_watch_ids_capacity = dispatcher.poll_watch_ids.capacity;

    try dispatcher.updateFdEvents(id, .{ .readable = true });
    try std.testing.expectEqual(pollEvents(.{ .readable = true }), dispatcher.pollfds.items[0].events);
    try std.testing.expectEqual(pollfds_capacity, dispatcher.pollfds.capacity);
    try std.testing.expectEqual(poll_watch_ids_capacity, dispatcher.poll_watch_ids.capacity);

    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "z"));
    try std.testing.expectEqual(@as(usize, 1), try dispatcher.runOnce());
    try std.testing.expectEqual(@as(u8, 'z'), context.read_byte);
}

test "dispatcher rejects stale watch ids after slot reuse" {
    const Context = struct {
        fn onReadable(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = ctx;
            _ = dispatcher;
            _ = id;
            _ = event;
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{};

    const old_id = try dispatcher.watchFd(fds[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });
    dispatcher.cancel(old_id);
    const new_id = try dispatcher.watchFd(fds[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });

    try std.testing.expectEqual(old_id.index, new_id.index);
    try std.testing.expect(old_id.generation != new_id.generation);
    try std.testing.expectError(error.UnknownWatch, dispatcher.updateFdEvents(old_id, .{ .readable = true }));
    try std.testing.expectEqual(@as(i16, 0), dispatcher.pollfds.items[0].events);

    try dispatcher.updateFdEvents(new_id, .{ .readable = true });
    try std.testing.expectEqual(pollEvents(.{ .readable = true }), dispatcher.pollfds.items[0].events);
}

test "dispatcher fd cancel updates moved poll index" {
    const Context = struct {
        fn onReadable(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = ctx;
            _ = dispatcher;
            _ = id;
            _ = event;
        }
    };

    const first = try posix.pipe();
    defer posix.close(first[0]);
    defer posix.close(first[1]);
    const second = try posix.pipe();
    defer posix.close(second[0]);
    defer posix.close(second[1]);

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{};

    const first_id = try dispatcher.watchFd(first[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });
    const second_id = try dispatcher.watchFd(second[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });

    dispatcher.cancel(first_id);
    try std.testing.expectEqual(@as(usize, 1), dispatcher.pollfds.items.len);
    try std.testing.expectEqual(second[0], dispatcher.pollfds.items[0].fd);

    try dispatcher.updateFdEvents(second_id, .{ .readable = true });
    try std.testing.expectEqual(pollEvents(.{ .readable = true }), dispatcher.pollfds.items[0].events);
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
