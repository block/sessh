const std = @import("std");
const c = std.c;

const config = @import("../core/config.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const user_error = @import("../core/user_error.zig");
const client_config = @import("../session/client_config.zig");
const daemon_accept = @import("accept.zig");
const daemon_broker_bridge = @import("broker_bridge.zig");
const daemon_client = @import("client.zig");
const daemon_cleanup_scheduler = @import("cleanup_scheduler.zig");
const daemon_executable = @import("executable.zig");
const daemon_identity = @import("identity.zig");
const daemon_log = @import("log.zig");
const daemon_shutdown = @import("shutdown.zig");
const daemon_startup = @import("startup.zig");
const socket_namespace = @import("socket_namespace.zig");
const socket_transport = @import("../transport/socket.zig");

// PROCESS_GLOBAL_REGISTRY: the daemon accept loop increments this for each
// dispatcher-owned local client connection. Idle shutdown reads it to avoid
// exiting while a foreground client is still attached.
var active_local_clients: usize = 0;

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    return daemon_client.socketPath(allocator);
}

pub fn socketPathForDirName(allocator: std.mem.Allocator, dir_name: []const u8) ![]u8 {
    return daemon_client.socketPathForDirName(allocator, dir_name);
}

pub fn connect(allocator: std.mem.Allocator) !c.fd_t {
    return daemon_client.connect(allocator);
}

pub fn ensureStarted(allocator: std.mem.Allocator, exe: []const u8) !void {
    return daemon_client.ensureStarted(allocator, exe);
}

pub fn forwardBrokerToDaemon(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return daemon_broker_bridge.forwardBrokerToDaemon(allocator, exe, args);
}

pub fn reexecBrokerOrForward(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return daemon_broker_bridge.reexecBrokerOrForward(allocator, exe, args);
}

pub fn reexecDaemonOrRun(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.line(":daemon: accepts at most one daemon socket namespace");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var runtime_executables = try daemon_executable.installRuntimeExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer runtime_executables.deinit();
    return daemon_executable.reexec(allocator, runtime_executables.daemon, args);
}

pub fn run(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var ready_fd = daemon_startup.inheritedReadyFd();
    var startup_lock_fd = daemon_startup.inheritedStartupLockFd();
    defer {
        if (ready_fd >= 0) _ = c.close(ready_fd);
        daemon_startup.closeStartupLockFd(&startup_lock_fd);
    }
    core_fds.closeInheritedNonStdioFileDescriptorsExceptList(&.{ ready_fd, startup_lock_fd });

    if (args.len > 1) {
        try user_error.line(":daemon: accepts at most one daemon socket namespace");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    socket_transport.publishRuntimeRootSymlinkOnce(allocator);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    const identity = try daemon_identity.current(allocator, path);
    defer allocator.free(identity.start_time);

    var daemon_lock = try acquireDaemonSocketLock(allocator, dir_name, path);
    defer daemon_lock.deinit();
    var locked_runtime_executables = try daemon_executable.installRuntimeExecutablesWhileHoldingLock(allocator, exe, dir_name);
    defer locked_runtime_executables.deinit();

    const listen_fd = try socket_transport.listenSocket(path);
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(path) catch {};
    daemon_startup.signalReady(&ready_fd);
    daemon_startup.closeStartupLockFd(&startup_lock_fd);
    daemon_log.infof(allocator, "daemon started socket={s}", .{path});

    // PROCESS_DISPATCHER: sesshd has exactly one Dispatcher. Daemon helpers
    // receive this pointer when they need fd/timer events; they should not
    // construct nested dispatchers.
    var daemon_dispatcher = try dispatcher.Dispatcher.init(allocator);
    defer daemon_dispatcher.deinit();

    var accept_context = daemon_accept.Context{
        .allocator = allocator,
        .terminal_remote_exe = locked_runtime_executables.terminal_remote,
        .proxy_remote_exe = locked_runtime_executables.proxy_remote,
        .identity = identity,
        .listen_fd = listen_fd,
        .active_local_clients = &active_local_clients,
    };
    const file_config = client_config.loadFileConfig(allocator) catch client_config.FileConfig{};
    var cleanup_context = daemon_cleanup_scheduler.Context{
        .allocator = allocator,
        .daemon_dispatcher = &daemon_dispatcher,
        .cleanup_wakeup_interval_ms = file_config.cleanup_wakeup_interval_ms orelse config.default_cleanup_wakeup_interval_ms,
        .cleanup_retry_limit_ms = file_config.cleanup_retry_limit_ms orelse config.default_cleanup_retry_limit_ms,
    };
    defer cleanup_context.deinit();
    var idle_context = daemon_shutdown.initContext(allocator, &daemon_dispatcher, &cleanup_context, &active_local_clients);
    _ = try daemon_dispatcher.watchFd(listen_fd, .{ .readable = true }, .{
        .ctx = &accept_context,
        .callback = daemon_accept.acceptDaemonClient,
    });
    try daemon_shutdown.watchIdle(&idle_context, &daemon_dispatcher);
    try daemon_dispatcher.run();
}

const DaemonSocketLock = struct {
    file: std.fs.File,

    fn deinit(self: *DaemonSocketLock) void {
        std.posix.flock(self.file.handle, std.posix.LOCK.UN) catch {};
        self.file.close();
        self.* = undefined;
    }
};

// The lock file, not the socket path, serializes daemon ownership. A Unix
// socket pathname can briefly be stale, absent, or connected to a daemon that is
// already exiting; the lock gives startup and shutdown one shared ordering point.
fn acquireDaemonSocketLock(allocator: std.mem.Allocator, dir_name: []const u8, socket_path: []const u8) !DaemonSocketLock {
    try socket_transport.ensureSocketDir(allocator, socket_path);

    return tryAcquireDaemonSocketLock(allocator, socket_path) catch |err| switch (err) {
        error.DaemonLockBusy => lock_busy: {
            if (daemon_client.connectAndHandshakeForDirName(allocator, dir_name)) |fd| {
                _ = c.close(fd);
                return error.DaemonAlreadyRunning;
            } else |_| {}
            break :lock_busy error.DaemonLockBusy;
        },
        else => return err,
    };
}

fn tryAcquireDaemonSocketLock(allocator: std.mem.Allocator, socket_path: []const u8) !DaemonSocketLock {
    const lock_path = try daemonSocketLockPath(allocator, socket_path);
    defer allocator.free(lock_path);

    var file = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer file.close();
    try socket_transport.setCloseOnExec(file.handle);

    std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonLockBusy,
        else => return err,
    };
    return .{ .file = file };
}

fn daemonSocketLockPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, socket_path, '/') orelse return error.InvalidDaemonSocketPath;
    return std.fmt.allocPrint(allocator, "{s}/sesshd.lock", .{socket_path[0..slash]});
}

test "daemon socket path uses runtime root" {
    const allocator = std.testing.allocator;
    const path = try socketPathForDirName(allocator, "1.dev.abcdef12");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/1.dev.abcdef12/sesshd.sock"));
}
