const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
const app_allocator = @import("../core/app_allocator.zig");
const daemon_log = @import("../daemon/log.zig");
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
    client_control,
};

pub const LocalStreamOptions = struct {
    guid: []const u8 = "",
    proxy_host: []const u8 = "",
    proxy_port: u16 = 0,
    source_fd: c.fd_t,
    sink_fd: c.fd_t,
    status_mode: StreamReconnectStatusMode,
    intercept_ctrl_r: bool,
    intercept_escape: bool = false,
    control_fd: c.fd_t = -1,
    status_fd: c.fd_t = -1,
    ctrl_r_status_enabled: ?bool = null,
    proxy_control_output_mode: proxy_control.OutputMode = .update,
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

const ProxyRuntimeControl = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    notify_read_fd: c.fd_t,
    notify_write_fd: c.fd_t,
    pending_mutex: std.Thread.Mutex = .{},
    pending_clients: std.ArrayList(c.fd_t) = .empty,
    closed: bool = false,

    fn enqueue(self: *ProxyRuntimeControl, fd: c.fd_t) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.closed) return error.StreamNotFound;
        try self.pending_clients.append(self.allocator, fd);
        var byte = [_]u8{1};
        const n = c.write(self.notify_write_fd, &byte, byte.len);
        if (n < 0 or @as(usize, @intCast(n)) != byte.len) {
            _ = self.pending_clients.pop();
            return error.RuntimeNotifyFailed;
        }
    }

    fn takePending(self: *ProxyRuntimeControl) ?c.fd_t {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending_clients.items.len == 0) return null;
        return self.pending_clients.orderedRemove(0);
    }

    fn close(self: *ProxyRuntimeControl) void {
        self.pending_mutex.lock();
        self.closed = true;
        while (self.pending_clients.items.len > 0) {
            const fd = self.pending_clients.pop().?;
            _ = c.close(fd);
        }
        self.pending_mutex.unlock();
    }

    fn deinit(self: *ProxyRuntimeControl) void {
        self.close();
        self.pending_clients.deinit(self.allocator);
        if (self.notify_read_fd >= 0) _ = c.close(self.notify_read_fd);
        if (self.notify_write_fd >= 0) _ = c.close(self.notify_write_fd);
        self.allocator.free(self.guid);
        self.* = undefined;
    }
};

var proxy_runtime_registry_mutex = std.Thread.Mutex{};
var proxy_runtime_registry: std.ArrayList(*ProxyRuntimeControl) = .empty;

fn sinkWithFd(stdin_fd: c.fd_t, close_fd_on_eof: ?*c.fd_t) StreamSink {
    return .{
        .fd = stdin_fd,
        .close_fd_on_eof = close_fd_on_eof,
    };
}

const StreamAttachedClientOptions = struct {
    source: StreamSource = .{},
    sink: StreamSink = .{},
    reconnect_status: ?*StreamReconnectStatus = null,
    control_fd: c.fd_t = -1,
    control_input: ?*StreamInputControl = null,
    replacement_control: ?*ProxyRuntimeControl = null,
    close_outbound_on_inbound_eof: bool = false,
    reset_on_source_eof: bool = false,
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
    options: StreamAttachedClientOptions,
    liveness: StreamLiveness,
    // Optional fd used only by the local stream loop. It lets that loop wake an
    // otherwise blocking attached client when an async replacement transport is
    // ready, without shortening the main poll timeout.
    external_wakeup_fd: c.fd_t = -1,
    interrupt_fd: c.fd_t = -1,

    fn init(
        state: *StreamState,
        transport_read_fd: c.fd_t,
        transport_write_fd: c.fd_t,
        options: StreamAttachedClientOptions,
    ) !StreamAttachedClient {
        state.peer_ready = false;
        state.outbound.outbound_eof_sent = false;
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

    fn step(self: *StreamAttachedClient, requested_timeout_ms: i32) !StreamStepOutcome {
        const state = self.state;
        if (state.complete()) return .complete;

        const now_before_poll_ms = nowMillis();
        var pollfds: [1 + 1 + 1 + 3]posix.pollfd = undefined;
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
        if (self.options.replacement_control) |control| {
            replacement_index = count;
            pollfds[count] = .{ .fd = control.notify_read_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }

        var external_wakeup_index: ?usize = null;
        if (self.external_wakeup_fd >= 0) {
            external_wakeup_index = count;
            pollfds[count] = .{ .fd = self.external_wakeup_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        var control_index: ?usize = null;
        if (self.options.control_fd >= 0 and self.options.control_input != null) {
            control_index = count;
            pollfds[count] = .{ .fd = self.options.control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
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
                if (self.options.replacement_control) |control| {
                    drainNotify(control.notify_read_fd);
                    if (control.takePending()) |fd| return .{ .replacement = fd };
                }
            }
        }
        if (interrupt_index) |index| {
            if (pollfds[index].revents != 0) return .interrupted;
        }
        if (control_index) |index| {
            if (pollfds[index].revents != 0) {
                if (self.options.control_input) |control| {
                    if (!readControlInput(self.options.control_fd, control)) self.options.control_fd = -1;
                }
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
        if (!source_ready) {
            // A wake-only event means the local loop has a replacement result
            // to inspect. Do not flush buffered bytes to the old transport just
            // because the replacement thread finished.
            if (external_wakeup_index) |index| {
                if (pollfds[index].revents != 0) return .idle;
            }
        }
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

fn createNotifyPipe() ![2]c.fd_t {
    const notify_pipe = try createNotifyPipe();
    return notify_pipe;
}

fn drainNotify(fd: c.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) continue;
        if (n == 0) return;
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
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

    fn attachedClientOptions(self: *ProxyEndpoint, control: *ProxyRuntimeControl) StreamAttachedClientOptions {
        return .{
            .source = .{ .fd = self.fd },
            .sink = .{
                .fd = self.fd,
                .shutdown_on_eof = true,
            },
            .replacement_control = control,
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

pub fn serveMuxStreamFrameAfterHandshake(
    allocator: std.mem.Allocator,
    exe: []const u8,
    frame: protocol.OwnedFrame,
    fd: c.fd_t,
) !void {
    var streams: std.ArrayList(ProxyMuxRuntime) = .empty;
    defer closeProxyMuxRuntimes(allocator, &streams);

    try handleProxyMuxFrame(allocator, exe, &streams, fd, frame);

    while (true) {
        const poll_targets = try allocator.alloc(ProxyMuxPollTarget, streams.items.len);
        defer allocator.free(poll_targets);
        for (streams.items, 0..) |stream, index| {
            poll_targets[index] = .{
                .stream_id = stream.stream_id,
                .runtime_fd = stream.runtime_fd,
            };
        }

        const pollfds = try allocator.alloc(posix.pollfd, 1 + poll_targets.len);
        defer allocator.free(pollfds);
        pollfds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
        for (poll_targets, 0..) |target, index| {
            pollfds[index + 1] = .{ .fd = target.runtime_fd, .events = posix.POLL.IN, .revents = 0 };
        }

        _ = try posix.poll(pollfds, -1);

        for (poll_targets, 0..) |target, index| {
            const revents = pollfds[index + 1].revents;
            if ((revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) continue;
            const runtime_index = findProxyMuxRuntimeIndex(&streams, target.stream_id) orelse continue;
            if (try forwardProxyRuntimeFrameToMux(allocator, fd, &streams.items[runtime_index])) {
                continue;
            }
            const runtime = streams.swapRemove(runtime_index);
            sendProxyMuxReset(allocator, fd, runtime.stream_id, "RUNTIME_CLOSED", "proxy stream runtime closed") catch {};
            _ = c.close(runtime.runtime_fd);
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var next = protocol.readFrameAlloc(allocator, fd) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer next.deinit(allocator);
            try handleProxyMuxFrame(allocator, exe, &streams, fd, next);
        }
    }
}

const ProxyMuxRuntime = struct {
    stream_id: u64,
    runtime_fd: c.fd_t,
};

const ProxyMuxPollTarget = struct {
    stream_id: u64,
    runtime_fd: c.fd_t,
};

fn closeProxyMuxRuntimes(allocator: std.mem.Allocator, streams: *std.ArrayList(ProxyMuxRuntime)) void {
    for (streams.items) |stream| {
        _ = c.close(stream.runtime_fd);
    }
    streams.deinit(allocator);
}

fn handleProxyMuxFrame(
    allocator: std.mem.Allocator,
    exe: []const u8,
    streams: *std.ArrayList(ProxyMuxRuntime),
    mux_fd: c.fd_t,
    frame: protocol.OwnedFrame,
) !void {
    if (frame.message_type != .daemon_tunnel) return error.StreamUnexpectedFrame;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    const message = mux_frame.message orelse return error.StreamUnexpectedFrame;
    switch (message) {
        .open => |open| try handleProxyMuxOpen(allocator, exe, streams, mux_fd, mux_frame.stream_id, open),
        .open_ok, .ack, .payload, .eof => try forwardProxyMuxFrameToRuntime(allocator, streams, mux_frame),
        .reset => {
            forwardProxyMuxFrameToRuntime(allocator, streams, mux_frame) catch {};
            try removeProxyMuxRuntime(streams, mux_frame.stream_id);
        },
    }
}

fn handleProxyMuxOpen(
    allocator: std.mem.Allocator,
    exe: []const u8,
    streams: *std.ArrayList(ProxyMuxRuntime),
    mux_fd: c.fd_t,
    stream_id: u64,
    open: pb.MuxStreamFrame.Open,
) !void {
    if (findProxyMuxRuntimeIndex(streams, stream_id) != null) {
        try sendProxyMuxReset(allocator, mux_fd, stream_id, "STREAM_EXISTS", "mux stream already exists");
        return;
    }
    const request = switch (open.detail orelse return error.StreamUnexpectedFrame) {
        .proxy => |proxy| proxy,
        else => return error.StreamUnexpectedFrame,
    };
    if (!session_registry.isValidProxyGuid(request.proxy_guid)) return error.InvalidStreamGuid;
    if (request.proxy_port == 0 or request.proxy_port > std.math.maxInt(u16)) return error.InvalidStreamArgs;

    const runtime = try connectOrStartProxyRuntime(
        allocator,
        exe,
        request.proxy_guid,
        request.proxy_host,
        @intCast(request.proxy_port),
    );
    const runtime_fd = try connectProxyRuntime(runtime);
    errdefer _ = c.close(runtime_fd);

    try sendProxyRuntimeMuxFrame(allocator, runtime_fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open = open },
    });
    try streams.append(allocator, .{
        .stream_id = stream_id,
        .runtime_fd = runtime_fd,
    });
}

fn forwardProxyMuxFrameToRuntime(
    allocator: std.mem.Allocator,
    streams: *std.ArrayList(ProxyMuxRuntime),
    mux_frame: pb.MuxStreamFrame,
) !void {
    const index = findProxyMuxRuntimeIndex(streams, mux_frame.stream_id) orelse return error.StreamUnexpectedFrame;
    var remapped = mux_frame;
    remapped.stream_id = proxy_mux_stream_id;
    try sendProxyRuntimeMuxFrame(allocator, streams.items[index].runtime_fd, remapped);
}

fn forwardProxyRuntimeFrameToMux(
    allocator: std.mem.Allocator,
    mux_fd: c.fd_t,
    runtime: *ProxyMuxRuntime,
) !bool {
    var frame = protocol.readFrameAlloc(allocator, runtime.runtime_fd) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    defer frame.deinit(allocator);
    if (frame.message_type != .daemon_tunnel) return error.StreamUnexpectedFrame;
    var mux_frame = try protocol.decodeDaemonMuxStreamFrame(allocator, frame.payload);
    defer mux_frame.deinit(allocator);
    mux_frame.stream_id = runtime.stream_id;
    try sendProxyRuntimeMuxFrame(allocator, mux_fd, mux_frame);
    return true;
}

fn findProxyMuxRuntimeIndex(streams: *const std.ArrayList(ProxyMuxRuntime), stream_id: u64) ?usize {
    for (streams.items, 0..) |stream, index| {
        if (stream.stream_id == stream_id) return index;
    }
    return null;
}

fn removeProxyMuxRuntime(streams: *std.ArrayList(ProxyMuxRuntime), stream_id: u64) !void {
    const index = findProxyMuxRuntimeIndex(streams, stream_id) orelse return;
    const runtime = streams.swapRemove(index);
    _ = c.close(runtime.runtime_fd);
}

fn sendProxyMuxReset(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    stream_id: u64,
    code: []const u8,
    message: []const u8,
) !void {
    try sendProxyRuntimeMuxFrame(allocator, fd, .{
        .stream_id = stream_id,
        .message = .{ .reset = .{
            .code = code,
            .message = message,
        } },
    });
}

fn sendProxyRuntimeMuxFrame(allocator: std.mem.Allocator, fd: c.fd_t, message: pb.MuxStreamFrame) !void {
    try protocol.sendMuxStreamFrame(allocator, fd, message);
}

fn runProxyRuntime(allocator: std.mem.Allocator, control: *ProxyRuntimeControl, proxy_host: []const u8, proxy_port: u16) !void {
    var endpoint = try ProxyEndpoint.connect(allocator, proxy_host, proxy_port);
    defer endpoint.deinit();

    var state = StreamState.init(allocator, control.guid, "", 0);
    defer state.deinit();

    var attach_fd: c.fd_t = -1;
    defer {
        if (attach_fd >= 0) _ = c.close(attach_fd);
    }
    while (true) {
        if (attach_fd < 0) {
            var disconnected_options = endpoint.attachedClientOptions(control);
            attach_fd = try waitForReplacementWhileDisconnected(&state, control, &disconnected_options);
        }

        const outcome = try runAttachedStream(
            &state,
            attach_fd,
            attach_fd,
            endpoint.attachedClientOptions(control),
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
    control: *ProxyRuntimeControl,
    options: *const StreamAttachedClientOptions,
) !c.fd_t {
    while (true) {
        // The proxy stream runtime is durable even when no ssh transport is currently
        // attached. It must keep draining remote fds into the offset-tracked
        // buffers; otherwise the remote TCP peer can block before a
        // replacement transport attaches.
        var pollfds: [1 + 1]posix.pollfd = undefined;
        var count: usize = 0;
        const replacement_index = count;
        pollfds[count] = .{ .fd = control.notify_read_fd, .events = posix.POLL.IN, .revents = 0 };
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
            drainNotify(control.notify_read_fd);
            if (control.takePending()) |fd| return fd;
        }

        if (source_poll_index) |poll_index| {
            if (pollfds[poll_index].revents != 0) {
                try readStreamSource(state, source);
            }
        }
        try drainStreamSourcesNonBlocking(state, options);
    }
}

/// Runs in the local `sessh` process. `start_transport` creates ssh transports
/// that execute the remote `:internal-broker:` entrypoint; this loop owns local
/// stdin/stdout and the reconnect policy.
pub fn runLocalStream(
    allocator: std.mem.Allocator,
    start_transport: anytype,
    options: LocalStreamOptions,
) !u8 {
    const Starter = @TypeOf(start_transport);
    const Transport = @TypeOf(start_transport.start() catch unreachable);
    const Pending = PendingReplacement(Starter, Transport);
    var control_fd = options.control_fd;
    if (control_fd >= 0) setNonBlockingFd(control_fd) catch {};

    var state = StreamState.init(allocator, options.guid, options.proxy_host, options.proxy_port);
    defer state.deinit();
    var input_control = StreamInputControl{
        .enabled = options.intercept_ctrl_r,
        .escape_enabled = options.intercept_escape,
    };
    const ctrl_r_status_enabled = options.ctrl_r_status_enabled orelse options.intercept_ctrl_r;
    const status_fd = if (options.status_fd >= 0) options.status_fd else control_fd;
    var reconnect_status = StreamReconnectStatus.init(
        options.status_mode,
        ctrl_r_status_enabled,
        options.title_fallback,
        status_fd,
        options.proxy_control_output_mode,
    );
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
                const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &control_fd, &input_control, &local_interrupt);
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
                    .reconnect_status = &reconnect_status,
                    .control_fd = control_fd,
                    .control_input = &input_control,
                    // Once the remote side closes its output stream there is
                    // no peer left to consume local input, so close the local
                    // outbound side too.
                    .close_outbound_on_inbound_eof = true,
                    .reset_on_source_eof = options.reset_on_source_eof,
                },
            ) catch {
                transport.close();
                retrying = true;
                continue :client_loop;
            };
            var old_unresponsive = false;
            while (true) {
                attached_client.external_wakeup_fd = if (pending) |*replacement| replacement.notifyFd() else -1;
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
                        if (pending == null) {
                            pending = Pending.start(allocator, start_transport) catch |err| {
                                client_log.userDiagnosticInfo("stream reconnect failed: transport: {t}", .{err});
                                const delay_ms = reconnect.delayMs(attempt);
                                const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &control_fd, &input_control, &local_interrupt);
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
                        sendReset(&state, transport.writeFd(), "CLIENT_DISCONNECT", "local proxy stream disconnected") catch {};
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
                                    const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &control_fd, &input_control, &local_interrupt);
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
                var pollfds: [4]posix.pollfd = undefined;
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
                var control_index: ?usize = null;
                if (control_fd >= 0) {
                    control_index = count;
                    pollfds[count] = .{ .fd = control_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
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
                if (control_index) |index| {
                    if (pollfds[index].revents != 0) {
                        if (!readControlInput(control_fd, &input_control)) control_fd = -1;
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
        const action = waitBeforeReconnect(&reconnect_status, delay_ms, &state, options.source_fd, &control_fd, &input_control, &local_interrupt);
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
        else => return error.StreamUnexpectedFrame,
    }
}

fn handleMuxStreamFrame(
    state: *StreamState,
    transport_write_fd: c.fd_t,
    options: *const StreamAttachedClientOptions,
    frame: pb.MuxStreamFrame,
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
                .te => return error.StreamUnexpectedFrame,
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

fn sendResumeMessage(state: *StreamState, fd: c.fd_t) !void {
    try sendMuxStreamFrame(state.allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .open = .{
            .recv_next_offset = state.inbound.recv_next_offset,
            .receive_window_bytes = max_buffered_bytes,
            .detail = .{ .proxy = .{
                .proxy_guid = state.guid,
                .proxy_host = state.proxy_host,
                .proxy_port = state.proxy_port,
            } },
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
    message: pb.MuxStreamFrame,
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

fn connectOrStartProxyRuntime(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*ProxyRuntimeControl {
    _ = exe;
    const canonical = try session_registry.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);

    if (lookupProxyRuntime(canonical)) |control| return control;

    return startProxyRuntimeThread(allocator, canonical, proxy_host, proxy_port);
}

fn connectProxyRuntime(control: *ProxyRuntimeControl) !c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    try setCloseOnExec(fds[0]);
    try setCloseOnExec(fds[1]);
    try control.enqueue(fds[1]);
    return fds[0];
}

const ProxyRuntimeThreadContext = struct {
    allocator: std.mem.Allocator,
    control: *ProxyRuntimeControl,
    proxy_host: []u8,
    proxy_port: u16,
};

fn startProxyRuntimeThread(
    allocator: std.mem.Allocator,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*ProxyRuntimeControl {
    const canonical = try session_registry.canonicalProxyGuid(allocator, guid);
    errdefer allocator.free(canonical);

    const notify_pipe = try posix.pipe();
    errdefer {
        posix.close(notify_pipe[0]);
        posix.close(notify_pipe[1]);
    }
    try setNonBlockingFd(notify_pipe[0]);
    try setNonBlockingFd(notify_pipe[1]);
    try setCloseOnExec(notify_pipe[0]);
    try setCloseOnExec(notify_pipe[1]);

    const control = try allocator.create(ProxyRuntimeControl);
    errdefer allocator.destroy(control);
    control.* = .{
        .allocator = allocator,
        .guid = canonical,
        .notify_read_fd = notify_pipe[0],
        .notify_write_fd = notify_pipe[1],
    };
    errdefer control.deinit();

    try registerProxyRuntime(control);
    errdefer unregisterProxyRuntime(control);

    const context = try allocator.create(ProxyRuntimeThreadContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .control = control,
        .proxy_host = undefined,
        .proxy_port = proxy_port,
    };
    context.proxy_host = try allocator.dupe(u8, proxy_host);
    errdefer allocator.free(context.proxy_host);

    const thread = try std.Thread.spawn(.{}, proxyRuntimeThreadMain, .{context});
    thread.detach();
    return control;
}

fn proxyRuntimeThreadMain(context: *ProxyRuntimeThreadContext) void {
    const allocator = context.allocator;
    const control = context.control;
    defer {
        unregisterProxyRuntime(control);
        control.deinit();
        allocator.destroy(control);
        allocator.free(context.proxy_host);
        allocator.destroy(context);
    }

    runProxyRuntime(allocator, control, context.proxy_host, context.proxy_port) catch {};
}

fn registerProxyRuntime(control: *ProxyRuntimeControl) !void {
    proxy_runtime_registry_mutex.lock();
    defer proxy_runtime_registry_mutex.unlock();
    for (proxy_runtime_registry.items) |existing| {
        if (std.mem.eql(u8, existing.guid, control.guid)) return error.StreamExists;
    }
    try proxy_runtime_registry.append(app_allocator.allocator(), control);
}

fn unregisterProxyRuntime(control: *ProxyRuntimeControl) void {
    proxy_runtime_registry_mutex.lock();
    defer proxy_runtime_registry_mutex.unlock();
    for (proxy_runtime_registry.items, 0..) |existing, index| {
        if (existing == control) {
            _ = proxy_runtime_registry.orderedRemove(index);
            return;
        }
    }
}

pub fn activeProxyRuntimeCount() usize {
    proxy_runtime_registry_mutex.lock();
    defer proxy_runtime_registry_mutex.unlock();
    return proxy_runtime_registry.items.len;
}

fn lookupProxyRuntime(guid: []const u8) ?*ProxyRuntimeControl {
    proxy_runtime_registry_mutex.lock();
    defer proxy_runtime_registry_mutex.unlock();
    for (proxy_runtime_registry.items) |control| {
        if (std.mem.eql(u8, control.guid, guid)) return control;
    }
    return null;
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
    control_fd: *c.fd_t,
    input_control: *StreamInputControl,
    interrupt: ?*LocalStreamInterrupt,
) StreamControlAction {
    var remaining_ms = delay_ms;
    while (remaining_ms > 0) {
        status.showRetry(remaining_ms);
        input_control.status_visible = true;
        const step_ms = @min(remaining_ms, 1_000);
        const action = pollReconnectInput(state, source_fd, control_fd, input_control, interrupt, @intCast(step_ms));
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
    control_fd: *c.fd_t,
    input_control: *StreamInputControl,
    interrupt: ?*LocalStreamInterrupt,
    timeout_ms: i32,
) StreamControlAction {
    var pollfds: [3]posix.pollfd = undefined;
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
    var control_index: ?usize = null;
    if (control_fd.* >= 0) {
        control_index = count;
        pollfds[count] = .{ .fd = control_fd.*, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
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
    if (control_index) |index| {
        if (pollfds[index].revents != 0) {
            if (!readControlInput(control_fd.*, input_control)) control_fd.* = -1;
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

fn readControlInput(control_fd: c.fd_t, input_control: *StreamInputControl) bool {
    if (control_fd < 0) return false;
    var message = proxy_control.readMessage(std.heap.smp_allocator, control_fd) catch return false;
    defer message.deinit(std.heap.smp_allocator);
    switch (message.message) {
        .ctrl_r => input_control.reconnect_requested = true,
        else => {},
    }
    return true;
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
    proxy_control_output_mode: proxy_control.OutputMode = .update,
    proxy_control_retry_line_visible: bool = false,
    title_visible: bool = false,
    escape_help_pending: bool = false,
    title_tracker: TerminalTitleTracker = .{},
    title_fallback: [max_title_fallback_bytes]u8 = [_]u8{0} ** max_title_fallback_bytes,
    title_fallback_len: usize = 0,

    fn init(
        mode: StreamReconnectStatusMode,
        ctrl_r_enabled: bool,
        title_fallback: []const u8,
        status_fd: c.fd_t,
        proxy_control_output_mode: proxy_control.OutputMode,
    ) StreamReconnectStatus {
        const displayed = client_log.displayedUserDiagnosticSeq();
        var status = StreamReconnectStatus{
            .fd = if (status_fd >= 0) status_fd else if (mode == .title) 1 else 2,
            .mode = mode,
            .ctrl_r_enabled = ctrl_r_enabled,
            .diagnostic_cursor = displayed,
            .live_diagnostic_start_seq = client_log.currentUserDiagnosticSeq(),
            .rendered_diagnostic_seq = displayed,
            .proxy_control_output_mode = proxy_control_output_mode,
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
        }) catch return;
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writeTitleRetry(delay_ms);
        self.writePlainStatusLine();
        self.writeClientRetry(delay_ms);
    }

    fn showReconnecting(self: *StreamReconnectStatus) void {
        const message = reconnect_title.reconnectingStatus(.{
            .ctrl_r = self.ctrl_r_enabled,
        });
        @memcpy(self.line[0..message.len], message);
        self.line_len = message.len;
        self.refreshDiagnostics();
        self.writeTitleReconnecting();
        self.writePlainStatusLine();
        self.writeClientReconnecting();
    }

    fn clear(self: *StreamReconnectStatus) void {
        self.refreshDiagnostics();
        self.restoreTitle();
        self.writeClientClear();
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
            .client_control => {},
            .disabled => {},
        }
    }

    fn writePlainStatusLine(self: *StreamReconnectStatus) void {
        if (self.mode != .stderr_plain) return;
        const message = self.line[0..self.line_len];
        io.writeAll(self.fd, message) catch return;
        io.writeAll(self.fd, "\r\n") catch return;
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
        switch (self.proxy_control_output_mode) {
            .update => proxy_control.writeDiagnostic(self.fd, .{
                .update = self.line[0..self.line_len],
                .intercept_ctrl_r = self.ctrl_r_enabled,
            }) catch return,
            .diagnostic_line => {
                if (self.proxy_control_retry_line_visible) return;
                var line_buf: [160]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &line_buf,
                    "{s} (retry_at_unix_ms={})",
                    .{ self.line[0..self.line_len], nowMillis() + delay_ms },
                ) catch self.line[0..self.line_len];
                proxy_control.writeDiagnostic(self.fd, .{
                    .diagnostic_line = line,
                    .intercept_ctrl_r = self.ctrl_r_enabled,
                }) catch return;
                self.proxy_control_retry_line_visible = true;
            },
            .none => {},
        }
    }

    fn writeClientReconnecting(self: *StreamReconnectStatus) void {
        if (self.mode != .client_control or self.fd < 0) return;
        self.proxy_control_retry_line_visible = false;
        switch (self.proxy_control_output_mode) {
            .update => proxy_control.writeDiagnostic(self.fd, .{
                .update = self.line[0..self.line_len],
                .intercept_ctrl_r = self.ctrl_r_enabled,
            }) catch return,
            .diagnostic_line => proxy_control.writeDiagnostic(self.fd, .{
                .diagnostic_line = self.line[0..self.line_len],
                .intercept_ctrl_r = self.ctrl_r_enabled,
            }) catch return,
            .none => {},
        }
    }

    fn writeClientClear(self: *StreamReconnectStatus) void {
        if (self.mode != .client_control or self.fd < 0) return;
        self.proxy_control_retry_line_visible = false;
        proxy_control.writeDiagnostic(self.fd, .{
            .intercept_ctrl_r = false,
        }) catch return;
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
        if (self.mode != .stderr_plain and self.mode != .client_control) return;
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
                .stderr_plain => {
                    io.writeAll(self.fd, line) catch return;
                    io.writeAll(self.fd, "\r\n") catch return;
                },
                .client_control => proxy_control.writeDiagnostic(self.fd, .{
                    .diagnostic_line = line,
                    .intercept_ctrl_r = self.ctrl_r_enabled,
                }) catch return,
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

fn expectMuxStreamFrame(fd: c.fd_t) !pb.MuxStreamFrame {
    var frame = try protocol.readFrameAlloc(std.testing.allocator, fd);
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
    const DuplexThread = struct {
        left_fd: c.fd_t,
        right_fd: c.fd_t,

        fn main(self: *@This()) void {
            forwardRawDuplex(self.left_fd, self.left_fd, self.right_fd) catch {};
            _ = c.close(self.left_fd);
            _ = c.close(self.right_fd);
        }
    };

    var left: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &left) != 0) return error.SocketPairFailed;
    defer _ = c.close(left[1]);

    var right: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &right) != 0) return error.SocketPairFailed;
    defer _ = c.close(right[1]);

    var context = DuplexThread{
        .left_fd = left[0],
        .right_fd = right[0],
    };
    const thread = try std.Thread.spawn(.{}, DuplexThread.main, .{&context});
    defer thread.join();

    _ = c.close(right[1]);
    right[1] = -1;

    var pollfds = [_]posix.pollfd{.{
        .fd = left[1],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pollfds, 1_000));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(left[1], &byte, byte.len));

    _ = c.shutdown(left[1], c.SHUT.WR);
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

    var frame = try protocol.readFrameAlloc(std.testing.allocator, fds[0]);
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
        .options = .{
            .close_outbound_on_inbound_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };

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
        .options = .{
            .source = .{ .fd = source[0] },
            .reset_on_source_eof = true,
        },
        .liveness = StreamLiveness.init(1_000),
    };

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
        .options = .{},
        .liveness = StreamLiveness.init(1_000),
    };

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

    var saw_retry_update = false;
    var saw_reconnecting_update = false;
    var saw_intercept_enabled = false;
    var saw_intercept_disabled = false;
    var saw_clear = false;
    while (true) {
        var message = proxy_control.readMessage(std.testing.allocator, fds[0]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer message.deinit(std.testing.allocator);

        switch (message.message) {
            .diagnostic => |diagnostic| {
                if (diagnostic.update) |line| {
                    if (std.mem.eql(u8, line, "sessh: disconnected: Retry connecting 1sec. CTRL-R now")) saw_retry_update = true;
                    if (std.mem.eql(u8, line, "sessh: disconnected: Reconnecting... CTRL-R now")) saw_reconnecting_update = true;
                } else if (diagnostic.diagnostic_line == null) {
                    saw_clear = true;
                }
                if (diagnostic.intercept_ctrl_r) {
                    saw_intercept_enabled = true;
                } else {
                    saw_intercept_disabled = true;
                }
            },
            .ctrl_r => {},
        }
    }

    try std.testing.expect(saw_retry_update);
    try std.testing.expect(saw_reconnecting_update);
    try std.testing.expect(saw_intercept_enabled);
    try std.testing.expect(saw_clear);
    try std.testing.expect(saw_intercept_disabled);
}

test "stream reconnect status emits infrequent diagnostic lines for proxy control" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    var status = StreamReconnectStatus.initForTest(fds[1], .client_control, true, "");
    status.proxy_control_output_mode = .diagnostic_line;
    status.showRetry(10_000);
    status.showRetry(9_000);
    status.showReconnecting();
    status.clear();
    posix.close(fds[1]);

    var retry_lines: usize = 0;
    var reconnecting_lines: usize = 0;
    while (true) {
        var message = proxy_control.readMessage(std.testing.allocator, fds[0]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer message.deinit(std.testing.allocator);

        switch (message.message) {
            .diagnostic => |diagnostic| {
                try std.testing.expectEqual(@as(?[]const u8, null), diagnostic.update);
                if (diagnostic.diagnostic_line) |line| {
                    if (std.mem.startsWith(u8, line, "sessh: disconnected: Retry connecting 10sec. CTRL-R now (retry_at_unix_ms=")) {
                        retry_lines += 1;
                    }
                    if (std.mem.eql(u8, line, "sessh: disconnected: Reconnecting... CTRL-R now")) {
                        reconnecting_lines += 1;
                    }
                }
            },
            .ctrl_r => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), retry_lines);
    try std.testing.expectEqual(@as(usize, 1), reconnecting_lines);
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
