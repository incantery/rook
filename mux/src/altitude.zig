//! Altitude: rook scope, the layer above a space.
//!
//! `prefix-o` zooms out. The current space contracts into a figure —
//! its layout skeleton, each pane's relative place and title kept —
//! and the other spaces resolve around it as rows: a name, an event
//! line rook can vouch for, and the tab row under it. Global pins do
//! not move a column: scope is taught by what refuses to move. The
//! calm bar stays. Esc zooms back in to the exact pane, cursor and
//! scroll, because nothing was moved to get here — the panes kept
//! running underneath, and this file only painted over them.
//!
//! One input, already focused. Bare text fuzzy-finds spaces, tabs and
//! panes; `:` prefixes an exact command with completions; the last
//! row, `✦ vera:`, hands the same text to the companion — and only by
//! choosing that row. Typing never acts; `↵` on a visible row does.
//!
//! Two fidelities, one model. Orbit draws the figure when the glass
//! has room for one; Ledger is the same rows with no figure, for
//! narrow glass, `zoom_view = "ledger"`, and every renderer that is
//! not this one. Identical keys, identical rows, zero loss.
//!
//! This file holds the model, the painter and the input state. It
//! knows nothing about sessions: the server builds the rows from its
//! own tables (`Server.altBuild`) and acts on the one chosen
//! (`Server.altAct`), and the docs are `docs/altitude.md`.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");

pub const Rgb = chromepkg.Rgb;

/// What a row is, which is what `↵` on it does.
pub const Kind = enum {
    /// an unread pane, oldest first: ↵ goes to it
    attention,
    /// a workspace: ↵ enters it
    space,
    /// a window of a workspace: ↵ enters the workspace and selects it
    window,
    /// one pane: ↵ focuses it
    pane,
    /// a global pin: ↵ focuses it (it is live at every altitude)
    pin,
    /// a `:` command with its argument: ↵ runs it
    command,
    /// the companion: ↵ hands the typed text to her
    ask,
    /// prose the cursor skips
    note,
};

pub const Command = enum {
    none,
    new,
    go,
    rename,
    close,
    ledger,
    orbit,
};

pub const CommandSpec = struct { word: []const u8, cmd: Command, arg: []const u8, help: []const u8 };

/// The exact commands, completed as they are typed. `:tab rename` is
/// accepted as the design spells it; `:rename` is the short form.
pub const commands = [_]CommandSpec{
    .{ .word = "go", .cmd = .go, .arg = "<space>", .help = "enter a space by name" },
    .{ .word = "switch", .cmd = .go, .arg = "<space>", .help = "the same as :go" },
    .{ .word = "new", .cmd = .new, .arg = "<name>", .help = "a new space, entered" },
    .{ .word = "rename", .cmd = .rename, .arg = "<name>", .help = "rename the current tab (it never renames itself)" },
    .{ .word = "tab rename", .cmd = .rename, .arg = "<name>", .help = "the same as :rename" },
    .{ .word = "close", .cmd = .close, .arg = "<space>", .help = "close a space: every pane in it is hung up" },
    .{ .word = "ledger", .cmd = .ledger, .arg = "", .help = "rows only, no figure" },
    .{ .word = "orbit", .cmd = .orbit, .arg = "", .help = "the figure, when the glass has room" },
};

pub const Row = struct {
    kind: Kind,
    /// the leading glyph and its ink — `●` accent for attention, `▸`
    /// for the current space, `⊕g` for a pin, `✦` for the companion
    glyph: []const u8 = " ",
    ink: Rgb = chromepkg.overlay0,
    name: []const u8,
    /// the event line beside the name
    line: []const u8 = "",
    /// the second line of a two-line entry: a space's tab row
    second: []const u8 = "",
    /// the right edge: what ↵ does here
    hint: []const u8 = "",
    ws: usize = 0,
    win: usize = 0,
    pane: u32 = 0,
    cmd: Command = .none,
    /// the argument a command row carries, already typed
    arg: []const u8 = "",
    /// a ranking key while finding: lower sorts first
    score: u32 = 0,

    pub fn height(self: Row) u16 {
        return if (self.second.len > 0) 2 else 1;
    }
    pub fn actionable(self: Row) bool {
        return self.kind != .note;
    }
};

/// A mini pane in the figure: where it sits (inside the figure's
/// inner rect), what it is running, and how it is marked.
pub const Cell = struct {
    rect: layoutpkg.Rect,
    title: []const u8,
    mark: chromepkg.TabMark = .none,
    focused: bool = false,
};

/// The current space contracted: its name and current tab, and the
/// panes of that tab as cells placed by the same split tree that
/// places them on the glass, into a smaller rect.
pub const Figure = struct {
    title: []const u8,
    unread: bool = false,
    cells: []const Cell,
};

/// Where a painted row landed, for the mouse. Rows relative to the
/// glass.
pub const Zone = struct { y0: u16, y1: u16, row: usize };

/// Everything the view holds between keystrokes: the input, the
/// cursor, the rows as last built (borrowing `buf`), the zones as
/// last painted. Lives on the server while altitude is up.
pub const State = struct {
    text: [128]u8 = @splat(0),
    len: usize = 0,
    cur: usize = 0,
    /// The rows, rebuilt every paint from the server's tables. Their
    /// strings borrow `buf`, which is bump-allocated per build.
    rows: std.ArrayList(Row) = .empty,
    buf: [32 * 1024]u8 = undefined,
    cells: [48]Cell = undefined,
    cells_n: usize = 0,
    cell_titles: [48][40]u8 = undefined,
    figure_title: [96]u8 = @splat(0),
    figure_title_len: usize = 0,
    figure_unread: bool = false,
    zones: [128]Zone = undefined,
    zones_n: usize = 0,
    /// The figure's rect as last painted, so the inner cells can be
    /// placed by the split tree before the frame is drawn.
    figure_rect: ?layoutpkg.Rect = null,
    /// Row the cursor should land on when the rows are next built:
    /// keeps it on the same item across a rebuild where possible.
    /// Ledger (rows only) rather than orbit, for this visit.
    ledger: bool = false,
    /// The ✦ row is never selected by rook — only by a hand that
    /// moved onto it (j, ⇥, a click). Typing disarms it again.
    ask_armed: bool = false,

    pub fn textSlice(self: *const State) []const u8 {
        return self.text[0..self.len];
    }

    /// Bare text finds; `:` leads a command.
    pub fn isCommand(self: *const State) bool {
        return self.len > 0 and self.text[0] == ':';
    }

    pub fn push(self: *State, ch: u8) void {
        if (self.len < self.text.len) {
            self.text[self.len] = ch;
            self.len += 1;
        }
    }

    pub fn pop(self: *State) void {
        if (self.len == 0) return;
        self.len -= 1;
        // back over a whole UTF-8 sequence
        while (self.len > 0 and (self.text[self.len] & 0xc0) == 0x80) self.len -= 1;
    }

    pub fn clear(self: *State) void {
        self.len = 0;
        self.cur = 0;
        self.ask_armed = false;
    }

    pub fn figure(self: *const State) ?Figure {
        if (self.figure_title_len == 0) return null;
        return .{
            .title = self.figure_title[0..self.figure_title_len],
            .unread = self.figure_unread,
            .cells = self.cells[0..self.cells_n],
        };
    }

    pub fn setFigureTitle(self: *State, t: []const u8) void {
        self.figure_title_len = @min(t.len, self.figure_title.len);
        @memcpy(self.figure_title[0..self.figure_title_len], t[0..self.figure_title_len]);
    }

    /// The row the cursor is on, if it is on one.
    pub fn selected(self: *const State) ?Row {
        if (self.rows.items.len == 0) return null;
        const i = @min(self.cur, self.rows.items.len - 1);
        const r = self.rows.items[i];
        if (r.kind == .ask and !self.ask_armed) return null;
        return if (r.actionable()) r else null;
    }

    /// Is the cursor's row painted as selected? The ✦ row only once
    /// a hand put the cursor there.
    pub fn highlighted(self: *const State, i: usize) bool {
        if (i != self.cur or i >= self.rows.items.len) return false;
        const r = self.rows.items[i];
        if (r.kind == .ask and !self.ask_armed) return false;
        return r.actionable();
    }

    /// Move the cursor `d` rows, skipping prose, staying in range.
    /// A move is a hand on the cursor: it arms the ✦ row.
    pub fn move(self: *State, d: i32) void {
        const n = self.rows.items.len;
        if (n == 0) return;
        self.ask_armed = true;
        var i: i64 = @intCast(@min(self.cur, n - 1));
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            i += d;
            if (i < 0) i = 0;
            if (i >= @as(i64, @intCast(n))) i = @intCast(n - 1);
            if (self.rows.items[@intCast(i)].actionable()) break;
            // an edge of prose: stay where we were
            if (i == 0 or i == @as(i64, @intCast(n - 1))) return;
        }
        self.cur = @intCast(i);
    }

    /// Put the cursor on the first actionable row, or on the first
    /// row of `kind` when there is one — the `⇥ ask` jump.
    pub fn moveTo(self: *State, kind: Kind) bool {
        for (self.rows.items, 0..) |r, i| {
            if (r.kind == kind) {
                self.cur = i;
                return true;
            }
        }
        return false;
    }

    pub fn clampCursor(self: *State) void {
        const n = self.rows.items.len;
        if (n == 0) {
            self.cur = 0;
            return;
        }
        if (self.cur >= n) self.cur = n - 1;
        if (!self.rows.items[self.cur].actionable()) {
            // find the nearest actionable row below, then above
            var i = self.cur;
            while (i < n and !self.rows.items[i].actionable()) i += 1;
            if (i < n) {
                self.cur = i;
                return;
            }
            i = self.cur;
            while (i > 0 and !self.rows.items[i].actionable()) i -= 1;
            self.cur = i;
        }
    }

    /// The row painted at glass row `y`, if any.
    pub fn rowAt(self: *const State, y: u16) ?usize {
        for (self.zones[0..self.zones_n]) |z| {
            if (y >= z.y0 and y < z.y1) return z.row;
        }
        return null;
    }
};

// ---- finding ----

/// A subsequence match, case-insensitive: every byte of `needle` in
/// order somewhere in `hay`. The score is where it starts plus what
/// it skips, so `api` ranks the space `api` above `vera › api-tests`.
/// Null is no match. Spaces in the needle are wildcards: `wait me`
/// finds `waiting on me`.
pub fn fuzzy(hay: []const u8, needle: []const u8) ?u32 {
    if (needle.len == 0) return 0;
    var score: u32 = 0;
    var hi: usize = 0;
    var first: ?usize = null;
    var last_hit: usize = 0;
    for (needle) |nc| {
        if (nc == ' ') continue;
        const want = std.ascii.toLower(nc);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != want) hi += 1;
        if (hi >= hay.len) return null;
        if (first == null) first = hi;
        if (first != null and first.? != hi) score += @intCast((hi - last_hit -| 1) * 2);
        last_hit = hi;
        hi += 1;
    }
    return score + @as(u32, @intCast(first orelse 0));
}

/// The command a `:` line names, and the argument after it. The
/// longest word that prefixes the line wins, so `:tab rename x` is
/// `rename` with `x`, not `tab` with `rename x`. Null when nothing
/// matches whole; partial words complete through `completions`.
pub fn parseCommand(line: []const u8) ?struct { spec: CommandSpec, arg: []const u8 } {
    const body = std.mem.trimStart(u8, if (line.len > 0 and line[0] == ':') line[1..] else line, " ");
    var best: ?CommandSpec = null;
    var best_len: usize = 0;
    for (commands) |c| {
        if (!std.mem.startsWith(u8, body, c.word)) continue;
        const rest = body[c.word.len..];
        if (rest.len > 0 and rest[0] != ' ') continue;
        if (c.word.len > best_len) {
            best = c;
            best_len = c.word.len;
        }
    }
    const spec = best orelse return null;
    return .{ .spec = spec, .arg = std.mem.trim(u8, body[spec.word.len..], " ") };
}

/// The commands a partial `:` line could become: every one whose word
/// starts with what was typed.
pub fn completions(line: []const u8, out: []CommandSpec) []CommandSpec {
    const body = std.mem.trimStart(u8, if (line.len > 0 and line[0] == ':') line[1..] else line, " ");
    const word = std.mem.sliceTo(body, ' ');
    var n: usize = 0;
    for (commands) |c| {
        if (n == out.len) break;
        if (std.mem.startsWith(u8, c.word, word)) {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

// ---- painting ----

const csi = "\x1b[";

fn fg(f: *renderpkg.Frame, c: Rgb) void {
    f.print(csi ++ "38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}
fn bg(f: *renderpkg.Frame, c: Rgb) void {
    f.print(csi ++ "48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Write at most `w` columns of `s` at the cursor; returns the
/// columns spent. Cuts on codepoint boundaries, one column each —
/// chrome's own strings are one cell a glyph, and the row is padded
/// after it either way.
fn putW(f: *renderpkg.Frame, s: []const u8, w: u16) u16 {
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

/// Clear the region to the glass's own background: the view is drawn
/// on the terminal, not on a panel. Also what the server uses to
/// blank the rects that contracted with the space.
pub fn clearRect(f: *renderpkg.Frame, r: layoutpkg.Rect) void {
    f.put(csi ++ "0m");
    var y: u16 = r.y;
    while (y < r.y + r.h) : (y += 1) {
        f.cup(r.x, y);
        pad(f, r.w);
    }
}

pub const Paint = struct {
    accent: Rgb,
    /// the companion's name for the ask row's hint, "" when none
    companion: []const u8 = "",
};

/// Paint the view into `region` and record where each row landed.
/// Returns where the input's cursor is on the glass.
pub fn draw(f: *renderpkg.Frame, st: *State, region: layoutpkg.Rect, p: Paint) renderpkg.CursorOverride {
    clearRect(f, region);
    st.zones_n = 0;
    const x = region.x + 1;
    const w = region.w -| 2;
    const bottom = region.y + region.h;
    var y = region.y;

    // The input: already focused, the cursor in it. A placeholder
    // says what it takes until something is typed.
    f.cup(x, y);
    f.put(csi ++ "0m");
    fg(f, p.accent);
    f.put("› ");
    var cx: u16 = x + 2;
    const text = st.textSlice();
    if (text.len == 0) {
        fg(f, chromepkg.overlay0);
        _ = putW(f, "find, go, or ask", w -| 2);
    } else {
        fg(f, chromepkg.text);
        cx += putW(f, text, w -| 2);
    }
    const cursor: renderpkg.CursorOverride = .{ .x = @min(cx, region.x + region.w -| 1), .y = y, .bar = true };
    y += 2;

    // The figure, when there is one and room for it: the current
    // space where it stood, its panes as cells inside.
    if (st.figure()) |fig| {
        if (st.figure_rect) |fr| {
            if (fr.y + fr.h <= bottom) {
                drawFigure(f, fig, fr, p.accent);
                y = fr.y + fr.h + 1;
            }
        }
    }

    // Rows. A selected row is a band; the glyph keeps its own ink so
    // the accent still means what it means (unread, current).
    for (st.rows.items, 0..) |r, i| {
        const h = r.height();
        if (y + h > bottom -| 1) {
            // what did not fit is said out loud
            if (y < bottom) {
                f.cup(x, y);
                f.put(csi ++ "0m");
                fg(f, chromepkg.overlay0);
                var mb: [32]u8 = undefined;
                const m = std.fmt.bufPrint(&mb, "⋯ {d} more", .{st.rows.items.len - i}) catch "⋯";
                _ = putW(f, m, w);
            }
            break;
        }
        const sel = st.highlighted(i);
        if (st.zones_n < st.zones.len) {
            st.zones[st.zones_n] = .{ .y0 = y, .y1 = y + h, .row = i };
            st.zones_n += 1;
        }
        drawRow(f, r, sel, x, y, w, p);
        y += h;
    }

    // A footer only while there is room, and only a hint: keys the
    // hand has not found yet. Nothing here is a control.
    if (y + 1 < bottom) {
        f.cup(x, bottom - 1);
        f.put(csi ++ "0m");
        fg(f, chromepkg.surface0);
        const foot: []const u8 = if (st.isCommand())
            "↵ runs the completed command · esc clears"
        else if (text.len > 0)
            "typing filters · ↵ acts on the selected row · nothing runs while you type"
        else
            "j k move · ↵ go · type to find · : command · esc back";
        _ = putW(f, foot, w);
    }
    f.put(csi ++ "0m");
    return cursor;
}

fn drawRow(f: *renderpkg.Frame, r: Row, sel: bool, x: u16, y: u16, w: u16, p: Paint) void {
    // the band: a selected row is one block, two rows tall when it is
    var row: u16 = 0;
    while (row < r.height()) : (row += 1) {
        f.cup(x, y + row);
        f.put(csi ++ "0m");
        if (sel) bg(f, chromepkg.surface0);
        pad(f, w);
    }
    f.cup(x, y);
    f.put(csi ++ "0m");
    if (sel) bg(f, chromepkg.surface0);
    // glyph column: two cells and a space
    fg(f, r.ink);
    var used: u16 = 0;
    used += putW(f, r.glyph, 3);
    while (used < 3) : (used += 1) f.put(" ");
    // the hint, right-aligned, measured first so the name and line
    // stop short of it
    const hint_w: u16 = if (r.hint.len > 0) chromepkg.cols(r.hint) + 2 else 0;
    const body_w = w -| (3 + hint_w);
    // name: bold text, unless the row is a note
    if (r.kind == .note) {
        fg(f, chromepkg.overlay0);
    } else {
        fg(f, chromepkg.text);
        f.put(csi ++ "1m");
    }
    const name_max: u16 = @min(body_w, 40);
    used += putW(f, r.name, name_max);
    f.put(csi ++ "22m");
    if (r.line.len > 0 and used + 3 < 3 + body_w) {
        fg(f, chromepkg.overlay0);
        f.put("  ");
        used += 2;
        // an event line reads in the state's ink where it has one
        fg(f, if (r.kind == .attention) chromepkg.text else chromepkg.overlay0);
        used += putW(f, r.line, (3 + body_w) -| used);
    }
    if (hint_w > 0) {
        f.cup(x + w -| (hint_w - 2), y);
        fg(f, if (sel) p.accent else chromepkg.surface0);
        _ = putW(f, r.hint, hint_w);
    }
    if (r.second.len > 0) {
        f.cup(x + 3, y + 1);
        f.put(csi ++ "0m");
        if (sel) bg(f, chromepkg.surface0);
        fg(f, chromepkg.overlay0);
        _ = putW(f, r.second, w -| 3);
    }
    f.put(csi ++ "0m");
}

/// The figure: a box with the space's name in its top edge, and the
/// panes of its current tab as smaller boxes inside — placed by the
/// same split tree that places them on the glass, so the shape is
/// the shape you just left.
fn drawFigure(f: *renderpkg.Frame, fig: Figure, r: layoutpkg.Rect, accent: Rgb) void {
    if (r.w < 8 or r.h < 4) return;
    f.put(csi ++ "0m");
    f.drawBoxIn(r, accent);
    // title in the top edge: ┌┤ vera · deploy ├──
    f.cup(r.x + 1, r.y);
    fg(f, accent);
    f.put("┤ ");
    f.put(csi ++ "0m");
    fg(f, chromepkg.text);
    f.put(csi ++ "1m");
    var used: u16 = 3;
    used += putW(f, fig.title, r.w -| 8);
    f.put(csi ++ "22m");
    if (fig.unread) {
        fg(f, accent);
        f.put(" ●");
        used += 2;
    }
    fg(f, accent);
    f.put(" ├");
    // cells
    for (fig.cells) |c| {
        drawCell(f, c, accent);
    }
    f.put(csi ++ "0m");
}

fn drawCell(f: *renderpkg.Frame, c: Cell, accent: Rgb) void {
    const r = c.rect;
    if (r.w < 4 or r.h < 1) return;
    f.put(csi ++ "0m");
    const ink: Rgb = if (c.focused) accent else chromepkg.overlay0;
    if (r.h >= 2 and r.w >= 6) {
        f.drawBoxIn(r, ink);
        // ┌─ title ─┐
        f.cup(r.x + 1, r.y);
        fg(f, ink);
        f.put("─ ");
        fg(f, if (c.focused) chromepkg.text else chromepkg.overlay0);
        _ = putW(f, c.title, r.w -| 6);
        fg(f, ink);
        f.put(" ");
        markGlyph(f, c.mark, accent, ink);
    } else {
        f.cup(r.x, r.y);
        fg(f, if (c.focused) chromepkg.text else chromepkg.overlay0);
        _ = putW(f, c.title, r.w -| 2);
        f.put(" ");
        markGlyph(f, c.mark, accent, ink);
    }
    f.put(csi ++ "0m");
}

fn markGlyph(f: *renderpkg.Frame, mark: chromepkg.TabMark, accent: Rgb, back: Rgb) void {
    switch (mark) {
        .working => {
            fg(f, chromepkg.yellow);
            f.put("◐");
        },
        .unread => {
            fg(f, accent);
            f.put("●");
        },
        .none => {
            fg(f, back);
            f.put("─");
        },
    }
}

/// How tall a figure is on this glass, and whether there is room for
/// one at all. Orbit wants a figure a third of the region tall with
/// at least six rows inside; anything smaller is Ledger.
pub fn figureRect(region: layoutpkg.Rect, cells: usize, ledger: bool) ?layoutpkg.Rect {
    if (ledger) return null;
    if (region.w < 60 or region.h < 16) return null;
    var h: u16 = @max(8, region.h / 3);
    h = @min(h, 12);
    // more cells want more rows, up to a point
    if (cells > 2) h = @min(h + 2, region.h / 2);
    const w: u16 = @min(region.w -| 2, 84);
    return .{ .x = region.x + 1, .y = region.y + 2, .w = w, .h = h };
}

/// A duration at human resolution: `12s`, `4m`, `2h`, `3d`.
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

test "fuzzy finds subsequences and ranks the tighter match first" {
    try std.testing.expect(fuzzy("vera", "") != null);
    try std.testing.expect(fuzzy("vera", "va") != null);
    try std.testing.expect(fuzzy("vera", "x") == null);
    try std.testing.expect(fuzzy("waiting on me", "wait me") != null);
    // `api` on the space `api` beats it buried in a longer name
    try std.testing.expect(fuzzy("api", "api").? < fuzzy("vera › api-tests", "api").?);
    // case does not matter
    try std.testing.expect(fuzzy("Claude Code", "cc") != null);
}

test "commands parse whole words and complete partial ones" {
    const r = parseCommand(":rename deploy").?;
    try std.testing.expectEqual(Command.rename, r.spec.cmd);
    try std.testing.expectEqualStrings("deploy", r.arg);
    const t = parseCommand(":tab rename deploy").?;
    try std.testing.expectEqual(Command.rename, t.spec.cmd);
    try std.testing.expectEqualStrings("deploy", t.arg);
    try std.testing.expect(parseCommand(":ren") == null);
    try std.testing.expect(parseCommand(":renamer x") == null);
    var out: [8]CommandSpec = undefined;
    const c = completions(":re", &out);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("rename", c[0].word);
    const all = completions(":", &out);
    try std.testing.expectEqual(commands.len, all.len);
}

test "the cursor skips prose and stays in range" {
    var st: State = .{};
    defer st.rows.deinit(std.testing.allocator);
    try st.rows.append(std.testing.allocator, .{ .kind = .note, .name = "PINS" });
    try st.rows.append(std.testing.allocator, .{ .kind = .space, .name = "vera" });
    try st.rows.append(std.testing.allocator, .{ .kind = .note, .name = "SHELF" });
    try st.rows.append(std.testing.allocator, .{ .kind = .pin, .name = "server" });
    st.cur = 0;
    st.clampCursor();
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    st.move(-1);
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    st.move(-1);
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    try std.testing.expect(st.moveTo(.pin));
    try std.testing.expectEqual(@as(usize, 3), st.cur);
}

test "ages read at human resolution" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12s", age(&b, 12_500));
    try std.testing.expectEqualStrings("4m", age(&b, 4 * 60_000 + 10));
    try std.testing.expectEqualStrings("2h", age(&b, 2 * 3_600_000));
    try std.testing.expectEqualStrings("3d", age(&b, 3 * 86_400_000));
}
