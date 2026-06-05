const std = @import("std");

const attached_client = @import("attached_client.zig");
const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const local_broker = @import("local_broker.zig");
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const route_commands = @import("../runtime/route_commands.zig");
const session_registry = @import("../runtime/session_registry.zig");
const tty_transcript = @import("../tty/transcript.zig");

pub const Request = struct {
    exe: []const u8,
    new_detached: bool = false,
    scrollback_row_count: u32 = config.default_scrollback_row_count,
    reap_ms: u64 = config.default_reap_ms,
    tombstone_retention_ms: u64 = config.default_tombstone_retention_ms,
    overlay_args: []const []const u8 = &.{},
    capture_tty_transcript: ?[]const u8 = null,
    command_argv: []const []const u8 = &.{},
    shell_command: ?[]const u8 = null,
};

pub fn runLocal(allocator: std.mem.Allocator, request: Request) !void {
    if (request.new_detached and request.capture_tty_transcript != null) {
        try io.writeAll(2, "sesshmux: new --detached does not support --capture-tty-transcript\n");
        return process_exit.request(64);
    }

    var transcript_recorder: ?tty_transcript.Recorder = null;
    if (request.capture_tty_transcript) |path| {
        transcript_recorder = try tty_transcript.Recorder.init(allocator, path);
        if (transcript_recorder) |*recorder| {
            try recorder.warnEnabled();
            tty_transcript.activate(recorder);
        }
    }
    defer if (transcript_recorder) |*recorder| {
        tty_transcript.deactivate();
        recorder.deinit();
    };

    const generated_guid = try session_registry.generateGuid(allocator);
    defer allocator.free(generated_guid);

    const runtime_broker_args: []const []const u8 = &.{};
    var child = try local_broker.start(allocator, request.exe, runtime_broker_args);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    if (request.new_detached) {
        var created = attached_client.createSessionOnRuntime(
            child_read_fd,
            child_write_fd,
            request.scrollback_row_count,
            generated_guid,
            request.command_argv,
            request.shell_command,
            null,
            request.reap_ms,
            request.tombstone_retention_ms,
        ) catch |err| {
            if (process_exit.is(err)) return err;
            local_broker.terminateChild(&child);
            try io.stderrPrint("sessh: local runtime create failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        defer created.deinit();
        try session_registry.writeLocalRoute(allocator, created.guid, created.session_dir, config.version, request.tombstone_retention_ms);
        session_registry.markRouteDetachedNow(allocator, created.guid) catch |err| {
            client_log.debug("event=local_route_detached_mark_failed session={s} error={t}", .{ created.guid, err });
        };
        local_broker.closeChildStdin(&child);
        _ = child.wait() catch {};
        var created_buf: [128]u8 = undefined;
        const created_line = try std.fmt.bufPrint(&created_buf, "CREATED {s}\n", .{created.guid});
        try io.writeAll(1, created_line);
        return;
    }

    var session = attached_client.startNewSessionOnRuntime(
        child_read_fd,
        child_write_fd,
        request.scrollback_row_count,
        generated_guid,
        request.command_argv,
        request.shell_command,
        null,
        request.reap_ms,
        request.tombstone_retention_ms,
    ) catch |err| {
        if (process_exit.is(err)) return err;
        local_broker.terminateChild(&child);
        try io.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    try session_registry.writeLocalRoute(allocator, session.guidSlice(), session.sessionDirSlice(), config.version, request.tombstone_retention_ms);
    attached_client.writeClientRouteHintForSession(allocator, &session);
    defer attached_client.removeClientRouteHintForSession(allocator, &session);

    while (true) {
        const end = attached_client.runAttachedClient(
            child.stdout.?.handle,
            child.stdin.?.handle,
            &session,
            .{},
        ) catch |err| {
            if (process_exit.is(err)) return err;
            local_broker.terminateChild(&child);
            try io.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreAttachedClientEndPresentationForExit();
                local_broker.terminateChild(&child);
                attached_client.markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                attached_client.writeDetachOverlayForTarget(&.{}, ".", request.overlay_args, session.idSlice());
                if (session.kill_requested) attached_client.writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.spawnLocalKillJsonl(allocator, request.exe, &.{session.guidSlice()});
                session.restoreAttachedClientEndPresentationForExit();
                local_broker.terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, request.exe, &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = attached_client.nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreAttachedClientEndPresentationForExit();
                local_broker.terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreAttachedClientEndPresentationForExit();
                local_broker.closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                local_broker.terminateChild(&child);
            },
            .transport_closed => {
                local_broker.closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!local_broker.anySessionExists(allocator, request.exe, runtime_broker_args)) {
                    session.restoreAttachedClientEndPresentationForExit();
                    try io.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io.writeAll(2, "\r\n");
        try io.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io.writeAll(2, "\r\n");
        child = local_broker.start(allocator, request.exe, runtime_broker_args) catch |err| {
            session.restoreAttachedClientEndPresentationForExit();
            try io.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        attached_client.reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            local_broker.terminateChild(&child);
            session.restoreAttachedClientEndPresentationForExit();
            try io.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}
