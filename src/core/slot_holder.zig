const std = @import("std");

/// Reusable slot storage with stale-handle detection.
///
/// Dispatcher sources/sinks need stable handles because tasks store references
/// while the owning fd can be cancelled and a later fd may reuse the same slot.
/// Each slot carries a generation counter; releasing a handle increments that
/// generation, so old handles become harmlessly stale instead of accidentally
/// mutating a newly-created source or sink.
pub fn SlotHolder(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A non-owning reference to one active slot.
        ///
        /// `get()` returns null after the slot is released or reused with a new
        /// generation. That lets higher-level handle wrappers make `deinit()`
        /// idempotent without adding separate `*_initialized` booleans.
        pub const Handle = struct {
            holder: *Self,
            index: usize,
            generation: u64,

            pub fn get(self: Handle) ?*T {
                const slot = self.holder.slotForHandle(self) orelse return null;
                return &slot.value;
            }

            pub fn release(self: Handle) void {
                self.holder.release(self);
            }

            pub fn eql(self: Handle, other: Handle) bool {
                return self.holder == other.holder and
                    self.index == other.index and
                    self.generation == other.generation;
            }
        };

        const Slot = struct {
            generation: u64 = 0,
            active: bool = false,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free: std.ArrayList(usize) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.free.deinit(self.allocator);
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn add(self: *Self, value: T) !Handle {
            const reused = self.free.items.len != 0;
            const index = if (reused) self.free.items[self.free.items.len - 1] else self.slots.items.len;
            if (!reused) {
                try self.free.ensureTotalCapacity(self.allocator, index + 1);
            }
            if (reused) {
                _ = self.free.pop();
            } else {
                try self.slots.append(self.allocator, .{});
            }
            self.slots.items[index] = .{
                .generation = self.slots.items[index].generation,
                .active = true,
                .value = value,
            };
            return .{
                .holder = self,
                .index = index,
                .generation = self.slots.items[index].generation,
            };
        }

        pub fn release(self: *Self, handle: Handle) void {
            const slot = self.slotForHandle(handle) orelse return;
            slot.active = false;
            slot.generation +%= 1;
            self.free.appendAssumeCapacity(handle.index);
        }

        pub fn len(self: *const Self) usize {
            return self.slots.items.len;
        }

        pub fn valueAt(self: *Self, index: usize) ?*T {
            if (index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            if (!slot.active) return null;
            return &slot.value;
        }

        pub fn slotForHandle(self: *Self, handle: Handle) ?*Slot {
            if (handle.holder != self) return null;
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.active) return null;
            if (slot.generation != handle.generation) return null;
            return slot;
        }
    };
}

test "slot holder rejects stale handles after reuse" {
    var holder = SlotHolder(u8).init(std.testing.allocator);
    defer holder.deinit();

    const old = try holder.add(1);
    old.release();
    const new = try holder.add(2);

    try std.testing.expectEqual(old.index, new.index);
    try std.testing.expect(old.generation != new.generation);
    try std.testing.expect(old.get() == null);
    try std.testing.expectEqual(@as(u8, 2), new.get().?.*);
}
