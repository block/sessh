// Foreground terminal client for one emulated sessh session. It connects local
// stdin/stdout, reconnect UI, input ACK tracking, and terminal-worker frames
// while preserving the user's terminal presentation on exit.
const std = @import("std");
const builtin = @import("builtin");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const visible_client_messages = @import("visible_client_messages.zig");
const visible_client_state = @import("visible_client_state.zig");
const client_config = @import("client_config.zig");
const client_loop = @import("client_loop.zig");
const client_log = @import("../core/client_log.zig");
const client_renderer = @import("renderer.zig");
const client_ui = @import("client_ui.zig");
const connection_event = @import("../diagnostics/connection_event.zig");
const connection_monitor_mod = @import("connection_monitor.zig");
const core_blocking = @import("../core/blocking.zig");
const dispatch_io = @import("../core/dispatch_io.zig");
const core_fds = @import("../core/fds.zig");
const dispatcher_mod = @import("../core/dispatcher.zig");
const error_payload = @import("error_payload.zig");
const input_ack = @import("input_ack.zig");
const local_terminal_mod = @import("local_terminal.zig");
const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const presentation_guard_mod = @import("presentation_guard.zig");
const protocol = @import("../protocol/mod.zig");
const protocol_test_helpers = if (builtin.is_test) @import("../protocol/test_helpers.zig") else struct {};
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const repaint_mod = @import("repaint.zig");
const socket_transport = @import("../transport/socket.zig");
const foreground_frame_io = @import("../transport/foreground_frame_io.zig");
const posix_pty = @import("../tty/posix_pty.zig");
const terminal = @import("../tty/terminal.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const WindowSize = terminal.WindowSize;
const max_visible_stdout_pending_bytes: usize = 4 * 1024 * 1024;
const visible_stdout_low_watermark: usize = 512 * 1024;

const ErrorPayload = error_payload.Payload;
const freeErrorPayload = error_payload.free;
const parseErrorPayload = error_payload.parse;
const printErrorPayload = error_payload.printPayload;
const printParsedError = error_payload.printParsed;
const transportExitCode = error_payload.transportExitCode;

/// Why the foreground visible client stopped running.
///
/// These values are intentionally ssh-shaped: a normal remote process exit is
/// different from losing the local daemon socket, and an unresponsive transport
/// is different from confirmed remote daemon death because reconnect UI handles
/// only the former.
pub const VisibleClientEnd = enum {
    unresponsive,
    transport_closed,
    remote_transport_closed,
    session_ended,
    client_hangup,
};

/// Result of reading worker frames while trying to recover from an
/// unresponsive connection. Recovery is only accepted after terminal state is
/// coherent again; arbitrary bytes are not enough when a repaint is pending.
pub const TerminalWorkerRecovery = enum {
    recovered,
    transport_closed,
    remote_transport_closed,
    session_ended,
};

pub const VisibleClientOptions = struct {
    monitor_connection: bool = false,
    responsiveness_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
};

pub const TerminalWorkerFds = struct {
    read: c.fd_t,
    write: c.fd_t,
};

const ConnectionMonitor = connection_monitor_mod.ConnectionMonitor;
const InputAckTracker = input_ack.Tracker;
const PasteLikeInputClassifier = client_loop.PasteLikeInputClassifier;
const PresentationGuard = presentation_guard_mod.Guard;
pub const VisibleClientSessionState = visible_client_state.VisibleClientSessionState;
pub const ScrollbackCursor = visible_client_state.ScrollbackCursor;
const InitialDrawAlignment = visible_client_state.InitialDrawAlignment;
const default_responsiveness_timeout_ms = connection_monitor_mod.default_responsiveness_timeout_ms;

pub const LocalTerminalState = local_terminal_mod.State;
pub const LocalTerminalProbe = local_terminal_mod.Probe;

pub fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

// Decoded draw frame plus the optional presentation bytes that need special
// handling. Normal draw bytes update stdout immediately; exit-restore bytes are
// retained until the visible client is actually leaving the session.
const DrawPayload = struct {
    scrollback_cursor: []const u8,
    viewport_offset: i32,
    draw_bytes: []const u8,
    app_title_present: ?bool,
    visible_client_end_restore_bytes: ?[]const u8,
};

test "paste-like input classifier uses read size and short rolling window" {
    var classifier = PasteLikeInputClassifier{};
    try std.testing.expect(!classifier.classify(31));

    var large_read = PasteLikeInputClassifier{};
    try std.testing.expect(large_read.classify(32));

    var window = PasteLikeInputClassifier{};
    try std.testing.expect(!window.classify(20));
    try std.testing.expect(!window.classify(20));
    try std.testing.expect(window.classify(24));
}

test "resize repaint timeout clears stale visible client display and enters unresponsive state" {
    var session = VisibleClientSessionState{ .viewport_offset = 7 };
    _ = session.pending_repaint.startResizeAt(1_000);

    try std.testing.expectEqual(
        @as(?VisibleClientEnd, null),
        checkResizeRepaintTimeoutAt(core_blocking.fromTest(), &session, 1_999),
    );
    try std.testing.expectEqual(@as(i32, 7), session.viewport_offset);

    try std.testing.expectEqual(
        VisibleClientEnd.unresponsive,
        checkResizeRepaintTimeoutAt(core_blocking.fromTest(), &session, 2_000).?,
    );
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);
    try std.testing.expect(session.pending_repaint.requiresRepaintForRecovery());
}

test "visible client drains pending session end before monitor timeout" {
    try dispatcher_mod.initGlobal(app_allocator.allocator());
    defer dispatcher_mod.deinitGlobal();

    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), remote_to_client[1], .{ .draw = .{
        .scrollback_cursor = "cursor-v1",
    } });

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), remote_to_client[1], .{ .session_ended = .{
        .reason = .REASON_PROCESS_EXITED,
    } });

    var session = VisibleClientSessionState{};
    defer session.deinit();

    try std.testing.expectEqual(
        VisibleClientEnd.session_ended,
        try runVisibleTerminal(.{
            .blocking = core_blocking.fromTest(),
            .input_fd = input[0],
            .worker_fds = .{
                .read = remote_to_client[0],
                .write = -1,
            },
            .session = &session,
            .options = .{ .monitor_connection = true },
        }),
    );
}

test "visible client treats input write failure as transport closed" {
    try dispatcher_mod.initGlobal(app_allocator.allocator());
    defer dispatcher_mod.deinitGlobal();

    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    var session = VisibleClientSessionState{};
    defer session.deinit();

    try core_blocking.fromTest().writeAll(input[1], "typed");

    try std.testing.expectEqual(
        VisibleClientEnd.transport_closed,
        try runVisibleTerminal(.{
            .blocking = core_blocking.fromTest(),
            .input_fd = input[0],
            .worker_fds = .{
                .read = remote_to_client[0],
                .write = -1,
            },
            .session = &session,
            .options = .{ .monitor_connection = true },
        }),
    );
}

test "visible client keeps exit-restore bytes while reconnecting" {
    var session = VisibleClientSessionState{};
    defer session.deinit();
    try session.visible_client_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    try std.testing.expectEqual(VisibleClientEnd.transport_closed, finishVisibleClientBlocking(core_blocking.fromTest(), .transport_closed, &session));
    try std.testing.expectEqualStrings("restore-primary", session.visible_client_end_restore.items);

    try std.testing.expectEqual(VisibleClientEnd.unresponsive, finishVisibleClientBlocking(core_blocking.fromTest(), .unresponsive, &session));
    try std.testing.expectEqualStrings("restore-primary", session.visible_client_end_restore.items);
}

test "cancelled reconnect frame read returns without input" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var cancelled = true;
    try std.testing.expectError(error.ReconnectCancelled, readVisibleClientFrameMaybeCancelled(core_blocking.fromTest(), fds[0], &cancelled));
}

test "draw payload preserves app title presence bit" {
    const draw = try drawPayloadFromMessage(.{
        .scrollback_cursor = "opaque-cursor",
        .draw_bytes = "",
        .app_title_present = false,
    });
    defer freeDrawPayload(draw);

    try std.testing.expect(draw.app_title_present != null);
    try std.testing.expect(!draw.app_title_present.?);
}

test "draw payload updates terminal worker app title presence state" {
    var session = VisibleClientSessionState{};
    defer session.deinit();

    try handleDrawPayload(.{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .app_title_present = false,
        .visible_client_end_restore_bytes = null,
    }, DrawApplyContext.forSession(core_blocking.fromTest(), &session, .ignore));

    try std.testing.expect(session.app_title_present != null);
    try std.testing.expect(!session.app_title_present.?);
}

test "recovery polling stores visible-client exit restore bytes from draw" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = VisibleClientSessionState{};
    defer session.deinit();

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), fds[1], .{ .draw = .{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .visible_client_end_restore_bytes = "restore-primary",
    } });

    try std.testing.expectEqual(TerminalWorkerRecovery.recovered, (try pollTerminalWorkerRecovery(core_blocking.fromTest(), fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.visible_client_end_restore.items);
}

test "recovery polling ignores draw while repaint is outstanding" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = VisibleClientSessionState{ .pending_repaint = .{ .repaint_request_seq = 7 } };
    defer session.deinit();

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), fds[1], .{ .draw = .{
        .scrollback_cursor = "stale-cursor",
        .viewport_offset = 3,
        .draw_bytes = "",
    } });

    try std.testing.expectEqual(@as(?TerminalWorkerRecovery, null), try pollTerminalWorkerRecovery(core_blocking.fromTest(), fds[0], &session, 0));
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);
    try std.testing.expect(session.pending_repaint.active());
}

test "recovery polling waits for resize repaint after input ack" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = VisibleClientSessionState{};
    defer session.deinit();
    const repaint_seq = session.pending_repaint.startResizeAt(1_000);

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), fds[1], .{ .input_ack = .{
        .input_seq = 1,
    } });

    try std.testing.expectEqual(@as(?TerminalWorkerRecovery, null), try pollTerminalWorkerRecovery(core_blocking.fromTest(), fds[0], &session, 0));
    try std.testing.expect(session.pending_repaint.requiresRepaintForRecovery());

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), fds[1], .{ .repaint_response = .{
        .repaint_request_seq = repaint_seq,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 0,
            .draw_bytes = "",
        },
    } });

    try std.testing.expectEqual(TerminalWorkerRecovery.recovered, (try pollTerminalWorkerRecovery(core_blocking.fromTest(), fds[0], &session, 0)).?);
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
}

test "repaint response applies only latest outstanding request" {
    const payload = try protocol.encodePayload(app_allocator.allocator(), pb.TerminalEmulatorItem.RepaintResponse{
        .repaint_request_seq = 7,
        .draw = .{
            .scrollback_cursor = "cursor-v7",
            .viewport_offset = 4,
            .draw_bytes = "",
            .visible_client_end_restore_bytes = "restore-v7",
        },
    });
    defer app_allocator.allocator().free(payload);

    var session = VisibleClientSessionState{};
    defer session.deinit();
    const draw_context = DrawApplyContext.forSession(core_blocking.fromTest(), &session, .ignore);
    try std.testing.expect(!try handleRepaintResponseFrame(payload, draw_context));
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);

    session.pending_repaint = .{ .repaint_request_seq = 8 };
    try std.testing.expect(!try handleRepaintResponseFrame(payload, draw_context));
    try std.testing.expectEqual(@as(u64, 8), session.pending_repaint.repaint_request_seq);
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);

    session.pending_repaint = .{ .repaint_request_seq = 7 };
    try std.testing.expect(try handleRepaintResponseFrame(payload, draw_context));
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("cursor-v7", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 4), session.viewport_offset);
    try std.testing.expectEqualStrings("restore-v7", session.visible_client_end_restore.items);
}

test "reconnect waits for repaint response before returning" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    repaint_mod.testing.setNextRequestSeq(77);

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), remote_to_client[1], .{ .session_ready = .{} });

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), remote_to_client[1], .{ .repaint_response = .{
        .repaint_request_seq = 77,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 5,
            .draw_bytes = "",
        },
    } });

    var session = VisibleClientSessionState{};
    defer session.deinit();
    try session.scrollback_cursor.set("old-cursor");

    try reconnectSessionOnTerminalWorker(core_blocking.fromTest(), .{
        .read = remote_to_client[0],
        .write = client_to_remote[1],
    }, &session);

    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 5), session.viewport_offset);
}

test "terminal worker repaint after local ui requests screen-only repaint" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    repaint_mod.testing.setNextRequestSeq(91);

    try protocol_test_helpers.sendTerminalEmulatorPayloadFrameBlocking(app_allocator.allocator(), remote_to_client[1], .{ .repaint_response = .{
        .repaint_request_seq = 91,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 6,
            .draw_bytes = "",
        },
    } });

    var session = VisibleClientSessionState{};
    defer session.deinit();
    try session.scrollback_cursor.set("old-cursor");
    session.viewport_offset = 5;

    try repaintVisibleClientSessionState(core_blocking.fromTest(), .{
        .read = remote_to_client[0],
        .write = client_to_remote[1],
    }, &session);

    var frame = try readVisibleClientFrameMaybeCancelled(core_blocking.fromTest(), client_to_remote[0], null);
    defer frame.deinit(app_allocator.allocator());
    try std.testing.expectEqual(protocol.MessageType.client_remote, frame.message_type);
    var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
    defer item.deinit(app_allocator.allocator());
    const item_payload = item.payload orelse return error.MissingTerminalEmulatorPayload;
    const resize = switch (item_payload) {
        .resize => |message| message,
        else => return error.UnexpectedTerminalEmulatorPayload,
    };
    try std.testing.expectEqual(@as(u32, 24), resize.terminal_rows);
    try std.testing.expectEqual(@as(u32, 80), resize.terminal_cols);
    try std.testing.expectEqual(@as(?i32, 5), resize.viewport_offset);
    const repaint = resize.repaint_request orelse return error.ExpectedRepaintRequest;
    try std.testing.expectEqual(@as(u64, 91), repaint.repaint_request_seq);
    try std.testing.expect(repaint.scrollback_cursor == null);
    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 6), session.viewport_offset);
}

// Session creation depends on a single local-terminal snapshot: size, cursor,
// keyboard mode, and default colors must describe the same point in time as the
// open request sent to the terminal worker.
pub const StartNewSessionOptions = struct {
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    reap_ms: u64,
    local_terminal: *LocalTerminalState,
};

pub fn startNewSessionOnTerminalWorker(
    options: StartNewSessionOptions,
) !VisibleClientSessionState {
    const repaint_request_seq = try sendSessionCreate(options);
    var session = try readVisibleClientSessionState(options.blocking, options.worker_fds.read);
    session.viewport_offset = options.local_terminal.viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    session.initial_draw_alignment.setCursor(options.local_terminal.cursor_position);
    session.initial_kitty_keyboard_flags = options.local_terminal.initial_kitty_keyboard_flags;
    return session;
}

fn reconnectSessionOnTerminalWorker(
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
) !void {
    try reconnectSessionOnTerminalWorkerInner(.{
        .blocking = blocking,
        .worker_fds = worker_fds,
        .session = session,
        .wait_for_repaint = true,
    });
}

pub fn reconnectSessionOnTerminalWorkerCancellable(
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    cancelled: *const bool,
) !void {
    try reconnectSessionOnTerminalWorkerInner(.{
        .blocking = blocking,
        .worker_fds = worker_fds,
        .session = session,
        .cancelled = cancelled,
        .wait_for_repaint = false,
    });
}

// Shared reconnect request shape for blocking reconnect and cancellable
// reconnect races. The cancellable form is used while an old transport may
// still recover, so it must be able to abandon the new read without consuming
// stale frames as success.
const ReconnectTerminalWorkerRequest = struct {
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    cancelled: ?*const bool = null,
    wait_for_repaint: bool,
};

fn reconnectSessionOnTerminalWorkerInner(request: ReconnectTerminalWorkerRequest) !void {
    request.session.pending_repaint.repaint_request_seq = try sendSessionOpen(request.blocking, request.worker_fds.write, terminal.currentWindowSize(), request.session);
    try readSessionReadyInner(request.blocking, request.worker_fds.read, request.cancelled);
    if (request.wait_for_repaint) {
        try finishReconnectRepaintInner(request.blocking, request.worker_fds.read, request.session, request.cancelled);
    }
}

pub fn finishReconnectRepaint(
    blocking: core_blocking.Blocking,
    read_fd: c.fd_t,
    session: *VisibleClientSessionState,
) !void {
    try finishReconnectRepaintInner(blocking, read_fd, session, null);
}

fn repaintVisibleClientSessionState(
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
) !void {
    try sendTerminalEmulatorPayloadForeground(blocking, worker_fds.write, .{ .resize = visible_client_messages.resizeMessage(.{
        .size = terminal.currentWindowSize(),
        .viewport_offset = visible_client_messages.nonZeroViewportOffset(session.viewport_offset),
        .repaint_request = .{ .repaint_request_seq = session.pending_repaint.start() },
    }) });
    try finishReconnectRepaint(blocking, worker_fds.read, session);
}

// During reconnect, keep reading worker frames until the requested repaint is
// complete. Draw/input-ack/transcript frames can arrive interleaved with the
// repaint response, so this loop applies only the pieces that advance recovery.
fn finishReconnectRepaintInner(
    blocking: core_blocking.Blocking,
    read_fd: c.fd_t,
    session: *VisibleClientSessionState,
    cancelled: ?*const bool,
) !void {
    while (session.pending_repaint.active()) {
        var frame = try readVisibleClientFrameMaybeCancelled(blocking, read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                switch (item_payload) {
                    .draw => {},
                    .repaint_response => |response| {
                        _ = try handleRepaintResponseMessage(response, DrawApplyContext.forSession(blocking, session, .ignore));
                    },
                    .input_ack => |ack| {
                        _ = handleInputAckMessage(ack, session);
                    },
                    .tty_transcript_chunk => |chunk| handleTtyTranscriptChunkMessage(chunk),
                    .session_ended => |ended| {
                        session.recordSessionEnded(ended);
                        return error.SessionEnded;
                    },
                    else => return error.UnexpectedFrame,
                }
            },
            .client_daemon => {
                switch (try handleClientDaemonFrame(blocking, frame.payload)) {
                    .handled => {},
                    .transport_closed => return error.RemoteTransportClosed,
                    .unexpected => return error.UnexpectedFrame,
                }
            },
            .error_message => {
                try printErrorPayload(blocking, frame.payload);
                return error.RemoteError;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

pub fn runVisibleClient(
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    options: VisibleClientOptions,
) !VisibleClientEnd {
    return runVisibleClientLoop(
        blocking,
        worker_fds,
        session,
        .{
            .monitor_connection = options.monitor_connection,
            .responsiveness_timeout_floor_ms = @max(options.responsiveness_timeout_floor_ms, session.unresponsive_timeout_floor_ms),
        },
    );
}

pub fn drainLocalTransportDiagnostics(blocking: core_blocking.Blocking, read_fd: c.fd_t, timeout_ms: u64) void {
    var context = LocalTransportDiagnosticsDrain.init(read_fd);
    defer context.deinit();
    context.run(blocking, timeout_ms) catch {};
}

const LocalTransportDiagnosticsDrain = struct {
    read_fd: c.fd_t,
    reader: protocol.FrameReader,

    fn init(read_fd: c.fd_t) LocalTransportDiagnosticsDrain {
        return .{
            .read_fd = read_fd,
            .reader = protocol.FrameReader.init(app_allocator.allocator()),
        };
    }

    fn deinit(self: *LocalTransportDiagnosticsDrain) void {
        self.reader.deinit();
    }

    fn run(self: *LocalTransportDiagnosticsDrain, blocking: core_blocking.Blocking, timeout_ms: u64) !void {
        var clock = try NonSuspendingTimer.start();
        const deadline_ms = visibleClientNowMs(&clock) +| timeout_ms;
        while (true) {
            var pollfds = [_]posix.pollfd{.{
                .fd = self.read_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const timeout = visibleClientPollTimeoutMs(&clock, deadline_ms);
            const ready = try blocking.poll(pollfds[0..], timeout);
            if (ready == 0) return;

            const revents = pollfds[0].revents;
            if ((revents & posix.POLL.IN) != 0) {
                if (try self.drainReadable(blocking)) return;
            }
            if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) return;
            if (visibleClientNowMs(&clock) >= deadline_ms) return;
        }
    }

    fn drainReadable(self: *LocalTransportDiagnosticsDrain, blocking: core_blocking.Blocking) !bool {
        while (true) {
            var frame = switch (try self.reader.readReady(self.read_fd)) {
                .blocked, .progress => return false,
                .frame => |frame| frame,
                .eof, .truncated_frame => return true,
            };
            defer frame.deinit(app_allocator.allocator());
            switch (frame.message_type) {
                .client_daemon => switch (try handleClientDaemonFrame(blocking, frame.payload)) {
                    .handled => {},
                    .transport_closed, .unexpected => return true,
                },
                else => return true,
            }
        }
    }
};

fn visibleClientNowMs(clock: *NonSuspendingTimer) u64 {
    return @intCast(clock.read() / std.time.ns_per_ms);
}

fn visibleClientPollTimeoutMs(clock: *NonSuspendingTimer, deadline_ms: u64) i32 {
    const now_ms = visibleClientNowMs(clock);
    if (now_ms >= deadline_ms) return 0;
    const remaining_ms = deadline_ms - now_ms;
    const max_poll_ms: u64 = @intCast(std.math.maxInt(i32));
    return @intCast(@min(remaining_ms, max_poll_ms));
}

fn pollTerminalWorkerRecovery(
    blocking: core_blocking.Blocking,
    read_fd: c.fd_t,
    session: *VisibleClientSessionState,
    timeout_ms: i32,
) !?TerminalWorkerRecovery {
    var pollfds = [_]posix.pollfd{.{
        .fd = read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try blocking.poll(pollfds[0..], timeout_ms);
    if (ready == 0) return null;

    const revents = pollfds[0].revents;
    if ((revents & posix.POLL.IN) != 0) {
        return readTerminalWorkerRecoveryFrame(blocking, read_fd, session);
    }
    if ((revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        return .transport_closed;
    }
    return null;
}

// Interpret one worker frame while deciding whether a previously unresponsive
// connection has recovered. Recovery requires a fresh draw/repaint boundary, not
// just arbitrary bytes, so stale output is ignored until the repaint state allows
// it.
fn readTerminalWorkerRecoveryFrame(blocking: core_blocking.Blocking, read_fd: c.fd_t, session: *VisibleClientSessionState) !?TerminalWorkerRecovery {
    const reader = session.recoveryReader(read_fd);
    var frame = switch (try reader.readReady(read_fd)) {
        .blocked, .progress => return null,
        .frame => |frame| frame,
        .eof, .truncated_frame => return .transport_closed,
    };
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse return error.UnexpectedFrame;
            switch (item_payload) {
                .draw => |draw| {
                    if (session.pending_repaint.active()) return null;
                    try handleDrawMessage(draw, DrawApplyContext.forSession(blocking, session, .ignore));
                    return .recovered;
                },
                .repaint_response => |response| {
                    const applied = try handleRepaintResponseMessage(response, DrawApplyContext.forSession(blocking, session, .ignore));
                    return if (applied) .recovered else null;
                },
                .input_ack => |ack| {
                    _ = handleInputAckMessage(ack, session);
                    if (session.pending_repaint.requiresRepaintForRecovery()) return null;
                    return .recovered;
                },
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return .recovered;
                },
                .session_ended => |ended| {
                    session.recordSessionEnded(ended);
                    _ = finishVisibleClientBlocking(blocking, .session_ended, session);
                    return .session_ended;
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(blocking, frame.payload)) {
            .handled => return null,
            .transport_closed => return .remote_transport_closed,
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(blocking, frame.payload);
            _ = finishVisibleClientBlocking(blocking, .session_ended, session);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

fn readVisibleClientSessionState(blocking: core_blocking.Blocking, read_fd: c.fd_t) !VisibleClientSessionState {
    // Initial session creation waits for either a session_ready item or a daemon
    // error. Client-daemon diagnostics may arrive first, so consume handled
    // daemon items until the terminal worker answers.
    while (true) {
        var frame = try readVisibleClientFrameMaybeCancelled(blocking, read_fd, null);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => return initialSessionError(blocking, frame.payload),
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                const ready = switch (item_payload) {
                    .session_ready => |message| message,
                    else => return error.UnexpectedFrame,
                };
                var session = VisibleClientSessionState{};
                try session.setIdentity(ready.session_guid);
                return session;
            },
            .client_daemon => switch (try handleClientDaemonFrame(blocking, frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readSessionReady(blocking: core_blocking.Blocking, conn: c.fd_t) !void {
    return readSessionReadyInner(blocking, conn, null);
}

fn readSessionReadyInner(
    blocking: core_blocking.Blocking,
    read_fd: c.fd_t,
    cancelled: ?*const bool,
) !void {
    // Reconnect opens wait for a fresh session_ready but may be cancelled by the
    // visible UI if the user hangs up before the replacement transport wins.
    while (true) {
        var frame = try readVisibleClientFrameMaybeCancelled(blocking, read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => return initialSessionError(blocking, frame.payload),
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                switch (item_payload) {
                    .session_ready => return,
                    else => return error.UnexpectedFrame,
                }
            },
            .client_daemon => switch (try handleClientDaemonFrame(blocking, frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn initialSessionError(blocking: core_blocking.Blocking, payload: []const u8) anyerror {
    // Convert daemon error frames into public sessh errors. Some errors are
    // control-flow signals for fallback/reconnect; other transport failures are
    // already user-facing and should be printed before returning an exit code.
    const parsed = try parseErrorPayload(payload);
    if (std.mem.eql(u8, parsed.code, "VERSION_MISMATCH")) {
        freeErrorPayload(parsed);
        return error.VersionMismatch;
    }
    if (std.mem.eql(u8, parsed.code, "SESSION_NOT_FOUND")) {
        freeErrorPayload(parsed);
        return error.RemoteDaemonDied;
    }
    if (std.mem.eql(u8, parsed.code, "UNSUPPORTED_REMOTE_PLATFORM")) {
        freeErrorPayload(parsed);
        return error.UnsupportedRemotePlatform;
    }
    if (transportExitCode(parsed.code)) |exit_code| {
        try printParsedError(blocking, parsed);
        return process_exit.request(exit_code);
    }
    try printParsedError(blocking, parsed);
    return process_exit.request(1);
}

fn readVisibleClientFrameMaybeCancelled(
    blocking: core_blocking.Blocking,
    fd: c.fd_t,
    cancelled: ?*const bool,
) !protocol.OwnedFrame {
    return foreground_frame_io.readFrame(.{
        .blocking = blocking,
        .allocator = app_allocator.allocator(),
        .fd = fd,
        .cancelled = cancelled,
        .cancel_error = error.ReconnectCancelled,
    });
}

fn writeVisibleClientFrameForeground(
    blocking: core_blocking.Blocking,
    fd: c.fd_t,
    message_type: protocol.MessageType,
    payload: []const u8,
) !void {
    try foreground_frame_io.writeFrame(.{
        .blocking = blocking,
        .allocator = app_allocator.allocator(),
        .fd = fd,
        .message_type = message_type,
        .payload = payload,
    });
}

// Build and send the terminal open/create request. This is where local tty
// settings, environment, command form, initial window size, and repaint request
// are frozen into the remote session's startup payload.
fn sendSessionCreate(
    options: StartNewSessionOptions,
) !u64 {
    if (options.command_argv.len > 0 and options.shell_command != null) return error.InvalidSessionCommand;
    const repaint_request_seq = repaint_mod.allocateRequestSeq();
    var create = pb.TerminalEmulatorItem.SessionCreate{
        .scrollback_row_limit = options.scrollback_row_count,
        .reap_ms = options.reap_ms,
    };
    var protocol_tty_settings = pb.TerminalEmulatorItem.SessionCreate.TtySettings{};
    defer protocol_tty_settings.tty_mode.deinit(app_allocator.allocator());
    if (options.local_terminal.tty_settings) |settings| {
        for (settings.modes) |mode| {
            try protocol_tty_settings.tty_mode.append(app_allocator.allocator(), .{
                .opcode = mode.opcode,
                .value = mode.value,
            });
        }
        create.tty_settings = protocol_tty_settings;
    }
    var exec_command = pb.TerminalEmulatorItem.SessionCreate.ExecCommand{};
    defer exec_command.argv.deinit(app_allocator.allocator());
    if (options.shell_command) |command| {
        create.command = .{ .shell_command = .{ .command = command } };
    } else if (options.command_argv.len > 0) {
        try exec_command.argv.appendSlice(app_allocator.allocator(), options.command_argv);
        create.command = .{ .exec_command = exec_command };
    }
    create.query_default_colors = .{
        .foreground_color = options.local_terminal.default_colors.foreground_color,
        .background_color = options.local_terminal.default_colors.background_color,
    };
    const message = pb.TerminalEmulatorItem.Open{
        .session_guid = options.session_guid,
        .resize = visible_client_messages.resizeMessage(.{
            .size = options.local_terminal.size,
            .viewport_offset = options.local_terminal.viewport_offset,
            .repaint_request = .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = "",
            },
        }),
        .capture_tty_transcript = tty_transcript.enabled(),
        .create = create,
    };
    try sendTerminalEmulatorPayloadForeground(options.blocking, options.worker_fds.write, .{ .open = message });
    return repaint_request_seq;
}

fn sendSessionOpen(
    blocking: core_blocking.Blocking,
    write_fd: c.fd_t,
    size: WindowSize,
    session: *const VisibleClientSessionState,
) !u64 {
    // Re-open an existing visible session after reconnect. The scrollback cursor
    // tells the worker which retained rows the client already has so repaint can
    // be incremental.
    const repaint_request_seq = repaint_mod.allocateRequestSeq();
    const message = pb.TerminalEmulatorItem.Open{
        .session_guid = session.guidSlice(),
        .resize = visible_client_messages.resizeMessage(.{
            .size = size,
            .viewport_offset = visible_client_messages.nonZeroViewportOffset(session.viewport_offset),
            .repaint_request = .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = session.scrollback_cursor.slice(),
            },
        }),
        .capture_tty_transcript = tty_transcript.enabled(),
    };
    try sendTerminalEmulatorPayloadForeground(blocking, write_fd, .{ .open = message });
    return repaint_request_seq;
}

fn sendTerminalEmulatorPayloadForeground(
    blocking: core_blocking.Blocking,
    fd: c.fd_t,
    payload: protocol.TerminalEmulatorPayload,
) !void {
    const encoded = try protocol.encodeClientRemotePayload(app_allocator.allocator(), .{
        .terminal_emulator = .{ .payload = payload },
    });
    defer app_allocator.allocator().free(encoded);
    try writeVisibleClientFrameForeground(blocking, fd, .client_remote, encoded);
}

fn readSessionEndedOrError(blocking: core_blocking.Blocking, conn: c.fd_t) !bool {
    // After sending a hang-up/open failure path, drain until the worker confirms
    // session end or reports a terminal error. Returning true means an error was
    // printed and should influence the caller's exit path.
    while (true) {
        var frame = try readVisibleClientFrameMaybeCancelled(blocking, conn, null);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                try printErrorPayload(blocking, frame.payload);
                return true;
            },
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                switch (item_payload) {
                    .session_ended => return false,
                    else => return error.UnexpectedFrame,
                }
            },
            .client_daemon => switch (try handleClientDaemonFrame(blocking, frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

// Wrap the foreground terminal for the lifetime of one visible client: enable
// raw-ish local input, install presentation cleanup, run the event loop, and
// restore terminal state before returning the ssh-shaped end reason.
fn runVisibleClientLoop(
    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    options: VisibleClientOptions,
) !VisibleClientEnd {
    const output_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    var mode_guard = try terminal.TerminalModeGuard.enable(posix.STDIN_FILENO);
    defer mode_guard.restore();
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    defer if (cleanup_title) |title| app_allocator.allocator().free(title);
    var presentation_guard = if (output_is_tty) guard: {
        break :guard if (cleanup_title) |title|
            PresentationGuard.initWithCleanupTitleAndInitialKittyKeyboardFlags(
                blocking,
                posix.STDOUT_FILENO,
                title,
                session.initial_kitty_keyboard_flags,
            )
        else
            PresentationGuard.initWithInitialKittyKeyboardFlags(blocking, posix.STDOUT_FILENO, session.initial_kitty_keyboard_flags);
    } else guard: {
        var inactive = PresentationGuard.initWithInitialKittyKeyboardFlags(blocking, posix.STDOUT_FILENO, session.initial_kitty_keyboard_flags);
        inactive.active = false;
        break :guard inactive;
    };
    defer presentation_guard.restore();

    const end = try runVisibleTerminal(.{
        .blocking = blocking,
        .input_fd = posix.STDIN_FILENO,
        .worker_fds = worker_fds,
        .session = session,
        .options = options,
    });
    if (end == .client_hangup) writeClientCloseBoundary(blocking);
    return end;
}

// Inputs needed to run the foreground terminal loop. Grouping them prevents the
// dispatcher loop setup from taking a long list of loosely-related fd/session
// parameters.
const VisibleTerminalRun = struct {
    blocking: core_blocking.Blocking,
    input_fd: c.fd_t,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    options: VisibleClientOptions,
};

// Event-driven foreground loop for one visible terminal. It owns local stdin,
// stdout, the worker frame connection, resize/repaint maintenance, ssh-style
// escape controls, and terminal output backpressure.
const VisibleTerminalLoop = struct {
    const Mode = enum {
        normal,
        escape_help,
    };

    blocking: core_blocking.Blocking,
    worker_fds: TerminalWorkerFds,
    session: *VisibleClientSessionState,
    read_fd_flags_guard: ?core_fds.StatusFlagsGuard = null,
    write_fd_flags_guard: ?core_fds.StatusFlagsGuard = null,
    stdout_fd_flags_guard: ?core_fds.StatusFlagsGuard = null,
    mode: Mode = .normal,
    dispatcher: *dispatcher_mod.Dispatcher,
    input_task: dispatcher_mod.DispatchTask = dispatcher_mod.DispatchTask.uninitialized(),
    worker_task: dispatcher_mod.DispatchTask = dispatcher_mod.DispatchTask.uninitialized(),
    timer_task: dispatcher_mod.DispatchTask = dispatcher_mod.DispatchTask.uninitialized(),
    end: ?VisibleClientEnd = null,
    help_overlay_state: ?client_ui.OverlayDrawState = null,
    help_last_size: WindowSize = .{ .rows = 0, .cols = 0 },
    filtered_buf: [8192]u8 = undefined,
    last_size: WindowSize,
    connection_monitor: ConnectionMonitor,
    input_source: dispatcher_mod.Source,
    worker_source: dispatcher_mod.Source,
    worker_sink: dispatcher_mod.Sink,
    stdout_sink: dispatcher_mod.Sink,

    fn init(params: VisibleTerminalRun) !VisibleTerminalLoop {
        // The visible terminal loop owns local stdin/stdout and one worker
        // transport. Put the worker fds in nonblocking mode before the
        // dispatcher watches them.
        var read_fd_flags_guard = try core_fds.StatusFlagsGuard.setNonBlocking(params.worker_fds.read);
        errdefer read_fd_flags_guard.restore();
        var write_fd_flags_guard = if (params.worker_fds.write == params.worker_fds.read)
            null
        else
            core_fds.StatusFlagsGuard.setNonBlocking(params.worker_fds.write) catch null;
        errdefer if (write_fd_flags_guard) |*guard| guard.restore();
        var stdout_fd_flags_guard = try core_fds.StatusFlagsGuard.setNonBlocking(posix.STDOUT_FILENO);
        errdefer stdout_fd_flags_guard.restore();
        const loop_dispatcher = dispatcher_mod.get();
        var registered_input = try loop_dispatcher.byteSource(params.input_fd, 4096);
        errdefer registered_input.deinit();
        var registered_worker_source = try loop_dispatcher.frameSource(params.worker_fds.read);
        errdefer registered_worker_source.deinit();
        var registered_worker_sink = try loop_dispatcher.frameSink(.{
            .allocator = app_allocator.allocator(),
            .fd = params.worker_fds.write,
        });
        errdefer registered_worker_sink.deinit();
        var registered_stdout_sink = try loop_dispatcher.byteSink(.{
            .allocator = app_allocator.allocator(),
            .fd = posix.STDOUT_FILENO,
            .max_pending_bytes = max_visible_stdout_pending_bytes,
            .low_watermark = visible_stdout_low_watermark,
        });
        errdefer registered_stdout_sink.deinit();
        return .{
            .blocking = params.blocking,
            .worker_fds = params.worker_fds,
            .session = params.session,
            .read_fd_flags_guard = read_fd_flags_guard,
            .write_fd_flags_guard = write_fd_flags_guard,
            .stdout_fd_flags_guard = stdout_fd_flags_guard,
            .dispatcher = loop_dispatcher,
            .last_size = terminal.currentWindowSize(),
            .connection_monitor = .{
                .enabled = params.options.monitor_connection,
                .responsiveness_timeout_floor_ms = params.options.responsiveness_timeout_floor_ms,
            },
            .input_source = registered_input,
            .worker_source = registered_worker_source,
            .worker_sink = registered_worker_sink,
            .stdout_sink = registered_stdout_sink,
        };
    }

    fn deinit(self: *VisibleTerminalLoop) void {
        self.input_task.deinit();
        self.worker_task.deinit();
        self.timer_task.deinit();
        self.stdout_sink.deinit();
        self.worker_sink.deinit();
        self.worker_source.deinit();
        self.input_source.deinit();
        if (self.stdout_fd_flags_guard) |*guard| guard.restore();
        if (self.write_fd_flags_guard) |*guard| guard.restore();
        if (self.read_fd_flags_guard) |*guard| guard.restore();
    }

    // Register worker-read and timer watches plus an input DispatchTask. The
    // task owns stdin as a Source and treats worker/stdout output as Sinks, so
    // terminal input is scheduled only when output backpressure can accept the
    // resulting work.
    fn run(self: *VisibleTerminalLoop) !VisibleClientEnd {
        self.input_task = dispatcher_mod.dispatchTask(VisibleTerminalLoop, app_allocator.allocator(), self, runInputTask);
        try self.input_task.requireSource(self.input_source);
        if (self.worker_fds.write >= 0) {
            try self.input_task.requireSink(self.worker_sink);
        }
        try self.input_task.requireSink(self.stdout_sink);
        try self.input_task.schedule(self.dispatcher);

        self.worker_task = dispatcher_mod.dispatchTask(VisibleTerminalLoop, app_allocator.allocator(), self, handleVisibleTerminalLoopWorker);
        try self.worker_task.requireSource(self.worker_source);
        try self.worker_task.requireSink(self.stdout_sink);
        try self.worker_task.schedule(self.dispatcher);

        self.timer_task = dispatcher_mod.timerDispatchTask(VisibleTerminalLoop, app_allocator.allocator(), self, handleVisibleTerminalLoopTimer);
        try self.updateFdInterests();
        try self.updateTimer();
        _ = try self.blocking.loop();
        return self.end orelse .transport_closed;
    }

    fn setEnd(self: *VisibleTerminalLoop, end: VisibleClientEnd) void {
        self.end = end;
        if (!self.stdout_sink.hasPendingWrite()) self.dispatcher.stop();
    }

    fn updateTimer(self: *VisibleTerminalLoop) !void {
        const delay_ms: u64 = if (self.end != null)
            10
        else
            @intCast(self.connection_monitor.pollTimeoutMs());
        self.timer_task.setTimerAfter(self.dispatcher, delay_ms);
        try self.timer_task.schedule(self.dispatcher);
    }

    fn updateFdInterests(self: *VisibleTerminalLoop) !void {
        const ending = self.end != null;
        if (self.worker_sink.hasPendingWrite() and self.worker_fds.write < 0) {
            self.setEnd(try finishVisibleClientAfterTerminalWorkerWriteFailed(self));
            return;
        }
        if (ending) {
            self.worker_task.cancel();
        } else {
            // Remote draw bytes are queued to stdout. If stdout is slow, the
            // worker task is gated by stdout's low watermark so backpressure
            // reaches the daemon tunnel instead of accumulating local draw data.
            try self.worker_task.schedule(self.dispatcher);
        }
    }

    fn handleWorkerEvent(self: *VisibleTerminalLoop, event: dispatcher_mod.FdEvent) !void {
        if (!event.readable and (event.hangup or event.error_event or event.invalid)) {
            self.setEnd(try self.finishVisibleClient(.transport_closed));
            return;
        }
        if (!event.readable) return;
        if (self.mode == .escape_help) {
            if (try drainEscapeHelpTerminalWorkerFrames(self)) |end| {
                try self.clearEscapeHelpOverlay();
                self.setEnd(try self.finishVisibleClient(end));
            }
            return;
        }
        if (try drainVisibleClientTerminalWorkerFrames(self)) |end| {
            self.setEnd(try self.finishVisibleClient(end));
        }
    }

    // Consume one Source-buffered terminal input unit, filter sessh escape
    // controls, and queue remaining bytes to the worker. Escape-help mode
    // consumes one keypress to dismiss the overlay instead of forwarding it to
    // the remote PTY.
    fn handleQueuedInput(self: *VisibleTerminalLoop) !void {
        const input_unit = self.input_source.readBytes() orelse return;
        const input = switch (input_unit) {
            .bytes => |bytes| bytes,
            .eof => {
                if (self.mode == .escape_help) try self.clearEscapeHelpOverlay();
                self.setEnd(try self.finishVisibleClient(clientHangup()));
                return;
            },
        };
        if (self.mode == .escape_help) {
            try self.dismissEscapeHelpOverlay();
            return;
        }

        const session = self.session;
        const result = session.input_escape_filter.filter(input, &self.filtered_buf);
        if (result.bytes.len > 0) {
            const paste_like = session.paste_like_input_classifier.classify(result.bytes.len);
            try visible_client_messages.writeInputChunks(.{
                .writer = self.worker_sink.frame(),
                .bytes = result.bytes,
                .session = session,
                .paste_like = paste_like,
            });
            self.connection_monitor.afterInput();
        }
        if (result.end) |end| switch (end) {
            .disconnect => self.setEnd(try self.finishVisibleClient(clientHangup())),
            .help => try self.enterEscapeHelpOverlay(),
            .repaint => try visible_client_messages.writeScreenRepaint(self.worker_sink.frame(), session),
        };
    }

    fn runMaintenance(self: *VisibleTerminalLoop) !void {
        if (self.mode == .escape_help) {
            try self.refreshEscapeHelpOverlayForResize();
            return;
        }
        const session = self.session;
        try visible_client_messages.maybeWriteResize(.{
            .writer = self.worker_sink.frame(),
            .last_size = &self.last_size,
            .session = session,
        });
        if (try self.checkResizeRepaintTimeout()) |end| {
            self.setEnd(end);
            return;
        }
        if (self.connection_monitor.isUnresponsive()) {
            self.setEnd(.unresponsive);
        }
    }

    fn enterEscapeHelpOverlay(self: *VisibleTerminalLoop) !void {
        self.mode = .escape_help;
        self.help_last_size = terminal.currentWindowSize();
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(app_allocator.allocator());
        try drawEscapeHelpOverlay(.{
            .renderer = client_renderer.Renderer.bufferedXtermCompatible(&buffer),
            .size = self.help_last_size,
            .session = self.session,
            .overlay_state = &self.help_overlay_state,
        });
        try self.stdout_sink.writeBytes(buffer.items);
    }

    fn dismissEscapeHelpOverlay(self: *VisibleTerminalLoop) !void {
        try self.clearEscapeHelpOverlay();
        try visible_client_messages.writeScreenRepaint(self.worker_sink.frame(), self.session);
    }

    fn clearEscapeHelpOverlay(self: *VisibleTerminalLoop) !void {
        if (self.mode != .escape_help and self.help_overlay_state == null) return;
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(app_allocator.allocator());
        const renderer = client_renderer.Renderer.bufferedXtermCompatible(&buffer);
        try clearEscapeHelpOverlayDraw(.{
            .renderer = renderer,
            .session = self.session,
            .overlay_state = &self.help_overlay_state,
        });
        try self.stdout_sink.writeBytes(buffer.items);
        self.mode = .normal;
    }

    fn refreshEscapeHelpOverlayForResize(self: *VisibleTerminalLoop) !void {
        const size = terminal.currentWindowSize();
        if (size.eql(self.help_last_size)) return;
        self.help_last_size = size;
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(app_allocator.allocator());
        try drawEscapeHelpOverlay(.{
            .renderer = client_renderer.Renderer.bufferedXtermCompatible(&buffer),
            .size = size,
            .session = self.session,
            .overlay_state = &self.help_overlay_state,
        });
        try self.stdout_sink.writeBytes(buffer.items);
    }

    fn checkResizeRepaintTimeout(self: *VisibleTerminalLoop) !?VisibleClientEnd {
        if (!self.session.pending_repaint.resizeTimedOut()) return null;
        try self.clearVisibleAfterResizeTimeout();
        return .unresponsive;
    }

    fn clearVisibleAfterResizeTimeout(self: *VisibleTerminalLoop) !void {
        self.session.viewport_offset = 0;
        if (c.isatty(posix.STDOUT_FILENO) == 0) return;
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(app_allocator.allocator());
        const renderer = client_renderer.Renderer.bufferedXtermCompatible(&buffer);
        renderer.restorePresentation(self.session.initial_kitty_keyboard_flags) catch {};
        renderer.clearVisible() catch {};
        try self.stdout_sink.writeBytes(buffer.items);
    }

    fn finishVisibleClient(self: *VisibleTerminalLoop, end: VisibleClientEnd) !VisibleClientEnd {
        if (end == .client_hangup or end == .session_ended) {
            if (c.isatty(posix.STDOUT_FILENO) != 0 and self.session.visible_client_end_restore.items.len != 0) {
                try self.stdout_sink.writeBytes(self.session.visible_client_end_restore.items);
            }
            self.session.visible_client_end_restore.clearRetainingCapacity();
        }
        return end;
    }

    fn runInputTask(
        self: *VisibleTerminalLoop,
        _: *dispatcher_mod.Dispatcher,
        _: *dispatcher_mod.DispatchTask,
    ) !dispatch_io.DispatchTaskStatus {
        if (self.end == null) {
            try self.handleQueuedInput();
            if (self.worker_sink.hasPendingWrite() and self.worker_fds.write < 0) {
                self.setEnd(try finishVisibleClientAfterTerminalWorkerWriteFailed(self));
            }
        }
        if (self.end == null) try self.runMaintenance();
        if (self.end != null) {
            try self.updateFdInterests();
            if (!self.stdout_sink.hasPendingWrite()) {
                self.dispatcher.stop();
            } else {
                try self.updateTimer();
            }
            return .pending;
        }
        try self.updateFdInterests();
        try self.updateTimer();
        return .pending;
    }
};

fn handleVisibleTerminalLoopWorker(
    loop: *VisibleTerminalLoop,
    _: *dispatcher_mod.Dispatcher,
    task: *dispatcher_mod.DispatchTask,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    if (loop.mode == .escape_help) {
        if (try drainEscapeHelpTerminalWorkerFrames(loop)) |end| {
            try loop.clearEscapeHelpOverlay();
            loop.setEnd(try loop.finishVisibleClient(end));
        }
    } else if (try drainVisibleClientTerminalWorkerFrames(loop)) |end| {
        loop.setEnd(try loop.finishVisibleClient(end));
    }
    try afterVisibleTerminalLoopEvent(loop);
    return .pending;
}

fn handleVisibleTerminalLoopTimer(
    loop: *VisibleTerminalLoop,
    _: *dispatcher_mod.Dispatcher,
    task: *dispatcher_mod.DispatchTask,
    _: dispatcher_mod.TimerEvent,
) !dispatch_io.DispatchTaskStatus {
    _ = task;
    try afterVisibleTerminalLoopEvent(loop);
    return .pending;
}

fn afterVisibleTerminalLoopEvent(loop: *VisibleTerminalLoop) !void {
    // Run maintenance after each dispatcher callback so timer rescheduling,
    // overlay repaint, and fd-interest changes are centralized.
    if (loop.end != null) {
        try loop.updateFdInterests();
        if (!loop.stdout_sink.hasPendingWrite()) {
            loop.dispatcher.stop();
        } else {
            try loop.updateTimer();
        }
        return;
    }
    try loop.runMaintenance();
    if (loop.end == null) try loop.updateFdInterests();
    if (loop.end == null) try loop.updateTimer();
}

fn runVisibleTerminal(run: VisibleTerminalRun) !VisibleClientEnd {
    var loop = try VisibleTerminalLoop.init(run);
    defer loop.deinit();
    return loop.run();
}

const EscapeHelpOverlayDrawOptions = struct {
    renderer: client_renderer.Renderer,
    size: WindowSize,
    session: *VisibleClientSessionState,
    overlay_state: *?client_ui.OverlayDrawState,
};

fn drawEscapeHelpOverlay(options: EscapeHelpOverlayDrawOptions) !void {
    // Escape help is drawn with the same overlay machinery as reconnect status
    // so it can coexist with viewport displacement and be erased cleanly.
    const renderer = options.renderer;
    const size = options.size;
    const session = options.session;
    const overlay_state = options.overlay_state;
    var lines: [terminal.escape_help_overlay_lines.len]client_ui.OverlayLine = undefined;
    inline for (terminal.escape_help_overlay_lines, 0..) |line, index| {
        lines[index] = .{
            .text = line,
            .alignment = if (index == 0) .center else .left,
        };
    }
    const top: u16 = if (session.viewport_offset > 0)
        @intCast(@min(@as(usize, @intCast(session.viewport_offset)), @as(usize, std.math.maxInt(u16))))
    else
        0;
    const next = try client_ui.drawOverlayLines(.{
        .renderer = renderer,
        .size = size,
        .viewport_offset = top,
        .previous = overlay_state.*,
        .lines = &lines,
    });
    session.viewport_offset = @intCast(next.viewport_offset);
    overlay_state.* = next;
}

const EscapeHelpOverlayClearOptions = struct {
    renderer: client_renderer.Renderer,
    session: *VisibleClientSessionState,
    overlay_state: *?client_ui.OverlayDrawState,
};

fn clearEscapeHelpOverlayDraw(options: EscapeHelpOverlayClearOptions) !void {
    const renderer = options.renderer;
    const session = options.session;
    const overlay_state = options.overlay_state;
    const state = overlay_state.* orelse return;
    const size = terminal.currentWindowSize();
    try client_ui.eraseOverlayRows(renderer, state, size);
    try client_ui.restoreOverlayExpansion(renderer, state, size);
    const cleared = client_ui.clearedOverlayViewportOffset(state);
    session.viewport_offset = @intCast(cleared);
    overlay_state.* = null;
    try renderer.moveCursor(terminal.top_left_position.withRow(cleared));
}

const TerminalWorkerFrameAction = union(enum) {
    blocked,
    handled,
    end: VisibleClientEnd,
};

fn drainEscapeHelpTerminalWorkerFrames(loop: *VisibleTerminalLoop) !?VisibleClientEnd {
    while (true) {
        switch (try handleEscapeHelpTerminalWorkerFrame(loop)) {
            .blocked => return null,
            .handled => continue,
            .end => |end| return end,
        }
    }
}

// While the help overlay is visible, worker frames are still consumed so input
// acks and session end state are not lost, but draw/repaint output is deferred
// until the overlay is dismissed and a repaint restores a single screen truth.
fn handleEscapeHelpTerminalWorkerFrame(loop: *VisibleTerminalLoop) !TerminalWorkerFrameAction {
    const session = loop.session;
    var frame = switch (loop.worker_source.readFrame() catch |err| switch (err) {
        error.TruncatedFrame => return .{ .end = .transport_closed },
        else => return err,
    }) {
        .blocked => return .blocked,
        .eof => return .{ .end = .transport_closed },
        .frame => |frame| frame,
    };
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse return error.UnexpectedFrame;
            switch (item_payload) {
                // The overlay sits on top of the last rendered screen. Applying
                // remote draws here would interleave two renderers;
                // repaint-after-dismiss is the boundary that gets us back to a
                // single source of screen truth.
                .draw, .repaint_response => return .handled,
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return .handled;
                },
                .input_ack => |ack| {
                    _ = handleInputAckMessage(ack, session);
                    return .handled;
                },
                .session_ended => |ended| {
                    session.recordSessionEnded(ended);
                    return .{ .end = .session_ended };
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(loop.blocking, frame.payload)) {
            .handled => return .handled,
            .transport_closed => return .{ .end = .remote_transport_closed },
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(loop.blocking, frame.payload);
            return .{ .end = .session_ended };
        },
        else => return error.UnexpectedFrame,
    }
}

fn drainVisibleClientTerminalWorkerFrames(loop: *VisibleTerminalLoop) !?VisibleClientEnd {
    while (true) {
        if (!loop.stdout_sink.belowWatermark()) return null;
        switch (try handleVisibleClientTerminalWorkerFrame(loop)) {
            .blocked => return null,
            .handled => continue,
            .end => |end| return end,
        }
    }
}

fn finishVisibleClientAfterTerminalWorkerWriteFailed(loop: *VisibleTerminalLoop) !VisibleClientEnd {
    if (try drainVisibleClientTerminalWorkerFrames(loop)) |end| return try loop.finishVisibleClient(end);
    return .transport_closed;
}

// Normal worker-frame drain for the visible client. Draws are applied unless a
// repaint is pending, repaint responses advance recovery, and input acks drive
// responsiveness monitoring.
fn handleVisibleClientTerminalWorkerFrame(loop: *VisibleTerminalLoop) !TerminalWorkerFrameAction {
    const session = loop.session;
    var frame = switch (loop.worker_source.readFrame() catch |err| switch (err) {
        error.TruncatedFrame => return .{ .end = .transport_closed },
        else => return err,
    }) {
        .blocked => return .blocked,
        .eof => return .{ .end = .transport_closed },
        .frame => |frame| frame,
    };
    defer frame.deinit(app_allocator.allocator());
    switch (frame.message_type) {
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
            defer item.deinit(app_allocator.allocator());
            const item_payload = item.payload orelse return error.UnexpectedFrame;
            switch (item_payload) {
                .draw => |draw| {
                    if (!session.pending_repaint.active()) {
                        try handleDrawMessage(draw, DrawApplyContext.forSessionSink(loop.blocking, session, loop.stdout_sink.byte(), .restore));
                    }
                    return .handled;
                },
                .repaint_response => |response| {
                    _ = try handleRepaintResponseMessage(response, DrawApplyContext.forSessionSink(loop.blocking, session, loop.stdout_sink.byte(), .restore));
                    return .handled;
                },
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return .handled;
                },
                .input_ack => |ack_message| {
                    const ack = handleInputAckMessage(ack_message, session);
                    if (ack.progressed) {
                        loop.connection_monitor.noteInputAckProgress(.{
                            .still_pending = ack.still_pending,
                        });
                    }
                    return .handled;
                },
                .session_ended => |ended| {
                    session.recordSessionEnded(ended);
                    return .{ .end = .session_ended };
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(loop.blocking, frame.payload)) {
            .handled => return .handled,
            .transport_closed => return .{ .end = .remote_transport_closed },
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(loop.blocking, frame.payload);
            return .{ .end = .session_ended };
        },
        else => return error.UnexpectedFrame,
    }
}

fn finishVisibleClientBlocking(blocking: core_blocking.Blocking, end: VisibleClientEnd, session: *VisibleClientSessionState) VisibleClientEnd {
    if (end == .client_hangup or end == .session_ended) {
        presentation_guard_mod.restoreVisibleClientEndBytes(blocking, &session.visible_client_end_restore);
    }
    return end;
}

fn clearVisibleAfterResizeTimeout(blocking: core_blocking.Blocking, session: *VisibleClientSessionState) void {
    session.viewport_offset = 0;
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    const renderer = client_renderer.Renderer.init(blocking, posix.STDOUT_FILENO);
    renderer.restorePresentation(terminal.queryInitialKittyKeyboardFlags(blocking, .{})) catch {};
    renderer.clearVisible() catch {};
}

fn checkResizeRepaintTimeout(blocking: core_blocking.Blocking, session: *VisibleClientSessionState) ?VisibleClientEnd {
    return checkResizeRepaintTimeoutAt(blocking, session, null);
}

fn checkResizeRepaintTimeoutAt(blocking: core_blocking.Blocking, session: *VisibleClientSessionState, now_ms: ?u64) ?VisibleClientEnd {
    const timed_out = if (now_ms) |ms|
        session.pending_repaint.resizeTimedOutAt(ms)
    else
        session.pending_repaint.resizeTimedOut();
    if (!timed_out) return null;
    clearVisibleAfterResizeTimeout(blocking, session);
    return .unresponsive;
}

fn clientHangup() VisibleClientEnd {
    return .client_hangup;
}

fn writeClientCloseBoundary(blocking: core_blocking.Blocking) void {
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    blocking.writeAll(posix.STDOUT_FILENO, "\r\n") catch {};
}

const InitialAlignmentMode = enum {
    ignore,
    restore,
};

const DrawApplyContext = struct {
    blocking: core_blocking.Blocking,
    session: *VisibleClientSessionState,
    initial_alignment: InitialAlignmentMode,
    stdout_sink: ?*dispatch_io.ByteSink = null,

    fn forSession(blocking: core_blocking.Blocking, session: *VisibleClientSessionState, initial_alignment: InitialAlignmentMode) DrawApplyContext {
        return .{
            .blocking = blocking,
            .session = session,
            .initial_alignment = initial_alignment,
        };
    }

    fn forSessionSink(
        blocking: core_blocking.Blocking,
        session: *VisibleClientSessionState,
        stdout_sink: *dispatch_io.ByteSink,
        initial_alignment: InitialAlignmentMode,
    ) DrawApplyContext {
        return .{
            .blocking = blocking,
            .session = session,
            .initial_alignment = initial_alignment,
            .stdout_sink = stdout_sink,
        };
    }

    fn initialDrawAlignment(self: DrawApplyContext) ?*InitialDrawAlignment {
        return if (self.initial_alignment == .restore) &self.session.initial_draw_alignment else null;
    }

    fn writeStdout(self: DrawApplyContext, bytes: []const u8) !void {
        if (self.stdout_sink) |sink| {
            try sink.writeBytes(bytes);
        } else {
            try self.blocking.writeAll(posix.STDOUT_FILENO, bytes);
        }
    }
};

fn handleRepaintResponseFrame(
    payload: []const u8,
    context: DrawApplyContext,
) !bool {
    var response = try protocol.decodePayload(pb.TerminalEmulatorItem.RepaintResponse, app_allocator.allocator(), payload);
    defer response.deinit(app_allocator.allocator());
    return handleRepaintResponseMessage(response, context);
}

fn handleRepaintResponseMessage(
    response: pb.TerminalEmulatorItem.RepaintResponse,
    context: DrawApplyContext,
) !bool {
    const pending_repaint = &context.session.pending_repaint;
    if (!pending_repaint.active() or !pending_repaint.matches(response.repaint_request_seq)) return false;
    const response_draw = response.draw orelse return error.MissingDraw;
    try handleDrawMessage(response_draw, context);
    pending_repaint.clear();
    return true;
}

fn handleTtyTranscriptChunkMessage(chunk: pb.TerminalEmulatorItem.TtyTranscriptChunk) void {
    switch (chunk.stream) {
        .STREAM_INNER_IN => tty_transcript.recordInnerIn(chunk.data),
        .STREAM_INNER_OUT => tty_transcript.recordInnerOut(chunk.data),
        .STREAM_UNSPECIFIED => {},
        _ => {},
    }
}

const ClientDaemonFrameAction = enum {
    handled,
    transport_closed,
    unexpected,
};

fn handleClientDaemonFrame(blocking: core_blocking.Blocking, payload: []const u8) !ClientDaemonFrameAction {
    return handleClientDaemonFrameWithUi(blocking, payload, null);
}

fn handleClientDaemonFrameWithUi(blocking: core_blocking.Blocking, payload: []const u8, reconnect_ui: ?*client_ui.ReconnectUi) !ClientDaemonFrameAction {
    var item = try protocol.decodePayload(pb.ClientDaemonItem, app_allocator.allocator(), payload);
    defer item.deinit(app_allocator.allocator());

    const item_payload = item.payload orelse return .unexpected;
    return switch (item_payload) {
        .connection_event => |event| handleConnectionEvent(blocking, event, reconnect_ui),
        else => .unexpected,
    };
}

fn handleConnectionEvent(blocking: core_blocking.Blocking, event: pb.ConnectionEvent, reconnect_ui: ?*client_ui.ReconnectUi) !ClientDaemonFrameAction {
    if (reconnect_ui) |ui| {
        try ui.handleConnectionEvent(event);
    } else switch (connection_event.classify(event)) {
        .ssh_stderr => |stderr| client_log.appendSshStderr(stderr.data),
        .binary_bootstrapping => try blocking.writeAll(posix.STDERR_FILENO, "\rsessh: bootstrapping..."),
        .daemon_connecting => try blocking.writeAll(posix.STDERR_FILENO, "\r\x1b[K"),
        .retry => |retry| if (retry.reason == .disconnected) return .transport_closed,
        .ssh_connecting,
        .ssh_connected,
        .daemon_connected,
        .none,
        => {},
    }
    return .handled;
}

fn handleInputAckMessage(ack: pb.TerminalEmulatorItem.InputAck, session: *VisibleClientSessionState) input_ack.AckResult {
    return input_ack.acknowledge(&session.input_ack_tracker, ack.input_seq);
}

fn handleDrawPayload(
    draw: DrawPayload,
    context: DrawApplyContext,
) !void {
    const session = context.session;
    try writeInitialCursorAndClearBelow(context);
    try context.writeStdout(draw.draw_bytes);
    if (draw.visible_client_end_restore_bytes) |restore| {
        session.visible_client_end_restore.clearRetainingCapacity();
        try session.visible_client_end_restore.appendSlice(app_allocator.allocator(), restore);
    }
    try session.scrollback_cursor.set(draw.scrollback_cursor);
    session.viewport_offset = draw.viewport_offset;
    if (draw.app_title_present) |present| session.app_title_present = present;
}

fn writeInitialCursorAndClearBelow(context: DrawApplyContext) !void {
    const alignment = context.initialDrawAlignment() orelse return;
    const position = alignment.takePendingCursor() orelse return;
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    if (context.stdout_sink) |_| {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(app_allocator.allocator());
        const renderer = client_renderer.Renderer.bufferedXtermCompatible(&buffer);
        renderer.moveCursor(position) catch return;
        renderer.clearBelowCursor() catch {};
        try context.writeStdout(buffer.items);
    } else {
        const renderer = client_renderer.Renderer.init(context.blocking, posix.STDOUT_FILENO);
        renderer.moveCursor(position) catch return;
        renderer.clearBelowCursor() catch {};
    }
}

fn handleDrawMessage(
    message: pb.TerminalEmulatorItem.Draw,
    context: DrawApplyContext,
) !void {
    const draw = try drawPayloadFromMessage(message);
    defer freeDrawPayload(draw);
    try handleDrawPayload(draw, context);
}

fn restoreInitialCursorAndClearBelow(blocking: core_blocking.Blocking, alignment: ?*InitialDrawAlignment) !void {
    try restoreInitialCursorAndClearBelowOnFd(
        blocking,
        posix.STDOUT_FILENO,
        alignment,
    );
}

fn restoreInitialCursorAndClearBelowOnFd(
    blocking: core_blocking.Blocking,
    fd: c.fd_t,
    alignment: ?*InitialDrawAlignment,
) !void {
    try restoreInitialCursorAndClearBelowWithRenderer(
        client_renderer.Renderer.init(blocking, fd),
        alignment,
    );
}

fn restoreInitialCursorAndClearBelowWithRenderer(
    renderer: client_renderer.Renderer,
    maybe_alignment: ?*InitialDrawAlignment,
) !void {
    const alignment = maybe_alignment orelse return;
    const position = alignment.takePendingCursor() orelse return;
    const fd = renderer.outputFd() orelse return;
    if (c.isatty(fd) == 0) return;
    renderer.moveCursor(position) catch return;
    renderer.clearBelowCursor() catch {};
}

test "initial draw alignment is consumed without writing to non-tty output" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try core_fds.setNonBlocking(pipe[0]);

    var alignment = InitialDrawAlignment{};
    alignment.setCursor(.{ .row = 2, .col = 5 });
    try restoreInitialCursorAndClearBelowWithRenderer(
        client_renderer.Renderer.withCapabilities(core_blocking.fromTest(), pipe[1], client_renderer.Capabilities.xterm_compatible),
        &alignment,
    );

    try std.testing.expect(!alignment.pending);
    try std.testing.expect(alignment.cursor_position == null);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try protocol_test_helpers.readAvailableForTest(std.testing.allocator, pipe[0], &output);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "initial draw alignment restores tty cursor and clears below" {
    var pty = try posix_pty.open();
    defer pty.close();
    try core_fds.setNonBlocking(pty.master_fd);

    var alignment = InitialDrawAlignment{};
    alignment.setCursor(.{ .row = 2, .col = 5 });
    try restoreInitialCursorAndClearBelowWithRenderer(
        client_renderer.Renderer.withCapabilities(core_blocking.fromTest(), pty.slave_fd, client_renderer.Capabilities.xterm_compatible),
        &alignment,
    );

    try std.testing.expect(!alignment.pending);
    try std.testing.expect(alignment.cursor_position == null);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try protocol_test_helpers.readAvailableForTest(std.testing.allocator, pty.master_fd, &output);
    try std.testing.expectEqualStrings("\x1b[3;6H\x1b[J", output.items);
}

fn drawPayloadFromMessage(message: pb.TerminalEmulatorItem.Draw) !DrawPayload {
    if (message.viewport_offset) |offset| {
        if (offset < -1) return error.InvalidViewportOffset;
        if (offset > std.math.maxInt(u16)) return error.IntOutOfRange;
    }
    if (message.scrollback_cursor.len == 0) return error.MissingScrollbackCursor;
    return .{
        .scrollback_cursor = try app_allocator.allocator().dupe(u8, message.scrollback_cursor),
        .viewport_offset = message.viewport_offset orelse 0,
        .draw_bytes = try app_allocator.allocator().dupe(u8, message.draw_bytes),
        .app_title_present = message.app_title_present,
        .visible_client_end_restore_bytes = if (message.visible_client_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.scrollback_cursor);
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.visible_client_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
}
