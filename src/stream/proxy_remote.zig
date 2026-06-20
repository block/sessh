const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const guid_ref = @import("../core/guid.zig");
const process_wait = @import("../core/waitpid.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const socket_transport = @import("../transport/socket.zig");
const worker_process = @import("../core/worker_process.zig");

// `sessh-proxy-remote` is the remote endpoint for one proxy byte stream. The
// local helper is `sessh-proxy`; this module only tracks/connects the remote
// process that opens localhost:sshd on the far side of the daemon tunnel.

pub const Process = struct {
    allocator: std.mem.Allocator,
    endpoint: ProcessEndpoint,
    identity: ?OwnedProcessIdentity = null,
    owned_process: bool = false,

    fn deinit(self: *Process) void {
        self.endpoint.deinit(self.allocator);
        if (self.identity) |*identity| identity.deinit(self.allocator);
        self.* = undefined;
    }
};

const ProcessEndpoint = struct {
    guid: []u8,
    socket_path: []u8,

    fn clone(allocator: std.mem.Allocator, guid: []const u8, socket_path: []const u8) !ProcessEndpoint {
        const owned_guid = try allocator.dupe(u8, guid);
        errdefer allocator.free(owned_guid);
        const owned_socket_path = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(owned_socket_path);
        return .{
            .guid = owned_guid,
            .socket_path = owned_socket_path,
        };
    }

    fn deinit(self: *ProcessEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.guid);
        allocator.free(self.socket_path);
        self.* = undefined;
    }
};

test "proxy remote process endpoint owns guid and socket path" {
    const guid = "p-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const socket_path = "/tmp/sessh-proxy.sock";

    var endpoint = try ProcessEndpoint.clone(std.testing.allocator, guid, socket_path);
    defer endpoint.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(guid, endpoint.guid);
    try std.testing.expectEqualStrings(socket_path, endpoint.socket_path);
    try std.testing.expect(guid.ptr != endpoint.guid.ptr);
    try std.testing.expect(socket_path.ptr != endpoint.socket_path.ptr);
}

const ProcessIdentityJson = struct {
    pid: u64,
    start_time: []const u8,
};

const OwnedProcessIdentity = struct {
    pid: c.pid_t,
    start_time: []u8,

    fn deinit(self: *OwnedProcessIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.start_time);
        self.* = undefined;
    }
};

// PROCESS_GLOBAL_REGISTRY: the local daemon tracks process-isolated proxy
// workers here so shutdown and cleanup can see whether useful proxy work still
// exists. The daemon is single-threaded; mutations happen from dispatcher-owned
// callbacks.
var processes: std.ArrayList(*Process) = .empty;

pub const ConnectOrStartOptions = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
};

pub fn connectOrStart(options: ConnectOrStartOptions) !*Process {
    const allocator = options.allocator;
    pruneExited();
    const canonical = try guid_ref.canonicalProxyGuid(allocator, options.guid);
    defer allocator.free(canonical);

    if (lookup(canonical)) |control| {
        daemon_log.infof(allocator, "proxy remote reusing registered process guid={s}", .{canonical});
        return control;
    }

    const socket_path = try socketPath(allocator, options.exe, canonical);
    defer allocator.free(socket_path);

    if (connectProcessPath(socket_path)) |fd| {
        _ = c.close(fd);
        daemon_log.infof(allocator, "proxy remote rediscovered process guid={s}", .{canonical});
        return registerExisting(allocator, canonical, socket_path);
    } else |err| switch (err) {
        error.SocketDirMissing, error.SocketPathMissing, error.ConnectFailed => {},
        else => return err,
    }

    daemon_log.infof(allocator, "proxy remote starting process guid={s}", .{canonical});
    return start(.{
        .allocator = allocator,
        .exe = options.exe,
        .guid = canonical,
        .socket_path = socket_path,
        .proxy_host = options.proxy_host,
        .proxy_port = options.proxy_port,
    });
}

pub fn connectStarted(control: *Process) !c.fd_t {
    return connectProcess(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forget(control.endpoint.guid);
            return error.StreamNotFound;
        },
        else => return err,
    };
}

pub fn requestCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    const canonical = try guid_ref.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);
    const control = lookup(canonical) orelse return error.StreamNotFound;
    // Cleanup records only need to prove that we attempted to hang up the
    // recorded remote resource. For proxy workers, closing the worker process
    // closes its localhost:sshd connection; sending it a framed reset first
    // would block the daemon and is redundant with the signal below.
    terminateAndForget(control);
}

test "proxy remote cleanup terminates registered process without framed reset" {
    const TestRegistry = struct {
        fn clear() void {
            while (processes.items.len != 0) {
                removeAt(0, .forget);
            }
            processes.deinit(app_allocator.allocator());
            processes = .empty;
        }
    };

    TestRegistry.clear();
    defer TestRegistry.clear();

    const guid = "p-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const socket_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/sessh-proxy-remote-cleanup-test-{}.sock",
        .{c.getpid()},
    );
    defer std.testing.allocator.free(socket_path);
    const control = try std.testing.allocator.create(Process);
    var control_initialized = false;
    var test_owns_control = true;
    defer if (test_owns_control) {
        if (control_initialized) control.deinit();
        std.testing.allocator.destroy(control);
    };
    var endpoint = try ProcessEndpoint.clone(std.testing.allocator, guid, socket_path);
    control.* = .{
        .allocator = std.testing.allocator,
        .endpoint = endpoint,
    };
    control_initialized = true;
    endpoint = undefined;
    try register(control);
    test_owns_control = false;

    try std.testing.expectEqual(@as(usize, 1), activeCount());
    try requestCleanup(std.testing.allocator, guid);
    try std.testing.expectEqual(@as(usize, 0), activeCount());
}

fn forget(guid: []const u8) void {
    for (processes.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.endpoint.guid, guid)) {
            removeAt(index, .forget);
            return;
        }
    }
}

pub fn terminate(guid: []const u8) void {
    for (processes.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.endpoint.guid, guid)) {
            removeAt(index, .terminate);
            return;
        }
    }
}

pub fn activeCount() usize {
    pruneExited();
    return processes.items.len;
}

fn connectProcess(control: *const Process) !c.fd_t {
    return connectProcessPath(control.endpoint.socket_path);
}

fn connectProcessPath(socket_path: []const u8) !c.fd_t {
    return socket_transport.connectSocket(socket_path);
}

const StartOptions = struct {
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    socket_path: []u8,
    proxy_host: []const u8,
    proxy_port: u16,
};

fn start(options: StartOptions) !*Process {
    const allocator = options.allocator;
    const control = try allocator.create(Process);
    errdefer allocator.destroy(control);
    var endpoint = try ProcessEndpoint.clone(allocator, options.guid, options.socket_path);
    errdefer endpoint.deinit(allocator);
    control.* = .{
        .allocator = allocator,
        .endpoint = endpoint,
    };

    try register(control);
    errdefer unregister(control);

    const port_arg = try std.fmt.allocPrint(allocator, "{}", .{options.proxy_port});
    defer allocator.free(port_arg);
    const process_id = try worker_process.spawnWithInheritedListener(allocator, .{
        .exe = options.exe,
        .socket_path = options.socket_path,
        .args_after_socket_path = &.{ options.guid, options.proxy_host, port_arg },
    });
    errdefer posix.kill(@intCast(process_id), posix.SIG.HUP) catch {};
    const pid: c.pid_t = @intCast(process_id);
    control.owned_process = true;
    var identity = try processIdentityForPid(allocator, pid);
    errdefer identity.deinit(allocator);
    try writeIdentityFile(allocator, control.endpoint.socket_path, identity);
    control.identity = identity;
    return control;
}

fn registerExisting(
    allocator: std.mem.Allocator,
    guid: []u8,
    socket_path: []u8,
) !*Process {
    const control = try allocator.create(Process);
    errdefer allocator.destroy(control);
    var endpoint = try ProcessEndpoint.clone(allocator, guid, socket_path);
    errdefer endpoint.deinit(allocator);
    control.* = .{
        .allocator = allocator,
        .endpoint = endpoint,
    };
    if (readIdentityFile(allocator, socket_path)) |identity| {
        control.identity = identity;
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidProcessIdentity => {},
        else => return err,
    }

    try register(control);
    return control;
}

fn socketPath(allocator: std.mem.Allocator, exe: []const u8, guid: []const u8) ![]u8 {
    const socket_file_name = try std.fmt.allocPrint(allocator, "proxy-{s}.sock", .{guid});
    defer allocator.free(socket_file_name);
    return worker_process.namespaceSocketPath(allocator, exe, socket_file_name);
}

fn register(control: *Process) !void {
    for (processes.items) |existing| {
        if (std.mem.eql(u8, existing.endpoint.guid, control.endpoint.guid)) return error.StreamExists;
    }
    try processes.append(app_allocator.allocator(), control);
}

fn unregister(control: *Process) void {
    for (processes.items, 0..) |existing, index| {
        if (existing == control) {
            _ = processes.orderedRemove(index);
            return;
        }
    }
}

fn terminateAndForget(control: *Process) void {
    for (processes.items, 0..) |existing, index| {
        if (existing == control) {
            removeAt(index, .terminate);
            return;
        }
    }
}

const RemoveProcessMode = enum {
    forget,
    terminate,
};

fn removeAt(index: usize, mode: RemoveProcessMode) void {
    const control = processes.orderedRemove(index);
    if (mode == .terminate) {
        std.fs.deleteFileAbsolute(control.endpoint.socket_path) catch {};
        deleteIdentityFile(control.allocator, control.endpoint.socket_path);
        signalProcess(control);
    }
    if (control.owned_process) {
        if (control.identity) |identity| _ = reapChild(identity.pid);
    }
    const allocator = control.allocator;
    control.deinit();
    allocator.destroy(control);
}

fn lookup(guid: []const u8) ?*Process {
    for (processes.items) |control| {
        if (std.mem.eql(u8, control.endpoint.guid, guid)) return control;
    }
    return null;
}

fn pruneExited() void {
    var index: usize = 0;
    while (index < processes.items.len) {
        const control = processes.items[index];
        if (processExited(control)) {
            _ = processes.orderedRemove(index);
            std.fs.deleteFileAbsolute(control.endpoint.socket_path) catch {};
            deleteIdentityFile(control.allocator, control.endpoint.socket_path);
            const allocator = control.allocator;
            control.deinit();
            allocator.destroy(control);
            continue;
        }
        index += 1;
    }
}

fn processExited(control: *Process) bool {
    const identity = control.identity orelse return false;
    if (control.owned_process) return reapChild(identity.pid);
    return !daemon_identity.processIdentityMatches(control.allocator, @intCast(identity.pid), identity.start_time);
}

fn signalProcess(control: *Process) void {
    const identity = control.identity orelse return;
    if (!control.owned_process) {
        if (!daemon_identity.processIdentityMatches(control.allocator, @intCast(identity.pid), identity.start_time)) return;
    }
    posix.kill(identity.pid, posix.SIG.HUP) catch {};
}

fn reapChild(pid: c.pid_t) bool {
    if (pid == 0) return false;
    if (pid < 0) return true;
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, process_wait.nohang);
    if (result == pid) return true;
    if (result < 0) return switch (posix.errno(result)) {
        .CHILD => true,
        else => false,
    };
    return false;
}

fn identityPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid.json", .{socket_path});
}

fn writeIdentityFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    identity: OwnedProcessIdentity,
) !void {
    const path = try identityPath(allocator, socket_path);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, c.getpid() });
    defer allocator.free(tmp_path);

    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(ProcessIdentityJson{
        .pid = @intCast(identity.pid),
        .start_time = identity.start_time,
    }, .{}, &json_writer.writer);
    try json_writer.writer.writeByte('\n');
    const bytes = try json_writer.toOwnedSlice();
    defer allocator.free(bytes);

    var file = try std.fs.createFileAbsolute(tmp_path, .{
        .read = false,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.renameAbsolute(tmp_path, path);
}

fn readIdentityFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
) !OwnedProcessIdentity {
    const path = try identityPath(allocator, socket_path);
    defer allocator.free(path);
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(ProcessIdentityJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.pid == 0 or parsed.value.pid > @as(u64, @intCast(std.math.maxInt(c.pid_t)))) return error.InvalidProcessIdentity;
    var identity = try processIdentityForPid(allocator, @intCast(parsed.value.pid));
    errdefer identity.deinit(allocator);
    if (!std.mem.eql(u8, identity.start_time, parsed.value.start_time)) {
        return error.InvalidProcessIdentity;
    }
    return identity;
}

fn processIdentityForPid(allocator: std.mem.Allocator, pid: c.pid_t) !OwnedProcessIdentity {
    return .{
        .pid = pid,
        .start_time = try daemon_identity.processStartTime(allocator, @intCast(pid)),
    };
}

fn deleteIdentityFile(allocator: std.mem.Allocator, socket_path: []const u8) void {
    const path = identityPath(allocator, socket_path) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}
