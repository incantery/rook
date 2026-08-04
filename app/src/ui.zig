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

/// Greedy word wrap, clip()'s sibling: each next() is the longest prefix
/// of what remains that fits `cols`, broken at a space when one offers
/// itself and mid-run when nothing does (a long path wraps hard rather
/// than vanishing). Same unit as clip — codepoints as cells — and the
/// same rule: never split a codepoint. `cols` is mutable on purpose:
/// a row whose first line is narrowed by right-aligned fields sets it
/// once, then widens for the continuation lines.
pub const WrapIter = struct {
    s: []const u8,
    cols: usize,
    pos: usize = 0,

    pub fn next(self: *WrapIter) ?[]const u8 {
        if (self.pos >= self.s.len or self.cols == 0) return null;
        const rest = self.s[self.pos..];
        var i: usize = 0;
        var n: usize = 0;
        var brk: usize = 0; // byte index of the last space seen
        while (i < rest.len and n < self.cols) : (n += 1) {
            if (rest[i] == ' ') brk = i;
            i = @min(rest.len, i + (std.unicode.utf8ByteSequenceLength(rest[i]) catch 1));
        }
        if (i >= rest.len) {
            self.pos = self.s.len;
            return rest;
        }
        // The cell after the fold: a space there means the line fits
        // exactly, and the break lands on it.
        if (rest[i] == ' ') brk = i;
        if (brk == 0) {
            self.pos += i;
            return rest[0..i];
        }
        self.pos += brk + 1; // the space is the break; nobody renders it
        return rest[0..brk];
    }
};

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

/// Does AppKit own this point, rather than rook?
///
/// A local event monitor sees every mouse event before the window does,
/// and swallowing one (returning nil) takes it away from AppKit for good.
/// Most of the window is rook's, but three regions are not, and every one
/// of them is a gesture the window manager implements and rook cannot:
///
///   the top strip  — drag to move, double-click to zoom. Only exists in
///                    glass mode, where the layer extends UNDER the
///                    titlebar; `top_inset` is 0 otherwise and AppKit's
///                    own titlebar sits above the layer entirely.
///   the side and bottom edges — drag to resize.
///   the bottom corners — drag to resize DIAGONALLY, and they need to
///                    reach further in than the edges do, which is the
///                    whole reason this is not one margin.
///
/// Why corners were the broken case: the window's resize region also
/// extends a pixel or two OUTSIDE the frame, into the shadow. An edge
/// drag can land in that sliver and never reach the monitor at all, which
/// is why edges appeared to work. At a corner the outside sliver is an L
/// two pixels wide, so a diagonal grab almost always lands inside the
/// layer — where it was being eaten.
///
/// `edge` and `corner` are in POINTS, scaled here: AppKit's regions are
/// point-sized, so a retina window must not get a half-sized grab area.
/// All coordinates are device pixels with the origin at the layer's top
/// left, matching the scene.
pub fn appKitOwns(
    x: f32,
    y: f32,
    px_w: f32,
    px_h: f32,
    top_inset: f32,
    scale: f32,
) bool {
    // AppKit's own numbers, near enough: a few points at an edge, and a
    // noticeably larger square at a corner.
    const edge = 5 * scale;
    const corner = 16 * scale;

    if (y < top_inset) return true;

    // No top edge in the list, and that is not an omission. In glass mode
    // the layer's top IS the window's top, and the strip above already
    // covers it — 28 points, wider than any corner. In opaque mode the
    // layer's top borders AppKit's titlebar rather than the outside
    // world, so there is nothing to resize from there.
    const near_side = x <= edge or x >= px_w - edge;
    const near_bottom = y >= px_h - edge;
    if (near_side or near_bottom) return true;

    return (x <= corner or x >= px_w - corner) and y >= px_h - corner;
}

test "appKitOwns claims the titlebar strip, and only in glass mode" {
    // Glass mode: the layer runs under a 28pt titlebar.
    try std.testing.expect(appKitOwns(400, 10, 1000, 800, 28, 1));
    try std.testing.expect(appKitOwns(400, 27, 1000, 800, 28, 1));
    // ...and stops claiming at the strip's edge, or the tab bar under it
    // would never get a click.
    try std.testing.expect(!appKitOwns(400, 28, 1000, 800, 28, 1));
    // Opaque mode has no strip: AppKit's titlebar is above the layer, so
    // the layer's first row is rook's.
    try std.testing.expect(!appKitOwns(400, 1, 1000, 800, 0, 1));
}

test "appKitOwns claims the sides and the bottom, but not the top" {
    try std.testing.expect(appKitOwns(0, 400, 1000, 800, 0, 1));
    try std.testing.expect(appKitOwns(1000, 400, 1000, 800, 0, 1));
    try std.testing.expect(appKitOwns(500, 800, 1000, 800, 0, 1));
    // The top edge of an opaque window's layer is not a resize border —
    // claiming it would cost the tab bar its clicks for nothing.
    try std.testing.expect(!appKitOwns(500, 2, 1000, 800, 0, 1));
    // The middle is rook's, which is nearly all of it.
    try std.testing.expect(!appKitOwns(500, 400, 1000, 800, 0, 1));
}

test "a corner reaches further in than an edge — the diagonal drag" {
    // THE BUG. Ten pixels in from the bottom is past the 5pt edge band,
    // so on an edge it belongs to rook...
    try std.testing.expect(!appKitOwns(500, 790, 1000, 800, 0, 1));
    // ...but at a corner the same depth is AppKit's, because that is what
    // a diagonal grab has to be able to hit. One margin for both would
    // either make corners unhittable or steal a 16pt band from every edge.
    try std.testing.expect(appKitOwns(10, 790, 1000, 800, 0, 1));
    try std.testing.expect(appKitOwns(990, 790, 1000, 800, 0, 1));
    // Just outside the corner square, along both axes.
    try std.testing.expect(!appKitOwns(17, 783, 1000, 800, 0, 1));
}

test "the grab areas are in points, so retina does not halve them" {
    // At 2x, a 5pt edge is 10px. A margin left in pixels would give a
    // retina window half the grab area of a non-retina one — the kind of
    // bug that reads as "resizing feels fussy on this display".
    try std.testing.expect(appKitOwns(500, 791, 1000, 800, 0, 2));
    try std.testing.expect(!appKitOwns(500, 789, 1000, 800, 0, 2));
    // ...and the corner square scales with it: 16pt = 32px.
    try std.testing.expect(appKitOwns(20, 770, 1000, 800, 0, 2));
    try std.testing.expect(!appKitOwns(40, 760, 1000, 800, 0, 2));
}

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

test "wrap breaks at spaces and swallows them" {
    var it = WrapIter{ .s = "one two three four", .cols = 9 };
    try T.expectEqualStrings("one two", it.next().?);
    try T.expectEqualStrings("three", it.next().?);
    try T.expectEqualStrings("four", it.next().?);
    try T.expect(it.next() == null);
}

test "wrap keeps a line that fits exactly, space on the fold included" {
    // "one two" is 7 cells; at 7 the fold lands ON the space after it.
    var it = WrapIter{ .s = "one two three", .cols = 7 };
    try T.expectEqualStrings("one two", it.next().?);
    try T.expectEqualStrings("three", it.next().?);
    try T.expect(it.next() == null);
}

test "an unbreakable run wraps hard instead of vanishing" {
    var it = WrapIter{ .s = "/a/very/long/path/nobody/spaced", .cols = 10 };
    try T.expectEqualStrings("/a/very/lo", it.next().?);
    try T.expectEqualStrings("ng/path/no", it.next().?);
    try T.expectEqualStrings("body/space", it.next().?);
    try T.expectEqualStrings("d", it.next().?);
    try T.expect(it.next() == null);
}

test "a hard wrap never splits a codepoint" {
    var it = WrapIter{ .s = "ééééé", .cols = 3 };
    const first = it.next().?;
    try T.expect(std.unicode.utf8ValidateSlice(first));
    try T.expectEqualStrings("ééé", first);
    try T.expectEqualStrings("éé", it.next().?);
}

test "widening mid-iteration widens the continuation lines" {
    // The first line is narrowed by fields; the rest get the full row.
    var it = WrapIter{ .s = "aa bb cc dd ee ff", .cols = 5 };
    try T.expectEqualStrings("aa bb", it.next().?);
    it.cols = 11;
    try T.expectEqualStrings("cc dd ee ff", it.next().?);
    try T.expect(it.next() == null);
}

test "zero cols yields nothing rather than spinning" {
    var it = WrapIter{ .s = "abc", .cols = 0 };
    try T.expect(it.next() == null);
}
