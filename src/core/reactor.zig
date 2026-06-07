const std = @import("std");
const c = std.c;
const posix = std.posix;

/// A small single-threaded event dispatcher built on `poll(2)`.
///
/// File-descriptor watches are persistent and level-triggered. Timer watches are
/// one-shot: the reactor folds the nearest deadline into the next poll timeout,
/// then dispatches expired timers after poll returns. That keeps the
/// implementation portable without timerfd/kqueue-specific code.
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
    callback: *const fn (*anyopaque, *Reactor, WatchId, Event) anyerror!void,
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

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    clock: std.time.Timer,
    watches: std.ArrayList(Watch) = .empty,
    next_id: WatchId = 1,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Reactor {
        return .{
            .allocator = allocator,
            .clock = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *Reactor) void {
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nowMs(self: *Reactor) u64 {
        return @intCast(self.clock.read() / std.time.ns_per_ms);
    }

    pub fn watch(self: *Reactor, source: WatchSource, handler: Handler) !WatchId {
        const id = self.next_id;
        if (id == std.math.maxInt(WatchId)) return error.WatchIdExhausted;
        self.next_id += 1;
        try self.watches.append(self.allocator, .{
            .id = id,
            .source = source,
            .handler = handler,
        });
        return id;
    }

    pub fn watchFd(
        self: *Reactor,
        fd: c.fd_t,
        events: FdEvents,
        handler: Handler,
    ) !WatchId {
        return self.watch(.{ .fd = .{ .fd = fd, .events = events } }, handler);
    }

    pub fn watchTimerAt(
        self: *Reactor,
        deadline_ms: u64,
        handler: Handler,
    ) !WatchId {
        return self.watch(.{ .timer = .{ .deadline_ms = deadline_ms } }, handler);
    }

    pub fn watchTimerAfter(
        self: *Reactor,
        delay_ms: u64,
        handler: Handler,
    ) !WatchId {
        return self.watchTimerAt(self.nowMs() +| delay_ms, handler);
    }

    pub fn cancel(self: *Reactor, id: WatchId) void {
        if (self.findWatchIndex(id)) |index| {
            self.watches.items[index].active = false;
        }
    }

    pub fn stop(self: *Reactor) void {
        self.running = false;
    }

    pub fn run(self: *Reactor) !void {
        self.running = true;
        while (self.running and self.activeWatchCount() != 0) {
            _ = try self.runOnce();
        }
    }

    pub fn runOnce(self: *Reactor) !usize {
        self.compactInactive();
        if (self.watches.items.len == 0) return 0;

        const now_before_poll = self.nowMs();
        var pollfds: std.ArrayList(posix.pollfd) = .empty;
        defer pollfds.deinit(self.allocator);
        var poll_watch_ids: std.ArrayList(WatchId) = .empty;
        defer poll_watch_ids.deinit(self.allocator);

        var nearest_deadline: ?u64 = null;
        for (self.watches.items) |watch_entry| {
            if (!watch_entry.active) continue;
            switch (watch_entry.source) {
                .fd => |fd_watch| {
                    try pollfds.append(self.allocator, .{
                        .fd = fd_watch.fd,
                        .events = pollEvents(fd_watch.events),
                        .revents = 0,
                    });
                    try poll_watch_ids.append(self.allocator, watch_entry.id);
                },
                .timer => |timer| {
                    if (nearest_deadline == null or timer.deadline_ms < nearest_deadline.?) {
                        nearest_deadline = timer.deadline_ms;
                    }
                },
            }
        }

        const timeout_ms = pollTimeoutMs(now_before_poll, nearest_deadline);
        if (pollfds.items.len == 0 and timeout_ms < 0) return 0;
        const ready = try posix.poll(pollfds.items, timeout_ms);
        const now_after_poll = self.nowMs();

        var pending: std.ArrayList(PendingEvent) = .empty;
        defer pending.deinit(self.allocator);

        if (ready > 0) {
            for (pollfds.items, poll_watch_ids.items) |pollfd, watch_id| {
                if (pollfd.revents == 0) continue;
                const fd_watch = self.fdWatchForId(watch_id) orelse continue;
                const event = fdEventFromRevents(fd_watch.fd, pollfd.revents);
                try pending.append(self.allocator, .{
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
                        try pending.append(self.allocator, .{
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
        for (pending.items) |pending_event| {
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

    fn findWatchIndex(self: *const Reactor, id: WatchId) ?usize {
        for (self.watches.items, 0..) |watch_entry, index| {
            if (watch_entry.id == id) return index;
        }
        return null;
    }

    fn handlerForId(self: *const Reactor, id: WatchId) ?Handler {
        const index = self.findWatchIndex(id) orelse return null;
        const watch_entry = self.watches.items[index];
        if (!watch_entry.active) return null;
        return watch_entry.handler;
    }

    fn fdWatchForId(self: *const Reactor, id: WatchId) ?FdWatch {
        const index = self.findWatchIndex(id) orelse return null;
        const watch_entry = self.watches.items[index];
        if (!watch_entry.active) return null;
        return switch (watch_entry.source) {
            .fd => |fd_watch| fd_watch,
            .timer => null,
        };
    }

    fn activeWatchCount(self: *const Reactor) usize {
        var count: usize = 0;
        for (self.watches.items) |watch_entry| {
            if (watch_entry.active) count += 1;
        }
        return count;
    }

    fn compactInactive(self: *Reactor) void {
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

test "reactor fires timer watch" {
    const Context = struct {
        fired: bool = false,

        fn onTimer(ctx: *anyopaque, reactor: *Reactor, id: WatchId, event: Event) !void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .timer => self.fired = true,
                .fd => return error.UnexpectedFdEvent,
            }
            reactor.stop();
        }
    };

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    var context = Context{};
    _ = try reactor.watchTimerAfter(1, .{ .ctx = &context, .callback = Context.onTimer });
    try reactor.run();
    try std.testing.expect(context.fired);
}

test "reactor dispatches fd readability and supports cancellation" {
    const Context = struct {
        fd: c.fd_t,
        read_byte: u8 = 0,

        fn onReadable(ctx: *anyopaque, reactor: *Reactor, id: WatchId, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .fd => |fd_event| {
                    if (!fd_event.readable) return error.ExpectedReadable;
                    var buf: [1]u8 = undefined;
                    const n = c.read(self.fd, &buf, 1);
                    if (n != 1) return error.ReadFailed;
                    self.read_byte = buf[0];
                    reactor.cancel(id);
                    reactor.stop();
                },
                .timer => return error.UnexpectedTimerEvent,
            }
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    var context = Context{ .fd = fds[0] };
    _ = try reactor.watchFd(fds[0], .{ .readable = true }, .{ .ctx = &context, .callback = Context.onReadable });
    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    try reactor.run();
    try std.testing.expectEqual(@as(u8, 'x'), context.read_byte);
    try std.testing.expectEqual(@as(usize, 0), reactor.watches.items.len);
}

test "reactor cancelled timer does not fire" {
    const Context = struct {
        fired: bool = false,

        fn onTimer(ctx: *anyopaque, reactor: *Reactor, id: WatchId, event: Event) !void {
            _ = reactor;
            _ = id;
            _ = event;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired = true;
        }
    };

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    var context = Context{};
    const id = try reactor.watchTimerAfter(0, .{ .ctx = &context, .callback = Context.onTimer });
    reactor.cancel(id);
    try std.testing.expectEqual(@as(usize, 0), try reactor.runOnce());
    try std.testing.expect(!context.fired);
}
