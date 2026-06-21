const std = @import("std");
const c = std.c;
const posix = std.posix;

const dispatch_io = @import("dispatch_io.zig");
const NonSuspendingTimer = @import("non_suspending_timer.zig").NonSuspendingTimer;
const protocol = @import("../protocol/mod.zig");
const slot_holder = @import("slot_holder.zig");

/// A small single-threaded event dispatcher built on `poll(2)`.
///
/// The public scheduling primitive is `DispatchTask`. Sources describe what a
/// task needs to read before it can run, sinks describe output queues that must
/// be below their watermark, and task deadlines model timers. That keeps fd
/// readiness, timer expiry, and backpressure as pieces of one scheduling model
/// instead of separate callback APIs that can accidentally block each other.
///
/// Production entrypoints initialize the process-global Dispatcher before role
/// code runs. Helpers use `dispatcher.get()` rather than creating nested event
/// loops.
pub const LoopExit = enum {
    explicit,
    implicit,
};

pub const FdEvents = struct {
    readable: bool = false,
    writable: bool = false,
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

const SourceStorage = union(enum) {
    byte: *dispatch_io.ByteSource,
    frame: *dispatch_io.FrameSource,
    fd: FdSource,

    fn sourceFd(self: *const SourceStorage) c.fd_t {
        return switch (self.*) {
            .byte => |source| source.fd,
            .frame => |source| source.fd,
            .fd => |source| source.fd,
        };
    }

    fn pollEvents(self: *const SourceStorage) i16 {
        return switch (self.*) {
            .byte, .frame => posix.POLL.IN,
            .fd => |source| fdEventsToPollEvents(source.events),
        };
    }

    fn readReady(self: *SourceStorage, revents: i16) !dispatch_io.SourceReadStatus {
        return switch (self.*) {
            .byte => |source| source.readReady(),
            .frame => |source| source.readReady(),
            .fd => |*source| source.readReady(revents),
        };
    }

    fn hasReadyUnit(self: *const SourceStorage) bool {
        return switch (self.*) {
            .byte => |source| source.hasReadyUnit(),
            .frame => |source| source.hasReadyUnit(),
            .fd => |*source| source.hasReadyUnit(),
        };
    }

    fn sourceKind(self: *const SourceStorage) SourceKind {
        return switch (self.*) {
            .byte => .byte,
            .frame => .frame,
            .fd => .fd,
        };
    }

    fn deinit(self: *SourceStorage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .byte => |source| {
                source.deinit();
                allocator.destroy(source);
            },
            .frame => |source| {
                source.deinit();
                allocator.destroy(source);
            },
            .fd => {},
        }
        self.* = undefined;
    }
};

const SourceKind = enum {
    byte,
    frame,
    fd,
};

const FdSource = struct {
    fd: c.fd_t,
    events: FdEvents,
    ready_event: ?FdEvent = null,

    fn readReady(self: *FdSource, revents: i16) dispatch_io.SourceReadStatus {
        self.ready_event = fdEventFromRevents(self.fd, revents);
        return .ready;
    }

    fn hasReadyUnit(self: *const FdSource) bool {
        return self.ready_event != null;
    }

    fn takeEvent(self: *FdSource) ?FdEvent {
        const event = self.ready_event orelse return null;
        self.ready_event = null;
        return event;
    }
};

const SourceSlots = slot_holder.SlotHolder(SourceStorage);

pub const Source = struct {
    handle: ?SourceSlots.Handle = null,

    pub fn uninitialized() Source {
        return .{};
    }

    pub fn isInitialized(self: Source) bool {
        const handle = self.handle orelse return false;
        return handle.get() != null;
    }

    pub fn eql(self: Source, other: Source) bool {
        const lhs = self.handle orelse return false;
        const rhs = other.handle orelse return false;
        return lhs.eql(rhs);
    }

    pub fn deinit(self: *Source) void {
        const handle = self.handle orelse return;
        if (handle.get()) |storage| storage.deinit(handle.holder.allocator);
        handle.release();
        self.* = Source.uninitialized();
    }

    pub fn byte(self: Source) *dispatch_io.ByteSource {
        const storage = sourceStorage(self) orelse @panic("uninitialized or stale ByteSource");
        return switch (storage.*) {
            .byte => |source| source,
            else => @panic("source is not ByteSource"),
        };
    }

    pub fn frame(self: Source) *dispatch_io.FrameSource {
        const storage = sourceStorage(self) orelse @panic("uninitialized or stale FrameSource");
        return switch (storage.*) {
            .frame => |source| source,
            else => @panic("source is not FrameSource"),
        };
    }

    pub fn readBytes(self: Source) ?dispatch_io.ByteSource.Read {
        return self.byte().read();
    }

    pub fn readFrame(self: Source) !dispatch_io.FrameSource.Read {
        return self.frame().readFrame();
    }

    pub fn setFdEvents(self: Source, events: FdEvents) void {
        const storage = sourceStorage(self) orelse @panic("uninitialized or stale fd Source");
        switch (storage.*) {
            .fd => |*source| source.events = events,
            else => @panic("source is not fd Source"),
        }
    }

    pub fn takeFdEvent(self: Source) ?FdEvent {
        const storage = sourceStorage(self) orelse return null;
        return switch (storage.*) {
            .fd => |*source| source.takeEvent(),
            else => null,
        };
    }

    fn fd(self: Source) ?c.fd_t {
        const storage = sourceStorage(self) orelse return null;
        return storage.sourceFd();
    }

    fn pollEvents(self: Source) ?i16 {
        const storage = sourceStorage(self) orelse return null;
        return storage.pollEvents();
    }

    fn readReady(self: Source, revents: i16) !dispatch_io.SourceReadStatus {
        const storage = sourceStorage(self) orelse return .blocked;
        return storage.readReady(revents);
    }

    fn hasReadyUnit(self: Source) bool {
        const storage = sourceStorage(self) orelse return false;
        return storage.hasReadyUnit();
    }
};

fn sourceStorage(source: Source) ?*SourceStorage {
    const handle = source.handle orelse return null;
    return handle.get();
}

const SinkStorage = union(enum) {
    byte: *dispatch_io.ByteSink,
    frame: *dispatch_io.FrameSink,

    fn sinkFd(self: *const SinkStorage) c.fd_t {
        return switch (self.*) {
            .byte => |sink| sink.fd,
            .frame => |sink| sink.fd,
        };
    }

    fn writeReady(self: *SinkStorage) !dispatch_io.SinkWriteStatus {
        return switch (self.*) {
            .byte => |sink| sink.writeReady(),
            .frame => |sink| sink.writeReady(),
        };
    }

    fn hasPendingWrite(self: *const SinkStorage) bool {
        return switch (self.*) {
            .byte => |sink| sink.hasPendingWrite(),
            .frame => |sink| sink.hasPendingWrite(),
        };
    }

    fn belowWatermark(self: *const SinkStorage) bool {
        return switch (self.*) {
            .byte => |sink| sink.belowWatermark(),
            .frame => |sink| sink.belowWatermark(),
        };
    }

    fn sinkKind(self: *const SinkStorage) SinkKind {
        return switch (self.*) {
            .byte => .byte,
            .frame => .frame,
        };
    }

    fn deinit(self: *SinkStorage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .byte => |sink| {
                sink.deinit();
                allocator.destroy(sink);
            },
            .frame => |sink| {
                sink.deinit();
                allocator.destroy(sink);
            },
        }
        self.* = undefined;
    }
};

const SinkKind = enum {
    byte,
    frame,
};

const SinkSlots = slot_holder.SlotHolder(SinkStorage);

pub const Sink = struct {
    handle: ?SinkSlots.Handle = null,

    pub fn uninitialized() Sink {
        return .{};
    }

    pub fn isInitialized(self: Sink) bool {
        const handle = self.handle orelse return false;
        return handle.get() != null;
    }

    pub fn eql(self: Sink, other: Sink) bool {
        const lhs = self.handle orelse return false;
        const rhs = other.handle orelse return false;
        return lhs.eql(rhs);
    }

    pub fn deinit(self: *Sink) void {
        const handle = self.handle orelse return;
        if (handle.get()) |storage| storage.deinit(handle.holder.allocator);
        handle.release();
        self.* = Sink.uninitialized();
    }

    pub fn byte(self: Sink) *dispatch_io.ByteSink {
        const storage = sinkStorage(self) orelse @panic("uninitialized or stale ByteSink");
        return switch (storage.*) {
            .byte => |sink| sink,
            else => @panic("sink is not ByteSink"),
        };
    }

    pub fn frame(self: Sink) *dispatch_io.FrameSink {
        const storage = sinkStorage(self) orelse @panic("uninitialized or stale FrameSink");
        return switch (storage.*) {
            .frame => |sink| sink,
            else => @panic("sink is not FrameSink"),
        };
    }

    pub fn writeBytes(self: Sink, bytes: []const u8) !void {
        try self.byte().writeBytes(bytes);
    }

    pub fn writeFrame(self: Sink, message_type: protocol.MessageType, payload: []const u8) !void {
        try self.frame().writeFrame(message_type, payload);
    }

    pub fn writeOwnedFrame(self: Sink, owned_frame: *protocol.OwnedFrame) !void {
        try self.frame().writeOwnedFrame(owned_frame);
    }

    pub fn hasPendingWrite(self: Sink) bool {
        const storage = sinkStorage(self) orelse return false;
        return storage.hasPendingWrite();
    }

    pub fn belowWatermark(self: Sink) bool {
        const storage = sinkStorage(self) orelse return false;
        return storage.belowWatermark();
    }

    fn fd(self: Sink) ?c.fd_t {
        const storage = sinkStorage(self) orelse return null;
        return storage.sinkFd();
    }

    fn writeReady(self: Sink) !dispatch_io.SinkWriteStatus {
        const storage = sinkStorage(self) orelse return .drained;
        return storage.writeReady();
    }
};

fn sinkStorage(sink: Sink) ?*SinkStorage {
    const handle = sink.handle orelse return null;
    return handle.get();
}

pub const DispatchTask = struct {
    allocator: std.mem.Allocator = undefined,
    ctx: *anyopaque = undefined,
    runFn: *const fn (*anyopaque, *Dispatcher, *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus = undefined,
    initialized: bool = false,
    sources: std.ArrayList(Source) = .empty,
    sinks: std.ArrayList(Sink) = .empty,
    source_readiness: SourceReadiness = .all,
    not_before_ms: ?u64 = null,
    scheduled_dispatcher: ?*Dispatcher = null,
    scheduled_index: usize = 0,

    pub fn uninitialized() DispatchTask {
        return .{};
    }

    pub fn isInitialized(self: *const DispatchTask) bool {
        return self.initialized;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        runFn: *const fn (*anyopaque, *Dispatcher, *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus,
    ) DispatchTask {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .runFn = runFn,
            .initialized = true,
        };
    }

    pub fn deinit(self: *DispatchTask) void {
        if (!self.initialized) return;
        self.cancel();
        self.sources.deinit(self.allocator);
        self.sinks.deinit(self.allocator);
        self.* = DispatchTask.uninitialized();
    }

    pub fn schedule(self: *DispatchTask, d: *Dispatcher) !void {
        self.requireInitialized();
        if (self.scheduled_dispatcher) |existing| {
            if (existing == d) return;
            @panic("DispatchTask scheduled on multiple Dispatchers");
        }
        self.scheduled_index = d.dispatch_tasks.items.len;
        try d.dispatch_tasks.append(d.allocator, self);
        self.scheduled_dispatcher = d;
    }

    pub fn cancel(self: *DispatchTask) void {
        if (!self.initialized) return;
        const d = self.scheduled_dispatcher orelse return;
        d.removeTaskAt(self.scheduled_index, true);
    }

    pub fn isScheduled(self: *const DispatchTask) bool {
        return self.initialized and self.scheduled_dispatcher != null;
    }

    pub fn requireSource(self: *DispatchTask, source: Source) !void {
        self.requireInitialized();
        if (!source.isInitialized()) @panic("uninitialized Source required by DispatchTask");
        for (self.sources.items) |existing| {
            if (existing.eql(source)) return;
        }
        try self.sources.append(self.allocator, source);
    }

    pub fn requireSink(self: *DispatchTask, sink: Sink) !void {
        self.requireInitialized();
        if (!sink.isInitialized()) @panic("uninitialized Sink required by DispatchTask");
        for (self.sinks.items) |existing| {
            if (existing.eql(sink)) return;
        }
        try self.sinks.append(self.allocator, sink);
    }

    pub fn clearSources(self: *DispatchTask) void {
        self.requireInitialized();
        self.sources.clearRetainingCapacity();
    }

    pub fn setSourceReadiness(self: *DispatchTask, readiness: SourceReadiness) void {
        self.requireInitialized();
        self.source_readiness = readiness;
    }

    pub fn clearSinks(self: *DispatchTask) void {
        self.requireInitialized();
        self.sinks.clearRetainingCapacity();
    }

    pub fn clearTimer(self: *DispatchTask) void {
        self.requireInitialized();
        self.not_before_ms = null;
    }

    pub fn setTimerAt(self: *DispatchTask, deadline_ms: u64) void {
        self.requireInitialized();
        self.not_before_ms = deadline_ms;
    }

    pub fn setTimerAfter(self: *DispatchTask, d: *Dispatcher, delay_ms: u64) void {
        self.requireInitialized();
        self.not_before_ms = d.nowMs() +| delay_ms;
    }

    fn requireInitialized(self: *const DispatchTask) void {
        if (!self.initialized) @panic("uninitialized DispatchTask");
    }
};

pub const SourceReadiness = enum {
    all,
    any,
};

pub fn dispatchTask(
    comptime Context: type,
    allocator: std.mem.Allocator,
    ctx: *Context,
    comptime run: fn (*Context, *Dispatcher, *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus,
) DispatchTask {
    const Wrapper = struct {
        fn callback(raw_ctx: *anyopaque, d: *Dispatcher, task: *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus {
            const typed_ctx: *Context = @ptrCast(@alignCast(raw_ctx));
            return run(typed_ctx, d, task);
        }
    };
    return DispatchTask.init(allocator, ctx, Wrapper.callback);
}

pub fn fdDispatchTask(
    comptime Context: type,
    allocator: std.mem.Allocator,
    ctx: *Context,
    source: Source,
    comptime run: fn (*Context, *Dispatcher, *DispatchTask, FdEvent) anyerror!dispatch_io.DispatchTaskStatus,
) !DispatchTask {
    const Wrapper = struct {
        fn callback(raw_ctx: *anyopaque, d: *Dispatcher, task: *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus {
            const typed_ctx: *Context = @ptrCast(@alignCast(raw_ctx));
            const event = task.sources.items[0].takeFdEvent() orelse return error.ExpectedFdEvent;
            return run(typed_ctx, d, task, event);
        }
    };
    var task = DispatchTask.init(allocator, ctx, Wrapper.callback);
    errdefer task.deinit();
    try task.requireSource(source);
    return task;
}

pub fn timerDispatchTask(
    comptime Context: type,
    allocator: std.mem.Allocator,
    ctx: *Context,
    comptime run: fn (*Context, *Dispatcher, *DispatchTask, TimerEvent) anyerror!dispatch_io.DispatchTaskStatus,
) DispatchTask {
    const Wrapper = struct {
        fn callback(raw_ctx: *anyopaque, d: *Dispatcher, task: *DispatchTask) anyerror!dispatch_io.DispatchTaskStatus {
            const typed_ctx: *Context = @ptrCast(@alignCast(raw_ctx));
            const deadline = task.not_before_ms orelse d.nowMs();
            return run(typed_ctx, d, task, .{
                .deadline_ms = deadline,
                .fired_at_ms = d.nowMs(),
            });
        }
    };
    return DispatchTask.init(allocator, ctx, Wrapper.callback);
}

const TaskPollRef = union(enum) {
    source: Source,
    sink: Sink,
};

var global_dispatcher: ?Dispatcher = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    if (global_dispatcher != null) @panic("global Dispatcher initialized twice");
    global_dispatcher = try Dispatcher.init(allocator);
}

pub fn get() *Dispatcher {
    if (global_dispatcher == null) @panic("global Dispatcher used before initialization");
    return &global_dispatcher.?;
}

pub fn deinitGlobal() void {
    if (global_dispatcher) |*instance| {
        instance.deinit();
        global_dispatcher = null;
    }
}

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    clock: NonSuspendingTimer,
    source_slots: SourceSlots,
    sink_slots: SinkSlots,
    dispatch_tasks: std.ArrayList(*DispatchTask) = .empty,
    poll_scratch: std.ArrayList(posix.pollfd) = .empty,
    task_poll_refs: std.ArrayList(TaskPollRef) = .empty,
    next_task_dispatch_index: usize = 0,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        if (global_dispatcher != null) @panic("Dispatcher.init called while global Dispatcher is initialized");
        return .{
            .allocator = allocator,
            .clock = try NonSuspendingTimer.start(),
            .source_slots = SourceSlots.init(allocator),
            .sink_slots = SinkSlots.init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        var sink_index: usize = 0;
        while (sink_index < self.sink_slots.len()) : (sink_index += 1) {
            if (self.sink_slots.valueAt(sink_index)) |storage| storage.deinit(self.allocator);
        }
        var source_index: usize = 0;
        while (source_index < self.source_slots.len()) : (source_index += 1) {
            if (self.source_slots.valueAt(source_index)) |storage| storage.deinit(self.allocator);
        }
        for (self.dispatch_tasks.items) |task| {
            task.scheduled_dispatcher = null;
            task.scheduled_index = 0;
        }
        self.task_poll_refs.deinit(self.allocator);
        self.poll_scratch.deinit(self.allocator);
        self.dispatch_tasks.deinit(self.allocator);
        self.sink_slots.deinit();
        self.source_slots.deinit();
        self.* = undefined;
    }

    pub fn nowMs(self: *Dispatcher) u64 {
        return @intCast(self.clock.read() / std.time.ns_per_ms);
    }

    pub fn fdSource(self: *Dispatcher, fd: c.fd_t, events: FdEvents) !Source {
        if (self.sourceHandleForFd(fd)) |source| {
            const storage = sourceStorage(source).?;
            if (storage.sourceKind() != .fd) @panic("fd already registered as non-fd Source");
            source.setFdEvents(events);
            return source;
        }
        const handle = try self.source_slots.add(.{ .fd = .{ .fd = fd, .events = events } });
        return .{ .handle = handle };
    }

    pub fn byteSource(self: *Dispatcher, fd: c.fd_t, capacity: usize) !Source {
        if (self.sourceHandleForFd(fd)) |source| {
            const storage = sourceStorage(source).?;
            if (storage.sourceKind() != .byte) @panic("fd already registered as non-byte Source");
            return source;
        }
        const source = try self.allocator.create(dispatch_io.ByteSource);
        errdefer self.allocator.destroy(source);
        source.* = try dispatch_io.ByteSource.init(self.allocator, fd, capacity);
        errdefer source.deinit();

        const handle = try self.source_slots.add(.{ .byte = source });
        return .{ .handle = handle };
    }

    pub fn frameSource(self: *Dispatcher, fd: c.fd_t) !Source {
        if (self.sourceHandleForFd(fd)) |source| {
            const storage = sourceStorage(source).?;
            if (storage.sourceKind() != .frame) @panic("fd already registered as non-frame Source");
            return source;
        }
        const source = try self.allocator.create(dispatch_io.FrameSource);
        errdefer self.allocator.destroy(source);
        source.* = dispatch_io.FrameSource.init(self.allocator, fd);
        errdefer source.deinit();

        const handle = try self.source_slots.add(.{ .frame = source });
        return .{ .handle = handle };
    }

    pub fn byteSink(self: *Dispatcher, options: dispatch_io.ByteSinkOptions) !Sink {
        if (self.sinkHandleForFd(options.fd)) |sink| {
            const storage = sinkStorage(sink).?;
            if (storage.sinkKind() != .byte) @panic("fd already registered as non-byte Sink");
            return sink;
        }
        const sink = try self.allocator.create(dispatch_io.ByteSink);
        errdefer self.allocator.destroy(sink);
        sink.* = dispatch_io.ByteSink.init(options);
        errdefer sink.deinit();

        const handle = try self.sink_slots.add(.{ .byte = sink });
        return .{ .handle = handle };
    }

    pub fn frameSink(self: *Dispatcher, options: dispatch_io.FrameSinkOptions) !Sink {
        if (self.sinkHandleForFd(options.fd)) |sink| {
            const storage = sinkStorage(sink).?;
            if (storage.sinkKind() != .frame) @panic("fd already registered as non-frame Sink");
            return sink;
        }
        const sink = try self.allocator.create(dispatch_io.FrameSink);
        errdefer self.allocator.destroy(sink);
        sink.* = dispatch_io.FrameSink.init(options);
        errdefer sink.deinit();

        const handle = try self.sink_slots.add(.{ .frame = sink });
        return .{ .handle = handle };
    }

    pub fn stop(self: *Dispatcher) void {
        self.running = false;
    }

    pub fn activeTaskCount(self: *const Dispatcher) usize {
        return self.dispatch_tasks.items.len;
    }

    pub fn loopForBlocking(self: *Dispatcher) !LoopExit {
        if (self.running) return error.DispatcherAlreadyRunning;
        self.running = true;
        defer self.running = false;
        while (self.running and self.dispatch_tasks.items.len != 0) {
            _ = try self.runOnce();
        }
        return if (self.running) .implicit else .explicit;
    }

    /// Poll readiness for all scheduled task dependencies, give Source/Sink
    /// objects a chance to make bounded progress, then run ready tasks in a
    /// rotating order. The rotation is the fairness point: a constantly-ready
    /// connection cannot monopolize every pass through the loop.
    pub fn runOnce(self: *Dispatcher) !usize {
        if (self.dispatch_tasks.items.len == 0) return 0;

        const now_before_poll = self.nowMs();
        const task_ready = self.anyTaskReady(now_before_poll);
        const timeout_ms = pollTimeoutMs(now_before_poll, self.nearestTaskDeadline());
        try self.rebuildPollScratch(now_before_poll);
        if (self.poll_scratch.items.len == 0 and timeout_ms < 0 and !task_ready) return 0;
        for (self.poll_scratch.items) |*pollfd| pollfd.revents = 0;
        const ready = try posix.poll(self.poll_scratch.items, if (task_ready) 0 else timeout_ms);
        const now_after_poll = self.nowMs();

        if (ready > 0) {
            try self.dispatchReadyTaskIo();
        }
        return try self.dispatchReadyTasks(now_after_poll);
    }

    fn sourceHandleForFd(self: *Dispatcher, fd: c.fd_t) ?Source {
        if (fd < 0) return null;
        var index: usize = 0;
        while (index < self.source_slots.len()) : (index += 1) {
            const storage = self.source_slots.valueAt(index) orelse continue;
            if (storage.sourceFd() != fd) continue;
            return .{ .handle = .{
                .holder = &self.source_slots,
                .index = index,
                .generation = self.source_slots.slots.items[index].generation,
            } };
        }
        return null;
    }

    fn sinkHandleForFd(self: *Dispatcher, fd: c.fd_t) ?Sink {
        if (fd < 0) return null;
        var index: usize = 0;
        while (index < self.sink_slots.len()) : (index += 1) {
            const storage = self.sink_slots.valueAt(index) orelse continue;
            if (storage.sinkFd() != fd) continue;
            return .{ .handle = .{
                .holder = &self.sink_slots,
                .index = index,
                .generation = self.sink_slots.slots.items[index].generation,
            } };
        }
        return null;
    }

    fn removeTaskAt(self: *Dispatcher, index: usize, clear_task: bool) void {
        if (index >= self.dispatch_tasks.items.len) return;
        const removed = self.dispatch_tasks.items[index];
        const last_index = self.dispatch_tasks.items.len - 1;
        if (index != last_index) {
            const moved = self.dispatch_tasks.items[last_index];
            self.dispatch_tasks.items[index] = moved;
            moved.scheduled_index = index;
        }
        _ = self.dispatch_tasks.pop();
        if (clear_task) {
            removed.scheduled_dispatcher = null;
            removed.scheduled_index = 0;
        }
        if (self.next_task_dispatch_index > index and self.next_task_dispatch_index != 0) {
            self.next_task_dispatch_index -= 1;
        }
        if (self.dispatch_tasks.items.len == 0) {
            self.next_task_dispatch_index = 0;
        } else if (self.next_task_dispatch_index >= self.dispatch_tasks.items.len) {
            self.next_task_dispatch_index = 0;
        }
    }

    fn removeTaskPointer(self: *Dispatcher, task: *DispatchTask, clear_task: bool) void {
        var index: usize = 0;
        while (index < self.dispatch_tasks.items.len) : (index += 1) {
            if (self.dispatch_tasks.items[index] == task) {
                self.removeTaskAt(index, clear_task);
                return;
            }
        }
    }

    fn rebuildPollScratch(self: *Dispatcher, now_ms: u64) !void {
        self.poll_scratch.clearRetainingCapacity();
        self.task_poll_refs.clearRetainingCapacity();

        for (self.dispatch_tasks.items) |task| {
            for (task.sinks.items) |sink| {
                if (!sink.hasPendingWrite()) continue;
                const fd = sink.fd() orelse continue;
                try self.task_poll_refs.append(self.allocator, .{ .sink = sink });
                try self.poll_scratch.append(self.allocator, .{
                    .fd = fd,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                });
            }

            if (!taskOtherwiseReadyForSourcePoll(task, now_ms)) continue;
            for (task.sources.items) |source| {
                if (source.hasReadyUnit()) continue;
                const fd = source.fd() orelse continue;
                const events = source.pollEvents() orelse continue;
                try self.task_poll_refs.append(self.allocator, .{ .source = source });
                try self.poll_scratch.append(self.allocator, .{
                    .fd = fd,
                    .events = events,
                    .revents = 0,
                });
            }
        }
    }

    fn dispatchReadyTaskIo(self: *Dispatcher) !void {
        for (self.poll_scratch.items, self.task_poll_refs.items) |pollfd, ref| {
            if (pollfd.revents == 0) continue;
            switch (ref) {
                .source => |source| {
                    if ((pollfd.revents & (posix.POLL.IN | posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
                        _ = try source.readReady(pollfd.revents);
                    }
                },
                .sink => |sink| {
                    if ((pollfd.revents & (posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
                        _ = try sink.writeReady();
                    }
                },
            }
        }
    }

    fn dispatchReadyTasks(self: *Dispatcher, now_ms: u64) !usize {
        if (self.dispatch_tasks.items.len == 0) return 0;

        const dispatch_limit = self.dispatch_tasks.items.len;
        var dispatched: usize = 0;
        while (dispatched < dispatch_limit and self.dispatch_tasks.items.len != 0) {
            const index = self.nextReadyTaskIndex(now_ms) orelse break;
            const task = self.dispatch_tasks.items[index];
            self.next_task_dispatch_index = if (self.dispatch_tasks.items.len == 0)
                0
            else
                (index + 1) % self.dispatch_tasks.items.len;
            const status = try task.runFn(task.ctx, self, task);
            if (status == .done) {
                self.removeTaskPointer(task, true);
            }
            dispatched += 1;
        }
        return dispatched;
    }

    fn nextReadyTaskIndex(self: *Dispatcher, now_ms: u64) ?usize {
        if (self.dispatch_tasks.items.len == 0) return null;
        var offset: usize = 0;
        while (offset < self.dispatch_tasks.items.len) : (offset += 1) {
            const index = (self.next_task_dispatch_index + offset) % self.dispatch_tasks.items.len;
            const task = self.dispatch_tasks.items[index];
            if (taskReadyAt(task, now_ms)) return index;
        }
        return null;
    }

    fn anyTaskReady(self: *Dispatcher, now_ms: u64) bool {
        return self.nextReadyTaskIndex(now_ms) != null;
    }

    fn nearestTaskDeadline(self: *Dispatcher) ?u64 {
        var nearest: ?u64 = null;
        for (self.dispatch_tasks.items) |task| {
            const deadline = task.not_before_ms orelse continue;
            nearest = minOptionalDeadline(nearest, deadline);
        }
        return nearest;
    }
};

fn taskOtherwiseReadyForSourcePoll(task: *const DispatchTask, now_ms: u64) bool {
    if (task.not_before_ms) |deadline| {
        if (deadline > now_ms) return false;
    }
    for (task.sinks.items) |sink| {
        if (!sink.belowWatermark()) return false;
    }
    return true;
}

fn taskReadyAt(task: *const DispatchTask, now_ms: u64) bool {
    if (!taskOtherwiseReadyForSourcePoll(task, now_ms)) return false;
    switch (task.source_readiness) {
        .all => {
            for (task.sources.items) |source| {
                if (!source.hasReadyUnit()) return false;
            }
            return true;
        },
        .any => {
            if (task.sources.items.len == 0) return true;
            for (task.sources.items) |source| {
                if (source.hasReadyUnit()) return true;
            }
            return false;
        },
    }
}

fn fdEventsToPollEvents(events: FdEvents) i16 {
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

fn minOptionalDeadline(lhs: ?u64, rhs: ?u64) ?u64 {
    if (lhs) |lhs_value| {
        if (rhs) |rhs_value| return @min(lhs_value, rhs_value);
        return lhs_value;
    }
    return rhs;
}

test "dispatcher fires timer task" {
    const Context = struct {
        fired: bool = false,

        fn run(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            _ = task;
            self.fired = true;
            d.stop();
            return .done;
        }
    };

    var d = try Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    var context = Context{};
    var task = dispatchTask(Context, std.testing.allocator, &context, Context.run);
    defer task.deinit();
    task.setTimerAfter(&d, 1);
    try task.schedule(&d);
    _ = try d.loopForBlocking();
    try std.testing.expect(context.fired);
}

test "dispatcher runs task when byte source has bytes" {
    const Context = struct {
        source: Source,
        value: []const u8 = &.{},

        fn run(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            _ = d;
            _ = task;
            switch (self.source.readBytes() orelse return error.ExpectedSourceRead) {
                .bytes => |bytes| self.value = bytes,
                .eof => return error.UnexpectedEof,
            }
            return .done;
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var d = try Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var source = try d.byteSource(fds[0], 8);
    defer source.deinit();
    var context = Context{ .source = source };
    var task = dispatchTask(Context, std.testing.allocator, &context, Context.run);
    defer task.deinit();
    try task.requireSource(source);
    try task.schedule(&d);

    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    try std.testing.expectEqual(LoopExit.implicit, try d.loopForBlocking());
    try std.testing.expectEqualStrings("x", context.value);
}

test "dispatcher dispatches fd source readability" {
    const Context = struct {
        source: Source,
        fd: c.fd_t,
        read_byte: u8 = 0,

        fn run(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            _ = task;
            const event = self.source.takeFdEvent() orelse return error.ExpectedFdEvent;
            if (!event.readable) return error.ExpectedReadable;
            var buf: [1]u8 = undefined;
            const n = c.read(self.fd, &buf, 1);
            if (n != 1) return error.ReadFailed;
            self.read_byte = buf[0];
            d.stop();
            return .done;
        }
    };

    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var d = try Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    var source = try d.fdSource(fds[0], .{ .readable = true });
    defer source.deinit();
    var context = Context{ .source = source, .fd = fds[0] };
    var task = dispatchTask(Context, std.testing.allocator, &context, Context.run);
    defer task.deinit();
    try task.requireSource(source);
    try task.schedule(&d);

    try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    _ = try d.loopForBlocking();
    try std.testing.expectEqual(@as(u8, 'x'), context.read_byte);
}

test "dispatcher rotates ready task order" {
    const Context = struct {
        sources: [3]Source,
        seen: std.ArrayList(u8) = .empty,

        fn run0(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            return self.runIndex(d, task, 0);
        }

        fn run1(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            return self.runIndex(d, task, 1);
        }

        fn run2(self: *@This(), d: *Dispatcher, task: *DispatchTask) !dispatch_io.DispatchTaskStatus {
            return self.runIndex(d, task, 2);
        }

        fn runIndex(self: *@This(), d: *Dispatcher, task: *DispatchTask, index: u8) !dispatch_io.DispatchTaskStatus {
            _ = task;
            _ = self.sources[index].takeFdEvent() orelse return error.ExpectedFdEvent;
            try self.seen.append(std.testing.allocator, index);
            if (self.seen.items.len == 3) d.stop();
            return .pending;
        }
    };

    var pipes: [3][2]c.fd_t = undefined;
    for (&pipes) |*fds| fds.* = try posix.pipe();
    defer for (pipes) |fds| {
        posix.close(fds[0]);
        posix.close(fds[1]);
    };

    var d = try Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    var sources = [_]Source{
        try d.fdSource(pipes[0][0], .{ .readable = true }),
        try d.fdSource(pipes[1][0], .{ .readable = true }),
        try d.fdSource(pipes[2][0], .{ .readable = true }),
    };
    defer for (&sources) |*source| source.deinit();

    var context = Context{ .sources = sources };
    defer context.seen.deinit(std.testing.allocator);

    var tasks = [_]DispatchTask{
        dispatchTask(Context, std.testing.allocator, &context, Context.run0),
        dispatchTask(Context, std.testing.allocator, &context, Context.run1),
        dispatchTask(Context, std.testing.allocator, &context, Context.run2),
    };
    defer for (&tasks) |*task| task.deinit();
    for (&tasks, sources) |*task, source| {
        try task.requireSource(source);
        try task.schedule(&d);
    }

    for (pipes) |fds| try std.testing.expectEqual(@as(usize, 1), try posix.write(fds[1], "x"));
    _ = try d.loopForBlocking();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, context.seen.items);
}
