const std = @import("std");

const daemon_cleanup = @import("../daemon/cleanup.zig");
const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const Remote = struct {
    process: daemon_cleanup.RemoteProcessIdentity,
    guid: []u8,

    pub const Parts = struct {
        process: daemon_cleanup.RemoteProcessIdentity,
        guid: []const u8,

        pub fn fromProto(process: pb.DaemonTunnelItem.RemoteProcessIdentity) Parts {
            return .{
                .process = daemon_cleanup.RemoteProcessIdentity.fromProto(process),
                .guid = process.guid,
            };
        }

        pub fn fromRecord(record: daemon_cleanup.Record) Parts {
            return .{
                .process = record.remote,
                .guid = record.guid,
            };
        }

        pub fn toProto(self: Parts) pb.DaemonTunnelItem.RemoteProcessIdentity {
            return self.process.toProto(self.guid);
        }
    };

    pub fn fromParts(allocator: std.mem.Allocator, remote_parts: Parts) !Remote {
        var process = try daemon_cleanup.RemoteProcessIdentity.clone(allocator, remote_parts.process);
        errdefer process.deinit(allocator);
        const guid = try allocator.dupe(u8, remote_parts.guid);
        errdefer allocator.free(guid);
        return .{
            .process = process,
            .guid = guid,
        };
    }

    pub fn fromProto(allocator: std.mem.Allocator, process: pb.DaemonTunnelItem.RemoteProcessIdentity) !Remote {
        return fromParts(allocator, Parts.fromProto(process));
    }

    pub fn clone(allocator: std.mem.Allocator, remote: Remote) !Remote {
        return fromParts(allocator, remote.parts());
    }

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        self.process.deinit(allocator);
        allocator.free(self.guid);
        self.* = undefined;
    }

    pub fn parts(self: Remote) Parts {
        return .{
            .process = self.process,
            .guid = self.guid,
        };
    }

    pub fn toProto(self: Remote) pb.DaemonTunnelItem.RemoteProcessIdentity {
        return self.parts().toProto();
    }
};

pub const PendingRequest = struct {
    remote: Remote,

    pub fn fromRemote(allocator: std.mem.Allocator, remote: Remote) !PendingRequest {
        return .{ .remote = try Remote.clone(allocator, remote) };
    }

    pub fn fromRecord(allocator: std.mem.Allocator, record: daemon_cleanup.Record) !PendingRequest {
        return .{ .remote = try Remote.fromParts(allocator, Remote.Parts.fromRecord(record)) };
    }

    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        self.remote.deinit(allocator);
        self.* = undefined;
    }
};

test "pending cleanup request owns a copy of remote identity fields" {
    var remote = try Remote.fromParts(std.testing.allocator, .{
        .process = .{
            .pid = 42,
            .start_time = "start-a",
            .socket_path = "/tmp/sesshd.sock",
        },
        .guid = "s-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    });
    defer remote.deinit(std.testing.allocator);

    var pending = try PendingRequest.fromRemote(std.testing.allocator, remote);
    defer pending.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 42), pending.remote.process.pid);
    try std.testing.expectEqualStrings(remote.process.start_time, pending.remote.process.start_time);
    try std.testing.expectEqualStrings(remote.process.socket_path, pending.remote.process.socket_path);
    try std.testing.expectEqualStrings(remote.guid, pending.remote.guid);
    try std.testing.expect(remote.process.start_time.ptr != pending.remote.process.start_time.ptr);
    try std.testing.expect(remote.process.socket_path.ptr != pending.remote.process.socket_path.ptr);
    try std.testing.expect(remote.guid.ptr != pending.remote.guid.ptr);
}
