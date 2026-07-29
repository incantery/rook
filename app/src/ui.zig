//! The seed of rook's own UI layer. Immediate-mode: chrome rebuilds its
//! quads every drawn frame from the same two pipelines and atlases the
//! grid uses — a widget is never a draw call of its own kind, just more
//! instanced cells and rects. Primitives grow only when a real tenant
//! needs them (the status bar is tenant one).
//!
//! Text v1 is deliberately the grid font at grid metrics: `text()` takes
//! a UTF-8 string and lays glyphs at the mono advance. When tabs/finder
//! need proportional runs, the internals move to CTLine shaping without
//! the callers changing.

const std = @import("std");
const objc = @import("objc");
const renderpkg = @import("render.zig");

/// The spatial system, in device pixels.
///
/// Every distance the chrome spaces itself by is derived here, once,
/// from the backing scale and the cell box. It is a struct rather than
/// literals at the call sites for two reasons found by looking at the
/// app: the bars inset themselves by one CELL, so the gutter grew and
/// shrank with the font size while nothing else did; and the numbers
/// were computed in two places (window creation and every resize) that
/// had to agree by hand.
///
/// Points, not cells, for anything that reads as an EDGE — an edge is a
/// property of the window, not of the text inside it.
pub const Metrics = struct {
    /// Chrome's inner left/right inset: where a bar's text starts.
    gutter: f32,
    /// Inside a pane, between its box and its first cell. Without it,
    /// text touches the split separator and the focus ring — the tell
    /// that made splits read as unfinished.
    pane_pad: f32,
    /// One chrome row: a bar, a panel line, a palette row.
    row: f32,
    /// Between clusters inside a panel — bigger than a gutter, smaller
    /// than a row.
    gap: f32,
    /// Corner radius for a small thing you can point at: a tab chip, a
    /// selected row, a badge.
    radius: f32,
    /// Corner radius for a surface that floats: the palette card.
    radius_card: f32,
    /// Shadow blur under a floating surface. Elevation is the only
    /// thing that says "this is over your work, and temporary".
    elevation: f32,

    /// A hairline is ONE device pixel at every scale. `App.sep` is the
    /// same number (it is also the split gap); this is only its name
    /// when it is being used as a rule.
    pub fn compute(scale: f32, cell_h: f32) Metrics {
        return .{
            .gutter = @round(10 * scale),
            .pane_pad = @round(6 * scale),
            .row = @ceil(cell_h + @round(10 * scale)),
            .gap = @round(6 * scale),
            .radius = @round(5 * scale),
            .radius_card = @round(10 * scale),
            .elevation = @round(18 * scale),
        };
    }
};

/// Fit `s` into `cols` cells, marking a cut with an ellipsis.
///
/// Two reasons this is not `s[0..@min(s.len, cols)]`, which is what the
/// panels did. Text that simply stops reads as a rendering fault; "…"
/// reads as "there is more", which is the truth, and in a 34-column
/// side pane it is the truth most of the time. And a byte-slice can cut
/// a codepoint in half — the glyph iterator is `initUnchecked`, so what
/// it does with the remainder is not something to find out.
///
/// Cells, not codepoints, is the honest unit here; they differ only for
/// wide glyphs, which the renderer already treats as one column.
pub fn clip(buf: []u8, s: []const u8, cols: usize) []const u8 {
    if (cols == 0) return "";
    var last: usize = 0; // byte index where the final cell starts
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cols) : (n += 1) {
        last = i;
        i = @min(s.len, i + (std.unicode.utf8ByteSequenceLength(s[i]) catch 1));
    }
    if (i >= s.len) return s;
    const head = s[0..last];
    if (head.len + 3 > buf.len) return head;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..3], "…");
    return buf[0 .. head.len + 3];
}

pub const Ui = struct {
    r: *renderpkg.Renderer,
    enc: objc.Object,
    vp_w: f32,
    vp_h: f32,
    /// The shared cell buffer; `off` is the next free slot (the panes'
    /// fill pass owns everything below it this frame).
    cells: []renderpkg.CellData,
    off: usize,

    pub fn rect(self: *Ui, x: f32, y: f32, w: f32, h: f32, color: [4]u8) void {
        self.r.drawRect(self.enc, self.vp_w, self.vp_h, x, y, w, h, color);
    }

    /// A rounded rect, optionally with a border drawn inside its edge.
    pub fn roundRect(self: *Ui, x: f32, y: f32, w: f32, h: f32, color: [4]u8, style: renderpkg.RectStyle) void {
        self.r.drawRoundRect(self.enc, self.vp_w, self.vp_h, x, y, w, h, color, style);
    }

    /// Elevation under a floating surface. Draw it BEFORE the surface —
    /// it paints outside the rect you give it, and the surface covers
    /// the middle.
    pub fn shadow(self: *Ui, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, color: [4]u8) void {
        self.r.drawRoundRect(self.enc, self.vp_w, self.vp_h, x, y, w, h, color, .{
            .radius = radius,
            .soften = blur,
        });
    }

    /// Fill the shared cell buffer with `str`; returns the glyph count.
    fn layout(self: *Ui, str: []const u8, fg: [4]u8, bg: [4]u8) usize {
        var n: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(str).iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.off + n >= self.cells.len) break;
            var cd = renderpkg.CellData{ .bg = bg, .fg = fg, .uvx = 0, .uvy = 0, .flags = 0 };
            if (cp > 32) {
                if (self.r.glyph(cp, false)) |loc| {
                    cd.uvx = loc.uvx;
                    cd.uvy = loc.uvy;
                    cd.flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                }
            }
            self.cells[self.off + n] = cd;
            n += 1;
        }
        return n;
    }

    /// Draw a text run at pixel (x, y); returns its pixel width.
    pub fn text(self: *Ui, x: f32, y: f32, str: []const u8, fg: [4]u8, bg: [4]u8) f32 {
        const n = self.layout(str, fg, bg);
        if (n == 0) return 0;
        self.r.drawGrid(self.enc, self.vp_w, self.vp_h, x, y, self.off, @intCast(n), 1);
        self.off += n;
        return @as(f32, @floatFromInt(n)) * self.r.cell_w;
    }

    /// Text with NO background of its own, for drawing on a shape that
    /// is already painted. `text()` lays a background cell under every
    /// glyph — square, edge to edge — which crops the corners off
    /// whatever pill or card it is sitting on.
    pub fn textOver(self: *Ui, x: f32, y: f32, str: []const u8, fg: [4]u8) f32 {
        const n = self.layout(str, fg, .{ 0, 0, 0, 0 });
        if (n == 0) return 0;
        self.r.drawGlyphs(self.enc, self.vp_w, self.vp_h, x, y, self.off, @intCast(n), 1);
        self.off += n;
        return @as(f32, @floatFromInt(n)) * self.r.cell_w;
    }

    /// Right-aligned `textOver`.
    pub fn textOverRight(self: *Ui, right_x: f32, y: f32, str: []const u8, fg: [4]u8) f32 {
        const count = std.unicode.utf8CountCodepoints(str) catch str.len;
        const w = @as(f32, @floatFromInt(count)) * self.r.cell_w;
        return self.textOver(right_x - w, y, str, fg);
    }

    /// Right-aligned text: the run ends at pixel `right_x`.
    pub fn textRight(self: *Ui, right_x: f32, y: f32, str: []const u8, fg: [4]u8, bg: [4]u8) f32 {
        const count = std.unicode.utf8CountCodepoints(str) catch str.len;
        const w = @as(f32, @floatFromInt(count)) * self.r.cell_w;
        return self.text(right_x - w, y, str, fg, bg);
    }
};

// ----------------------------------------------------------------- tests

const T = std.testing;

test "text that fits is returned untouched" {
    var buf: [64]u8 = undefined;
    try T.expectEqualStrings("hello", clip(&buf, "hello", 5));
    try T.expectEqualStrings("hello", clip(&buf, "hello", 99));
}

test "a cut is marked, and the result still fits" {
    var buf: [64]u8 = undefined;
    // 5 cells: four characters and the mark.
    try T.expectEqualStrings("abcd…", clip(&buf, "abcdefgh", 5));
}

test "a cut never splits a codepoint" {
    var buf: [64]u8 = undefined;
    // Each é is two bytes; a byte-slice at 3 would leave half of one,
    // and the glyph iterator reads unchecked UTF-8.
    const out = clip(&buf, "ééééé", 3);
    try T.expect(std.unicode.utf8ValidateSlice(out));
    try T.expectEqualStrings("éé…", out);
}

test "one cell of room is all mark" {
    var buf: [64]u8 = undefined;
    try T.expectEqualStrings("…", clip(&buf, "abcdef", 1));
    try T.expectEqualStrings("", clip(&buf, "abcdef", 0));
}
