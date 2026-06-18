const std = @import("std");
const c = std.c;
const posix = std.posix;

const io_helpers = @import("../core/io.zig");
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
        input_fd: c.fd_t,
        output_fd: c.fd_t,
        diagnostic_notify_read_fd: c.fd_t,
        timeout_ms: i32,
        overlay_presentation: bool,
        now_ms: u64,
    ) !Decision {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = input_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = diagnostic_notify_read_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const poll_count: usize = if (diagnostic_notify_read_fd >= 0) 2 else 1;
        const ready = try posix.poll(pollfds[0..poll_count], self.effectivePollTimeout(timeout_ms, overlay_presentation, now_ms));
        if (ready == 0) return .wait_elapsed;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .client_hangup;
        if (poll_count > 1 and (pollfds[1].revents & posix.POLL.IN) != 0) {
            drainDiagnosticNotifier(diagnostic_notify_read_fd);
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

        var input: [256]u8 = undefined;
        var filtered: [512]u8 = undefined;
        const n = c.read(input_fd, &input, input.len);
        if (n <= 0) return .client_hangup;
        io_helpers.noteRead(input_fd, input[0..@intCast(n)]);

        const bytes = input[0..@intCast(n)];
        switch (reconnect_control.scanInput(bytes, .{})) {
            .reconnect_now => {
                self.reconnect_acknowledged = true;
                return .reconnect_now;
            },
            .none => {},
        }
        const result = self.escape_filter.filter(bytes, &filtered);
        if (result.end) |end| switch (end) {
            .disconnect => return .client_hangup,
            .help => {},
            .repaint => {},
        };
        if (bytes.len > 0) {
            self.input_during_disconnect = true;
            try self.alertDisconnectedInput(output_fd, now_ms);
        }
        return .wait_elapsed;
    }

    pub fn refreshDisconnectedInputFlash(self: *State, output_fd: c.fd_t, now_ms: u64) !void {
        if (self.disconnected_input_flash_until_ms <= 0) return;
        if (now_ms < self.disconnected_input_flash_until_ms) return;
        try self.clearDisconnectedInputFlash(output_fd);
    }

    pub fn clearDisconnectedInputFlash(self: *State, output_fd: c.fd_t) !void {
        if (self.disconnected_input_flash_until_ms <= 0) return;
        self.disconnected_input_flash_until_ms = 0;
        if (c.isatty(output_fd) != 0) try io_helpers.writeAll(output_fd, "\x1b[?5l");
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

    fn alertDisconnectedInput(self: *State, output_fd: c.fd_t, now_ms: u64) !void {
        try io_helpers.writeAll(output_fd, "\x07");
        if (c.isatty(output_fd) == 0) return;
        if (self.disconnected_input_flash_until_ms <= 0) {
            try io_helpers.writeAll(output_fd, "\x1b[?5h");
        }
        self.disconnected_input_flash_until_ms = now_ms +| disconnected_input_flash_ms;
    }
};

pub fn drainDiagnosticNotifier(fd: c.fd_t) void {
    if (fd < 0) return;
    var buf: [128]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) continue;
        if (n == 0) return;
        switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return,
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

    try io_helpers.writeAll(input[1], &.{reconnect_control.ctrl_r});

    var state = State{};
    try std.testing.expectEqual(
        Decision.reconnect_now,
        try state.poll(input[0], output[1], -1, 0, false, 1_000),
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

    try io_helpers.writeAll(input[1], "x");

    var state = State{};
    try std.testing.expectEqual(
        Decision.wait_elapsed,
        try state.poll(input[0], output[1], -1, 0, false, 1_000),
    );
    try std.testing.expect(state.input_during_disconnect);

    var buf: [8]u8 = undefined;
    const n = try posix.read(output[0], &buf);
    try std.testing.expectEqualStrings("\x07", buf[0..n]);
}
