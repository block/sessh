const std = @import("std");

pub fn allowsName(patterns: []const []const u8, name: []const u8) bool {
    var allowed = false;
    for (patterns) |pattern| {
        if (pattern.len == 0) continue;
        const negated = pattern[0] == '-';
        const raw_pattern = if (negated) pattern[1..] else pattern;
        if (raw_pattern.len == 0) continue;
        if (patternMatches(raw_pattern, name)) allowed = !negated;
    }
    return allowed;
}

fn patternMatches(pattern: []const u8, name: []const u8) bool {
    return patternMatchesFrom(pattern, 0, name, 0);
}

fn patternMatchesFrom(pattern: []const u8, pattern_index: usize, name: []const u8, name_index: usize) bool {
    if (pattern_index == pattern.len) return name_index == name.len;
    const char = pattern[pattern_index];
    if (char == '*') {
        var index = name_index;
        while (index <= name.len) : (index += 1) {
            if (patternMatchesFrom(pattern, pattern_index + 1, name, index)) return true;
        }
        return false;
    }
    if (name_index == name.len) return false;
    if (char == '?' or char == name[name_index]) {
        return patternMatchesFrom(pattern, pattern_index + 1, name, name_index + 1);
    }
    return false;
}

test "matcher supports ssh wildcard and removal patterns" {
    try std.testing.expect(allowsName(&.{ "LANG", "LC_*" }, "LANG"));
    try std.testing.expect(allowsName(&.{ "LANG", "LC_*" }, "LC_CTYPE"));
    try std.testing.expect(!allowsName(&.{ "LANG", "LC_*" }, "SHELL"));
    try std.testing.expect(!allowsName(&.{ "*", "-SHELL" }, "SHELL"));
    try std.testing.expect(allowsName(&.{ "*", "-SHELL" }, "TERM"));
    try std.testing.expect(allowsName(&.{"SESSH_TEST_SENDEN?"}, "SESSH_TEST_SENDENV"));
}
