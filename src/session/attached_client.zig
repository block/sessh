const std = @import("std");
const app_allocator = @import("../core/app_allocator.zig");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const attached_client_messages = @import("attached_client_messages.zig");
const attached_client_state = @import("attached_client_state.zig");
const client_config = @import("client_config.zig");
const client_loop = @import("client_loop.zig");
const client_log = @import("../core/client_log.zig");
const client_renderer = @import("renderer.zig");
const client_ui = @import("client_ui.zig");
const connection_event = @import("../diagnostics/connection_event.zig");
const connection_monitor_mod = @import("connection_monitor.zig");
const core_fds = @import("../core/fds.zig");
const error_payload = @import("error_payload.zig");
const input_ack = @import("input_ack.zig");
const io_helpers = @import("../core/io.zig");
const local_terminal_mod = @import("local_terminal.zig");
const NonSuspendingTimer = @import("../core/non_suspending_timer.zig").NonSuspendingTimer;
const presentation_guard_mod = @import("presentation_guard.zig");
const protocol = @import("../protocol/mod.zig");
const protocol_test_helpers = @import("../protocol/test_helpers.zig");
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const repaint_mod = @import("repaint.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal = @import("../tty/terminal.zig");
const tty_transcript = @import("../tty/transcript.zig");

const pb = protocol.pb;
const WindowSize = terminal.WindowSize;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
const ErrorPayload = error_payload.Payload;
const freeErrorPayload = error_payload.free;
const parseErrorPayload = error_payload.parse;
const printErrorPayload = error_payload.printPayload;
const printParsedError = error_payload.printParsed;
const transportExitCode = error_payload.transportExitCode;

pub const AttachedClientEnd = enum {
    unresponsive,
    transport_closed,
    remote_transport_closed,
    session_ended,
    client_hangup,
};

pub const ReconnectInputPumpResult = enum {
    wait_elapsed,
    reconnect_now,
    client_hangup,
    transport_closed,
    remote_transport_closed,
};

pub const RuntimeRecovery = enum {
    recovered,
    transport_closed,
    remote_transport_closed,
    session_ended,
};

pub const AttachedClientOptions = struct {
    monitor_connection: bool = false,
    responsiveness_timeout_floor_ms: i64 = default_responsiveness_timeout_ms,
};

const ConnectionMonitor = connection_monitor_mod.ConnectionMonitor;
const InputAckTracker = input_ack.Tracker;
const PasteLikeInputClassifier = client_loop.PasteLikeInputClassifier;
const PendingRepaint = repaint_mod.Pending;
const PresentationGuard = presentation_guard_mod.Guard;
pub const RuntimeSession = attached_client_state.RuntimeSession;
pub const ScrollbackCursor = attached_client_state.ScrollbackCursor;
const default_responsiveness_timeout_ms = connection_monitor_mod.default_responsiveness_timeout_ms;

pub const LocalTerminalState = local_terminal_mod.State;
pub const LocalTerminalProbe = local_terminal_mod.Probe;

pub fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

const DrawPayload = struct {
    scrollback_cursor: []const u8,
    viewport_offset: i32,
    draw_bytes: []const u8,
    app_title_present: ?bool,
    attached_client_end_restore_bytes: ?[]const u8,
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

test "resize repaint timeout clears stale attached client display and enters unresponsive state" {
    var pending = PendingRepaint{};
    _ = pending.startResizeAt(1_000);
    var viewport_offset: i32 = 7;

    try std.testing.expectEqual(
        @as(?AttachedClientEnd, null),
        checkResizeRepaintTimeout(&pending, &viewport_offset, 1_999),
    );
    try std.testing.expectEqual(@as(i32, 7), viewport_offset);

    try std.testing.expectEqual(
        AttachedClientEnd.unresponsive,
        checkResizeRepaintTimeout(&pending, &viewport_offset, 2_000).?,
    );
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);
    try std.testing.expect(pending.requiresRepaintForRecovery());
}

test "attached client drains pending session end before monitor timeout" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), remote_to_client[1], .{ .draw = .{
        .scrollback_cursor = "cursor-v1",
    } });

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), remote_to_client[1], .{ .session_ended = .{
        .reason = .REASON_PROCESS_EXITED,
    } });

    var presentation_guard = PresentationGuard.init(1);
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var app_title_present: ?bool = null;
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};
    var initial_cursor_position: ?terminal.CursorPosition = null;
    var initial_draw_alignment_pending = false;

    try std.testing.expectEqual(
        AttachedClientEnd.session_ended,
        try runAttachedTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &attached_client_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            null,
            &app_title_present,
            &initial_cursor_position,
            &initial_draw_alignment_pending,
            .{ .monitor_connection = true },
        ),
    );
}

test "attached client treats input write failure as transport closed" {
    const input = try posix.pipe();
    defer posix.close(input[0]);
    defer posix.close(input[1]);
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);

    var presentation_guard = PresentationGuard.init(1);
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var pending_repaint = PendingRepaint{};
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    var input_ack_tracker = InputAckTracker{};
    var input_escape_filter = terminal.EscapeFilter{};
    var paste_like_input_classifier = PasteLikeInputClassifier{};
    var app_title_present: ?bool = null;
    var initial_cursor_position: ?terminal.CursorPosition = null;
    var initial_draw_alignment_pending = false;

    try io_helpers.writeAll(input[1], "typed");

    try std.testing.expectEqual(
        AttachedClientEnd.transport_closed,
        try runAttachedTerminal(
            input[0],
            remote_to_client[0],
            @as(c.fd_t, -1),
            &input_escape_filter,
            &presentation_guard,
            &scrollback_cursor,
            &viewport_offset,
            &pending_repaint,
            &attached_client_end_restore,
            &input_ack_tracker,
            &paste_like_input_classifier,
            null,
            &app_title_present,
            &initial_cursor_position,
            &initial_draw_alignment_pending,
            .{ .monitor_connection = true },
        ),
    );
}

test "attached client keeps attached-client-end restore bytes while reconnecting" {
    var attached_client_end_restore = std.ArrayList(u8).empty;
    defer attached_client_end_restore.deinit(app_allocator.allocator());
    try attached_client_end_restore.appendSlice(app_allocator.allocator(), "restore-primary");

    try std.testing.expectEqual(AttachedClientEnd.transport_closed, finishAttachedClient(.transport_closed, &attached_client_end_restore));
    try std.testing.expectEqualStrings("restore-primary", attached_client_end_restore.items);

    try std.testing.expectEqual(AttachedClientEnd.unresponsive, finishAttachedClient(.unresponsive, &attached_client_end_restore));
    try std.testing.expectEqualStrings("restore-primary", attached_client_end_restore.items);
}

test "cancelled reconnect frame read returns without input" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var cancelled = true;
    try std.testing.expectError(error.ReconnectCancelled, readFrameMaybeCancelled(fds[0], &cancelled));
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

test "draw payload updates runtime app title presence state" {
    var scrollback_cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var app_title_present: ?bool = null;

    try handleDrawPayload(.{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .app_title_present = false,
        .attached_client_end_restore_bytes = null,
    }, null, &scrollback_cursor, &viewport_offset, &app_title_present);

    try std.testing.expect(app_title_present != null);
    try std.testing.expect(!app_title_present.?);
}

test "recovery polling stores attached-client-end restore bytes from draw" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.deinit();

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), fds[1], .{ .draw = .{
        .scrollback_cursor = "opaque-cursor",
        .viewport_offset = 0,
        .draw_bytes = "",
        .attached_client_end_restore_bytes = "restore-primary",
    } });

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
    try std.testing.expectEqualStrings("restore-primary", session.attached_client_end_restore.items);
}

test "recovery polling ignores draw while repaint is outstanding" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{ .pending_repaint = .{ .repaint_request_seq = 7 } };
    defer session.deinit();

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), fds[1], .{ .draw = .{
        .scrollback_cursor = "stale-cursor",
        .viewport_offset = 3,
        .draw_bytes = "",
    } });

    try std.testing.expectEqual(@as(?RuntimeRecovery, null), try pollRuntimeRecovery(fds[0], &session, 0));
    try std.testing.expectEqual(@as(usize, 0), session.scrollback_cursor.len);
    try std.testing.expectEqual(@as(i32, 0), session.viewport_offset);
    try std.testing.expect(session.pending_repaint.active());
}

test "recovery polling waits for resize repaint after input ack" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var session = RuntimeSession{};
    defer session.deinit();
    const repaint_seq = session.pending_repaint.startResizeAt(1_000);

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), fds[1], .{ .input_ack = .{
        .input_seq = 1,
    } });

    try std.testing.expectEqual(@as(?RuntimeRecovery, null), try pollRuntimeRecovery(fds[0], &session, 0));
    try std.testing.expect(session.pending_repaint.requiresRepaintForRecovery());

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), fds[1], .{ .repaint_response = .{
        .repaint_request_seq = repaint_seq,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 0,
            .draw_bytes = "",
        },
    } });

    try std.testing.expectEqual(RuntimeRecovery.recovered, (try pollRuntimeRecovery(fds[0], &session, 0)).?);
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
            .attached_client_end_restore_bytes = "restore-v7",
        },
    });
    defer app_allocator.allocator().free(payload);

    var restore = std.ArrayList(u8).empty;
    defer restore.deinit(app_allocator.allocator());
    var cursor = ScrollbackCursor{};
    var viewport_offset: i32 = 0;
    var no_pending = PendingRepaint{};
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &no_pending, null));
    try std.testing.expectEqual(@as(usize, 0), cursor.len);
    try std.testing.expectEqual(@as(i32, 0), viewport_offset);

    var older_pending = PendingRepaint{ .repaint_request_seq = 8 };
    try std.testing.expect(!try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &older_pending, null));
    try std.testing.expectEqual(@as(u64, 8), older_pending.repaint_request_seq);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    var matching_pending = PendingRepaint{ .repaint_request_seq = 7 };
    try std.testing.expect(try handleRepaintResponseFrame(payload, &restore, &cursor, &viewport_offset, &matching_pending, null));
    try std.testing.expect(!matching_pending.active());
    try std.testing.expectEqualStrings("cursor-v7", cursor.slice());
    try std.testing.expectEqual(@as(i32, 4), viewport_offset);
    try std.testing.expectEqualStrings("restore-v7", restore.items);
}

test "reconnect waits for repaint response before returning" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    repaint_mod.setNextRequestSeqForTest(77);

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), remote_to_client[1], .{ .session_attached = .{} });

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), remote_to_client[1], .{ .repaint_response = .{
        .repaint_request_seq = 77,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 5,
            .draw_bytes = "",
        },
    } });

    var session = RuntimeSession{};
    defer session.deinit();
    try session.scrollback_cursor.set("old-cursor");

    try reconnectSessionOnRuntime(remote_to_client[0], client_to_remote[1], &session);

    try std.testing.expect(!session.pending_repaint.active());
    try std.testing.expectEqualStrings("fresh-cursor", session.scrollback_cursor.slice());
    try std.testing.expectEqual(@as(i32, 5), session.viewport_offset);
}

test "runtime repaint after local ui requests screen-only repaint" {
    const remote_to_client = try posix.pipe();
    defer posix.close(remote_to_client[0]);
    defer posix.close(remote_to_client[1]);
    const client_to_remote = try posix.pipe();
    defer posix.close(client_to_remote[0]);
    defer posix.close(client_to_remote[1]);

    repaint_mod.setNextRequestSeqForTest(91);

    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), remote_to_client[1], .{ .repaint_response = .{
        .repaint_request_seq = 91,
        .draw = .{
            .scrollback_cursor = "fresh-cursor",
            .viewport_offset = 6,
            .draw_bytes = "",
        },
    } });

    var session = RuntimeSession{};
    defer session.deinit();
    try session.scrollback_cursor.set("old-cursor");
    session.viewport_offset = 5;

    try repaintRuntimeSession(remote_to_client[0], client_to_remote[1], &session);

    var frame = try readVisibleClientFrameBlocking(client_to_remote[0]);
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

pub fn startNewSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    reap_ms: u64,
    local_terminal: *LocalTerminalState,
) !RuntimeSession {
    const repaint_request_seq = try sendSessionCreate(
        write_fd,
        local_terminal,
        scrollback_row_count,
        session_guid,
        command_argv,
        shell_command,
        reap_ms,
    );
    var session = try readRuntimeSession(read_fd);
    session.viewport_offset = local_terminal.viewport_offset orelse 0;
    session.pending_repaint.repaint_request_seq = repaint_request_seq;
    session.initial_cursor_position = local_terminal.cursor_position;
    session.initial_draw_alignment_pending = local_terminal.cursor_position != null;
    session.initial_kitty_keyboard_flags = local_terminal.initial_kitty_keyboard_flags;
    return session;
}

pub fn reconnectSessionOnRuntime(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, null, true);
}

pub fn reconnectSessionOnRuntimeCancellable(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: *const bool,
) !void {
    try reconnectSessionOnRuntimeInner(read_fd, write_fd, session, cancelled, false);
}

fn reconnectSessionOnRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const bool,
    wait_for_repaint: bool,
) !void {
    try attachReconnectRuntimeInner(read_fd, write_fd, session, cancelled, wait_for_repaint);
}

fn attachReconnectRuntimeInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const bool,
    wait_for_repaint: bool,
) !void {
    session.pending_repaint.repaint_request_seq = try sendSessionAttach(write_fd, terminal.currentWindowSize(), attached_client_messages.nonZeroViewportOffset(session.viewport_offset), &session.scrollback_cursor, session.guidSlice());
    try readSessionAttachedInner(read_fd, write_fd, cancelled);
    if (wait_for_repaint) try finishReconnectRepaintInner(read_fd, write_fd, session, cancelled);
}

pub fn finishReconnectRepaint(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try finishReconnectRepaintInner(read_fd, write_fd, session, null);
}

pub fn repaintRuntimeSession(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
) !void {
    try attached_client_messages.sendResizeScreenRepaint(write_fd, terminal.currentWindowSize(), session.viewport_offset, &session.pending_repaint);
    try finishReconnectRepaint(read_fd, write_fd, session);
}

fn finishReconnectRepaintInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    cancelled: ?*const bool,
) !void {
    _ = write_fd;
    while (session.pending_repaint.active()) {
        var frame = try readFrameMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                switch (item_payload) {
                    .draw => {},
                    .repaint_response => |response| {
                        _ = try handleRepaintResponseMessageWithInitialAlignment(
                            response,
                            &session.attached_client_end_restore,
                            &session.scrollback_cursor,
                            &session.viewport_offset,
                            &session.pending_repaint,
                            &session.app_title_present,
                            null,
                            null,
                        );
                    },
                    .input_ack => |ack| {
                        _ = handleInputAckMessage(ack, &session.input_ack_tracker);
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
                switch (try handleClientDaemonFrame(frame.payload)) {
                    .handled => {},
                    .transport_closed => return error.RemoteTransportClosed,
                    .unexpected => return error.UnexpectedFrame,
                }
            },
            .error_message => {
                try printErrorPayload(frame.payload);
                return error.RemoteError;
            },
            else => return error.UnexpectedFrame,
        }
    }
}

pub fn runAttachedClient(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    return runAttachedClientLoop(
        read_fd,
        write_fd,
        &session.input_escape_filter,
        &session.scrollback_cursor,
        &session.viewport_offset,
        &session.pending_repaint,
        &session.attached_client_end_restore,
        &session.input_ack_tracker,
        &session.paste_like_input_classifier,
        &session.ended_process_exit_code,
        &session.app_title_present,
        &session.initial_cursor_position,
        &session.initial_draw_alignment_pending,
        session.initial_kitty_keyboard_flags,
        .{
            .monitor_connection = options.monitor_connection,
            .responsiveness_timeout_floor_ms = @max(options.responsiveness_timeout_floor_ms, session.unresponsive_timeout_floor_ms),
        },
    );
}

pub fn drainLocalTransportDiagnostics(read_fd: c.fd_t, timeout_ms: u64) void {
    var timer = NonSuspendingTimer.start() catch return;
    var reader = protocol.FrameReader.init(app_allocator.allocator());
    defer reader.deinit();
    // BLOCKING_POLL: foreground visible-client diagnostic drain. It runs while
    // the client is already handling a local transport close and has no daemon
    // dispatcher work to make progress on.
    while (true) {
        const elapsed_ms = @divTrunc(timer.read(), std.time.ns_per_ms);
        if (elapsed_ms >= timeout_ms) return;
        const remaining_ms: i32 = @intCast(@min(timeout_ms - elapsed_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
        var pollfds = [_]posix.pollfd{.{
            .fd = read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&pollfds, remaining_ms) catch return;
        if (ready == 0) return;
        if ((pollfds[0].revents & posix.POLL.IN) == 0) return;

        var frame = switch (reader.readReady(read_fd) catch return) {
            .blocked, .progress => continue,
            .frame => |frame| frame,
            .eof, .truncated_frame => return,
        };
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .client_daemon => switch (handleClientDaemonFrame(frame.payload) catch return) {
                .handled => {},
                .transport_closed, .unexpected => return,
            },
            else => return,
        }
    }
}

pub fn pollRuntimeRecovery(
    read_fd: c.fd_t,
    session: *RuntimeSession,
    timeout_ms: i32,
) !?RuntimeRecovery {
    // BLOCKING_POLL: foreground reconnect UI waits for one runtime frame or a
    // short timeout so it can keep refreshing diagnostics between attempts.
    var pollfds = [_]posix.pollfd{.{
        .fd = read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return null;
    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
        (pollfds[0].revents & posix.POLL.IN) == 0)
    {
        return .transport_closed;
    }
    if ((pollfds[0].revents & posix.POLL.IN) == 0) return null;

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
                    try handleDrawMessageWithInitialAlignment(draw, &session.attached_client_end_restore, &session.scrollback_cursor, &session.viewport_offset, &session.app_title_present, null, null);
                    return .recovered;
                },
                .repaint_response => |response| {
                    const applied = try handleRepaintResponseMessageWithInitialAlignment(
                        response,
                        &session.attached_client_end_restore,
                        &session.scrollback_cursor,
                        &session.viewport_offset,
                        &session.pending_repaint,
                        &session.app_title_present,
                        null,
                        null,
                    );
                    return if (applied) .recovered else null;
                },
                .input_ack => |ack| {
                    _ = handleInputAckMessage(ack, &session.input_ack_tracker);
                    if (session.pending_repaint.requiresRepaintForRecovery()) return null;
                    return .recovered;
                },
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return .recovered;
                },
                .session_ended => |ended| {
                    session.recordSessionEnded(ended);
                    _ = finishAttachedClient(.session_ended, &session.attached_client_end_restore);
                    return .session_ended;
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
            .handled => return null,
            .transport_closed => return .remote_transport_closed,
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            _ = finishAttachedClient(.session_ended, &session.attached_client_end_restore);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

pub fn pollAndForwardReconnectInput(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    session: *RuntimeSession,
    reconnect_ui: *client_ui.ReconnectUi,
    timeout_ms: i32,
) !ReconnectInputPumpResult {
    _ = read_fd;
    try reconnect_ui.refreshForResize();
    if (reconnect_ui.consumeResizeForRuntime()) {
        session.viewport_offset = reconnect_ui.currentViewportOffset();
        attached_client_messages.sendResizeWithRepaint(
            write_fd,
            terminal.currentWindowSize(),
            &session.scrollback_cursor,
            session.viewport_offset,
            &session.pending_repaint,
        ) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        };
    }
    try reconnect_ui.refreshOverlayIfDiagnosticsChanged();

    // BLOCKING_POLL: foreground reconnect UI input pump. It waits only for the
    // caller-provided timeout so the surrounding reconnect loop can redraw and
    // retry on schedule.
    var pollfds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return .wait_elapsed;
    if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .client_hangup;
    if ((pollfds[0].revents & posix.POLL.IN) == 0) return .wait_elapsed;

    var input: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    const n = c.read(posix.STDIN_FILENO, &input, input.len);
    if (n <= 0) return .client_hangup;
    const bytes = input[0..@intCast(n)];
    io_helpers.noteRead(posix.STDIN_FILENO, bytes);

    for (bytes) |byte| {
        if (byte == 0x12) {
            reconnect_ui.reconnect_acknowledged = true;
            return .reconnect_now;
        }
    }

    const result = session.input_escape_filter.filter(bytes, &filtered);
    if (result.bytes.len > 0) {
        const paste_like = session.paste_like_input_classifier.classify(result.bytes.len);
        attached_client_messages.sendInputChunks(write_fd, result.bytes, &session.input_ack_tracker, paste_like) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        };
    }

    if (result.end) |end| switch (end) {
        .disconnect => return .client_hangup,
        .help => {},
        .repaint => attached_client_messages.sendRepaint(write_fd, "", &session.pending_repaint) catch |err| switch (err) {
            error.WriteFailed => return .transport_closed,
            else => return err,
        },
    };

    try reconnect_ui.refreshOverlayIfDiagnosticsChanged();
    return .wait_elapsed;
}

fn readRuntimeSession(read_fd: c.fd_t) !RuntimeSession {
    while (true) {
        var frame = try readVisibleClientFrameBlocking(read_fd);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
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
                    try printParsedError(parsed);
                    return process_exit.request(exit_code);
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                const attached = switch (item_payload) {
                    .session_attached => |message| message,
                    else => return error.UnexpectedFrame,
                };
                var session = RuntimeSession{};
                try session.setIdentity(attached.session_guid);
                return session;
            },
            .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readSessionAttached(conn: c.fd_t) !void {
    return readSessionAttachedInner(conn, conn, null);
}

fn readSessionAttachedInner(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    cancelled: ?*const bool,
) !void {
    _ = write_fd;
    while (true) {
        var frame = try readFrameMaybeCancelled(read_fd, cancelled);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                const parsed = try parseErrorPayload(frame.payload);
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
                    try printParsedError(parsed);
                    return process_exit.request(exit_code);
                }
                try printParsedError(parsed);
                return process_exit.request(1);
            },
            .client_remote => {
                var item = try protocol.decodeClientRemoteTerminalEmulatorItem(app_allocator.allocator(), frame.payload);
                defer item.deinit(app_allocator.allocator());
                const item_payload = item.payload orelse return error.UnexpectedFrame;
                switch (item_payload) {
                    .session_attached => return,
                    else => return error.UnexpectedFrame,
                }
            },
            .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn readFrameMaybeCancelled(
    fd: c.fd_t,
    cancelled: ?*const bool,
) !protocol.OwnedFrame {
    const flag = cancelled orelse return readVisibleClientFrameBlocking(fd);
    var reader = protocol.FrameReader.init(app_allocator.allocator());
    defer reader.deinit();
    // BLOCKING_POLL: foreground reconnect setup wait. The short timeout lets a
    // racing reconnect attempt notice cancellation while waiting for the remote
    // runtime's next frame.
    while (true) {
        if (flag.*) return error.ReconnectCancelled;
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 50);
        if (flag.*) return error.ReconnectCancelled;
        if (ready == 0) continue;
        if ((pollfds[0].revents & posix.POLL.IN) != 0) {
            switch (try reader.readReady(fd)) {
                .blocked, .progress => continue,
                .frame => |frame| return frame,
                .eof => return error.EndOfStream,
                .truncated_frame => return error.TruncatedFrame,
            }
        }
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            return error.EndOfStream;
        }
    }
}

// BLOCKING_FRAME_READ: visible-client startup/reconnect/exit-status waits.
// This code is outside sesshd and outside pooled transports; poll-driven
// runtime paths keep a persistent FrameReader and call readReady.
fn readVisibleClientFrameBlocking(fd: c.fd_t) !protocol.OwnedFrame {
    var reader = protocol.FrameReader.init(app_allocator.allocator());
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

fn sendSessionCreate(
    conn: c.fd_t,
    local_terminal: *const LocalTerminalState,
    scrollback_row_count: u32,
    session_guid: []const u8,
    command_argv: []const []const u8,
    shell_command: ?[]const u8,
    reap_ms: u64,
) !u64 {
    if (command_argv.len > 0 and shell_command != null) return error.InvalidSessionCommand;
    const repaint_request_seq = repaint_mod.allocateRequestSeq();
    var create = pb.TerminalEmulatorItem.SessionCreate{
        .scrollback_row_limit = scrollback_row_count,
        .reap_ms = reap_ms,
    };
    var protocol_tty_settings = pb.TerminalEmulatorItem.SessionCreate.TtySettings{};
    defer protocol_tty_settings.tty_mode.deinit(app_allocator.allocator());
    if (local_terminal.tty_settings) |settings| {
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
    if (shell_command) |command| {
        create.command = .{ .shell_command = .{ .command = command } };
    } else if (command_argv.len > 0) {
        try exec_command.argv.appendSlice(app_allocator.allocator(), command_argv);
        create.command = .{ .exec_command = exec_command };
    }
    create.query_default_colors = .{
        .foreground_color = local_terminal.default_colors.foreground_color,
        .background_color = local_terminal.default_colors.background_color,
    };
    const message = pb.TerminalEmulatorItem.Open{
        .session_guid = session_guid,
        .resize = .{
            .terminal_rows = local_terminal.size.rows,
            .terminal_cols = local_terminal.size.cols,
            .viewport_offset = local_terminal.viewport_offset,
            .repaint_request = .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = "",
            },
        },
        .capture_tty_transcript = tty_transcript.enabled(),
        .create = create,
    };
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), conn, .{ .open = message });
    return repaint_request_seq;
}

fn sendSessionAttach(
    conn: c.fd_t,
    size: WindowSize,
    viewport_offset: ?i32,
    reconnect_cursor: ?*const ScrollbackCursor,
    session_guid: []const u8,
) !u64 {
    const repaint_request_seq = repaint_mod.allocateRequestSeq();
    const message = pb.TerminalEmulatorItem.Open{
        .session_guid = session_guid,
        .resize = .{
            .terminal_rows = size.rows,
            .terminal_cols = size.cols,
            .viewport_offset = viewport_offset,
            .repaint_request = if (reconnect_cursor) |cursor| .{
                .repaint_request_seq = repaint_request_seq,
                .scrollback_cursor = cursor.slice(),
            } else .{
                .repaint_request_seq = repaint_request_seq,
            },
        },
        .capture_tty_transcript = tty_transcript.enabled(),
    };
    try protocol.sendTerminalEmulatorPayloadFrame(app_allocator.allocator(), conn, .{ .open = message });
    return repaint_request_seq;
}

fn readSessionEndedOrError(conn: c.fd_t) !bool {
    while (true) {
        var frame = try readVisibleClientFrameBlocking(conn);
        defer frame.deinit(app_allocator.allocator());
        switch (frame.message_type) {
            .error_message => {
                try printErrorPayload(frame.payload);
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
            .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
                .handled => {},
                .transport_closed => return error.RemoteTransportClosed,
                .unexpected => return error.UnexpectedFrame,
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn runAttachedClientLoop(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    initial_cursor_position: *?terminal.CursorPosition,
    initial_draw_alignment_pending: *bool,
    initial_kitty_keyboard_flags: u5,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    const output_is_tty = c.isatty(posix.STDOUT_FILENO) != 0;
    var mode_guard = try terminal.TerminalModeGuard.enable(posix.STDIN_FILENO);
    defer mode_guard.restore();
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    defer if (cleanup_title) |title| app_allocator.allocator().free(title);
    var presentation_guard = if (output_is_tty) guard: {
        break :guard if (cleanup_title) |title|
            PresentationGuard.initWithCleanupTitleAndInitialKittyKeyboardFlags(
                posix.STDOUT_FILENO,
                title,
                initial_kitty_keyboard_flags,
            )
        else
            PresentationGuard.initWithInitialKittyKeyboardFlags(posix.STDOUT_FILENO, initial_kitty_keyboard_flags);
    } else guard: {
        var inactive = PresentationGuard.initWithInitialKittyKeyboardFlags(posix.STDOUT_FILENO, initial_kitty_keyboard_flags);
        inactive.active = false;
        break :guard inactive;
    };
    defer presentation_guard.restore();

    const end = try runAttachedTerminal(
        posix.STDIN_FILENO,
        read_fd,
        write_fd,
        input_escape_filter,
        &presentation_guard,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        attached_client_end_restore,
        input_ack_tracker,
        paste_like_input_classifier,
        ended_process_exit_code,
        app_title_present,
        initial_cursor_position,
        initial_draw_alignment_pending,
        options,
    );
    if (end == .client_hangup) writeClientCloseBoundary();
    return end;
}

fn runAttachedTerminal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    input_escape_filter: *terminal.EscapeFilter,
    presentation_guard: *PresentationGuard,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    paste_like_input_classifier: *PasteLikeInputClassifier,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    initial_cursor_position: *?terminal.CursorPosition,
    initial_draw_alignment_pending: *bool,
    options: AttachedClientOptions,
) !AttachedClientEnd {
    var pollfds = [_]posix.pollfd{
        .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    var buf: [4096]u8 = undefined;
    var filtered: [8192]u8 = undefined;
    var last_size = terminal.currentWindowSize();
    var connection_monitor = ConnectionMonitor{
        .enabled = options.monitor_connection,
        .responsiveness_timeout_floor_ms = options.responsiveness_timeout_floor_ms,
    };
    var runtime_reader = protocol.FrameReader.init(app_allocator.allocator());
    defer runtime_reader.deinit();
    _ = presentation_guard;

    // PROCESS_EVENT_LOOP: the visible terminal client owns this foreground poll
    // loop. Dispatcher ownership is a sesshd rule; this process directly
    // arbitrates stdin, terminal runtime frames, and local responsiveness state.
    while (true) {
        _ = try posix.poll(&pollfds, connection_monitor.pollTimeoutMs());

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (try drainAttachedClientRuntimeFrames(
                read_fd,
                write_fd,
                &runtime_reader,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                attached_client_end_restore,
                input_ack_tracker,
                ended_process_exit_code,
                app_title_present,
                initial_cursor_position,
                initial_draw_alignment_pending,
            )) |end| return finishAttachedClient(end, attached_client_end_restore);
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = c.read(input_fd, &buf, buf.len);
            if (n <= 0) return finishAttachedClient(clientHangup(), attached_client_end_restore);
            io_helpers.noteRead(input_fd, buf[0..@intCast(n)]);
            const result = input_escape_filter.filter(buf[0..@intCast(n)], &filtered);
            if (result.bytes.len > 0) {
                const paste_like = paste_like_input_classifier.classify(result.bytes.len);
                attached_client_messages.sendInputChunks(write_fd, result.bytes, input_ack_tracker, paste_like) catch |err| switch (err) {
                    error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                        read_fd,
                        &runtime_reader,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        attached_client_end_restore,
                        input_ack_tracker,
                        ended_process_exit_code,
                        app_title_present,
                        initial_cursor_position,
                        initial_draw_alignment_pending,
                    ),
                    else => return err,
                };
                connection_monitor.afterInput();
            }
            if (result.end) |end| switch (end) {
                .disconnect => return finishAttachedClient(clientHangup(), attached_client_end_restore),
                .help => {
                    if (try showEscapeHelpModal(
                        input_fd,
                        read_fd,
                        write_fd,
                        &runtime_reader,
                        viewport_offset,
                        pending_repaint,
                        input_ack_tracker,
                        ended_process_exit_code,
                    )) |modal_end| return finishAttachedClient(modal_end, attached_client_end_restore);
                },
                .repaint => attached_client_messages.sendRepaint(write_fd, "", pending_repaint) catch |err| switch (err) {
                    error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                        read_fd,
                        &runtime_reader,
                        &connection_monitor,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        attached_client_end_restore,
                        input_ack_tracker,
                        ended_process_exit_code,
                        app_title_present,
                        initial_cursor_position,
                        initial_draw_alignment_pending,
                    ),
                    else => return err,
                },
            };
        }

        attached_client_messages.maybeSendResize(write_fd, &last_size, scrollback_cursor, viewport_offset, pending_repaint) catch |err| switch (err) {
            error.WriteFailed => return try finishAttachedClientAfterRuntimeWriteFailed(
                read_fd,
                &runtime_reader,
                &connection_monitor,
                scrollback_cursor,
                viewport_offset,
                pending_repaint,
                attached_client_end_restore,
                input_ack_tracker,
                ended_process_exit_code,
                app_title_present,
                initial_cursor_position,
                initial_draw_alignment_pending,
            ),
            else => return err,
        };

        if (checkResizeRepaintTimeout(pending_repaint, viewport_offset, std.time.milliTimestamp())) |end| return end;

        if (connection_monitor.isUnresponsive()) {
            return .unresponsive;
        }
    }
}

fn showEscapeHelpModal(
    input_fd: c.fd_t,
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    // The help overlay is local UI, not part of the remote terminal model. While
    // it is visible, remote draw frames are discarded and a repaint is requested
    // after dismissal so the client resumes from the remote terminal process's latest
    // screen state.
    const renderer = client_renderer.Renderer.init(posix.STDOUT_FILENO);
    var overlay_state: ?client_ui.OverlayDrawState = null;
    var last_size = terminal.currentWindowSize();
    try drawEscapeHelpOverlay(renderer, last_size, viewport_offset, &overlay_state);

    // PROCESS_EVENT_LOOP: modal foreground terminal UI. While the local help
    // overlay is visible, this loop owns stdin and runtime-drain decisions until
    // it requests a repaint and returns to the main attached-client loop.
    while (true) {
        var pollfds = [_]posix.pollfd{
            .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&pollfds, 250);

        if ((pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            if (try drainEscapeHelpRuntimeFrames(
                read_fd,
                write_fd,
                runtime_reader,
                input_ack_tracker,
                ended_process_exit_code,
            )) |end| {
                try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
                return end;
            }
        }

        if ((pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            var input: [256]u8 = undefined;
            const n = c.read(input_fd, &input, input.len);
            if (n <= 0) {
                try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
                return clientHangup();
            }
            const bytes = input[0..@intCast(n)];
            io_helpers.noteRead(input_fd, bytes);
            // The key that dismisses the help screen is local UI input. Do not
            // forward it to the remote session after the repaint.
            break;
        }

        const size = terminal.currentWindowSize();
        if (size.rows != last_size.rows or size.cols != last_size.cols) {
            last_size = size;
            try drawEscapeHelpOverlay(renderer, size, viewport_offset, &overlay_state);
        }
    }

    try clearEscapeHelpOverlay(renderer, viewport_offset, &overlay_state);
    attached_client_messages.sendScreenRepaint(write_fd, pending_repaint) catch |err| switch (err) {
        error.WriteFailed => return .transport_closed,
        else => return err,
    };
    return null;
}

fn drawEscapeHelpOverlay(
    renderer: client_renderer.Renderer,
    size: WindowSize,
    viewport_offset: *i32,
    overlay_state: *?client_ui.OverlayDrawState,
) !void {
    var lines: [terminal.escape_help_overlay_lines.len]client_ui.OverlayLine = undefined;
    inline for (terminal.escape_help_overlay_lines, 0..) |line, index| {
        lines[index] = .{
            .text = line,
            .alignment = if (index == 0) .center else .left,
        };
    }
    const top: u16 = if (viewport_offset.* > 0)
        @intCast(@min(@as(usize, @intCast(viewport_offset.*)), @as(usize, std.math.maxInt(u16))))
    else
        0;
    const next = try client_ui.drawOverlayLines(renderer, size, top, overlay_state.*, &lines);
    viewport_offset.* = @intCast(next.viewport_offset);
    overlay_state.* = next;
}

fn clearEscapeHelpOverlay(
    renderer: client_renderer.Renderer,
    viewport_offset: *i32,
    overlay_state: *?client_ui.OverlayDrawState,
) !void {
    const state = overlay_state.* orelse return;
    const size = terminal.currentWindowSize();
    try client_ui.eraseOverlayRows(renderer, state, size.rows, size.cols);
    try client_ui.restoreOverlayExpansion(renderer, state, size.rows);
    const cleared = client_ui.clearedOverlayViewportOffset(state);
    viewport_offset.* = @intCast(cleared);
    overlay_state.* = null;
    try renderer.moveCursor(cleared, 0);
}

fn drainEscapeHelpRuntimeFrames(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    while (true) {
        var runtime_poll = [_]posix.pollfd{.{
            .fd = read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = try posix.poll(&runtime_poll, 0);
        const revents = runtime_poll[0].revents;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((revents & posix.POLL.IN) == 0) return null;

        if (try handleEscapeHelpRuntimeFrame(read_fd, write_fd, runtime_reader, input_ack_tracker, ended_process_exit_code)) |end| return end;
    }
}

fn handleEscapeHelpRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
) !?AttachedClientEnd {
    _ = write_fd;
    var frame = switch (try runtime_reader.readReady(read_fd)) {
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
                // The overlay sits on top of the last rendered screen. Applying
                // remote draws here would interleave two renderers;
                // repaint-after-dismiss is the boundary that gets us back to a
                // single source of screen truth.
                .draw, .repaint_response => return null,
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return null;
                },
                .input_ack => |ack| {
                    _ = handleInputAckMessage(ack, input_ack_tracker);
                    return null;
                },
                .session_ended => |ended| {
                    if (ended_process_exit_code) |exit_code| {
                        exit_code.* = attached_client_state.processExitCodeFromSessionEnded(ended);
                    }
                    return .session_ended;
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
            .handled => return null,
            .transport_closed => return .remote_transport_closed,
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

fn drainAttachedClientRuntimeFrames(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    initial_cursor_position: *?terminal.CursorPosition,
    initial_draw_alignment_pending: *bool,
) !?AttachedClientEnd {
    while (true) {
        var runtime_poll = [_]posix.pollfd{.{
            .fd = read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = try posix.poll(&runtime_poll, 0);
        const revents = runtime_poll[0].revents;
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (revents & posix.POLL.IN) == 0)
        {
            return .transport_closed;
        }
        if ((revents & posix.POLL.IN) == 0) return null;

        if (try handleAttachedClientRuntimeFrame(
            read_fd,
            write_fd,
            runtime_reader,
            connection_monitor,
            scrollback_cursor,
            viewport_offset,
            pending_repaint,
            attached_client_end_restore,
            input_ack_tracker,
            ended_process_exit_code,
            app_title_present,
            initial_cursor_position,
            initial_draw_alignment_pending,
        )) |end| return end;
    }
}

fn finishAttachedClientAfterRuntimeWriteFailed(
    read_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    initial_cursor_position: *?terminal.CursorPosition,
    initial_draw_alignment_pending: *bool,
) !AttachedClientEnd {
    if (try drainAttachedClientRuntimeFrames(
        read_fd,
        @as(c.fd_t, -1),
        runtime_reader,
        connection_monitor,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        attached_client_end_restore,
        input_ack_tracker,
        ended_process_exit_code,
        app_title_present,
        initial_cursor_position,
        initial_draw_alignment_pending,
    )) |end| return finishAttachedClient(end, attached_client_end_restore);
    return .transport_closed;
}

fn handleAttachedClientRuntimeFrame(
    read_fd: c.fd_t,
    write_fd: c.fd_t,
    runtime_reader: *protocol.FrameReader,
    connection_monitor: *ConnectionMonitor,
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    attached_client_end_restore: *std.ArrayList(u8),
    input_ack_tracker: *InputAckTracker,
    ended_process_exit_code: ?*?u8,
    app_title_present: *?bool,
    initial_cursor_position: *?terminal.CursorPosition,
    initial_draw_alignment_pending: *bool,
) !?AttachedClientEnd {
    _ = write_fd;
    var frame = switch (try runtime_reader.readReady(read_fd)) {
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
                    if (!pending_repaint.active()) {
                        try handleDrawMessageWithInitialAlignment(
                            draw,
                            attached_client_end_restore,
                            scrollback_cursor,
                            viewport_offset,
                            app_title_present,
                            initial_cursor_position,
                            initial_draw_alignment_pending,
                        );
                    }
                    return null;
                },
                .repaint_response => |response| {
                    _ = try handleRepaintResponseMessageWithInitialAlignment(
                        response,
                        attached_client_end_restore,
                        scrollback_cursor,
                        viewport_offset,
                        pending_repaint,
                        app_title_present,
                        initial_cursor_position,
                        initial_draw_alignment_pending,
                    );
                    return null;
                },
                .tty_transcript_chunk => |chunk| {
                    handleTtyTranscriptChunkMessage(chunk);
                    return null;
                },
                .input_ack => |ack_message| {
                    const ack = handleInputAckMessage(ack_message, input_ack_tracker);
                    if (ack.progressed) connection_monitor.noteInputAckProgress(ack.still_pending);
                    return null;
                },
                .session_ended => |ended| {
                    if (ended_process_exit_code) |exit_code| {
                        exit_code.* = attached_client_state.processExitCodeFromSessionEnded(ended);
                    }
                    return .session_ended;
                },
                else => return error.UnexpectedFrame,
            }
        },
        .client_daemon => switch (try handleClientDaemonFrame(frame.payload)) {
            .handled => return null,
            .transport_closed => return .remote_transport_closed,
            .unexpected => return error.UnexpectedFrame,
        },
        .error_message => {
            try printErrorPayload(frame.payload);
            return .session_ended;
        },
        else => return error.UnexpectedFrame,
    }
}

fn finishAttachedClient(end: AttachedClientEnd, attached_client_end_restore: ?*std.ArrayList(u8)) AttachedClientEnd {
    if (end == .client_hangup or end == .session_ended) {
        presentation_guard_mod.restoreAttachedClientEndBytes(attached_client_end_restore);
    }
    return end;
}

fn clearVisibleAfterResizeTimeout(viewport_offset: *i32) void {
    viewport_offset.* = 0;
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    const renderer = client_renderer.Renderer.init(posix.STDOUT_FILENO);
    renderer.restorePresentation(terminal.queryInitialKittyKeyboardFlags(posix.STDIN_FILENO, posix.STDOUT_FILENO)) catch {};
    renderer.clearVisible() catch {};
}

fn checkResizeRepaintTimeout(pending_repaint: *const PendingRepaint, viewport_offset: *i32, now_ms: i64) ?AttachedClientEnd {
    if (!pending_repaint.resizeTimedOut(now_ms)) return null;
    clearVisibleAfterResizeTimeout(viewport_offset);
    return .unresponsive;
}

fn clientHangup() AttachedClientEnd {
    return .client_hangup;
}

fn writeClientCloseBoundary() void {
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    io_helpers.writeAll(posix.STDOUT_FILENO, "\r\n") catch {};
}

fn handleRepaintResponseFrame(
    payload: []const u8,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    app_title_present: ?*?bool,
) !bool {
    var response = try protocol.decodePayload(pb.TerminalEmulatorItem.RepaintResponse, app_allocator.allocator(), payload);
    defer response.deinit(app_allocator.allocator());
    return handleRepaintResponseMessageWithInitialAlignment(
        response,
        attached_client_end_restore,
        scrollback_cursor,
        viewport_offset,
        pending_repaint,
        app_title_present,
        null,
        null,
    );
}

fn handleRepaintResponseMessageWithInitialAlignment(
    response: pb.TerminalEmulatorItem.RepaintResponse,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    pending_repaint: *PendingRepaint,
    app_title_present: ?*?bool,
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !bool {
    if (!pending_repaint.active() or !pending_repaint.matches(response.repaint_request_seq)) return false;
    const response_draw = response.draw orelse return error.MissingDraw;
    try handleDrawMessageWithInitialAlignment(
        response_draw,
        attached_client_end_restore,
        scrollback_cursor,
        viewport_offset,
        app_title_present,
        initial_cursor_position,
        initial_draw_alignment_pending,
    );
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

fn handleClientDaemonFrame(payload: []const u8) !ClientDaemonFrameAction {
    return handleClientDaemonFrameWithUi(payload, null);
}

fn handleClientDaemonFrameWithUi(payload: []const u8, reconnect_ui: ?*client_ui.ReconnectUi) !ClientDaemonFrameAction {
    var item = try protocol.decodePayload(pb.ClientDaemonItem, app_allocator.allocator(), payload);
    defer item.deinit(app_allocator.allocator());

    const item_payload = item.payload orelse return .unexpected;
    return switch (item_payload) {
        .connection_event => |event| handleConnectionEvent(event, reconnect_ui),
        else => .unexpected,
    };
}

fn handleConnectionEvent(event: pb.ConnectionEvent, reconnect_ui: ?*client_ui.ReconnectUi) !ClientDaemonFrameAction {
    if (reconnect_ui) |ui| {
        try ui.handleConnectionEvent(event);
    } else switch (connection_event.classify(event)) {
        .ssh_stderr => |stderr| client_log.appendSshStderr(stderr.data),
        .binary_bootstrapping => try io_helpers.writeAll(2, "\rsessh: bootstrapping..."),
        .daemon_connecting => try io_helpers.writeAll(2, "\r\x1b[K"),
        .retry => |retry| if (retry.reason == .disconnected) return .transport_closed,
        .ssh_connecting,
        .ssh_connected,
        .daemon_connected,
        .none,
        => {},
    }
    return .handled;
}

fn handleInputAckMessage(ack: pb.TerminalEmulatorItem.InputAck, input_ack_tracker: *InputAckTracker) input_ack.AckResult {
    return input_ack.acknowledge(input_ack_tracker, ack.input_seq);
}

fn handleDrawPayload(
    draw: DrawPayload,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
) !void {
    try handleDrawPayloadWithInitialAlignment(
        draw,
        attached_client_end_restore,
        scrollback_cursor,
        viewport_offset,
        app_title_present,
        null,
        null,
    );
}

fn handleDrawPayloadWithInitialAlignment(
    draw: DrawPayload,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !void {
    try restoreInitialCursorAndClearBelow(initial_cursor_position, initial_draw_alignment_pending);
    try io_helpers.writeAll(posix.STDOUT_FILENO, draw.draw_bytes);
    if (attached_client_end_restore) |target| {
        if (draw.attached_client_end_restore_bytes) |restore| {
            target.clearRetainingCapacity();
            try target.appendSlice(app_allocator.allocator(), restore);
        }
    }
    try scrollback_cursor.set(draw.scrollback_cursor);
    viewport_offset.* = draw.viewport_offset;
    if (app_title_present) |target| {
        if (draw.app_title_present) |present| target.* = present;
    }
}

fn handleDrawMessageWithInitialAlignment(
    message: pb.TerminalEmulatorItem.Draw,
    attached_client_end_restore: ?*std.ArrayList(u8),
    scrollback_cursor: *ScrollbackCursor,
    viewport_offset: *i32,
    app_title_present: ?*?bool,
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !void {
    const draw = try drawPayloadFromMessage(message);
    defer freeDrawPayload(draw);
    try handleDrawPayloadWithInitialAlignment(
        draw,
        attached_client_end_restore,
        scrollback_cursor,
        viewport_offset,
        app_title_present,
        initial_cursor_position,
        initial_draw_alignment_pending,
    );
}

fn restoreInitialCursorAndClearBelow(
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !void {
    try restoreInitialCursorAndClearBelowOnFd(
        posix.STDOUT_FILENO,
        initial_cursor_position,
        initial_draw_alignment_pending,
    );
}

fn restoreInitialCursorAndClearBelowOnFd(
    fd: c.fd_t,
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !void {
    try restoreInitialCursorAndClearBelowWithRenderer(
        fd,
        client_renderer.Renderer.init(fd),
        initial_cursor_position,
        initial_draw_alignment_pending,
    );
}

fn restoreInitialCursorAndClearBelowWithRenderer(
    fd: c.fd_t,
    renderer: client_renderer.Renderer,
    initial_cursor_position: ?*?terminal.CursorPosition,
    initial_draw_alignment_pending: ?*bool,
) !void {
    const pending = initial_draw_alignment_pending orelse return;
    if (!pending.*) return;
    pending.* = false;
    const cursor = initial_cursor_position orelse return;
    defer cursor.* = null;
    const position = cursor.* orelse return;
    if (c.isatty(fd) == 0) return;
    renderer.moveCursor(position.row, position.col) catch return;
    renderer.clearBelowCursor() catch {};
}

test "initial draw alignment is consumed without writing to non-tty output" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try core_fds.setNonBlocking(pipe[0]);

    var cursor: ?terminal.CursorPosition = .{ .row = 2, .col = 5 };
    var pending = true;
    try restoreInitialCursorAndClearBelowWithRenderer(
        pipe[1],
        client_renderer.Renderer.withCapabilities(pipe[1], .{ .kind = .xterm_compatible }),
        &cursor,
        &pending,
    );

    try std.testing.expect(!pending);
    try std.testing.expect(cursor == null);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try protocol_test_helpers.readAvailableForTest(std.testing.allocator, pipe[0], &output);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "initial draw alignment restores tty cursor and clears below" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
    defer posix.close(master);
    defer posix.close(slave);
    try core_fds.setNonBlocking(master);

    var cursor: ?terminal.CursorPosition = .{ .row = 2, .col = 5 };
    var pending = true;
    try restoreInitialCursorAndClearBelowWithRenderer(
        slave,
        client_renderer.Renderer.withCapabilities(slave, .{ .kind = .xterm_compatible }),
        &cursor,
        &pending,
    );

    try std.testing.expect(!pending);
    try std.testing.expect(cursor == null);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try protocol_test_helpers.readAvailableForTest(std.testing.allocator, master, &output);
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
        .attached_client_end_restore_bytes = if (message.attached_client_end_restore_bytes) |restore|
            try app_allocator.allocator().dupe(u8, restore)
        else
            null,
    };
}

fn freeDrawPayload(draw: DrawPayload) void {
    app_allocator.allocator().free(draw.scrollback_cursor);
    app_allocator.allocator().free(draw.draw_bytes);
    if (draw.attached_client_end_restore_bytes) |restore| app_allocator.allocator().free(restore);
}
