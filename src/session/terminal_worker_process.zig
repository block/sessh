const std = @import("std");
const c = std.c;

const app_allocator = @import("../core/app_allocator.zig");
const core_fds = @import("../core/fds.zig");
const guid_ref = @import("../core/guid.zig");
const socket_transport = @import("../transport/socket.zig");
const terminal_worker = @import("terminal_worker.zig");

var terminal_remote_socket_sequence: u64 = 0;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    if (args.len != 3) return error.InvalidTerminalRemoteArgs;
    const listen_fd = try std.fmt.parseInt(c.fd_t, args[0], 10);
    const socket_path = args[1];
    const session_guid = args[2];
    core_fds.closeInheritedNonStdioFileDescriptorsExcept(listen_fd);
    socket_transport.publishSesshRuntimeDirSymlinkOnce(app_allocator.allocator());
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    try terminal_worker.runTerminalWorkerLoop(session_guid, listen_fd);
}

pub fn start(allocator: std.mem.Allocator, exe: []const u8, session_guid: []const u8) !*terminal_worker.TerminalWorkerHandle {
    const guid = try guid_ref.canonicalSessionGuid(allocator, session_guid);
    errdefer allocator.free(guid);

    const socket_path = try terminalRemoteSocketPath(allocator, exe, "terminal");
    errdefer allocator.free(socket_path);
    try socket_transport.ensureSocketDir(allocator, socket_path);
    const listen_fd = try socket_transport.listenSocket(socket_path);
    errdefer _ = c.close(listen_fd);
    try socket_transport.clearCloseOnExec(listen_fd);

    const control = try allocator.create(terminal_worker.TerminalWorkerHandle);
    errdefer allocator.destroy(control);
    control.* = .{
        .allocator = allocator,
        .guid = guid,
        .kind = .{ .process = .{
            .socket_path = socket_path,
        } },
    };
    errdefer control.deinit(null);

    try terminal_worker.registerTerminalWorker(control);
    errdefer terminal_worker.unregisterTerminalWorker(control);

    const listen_fd_arg = try std.fmt.allocPrint(allocator, "{}", .{listen_fd});
    defer allocator.free(listen_fd_arg);
    const argv = [_][]const u8{ exe, listen_fd_arg, socket_path, guid };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = c.close(listen_fd);
    control.kind.process.pid = @intCast(child.id);
    return control;
}

fn terminalRemoteSocketPath(allocator: std.mem.Allocator, exe: []const u8, prefix: []const u8) ![]u8 {
    const exe_dir = std.fs.path.dirname(exe) orelse return error.InvalidRemoteProcessExecutablePath;
    const namespace = std.fs.path.basename(exe_dir);
    const root = try socket_transport.shortSesshRuntimeDir(allocator);
    defer allocator.free(root);
    const sequence = terminal_remote_socket_sequence;
    terminal_remote_socket_sequence +%= 1;
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}-{}-{}.sock", .{ root, namespace, prefix, c.getpid(), sequence });
}

test "terminal worker socket path uses short sessh runtime dir" {
    const allocator = std.testing.allocator;
    const exe = "/tmp/sessh-ssh-reconnect-tmux-abcdefgh/sessh-test-root/runtime.remote/3.dev.abcdef12/sessh-terminal-remote";
    const path = try terminalRemoteSocketPath(allocator, exe, "terminal");
    defer allocator.free(path);

    const root = try socket_transport.shortSesshRuntimeDir(allocator);
    defer allocator.free(root);
    const expected_prefix = try std.fmt.allocPrint(allocator, "{s}/3.dev.abcdef12/terminal-", .{root});
    defer allocator.free(expected_prefix);

    const addr: c.sockaddr.un = undefined;
    try std.testing.expect(std.mem.startsWith(u8, path, expected_prefix));
    try std.testing.expect(path.len < addr.path.len);
}
