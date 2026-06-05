const std = @import("std");

pub fn appendCommand(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    parsed: anytype,
    session_ref: ?[]const u8,
) !void {
    try appendCommandName(allocator, out, parsed.action);
    try appendTail(allocator, out, parsed, session_ref);
}

pub fn appendCommandName(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    action: anytype,
) !void {
    switch (action) {
        .detach_client => try out.append(allocator, "detach"),
        .repaint_client => try out.append(allocator, "repaint"),
        .debug_client => try out.append(allocator, "debug"),
        else => unreachable,
    }
}

pub fn appendTail(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    parsed: anytype,
    session_ref: ?[]const u8,
) !void {
    if (parsed.action == .debug_client) {
        try out.append(allocator, switch (parsed.debug_client_action.?) {
            .sever_connection => "sever-connection",
            .unresponsive_connection => "unresponsive-connection",
        });
    }
    switch (parsed.client_target) {
        .default => {},
        .all => try out.append(allocator, "--all"),
        .last_input => try out.append(allocator, "--last-input"),
        .client_guid => try out.append(allocator, parsed.client_guid.?),
    }
    if (parsed.client_repaint_scrollback) try out.append(allocator, "--scrollback");
    if (parsed.debug_unresponsive_seconds) |seconds| {
        try out.append(allocator, "--seconds");
        try out.append(allocator, seconds);
    }
    if (session_ref) |ref| try out.append(allocator, ref);
}
