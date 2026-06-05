const std = @import("std");

const mux_cli = @import("cli.zig");
const session_registry = @import("../runtime/session_registry.zig");
const ssh_client = @import("../transport/ssh.zig");

pub fn baseInvocation(
    options: []const []const u8,
    action: ssh_client.SessionAction,
    common: mux_cli.CommonSessionOptions,
) !ssh_client.SessionInvocation {
    var parsed = ssh_client.SessionInvocation{
        .options = options,
        .host = "",
        .action = action,
        .alias = common.alias,
        .banner_args = common.banner_args,
        .scrollback_row_count = common.scrollback_row_count,
        .scrollback_row_count_set = common.scrollback_row_count_set,
        .initial_scrollback_row_count = common.initial_scrollback_row_count,
        .initial_scrollback_row_count_set = common.initial_scrollback_row_count_set,
        .client_log_level = common.client_log_level,
        .client_log_level_set = common.client_log_level_set,
        .bootstrap = common.bootstrap,
        .bootstrap_set = common.bootstrap_set,
        .terminal_emulator = common.terminal_emulator,
        .terminal_emulator_set = common.terminal_emulator_set,
        .filter_level = common.filter_level,
        .filter_level_set = common.filter_level_set,
        .capture_tty_transcript = common.capture_tty_transcript,
    };
    try ssh_client.classifySshOptions(options, &parsed.tty_request, &parsed.proxy_required);
    return parsed;
}

pub fn readRouteForRef(allocator: std.mem.Allocator, route_storage: *?session_registry.Route, ref: []const u8) !void {
    if (!try tryReadRouteForRef(allocator, route_storage, ref)) return error.FileNotFound;
}

pub fn tryReadRouteForRef(allocator: std.mem.Allocator, route_storage: *?session_registry.Route, ref: []const u8) !bool {
    route_storage.* = session_registry.readRouteForRef(allocator, ref) catch |err| switch (err) {
        error.FileNotFound => {
            if (session_registry.tombstoneExistsForRef(allocator, ref)) return error.SessionAlreadyExited;
            return false;
        },
        else => return err,
    };
    return true;
}

pub fn fillFromRoute(action: ssh_client.SessionAction, parsed: *ssh_client.SessionInvocation, route: session_registry.Route) void {
    parsed.options = route.ssh_options;
    parsed.host = route.host;
    parsed.action = action;
    switch (action) {
        .attach => {
            parsed.attach_id = route.guid;
            parsed.attach_session_dir = route.session_dir;
        },
        .kill => {
            parsed.kill_id = route.guid;
            parsed.kill_ids = &.{route.guid};
        },
        .new, .list, .kill_all, .detach_client, .repaint_client, .debug_client => unreachable,
    }
}
