//! Configuration, minimal: the prefix key, read from the same
//! ~/.config/rook/rook.toml the Go rook uses ([tmux] prefix = "`" or
//! "C-b"). No new config surface until a knob earns one.
const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn prefixKey() u8 {
    var buf: [4096]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return 0x02);
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return 0x02;
    const f = std.c.fopen(path, "r") orelse return 0x02;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    return parsePrefix(buf[0..n]) orelse 0x02;
}

/// Finds `prefix = "..."` and translates tmux key syntax: "C-x" is
/// ctrl, a single char is itself.
pub fn parsePrefix(toml: []const u8) ?u8 {
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "prefix")) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"'");
        if (val.len == 1) return val[0];
        if (val.len == 3 and (val[0] == 'C' or val[0] == 'c') and val[1] == '-') {
            const ch = std.ascii.toLower(val[2]);
            if (ch >= 'a' and ch <= 'z') return ch - 'a' + 1;
        }
    }
    return null;
}

test "parsePrefix" {
    try std.testing.expectEqual(@as(?u8, 0x60), parsePrefix("[tmux]\nprefix = \"`\"\n"));
    try std.testing.expectEqual(@as(?u8, 0x02), parsePrefix("prefix = \"C-b\""));
    try std.testing.expectEqual(@as(?u8, 0x01), parsePrefix("prefix = 'C-a'"));
    try std.testing.expectEqual(@as(?u8, null), parsePrefix("[tmux]\nplugins = []\n"));
}
