const std = @import("std");

pub fn cloneOwned(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer freeItems(allocator, result[0..initialized]);
    for (values, 0..) |value, i| {
        result[i] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

pub fn freeOwned(allocator: std.mem.Allocator, values: []const []const u8) void {
    freeItems(allocator, values);
    if (values.len != 0) allocator.free(values);
}

pub fn freeItems(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

test "cloneOwned duplicates each item and freeOwned releases the slice" {
    const allocator = std.testing.allocator;
    const input = [_][]const u8{ "alpha", "beta" };

    const cloned = try cloneOwned(allocator, &input);
    defer freeOwned(allocator, cloned);

    try std.testing.expectEqual(@as(usize, 2), cloned.len);
    try std.testing.expectEqualStrings("alpha", cloned[0]);
    try std.testing.expectEqualStrings("beta", cloned[1]);
    try std.testing.expect(cloned[0].ptr != input[0].ptr);
    try std.testing.expect(cloned[1].ptr != input[1].ptr);
}
