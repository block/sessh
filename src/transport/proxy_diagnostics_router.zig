// Local-daemon rendezvous for process-isolated proxy diagnostics. It pairs the
// visible client's diagnostics/control connection with the long-lived
// `sessh-proxy` byte-stream process for the same proxy GUID.
const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const protocol = @import("../protocol/mod.zig");
const guid_ref = @import("../core/guid.zig");
const pb = protocol.pb;

const Registration = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    visible: ?*VisibleConnection = null,
    stream_fd: c.fd_t = -1,
    stream_sink: ?StreamSink = null,

    fn deinit(self: *Registration) void {
        self.allocator.free(self.guid);
        self.* = undefined;
    }
};

pub const StreamSink = struct {
    ctx: *anyopaque,
    writeFrame: *const fn (*anyopaque, *dispatcher.Dispatcher, protocol.OwnedFrame) anyerror!void,
};

// PROCESS_GLOBAL_REGISTRY: process-isolated proxy mode keeps a long-lived
// `sessh-proxy` process between OpenSSH and the daemon, so the visible client
// cannot share the raw byte fd. This local-daemon registry is the rendezvous
// between that proxy byte-stream process and the visible client's
// diagnostics/retry connection, keyed by the proxy GUID generated for that
// invocation. It is intentionally process-global while there is exactly one
// dispatcher-owned daemon per process; tests that touch it must clear it.
var registrations: std.ArrayList(*Registration) = .empty;

pub const RegisterOpenFromDaemonOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
    open: pb.ClientDaemonItem.ProxyDiagnosticsOpen,
};

pub fn registerOpenFromDaemon(options: RegisterOpenFromDaemonOptions) !void {
    // Register the visible diagnostics side channel for one proxy guid. Later
    // proxy-stream connection events are routed through this socket without
    // involving the raw proxy byte stream.
    const allocator = options.allocator;
    const fd = options.fd;
    const context = try allocator.create(VisibleConnection);
    errdefer allocator.destroy(context);
    const guid = try guid_ref.canonicalProxyGuid(allocator, options.open.proxy_guid);
    errdefer allocator.free(guid);
    try registerVisible(allocator, guid, context);
    errdefer unregisterVisible(fd);
    try core_fds.setNonBlocking(fd);
    context.* = .{
        .allocator = allocator,
        .fd = fd,
        .guid = guid,
    };
    context.source = try options.daemon_dispatcher.frameSource(fd);
    errdefer context.source.deinit();
    context.sink = try options.daemon_dispatcher.frameSink(.{ .allocator = allocator, .fd = fd });
    errdefer context.sink.deinit();
    context.task = dispatcher.dispatchTask(
        VisibleConnection,
        allocator,
        context,
        readVisibleConnection,
    );
    try context.task.requireSource(context.source);
    try context.task.requireSink(context.sink);
    try context.task.schedule(options.daemon_dispatcher);
}

const VisibleConnection = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t = -1,
    guid: []u8,
    source: dispatcher.Source = dispatcher.Source.uninitialized(),
    sink: dispatcher.Sink = dispatcher.Sink.uninitialized(),
    task: dispatcher.DispatchTask = dispatcher.DispatchTask.uninitialized(),

    fn deinit(self: *VisibleConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        _ = daemon_dispatcher;
        self.task.deinit();
        self.source.deinit();
        self.sink.deinit();
        if (self.fd >= 0) {
            unregisterVisible(self.fd);
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.allocator.free(self.guid);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn readVisibleConnection(
    connection: *VisibleConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    _: *dispatcher.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    readVisibleConnectionInner(connection, daemon_dispatcher) catch {
        connection.deinit(daemon_dispatcher);
        return .done;
    };
    return .pending;
}

fn readVisibleConnectionInner(
    connection: *VisibleConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
) !void {
    // Diagnostics clients are optional side channels for visible proxy UI. They
    // receive connection events from the daemon but must never be allowed to
    // block the daemon's pooled SSH transport or proxy streams.
    while (true) {
        switch (try connection.source.readFrame()) {
            .blocked => return,
            .eof => {
                connection.deinit(daemon_dispatcher);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (!try visibleFrameIsAllowed(connection.allocator, frame)) return error.UnexpectedProxyDiagnosticsFrame;
                try forwardToStream(daemon_dispatcher, connection.guid, frame);
            },
        }
    }
}

fn registerVisible(allocator: std.mem.Allocator, guid: []const u8, connection: *VisibleConnection) !void {
    const registration = try findOrCreateRegistration(allocator, guid);
    if (registration.visible != null and registration.visible != connection) return error.ProxyDiagnosticsAlreadyOpen;
    registration.visible = connection;
}

pub const RegisterStreamOptions = struct {
    allocator: std.mem.Allocator,
    guid: []const u8,
    fd: c.fd_t,
    sink: StreamSink,
};

pub fn registerStream(options: RegisterStreamOptions) !void {
    const registration = try findOrCreateRegistration(options.allocator, options.guid);
    registration.stream_fd = options.fd;
    registration.stream_sink = options.sink;
}

fn unregisterVisible(fd: c.fd_t) void {
    for (registrations.items) |registration| {
        if (registration.visible) |visible| {
            if (visible.fd == fd) registration.visible = null;
        }
    }
    removeUnusedRegistrations();
}

pub fn unregisterStream(fd: c.fd_t) void {
    for (registrations.items) |registration| {
        if (registration.stream_fd == fd) {
            registration.stream_fd = -1;
            registration.stream_sink = null;
        }
    }
    removeUnusedRegistrations();
}

fn findOrCreateRegistration(allocator: std.mem.Allocator, guid: []const u8) !*Registration {
    for (registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid)) return registration;
    }
    const registration = try allocator.create(Registration);
    errdefer allocator.destroy(registration);
    registration.* = .{
        .allocator = allocator,
        .guid = try allocator.dupe(u8, guid),
    };
    errdefer registration.deinit();
    try registrations.append(allocator, registration);
    return registration;
}

fn removeUnusedRegistrations() void {
    var index: usize = 0;
    while (index < registrations.items.len) {
        const registration = registrations.items[index];
        if (registration.visible != null or registration.stream_fd >= 0) {
            index += 1;
            continue;
        }
        _ = registrations.swapRemove(index);
        const allocator = registration.allocator;
        registration.deinit();
        allocator.destroy(registration);
    }
}

fn visibleFrameIsAllowed(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !bool {
    if (frame.message_type != .client_daemon) return false;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    return switch (item.payload orelse return false) {
        .retry_now => true,
        else => false,
    };
}

fn forwardToStream(daemon_dispatcher: *dispatcher.Dispatcher, guid: []const u8, frame: protocol.OwnedFrame) !void {
    const registration = streamRegistration(guid) orelse return;
    const sink = registration.stream_sink orelse return;
    sink.writeFrame(sink.ctx, daemon_dispatcher, frame) catch |err| {
        unregisterStream(registration.stream_fd);
        return err;
    };
}

pub const ForwardFromStreamOptions = struct {
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    guid: []const u8,
    frame: protocol.OwnedFrame,
};

pub fn forwardFromStream(options: ForwardFromStreamOptions) !void {
    const allocator = options.allocator;
    const frame = options.frame;
    const guid = options.guid;
    if (!try streamFrameIsAllowed(allocator, frame)) return error.UnexpectedProxyDiagnosticsFrame;
    const visible = visibleConnection(guid) orelse return;
    visible.sink.writeFrame(frame.message_type, frame.payload) catch |err| {
        unregisterVisible(visible.fd);
        return err;
    };
}

fn streamFrameIsAllowed(allocator: std.mem.Allocator, frame: protocol.OwnedFrame) !bool {
    if (frame.message_type != .client_daemon) return false;
    var item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, frame.payload);
    defer item.deinit(allocator);
    return switch (item.payload orelse return false) {
        .connection_event => true,
        else => false,
    };
}

fn visibleConnection(guid: []const u8) ?*VisibleConnection {
    for (registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid)) {
            if (registration.visible) |visible| return visible;
        }
    }
    return null;
}

fn streamRegistration(guid: []const u8) ?*Registration {
    for (registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.stream_fd >= 0) return registration;
    }
    return null;
}

test "routes diagnostics and retry by proxy guid" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const TestSink = struct {
        fd: c.fd_t,
        writer: dispatch_io.FrameSink,

        fn writeFrame(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, frame: protocol.OwnedFrame) !void {
            _ = daemon_dispatcher;
            const sink: *@This() = @ptrCast(@alignCast(ctx));
            try sink.writer.writeFrame(frame.message_type, frame.payload);
            _ = try sink.writer.writeReadyTo(sink.fd);
        }
    };

    const allocator = std.testing.allocator;
    const guid = "p-550e8400-e29b-41d4-a716-446655440000";
    var d = try dispatcher.Dispatcher.init(allocator);
    defer d.deinit();

    var visible: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &visible) != 0) return error.SocketPairFailed;
    defer _ = c.close(visible[1]);

    var stream: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &stream) != 0) return error.SocketPairFailed;
    defer _ = c.close(stream[0]);
    defer _ = c.close(stream[1]);

    defer {
        unregisterVisible(visible[0]);
        unregisterStream(stream[0]);
        registrations.deinit(allocator);
        registrations = .empty;
    }

    const visible_context = try allocator.create(VisibleConnection);
    const visible_guid = try allocator.dupe(u8, guid);
    visible_context.* = .{
        .allocator = allocator,
        .fd = visible[0],
        .guid = visible_guid,
        .frame_source = dispatch_io.FrameSource.init(allocator, visible[0]),
        .writer = dispatch_io.FrameSink.init(.{ .allocator = allocator, .fd = -1 }),
    };
    defer visible_context.deinit(null);
    try registerVisible(allocator, guid, visible_context);

    var stream_sink = TestSink{
        .fd = stream[0],
        .writer = dispatch_io.FrameSink.init(.{ .allocator = allocator, .fd = -1 }),
    };
    defer stream_sink.writer.deinit();
    try registerStream(.{
        .allocator = allocator,
        .guid = guid,
        .fd = stream[0],
        .sink = .{
            .ctx = &stream_sink,
            .writeFrame = TestSink.writeFrame,
        },
    });

    const stderr_payload = try protocol.encodeConnectionEventPayload(allocator, .{
        .ssh_stderr = .{ .data = "proxy stderr line" },
    });
    defer allocator.free(stderr_payload);
    try forwardFromStream(.{
        .allocator = allocator,
        .daemon_dispatcher = &d,
        .guid = guid,
        .frame = .{
            .message_type = .client_daemon,
            .payload = stderr_payload,
        },
    });
    _ = try visible_context.writer.writeReadyTo(visible[0]);

    var visible_frame = try protocol_test_helpers.readFrameForTest(allocator, visible[1]);
    defer visible_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, visible_frame.message_type);
    var visible_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, visible_frame.payload);
    defer visible_item.deinit(allocator);
    const event = switch (visible_item.payload orelse return error.MissingProxyDiagnosticsPayload) {
        .connection_event => |event| event,
        else => return error.UnexpectedProxyDiagnosticsFrame,
    };
    const stderr = switch (event.event orelse return error.MissingProxyDiagnosticsPayload) {
        .ssh_stderr => |stderr| stderr,
        else => return error.UnexpectedProxyDiagnosticsFrame,
    };
    try std.testing.expectEqualStrings("proxy stderr line", stderr.data);

    const retry_payload = try protocol.encodeClientDaemonPayload(allocator, .{ .retry_now = .{} });
    defer allocator.free(retry_payload);
    try forwardToStream(&d, guid, .{
        .message_type = .client_daemon,
        .payload = retry_payload,
    });

    var stream_frame = try protocol_test_helpers.readFrameForTest(allocator, stream[1]);
    defer stream_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, stream_frame.message_type);
    var stream_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, stream_frame.payload);
    defer stream_item.deinit(allocator);
    switch (stream_item.payload orelse return error.MissingProxyDiagnosticsPayload) {
        .retry_now => {},
        else => return error.UnexpectedProxyDiagnosticsFrame,
    }
}
