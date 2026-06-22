// Dispatcher-owned relay for two framed sessh fds. The relay decodes whole
// frames at each source and queues those frames into the opposite sink, so
// protobuf bytes, attached bytes, and SCM_RIGHTS markers cannot interleave.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const protocol = @import("../protocol/mod.zig");
const protocol_frame = @import("../protocol/frame.zig");
const test_helpers = if (builtin.is_test) @import("../protocol/test_helpers.zig") else struct {};

pub const InitialFrame = struct {
    message_type: protocol.MessageType,
    payload: []const u8,
};

const InitialWrites = struct {
    left_to_right: ?InitialFrame = null,
    right_to_left: ?InitialFrame = null,
};

const FrameRelayEndpoints = struct {
    left: c.fd_t,
    right: c.fd_t,
};

const FrameRelayRegistration = struct {
    allocator: std.mem.Allocator,
    dispatcher: *dispatcher.Dispatcher,
    endpoints: FrameRelayEndpoints,
    initial_writes: InitialWrites = .{},
};

const DispatcherFrameRelay = struct {
    allocator: std.mem.Allocator,
    endpoints: FrameRelayEndpoints,
    left_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    right_source: dispatcher.Source = dispatcher.Source.uninitialized(),
    left_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    right_sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),
    closing: bool = false,

    fn deinit(self: *DispatcherFrameRelay) void {
        self.task.deinit();
        self.left_source.deinit();
        self.right_source.deinit();
        self.left_sink.deinit();
        self.right_sink.deinit();
        if (self.endpoints.left >= 0) {
            _ = c.close(self.endpoints.left);
            self.endpoints.left = -1;
        }
        if (self.endpoints.right >= 0) {
            _ = c.close(self.endpoints.right);
            self.endpoints.right = -1;
        }
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn runTask(
        self: *DispatcherFrameRelay,
        _: *dispatcher.Dispatcher,
        _: *dispatcher.DispatchTask,
    ) !dispatch_io.DispatchTaskStatus {
        if (self.left_sink.takeWriteError() != null or self.right_sink.takeWriteError() != null) {
            self.deinit();
            return .done;
        }

        if (!self.closing) {
            try self.forwardReadyFrames(self.left_source, self.right_sink);
            if (!self.closing) try self.forwardReadyFrames(self.right_source, self.left_sink);
        }

        if (self.closing) {
            // EOF on one side can arrive after we have already queued a final
            // frame from that side, such as TerminalEmulatorItem.session_ended.
            // Keep the relay alive until those queued writes drain; otherwise
            // the surviving peer sees a closed socket instead of the final
            // protocol frame.
            if (self.left_sink.hasPendingWrite() or self.right_sink.hasPendingWrite()) return .pending;
            self.deinit();
            return .done;
        }
        return .pending;
    }

    fn forwardReadyFrames(
        self: *DispatcherFrameRelay,
        source: dispatcher.Source,
        sink: dispatcher.Sink,
    ) !void {
        while (true) {
            var frame = switch (source.readFrame() catch |err| switch (err) {
                error.TruncatedFrame => {
                    self.closing = true;
                    return;
                },
                else => return err,
            }) {
                .blocked => return,
                .eof => {
                    self.closing = true;
                    return;
                },
                .frame => |frame_value| frame_value,
            };
            defer frame.deinit(self.allocator);
            try sink.writeOwnedFrame(&frame);
        }
    }
};

pub fn registerFrameRelayWithInitialWrites(options: FrameRelayRegistration) !void {
    const allocator = options.allocator;
    const d = options.dispatcher;
    const endpoints = options.endpoints;

    try core_fds.setNonBlocking(endpoints.left);
    try core_fds.setNonBlocking(endpoints.right);

    const relay = try allocator.create(DispatcherFrameRelay);
    errdefer allocator.destroy(relay);
    relay.* = .{
        .allocator = allocator,
        .endpoints = endpoints,
    };
    errdefer relay.deinit();

    relay.left_source = try d.frameSource(endpoints.left);
    relay.right_source = try d.frameSource(endpoints.right);
    relay.left_sink = try d.frameSink(.{ .allocator = allocator, .fd = endpoints.left });
    relay.right_sink = try d.frameSink(.{ .allocator = allocator, .fd = endpoints.right });

    if (options.initial_writes.left_to_right) |initial| {
        try relay.right_sink.writeFrame(initial.message_type, initial.payload);
    }
    if (options.initial_writes.right_to_left) |initial| {
        try relay.left_sink.writeFrame(initial.message_type, initial.payload);
    }

    relay.task = dispatcher.dispatchTask(DispatcherFrameRelay, allocator, relay, DispatcherFrameRelay.runTask);
    relay.task.setSourceReadiness(.any);
    try relay.task.requireSource(relay.left_source);
    try relay.task.requireSource(relay.right_source);
    try relay.task.requireSink(relay.left_sink);
    try relay.task.requireSink(relay.right_sink);
    try relay.task.schedule(d);
}

test "dispatcher frame relay forwards attached-byte frames in both directions" {
    const left = try test_helpers.socketPairForTest();
    const right = try test_helpers.socketPairForTest();
    var left_external_open = true;
    var right_external_open = true;
    defer {
        if (left_external_open) _ = c.close(left[0]);
    }
    defer {
        if (right_external_open) _ = c.close(right[0]);
    }

    try core_fds.setNonBlocking(left[0]);
    try core_fds.setNonBlocking(right[0]);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try registerFrameRelayWithInitialWrites(.{
        .allocator = std.testing.allocator,
        .dispatcher = &d,
        .endpoints = .{ .left = left[1], .right = right[1] },
    });

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    try test_helpers.sendFrameWithAttachedKindAndBytesBlocking(left[0], .{
        .message_type = .client_daemon,
        .payload = payload,
        .attached_bytes = "left-to-right",
    });
    var first = try testing.readRelayedFrame(&d, right[0]);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, first.message_type);
    try std.testing.expectEqualStrings(payload, first.payload);
    try std.testing.expectEqualStrings("left-to-right", first.attached_bytes);

    try test_helpers.sendFrameWithAttachedKindAndBytesBlocking(right[0], .{
        .message_type = .client_daemon,
        .payload = payload,
        .attached_bytes = "right-to-left",
    });
    var second = try testing.readRelayedFrame(&d, left[0]);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, second.message_type);
    try std.testing.expectEqualStrings(payload, second.payload);
    try std.testing.expectEqualStrings("right-to-left", second.attached_bytes);

    _ = c.close(left[0]);
    left_external_open = false;
    _ = c.close(right[0]);
    right_external_open = false;
    var iterations: usize = 0;
    while (d.activeTaskCount() != 0 and iterations < 10) : (iterations += 1) {
        _ = try d.runOnce();
    }
    try std.testing.expectEqual(@as(usize, 0), d.activeTaskCount());
}

test "dispatcher frame relay drains initial left-to-right write through dispatcher" {
    const left = try test_helpers.socketPairForTest();
    const right = try test_helpers.socketPairForTest();
    var left_external_open = true;
    var right_external_open = true;
    defer {
        if (left_external_open) _ = c.close(left[0]);
    }
    defer {
        if (right_external_open) _ = c.close(right[0]);
    }

    try core_fds.setNonBlocking(left[0]);
    try core_fds.setNonBlocking(right[0]);

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try registerFrameRelayWithInitialWrites(.{
        .allocator = std.testing.allocator,
        .dispatcher = &d,
        .endpoints = .{ .left = left[1], .right = right[1] },
        .initial_writes = .{ .left_to_right = .{ .message_type = .client_daemon, .payload = payload } },
    });

    var initial = try testing.readRelayedFrame(&d, right[0]);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, initial.message_type);
    try std.testing.expectEqualStrings(payload, initial.payload);

    try test_helpers.sendFrameBlocking(left[0], .client_daemon, payload);
    var relayed = try testing.readRelayedFrame(&d, right[0]);
    defer relayed.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, relayed.message_type);
    try std.testing.expectEqualStrings(payload, relayed.payload);

    _ = c.close(left[0]);
    left_external_open = false;
    _ = c.close(right[0]);
    right_external_open = false;
    var iterations: usize = 0;
    while (d.activeTaskCount() != 0 and iterations < 10) : (iterations += 1) {
        _ = try d.runOnce();
    }
    try std.testing.expectEqual(@as(usize, 0), d.activeTaskCount());
}

test "dispatcher frame relay drains queued frame before closing after eof" {
    const left = try test_helpers.socketPairForTest();
    const right = try test_helpers.socketPairForTest();
    var left_external_open = true;
    var right_external_open = true;
    defer {
        if (left_external_open) _ = c.close(left[0]);
    }
    defer {
        if (right_external_open) _ = c.close(right[0]);
    }

    try core_fds.setNonBlocking(left[0]);
    try core_fds.setNonBlocking(right[0]);

    const payload = try protocol.encodeClientDaemonPayload(std.testing.allocator, .{ .log_request = .{} });
    defer std.testing.allocator.free(payload);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    try registerFrameRelayWithInitialWrites(.{
        .allocator = std.testing.allocator,
        .dispatcher = &d,
        .endpoints = .{ .left = left[1], .right = right[1] },
    });

    try test_helpers.sendFrameBlocking(right[0], .client_daemon, payload);
    _ = c.close(right[0]);
    right_external_open = false;

    var relayed = try testing.readRelayedFrame(&d, left[0]);
    defer relayed.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, relayed.message_type);
    try std.testing.expectEqualStrings(payload, relayed.payload);

    _ = c.close(left[0]);
    left_external_open = false;
    var iterations: usize = 0;
    while (d.activeTaskCount() != 0 and iterations < 10) : (iterations += 1) {
        _ = try d.runOnce();
    }
    try std.testing.expectEqual(@as(usize, 0), d.activeTaskCount());
}

const testing = if (builtin.is_test) struct {
    fn readRelayedFrame(d: *dispatcher.Dispatcher, fd: c.fd_t) !protocol.OwnedFrame {
        var reader = protocol_frame.FrameReader.init(std.testing.allocator);
        defer reader.deinit();
        var iterations: usize = 0;
        while (iterations < 100) : (iterations += 1) {
            while (true) {
                switch (try reader.readReady(fd)) {
                    .blocked => break,
                    .progress => continue,
                    .frame => |frame| return frame,
                    .eof => return error.UnexpectedEof,
                    .truncated_frame => return error.UnexpectedTruncatedFrame,
                }
            }
            _ = try d.runOnce();
        }
        return error.TimedOut;
    }
} else struct {};
