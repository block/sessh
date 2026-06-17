const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher = @import("../core/dispatcher.zig");
const app_allocator = @import("../core/app_allocator.zig");
const daemon_cleanup = @import("../daemon/cleanup.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const socket_transport = @import("../transport/socket.zig");
const local_boot_time = @import("../core/local_boot_time.zig");
const protocol = @import("../protocol/mod.zig");
const client_log = @import("../core/client_log.zig");
const proxy_control = @import("proxy_control.zig");
const reconnect_control = @import("../reconnect/control.zig");
const reconnect = @import("../reconnect/mod.zig");
const reconnect_title = @import("../reconnect/title.zig");
const session_registry = @import("../runtime/session_registry.zig");
const terminal = @import("../tty/terminal.zig");
const pb = protocol.pb;

const max_buffered_bytes = 1024 * 1024;
const max_chunk_bytes = 16 * 1024;
const transport_ping_interval_ms: u64 = 1_000;
const stream_unresponsive_after_ms: u64 = 10_000;
const proxy_mux_stream_id: u64 = 1;

// POSIX WNOHANG. Zig 0.15 does not expose a portable constant, and our
// supported Unix targets use the stable POSIX value.
const wait_nohang: c_int = 1;

const StreamOutcome = union(enum) {
    complete,
    transport_closed,
    unresponsive,
    replacement: c.fd_t,
};

pub const StreamReconnectStatusMode = enum {
    disabled,
    stderr_plain,
    status_line,
    title,
    jsonl,
    client_control,
};

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

const StreamByteState = struct {
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

    fn outboundNext(self: *const StreamByteState) u64 {
        return self.outbound_base + self.outbound.items.len;
    }

    fn bufferedBytes(self: *const StreamByteState) usize {
        return self.outbound.items.len;
    }

    fn deinit(self: *StreamByteState, allocator: std.mem.Allocator) void {
        self.outbound.deinit(allocator);
        self.* = undefined;
    }
};

// Tracks one byte stream in each direction. The local side appends source bytes
// to `outbound`; peer data advances `inbound.recv_next_offset`.
const StreamState = struct {
    allocator: std.mem.Allocator,
    guid: []const u8,
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    outbound: StreamByteState = .{},
    inbound: StreamByteState = .{},
    peer_ready: bool = false,
    source_eof: bool = false,

    fn init(allocator: std.mem.Allocator, guid: []const u8, proxy_host: []const u8, proxy_port: u16) StreamState {
        return .{
            .allocator = allocator,
            .guid = guid,
            .proxy_host = proxy_host,
            .proxy_port = proxy_port,
        };
    }

    fn deinit(self: *StreamState) void {
        self.outbound.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendOutbound(self: *StreamState, bytes: []const u8) !void {
        try self.outbound.outbound.appendSlice(self.allocator, bytes);
    }

    fn dropOutboundThrough(self: *StreamState, offset: u64) !void {
        if (offset < self.outbound.outbound_base) return;
        if (offset > self.outbound.outboundNext()) return error.StreamAckOutOfRange;
        const drop: usize = @intCast(offset - self.outbound.outbound_base);
        if (drop == 0) return;
        const remaining = self.outbound.outbound.items.len - drop;
        std.mem.copyForwards(u8, self.outbound.outbound.items[0..remaining], self.outbound.outbound.items[drop..]);
        self.outbound.outbound.shrinkRetainingCapacity(remaining);
        self.outbound.outbound_base = offset;
    }

    fn bufferedBytes(self: *const StreamState) usize {
        return self.outbound.bufferedBytes();
    }

    fn complete(self: *const StreamState) bool {
        return self.outbound.outbound_eof and
            self.outbound.outbound_eof_acked and
            self.outbound.outbound.items.len == 0 and
            self.inbound.inbound_eof;
    }

    fn hasProgress(self: *const StreamState) bool {
        return self.inbound.recv_next_offset != 0 or
            self.outbound.outbound_base != 0 or
            self.outbound.outbound.items.len != 0;
    }
};

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

const ProxyRemoteProcess = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    socket_path: []u8,
    pid: c.pid_t = 0,

    fn deinit(self: *ProxyRemoteProcess) void {
        self.allocator.free(self.guid);
        self.allocator.free(self.socket_path);
        self.* = undefined;
    }
};

var proxy_remote_processes: std.ArrayList(*ProxyRemoteProcess) = .empty;
var proxy_remote_socket_sequence: u64 = 0;

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
    control_reader: proxy_control.Reader,
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
            .control_reader = proxy_control.Reader.init(state.allocator),
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
                if (acceptRuntimeClient(self.options.replacement_listen_fd)) |fd| return .{ .replacement = fd };
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

pub const ProxyMuxStream = struct {
    stream_id: u64,
    process_fd: c.fd_t = -1,
    process_watch_id: ?dispatcher.FdWatchId = null,
    reader: protocol.FrameReader = undefined,
    reader_initialized: bool = false,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
    proxy_guid: [session_registry.proxy_guid_len]u8 = [_]u8{0} ** session_registry.proxy_guid_len,
    proxy_guid_len: usize = 0,
    cleanup_recorded: bool = false,

    pub fn proxyGuidSlice(self: *const ProxyMuxStream) []const u8 {
        return self.proxy_guid[0..self.proxy_guid_len];
    }

    fn setProxyGuid(self: *ProxyMuxStream, guid: []const u8) !void {
        if (guid.len > self.proxy_guid.len) return error.ProxyGuidTooLarge;
        @memcpy(self.proxy_guid[0..guid.len], guid);
        self.proxy_guid_len = guid.len;
    }
};

pub fn closeProxyMuxStreams(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    for (streams.items) |stream| {
        closeProxyMuxStream(allocator, stream, true, daemon_dispatcher);
    }
    streams.deinit(allocator);
}

pub fn closeProxyMuxStream(
    allocator: std.mem.Allocator,
    stream: ProxyMuxStream,
    send_startup_failed: bool,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) void {
    if (daemon_dispatcher) |d| {
        if (stream.process_watch_id) |watch_id| d.cancel(.{ .fd = watch_id });
    }
    if (stream.process_fd >= 0 and send_startup_failed and !stream.cleanup_recorded) {
        sendProxyMuxReset(allocator, stream.process_fd, proxy_mux_stream_id, "STARTUP_FAILED", "proxy cleanup record was not acknowledged") catch {};
    }
    if (stream.process_fd >= 0) _ = c.close(stream.process_fd);
    var moved_stream = stream;
    if (moved_stream.reader_initialized) moved_stream.reader.deinit();
}

pub fn handleProxyMuxStreamFrame(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_fd: c.fd_t,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    var owned_mux_frame = mux_frame;
    defer owned_mux_frame.deinit(allocator);
    const message = owned_mux_frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| try handleProxyMuxOpen(allocator, streams, owned_mux_frame.stream_id, open),
        .payload => |payload| try handleProxyMuxPayload(allocator, exe, identity, streams, mux_fd, owned_mux_frame.stream_id, payload, owned_mux_frame, process_watch_handler, daemon_dispatcher),
        .open_ok, .ack, .eof => try forwardProxyMuxFrameToProxyRemote(allocator, streams, owned_mux_frame),
        .reset => {
            forwardProxyMuxFrameToProxyRemote(allocator, streams, owned_mux_frame) catch {};
            try removeProxyMuxStream(allocator, streams, owned_mux_frame.stream_id, daemon_dispatcher);
        },
    }
}

pub fn handleProxyMuxOpen(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    stream_id: u64,
    open: pb.DaemonTunnelItem.MuxStreamFrame.Open,
) !void {
    if (findProxyMuxStreamIndex(streams, stream_id)) |index| {
        streams.items[index].open = open;
        if (streams.items[index].process_fd >= 0) {
            try sendProxyMuxFrame(allocator, streams.items[index].process_fd, .{
                .stream_id = proxy_mux_stream_id,
                .message = .{ .open = open },
            });
        }
        return;
    }
    try streams.append(allocator, .{
        .stream_id = stream_id,
        .open = open,
    });
}

fn handleProxyMuxPayload(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_fd: c.fd_t,
    stream_id: u64,
    payload: pb.DaemonTunnelItem.MuxStreamFrame.Payload,
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const item = payload.item orelse return error.StreamUnexpectedFrame;
    const proxy_item = switch (item) {
        .proxy => |proxy| proxy,
        else => return error.StreamUnexpectedFrame,
    };
    const proxy_payload = proxy_item.payload orelse return error.StreamUnexpectedFrame;
    switch (proxy_payload) {
        .open => |request| try handleProxyMuxPayloadOpen(allocator, exe, identity, streams, mux_fd, stream_id, request, process_watch_handler, daemon_dispatcher),
        .data => try forwardProxyMuxFrameToProxyRemote(allocator, streams, mux_frame),
    }
}

fn handleProxyMuxPayloadOpen(
    allocator: std.mem.Allocator,
    exe: []const u8,
    identity: daemon_identity.DaemonIdentity,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_fd: c.fd_t,
    stream_id: u64,
    request: pb.ProxyStreamItem.Open,
    process_watch_handler: ?dispatcher.Handler,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findProxyMuxStreamIndex(streams, stream_id) orelse return error.StreamUnexpectedFrame;
    if (streams.items[index].process_fd >= 0) return;
    if (!session_registry.isValidProxyGuid(request.proxy_guid)) return error.InvalidStreamGuid;
    if (request.proxy_port == 0 or request.proxy_port > std.math.maxInt(u16)) return error.InvalidStreamArgs;

    const remote_process = try connectOrStartProxyRemote(
        allocator,
        exe,
        request.proxy_guid,
        request.proxy_host,
        @intCast(request.proxy_port),
    );
    const process_fd = try connectStartedProxyRemote(remote_process);
    errdefer _ = c.close(process_fd);
    if (daemon_dispatcher != null) {
        try core_fds.setNonBlocking(process_fd);
    }

    try sendProxyMuxFrame(allocator, process_fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open = streams.items[index].open },
    });
    streams.items[index].process_fd = process_fd;
    const canonical = try session_registry.canonicalProxyGuid(allocator, request.proxy_guid);
    defer allocator.free(canonical);
    try streams.items[index].setProxyGuid(canonical);
    try daemon_cleanup.sendRemoteProcessStarted(
        allocator,
        mux_fd,
        stream_id,
        daemon_cleanup.makeRemoteProcessIdentity(identity, canonical),
    );
    if (daemon_dispatcher) |d| {
        const handler = process_watch_handler orelse return error.MissingProxyRemoteHandler;
        streams.items[index].reader = protocol.FrameReader.init(allocator);
        streams.items[index].reader_initialized = true;
        streams.items[index].process_watch_id = try d.watchFd(process_fd, .{ .readable = true }, .{
            .ctx = handler.ctx,
            .callback = handler.callback,
        });
    }
}

fn forwardProxyMuxFrameToProxyRemote(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    mux_frame: pb.DaemonTunnelItem.MuxStreamFrame,
) !void {
    const index = findProxyMuxStreamIndex(streams, mux_frame.stream_id) orelse return error.StreamUnexpectedFrame;
    if (streams.items[index].process_fd < 0) return error.StreamUnexpectedFrame;
    var remapped = mux_frame;
    remapped.stream_id = proxy_mux_stream_id;
    try sendProxyMuxFrame(allocator, streams.items[index].process_fd, remapped);
}

pub fn forwardProxyRemoteFrameToMux(
    allocator: std.mem.Allocator,
    mux_fd: c.fd_t,
    stream: *ProxyMuxStream,
    frame: *protocol.OwnedFrame,
) !bool {
    if (frame.message_type != .daemon_tunnel) return error.StreamUnexpectedFrame;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    mux_frame.stream_id = stream.stream_id;
    try sendProxyMuxFrame(allocator, mux_fd, mux_frame);
    return true;
}

pub fn findProxyMuxStreamIndex(streams: *const std.ArrayList(ProxyMuxStream), stream_id: u64) ?usize {
    for (streams.items, 0..) |stream, index| {
        if (stream.stream_id == stream_id) return index;
    }
    return null;
}

pub fn findProxyMuxStreamIndexByWatch(streams: *const std.ArrayList(ProxyMuxStream), watch_id: dispatcher.FdWatchId) ?usize {
    for (streams.items, 0..) |stream, index| {
        const process_watch_id = stream.process_watch_id orelse continue;
        if (process_watch_id.index == watch_id.index and process_watch_id.generation == watch_id.generation) return index;
    }
    return null;
}

pub fn removeProxyMuxStream(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxStream),
    stream_id: u64,
    daemon_dispatcher: ?*dispatcher.Dispatcher,
) !void {
    const index = findProxyMuxStreamIndex(streams, stream_id) orelse return;
    const stream = streams.swapRemove(index);
    closeProxyMuxStream(allocator, stream, false, daemon_dispatcher);
}

pub fn sendProxyMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendProxyMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendProxyMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.DaemonTunnelItem.MuxStreamFrame) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, message);
}

fn runProxyRemote(allocator: std.mem.Allocator, guid: []const u8, replacement_listen_fd: c.fd_t, proxy_host: []const u8, proxy_port: u16) !void {
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
    // PROCESS_EVENT_LOOP: remote proxy runtime while detached from a transport.
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
            if (acceptRuntimeClient(replacement_listen_fd)) |fd| return fd;
        }

        if (source_poll_index) |poll_index| {
            if (pollfds[poll_index].revents != 0) {
                try readStreamSource(state, source);
            }
        }
        try drainStreamSourcesNonBlocking(state, options);
    }
}

fn acceptRuntimeClient(listen_fd: c.fd_t) ?c.fd_t {
    const fd = c.accept(listen_fd, null, null);
    if (fd < 0) return null;
    setCloseOnExec(fd) catch {
        _ = c.close(fd);
        return null;
    };
    return fd;
}

/// Runs in the local `sessh` process. `start_transport` creates ssh transports
/// that execute the remote `:broker:` entrypoint; this loop owns local
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
            const delay_ms = reconnect.delayMs(attempt);
            const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, options.reconnect_input_fd, &control_fd, &input_control, &local_interrupt);
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
    state.outbound.peer_recv = offset;
    try state.dropOutboundThrough(offset);
    state.outbound.outbound_sent_next = offset;
}

fn handleAck(state: *StreamState, offset: u64) !void {
    state.outbound.peer_recv = offset;
    try state.dropOutboundThrough(offset);
    if (state.outbound.outbound_sent_next < offset) state.outbound.outbound_sent_next = offset;
    if (state.outbound.outbound_eof_sent and offset == state.outbound.outboundNext()) {
        state.outbound.outbound_eof_acked = true;
    }
}

fn handleInboundData(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    offset: u64,
    data: []const u8,
) !void {
    const sink = options.sink;
    if (offset < state.inbound.recv_next_offset) {
        // Reconnect retransmits from the peer's last confirmed offset. If a
        // frame overlaps bytes already delivered, keep only the new suffix.
        const already_received: usize = @intCast(state.inbound.recv_next_offset - offset);
        if (already_received < data.len) {
            const new_data = data[already_received..];
            if (sink.fd < 0) return error.StreamSinkClosed;
            try deliverInboundData(options, sink.fd, new_data);
            state.inbound.recv_next_offset += new_data.len;
        }
        sendAck(state, transport_write_fd, state.inbound.recv_next_offset) catch |err| switch (err) {
            error.WriteFailed => return error.StreamTransportWriteFailed,
            else => return err,
        };
        return;
    }
    if (offset != state.inbound.recv_next_offset) return error.StreamOffsetGap;
    if (data.len != 0 and sink.fd < 0) return error.StreamSinkClosed;
    if (data.len != 0) try deliverInboundData(options, sink.fd, data);
    state.inbound.recv_next_offset += data.len;
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
    if (final_offset != state.inbound.recv_next_offset) return error.StreamOffsetGap;
    state.inbound.inbound_eof = true;
    const sink = options.sink;
    if (sink.shutdown_on_eof and sink.fd >= 0) _ = c.shutdown(sink.fd, c.SHUT.WR);
    if (sink.close_fd_on_eof) |sink_fd_ptr| {
        if (sink_fd_ptr.* >= 0) {
            _ = c.close(sink_fd_ptr.*);
            sink_fd_ptr.* = -1;
        }
    }
    if (options.close_outbound_on_inbound_eof and state.inbound.inbound_eof) {
        state.outbound.outbound_eof = true;
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
            .receive_window_bytes = max_buffered_bytes,
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
            .receive_window_bytes = max_buffered_bytes,
        } },
    });
}

fn sendAck(state: *StreamState, fd: c.fd_t, offset: u64) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .ack = .{
            .recv_next_offset = offset,
            .receive_window_bytes = max_buffered_bytes,
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

pub fn forwardRawDuplex(left_read_fd: c.fd_t, left_write_fd: c.fd_t, right_fd: c.fd_t) !void {
    var left_open = true;
    var right_open = true;
    // PROCESS_EVENT_LOOP: foreground raw proxy bridge. This process exists only
    // to relay bytes between two fds, so a direct poll loop is the event loop.
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
                    _ = c.shutdown(left_write_fd, c.SHUT.WR);
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

fn connectOrStartProxyRemote(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*ProxyRemoteProcess {
    const canonical = try session_registry.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);

    if (lookupProxyRemote(canonical)) |control| return control;

    return startProxyRemoteProcess(allocator, exe, canonical, proxy_host, proxy_port);
}

fn connectProxyRemote(control: *ProxyRemoteProcess) !c.fd_t {
    return connectProxyRemoteProcess(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forgetProxyRemote(control.guid);
            return error.StreamNotFound;
        },
        else => return err,
    };
}

fn connectStartedProxyRemote(control: *ProxyRemoteProcess) !c.fd_t {
    return connectProxyRemoteProcess(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forgetProxyRemote(control.guid);
            return error.StreamNotFound;
        },
        else => return err,
    };
}

fn connectProxyRemoteProcess(control: *const ProxyRemoteProcess) !c.fd_t {
    return socket_transport.connectSocket(control.socket_path);
}

pub fn requestProxyRemoteCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    const canonical = try session_registry.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);
    const control = lookupProxyRemote(canonical) orelse return error.StreamNotFound;
    const fd = try connectProxyRemote(control);
    defer _ = c.close(fd);
    try sendMuxStreamFrame(allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .reset = .{
            .code = "CLEANUP_REQUESTED",
            .message = "remote cleanup requested",
        } },
    });
}

pub fn runProxyRemoteProcess(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 5) return error.InvalidProxyRemoteArgs;
    const listen_fd = try std.fmt.parseInt(c.fd_t, args[0], 10);
    const socket_path = args[1];
    const guid = args[2];
    const proxy_host = args[3];
    const proxy_port = try std.fmt.parseInt(u16, args[4], 10);
    core_fds.closeInheritedNonStdioFileDescriptorsExcept(listen_fd);
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    try runProxyRemote(allocator, guid, listen_fd, proxy_host, proxy_port);
}

fn startProxyRemoteProcess(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*ProxyRemoteProcess {
    const canonical = try session_registry.canonicalProxyGuid(allocator, guid);
    errdefer allocator.free(canonical);

    const socket_path = try proxyRemoteSocketPath(allocator, exe);
    errdefer allocator.free(socket_path);
    try socket_transport.ensureSocketDir(allocator, socket_path);
    const listen_fd = try socket_transport.listenSocket(socket_path);
    errdefer _ = c.close(listen_fd);
    try socket_transport.clearCloseOnExec(listen_fd);

    const control = try allocator.create(ProxyRemoteProcess);
    errdefer allocator.destroy(control);
    control.* = .{
        .allocator = allocator,
        .guid = canonical,
        .socket_path = socket_path,
    };
    errdefer control.deinit();

    try registerProxyRemote(control);
    errdefer unregisterProxyRemote(control);

    const port_arg = try std.fmt.allocPrint(allocator, "{}", .{proxy_port});
    defer allocator.free(port_arg);
    const listen_fd_arg = try std.fmt.allocPrint(allocator, "{}", .{listen_fd});
    defer allocator.free(listen_fd_arg);
    const argv = [_][]const u8{ exe, listen_fd_arg, socket_path, canonical, proxy_host, port_arg };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = c.close(listen_fd);
    control.pid = @intCast(child.id);
    return control;
}

fn proxyRemoteSocketPath(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    const exe_dir = std.fs.path.dirname(exe) orelse return error.InvalidRemoteProcessExecutablePath;
    const namespace = std.fs.path.basename(exe_dir);
    const root = try socket_transport.shortRuntimeRoot(allocator);
    defer allocator.free(root);
    const sequence = proxy_remote_socket_sequence;
    proxy_remote_socket_sequence +%= 1;
    return std.fmt.allocPrint(allocator, "{s}/{s}/proxy-{}-{}.sock", .{ root, namespace, c.getpid(), sequence });
}

fn registerProxyRemote(control: *ProxyRemoteProcess) !void {
    for (proxy_remote_processes.items) |existing| {
        if (std.mem.eql(u8, existing.guid, control.guid)) return error.StreamExists;
    }
    try proxy_remote_processes.append(app_allocator.allocator(), control);
}

fn unregisterProxyRemote(control: *ProxyRemoteProcess) void {
    for (proxy_remote_processes.items, 0..) |existing, index| {
        if (existing == control) {
            _ = proxy_remote_processes.orderedRemove(index);
            return;
        }
    }
}

pub fn forgetProxyRemote(guid: []const u8) void {
    for (proxy_remote_processes.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.guid, guid)) {
            _ = proxy_remote_processes.orderedRemove(index);
            _ = reapProxyRemote(control.pid);
            const allocator = control.allocator;
            control.deinit();
            allocator.destroy(control);
            return;
        }
    }
}

pub fn activeProxyRemoteProcessCount() usize {
    pruneExitedProxyRemotes();
    return proxy_remote_processes.items.len;
}

fn lookupProxyRemote(guid: []const u8) ?*ProxyRemoteProcess {
    for (proxy_remote_processes.items) |control| {
        if (std.mem.eql(u8, control.guid, guid)) return control;
    }
    return null;
}

fn pruneExitedProxyRemotes() void {
    var index: usize = 0;
    while (index < proxy_remote_processes.items.len) {
        const control = proxy_remote_processes.items[index];
        if (reapProxyRemote(control.pid)) {
            _ = proxy_remote_processes.orderedRemove(index);
            const allocator = control.allocator;
            control.deinit();
            allocator.destroy(control);
            continue;
        }
        index += 1;
    }
}

fn reapProxyRemote(pid: c.pid_t) bool {
    if (pid <= 0) return true;
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, wait_nohang);
    if (result == pid) return true;
    if (result < 0) return switch (posix.errno(result)) {
        .CHILD => true,
        else => false,
    };
    return false;
}

fn nowMillis() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
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
    var control_reader = proxy_control.Reader.init(state.allocator);
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
    control_reader: *proxy_control.Reader,
    interrupt: ?*LocalStreamInterrupt,
    timeout_ms: i32,
) StreamControlAction {
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

fn readControlInput(control_fd: c.fd_t, input_control: *StreamInputControl, reader: *proxy_control.Reader) bool {
    if (control_fd < 0) return false;
    while (true) {
        var message = switch (reader.readReady(std.heap.smp_allocator, control_fd) catch return false) {
            .blocked, .progress => return true,
            .eof, .truncated_frame => return false,
            .message => |value| value,
        };
        defer message.deinit(std.heap.smp_allocator);
        switch (message.message) {
            .retry_now => input_control.reconnect_requested = true,
            else => {},
        }
    }
}

pub const TerminalTitleTracker = struct {
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

    pub fn observe(self: *TerminalTitleTracker, bytes: []const u8) void {
        for (bytes) |byte| self.observeByte(byte);
    }

    pub fn safeForLocalTitle(self: *const TerminalTitleTracker) bool {
        // A finished `CSI ? 2026 h` leaves the parser in ground state, but the
        // terminal is still inside a synchronized update. Title changes made
        // there can be held back by the terminal until the matching `l`, so the
        // reconnect UI treats that interval as unsafe too.
        return self.state == .ground and !self.synchronized_update_active;
    }

    pub fn titlePresent(self: *const TerminalTitleTracker) bool {
        return self.title_present;
    }

    pub fn titleSlice(self: *const TerminalTitleTracker) []const u8 {
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
    status_line_visible: bool = false,
    connection_status_active: bool = false,
    append_only_retry_announced: bool = false,
    escape_help_pending: bool = false,
    title_tracker: TerminalTitleTracker = .{},
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,

    fn init(
        mode: StreamReconnectStatusMode,
        ctrl_r_enabled: bool,
        title_fallback: []const u8,
        status_fd: c.fd_t,
    ) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = StreamReconnectStatus{
            .fd = if (status_fd >= 0) status_fd else switch (mode) {
                .title => 1,
                .stderr_plain, .status_line, .jsonl => 2,
                .client_control, .disabled => -1,
            },
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

    fn setFd(self: *StreamReconnectStatus, fd: c.fd_t) void {
        self.fd = fd;
    }

    fn showRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        const message = reconnect_title.retryStatus(&self.line, delay_ms, .{
            .ctrl_r = self.ctrl_r_enabled,
        }) catch return;
        self.line_len = message.len;
        self.connection_status_active = true;
        self.refreshDiagnostics();
        self.writeTitleRetry(delay_ms);
        self.writeStatusLine();
        self.writeAppendOnlyRetry(delay_ms);
        self.writeClientRetry(delay_ms);
    }

    fn showReconnecting(self: *StreamReconnectStatus) void {
        const message = reconnect_title.reconnectingStatus(.{
            .ctrl_r = self.ctrl_r_enabled,
        });
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
        self.connection_status_active = true;
        self.append_only_retry_announced = false;
        self.refreshDiagnostics();
        self.writeTitleReconnecting();
        self.writeStatusLine();
        self.writePlainStatusLine();
        self.writeJsonlEvent("reconnecting");
        self.writeClientReconnecting();
    }

    fn clear(self: *StreamReconnectStatus) void {
        const had_connection_status = self.connection_status_active;
        self.connection_status_active = false;
        self.append_only_retry_announced = false;
        self.refreshDiagnostics();
        self.clearStatusLine();
        self.restoreTitle();
        if (had_connection_status) {
            self.writeJsonlEvent("connected");
            self.writeClientClear();
        }
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
            .status_line => {
                self.clearStatusLine();
                self.writeEscapeHelpText();
                if (self.connection_status_active) self.writeStatusLine();
            },
            .jsonl => {},
            .client_control => {},
            .disabled => {},
        }
    }

    fn handleConnectionEvent(self: *StreamReconnectStatus, event: pb.ConnectionEvent) void {
        switch (event.event orelse return) {
            .ssh_stderr => |stderr| {
                client_log.appendSshStderr(stderr.data);
                self.refreshDiagnostics();
            },
            .binary_bootstrapping => switch (self.mode) {
                .stderr_plain => {
                    io.writeAll(self.fd, "sessh: bootstrapping...") catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                },
                .status_line => {
                    @memcpy(self.line[0.."sessh: bootstrapping...".len], "sessh: bootstrapping...");
                    self.line_len = "sessh: bootstrapping...".len;
                    self.connection_status_active = true;
                    self.writeStatusLine();
                },
                .jsonl => self.writeJsonlEvent("binary_bootstrapping"),
                .client_control => proxy_control.writeConnectionEvent(self.fd, .{ .binary_bootstrapping = .{} }) catch return,
                .title, .disabled => {},
            },
            .daemon_connecting => self.showReconnecting(),
            .daemon_connected => self.clear(),
            .daemon_disconnected => |disconnected| self.showRetry(retryDelayFromLocalBootDeadline(disconnected.retry_at_local_boot_time_ms)),
            .unresponsive => |unresponsive| self.showRetry(retryDelayFromLocalBootDeadline(unresponsive.retry_at_local_boot_time_ms)),
            .ssh_connecting,
            .ssh_connected,
            => {},
        }
    }

    fn writePlainStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\r\n") catch return;
    }

    fn writeStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .status_line or self.fd < 0) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, "\r\x1b[K") catch return;
        io.writeAll(self.fd, message) catch return;
        self.status_line_visible = true;
    }

    fn clearStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .status_line or self.fd < 0 or !self.status_line_visible) return;
        io.writeAll(self.fd, "\r\x1b[K") catch return;
        self.status_line_visible = false;
    }

    fn writeAppendOnlyRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        switch (self.mode) {
            .stderr_plain, .jsonl => {},
            else => return,
        }
        if (self.append_only_retry_announced) return;
        self.append_only_retry_announced = true;
        switch (self.mode) {
            .stderr_plain => self.writePlainStatusLine(),
            .jsonl => self.writeJsonlRetry(delay_ms),
            else => unreachable,
        }
    }

    fn writeJsonlRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "{{\"event\":\"retry\",\"retry_at_unix_ms\":{}}}\n",
            .{nowUnixMs() +| delay_ms},
        ) catch return;
        io.writeAll(self.fd, line) catch return;
    }

    fn writeJsonlEvent(self: *StreamReconnectStatus, event: []const u8) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "{{\"event\":\"{s}\"}}\n",
            .{event},
        ) catch return;
        io.writeAll(self.fd, line) catch return;
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

    fn writeClientRetry(self: *StreamReconnectStatus, delay_ms: u64) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_control.writeConnectionEvent(self.fd, .{ .daemon_disconnected = .{
            .retry_at_local_boot_time_ms = local_boot_time.nowMs() +| delay_ms,
        } }) catch return;
    }

    fn writeClientReconnecting(self: *StreamReconnectStatus) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_control.writeConnectionEvent(self.fd, .{ .daemon_connecting = .{} }) catch return;
    }

    fn writeClientClear(self: *StreamReconnectStatus) void {
        if (self.mode != .client_control or self.fd < 0) return;
        proxy_control.writeConnectionEvent(self.fd, .{ .daemon_connected = .{} }) catch return;
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

    fn observeInbound(self: *StreamReconnectStatus, bytes: []const u8) void {
        if (self.mode != .title) return;
        self.title_tracker.observe(bytes);
        if (self.escape_help_pending and self.canWriteTitle()) self.writeEscapeHelpText();
    }

    fn refreshDiagnostics(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain and self.mode != .status_line and self.mode != .client_control and self.mode != .jsonl) return;
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
            switch (self.mode) {
                .status_line => {
                    self.clearStatusLine();
                    io.writeAll(self.fd, line) catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                    if (self.connection_status_active) self.writeStatusLine();
                },
                .stderr_plain => {
                    io.writeAll(self.fd, line) catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                },
                .jsonl => self.writeJsonlDiagnostic(line),
                .client_control => proxy_control.writeConnectionEvent(self.fd, .{ .ssh_stderr = .{ .data = line } }) catch return,
                .title, .disabled => unreachable,
            }
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

    fn writeJsonlDiagnostic(self: *StreamReconnectStatus, line: []const u8) void {
        if (self.mode != .jsonl or self.fd < 0) return;
        io.writeAll(self.fd, "{\"event\":\"diagnostic\",\"message\":") catch return;
        writeJsonString(self.fd, line) catch return;
        io.writeAll(self.fd, "}\n") catch return;
    }
};

fn writeJsonString(fd: c.fd_t, value: []const u8) !void {
    try io.writeAll(fd, "\"");
    for (value) |byte| switch (byte) {
        '"' => try io.writeAll(fd, "\\\""),
        '\\' => try io.writeAll(fd, "\\\\"),
        '\n' => try io.writeAll(fd, "\\n"),
        '\r' => try io.writeAll(fd, "\\r"),
        '\t' => try io.writeAll(fd, "\\t"),
        else => {
            if (byte < 0x20) {
                var buf: [6]u8 = undefined;
                const escaped = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte});
                try io.writeAll(fd, escaped);
            } else {
                try io.writeAll(fd, (&[_]u8{byte})[0..]);
            }
        },
    };
    try io.writeAll(fd, "\"");
}

fn retryDelayFromLocalBootDeadline(deadline_ms: ?u64) u64 {
    const deadline = deadline_ms orelse return 0;
    const now = local_boot_time.nowMs();
    return deadline -| now;
}

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

fn encodeMuxProxyDataPayload(allocator: std.mem.Allocator, offset: u64, data: []const u8) ![]u8 {
    return protocol.encodePayload(allocator, pb.DaemonTunnelItem{
        .payload = .{ .mux_stream = .{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .payload = .{
                .offset = offset,
                .item = .{ .proxy = .{ .payload = .{ .data = data } } },
            } },
        } },
    });
}

fn encodeMuxProxyEofPayload(allocator: std.mem.Allocator, offset: u64) ![]u8 {
    return protocol.encodePayload(allocator, pb.DaemonTunnelItem{
        .payload = .{ .mux_stream = .{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .eof = .{ .final_offset = offset } },
        } },
    });
}

fn encodeMuxAckPayload(allocator: std.mem.Allocator, recv_next_offset: u64) ![]u8 {
    return protocol.encodePayload(allocator, pb.DaemonTunnelItem{
        .payload = .{ .mux_stream = .{
            .stream_id = proxy_mux_stream_id,
            .message = .{ .ack = .{
                .recv_next_offset = recv_next_offset,
                .receive_window_bytes = max_buffered_bytes,
            } },
        } },
    });
}

fn expectMuxStreamFrame(fd: c.fd_t) !pb.DaemonTunnelItem.MuxStreamFrame {
    var frame = try readFrameForTest(fd);
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

test "raw duplex propagates right-side eof to the left peer" {
    const left_input = try posix.pipe();
    posix.close(left_input[1]);
    defer posix.close(left_input[0]);

    var left_output: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &left_output) != 0) return error.SocketPairFailed;
    defer _ = c.close(left_output[0]);
    defer _ = c.close(left_output[1]);

    var right: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &right) != 0) return error.SocketPairFailed;
    defer _ = c.close(right[0]);

    _ = c.close(right[1]);
    right[1] = -1;

    try forwardRawDuplex(left_input[0], left_output[0], right[0]);

    var pollfds = [_]posix.pollfd{.{
        .fd = left_output[1],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 0));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(left_output[1], &byte, byte.len));
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
    const payload = try protocol.encodePayload(std.testing.allocator, pb.DaemonTunnelItem{ .payload = .{ .ping = .{} } });
    const options = StreamAttachedClientOptions{};
    try handleFrame(&state, fds[1], &options, .{
        .message_type = .daemon_tunnel,
        .payload = payload,
    });

    var frame = try readFrameForTest(fds[0]);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MessageType.daemon_tunnel, frame.message_type);
    try std.testing.expectEqual(@as(u64, 0), state.inbound.recv_next_offset);
    try std.testing.expectEqual(@as(u64, 0), state.outbound.outboundNext());
}

// BLOCKING_FRAME_READ: test-only frame reader.
fn readFrameForTest(fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(std.testing.allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked => return error.WouldBlock,
            .progress => continue,
            .frame => |frame| return frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
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

test "stream inbound eof promptly flushes generated outbound eof" {
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
        .control_reader = proxy_control.Reader.init(std.testing.allocator),
        .options = .{
            .close_outbound_on_inbound_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };
    defer attached_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.progress, try attached_client.step(1_000));

    try expectAckFrame(transport_out[0], 0);

    var pollfds = [_]posix.pollfd{.{
        .fd = transport_out[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 0));

    try expectProxyEofFrame(transport_out[0], 0);
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
        .control_reader = proxy_control.Reader.init(std.testing.allocator),
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
        .control_reader = proxy_control.Reader.init(std.testing.allocator),
        .options = .{},
        .liveness = StreamLiveness.init(1_000),
    };
    defer attached_client.deinit();

    try std.testing.expectEqual(StreamStepOutcome.complete, try attached_client.step(1_000));
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

test "stream reconnect status uses plain stderr lines" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .stderr_plain, false, "");
    status.showRetry(1_000);
    status.showRetry(500);
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
        "sessh: disconnected: Retry connecting 1sec\r\n" ++
            "sessh: disconnected: Reconnecting...\r\n",
        output.items,
    );
}

test "stream reconnect status line redraws in place" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .status_line, false, "");
    status.showRetry(2_000);
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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\r\x1b[Ksessh: disconnected: Retry connecting 2sec") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\r\x1b[Ksessh: disconnected: Retry connecting 1sec") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.items, "\r\x1b[K"));
}

test "stream reconnect status emits one jsonl retry per wait" {
    client_log.markUserDiagnosticsDisplayedThrough(client_log.currentUserDiagnosticSeq());

    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .jsonl, false, "");
    status.showRetry(2_000);
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

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "\"event\":\"retry\""));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"retry_at_unix_ms\":") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "\"event\":\"reconnecting\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "\"event\":\"connected\""));
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

test "stream reconnect status emits client control messages" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .client_control, true, "");
    status.showRetry(1_000);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    var saw_disconnected = false;
    var saw_reconnecting = false;
    var saw_connected = false;
    while (true) {
        var message = proxy_control.readMessage(std.testing.allocator, fds[0]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer message.deinit(std.testing.allocator);

        switch (message.message) {
            .connection_event => |event| {
                switch (event.event orelse continue) {
                    .daemon_disconnected => |disconnected| {
                        try std.testing.expect(disconnected.retry_at_local_boot_time_ms != null);
                        saw_disconnected = true;
                    },
                    .daemon_connecting => saw_reconnecting = true,
                    .daemon_connected => saw_connected = true,
                    else => {},
                }
            },
            .retry_now => {},
        }
    }

    try std.testing.expect(saw_disconnected);
    try std.testing.expect(saw_reconnecting);
    try std.testing.expect(saw_connected);
}

test "stream reconnect status restores tracked application title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .title, true, "test-host");
    status.observeInbound("\x1b]2;remote");
    status.observeInbound("-title\x1b\\");
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
    status.observeInbound("\x1b]2;partial-title");
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
    status.observeInbound("\x1b]2;partial-title");
    status.showEscapeHelp();

    var empty_buf: [16]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds[0], &empty_buf));

    status.observeInbound("\x1b\\");
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
    status.observeInbound("\x1b[?2026h");
    status.showRetry(10_000);
    status.clear();
    status.observeInbound("\x1b[?2026l");
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
            "sessh: disconnected: Retry connecting 1sec\r\n",
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
        "sessh: disconnected: Retry connecting 1sec\r\n" ++
            "ssh: connection failed\r\n",
        output.items,
    );
}
