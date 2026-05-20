const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ExitRequested};

const unwind_for_cleanup = builtin.is_test or builtin.mode == .Debug;

var requested_code: u8 = 0;

pub fn request(exit_code: u8) Error {
    if (comptime !unwind_for_cleanup) std.process.exit(exit_code);

    requested_code = exit_code;
    return error.ExitRequested;
}

pub fn code() u8 {
    return requested_code;
}

pub fn is(err: anyerror) bool {
    return err == error.ExitRequested;
}

test "request records exit code" {
    const err = request(42);
    try std.testing.expectEqual(error.ExitRequested, err);
    try std.testing.expectEqual(@as(u8, 42), code());
    try std.testing.expect(is(err));
}
