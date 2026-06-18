const std = @import("std");

const daemon_cleanup = @import("../daemon/cleanup.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const Remote = struct {
    pid: u64,
    start_time: []u8,
    daemon_socket_path: []u8,
    guid: []u8,

    pub fn fromProto(allocator: std.mem.Allocator, process: pb.DaemonTunnelItem.RemoteProcessIdentity) !Remote {
        const start_time = try allocator.dupe(u8, process.start_time);
        errdefer allocator.free(start_time);
        const daemon_socket_path = try allocator.dupe(u8, process.daemon_socket_path);
        errdefer allocator.free(daemon_socket_path);
        const guid = try allocator.dupe(u8, process.guid);
        errdefer allocator.free(guid);
        return .{
            .pid = process.pid,
            .start_time = start_time,
            .daemon_socket_path = daemon_socket_path,
            .guid = guid,
        };
    }

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        allocator.free(self.start_time);
        allocator.free(self.daemon_socket_path);
        allocator.free(self.guid);
        self.* = undefined;
    }

    pub fn toProto(self: Remote) pb.DaemonTunnelItem.RemoteProcessIdentity {
        return .{
            .pid = self.pid,
            .start_time = self.start_time,
            .daemon_socket_path = self.daemon_socket_path,
            .guid = self.guid,
        };
    }
};

pub const PendingRequest = struct {
    remote: Remote,

    pub fn fromRemote(allocator: std.mem.Allocator, remote: Remote) !PendingRequest {
        const start_time = try allocator.dupe(u8, remote.start_time);
        errdefer allocator.free(start_time);
        const daemon_socket_path = try allocator.dupe(u8, remote.daemon_socket_path);
        errdefer allocator.free(daemon_socket_path);
        const guid = try allocator.dupe(u8, remote.guid);
        errdefer allocator.free(guid);
        return .{ .remote = .{
            .pid = remote.pid,
            .start_time = start_time,
            .daemon_socket_path = daemon_socket_path,
            .guid = guid,
        } };
    }

    pub fn fromRecord(allocator: std.mem.Allocator, record: daemon_cleanup.Record) !PendingRequest {
        const start_time = try allocator.dupe(u8, record.remote_start_time);
        errdefer allocator.free(start_time);
        const daemon_socket_path = try allocator.dupe(u8, record.remote_socket_path);
        errdefer allocator.free(daemon_socket_path);
        const guid = try allocator.dupe(u8, record.guid);
        errdefer allocator.free(guid);
        return .{ .remote = .{
            .pid = record.remote_pid,
            .start_time = start_time,
            .daemon_socket_path = daemon_socket_path,
            .guid = guid,
        } };
    }

    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        self.remote.deinit(allocator);
        self.* = undefined;
    }
};
