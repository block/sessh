// Proxy-stream worker and reconnect loop. It keeps OpenSSH's byte stream clean
// while bridging raw proxy bytes through the daemon tunnel and presenting
// diagnostics on a separate local channel when available.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const core_blocking = @import("../core/blocking.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const poll_sets = @import("../core/poll_set.zig");
const app_allocator = @import("../core/app_allocator.zig");
const non_suspending_timer = @import("../core/non_suspending_timer.zig");
const daemon_log = @import("../daemon/log.zig");
const protocol = @import("../protocol/mod.zig");
const protocol_test_helpers = if (builtin.is_test) @import("../protocol/test_helpers.zig") else struct {};
const dispatch_io = @import("../core/dispatch_io.zig");
const client_log = @import("../core/client_log.zig");
const proxy_diagnostics = @import("proxy_diagnostics_channel.zig");
const reconnect = @import("../reconnect/mod.zig");
const byte_stream = @import("byte_stream.zig");
const local_stream_interrupt = @import("local_stream_interrupt.zig");
const mux_proxy = @import("mux_proxy.zig");
const proxy_remote = @import("proxy_remote.zig");
const raw_bridge = @import("raw_bridge.zig");
const status_output = @import("status_output.zig");
const stream_input_control = @import("stream_input_control.zig");
const stream_liveness = @import("stream_liveness.zig");
const pb = protocol.pb;

const max_buffered_bytes = 1024 * 1024;
const max_chunk_bytes = 16 * 1024;
const proxy_mux_stream_id: u64 = 1;
const StreamState = byte_stream.StreamState;
const StreamInputControl = stream_input_control.StreamInputControl;
const StreamControlAction = stream_input_control.StreamControlAction;
const StreamLiveness = stream_liveness.StreamLiveness;
const LocalStreamInterrupt = local_stream_interrupt.LocalStreamInterrupt;
const ReadSomeResult = io.ReadSomeResult;

const ProxyDataPayload = struct {
    offset: u64,
    data: []const u8,
};

const StreamOutcome = union(enum) {
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

pub const StreamReconnectStatusMode = status_output.Mode;
pub const forwardRawDuplex = raw_bridge.forwardRawDuplex;
pub const ProxyMuxContext = mux_proxy.ProxyMuxContext;
pub const ProxyMuxStream = mux_proxy.ProxyMuxStream;
pub const closeProxyMuxStreams = mux_proxy.closeProxyMuxStreams;
pub const closeProxyMuxStream = mux_proxy.closeProxyMuxStream;
pub const handleProxyMuxStreamFrame = mux_proxy.handleProxyMuxStreamFrame;
pub const handleProxyMuxOpen = mux_proxy.handleProxyMuxOpen;
pub const forwardProxyRemoteFrameToMux = mux_proxy.forwardProxyRemoteFrameToMux;
pub const handleProxyRemoteControlFrame = mux_proxy.handleProxyRemoteControlFrame;
pub const findProxyMuxStreamIndex = mux_proxy.findProxyMuxStreamIndex;
pub const findProxyMuxStreamIndexBySource = mux_proxy.findProxyMuxStreamIndexBySource;
pub const drainProxyProcessWrites = mux_proxy.drainProxyProcessWrites;
const StreamReconnectStatus = status_output.Status;

const LocalStreamFds = struct {
    source: c.fd_t,
    sink: c.fd_t,
};

pub const LocalStreamOptions = struct {
    guid: []const u8 = "",
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    stream_fds: LocalStreamFds,
    reconnect_input_fd: c.fd_t = -1,
    status_mode: StreamReconnectStatusMode,
    intercept_ctrl_r: bool,
    intercept_escape: bool = false,
    control_fd: c.fd_t = -1,
    status_fd: c.fd_t = -1,
    ctrl_r_status_enabled: ?bool = null,
    title_fallback: []const u8 = "",
    reset_on_source_eof: bool = false,
};

// Source EOF is reported as fd readiness on some platforms and as HUP/ERR on
// others. Either way, a ready source gets a read attempt before we consider the
// worker process reaped or the stream complete.
const source_poll_events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;

const StreamStepOutcome = union(enum) {
    idle,
    progress,
    complete,
    interrupted,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

const StreamSource = struct {
    fd: c.fd_t = -1,
    input_control: ?*StreamInputControl = null,
};

const StreamSink = struct {
    fd: c.fd_t = -1,
    close_fd_on_eof: ?*c.fd_t = null,
    shutdown_on_eof: bool = false,
};

fn sinkWithFd(stdin_fd: c.fd_t, close_fd_on_eof: ?*c.fd_t) StreamSink {
    return .{
        .fd = stdin_fd,
        .close_fd_on_eof = close_fd_on_eof,
    };
}

const StreamActiveClientOptions = struct {
    blocking: core_blocking.Blocking,
    source: StreamSource = .{},
    sink: StreamSink = .{},
    reconnect_input_fd: c.fd_t = -1,
    reconnect_status: ?*StreamReconnectStatus = null,
    control_fd: c.fd_t = -1,
    control_input: ?*StreamInputControl = null,
    replacement_listen_fd: c.fd_t = -1,
    close_outbound_on_inbound_eof: bool = false,
    reset_on_source_eof: bool = false,
    send_proxy_open: bool = false,
};

// Owns one active transport. The byte-offset state is outside this type so a
// caller can drop this transport and resume the same stream over a replacement
// without duplicating or losing bytes.
const TransportFds = struct {
    read: c.fd_t,
    write: c.fd_t,
};

const StreamActiveClient = struct {
    state: *StreamState,
    transport_fds: TransportFds,
    transport_reader: protocol.FrameReader,
    transport_writer: dispatch_io.FrameSink = undefined,
    transport_writer_initialized: bool = false,
    control_reader: proxy_diagnostics.Reader,
    options: StreamActiveClientOptions,
    liveness: StreamLiveness,
    interrupt_fd: c.fd_t = -1,

    fn init(
        state: *StreamState,
        transport_fds: TransportFds,
        options: StreamActiveClientOptions,
    ) !StreamActiveClient {
        // A new active transport starts with the peer unready and no EOF sent.
        // Resume/open frames will re-establish offsets before source bytes are
        // allowed to drain onto the mux tunnel.
        state.peer_ready = false;
        state.outbound.outbound_eof_sent = false;
        try core_fds.setNonBlocking(transport_fds.read);
        try core_fds.setNonBlocking(transport_fds.write);
        const now_ms = nowMillis();
        var client = StreamActiveClient{
            .state = state,
            .transport_fds = transport_fds,
            .transport_reader = protocol.FrameReader.init(state.allocator),
            .transport_writer = dispatch_io.FrameSink.init(.{ .allocator = state.allocator, .fd = -1 }),
            .transport_writer_initialized = true,
            .control_reader = proxy_diagnostics.Reader.init(state.allocator),
            .options = options,
            .liveness = StreamLiveness.init(now_ms),
        };
        errdefer client.deinit();
        client.queueResumeMessage(if (options.send_proxy_open) .send_proxy_open else .resume_only) catch return error.StreamTransportClosed;
        _ = client.drainTransportWrites() catch {};
        return client;
    }

    fn deinit(self: *StreamActiveClient) void {
        self.transport_reader.deinit();
        if (self.transport_writer_initialized) self.transport_writer.deinit();
        self.control_reader.deinit();
        self.* = undefined;
    }

    fn ensureTransportWriter(self: *StreamActiveClient) void {
        if (self.transport_writer_initialized) return;
        self.transport_writer = dispatch_io.FrameSink.init(.{ .allocator = self.state.allocator, .fd = -1 });
        self.transport_writer_initialized = true;
    }

    fn hasPendingTransportWrite(self: *StreamActiveClient) bool {
        return self.transport_writer_initialized and self.transport_writer.hasPendingWrite();
    }

    fn writeDaemonTunnelPayload(self: *StreamActiveClient, payload: protocol.DaemonTunnelPayload) !void {
        self.ensureTransportWriter();
        try self.transport_writer.writeDaemonTunnelPayload(payload);
    }

    fn writeMuxStreamFrame(self: *StreamActiveClient, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
        self.ensureTransportWriter();
        try self.transport_writer.writeMuxStreamFrame(message);
    }

    const ResumeMessageMode = enum {
        resume_only,
        send_proxy_open,
    };

    fn queueResumeMessage(self: *StreamActiveClient, mode: ResumeMessageMode) !void {
        // Every proxy transport starts by advertising the inbound offset it has
        // already delivered. Replacement transports may also resend the proxy
        // open payload so the other side can rebuild stream routing.
        try self.writeMuxStreamFrame(.{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .open = .{
                .recv_next_offset = self.state.inbound.recv_next_offset,
            } },
        });
        if (mode != .send_proxy_open) return;
        try self.writeMuxStreamFrame(.{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .payload = .{
                .offset = 0,
                .item = .{ .proxy = .{ .payload = .{ .open = .{
                    .proxy_guid = self.state.guid,
                    .proxy_host = self.state.proxy_host,
                    .proxy_port = self.state.proxy_port,
                } } } },
            } },
        });
    }

    fn queueOpenOk(self: *StreamActiveClient) !void {
        try self.writeMuxStreamFrame(.{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .open_ok = .{
                .recv_next_offset = self.state.inbound.recv_next_offset,
            } },
        });
    }

    fn queueAck(self: *StreamActiveClient, offset: u64) !void {
        try self.writeMuxStreamFrame(.{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .ack = .{
                .recv_next_offset = offset,
            } },
        });
    }

    fn queueData(self: *StreamActiveClient, payload: ProxyDataPayload) !void {
        try self.writeMuxStreamFrame(muxProxyDataFrame(payload));
    }

    fn queueEof(self: *StreamActiveClient, offset: u64) !void {
        try self.writeMuxStreamFrame(.{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .eof = .{ .final_offset = offset } },
        });
    }

    fn queueReset(self: *StreamActiveClient, code: []const u8, message: []const u8) !void {
        try self.writeMuxStreamFrame(protocol.muxStreamResetFrame(proxy_mux_stream_id, code, message));
    }

    // Queue outbound data/EOS that the peer has not acknowledged yet. The same
    // StreamState survives reconnects, so offsets are absolute within the proxy
    // stream rather than relative to one TCP/SSH transport instance.
    fn queuePending(self: *StreamActiveClient) !void {
        if (!self.state.peer_ready) return;
        const outbound = &self.state.outbound;
        if (outbound.peer_recv < outbound.outbound_base or
            outbound.peer_recv > outbound.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        if (outbound.outbound_sent_next < outbound.outbound_base or
            outbound.outbound_sent_next > outbound.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        // ACKs tell us what the peer has durably received. Separately remember
        // how far this transport has been queued to send so appending new source
        // bytes does not cause an overlapping resend on the same still-live
        // transport. On a replacement transport, the resume frame resets
        // outbound_sent_next to the peer's reported receive offset, which is
        // when retransmission is needed.
        var index: usize = @intCast(outbound.outbound_sent_next - outbound.outbound_base);
        while (index < outbound.outbound.items.len) {
            const len = @min(max_chunk_bytes, outbound.outbound.items.len - index);
            const offset = outbound.outbound_base + index;
            try self.queueData(.{
                .offset = offset,
                .data = outbound.outbound.items[index .. index + len],
            });
            index += len;
            outbound.outbound_sent_next = offset + len;
        }
        if (outbound.outbound_eof and !outbound.outbound_eof_acked and !outbound.outbound_eof_sent) {
            try self.queueEof(outbound.outboundNext());
            outbound.outbound_eof_sent = true;
        }
    }

    fn drainTransportWrites(self: *StreamActiveClient) !dispatch_io.SinkWriteStatus {
        if (!self.transport_writer_initialized) return .drained;
        return self.transport_writer.writeReadyTo(self.transport_fds.write);
    }

    fn hasPendingSinkWrite(self: *const StreamActiveClient) bool {
        return self.state.pendingInboundData().len != 0;
    }

    fn canReadTransport(self: *const StreamActiveClient) bool {
        return self.state.pendingInboundData().len < max_buffered_bytes;
    }

    fn drainSinkWrites(self: *StreamActiveClient) !bool {
        // Write ordered inbound bytes to the local sink and advance receive
        // offset only after the sink accepted them. That offset is what future
        // reconnects use to suppress duplicate delivery.
        var made_progress = false;
        while (self.state.pendingInboundData().len != 0) {
            const sink = self.options.sink;
            if (sink.fd < 0) return error.StreamSinkClosed;
            const pending = self.state.pendingInboundData();
            switch (try io.writeSomeNonBlocking(sink.fd, pending)) {
                .wrote => |n| {
                    if (n == 0) break;
                    if (self.options.reconnect_status) |status| status.observeInbound(pending[0..n]);
                    try self.state.noteInboundDelivered(n);
                    made_progress = true;
                },
                .would_block => break,
            }
        }
        if (try self.applyInboundEofIfReady()) made_progress = true;
        if (made_progress) try self.queueAck(self.state.inbound.recv_next_offset);
        return made_progress;
    }

    fn applyInboundEofIfReady(self: *StreamActiveClient) !bool {
        if (!self.state.inbound.inbound_eof or self.state.inbound_eof_applied) return false;
        const sink = self.options.sink;
        if (sink.shutdown_on_eof and sink.fd >= 0) _ = c.shutdown(sink.fd, c.SHUT.WR);
        if (sink.close_fd_on_eof) |sink_fd_ptr| {
            if (sink_fd_ptr.* >= 0) {
                _ = c.close(sink_fd_ptr.*);
                sink_fd_ptr.* = -1;
            }
        }
        if (self.options.close_outbound_on_inbound_eof) {
            self.state.completeOutboundAfterInboundEof();
        }
        self.state.inbound_eof_applied = true;
        return true;
    }

    // Advance one proxy-stream owner by servicing whichever fd is ready:
    // local OpenSSH bytes, daemon-tunnel frames, diagnostics control, reconnect
    // input, or liveness timers. Keeping this as one explicit state transition
    // prevents the shared transport fd from blocking on any one local stream.
    fn step(self: *StreamActiveClient, requested_timeout_ms: i32) !StreamStepOutcome {
        const state = self.state;
        if (state.complete()) return .complete;

        const now_before_poll_ms = nowMillis();
        const timeout_ms = self.liveness.pollTimeoutMs(now_before_poll_ms, requested_timeout_ms);
        var poll = try StreamActiveClientStepPoll.init(self);
        defer poll.deinit();
        try poll.run(timeout_ms);
        const now_after_poll_ms = nowMillis();

        if (!poll.hasFdEvent()) {
            if (self.liveness.timedOut(now_after_poll_ms)) return .unresponsive;
            if (self.liveness.pingDue(now_after_poll_ms)) {
                if (!self.hasPendingTransportWrite()) try self.writeDaemonTunnelPayload(.{ .ping = .{} });
                self.liveness.notePingSent(now_after_poll_ms);
                return .progress;
            }
            return .idle;
        }

        if (poll.replacement_event) |replacement_event| {
            if (replacement_event.readable) {
                if (acceptWorkerClient(self.options.replacement_listen_fd)) |fd| return .{ .replacement = fd };
            }
        }
        if (poll.interrupt_event != null) {
            return .interrupted;
        }
        if (poll.control_event != null) {
            if (self.options.control_input) |control| {
                if (!readControlInput(self.options.control_fd, control, &self.control_reader)) self.options.control_fd = -1;
            }
        }
        if (poll.reconnect_input_event != null) {
            if (self.options.control_input) |control| {
                readReconnectControlInput(self.options.reconnect_input_fd, control);
            }
        }

        if (poll.transport_event) |transport_event| {
            if ((transport_event.hangup or transport_event.error_event or transport_event.invalid) and !transport_event.readable) {
                return .transport_closed;
            }
        }
        if (poll.transport_write_event != null) {
            return switch (self.drainTransportWrites() catch return .transport_closed) {
                .blocked => .idle,
                .progress, .drained => .progress,
            };
        }
        if (poll.sink_write_event != null) {
            const made_progress = self.drainSinkWrites() catch |err| switch (err) {
                error.StreamSinkClosed => return .complete,
                else => return err,
            };
            _ = self.drainTransportWrites() catch return .transport_closed;
            return if (made_progress) .progress else .idle;
        }
        if (if (poll.transport_event) |transport_event| transport_event.readable else false) {
            const frame = switch (self.transport_reader.readReady(self.transport_fds.read) catch return .transport_closed) {
                .blocked => return .idle,
                .progress => {
                    self.liveness.noteIncoming(nowMillis());
                    return .progress;
                },
                .eof, .truncated_frame => return .transport_closed,
                .frame => |frame_value| frame_value,
            };
            self.liveness.noteIncoming(nowMillis());
            self.handleFrame(frame) catch |err| switch (err) {
                error.StreamReset => return .complete,
                else => return err,
            };
            _ = self.drainSinkWrites() catch |err| switch (err) {
                error.StreamSinkClosed => return .complete,
                else => return err,
            };
            _ = self.drainTransportWrites() catch return .transport_closed;
            // A transport frame can make source bytes or EOF immediately useful
            // without any new source readiness. For example, a resume frame
            // tells us the peer is ready for retransmission, and inbound EOF can mark
            // our outbound side closed.
            try drainStreamSourcesNonBlocking(state, &self.options);
            if (try self.completeAfterSourceReset()) return .complete;
            if (state.complete()) return .complete;
            if (state.peer_ready) {
                try self.queuePending();
            }
            _ = self.drainTransportWrites() catch return .transport_closed;
            return .progress;
        }

        const source_ready = blk: {
            const source = self.options.source;
            if (poll.source_event != null) {
                try readStreamSource(state, source);
                break :blk true;
            }
            break :blk false;
        };
        _ = source_ready;
        try drainStreamSourcesNonBlocking(state, &self.options);
        if (try self.completeAfterSourceReset()) return .complete;

        if (state.peer_ready) {
            try self.queuePending();
            _ = self.drainTransportWrites() catch return .transport_closed;
        }
        return .idle;
    }

    fn completeAfterSourceReset(self: *StreamActiveClient) !bool {
        if (!self.options.reset_on_source_eof or !self.state.source_eof) return false;
        try self.queueReset("SOURCE_CLOSED", "local proxy stream closed");
        _ = self.drainTransportWrites() catch {};
        return true;
    }

    fn handleFrame(self: *StreamActiveClient, frame: protocol.OwnedFrame) !void {
        try handleTransportFrame(
            self,
            &self.options,
            frame,
        );
    }
};

const StreamActiveClientStepPoll = struct {
    client: *StreamActiveClient,
    transport_event: ?dispatcher.FdEvent = null,
    transport_write_event: ?dispatcher.FdEvent = null,
    sink_write_event: ?dispatcher.FdEvent = null,
    source_event: ?dispatcher.FdEvent = null,
    replacement_event: ?dispatcher.FdEvent = null,
    control_event: ?dispatcher.FdEvent = null,
    reconnect_input_event: ?dispatcher.FdEvent = null,
    interrupt_event: ?dispatcher.FdEvent = null,

    fn init(client: *StreamActiveClient) !StreamActiveClientStepPoll {
        return .{
            .client = client,
        };
    }

    fn deinit(_: *StreamActiveClientStepPoll) void {}

    fn run(self: *StreamActiveClientStepPoll, timeout_ms: i32) !void {
        // The proxy worker is still process-local, so this is its complete
        // event wait. Each poll slot maps back to a state-machine input; the
        // subsequent step decides how backpressure affects the paired fds.
        var poll_set = StreamActiveClientPollSet{};
        if (self.client.canReadTransport()) {
            poll_set.add(self.client.transport_fds.read, posix.POLL.IN, .transport);
        }
        if (self.client.hasPendingTransportWrite()) {
            poll_set.add(self.client.transport_fds.write, posix.POLL.OUT, .transport_write);
        }
        if (self.client.hasPendingSinkWrite() and self.client.options.sink.fd >= 0) {
            poll_set.add(self.client.options.sink.fd, posix.POLL.OUT, .sink_write);
        }

        const state = self.client.state;
        const source = self.client.options.source;
        if (source.fd >= 0 and !state.outbound.outbound_eof and state.bufferedBytes() < max_buffered_bytes) {
            poll_set.add(source.fd, source_poll_events, .source);
        }
        if (self.client.options.replacement_listen_fd >= 0) {
            poll_set.add(self.client.options.replacement_listen_fd, posix.POLL.IN, .replacement);
        }
        if (self.client.options.control_fd >= 0 and self.client.options.control_input != null) {
            poll_set.add(self.client.options.control_fd, posix.POLL.IN, .control);
        }
        if (self.client.options.reconnect_input_fd >= 0 and self.client.options.control_input != null) {
            if (self.client.options.control_input) |control| {
                if (reconnectInputPollEnabled(control)) {
                    poll_set.add(self.client.options.reconnect_input_fd, posix.POLL.IN, .reconnect_input);
                }
            }
        }
        if (self.client.interrupt_fd >= 0) {
            poll_set.add(self.client.interrupt_fd, posix.POLL.IN, .interrupt);
        }
        if (poll_set.count == 0 and timeout_ms < 0) return;
        const ready = try self.client.options.blocking.poll(poll_set.fdSlice(), timeout_ms);
        if (ready == 0) return;
        for (poll_set.fdSlice(), poll_set.kindSlice()) |pollfd, kind| {
            if (pollfd.revents == 0) continue;
            self.noteFdEvent(kind, fdEventFromRevents(pollfd.fd, pollfd.revents));
        }
    }

    fn hasFdEvent(self: *const StreamActiveClientStepPoll) bool {
        return self.transport_event != null or
            self.transport_write_event != null or
            self.sink_write_event != null or
            self.source_event != null or
            self.replacement_event != null or
            self.control_event != null or
            self.reconnect_input_event != null or
            self.interrupt_event != null;
    }

    fn noteFdEvent(self: *StreamActiveClientStepPoll, kind: StreamActiveClientPollKind, event: dispatcher.FdEvent) void {
        switch (kind) {
            .transport => self.transport_event = event,
            .transport_write => self.transport_write_event = event,
            .sink_write => self.sink_write_event = event,
            .source => self.source_event = event,
            .replacement => self.replacement_event = event,
            .control => self.control_event = event,
            .reconnect_input => self.reconnect_input_event = event,
            .interrupt => self.interrupt_event = event,
        }
    }
};

const StreamActiveClientPollKind = enum {
    transport,
    transport_write,
    sink_write,
    source,
    replacement,
    control,
    reconnect_input,
    interrupt,
};

const StreamActiveClientPollSet = poll_sets.PollSet(StreamActiveClientPollKind, 8);

fn fdEventFromRevents(fd: c.fd_t, revents: i16) dispatcher.FdEvent {
    return .{
        .fd = fd,
        .readable = (revents & posix.POLL.IN) != 0,
        .writable = (revents & posix.POLL.OUT) != 0,
        .hangup = (revents & posix.POLL.HUP) != 0,
        .error_event = (revents & posix.POLL.ERR) != 0,
        .invalid = (revents & posix.POLL.NVAL) != 0,
    };
}

fn readStreamSource(state: *StreamState, source: StreamSource) !void {
    if (state.outbound.outbound_eof) return;
    // HUP/ERR can arrive while bytes are still readable, so source readiness
    // always gets a read attempt.
    var buf: [max_chunk_bytes]u8 = undefined;
    switch (try readStreamSourceFd(source, &buf)) {
        .bytes => |bytes| try appendStreamSourceBytes(state, source, bytes),
        .would_block => {},
        .eof => {
            state.source_eof = true;
            state.outbound.outbound_eof = true;
        },
    }
}

fn appendStreamSourceBytes(state: *StreamState, source: StreamSource, bytes: []const u8) !void {
    if (source.input_control) |control| {
        var filtered: [max_chunk_bytes]u8 = undefined;
        const filtered_bytes = control.filter(bytes, &filtered);
        try state.appendOutbound(filtered_bytes);
    } else {
        try state.appendOutbound(bytes);
    }
}

fn drainStreamSourcesNonBlocking(
    state: *StreamState,
    options: *const StreamActiveClientOptions,
) !void {
    // Fill the outbound buffer opportunistically before the main relay loop
    // starts. This is especially useful for fd-pass proxy streams where
    // OpenSSH may have already written bytes before the worker has finished
    // sending the mux open frame.
    const source = options.source;
    if (source.fd < 0) return;
    while (!state.outbound.outbound_eof and state.bufferedBytes() < max_buffered_bytes) {
        var buf: [max_chunk_bytes]u8 = undefined;
        switch (try readStreamSourceFdNonBlocking(source, &buf)) {
            .bytes => |bytes| if (bytes.len == 0) {
                state.source_eof = true;
                state.outbound.outbound_eof = true;
                break;
            } else {
                try appendStreamSourceBytes(state, source, bytes);
            },
            .would_block => {
                // Would-block only means there is no source data ready
                // right now. EOF must come from the source fd itself, not
                // from a process-status guess.
                break;
            },
            .eof => {
                state.source_eof = true;
                state.outbound.outbound_eof = true;
                break;
            },
        }
    }
}

fn readStreamSourceFd(source: StreamSource, buf: []u8) !ReadSomeResult {
    return io.readSome(source.fd, buf);
}

fn readStreamSourceFdNonBlocking(source: StreamSource, buf: []u8) !ReadSomeResult {
    return io.readSomeNonBlocking(source.fd, buf);
}

const ProxyEndpoint = struct {
    stream: std.net.Stream,
    fd: c.fd_t,

    fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !ProxyEndpoint {
        daemon_log.infof(allocator, "proxy tcp connection starting host={s} port={}", .{ host, port });
        const stream = try std.net.tcpConnectToHost(allocator, host, port);
        daemon_log.infof(allocator, "proxy tcp connection ready host={s} port={}", .{ host, port });
        return .{
            .stream = stream,
            .fd = stream.handle,
        };
    }

    fn activeClientOptions(self: *ProxyEndpoint, blocking: core_blocking.Blocking, replacement_listen_fd: c.fd_t) StreamActiveClientOptions {
        return .{
            .blocking = blocking,
            .source = .{ .fd = self.fd },
            .sink = .{
                .fd = self.fd,
                .shutdown_on_eof = true,
            },
            .replacement_listen_fd = replacement_listen_fd,
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

pub const RemoteWorkerOptions = struct {
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    guid: []const u8,
    replacement_listen_fd: c.fd_t,
    proxy_host: []const u8,
    proxy_port: u16,
};

/// Run the remote proxy worker that connects to the real proxy destination
/// socket. When the daemon tunnel drops, the worker keeps StreamState and waits
/// for a replacement local-daemon connection so unacknowledged bytes can resume.
pub fn runRemoteWorker(options: RemoteWorkerOptions) !void {
    _ = options.blocking;
    const allocator = options.allocator;
    const replacement_listen_fd = options.replacement_listen_fd;
    var endpoint = try ProxyEndpoint.connect(allocator, options.proxy_host, options.proxy_port);
    defer endpoint.deinit();

    var state = StreamState.init(.{
        .allocator = allocator,
        .guid = options.guid,
    });
    defer state.deinit();

    var transport_fd = core_fds.OwnedFd{};
    defer transport_fd.deinit();
    while (true) {
        if (transport_fd.get() < 0) {
            var disconnected_options = endpoint.activeClientOptions(options.blocking, replacement_listen_fd);
            transport_fd = core_fds.OwnedFd.init(try waitForReplacementWhileDisconnected(&state, replacement_listen_fd, &disconnected_options));
        }

        const connected_fd = transport_fd.get();
        const outcome = try runConnectedStream(
            &state,
            .{
                .read = connected_fd,
                .write = connected_fd,
            },
            endpoint.activeClientOptions(options.blocking, replacement_listen_fd),
        );
        switch (outcome) {
            .complete => return,
            .replacement => |replacement_fd| {
                transport_fd.deinit();
                transport_fd = core_fds.OwnedFd.init(replacement_fd);
            },
            .transport_closed, .unresponsive => {
                transport_fd.deinit();
            },
        }
    }
}

fn waitForReplacementWhileDisconnected(
    state: *StreamState,
    replacement_listen_fd: c.fd_t,
    options: *const StreamActiveClientOptions,
) !c.fd_t {
    // While disconnected, the worker keeps buffering remote-side bytes and waits
    // for the next daemon transport to attach. Returning the accepted fd hands
    // those durable offsets to the replacement active-client loop.
    while (true) {
        // The remote proxy process is durable while no ssh transport is
        // connected. It must keep draining remote fds into the offset-tracked
        // buffers; otherwise the remote TCP peer can block before a replacement
        // transport connects.
        var poll = try DisconnectedReplacementPoll.init(state, replacement_listen_fd, options);
        defer poll.deinit();
        try poll.run();
        if (if (poll.replacement_event) |event| event.readable else false) {
            if (acceptWorkerClient(replacement_listen_fd)) |fd| return fd;
        }

        if (poll.source_event != null) {
            try readStreamSource(state, options.source);
        }
        try drainStreamSourcesNonBlocking(state, options);
    }
}

// disconnected process-isolated proxy worker wait. While no
// transport is connected, the worker still drains the local source into durable
// byte offsets and waits for a replacement transport.
const DisconnectedReplacementPoll = struct {
    state: *StreamState,
    replacement_listen_fd: c.fd_t,
    options: *const StreamActiveClientOptions,
    replacement_event: ?dispatcher.FdEvent = null,
    source_event: ?dispatcher.FdEvent = null,

    fn init(
        state: *StreamState,
        replacement_listen_fd: c.fd_t,
        options: *const StreamActiveClientOptions,
    ) !DisconnectedReplacementPoll {
        return .{
            .state = state,
            .replacement_listen_fd = replacement_listen_fd,
            .options = options,
        };
    }

    fn deinit(_: *DisconnectedReplacementPoll) void {}

    fn run(self: *DisconnectedReplacementPoll) !void {
        var poll_set = DisconnectedReplacementPollSet{};
        poll_set.add(self.replacement_listen_fd, posix.POLL.IN, .replacement);

        const source = self.options.source;
        if (source.fd >= 0 and !self.state.outbound.outbound_eof and self.state.bufferedBytes() < max_buffered_bytes) {
            poll_set.add(source.fd, source_poll_events, .source);
        }

        const ready = try self.options.blocking.poll(poll_set.fdSlice(), -1);
        if (ready == 0) return;
        for (poll_set.fdSlice(), poll_set.kindSlice()) |pollfd, kind| {
            if (pollfd.revents == 0) continue;
            switch (kind) {
                .replacement => self.replacement_event = fdEventFromRevents(pollfd.fd, pollfd.revents),
                .source => self.source_event = fdEventFromRevents(pollfd.fd, pollfd.revents),
            }
        }
    }
};

const DisconnectedReplacementPollKind = enum {
    replacement,
    source,
};

const DisconnectedReplacementPollSet = poll_sets.PollSet(DisconnectedReplacementPollKind, 2);

fn acceptWorkerClient(listen_fd: c.fd_t) ?c.fd_t {
    const fd = c.accept(listen_fd, null, null);
    if (fd < 0) return null;
    core_fds.setCloseOnExec(fd) catch {
        _ = c.close(fd);
        return null;
    };
    return fd;
}

/// Runs in the local `sessh` process. `start_transport` creates daemon-tunnel
/// ssh transports to the remote host; this loop owns local stdin/stdout and the
/// reconnect policy.
pub fn runLocalStream(
    blocking: core_blocking.Blocking,
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: LocalStreamOptions,
) !u8 {
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    var control_fd = options.control_fd;
    if (control_fd >= 0) core_fds.setNonBlocking(control_fd) catch {};
    if (options.reconnect_input_fd >= 0) core_fds.setNonBlocking(options.reconnect_input_fd) catch {};

    var state = StreamState.init(.{
        .allocator = allocator,
        .guid = options.guid,
        .proxy_host = options.proxy_host,
        .proxy_port = options.proxy_port,
    });
    defer state.deinit();
    var input_control = StreamInputControl{
        .enabled = options.intercept_ctrl_r or options.reconnect_input_fd >= 0,
        .escape_enabled = options.intercept_escape,
    };
    const ctrl_r_status_enabled = options.ctrl_r_status_enabled orelse (options.intercept_ctrl_r or options.reconnect_input_fd >= 0);
    const status_fd = if (options.status_fd >= 0) options.status_fd else control_fd;
    var reconnect_status = StreamReconnectStatus.init(.{
        .blocking = blocking,
        .mode = options.status_mode,
        .ctrl_r_enabled = ctrl_r_status_enabled,
        .title_fallback = options.title_fallback,
        .status_fd = status_fd,
    });
    defer reconnect_status.deinit();
    var local_interrupt = try LocalStreamInterrupt.install();
    defer local_interrupt.deinit();
    var reconnect_context = ProxyReconnectControlContext.init(.{
        .blocking = blocking,
        .state = &state,
        .source_fd = options.stream_fds.source,
        .reconnect_input_fd = options.reconnect_input_fd,
        .control_fd = &control_fd,
        .input_control = &input_control,
        .interrupt = &local_interrupt,
    });
    defer reconnect_context.deinit();

    var attempt: usize = 0;
    var had_transport = false;
    var retrying = false;

    client_loop: while (true) {
        var transport: Transport = undefined;
        if (retrying) reconnect_status.showReconnecting();
        transport = start_transport.start() catch |err| {
            // Before the first successful transport, a start failure usually
            // means ssh could not authenticate in BatchMode. The error goes to
            // the outer ssh instead of retrying forever.
            if (!had_transport and !state.hasProgress()) {
                reconnect_status.flushDiagnostics();
                return err;
            }
            if (try disconnectedSourceClosed(blocking, &state, options.stream_fds.source, &input_control)) return 0;
            const delay_ms = reconnect.delayMs(attempt);
            const action = waitBeforeReconnect(&reconnect_status, delay_ms, &reconnect_context);
            if (options.reset_on_source_eof and state.source_eof) return 0;
            if (action == .disconnect) return 0;
            if (action == .interrupt) return 255;
            attempt = reconnect.nextAttempt(attempt, if (action == .reconnect) .reset else .increment);
            retrying = true;
            continue;
        };
        had_transport = true;
        reconnect_status.flushDiagnostics();
        reconnect_status.clear();
        input_control.status_visible = false;

        transport_loop: while (true) {
            var active_client = StreamActiveClient.init(
                &state,
                .{
                    .read = transport.readFd(),
                    .write = transport.writeFd(),
                },
                .{
                    .blocking = blocking,
                    .source = .{
                        .fd = options.stream_fds.source,
                        .input_control = &input_control,
                    },
                    .sink = .{ .fd = options.stream_fds.sink },
                    .reconnect_input_fd = options.reconnect_input_fd,
                    .reconnect_status = &reconnect_status,
                    .control_fd = control_fd,
                    .control_input = &input_control,
                    // Once the remote side closes its output stream there is
                    // no peer left to consume local input, so close the local
                    // outbound side too.
                    .close_outbound_on_inbound_eof = true,
                    .reset_on_source_eof = options.reset_on_source_eof,
                    .send_proxy_open = true,
                },
            ) catch {
                transport.close();
                retrying = true;
                continue :client_loop;
            };
            defer active_client.deinit();
            if (options.status_mode == .client_control and options.control_fd < 0 and options.status_fd < 0) {
                reconnect_status.setFd(transport.writeFd());
                reconnect_status.clear();
            }
            var old_unresponsive = false;
            while (true) {
                active_client.interrupt_fd = local_interrupt.read_fd;
                const outcome = active_client.step(-1) catch .transport_closed;
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
                        const new_transport = start_transport.start() catch |err| {
                            client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                            const delay_ms = reconnect.delayMs(attempt);
                            const action = waitBeforeReconnect(&reconnect_status, delay_ms, &reconnect_context);
                            if (action == .disconnect) return 0;
                            if (action == .interrupt) return 255;
                            attempt = reconnect.nextAttempt(attempt, if (action == .reconnect) .reset else .increment);
                            continue;
                        };
                        abortTransport(&transport);
                        transport = new_transport;
                        attempt = 0;
                        retrying = false;
                        reconnect_status.clear();
                        input_control.status_visible = false;
                        continue :transport_loop;
                    },
                    .transport_closed => {
                        transport.close();
                        if (options.status_mode == .client_control and options.control_fd < 0 and options.status_fd < 0) {
                            reconnect_status.setFd(-1);
                        }
                        if (try disconnectedSourceClosed(blocking, &state, options.stream_fds.source, &input_control)) return 0;
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
                        active_client.queueReset("CLIENT_DISCONNECT", "local proxy stream disconnected") catch {};
                        _ = active_client.drainTransportWrites() catch {};
                        abortTransport(&transport);
                        return 0;
                    },
                    .reconnect => if (old_unresponsive) {
                        const new_transport = start_transport.start() catch |err| {
                            client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                            continue;
                        };
                        abortTransport(&transport);
                        transport = new_transport;
                        attempt = 0;
                        retrying = false;
                        reconnect_status.clear();
                        input_control.status_visible = false;
                        continue :transport_loop;
                    },
                    .help => reconnect_status.showEscapeHelp(),
                    .none => {},
                    .interrupt => unreachable,
                }
            }
        }

        const delay_ms = reconnect.delayMs(attempt);
        const action = waitBeforeReconnect(&reconnect_status, delay_ms, &reconnect_context);
        if (options.reset_on_source_eof and state.source_eof) return 0;
        if (action == .disconnect) return 0;
        if (action == .interrupt) return 255;
        attempt = reconnect.nextAttempt(attempt, if (action == .reconnect) .reset else .increment);
        retrying = true;
    }
}

fn disconnectedSourceClosed(
    blocking: core_blocking.Blocking,
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
) !bool {
    if (source_fd < 0) return false;
    var options = StreamActiveClientOptions{
        .blocking = blocking,
        .source = .{
            .fd = source_fd,
            .input_control = input_control,
        },
    };
    try drainStreamSourcesNonBlocking(state, &options);
    return state.source_eof;
}

// Drive a proxy stream while one transport connection is alive. Completion means
// the logical stream ended; transport_closed/unresponsive means callers should
// reconnect and reuse the same StreamState.
fn runConnectedStream(
    state: *StreamState,
    transport_fds: TransportFds,
    options: StreamActiveClientOptions,
) !StreamOutcome {
    var active_client = StreamActiveClient.init(
        state,
        transport_fds,
        options,
    ) catch return .transport_closed;

    while (true) {
        switch (try active_client.step(-1)) {
            .complete => return .complete,
            .transport_closed => return .transport_closed,
            .unresponsive => return .unresponsive,
            .interrupted => return .transport_closed,
            .replacement => |fd| return .{ .replacement = fd },
            .idle, .progress => {},
        }
    }
}

// Decode one frame from the daemon tunnel side. Transport control affects
// liveness/diagnostics, while mux stream frames advance the durable proxy-stream
// offset protocol.
fn handleTransportFrame(
    active_client: *StreamActiveClient,
    options: *const StreamActiveClientOptions,
    frame: protocol.OwnedFrame,
) !void {
    var mutable = frame;
    defer mutable.deinit(active_client.state.allocator);

    switch (mutable.message_type) {
        .daemon_tunnel => {
            if (try handleTransportControlFrame(active_client, mutable.message_type, mutable.payload)) return;
            var message = try protocol.decodeDaemonMuxStreamFrame(active_client.state.allocator, mutable.payload);
            defer message.deinit(active_client.state.allocator);
            try handleMuxStreamFrame(active_client, options, message);
        },
        .error_message => {
            var message = try protocol.decodePayload(protocol.hpb.Error, active_client.state.allocator, mutable.payload);
            defer message.deinit(active_client.state.allocator);
            try options.blocking.stderrPrint("sessh: {s}\n", .{message.message});
            if (message.hint) |hint| {
                if (hint.len > 0) try options.blocking.stderrPrint("{s}\n", .{hint});
            }
            return error.StreamReset;
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, active_client.state.allocator, mutable.payload);
            defer item.deinit(active_client.state.allocator);
            switch (item.payload orelse return error.StreamUnexpectedFrame) {
                .connection_event => |event| {
                    if (options.reconnect_status) |status| status.handleConnectionEvent(event);
                },
                .retry_now => {
                    if (options.control_input) |control| {
                        control.reconnect_requested = true;
                    }
                },
                else => return error.StreamUnexpectedFrame,
            }
        },
        else => return error.StreamUnexpectedFrame,
    }
}

fn handleTransportControlFrame(
    active_client: *StreamActiveClient,
    message_type: protocol.MessageType,
    payload: []const u8,
) !bool {
    switch (try protocol.decodeTransportControlFrame(active_client.state.allocator, message_type, payload) orelse return false) {
        .ping => {
            // A ping response must not make frame decoding depend on a
            // successful write to the same fd. Queueing keeps transport
            // liveness on the same nonblocking path as other control output.
            try active_client.writeDaemonTunnelPayload(.{ .pong = .{} });
        },
        .pong => {},
    }
    return true;
}

// Apply one logical proxy mux-stream frame. Open/OpenOk establish the peer's
// receive cursor, payload data is ordered by offset, ACKs release outbound
// buffer space, and EOF/reset finish the corresponding half or whole stream.
fn handleMuxStreamFrame(
    active_client: *StreamActiveClient,
    options: *const StreamActiveClientOptions,
    frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const state = active_client.state;
    if (frame.stream_id != proxy_mux_stream_id) return error.StreamUnexpectedFrame;
    const message = frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| {
            state.peer_ready = true;
            try handleResumeOffset(state, open.recv_next_offset);
            try active_client.queueOpenOk();
            try active_client.queuePending();
        },
        .open_ok => |open_ok| {
            state.peer_ready = true;
            try handleAck(state, open_ok.recv_next_offset);
            try active_client.queuePending();
        },
        .ack => |ack| try handleAck(state, ack.recv_next_offset),
        .payload => |payload| {
            const item = payload.item orelse return error.StreamUnexpectedFrame;
            switch (item) {
                .proxy => |proxy_item| try handleProxyStreamPayload(.{
                    .active_client = active_client,
                    .options = options,
                    .offset = payload.offset,
                    .item = proxy_item,
                }),
                .terminal_emulator => return error.StreamUnexpectedFrame,
            }
        },
        .eof => |eof| try handleInboundEof(
            active_client,
            eof.final_offset,
        ),
        .reset => return error.StreamReset,
    }
}

const ProxyStreamPayloadContext = struct {
    active_client: *StreamActiveClient,
    options: *const StreamActiveClientOptions,
    offset: u64,
    item: pb.ProxyStreamItem,
};

const InboundProxyDataContext = struct {
    active_client: *StreamActiveClient,
    options: *const StreamActiveClientOptions,
    offset: u64,
    data: []const u8,
};

fn handleProxyStreamPayload(context: ProxyStreamPayloadContext) !void {
    const payload = context.item.payload orelse return error.StreamUnexpectedFrame;
    switch (payload) {
        .data => |data| try handleInboundData(.{
            .active_client = context.active_client,
            .options = context.options,
            .offset = context.offset,
            .data = data,
        }),
        else => return error.StreamUnexpectedFrame,
    }
}

fn handleResumeOffset(state: *StreamState, offset: u64) !void {
    try state.resumeOutbound(offset);
}

fn handleAck(state: *StreamState, offset: u64) !void {
    try state.ackOutbound(offset);
}

fn handleInboundData(context: InboundProxyDataContext) !void {
    const sink = context.options.sink;
    const queued = try context.active_client.state.queueInboundData(context.offset, context.data);
    if (queued != 0 and sink.fd < 0) return error.StreamSinkClosed;
    _ = try context.active_client.drainSinkWrites();
}

fn handleInboundEof(
    active_client: *StreamActiveClient,
    final_offset: u64,
) !void {
    const state = active_client.state;
    try state.markInboundEof(final_offset);
    _ = try active_client.drainSinkWrites();
}

const test_frames = if (builtin.is_test) struct {
    // Test helpers use blocking writes only to build pipe fixtures. Production
    // proxy-stream output goes through StreamActiveClient's FrameSink so a
    // stalled transport cannot block the worker state machine.
    const SendDataRequest = struct {
        state: *StreamState,
        fd: c.fd_t,
        payload: ProxyDataPayload,
    };

    fn sendData(request: SendDataRequest) !void {
        try sendMuxStreamFrame(request.state.allocator, request.fd, muxProxyDataFrame(request.payload));
    }

    fn sendEof(state: *StreamState, fd: c.fd_t, offset: u64) !void {
        try sendMuxStreamFrame(state.allocator, fd, .{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .eof = .{ .final_offset = offset } },
        });
    }

    fn sendReset(state: *StreamState, fd: c.fd_t, info: protocol.ErrorInfo) !void {
        try protocol_test_helpers.sendMuxStreamResetFrameBlocking(.{
            .allocator = state.allocator,
            .fd = fd,
            .stream_id = proxy_mux_stream_id,
            .code = info.code,
            .message = info.message,
        });
    }

    fn sendPending(state: *StreamState, transport_write_fd: c.fd_t) !void {
        // Test helper that sends exactly the frames the live relay would emit:
        // new bytes from the outbound window, followed by EOF once source EOF
        // has advanced past all pending data.
        if (!state.peer_ready) return;
        const outbound = &state.outbound;
        if (outbound.peer_recv < outbound.outbound_base or
            outbound.peer_recv > outbound.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        if (outbound.outbound_sent_next < outbound.outbound_base or
            outbound.outbound_sent_next > outbound.outboundNext())
        {
            return error.StreamAckOutOfRange;
        }
        // ACKs tell us what the peer has durably received. Separately remember
        // how far this transport has already been sent so appending new source
        // bytes does not cause an overlapping resend on the same still-live
        // transport. On a replacement transport, the resume frame resets
        // outbound_sent_next to the peer's reported receive offset, which is
        // when retransmission is needed.
        var index: usize = @intCast(outbound.outbound_sent_next - outbound.outbound_base);
        while (index < outbound.outbound.items.len) {
            const len = @min(max_chunk_bytes, outbound.outbound.items.len - index);
            const offset = outbound.outbound_base + index;
            try sendData(.{
                .state = state,
                .fd = transport_write_fd,
                .payload = .{
                    .offset = offset,
                    .data = outbound.outbound.items[index .. index + len],
                },
            });
            index += len;
            outbound.outbound_sent_next = offset + len;
        }
        if (outbound.outbound_eof and !outbound.outbound_eof_acked and !outbound.outbound_eof_sent) {
            try sendEof(state, transport_write_fd, outbound.outboundNext());
            outbound.outbound_eof_sent = true;
        }
    }

    fn sendMuxStreamFrame(
        allocator: std.mem.Allocator,
        fd: c.fd_t,
        message: pb.DaemonTunnelItem.MuxStreamFrame,
    ) !void {
        try protocol_test_helpers.sendMuxStreamFrameBlocking(allocator, fd, message);
    }
} else struct {};

fn abortTransport(transport: anytype) void {
    const Transport = @TypeOf(transport.*);
    if (@hasDecl(Transport, "terminate")) {
        transport.terminate();
    } else {
        transport.close();
    }
}

pub fn requestProxyRemoteCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    return proxy_remote.requestCleanup(allocator, guid);
}

pub fn activeProxyRemoteProcessCount() usize {
    return proxy_remote.activeCount();
}

fn nowMillis() u64 {
    return non_suspending_timer.nowMs() catch {
        const ms = std.time.milliTimestamp();
        if (ms < 0) return 0;
        return @intCast(ms);
    };
}

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    return if (end_ms >= start_ms) end_ms - start_ms else 0;
}

fn remainingDelayMs(deadline_ms: u64, now_ms: u64) ?u64 {
    if (now_ms >= deadline_ms) return null;
    return deadline_ms - now_ms;
}

const ProxyReconnectControlContext = struct {
    blocking: core_blocking.Blocking,
    state: *StreamState,
    source_fd: c.fd_t,
    reconnect_input_fd: c.fd_t,
    control_fd: *c.fd_t,
    input_control: *StreamInputControl,
    control_reader: proxy_diagnostics.Reader,
    interrupt: ?*LocalStreamInterrupt,

    const Init = struct {
        blocking: core_blocking.Blocking,
        state: *StreamState,
        source_fd: c.fd_t,
        reconnect_input_fd: c.fd_t,
        control_fd: *c.fd_t,
        input_control: *StreamInputControl,
        interrupt: ?*LocalStreamInterrupt,
    };

    fn init(init_options: Init) ProxyReconnectControlContext {
        return .{
            .blocking = init_options.blocking,
            .state = init_options.state,
            .source_fd = init_options.source_fd,
            .reconnect_input_fd = init_options.reconnect_input_fd,
            .control_fd = init_options.control_fd,
            .input_control = init_options.input_control,
            .control_reader = proxy_diagnostics.Reader.init(init_options.state.allocator),
            .interrupt = init_options.interrupt,
        };
    }

    fn deinit(self: *ProxyReconnectControlContext) void {
        self.control_reader.deinit();
    }
};

fn waitBeforeReconnect(
    status: *StreamReconnectStatus,
    delay_ms: u64,
    control: *ProxyReconnectControlContext,
) StreamControlAction {
    // Proxy reconnect delay is user-interruptible. Update diagnostics at coarse
    // intervals, but let Ctrl-R, help, interrupt, or disconnect break the wait
    // immediately.
    const deadline_ms = nowMillis() +| delay_ms;
    while (remainingDelayMs(deadline_ms, nowMillis())) |remaining_ms| {
        status.showRetry(remaining_ms);
        control.input_control.status_visible = true;
        const step_ms = @min(remaining_ms, 1_000);
        const action = pollReconnectInput(control, @intCast(step_ms));
        if (action == .help) {
            status.showEscapeHelp();
            continue;
        }
        if (action != .none) return action;
        status.flushDiagnostics();
    }
    const action = control.input_control.consumeAction();
    if (action == .help) {
        status.showEscapeHelp();
        return .none;
    }
    return action;
}

fn pollReconnectInput(
    control: *ProxyReconnectControlContext,
    timeout_ms: i32,
) StreamControlAction {
    var poll = ReconnectInputDispatcherPoll.init(control) catch return control.input_control.consumeAction();
    defer poll.deinit();
    poll.run(timeout_ms) catch return control.input_control.consumeAction();
    return poll.result;
}

// foreground proxy reconnect UI wait. It observes local
// control input and diagnostics while the process is between transport
// attempts, outside sesshd's daemon Dispatcher.
const ReconnectInputDispatcherPoll = struct {
    control: *ProxyReconnectControlContext,
    result: StreamControlAction = .none,
    done: bool = false,

    fn init(control: *ProxyReconnectControlContext) !ReconnectInputDispatcherPoll {
        return .{
            .control = control,
            .result = control.input_control.consumeAction(),
        };
    }

    fn deinit(_: *ReconnectInputDispatcherPoll) void {}

    // Wait for reconnect-control input while disconnected. This small foreground
    // poll loop is separate from the active stream loop because there may be no
    // transport fd to watch yet.
    fn run(self: *ReconnectInputDispatcherPoll, timeout_ms: i32) !void {
        var poll_set = ReconnectInputPollSet{};
        if (self.control.interrupt) |local_interrupt| {
            if (local_interrupt.read_fd >= 0) {
                poll_set.add(local_interrupt.read_fd, posix.POLL.IN, .interrupt);
            }
        }
        if (self.control.source_fd >= 0 and reconnectInputPollEnabled(self.control.input_control)) {
            poll_set.add(self.control.source_fd, source_poll_events, .input);
        }
        if (self.control.reconnect_input_fd >= 0 and reconnectInputPollEnabled(self.control.input_control)) {
            poll_set.add(self.control.reconnect_input_fd, posix.POLL.IN, .reconnect_input);
        }
        if (self.control.control_fd.* >= 0) {
            poll_set.add(self.control.control_fd.*, posix.POLL.IN, .control);
        }
        if (poll_set.count == 0 and timeout_ms < 0) return;
        const ready = try self.control.blocking.poll(poll_set.fdSlice(), timeout_ms);
        if (ready == 0) {
            self.finish(self.control.input_control.consumeAction());
            return;
        }
        for (poll_set.fdSlice(), poll_set.kindSlice()) |pollfd, kind| {
            if (self.done) break;
            if (pollfd.revents == 0) continue;
            const fd_event = fdEventFromRevents(pollfd.fd, pollfd.revents);
            if (!fd_event.readable and !fd_event.hangup and !fd_event.error_event and !fd_event.invalid) continue;
            self.handleFdEvent(kind);
        }
    }

    fn finish(self: *ReconnectInputDispatcherPoll, result: StreamControlAction) void {
        self.result = result;
        self.done = true;
    }

    fn handleFdEvent(self: *ReconnectInputDispatcherPoll, kind: ReconnectInputPollKind) void {
        switch (kind) {
            .interrupt => {
                if (self.control.interrupt) |local_interrupt| local_interrupt.consume();
                self.finish(.interrupt);
            },
            .input => self.finish(readReconnectInput(self.control.state, self.control.source_fd, self.control.input_control)),
            .reconnect_input => {
                readReconnectControlInput(self.control.reconnect_input_fd, self.control.input_control);
                self.finish(self.control.input_control.consumeAction());
            },
            .control => {
                if (!readControlInput(self.control.control_fd.*, self.control.input_control, &self.control.control_reader)) self.control.control_fd.* = -1;
                self.finish(self.control.input_control.consumeAction());
            },
        }
    }
};

const ReconnectInputPollKind = enum {
    interrupt,
    input,
    reconnect_input,
    control,
};

const ReconnectInputPollSet = poll_sets.PollSet(ReconnectInputPollKind, 4);

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
        state.source_eof = true;
        state.outbound.outbound_eof = true;
    } else {
        var filtered: [max_chunk_bytes]u8 = undefined;
        const filtered_bytes = input_control.filter(buf[0..@intCast(n)], &filtered);
        state.appendOutbound(filtered_bytes) catch {};
    }
    return input_control.consumeAction();
}

fn readReconnectControlInput(
    fd: c.fd_t,
    input_control: *StreamInputControl,
) void {
    var buf: [max_chunk_bytes]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return;
    input_control.observeControlOnly(buf[0..@intCast(n)]);
}

fn readControlInput(control_fd: c.fd_t, input_control: *StreamInputControl, reader: *proxy_diagnostics.Reader) bool {
    if (control_fd < 0) return false;
    const allocator = app_allocator.allocator();
    while (true) {
        var message = switch (reader.readReady(allocator, control_fd) catch return false) {
            .blocked, .progress => return true,
            .eof, .truncated_frame => return false,
            .message => |value| value,
        };
        defer message.deinit(allocator);
        switch (message.message) {
            .retry_now => input_control.reconnect_requested = true,
            else => {},
        }
    }
}

fn muxProxyDataFrame(payload: ProxyDataPayload) pb.DaemonTunnelItem.MuxStreamFrame {
    return .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .payload = .{
            .offset = payload.offset,
            .item = .{ .proxy = .{ .payload = .{ .data = payload.data } } },
        } },
    };
}

fn encodeMuxProxyDataPayload(allocator: std.mem.Allocator, payload: ProxyDataPayload) ![]u8 {
    return protocol.encodeMuxStreamFramePayload(allocator, muxProxyDataFrame(payload));
}

fn encodeMuxProxyEofPayload(allocator: std.mem.Allocator, offset: u64) ![]u8 {
    return protocol.encodeMuxStreamFramePayload(allocator, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .eof = .{ .final_offset = offset } },
    });
}

fn encodeMuxAckPayload(allocator: std.mem.Allocator, recv_next_offset: u64) ![]u8 {
    return protocol.encodeMuxStreamFramePayload(allocator, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .ack = .{
            .recv_next_offset = recv_next_offset,
        } },
    });
}

const test_support = if (builtin.is_test) struct {
    fn expectMuxStreamFrame(fd: c.fd_t) !pb.DaemonTunnelItem.MuxStreamFrame {
        var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, fd);
        defer frame.deinit(std.testing.allocator);
        try std.testing.expectEqual(protocol.MessageType.daemon_tunnel, frame.message_type);
        var mux = try protocol.decodeDaemonMuxStreamFrame(std.testing.allocator, frame.payload);
        errdefer mux.deinit(std.testing.allocator);
        try std.testing.expectEqual(proxy_mux_stream_id, mux.stream_id);
        return mux;
    }

    fn expectProxyDataFrame(fd: c.fd_t, expected_offset: u64, expected_data: []const u8) !void {
        // Test assertion for the nested proxy data frame: daemon-tunnel frame,
        // fixed proxy stream id, proxy payload, expected offset, expected bytes.
        var mux = try expectMuxStreamFrame(fd);
        defer mux.deinit(std.testing.allocator);
        const message = mux.message orelse return error.UnexpectedMuxFrame;
        switch (message) {
            .payload => |payload| {
                try std.testing.expectEqual(expected_offset, payload.offset);
                const item = payload.item orelse return error.UnexpectedMuxFrame;
                switch (item) {
                    .proxy => |proxy_item| {
                        const proxy_payload = proxy_item.payload orelse return error.UnexpectedMuxFrame;
                        switch (proxy_payload) {
                            .data => |data| try std.testing.expectEqualStrings(expected_data, data),
                            else => return error.UnexpectedMuxFrame,
                        }
                    },
                    else => return error.UnexpectedMuxFrame,
                }
            },
            else => return error.UnexpectedMuxFrame,
        }
    }

    fn expectProxyEofFrame(fd: c.fd_t, expected_offset: u64) !void {
        var mux = try expectMuxStreamFrame(fd);
        defer mux.deinit(std.testing.allocator);
        const message = mux.message orelse return error.UnexpectedMuxFrame;
        switch (message) {
            .eof => |eof| try std.testing.expectEqual(expected_offset, eof.final_offset),
            else => return error.UnexpectedMuxFrame,
        }
    }

    fn expectAckFrame(fd: c.fd_t, expected_offset: u64) !void {
        var mux = try expectMuxStreamFrame(fd);
        defer mux.deinit(std.testing.allocator);
        const message = mux.message orelse return error.UnexpectedMuxFrame;
        switch (message) {
            .ack => |ack| try std.testing.expectEqual(expected_offset, ack.recv_next_offset),
            else => return error.UnexpectedMuxFrame,
        }
    }

    fn expectResetFrame(fd: c.fd_t, expected_code: []const u8) !void {
        var mux = try expectMuxStreamFrame(fd);
        defer mux.deinit(std.testing.allocator);
        const message = mux.message orelse return error.UnexpectedMuxFrame;
        switch (message) {
            .reset => |reset| try std.testing.expectEqualStrings(expected_code, reset.code),
            else => return error.UnexpectedMuxFrame,
        }
    }

    fn activeClient(
        state: *StreamState,
        transport_write_fd: c.fd_t,
        options: StreamActiveClientOptions,
    ) !StreamActiveClient {
        // Construct the smallest active client needed by state-machine tests:
        // no readable transport, optional writable transport, and caller-owned
        // source/sink fds.
        if (transport_write_fd >= 0) try core_fds.setNonBlocking(transport_write_fd);
        return .{
            .state = state,
            .transport_fds = .{
                .read = -1,
                .write = transport_write_fd,
            },
            .transport_reader = protocol.FrameReader.init(std.testing.allocator),
            .transport_writer = dispatch_io.FrameSink.init(.{ .allocator = std.testing.allocator, .fd = -1 }),
            .transport_writer_initialized = true,
            .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
            .options = options,
            .liveness = StreamLiveness.init(1_000),
        };
    }

    fn drainActiveClient(active_client: *StreamActiveClient) !void {
        try std.testing.expectEqual(dispatch_io.SinkWriteStatus.drained, try active_client.drainTransportWrites());
    }

    fn fillPipe(write_fd: c.fd_t) !void {
        try core_fds.setNonBlocking(write_fd);
        const bytes = [_]u8{'x'} ** 4096;
        while (true) {
            const n = c.write(write_fd, &bytes, bytes.len);
            if (n > 0) continue;
            if (n == 0) return error.WriteFailed;
            switch (posix.errno(n)) {
                .AGAIN => return,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }

    fn expectNoReadable(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        try std.testing.expectEqual(@as(usize, 0), try blocking.poll(&pollfds, 0));
    }

    fn streamState() StreamState {
        return StreamState.init(.{
            .allocator = std.testing.allocator,
            .guid = "p-550e8400-e29b-41d4-a716-446655440000",
        });
    }
} else struct {};

test "stream frames round trip through a pipe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = test_support.streamState();
    defer state.deinit();
    try test_frames.sendData(.{
        .state = &state,
        .fd = fds[1],
        .payload = .{ .offset = 42, .data = "hello" },
    });
    try test_support.expectProxyDataFrame(fds[0], 42, "hello");
}

test "stream ping receives pong without changing offsets" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = test_support.streamState();
    defer state.deinit();
    const payload = try protocol.encodeDaemonTunnelPayload(std.testing.allocator, .{ .ping = .{} });
    const options = StreamActiveClientOptions{ .blocking = core_blocking.fromTest() };
    var active_client = try test_support.activeClient(&state, fds[1], options);
    defer active_client.deinit();

    try handleTransportFrame(&active_client, &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });
    try test_support.drainActiveClient(&active_client);

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.daemon_tunnel, frame.message_type);
    try std.testing.expectEqual(@as(u64, 0), state.inbound.recv_next_offset);
    try std.testing.expectEqual(@as(u64, 0), state.outbound.outboundNext());
}

test "proxy reconnect delay helper expires at deadline" {
    try std.testing.expectEqual(@as(?u64, 500), remainingDelayMs(1_500, 1_000));
    try std.testing.expectEqual(@as(?u64, null), remainingDelayMs(1_500, 1_500));
    try std.testing.expectEqual(@as(?u64, null), remainingDelayMs(1_500, 1_501));
}

test "stream sender sends only newly appended bytes on a live transport" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = test_support.streamState();
    defer state.deinit();
    state.peer_ready = true;

    try state.appendOutbound("first");
    try test_frames.sendPending(&state, fds[1]);
    try test_support.expectProxyDataFrame(fds[0], 0, "first");

    try state.appendOutbound("second");
    try test_frames.sendPending(&state, fds[1]);
    try test_support.expectProxyDataFrame(fds[0], 5, "second");
}

test "stream receiver keeps suffix from overlapping data frame" {
    const sink = try posix.pipe();
    defer posix.close(sink[0]);
    defer posix.close(sink[1]);
    const ack = try posix.pipe();
    defer posix.close(ack[0]);
    defer posix.close(ack[1]);

    var state = test_support.streamState();
    defer state.deinit();
    state.inbound.recv_next_offset = 5;

    const payload = try encodeMuxProxyDataPayload(std.testing.allocator, .{
        .offset = 0,
        .data = "firstsecond",
    });
    var options = StreamActiveClientOptions{ .blocking = core_blocking.fromTest() };
    options.sink = .{ .fd = sink[1] };
    var active_client = try test_support.activeClient(&state, ack[1], options);
    defer active_client.deinit();
    try handleTransportFrame(&active_client, &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });
    try test_support.drainActiveClient(&active_client);

    var delivered: [6]u8 = undefined;
    try core_blocking.fromTest().readExact(sink[0], &delivered);
    try std.testing.expectEqualStrings("second", delivered[0..]);

    try test_support.expectAckFrame(ack[0], 11);
}

test "stream receiver ACK waits for blocked sink delivery" {
    const sink = try posix.pipe();
    defer posix.close(sink[0]);
    defer posix.close(sink[1]);
    const ack = try posix.pipe();
    defer posix.close(ack[0]);
    defer posix.close(ack[1]);

    try test_support.fillPipe(sink[1]);

    var state = test_support.streamState();
    defer state.deinit();

    const payload = try encodeMuxProxyDataPayload(std.testing.allocator, .{
        .offset = 0,
        .data = "hello",
    });
    var options = StreamActiveClientOptions{ .blocking = core_blocking.fromTest() };
    options.sink = .{ .fd = sink[1] };
    var active_client = try test_support.activeClient(&state, ack[1], options);
    defer active_client.deinit();
    try handleTransportFrame(&active_client, &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });

    try std.testing.expectEqual(@as(u64, 0), state.inbound.recv_next_offset);
    try std.testing.expectEqualStrings("hello", state.pendingInboundData());
    try test_support.expectNoReadable(core_blocking.fromTest(), ack[0]);

    var drain: [8192]u8 = undefined;
    _ = c.read(sink[0], &drain, drain.len);
    try std.testing.expect(try active_client.drainSinkWrites());
    try test_support.drainActiveClient(&active_client);
    try std.testing.expectEqual(@as(u64, 5), state.inbound.recv_next_offset);
    try std.testing.expectEqual(@as(usize, 0), state.pendingInboundData().len);
    try test_support.expectAckFrame(ack[0], 5);
}

test "stream inbound eof can complete without generated outbound eof ack" {
    const transport_in = try posix.pipe();
    defer posix.close(transport_in[0]);
    defer posix.close(transport_in[1]);
    const transport_out = try posix.pipe();
    defer posix.close(transport_out[0]);
    defer posix.close(transport_out[1]);

    var state = test_support.streamState();
    defer state.deinit();
    state.peer_ready = true;

    const payload = try encodeMuxProxyEofPayload(std.testing.allocator, 0);
    defer std.testing.allocator.free(payload);
    try protocol_test_helpers.sendFrameBlocking(transport_in[1], .daemon_tunnel, payload);

    var active_client = StreamActiveClient{
        .state = &state,
        .transport_fds = .{
            .read = transport_in[0],
            .write = transport_out[1],
        },
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{
            .blocking = core_blocking.fromTest(),
            .close_outbound_on_inbound_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };
    defer active_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try active_client.step(1_000));

    try test_support.expectAckFrame(transport_out[0], 0);

    var pollfds = [_]posix.pollfd{.{
        .fd = transport_out[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&pollfds, 0));
}

test "stream source eof can reset proxy stream" {
    const source = try posix.pipe();
    defer posix.close(source[0]);
    posix.close(source[1]);

    const transport_in = try posix.pipe();
    defer posix.close(transport_in[0]);
    defer posix.close(transport_in[1]);
    const transport_out = try posix.pipe();
    defer posix.close(transport_out[0]);
    defer posix.close(transport_out[1]);

    var state = test_support.streamState();
    defer state.deinit();
    state.peer_ready = true;

    var active_client = StreamActiveClient{
        .state = &state,
        .transport_fds = .{
            .read = transport_in[0],
            .write = transport_out[1],
        },
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{
            .blocking = core_blocking.fromTest(),
            .source = .{ .fd = source[0] },
            .reset_on_source_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };
    defer active_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try active_client.step(1_000));
    try test_support.expectResetFrame(transport_out[0], "SOURCE_CLOSED");
}

test "disconnected proxy stream notices source eof before retry" {
    const source = try posix.pipe();
    defer posix.close(source[0]);
    posix.close(source[1]);

    var state = test_support.streamState();
    defer state.deinit();
    var input_control = StreamInputControl{ .enabled = false };

    try std.testing.expect(try disconnectedSourceClosed(core_blocking.fromTest(), &state, source[0], &input_control));
    try std.testing.expect(state.source_eof);
    try std.testing.expect(state.outbound.outbound_eof);
}

test "stream reset completes proxy stream" {
    const transport_in = try posix.pipe();
    defer posix.close(transport_in[0]);
    defer posix.close(transport_in[1]);
    const transport_out = try posix.pipe();
    defer posix.close(transport_out[0]);
    defer posix.close(transport_out[1]);

    var state = test_support.streamState();
    defer state.deinit();
    state.peer_ready = true;

    try test_frames.sendReset(&state, transport_in[1], .{
        .code = "CLIENT_DISCONNECT",
        .message = "test reset",
    });

    var active_client = StreamActiveClient{
        .state = &state,
        .transport_fds = .{
            .read = transport_in[0],
            .write = transport_out[1],
        },
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{ .blocking = core_blocking.fromTest() },
        .liveness = StreamLiveness.init(1_000),
    };
    defer active_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try active_client.step(1_000));
}

test "proxy mux close queues startup reset through dispatcher" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    closeProxyMuxStream(.{
        .allocator = std.testing.allocator,
        .stream = .{
            .stream_id = 42,
            .endpoint = .{ .fd = fds[1] },
            .open = .{},
            .cleanup_recorded = false,
        },
        .send_startup_failed = true,
        .daemon_dispatcher = &d,
    });
    _ = try d.loopForBlocking();

    try test_support.expectResetFrame(fds[0], "STARTUP_FAILED");
}

test "proxy mux close after cleanup record sends no startup reset" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var d = try dispatcher.Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    closeProxyMuxStream(.{
        .allocator = std.testing.allocator,
        .stream = .{
            .stream_id = 42,
            .endpoint = .{ .fd = fds[1] },
            .open = .{},
            .cleanup_recorded = true,
        },
        .send_startup_failed = true,
        .daemon_dispatcher = &d,
    });

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[0], &byte, byte.len));
}

test "stream completion waits for eof acknowledgement" {
    var state = test_support.streamState();
    defer state.deinit();
    state.outbound.outbound_eof = true;
    state.outbound.outbound_eof_sent = true;
    state.inbound.inbound_eof = true;

    try std.testing.expect(!state.complete());

    const payload = try encodeMuxAckPayload(std.testing.allocator, 0);
    const options = StreamActiveClientOptions{ .blocking = core_blocking.fromTest() };
    var active_client = try test_support.activeClient(&state, -1, options);
    defer active_client.deinit();
    try handleTransportFrame(&active_client, &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });
    try std.testing.expect(state.complete());
}

test "stream inbound eof can complete outbound when caller closes outbound on inbound eof" {
    const sink = try posix.pipe();
    defer posix.close(sink[0]);
    defer posix.close(sink[1]);
    const ack = try posix.pipe();
    defer posix.close(ack[0]);
    defer posix.close(ack[1]);

    var state = test_support.streamState();
    defer state.deinit();
    try state.appendOutbound("unsent local input");

    const payload = try encodeMuxProxyEofPayload(std.testing.allocator, 0);
    const options = StreamActiveClientOptions{
        .blocking = core_blocking.fromTest(),
        .sink = .{ .fd = sink[1] },
        .close_outbound_on_inbound_eof = true,
    };
    var active_client = try test_support.activeClient(&state, ack[1], options);
    defer active_client.deinit();
    try handleTransportFrame(&active_client, &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });
    try test_support.drainActiveClient(&active_client);

    try std.testing.expect(state.complete());
    try std.testing.expectEqual(@as(usize, 0), state.outbound.outbound.items.len);
}
