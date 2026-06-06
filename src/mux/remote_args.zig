const std = @import("std");

const mux_cli = @import("cli.zig");
const session_registry = @import("../runtime/session_registry.zig");
const shell = @import("../core/shell.zig");

pub const ListOptions = struct {
    refresh: bool = false,
    exited: bool = false,
    all: bool = false,
    jsonl: bool = false,
    client_target: ?[]const u8 = null,
    client_option_arg: ?[]const u8 = null,
};

pub const KillOptions = struct {
    jsonl: bool = false,
    all: bool = false,
    current: bool = false,
    ids: []const []const u8 = &.{},
    request_jsons: []const []const u8 = &.{},
};

pub fn appendProgramLocalList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    program: []const u8,
    options: ListOptions,
) !void {
    try out.append(allocator, program);
    try appendLocalList(allocator, out, options);
}

pub fn appendProgramLocalKill(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    program: []const u8,
    options: KillOptions,
) !void {
    try out.append(allocator, program);
    try appendLocalKill(allocator, out, options);
}

pub fn appendRoutedList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    program: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    options: ListOptions,
) !?[]u8 {
    try out.append(allocator, program);
    try out.append(allocator, "list");
    const ssh_options_arg = try appendRoutedTarget(allocator, out, host, ssh_options);
    try appendListOptions(allocator, out, options);
    return ssh_options_arg;
}

pub fn appendRoutedKill(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    program: []const u8,
    host: []const u8,
    ssh_options: []const []const u8,
    options: KillOptions,
) !?[]u8 {
    try out.append(allocator, program);
    try out.append(allocator, "kill");
    const ssh_options_arg = try appendRoutedTarget(allocator, out, host, ssh_options);
    try appendKillOptions(allocator, out, options);
    return ssh_options_arg;
}

pub fn appendList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    list: mux_cli.List,
) !void {
    try out.appendSlice(allocator, &.{ "list", "--host", "." });
    try mux_cli.appendRemoteCommonArgs(allocator, out, list.common);
    try appendListOptions(allocator, out, .{
        .refresh = list.refresh,
        .exited = list.exited,
        .all = list.all,
        .jsonl = list.jsonl,
        .client_target = list.client_target,
        .client_option_arg = list.client_option_arg,
    });
}

pub fn appendKill(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    kill: mux_cli.Kill,
    route: ?*const session_registry.Route,
) !void {
    const ids = if (route) |resolved_route| blk: {
        if (kill.command_target == .route_ref_or_local_id) break :blk @as([]const []const u8, &.{resolved_route.guid});
        break :blk kill.ids;
    } else kill.ids;
    try out.appendSlice(allocator, &.{ "kill", "--host", "." });
    for (ids) |id| {
        try out.append(allocator, "--id");
        try out.append(allocator, id);
    }
    try mux_cli.appendRemoteCommonArgs(allocator, out, kill.common);
    if (kill.jsonl) try out.append(allocator, "--jsonl");
    try appendKillOptionsNoIds(allocator, out, .{
        .all = kill.all,
        .current = kill.current,
        .request_jsons = kill.request_jsons,
    });
}

fn appendLocalList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    options: ListOptions,
) !void {
    try out.appendSlice(allocator, &.{ "list", "--host", "." });
    try appendListOptions(allocator, out, options);
}

fn appendLocalKill(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    options: KillOptions,
) !void {
    try out.appendSlice(allocator, &.{ "kill", "--host", "." });
    try appendKillOptions(allocator, out, options);
}

fn appendRoutedTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    host: []const u8,
    ssh_options: []const []const u8,
) !?[]u8 {
    const ssh_options_arg = if (ssh_options.len > 0) try shell.joinArgs(allocator, ssh_options) else null;
    if (ssh_options_arg) |value| {
        try out.append(allocator, "--ssh-options");
        try out.append(allocator, value);
    }
    try out.append(allocator, "--host");
    try out.append(allocator, host);
    return ssh_options_arg;
}

fn appendListOptions(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    options: ListOptions,
) !void {
    if (options.refresh) try out.append(allocator, "--refresh");
    if (options.exited) try out.append(allocator, "--exited");
    if (options.all) try out.append(allocator, "--all");
    if (options.jsonl) try out.append(allocator, "--jsonl");
    if (options.client_target) |target| {
        if (options.client_option_arg) |client_arg| {
            try out.append(allocator, client_arg);
            if (std.mem.eql(u8, client_arg, "--client")) try out.append(allocator, target);
        } else {
            try out.append(allocator, "--client");
            try out.append(allocator, target);
        }
    }
}

fn appendKillOptions(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    options: KillOptions,
) !void {
    if (options.jsonl) try out.append(allocator, "--jsonl");
    for (options.ids) |id| {
        try out.append(allocator, "--id");
        try out.append(allocator, id);
    }
    try appendKillOptionsNoIds(allocator, out, options);
}

fn appendKillOptionsNoIds(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    options: KillOptions,
) !void {
    if (options.all) try out.append(allocator, "--all");
    if (options.current) try out.append(allocator, "--current");
    for (options.request_jsons) |request_json| {
        try out.append(allocator, "--request");
        try out.append(allocator, request_json);
    }
}
