const std = @import("std");
const c = std.c;

const core_fds = @import("fds.zig");
const socket_transport = @import("../transport/socket.zig");

pub const InheritedListener = struct {
    fd: c.fd_t,
    socket_path: []const u8,

    pub fn deinit(self: *InheritedListener) void {
        _ = c.close(self.fd);
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }
};

pub const InheritedListenerOptions = struct {
    args: []const []const u8,
    expected_arg_count: usize,
    invalid_args_error: anyerror,
};

pub fn prepareInheritedListener(
    allocator: std.mem.Allocator,
    options: InheritedListenerOptions,
) !InheritedListener {
    if (options.args.len != options.expected_arg_count) return options.invalid_args_error;
    const listen_fd = try std.fmt.parseInt(c.fd_t, options.args[0], 10);
    core_fds.closeInheritedNonStdioFileDescriptorsExcept(listen_fd);
    socket_transport.publishSesshRuntimeDirSymlinkOnce(allocator);
    return .{
        .fd = listen_fd,
        .socket_path = options.args[1],
    };
}

pub const SpawnWithInheritedListenerOptions = struct {
    exe: []const u8,
    socket_path: []const u8,
    args_after_socket_path: []const []const u8 = &.{},
};

pub fn namespaceSocketPath(
    allocator: std.mem.Allocator,
    exe: []const u8,
    socket_file_name: []const u8,
) ![]u8 {
    const exe_dir = std.fs.path.dirname(exe) orelse return error.InvalidRemoteProcessExecutablePath;
    const namespace = std.fs.path.basename(exe_dir);
    const root = try socket_transport.shortSesshRuntimeDir(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root, namespace, socket_file_name });
}

pub fn spawnWithInheritedListener(
    allocator: std.mem.Allocator,
    options: SpawnWithInheritedListenerOptions,
) !std.process.Child.Id {
    try socket_transport.ensureSocketDir(allocator, options.socket_path);
    const listen_fd = try socket_transport.listenSocket(options.socket_path);
    var owned_listen_fd = core_fds.OwnedFd.init(listen_fd);
    defer owned_listen_fd.deinit();
    try socket_transport.clearCloseOnExec(owned_listen_fd.get());

    const listen_fd_arg = try std.fmt.allocPrint(allocator, "{}", .{owned_listen_fd.get()});
    defer allocator.free(listen_fd_arg);

    const argv_len = 3 + options.args_after_socket_path.len;
    var argv = try allocator.alloc([]const u8, argv_len);
    defer allocator.free(argv);
    argv[0] = options.exe;
    argv[1] = listen_fd_arg;
    argv[2] = options.socket_path;
    for (options.args_after_socket_path, 0..) |arg, index| {
        argv[3 + index] = arg;
    }

    var worker_process = std.process.Child.init(argv, allocator);
    worker_process.stdin_behavior = .Ignore;
    worker_process.stdout_behavior = .Ignore;
    worker_process.stderr_behavior = .Ignore;
    try worker_process.spawn();
    owned_listen_fd.deinit();
    return worker_process.id;
}

test "worker namespace socket path uses executable namespace" {
    const allocator = std.testing.allocator;
    const exe = "/tmp/sessh-test-root/runtime.remote/3.dev.abcdef12/sessh-terminal-remote";
    const path = try namespaceSocketPath(allocator, exe, "terminal-123-0.sock");
    defer allocator.free(path);

    const root = try socket_transport.shortSesshRuntimeDir(allocator);
    defer allocator.free(root);
    const expected = try std.fmt.allocPrint(allocator, "{s}/3.dev.abcdef12/terminal-123-0.sock", .{root});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}
