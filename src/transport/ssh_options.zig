const std = @import("std");

const client_log = @import("../core/client_log.zig");
const session_registry = @import("../runtime/session_registry.zig");

const default_ipqos_option_prefix = "-oIPQoS=";
const ssh_config_query_max_output_bytes = 256 * 1024;

pub const SshTtyRequest = enum {
    none,
    requested,
    forced,
};

pub const ResolvedSshConfig = struct {
    user: []u8,
    hostname: []u8,
    port: []u8,
    ipqos: ?[]u8 = null,
    send_env: []const []const u8 = &.{},

    pub fn deinit(self: *ResolvedSshConfig, allocator: std.mem.Allocator) void {
        if (self.ipqos) |value| allocator.free(value);
        freeStringList(allocator, self.send_env);
        allocator.free(self.port);
        allocator.free(self.hostname);
        allocator.free(self.user);
        self.* = undefined;
    }

    pub fn defaultIpQosOption(self: *const ResolvedSshConfig, allocator: std.mem.Allocator) !?[]u8 {
        const value = self.ipqos orelse return null;
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ default_ipqos_option_prefix, value });
    }
};

pub fn classifySshOptions(
    options: []const []const u8,
    tty_request: *SshTtyRequest,
    proxy_required: *bool,
) !void {
    var i: usize = 0;
    while (i < options.len) {
        try consumeSshOption(options, &i, tty_request, proxy_required);
    }
}

pub fn resolveSshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) !ResolvedSshConfig {
    const output = querySshConfig(allocator, ssh_options, host) catch |err| {
        client_log.debug("event=ssh_config_query_failed host={s} error={t}", .{ host, err });
        return fallbackResolvedSshConfig(allocator, ssh_options, host);
    };
    defer allocator.free(output);
    return parseSshConfig(allocator, output, ssh_options, host) catch |err| {
        client_log.debug("event=ssh_config_parse_failed host={s} error={t}", .{ host, err });
        return fallbackResolvedSshConfig(allocator, ssh_options, host);
    };
}

fn fallbackResolvedSshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) !ResolvedSshConfig {
    const explicit_port = explicitSshPort(ssh_options) orelse session_registry.default_ssh_port;
    return .{
        .user = try fallbackSshUser(allocator),
        .hostname = try allocator.dupe(u8, host),
        .port = try allocator.dupe(u8, explicit_port),
        .ipqos = null,
        .send_env = &.{},
    };
}

fn fallbackSshUser(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "USER") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, ""),
        else => return err,
    };
}

fn querySshConfig(allocator: std.mem.Allocator, ssh_options: []const []const u8, host: []const u8) ![]u8 {
    const transport_options = transportSshOptionsLen(ssh_options);
    const argv = try allocator.alloc([]const u8, transport_options + 3);
    defer allocator.free(argv);
    argv[0] = "ssh";
    var arg_index: usize = 1;
    appendTransportSshOptions(argv, &arg_index, ssh_options);
    argv[arg_index] = "-G";
    argv[arg_index + 1] = host;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = ssh_config_query_max_output_bytes,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.SshConfigQueryFailed,
        else => return error.SshConfigQueryFailed,
    }
    return try allocator.dupe(u8, result.stdout);
}

pub fn parseSshConfig(allocator: std.mem.Allocator, output: []const u8, ssh_options: []const []const u8, fallback_host: []const u8) !ResolvedSshConfig {
    var user: ?[]u8 = null;
    var hostname: ?[]u8 = null;
    var port: ?[]u8 = null;
    var ipqos: ?[]u8 = null;
    var send_env = std.ArrayList([]const u8).empty;
    errdefer {
        if (user) |value| allocator.free(value);
        if (hostname) |value| allocator.free(value);
        if (port) |value| allocator.free(value);
        if (ipqos) |value| allocator.free(value);
        freeStrings(allocator, send_env.items);
        send_env.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = fields.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(key, "user")) {
            const value = fields.next() orelse continue;
            if (user) |old| allocator.free(old);
            user = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "hostname")) {
            const value = fields.next() orelse continue;
            if (hostname) |old| allocator.free(old);
            hostname = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "port")) {
            const value = fields.next() orelse continue;
            if (!isValidSshPort(value)) continue;
            if (port) |old| allocator.free(old);
            port = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "ipqos")) {
            const interactive = fields.next() orelse continue;
            if (ipqos) |old| allocator.free(old);
            ipqos = try allocator.dupe(u8, interactive);
        } else if (std.ascii.eqlIgnoreCase(key, "sendenv")) {
            while (fields.next()) |pattern| {
                try send_env.append(allocator, try allocator.dupe(u8, pattern));
            }
        }
    }
    if (user == null) user = try fallbackSshUser(allocator);
    if (hostname == null) hostname = try allocator.dupe(u8, fallback_host);
    if (port == null) {
        const explicit_port = explicitSshPort(ssh_options) orelse session_registry.default_ssh_port;
        port = try allocator.dupe(u8, explicit_port);
    }
    return .{
        .user = user.?,
        .hostname = hostname.?,
        .port = port.?,
        .ipqos = ipqos,
        .send_env = try send_env.toOwnedSlice(allocator),
    };
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    freeStrings(allocator, values);
    if (values.len != 0) allocator.free(values);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

pub fn explicitSshPort(ssh_options: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < ssh_options.len) : (i += 1) {
        const option = ssh_options[i];
        if (std.mem.eql(u8, option, "-p")) {
            if (i + 1 < ssh_options.len and isValidSshPort(ssh_options[i + 1])) return ssh_options[i + 1];
            continue;
        }
        if (std.mem.startsWith(u8, option, "-p") and option.len > 2) {
            const value = option[2..];
            if (isValidSshPort(value)) return value;
            continue;
        }
        if (std.mem.eql(u8, option, "-o")) {
            if (i + 1 < ssh_options.len) {
                if (sshConfigOptionValue(ssh_options[i + 1], "Port")) |value| {
                    if (isValidSshPort(value)) return value;
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, option, "-o") and option.len > 2) {
            if (sshConfigOptionValue(option[2..], "Port")) |value| {
                if (isValidSshPort(value)) return value;
            }
        }
    }
    return null;
}

fn isValidSshPort(value: []const u8) bool {
    if (value.len == 0) return false;
    const port = std.fmt.parseInt(u16, value, 10) catch return false;
    return port != 0;
}

pub fn transportSshOptionsLen(options: []const []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < options.len) : (i += 1) {
        const option = options[i];
        if (isSshTtyRequestOption(option)) continue;
        len += 1;
        if (sshOptionSeparateValueIndex(options, i)) |value_index| {
            len += 1;
            i = value_index;
        }
    }
    return len;
}

// The runtime transport always uses `ssh -T` because sessh owns the PTY
// protocol. User-provided `-t`/`-tt` only decides whether ssh-shaped remote
// command args are accepted, so those options must not be forwarded to the
// transport ssh invocation.
pub fn appendTransportSshOptions(ssh_argv: [][]const u8, arg_index: *usize, options: []const []const u8) void {
    var i: usize = 0;
    while (i < options.len) : (i += 1) {
        const option = options[i];
        if (isSshTtyRequestOption(option)) continue;
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
        if (sshOptionSeparateValueIndex(options, i)) |value_index| {
            ssh_argv[arg_index.*] = options[value_index];
            arg_index.* += 1;
            i = value_index;
        }
    }
}

pub fn sshOptionSeparateValueIndex(options: []const []const u8, index: usize) ?usize {
    const arg = options[index];
    if (arg.len < 2 or arg[0] != '-' or std.mem.startsWith(u8, arg, "--")) return null;
    var pos: usize = 1;
    while (pos < arg.len) : (pos += 1) {
        if (!sshOptionConsumesValueForHostScan(arg[pos])) continue;
        return if (pos + 1 < arg.len or index + 1 >= options.len) null else index + 1;
    }
    return null;
}

pub fn consumeSshOption(
    args: []const []const u8,
    index: *usize,
    tty_request: *SshTtyRequest,
    proxy_required: *bool,
) !void {
    const arg = args[index.*];
    if (std.mem.startsWith(u8, arg, "--")) return error.UnsupportedSshOption;

    if (sshTtyRequestCount(arg)) |count| {
        noteSshTtyRequest(tty_request, count);
        index.* += 1;
        return;
    }

    var pos: usize = 1;
    while (pos < arg.len) {
        const option = arg[pos];
        if (isProxyRequiredSshFlag(option)) {
            proxy_required.* = true;
            pos += 1;
            continue;
        }
        if (isProxyRequiredSshOptionWithValue(option)) {
            _ = try optionValue(args, index, pos);
            proxy_required.* = true;
            return;
        }
        if (isUnsafeSshFlag(option) or isUnsafeSshOptionWithValue(option)) {
            return error.UnsafeSshOption;
        }

        if (option == 'o') {
            const value = try optionValue(args, index, pos);
            if (try sshConfigOptionRequiresProxy(value)) {
                proxy_required.* = true;
            } else {
                try validateSshConfigOption(value);
            }
            return;
        }

        if (sshOptionRequiresValue(option)) {
            _ = try optionValue(args, index, pos);
            return;
        }

        if (!isSafeSshFlag(option)) return error.UnsupportedSshOption;
        pos += 1;
    }

    index.* += 1;
}

pub fn isSshTtyRequestOption(arg: []const u8) bool {
    return sshTtyRequestCount(arg) != null;
}

fn sshTtyRequestCount(arg: []const u8) ?usize {
    if (arg.len < 2 or arg[0] != '-') return null;
    for (arg[1..]) |byte| {
        if (byte != 't') return null;
    }
    return arg.len - 1;
}

fn noteSshTtyRequest(tty_request: *SshTtyRequest, count: usize) void {
    if (count >= 2 or tty_request.* == .requested) {
        tty_request.* = .forced;
    } else if (count == 1 and tty_request.* == .none) {
        tty_request.* = .requested;
    }
}

fn optionValue(args: []const []const u8, index: *usize, option_pos: usize) ![]const u8 {
    const arg = args[index.*];
    if (option_pos + 1 < arg.len) {
        index.* += 1;
        return arg[option_pos + 1 ..];
    }

    if (index.* + 1 >= args.len) return error.MissingSshOptionValue;
    const value = args[index.* + 1];
    index.* += 2;
    return value;
}

fn isSafeSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "46CgKkqsTv", option) != null;
}

fn isUnsafeSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "GtV", option) != null;
}

pub fn sshOptionRequiresValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmOPpRSwW", option) != null;
}

pub fn isUnsafeSshOptionWithValue(option: u8) bool {
    return option == 'Q';
}

pub fn isProxyRequiredSshFlag(option: u8) bool {
    return std.mem.indexOfScalar(u8, "AafMNsXxYyn", option) != null;
}

pub fn isProxyRequiredSshOptionWithValue(option: u8) bool {
    return std.mem.indexOfScalar(u8, "DLORWw", option) != null;
}

fn validateSshConfigOption(raw_option: []const u8) !void {
    const key = sshConfigKey(raw_option);
    if (std.ascii.eqlIgnoreCase(key, "RemoteCommand")) return error.UnsafeSshOption;

    if (std.ascii.eqlIgnoreCase(key, "RequestTTY")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "SessionType")) {
        if (!sshConfigValueIs(raw_option, key.len, "default")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "StdinNull")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
    if (std.ascii.eqlIgnoreCase(key, "ForkAfterAuthentication")) {
        if (!sshConfigValueIs(raw_option, key.len, "no")) return error.UnsafeSshOption;
        return;
    }
}

pub fn sshConfigOptionRequiresProxy(raw_option: []const u8) !bool {
    const key = sshConfigKey(raw_option);
    if (sshConfigKeyIs(raw_option, "RemoteCommand")) return true;
    if (sshConfigKeyIs(raw_option, "ForwardAgent")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForwardX11")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForwardX11Trusted")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "LocalForward")) return true;
    if (sshConfigKeyIs(raw_option, "RemoteForward")) return true;
    if (sshConfigKeyIs(raw_option, "DynamicForward")) return true;
    if (sshConfigKeyIs(raw_option, "StreamLocalBindUnlink")) return true;
    if (sshConfigKeyIs(raw_option, "StreamLocalForward")) return true;
    if (sshConfigKeyIs(raw_option, "ClearAllForwardings")) return true;
    if (sshConfigKeyIs(raw_option, "PermitLocalCommand")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "RequestTTY")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "SessionType")) return !sshConfigValueIs(raw_option, key.len, "default");
    if (sshConfigKeyIs(raw_option, "StdinNull")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "ForkAfterAuthentication")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "Tunnel")) return !sshConfigValueIs(raw_option, key.len, "no");
    if (sshConfigKeyIs(raw_option, "TunnelDevice")) return true;
    return false;
}

pub fn sshConfigKeyIs(raw_option: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(sshConfigKey(raw_option), expected);
}

pub fn sshConfigKey(raw_option: []const u8) []const u8 {
    var end: usize = 0;
    while (end < raw_option.len) : (end += 1) {
        switch (raw_option[end]) {
            '=', ' ', '\t' => break,
            else => {},
        }
    }
    return raw_option[0..end];
}

fn sshConfigOptionValue(raw_option: []const u8, expected_key: []const u8) ?[]const u8 {
    const key = sshConfigKey(raw_option);
    if (!std.ascii.eqlIgnoreCase(key, expected_key)) return null;
    var value_start = key.len;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    if (value_start < raw_option.len and raw_option[value_start] == '=') value_start += 1;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    if (value_start >= raw_option.len) return null;
    return raw_option[value_start..];
}

pub fn sshConfigValueIs(raw_option: []const u8, key_len: usize, expected: []const u8) bool {
    var value_start = key_len;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    if (value_start < raw_option.len and raw_option[value_start] == '=') value_start += 1;
    while (value_start < raw_option.len and
        (raw_option[value_start] == ' ' or raw_option[value_start] == '\t'))
    {
        value_start += 1;
    }
    return std.ascii.eqlIgnoreCase(raw_option[value_start..], expected);
}

fn sshOptionConsumesValueForHostScan(option: u8) bool {
    return option == 'o' or
        sshOptionRequiresValue(option) or
        isUnsafeSshOptionWithValue(option);
}

test "transport ssh option filtering only removes tty request options" {
    const options = &.{ "-F", "-tt", "-t", "-p2222", "-o", "BatchMode=yes" };
    var out: [5][]const u8 = undefined;
    var index: usize = 0;

    try std.testing.expectEqual(@as(usize, 5), transportSshOptionsLen(options));
    appendTransportSshOptions(out[0..], &index, options);

    try expectArgvEqual(&.{ "-F", "-tt", "-p2222", "-o", "BatchMode=yes" }, out[0..index]);
}

test "parseSshConfig returns resolved endpoint and first configured ipqos value" {
    var resolved = try parseSshConfig(std.testing.allocator,
        \\hostname example.com
        \\port 2200
        \\ipqos ef cs0
        \\sendenv LANG LC_* SESSH_TEST_SENDENV
        \\user tomm
        \\
    , &.{}, "alias");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example.com", resolved.hostname);
    try std.testing.expectEqualStrings("2200", resolved.port);
    try std.testing.expectEqualStrings("ef", resolved.ipqos.?);
    try expectArgvEqual(&.{ "LANG", "LC_*", "SESSH_TEST_SENDENV" }, resolved.send_env);
}

test "parseSshConfig defaults endpoint fields" {
    var resolved = try parseSshConfig(std.testing.allocator,
        \\user tomm
        \\
    , &.{ "-p", "2022" }, "alias");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alias", resolved.hostname);
    try std.testing.expectEqualStrings("2022", resolved.port);
    try std.testing.expectEqual(@as(?[]u8, null), resolved.ipqos);
}

test "explicitSshPort parses common ssh port options" {
    try std.testing.expectEqualStrings("2022", explicitSshPort(&.{ "-p", "2022" }).?);
    try std.testing.expectEqualStrings("2023", explicitSshPort(&.{"-p2023"}).?);
    try std.testing.expectEqualStrings("2024", explicitSshPort(&.{ "-o", "Port=2024" }).?);
    try std.testing.expectEqualStrings("2025", explicitSshPort(&.{"-oPort 2025"}).?);
    try std.testing.expectEqual(@as(?[]const u8, null), explicitSshPort(&.{"-p0"}));
}

fn expectArgvEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}
