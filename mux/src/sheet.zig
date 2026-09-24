//! Painting a sheet over the panes: what the ownership gate and the
//! inspector are drawn with. Rects filled with a ground, a box edge,
//! text cut to a width.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const ui = @import("ui.zig");

pub const Rgb = chromepkg.Rgb;
const csi = "\x1b[";

/// How long ago, in the one unit that reads at a glance.
pub fn age(buf: []u8, ms: i64) []const u8 {
    if (ms < 0) return "now";
    const s = @divTrunc(ms, 1000);
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "";
    const m = @divTrunc(s, 60);
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "";
    const h = @divTrunc(m, 60);
    if (h < 48) return std.fmt.bufPrint(buf, "{d}h", .{h}) catch "";
    return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(h, 24)}) catch "";
}

fn style(f: *renderpkg.Frame, st: ui.Style) void {
    var b: [64]u8 = undefined;
    f.put(st.sgr(&b));
}

/// Write at most `w` columns of `s` at the cursor; returns the
/// columns spent. Cuts on codepoint boundaries, one column each —
/// chrome's own strings are one cell a glyph, and the row is padded
/// after it either way.
pub fn putW(f: *renderpkg.Frame, s: []const u8, w: u16) u16 {
    var n: u16 = 0;
    var i: usize = 0;
    while (i < s.len and n < w) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        f.put(s[i..end]);
        i = end;
        n += 1;
    }
    return n;
}

fn pad(f: *renderpkg.Frame, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) f.put(" ");
}

/// Fill a rect with a ground.
pub fn fillRect(f: *renderpkg.Frame, r: layoutpkg.Rect, ground: Rgb) void {
    var b: [64]u8 = undefined;
    f.put((ui.Style{ .bg = ground }).sgr(&b));
    var y: u16 = r.y;
    while (y < r.y + r.h) : (y += 1) {
        f.cup(r.x, y);
        pad(f, r.w);
    }
    f.put(csi ++ "0m");
}

fn hline(f: *renderpkg.Frame, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) f.put("─");
}

/// A box edge in a role's ink, on a ground.
pub fn box(f: *renderpkg.Frame, r: layoutpkg.Rect, edge: Rgb, ground: Rgb) void {
    if (r.w < 2 or r.h < 2) return;
    var row: u16 = 0;
    while (row < r.h) : (row += 1) {
        f.cup(r.x, r.y + row);
        style(f, .{ .fg = edge, .bg = ground });
        if (row == 0) {
            f.put("┌");
            hline(f, r.w -| 2);
            f.put("┐");
        } else if (row == r.h - 1) {
            f.put("└");
            hline(f, r.w -| 2);
            f.put("┘");
        } else {
            f.put("│");
            pad(f, r.w -| 2);
            f.put("│");
        }
    }
    f.put(csi ++ "0m");
}

test "age" {
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("now", age(&b, -1));
    try std.testing.expectEqualStrings("5s", age(&b, 5_000));
    try std.testing.expectEqualStrings("3m", age(&b, 180_000));
    try std.testing.expectEqualStrings("2d", age(&b, 49 * 3_600_000));
}
