//! Configuration, minimal, from the same ~/.config/rook/rook.toml
//! the Go rook uses. [tmux] prefix = "`" or "C-b" (compat), and a
//! [mux] section for knobs that earned one:
//!   nav_owners = ["nvim", "fzf"]   # programs that keep Ctrl-hjkl
//!   scrollback_mb = 4
//!   accent = "#cba6f7"             # chrome color: tabs, borders, popup
//!   restore = true                 # resurrect last layout on boot (default off)
//!   sidebar = true                 # the spaces/agents side panel
//!   sidebar_width = 30             # its width in columns
const std = @import("std");
const chrome = @import("chrome.zig");

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

/// The [mux] knobs, defaults matching the hardcoded originals.
pub const Mux = struct {
    /// newline-joined program names that own Ctrl-h/j/k/l
    owners: [512]u8 = @splat(0),
    owners_len: usize = 0,
    scrollback_bytes: usize = 4 * 1024 * 1024,
    /// The one chrome accent: the active tab chip, focused borders, the
    /// popup box. A hex color or one of the eight ANSI names, which map
    /// into the same palette.
    accent: chrome.Rgb = chrome.mauve,
    /// The side panel: on unless asked otherwise, and it folds away on
    /// glass too narrow for it regardless.
    sidebar: bool = true,
    sidebar_width: u16 = 30,
    /// Resurrect the last saved layout on server boot. Off by default:
    /// a fresh `rook` opens a clean workspace, not last session's splits.
    restore: bool = false,

    pub fn ownersSlice(self: *const Mux) []const u8 {
        return self.owners[0..self.owners_len];
    }
};

pub fn muxConfig() Mux {
    var out: Mux = .{};
    var buf: [8192]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return out);
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return out;
    const f = std.c.fopen(path, "r") orelse return out;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    parseMux(buf[0..n], &out);
    return out;
}

pub fn parseMux(toml: []const u8, out: *Mux) void {
    var in_mux = false;
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_mux = std.mem.eql(u8, t, "[mux]");
            continue;
        }
        if (!in_mux) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "scrollback_mb")) {
            const mb = std.fmt.parseInt(usize, std.mem.trim(u8, val, "\"'"), 10) catch continue;
            const clamped: usize = @min(mb, 256);
            out.scrollback_bytes = clamped * 1024 * 1024;
        } else if (std.mem.eql(u8, key, "accent")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.accent = chrome.Rgb.parse(v) orelse chrome.named(v) orelse out.accent;
        } else if (std.mem.eql(u8, key, "restore")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.restore = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "sidebar")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.sidebar = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "sidebar_width")) {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, val, "\"'"), 10) catch continue;
            out.sidebar_width = std.math.clamp(n, 16, 60);
        } else if (std.mem.eql(u8, key, "nav_owners")) {
            // ["a", "b"] → a\nb
            out.owners_len = 0;
            var it = std.mem.tokenizeAny(u8, val, "[]\"', ");
            while (it.next()) |name| {
                if (out.owners_len + name.len + 1 > out.owners.len) break;
                if (out.owners_len > 0) {
                    out.owners[out.owners_len] = '\n';
                    out.owners_len += 1;
                }
                @memcpy(out.owners[out.owners_len .. out.owners_len + name.len], name);
                out.owners_len += name.len;
            }
        }
    }
}

test "parseMux" {
    var m: Mux = .{};
    parseMux("[mux]\nscrollback_mb = 8\naccent = \"cyan\"\nnav_owners = [\"nvim\", \"fzf\"]\n", &m);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), m.scrollback_bytes);
    try std.testing.expectEqual(chrome.teal, m.accent);
    try std.testing.expectEqualStrings("nvim\nfzf", m.ownersSlice());
    var d: Mux = .{};
    parseMux("[tmux]\nprefix = \"`\"\naccent = \"red\"\n", &d);
    try std.testing.expectEqual(chrome.mauve, d.accent); // wrong section: ignored
    parseMux("[mux]\naccent = \"bright-blue\"\n", &d);
    try std.testing.expectEqual(chrome.blue, d.accent);
    parseMux("[mux]\naccent = \"#f9e2af\"\n", &d);
    try std.testing.expectEqual(chrome.yellow, d.accent);
    var sb: Mux = .{};
    try std.testing.expectEqual(true, sb.sidebar);
    try std.testing.expectEqual(@as(u16, 30), sb.sidebar_width);
    parseMux("[mux]\nsidebar = false\nsidebar_width = 999\n", &sb);
    try std.testing.expectEqual(false, sb.sidebar);
    try std.testing.expectEqual(@as(u16, 60), sb.sidebar_width); // clamped
    var r: Mux = .{};
    try std.testing.expectEqual(false, r.restore); // default off
    parseMux("[mux]\nrestore = true\n", &r);
    try std.testing.expectEqual(true, r.restore);
    parseMux("[mux]\nrestore = false\n", &r);
    try std.testing.expectEqual(false, r.restore);
}

test "parsePrefix" {
    try std.testing.expectEqual(@as(?u8, 0x60), parsePrefix("[tmux]\nprefix = \"`\"\n"));
    try std.testing.expectEqual(@as(?u8, 0x02), parsePrefix("prefix = \"C-b\""));
    try std.testing.expectEqual(@as(?u8, 0x01), parsePrefix("prefix = 'C-a'"));
    try std.testing.expectEqual(@as(?u8, null), parsePrefix("[tmux]\nplugins = []\n"));
}
