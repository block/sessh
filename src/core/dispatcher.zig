const std = @import("std");
const c = std.c;
const posix = std.posix;

/// A small single-threaded event dispatcher built on `poll(2)`.
///
/// File-descriptor watches and timer watches use separate storage because they
/// have different performance needs. Fd watches map 1:1 to `pollfds`, so fd
/// cancellation and interest updates are direct slot writes. Timer watches live
/// in a deadline min-heap, so finding the next timeout is O(1) and cancellation
/// is O(log n) without making `poll(2)` scan timer-only entries.
pub const FdWatchId = struct {
    index: usize,
    generation: u64,
};

pub const TimerWatchId = struct {
    index: usize,
    generation: u64,
};

pub const WatchId = union(enum) {
    fd: FdWatchId,
    timer: TimerWatchId,
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

const FdWatchSlot = struct {
    generation: u64 = 0,
    active: bool = false,
    fd: c.fd_t = -1,
    events: FdEvents = .{},
    handler: Handler = undefined,
};

const TimerWatchSlot = struct {
    generation: u64 = 0,
    active: bool = false,
    deadline_ms: u64 = 0,
    handler: Handler = undefined,
    heap_index: ?usize = null,
};

const PendingEvent = struct {
    id: WatchId,
    event: Event,
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    clock: std.time.Timer,
    fd_watches: std.ArrayList(FdWatchSlot) = .empty,
    free_fd_watches: std.ArrayList(usize) = .empty,
    pollfds: std.ArrayList(posix.pollfd) = .empty,
    timer_watches: std.ArrayList(TimerWatchSlot) = .empty,
    free_timer_watches: std.ArrayList(usize) = .empty,
    timer_heap: std.ArrayList(TimerWatchId) = .empty,
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
        self.timer_heap.deinit(self.allocator);
        self.free_timer_watches.deinit(self.allocator);
        self.timer_watches.deinit(self.allocator);
        self.pollfds.deinit(self.allocator);
        self.free_fd_watches.deinit(self.allocator);
        self.fd_watches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn nowMs(self: *Dispatcher) u64 {
        return @intCast(self.clock.read() / std.time.ns_per_ms);
    }

    pub fn watch(self: *Dispatcher, source: WatchSource, handler: Handler) !WatchId {
        return switch (source) {
            .fd => |fd_watch| .{ .fd = try self.watchFd(fd_watch.fd, fd_watch.events, handler) },
            .timer => |timer| .{ .timer = try self.watchTimerAt(timer.deadline_ms, handler) },
        };
    }

    pub fn watchFd(
        self: *Dispatcher,
        fd: c.fd_t,
        events: FdEvents,
        handler: Handler,
    ) !FdWatchId {
        const reused = self.free_fd_watches.items.len != 0;
        const index = if (reused) self.free_fd_watches.items[self.free_fd_watches.items.len - 1] else self.fd_watches.items.len;
        if (!reused) {
            try self.free_fd_watches.ensureTotalCapacity(self.allocator, index + 1);
        }
        const generation = if (reused) self.fd_watches.items[index].generation else 0;
        if (reused) {
            _ = self.free_fd_watches.pop();
        } else {
            try self.fd_watches.append(self.allocator, .{});
            errdefer _ = self.fd_watches.pop();
            try self.pollfds.append(self.allocator, disabledPollfd());
            errdefer _ = self.pollfds.pop();
        }

        self.fd_watches.items[index] = .{
            .generation = generation,
            .active = true,
            .fd = fd,
            .events = events,
            .handler = handler,
        };
        self.pollfds.items[index] = .{
            .fd = fd,
            .events = pollEvents(events),
            .revents = 0,
        };
        self.active_count += 1;
        return .{
            .index = index,
            .generation = generation,
        };
    }

    pub fn watchTimerAt(
        self: *Dispatcher,
        deadline_ms: u64,
        handler: Handler,
    ) !TimerWatchId {
        const reused = self.free_timer_watches.items.len != 0;
        const index = if (reused) self.free_timer_watches.items[self.free_timer_watches.items.len - 1] else self.timer_watches.items.len;
        if (!reused) {
            try self.free_timer_watches.ensureTotalCapacity(self.allocator, index + 1);
        }
        const generation = if (reused) self.timer_watches.items[index].generation else 0;
        const id: TimerWatchId = .{
            .index = index,
            .generation = generation,
        };
        if (reused) {
            _ = self.free_timer_watches.pop();
        } else {
            try self.timer_watches.append(self.allocator, .{});
            errdefer _ = self.timer_watches.pop();
        }
        errdefer self.cancelTimerByIndex(index);

        self.timer_watches.items[index] = .{
            .generation = generation,
            .active = true,
            .deadline_ms = deadline_ms,
            .handler = handler,
            .heap_index = self.timer_heap.items.len,
        };
        try self.timer_heap.append(self.allocator, id);
        self.siftTimerUp(self.timer_heap.items.len - 1);
        self.active_count += 1;
        return id;
    }

    pub fn watchTimerAfter(
        self: *Dispatcher,
        delay_ms: u64,
        handler: Handler,
    ) !TimerWatchId {
        return self.watchTimerAt(self.nowMs() +| delay_ms, handler);
    }

    pub fn cancel(self: *Dispatcher, id: WatchId) void {
        switch (id) {
            .fd => |fd_id| self.cancelFd(fd_id),
            .timer => |timer_id| self.cancelTimer(timer_id),
        }
    }

    pub fn updateFdEvents(self: *Dispatcher, id: FdWatchId, events: FdEvents) !void {
        const slot = self.fdSlotForId(id) orelse return error.UnknownWatch;
        slot.events = events;
        self.pollfds.items[id.index].events = pollEvents(events);
        self.pollfds.items[id.index].revents = 0;
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
        const nearest_deadline = self.nearestTimerDeadline();
        const timeout_ms = pollTimeoutMs(now_before_poll, nearest_deadline);
        if (self.pollfds.items.len == 0 and timeout_ms < 0) return 0;
        for (self.pollfds.items) |*pollfd| pollfd.revents = 0;
        const ready = try posix.poll(self.pollfds.items, timeout_ms);
        const now_after_poll = self.nowMs();

        self.pending_events.clearRetainingCapacity();

        if (ready > 0) {
            for (self.pollfds.items, 0..) |pollfd, index| {
                if (pollfd.revents == 0) continue;
                const fd_id = self.fdWatchIdForIndex(index);
                const slot = self.fdSlotForId(fd_id) orelse continue;
                const event = fdEventFromRevents(slot.fd, pollfd.revents);
                try self.pending_events.append(self.allocator, .{
                    .id = .{ .fd = fd_id },
                    .event = .{ .fd = event },
                });
            }
        }

        while (self.peekExpiredTimer(now_after_poll)) |timer_id| {
            const slot = self.timerSlotForId(timer_id) orelse {
                self.removeTimerHeapIndex(0);
                continue;
            };
            const deadline_ms = slot.deadline_ms;
            const heap_index = slot.heap_index.?;
            self.removeTimerHeapIndex(heap_index);
            try self.pending_events.append(self.allocator, .{
                .id = .{ .timer = timer_id },
                .event = .{ .timer = .{
                    .deadline_ms = deadline_ms,
                    .fired_at_ms = now_after_poll,
                } },
            });
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

    fn cancelFd(self: *Dispatcher, id: FdWatchId) void {
        const slot = self.fdSlotForId(id) orelse return;
        slot.active = false;
        slot.generation += 1;
        slot.fd = -1;
        slot.events = .{};
        self.pollfds.items[id.index] = disabledPollfd();
        self.active_count -= 1;
        self.free_fd_watches.appendAssumeCapacity(id.index);
    }

    fn cancelTimer(self: *Dispatcher, id: TimerWatchId) void {
        const slot = self.timerSlotForId(id) orelse return;
        if (slot.heap_index) |heap_index| {
            self.removeTimerHeapIndex(heap_index);
        }
        self.cancelTimerByIndex(id.index);
    }

    fn cancelTimerByIndex(self: *Dispatcher, index: usize) void {
        const slot = &self.timer_watches.items[index];
        if (!slot.active) return;
        slot.active = false;
        slot.generation += 1;
        slot.deadline_ms = 0;
        slot.heap_index = null;
        self.active_count -= 1;
        self.free_timer_watches.appendAssumeCapacity(index);
    }

    fn nearestTimerDeadline(self: *const Dispatcher) ?u64 {
        if (self.timer_heap.items.len == 0) return null;
        const timer_id = self.timer_heap.items[0];
        const slot = self.timerSlotForIdConst(timer_id) orelse return null;
        return slot.deadline_ms;
    }

    fn peekExpiredTimer(self: *const Dispatcher, now_ms: u64) ?TimerWatchId {
        if (self.timer_heap.items.len == 0) return null;
        const timer_id = self.timer_heap.items[0];
        const slot = self.timerSlotForIdConst(timer_id) orelse return timer_id;
        if (slot.deadline_ms > now_ms) return null;
        return timer_id;
    }

    fn handlerForId(self: *const Dispatcher, id: WatchId) ?Handler {
        return switch (id) {
            .fd => |fd_id| blk: {
                const slot = self.fdSlotForIdConst(fd_id) orelse break :blk null;
                break :blk slot.handler;
            },
            .timer => |timer_id| blk: {
                const slot = self.timerSlotForIdConst(timer_id) orelse break :blk null;
                break :blk slot.handler;
            },
        };
    }

    fn fdWatchIdForIndex(self: *const Dispatcher, index: usize) FdWatchId {
        const slot = self.fd_watches.items[index];
        return .{
            .index = index,
            .generation = slot.generation,
        };
    }

    fn fdSlotForId(self: *Dispatcher, id: FdWatchId) ?*FdWatchSlot {
        if (id.index >= self.fd_watches.items.len) return null;
        const slot = &self.fd_watches.items[id.index];
        if (!slot.active) return null;
        if (slot.generation != id.generation) return null;
        return slot;
    }

    fn fdSlotForIdConst(self: *const Dispatcher, id: FdWatchId) ?*const FdWatchSlot {
        if (id.index >= self.fd_watches.items.len) return null;
        const slot = &self.fd_watches.items[id.index];
        if (!slot.active) return null;
        if (slot.generation != id.generation) return null;
        return slot;
    }

    fn timerSlotForId(self: *Dispatcher, id: TimerWatchId) ?*TimerWatchSlot {
        if (id.index >= self.timer_watches.items.len) return null;
        const slot = &self.timer_watches.items[id.index];
        if (!slot.active) return null;
        if (slot.generation != id.generation) return null;
        return slot;
    }

    fn timerSlotForIdConst(self: *const Dispatcher, id: TimerWatchId) ?*const TimerWatchSlot {
        if (id.index >= self.timer_watches.items.len) return null;
        const slot = &self.timer_watches.items[id.index];
        if (!slot.active) return null;
        if (slot.generation != id.generation) return null;
        return slot;
    }

    fn removeTimerHeapIndex(self: *Dispatcher, heap_index: usize) void {
        const removed_id = self.timer_heap.items[heap_index];
        const last_index = self.timer_heap.items.len - 1;
        if (heap_index != last_index) {
            const moved = self.timer_heap.items[last_index];
            self.timer_heap.items[heap_index] = moved;
            self.timerSlotForId(moved).?.heap_index = heap_index;
        }
        _ = self.timer_heap.pop();
        if (self.timerSlotForId(removed_id)) |removed_slot| {
            removed_slot.heap_index = null;
        }
        if (heap_index < self.timer_heap.items.len) {
            if (heap_index > 0 and self.timerLess(heap_index, parentIndex(heap_index))) {
                self.siftTimerUp(heap_index);
            } else {
                self.siftTimerDown(heap_index);
            }
        }
    }

    fn siftTimerUp(self: *Dispatcher, start_index: usize) void {
        var index = start_index;
        while (index > 0) {
            const parent = parentIndex(index);
            if (!self.timerLess(index, parent)) break;
            self.swapTimers(index, parent);
            index = parent;
        }
    }

    fn siftTimerDown(self: *Dispatcher, start_index: usize) void {
        var index = start_index;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.timer_heap.items.len) break;
            const right = left + 1;
            var smallest = left;
            if (right < self.timer_heap.items.len and self.timerLess(right, left)) {
                smallest = right;
            }
            if (!self.timerLess(smallest, index)) break;
            self.swapTimers(index, smallest);
            index = smallest;
        }
    }

    fn timerLess(self: *const Dispatcher, lhs_index: usize, rhs_index: usize) bool {
        const lhs = self.timer_heap.items[lhs_index];
        const rhs = self.timer_heap.items[rhs_index];
        const lhs_deadline = self.timerSlotForIdConst(lhs).?.deadline_ms;
        const rhs_deadline = self.timerSlotForIdConst(rhs).?.deadline_ms;
        if (lhs_deadline != rhs_deadline) return lhs_deadline < rhs_deadline;
        return lhs.index < rhs.index;
    }

    fn swapTimers(self: *Dispatcher, a: usize, b: usize) void {
        const a_id = self.timer_heap.items[a];
        const b_id = self.timer_heap.items[b];
        self.timer_heap.items[a] = b_id;
        self.timer_heap.items[b] = a_id;
        self.timerSlotForId(a_id).?.heap_index = b;
        self.timerSlotForId(b_id).?.heap_index = a;
    }
};

fn parentIndex(index: usize) usize {
    return (index - 1) / 2;
}

fn disabledPollfd() posix.pollfd {
    return .{
        .fd = -1,
        .events = 0,
        .revents = 0,
    };
}

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
    try std.testing.expectEqual(@as(c.fd_t, -1), dispatcher.pollfds.items[0].fd);
    try std.testing.expectEqual(@as(usize, 1), dispatcher.free_fd_watches.items.len);
}

test "dispatcher fd watch slots are reused and stale ids are rejected" {
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
    dispatcher.cancel(.{ .fd = old_id });
    const new_id = try dispatcher.watchFd(fds[0], .{}, .{ .ctx = &context, .callback = Context.onReadable });

    try std.testing.expectEqual(old_id.index, new_id.index);
    try std.testing.expect(old_id.generation != new_id.generation);
    try std.testing.expectError(error.UnknownWatch, dispatcher.updateFdEvents(old_id, .{ .readable = true }));
    try std.testing.expectEqual(@as(i16, 0), dispatcher.pollfds.items[new_id.index].events);

    try dispatcher.updateFdEvents(new_id, .{ .readable = true });
    try std.testing.expectEqual(pollEvents(.{ .readable = true }), dispatcher.pollfds.items[new_id.index].events);
}

test "dispatcher timer heap fires earliest timer first without scanning pollfds" {
    const Context = struct {
        fired: std.ArrayList(u8) = .empty,

        fn onTimer(ctx: *anyopaque, dispatcher: *Dispatcher, id: WatchId, event: Event) !void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .timer => |timer| try self.fired.append(std.testing.allocator, @intCast(timer.deadline_ms)),
                .fd => return error.UnexpectedFdEvent,
            }
            if (self.fired.items.len == 2) dispatcher.stop();
        }
    };

    var dispatcher = try Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = Context{};
    defer context.fired.deinit(std.testing.allocator);

    const now = dispatcher.nowMs();
    _ = try dispatcher.watchTimerAt(now + 30, .{ .ctx = &context, .callback = Context.onTimer });
    _ = try dispatcher.watchTimerAt(now + 1, .{ .ctx = &context, .callback = Context.onTimer });

    try std.testing.expectEqual(@as(usize, 0), dispatcher.pollfds.items.len);
    try dispatcher.run();
    try std.testing.expectEqual(@as(usize, 2), context.fired.items.len);
    try std.testing.expect(context.fired.items[0] <= context.fired.items[1]);
}

test "dispatcher timer cancellation removes heap entry and rejects stale ids" {
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

    const now = dispatcher.nowMs();
    const far = try dispatcher.watchTimerAt(now + 10_000, .{ .ctx = &context, .callback = Context.onTimer });
    const near = try dispatcher.watchTimerAt(now + 1, .{ .ctx = &context, .callback = Context.onTimer });

    dispatcher.cancel(.{ .timer = near });
    try std.testing.expectEqual(@as(usize, 1), dispatcher.timer_heap.items.len);
    try std.testing.expectEqual(far.index, dispatcher.timer_heap.items[0].index);

    const replacement = try dispatcher.watchTimerAt(now + 1, .{ .ctx = &context, .callback = Context.onTimer });
    try std.testing.expectEqual(near.index, replacement.index);
    try std.testing.expect(near.generation != replacement.generation);
    dispatcher.cancel(.{ .timer = near });
    _ = try dispatcher.runOnce();
    try std.testing.expect(context.fired);
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
    dispatcher.cancel(.{ .timer = id });
    try std.testing.expectEqual(@as(usize, 0), try dispatcher.runOnce());
    try std.testing.expect(!context.fired);
}
