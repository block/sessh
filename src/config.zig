const std = @import("std");

pub const version = "0.7.0-dev";

pub const default_scrollback_row_count = 2000;
pub const default_debug_unresponsive_seconds = 10;
pub const default_filter_level: FilterLevel = .emulated;

pub const session_guid_env = "SESSH_GUID";
pub const client_version_env = "SESSH_CLIENT_VERSION";
pub const compat_env = "SESSH_COMPAT";

pub const protocol_major = 3;
pub const protocol_minor = 0;
pub const min_protocol_major = 3;
pub const min_protocol_minor = 0;

pub const FilterLevel = enum {
    raw,
    unhygienic,
    hygienic,
    emulated,

    pub fn label(self: FilterLevel) []const u8 {
        return switch (self) {
            .raw => "raw",
            .unhygienic => "unhygienic",
            .hygienic => "hygienic",
            .emulated => "emulated",
        };
    }
};

pub fn parseFilterLevel(value: []const u8) !FilterLevel {
    if (std.ascii.eqlIgnoreCase(value, "raw")) return .raw;
    if (std.ascii.eqlIgnoreCase(value, "unhygienic")) return .unhygienic;
    if (std.ascii.eqlIgnoreCase(value, "hygienic")) return .hygienic;
    if (std.ascii.eqlIgnoreCase(value, "emulated")) return .emulated;
    return error.InvalidFilterLevel;
}
