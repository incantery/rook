//! Frame builder: RenderState grids → one VT byte string for the
//! client's whole screen, wrapped in synchronized output. The client
//! is dumb glass: it writes these bytes and nothing else.
const std = @import("std");
const vt = @import("ghostty-vt");
const layoutpkg = @import("layout.zig");
const panepkg = @import("pane.zig");
const chromepkg = @import("chrome.zig");

const csi = "\x1b[";

/// Everything on the screen that is not a pane: the tab bar, the side
/// panel, and the seams that separate them from the panes.
pub const Chrome = struct {
    /// Pre-sized to exactly (cols - tab_x) visible columns.
    tabbar: []const u8,
    /// Column the tab bar starts at — the side panel pushes it right.
    tab_x: u16 = 0,
    /// Row its words are on: 0, or 1 in a three-row bar (the rows
    /// around it are the server's, painted in the overlay).
    tab_y: u16 = 0,
    /// The side panel, when it is showing: its model, its width, and
    /// how much of itself it is showing (`chrome.SideMode`). It owns
    /// columns 0..w-1 and the seam at w. Hidden is `null` here — the
    /// mode that costs no columns costs no branch either.
    side: ?struct { model: chromepkg.Model, w: u16, mode: chromepkg.SideMode = .open } = null,
    /// Column of the pin rail's seam, and the row it starts on.
    dock_x: ?u16 = null,
    dock_top: u16 = 0,
    /// The calm bar: pre-sized to `cols` columns, painted on row
    /// `bar_y` (the last row of the glass). Null when the bar is off.
    bar: ?Bar = null,
    /// Chrome the server composed itself and wants painted over the
    /// panes, after them and before the cursor: the altitude view,
    /// the ownership gate, the inspector. Raw frame bytes, from a
    /// second Frame; empty when there is none.
    overlay: []const u8 = "",
};

/// The calm bar as painted: its row and its pre-sized bytes.
pub const Bar = struct { y: u16, bytes: []const u8 };

/// Where the composed cursor goes when the mux owns it: copy mode's
/// block, or the altitude input's bar — or nowhere, while the gate
/// or the inspector holds the keys and no pane should show one.
pub const CursorOverride = struct { x: u16, y: u16, bar: bool = false, hidden: bool = false };

/// How a pane is put on the glass, beyond where.
///
/// A popup is the one lit plane while it is up. Two things make that
/// true rather than hoped for. The world behind it is drawn under a
/// `scrim`: every cell faint, and what colour it had pulled most of the
/// way to the ground, so it is still there to glance at and no longer
/// competes to be read. And the popup itself may stand on a `ground`:
/// cells the program left unpainted are painted with the background it
/// asked for, so a translucent terminal's wallpaper and whatever was
/// underneath stop showing through the one thing being read. A program
/// that never named a background (fzf, a shell) keeps the glass's own.
pub const Paint = struct {
    scrim: bool = false,
    ground: ?vt.color.RGB = null,
};

fn toward(c: vt.color.RGB, to: vt.color.RGB, pct: u16) vt.color.RGB {
    const mix = struct {
        fn f(a: u8, b: u8, p: u16) u8 {
            return @intCast((@as(u16, a) * (100 - p) + @as(u16, b) * p) / 100);
        }
    }.f;
    return .{ .r = mix(c.r, to.r, pct), .g = mix(c.g, to.g, pct), .b = mix(c.b, to.b, pct) };
}

pub const Frame = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// Focused borders, the popup box, the active tab chip.
    accent: chromepkg.Rgb = chromepkg.mauve,
    /// Inactive seams and the dock: visible over transparency, never
    /// boxing the work (`ui.Theme.border`).
    border: chromepkg.Rgb = chromepkg.surface0,

    pub fn init(gpa: std.mem.Allocator) Frame {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Frame) void {
        self.buf.deinit(self.gpa);
    }

    // pub: chrome.zig paints the side panel through these
    pub fn put(self: *Frame, bytes: []const u8) void {
        self.buf.appendSlice(self.gpa, bytes) catch {};
    }
    pub fn print(self: *Frame, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.gpa, fmt, args) catch {};
    }
    pub fn cup(self: *Frame, x: u16, y: u16) void {
        self.print(csi ++ "{d};{d}H", .{ @as(u32, y) + 1, @as(u32, x) + 1 });
    }
    /// Reset, then a 24-bit foreground.
    pub fn putFg(self: *Frame, c: chromepkg.Rgb) void {
        self.print(csi ++ "0;38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    }
    /// A light vertical rule at column `x`, rows [y0, y1).
    fn seam(self: *Frame, x: u16, y0: u16, y1: u16) void {
        self.putFg(chromepkg.surface0);
        var y: u16 = y0;
        while (y < y1) : (y += 1) {
            self.cup(x, y);
            self.put("│");
        }
        self.put(csi ++ "0m");
    }

    /// Build a frame. `full` repaints everything (attach, resize,
    /// layout or focus change); otherwise only rows RenderState marked
    /// dirty since the last frame are emitted — the poor man's cell
    /// protocol, and the shape the real one will keep.
    pub fn build(
        self: *Frame,
        panes: []const *panepkg.Pane,
        placed: []const layoutpkg.Placed,
        focused: u32,
        cols: u16,
        rows: u16,
        chrome: Chrome,
        full: bool,
        /// start from an empty glass (inside the synchronized update,
        /// so a terminal that honours it shows no blank frame)
        clear: bool,
        cursor_override: ?CursorOverride,
        popup: ?struct { pane: u32, rect: layoutpkg.Rect },
    ) []const u8 {
        self.buf.clearRetainingCapacity();
        self.put(csi ++ "?2026h" ++ csi ++ "?25l");
        self.put(csi ++ "0m");
        if (clear) self.put(csi ++ "2J");

        var cursor: ?struct { x: u16, y: u16 } = null;
        var cursor_style: []const u8 = csi ++ "0 q";
        for (placed) |pl| {
            const pane = findPane(panes, pl.pane) orelse continue;
            self.drawPane(pane, pl.rect, full, .{ .scrim = popup != null });
            if (pl.pane == focused) {
                const cur = pane.rs.cursor;
                // DECSCUSR: the focused pane's cursor shape is the
                // screen's (nvim beam-in-insert must read through).
                cursor_style = switch (cur.visual_style) {
                    .block => csi ++ "2 q",
                    .underline => csi ++ "4 q",
                    .bar => csi ++ "6 q",
                    else => csi ++ "0 q",
                };
                if (cur.visible) if (cur.viewport) |v| {
                    if (v.x < pl.rect.w and v.y < pl.rect.h)
                        cursor = .{ .x = pl.rect.x + v.x, .y = pl.rect.y + v.y };
                };
            }
        }

        if (full) {
            // under a popup no pane is the focused one: the accent is the popup's
            self.drawBorders(placed, if (popup != null) 0 else focused, cols, rows, chrome.dock_x);
            // The side panel and its seam: chrome, so only on a full
            // repaint — nothing in it changes with pane output.
            if (chrome.side) |side| {
                switch (side.mode) {
                    .collapsed => chromepkg.drawCollapsed(self, side.model, 0, 0, side.w, rows),
                    else => chromepkg.draw(self, side.model, 0, 0, side.w, rows),
                }
                self.seam(side.w, 0, rows);
            }
            // Dock seam: the heavier line between the pin rail and the
            // window. Global (app-chrome) pins run from row 0, past the
            // tab bar; workspace-local pins start under it.
            if (chrome.dock_x) |dx| {
                self.putFg(self.border);
                var y: u16 = chrome.dock_top;
                while (y < rows) : (y += 1) {
                    self.cup(dx, y);
                    self.put("┃");
                }
                self.put(csi ++ "0m");
            }
        }

        // Tab bar: top row, starting past whatever chrome pushed it
        // right. `tabbar` is pre-sized to (cols - tab_x) columns.
        self.cup(chrome.tab_x, chrome.tab_y);
        self.put(chrome.tabbar);
        self.put(csi ++ "0m");
        if (chrome.bar) |bar| {
            self.cup(0, bar.y);
            self.put(bar.bytes);
            self.put(csi ++ "0m");
        }
        // The server's own overlay goes on top of every pane and
        // under the popup: the altitude view is the world, and a
        // popup is still a popup over it.
        if (chrome.overlay.len > 0) {
            self.put(chrome.overlay);
            self.put(csi ++ "0m");
        }

        if (popup) |po| {
            if (findPane(panes, po.pane)) |pp| {
                self.drawBox(po.rect, pp.ground);
                self.drawPane(pp, .{
                    .x = po.rect.x + 1,
                    .y = po.rect.y + 1,
                    .w = po.rect.w -| 2,
                    .h = po.rect.h -| 2,
                }, true, .{ .ground = pp.ground });
                // the popup owns the cursor while it is up
                cursor = null;
                const cur = pp.rs.cursor;
                if (cur.visible) if (cur.viewport) |v| {
                    if (v.x < po.rect.w -| 2 and v.y < po.rect.h -| 2)
                        cursor = .{ .x = po.rect.x + 1 + v.x, .y = po.rect.y + 1 + v.y };
                };
                cursor_style = switch (cur.visual_style) {
                    .block => csi ++ "2 q",
                    .underline => csi ++ "4 q",
                    .bar => csi ++ "6 q",
                    else => csi ++ "0 q",
                };
            }
        }
        if (cursor_override) |co| {
            // the mux's own cursor: copy mode's block, the input's bar
            cursor = if (co.hidden) null else .{ .x = co.x, .y = co.y };
            cursor_style = if (co.bar) csi ++ "6 q" else csi ++ "2 q";
        }
        if (cursor) |c| {
            self.cup(c.x, c.y);
            self.put(cursor_style);
            self.put(csi ++ "?25h");
        }
        self.put(csi ++ "?2026l");
        return self.buf.items;
    }

    /// Paint a pane's grid into an arbitrary rect of this frame.
    /// The overlay is a frame too, and a hosted terminal — vera's
    /// chat in her panel — is a pane the server draws inside its own
    /// chrome rather than through the window layout. Always a full
    /// repaint: the overlay is rebuilt from nothing every frame it is
    /// needed, so row-dirty means nothing here.
    pub fn drawPaneIn(self: *Frame, pane: *panepkg.Pane, rect: layoutpkg.Rect) void {
        self.drawPane(pane, rect, true, .{});
    }

    fn drawPane(self: *Frame, pane: *panepkg.Pane, rect: layoutpkg.Rect, full: bool, paint: Paint) void {
        var blank: Sgr = .{ .bg = paint.ground };
        blank.faint = paint.scrim;
        const rs = &pane.rs;
        const colors = &rs.colors;
        const row_cells = rs.row_data.items(.cells);
        const row_dirty = rs.row_data.items(.dirty);
        const row_sels = rs.row_data.items(.selection);
        const vrows: usize = @min(rect.h, rs.rows);
        for (0..vrows) |y| {
            if (!full and !row_dirty[y]) continue;
            row_dirty[y] = false;
            self.cup(rect.x, rect.y + @as(u16, @intCast(y)));
            self.put(csi ++ "0m");
            var last_sgr: Sgr = .{};
            if (paint.ground != null) {
                blank.emit(self);
                last_sgr = blank;
            }
            const raws = row_cells[y].items(.raw);
            const styles = row_cells[y].items(.style);
            const graphemes = row_cells[y].items(.grapheme);
            const vcols: usize = @min(rect.w, rs.cols);
            var x: usize = 0;
            while (x < vcols) : (x += 1) {
                const raw = &raws[x];
                const styled = raw.style_id != 0;
                const st: vt.Style = if (styled) styles[x] else .{};
                var sgr = Sgr.from(st, raw, colors);
                if (row_sels[y]) |sr| {
                    if (x >= sr[0] and x <= sr[1]) sgr.inverse = !sgr.inverse;
                }
                if (paint.scrim) {
                    sgr.faint = true;
                    sgr.bold = false;
                    if (sgr.fg) |c| sgr.fg = toward(c, colors.background, 45);
                    if (sgr.bg) |c| sgr.bg = toward(c, colors.background, 65);
                }
                if (sgr.bg == null) sgr.bg = paint.ground;
                // A wide glyph's tail is covered by its head cell.
                if (raw.wide == .spacer_tail) continue;
                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };
                if (!sgr.eql(last_sgr)) {
                    sgr.emit(self);
                    last_sgr = sgr;
                }
                if (cp <= 32) {
                    self.put(" ");
                    continue;
                }
                var cbuf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &cbuf) catch {
                    self.put(" ");
                    continue;
                };
                self.put(cbuf[0..n]);
                if (raw.content_tag == .codepoint_grapheme) {
                    for (graphemes[x]) |extra| {
                        var eb: [4]u8 = undefined;
                        const en = std.unicode.utf8Encode(extra, &eb) catch continue;
                        self.put(eb[0..en]);
                    }
                }
            }
            // pad the remainder of the pane width
            if (rect.w > vcols) {
                blank.emit(self);
                var pad: usize = rect.w - vcols;
                while (pad > 0) : (pad -= 1) self.put(" ");
            }
        }
        // pad missing rows (pane taller than grid, transiently)
        if (!full) return;
        var y: usize = vrows;
        while (y < rect.h) : (y += 1) {
            self.cup(rect.x, rect.y + @as(u16, @intCast(y)));
            blank.emit(self);
            var pad: usize = rect.w;
            while (pad > 0) : (pad -= 1) self.put(" ");
        }
    }

    /// A block client's attach snapshot: clear, full repaint of the
    /// pane at origin, cursor state. The client's own VT state machine
    /// starts here and then follows the raw tee.
    pub fn blockSnapshot(self: *Frame, pane: *panepkg.Pane) []const u8 {
        self.buf.clearRetainingCapacity();
        self.put(csi ++ "?2026h");
        self.put(csi ++ "2J" ++ csi ++ "H" ++ csi ++ "0m");
        self.drawPane(pane, .{ .x = 0, .y = 0, .w = pane.cols, .h = pane.rows }, true, .{});
        const cur = pane.rs.cursor;
        if (cur.visible) {
            if (cur.viewport) |v| {
                self.cup(v.x, v.y);
                self.put(switch (cur.visual_style) {
                    .block => csi ++ "2 q",
                    .underline => csi ++ "4 q",
                    .bar => csi ++ "6 q",
                    else => csi ++ "0 q",
                });
                self.put(csi ++ "?25h");
            }
        } else {
            self.put(csi ++ "?25l");
        }
        self.put(csi ++ "?2026l");
        return self.buf.items;
    }

    /// A pane's viewport as plain text: one line per row, trailing
    /// blanks trimmed, no SGR and no cursor. What a phone, a rail
    /// preview, or anything that wants to *read* a pane needs — and
    /// the thing that stops such a client having to re-parse the VT
    /// frame this file just wrote.
    pub fn plainText(self: *Frame, pane: *panepkg.Pane) []const u8 {
        self.buf.clearRetainingCapacity();
        gridText(self.gpa, &self.buf, &pane.rs);
        return self.buf.items;
    }

    /// The popup's border. It is quiet — a lifted neutral, not the
    /// accent: with the world behind it under a scrim the popup does
    /// not need a bright line to be found, and the accent is left for
    /// what is live inside it. It stands on the popup's ground, so the
    /// plane has one edge rather than a line floating beside it.
    fn drawBox(self: *Frame, r: layoutpkg.Rect, ground: ?vt.color.RGB) void {
        if (r.w < 2 or r.h < 2) return;
        self.putFg(chromepkg.overlay0);
        if (ground) |g| self.print(csi ++ "48;2;{d};{d};{d}m", .{ g.r, g.g, g.b });
        self.boxLines(r);
    }

    /// A box border in any color — the inspector and the altitude
    /// figures draw theirs through this.
    pub fn drawBoxIn(self: *Frame, r: layoutpkg.Rect, color: chromepkg.Rgb) void {
        if (r.w < 2 or r.h < 2) return;
        self.putFg(color);
        self.boxLines(r);
    }

    /// The lines of a box, in whatever colours are set.
    fn boxLines(self: *Frame, r: layoutpkg.Rect) void {
        self.cup(r.x, r.y);
        self.put("┌");
        var x: u16 = 1;
        while (x < r.w - 1) : (x += 1) self.put("─");
        self.put("┐");
        var y: u16 = r.y + 1;
        while (y < r.y + r.h - 1) : (y += 1) {
            self.cup(r.x, y);
            self.put("│");
            self.cup(r.x + r.w - 1, y);
            self.put("│");
        }
        self.cup(r.x, r.y + r.h - 1);
        self.put("└");
        x = 1;
        while (x < r.w - 1) : (x += 1) self.put("─");
        self.put("┘");
        self.put(csi ++ "0m");
    }

    /// Borders: the column/row gaps place() left between rects.
    fn drawBorders(self: *Frame, placed: []const layoutpkg.Placed, focused: u32, cols: u16, rows: u16, dock_x: ?u16) void {
        _ = cols;
        for (placed) |pl| {
            const r = pl.rect;
            // right border, if there's a gap column to our right; it
            // lights up when either side of the gap is focused. The
            // rail/window seam is heavier: a dock, not a split.
            if (neighborAt(placed, r.x + r.w + 1, r.y)) |nb| {
                // The rail/window dock seam is drawn by build() (it spans
                // the full rail height, which may differ from this rect);
                // here we only draw the light │ between window splits.
                const is_dock = dock_x != null and dock_x.? == r.x + r.w;
                if (!is_dock) {
                    const acc = pl.pane == focused or nb == focused;
                    self.putFg(if (acc) self.accent else self.border);
                    var y: u16 = r.y;
                    while (y < r.y + r.h and y < rows) : (y += 1) {
                        self.cup(r.x + r.w, y);
                        self.put("│");
                    }
                }
            }
            // bottom border
            if (r.y + r.h + 1 < rows) {
                if (neighborBelowAt(placed, r.x, r.y + r.h + 1)) |nb| {
                    const acc = pl.pane == focused or nb == focused;
                    self.putFg(if (acc) self.accent else self.border);
                    self.cup(r.x, r.y + r.h);
                    var x: u16 = 0;
                    while (x < r.w) : (x += 1) self.put("─");
                }
            }
        }
        self.put(csi ++ "0m");
    }
};

/// One cell's codepoint, 0 for a blank, and null for the tail of a
/// wide glyph (its head cell carried it).
fn cellCp(raw: anytype) ?u21 {
    if (raw.wide == .spacer_tail) return null;
    const cp: u21 = switch (raw.content_tag) {
        .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
        else => 0,
    };
    // a control byte in a cell (DEL, typed at a pane) shows as nothing
    return if (cp <= 32 or cp == 0x7f) 0 else cp;
}

/// A cell's glyph as UTF-8, a blank as one space.
fn putCell(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21, raw: anytype, extras: []const u21) void {
    var cbuf: [4]u8 = undefined;
    const n = if (cp == 0) 0 else std.unicode.utf8Encode(cp, &cbuf) catch 0;
    if (n == 0) {
        out.append(gpa, ' ') catch {};
        return;
    }
    out.appendSlice(gpa, cbuf[0..n]) catch {};
    if (raw.content_tag == .codepoint_grapheme) {
        for (extras) |extra| {
            var eb: [4]u8 = undefined;
            const en = std.unicode.utf8Encode(extra, &eb) catch continue;
            out.appendSlice(gpa, eb[0..en]) catch {};
        }
    }
}

/// A grid as plain text: one line per row, trailing blanks trimmed.
/// A pane's (`Frame.plainText`), or the whole glass's (`rook shot`).
pub fn gridText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), rs: *vt.RenderState) void {
    const row_cells = rs.row_data.items(.cells);
    for (0..rs.rows) |y| {
        const raws = row_cells[y].items(.raw);
        const graphemes = row_cells[y].items(.grapheme);
        var trimmed = out.items.len;
        for (0..rs.cols) |x| {
            const cp = cellCp(&raws[x]) orelse continue;
            putCell(gpa, out, cp, &raws[x], if (raws[x].content_tag == .codepoint_grapheme) graphemes[x] else &.{});
            if (cp != 0) trimmed = out.items.len;
        }
        out.shrinkRetainingCapacity(trimmed);
        out.append(gpa, '\n') catch {};
    }
}

fn sgrBytes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: Sgr) void {
    out.appendSlice(gpa, csi ++ "0") catch {};
    if (s.bold) out.appendSlice(gpa, ";1") catch {};
    if (s.faint) out.appendSlice(gpa, ";2") catch {};
    if (s.italic) out.appendSlice(gpa, ";3") catch {};
    if (s.underline) out.appendSlice(gpa, ";4") catch {};
    if (s.inverse) out.appendSlice(gpa, ";7") catch {};
    if (s.invisible) out.appendSlice(gpa, ";8") catch {};
    if (s.strikethrough) out.appendSlice(gpa, ";9") catch {};
    if (s.fg) |c| out.print(gpa, ";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
    if (s.bg) |c| out.print(gpa, ";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
    out.append(gpa, 'm') catch {};
}

/// A grid as text with its colours: one line per row, SGR runs, each
/// line reset at its end — `cat` it into a terminal and it is the
/// picture.
pub fn gridAnsi(gpa: std.mem.Allocator, out: *std.ArrayList(u8), rs: *vt.RenderState) void {
    const row_cells = rs.row_data.items(.cells);
    for (0..rs.rows) |y| {
        const raws = row_cells[y].items(.raw);
        const styles = row_cells[y].items(.style);
        const graphemes = row_cells[y].items(.grapheme);
        var last: Sgr = .{};
        for (0..rs.cols) |x| {
            const raw = &raws[x];
            const cp = cellCp(raw) orelse continue;
            const st: vt.Style = if (raw.style_id != 0) styles[x] else .{};
            const sgr = Sgr.from(st, raw, &rs.colors);
            if (!sgr.eql(last)) {
                sgrBytes(gpa, out, sgr);
                last = sgr;
            }
            putCell(gpa, out, cp, raw, if (raw.content_tag == .codepoint_grapheme) graphemes[x] else &.{});
        }
        out.appendSlice(gpa, csi ++ "0m\n") catch {};
    }
}

fn jsonStr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => out.appendSlice(gpa, "\\\"") catch return,
        '\\' => out.appendSlice(gpa, "\\\\") catch return,
        0...31 => out.print(gpa, "\\u{x:0>4}", .{c}) catch return,
        else => out.append(gpa, c) catch return,
    };
    out.append(gpa, '"') catch return;
}

fn jsonRgb(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, c: ?vt.color.RGB) void {
    const v = c orelse return;
    out.print(gpa, ",\"{s}\":\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ key, v.r, v.g, v.b }) catch {};
}

/// A grid as JSON, for a program that asserts on what is shown:
///   {"cols":N,"rows":N,"cursor":{"x","y","visible"},
///    "panes":[{"id","x","y","w","h","focused"}],     (the glass only)
///    "lines":[{"y":0,"text":"…","bg":"#rrggbb","runs":[{"x":0,"w":4,"text":"main",
///      "fg":"#rrggbb","bg":"#rrggbb","bold":true}]}]}
/// A run is a stretch of cells in one style, `x` and `w` in cells: one
/// character a cell, except a run marked `"cluster":true`, which is one
/// glyph — a wide one, or several codepoints — in its `w` cells. A
/// colour that is absent is the terminal's own; a flag that is absent
/// is off. Blank stretches in the default style are left out, and a
/// default-style run ends at its last glyph. A line's own `bg` is there
/// when one background runs edge to edge.
pub fn gridJson(gpa: std.mem.Allocator, out: *std.ArrayList(u8), rs: *vt.RenderState, extra: []const u8) void {
    out.print(gpa, "{{\"cols\":{d},\"rows\":{d},\"cursor\":", .{ rs.cols, rs.rows }) catch return;
    if (rs.cursor.viewport) |v| {
        out.print(gpa, "{{\"x\":{d},\"y\":{d},\"visible\":{s}}}", .{ v.x, v.y, if (rs.cursor.visible) "true" else "false" }) catch return;
    } else out.appendSlice(gpa, "null") catch return;
    out.appendSlice(gpa, extra) catch return;
    out.appendSlice(gpa, ",\"lines\":[") catch return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const row_cells = rs.row_data.items(.cells);
    for (0..rs.rows) |y| {
        const raws = row_cells[y].items(.raw);
        const styles = row_cells[y].items(.style);
        const graphemes = row_cells[y].items(.grapheme);
        if (y > 0) out.append(gpa, ',') catch return;
        out.print(gpa, "{{\"y\":{d},\"text\":", .{y}) catch return;
        // the line, trimmed
        text.clearRetainingCapacity();
        var trimmed: usize = 0;
        for (0..rs.cols) |x| {
            const cp = cellCp(&raws[x]) orelse continue;
            putCell(gpa, &text, cp, &raws[x], if (raws[x].content_tag == .codepoint_grapheme) graphemes[x] else &.{});
            if (cp != 0) trimmed = text.items.len;
        }
        jsonStr(gpa, out, text.items[0..trimmed]);
        // one background edge to edge: the row is a filled bar
        var row_bg: ?vt.color.RGB = null;
        for (0..rs.cols) |cx| {
            const st: vt.Style = if (raws[cx].style_id != 0) styles[cx] else .{};
            const sg = Sgr.from(st, &raws[cx], &rs.colors);
            const bg = if (sg.inverse) (sg.fg orelse rs.colors.foreground) else sg.bg;
            if (bg == null or (cx > 0 and !std.meta.eql(row_bg, bg))) {
                row_bg = null;
                break;
            }
            row_bg = bg;
        }
        jsonRgb(gpa, out, "bg", row_bg);
        out.appendSlice(gpa, ",\"runs\":[") catch return;
        // the runs
        var n_runs: usize = 0;
        var x: usize = 0;
        while (x < rs.cols) {
            const st0: vt.Style = if (raws[x].style_id != 0) styles[x] else .{};
            const sgr = Sgr.from(st0, &raws[x], &rs.colors);
            const x0 = x;
            text.clearRetainingCapacity();
            var inked = false;
            // A cell that is not one codepoint in one column — a wide
            // glyph, a grapheme of several codepoints — is a run of its
            // own, marked `cluster`: a reader counts cells by counting
            // characters everywhere else, and must not have to know
            // this terminal's width table to stay in step.
            var cluster = false;
            while (x < rs.cols) : (x += 1) {
                const raw = &raws[x];
                const st: vt.Style = if (raw.style_id != 0) styles[x] else .{};
                if (!Sgr.from(st, raw, &rs.colors).eql(sgr)) break;
                const cp = cellCp(raw) orelse continue;
                const special = raw.wide == .wide or raw.content_tag == .codepoint_grapheme;
                if (special and x != x0) break;
                if (cp != 0) inked = true;
                putCell(gpa, &text, cp, raw, if (raw.content_tag == .codepoint_grapheme) graphemes[x] else &.{});
                if (special) {
                    cluster = true;
                    x += 1;
                    while (x < rs.cols and raws[x].wide == .spacer_tail) x += 1;
                    break;
                }
            }
            if (!inked and sgr.eql(.{})) continue;
            // a run in the default style ends at its last glyph: the
            // blanks after it are nothing
            var run_text: []const u8 = text.items;
            var run_w = x - x0;
            if (sgr.eql(.{})) {
                while (run_text.len > 0 and run_text[run_text.len - 1] == ' ') {
                    run_text = run_text[0 .. run_text.len - 1];
                    run_w -= 1;
                }
            }
            if (n_runs > 0) out.append(gpa, ',') catch return;
            n_runs += 1;
            out.print(gpa, "{{\"x\":{d},\"w\":{d},\"text\":", .{ x0, run_w }) catch return;
            jsonStr(gpa, out, run_text);
            if (cluster) out.appendSlice(gpa, ",\"cluster\":true") catch return;
            jsonRgb(gpa, out, "fg", sgr.fg);
            jsonRgb(gpa, out, "bg", sgr.bg);
            inline for (.{ "bold", "faint", "italic", "underline", "inverse", "strikethrough", "invisible" }) |flag| {
                if (@field(sgr, flag)) out.appendSlice(gpa, ",\"" ++ flag ++ "\":true") catch return;
            }
            out.append(gpa, '}') catch return;
        }
        out.appendSlice(gpa, "]}") catch return;
    }
    out.appendSlice(gpa, "]}\n") catch return;
}

/// The glass a frame would paint, as a grid: a terminal of that size
/// fed the frame's own bytes. What `rook shot` reads is therefore what
/// the render path wrote, not a second opinion of it.
pub const Shadow = struct {
    term: vt.Terminal,
    rs: vt.RenderState = .empty,
    gpa: std.mem.Allocator,

    pub fn init(self: *Shadow, gpa: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, frame: []const u8) !void {
        self.* = .{ .gpa = gpa, .term = try .init(io, gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 0 }) };
        errdefer self.term.deinit(gpa);
        var stream: vt.TerminalStream = .init(.{ .handler = self.term.vtHandler(), .allocator = gpa });
        defer stream.deinit();
        stream.nextSlice(frame);
        try self.rs.update(gpa, &self.term);
    }

    pub fn deinit(self: *Shadow) void {
        self.rs.deinit(self.gpa);
        self.term.deinit(self.gpa);
    }
};

fn neighborAt(placed: []const layoutpkg.Placed, x: u16, y: u16) ?u32 {
    for (placed) |p| {
        if (p.rect.x == x and y >= p.rect.y and y < p.rect.y + p.rect.h) return p.pane;
    }
    return null;
}
fn neighborBelowAt(placed: []const layoutpkg.Placed, x: u16, y: u16) ?u32 {
    for (placed) |p| {
        if (p.rect.y == y and x >= p.rect.x and x < p.rect.x + p.rect.w) return p.pane;
    }
    return null;
}

fn findPane(panes: []const *panepkg.Pane, id: u32) ?*panepkg.Pane {
    for (panes) |p| {
        if (p.id == id) return p;
    }
    return null;
}

/// One cell's effective SGR, comparable so runs collapse.
const Sgr = struct {
    fg: ?vt.color.RGB = null, // null = default
    bg: ?vt.color.RGB = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    faint: bool = false,
    /// SGR 8, conceal: the cell has its glyph and does not show it.
    invisible: bool = false,

    fn from(st: vt.Style, raw: anytype, colors: anytype) Sgr {
        var s: Sgr = .{
            .bold = st.flags.bold,
            .italic = st.flags.italic,
            .underline = st.flags.underline != .none,
            .inverse = st.flags.inverse,
            .strikethrough = st.flags.strikethrough,
            .faint = st.flags.faint,
            .invisible = st.flags.invisible,
        };
        // A colour is the terminal's own when the program named none —
        // not when the one it named happens to equal a default: white
        // text and a black fill a program asked for are asked for,
        // whatever the terminal behind the glass calls its own.
        if (st.bg(raw, &colors.palette)) |bg| s.bg = bg;
        if (st.fg_color != .none) s.fg = st.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        return s;
    }

    fn eql(a: Sgr, b: Sgr) bool {
        return std.meta.eql(a, b);
    }

    fn emit(self: Sgr, f: *Frame) void {
        f.put(csi ++ "0");
        if (self.bold) f.put(";1");
        if (self.faint) f.put(";2");
        if (self.italic) f.put(";3");
        if (self.underline) f.put(";4");
        if (self.inverse) f.put(";7");
        if (self.invisible) f.put(";8");
        if (self.strikethrough) f.put(";9");
        if (self.fg) |c| f.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        if (self.bg) |c| f.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        f.put("m");
    }
};

test "a scrim pulls a colour most of the way to the ground, and never past it" {
    const bright: vt.color.RGB = .{ .r = 250, .g = 128, .b = 25 };
    const ground: vt.color.RGB = .{ .r = 20, .g = 22, .b = 31 };
    const dimmed = toward(bright, ground, 45);
    try std.testing.expect(dimmed.r < bright.r and dimmed.r > ground.r);
    try std.testing.expect(dimmed.g < bright.g and dimmed.g > ground.g);
    try std.testing.expectEqual(bright, toward(bright, ground, 0));
    try std.testing.expectEqual(ground, toward(bright, ground, 100));
}
