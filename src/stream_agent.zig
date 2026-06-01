const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");
const protocol = @import("protocol.zig");
const client_log = @import("client_log.zig");
const pty_process = @import("pty_process.zig");
const reconnect_control = @import("reconnect_control.zig");
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

pub const LocalStreamOptions = struct {
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
    stderr_fd: c.fd_t,
    show_status: bool,
    intercept_ctrl_r: bool,
    receive_stderr: bool,
};

// Stream channel ids are wire values, not a closed enum. The standard channels
// intentionally match Unix fd numbers; positive ids above stderr stay available
// for future byte streams without reshaping the protocol.
const StreamChannel = i32;
const stream_channel_undefined: StreamChannel = -1;
const stream_channel_stdin: StreamChannel = 0;
const stream_channel_stdout: StreamChannel = 1;
const stream_channel_stderr: StreamChannel = 2;
const channel_count = 3;
const max_stream_sources = 2;
const stream_channels = [_]StreamChannel{
    stream_channel_stdin,
    stream_channel_stdout,
    stream_channel_stderr,
};

const ChannelMask = struct {
    stdin: bool = false,
    stdout: bool = false,
    stderr: bool = false,

    fn contains(self: ChannelMask, channel: StreamChannel) bool {
        return switch (channel) {
            stream_channel_stdin => self.stdin,
            stream_channel_stdout => self.stdout,
            stream_channel_stderr => self.stderr,
            else => false,
        };
    }
};

const StreamChannelState = struct {
    outbound: std.ArrayList(u8) = .empty,
    outbound_base: u64 = 0,
    recv_next_offset: u64 = 0,
    peer_recv: u64 = 0,
    // Highest outbound offset already written to the currently attached
    // transport. This is intentionally separate from peer_recv: ACKs decide
    // what can be dropped, while this prevents overlapping sends before an ACK
    // has had time to come back.
    outbound_sent_next: u64 = 0,
    outbound_eof: bool = false,
    outbound_eof_sent: bool = false,
    outbound_eof_acked: bool = false,
    inbound_eof: bool = false,

    fn outboundNext(self: *const StreamChannelState) u64 {
        return self.outbound_base + self.outbound.items.len;
    }

    fn bufferedBytes(self: *const StreamChannelState) usize {
        return self.outbound.items.len;
    }

    fn deinit(self: *StreamChannelState, allocator: std.mem.Allocator) void {
        self.outbound.deinit(allocator);
        self.* = undefined;
    }
};

// Tracks byte offsets independently for stdin, stdout, and stderr. That is
// what lets a replacement ssh transport resume without dropping or replaying
// bytes while still preserving non-tty stdout/stderr separation.
const StreamState = struct {
    allocator: std.mem.Allocator,
    channels: [channel_count]StreamChannelState = .{ .{}, .{}, .{} },
    active_outbound: ChannelMask,
    active_inbound: ChannelMask,
    peer_ready: bool = false,

    fn init(allocator: std.mem.Allocator, active_outbound: ChannelMask, active_inbound: ChannelMask) StreamState {
        var state = StreamState{
            .allocator = allocator,
            .active_outbound = active_outbound,
            .active_inbound = active_inbound,
        };
        for (stream_channels) |stream_channel| {
            if (!active_inbound.contains(stream_channel)) state.channel(stream_channel).inbound_eof = true;
            if (!active_outbound.contains(stream_channel)) {
                state.channel(stream_channel).outbound_eof = true;
                state.channel(stream_channel).outbound_eof_acked = true;
            }
        }
        return state;
    }

    fn deinit(self: *StreamState) void {
        for (&self.channels) |*channel_state| channel_state.deinit(self.allocator);
        self.* = undefined;
    }

    fn channel(self: *StreamState, stream_channel: StreamChannel) *StreamChannelState {
        return &self.channels[channelIndex(stream_channel)];
    }

    fn constChannel(self: *const StreamState, stream_channel: StreamChannel) *const StreamChannelState {
        return &self.channels[channelIndex(stream_channel)];
    }

    fn resumeMessage(self: *const StreamState) pb.StreamResume {
        return .{
            .stdin_recv_next_offset = self.constChannel(stream_channel_stdin).recv_next_offset,
            .stdout_recv_next_offset = self.constChannel(stream_channel_stdout).recv_next_offset,
            .stderr_recv_next_offset = self.constChannel(stream_channel_stderr).recv_next_offset,
        };
    }

    fn appendOutbound(self: *StreamState, stream_channel: StreamChannel, bytes: []const u8) !void {
        try self.channel(stream_channel).outbound.appendSlice(self.allocator, bytes);
    }

    fn dropOutboundThrough(self: *StreamState, stream_channel: StreamChannel, offset: u64) !void {
        const channel_state = self.channel(stream_channel);
        if (offset < channel_state.outbound_base) return;
        if (offset > channel_state.outboundNext()) return error.StreamAckOutOfRange;
        const drop: usize = @intCast(offset - channel_state.outbound_base);
        if (drop == 0) return;
        const remaining = channel_state.outbound.items.len - drop;
        std.mem.copyForwards(u8, channel_state.outbound.items[0..remaining], channel_state.outbound.items[drop..]);
        channel_state.outbound.shrinkRetainingCapacity(remaining);
        channel_state.outbound_base = offset;
    }

    fn bufferedBytes(self: *const StreamState, stream_channel: StreamChannel) usize {
        return self.constChannel(stream_channel).bufferedBytes();
    }

    fn allActiveInboundEof(self: *const StreamState) bool {
        for (stream_channels) |stream_channel| {
            if (self.active_inbound.contains(stream_channel) and !self.constChannel(stream_channel).inbound_eof) return false;
        }
        return true;
    }

    fn complete(self: *const StreamState) bool {
        for (stream_channels) |stream_channel| {
            const channel_state = self.constChannel(stream_channel);
            if (self.active_outbound.contains(stream_channel)) {
                if (!channel_state.outbound_eof or
                    !channel_state.outbound_eof_acked or
                    channel_state.outbound.items.len != 0)
                {
                    return false;
                }
            }
            if (self.active_inbound.contains(stream_channel) and !channel_state.inbound_eof) return false;
        }
        return true;
    }

    fn hasProgress(self: *const StreamState) bool {
        for (stream_channels) |stream_channel| {
            const channel_state = self.constChannel(stream_channel);
            if (channel_state.recv_next_offset != 0 or
                channel_state.outbound_base != 0 or
                channel_state.outbound.items.len != 0)
            {
                return true;
            }
        }
        return false;
    }
};

fn channelIndex(channel: StreamChannel) usize {
    return switch (channel) {
        stream_channel_stdin => 0,
        stream_channel_stdout => 1,
        stream_channel_stderr => 2,
        else => unreachable,
    };
}

fn streamChannelFromWire(channel: i32) !StreamChannel {
    return switch (channel) {
        stream_channel_stdin,
        stream_channel_stdout,
        stream_channel_stderr,
        => channel,
        else => error.StreamInvalidChannel,
    };
}

fn recvNextFromResume(message: pb.StreamResume, channel: StreamChannel) u64 {
    return switch (channel) {
        stream_channel_stdin => message.stdin_recv_next_offset,
        stream_channel_stdout => message.stdout_recv_next_offset,
        stream_channel_stderr => message.stderr_recv_next_offset,
        else => unreachable,
    };
}

const StreamStepOutcome = union(enum) {
    idle,
    progress,
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

const StreamSource = struct {
    fd: c.fd_t = -1,
    channel: StreamChannel = stream_channel_undefined,
    source_eio_is_eof: bool = false,
    input_control: ?*StreamInputControl = null,
};

const ChannelSink = struct {
    fd: c.fd_t = -1,
    close_fd_on_eof: ?*c.fd_t = null,
    shutdown_on_eof: bool = false,
};

fn sinksWithStdin(stdin_fd: c.fd_t, close_fd_on_eof: ?*c.fd_t) [channel_count]ChannelSink {
    var sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} };
    sinks[channelIndex(stream_channel_stdin)] = .{
        .fd = stdin_fd,
        .close_fd_on_eof = close_fd_on_eof,
    };
    return sinks;
}

fn localStreamSinks(stdout_fd: c.fd_t, stderr_fd: c.fd_t, receive_stderr: bool) [channel_count]ChannelSink {
    var sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} };
    sinks[channelIndex(stream_channel_stdout)] = .{ .fd = stdout_fd };
    if (receive_stderr) {
        sinks[channelIndex(stream_channel_stderr)] = .{ .fd = stderr_fd };
    }
    return sinks;
}

const StreamAttachmentOptions = struct {
    source_count: usize = 0,
    sources: [max_stream_sources]StreamSource = .{ .{}, .{} },
    sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} },
    replacement_listen_fd: ?c.fd_t = null,
    close_outbound_on_inbound_eof: bool = false,
    source_exit_pid: ?c.pid_t = null,
    source_exit_seen: ?*bool = null,

    fn sink(self: *const StreamAttachmentOptions, channel: StreamChannel) ChannelSink {
        return self.sinks[channelIndex(channel)];
    }
};

const StreamInputControl = struct {
    enabled: bool,
    status_visible: bool = false,
    reconnect_requested: bool = false,

    fn filter(self: *StreamInputControl, bytes: []const u8, out: []u8) []const u8 {
        if (!self.enabled or !self.status_visible) {
            @memcpy(out[0..bytes.len], bytes);
            return out[0..bytes.len];
        }
        var written: usize = 0;
        for (bytes) |byte| {
            if (byte == reconnect_control.ctrl_r) {
                self.reconnect_requested = true;
                continue;
            }
            out[written] = byte;
            written += 1;
        }
        return out[0..written];
    }

    fn consumeReconnectRequest(self: *StreamInputControl) bool {
        const requested = self.reconnect_requested;
        self.reconnect_requested = false;
        return requested;
    }
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
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    options: StreamAttachmentOptions,
    liveness: StreamLiveness,

    fn init(
        state: *StreamState,
        transport_read_fd: c.fd_t,
        transport_write_fd: c.fd_t,
        options: StreamAttachmentOptions,
    ) !StreamAttachment {
        state.peer_ready = false;
        for (stream_channels) |channel| {
            if (state.active_outbound.contains(channel)) {
                state.channel(channel).outbound_eof_sent = false;
            }
        }
        sendStreamMessage(state.allocator, transport_write_fd, .stream_resume, state.resumeMessage()) catch return error.StreamTransportClosed;
        const now_ms = nowMillis();
        return .{
            .state = state,
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
        var pollfds: [1 + max_stream_sources + 1]posix.pollfd = undefined;
        var count: usize = 0;
        const transport_index = count;
        pollfds[count] = .{ .fd = self.transport_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;

        var source_poll_indices: [max_stream_sources]?usize = .{ null, null };
        if (self.options.source_count > max_stream_sources) return error.StreamTooManySources;
        for (self.options.sources[0..self.options.source_count], 0..) |source, source_index| {
            if (source.fd < 0) continue;
            if (!state.active_outbound.contains(source.channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(source.channel);
            if (channel_state.outbound_eof or channel_state.bufferedBytes() >= max_buffered_bytes) continue;
            source_poll_indices[source_index] = count;
            pollfds[count] = .{ .fd = source.fd, .events = posix.POLL.IN, .revents = 0 };
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
            // A command can exit after we drain its final stdout bytes but
            // before the pipe reports EOF. Poll then wakes only for our
            // liveness timer, so the timeout path must also check the child
            // status and send StreamEof. Otherwise short non-tty commands can
            // print their output and leave the durable stream agent alive
            // waiting for a reconnect that will never be needed.
            try self.drainExitedSources();
            if (state.peer_ready) {
                sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                    error.WriteFailed => return .transport_closed,
                    else => return err,
                };
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
            handleFrame(
                state,
                self.transport_write_fd,
                &self.options,
                frame,
            ) catch |err| switch (err) {
                error.StreamTransportWriteFailed => return .transport_closed,
                else => return err,
            };
            return .progress;
        }

        for (self.options.sources[0..self.options.source_count], 0..) |source, source_index| {
            const poll_index = source_poll_indices[source_index] orelse continue;
            if (pollfds[poll_index].revents != 0) {
                try self.readSource(source);
            }
        }
        try self.drainExitedSources();

        if (state.peer_ready) {
            sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return .transport_closed,
                else => return err,
            };
        }
        return .idle;
    }

    fn readSource(self: *StreamAttachment, source: StreamSource) !void {
        const channel_state = self.state.channel(source.channel);
        if (channel_state.outbound_eof) return;
        // HUP can arrive with bytes still waiting. Only a zero-length read
        // means the byte stream is actually closed and should be mirrored to
        // the peer as StreamEof. macOS can report POLLNVAL for sources like
        // /dev/null even though read() is still valid and returns EOF, so any
        // source event gets one read attempt.
        var buf: [max_chunk_bytes]u8 = undefined;
        const n = c.read(source.fd, &buf, buf.len);
        if (n < 0) {
            switch (posix.errno(n)) {
                .AGAIN, .INTR => return,
                .IO => if (source.source_eio_is_eof) {
                    channel_state.outbound_eof = true;
                } else return error.StreamReadFailed,
                else => return error.StreamReadFailed,
            }
        } else if (n == 0) {
            channel_state.outbound_eof = true;
        } else {
            try self.appendSourceBytes(source, buf[0..@intCast(n)]);
        }
    }

    fn appendSourceBytes(self: *StreamAttachment, source: StreamSource, bytes: []const u8) !void {
        if (source.input_control) |control| {
            var filtered: [max_chunk_bytes]u8 = undefined;
            const filtered_bytes = control.filter(bytes, &filtered);
            try self.state.appendOutbound(source.channel, filtered_bytes);
        } else {
            try self.state.appendOutbound(source.channel, bytes);
        }
    }

    fn drainExitedSources(self: *StreamAttachment) !void {
        const pid = self.options.source_exit_pid orelse return;
        const exited = self.options.source_exit_seen orelse return;
        if (!exited.*) {
            var status: c_int = 0;
            const result = c.waitpid(pid, &status, 1);
            if (result == pid) {
                exited.* = true;
            } else if (result < 0) {
                exited.* = true;
            } else {
                return;
            }
        }

        for (self.options.sources[0..self.options.source_count]) |source| {
            if (source.fd < 0) continue;
            const channel_state = self.state.channel(source.channel);
            while (!channel_state.outbound_eof and channel_state.bufferedBytes() < max_buffered_bytes) {
                var buf: [max_chunk_bytes]u8 = undefined;
                switch (readSomeNonBlocking(source.fd, &buf)) {
                    .bytes => |bytes| if (bytes.len == 0) {
                        channel_state.outbound_eof = true;
                        break;
                    } else {
                        try self.appendSourceBytes(source, bytes);
                    },
                    // Once the child process is gone, the pipe has no writers.
                    // A would-block result here means this channel has no more
                    // bytes for us to preserve, so publish EOF to the peer.
                    .would_block => {
                        channel_state.outbound_eof = true;
                        break;
                    },
                    .failed => return error.StreamReadFailed,
                }
            }
        }
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

const StreamMode = enum {
    pty,
    pipe,
};

const StreamAgentConfig = struct {
    guid: []const u8,
    mode: StreamMode,
    rows: u16,
    cols: u16,
    shell_command: ?[]u8,

    fn deinit(self: *StreamAgentConfig, allocator: std.mem.Allocator) void {
        if (self.shell_command) |command| allocator.free(command);
        self.* = undefined;
    }
};

const StreamEndpoint = union(enum) {
    pty: pty_process.Child,
    pipe: PipeEndpoint,

    fn activeOutbound(self: *const StreamEndpoint) ChannelMask {
        return switch (self.*) {
            .pty => .{ .stdout = true },
            .pipe => .{ .stdout = true, .stderr = true },
        };
    }

    fn activeInbound(self: *const StreamEndpoint) ChannelMask {
        _ = self;
        return .{ .stdin = true };
    }

    fn attachmentOptions(self: *StreamEndpoint, listen_fd: c.fd_t) StreamAttachmentOptions {
        return switch (self.*) {
            .pty => |*pty| .{
                .source_count = 1,
                .sources = .{
                    .{
                        .fd = pty.master_fd,
                        .channel = stream_channel_stdout,
                        .source_eio_is_eof = true,
                    },
                    .{},
                },
                .sinks = sinksWithStdin(pty.master_fd, null),
                .replacement_listen_fd = listen_fd,
            },
            .pipe => |*pipe| .{
                .source_count = 2,
                .sources = .{
                    .{ .fd = pipe.stdout_fd, .channel = stream_channel_stdout },
                    .{ .fd = pipe.stderr_fd, .channel = stream_channel_stderr },
                },
                .sinks = sinksWithStdin(pipe.stdin_fd, &pipe.stdin_fd),
                .replacement_listen_fd = listen_fd,
                .source_exit_pid = pipe.child.id,
                .source_exit_seen = &pipe.exited,
            },
        };
    }

    fn deinit(self: *StreamEndpoint) void {
        switch (self.*) {
            .pty => |*pty| pty.terminate(),
            .pipe => |*pipe| pipe.deinit(),
        }
        self.* = undefined;
    }
};

const PipeEndpoint = struct {
    child: std.process.Child,
    stdin_fd: c.fd_t,
    stdout_fd: c.fd_t,
    stderr_fd: c.fd_t,
    exited: bool = false,

    fn spawn(allocator: std.mem.Allocator, shell_command: ?[]const u8) !PipeEndpoint {
        const shell = pty_process.defaultShellPath();
        var argv_buf: [3][]const u8 = undefined;
        argv_buf[0] = shell;
        var argv_len: usize = 1;
        if (shell_command) |command| {
            argv_buf[1] = "-c";
            argv_buf[2] = command;
            argv_len = 3;
        }

        var child = std.process.Child.init(argv_buf[0..argv_len], allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const stdin_fd = child.stdin.?.handle;
        const stdout_fd = child.stdout.?.handle;
        const stderr_fd = child.stderr.?.handle;
        return .{
            .child = child,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .stderr_fd = stderr_fd,
        };
    }

    fn deinit(self: *PipeEndpoint) void {
        if (self.stdin_fd >= 0) {
            _ = c.close(self.stdin_fd);
            self.stdin_fd = -1;
            self.child.stdin = null;
        }
        if (self.stdout_fd >= 0) {
            _ = c.close(self.stdout_fd);
            self.stdout_fd = -1;
            self.child.stdout = null;
        }
        if (self.stderr_fd >= 0) {
            _ = c.close(self.stderr_fd);
            self.stderr_fd = -1;
            self.child.stderr = null;
        }
        _ = self.child.wait() catch {};
        self.* = undefined;
    }
};

/// The visible `:internal-stream-agent:` process runs inside the current ssh
/// transport. It connects that short-lived transport to a durable agent socket
/// for the `r-` GUID, starting the durable agent under the same entrypoint when
/// needed. Keeping one public stream entrypoint avoids the old client/remote
/// split where different sockets spoke different ad-hoc protocols.
pub fn runAgent(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--serve")) {
        return runAgentServer(allocator, args[1..]);
    }
    var config = try parseStreamAgentConfig(allocator, args);
    defer config.deinit(allocator);

    var socket_paths = try session_registry.runtimeAgentSocketPathsForGuid(allocator, config.guid);
    defer socket_paths.deinit(allocator);

    const fd = try connectOrStartAgent(allocator, exe, args, socket_paths.socket);
    defer _ = c.close(fd);
    try relayRawDuplex(0, 1, fd);
}

fn runAgentServer(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 6) {
        try io.writeAll(2, "sessh: :internal-stream-agent: --serve requires GUID SOCKET MODE ROWS COLS COMMAND\n");
        return error.InvalidStreamArgs;
    }
    const socket_path = args[1];
    var config = try parseStreamAgentConfig(allocator, &.{ args[0], args[2], args[3], args[4], args[5] });
    defer config.deinit(allocator);

    var socket_paths = try session_registry.runtimeAgentSocketPathsForGuid(allocator, config.guid);
    defer {
        socket_paths.removeRuntimeFiles();
        socket_paths.deinit(allocator);
    }

    const listen_fd = try socket_transport.listenSocket(socket_path);
    defer _ = c.close(listen_fd);

    var endpoint = try startStreamEndpoint(allocator, config);
    defer endpoint.deinit();

    var state = StreamState.init(allocator, endpoint.activeOutbound(), endpoint.activeInbound());
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

        const outcome = try runAttachedStream(
            &state,
            attach_fd,
            attach_fd,
            endpoint.attachmentOptions(listen_fd),
        );
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

/// Runs in the local `sessh` process. `start_transport` creates ssh transports
/// that execute the visible `:internal-stream-agent:` entrypoint remotely; this
/// loop owns local stdin/stdout and the reconnect policy.
pub fn runLocalStream(
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: LocalStreamOptions,
) !void {
    const Starter = @TypeOf(start_transport);
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    const Pending = PendingReplacement(Starter, Transport);

    var state = StreamState.init(
        allocator,
        .{ .stdin = true },
        .{ .stdout = true, .stderr = options.receive_stderr },
    );
    defer state.deinit();
    var input_control = StreamInputControl{ .enabled = options.intercept_ctrl_r };
    var reconnect_status = StreamReconnectStatus.init(options.show_status, options.intercept_ctrl_r);
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
                if (!had_transport and !state.hasProgress()) {
                    reconnect_status.flushDiagnostics();
                    return err;
                }
                const delay_ms = reconnect.delayMs(attempt);
                const reconnect_now = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control);
                attempt = reconnect.nextAttempt(attempt, reconnect_now);
                retrying = true;
                continue;
            };
        }
        had_transport = true;
        reconnect_status.flushDiagnostics();
        reconnect_status.clear();
        input_control.status_visible = false;

        transport_loop: while (true) {
            var attachment = StreamAttachment.init(
                &state,
                transport.readFd(),
                transport.writeFd(),
                .{
                    .source_count = 1,
                    .sources = .{
                        .{
                            .fd = options.source_fd,
                            .channel = stream_channel_stdin,
                            .input_control = &input_control,
                        },
                        .{},
                    },
                    .sinks = localStreamSinks(options.sink_fd, options.stderr_fd, options.receive_stderr),
                    // A direct stream represents one remote command, not
                    // an interactive session. Once the remote side has
                    // closed its output stream there is no process left to
                    // consume more local input, so match OpenSSH and let
                    // the command finish even if local stdin is still a
                    // live terminal.
                    .close_outbound_on_inbound_eof = true,
                },
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
                            input_control.status_visible = false;
                        }
                    },
                    .unresponsive => {
                        if (!old_unresponsive) {
                            old_unresponsive = true;
                            reconnect_status.showReconnecting();
                            input_control.status_visible = true;
                        }
                        if (pending == null) {
                            pending = Pending.start(allocator, start_transport) catch |err| {
                                client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                                const delay_ms = reconnect.delayMs(attempt);
                                const reconnect_now = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control);
                                attempt = reconnect.nextAttempt(attempt, reconnect_now);
                                continue;
                            };
                            reconnect_status.showReconnecting();
                            input_control.status_visible = true;
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
                if (input_control.consumeReconnectRequest() and old_unresponsive and pending == null) {
                    pending = Pending.start(allocator, start_transport) catch |err| {
                        client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                        continue;
                    };
                    reconnect_status.showReconnecting();
                    input_control.status_visible = true;
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
                                    input_control.status_visible = false;
                                    continue :transport_loop;
                                }
                                var discard = new_transport;
                                discard.close();
                            },
                            .failed => |err| {
                                client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                                if (old_unresponsive) {
                                    const delay_ms = reconnect.delayMs(attempt);
                                    const reconnect_now = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control);
                                    attempt = reconnect.nextAttempt(attempt, reconnect_now);
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
                input_control.status_visible = true;
                _ = pollReconnectInput(&state, options.source_fd, &input_control, 50);
                reconnect_status.flushDiagnostics();
            }
            pending = null;
            switch (result.?) {
                .ready => |new_transport| {
                    resumed_transport = new_transport;
                    attempt = 0;
                    retrying = false;
                    input_control.status_visible = false;
                    continue :client_loop;
                },
                .failed => |err| {
                    client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                },
            }
        }
        const delay_ms = reconnect.delayMs(attempt);
        const reconnect_now = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control);
        attempt = reconnect.nextAttempt(attempt, reconnect_now);
        retrying = true;
    }
}

fn runAttachedStream(
    state: *StreamState,
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    options: StreamAttachmentOptions,
) !StreamOutcome {
    var attachment = StreamAttachment.init(
        state,
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
    transport_write_fd: c.fd_t,
    options: *const StreamAttachmentOptions,
    frame: protocol.OwnedFrame,
) !void {
    var mutable = frame;
    defer mutable.deinit(state.allocator);

    switch (mutable.message_type) {
        .stream_resume => {
            var message = try protocol.decodePayload(pb.StreamResume, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            state.peer_ready = true;
            for (stream_channels) |channel| {
                if (!state.active_outbound.contains(channel)) continue;
                const offset = recvNextFromResume(message, channel);
                const channel_state = state.channel(channel);
                channel_state.peer_recv = offset;
                try state.dropOutboundThrough(channel, offset);
                channel_state.outbound_sent_next = offset;
            }
            sendPending(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_ack => {
            var message = try protocol.decodePayload(pb.StreamAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            const channel = try streamChannelFromWire(message.channel);
            if (!state.active_outbound.contains(channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(channel);
            channel_state.peer_recv = message.offset;
            try state.dropOutboundThrough(channel, message.offset);
            if (channel_state.outbound_sent_next < message.offset) channel_state.outbound_sent_next = message.offset;
        },
        .stream_eof_ack => {
            var message = try protocol.decodePayload(pb.StreamEofAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            const channel = try streamChannelFromWire(message.channel);
            if (!state.active_outbound.contains(channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(channel);
            channel_state.peer_recv = message.offset;
            try state.dropOutboundThrough(channel, message.offset);
            if (channel_state.outbound_sent_next < message.offset) channel_state.outbound_sent_next = message.offset;
            if (message.offset == channel_state.outboundNext()) channel_state.outbound_eof_acked = true;
        },
        .stream_data => {
            var message = try protocol.decodePayload(pb.StreamData, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            const channel = try streamChannelFromWire(message.channel);
            if (!state.active_inbound.contains(channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(channel);
            const sink = options.sink(channel);
            if (message.offset < channel_state.recv_next_offset) {
                // Reconnect retransmits from the peer's last confirmed offset.
                // If a frame overlaps bytes we already delivered, keep any new
                // suffix instead of discarding the whole frame as a duplicate.
                const already_received: usize = @intCast(channel_state.recv_next_offset - message.offset);
                if (already_received < message.data.len) {
                    const new_data = message.data[already_received..];
                    if (sink.fd < 0) return error.StreamSinkClosed;
                    try io.writeAll(sink.fd, new_data);
                    channel_state.recv_next_offset += new_data.len;
                }
                sendStreamMessage(state.allocator, transport_write_fd, .stream_ack, pb.StreamAck{
                    .channel = channel,
                    .offset = channel_state.recv_next_offset,
                }) catch |err| switch (err) {
                    error.WriteFailed => return error.StreamTransportWriteFailed,
                    else => return err,
                };
                return;
            }
            if (message.offset != channel_state.recv_next_offset) return error.StreamOffsetGap;
            if (message.data.len != 0 and sink.fd < 0) return error.StreamSinkClosed;
            if (message.data.len != 0) try io.writeAll(sink.fd, message.data);
            channel_state.recv_next_offset += message.data.len;
            sendStreamMessage(state.allocator, transport_write_fd, .stream_ack, pb.StreamAck{
                .channel = channel,
                .offset = channel_state.recv_next_offset,
            }) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .stream_eof => {
            var message = try protocol.decodePayload(pb.StreamEof, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            const channel = try streamChannelFromWire(message.channel);
            if (!state.active_inbound.contains(channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(channel);
            if (message.offset > channel_state.recv_next_offset) return error.StreamOffsetGap;
            channel_state.inbound_eof = true;
            const sink = options.sink(channel);
            if (sink.shutdown_on_eof and sink.fd >= 0) _ = c.shutdown(sink.fd, c.SHUT.WR);
            if (sink.close_fd_on_eof) |sink_fd_ptr| {
                if (sink_fd_ptr.* >= 0) {
                    _ = c.close(sink_fd_ptr.*);
                    sink_fd_ptr.* = -1;
                }
            }
            if (options.close_outbound_on_inbound_eof and state.allActiveInboundEof()) {
                for (stream_channels) |outbound_channel| {
                    if (state.active_outbound.contains(outbound_channel)) {
                        state.channel(outbound_channel).outbound_eof = true;
                    }
                }
            }
            sendStreamMessage(state.allocator, transport_write_fd, .stream_eof_ack, pb.StreamEofAck{
                .channel = channel,
                .offset = channel_state.recv_next_offset,
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
    for (stream_channels) |channel| {
        if (!state.active_outbound.contains(channel)) continue;
        const channel_state = state.channel(channel);
        if (channel_state.peer_recv < channel_state.outbound_base or
            channel_state.peer_recv > channel_state.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        if (channel_state.outbound_sent_next < channel_state.outbound_base or
            channel_state.outbound_sent_next > channel_state.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        // ACKs tell us what the peer has durably received. Separately remember
        // how far this transport has already been sent so appending new source
        // bytes does not cause an overlapping resend on the same still-live
        // transport. On a replacement transport, StreamResume resets
        // outbound_sent_next to the peer's reported receive offset, which is
        // when retransmission is needed.
        var index: usize = @intCast(channel_state.outbound_sent_next - channel_state.outbound_base);
        while (index < channel_state.outbound.items.len) {
            const len = @min(max_chunk_bytes, channel_state.outbound.items.len - index);
            const offset = channel_state.outbound_base + index;
            try sendStreamMessage(
                state.allocator,
                transport_write_fd,
                .stream_data,
                pb.StreamData{
                    .channel = channel,
                    .offset = offset,
                    .data = channel_state.outbound.items[index .. index + len],
                },
            );
            index += len;
            channel_state.outbound_sent_next = offset + len;
        }
        if (channel_state.outbound_eof and !channel_state.outbound_eof_acked and !channel_state.outbound_eof_sent) {
            try sendStreamMessage(state.allocator, transport_write_fd, .stream_eof, pb.StreamEof{
                .channel = channel,
                .offset = channel_state.outboundNext(),
            });
            channel_state.outbound_eof_sent = true;
        }
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

const ReadSomeResult = union(enum) {
    bytes: []const u8,
    would_block,
    failed,
};

fn readSomeNonBlocking(fd: c.fd_t, buf: []u8) ReadSomeResult {
    const original_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (original_flags < 0) return .failed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    const changed_flags = (original_flags & nonblocking_flag) == 0;
    if (changed_flags and c.fcntl(fd, c.F.SETFL, original_flags | nonblocking_flag) < 0) return .failed;
    defer {
        if (changed_flags) _ = c.fcntl(fd, c.F.SETFL, original_flags);
    }

    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .{ .bytes = buf[0..0] };
        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            else => return .failed,
        }
    }
}

fn connectOrStartAgent(
    allocator: std.mem.Allocator,
    exe: []const u8,
    agent_args: []const []const u8,
    socket_path: []const u8,
) !c.fd_t {
    if (socket_transport.connectSocket(socket_path)) |fd| return fd else |_| {}

    if (agent_args.len != 5) return error.InvalidStreamArgs;
    const argv = [_][]const u8{
        exe,
        ":internal-stream-agent:",
        "--serve",
        agent_args[0],
        socket_path,
        agent_args[1],
        agent_args[2],
        agent_args[3],
        agent_args[4],
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    // The durable agent outlives this ssh channel, so it must not inherit the
    // channel's stdio fds. Otherwise the local client can wait forever for an
    // already-dead transport to close.
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

fn parseStreamAgentConfig(allocator: std.mem.Allocator, args: []const []const u8) !StreamAgentConfig {
    if (args.len != 5) {
        try io.writeAll(2, "sessh: :internal-stream-agent: requires GUID MODE ROWS COLS COMMAND\n");
        return error.InvalidStreamArgs;
    }
    if (!session_registry.isValidReconnectGuid(args[0])) return error.InvalidStreamGuid;
    const mode: StreamMode = if (std.mem.eql(u8, args[1], "pty"))
        .pty
    else if (std.mem.eql(u8, args[1], "pipe"))
        .pipe
    else
        return error.InvalidStreamMode;
    const rows = try parseDimension(args[2]);
    const cols = try parseDimension(args[3]);
    const shell_command = try decodeCommandArg(allocator, args[4]);
    errdefer if (shell_command) |command| allocator.free(command);
    return .{
        .guid = args[0],
        .mode = mode,
        .rows = rows,
        .cols = cols,
        .shell_command = shell_command,
    };
}

fn parseDimension(value: []const u8) !u16 {
    const parsed = try std.fmt.parseInt(u16, value, 10);
    return @max(parsed, 1);
}

fn decodeCommandArg(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.eql(u8, value, "-")) return null;
    const len = try std.base64.standard.Decoder.calcSizeForSlice(value);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, value);
    return out;
}

fn startStreamEndpoint(allocator: std.mem.Allocator, config: StreamAgentConfig) !StreamEndpoint {
    return switch (config.mode) {
        .pty => .{ .pty = try pty_process.spawn(allocator, .{
            .rows = config.rows,
            .cols = config.cols,
            .shell_command = config.shell_command,
            .session_guid = config.guid,
        }) },
        .pipe => .{ .pipe = try PipeEndpoint.spawn(allocator, config.shell_command) },
    };
}

fn nowMillis() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    return if (end_ms >= start_ms) end_ms - start_ms else 0;
}

fn waitBeforeReconnect(
    status: *StreamReconnectStatus,
    delay_ms: u64,
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
) bool {
    var remaining_ms = delay_ms;
    while (remaining_ms > 0) {
        status.showRetry(remaining_ms);
        input_control.status_visible = true;
        const step_ms = @min(remaining_ms, 1_000);
        if (pollReconnectInput(state, source_fd, input_control, @intCast(step_ms))) return true;
        remaining_ms -= step_ms;
        status.flushDiagnostics();
    }
    return input_control.consumeReconnectRequest();
}

fn pollReconnectInput(
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
    timeout_ms: i32,
) bool {
    if (!input_control.enabled or !input_control.status_visible) {
        if (timeout_ms > 0) io.sleepMillis(@intCast(timeout_ms));
        return false;
    }
    var pollfd = [_]posix.pollfd{.{
        .fd = source_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = posix.poll(&pollfd, timeout_ms) catch return input_control.consumeReconnectRequest();
    if (ready == 0) return input_control.consumeReconnectRequest();
    if (pollfd[0].revents != 0) {
        var buf: [max_chunk_bytes]u8 = undefined;
        const n = c.read(source_fd, &buf, buf.len);
        if (n <= 0) {
            state.channel(stream_channel_stdin).outbound_eof = true;
        } else {
            var filtered: [max_chunk_bytes]u8 = undefined;
            const filtered_bytes = input_control.filter(buf[0..@intCast(n)], &filtered);
            state.appendOutbound(stream_channel_stdin, filtered_bytes) catch {};
        }
    }
    return input_control.consumeReconnectRequest();
}

// Direct streams must keep stdout byte-for-byte clean when it is redirected, so
// reconnect status is append-only stderr text. The caller only enables this when
// stderr is a terminal; otherwise reconnect attempts stay quiet.
const StreamReconnectStatus = struct {
    const max_diagnostic_lines = 3;
    const Mode = enum {
        disabled,
        stderr_plain,
    };

    fd: c.fd_t,
    mode: Mode,
    line: [96]u8 = undefined,
    line_len: usize = 0,
    ctrl_r_enabled: bool,
    diagnostic_cursor: u64,
    live_diagnostic_start_seq: u64,
    rendered_diagnostic_seq: u64,

    fn init(enabled: bool, ctrl_r_enabled: bool) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        return .{
            .fd = 2,
            .mode = if (enabled) .stderr_plain else .disabled,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn initForTest(fd: c.fd_t, enabled: bool, ctrl_r_enabled: bool) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        return .{
            .fd = fd,
            .mode = if (enabled) .stderr_plain else .disabled,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
    }

    fn deinit(self: *StreamReconnectStatus) void {
        self.clear();
    }

    fn showRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        var delay_buf: [16]u8 = undefined;
        const delay = reconnect_title.formatDelay(delay_ms, &delay_buf) catch return;
        const message = if (self.ctrl_r_enabled)
            std.fmt.bufPrint(&self.line, "sessh: disconnected: Retry connecting {s}. CTRL-R now", .{delay}) catch return
        else
            std.fmt.bufPrint(&self.line, "sessh: disconnected: Retry connecting {s}", .{delay}) catch return;
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writePlainStatusLine();
    }

    fn showReconnecting(self: *StreamReconnectStatus) void {
        const message = if (self.ctrl_r_enabled)
            "sessh: disconnected: Reconnecting... CTRL-R now"
        else
            "sessh: disconnected: Reconnecting...";
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writePlainStatusLine();
    }

    fn clear(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics();
    }

    fn flushDiagnostics(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics();
    }

    fn writePlainStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\n") catch return;
    }

    fn refreshDiagnostics(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain) return;
        if (client_log.currentUserDiagnosticSeq() == self.rendered_diagnostic_seq) return;

        var diagnostics = [_]client_log.UserDiagnosticLine{.{}} ** max_diagnostic_lines;
        const new_cursor = client_log.copyUserDiagnosticsSince(self.diagnostic_cursor, &diagnostics);
        if (new_cursor == self.diagnostic_cursor) {
            self.rendered_diagnostic_seq = new_cursor;
            return;
        }

        for (&diagnostics) |*diagnostic| {
            if (diagnostic.seq == 0) continue;

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
        .channel = stream_channel_stdout,
        .offset = 42,
        .data = "hello",
    });
    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(protocol.MessageType.stream_data, frame.message_type);
    var message = try protocol.decodePayload(pb.StreamData, std.testing.allocator, frame.payload);
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqual(stream_channel_stdout, message.channel);
    try std.testing.expectEqual(@as(u64, 42), message.offset);
    try std.testing.expectEqualStrings("hello", message.data);
}

test "stream ping receives pong without changing offsets" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{ .stdout = true });
    defer state.deinit();
    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamPing{});
    const options = StreamAttachmentOptions{};
    try handleFrame(&state, fds[1], &options, .{
        .message_type = .stream_ping,
        .payload = payload,
    });

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.stream_pong, frame.message_type);
    try std.testing.expectEqual(@as(u64, 0), state.constChannel(stream_channel_stdout).recv_next_offset);
    try std.testing.expectEqual(@as(u64, 0), state.constChannel(stream_channel_stdin).outboundNext());
}

test "stream sender sends only newly appended bytes on a live transport" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{});
    defer state.deinit();
    state.peer_ready = true;

    try state.appendOutbound(stream_channel_stdin, "first");
    try sendPending(&state, fds[1]);
    var first_frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer first_frame.deinit(std.testing.allocator);
    var first = try protocol.decodePayload(pb.StreamData, std.testing.allocator, first_frame.payload);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(stream_channel_stdin, first.channel);
    try std.testing.expectEqual(@as(u64, 0), first.offset);
    try std.testing.expectEqualStrings("first", first.data);

    try state.appendOutbound(stream_channel_stdin, "second");
    try sendPending(&state, fds[1]);
    var second_frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer second_frame.deinit(std.testing.allocator);
    var second = try protocol.decodePayload(pb.StreamData, std.testing.allocator, second_frame.payload);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(stream_channel_stdin, second.channel);
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

    var state = StreamState.init(std.testing.allocator, .{}, .{ .stdout = true });
    defer state.deinit();
    state.channel(stream_channel_stdout).recv_next_offset = 5;

    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamData{
        .channel = stream_channel_stdout,
        .offset = 0,
        .data = "firstsecond",
    });
    var options = StreamAttachmentOptions{};
    options.sinks[channelIndex(stream_channel_stdout)] = .{ .fd = sink[1] };
    try handleFrame(&state, ack[1], &options, .{
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
    try std.testing.expectEqual(stream_channel_stdout, ack_message.channel);
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
    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{});
    defer state.deinit();
    state.channel(stream_channel_stdin).outbound_eof = true;

    try std.testing.expect(!state.complete());

    const payload = try protocol.encodePayload(std.testing.allocator, pb.StreamEofAck{
        .channel = stream_channel_stdin,
        .offset = 0,
    });
    const options = StreamAttachmentOptions{};
    try handleFrame(&state, -1, &options, .{
        .message_type = .stream_eof_ack,
        .payload = payload,
    });
    try std.testing.expect(state.complete());
}

test "stream reconnect status uses plain stderr lines" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], true, false);
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
        "sessh: disconnected: Retry connecting 1sec\n" ++
            "sessh: disconnected: Reconnecting...\n",
        output.items,
    );
}

test "stream reconnect status renders ssh diagnostics before status" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], true, false);
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
            "sessh: disconnected: Retry connecting 1sec\n",
        output.items,
    );
}

test "stream reconnect status appends diagnostics after status line" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());
    var status = StreamReconnectStatus.initForTest(fds[1], true, false);
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
        "sessh: disconnected: Retry connecting 1sec\n" ++
            "ssh: connection failed\r\n",
        output.items,
    );
}
