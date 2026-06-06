const std = @import("std");

pub fn start(allocator: std.mem.Allocator, exe: []const u8) !std.process.Child {
    const argv = try allocator.alloc([]const u8, 2);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = ":internal-session-broker:";
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

pub fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

pub fn terminateChild(child: *std.process.Child) void {
    closeChildStdin(child);
    if (child.kill()) |_| return else |_| {}
    _ = child.wait() catch {};
}
