//! The chrome rook-mux draws itself — every cell that is not a pane.
//!
//! Two things live here: the palette (Catppuccin Mocha, the colors the
//! herdr design is drawn in) and the side panel, a left rail of
//! *spaces* over *agents*. The panel is app chrome, not a pty: no
//! process backs it, the frame builder paints it straight from a
//! model. Today that model is `placeholder` — the shape is the
//! contract the real spaces/agents feed will fill in.
const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// "#rrggbb" (or "rrggbb") → Rgb. Null on anything else.
    pub fn parse(s: []const u8) ?Rgb {
        const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (h.len != 6) return null;
        const v = std.fmt.parseInt(u24, h, 16) catch return null;
        return .{
            .r = @intCast(v >> 16),
            .g = @truncate(v >> 8),
            .b = @truncate(v),
        };
    }
};

// Catppuccin Mocha. crust is the page, mantle the panel, base the
// tab bar and the selected row; surface0 draws every seam.
pub const crust: Rgb = .{ .r = 0x11, .g = 0x11, .b = 0x1b };
pub const mantle: Rgb = .{ .r = 0x18, .g = 0x18, .b = 0x25 };
pub const base: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
pub const surface0: Rgb = .{ .r = 0x31, .g = 0x32, .b = 0x44 };
pub const overlay0: Rgb = .{ .r = 0x6c, .g = 0x70, .b = 0x86 };
pub const text: Rgb = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 };
pub const mauve: Rgb = .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 };
pub const red: Rgb = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 };
pub const peach: Rgb = .{ .r = 0xfa, .g = 0xb3, .b = 0x87 };
pub const yellow: Rgb = .{ .r = 0xf9, .g = 0xe2, .b = 0xaf };
pub const green: Rgb = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 };
pub const teal: Rgb = .{ .r = 0x94, .g = 0xe2, .b = 0xd5 };
pub const sky: Rgb = .{ .r = 0x89, .g = 0xdc, .b = 0xeb };
pub const blue: Rgb = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };

/// The eight ANSI names an `accent = "..."` can still spell, mapped
/// into the palette so a named accent and a hex one are the same kind
/// of color. `bright-` is accepted and means the same hue: Mocha has
/// one shade of each.
pub fn named(name: []const u8) ?Rgb {
    const want = if (std.mem.startsWith(u8, name, "bright-")) name["bright-".len..] else name;
    const table = [_]struct { n: []const u8, c: Rgb }{
        .{ .n = "black", .c = surface0 },   .{ .n = "red", .c = red },
        .{ .n = "green", .c = green },      .{ .n = "yellow", .c = yellow },
        .{ .n = "blue", .c = blue },        .{ .n = "magenta", .c = mauve },
        .{ .n = "cyan", .c = teal },        .{ .n = "white", .c = text },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.n, want)) return e.c;
    }
    return null;
}

// ---- the side panel ----

/// The status glyph beside a row. Ambiguous-width on purpose: one
/// cell on every terminal that defaults ambiguous to narrow, which
/// the glass does.
pub const Dot = enum {
    filled, // ●  running / present
    hollow, // ○  idle
    ring, // ◉  wants you (blocked on an ask)

    fn glyph(self: Dot) []const u8 {
        return switch (self) {
            .filled => "●",
            .hollow => "○",
            .ring => "◉",
        };
    }
};

pub const Item = struct {
    name: []const u8,
    /// The second line: a branch for a space, "state · tool" for an agent.
    sub: []const u8,
    dot: Rgb = overlay0,
    shape: Dot = .filled,
    /// The subtitle's color — an agent's state is the color.
    sub_fg: Rgb = overlay0,
};

pub const Panel = struct {
    title: []const u8,
    /// Right-aligned note in the header row ("grouped").
    note: []const u8 = "",
    items: []const Item,
    /// The highlighted row, if any.
    cur: ?usize = null,
};

pub const Model = struct {
    spaces: Panel,
    agents: Panel,
    /// The configured accent — a selected row's subtitle wears it.
    accent: Rgb = mauve,
};

/// Rows one item occupies: a leading gap, the name, the subtitle.
pub const item_rows: u16 = 3;

/// The panel needs at least this much glass to be worth drawing.
pub const min_rows: u16 = 8;

/// Row of the seam between spaces and agents, in a panel `h` tall.
/// The hit test and the painter must agree on this.
pub fn splitRow(h: u16) u16 {
    return h / 2;
}

/// What the panel shows before anything real is wired to it. It is
/// the herdr screenshot, cell for cell, so the thing can be demoed
/// and dialed in before the feed exists.
pub const placeholder: Model = .{
    .spaces = .{
        .title = "spaces",
        .cur = 1,
        .items = &.{
            .{ .name = "herdr", .sub = "master", .dot = yellow },
            .{ .name = "web-dashboard", .sub = "feat/usage-charts", .dot = red },
            .{ .name = "data-pipeline", .sub = "backfill/events-v2", .dot = green },
        },
    },
    .agents = .{
        .title = "agents",
        .note = "grouped",
        .cur = 2,
        .items = &.{
            .{ .name = "herdr", .sub = "working · claude", .dot = yellow, .sub_fg = yellow },
            .{ .name = "explore", .sub = "idle · opencode", .dot = green, .shape = .hollow },
            .{ .name = "web-dashboard", .sub = "blocked · claude", .dot = red, .shape = .ring, .sub_fg = red },
            .{ .name = "data-pipeline", .sub = "done · codex", .dot = teal, .sub_fg = teal },
        },
    },
};

/// Cell coordinates of the item under a click, or null for a click
/// that landed on a header, a gap, or past the last row. `y` is
/// panel-relative (row 0 is the header).
pub fn hit(p: Panel, y: u16) ?usize {
    if (y == 0) return null;
    const i = (y - 1) / item_rows;
    // row 0 of an item block is its leading gap, not the item
    if ((y - 1) % item_rows == 0) return null;
    return if (i < p.items.len) i else null;
}

// ---- drawing ----
//
// `f` is a render.Frame; taken as anytype so the panel does not have
// to import the frame builder that imports it.

fn sgrFg(f: anytype, c: Rgb) void {
    f.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}
fn sgrBg(f: anytype, c: Rgb) void {
    f.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Paint `w` cells of `back` at (x, y) and leave the bg set, so
/// whatever is written next inherits it.
fn band(f: anytype, x: u16, y: u16, w: u16, back: Rgb) void {
    f.cup(x, y);
    f.put("\x1b[0m");
    sgrBg(f, back);
    var n: u16 = 0;
    while (n < w) : (n += 1) f.put(" ");
}

/// Write `s` at (x, y), clipped to `w` cells. Assumes the row's band
/// is already painted (so the bg shows through).
fn at(f: anytype, x: u16, y: u16, w: u16, s: []const u8) void {
    if (w == 0) return;
    f.cup(x, y);
    f.put(clip(s, w));
}

/// Byte-clip to `n` columns. ASCII-only by contract: names come from
/// the feed and are truncated, not ellipsized, so no partial UTF-8.
fn clip(s: []const u8, n: u16) []const u8 {
    return s[0..@min(s.len, n)];
}

/// The whole panel: spaces over agents, split down the middle by a
/// seam, the way the design has it.
pub fn draw(f: anytype, m: Model, x: u16, y: u16, w: u16, h: u16) void {
    if (w < 8 or h < min_rows) return;
    const split = y + splitRow(h);
    drawPanel(f, m.spaces, m.accent, x, y, w, split -| y);
    // the seam between the two panels
    band(f, x, split, w, mantle);
    f.cup(x, split);
    sgrFg(f, surface0);
    var n: u16 = 0;
    while (n < w) : (n += 1) f.put("─");
    drawPanel(f, m.agents, m.accent, x, split + 1, w, (y + h) -| (split + 1));
    f.put("\x1b[0m");
}

fn drawPanel(f: anytype, p: Panel, accent: Rgb, x: u16, y: u16, w: u16, h: u16) void {
    if (h == 0) return;
    const pad: u16 = 2; // breathing room down the left edge
    // header: the title, and its note pushed to the right edge
    band(f, x, y, w, mantle);
    sgrFg(f, overlay0);
    at(f, x + pad, y, w -| pad, p.title);
    if (p.note.len > 0 and p.note.len + p.title.len + 3 <= w) {
        at(f, x + w - pad - @as(u16, @intCast(p.note.len)), y, w, p.note);
    }

    for (p.items, 0..) |it, i| {
        const top = y + 1 + @as(u16, @intCast(i)) * item_rows;
        if (top + item_rows > y + h) break; // no room for a whole item
        const sel = p.cur != null and p.cur.? == i;
        const back: Rgb = if (sel) base else mantle;
        // the item's band covers its leading gap, name and subtitle,
        // so a selected row reads as one block
        band(f, x, top, w, back);
        band(f, x, top + 1, w, back);
        band(f, x, top + 2, w, back);

        // name row: the dot, then the name
        f.cup(x + pad, top + 1);
        sgrFg(f, it.dot);
        f.put(it.shape.glyph());
        sgrFg(f, text);
        f.put("\x1b[1m");
        at(f, x + pad + 2, top + 1, w -| (pad + 2), it.name);
        f.put("\x1b[22m");

        // subtitle row, indented under the name
        // a selected row's plain subtitle takes the accent; a state
        // color (working, blocked, done) already says more than that
        sgrFg(f, if (sel and it.sub_fg.eql(overlay0)) accent else it.sub_fg);
        at(f, x + pad + 2, top + 2, w -| (pad + 2), it.sub);
    }

    // fill the rest of the panel so it reads as one surface
    var row = y + 1 + @as(u16, @intCast(p.items.len)) * item_rows;
    while (row < y + h) : (row += 1) band(f, x, row, w, mantle);
    f.put("\x1b[0m");
}

test "hex parse" {
    try std.testing.expectEqual(Rgb{ .r = 0xcb, .g = 0xa6, .b = 0xf7 }, Rgb.parse("#cba6f7").?);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x11, .b = 0x1b }, Rgb.parse("11111b").?);
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#fff"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("cyan"));
    try std.testing.expectEqual(mauve, named("magenta").?);
    try std.testing.expectEqual(teal, named("bright-cyan").?);
    try std.testing.expectEqual(@as(?Rgb, null), named("chartreuse"));
}

test "hit test skips headers and gaps" {
    const p = placeholder.spaces;
    try std.testing.expectEqual(@as(?usize, null), hit(p, 0)); // header
    try std.testing.expectEqual(@as(?usize, null), hit(p, 1)); // gap
    try std.testing.expectEqual(@as(?usize, 0), hit(p, 2)); // name
    try std.testing.expectEqual(@as(?usize, 0), hit(p, 3)); // sub
    try std.testing.expectEqual(@as(?usize, null), hit(p, 4)); // gap
    try std.testing.expectEqual(@as(?usize, 1), hit(p, 5));
    try std.testing.expectEqual(@as(?usize, 2), hit(p, 8));
    try std.testing.expectEqual(@as(?usize, null), hit(p, 11)); // past the end
}
