const std = @import("std");

const attached_client = @import("attached_client.zig");
const client_log = @import("../core/client_log.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const broker_process = @import("broker_process.zig");
const process_exit = @import("../core/process_exit.zig");
const reconnect_title = @import("../reconnect/title.zig");
const runtime_commands = @import("../runtime/commands.zig");
const route_commands = @import("../runtime/route_commands.zig");
const session_registry = @import("../runtime/session_registry.zig");
const tty_transcript = @import("../tty/transcript.zig");

pub const Request = struct {
    exe: []const u8,
    session_ref: ?[]const u8 = null,
    session_dir: []const u8 = "",
    initial_scrollback_row_count: ?u32 = null,
    overlay_args: []const []const u8 = &.{},
    capture_tty_transcript: ?[]const u8 = null,
    compat_mode: bool = false,
};

pub fn runLocal(allocator: std.mem.Allocator, request: Request) !void {
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

    var compat_attach_id: ?[]u8 = null;
    defer if (compat_attach_id) |id| allocator.free(id);
    if (request.session_ref == null and request.compat_mode) {
        // Compat callers set SESSH_GUID when they already know the intended
        // session. Prefer that over the older "latest detached" behavior.
        compat_attach_id = std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
    }

    var child = try broker_process.start(allocator, request.exe);
    const child_read_fd = child.stdout.?.handle;
    const child_write_fd = child.stdin.?.handle;

    var session = attached_client.startAttachSessionOnRuntime(
        child_read_fd,
        child_write_fd,
        request.session_ref orelse compat_attach_id orelse "",
        request.session_dir,
        request.initial_scrollback_row_count,
        null,
    ) catch |err| {
        if (process_exit.is(err)) return err;
        broker_process.terminateChild(&child);
        try io.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
        return process_exit.request(1);
    };
    defer session.deinit();
    if (session.guidSlice().len > 0) {
        session_registry.markRouteAttached(allocator, session.guidSlice()) catch |err| {
            client_log.debug("event=local_route_attached_mark_failed session={s} error={t}", .{ session.guidSlice(), err });
        };
    }
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
            broker_process.terminateChild(&child);
            try io.stderrPrint("sessh: local runtime attach failed: {t}\n", .{err});
            return process_exit.request(1);
        };

        switch (end) {
            .detach => {
                session.restoreAttachedClientEndPresentationForExit();
                broker_process.terminateChild(&child);
                attached_client.markRouteDetachedForSession(allocator, &session);
                try tty_transcript.finishActiveOrReport();
                attached_client.writeDetachOverlayForTarget(&.{}, ".", request.overlay_args, session.idSlice());
                if (session.kill_requested) attached_client.writeUnconfirmedKillDetachWarningForSessionRef(session.guidSlice());
                return;
            },
            .kill_detach => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                route_commands.requestLocalKillNoWait(allocator, &.{session.guidSlice()});
                session.restoreAttachedClientEndPresentationForExit();
                broker_process.terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .kill_wait => {
                attached_client.recordRuntimeSessionKillRequested(allocator, ".", &session);
                const killed = try route_commands.runLocalKillJsonlAndProcess(allocator, &.{session.guidSlice()}, session.guidSlice());
                if (killed) session.ended_tombstone_details = .{
                    .ended_at_unix_ms = attached_client.nowUnixMs(),
                    .end_reason = .killed_by_request,
                };
                session.restoreAttachedClientEndPresentationForExit();
                broker_process.terminateChild(&child);
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .session_ended => {
                session.restoreAttachedClientEndPresentationForExit();
                broker_process.closeChildStdin(&child);
                _ = child.wait() catch {};
                try tty_transcript.finishActiveOrReport();
                return;
            },
            .unresponsive => {
                broker_process.terminateChild(&child);
            },
            .transport_closed => {
                broker_process.closeChildStdin(&child);
                _ = child.wait() catch {};
                if (!runtime_commands.anyLiveSessionExists(allocator)) {
                    session.restoreAttachedClientEndPresentationForExit();
                    try io.writeAll(2, "\r\nsessh: session agent crashed\r\n");
                    return process_exit.request(1);
                }
            },
        }

        try io.writeAll(2, "\r\n");
        try io.writeAll(2, reconnect_title.reconnectingStatus(.{ .ctrl_c_detach = true }));
        try io.writeAll(2, "\r\n");
        child = broker_process.start(allocator, request.exe) catch |err| {
            session.restoreAttachedClientEndPresentationForExit();
            try io.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
        attached_client.reconnectSessionOnRuntime(child.stdout.?.handle, child.stdin.?.handle, &session) catch |err| {
            if (process_exit.is(err)) return err;
            broker_process.terminateChild(&child);
            session.restoreAttachedClientEndPresentationForExit();
            try io.stderrPrint("sessh: reconnect failed: {t}\n", .{err});
            return process_exit.request(1);
        };
    }
}
