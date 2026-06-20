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
    return patternMatchesFrom(.{
        .pattern = pattern,
        .name = name,
    });
}

const MatchState = struct {
    pattern: []const u8,
    pattern_index: usize = 0,
    name: []const u8,
    name_index: usize = 0,
};

fn patternMatchesFrom(state: MatchState) bool {
    if (state.pattern_index == state.pattern.len) return state.name_index == state.name.len;
    const char = state.pattern[state.pattern_index];
    if (char == '*') {
        var index = state.name_index;
        while (index <= state.name.len) : (index += 1) {
            if (patternMatchesFrom(.{
                .pattern = state.pattern,
                .pattern_index = state.pattern_index + 1,
                .name = state.name,
                .name_index = index,
            })) return true;
        }
        return false;
    }
    if (state.name_index == state.name.len) return false;
    if (char == '?' or char == state.name[state.name_index]) {
        return patternMatchesFrom(.{
            .pattern = state.pattern,
            .pattern_index = state.pattern_index + 1,
            .name = state.name,
            .name_index = state.name_index + 1,
        });
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
