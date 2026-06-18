const std = @import("std");

pub const hpb = @import("../proto/sessh/handshake/v1.pb.zig");

pub fn helloRequestIsCompatible(
    hello: hpb.HelloRequest,
    min_major: u32,
    min_minor: u32,
) bool {
    return hello.protocol_major > min_major or
        (hello.protocol_major == min_major and hello.protocol_minor >= min_minor);
}

test "hello compatibility accepts peer max protocol when it satisfies local minimum" {
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 9,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(!helloRequestIsCompatible(.{
        .protocol_major = 2,
        .protocol_minor = 4,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 4,
        .protocol_minor = 0,
        .version = "0.5.0-dev",
    }, 3, 0));
    try std.testing.expect(helloRequestIsCompatible(.{
        .protocol_major = 3,
        .protocol_minor = 1,
        .version = "0.6.0-dev",
    }, 3, 0));
}
