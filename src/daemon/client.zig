// Client-side helpers for finding, starting, connecting to, and subscribing to
// the local sesshd instance. This is foreground setup code; the daemon's own
// accept loop and request routing live in daemon/mod and daemon/client_router.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const protocol = @import("../protocol/mod.zig");
const daemon_executable = @import("executable.zig");
const daemon_handshake = @import("handshake.zig");
const socket_namespace = @import("socket_namespace.zig");
const daemon_startup = @import("startup.zig");
const socket_transport = @import("../transport/socket.zig");

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return socketPathForDirName(allocator, dir_name);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return socket_namespace.socketPath(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return connectForDirName(allocator, dir_name);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    var fd = core_fds.OwnedFd.init(try connectOrStart(allocator, exe));
    defer fd.deinit();
}

pub fn ensureStartedForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !void {
    var fd = core_fds.OwnedFd.init(try connectOrStartForDirName(allocator, exe, dir_name));
    defer fd.deinit();
}

pub fn connectOrStart(allocator: std.mem.Allocator, exe: []const u8) !c.fd_t {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    return connectOrStartForDirName(allocator, exe, dir_name);
}

// Foreground startup path shared by sessh, sesshd reexec helpers, and proxy
// roles. It owns the daemon startup lock/ready-pipe choreography so daemon
// daemon client code does not duplicate client-side spawn behavior.
pub fn connectOrStartForDirName(allocator: std.mem.Allocator, exe: []const u8, dir_name: []const u8) !c.fd_t {
    if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}

    var startup_lock = (try daemon_startup.tryAcquireStartupLock(allocator, dir_name)) orelse {
        try daemon_startup.waitForStartupLockRelease(allocator, dir_name);
        return connectAndHandshakeForDirName(allocator, dir_name);
    };
    defer startup_lock.deinit();

    if (connectAndHandshakeForDirName(allocator, dir_name)) |fd| return fd else |_| {}

    var pipe = try daemon_startup.ReadyPipe.init();
    defer pipe.deinit();
    if (!try spawnDaemonIfNamespaceUnlocked(.{
        .allocator = allocator,
        .exe = exe,
        .dir_name = dir_name,
        .ready_pipe = &pipe,
        .startup_lock = &startup_lock,
    })) {
        return error.DaemonDidNotStart;
    }
    pipe.closeWrite();
    switch (try daemon_startup.waitForReady(&pipe)) {
        .ready => return connectAndHandshakeForDirName(allocator, dir_name),
        .closed, .timed_out => return error.DaemonDidNotStart,
    }
}

const DaemonSpawnOptions = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    dir_name: []const u8,
    ready_pipe: *daemon_startup.ReadyPipe,
    startup_lock: *daemon_startup.StartupLock,
};

fn spawnDaemonIfNamespaceUnlocked(options: DaemonSpawnOptions) !bool {
    // Only the process holding the namespace startup lock may create/update the
    // role symlinks and spawn sesshd. Contenders wait for the ready pipe instead
    // of starting a second daemon for the same socket namespace.
    const allocator = options.allocator;
    const exe = options.exe;
    const dir_name = options.dir_name;
    var namespace_executables = (try daemon_executable.installNamespaceExecutablesForDaemonStart(allocator, exe, dir_name)) orelse return false;
    defer namespace_executables.deinit();
    const argv = [_][]const u8{ namespace_executables.daemon, dir_name };
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try daemon_startup.addReadyFdToEnvMap(allocator, &env_map, options.ready_pipe.write_fd);
    try daemon_startup.addStartupLockFdToEnvMap(allocator, &env_map, options.startup_lock.file.handle);
    try socket_transport.clearCloseOnExec(options.startup_lock.file.handle);
    var daemon_process = std.process.Child.init(&argv, allocator);
    daemon_process.stdin_behavior = .Ignore;
    daemon_process.stdout_behavior = .Ignore;
    daemon_process.stderr_behavior = .Ignore;
    daemon_process.env_map = &env_map;
    daemon_process.pgid = 0;
    try daemon_process.spawn();
    return true;
}

pub fn printDaemonLog(allocator: std.mem.Allocator, exe: []const u8) !void {
    const dir_name = try socket_namespace.selectedDirName(allocator);
    defer allocator.free(dir_name);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);

    const fd = try connectOrStartForDirName(allocator, exe, dir_name);
    defer _ = c.close(fd);
    try io.writeAll(posix.STDOUT_FILENO, "daemon socket ");
    try io.writeAll(posix.STDOUT_FILENO, path);
    try io.writeAll(posix.STDOUT_FILENO, "\n");

    var subscriber = try DaemonLogSubscriber.init(allocator, fd, posix.STDOUT_FILENO);
    defer subscriber.deinit();
    try subscriber.run();
}

fn daemonLogRequestWriter(allocator: std.mem.Allocator) !protocol.FrameWriteState {
    const payload = try protocol.encodeClientDaemonPayload(allocator, .{ .log_request = .{} });
    defer allocator.free(payload);
    return protocol.FrameWriteState.init(allocator, .client_daemon, payload);
}

const DaemonLogSubscriber = struct {
    allocator: std.mem.Allocator,
    dispatcher: dispatcher.Dispatcher,
    daemon_fd: c.fd_t,
    output_fd: c.fd_t,
    reader: protocol.FrameReader,
    request_writer: ?protocol.FrameWriteState,
    watch_id: ?dispatcher.FdWatchId = null,
    err: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, daemon_fd: c.fd_t, output_fd: c.fd_t) !DaemonLogSubscriber {
        var request_writer = try daemonLogRequestWriter(allocator);
        errdefer request_writer.deinit();
        return .{
            .allocator = allocator,
            // PROCESS_EVENT_LOOP: `sessh --daemon-log` is a foreground
            // subscriber. This Dispatcher owns only its daemon socket and
            // stdout writes; it is not the long-lived sesshd dispatcher.
            .dispatcher = try dispatcher.Dispatcher.init(allocator),
            .daemon_fd = daemon_fd,
            .output_fd = output_fd,
            .reader = protocol.FrameReader.init(allocator),
            .request_writer = request_writer,
        };
    }

    fn deinit(self: *DaemonLogSubscriber) void {
        if (self.request_writer) |*writer| writer.deinit();
        self.dispatcher.deinit();
        self.reader.deinit();
        self.* = undefined;
    }

    fn run(self: *DaemonLogSubscriber) !void {
        self.watch_id = try self.dispatcher.watchFd(.{
            .fd = self.daemon_fd,
            .events = .{ .writable = true },
            .handler = .{
                .ctx = self,
                .callback = handleDaemonLogEvent,
            },
        });
        try self.dispatcher.run();
        if (self.err) |err| return err;
    }

    fn stop(self: *DaemonLogSubscriber, err: ?anyerror) void {
        self.err = err;
        self.dispatcher.stop();
    }

    fn handleFrame(self: *DaemonLogSubscriber, frame: *const protocol.OwnedFrame) !void {
        switch (frame.message_type) {
            .client_daemon => {
                var entry = try protocol.decodeClientDaemonLogEntry(self.allocator, frame.payload);
                defer entry.deinit(self.allocator);
                const line = try daemonLogLine(self.allocator, entry.unix_ms, entry.message);
                defer self.allocator.free(line);
                try io.writeAll(self.output_fd, line);
            },
            else => return error.UnexpectedDaemonFrame,
        }
    }
};

fn finishDaemonLogRequest(subscriber: *DaemonLogSubscriber, event_dispatcher: *dispatcher.Dispatcher) !void {
    if (subscriber.request_writer) |*writer| {
        writer.deinit();
        subscriber.request_writer = null;
    }
    const watch_id = subscriber.watch_id orelse return;
    try event_dispatcher.updateFdEvents(watch_id, .{ .readable = true });
}

fn writeDaemonLogRequest(
    subscriber: *DaemonLogSubscriber,
    event_dispatcher: *dispatcher.Dispatcher,
    fd_event: dispatcher.FdEvent,
) !bool {
    const writer = if (subscriber.request_writer) |*writer| writer else return false;
    if (!fd_event.writable) return true;
    switch (try writer.writeReady(subscriber.daemon_fd)) {
        .blocked, .progress => return true,
        .done => {
            try finishDaemonLogRequest(subscriber, event_dispatcher);
            return false;
        },
    }
}

fn handleDaemonLogEvent(
    ctx: *anyopaque,
    handler_event: dispatcher.HandlerEvent,
) !void {
    // `sessh --daemon-log` first writes a subscription request, then switches
    // the same socket to a read-only stream of log frames. Keeping both phases
    // in one watch avoids a helper thread just to tail daemon output.
    const event_dispatcher = handler_event.dispatcher;
    const id = handler_event.id;
    const event = handler_event.event;
    const subscriber: *DaemonLogSubscriber = @ptrCast(@alignCast(ctx));
    const watch_id = subscriber.watch_id orelse return;
    switch (id) {
        .fd => |fd_id| if (fd_id.index != watch_id.index or fd_id.generation != watch_id.generation) return,
        .timer => return,
    }

    const fd_event = switch (event) {
        .fd => |fd| fd,
        .timer => return,
    };
    if (fd_event.error_event or fd_event.invalid) {
        subscriber.stop(error.DaemonTransportClosed);
        return;
    }
    if (subscriber.request_writer != null and try writeDaemonLogRequest(subscriber, event_dispatcher, fd_event)) {
        if (fd_event.hangup) subscriber.stop(null);
        return;
    }
    if (!fd_event.readable) {
        if (fd_event.hangup) subscriber.stop(null);
        return;
    }
    while (true) {
        switch (try subscriber.reader.readReady(subscriber.daemon_fd)) {
            .blocked, .progress => {
                if (fd_event.hangup) subscriber.stop(null);
                return;
            },
            .frame => |frame| {
                var owned_frame = frame;
                defer owned_frame.deinit(subscriber.allocator);
                subscriber.handleFrame(&owned_frame) catch |err| {
                    subscriber.stop(err);
                    return;
                };
            },
            .eof => {
                subscriber.stop(null);
                return;
            },
            .truncated_frame => {
                subscriber.stop(error.TruncatedFrame);
                return;
            },
        }
    }
}

fn daemonLogLine(allocator: std.mem.Allocator, unix_ms: i64, message: []const u8) ![]u8 {
    var timestamp_buf: [daemon_log_timestamp_len]u8 = undefined;
    if (formatDaemonLogTimestamp(&timestamp_buf, unix_ms)) |timestamp| {
        return std.fmt.allocPrint(allocator, "{s} {s}\n", .{ timestamp, message });
    } else |_| {
        return std.fmt.allocPrint(allocator, "{} {s}\n", .{ unix_ms, message });
    }
}

const daemon_log_timestamp_len = "00:00:00.000".len;

const LocalTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};

extern "c" fn localtime_r(timer: *const c.time_t, result: *LocalTm) ?*LocalTm;

fn formatDaemonLogTimestamp(buf: *[daemon_log_timestamp_len]u8, unix_ms: i64) ![]const u8 {
    const seconds_i64 = @divFloor(unix_ms, 1000);
    const milliseconds_i64 = @mod(unix_ms, 1000);
    const seconds = std.math.cast(c.time_t, seconds_i64) orelse return error.TimestampOutOfRange;
    const milliseconds = std.math.cast(u16, milliseconds_i64) orelse return error.TimestampOutOfRange;

    var local_time: LocalTm = undefined;
    if (localtime_r(&seconds, &local_time) == null) return error.TimestampOutOfRange;
    return formatDaemonLogTimestampParts(buf, local_time, milliseconds);
}

fn formatDaemonLogTimestampParts(buf: *[daemon_log_timestamp_len]u8, local_time: LocalTm, milliseconds: u16) ![]const u8 {
    const hour = std.math.cast(u8, local_time.tm_hour) orelse return error.InvalidLocalTime;
    const minute = std.math.cast(u8, local_time.tm_min) orelse return error.InvalidLocalTime;
    const second = std.math.cast(u8, local_time.tm_sec) orelse return error.InvalidLocalTime;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        hour,
        minute,
        second,
        milliseconds,
    });
}

test "daemon log timestamp uses readable milliseconds" {
    var local_time = std.mem.zeroes(LocalTm);
    local_time.tm_hour = 3;
    local_time.tm_min = 4;
    local_time.tm_sec = 5;
    var buf: [daemon_log_timestamp_len]u8 = undefined;
    const text = try formatDaemonLogTimestampParts(&buf, local_time, 7);
    try std.testing.expectEqualStrings("03:04:05.007", text);
}

test "daemon log subscriber reads frames with dispatcher" {
    const protocol_test_helpers = @import("../protocol/test_helpers.zig");
    const allocator = std.testing.allocator;
    var daemon_pair: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &daemon_pair) != 0) return error.SocketPairFailed;
    var daemon_fd_open = true;
    defer {
        if (daemon_fd_open) _ = c.close(daemon_pair[0]);
    }
    const output_pipe = try posix.pipe();
    defer _ = c.close(output_pipe[0]);
    var output_write_open = true;
    defer {
        if (output_write_open) _ = c.close(output_pipe[1]);
    }

    const TestPeer = struct {
        fd: c.fd_t,
        err: ?anyerror = null,

        fn run(peer: *@This()) void {
            peer.runInner() catch |err| {
                peer.err = err;
            };
        }

        fn runInner(peer: *@This()) !void {
            // Test peer for daemon-log subscription: assert the foreground
            // client sends the subscription request, then deliver one daemon log
            // entry through the same framed socket.
            defer _ = c.close(peer.fd);
            var request = protocol_test_helpers.readFrameForTest(std.testing.allocator, peer.fd) catch |err| switch (err) {
                error.EndOfStream => return error.MissingDaemonLogRequest,
                else => return err,
            };
            defer request.deinit(std.testing.allocator);
            if (request.message_type != .client_daemon) return error.UnexpectedDaemonFrame;
            var item = try protocol.decodePayload(protocol.pb.ClientDaemonItem, std.testing.allocator, request.payload);
            defer item.deinit(std.testing.allocator);
            switch (item.payload orelse return error.MissingClientDaemonPayload) {
                .log_request => {},
                else => return error.UnexpectedClientDaemonPayload,
            }

            try protocol_test_helpers.sendClientDaemonPayloadFrameBlocking(std.testing.allocator, peer.fd, .{
                .log_entry = .{
                    .unix_ms = 0,
                    .message = "dispatcher log event",
                },
            });
        }
    };

    var peer = TestPeer{ .fd = daemon_pair[1] };
    var peer_thread = try std.Thread.spawn(.{}, TestPeer.run, .{&peer});
    defer {
        if (daemon_fd_open) {
            _ = c.close(daemon_pair[0]);
            daemon_fd_open = false;
        }
        peer_thread.join();
    }

    var subscriber = try DaemonLogSubscriber.init(allocator, daemon_pair[0], output_pipe[1]);
    defer subscriber.deinit();
    try subscriber.run();
    if (peer.err) |err| return err;

    _ = c.close(output_pipe[1]);
    output_write_open = false;
    var buf: [256]u8 = undefined;
    const n = c.read(output_pipe[0], &buf, buf.len);
    if (n <= 0) return error.MissingDaemonLogOutput;
    const output = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, output, "dispatcher log event\n") != null);
}

pub fn connectForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    return socket_transport.connectSocket(path);
}

pub fn connectAndHandshakeForDirName(allocator: std.mem.Allocator, dir_name: []const u8) !c.fd_t {
    var fd = core_fds.OwnedFd.init(try connectForDirName(allocator, dir_name));
    defer fd.deinit();
    try daemon_handshake.initiateForegroundClientHandshake(allocator, fd.get());
    return fd.take();
}
