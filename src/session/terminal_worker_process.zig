const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const guid_ref = @import("../core/guid.zig");
const terminal_worker = @import("terminal_worker.zig");
const worker_process = @import("../core/worker_process.zig");

var terminal_remote_socket_sequence: u64 = 0;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var listener = try worker_process.prepareInheritedListener(allocator, .{
        .args = args,
        .expected_arg_count = 3,
        .invalid_args_error = error.InvalidTerminalRemoteArgs,
    });
    defer listener.deinit();
    const session_guid = args[2];

    try terminal_worker.runTerminalWorkerLoop(session_guid, listener.fd);
}

pub fn start(allocator: std.mem.Allocator, exe: []const u8, session_guid: []const u8) !*terminal_worker.TerminalWorkerHandle {
    var guid: ?[]u8 = try guid_ref.canonicalSessionGuid(allocator, session_guid);
    errdefer if (guid) |owned_guid| allocator.free(owned_guid);

    var socket_path: ?[]u8 = try terminalWorkerSocketPath(allocator, exe);
    errdefer if (socket_path) |owned_socket_path| allocator.free(owned_socket_path);
    const control = try allocator.create(terminal_worker.TerminalWorkerHandle);
    errdefer allocator.destroy(control);
    control.* = terminal_worker.TerminalWorkerHandle.initOwnedProcess(allocator, guid.?, socket_path.?);
    guid = null;
    socket_path = null;
    errdefer control.deinit(null);

    try terminal_worker.registerTerminalWorker(control);
    errdefer terminal_worker.unregisterTerminalWorker(control);

    const process_id = try worker_process.spawnWithInheritedListener(allocator, .{
        .exe = exe,
        .socket_path = control.processSocketPath() orelse return error.MissingTerminalWorkerProcess,
        .args_after_socket_path = &.{control.guid},
    });
    control.setProcessPid(@intCast(process_id));
    return control;
}

fn terminalWorkerSocketPath(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    const sequence = terminal_remote_socket_sequence;
    terminal_remote_socket_sequence +%= 1;
    const socket_file_name = try std.fmt.allocPrint(allocator, "terminal-{}-{}.sock", .{ c.getpid(), sequence });
    defer allocator.free(socket_file_name);
    return worker_process.namespaceSocketPath(allocator, exe, socket_file_name);
}

test "terminal worker socket path uses short sessh runtime dir" {
    const allocator = std.testing.allocator;
    const exe = "/tmp/sessh-ssh-reconnect-tmux-abcdefgh/sessh-test-root/runtime.remote/3.dev.abcdef12/sessh-terminal-remote";
    const path = try terminalWorkerSocketPath(allocator, exe);
    defer allocator.free(path);

    const socket_transport = @import("../transport/socket.zig");
    const root = try socket_transport.shortSesshRuntimeDir(allocator);
    defer allocator.free(root);
    const expected_prefix = try std.fmt.allocPrint(allocator, "{s}/3.dev.abcdef12/terminal-", .{root});
    defer allocator.free(expected_prefix);

    const addr: c.sockaddr.un = undefined;
    try std.testing.expect(std.mem.startsWith(u8, path, expected_prefix));
    try std.testing.expect(path.len < addr.path.len);
}
