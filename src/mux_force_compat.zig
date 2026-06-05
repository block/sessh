const std = @import("std");
const c = std.c;

const io = @import("io.zig");
const process_exit = @import("process_exit.zig");
const session_registry = @import("session_registry.zig");
const ssh_client = @import("ssh_client.zig");

const ArgScratch = struct {
    allocator: std.mem.Allocator,
    owned_args: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ArgScratch) void {
        for (self.owned_args.items) |arg| self.allocator.free(arg);
        self.owned_args.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var scratch = ArgScratch{ .allocator = allocator };
    defer scratch.deinit();
    var explicit_ssh_options: std.ArrayList([]const u8) = .empty;
    defer explicit_ssh_options.deinit(allocator);

    var host_option: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var command_args: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) return usage(error.MissingHost);
            host_option = args[i];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--ssh-options")) {
            i += 1;
            if (i >= args.len) return usage(error.MissingSshOptions);
            try appendShellSplitWords(&scratch, &explicit_ssh_options, args[i]);
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(error.UnsupportedMuxOption);
        } else {
            session_ref = arg;
            command_args = args[i + 1 ..];
            break;
        }
    }

    const requested_ref = session_ref orelse return usage(error.MissingCompatSession);
    if (command_args.len == 0) return usage(error.MissingCompatCommand);

    var route_storage: ?session_registry.Route = null;
    defer if (route_storage) |*route| route.deinit(allocator);
    var combined_ssh_options: std.ArrayList([]const u8) = .empty;
    defer combined_ssh_options.deinit(allocator);

    var transport = ssh_client.CompatTransport{
        .options = explicit_ssh_options.items,
        .host = "",
    };
    const remote_ref = if (host_option) |host| blk: {
        transport.host = host;
        break :blk requested_ref;
    } else blk: {
        route_storage = session_registry.readRouteForRef(allocator, requested_ref) catch |err| switch (err) {
            error.FileNotFound => {
                if (session_registry.tombstoneExistsForRef(allocator, requested_ref)) {
                    try io.writeAll(2, "ERROR session already exited\n");
                    return process_exit.request(1);
                }
                return usage(error.MissingCompatHost);
            },
            else => return err,
        };
        const route = &route_storage.?;
        if (route.host.len == 0 or std.mem.eql(u8, route.host, ".")) return usage(error.MissingCompatHost);
        transport.host = route.host;
        if (explicit_ssh_options.items.len == 0) {
            transport.options = route.ssh_options;
        } else {
            try combined_ssh_options.appendSlice(allocator, route.ssh_options);
            try combined_ssh_options.appendSlice(allocator, explicit_ssh_options.items);
            transport.options = combined_ssh_options.items;
        }
        break :blk route.guid;
    };

    var resolved_ssh_config = try ssh_client.resolveSshConfig(allocator, transport.options, transport.host);
    defer resolved_ssh_config.deinit(allocator);
    transport.default_ipqos_option = try resolved_ssh_config.defaultIpQosOption(allocator);
    defer if (transport.default_ipqos_option) |option| allocator.free(option);

    const local_args = try localCompatArgsForExplicitCommand(allocator, command_args, remote_ref);
    defer allocator.free(local_args);
    const command_script = try ssh_client.remoteCompatCommandScriptFor(allocator, "force-compat", remote_ref, local_args);
    defer allocator.free(command_script);

    const tty_option = ssh_client.compatSshTtyOptionForLocalArgs(command_args, c.isatty(0) != 0, c.isatty(1) != 0);
    try ssh_client.runRemoteCompatCommandScriptForTransport(allocator, transport, command_script, .forced, tty_option);
}

fn usage(err: anyerror) !void {
    switch (err) {
        error.MissingHost => try io.writeAll(2, "sesshmux: --host requires a value\n"),
        error.MissingSshOptions => try io.writeAll(2, "sesshmux: --ssh-options requires a value\n"),
        error.UnsupportedMuxOption => try io.writeAll(2, "sesshmux: unsupported option for this command\n"),
        error.MissingCompatSession => try io.writeAll(2, "sesshmux: force-compat requires a session id or alias\n"),
        error.MissingCompatCommand => try io.writeAll(2, "sesshmux: force-compat requires a command after the session id\n"),
        error.MissingCompatHost => try io.writeAll(2, "sesshmux: force-compat requires --host HOST unless the session has a cached remote route\n"),
        else => try io.stderrPrint("sesshmux: invalid force-compat arguments: {t}\n", .{err}),
    }
    return process_exit.request(64);
}

fn appendShellSplitWords(
    scratch: *ArgScratch,
    out: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(scratch.allocator, value);
    defer it.deinit();
    while (it.next()) |word| {
        const owned = try scratch.allocator.dupe(u8, word);
        errdefer scratch.allocator.free(owned);
        try scratch.owned_args.append(scratch.allocator, owned);
        try out.append(scratch.allocator, owned);
    }
}

fn localCompatArgsForExplicitCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    session_ref: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--log-level") and i + 1 < args.len) {
            try appendCompatArg(allocator, &out, args[i]);
            try appendCompatArg(allocator, &out, args[i + 1]);
            i += 2;
            continue;
        }
        break;
    }

    if (i < args.len and std.mem.eql(u8, args[i], "attach")) {
        try appendCompatArg(allocator, &out, args[i]);
        i += 1;
        if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
            // Older clients attach the latest detached session when no id is
            // present. The public compat command names a specific session, so
            // add that ref before forwarding the rest of the attach options.
            try appendCompatArg(allocator, &out, session_ref);
        }
    }

    while (i < args.len) : (i += 1) {
        try appendCompatArg(allocator, &out, args[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn appendCompatArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    const quoted = try shellQuote(allocator, arg);
    defer allocator.free(quoted);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, quoted);
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

test "force-compat local args add explicit attach session" {
    const args = try localCompatArgsForExplicitCommand(std.testing.allocator, &.{ "attach", "--log-level", "warn" }, "s1");
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings(" 'attach' 's1' '--log-level' 'warn'", args);
}
