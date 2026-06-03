const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");
const protocol = @import("protocol.zig");
const client_log = @import("client_log.zig");
const reconnect_control = @import("reconnect_control.zig");
const reconnect = @import("reconnect.zig");
const reconnect_title = @import("reconnect_title.zig");
const session_registry = @import("session_registry.zig");
const socket_transport = @import("socket_transport.zig");
const terminal = @import("terminal.zig");
const pb = protocol.pb;

const max_buffered_bytes = 1024 * 1024;
const max_chunk_bytes = 16 * 1024;
const transport_ping_interval_ms: u64 = 1_000;
const stream_unresponsive_after_ms: u64 = 10_000;

const StreamOutcome = union(enum) {
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

pub const StreamReconnectStatusMode = enum {
    disabled,
    stderr_plain,
    title,
};

pub const LocalStreamOptions = struct {
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
    status_mode: StreamReconnectStatusMode,
    intercept_ctrl_r: bool,
    intercept_escape: bool = false,
    title_fallback: []const u8 = "",
};

// Stream channels are internal fd-shaped identities. The proxy stream protocol
// carries one active outbound channel and one active inbound channel at a time.
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
// Source EOF is reported as fd readiness on some platforms and as HUP/ERR on
// others. Either way, a ready source gets a read attempt before we consider the
// child reaped or the stream complete.
const source_poll_events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;

var local_stream_interrupt_write_fd: c.fd_t = -1;

fn handleLocalStreamInterrupt(_: c_int) callconv(.c) void {
    const fd = local_stream_interrupt_write_fd;
    if (fd < 0) return;
    var byte = [_]u8{1};
    _ = c.write(fd, &byte, byte.len);
}

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

// Tracks byte offsets independently for the internal stdin/stdout/stderr
// identities. The active channel masks decide which single channel is carried
// in each direction for a proxy stream.
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

fn singleActiveChannel(mask: ChannelMask) !StreamChannel {
    var channel: StreamChannel = stream_channel_undefined;
    var count: usize = 0;
    for (stream_channels) |candidate| {
        if (!mask.contains(candidate)) continue;
        channel = candidate;
        count += 1;
    }
    if (count != 1) return error.StreamInvalidChannel;
    return channel;
}

const StreamStepOutcome = union(enum) {
    idle,
    progress,
    complete,
    interrupted,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

const StreamSourceKind = enum {
    byte_stream,
};

const StreamSource = struct {
    fd: c.fd_t = -1,
    channel: StreamChannel = stream_channel_undefined,
    kind: StreamSourceKind = .byte_stream,
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

fn localStreamSinks(stdout_fd: c.fd_t) [channel_count]ChannelSink {
    var sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} };
    sinks[channelIndex(stream_channel_stdout)] = .{ .fd = stdout_fd };
    return sinks;
}

const StreamAttachmentOptions = struct {
    source_count: usize = 0,
    sources: [max_stream_sources]StreamSource = .{ .{}, .{} },
    sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} },
    reconnect_status: ?*StreamReconnectStatus = null,
    replacement_listen_fd: ?c.fd_t = null,
    close_outbound_on_inbound_eof: bool = false,

    fn sink(self: *const StreamAttachmentOptions, channel: StreamChannel) ChannelSink {
        return self.sinks[channelIndex(channel)];
    }
};

const StreamInputControl = struct {
    enabled: bool,
    escape_enabled: bool = false,
    status_visible: bool = false,
    reconnect_requested: bool = false,
    disconnect_requested: bool = false,
    help_requested: bool = false,
    escape_filter: terminal.EscapeFilter = .{},

    fn filter(self: *StreamInputControl, bytes: []const u8, out: []u8) []const u8 {
        var input = bytes;
        var scratch: [max_chunk_bytes]u8 = undefined;
        if (self.escape_enabled) {
            const result = self.escape_filter.filter(bytes, &scratch);
            if (result.end) |end| switch (end) {
                .detach => self.disconnect_requested = true,
                .help => self.help_requested = true,
                .repaint, .reconnect => {},
            };
            input = result.bytes;
        }

        if (!self.enabled or !self.status_visible) {
            @memcpy(out[0..input.len], input);
            return out[0..input.len];
        }
        var written: usize = 0;
        for (input) |byte| {
            if (byte == reconnect_control.ctrl_r) {
                self.reconnect_requested = true;
                continue;
            }
            out[written] = byte;
            written += 1;
        }
        return out[0..written];
    }

    fn consumeAction(self: *StreamInputControl) StreamControlAction {
        if (self.disconnect_requested) {
            self.disconnect_requested = false;
            self.reconnect_requested = false;
            self.help_requested = false;
            return .disconnect;
        }
        if (self.help_requested) {
            self.help_requested = false;
            return .help;
        }
        const requested = self.reconnect_requested;
        self.reconnect_requested = false;
        return if (requested) .reconnect else .none;
    }
};

const StreamControlAction = enum {
    none,
    reconnect,
    disconnect,
    help,
    interrupt,
};

const StreamLiveness = struct {
    last_incoming_ms: u64,
    next_ping_ms: u64,
    ping_interval_ms: u64 = transport_ping_interval_ms,
    unresponsive_after_ms: u64 = stream_unresponsive_after_ms,

    fn init(now_ms: u64) StreamLiveness {
        return .{
            .last_incoming_ms = now_ms,
            .next_ping_ms = now_ms + transport_ping_interval_ms,
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
    // Optional fd used only by the local stream loop. It lets that loop wake an
    // otherwise blocking attachment when an async replacement transport is
    // ready, without shortening the main poll timeout.
    external_wakeup_fd: c.fd_t = -1,
    interrupt_fd: c.fd_t = -1,

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
        sendResumeMessage(state, transport_write_fd) catch return error.StreamTransportClosed;
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
        var pollfds: [1 + max_stream_sources + 1 + 2]posix.pollfd = undefined;
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
            pollfds[count] = .{ .fd = source.fd, .events = source_poll_events, .revents = 0 };
            count += 1;
        }

        var replacement_index: ?usize = null;
        if (self.options.replacement_listen_fd) |listen_fd| {
            replacement_index = count;
            pollfds[count] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        var external_wakeup_index: ?usize = null;
        if (self.external_wakeup_fd >= 0) {
            external_wakeup_index = count;
            pollfds[count] = .{ .fd = self.external_wakeup_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        var interrupt_index: ?usize = null;
        if (self.interrupt_fd >= 0) {
            interrupt_index = count;
            pollfds[count] = .{ .fd = self.interrupt_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        const timeout_ms = self.liveness.pollTimeoutMs(now_before_poll_ms, requested_timeout_ms);
        const ready = try posix.poll(pollfds[0..count], timeout_ms);
        const now_after_poll_ms = nowMillis();

        if (ready == 0) {
            if (self.liveness.timedOut(now_after_poll_ms)) return .unresponsive;
            if (self.liveness.pingDue(now_after_poll_ms)) {
                protocol.sendPing(self.transport_write_fd) catch return .transport_closed;
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
        if (interrupt_index) |index| {
            if (pollfds[index].revents != 0) return .interrupted;
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
            // A transport frame can make source bytes or EOF immediately useful
            // without any new source readiness. For example, a resume frame
            // tells us the peer is ready for retransmission, and inbound EOF can mark
            // our outbound side closed.
            try drainStreamSourcesNonBlocking(state, &self.options);
            if (state.peer_ready) {
                sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                    error.WriteFailed => return .transport_closed,
                    else => return err,
                };
            }
            return .progress;
        }

        var source_ready = false;
        for (self.options.sources[0..self.options.source_count], 0..) |source, source_index| {
            const poll_index = source_poll_indices[source_index] orelse continue;
            if (pollfds[poll_index].revents != 0) {
                source_ready = true;
                try readStreamSource(state, source);
            }
        }
        if (!source_ready) {
            // A wake-only event means the local loop has a replacement result
            // to inspect. Do not flush buffered bytes to the old transport just
            // because the replacement thread finished.
            if (external_wakeup_index) |index| {
                if (pollfds[index].revents != 0) return .idle;
            }
        }
        try drainStreamSourcesNonBlocking(state, &self.options);

        if (state.peer_ready) {
            sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return .transport_closed,
                else => return err,
            };
        }
        return .idle;
    }
};

fn readStreamSource(state: *StreamState, source: StreamSource) !void {
    const channel_state = state.channel(source.channel);
    if (channel_state.outbound_eof) return;
    // HUP/ERR can arrive while bytes are still readable, so source readiness
    // always gets a read attempt.
    var buf: [max_chunk_bytes]u8 = undefined;
    switch (try readStreamSourceFd(source, &buf)) {
        .bytes => |bytes| try appendStreamSourceBytes(state, source, bytes),
        .would_block => {},
        .eof => channel_state.outbound_eof = true,
    }
}

fn appendStreamSourceBytes(state: *StreamState, source: StreamSource, bytes: []const u8) !void {
    if (source.input_control) |control| {
        var filtered: [max_chunk_bytes]u8 = undefined;
        const filtered_bytes = control.filter(bytes, &filtered);
        try state.appendOutbound(source.channel, filtered_bytes);
    } else {
        try state.appendOutbound(source.channel, bytes);
    }
}

fn drainStreamSourcesNonBlocking(
    state: *StreamState,
    options: *const StreamAttachmentOptions,
) !void {
    for (options.sources[0..options.source_count]) |source| {
        if (source.fd < 0) continue;
        const channel_state = state.channel(source.channel);
        while (!channel_state.outbound_eof and channel_state.bufferedBytes() < max_buffered_bytes) {
            var buf: [max_chunk_bytes]u8 = undefined;
            switch (try readStreamSourceFdNonBlocking(source, &buf)) {
                .bytes => |bytes| if (bytes.len == 0) {
                    channel_state.outbound_eof = true;
                    break;
                } else {
                    try appendStreamSourceBytes(state, source, bytes);
                },
                .would_block => {
                    // Would-block only means there is no source data ready
                    // right now. EOF must come from the source fd itself, not
                    // from a child-status guess.
                    break;
                },
                .eof => {
                    channel_state.outbound_eof = true;
                    break;
                },
            }
        }
    }
}

fn readStreamSourceFd(source: StreamSource, buf: []u8) !ReadSomeResult {
    _ = source.kind;
    return readSome(source.fd, buf);
}

fn readStreamSourceFdNonBlocking(source: StreamSource, buf: []u8) !ReadSomeResult {
    _ = source.kind;
    return readSomeNonBlocking(source.fd, buf);
}

fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const close_on_exec_flag = @as(c_int, @intCast(c.FD_CLOEXEC));
    if ((flags & close_on_exec_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFD, flags | close_on_exec_flag) < 0) return error.FcntlFailed;
}

const LocalStreamInterrupt = struct {
    read_fd: c.fd_t = -1,
    write_fd: c.fd_t = -1,
    previous_action: posix.Sigaction = undefined,
    installed: bool = false,

    fn install() !LocalStreamInterrupt {
        const pipe_fds = try posix.pipe();
        var interrupt = LocalStreamInterrupt{
            .read_fd = pipe_fds[0],
            .write_fd = pipe_fds[1],
        };
        errdefer interrupt.closeFds();

        try setNonBlockingFd(interrupt.read_fd);
        try setNonBlockingFd(interrupt.write_fd);
        try setCloseOnExec(interrupt.read_fd);
        try setCloseOnExec(interrupt.write_fd);

        // OpenSSH does not expose a negative local SIGINT return code for
        // non-tty commands; it exits as ssh failure 255. The stream client uses
        // this pipe to turn SIGINT into a normal poll event so it can abort the
        // transport, clean up local terminal state, and return the same status.
        const action = posix.Sigaction{
            .handler = .{ .handler = handleLocalStreamInterrupt },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        local_stream_interrupt_write_fd = interrupt.write_fd;
        posix.sigaction(posix.SIG.INT, &action, &interrupt.previous_action);
        interrupt.installed = true;
        return interrupt;
    }

    fn deinit(self: *LocalStreamInterrupt) void {
        if (self.installed) {
            posix.sigaction(posix.SIG.INT, &self.previous_action, null);
            self.installed = false;
        }
        local_stream_interrupt_write_fd = -1;
        self.closeFds();
    }

    fn consume(self: *LocalStreamInterrupt) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.read_fd, &buf, buf.len);
            if (n > 0) continue;
            if (n == 0) return;
            switch (posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return,
                else => return,
            }
        }
    }

    fn closeFds(self: *LocalStreamInterrupt) void {
        if (self.read_fd >= 0) {
            posix.close(self.read_fd);
            self.read_fd = -1;
        }
        if (self.write_fd >= 0) {
            posix.close(self.write_fd);
            self.write_fd = -1;
        }
    }
};

fn PendingReplacement(comptime Starter: type, comptime Transport: type) type {
    return struct {
        const Self = @This();
        const Result = reconnect.AsyncResult(Transport);

        state: *State,

        // The reconnect attempt runs on a thread, but the stream loop is built
        // around fd readiness. This pipe turns thread completion into another
        // pollable event so the loop does not need a short timeout just to ask
        // whether the thread is done.
        const State = struct {
            allocator: std.mem.Allocator,
            starter: Starter,
            mutex: std.Thread.Mutex = .{},
            done: bool = false,
            abandoned: bool = false,
            result: ?Result = null,
            notify_read_fd: c.fd_t = -1,
            notify_write_fd: c.fd_t = -1,

            fn main(self: *State, thread_allocator: std.mem.Allocator) void {
                var result: Result = if (self.starter.start()) |transport|
                    .{ .ready = transport }
                else |err|
                    .{ .failed = err };

                self.mutex.lock();
                if (self.abandoned) {
                    self.mutex.unlock();
                    cleanupReplacementResult(Transport, &result);
                    self.closeNotifyFds();
                    self.allocator.destroy(self);
                    return;
                }
                self.result = result;
                self.done = true;
                self.notifyDone();
                self.mutex.unlock();
                _ = thread_allocator;
            }

            fn notifyDone(self: *State) void {
                var byte = [_]u8{1};
                while (true) {
                    const n = c.write(self.notify_write_fd, byte[0..].ptr, byte.len);
                    if (n > 0) return;
                    if (n == 0) return;
                    switch (posix.errno(n)) {
                        .INTR => continue,
                        else => return,
                    }
                }
            }

            fn closeNotifyFds(self: *State) void {
                if (self.notify_read_fd >= 0) {
                    posix.close(self.notify_read_fd);
                    self.notify_read_fd = -1;
                }
                if (self.notify_write_fd >= 0) {
                    posix.close(self.notify_write_fd);
                    self.notify_write_fd = -1;
                }
            }
        };

        fn start(allocator: std.mem.Allocator, starter: Starter) !Self {
            const notify_pipe = try posix.pipe();
            errdefer {
                posix.close(notify_pipe[0]);
                posix.close(notify_pipe[1]);
            }
            try setNonBlockingFd(notify_pipe[0]);
            try setNonBlockingFd(notify_pipe[1]);
            try setCloseOnExec(notify_pipe[0]);
            try setCloseOnExec(notify_pipe[1]);

            const state = try allocator.create(State);
            state.* = .{
                .allocator = allocator,
                .starter = starter,
                .notify_read_fd = notify_pipe[0],
                .notify_write_fd = notify_pipe[1],
            };
            errdefer {
                state.closeNotifyFds();
                allocator.destroy(state);
            }
            const thread = try std.Thread.spawn(.{}, State.main, .{ state, std.heap.smp_allocator });
            thread.detach();
            return .{ .state = state };
        }

        fn notifyFd(self: *const Self) c.fd_t {
            return self.state.notify_read_fd;
        }

        fn takeIfDone(self: *Self) ?Result {
            self.state.mutex.lock();
            if (!self.state.done) {
                self.state.mutex.unlock();
                return null;
            }
            const result = self.state.result.?;
            self.state.result = null;
            self.state.closeNotifyFds();
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
                self.state.closeNotifyFds();
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
    proxy,
};

const StreamAgentConfig = struct {
    guid: []const u8,
    mode: StreamMode,
    proxy_host: ?[]u8,
    proxy_port: u16 = 0,

    fn deinit(self: *StreamAgentConfig, allocator: std.mem.Allocator) void {
        if (self.proxy_host) |host| allocator.free(host);
        self.* = undefined;
    }
};

const ProxyEndpoint = struct {
    stream: std.net.Stream,
    fd: c.fd_t,

    fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !ProxyEndpoint {
        const stream = try std.net.tcpConnectToHost(allocator, host, port);
        return .{
            .stream = stream,
            .fd = stream.handle,
        };
    }

    fn attachmentOptions(self: *ProxyEndpoint, listen_fd: c.fd_t) StreamAttachmentOptions {
        return .{
            .source_count = 1,
            .sources = .{
                .{ .fd = self.fd, .channel = stream_channel_stdout },
                .{},
            },
            .sinks = blk: {
                var sinks: [channel_count]ChannelSink = .{ .{}, .{}, .{} };
                sinks[channelIndex(stream_channel_stdin)] = .{
                    .fd = self.fd,
                    .shutdown_on_eof = true,
                };
                break :blk sinks;
            },
            .replacement_listen_fd = listen_fd,
        };
    }

    fn deinit(self: *ProxyEndpoint) void {
        if (self.fd >= 0) {
            self.stream.close();
            self.fd = -1;
        }
        self.* = undefined;
    }
};

/// The stream broker is bound to one ssh transport. It connects that transport
/// to the durable stream agent socket for the stream GUID, starting the agent
/// when needed, then relays bytes between ssh stdio and the agent socket.
/// Stream brokers use `p-` GUIDs, but their durable sockets are still agent
/// sockets under `a/`; the GUID directory carries proxy-specific metadata.
pub fn runBroker(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var config = try parseStreamAgentConfig(allocator, args);
    defer config.deinit(allocator);

    var socket_paths = try session_registry.runtimeAgentSocketPathsForGuid(allocator, config.guid);
    defer socket_paths.deinit(allocator);

    const fd = try connectOrStartAgent(allocator, exe, args, socket_paths.socket);
    defer _ = c.close(fd);
    try relayRawDuplex(0, 1, fd);
}

pub fn runAgent(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    _ = exe;
    if (args.len != 8) {
        try io.writeAll(2, "sessh: :internal-stream-agent: requires GUID SOCKET MODE ROWS COLS HOST PORT -\n");
        return error.InvalidStreamArgs;
    }
    const socket_path = args[1];
    var config = try parseStreamAgentConfig(allocator, &.{ args[0], args[2], args[3], args[4], args[5], args[6], args[7] });
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

    var state = StreamState.init(allocator, .{ .stdout = true }, .{ .stdin = true });
    defer state.deinit();

    var attach_fd: c.fd_t = -1;
    defer {
        if (attach_fd >= 0) _ = c.close(attach_fd);
    }
    while (true) {
        if (attach_fd < 0) {
            var detached_options = endpoint.attachmentOptions(listen_fd);
            attach_fd = try waitForReplacementWhileDetached(&state, listen_fd, &detached_options);
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

fn waitForReplacementWhileDetached(
    state: *StreamState,
    listen_fd: c.fd_t,
    options: *const StreamAttachmentOptions,
) !c.fd_t {
    while (true) {
        // The stream agent is durable even when no ssh transport is currently
        // attached. It must keep draining remote fds into the offset-tracked
        // buffers; otherwise the remote TCP peer can block before a
        // replacement transport attaches.
        var pollfds: [1 + max_stream_sources]posix.pollfd = undefined;
        var count: usize = 0;
        const listen_index = count;
        pollfds[count] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;

        var source_poll_indices: [max_stream_sources]?usize = .{ null, null };
        if (options.source_count > max_stream_sources) return error.StreamTooManySources;
        for (options.sources[0..options.source_count], 0..) |source, source_index| {
            if (source.fd < 0) continue;
            if (!state.active_outbound.contains(source.channel)) return error.StreamInactiveChannel;
            const channel_state = state.channel(source.channel);
            if (channel_state.outbound_eof or channel_state.bufferedBytes() >= max_buffered_bytes) continue;
            source_poll_indices[source_index] = count;
            pollfds[count] = .{ .fd = source.fd, .events = source_poll_events, .revents = 0 };
            count += 1;
        }

        _ = try posix.poll(pollfds[0..count], -1);
        if ((pollfds[listen_index].revents & posix.POLL.IN) != 0) {
            const fd = c.accept(listen_fd, null, null);
            if (fd < 0) return error.AcceptFailed;
            return fd;
        }

        for (options.sources[0..options.source_count], 0..) |source, source_index| {
            const poll_index = source_poll_indices[source_index] orelse continue;
            if (pollfds[poll_index].revents != 0) {
                try readStreamSource(state, source);
            }
        }
        try drainStreamSourcesNonBlocking(state, options);
    }
}

/// Runs in the local `sessh` process. `start_transport` creates ssh transports
/// that execute the visible `:internal-stream-broker:` entrypoint remotely; this
/// loop owns local stdin/stdout and the reconnect policy.
pub fn runLocalStream(
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: LocalStreamOptions,
) !u8 {
    const Starter = @TypeOf(start_transport);
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    const Pending = PendingReplacement(Starter, Transport);

    var state = StreamState.init(
        allocator,
        .{ .stdin = true },
        .{ .stdout = true },
    );
    defer state.deinit();
    var input_control = StreamInputControl{
        .enabled = options.intercept_ctrl_r,
        .escape_enabled = options.intercept_escape,
    };
    var reconnect_status = StreamReconnectStatus.init(options.status_mode, options.intercept_ctrl_r, options.title_fallback);
    defer reconnect_status.deinit();
    var local_interrupt = try LocalStreamInterrupt.install();
    defer local_interrupt.deinit();

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
                const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control, &local_interrupt);
                if (action == .disconnect) return 0;
                if (action == .interrupt) return 255;
                attempt = reconnect.nextAttempt(attempt, action == .reconnect);
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
                    .sinks = localStreamSinks(options.sink_fd),
                    .reconnect_status = &reconnect_status,
                    // Once the remote side closes its output stream there is
                    // no peer left to consume local input, so close the local
                    // outbound side too.
                    .close_outbound_on_inbound_eof = true,
                },
            ) catch {
                transport.close();
                retrying = true;
                continue :client_loop;
            };
            var old_unresponsive = false;
            while (true) {
                attachment.external_wakeup_fd = if (pending) |*replacement| replacement.notifyFd() else -1;
                attachment.interrupt_fd = local_interrupt.read_fd;
                const outcome = attachment.step(-1) catch .transport_closed;
                switch (outcome) {
                    .complete => {
                        transport.close();
                        return 0;
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
                                const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control, &local_interrupt);
                                if (action == .disconnect) return 0;
                                if (action == .interrupt) return 255;
                                attempt = reconnect.nextAttempt(attempt, action == .reconnect);
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
                    .interrupted => {
                        local_interrupt.consume();
                        abortTransport(&transport);
                        return 255;
                    },
                    .replacement => |fd| {
                        _ = c.close(fd);
                    },
                    .idle => {},
                }
                switch (input_control.consumeAction()) {
                    .disconnect => {
                        abortTransport(&transport);
                        return 0;
                    },
                    .reconnect => if (old_unresponsive and pending == null) {
                        pending = Pending.start(allocator, start_transport) catch |err| {
                            client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                            continue;
                        };
                        reconnect_status.showReconnecting();
                        input_control.status_visible = true;
                    },
                    .help => reconnect_status.showEscapeHelp(),
                    .none => {},
                    .interrupt => unreachable,
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
                                    const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control, &local_interrupt);
                                    if (action == .disconnect) return 0;
                                    if (action == .interrupt) return 255;
                                    attempt = reconnect.nextAttempt(attempt, action == .reconnect);
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
                var pollfds: [3]posix.pollfd = undefined;
                var count: usize = 0;
                pollfds[count] = .{ .fd = replacement.notifyFd(), .events = posix.POLL.IN, .revents = 0 };
                count += 1;
                const interrupt_index = count;
                pollfds[count] = .{ .fd = local_interrupt.read_fd, .events = posix.POLL.IN, .revents = 0 };
                count += 1;
                var input_index: ?usize = null;
                if (reconnectInputPollEnabled(&input_control)) {
                    input_index = count;
                    pollfds[count] = .{ .fd = options.source_fd, .events = posix.POLL.IN, .revents = 0 };
                    count += 1;
                }

                _ = posix.poll(pollfds[0..count], -1) catch {};
                if (pollfds[interrupt_index].revents != 0) {
                    local_interrupt.consume();
                    return 255;
                }
                if (input_index) |index| {
                    if (pollfds[index].revents != 0) {
                        switch (readReconnectInput(&state, options.source_fd, &input_control)) {
                            .disconnect => return 0,
                            .help => reconnect_status.showEscapeHelp(),
                            .none, .reconnect => {},
                            .interrupt => unreachable,
                        }
                    }
                }
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
        const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &input_control, &local_interrupt);
        if (action == .disconnect) return 0;
        if (action == .interrupt) return 255;
        attempt = reconnect.nextAttempt(attempt, action == .reconnect);
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
            .interrupted => return .transport_closed,
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
        .proxy_stream_resume => {
            var message = try protocol.decodePayload(pb.ProxyStreamResume, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            state.peer_ready = true;
            try handleResumeOffset(state, try singleActiveChannel(state.active_outbound), message.recv_next_offset);
            sendPending(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .proxy_stream_ack => {
            var message = try protocol.decodePayload(pb.ProxyStreamAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try handleAck(state, try singleActiveChannel(state.active_outbound), message.offset);
        },
        .proxy_stream_eof_ack => {
            var message = try protocol.decodePayload(pb.ProxyStreamEofAck, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try handleEofAck(state, try singleActiveChannel(state.active_outbound), message.offset);
        },
        .proxy_stream_data => {
            var message = try protocol.decodePayload(pb.ProxyStreamData, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try handleInboundData(
                state,
                transport_write_fd,
                options,
                try singleActiveChannel(state.active_inbound),
                message.offset,
                message.data,
            );
        },
        .proxy_stream_eof => {
            var message = try protocol.decodePayload(pb.ProxyStreamEof, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try handleInboundEof(
                state,
                transport_write_fd,
                options,
                try singleActiveChannel(state.active_inbound),
                message.offset,
            );
        },
        .ping, .pong => {
            _ = protocol.handleTransportControlFrame(mutable.message_type, mutable.payload, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        else => return error.StreamUnexpectedFrame,
    }
}

fn handleResumeOffset(state: *StreamState, channel: StreamChannel, offset: u64) !void {
    if (!state.active_outbound.contains(channel)) return error.StreamInactiveChannel;
    const channel_state = state.channel(channel);
    channel_state.peer_recv = offset;
    try state.dropOutboundThrough(channel, offset);
    channel_state.outbound_sent_next = offset;
}

fn handleAck(state: *StreamState, channel: StreamChannel, offset: u64) !void {
    if (!state.active_outbound.contains(channel)) return error.StreamInactiveChannel;
    const channel_state = state.channel(channel);
    channel_state.peer_recv = offset;
    try state.dropOutboundThrough(channel, offset);
    if (channel_state.outbound_sent_next < offset) channel_state.outbound_sent_next = offset;
}

fn handleEofAck(state: *StreamState, channel: StreamChannel, offset: u64) !void {
    try handleAck(state, channel, offset);
    const channel_state = state.channel(channel);
    if (offset == channel_state.outboundNext()) channel_state.outbound_eof_acked = true;
}

fn handleInboundData(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachmentOptions,
    channel: StreamChannel,
    offset: u64,
    data: []const u8,
) !void {
    if (!state.active_inbound.contains(channel)) return error.StreamInactiveChannel;
    const channel_state = state.channel(channel);
    const sink = options.sink(channel);
    if (offset < channel_state.recv_next_offset) {
        // Reconnect retransmits from the peer's last confirmed offset. If a
        // frame overlaps bytes already delivered, keep only the new suffix.
        const already_received: usize = @intCast(channel_state.recv_next_offset - offset);
        if (already_received < data.len) {
            const new_data = data[already_received..];
            if (sink.fd < 0) return error.StreamSinkClosed;
            try deliverInboundData(options, channel, sink.fd, new_data);
            channel_state.recv_next_offset += new_data.len;
        }
        sendAckForChannel(state, transport_write_fd, channel, channel_state.recv_next_offset) catch |err| switch (err) {
            error.WriteFailed => return error.StreamTransportWriteFailed,
            else => return err,
        };
        return;
    }
    if (offset != channel_state.recv_next_offset) return error.StreamOffsetGap;
    if (data.len != 0 and sink.fd < 0) return error.StreamSinkClosed;
    if (data.len != 0) try deliverInboundData(options, channel, sink.fd, data);
    channel_state.recv_next_offset += data.len;
    sendAckForChannel(state, transport_write_fd, channel, channel_state.recv_next_offset) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTransportWriteFailed,
        else => return err,
    };
}

fn handleInboundEof(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachmentOptions,
    channel: StreamChannel,
    offset: u64,
) !void {
    if (!state.active_inbound.contains(channel)) return error.StreamInactiveChannel;
    const channel_state = state.channel(channel);
    if (offset > channel_state.recv_next_offset) return error.StreamOffsetGap;
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
    sendEofAckForChannel(state, transport_write_fd, channel, channel_state.recv_next_offset) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTransportWriteFailed,
        else => return err,
    };
}

fn deliverInboundData(options: *const StreamAttachmentOptions, channel: StreamChannel, sink_fd: c.fd_t, bytes: []const u8) !void {
    if (options.reconnect_status) |status| status.observeInbound(channel, bytes);
    try io.writeAll(sink_fd, bytes);
}

fn sendResumeMessage(state: *StreamState, fd: c.fd_t) !void {
    const channel = try singleActiveChannel(state.active_inbound);
    try sendStreamMessage(state.allocator, fd, .proxy_stream_resume, pb.ProxyStreamResume{
        .recv_next_offset = state.constChannel(channel).recv_next_offset,
    });
}

fn sendAckForChannel(state: *StreamState, fd: c.fd_t, channel: StreamChannel, offset: u64) !void {
    if (channel != try singleActiveChannel(state.active_inbound)) return error.StreamInvalidChannel;
    try sendStreamMessage(state.allocator, fd, .proxy_stream_ack, pb.ProxyStreamAck{
        .offset = offset,
    });
}

fn sendEofAckForChannel(state: *StreamState, fd: c.fd_t, channel: StreamChannel, offset: u64) !void {
    if (channel != try singleActiveChannel(state.active_inbound)) return error.StreamInvalidChannel;
    try sendStreamMessage(state.allocator, fd, .proxy_stream_eof_ack, pb.ProxyStreamEofAck{
        .offset = offset,
    });
}

fn sendDataForChannel(
    state: *StreamState,
    fd: c.fd_t,
    channel: StreamChannel,
    offset: u64,
    data: []const u8,
) !void {
    if (channel != try singleActiveChannel(state.active_outbound)) return error.StreamInvalidChannel;
    try sendStreamMessage(state.allocator, fd, .proxy_stream_data, pb.ProxyStreamData{
        .offset = offset,
        .data = data,
    });
}

fn sendEofForChannel(state: *StreamState, fd: c.fd_t, channel: StreamChannel, offset: u64) !void {
    if (channel != try singleActiveChannel(state.active_outbound)) return error.StreamInvalidChannel;
    try sendStreamMessage(state.allocator, fd, .proxy_stream_eof, pb.ProxyStreamEof{
        .offset = offset,
    });
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
        // transport. On a replacement transport, the resume frame resets
        // outbound_sent_next to the peer's reported receive offset, which is
        // when retransmission is needed.
        var index: usize = @intCast(channel_state.outbound_sent_next - channel_state.outbound_base);
        while (index < channel_state.outbound.items.len) {
            const len = @min(max_chunk_bytes, channel_state.outbound.items.len - index);
            const offset = channel_state.outbound_base + index;
            try sendDataForChannel(state, transport_write_fd, channel, offset, channel_state.outbound.items[index .. index + len]);
            index += len;
            channel_state.outbound_sent_next = offset + len;
        }
        if (channel_state.outbound_eof and !channel_state.outbound_eof_acked and !channel_state.outbound_eof_sent) {
            try sendEofForChannel(state, transport_write_fd, channel, channel_state.outboundNext());
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
    eof,
};

fn readSome(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .eof;
        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            else => return error.StreamReadFailed,
        }
    }
}

fn readSomeNonBlocking(fd: c.fd_t, buf: []u8) !ReadSomeResult {
    const original_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (original_flags < 0) return error.StreamReadFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    const changed_flags = (original_flags & nonblocking_flag) == 0;
    if (changed_flags and c.fcntl(fd, c.F.SETFL, original_flags | nonblocking_flag) < 0) return error.StreamReadFailed;
    defer {
        if (changed_flags) _ = c.fcntl(fd, c.F.SETFL, original_flags);
    }

    return readSome(fd, buf);
}

fn connectOrStartAgent(
    allocator: std.mem.Allocator,
    exe: []const u8,
    agent_args: []const []const u8,
    socket_path: []const u8,
) !c.fd_t {
    if (socket_transport.connectSocket(socket_path)) |fd| return fd else |_| {}

    if (agent_args.len != 7) return error.InvalidStreamArgs;
    const argv = [_][]const u8{
        exe,
        ":internal-stream-agent:",
        agent_args[0],
        socket_path,
        agent_args[1],
        agent_args[2],
        agent_args[3],
        agent_args[4],
        agent_args[5],
        agent_args[6],
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
    if (args.len != 7) {
        try io.writeAll(2, "sessh: :internal-stream-broker: requires GUID MODE ROWS COLS HOST PORT -\n");
        return error.InvalidStreamArgs;
    }
    const mode: StreamMode = if (std.mem.eql(u8, args[1], "proxy"))
        .proxy
    else
        return error.InvalidStreamMode;

    if (!session_registry.isValidProxyGuid(args[0])) return error.InvalidStreamGuid;

    _ = try parseDimension(args[2]);
    _ = try parseDimension(args[3]);
    const proxy_host = try decodeCommandArg(allocator, args[4]) orelse return error.InvalidStreamArgs;
    errdefer allocator.free(proxy_host);
    const proxy_port = try parsePort(args[5]);
    if (!std.mem.eql(u8, args[6], "-")) return error.InvalidStreamArgs;
    return .{
        .guid = args[0],
        .mode = mode,
        .proxy_host = proxy_host,
        .proxy_port = proxy_port,
    };
}

fn parseDimension(value: []const u8) !u16 {
    const parsed = try std.fmt.parseInt(u16, value, 10);
    return @max(parsed, 1);
}

fn parsePort(value: []const u8) !u16 {
    const parsed = try std.fmt.parseInt(u16, value, 10);
    if (parsed == 0) return error.InvalidStreamArgs;
    return parsed;
}

fn decodeCommandArg(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.eql(u8, value, "-")) return null;
    const len = try std.base64.standard.Decoder.calcSizeForSlice(value);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, value);
    return out;
}

fn startStreamEndpoint(allocator: std.mem.Allocator, config: StreamAgentConfig) !ProxyEndpoint {
    return switch (config.mode) {
        .proxy => try ProxyEndpoint.connect(allocator, config.proxy_host.?, config.proxy_port),
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
    interrupt: ?*LocalStreamInterrupt,
) StreamControlAction {
    var remaining_ms = delay_ms;
    while (remaining_ms > 0) {
        status.showRetry(remaining_ms);
        input_control.status_visible = true;
        const step_ms = @min(remaining_ms, 1_000);
        const action = pollReconnectInput(state, source_fd, input_control, interrupt, @intCast(step_ms));
        if (action == .help) {
            status.showEscapeHelp();
            continue;
        }
        if (action != .none) return action;
        remaining_ms -= step_ms;
        status.flushDiagnostics();
    }
    const action = input_control.consumeAction();
    if (action == .help) {
        status.showEscapeHelp();
        return .none;
    }
    return action;
}

fn pollReconnectInput(
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
    interrupt: ?*LocalStreamInterrupt,
    timeout_ms: i32,
) StreamControlAction {
    var pollfds: [2]posix.pollfd = undefined;
    var count: usize = 0;
    var interrupt_index: ?usize = null;
    if (interrupt) |local_interrupt| {
        if (local_interrupt.read_fd >= 0) {
            interrupt_index = count;
            pollfds[count] = .{ .fd = local_interrupt.read_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
    }
    var input_index: ?usize = null;
    if (reconnectInputPollEnabled(input_control)) {
        input_index = count;
        pollfds[count] = .{ .fd = source_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
    }

    if (count == 0) {
        if (timeout_ms > 0) io.sleepMillis(@intCast(timeout_ms));
        return input_control.consumeAction();
    }
    const ready = posix.poll(pollfds[0..count], timeout_ms) catch return input_control.consumeAction();
    if (ready == 0) return input_control.consumeAction();
    if (interrupt_index) |index| {
        if (pollfds[index].revents != 0) {
            if (interrupt) |local_interrupt| local_interrupt.consume();
            return .interrupt;
        }
    }
    if (input_index) |index| {
        if (pollfds[index].revents != 0) {
            return readReconnectInput(state, source_fd, input_control);
        }
    }
    return input_control.consumeAction();
}

fn reconnectInputPollEnabled(input_control: *const StreamInputControl) bool {
    return (input_control.enabled or input_control.escape_enabled) and input_control.status_visible;
}

fn readReconnectInput(
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
) StreamControlAction {
    var buf: [max_chunk_bytes]u8 = undefined;
    const n = c.read(source_fd, &buf, buf.len);
    if (n <= 0) {
        state.channel(stream_channel_stdin).outbound_eof = true;
    } else {
        var filtered: [max_chunk_bytes]u8 = undefined;
        const filtered_bytes = input_control.filter(buf[0..@intCast(n)], &filtered);
        state.appendOutbound(stream_channel_stdin, filtered_bytes) catch {};
    }
    return input_control.consumeAction();
}

const TerminalTitleTracker = struct {
    const max_title_bytes = 512;
    const State = enum {
        ground,
        escape,
        csi,
        osc_command,
        osc_text,
        osc_escape,
        string,
        string_escape,
    };

    state: State = .ground,
    osc_command: [8]u8 = [_]u8{0} ** 8,
    osc_command_len: usize = 0,
    tracking_title: bool = false,
    title: [max_title_bytes]u8 = [_]u8{0} ** max_title_bytes,
    title_len: usize = 0,
    title_present: bool = false,
    pending_title: [max_title_bytes]u8 = [_]u8{0} ** max_title_bytes,
    pending_title_len: usize = 0,
    csi_bytes: [32]u8 = [_]u8{0} ** 32,
    csi_len: usize = 0,
    synchronized_update_active: bool = false,

    fn observe(self: *TerminalTitleTracker, bytes: []const u8) void {
        for (bytes) |byte| self.observeByte(byte);
    }

    fn safeForLocalTitle(self: *const TerminalTitleTracker) bool {
        // A finished `CSI ? 2026 h` leaves the parser in ground state, but the
        // terminal is still inside a synchronized update. Title changes made
        // there can be held back by the terminal until the matching `l`, so the
        // reconnect UI treats that interval as unsafe too.
        return self.state == .ground and !self.synchronized_update_active;
    }

    fn titlePresent(self: *const TerminalTitleTracker) bool {
        return self.title_present;
    }

    fn titleSlice(self: *const TerminalTitleTracker) []const u8 {
        return self.title[0..self.title_len];
    }

    fn observeByte(self: *TerminalTitleTracker, byte: u8) void {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) self.state = .escape;
            },
            .escape => switch (byte) {
                '[' => {
                    self.state = .csi;
                    self.csi_len = 0;
                },
                ']' => {
                    self.state = .osc_command;
                    self.osc_command_len = 0;
                    self.tracking_title = false;
                    self.pending_title_len = 0;
                },
                'P', '^', '_', 'X' => self.state = .string,
                else => self.state = .ground,
            },
            .csi => {
                if (byte == 0x1b) {
                    self.state = .escape;
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    self.finishCsi(byte);
                    self.state = .ground;
                } else if (self.csi_len < self.csi_bytes.len) {
                    self.csi_bytes[self.csi_len] = byte;
                    self.csi_len += 1;
                }
            },
            .osc_command => {
                if (byte == 0x07) {
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                } else if (byte == ';') {
                    self.tracking_title = self.isTitleCommand();
                    self.pending_title_len = 0;
                    self.state = .osc_text;
                } else if (self.osc_command_len < self.osc_command.len) {
                    self.osc_command[self.osc_command_len] = byte;
                    self.osc_command_len += 1;
                }
            },
            .osc_text => {
                if (byte == 0x07) {
                    self.finishOsc();
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                } else {
                    self.appendPendingTitle(byte);
                }
            },
            .osc_escape => {
                if (byte == '\\') {
                    self.finishOsc();
                    self.state = .ground;
                } else {
                    self.appendPendingTitle(0x1b);
                    self.appendPendingTitle(byte);
                    self.state = .osc_text;
                }
            },
            .string => {
                if (byte == 0x1b) self.state = .string_escape;
            },
            .string_escape => {
                self.state = if (byte == '\\') .ground else .string;
            },
        }
    }

    fn isTitleCommand(self: *const TerminalTitleTracker) bool {
        const command = self.osc_command[0..self.osc_command_len];
        return std.mem.eql(u8, command, "0") or std.mem.eql(u8, command, "2");
    }

    fn appendPendingTitle(self: *TerminalTitleTracker, byte: u8) void {
        if (!self.tracking_title) return;
        if (self.pending_title_len >= self.pending_title.len) return;
        self.pending_title[self.pending_title_len] = byte;
        self.pending_title_len += 1;
    }

    fn finishOsc(self: *TerminalTitleTracker) void {
        if (!self.tracking_title) return;
        @memcpy(self.title[0..self.pending_title_len], self.pending_title[0..self.pending_title_len]);
        self.title_len = self.pending_title_len;
        self.title_present = true;
    }

    fn finishCsi(self: *TerminalTitleTracker, final_byte: u8) void {
        const params = self.csi_bytes[0..self.csi_len];
        if (std.mem.eql(u8, params, "?2026")) {
            if (final_byte == 'h') self.synchronized_update_active = true;
            if (final_byte == 'l') self.synchronized_update_active = false;
        }
    }
};

// Stream reconnect UI must keep application bytes clean. When stdout is a
// terminal a caller may use the window title for reconnect status; otherwise it
// may allow append-only stderr lines. Title mode tracks app OSC titles in the
// byte stream so reconnect status can be restored without inventing a second UI
// channel.
const StreamReconnectStatus = struct {
    const max_diagnostic_lines = 3;
    const max_title_fallback_bytes = 512;

    fd: c.fd_t,
    mode: StreamReconnectStatusMode,
    line: [96]u8 = undefined,
    line_len: usize = 0,
    ctrl_r_enabled: bool,
    diagnostic_cursor: u64,
    live_diagnostic_start_seq: u64,
    rendered_diagnostic_seq: u64,
    title_visible: bool = false,
    escape_help_pending: bool = false,
    title_tracker: TerminalTitleTracker = .{},
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,

    fn init(mode: StreamReconnectStatusMode, ctrl_r_enabled: bool, title_fallback: []const u8) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = StreamReconnectStatus{
            .fd = if (mode == .title) 1 else 2,
            .mode = mode,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
        status.title_fallback_len = copyTitle(&status.title_fallback, title_fallback);
        return status;
    }

    fn initForTest(fd: c.fd_t, mode: StreamReconnectStatusMode, ctrl_r_enabled: bool, title_fallback: []const u8) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = StreamReconnectStatus{
            .fd = fd,
            .mode = mode,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
        };
        status.title_fallback_len = copyTitle(&status.title_fallback, title_fallback);
        return status;
    }

    fn deinit(self: *StreamReconnectStatus) void {
        self.clear();
    }

    fn showRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        const message = reconnect_title.retryStatus(&self.line, delay_ms, .{
            .ctrl_r = self.ctrl_r_enabled,
            .ctrl_c_detach = false,
        }) catch return;
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writeTitleRetry(delay_ms);
        self.writePlainStatusLine();
    }

    fn showReconnecting(self: *StreamReconnectStatus) void {
        const message = reconnect_title.reconnectingStatus(.{
            .ctrl_r = self.ctrl_r_enabled,
            .ctrl_c_detach = false,
        });
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writeTitleReconnecting();
        self.writePlainStatusLine();
    }

    fn clear(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics();
        self.restoreTitle();
    }

    fn flushDiagnostics(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics();
    }

    fn showEscapeHelp(self: *StreamReconnectStatus) void {
        switch (self.mode) {
            .title => {
                if (!self.canWriteTitle()) {
                    // Direct stream UI shares the terminal with remote output.
                    // If the remote stream is mid-control-sequence, wait until
                    // the parser reaches a safe point before writing local help.
                    self.escape_help_pending = true;
                    return;
                }
                self.writeEscapeHelpText();
            },
            .stderr_plain => self.writeEscapeHelpText(),
            .disabled => {},
        }
    }

    fn writePlainStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\n") catch return;
    }

    fn writeTitleRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeRetryNowTitle(self.fd, delay_ms) catch return;
        } else {
            reconnect_title.writeRetryTitle(self.fd, delay_ms) catch return;
        }
        self.title_visible = true;
    }

    fn writeTitleReconnecting(self: *StreamReconnectStatus) void {
        if (!self.canWriteTitle()) return;
        if (self.ctrl_r_enabled) {
            reconnect_title.writeReconnectingNowTitle(self.fd) catch return;
        } else {
            reconnect_title.writeReconnectingTitle(self.fd) catch return;
        }
        self.title_visible = true;
    }

    fn canWriteTitle(self: *const StreamReconnectStatus) bool {
        return self.mode == .title and self.fd >= 0 and self.title_tracker.safeForLocalTitle();
    }

    fn restoreTitle(self: *StreamReconnectStatus) void {
        if (!self.title_visible or self.mode != .title or self.fd < 0) return;
        const title = if (self.title_tracker.titlePresent())
            self.title_tracker.titleSlice()
        else
            self.title_fallback[0..self.title_fallback_len];
        reconnect_title.writeTitle(self.fd, title) catch {};
        self.title_visible = false;
    }

    fn observeInbound(self: *StreamReconnectStatus, channel: StreamChannel, bytes: []const u8) void {
        if (channel != stream_channel_stdout or self.mode != .title) return;
        self.title_tracker.observe(bytes);
        if (self.escape_help_pending and self.canWriteTitle()) self.writeEscapeHelpText();
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

    fn writeEscapeHelpText(self: *StreamReconnectStatus) void {
        if (self.fd < 0) return;
        self.escape_help_pending = false;
        io.writeAll(self.fd, "\r\n") catch return;
        inline for (terminal.escape_help_lines) |line| {
            io.writeAll(self.fd, line) catch return;
            io.writeAll(self.fd, "\r\n") catch return;
        }
    }
};

fn copyTitle(dest: []u8, title: []const u8) usize {
    const len = @min(dest.len, title.len);
    @memcpy(dest[0..len], title[0..len]);
    return len;
}

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

test "proxy stream config uses proxy guid and tcp target" {
    var config = try parseStreamAgentConfig(std.testing.allocator, &.{
        "p-550e8400-e29b-41d4-a716-446655440000",
        "proxy",
        "1",
        "1",
        "bG9jYWxob3N0",
        "22",
        "-",
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(StreamMode.proxy, config.mode);
    try std.testing.expectEqualStrings("localhost", config.proxy_host.?);
    try std.testing.expectEqual(@as(u16, 22), config.proxy_port);

    try std.testing.expectError(error.InvalidStreamGuid, parseStreamAgentConfig(std.testing.allocator, &.{
        "s-550e8400-e29b-41d4-a716-446655440000",
        "proxy",
        "1",
        "1",
        "bG9jYWxob3N0",
        "22",
        "-",
    }));
    try std.testing.expectError(error.InvalidStreamMode, parseStreamAgentConfig(std.testing.allocator, &.{
        "p-550e8400-e29b-41d4-a716-446655440000",
        "tty",
        "1",
        "1",
        "-",
        "-",
        "-",
    }));
}

test "stream frames round trip through a pipe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try sendStreamMessage(std.testing.allocator, fds[1], .proxy_stream_data, pb.ProxyStreamData{
        .offset = 42,
        .data = "hello",
    });
    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(protocol.MessageType.proxy_stream_data, frame.message_type);
    var message = try protocol.decodePayload(pb.ProxyStreamData, std.testing.allocator, frame.payload);
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), message.offset);
    try std.testing.expectEqualStrings("hello", message.data);
}

test "stream ping receives pong without changing offsets" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{ .stdout = true });
    defer state.deinit();
    const payload = try protocol.encodePayload(std.testing.allocator, pb.Ping{});
    const options = StreamAttachmentOptions{};
    try handleFrame(&state, fds[1], &options, .{
        .message_type = .ping,
        .payload = payload,
    });

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.pong, frame.message_type);
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
    try std.testing.expectEqual(protocol.MessageType.proxy_stream_data, first_frame.message_type);
    var first = try protocol.decodePayload(pb.ProxyStreamData, std.testing.allocator, first_frame.payload);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), first.offset);
    try std.testing.expectEqualStrings("first", first.data);

    try state.appendOutbound(stream_channel_stdin, "second");
    try sendPending(&state, fds[1]);
    var second_frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
    defer second_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.proxy_stream_data, second_frame.message_type);
    var second = try protocol.decodePayload(pb.ProxyStreamData, std.testing.allocator, second_frame.payload);
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

    var state = StreamState.init(std.testing.allocator, .{}, .{ .stdout = true });
    defer state.deinit();
    state.channel(stream_channel_stdout).recv_next_offset = 5;

    const payload = try protocol.encodePayload(std.testing.allocator, pb.ProxyStreamData{
        .offset = 0,
        .data = "firstsecond",
    });
    var options = StreamAttachmentOptions{};
    options.sinks[channelIndex(stream_channel_stdout)] = .{ .fd = sink[1] };
    try handleFrame(&state, ack[1], &options, .{
        .message_type = .proxy_stream_data,
        .payload = payload,
    });

    var delivered: [6]u8 = undefined;
    try io.readExact(sink[0], &delivered);
    try std.testing.expectEqualStrings("second", delivered[0..]);

    var ack_frame = try protocol.readFrameAlloc(std.testing.allocator, ack[0]);
    defer ack_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.proxy_stream_ack, ack_frame.message_type);
    var ack_message = try protocol.decodePayload(pb.ProxyStreamAck, std.testing.allocator, ack_frame.payload);
    defer ack_message.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 11), ack_message.offset);
}

test "stream inbound eof promptly flushes generated outbound eof" {
    const transport_in = try posix.pipe();
    defer posix.close(transport_in[0]);
    defer posix.close(transport_in[1]);
    const transport_out = try posix.pipe();
    defer posix.close(transport_out[0]);
    defer posix.close(transport_out[1]);

    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{ .stdout = true });
    defer state.deinit();
    state.peer_ready = true;

    const payload = try protocol.encodePayload(std.testing.allocator, pb.ProxyStreamEof{
        .offset = 0,
    });
    defer std.testing.allocator.free(payload);
    try protocol.sendFrame(transport_in[1], .proxy_stream_eof, payload);

    var attachment = StreamAttachment{
        .state = &state,
        .transport_read_fd = transport_in[0],
        .transport_write_fd = transport_out[1],
        .options = .{
            .close_outbound_on_inbound_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };

    try std.testing.expectEqual(StreamStepOutcome.progress, try attachment.step(1_000));

    var ack_frame = try protocol.readFrameAlloc(std.testing.allocator, transport_out[0]);
    defer ack_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.proxy_stream_eof_ack, ack_frame.message_type);

    var pollfds = [_]posix.pollfd{.{
        .fd = transport_out[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 0));

    var eof_frame = try protocol.readFrameAlloc(std.testing.allocator, transport_out[0]);
    defer eof_frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.proxy_stream_eof, eof_frame.message_type);
    var eof = try protocol.decodePayload(pb.ProxyStreamEof, std.testing.allocator, eof_frame.payload);
    defer eof.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), eof.offset);
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

test "stream input control intercepts only reconnect UI controls" {
    var control = StreamInputControl{
        .enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("ab", control.filter("a\x12b", &out));
    try std.testing.expectEqual(StreamControlAction.reconnect, control.consumeAction());

    try std.testing.expectEqualStrings("\x03", control.filter("\x03", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());

    control.status_visible = false;
    try std.testing.expectEqualStrings("\x12", control.filter("\x12", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}

test "stream input control uses ssh escape to disconnect no-terminal-emulator streams" {
    var control = StreamInputControl{
        .enabled = true,
        .escape_enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("", control.filter("~.", &out));
    try std.testing.expectEqual(StreamControlAction.disconnect, control.consumeAction());
}

test "stream input control supports ssh help and doubled tilde escapes" {
    var control = StreamInputControl{
        .enabled = true,
        .escape_enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("", control.filter("~?", &out));
    try std.testing.expectEqual(StreamControlAction.help, control.consumeAction());

    try std.testing.expectEqualStrings("~hello", control.filter("~~hello", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
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

    var pollfds = [_]posix.pollfd{.{
        .fd = pending.notifyFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 1_000));

    var completed = pending.takeIfDone() orelse return error.PendingReplacementDidNotFinish;
    defer cleanupReplacementResult(TestTransport, &completed);

    switch (completed) {
        .ready => try std.testing.expect(!closed),
        .failed => return error.UnexpectedPendingReplacementFailure,
    }
}

test "pending stream replacement notifies failed preparation" {
    const TestTransport = struct {
        fn close(_: *@This()) void {}
    };
    const TestStarter = struct {
        fn start(_: *@This()) !TestTransport {
            return error.TestReplacementFailed;
        }
    };

    var starter = TestStarter{};
    const Pending = PendingReplacement(*TestStarter, TestTransport);
    var pending = try Pending.start(std.testing.allocator, &starter);

    var pollfds = [_]posix.pollfd{.{
        .fd = pending.notifyFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 1_000));

    var completed = pending.takeIfDone() orelse return error.PendingReplacementDidNotFinish;
    defer cleanupReplacementResult(TestTransport, &completed);

    switch (completed) {
        .ready => return error.UnexpectedPendingReplacementSuccess,
        .failed => |err| try std.testing.expectEqual(error.TestReplacementFailed, err),
    }
}

test "stream completion waits for eof acknowledgement" {
    var state = StreamState.init(std.testing.allocator, .{ .stdin = true }, .{});
    defer state.deinit();
    state.channel(stream_channel_stdin).outbound_eof = true;

    try std.testing.expect(!state.complete());

    const payload = try protocol.encodePayload(std.testing.allocator, pb.ProxyStreamEofAck{
        .offset = 0,
    });
    const options = StreamAttachmentOptions{};
    try handleFrame(&state, -1, &options, .{
        .message_type = .proxy_stream_eof_ack,
        .payload = payload,
    });
    try std.testing.expect(state.complete());
}

test "stream reconnect status uses plain stderr lines" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .stderr_plain, false, "");
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

test "disabled stream reconnect status emits no UI" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .disabled, true, "test-host");
    status.showRetry(1_000);
    status.showReconnecting();
    status.showEscapeHelp();
    status.clear();
    posix.close(fds[1]);

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "stream reconnect status restores tracked application title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound(stream_channel_stdout, "\x1b]2;remote");
    status.observeInbound(stream_channel_stdout, "-title\x1b\\");
    status.showRetry(10_000);
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
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;remote-title\x1b\\",
        output.items,
    );
}

test "stream reconnect status uses fallback title when app set none" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.showRetry(10_000);
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
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output.items,
    );
}

test "stream reconnect status skips title while terminal parser is unsafe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound(stream_channel_stdout, "\x1b]2;partial-title");
    status.showRetry(10_000);
    status.clear();
    posix.close(fds[1]);

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "stream escape help waits for terminal parser safe point" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    try setNonBlockingFd(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound(stream_channel_stdout, "\x1b]2;partial-title");
    status.showEscapeHelp();

    var empty_buf: [16]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &empty_buf));

    status.observeInbound(stream_channel_stdout, "\x1b\\");
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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Supported escape sequences") != null);
}

test "stream reconnect status treats synchronized update as unsafe for title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound(stream_channel_stdout, "\x1b[?2026h");
    status.showRetry(10_000);
    status.clear();
    status.observeInbound(stream_channel_stdout, "\x1b[?2026l");
    status.showRetry(10_000);
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
        "\x1b]2;10sec retry CTRL-R\x1b\\\x1b]2;test-host\x1b\\",
        output.items,
    );
}

test "stream reconnect status renders ssh diagnostics before status" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .stderr_plain, false, "");
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
    var status = StreamReconnectStatus.initForTest(fds[1], .stderr_plain, false, "");
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
