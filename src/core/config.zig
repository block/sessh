const std = @import("std");

pub const version = "0.7.0-dev";

pub const default_scrollback_row_count = 2000;
pub const default_ssh_port = "22";
pub const default_debug_unresponsive_seconds = 10;
pub const default_filter_level: FilterLevel = .emulated;
pub const default_diagnostics_level: DiagnosticsLevel = .overlay;
pub const default_isolation_mode: IsolationMode = .process;
pub const hour_ms: u64 = 60 * 60 * 1000;
pub const default_cleanup_wakeup_interval_ms: u64 = hour_ms;
pub const default_cleanup_retry_limit_ms: u64 = 168 * hour_ms;
pub const default_disconnected_reap_ms: u64 = 168 * hour_ms;

pub const session_guid_env = "SESSH_GUID";
pub const client_version_env = "SESSH_CLIENT_VERSION";

pub const protocol_major = 3;
pub const protocol_minor = 0;
pub const min_protocol_major = 3;
pub const min_protocol_minor = 0;

pub const FilterLevel = enum {
    unhygienic,
    hygienic,
    emulated,

    pub fn label(self: FilterLevel) []const u8 {
        return switch (self) {
            .unhygienic => "unhygienic",
            .hygienic => "hygienic",
            .emulated => "emulated",
        };
    }
};

pub fn parseFilterLevel(value: []const u8) !FilterLevel {
    if (std.ascii.eqlIgnoreCase(value, "unhygienic")) return .unhygienic;
    if (std.ascii.eqlIgnoreCase(value, "hygienic")) return .hygienic;
    if (std.ascii.eqlIgnoreCase(value, "emulated")) return .emulated;
    return error.InvalidFilterLevel;
}

pub const DiagnosticsLevel = enum {
    overlay,
    status,
    title,
    line,
    jsonl,

    pub fn label(self: DiagnosticsLevel) []const u8 {
        return switch (self) {
            .overlay => "overlay",
            .status => "status",
            .title => "title",
            .line => "line",
            .jsonl => "jsonl",
        };
    }
};

pub fn parseDiagnosticsLevel(value: []const u8) !DiagnosticsLevel {
    if (std.ascii.eqlIgnoreCase(value, "overlay")) return .overlay;
    if (std.ascii.eqlIgnoreCase(value, "status")) return .status;
    if (std.ascii.eqlIgnoreCase(value, "title")) return .title;
    if (std.ascii.eqlIgnoreCase(value, "line")) return .line;
    if (std.ascii.eqlIgnoreCase(value, "jsonl")) return .jsonl;
    return error.InvalidDiagnosticsLevel;
}

pub const IsolationMode = enum {
    full,
    process,
    none,

    pub fn label(self: IsolationMode) []const u8 {
        return switch (self) {
            .full => "full",
            .process => "process",
            .none => "none",
        };
    }
};

pub fn parseIsolationMode(value: []const u8) !IsolationMode {
    if (std.ascii.eqlIgnoreCase(value, "full")) return .full;
    if (std.ascii.eqlIgnoreCase(value, "process")) return .process;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    return error.InvalidIsolationMode;
}
