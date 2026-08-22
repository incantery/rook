//! Frame builder: RenderState grids → one VT byte string for the
//! client's whole screen, wrapped in synchronized output. The client
//! is dumb glass: it writes these bytes and nothing else.
const std = @import("std");
const vt = @import("ghostty-vt");
const layoutpkg = @import("layout.zig");
const panepkg = @import("pane.zig");

const csi = "\x1b[";

pub const Frame = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Frame {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Frame) void {
        self.buf.deinit(self.gpa);
    }

    fn put(self: *Frame, bytes: []const u8) void {
        self.buf.appendSlice(self.gpa, bytes) catch {};
    }
    fn print(self: *Frame, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.gpa, fmt, args) catch {};
    }
    fn cup(self: *Frame, x: u16, y: u16) void {
        self.print(csi ++ "{d};{d}H", .{ @as(u32, y) + 1, @as(u32, x) + 1 });
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
        status: []const u8,
        full: bool,
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

        if (full) self.drawBorders(placed, focused, cols, rows);

        // Status line: bottom row, inverse. Cheap; always emitted.
        self.cup(0, rows - 1);
        self.put(csi ++ "0;7m ");
        const max: usize = if (cols > 2) cols - 2 else 0;
        self.put(status[0..@min(status.len, max)]);
        var pad: usize = @intCast(cols -| 1 -| @min(status.len, max));
        while (pad > 0) : (pad -= 1) self.put(" ");
        self.put(csi ++ "0m");

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

    /// Borders: the column/row gaps place() left between rects.
    fn drawBorders(self: *Frame, placed: []const layoutpkg.Placed, focused: u32, cols: u16, rows: u16) void {
        _ = cols;
        for (placed) |pl| {
            const r = pl.rect;
            const acc = pl.pane == focused;
            // right border, if there's a gap column to our right
            if (hasNeighbor(placed, r.x + r.w + 1, r.y)) {
                self.put(if (acc) csi ++ "0;33m" else csi ++ "0;90m");
                var y: u16 = r.y;
                while (y < r.y + r.h and y < rows - 1) : (y += 1) {
                    self.cup(r.x + r.w, y);
                    self.put("│");
                }
            }
            // bottom border
            if (r.y + r.h + 1 < rows and hasNeighborBelow(placed, r.x, r.y + r.h + 1)) {
                self.put(if (acc) csi ++ "0;33m" else csi ++ "0;90m");
                self.cup(r.x, r.y + r.h);
                var x: u16 = 0;
                while (x < r.w) : (x += 1) self.put("─");
            }
        }
        self.put(csi ++ "0m");
    }
};

fn hasNeighbor(placed: []const layoutpkg.Placed, x: u16, y: u16) bool {
    for (placed) |p| {
        if (p.rect.x == x and y >= p.rect.y and y < p.rect.y + p.rect.h) return true;
    }
    return false;
}
fn hasNeighborBelow(placed: []const layoutpkg.Placed, x: u16, y: u16) bool {
    for (placed) |p| {
        if (p.rect.y == y and x >= p.rect.x and x < p.rect.x + p.rect.w) return true;
    }
    return false;
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
