const std = @import("std");

const config = @import("config.zig");
const io = @import("io.zig");
const mux_attach = @import("mux_attach.zig");
const mux_cli = @import("mux_cli.zig");
const mux_debug = @import("mux_debug.zig");
const mux_detach = @import("mux_detach.zig");
const mux_kill = @import("mux_kill.zig");
const mux_list = @import("mux_list.zig");
const mux_new = @import("mux_new.zig");
const mux_parser = @import("mux_parser.zig");
const mux_repaint = @import("mux_repaint.zig");
const process_exit = @import("process_exit.zig");
const session_registry = @import("session_registry.zig");
const ssh_client = @import("ssh_client.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2 or !mux_parser.isSubcommand(args[1])) {
        try ssh_client.printSshArgError(error.UnsupportedMuxCommand);
        return process_exit.request(64);
    }

    var mux_invocation = mux_parser.parse(allocator, args) catch |err| {
        try ssh_client.printSshArgError(err);
        return process_exit.request(64);
    };
    defer mux_invocation.deinit(allocator);

    var route_storage: ?session_registry.Route = null;
    defer if (route_storage) |*route| route.deinit(allocator);

    var parsed_ssh_args = invocationFromCommand(allocator, mux_invocation.command, &route_storage) catch |err| {
        try ssh_client.printSshArgError(err);
        return process_exit.request(64);
    };
    defer parsed_ssh_args.deinit(allocator);

    var default_session_ref: ?[]u8 = null;
    defer if (default_session_ref) |session_ref| allocator.free(session_ref);
    var remote_local_args: ?[]const []const u8 = null;
    defer if (remote_local_args) |argv| allocator.free(argv);
    if (needsRemoteLocalArgs(parsed_ssh_args)) {
        if (remoteClientControlNeedsDefaultSession(parsed_ssh_args)) {
            default_session_ref = std.process.getEnvVarOwned(allocator, config.session_guid_env) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    try io.writeAll(2, "sessh: client command requires an ID outside a sessh session\n");
                    return process_exit.request(64);
                },
                else => return err,
            };
        }
        remote_local_args = try mux_parser.remoteLocalArgs(allocator, args, default_session_ref);
        parsed_ssh_args.remote_local_args = remote_local_args.?;
    }

    return ssh_client.runInvocation(allocator, args, &parsed_ssh_args, &route_storage, true);
}

fn needsRemoteLocalArgs(parsed: ssh_client.SessionInvocation) bool {
    return isClientControlAction(parsed.action) and
        parsed.host.len > 0 and
        !std.mem.eql(u8, parsed.host, ".");
}

fn isClientControlAction(action: ssh_client.SessionAction) bool {
    return switch (action) {
        .detach_client, .repaint_client, .debug_client => true,
        .new, .attach, .list, .kill, .kill_all => false,
    };
}

fn remoteClientControlNeedsDefaultSession(parsed: ssh_client.SessionInvocation) bool {
    return parsed.client_session_ref == null and parsed.client_target != .client_guid;
}

fn invocationFromCommand(
    allocator: std.mem.Allocator,
    invocation: mux_cli.Command,
    route_storage: *?session_registry.Route,
) !ssh_client.SessionInvocation {
    return switch (invocation) {
        .new => |new| try mux_new.toInvocation(new),
        .attach => |attach| try mux_attach.toInvocation(allocator, attach, route_storage),
        .list => |list| try mux_list.toInvocation(list),
        .kill => |kill| try mux_kill.toInvocation(allocator, kill, route_storage),
        .detach => |control| try mux_detach.toInvocation(control),
        .repaint => |control| try mux_repaint.toInvocation(control),
        .debug => |debug| try mux_debug.toInvocation(debug),
    };
}

test "remote client-control default session is required unless targeting a client guid" {
    try std.testing.expect(remoteClientControlNeedsDefaultSession(.{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .client_target = .last_input,
    }));
    try std.testing.expect(!remoteClientControlNeedsDefaultSession(.{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .client_target = .last_input,
        .client_session_ref = "s1",
    }));
    try std.testing.expect(!remoteClientControlNeedsDefaultSession(.{
        .options = &.{},
        .host = "example.com",
        .action = .debug_client,
        .client_target = .client_guid,
        .client_guid = "c-00000000-0000-4000-8000-000000000001",
    }));
}
