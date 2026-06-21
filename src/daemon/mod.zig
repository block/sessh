// Main sesshd process loop. It claims the namespace lock, publishes role
// executables, accepts local clients, schedules cleanup maintenance, and exits
// once no live daemon work remains.
const std = @import("std");
const c = std.c;

const config = @import("../core/config.zig");
const core_blocking = @import("../core/blocking.zig");
const dispatcher = @import("../core/dispatcher.zig");
const core_fds = @import("../core/fds.zig");
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
// exiting while a foreground client is still connected.
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

pub fn ensureStarted(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8) !void {
    return daemon_client.ensureStarted(blocking, allocator, exe);
}

pub fn forwardBrokerToDaemon(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return daemon_broker_bridge.forwardBrokerToDaemon(blocking, allocator, exe, args);
}

pub fn reexecBrokerOrForward(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    return daemon_broker_bridge.reexecBrokerOrForward(blocking, allocator, exe, args);
}

pub fn reexecDaemonOrRun(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    if (args.len > 1) {
        try user_error.line(blocking, ":daemon: accepts at most one daemon socket namespace");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    var namespace_executables = try daemon_executable.installNamespaceExecutablesOrUseNamespaceOwner(allocator, exe, dir_name);
    defer namespace_executables.deinit();
    return daemon_executable.reexec(allocator, namespace_executables.daemon, args);
}

/// Run the daemon in its selected socket namespace. Startup keeps the namespace
/// lock until the listening socket, role symlinks, cleanup scheduler, and single
/// process-wide dispatcher are all installed, then exits only after idle
/// shutdown sees no clients, mux tunnels, or cleanup work.
pub fn run(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !void {
    var ready_fd = daemon_startup.inheritedReadyFd();
    var startup_lock_fd = daemon_startup.inheritedStartupLockFd();
    defer {
        if (ready_fd >= 0) _ = c.close(ready_fd);
        daemon_startup.closeStartupLockFd(&startup_lock_fd);
    }
    core_fds.closeInheritedNonStdioFileDescriptorsExceptList(&.{ ready_fd, startup_lock_fd });

    if (args.len > 1) {
        try user_error.line(blocking, ":daemon: accepts at most one daemon socket namespace");
        return error.InvalidDaemonArgs;
    }
    const dir_name = if (args.len == 1) args[0] else try socket_namespace.selectedDirName(allocator);
    defer if (args.len == 0) allocator.free(dir_name);

    socket_transport.publishSesshRuntimeDirSymlinkOnce(allocator);
    const path = try socketPathForDirName(allocator, dir_name);
    defer allocator.free(path);
    const identity = try daemon_identity.current(allocator, path);
    defer allocator.free(identity.start_time);

    var daemon_lock = try acquireDaemonSocketLock(blocking, allocator, dir_name, path);
    defer daemon_lock.deinit();
    var locked_namespace_executables = try daemon_executable.installNamespaceExecutablesWhileHoldingLock(allocator, exe, dir_name);
    defer locked_namespace_executables.deinit();

    const listen_fd = try socket_transport.listenSocket(path);
    defer _ = c.close(listen_fd);
    defer std.fs.deleteFileAbsolute(path) catch {};
    daemon_startup.signalReady(&ready_fd);
    daemon_startup.closeStartupLockFd(&startup_lock_fd);
    daemon_log.infof(allocator, "daemon started socket={s}", .{path});

    // sesshd has exactly one Dispatcher, initialized by
    // main before role dispatch. Daemon helpers receive this pointer when they
    // need fd/timer events; they should not construct nested dispatchers.
    const daemon_dispatcher = dispatcher.get();

    var accept_context = daemon_accept.Context{
        .blocking = blocking,
        .allocator = allocator,
        .terminal_remote_exe = locked_namespace_executables.terminal_remote,
        .proxy_remote_exe = locked_namespace_executables.proxy_remote,
        .identity = identity,
        .listen_fd = listen_fd,
        .active_local_clients = &active_local_clients,
    };
    accept_context.listen_source = try daemon_dispatcher.fdSource(listen_fd, .{ .readable = true });
    defer accept_context.listen_source.deinit();
    accept_context.listen_task = try dispatcher.fdDispatchTask(
        daemon_accept.Context,
        allocator,
        &accept_context,
        accept_context.listen_source,
        daemon_accept.acceptDaemonClient,
    );
    defer accept_context.listen_task.deinit();
    const file_config = client_config.loadFileConfig(allocator) catch client_config.FileConfig{};
    var cleanup_context = daemon_cleanup_scheduler.Context{
        .allocator = allocator,
        .daemon_dispatcher = daemon_dispatcher,
        .cleanup_wakeup_interval_ms = file_config.cleanup_wakeup_interval_ms orelse config.default_cleanup_wakeup_interval_ms,
        .cleanup_retry_limit_ms = file_config.cleanup_retry_limit_ms orelse config.default_cleanup_retry_limit_ms,
    };
    defer cleanup_context.deinit();
    var idle_context = daemon_shutdown.Context{
        .allocator = allocator,
        .cleanup_context = &cleanup_context,
        .active_local_clients = &active_local_clients,
        .last_live_work_ms = daemon_dispatcher.nowMs(),
    };
    try accept_context.listen_task.schedule(daemon_dispatcher);
    try daemon_shutdown.watchIdle(&idle_context, daemon_dispatcher);
    try blocking.runLoop();
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
fn acquireDaemonSocketLock(blocking: core_blocking.Blocking, allocator: std.mem.Allocator, dir_name: []const u8, socket_path: []const u8) !DaemonSocketLock {
    try socket_transport.ensureSocketDir(allocator, socket_path);

    return tryAcquireDaemonSocketLock(allocator, socket_path) catch |err| switch (err) {
        error.DaemonLockBusy => lock_busy: {
            if (daemon_client.connectAndHandshakeForDirName(blocking, allocator, dir_name)) |fd| {
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

test "daemon socket path uses sessh runtime dir" {
    const allocator = std.testing.allocator;
    const path = try socketPathForDirName(allocator, "1.dev.abcdef12");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/1.dev.abcdef12/sesshd.sock"));
}
