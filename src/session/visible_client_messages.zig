const std = @import("std");

const visible_client_state = @import("visible_client_state.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const protocol = @import("../protocol/mod.zig");
const terminal = @import("../tty/terminal.zig");

const pb = protocol.pb;
const WindowSize = terminal.WindowSize;
const VisibleClientSessionState = visible_client_state.VisibleClientSessionState;
const input_chunk_bytes = 1024;

pub const MaybeWriteResizeOptions = struct {
    writer: *dispatch_io.FrameSink,
    last_size: *WindowSize,
    session: *VisibleClientSessionState,
};

pub const QueueInputChunksOptions = struct {
    writer: *dispatch_io.FrameSink,
    bytes: []const u8,
    session: *VisibleClientSessionState,
    paste_like: bool,
};

pub fn nonZeroViewportOffset(viewport_offset: i32) ?i32 {
    return if (viewport_offset == 0) null else viewport_offset;
}

pub const ResizeMessageOptions = struct {
    size: WindowSize,
    viewport_offset: ?i32 = null,
    repaint_request: ?pb.TerminalEmulatorItem.RepaintRequest = null,
};

pub fn resizeMessage(options: ResizeMessageOptions) pb.TerminalEmulatorItem.Resize {
    return .{
        .terminal_rows = options.size.rows,
        .terminal_cols = options.size.cols,
        .viewport_offset = options.viewport_offset,
        .repaint_request = options.repaint_request,
    };
}

pub fn maybeWriteResize(options: MaybeWriteResizeOptions) !void {
    const size = terminal.currentWindowSize();
    if (size.eql(options.last_size.*)) return;
    options.last_size.* = size;
    const session = options.session;
    const resize_viewport_offset: i32 = if (session.viewport_offset == 0) 0 else -1;
    session.viewport_offset = resize_viewport_offset;
    writeResizeWithRepaint(options.writer, size, session) catch |err| {
        session.pending_repaint.clear();
        return err;
    };
}

fn writeResizeWithRepaint(
    writer: *dispatch_io.FrameSink,
    size: WindowSize,
    session: *VisibleClientSessionState,
) !void {
    const repaint_request_seq = session.pending_repaint.startResize();
    try writer.writeTerminalEmulatorPayload(.{ .resize = resizeMessage(.{
        .size = size,
        .viewport_offset = nonZeroViewportOffset(session.viewport_offset),
        .repaint_request = .{
            .repaint_request_seq = repaint_request_seq,
            .scrollback_cursor = session.scrollback_cursor.slice(),
        },
    }) });
}

pub fn writeScreenRepaint(
    writer: *dispatch_io.FrameSink,
    session: *VisibleClientSessionState,
) !void {
    try writer.writeTerminalEmulatorPayload(.{ .repaint_request = .{
        .repaint_request_seq = session.pending_repaint.start(),
    } });
}

fn writeInput(options: QueueInputChunksOptions) !void {
    try options.writer.writeTerminalEmulatorPayload(.{ .input = .{
        .data = options.bytes,
        .input_seq = options.session.input_ack_tracker.allocate(if (options.paste_like) .paste_like else .normal),
    } });
}

pub fn writeInputChunks(options: QueueInputChunksOptions) !void {
    var offset: usize = 0;
    while (offset < options.bytes.len) {
        const end = @min(offset + input_chunk_bytes, options.bytes.len);
        try writeInput(.{
            .writer = options.writer,
            .bytes = options.bytes[offset..end],
            .session = options.session,
            .paste_like = options.paste_like,
        });
        offset = end;
    }
}

test "resize message maps window size to terminal resize fields" {
    const message = resizeMessage(.{
        .size = .{ .rows = 33, .cols = 120 },
        .viewport_offset = 7,
        .repaint_request = .{ .repaint_request_seq = 42, .scrollback_cursor = "cursor" },
    });
    try std.testing.expectEqual(@as(u32, 33), message.terminal_rows);
    try std.testing.expectEqual(@as(u32, 120), message.terminal_cols);
    try std.testing.expectEqual(@as(?i32, 7), message.viewport_offset);
    try std.testing.expectEqual(@as(u64, 42), message.repaint_request.?.repaint_request_seq);
    try std.testing.expectEqualStrings("cursor", message.repaint_request.?.scrollback_cursor.?);
}
