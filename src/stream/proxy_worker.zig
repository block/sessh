const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const app_allocator = @import("../core/app_allocator.zig");
const daemon_log = @import("../daemon/log.zig");
const protocol = @import("../protocol/mod.zig");
const protocol_test_helpers = @import("../protocol/test_helpers.zig");
const client_log = @import("../core/client_log.zig");
const proxy_diagnostics = @import("proxy_diagnostics_channel.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect = @import("../reconnect/mod.zig");
const byte_stream = @import("byte_stream.zig");
const mux_proxy = @import("mux_proxy.zig");
const proxy_remote = @import("proxy_remote.zig");
const raw_bridge = @import("raw_bridge.zig");
const status_output = @import("status_output.zig");
const terminal = @import("../tty/terminal.zig");
const pb = protocol.pb;

const max_buffered_bytes = 1024 * 1024;
const max_chunk_bytes = 16 * 1024;
const transport_ping_interval_ms: u64 = 1_000;
const stream_unresponsive_after_ms: u64 = 10_000;
const proxy_mux_stream_id: u64 = 1;
const StreamState = byte_stream.StreamState;

const StreamOutcome = union(enum) {
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

pub const StreamReconnectStatusMode = status_output.Mode;
pub const forwardRawDuplex = raw_bridge.forwardRawDuplex;
pub const ProxyMuxStream = mux_proxy.ProxyMuxStream;
pub const closeProxyMuxStreams = mux_proxy.closeProxyMuxStreams;
pub const closeProxyMuxStream = mux_proxy.closeProxyMuxStream;
pub const handleProxyMuxStreamFrame = mux_proxy.handleProxyMuxStreamFrame;
pub const handleProxyMuxOpen = mux_proxy.handleProxyMuxOpen;
pub const forwardProxyRemoteFrameToMux = mux_proxy.forwardProxyRemoteFrameToMux;
pub const handleProxyRemoteControlFrame = mux_proxy.handleProxyRemoteControlFrame;
pub const findProxyMuxStreamIndex = mux_proxy.findProxyMuxStreamIndex;
pub const findProxyMuxStreamIndexByWatch = mux_proxy.findProxyMuxStreamIndexByWatch;
pub const removeProxyMuxStream = mux_proxy.removeProxyMuxStream;
pub const sendProxyMuxReset = mux_proxy.sendProxyMuxReset;
pub const queueProxyMuxReset = mux_proxy.queueProxyMuxReset;
pub const drainProxyProcessWrites = mux_proxy.drainProxyProcessWrites;
const StreamReconnectStatus = status_output.Status;

pub const LocalStreamOptions = struct {
    guid: []const u8 = "",
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
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
// child reaped or the stream complete.
const source_poll_events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;

var local_stream_interrupt_write_fd: c.fd_t = -1;

fn handleLocalStreamInterrupt(_: c_int) callconv(.c) void {
    const fd = local_stream_interrupt_write_fd;
    if (fd < 0) return;
    var byte = [_]u8{1};
    _ = c.write(fd, &byte, byte.len);
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

const StreamAttachedClientOptions = struct {
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
                .disconnect => self.disconnect_requested = true,
                .help => self.help_requested = true,
                .repaint => {},
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

    fn observeControlOnly(self: *StreamInputControl, bytes: []const u8) void {
        var input = bytes;
        var scratch: [max_chunk_bytes]u8 = undefined;
        if (self.escape_enabled) {
            const result = self.escape_filter.filter(bytes, &scratch);
            if (result.end) |end| switch (end) {
                .disconnect => self.disconnect_requested = true,
                .help => self.help_requested = true,
                .repaint => {},
            };
            input = result.bytes;
        }

        if (!self.enabled or !self.status_visible) return;
        for (input) |byte| {
            if (byte == reconnect_control.ctrl_r) self.reconnect_requested = true;
        }
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
const StreamAttachedClient = struct {
    state: *StreamState,
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    transport_reader: protocol.FrameReader,
    control_reader: proxy_diagnostics.Reader,
    options: StreamAttachedClientOptions,
    liveness: StreamLiveness,
    interrupt_fd: c.fd_t = -1,

    fn init(
        state: *StreamState,
        transport_read_fd: c.fd_t,
        transport_write_fd: c.fd_t,
        options: StreamAttachedClientOptions,
    ) !StreamAttachedClient {
        state.peer_ready = false;
        state.outbound.outbound_eof_sent = false;
        try core_fds.setNonBlocking(transport_read_fd);
        sendResumeMessage(state, transport_write_fd, options.send_proxy_open) catch return error.StreamTransportClosed;
        const now_ms = nowMillis();
        return .{
            .state = state,
            .transport_read_fd = transport_read_fd,
            .transport_write_fd = transport_write_fd,
            .transport_reader = protocol.FrameReader.init(state.allocator),
            .control_reader = proxy_diagnostics.Reader.init(state.allocator),
            .options = options,
            .liveness = StreamLiveness.init(now_ms),
        };
    }

    fn deinit(self: *StreamAttachedClient) void {
        self.transport_reader.deinit();
        self.control_reader.deinit();
        self.* = undefined;
    }

    fn step(self: *StreamAttachedClient, requested_timeout_ms: i32) !StreamStepOutcome {
        const state = self.state;
        if (state.complete()) return .complete;

        // PROCESS_EVENT_LOOP: foreground proxy-stream client loop. It owns the
        // raw byte source, mux transport, diagnostics control, replacement
        // listener, and reconnect input for this process; sesshd-owned proxy
        // streams use the daemon dispatcher instead.
        const now_before_poll_ms = nowMillis();
        var pollfds: [1 + 1 + 1 + 1 + 2]posix.pollfd = undefined;
        var count: usize = 0;
        const transport_index = count;
        pollfds[count] = .{ .fd = self.transport_read_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;

        var source_poll_index: ?usize = null;
        const source = self.options.source;
        if (source.fd >= 0 and !state.outbound.outbound_eof and state.bufferedBytes() < max_buffered_bytes) {
            source_poll_index = count;
            pollfds[count] = .{ .fd = source.fd, .events = source_poll_events, .revents = 0 };
            count += 1;
        }

        var replacement_index: ?usize = null;
        if (self.options.replacement_listen_fd >= 0) {
            replacement_index = count;
            pollfds[count] = .{ .fd = self.options.replacement_listen_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        var control_index: ?usize = null;
        if (self.options.control_fd >= 0 and self.options.control_input != null) {
            control_index = count;
            pollfds[count] = .{ .fd = self.options.control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
            count += 1;
        }
        var reconnect_input_index: ?usize = null;
        if (self.options.reconnect_input_fd >= 0 and self.options.control_input != null) {
            if (self.options.control_input) |control| {
                if (reconnectInputPollEnabled(control)) {
                    reconnect_input_index = count;
                    pollfds[count] = .{ .fd = self.options.reconnect_input_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
                    count += 1;
                }
            }
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
                if (acceptWorkerClient(self.options.replacement_listen_fd)) |fd| return .{ .replacement = fd };
            }
        }
        if (interrupt_index) |index| {
            if (pollfds[index].revents != 0) return .interrupted;
        }
        if (control_index) |index| {
            if (pollfds[index].revents != 0) {
                if (self.options.control_input) |control| {
                    if (!readControlInput(self.options.control_fd, control, &self.control_reader)) self.options.control_fd = -1;
                }
            }
        }
        if (reconnect_input_index) |index| {
            if (pollfds[index].revents != 0) {
                if (self.options.control_input) |control| {
                    readReconnectControlInput(self.options.reconnect_input_fd, control);
                }
            }
        }

        if ((pollfds[transport_index].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[transport_index].revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((pollfds[transport_index].revents & posix.POLL.IN) != 0) {
            const frame = switch (self.transport_reader.readReady(self.transport_read_fd) catch return .transport_closed) {
                .blocked => return .idle,
                .progress => {
                    self.liveness.noteIncoming(nowMillis());
                    return .progress;
                },
                .eof, .truncated_frame => return .transport_closed,
                .frame => |frame_value| frame_value,
            };
            self.liveness.noteIncoming(nowMillis());
            handleFrame(
                state,
                self.transport_write_fd,
                &self.options,
                frame,
            ) catch |err| switch (err) {
                error.StreamReset => return .complete,
                error.StreamTransportWriteFailed => return .transport_closed,
                else => return err,
            };
            // A transport frame can make source bytes or EOF immediately useful
            // without any new source readiness. For example, a resume frame
            // tells us the peer is ready for retransmission, and inbound EOF can mark
            // our outbound side closed.
            try drainStreamSourcesNonBlocking(state, &self.options);
            if (try self.completeAfterSourceReset()) return .complete;
            if (state.complete()) return .complete;
            if (state.peer_ready) {
                sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                    error.WriteFailed => return .transport_closed,
                    else => return err,
                };
            }
            return .progress;
        }

        const source_ready = blk: {
            const poll_index = source_poll_index orelse break :blk false;
            if (pollfds[poll_index].revents != 0) {
                try readStreamSource(state, source);
                break :blk true;
            }
            break :blk false;
        };
        _ = source_ready;
        try drainStreamSourcesNonBlocking(state, &self.options);
        if (try self.completeAfterSourceReset()) return .complete;

        if (state.peer_ready) {
            sendPending(state, self.transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return .transport_closed,
                else => return err,
            };
        }
        return .idle;
    }

    fn completeAfterSourceReset(self: *StreamAttachedClient) !bool {
        if (!self.options.reset_on_source_eof or !self.state.source_eof) return false;
        try sendReset(self.state, self.transport_write_fd, "SOURCE_CLOSED", "local proxy stream closed");
        return true;
    }
};

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
    options: *const StreamAttachedClientOptions,
) !void {
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
                // from a child-status guess.
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
    return readSome(source.fd, buf);
}

fn readStreamSourceFdNonBlocking(source: StreamSource, buf: []u8) !ReadSomeResult {
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

    fn attachedClientOptions(self: *ProxyEndpoint, replacement_listen_fd: c.fd_t) StreamAttachedClientOptions {
        return .{
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

pub fn runRemoteWorker(allocator: std.mem.Allocator, guid: []const u8, replacement_listen_fd: c.fd_t, proxy_host: []const u8, proxy_port: u16) !void {
    var endpoint = try ProxyEndpoint.connect(allocator, proxy_host, proxy_port);
    defer endpoint.deinit();

    var state = StreamState.init(allocator, guid, "", 0);
    defer state.deinit();

    var attach_fd: c.fd_t = -1;
    defer {
        if (attach_fd >= 0) _ = c.close(attach_fd);
    }
    while (true) {
        if (attach_fd < 0) {
            var disconnected_options = endpoint.attachedClientOptions(replacement_listen_fd);
            attach_fd = try waitForReplacementWhileDisconnected(&state, replacement_listen_fd, &disconnected_options);
        }

        const outcome = try runAttachedStream(
            &state,
            attach_fd,
            attach_fd,
            endpoint.attachedClientOptions(replacement_listen_fd),
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

fn waitForReplacementWhileDisconnected(
    state: *StreamState,
    replacement_listen_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
) !c.fd_t {
    // PROCESS_EVENT_LOOP: remote proxy worker without an active transport.
    // It must keep draining its remote fd and accepting a replacement transport;
    // this is the process's main loop, not a helper-owned Dispatcher.
    while (true) {
        // The remote proxy process is durable even when no ssh transport is currently
        // attached. It must keep draining remote fds into the offset-tracked
        // buffers; otherwise the remote TCP peer can block before a
        // replacement transport attaches.
        var pollfds: [1 + 1]posix.pollfd = undefined;
        var count: usize = 0;
        const replacement_index = count;
        pollfds[count] = .{ .fd = replacement_listen_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;

        var source_poll_index: ?usize = null;
        const source = options.source;
        if (source.fd >= 0 and !state.outbound.outbound_eof and state.bufferedBytes() < max_buffered_bytes) {
            source_poll_index = count;
            pollfds[count] = .{ .fd = source.fd, .events = source_poll_events, .revents = 0 };
            count += 1;
        }

        _ = try posix.poll(pollfds[0..count], -1);
        if ((pollfds[replacement_index].revents & posix.POLL.IN) != 0) {
            if (acceptWorkerClient(replacement_listen_fd)) |fd| return fd;
        }

        if (source_poll_index) |poll_index| {
            if (pollfds[poll_index].revents != 0) {
                try readStreamSource(state, source);
            }
        }
        try drainStreamSourcesNonBlocking(state, options);
    }
}

fn acceptWorkerClient(listen_fd: c.fd_t) ?c.fd_t {
    const fd = c.accept(listen_fd, null, null);
    if (fd < 0) return null;
    setCloseOnExec(fd) catch {
        _ = c.close(fd);
        return null;
    };
    return fd;
}

/// Runs in the local `sessh` process. `start_transport` creates ssh transports
/// that execute the remote `sessh-broker` role; this loop owns local
/// stdin/stdout and the reconnect policy.
pub fn runLocalStream(
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: LocalStreamOptions,
) !u8 {
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    var control_fd = options.control_fd;
    if (control_fd >= 0) setNonBlockingFd(control_fd) catch {};
    if (options.reconnect_input_fd >= 0) setNonBlockingFd(options.reconnect_input_fd) catch {};

    var state = StreamState.init(allocator, options.guid, options.proxy_host, options.proxy_port);
    defer state.deinit();
    var input_control = StreamInputControl{
        .enabled = options.intercept_ctrl_r or options.reconnect_input_fd >= 0,
        .escape_enabled = options.intercept_escape,
    };
    const ctrl_r_status_enabled = options.ctrl_r_status_enabled orelse (options.intercept_ctrl_r or options.reconnect_input_fd >= 0);
    const status_fd = if (options.status_fd >= 0) options.status_fd else control_fd;
    var reconnect_status = StreamReconnectStatus.init(
        options.status_mode,
        ctrl_r_status_enabled,
        options.title_fallback,
        status_fd,
    );
    defer reconnect_status.deinit();
    var local_interrupt = try LocalStreamInterrupt.install();
    defer local_interrupt.deinit();

    var attempt: usize = 0;
    var had_transport = false;
    var retrying = false;

    client_loop: while (true) {
        var transport: Transport = undefined;
        if (retrying) reconnect_status.showReconnecting();
        transport = start_transport.start() catch |err| {
            // Before the first successful transport, a start failure usually
            // means ssh could not authenticate in BatchMode. Return that to
            // the outer ssh instead of retrying forever.
            if (!had_transport and !state.hasProgress()) {
                reconnect_status.flushDiagnostics();
                return err;
            }
            if (try disconnectedSourceClosed(&state, options.source_fd, &input_control)) return 0;
            const delay_ms = reconnect.delayMs(attempt);
            const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, options.reconnect_input_fd, &control_fd, &input_control, &local_interrupt);
            if (options.reset_on_source_eof and state.source_eof) return 0;
            if (action == .disconnect) return 0;
            if (action == .interrupt) return 255;
            attempt = reconnect.nextAttempt(attempt, action == .reconnect);
            retrying = true;
            continue;
        };
        had_transport = true;
        reconnect_status.flushDiagnostics();
        reconnect_status.clear();
        input_control.status_visible = false;

        transport_loop: while (true) {
            var attached_client = StreamAttachedClient.init(
                &state,
                transport.readFd(),
                transport.writeFd(),
                .{
                    .source = .{
                        .fd = options.source_fd,
                        .input_control = &input_control,
                    },
                    .sink = .{ .fd = options.sink_fd },
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
            defer attached_client.deinit();
            if (options.status_mode == .client_control and options.control_fd < 0 and options.status_fd < 0) {
                reconnect_status.setFd(transport.writeFd());
                reconnect_status.clear();
            }
            var old_unresponsive = false;
            while (true) {
                attached_client.interrupt_fd = local_interrupt.read_fd;
                const outcome = attached_client.step(-1) catch .transport_closed;
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
                            const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, options.reconnect_input_fd, &control_fd, &input_control, &local_interrupt);
                            if (action == .disconnect) return 0;
                            if (action == .interrupt) return 255;
                            attempt = reconnect.nextAttempt(attempt, action == .reconnect);
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
                        if (try disconnectedSourceClosed(&state, options.source_fd, &input_control)) return 0;
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
                        sendReset(&state, transport.writeFd(), "CLIENT_DISCONNECT", "local proxy stream disconnected") catch {};
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
        const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, options.reconnect_input_fd, &control_fd, &input_control, &local_interrupt);
        if (options.reset_on_source_eof and state.source_eof) return 0;
        if (action == .disconnect) return 0;
        if (action == .interrupt) return 255;
        attempt = reconnect.nextAttempt(attempt, action == .reconnect);
        retrying = true;
    }
}

fn disconnectedSourceClosed(
    state: *StreamState,
    source_fd: c.fd_t,
    input_control: *StreamInputControl,
) !bool {
    if (source_fd < 0) return false;
    var options = StreamAttachedClientOptions{
        .source = .{
            .fd = source_fd,
            .input_control = input_control,
        },
    };
    try drainStreamSourcesNonBlocking(state, &options);
    return state.source_eof;
}

fn runAttachedStream(
    state: *StreamState,
    transport_read_fd: c.fd_t,
    transport_write_fd: c.fd_t,
    options: StreamAttachedClientOptions,
) !StreamOutcome {
    var attached_client = StreamAttachedClient.init(
        state,
        transport_read_fd,
        transport_write_fd,
        options,
    ) catch return .transport_closed;

    while (true) {
        switch (try attached_client.step(-1)) {
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
    options: *const StreamAttachedClientOptions,
    frame: protocol.OwnedFrame,
) !void {
    var mutable = frame;
    defer mutable.deinit(state.allocator);

    switch (mutable.message_type) {
        .daemon_tunnel => {
            if (protocol.handleTransportControlFrame(mutable.message_type, mutable.payload, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            }) return;
            var message = try protocol.decodeDaemonMuxStreamFrame(state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try handleMuxStreamFrame(state, transport_write_fd, options, message);
        },
        .error_message => {
            var message = try protocol.decodePayload(protocol.hpb.Error, state.allocator, mutable.payload);
            defer message.deinit(state.allocator);
            try io.stderrPrint("sessh: {s}\n", .{message.message});
            if (message.hint) |hint| {
                if (hint.len > 0) try io.stderrPrint("{s}\n", .{hint});
            }
            return error.StreamReset;
        },
        .client_daemon => {
            var item = try protocol.decodePayload(pb.ClientDaemonItem, state.allocator, mutable.payload);
            defer item.deinit(state.allocator);
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

fn handleMuxStreamFrame(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    if (frame.stream_id != proxy_mux_stream_id) return error.StreamUnexpectedFrame;
    const message = frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| {
            state.peer_ready = true;
            try handleResumeOffset(state, open.recv_next_offset);
            sendOpenOk(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
            sendPending(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .open_ok => |open_ok| {
            state.peer_ready = true;
            try handleAck(state, open_ok.recv_next_offset);
            sendPending(state, transport_write_fd) catch |err| switch (err) {
                error.WriteFailed => return error.StreamTransportWriteFailed,
                else => return err,
            };
        },
        .ack => |ack| try handleAck(state, ack.recv_next_offset),
        .payload => |payload| {
            const item = payload.item orelse return error.StreamUnexpectedFrame;
            switch (item) {
                .proxy => |proxy_item| try handleProxyStreamPayload(state, transport_write_fd, options, payload.offset, proxy_item),
                .terminal_emulator => return error.StreamUnexpectedFrame,
            }
        },
        .eof => |eof| try handleInboundEof(
            state,
            transport_write_fd,
            options,
            eof.final_offset,
        ),
        .reset => return error.StreamReset,
    }
}

fn handleProxyStreamPayload(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    offset: u64,
    item: pb.ProxyStreamItem,
) !void {
    const payload = item.payload orelse return error.StreamUnexpectedFrame;
    switch (payload) {
        .data => |data| try handleInboundData(
            state,
            transport_write_fd,
            options,
            offset,
            data,
        ),
        else => return error.StreamUnexpectedFrame,
    }
}

fn handleResumeOffset(state: *StreamState, offset: u64) !void {
    try state.resumeOutbound(offset);
}

fn handleAck(state: *StreamState, offset: u64) !void {
    try state.ackOutbound(offset);
}

fn handleInboundData(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    offset: u64,
    data: []const u8,
) !void {
    const sink = options.sink;
    const inbound = try state.acceptInboundData(offset, data);
    if (inbound.new_data.len != 0 and sink.fd < 0) return error.StreamSinkClosed;
    if (inbound.new_data.len != 0) try deliverInboundData(options, sink.fd, inbound.new_data);
    sendAck(state, transport_write_fd, state.inbound.recv_next_offset) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTransportWriteFailed,
        else => return err,
    };
}

fn handleInboundEof(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    final_offset: u64,
) !void {
    try state.markInboundEof(final_offset);
    const sink = options.sink;
    if (sink.shutdown_on_eof and sink.fd >= 0) _ = c.shutdown(sink.fd, c.SHUT.WR);
    if (sink.close_fd_on_eof) |sink_fd_ptr| {
        if (sink_fd_ptr.* >= 0) {
            _ = c.close(sink_fd_ptr.*);
            sink_fd_ptr.* = -1;
        }
    }
    if (options.close_outbound_on_inbound_eof and state.inbound.inbound_eof) {
        state.completeOutboundAfterInboundEof();
    }
    sendAck(state, transport_write_fd, state.inbound.recv_next_offset) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTransportWriteFailed,
        else => return err,
    };
}

fn deliverInboundData(options: *const StreamAttachedClientOptions, sink_fd: c.fd_t, bytes: []const u8) !void {
    if (options.reconnect_status) |status| status.observeInbound(bytes);
    try io.writeAll(sink_fd, bytes);
}

fn sendResumeMessage(state: *StreamState, fd: c.fd_t, send_proxy_open: bool) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open = .{
            .recv_next_offset = state.inbound.recv_next_offset,
        } },
    });
    if (!send_proxy_open) return;
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .payload = .{
            .offset = 0,
            .item = .{ .proxy = .{ .payload = .{ .open = .{
                .proxy_guid = state.guid,
                .proxy_host = state.proxy_host,
                .proxy_port = state.proxy_port,
            } } } },
        } },
    });
}

fn sendOpenOk(state: *StreamState, fd: c.fd_t) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open_ok = .{
            .recv_next_offset = state.inbound.recv_next_offset,
        } },
    });
}

fn sendAck(state: *StreamState, fd: c.fd_t, offset: u64) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .ack = .{
            .recv_next_offset = offset,
        } },
    });
}

fn sendData(
    state: *StreamState,
    fd: c.fd_t,
    offset: u64,
    data: []const u8,
) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .payload = .{
            .offset = offset,
            .item = .{ .proxy = .{ .payload = .{ .data = data } } },
        } },
    });
}

fn sendEof(state: *StreamState, fd: c.fd_t, offset: u64) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .eof = .{ .final_offset = offset } },
    });
}

fn sendReset(state: *StreamState, fd: c.fd_t, code: []const u8, message: []const u8) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendPending(state: *StreamState, transport_write_fd: c.fd_t) !void {
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
        try sendData(state, transport_write_fd, offset, outbound.outbound.items[index .. index + len]);
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
    try protocol.sendMuxStreamFrame(allocator, fd, message);
}

fn abortTransport(transport: anytype) void {
    const Transport = @TypeOf(transport.*);
    if (@hasDecl(Transport, "terminate")) {
        transport.terminate();
    } else {
        transport.close();
    }
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

pub fn requestProxyRemoteCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    return proxy_remote.requestCleanup(allocator, guid);
}

pub fn forgetProxyRemote(guid: []const u8) void {
    proxy_remote.forget(guid);
}

pub fn activeProxyRemoteProcessCount() usize {
    return proxy_remote.activeCount();
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
    reconnect_input_fd: c.fd_t,
    control_fd: *c.fd_t,
    input_control: *StreamInputControl,
    interrupt: ?*LocalStreamInterrupt,
) StreamControlAction {
    var remaining_ms = delay_ms;
    var control_reader = proxy_diagnostics.Reader.init(state.allocator);
    defer control_reader.deinit();
    while (remaining_ms > 0) {
        status.showRetry(remaining_ms);
        input_control.status_visible = true;
        const step_ms = @min(remaining_ms, 1_000);
        const action = pollReconnectInput(state, source_fd, reconnect_input_fd, control_fd, input_control, &control_reader, interrupt, @intCast(step_ms));
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
    reconnect_input_fd: c.fd_t,
    control_fd: *c.fd_t,
    input_control: *StreamInputControl,
    control_reader: *proxy_diagnostics.Reader,
    interrupt: ?*LocalStreamInterrupt,
    timeout_ms: i32,
) StreamControlAction {
    // BLOCKING_POLL: foreground proxy-stream reconnect/control helper. It is
    // called by the stream client loop to multiplex local reconnect input and
    // diagnostics control without creating a second process dispatcher.
    var pollfds: [4]posix.pollfd = undefined;
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
    if (source_fd >= 0 and reconnectInputPollEnabled(input_control)) {
        input_index = count;
        pollfds[count] = .{ .fd = source_fd, .events = posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    var reconnect_input_index: ?usize = null;
    if (reconnect_input_fd >= 0 and reconnectInputPollEnabled(input_control)) {
        reconnect_input_index = count;
        pollfds[count] = .{ .fd = reconnect_input_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
    }
    var control_index: ?usize = null;
    if (control_fd.* >= 0) {
        control_index = count;
        pollfds[count] = .{ .fd = control_fd.*, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
        count += 1;
    }

    if (count == 0) {
        // BLOCKING_POLL: no reconnect/control fds are currently active, so this
        // foreground stream process has nothing else to service until the next
        // scheduled input-control check.
        if (timeout_ms > 0) _ = posix.poll(pollfds[0..0], timeout_ms) catch 0;
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
    if (reconnect_input_index) |index| {
        if (pollfds[index].revents != 0) {
            readReconnectControlInput(reconnect_input_fd, input_control);
        }
    }
    if (control_index) |index| {
        if (pollfds[index].revents != 0) {
            if (!readControlInput(control_fd.*, input_control, control_reader)) control_fd.* = -1;
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

fn encodeMuxProxyDataPayload(allocator: std.mem.Allocator, offset: u64, data: []const u8) ![]u8 {
    return protocol.encodeMuxStreamFramePayload(allocator, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .payload = .{
            .offset = offset,
            .item = .{ .proxy = .{ .payload = .{ .data = data } } },
        } },
    });
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

test "stream frames round trip through a pipe" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    try sendData(&state, fds[1], 42, "hello");
    try expectProxyDataFrame(fds[0], 42, "hello");
}

test "stream ping receives pong without changing offsets" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    const payload = try protocol.encodeDaemonTunnelPayload(std.testing.allocator, .{ .ping = .{} });
    const options = StreamAttachedClientOptions{};
    try handleFrame(&state, fds[1], &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });

    var frame = try protocol_test_helpers.readFrameForTest(std.testing.allocator, fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.daemon_tunnel, frame.message_type);
    try std.testing.expectEqual(@as(u64, 0), state.inbound.recv_next_offset);
    try std.testing.expectEqual(@as(u64, 0), state.outbound.outboundNext());
}

test "stream sender sends only newly appended bytes on a live transport" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.peer_ready = true;

    try state.appendOutbound("first");
    try sendPending(&state, fds[1]);
    try expectProxyDataFrame(fds[0], 0, "first");

    try state.appendOutbound("second");
    try sendPending(&state, fds[1]);
    try expectProxyDataFrame(fds[0], 5, "second");
}

test "stream receiver keeps suffix from overlapping data frame" {
    const sink = try posix.pipe();
    defer posix.close(sink[0]);
    defer posix.close(sink[1]);
    const ack = try posix.pipe();
    defer posix.close(ack[0]);
    defer posix.close(ack[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.inbound.recv_next_offset = 5;

    const payload = try encodeMuxProxyDataPayload(std.testing.allocator, 0, "firstsecond");
    var options = StreamAttachedClientOptions{};
    options.sink = .{ .fd = sink[1] };
    try handleFrame(&state, ack[1], &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });

    var delivered: [6]u8 = undefined;
    try io.readExact(sink[0], &delivered);
    try std.testing.expectEqualStrings("second", delivered[0..]);

    try expectAckFrame(ack[0], 11);
}

test "stream inbound eof can complete without generated outbound eof ack" {
    const transport_in = try posix.pipe();
    defer posix.close(transport_in[0]);
    defer posix.close(transport_in[1]);
    const transport_out = try posix.pipe();
    defer posix.close(transport_out[0]);
    defer posix.close(transport_out[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.peer_ready = true;

    const payload = try encodeMuxProxyEofPayload(std.testing.allocator, 0);
    defer std.testing.allocator.free(payload);
    try protocol.sendFrame(transport_in[1], .daemon_tunnel, payload);

    var attached_client = StreamAttachedClient{
        .state = &state,
        .transport_read_fd = transport_in[0],
        .transport_write_fd = transport_out[1],
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{
            .close_outbound_on_inbound_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };
    defer attached_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try attached_client.step(1_000));

    try expectAckFrame(transport_out[0], 0);

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

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.peer_ready = true;

    var attached_client = StreamAttachedClient{
        .state = &state,
        .transport_read_fd = transport_in[0],
        .transport_write_fd = transport_out[1],
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{
            .source = .{ .fd = source[0] },
            .reset_on_source_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };
    defer attached_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try attached_client.step(1_000));
    try expectResetFrame(transport_out[0], "SOURCE_CLOSED");
}

test "disconnected proxy stream notices source eof before retry" {
    const source = try posix.pipe();
    defer posix.close(source[0]);
    posix.close(source[1]);

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    var input_control = StreamInputControl{ .enabled = false };

    try std.testing.expect(try disconnectedSourceClosed(&state, source[0], &input_control));
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

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.peer_ready = true;

    try sendReset(&state, transport_in[1], "CLIENT_DISCONNECT", "test reset");

    var attached_client = StreamAttachedClient{
        .state = &state,
        .transport_read_fd = transport_in[0],
        .transport_write_fd = transport_out[1],
        .transport_reader = protocol.FrameReader.init(std.testing.allocator),
        .control_reader = proxy_diagnostics.Reader.init(std.testing.allocator),
        .options = .{},
        .liveness = StreamLiveness.init(1_000),
    };
    defer attached_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try attached_client.step(1_000));
}

test "proxy mux close resets unrecorded remote process startup" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    closeProxyMuxStream(std.testing.allocator, .{
        .stream_id = 42,
        .process_fd = fds[1],
        .open = .{},
        .cleanup_recorded = false,
    }, true, null);

    try expectResetFrame(fds[0], "STARTUP_FAILED");
}

test "proxy mux close after cleanup record sends no startup reset" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    closeProxyMuxStream(std.testing.allocator, .{
        .stream_id = 42,
        .process_fd = fds[1],
        .open = .{},
        .cleanup_recorded = true,
    }, true, null);

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[0], &byte, byte.len));
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

test "stream control-only input never forwards bytes" {
    var control = StreamInputControl{
        .enabled = true,
        .status_visible = true,
    };

    control.observeControlOnly("a\x12b");
    try std.testing.expectEqual(StreamControlAction.reconnect, control.consumeAction());

    control.observeControlOnly("abc");
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());

    control.status_visible = false;
    control.observeControlOnly("\x12");
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
}

test "stream input control uses ssh disconnect escape for no-terminal-emulator streams" {
    var control = StreamInputControl{
        .enabled = true,
        .escape_enabled = true,
        .status_visible = true,
    };
    var out: [16]u8 = undefined;

    try std.testing.expectEqualStrings("", control.filter("~.", &out));
    try std.testing.expectEqual(StreamControlAction.disconnect, control.consumeAction());

    try std.testing.expectEqualStrings("~k", control.filter("~k", &out));
    try std.testing.expectEqual(StreamControlAction.none, control.consumeAction());
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

test "stream completion waits for eof acknowledgement" {
    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    state.outbound.outbound_eof = true;
    state.outbound.outbound_eof_sent = true;
    state.inbound.inbound_eof = true;

    try std.testing.expect(!state.complete());

    const payload = try encodeMuxAckPayload(std.testing.allocator, 0);
    const options = StreamAttachedClientOptions{};
    try handleFrame(&state, -1, &options, .{
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

    var state = StreamState.init(std.testing.allocator, "p-550e8400-e29b-41d4-a716-446655440000", "", 0);
    defer state.deinit();
    try state.appendOutbound("unsent local input");

    const payload = try encodeMuxProxyEofPayload(std.testing.allocator, 0);
    const options = StreamAttachedClientOptions{
        .sink = .{ .fd = sink[1] },
        .close_outbound_on_inbound_eof = true,
    };
    try handleFrame(&state, ack[1], &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });

    try std.testing.expect(state.complete());
    try std.testing.expectEqual(@as(usize, 0), state.outbound.outbound.items.len);
}
