const std = @import("std");

const app_allocator = @import("../core/app_allocator.zig");
const config = @import("../core/config.zig");
const remote_process = @import("remote_process.zig");
const vt = @import("vt.zig");

pub const Session = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: usize = 0,
    process: remote_process.Process = .{},
    terminal_model: ?*vt.SessionTerminal = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    scrollback_epoch: u64 = 1,
    last_scrollback_clear_epoch: u64 = 1,
    end_reason: u8 = 0,
    attached: bool = false,
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
        return self.id[0..self.id_len];
    }

    pub fn clearPendingPlainOutput(self: *Session) void {
        self.pending_plain_output.clearRetainingCapacity();
        self.pending_plain_starts_at_boundary = false;
    }

    pub fn appendPendingPlainOutput(
        self: *Session,
        bytes: []const u8,
        starts_at_boundary: bool,
    ) !void {
        if (self.pending_plain_output.items.len == 0) {
            self.pending_plain_starts_at_boundary = starts_at_boundary;
        }
        try self.pending_plain_output.appendSlice(app_allocator.allocator(), bytes);
    }

    pub fn pendingPlainOutputCanReplay(self: *const Session) bool {
        return self.pending_plain_output.items.len > 0 and
            self.pending_plain_starts_at_boundary;
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
