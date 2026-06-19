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

pub fn spawnWithInheritedListener(
    allocator: std.mem.Allocator,
    options: SpawnWithInheritedListenerOptions,
) !std.process.Child.Id {
    try socket_transport.ensureSocketDir(allocator, options.socket_path);
    const listen_fd = try socket_transport.listenSocket(options.socket_path);
    errdefer _ = c.close(listen_fd);
    try socket_transport.clearCloseOnExec(listen_fd);

    const listen_fd_arg = try std.fmt.allocPrint(allocator, "{}", .{listen_fd});
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

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = c.close(listen_fd);
    return child.id;
}
