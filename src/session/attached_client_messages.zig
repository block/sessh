const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const attached_client_state = @import("attached_client_state.zig");
const input_ack = @import("input_ack.zig");
const protocol = @import("../protocol/mod.zig");
const repaint = @import("repaint.zig");
const terminal = @import("../tty/terminal.zig");

const WindowSize = terminal.WindowSize;
const input_chunk_bytes = 1024;

pub fn nonZeroViewportOffset(viewport_offset: i32) ?i32 {
    return if (viewport_offset == 0) null else viewport_offset;
}

pub fn maybeSendResize(
    socket_fd: c.fd_t,
    last_size: *WindowSize,
    scrollback_cursor: *const attached_client_state.ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *repaint.Pending,
) !void {
    const size = terminal.currentWindowSize();
    if (size.rows == last_size.rows and size.cols == last_size.cols) return;
    last_size.* = size;
    const resize_viewport_offset: i32 = if (viewport_offset.* == 0) 0 else -1;
    viewport_offset.* = resize_viewport_offset;
    sendResizeWithRepaint(socket_fd, size, scrollback_cursor, resize_viewport_offset, pending_repaint) catch |err| {
        pending_repaint.clear();
        return err;
    };
}

pub fn sendResize(socket_fd: c.fd_t, size: WindowSize) !void {
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .resize = .{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
    } });
}

pub fn sendResizeWithRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
    scrollback_cursor: *const attached_client_state.ScrollbackCursor,
    viewport_offset: i32,
    pending_repaint: *repaint.Pending,
) !void {
    const repaint_request_seq = pending_repaint.startResize();
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .resize = .{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
        .viewport_offset = nonZeroViewportOffset(viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
            .scrollback_cursor = scrollback_cursor.slice(),
        },
    } });
}

pub fn sendResizeScreenRepaint(
    socket_fd: c.fd_t,
    size: WindowSize,
    viewport_offset: i32,
    pending_repaint: *repaint.Pending,
) !void {
    const repaint_request_seq = pending_repaint.start();
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .resize = .{
        .terminal_rows = size.rows,
        .terminal_cols = size.cols,
        .viewport_offset = nonZeroViewportOffset(viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
        },
    } });
}

pub fn sendRepaint(socket_fd: c.fd_t, scrollback_cursor: []const u8, pending_repaint: *repaint.Pending) !void {
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .repaint_request = .{
        .repaint_request_seq = pending_repaint.start(),
        .scrollback_cursor = scrollback_cursor,
    } });
}

pub fn sendScreenRepaint(socket_fd: c.fd_t, pending_repaint: *repaint.Pending) !void {
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .repaint_request = .{
        .repaint_request_seq = pending_repaint.start(),
    } });
}

pub fn sendInput(socket_fd: c.fd_t, bytes: []const u8, input_ack_tracker: *input_ack.Tracker, paste_like: bool) !void {
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), socket_fd, .{ .input = .{
        .data = bytes,
        .input_seq = input_ack_tracker.allocate(paste_like),
    } });
}

pub fn sendInputChunks(socket_fd: c.fd_t, bytes: []const u8, input_ack_tracker: *input_ack.Tracker, paste_like: bool) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + input_chunk_bytes, bytes.len);
        try sendInput(socket_fd, bytes[offset..end], input_ack_tracker, paste_like);
        offset = end;
    }
}
