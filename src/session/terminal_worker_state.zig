const std = @import("std");
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const guid_ref = @import("../core/guid.zig");
const terminal = @import("../tty/terminal.zig");
const remote_process = @import("remote_process.zig");
const vt = @import("vt.zig");

const WindowSize = terminal.WindowSize;
const max_pty_input_queue_bytes = 16 * 1024 * 1024;

pub const Session = struct {
    id: guid_ref.FixedSessionGuid = .{},
    process: remote_process.Process = .{},
    terminal_model: ?*vt.SessionTerminal = null,
    size: WindowSize = .{},
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_epoch: u64 = 1,
    last_scrollback_clear_epoch: u64 = 1,
    end_reason: u8 = 0,
    visible_client_connected: bool = false,
    disconnected_at_unix_ms: u64 = 0,
    reap_ms: u64 = 0,
    alive: bool = false,
    pending_plain_output: std.ArrayList(u8) = .empty,
    pending_plain_starts_at_boundary: bool = false,
    pending_pty_input: std.ArrayList(u8) = .empty,
    pending_pty_input_offset: usize = 0,
    synchronized_output_since_ms: i64 = 0,
    pty_eof_wait_started_ms: i64 = 0,

    pub fn idSlice(self: *const Session) []const u8 {
        return self.id.slice();
    }

    pub fn setId(self: *Session, id: []const u8) !void {
        try self.id.set(id);
    }

    pub fn clearPendingPlainOutput(self: *Session) void {
        self.pending_plain_output.clearRetainingCapacity();
        self.pending_plain_starts_at_boundary = false;
    }

    pub const PendingPlainOutput = struct {
        bytes: []const u8,
        starts_at_boundary: bool,
    };

    pub fn appendPendingPlainOutput(self: *Session, output: PendingPlainOutput) !void {
        if (self.pending_plain_output.items.len == 0) {
            self.pending_plain_starts_at_boundary = output.starts_at_boundary;
        }
        try self.pending_plain_output.appendSlice(app_allocator.allocator(), output.bytes);
    }

    pub fn pendingPlainOutputCanReplay(self: *const Session) bool {
        return self.pending_plain_output.items.len > 0 and
            self.pending_plain_starts_at_boundary;
    }

    pub fn hasPendingPtyInput(self: *const Session) bool {
        return self.pending_pty_input_offset < self.pending_pty_input.items.len;
    }

    pub fn queuedPtyInputBytes(self: *const Session) usize {
        return self.pending_pty_input.items.len - self.pending_pty_input_offset;
    }

    fn compactPendingPtyInput(self: *Session) void {
        if (self.pending_pty_input_offset == 0) return;
        const remaining = self.pending_pty_input.items[self.pending_pty_input_offset..];
        @memmove(self.pending_pty_input.items[0..remaining.len], remaining);
        self.pending_pty_input.items.len = remaining.len;
        self.pending_pty_input_offset = 0;
    }

    pub fn queuePtyInput(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (!self.alive or !self.process.hasOpenPty()) return error.SessionPtyClosed;
        self.compactPendingPtyInput();
        if (bytes.len > max_pty_input_queue_bytes or
            self.pending_pty_input.items.len > max_pty_input_queue_bytes - bytes.len)
        {
            return error.SessionPtyInputQueueFull;
        }
        try self.pending_pty_input.appendSlice(app_allocator.allocator(), bytes);
        if (!self.flushPtyInput()) return error.SessionPtyInputWriteFailed;
    }

    pub fn flushPtyInput(self: *Session) bool {
        if (!self.alive or !self.process.hasOpenPty()) return true;
        while (self.hasPendingPtyInput()) {
            const remaining = self.pending_pty_input.items[self.pending_pty_input_offset..];
            switch (self.process.writeSomeInput(remaining) catch return false) {
                .would_block => return true,
                .wrote => |n| {
                    self.pending_pty_input_offset += n;
                    if (self.pending_pty_input_offset == self.pending_pty_input.items.len) {
                        self.pending_pty_input.clearRetainingCapacity();
                        self.pending_pty_input_offset = 0;
                        return true;
                    }
                },
            }
        }
        return true;
    }

    pub fn deinit(self: *Session) void {
        self.pending_plain_output.deinit(app_allocator.allocator());
        self.pending_plain_output = .empty;
        self.pending_plain_starts_at_boundary = false;
        self.pending_pty_input.deinit(app_allocator.allocator());
        self.pending_pty_input = .empty;
        self.pending_pty_input_offset = 0;
        self.synchronized_output_since_ms = 0;
        self.pty_eof_wait_started_ms = 0;
    }
};

test "session PTY input queue flushes through nonblocking writes" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try core_fds.setNonBlocking(pipe[1]);

    var session = Session{
        .process = .{ .pty_fd = pipe[1] },
        .alive = true,
    };
    defer session.deinit();

    try session.queuePtyInput("abc");
    try std.testing.expectEqual(@as(usize, 0), session.queuedPtyInputBytes());

    var out: [3]u8 = undefined;
    const n = try posix.read(pipe[0], &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", out[0..n]);
}
