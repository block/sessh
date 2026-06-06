const std = @import("std");

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stderr);
        allocator.free(self.stdout);
        self.* = undefined;
    }
};

pub const Runner = struct {
    context: *anyopaque,
    runFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) anyerror!Result,

    pub fn run(
        self: *Runner,
        allocator: std.mem.Allocator,
        host: []const u8,
        ssh_options: []const []const u8,
        argv: []const []const u8,
    ) !Result {
        return self.runFn(self.context, allocator, host, ssh_options, argv);
    }
};
