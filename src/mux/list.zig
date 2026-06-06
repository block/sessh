const std = @import("std");

const mux_cli = @import("cli.zig");
const mux_common = @import("common.zig");
const ssh_client = @import("../transport/ssh.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.List {
    var parsed = mux_cli.CommandParts{};
    defer parsed.deinit(scratch.allocator);
    var list = mux_cli.List{};
    try mux_cli.parseSharedPartsWithCommandOptions(scratch, args, &parsed, .list, struct {
        fn parseOption(arg: []const u8, parser: *mux_cli.CommandParts, out: *mux_cli.List) !bool {
            _ = parser;
            if (std.mem.eql(u8, arg, "--refresh")) {
                out.refresh = true;
            } else if (std.mem.eql(u8, arg, "--exited")) {
                out.exited = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                out.all = true;
            } else if (std.mem.eql(u8, arg, "--jsonl")) {
                out.jsonl = true;
            } else {
                return false;
            }
            return true;
        }
    }.parseOption, &list);

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.startsWith(u8, args[i], "--client=")) {
            const value = args[i]["--client=".len..];
            if (value.len == 0) return error.MissingClientListTarget;
            if (list.client_target != null) return error.MultipleTargets;
            list.client_target = value;
            list.client_option_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--client")) {
            if (list.client_target != null) return error.MultipleTargets;
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "-")) return error.MissingClientListTarget;
            list.client_target = args[i];
            list.client_option_arg = "--client";
        }
        i += 1;
    }

    list.common = parsed.common;
    if (parsed.host) |host| {
        if (parsed.positionals.items.len != 0) return error.TooManyMuxArguments;
        list.target = if (std.mem.eql(u8, host, ".")) .local else .{ .host = host };
        if (std.mem.eql(u8, host, ".")) list.include_cached_routes = false;
    } else if (parsed.positionals.items.len == 0) {
        if (parsed.ssh_options.items.len > 0) return error.MissingHost;
        list.target = .local;
    } else if (parsed.positionals.items.len == 1) {
        const target = parsed.positionals.items[0];
        list.target = if (std.mem.eql(u8, target, ".")) .local else .{ .host = target };
        if (std.mem.eql(u8, target, ".")) list.include_cached_routes = false;
    } else {
        return error.TooManyMuxArguments;
    }
    if (list.all and (list.exited or list.client_target != null)) return error.UnsupportedMuxOption;
    if (list.client_target != null and (list.refresh or list.exited or !list.include_cached_routes)) return error.UnsupportedMuxOption;
    list.ssh_options = try scratch.ownSshOptions(&parsed.ssh_options);
    return list;
}

pub fn toInvocation(list: mux_cli.List) !ssh_client.SessionInvocation {
    var parsed = try mux_common.baseInvocation(list.ssh_options, .list, list.common);
    parsed.host = switch (list.target) {
        .local => "",
        .host => |host| host,
    };
    parsed.list_refresh = list.refresh;
    parsed.list_include_cached_routes = list.include_cached_routes;
    parsed.list_jsonl = list.jsonl;
    parsed.list_exited = list.exited;
    parsed.list_all = list.all;
    parsed.list_client_target = list.client_target;
    parsed.list_client_option_arg = list.client_option_arg;
    return parsed;
}

test "parse dot is explicit local-only target" {
    var positional_scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer positional_scratch.deinit();
    const positional = try parse(&positional_scratch, &.{"."});
    try std.testing.expectEqual(mux_cli.ListTarget.local, positional.target);
    try std.testing.expect(!positional.include_cached_routes);

    var host_option_scratch = mux_cli.Scratch{ .allocator = std.testing.allocator };
    defer host_option_scratch.deinit();
    const host_option = try parse(&host_option_scratch, &.{ "--host", "." });
    try std.testing.expectEqual(mux_cli.ListTarget.local, host_option.target);
    try std.testing.expect(!host_option.include_cached_routes);
}
