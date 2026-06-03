const std = @import("std");

pub const version = "0.7.0-dev";

pub const default_scrollback_row_count = 2000;
pub const default_debug_unresponsive_seconds = 10;
pub const default_connection_diagnostics: ConnectionDiagnostics = .overlay;

pub const session_guid_env = "SESSH_GUID";
pub const client_version_env = "SESSH_CLIENT_VERSION";
pub const compat_env = "SESSH_COMPAT";

pub const protocol_major = 3;
pub const protocol_minor = 0;
pub const min_protocol_major = 3;
pub const min_protocol_minor = 0;

pub const ConnectionDiagnostics = enum {
    none,
    unhygienic,
    hygienic,
    overlay,

    pub fn label(self: ConnectionDiagnostics) []const u8 {
        return switch (self) {
            .none => "none",
            .unhygienic => "unhygienic",
            .hygienic => "hygienic",
            .overlay => "overlay",
        };
    }
};

pub fn parseConnectionDiagnostics(value: []const u8) !ConnectionDiagnostics {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "unhygienic")) return .unhygienic;
    if (std.ascii.eqlIgnoreCase(value, "hygienic")) return .hygienic;
    if (std.ascii.eqlIgnoreCase(value, "overlay")) return .overlay;
    return error.InvalidConnectionDiagnostics;
}
