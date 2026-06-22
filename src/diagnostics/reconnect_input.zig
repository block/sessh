// Reconnect-control input state for foreground UI loops. It recognizes local
// sessh controls, schedules short visual feedback, and keeps ordinary input
// untouched whenever reconnect interception is disabled.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const dispatcher = @import("../core/dispatcher.zig");
const reconnect_control = @import("../reconnect/control.zig");
const terminal = @import("../tty/terminal.zig");

const disconnected_input_flash_ms = 35;

pub const Decision = enum {
    wait_elapsed,
    reconnect_now,
    client_hangup,
};

pub const State = struct {
    reconnect_acknowledged: bool = false,
    input_during_disconnect: bool = false,
    escape_filter: terminal.EscapeFilter = .{},
    disconnected_input_flash_until_ms: u64 = 0,

    pub fn hasReconnectAcknowledgement(self: *const State) bool {
        return self.reconnect_acknowledged;
    }

    pub fn consumeReconnectAcknowledgement(self: *State) bool {
        const acknowledged = self.reconnect_acknowledged;
        self.reconnect_acknowledged = false;
        return acknowledged;
    }

    pub fn poll(
        self: *State,
        blocking: core_blocking.Blocking,
        options: PollOptions,
    ) !Decision {
        var wait = try PollWait.init(self, blocking, options);
        defer wait.deinit();
        return wait.run();
    }

    pub fn refreshDisconnectedInputFlash(self: *State, blocking: core_blocking.Blocking, output_fd: c.fd_t, now_ms: u64) !void {
        if (self.disconnected_input_flash_until_ms <= 0) return;
        if (now_ms < self.disconnected_input_flash_until_ms) return;
        try self.clearDisconnectedInputFlash(blocking, output_fd);
    }

    pub fn clearDisconnectedInputFlash(self: *State, blocking: core_blocking.Blocking, output_fd: c.fd_t) !void {
        if (self.disconnected_input_flash_until_ms <= 0) return;
        self.disconnected_input_flash_until_ms = 0;
        if (c.isatty(output_fd) != 0) try blocking.writeAll(output_fd, "\x1b[?5l");
    }

    fn effectivePollTimeout(self: *const State, timeout_ms: i32, overlay_presentation: bool, now_ms: u64) i32 {
        var effective_timeout = timeout_ms;
        if (effective_timeout < 0 and overlay_presentation) effective_timeout = 250;
        if (self.disconnected_input_flash_until_ms <= 0) return effective_timeout;
        if (now_ms >= self.disconnected_input_flash_until_ms) return 0;
        const remaining_ms = self.disconnected_input_flash_until_ms - now_ms;
        const flash_timeout: i32 = @intCast(@min(remaining_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
        if (effective_timeout < 0) return flash_timeout;
        return @min(effective_timeout, flash_timeout);
    }

    fn alertDisconnectedInput(self: *State, blocking: core_blocking.Blocking, output_fd: c.fd_t, now_ms: u64) !void {
        try blocking.writeAll(output_fd, "\x07");
        if (c.isatty(output_fd) == 0) return;
        if (self.disconnected_input_flash_until_ms <= 0) {
            try blocking.writeAll(output_fd, "\x1b[?5h");
        }
        self.disconnected_input_flash_until_ms = now_ms +| disconnected_input_flash_ms;
    }
};

const PollWait = struct {
    state: *State,
    blocking: core_blocking.Blocking,
    options: PollOptions,
    input_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    diagnostic_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    input_flags_guard: ?core_fds.StatusFlagsGuard = null,
    diagnostic_flags_guard: ?core_fds.StatusFlagsGuard = null,
    io_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    timer_task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    decision: ?Decision = null,

    fn init(state: *State, blocking: core_blocking.Blocking, options: PollOptions) !PollWait {
        var input_flags_guard = try core_fds.StatusFlagsGuard.setNonBlocking(options.terminal_fds.input);
        errdefer input_flags_guard.restore();
        var diagnostic_flags_guard = if (options.diagnostic_notify_read_fd >= 0)
            try core_fds.StatusFlagsGuard.setNonBlocking(options.diagnostic_notify_read_fd)
        else
            null;
        errdefer if (diagnostic_flags_guard) |*guard| guard.restore();
        const d = dispatcher.get();
        return .{
            .state = state,
            .blocking = blocking,
            .options = options,
            .input_source = try d.byteSource(options.terminal_fds.input, 256),
            .diagnostic_source = if (options.diagnostic_notify_read_fd >= 0)
                try d.byteSource(options.diagnostic_notify_read_fd, 128)
            else
                dispatcher.Source.uninitialized(),
            .input_flags_guard = input_flags_guard,
            .diagnostic_flags_guard = diagnostic_flags_guard,
        };
    }

    fn deinit(self: *PollWait) void {
        self.io_task.deinit();
        self.timer_task.deinit();
        self.diagnostic_source.deinit();
        self.input_source.deinit();
        if (self.diagnostic_flags_guard) |*guard| guard.restore();
        if (self.input_flags_guard) |*guard| guard.restore();
    }

    fn run(self: *PollWait) !Decision {
        const d = dispatcher.get();
        const timeout_ms = self.state.effectivePollTimeout(
            self.options.timeout_ms,
            self.options.overlay_presentation,
            self.options.now_ms,
        );
        if (timeout_ms == 0) return self.pollImmediate();

        self.io_task = dispatcher.dispatchTask(PollWait, d.allocator, self, runIo);
        self.io_task.setSourceReadiness(.any);
        try self.io_task.requireSource(self.input_source);
        if (self.diagnostic_source.isInitialized()) try self.io_task.requireSource(self.diagnostic_source);
        try self.io_task.schedule(d);

        if (timeout_ms >= 0) {
            self.timer_task = dispatcher.timerDispatchTask(PollWait, d.allocator, self, runTimer);
            self.timer_task.setTimerAfter(d, @intCast(timeout_ms));
            try self.timer_task.schedule(d);
        }

        while (self.decision == null) {
            if (try d.runOnce() == 0 and d.activeTaskCount() == 0) return .wait_elapsed;
        }
        return self.decision.?;
    }

    fn pollImmediate(self: *PollWait) !Decision {
        if (self.diagnostic_source.isInitialized()) {
            switch (try self.diagnostic_source.byte().readReady()) {
                .ready, .eof => drainDiagnosticNotifierSource(self.diagnostic_source),
                .blocked, .progress => {},
            }
        }
        switch (try self.input_source.byte().readReady()) {
            .ready, .eof => return self.readInput(),
            .blocked, .progress => return .wait_elapsed,
        }
    }

    fn runIo(
        self: *PollWait,
        d: *dispatcher.Dispatcher,
        task: *dispatcher.DispatchTask,
    ) !dispatch_io.DispatchTaskStatus {
        _ = d;
        _ = task;
        if (self.diagnostic_source.isInitialized() and self.diagnostic_source.hasReadyUnit()) {
            drainDiagnosticNotifierSource(self.diagnostic_source);
        }
        if (self.input_source.hasReadyUnit()) {
            self.decision = try self.readInput();
        } else {
            self.decision = .wait_elapsed;
        }
        return .done;
    }

    fn runTimer(
        self: *PollWait,
        d: *dispatcher.Dispatcher,
        task: *dispatcher.DispatchTask,
        event: dispatcher.TimerEvent,
    ) !dispatch_io.DispatchTaskStatus {
        _ = d;
        _ = task;
        _ = event;
        if (self.input_source.hasReadyUnit()) return .done;
        if (self.diagnostic_source.isInitialized() and self.diagnostic_source.hasReadyUnit()) return .done;
        self.decision = .wait_elapsed;
        return .done;
    }

    fn readInput(self: *PollWait) !Decision {
        var filtered: [512]u8 = undefined;
        const read = self.input_source.readBytes() orelse return .wait_elapsed;
        const bytes = switch (read) {
            .bytes => |bytes| bytes,
            .eof => return .client_hangup,
        };

        switch (reconnect_control.scanInput(bytes)) {
            .reconnect_now => {
                self.state.reconnect_acknowledged = true;
                return .reconnect_now;
            },
            .none => {},
        }
        const result = self.state.escape_filter.filter(bytes, &filtered);
        if (result.end) |end| switch (end) {
            .disconnect => return .client_hangup,
            .help => {},
            .repaint => {},
        };
        if (bytes.len > 0) {
            self.state.input_during_disconnect = true;
            try self.state.alertDisconnectedInput(self.blocking, self.options.terminal_fds.output, self.options.now_ms);
        }
        return .wait_elapsed;
    }
};

pub const PollOptions = struct {
    terminal_fds: terminal.TerminalFds,
    diagnostic_notify_read_fd: c.fd_t,
    timeout_ms: i32,
    overlay_presentation: bool,
    now_ms: u64,
};

fn drainDiagnosticNotifierSource(source: dispatcher.Source) void {
    while (true) {
        if (!source.hasReadyUnit()) {
            switch (source.byte().readReady() catch return) {
                .blocked, .progress => return,
                .ready, .eof => {},
            }
        }
        switch (source.readBytes() orelse return) {
            .bytes => {},
            .eof => return,
        }
    }
}

test "reconnect input returns reconnect_now for ctrl-r" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);

    const output = try posix.pipe();
    defer posix.close(output[0]);
    defer posix.close(output[1]);

    try core_blocking.fromTest().writeAll(input[1], &.{reconnect_control.ctrl_r});
    try dispatcher.initGlobal(std.testing.allocator);
    defer dispatcher.deinitGlobal();

    var state = State{};
    try std.testing.expectEqual(
        Decision.reconnect_now,
        try state.poll(core_blocking.fromTest(), .{
            .terminal_fds = .{
                .input = input[0],
                .output = output[1],
            },
            .diagnostic_notify_read_fd = -1,
            .timeout_ms = 0,
            .overlay_presentation = false,
            .now_ms = 1_000,
        }),
    );
    try std.testing.expect(state.hasReconnectAcknowledgement());
}

test "reconnect input records ordinary input during disconnect" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);

    const output = try posix.pipe();
    defer posix.close(output[0]);
    defer posix.close(output[1]);

    try core_blocking.fromTest().writeAll(input[1], "x");
    try dispatcher.initGlobal(std.testing.allocator);
    defer dispatcher.deinitGlobal();

    var state = State{};
    try std.testing.expectEqual(
        Decision.wait_elapsed,
        try state.poll(core_blocking.fromTest(), .{
            .terminal_fds = .{
                .input = input[0],
                .output = output[1],
            },
            .diagnostic_notify_read_fd = -1,
            .timeout_ms = 0,
            .overlay_presentation = false,
            .now_ms = 1_000,
        }),
    );
    try std.testing.expect(state.input_during_disconnect);

    var buf: [8]u8 = undefined;
    const n = try posix.read(output[0], &buf);
    try std.testing.expectEqualStrings("\x07", buf[0..n]);
}
