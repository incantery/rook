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
    /// The side panel, when it is showing: its model and its width.
    /// It owns columns 0..w-1 and the seam at w.
    side: ?struct { model: chromepkg.Model, w: u16 } = null,
    /// Column of the pin rail's seam, and the row it starts on.
    dock_x: ?u16 = null,
    dock_top: u16 = 0,
};

pub const Frame = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// Focused borders, the popup box, the active tab chip.
    accent: chromepkg.Rgb = chromepkg.mauve,

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
    fn putFg(self: *Frame, c: chromepkg.Rgb) void {
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
        cursor_override: ?struct { x: u16, y: u16 },
        popup: ?struct { pane: u32, rect: layoutpkg.Rect },
    ) []const u8 {
        self.buf.clearRetainingCapacity();
        self.put(csi ++ "?2026h" ++ csi ++ "?25l");
        self.put(csi ++ "0m");

        var cursor: ?struct { x: u16, y: u16 } = null;
        var cursor_style: []const u8 = csi ++ "0 q";
        for (placed) |pl| {
            const pane = findPane(panes, pl.pane) orelse continue;
            self.drawPane(pane, pl.rect, full);
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
            self.drawBorders(placed, focused, cols, rows, chrome.dock_x);
            // The side panel and its seam: chrome, so only on a full
            // repaint — nothing in it changes with pane output.
            if (chrome.side) |side| {
                chromepkg.draw(self, side.model, 0, 0, side.w, rows);
                self.seam(side.w, 0, rows);
            }
            // Dock seam: the heavier line between the pin rail and the
            // window. Global (app-chrome) pins run from row 0, past the
            // tab bar; workspace-local pins start under it.
            if (chrome.dock_x) |dx| {
                self.putFg(chromepkg.surface0);
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
        self.cup(chrome.tab_x, 0);
        self.put(chrome.tabbar);
        self.put(csi ++ "0m");

        if (popup) |po| {
            if (findPane(panes, po.pane)) |pp| {
                self.drawBox(po.rect);
                self.drawPane(pp, .{
                    .x = po.rect.x + 1,
                    .y = po.rect.y + 1,
                    .w = po.rect.w -| 2,
                    .h = po.rect.h -| 2,
                }, true);
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
            // copy mode: the mux's cursor, always a visible block
            cursor = .{ .x = co.x, .y = co.y };
            cursor_style = csi ++ "2 q";
        }
        if (cursor) |c| {
            self.cup(c.x, c.y);
            self.put(cursor_style);
            self.put(csi ++ "?25h");
        }
        self.put(csi ++ "?2026l");
        return self.buf.items;
    }

    fn drawPane(self: *Frame, pane: *panepkg.Pane, rect: layoutpkg.Rect, full: bool) void {
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
                self.put(csi ++ "0m");
                var pad: usize = rect.w - vcols;
                while (pad > 0) : (pad -= 1) self.put(" ");
            }
        }
        // pad missing rows (pane taller than grid, transiently)
        if (!full) return;
        var y: usize = vrows;
        while (y < rect.h) : (y += 1) {
            self.cup(rect.x, rect.y + @as(u16, @intCast(y)));
            self.put(csi ++ "0m");
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
        self.drawPane(pane, .{ .x = 0, .y = 0, .w = pane.cols, .h = pane.rows }, true);
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

    /// A full box border for the popup, accent-colored.
    fn drawBox(self: *Frame, r: layoutpkg.Rect) void {
        if (r.w < 2 or r.h < 2) return;
        self.putFg(self.accent);
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
                    self.putFg(if (acc) self.accent else chromepkg.surface0);
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
                    self.putFg(if (acc) self.accent else chromepkg.surface0);
                    self.cup(r.x, r.y + r.h);
                    var x: u16 = 0;
                    while (x < r.w) : (x += 1) self.put("─");
                }
            }
        }
        self.put(csi ++ "0m");
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

    fn from(st: vt.Style, raw: anytype, colors: anytype) Sgr {
        var s: Sgr = .{
            .bold = st.flags.bold,
            .italic = st.flags.italic,
            .underline = st.flags.underline != .none,
            .inverse = st.flags.inverse,
            .strikethrough = st.flags.strikethrough,
            .faint = st.flags.faint,
        };
        if (st.bg(raw, &colors.palette)) |bg| {
            if (!bg.eql(colors.background)) s.bg = bg;
        }
        const fg = st.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        if (!fg.eql(colors.foreground)) s.fg = fg;
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
        if (self.strikethrough) f.put(";9");
        if (self.fg) |c| f.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        if (self.bg) |c| f.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        f.put("m");
    }
};
