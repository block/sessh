const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const protocol = @import("../protocol/mod.zig");

pub const RegisterOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
    message_type: protocol.MessageType,
    payload: []const u8,
};

pub fn registerFrameAndClose(options: RegisterOptions) !void {
    // Some setup paths need to send exactly one framed response and then give up
    // the fd. Register that write with the daemon dispatcher instead of blocking
    // the caller until the peer becomes writable.
    var writer = try protocol.FrameWriteState.init(options.allocator, options.message_type, options.payload);
    errdefer writer.deinit();

    try core_fds.setNonBlocking(options.fd);
    const context = try options.allocator.create(OneShotFrameWriter);
    errdefer options.allocator.destroy(context);
    context.* = .{
        .allocator = options.allocator,
        .fd = options.fd,
        .writer = writer,
    };
    writer = undefined;

    errdefer context.writer.deinit();
    _ = try options.daemon_dispatcher.watchFd(.{
        .fd = options.fd,
        .events = .{ .writable = true },
        .handler = .{
            .ctx = context,
            .callback = OneShotFrameWriter.onWritable,
        },
    });
}

/// Owns one fd long enough to flush one framed setup response from the process
/// dispatcher. Use this for short-lived setup sockets before the fd can be
/// handed to a richer relay/endpoint owner.
const OneShotFrameWriter = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    writer: protocol.FrameWriteState,

    fn close(self: *OneShotFrameWriter, d: *dispatcher.Dispatcher, id: dispatcher.WatchId) void {
        d.cancel(id);
        self.writer.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn onWritable(ctx: *anyopaque, handler_event: dispatcher.HandlerEvent) !void {
        // Keep ownership of the fd until the encoded frame is completely
        // flushed. Any peer close/error abandons the response and releases the
        // fd because there is no later state machine to recover it.
        const d = handler_event.dispatcher;
        const id = handler_event.id;
        const event = handler_event.event;
        const self: *OneShotFrameWriter = @ptrCast(@alignCast(ctx));
        const fd_event = switch (event) {
            .fd => |fd| fd,
            .timer => return error.UnexpectedOneShotFrameWriterTimer,
        };
        if (fd_event.error_event or fd_event.invalid or fd_event.hangup) {
            self.close(d, id);
            return;
        }
        if (!fd_event.writable) return;
        switch (self.writer.writeReady(self.fd) catch {
            self.close(d, id);
            return;
        }) {
            .blocked, .progress => {},
            .done => self.close(d, id),
        }
    }
};

test "one-shot frame writer flushes frame and closes fd" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const pipe = try std.posix.pipe();
    defer {
        _ = c.close(pipe[0]);
    }

    const payload = try protocol.encodeErrorPayload(std.testing.allocator, .{
        .code = "PROTOCOL_ERROR",
        .message = "bad request",
    });
    defer std.testing.allocator.free(payload);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try registerFrameAndClose(.{
        .allocator = std.testing.allocator,
        .daemon_dispatcher = &d,
        .fd = pipe[1],
        .message_type = .error_message,
        .payload = payload,
    });
    _ = try d.loopForBlocking();

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, pipe[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.error_message, frame.message_type);
}
