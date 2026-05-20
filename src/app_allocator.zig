const std = @import("std");
const builtin = @import("builtin");

const use_debug_allocator = builtin.mode == .Debug and !builtin.is_test;

var debug_allocator: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void =
    if (use_debug_allocator) .init else {};

pub fn allocator() std.mem.Allocator {
    if (comptime builtin.is_test) return std.testing.allocator;
    if (comptime use_debug_allocator) return debug_allocator.allocator();
    return std.heap.smp_allocator;
}

pub fn deinit() void {
    if (comptime use_debug_allocator) {
        if (debug_allocator.deinit() == .leak) {
            std.debug.print("sessh: memory leaks detected\n", .{});
            std.process.exit(1);
        }
    }
}
