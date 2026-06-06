const std = @import("std");

const mux_cli = @import("cli.zig");

pub fn parse(
    scratch: *mux_cli.Scratch,
    args: []const []const u8,
    repaint_defaults_to_all: bool,
    debug_action: ?mux_cli.DebugAction,
) !mux_cli.ClientControl {
    var parsed = mux_cli.CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var control = mux_cli.ClientControl{};
    var seconds: ?[]const u8 = null;

    var i: usize = 0;
    try parseTail(scratch, args, &i, &parsed, &control, repaint_defaults_to_all, debug_action, &seconds);
    try finish(scratch, &parsed, &control, repaint_defaults_to_all, seconds);
    return control;
}

pub fn parseTail(
    scratch: *mux_cli.Scratch,
    args: []const []const u8,
    index: *usize,
    parsed: *mux_cli.CommandParts,
    control: *mux_cli.ClientControl,
    repaint_defaults_to_all: bool,
    debug_action: ?mux_cli.DebugAction,
    seconds: *?[]const u8,
) !void {
    var i = index.*;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            control.all = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--last-input")) {
            control.last_input = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scrollback")) {
            if (!repaint_defaults_to_all) return error.UnsupportedMuxOption;
            control.scrollback = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            if (debug_action != .unresponsive_connection) return error.UnsupportedMuxOption;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingDebugSeconds;
            _ = try mux_cli.parseDebugUnresponsiveSeconds(args[i]);
            seconds.* = args[i];
            i += 1;
        } else if (try mux_cli.parseSharedOption(scratch, args, &i, parsed, .client_control)) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedMuxOption;
        } else {
            try parsed.positionals.append(scratch.allocator, arg);
            i += 1;
        }
    }
    index.* = i;
}

pub fn finish(
    scratch: *mux_cli.Scratch,
    parsed: *mux_cli.CommandParts,
    control: *mux_cli.ClientControl,
    repaint_defaults_to_all: bool,
    seconds: ?[]const u8,
) !void {
    control.common = parsed.common;
    if (parsed.host) |host| {
        control.target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
    } else if (parsed.ssh_options.items.len > 0) {
        return error.MissingHost;
    }
    if (parsed.positionals.items.len > 0 and std.mem.eql(u8, parsed.positionals.items[0], ".")) {
        if (control.target != .local) return error.TooManyMuxArguments;
        _ = parsed.positionals.orderedRemove(0);
    }
    try mux_cli.applyClientControlPositionals(control, parsed.positionals.items, repaint_defaults_to_all);
    if (parsed.ids.items.len > 1) return error.TooManyMuxArguments;
    if (parsed.ids.items.len == 1) {
        if (control.session_ref != null) return error.TooManyMuxArguments;
        control.session_ref = parsed.ids.items[0];
    }
    control.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    control.seconds = seconds;
}

pub fn appendRemoteArgs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    command: []const u8,
    debug_action: ?mux_cli.DebugAction,
    control: mux_cli.ClientControl,
    default_session_ref: ?[]const u8,
) !void {
    try out.append(allocator, command);
    try out.append(allocator, "--host");
    try out.append(allocator, ".");
    const resolved_session_ref: ?[]const u8 = if (control.session_ref) |session_ref| session_ref else default_session_ref;
    if (resolved_session_ref) |session_ref| {
        try out.append(allocator, "--id");
        try out.append(allocator, session_ref);
    }
    try mux_cli.appendRemoteCommonArgs(allocator, out, control.common);
    if (debug_action) |action| {
        try out.append(allocator, switch (action) {
            .sever_connection => "sever-connection",
            .unresponsive_connection => "unresponsive-connection",
        });
    }
    switch (mux_cli.clientControlTarget(control)) {
        .default => {},
        .all => try out.append(allocator, "--all"),
        .last_input => try out.append(allocator, "--last-input"),
        .client_guid => try out.append(allocator, control.client_guid.?),
    }
    if (control.scrollback) try out.append(allocator, "--scrollback");
    if (control.seconds) |seconds| {
        try out.append(allocator, "--seconds");
        try out.append(allocator, seconds);
    }
}
