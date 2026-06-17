const std = @import("std");
const c = std.c;

const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const session_registry = @import("../runtime/session_registry.zig");
const pb = protocol.pb;

const Registration = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    visible_fd: c.fd_t = -1,
    stream_fd: c.fd_t = -1,

    fn deinit(self: *Registration) void {
        self.allocator.free(self.guid);
        self.* = undefined;
    }
};

var registrations: std.ArrayList(*Registration) = .empty;

pub fn registerOpenFromDaemon(
    allocator: std.mem.Allocator,
    daemon_dispatcher: *dispatcher.Dispatcher,
    fd: c.fd_t,
    open: pb.ClientDaemonItem.ProxyControlOpen,
) !void {
    const context = try allocator.create(VisibleConnection);
    errdefer allocator.destroy(context);
    const guid = try session_registry.canonicalProxyGuid(allocator, open.proxy_guid);
    errdefer allocator.free(guid);
    try registerVisible(allocator, guid, fd);
    errdefer unregisterVisible(fd);
    try core_fds.setNonBlocking(fd);
    context.* = .{
        .allocator = allocator,
        .fd = fd,
        .guid = guid,
        .reader = protocol.FrameReader.init(allocator),
    };
    errdefer context.reader.deinit();
    context.watch_id = try daemon_dispatcher.watchFd(fd, .{ .readable = true }, .{
        .ctx = context,
        .callback = readVisibleConnection,
    });
}

const VisibleConnection = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t = -1,
    guid: []u8,
    reader: protocol.FrameReader,
    watch_id: ?dispatcher.FdWatchId = null,

    fn deinit(self: *VisibleConnection, daemon_dispatcher: ?*dispatcher.Dispatcher) void {
        if (daemon_dispatcher) |d| {
            if (self.watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
        }
        self.watch_id = null;
        if (self.fd >= 0) {
            unregisterVisible(self.fd);
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.reader.deinit();
        self.allocator.free(self.guid);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn readVisibleConnection(ctx: *anyopaque, daemon_dispatcher: *dispatcher.Dispatcher, id: dispatcher.WatchId, event: dispatcher.Event) !void {
    _ = id;
    const connection: *VisibleConnection = @ptrCast(@alignCast(ctx));
    readVisibleConnectionInner(connection, daemon_dispatcher, event) catch {
        connection.deinit(daemon_dispatcher);
    };
}

fn readVisibleConnectionInner(
    connection: *VisibleConnection,
    daemon_dispatcher: *dispatcher.Dispatcher,
    event: dispatcher.Event,
) !void {
    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return error.UnexpectedProxyControlTimer,
    };
    if (fd_event.error_event or fd_event.invalid) {
        connection.deinit(daemon_dispatcher);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) connection.deinit(daemon_dispatcher);
        return;
    }
    while (true) {
        switch (try connection.reader.readReady(connection.fd)) {
            .blocked => return,
            .progress => continue,
            .eof, .truncated_frame => {
                connection.deinit(daemon_dispatcher);
                return;
            },
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(connection.allocator);
                if (!try visibleFrameIsAllowed(connection.allocator, frame)) return error.UnexpectedProxyControlFrame;
                try forwardToStream(connection.guid, frame);
            },
        }
    }
}

fn registerVisible(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    const registration = try findOrCreateRegistration(allocator, guid);
    if (registration.visible_fd >= 0 and registration.visible_fd != fd) return error.ProxyControlAlreadyOpen;
    registration.visible_fd = fd;
}

pub fn registerStream(allocator: std.mem.Allocator, guid: []const u8, fd: c.fd_t) !void {
    const registration = try findOrCreateRegistration(allocator, guid);
    registration.stream_fd = fd;
}

fn unregisterVisible(fd: c.fd_t) void {
    for (registrations.items) |registration| {
        if (registration.visible_fd == fd) registration.visible_fd = -1;
    }
    removeUnusedRegistrations();
}

pub fn unregisterStream(fd: c.fd_t) void {
    for (registrations.items) |registration| {
        if (registration.stream_fd == fd) registration.stream_fd = -1;
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
        if (registration.visible_fd >= 0 or registration.stream_fd >= 0) {
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

fn forwardToStream(guid: []const u8, frame: protocol.OwnedFrame) !void {
    const stream_fd = streamFd(guid) orelse return;
    protocol.sendFrame(stream_fd, frame.message_type, frame.payload) catch |err| {
        unregisterStream(stream_fd);
        return err;
    };
}

pub fn forwardFromStream(allocator: std.mem.Allocator, guid: []const u8, frame: protocol.OwnedFrame) !void {
    if (!try streamFrameIsAllowed(allocator, frame)) return error.UnexpectedProxyControlFrame;
    const visible_fd = visibleFd(guid) orelse return;
    protocol.sendFrame(visible_fd, frame.message_type, frame.payload) catch |err| {
        unregisterVisible(visible_fd);
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

fn visibleFd(guid: []const u8) ?c.fd_t {
    for (registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.visible_fd >= 0) return registration.visible_fd;
    }
    return null;
}

fn streamFd(guid: []const u8) ?c.fd_t {
    for (registrations.items) |registration| {
        if (std.mem.eql(u8, registration.guid, guid) and registration.stream_fd >= 0) return registration.stream_fd;
    }
    return null;
}

test "routes diagnostics and retry by proxy guid" {
    const allocator = std.testing.allocator;
    const guid = "p-550e8400-e29b-41d4-a716-446655440000";

    var visible: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &visible) != 0) return error.SocketPairFailed;
    defer _ = c.close(visible[0]);
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

    try registerVisible(allocator, guid, visible[0]);
    try registerStream(allocator, guid, stream[0]);

    const stderr_payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{ .payload = .{
        .connection_event = .{ .event = .{ .ssh_stderr = .{ .data = "proxy stderr line" } } },
    } });
    defer allocator.free(stderr_payload);
    try forwardFromStream(allocator, guid, .{
        .message_type = .client_daemon,
        .payload = stderr_payload,
    });

    var visible_frame = try readFrameForTest(allocator, visible[1]);
    defer visible_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, visible_frame.message_type);
    var visible_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, visible_frame.payload);
    defer visible_item.deinit(allocator);
    const event = switch (visible_item.payload orelse return error.MissingProxyControlPayload) {
        .connection_event => |event| event,
        else => return error.UnexpectedProxyControlFrame,
    };
    const stderr = switch (event.event orelse return error.MissingProxyControlPayload) {
        .ssh_stderr => |stderr| stderr,
        else => return error.UnexpectedProxyControlFrame,
    };
    try std.testing.expectEqualStrings("proxy stderr line", stderr.data);

    const retry_payload = try protocol.encodePayload(allocator, pb.ClientDaemonItem{ .payload = .{
        .retry_now = .{},
    } });
    defer allocator.free(retry_payload);
    try forwardToStream(guid, .{
        .message_type = .client_daemon,
        .payload = retry_payload,
    });

    var stream_frame = try readFrameForTest(allocator, stream[1]);
    defer stream_frame.deinit(allocator);
    try std.testing.expectEqual(protocol.MessageType.client_daemon, stream_frame.message_type);
    var stream_item = try protocol.decodePayload(pb.ClientDaemonItem, allocator, stream_frame.payload);
    defer stream_item.deinit(allocator);
    switch (stream_item.payload orelse return error.MissingProxyControlPayload) {
        .retry_now => {},
        else => return error.UnexpectedProxyControlFrame,
    }
}

fn readFrameForTest(allocator: std.mem.Allocator, fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked, .progress => continue,
            .frame => |frame| return frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
}
