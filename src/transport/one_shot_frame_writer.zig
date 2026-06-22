const std = @import("std");
const c = std.c;

const dispatcher = @import("../core/dispatcher.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
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
    try core_fds.setNonBlocking(options.fd);
    const context = try options.allocator.create(OneShotFrameWriter);
    errdefer options.allocator.destroy(context);
    var sink = try options.daemon_dispatcher.frameSink(.{
        .allocator = options.allocator,
        .fd = options.fd,
    });
    errdefer sink.deinit();
    try sink.writeFrame(options.message_type, options.payload);
    context.* = .{
        .allocator = options.allocator,
        .fd = options.fd,
        .sink = sink,
        .task = undefined,
    };
    sink = dispatcher.Sink.uninitialized();

    errdefer context.sink.deinit();
    context.task = dispatcher.dispatchTask(
        OneShotFrameWriter,
        options.allocator,
        context,
        OneShotFrameWriter.flush,
    );
    errdefer context.task.deinit();
    context.task.setSourceReadiness(.any);
    try context.task.requireSink(context.sink);
    try context.task.schedule(options.daemon_dispatcher);
}

/// Owns one fd long enough to flush one framed setup response from the process
/// dispatcher. Use this for short-lived setup sockets before the fd can be
/// handed to a richer relay/endpoint owner.
const OneShotFrameWriter = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    sink: dispatcher.Sink,
    task: dispatcher.DispatchTask,

    fn close(self: *OneShotFrameWriter) void {
        self.task.deinit();
        self.sink.deinit();
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn flush(
        self: *OneShotFrameWriter,
        d: *dispatcher.Dispatcher,
        task: *dispatcher.DispatchTask,
    ) !dispatch_io.DispatchTaskStatus {
        _ = d;
        _ = task;
        // Keep ownership of the fd until the encoded frame is completely
        // flushed. Sink write errors are surfaced by the dispatcher; this
        // callback only observes successful drain and then closes the setup fd.
        if (self.sink.takeWriteError()) |_| {
            self.close();
            return .done;
        }
        if (self.sink.hasPendingWrite()) {
            return .pending;
        }
        self.close();
        return .done;
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
