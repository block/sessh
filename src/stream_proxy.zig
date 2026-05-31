const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");
const protocol = @import("protocol.zig");
const client_log = @import("client_log.zig");
const reconnect = @import("reconnect.zig");
const reconnect_title = @import("reconnect_title.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const pb = protocol.pb;

const max_buffered_bytes = 1024 * 1024;
const max_chunk_bytes = 16 * 1024;
const stream_ping_interval_ms: u64 = 1_000;
const stream_unresponsive_after_ms: u64 = 10_000;

const StreamOutcome = union(enum) {
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

pub const ClientStreamOptions = struct {
    status_enabled: bool = false,
    title_status_path: ?[]const u8 = null,
};

// Tracks byte offsets for one side of the reconnectable stream. `outbound`
// holds bytes already read from the local source but not yet acknowledged by
// the peer, which is what lets a replacement ssh transport resume without
// dropping or replaying bytes.
const StreamState = struct {
    allocator: std.mem.Allocator,
    outbound: std.ArrayList(u8) = .empty,
    outbound_base: u64 = 0,
    recv_next_offset: u64 = 0,
    peer_recv: u64 = 0,
    // Highest outbound offset already written to the currently attached
    // transport. This is intentionally separate from peer_recv: ACKs decide
    // what can be dropped, while this prevents overlapping sends before an ACK
    // has had time to come back.
    outbound_sent_next: u64 = 0,
    peer_ready: bool = false,
    outbound_eof: bool = false,
    outbound_eof_sent: bool = false,
    outbound_eof_acked: bool = false,
    inbound_eof: bool = false,

    fn init(allocator: std.mem.Allocator) StreamState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StreamState) void {
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    fn outboundNext(self: *const StreamState) u64 {
        return self.outbound_base + self.outbound.items.len;
    }

    fn bufferedBytes(self: *const StreamState) usize {
        return self.outbound.items.len;
    }

    fn appendOutbound(self: *StreamState, bytes: []const u8) !void {
        try self.outbound.appendSlice(self.allocator, bytes);
    }

    fn dropOutboundThrough(self: *StreamState, offset: u64) !void {
        if (offset < self.outbound_base) return;
        if (offset > self.outboundNext()) return error.StreamAckOutOfRange;
        const drop: usize = @intCast(offset - self.outbound_base);
        if (drop == 0) return;
        const remaining = self.outbound.items.len - drop;
        std.mem.copyForwards(u8, self.outbound.items[0..remaining], self.outbound.items[drop..]);
        self.outbound.shrinkRetainingCapacity(remaining);
        self.outbound_base = offset;
    }

    fn complete(self: *const StreamState) bool {
        return self.outbound_eof and
            self.outbound_eof_acked and
            self.inbound_eof and
            self.outbound.items.len == 0;
    }
};

const StreamStepOutcome = union(enum) {
    idle,
    progress,
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

const StreamAttachmentOptions = struct {
    sink_is_socket: bool,
    replacement_listen_fd: ?c.fd_t = null,
};

const StreamLiveness = struct {
    last_incoming_ms: u64,
    next_ping_ms: u64,
    ping_interval_ms: u64 = stream_ping_interval_ms,
    unresponsive_after_ms: u64 = stream_unresponsive_after_ms,

    fn init(now_ms: u64) StreamLiveness {
        return .{
            .last_incoming_ms = now_ms,
            .next_ping_ms = now_ms + stream_ping_interval_ms,
        };
    }

    fn noteIncoming(self: *StreamLiveness, now_ms: u64) void {
        self.last_incoming_ms = now_ms;
        self.next_ping_ms = now_ms + self.ping_interval_ms;
    }

    fn pollTimeoutMs(self: *const StreamLiveness, now_ms: u64, requested_timeout_ms: i32) i32 {
        var deadline_ms = self.next_ping_ms;
        const unresponsive_deadline_ms = self.last_incoming_ms + self.unresponsive_after_ms;
        if (unresponsive_deadline_ms < deadline_ms) deadline_ms = unresponsive_deadline_ms;
        const liveness_timeout_ms: i32 = if (deadline_ms <= now_ms)
            if (requested_timeout_ms >= 0 and self.timedOut(now_ms)) requested_timeout_ms else 0
        else
            @intCast(@min(deadline_ms - now_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
        if (requested_timeout_ms < 0) return liveness_timeout_ms;
        return @min(requested_timeout_ms, liveness_timeout_ms);
    }

    fn timedOut(self: *const StreamLiveness, now_ms: u64) bool {
        return elapsedMs(self.last_incoming_ms, now_ms) >= self.unresponsive_after_ms;
    }

    fn pingDue(self: *const StreamLiveness, now_ms: u64) bool {
        return now_ms >= self.next_ping_ms;
    }

    fn notePingSent(self: *StreamLiveness, now_ms: u64) void {
        self.next_ping_ms = now_ms + self.ping_interval_ms;
    }
};

// Owns one currently attached transport. The byte-offset state is outside this
// type so a caller can drop this transport and resume the same stream over a
// replacement without duplicating or losing bytes.
const StreamAttachment = struct {
    state: *StreamState,
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    options: StreamAttachmentOptions,
    liveness: StreamLiveness,

    fn init(
        state: *StreamState,
        source_fd: c.fd_t,
        sink_fd: c.fd_t,
        transport_read_fd: c.fd_t,
        transport_write_fd: c.fd_t,
        options: StreamAttachmentOptions,
    ) !StreamAttachment {
        state.peer_ready = false;
        state.outbound_eof_sent = false;
        sendStreamMessage(state.allocator, transport_write_fd, .stream_resume, pb.StreamResume{
            .recv_next_offset = state.recv_next_offset,
        }) catch return error.StreamTransportClosed;
        const now_ms = nowMillis();
        return .{
            .state = state,
            .source_fd = source_fd,
            .sink_fd = sink_fd,
            .transport_read_fd = transport_read_fd,
            .transport_write_fd = transport_write_fd,
            .options = options,
            .liveness = StreamLiveness.init(now_ms),
        };
    }

    fn step(self: *StreamAttachment, requested_timeout_ms: i32) !StreamStepOutcome {
        const state = self.state;
        if (state.complete()) return .complete;

        const now_before_poll_ms = nowMillis();
        var pollfds: [3]posix.pollfd = undefined;
        var count: usize = 0;
        const transport_index = count;
        pollfds[count] = .{ .fd = self.transport_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;

        var source_index: ?usize = null;
        const can_read_source = !state.outbound_eof and state.bufferedBytes() < max_buffered_bytes;
        if (can_read_source) {
            source_index = count;
            pollfds[count] = .{ .fd = self.source_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        var replacement_index: ?usize = null;
        if (self.options.replacement_listen_fd) |listen_fd| {
            replacement_index = count;
            pollfds[count] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        const timeout_ms = self.liveness.pollTimeoutMs(now_before_poll_ms, requested_timeout_ms);
        const ready = try posix.poll(pollfds[0..count], timeout_ms);
        const now_after_poll_ms = nowMillis();

        if (ready == 0) {
            if (self.liveness.timedOut(now_after_poll_ms)) return .unresponsive;
            if (self.liveness.pingDue(now_after_poll_ms)) {
                sendStreamMessage(state.allocator, self.transport_write_fd, .stream_ping, pb.StreamPing{}) catch return .transport_closed;
                self.liveness.notePingSent(now_after_poll_ms);
            }
            return .idle;
        }

        if (replacement_index) |index| {
            if ((pollfds[index].revents & posix.POLL.IN) != 0) {
                const fd = c.accept(pollfds[index].fd, null, null);
                if (fd < 0) return error.AcceptFailed;
                return .{ .replacement = fd };
            }
        }

        if ((pollfds[transport_index].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[transport_index].revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((pollfds[transport_index].revents & posix.POLL.IN) != 0) {
            const frame = protocol.readFrameAlloc(state.allocator, self.transport_read_fd) catch return .transport_closed;
            self.liveness.noteIncoming(nowMillis());
            handleFrame(state, self.sink_fd, self.transport_write_fd, self.options.sink_is_socket, frame) catch |err| switch (err) {
                error.StreamTransportWriteFailed => return .transport_closed,
                else => return err,
            };
            return .progress;
        }

        if (source_index) |index| {
            const source_revents = pollfds[index].revents;
            if ((source_revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                // HUP can arrive with bytes still waiting, especially through
                // OpenSSH's ProxyCommand pipes. Only a zero-length read means
                // the byte stream is actually closed and should be mirrored to
                // the peer as StreamEof.
                var buf: [max_chunk_bytes]u8 = undefined;
                const n = c.read(self.source_fd, &buf, buf.len);
                if (n < 0) switch (posix.errno(n)) {
                    .AGAIN, .INTR => return .idle,
                    else => return error.StreamReadFailed,
                };
                if (n == 0) {
                    state.outbound_eof = true;
                } else {
                    try state.appendOutbound(buf[0..@intCast(n)]);
                }
            }
        }

        if (state.peer_ready) {
            sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return .transport_closed,
                else => return err,
            };
        }
        return .idle;
    }
};

fn PendingReplacement(comptime Starter: type, comptime Transport: type) type {
    return struct {
        const Self = @This();
        const Result = reconnect.AsyncResult(Transport);

        state: *State,

        const State = struct {
            allocator: std.mem.Allocator,
            starter: Starter,
            mutex: std.Thread.Mutex = .{},
            done: bool = false,
            abandoned: bool = false,
            result: ?Result = null,

            fn main(self: *State, thread_allocator: std.mem.Allocator) void {
                var result: Result = if (self.starter.start()) |transport|
                    .{ .ready = transport }
                else |err|
                    .{ .failed = err };

                self.mutex.lock();
                if (self.abandoned) {
                    self.mutex.unlock();
                    cleanupReplacementResult(Transport, &result);
                    self.allocator.destroy(self);
                    return;
                }
                self.result = result;
                self.done = true;
                self.mutex.unlock();
                _ = thread_allocator;
            }
        };

        fn start(allocator: std.mem.Allocator, starter: Starter) !Self {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            state.* = .{
                .allocator = allocator,
                .starter = starter,
            };
            const thread = try std.Thread.spawn(.{}, State.main, .{ state, std.heap.smp_allocator });
            thread.detach();
            return .{ .state = state };
        }

        fn takeIfDone(self: *Self) ?Result {
            self.state.mutex.lock();
            if (!self.state.done) {
                self.state.mutex.unlock();
                return null;
            }
            const result = self.state.result.?;
            self.state.result = null;
            self.state.mutex.unlock();
            self.state.allocator.destroy(self.state);
            self.* = undefined;
            return result;
        }

        fn abandon(self: *Self) void {
            self.state.mutex.lock();
            if (self.state.done) {
                var result = self.state.result.?;
                self.state.result = null;
                self.state.mutex.unlock();
                cleanupReplacementResult(Transport, &result);
                self.state.allocator.destroy(self.state);
            } else {
                self.state.abandoned = true;
                self.state.mutex.unlock();
            }
            self.* = undefined;
        }
    };
}

fn cleanupReplacementResult(comptime Transport: type, result: *reconnect.AsyncResult(Transport)) void {
    switch (result.*) {
        .ready => |*transport| transport.close(),
        .failed => {},
    }
}

/// Runs on the destination host inside the inner ssh channel. It connects that
/// short-lived channel to the per-stream remote agent; the agent owns the real
/// localhost TCP connection to sshd and survives channel loss.
pub fn runRemote(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len != 2) {
        try io.writeAll(2, "sessh: :internal-stream-remote: requires GUID PORT\n");
        return error.InvalidStreamArgs;
    }
    const guid = args[0];
    if (!session_registry.isValidReconnectGuid(guid)) return error.InvalidStreamGuid;
    const port = try parsePort(args[1]);
    const socket_path = try streamSocketPath(allocator, guid);
    defer allocator.free(socket_path);

    const fd = try connectOrStartAgent(allocator, exe, guid, port, socket_path);
    defer _ = c.close(fd);
    try relayRawDuplex(0, 1, fd);
}

/// Runs on the destination host as a detached helper for one `r-` stream. It
/// keeps the connection to localhost:sshd open and accepts replacement inner
/// ssh channels from `runRemote` when the previous channel dies.
pub fn runAgent(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 3) {
        try io.writeAll(2, "sessh: :internal-stream-agent: requires GUID PORT SOCKET\n");
        return error.InvalidStreamArgs;
    }
    const guid = args[0];
    if (!session_registry.isValidReconnectGuid(guid)) return error.InvalidStreamGuid;
    const port = try parsePort(args[1]);
    const socket_path = args[2];

    const listen_fd = try socket_transport.listenSocket(socket_path);
    defer _ = c.close(listen_fd);

    var tcp = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
    defer tcp.close();
    const tcp_fd = tcp.handle;

    var state = StreamState.init(allocator);
    defer state.deinit();

    var attach_fd: c.fd_t = -1;
    defer {
        if (attach_fd >= 0) _ = c.close(attach_fd);
    }
    while (true) {
        if (attach_fd < 0) {
            attach_fd = c.accept(listen_fd, null, null);
            if (attach_fd < 0) return error.AcceptFailed;
        }

        const outcome = try runAttachedStream(&state, tcp_fd, tcp_fd, attach_fd, attach_fd, .{
            .sink_is_socket = true,
            .replacement_listen_fd = listen_fd,
        });
        switch (outcome) {
            .complete => return,
            .replacement => |replacement_fd| {
                _ = c.close(attach_fd);
                attach_fd = replacement_fd;
            },
            .transport_closed, .unresponsive => {
                _ = c.close(attach_fd);
                attach_fd = -1;
            },
        }
    }
}

/// Runs inside the local outer ssh ProxyCommand. Its stdin/stdout are the byte
/// stream OpenSSH expects from a ProxyCommand, and `start_transport` creates
/// inner ssh channels that carry our acknowledged protobuf frames.
pub fn runClientStream(
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: ClientStreamOptions,
) !void {
    const Starter = @TypeOf(start_transport);
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    const Pending = PendingReplacement(Starter, Transport);

    var state = StreamState.init(allocator);
    defer state.deinit();
    var reconnect_status = if (options.title_status_path) |path|
        StreamReconnectStatus.initTitle(path)
    else
        StreamReconnectStatus.init(options.status_enabled);
    defer reconnect_status.deinit();

    var attempt: usize = 0;
    var had_transport = false;
    var retrying = false;
    var pending: ?Pending = null;
    var resumed_transport: ?Transport = null;
    defer if (pending) |*replacement| replacement.abandon();
    defer if (resumed_transport) |*transport| transport.close();

    client_loop: while (true) {
        var transport: Transport = undefined;
        if (resumed_transport) |existing| {
            transport = existing;
            resumed_transport = null;
        } else {
            if (retrying) reconnect_status.showReconnecting();
            transport = start_transport.start() catch |err| {
                // Before the first successful transport, a start failure usually
                // means ssh could not authenticate in BatchMode. Return that to
                // the outer ssh instead of retrying forever.
                if (!had_transport and state.outbound_base == 0 and state.recv_next_offset == 0 and state.outbound.items.len == 0) {
                    reconnect_status.flushDiagnostics();
                    return err;
                }
                const delay_ms = reconnect.delayMs(attempt);
                sleepBeforeReconnect(&reconnect_status, delay_ms);
                attempt = reconnect.nextAttempt(attempt, false);
                retrying = true;
                continue;
            };
        }
        had_transport = true;
        reconnect_status.flushDiagnostics();
        reconnect_status.clear();

        transport_loop: while (true) {
            var attachment = StreamAttachment.init(
                &state,
                0,
                1,
                transport.readFd(),
                transport.writeFd(),
                .{ .sink_is_socket = false },
            ) catch {
                transport.close();
                retrying = true;
                continue :client_loop;
            };
            var old_unresponsive = false;
            while (true) {
                const outcome = attachment.step(if (pending == null) -1 else 50) catch .transport_closed;
                switch (outcome) {
                    .complete => {
                        transport.close();
                        return;
                    },
                    .progress => {
                        if (old_unresponsive) {
                            old_unresponsive = false;
                            attempt = 0;
                            reconnect_status.clear();
                        }
                    },
                    .unresponsive => {
                        if (!old_unresponsive) {
                            old_unresponsive = true;
                            reconnect_status.showReconnecting();
                        }
                        if (pending == null) {
                            pending = Pending.start(allocator, start_transport) catch |err| {
                                client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                                const delay_ms = reconnect.delayMs(attempt);
                                sleepBeforeReconnect(&reconnect_status, delay_ms);
                                attempt = reconnect.nextAttempt(attempt, false);
                                continue;
                            };
                            reconnect_status.showReconnecting();
                        }
                    },
                    .transport_closed => {
                        transport.close();
                        break :transport_loop;
                    },
                    .replacement => |fd| {
                        _ = c.close(fd);
                    },
                    .idle => {},
                }

                if (pending) |*replacement| {
                    if (replacement.takeIfDone()) |result| {
                        pending = null;
                        switch (result) {
                            .ready => |new_transport| {
                                if (old_unresponsive) {
                                    abortTransport(&transport);
                                    transport = new_transport;
                                    attempt = 0;
                                    retrying = false;
                                    reconnect_status.clear();
                                    continue :transport_loop;
                                }
                                var discard = new_transport;
                                discard.close();
                            },
                            .failed => |err| {
                                client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                                if (old_unresponsive) {
                                    const delay_ms = reconnect.delayMs(attempt);
                                    sleepBeforeReconnect(&reconnect_status, delay_ms);
                                    attempt = reconnect.nextAttempt(attempt, false);
                                    pending = Pending.start(allocator, start_transport) catch |retry_err| {
                                        client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{retry_err});
                                        continue;
                                    };
                                    reconnect_status.showReconnecting();
                                }
                            },
                        }
                    }
                }
            }
        }

        if (pending) |*replacement| {
            var result: ?reconnect.AsyncResult(Transport) = null;
            while (result == null) {
                result = replacement.takeIfDone();
                if (result != null) break;
                reconnect_status.showReconnecting();
                io.sleepMillis(50);
                reconnect_status.flushDiagnostics();
            }
            pending = null;
            switch (result.?) {
                .ready => |new_transport| {
                    resumed_transport = new_transport;
                    attempt = 0;
                    retrying = false;
                    continue :client_loop;
                },
                .failed => |err| {
                    client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                },
            }
        }
        const delay_ms = reconnect.delayMs(attempt);
        sleepBeforeReconnect(&reconnect_status, delay_ms);
        attempt = reconnect.nextAttempt(attempt, false);
        retrying = true;
    }
}

fn runAttachedStream(
    state: *StreamState,
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    options: StreamAttachmentOptions,
) !StreamOutcome {
    var attachment = StreamAttachment.init(
        state,
        source_fd,
        sink_fd,
        transport_read_fd,
        transport_write_fd,
        options,
    ) catch return .transport_closed;

    while (true) {
        switch (try attachment.step(-1)) {
            .complete => return .complete,
            .transport_closed => return .transport_closed,
            .unresponsive => return .unresponsive,
            .replacement => |fd| return .{ .replacement = fd },
            .idle, .progress => {},
        }
    }
}

fn handleFrame(
    state: *StreamState,
    sink_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    sink_is_socket: bool,
    frame: protocol.OwnedFrame,
) !void {
    var mutable = frame;
    defer mutable.deinit(state.allocator);

    switch (mutable.message_type) {
        .stream_resume => {
            var message = try protocol.decodePayload(pb.StreamResume, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            state.peer_ready = true;
            state.peer_recv = message.recv_next_offset;
            try state.dropOutboundThrough(message.recv_next_offset);
            state.outbound_sent_next = message.recv_next_offset;
            sendPending(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_ack => {
            var message = try protocol.decodePayload(pb.StreamAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            state.peer_recv = message.offset;
            try state.dropOutboundThrough(message.offset);
            if (state.outbound_sent_next < message.offset) state.outbound_sent_next = message.offset;
        },
        .stream_eof_ack => {
            var message = try protocol.decodePayload(pb.StreamEofAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            state.peer_recv = message.offset;
            try state.dropOutboundThrough(message.offset);
            if (state.outbound_sent_next < message.offset) state.outbound_sent_next = message.offset;
            if (message.offset == state.outboundNext()) state.outbound_eof_acked = true;
        },
        .stream_data => {
            var message = try protocol.decodePayload(pb.StreamData, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            if (message.offset < state.recv_next_offset) {
                // Reconnect retransmits from the peer's last confirmed offset.
                // If a frame overlaps bytes we already delivered, keep any new
                // suffix instead of discarding the whole frame as a duplicate.
                const already_received: usize = @intCast(state.recv_next_offset - message.offset);
                if (already_received < message.data.len) {
                    const new_data = message.data[already_received..];
                    try io.writeAll(sink_fd, new_data);
                    state.recv_next_offset += new_data.len;
                }
                sendStreamMessage(state.allocator, transport_write_fd, .stream_ack, pb.StreamAck{
                    .offset = state.recv_next_offset,
                }) catch |err| switch (err) {
                    error.WriteFailed => return error.StreamTransportWriteFailed,
                    else => return err,
                };
                return;
            }
            if (message.offset != state.recv_next_offset) return error.StreamOffsetGap;
            try io.writeAll(sink_fd, message.data);
            state.recv_next_offset += message.data.len;
            sendStreamMessage(state.allocator, transport_write_fd, .stream_ack, pb.StreamAck{
                .offset = state.recv_next_offset,
            }) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_eof => {
            var message = try protocol.decodePayload(pb.StreamEof, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            if (message.offset > state.recv_next_offset) return error.StreamOffsetGap;
            state.inbound_eof = true;
            if (sink_is_socket) _ = c.shutdown(sink_fd, c.SHUT.WR);
            sendStreamMessage(state.allocator, transport_write_fd, .stream_eof_ack, pb.StreamEofAck{
                .offset = state.recv_next_offset,
            }) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_ping => {
            var message = try protocol.decodePayload(pb.StreamPing, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            sendStreamMessage(state.allocator, transport_write_fd, .stream_pong, pb.StreamPong{}) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_pong => {
            var message = try protocol.decodePayload(pb.StreamPong, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
        },
        else => return error.StreamUnexpectedFrame,
    }
}

fn sendPending(state: *StreamState, transport_write_fd: c.fd_t) !void {
    if (!state.peer_ready) return;
    if (state.peer_recv < state.outbound_base or state.peer_recv > state.outboundNext()) {
        return error.StreamAckOutOfRange;
    }
    if (state.outbound_sent_next < state.outbound_base or state.outbound_sent_next > state.outboundNext()) {
        return error.StreamAckOutOfRange;
    }
    // ACKs tell us what the peer has durably received. Separately remember how
    // far this transport has already been sent so appending new source bytes
    // does not cause an overlapping resend on the same still-live transport.
    // On a replacement transport, StreamResume resets outbound_sent_next to the
    // peer's reported receive offset, which is when retransmission is needed.
    var index: usize = @intCast(state.outbound_sent_next - state.outbound_base);
    while (index < state.outbound.items.len) {
        const len = @min(max_chunk_bytes, state.outbound.items.len - index);
        const offset = state.outbound_base + index;
        try sendStreamMessage(
            state.allocator,
            transport_write_fd,
            .stream_data,
            pb.StreamData{
                .offset = offset,
                .data = state.outbound.items[index .. index + len],
            },
        );
        index += len;
        state.outbound_sent_next = offset + len;
    }
    if (state.outbound_eof and !state.outbound_eof_acked and !state.outbound_eof_sent) {
        try sendStreamMessage(state.allocator, transport_write_fd, .stream_eof, pb.StreamEof{
            .offset = state.outboundNext(),
        });
        state.outbound_eof_sent = true;
    }
}

fn sendStreamMessage(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    message_type: protocol.MessageType,
    message: anytype,
) !void {
    const payload = try protocol.encodePayload(allocator, message);
    defer allocator.free(payload);
    try protocol.sendFrame(fd, message_type, payload);
}

fn abortTransport(transport: anytype) void {
    const Transport = @TypeOf(transport.*);
    if (@hasDecl(Transport, "terminate")) {
        transport.terminate();
    } else {
        transport.close();
    }
}

fn relayRawDuplex(left_read_fd: c.fd_t, left_write_fd: c.fd_t, right_fd: c.fd_t) !void {
    var left_open = true;
    var right_open = true;
    while (left_open or right_open) {
        var pollfds: [2]posix.pollfd = undefined;
        var count: usize = 0;
        if (left_open) {
            pollfds[count] = .{ .fd = left_read_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (right_open) {
            pollfds[count] = .{ .fd = right_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (count == 0) return;
        _ = try posix.poll(pollfds[0..count], -1);

        var poll_index: usize = 0;
        if (left_open) {
            if ((pollfds[poll_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                if (!copySomeOrClose(left_read_fd, right_fd)) {
                    left_open = false;
                    _ = c.shutdown(right_fd, c.SHUT.WR);
                }
            }
            poll_index += 1;
        }
        if (right_open) {
            if ((pollfds[poll_index].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                if (!copySomeOrClose(right_fd, left_write_fd)) {
                    right_open = false;
                }
            }
        }
    }
}

fn copySomeOrClose(read_fd: c.fd_t, write_fd: c.fd_t) bool {
    var buf: [8192]u8 = undefined;
    const n = c.read(read_fd, &buf, buf.len);
    if (n < 0) return switch (posix.errno(n)) {
        .AGAIN, .INTR => true,
        else => false,
    };
    if (n == 0) return false;
    io.writeAll(write_fd, buf[0..@intCast(n)]) catch return false;
    return true;
}

fn connectOrStartAgent(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    port: u16,
    socket_path: []const u8,
) !c.fd_t {
    if (socket_transport.connectSocket(socket_path)) |fd| return fd else |_| {}

    const port_text = try std.fmt.allocPrint(allocator, "{}", .{port});
    defer allocator.free(port_text);
    const argv = [_][]const u8{
        exe,
        ":internal-stream-agent:",
        guid,
        port_text,
        socket_path,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    // The stream agent outlives a single inner ssh channel. It must not keep
    // any of that channel's stdio fds open, or the local client can block while
    // waiting for the dead transport's stderr pump to finish.
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (socket_transport.connectSocket(socket_path)) |fd| return fd else |_| {}
        io.sleepMillis(20);
    }
    return error.StreamAgentDidNotStart;
}

fn streamSocketPath(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    const root = try socket_transport.runtimeRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/r/{s}.sock", .{ root, guid });
}

fn parsePort(value: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, value, 10);
    if (port == 0) return error.InvalidStreamPort;
    return port;
}

fn nowMillis() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    return if (end_ms >= start_ms) end_ms - start_ms else 0;
}

fn sleepBeforeReconnect(status: *StreamReconnectStatus, delay_ms: u64) void {
    var remaining_ms = delay_ms;
    while (remaining_ms > 0) {
        status.showRetry(remaining_ms);
        const step_ms = @min(remaining_ms, 1_000);
        io.sleepMillis(step_ms);
        remaining_ms -= step_ms;
        status.flushDiagnostics();
    }
}

// In ProxyCommand mode stdout is the ssh byte stream, so reconnect status must
// never write there. Non-tty streams can use a repaintable stderr line. Tty
// passthrough uses the window title instead, because stderr output would appear
// inside the user's terminal session.
const StreamReconnectStatus = struct {
    const max_diagnostic_lines = 3;
    const Mode = enum {
        disabled,
        stderr_line,
        window_title,
    };

    fd: c.fd_t,
    mode: Mode,
    owned_fd: bool = false,
    visible: bool = false,
    line: [96]u8 = undefined,
    line_len: usize = 0,
    diagnostic_cursor: u64,
    live_diagnostic_start_seq: u64,
    rendered_diagnostic_seq: u64,

    fn init(enabled: bool) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        return .{
            .fd = 2,
            .mode = if (enabled) .stderr_line else .disabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn initTitle(title_status_path: []const u8) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        // In tty passthrough the proxy only sees OpenSSH's ProxyCommand byte
        // stream, not the decrypted terminal output. Send status requests to
        // the parent relay so it can inject title changes only at safe parser
        // boundaries.
        const fd = socket_transport.connectSocket(title_status_path) catch {
            return .{
                .fd = -1,
                .mode = .disabled,
                .diagnostic_cursor = displayed,
                .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
                .rendered_diagnostic_seq = displayed,
            };
        };
        return .{
            .fd = fd,
            .mode = .window_title,
            .owned_fd = true,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn initForTest(fd: c.fd_t, enabled: bool) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        return .{
            .fd = fd,
            .mode = if (enabled) .stderr_line else .disabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn initTitleForTest(fd: c.fd_t) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        return .{
            .fd = fd,
            .mode = .window_title,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn deinit(self: *StreamReconnectStatus) void {
        self.clear();
        if (self.owned_fd and self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
            self.owned_fd = false;
        }
    }

    fn showRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        var delay_buf: [16]u8 = undefined;
        const delay = reconnect_title.formatDelay(delay_ms, &delay_buf) catch return;
        if (self.mode == .window_title) {
            self.sendTitleStatus("retry {}\n", .{delay_ms});
            return;
        }
        const message = std.fmt.bufPrint(
            &self.line,
            "sessh: disconnected: Retry connecting {s}",
            .{delay},
        ) catch return;
        self.line_len = message.len;
        self.refreshDiagnostics(false);
        self.redrawLine();
    }

    fn showReconnecting(self: *StreamReconnectStatus) void {
        if (self.mode == .window_title) {
            self.sendTitleStatus("reconnecting\n", .{});
            return;
        }
        const message = "sessh: disconnected: Reconnecting...";
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
        self.refreshDiagnostics(false);
        self.redrawLine();
    }

    fn clear(self: *StreamReconnectStatus) void {
        if (self.mode == .window_title) {
            self.sendTitleStatus("clear\n", .{});
            return;
        }
        self.refreshDiagnostics(false);
        self.clearLine();
    }

    fn flushDiagnostics(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics(false);
    }

    fn clearLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_line or !self.visible) return;
        io.writeAll(self.fd, "\r\x1b[K") catch {};
        self.visible = false;
    }

    fn redrawLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_line) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, "\r") catch return;
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\x1b[K") catch return;
        self.visible = true;
    }

    fn refreshDiagnostics(self: *StreamReconnectStatus, redraw_after: bool) void {
        if (self.mode != .stderr_line) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;

        var diagnostics = [_]client_log.UserDiagnosticLine{.{}} ** max_diagnostic_lines;
        const new_cursor = client_log.copyUserDiagnosticsSince(self.diagnostic_cursor, &diagnostics);
        if (new_cursor == self.diagnostic_cursor) {
            self.rendered_diagnostic_seq = new_cursor;
            return;
        }

        var wrote = false;
        for (&diagnostics) |*diagnostic| {
            if (diagnostic.seq == 0) continue;
            if (!wrote and self.visible) {
                // The retry countdown already owns the row the cursor is on.
                // Reuse that row for the ssh diagnostic; writing a newline
                // here leaves a blank row before every diagnostic.
                io.writeAll(self.fd, "\r\x1b[K") catch return;
                self.visible = false;
            }
            wrote = true;

            var line_buf: [client_log.max_user_diagnostic_display_bytes]u8 = undefined;
            const line = formatDiagnosticLine(
                &line_buf,
                diagnostic,
                diagnostic.seq <= self.live_diagnostic_start_seq,
            ) catch continue;
            io.writeAll(self.fd, line) catch return;
            io.writeAll(self.fd, "\r\n") catch return;
        }

        self.diagnostic_cursor = new_cursor;
        self.rendered_diagnostic_seq = new_cursor;
        client_log.markUserDiagnosticsDisplayedThrough(new_cursor);
        if (wrote and redraw_after and self.line_len > 0) self.redrawLine();
    }

    fn sendTitleStatus(self: *StreamReconnectStatus, comptime fmt: []const u8, args: anytype) void {
        if (self.mode != .window_title or self.fd < 0) return;
        var buf: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch return;
        io.writeAll(self.fd, message) catch {};
    }
};

fn formatDiagnosticLine(
    out: []u8,
    diagnostic: *const client_log.UserDiagnosticLine,
    delayed: bool,
) ![]const u8 {
    const prefix = if (delayed)
        try std.fmt.bufPrint(out, "{s} ts_ms={}: ", .{ diagnostic.tag.label(), diagnostic.ts_ms })
    else
        try std.fmt.bufPrint(out, "{s}: ", .{diagnostic.tag.label()});
    const message = diagnostic.slice();
    if (prefix.len + message.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[prefix.len .. prefix.len + message.len], message);
    return out[0 .. prefix.len + message.len];
}

test "stream frames round trip through a pipe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try sendStreamMessage(std.testing.allocator, fds[1], .stream_data, pb.StreamData{
        .offset = 42,
        .data = "hello",
    });
    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(protocol.MessageType.stream_data, frame.message_type);
    var message = try protocol.decodePayload(pb.StreamData, std.testing.allocator, frame.payload);
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), message.offset);
    try std.testing.expectEqualStrings("hello", message.data);
}

test "stream ping receives pong without changing offsets" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator);
    defer state.deinit();
    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamPing{});
    try handleFrame(&state, -1, fds[1], false, .{
        .message_type = .stream_ping,
        .payload = payload,
    });

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.stream_pong, frame.message_type);
    try std.testing.expectEqual(@as(u64, 0), state.recv_next_offset);
    try std.testing.expectEqual(@as(u64, 0), state.outboundNext());
}

test "stream sender sends only newly appended bytes on a live transport" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator);
    defer state.deinit();
    state.peer_ready = true;

    try state.appendOutbound("first");
    try sendPending(&state, fds[1]);
    var first_frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer first_frame.deinit(std.testing.allocator);
    var first = try protocol.decodePayload(pb.StreamData, std.testing.allocator, first_frame.payload);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), first.offset);
    try std.testing.expectEqualStrings("first", first.data);

    try state.appendOutbound("second");
    try sendPending(&state, fds[1]);
    var second_frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer second_frame.deinit(std.testing.allocator);
    var second = try protocol.decodePayload(pb.StreamData, std.testing.allocator, second_frame.payload);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 5), second.offset);
    try std.testing.expectEqualStrings("second", second.data);
}

test "stream receiver keeps suffix from overlapping data frame" {
    const sink = try posix.pipe();
    defer posix.close(sink[0]);
    defer posix.close(sink[1]);
    const ack = try posix.pipe();
    defer posix.close(ack[0]);
    defer posix.close(ack[1]);

    var state = StreamState.init(std.testing.allocator);
    defer state.deinit();
    state.recv_next_offset = 5;

    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamData{
        .offset = 0,
        .data = "firstsecond",
    });
    try handleFrame(&state, sink[1], ack[1], false, .{
        .message_type = .stream_data,
        .payload = payload,
    });

    var delivered: [6]u8 = undefined;
    try io.readExact(sink[0], &delivered);
    try std.testing.expectEqualStrings("second", delivered[0..]);

    var ack_frame = try protocol.readFrameAlloc(std.testing.allocator, ack[0]);
    defer ack_frame.deinit(std.testing.allocator);
    var ack_message = try protocol.decodePayload(pb.StreamAck, std.testing.allocator, ack_frame.payload);
    defer ack_message.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 11), ack_message.offset);
}

test "stream liveness schedules probes before declaring unresponsive" {
    var liveness = StreamLiveness.init(1_000);
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(1_000, -1));
    try std.testing.expect(liveness.pingDue(2_000));
    try std.testing.expect(!liveness.timedOut(2_000));
    liveness.notePingSent(2_000);
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(2_000, -1));
    try std.testing.expect(liveness.timedOut(11_000));
    try std.testing.expectEqual(@as(i32, 50), liveness.pollTimeoutMs(11_000, 50));
    liveness.noteIncoming(11_000);
    try std.testing.expect(!liveness.timedOut(11_000));
    try std.testing.expectEqual(@as(i32, 1_000), liveness.pollTimeoutMs(11_000, -1));
}

test "pending stream replacement hands off a prepared transport" {
    const TestTransport = struct {
        closed: *bool,

        fn close(self: *@This()) void {
            self.closed.* = true;
        }
    };
    const TestStarter = struct {
        closed: *bool,

        fn start(self: *@This()) !TestTransport {
            return .{ .closed = self.closed };
        }
    };

    var closed = false;
    var starter = TestStarter{ .closed = &closed };
    const Pending = PendingReplacement(*TestStarter, TestTransport);
    var pending = try Pending.start(std.testing.allocator, &starter);

    var result: ?reconnect.AsyncResult(TestTransport) = null;
    var attempts: usize = 0;
    while (result == null and attempts < 100) : (attempts += 1) {
        result = pending.takeIfDone();
        if (result == null) io.sleepMillis(1);
    }
    var completed = result orelse return error.PendingReplacementDidNotFinish;
    defer cleanupReplacementResult(TestTransport, &completed);

    switch (completed) {
        .ready => try std.testing.expect(!closed),
        .failed => return error.UnexpectedPendingReplacementFailure,
    }
}

test "stream completion waits for eof acknowledgement" {
    var state = StreamState.init(std.testing.allocator);
    defer state.deinit();
    state.outbound_eof = true;
    state.inbound_eof = true;

    try std.testing.expect(!state.complete());

    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamEofAck{
        .offset = 0,
    });
    try handleFrame(&state, -1, -1, false, .{
        .message_type = .stream_eof_ack,
        .payload = payload,
    });
    try std.testing.expect(state.complete());
}

test "stream reconnect status uses stderr-style terminal line" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], true);
    status.showRetry(1_000);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [128]u8 = undefined;
        const n = c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }

    try std.testing.expectEqualStrings(
        "\rsessh: disconnected: Retry connecting 1sec\x1b[K" ++
            "\rsessh: disconnected: Reconnecting...\x1b[K" ++
            "\r\x1b[K",
        output.items,
    );
}

test "stream reconnect title status sends parent relay commands" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initTitleForTest(fds[1]);
    status.showRetry(12_000);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [128]u8 = undefined;
        const n = c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }

    try std.testing.expectEqualStrings(
        "retry 12000\n" ++
            "reconnecting\n" ++
            "clear\n",
        output.items,
    );
}

test "stream reconnect status renders ssh diagnostics before status" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], true);
    client_log.appendSshStderr("control sequence: \x1b[31mred\n");
    status.showRetry(1_000);
    status.clear();
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [128]u8 = undefined;
        const n = c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }

    try std.testing.expectEqualStrings(
        "ssh: control sequence: ?[31mred\r\n" ++
            "\rsessh: disconnected: Retry connecting 1sec\x1b[K" ++
            "\r\x1b[K",
        output.items,
    );
}

test "stream reconnect status reuses visible status row for diagnostics" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());
    var status = StreamReconnectStatus.initForTest(fds[1], true);
    status.showRetry(1_000);
    client_log.appendSshStderr("connection failed\n");
    status.flushDiagnostics();
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [128]u8 = undefined;
        const n = c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }

    try std.testing.expectEqualStrings(
        "\rsessh: disconnected: Retry connecting 1sec\x1b[K" ++
            "\r\x1b[Kssh: connection failed\r\n",
        output.items,
    );
}
