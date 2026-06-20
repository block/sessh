const std = @import("std");
const c = std.c;
const posix = std.posix;

/// Small typed builder for foreground `poll(2)` wait sets.
///
/// Foreground process event loops often rebuild their `pollfd` array on each
/// state-machine step. Keeping the parallel fd and kind arrays in one type
/// prevents each loop from carrying its own version of that bookkeeping.
pub fn PollSet(comptime Kind: type, comptime max_fds: usize) type {
    return struct {
        fds: [max_fds]posix.pollfd = undefined,
        kinds: [max_fds]Kind = undefined,
        count: usize = 0,

        pub fn add(self: *@This(), fd: c.fd_t, events: i16, kind: Kind) void {
            std.debug.assert(self.count < max_fds);
            self.fds[self.count] = .{ .fd = fd, .events = events, .revents = 0 };
            self.kinds[self.count] = kind;
            self.count += 1;
        }

        pub fn fdSlice(self: *@This()) []posix.pollfd {
            return self.fds[0..self.count];
        }

        pub fn kindSlice(self: *@This()) []Kind {
            return self.kinds[0..self.count];
        }
    };
}

test "PollSet keeps fds and event kinds aligned" {
    const Kind = enum { left, right };
    var set = PollSet(Kind, 2){};

    set.add(10, posix.POLL.IN, .left);
    set.add(11, posix.POLL.OUT, .right);

    try std.testing.expectEqual(@as(usize, 2), set.count);
    try std.testing.expectEqual(@as(c.fd_t, 10), set.fdSlice()[0].fd);
    try std.testing.expectEqual(@as(i16, posix.POLL.IN), set.fdSlice()[0].events);
    try std.testing.expectEqual(Kind.left, set.kindSlice()[0]);
    try std.testing.expectEqual(@as(c.fd_t, 11), set.fdSlice()[1].fd);
    try std.testing.expectEqual(@as(i16, posix.POLL.OUT), set.fdSlice()[1].events);
    try std.testing.expectEqual(Kind.right, set.kindSlice()[1]);
}
