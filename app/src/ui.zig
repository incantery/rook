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

    /// A hairline is ONE device pixel at every scale. `App.sep` is the
    /// same number (it is also the split gap); this is only its name
    /// when it is being used as a rule.
    pub fn compute(scale: f32, cell_h: f32) Metrics {
        return .{
            .gutter = @round(10 * scale),
            .pane_pad = @round(6 * scale),
            .row = @ceil(cell_h + @round(10 * scale)),
            .gap = @round(6 * scale),
        };
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

    /// Draw a text run at pixel (x, y); returns its pixel width.
    pub fn text(self: *Ui, x: f32, y: f32, str: []const u8, fg: [4]u8, bg: [4]u8) f32 {
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
        if (n == 0) return 0;
        self.r.drawGrid(self.enc, self.vp_w, self.vp_h, x, y, self.off, @intCast(n), 1);
        self.off += n;
        return @as(f32, @floatFromInt(n)) * self.r.cell_w;
    }

    /// Right-aligned text: the run ends at pixel `right_x`.
    pub fn textRight(self: *Ui, right_x: f32, y: f32, str: []const u8, fg: [4]u8, bg: [4]u8) f32 {
        const count = std.unicode.utf8CountCodepoints(str) catch str.len;
        const w = @as(f32, @floatFromInt(count)) * self.r.cell_w;
        return self.text(right_x - w, y, str, fg, bg);
    }
};
