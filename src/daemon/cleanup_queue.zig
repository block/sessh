// In-memory cleanup delivery queue for one pooled daemon-to-daemon transport.
// Durable cleanup records live in cleanup.zig; this type only tracks requests
// that have been selected for delivery on an already chosen SSH transport.
const std = @import("std");

const cleanup_identity = @import("../session/cleanup_identity.zig");
const daemon_cleanup = @import("cleanup.zig");

pub const PendingRequest = cleanup_identity.PendingRequest;
pub const Remote = cleanup_identity.Remote;

pub const Queue = struct {
    pending: std.ArrayList(PendingRequest) = .empty,
    in_flight: usize = 0,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        for (self.pending.items) |*request| request.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = .{};
    }

    pub fn hasWork(self: *const Queue) bool {
        return self.pending.items.len != 0 or self.in_flight != 0;
    }

    pub fn hasInFlight(self: *const Queue) bool {
        return self.in_flight != 0;
    }

    pub fn inFlightCount(self: *const Queue) usize {
        return self.in_flight;
    }

    pub fn enqueueRecord(self: *Queue, allocator: std.mem.Allocator, record: daemon_cleanup.Record) !void {
        var pending = try PendingRequest.fromRecord(allocator, record);
        errdefer pending.deinit(allocator);
        try self.pending.append(allocator, pending);
        pending = undefined;
    }

    pub fn enqueueRemote(self: *Queue, allocator: std.mem.Allocator, remote: Remote) !void {
        var pending = try PendingRequest.fromRemote(allocator, remote);
        errdefer pending.deinit(allocator);
        try self.pending.append(allocator, pending);
        pending = undefined;
    }

    pub fn popPending(self: *Queue) ?PendingRequest {
        if (self.pending.items.len == 0) return null;
        return self.pending.orderedRemove(0);
    }

    pub fn noteStarted(self: *Queue) void {
        self.in_flight += 1;
    }

    pub fn noteResponse(self: *Queue) void {
        if (self.in_flight != 0) self.in_flight -= 1;
    }
};

test "cleanup queue owns pending request copies" {
    var queue = Queue{};
    defer queue.deinit(std.testing.allocator);

    var remote = try Remote.fromParts(std.testing.allocator, .{
        .process = .{
            .pid = 42,
            .start_time = "start-a",
            .socket_path = "/tmp/sesshd.sock",
        },
        .guid = "s-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    });
    defer remote.deinit(std.testing.allocator);

    try queue.enqueueRemote(std.testing.allocator, remote);
    try std.testing.expect(queue.hasWork());
    var pending = queue.popPending() orelse return error.ExpectedPendingCleanup;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(remote.guid, pending.remote.guid);
    try std.testing.expect(remote.guid.ptr != pending.remote.guid.ptr);
}
