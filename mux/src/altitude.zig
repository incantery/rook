//! Altitude: rook's outermost scope, the layer above a space.
//!
//! `prefix-o` changes altitude. The whole glass belongs to rook: the
//! scope slot that read the space's name reads the system badge, the
//! space you left is the breadcrumb beside it, and the canvas holds
//! every space — each one a figure made of what rook can truthfully
//! say about it (its tabs, who is driving them, what a program said,
//! how long it has been quiet) or, when it has little to say, one
//! compact row. Global pins do not move a column: scope is taught by
//! what refuses to move. The calm bar stays. Esc returns to the exact
//! pane, cursor and scroll, because nothing moved to get here — the
//! panes kept running underneath, unresized, and this file painted
//! over them.
//!
//! One input, already focused. Text finds spaces, tabs and panes; `:`
//! prefixes an exact command with completions; the last row, `✦ vera:`,
//! hands the same text to the companion — and only by choosing that
//! row. Typing never acts; `↵` on a visible row does. Because bare
//! typing searches, the rows are walked with ↑ ↓ (⇥ ⇤, C-n C-p), never
//! with letters. Esc closes the deepest layer first: a query, then the
//! view.
//!
//! Two fidelities, one model. Orbit draws a figure per space when the
//! glass has room for them; Ledger is the same spaces as two-line rows
//! — narrow glass, `zoom_view = "ledger"`, and every renderer that is
//! not this one. Identical keys, identical rows.
//!
//! This file holds the model, the painter and the input state. It
//! knows nothing about sessions: the server fills the model from its
//! own tables (`Server.altBuild`) and acts on the row chosen
//! (`Server.altAct`). The ontology — what a space, a tab, a pane, an
//! actor and a tool are at runtime — is `docs/altitude.md`.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");

pub const Rgb = chromepkg.Rgb;

/// The system scope's mark. Only rook's own scope ever wears it: a
/// space that happens to be named `rook` is a space, and shows as one.
pub const scope_glyph = "♜";

/// What a row is, which is what `↵` on it does.
pub const Kind = enum {
    /// an unread pane, oldest first: ↵ goes to it
    attention,
    /// a producer says an agent there needs you: ↵ goes to it
    ask,
    /// a space: ↵ enters it (a figure in orbit, two lines in ledger)
    space,
    /// a tab of a space: ↵ enters the space and selects it
    tab,
    /// one pane: ↵ focuses it
    pane,
    /// a global pin: ↵ focuses it (it is live at every altitude)
    pin,
    /// a `:` command with its argument: ↵ runs it
    command,
    /// the companion: ↵ hands the typed text to her
    vera,
    /// prose the cursor skips
    note,
};

pub const Command = enum { none, new, go, rename, close, ledger, orbit };

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
    .{ .word = "ledger", .cmd = .ledger, .arg = "", .help = "spaces as rows, no figures" },
    .{ .word = "orbit", .cmd = .orbit, .arg = "", .help = "spaces as figures, when the glass has room" },
};

/// One tab of a space, as the figure lists it: the minted name, the
/// actor driving it when one claimed a pane there, and the mark.
pub const Tab = struct {
    name: []const u8,
    actor: []const u8 = "",
    mark: chromepkg.TabMark = .none,
    current: bool = false,
};

/// What the event line is about, which picks its ink.
pub const Event = enum { quiet, working, unread, needs_you, said };

/// A space, as rook can truthfully describe it.
pub const Space = struct {
    /// the label (the workspace name with its repository prefix off)
    name: []const u8,
    /// the workspace identity, what `:go` takes
    full: []const u8,
    ws: usize,
    /// the space that was on the glass — the one Esc returns to
    current: bool = false,
    /// the space's own name is the system's word: shown as a space
    /// still, the badge is what marks the scope
    unread: usize = 0,
    working: bool = false,
    /// one line: a producer's words for it, what a program said, who
    /// is working, else how long it has been quiet
    event: []const u8 = "",
    event_kind: Event = .quiet,
    tabs: []const Tab = &.{},
    /// the last lines of the focused pane, read from retained cells
    /// (never a resize), for the current space only
    excerpt: []const []const u8 = &.{},

    /// A space with something to show gets a figure in orbit; one
    /// with only a name and a quiet line gets a row, on purpose —
    /// being the space you left is not, by itself, something to show.
    pub fn rich(self: Space) bool {
        return self.unread > 0 or self.working or self.event_kind != .quiet or self.tabs.len > 1 or self.excerpt.len > 0;
    }

    /// Rows a figure of this space takes, borders included.
    pub fn figureRows(self: Space) u16 {
        var h: u16 = 3; // top edge with the name and event, the tab line, bottom edge
        h += @intCast(self.excerpt.len);
        return h;
    }
};

pub const Row = struct {
    kind: Kind,
    /// the leading glyph and its ink — `●` accent for unread, `◇`
    /// yellow for an ask, `⊕g` for a pin, `✦` for the companion
    glyph: []const u8 = " ",
    ink: Rgb = chromepkg.overlay0,
    name: []const u8,
    /// the line beside the name
    line: []const u8 = "",
    line_ink: Rgb = chromepkg.overlay0,
    /// the second line of a two-line entry (a space's tabs, in ledger)
    second: []const u8 = "",
    /// the right edge: what ↵ does here
    hint: []const u8 = "",
    ws: usize = 0,
    win: usize = 0,
    pane: u32 = 0,
    /// index into `State.spaces` for a `.space` row
    space: usize = 0,
    cmd: Command = .none,
    /// the argument a command row carries, already typed; a
    /// workspace name for an `.ask` row
    arg: []const u8 = "",
    /// a ranking key while finding: lower sorts first
    score: u32 = 0,

    pub fn actionable(self: Row) bool {
        return self.kind != .note;
    }
};

/// Where a painted row landed, for the mouse. Rows relative to the
/// glass.
pub const Zone = struct { y0: u16, y1: u16, row: usize };

pub const max_spaces: usize = 24;
pub const max_tabs: usize = 12;
pub const max_excerpt: usize = 2;

/// What Esc did.
pub const Escape = enum { cleared, leave };

/// Everything the view holds between keystrokes: the input, the
/// cursor, the rows and spaces as last built (borrowing `buf`), the
/// zones as last painted. Lives on the server while altitude is up.
pub const State = struct {
    text: [128]u8 = @splat(0),
    len: usize = 0,
    cur: usize = 0,
    /// The rows, rebuilt every paint from the server's tables. Their
    /// strings borrow `buf`, which is bump-allocated per build.
    rows: std.ArrayList(Row) = .empty,
    buf: [48 * 1024]u8 = undefined,
    spaces: [max_spaces]Space = undefined,
    spaces_n: usize = 0,
    tabs: [max_spaces * max_tabs]Tab = undefined,
    tabs_n: usize = 0,
    excerpt: [max_excerpt][]const u8 = undefined,
    zones: [128]Zone = undefined,
    zones_n: usize = 0,
    /// Ledger (rows only) rather than orbit, for this visit.
    ledger: bool = false,
    /// What was actually painted last: orbit fell back to ledger when
    /// the figures did not fit.
    painted_ledger: bool = false,
    /// The ✦ row is never selected by rook — only by a hand that
    /// moved onto it (↓, ⇥, a click). Typing disarms it again.
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

    /// Esc closes the deepest layer first: a query (and with it the
    /// results, the completions), then the view. A half-typed query
    /// never sends you back into the space by surprise.
    pub fn escape(self: *State) Escape {
        if (self.len > 0) {
            self.clear();
            return .cleared;
        }
        return .leave;
    }

    pub fn reset(self: *State) void {
        self.rows.clearRetainingCapacity();
        self.spaces_n = 0;
        self.tabs_n = 0;
    }

    /// Reserve `n` tab slots for a space being built.
    pub fn takeTabs(self: *State, n: usize) []Tab {
        const room = @min(n, self.tabs.len - self.tabs_n);
        const out = self.tabs[self.tabs_n .. self.tabs_n + room];
        self.tabs_n += room;
        return out;
    }

    /// The row the cursor is on, if it is on one.
    pub fn selected(self: *const State) ?Row {
        if (self.rows.items.len == 0) return null;
        const i = @min(self.cur, self.rows.items.len - 1);
        const r = self.rows.items[i];
        if (r.kind == .vera and !self.ask_armed) return null;
        return if (r.actionable()) r else null;
    }

    /// Is the cursor's row painted as selected? The ✦ row only once
    /// a hand put the cursor there.
    pub fn highlighted(self: *const State, i: usize) bool {
        if (i != self.cur or i >= self.rows.items.len) return false;
        const r = self.rows.items[i];
        if (r.kind == .vera and !self.ask_armed) return false;
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

    /// Put the cursor on the first row of `kind` — the ⇥ jump to the
    /// companion's row.
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

/// The label a tab wears: the stable name first, the actor after it
/// only when one claimed a pane there, and never the tool — the tool
/// is the bar's word (`you ▸ claude`), the actor is the tab's
/// (`deploy · main`). An actor that is the name adds nothing.
pub fn tabLabel(buf: []u8, name: []const u8, actor: []const u8) []const u8 {
    if (actor.len == 0 or std.mem.eql(u8, actor, name)) {
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ name, actor }) catch name;
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

// ---- painting ----

const csi = "\x1b[";

/// The canvas ground. Rook's own surface, opaque: the view is the
/// system's, not the terminal's, and it must read over a wallpaper.
pub const ground: Rgb = chromepkg.mantle;
/// The input's band and a selected compact row.
const band: Rgb = chromepkg.surface0;

fn fg(f: *renderpkg.Frame, c: Rgb) void {
    f.print(csi ++ "38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}
fn bg(f: *renderpkg.Frame, c: Rgb) void {
    f.print(csi ++ "48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}
/// Reset to the ground: default ink, the canvas colour behind it.
fn ink(f: *renderpkg.Frame, c: Rgb) void {
    f.put(csi ++ "0m");
    bg(f, ground);
    fg(f, c);
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

/// Fill a rect with the ground.
pub fn clearRect(f: *renderpkg.Frame, r: layoutpkg.Rect) void {
    f.put(csi ++ "0m");
    bg(f, ground);
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

pub const Paint = struct {
    accent: Rgb,
    /// the space Esc returns to, for the empty-state hint
    back: []const u8 = "",
};

/// Decide the fidelity for this frame, before the bars are composed:
/// orbit when asked for it, nothing is being typed, the region is wide
/// enough for a figure, and the figures fit; ledger otherwise.
pub fn chooseFidelity(st: *State, region: layoutpkg.Rect) void {
    const avail = region.h -| 5; // the input, its line, the footer
    const orbit = !st.ledger and st.len == 0 and region.w >= 60 and orbitRows(st) <= avail;
    st.painted_ledger = !orbit;
}

/// Rows the orbit needs for its content: every row as it would be
/// drawn, figures included.
fn orbitRows(st: *const State) u16 {
    var h: u16 = 0;
    for (st.rows.items) |r| {
        if (r.kind == .space) {
            const sp = st.spaces[r.space];
            h += if (sp.rich()) sp.figureRows() + 1 else 1;
        } else {
            h += 1;
        }
    }
    return h;
}

/// Paint the view into `region` and record where each row landed.
/// Returns where the input's cursor is on the glass.
pub fn draw(f: *renderpkg.Frame, st: *State, region: layoutpkg.Rect, p: Paint) renderpkg.CursorOverride {
    clearRect(f, region);
    st.zones_n = 0;
    const x = region.x + 2;
    const w = region.w -| 4;
    const bottom = region.y + region.h;
    var y = region.y + 1;

    // The input: a band the eye finds, the prompt in the accent, the
    // cursor in it. The placeholder is in the band too, so an empty
    // query still reads as a control and not as a caption.
    f.cup(region.x + 1, y);
    f.put(csi ++ "0m");
    bg(f, band);
    pad(f, region.w -| 2);
    f.cup(x, y);
    bg(f, band);
    fg(f, p.accent);
    f.put(csi ++ "1m› " ++ csi ++ "22m");
    var cx: u16 = x + 2;
    const text = st.textSlice();
    if (text.len == 0) {
        fg(f, chromepkg.overlay0);
        _ = putW(f, "find a space, a tab, a pane · : for a command", w -| 2);
    } else {
        fg(f, chromepkg.text);
        f.put(csi ++ "1m");
        cx += putW(f, text, w -| 2);
        f.put(csi ++ "22m");
    }
    const cursor: renderpkg.CursorOverride = .{ .x = @min(cx, region.x + region.w -| 1), .y = y, .bar = true };
    y += 1;

    // Under the band: what the rows are, in one dim line.
    f.cup(x, y);
    ink(f, chromepkg.overlay0);
    const under: []const u8 = if (st.isCommand())
        "completions · ↵ runs the selected one · esc clears"
    else if (text.len > 0)
        "matches · ↑ ↓ move · ↵ acts on the selected · typing never does"
    else
        "";
    _ = putW(f, under, w);
    y += if (under.len > 0) 2 else 1;

    // Orbit when the figures fit; the same rows as ledger when they
    // do not, or when asked for. Decided in `chooseFidelity`, so the
    // bar and this frame agree.
    const orbit = !st.painted_ledger;

    for (st.rows.items, 0..) |r, i| {
        const sel = st.highlighted(i);
        var h: u16 = 1;
        var figure: ?Space = null;
        if (r.kind == .space) {
            const sp = st.spaces[r.space];
            if (orbit and sp.rich()) {
                figure = sp;
                h = sp.figureRows();
            } else if (!orbit and r.second.len > 0) {
                h = 2;
            }
        }
        if (y + h > bottom -| 1) {
            // what did not fit is said out loud
            if (y < bottom) {
                f.cup(x, y);
                ink(f, chromepkg.overlay0);
                var mb: [32]u8 = undefined;
                const m = std.fmt.bufPrint(&mb, "⋯ {d} more", .{st.rows.items.len - i}) catch "⋯";
                _ = putW(f, m, w);
            }
            break;
        }
        if (st.zones_n < st.zones.len) {
            st.zones[st.zones_n] = .{ .y0 = y, .y1 = y + h, .row = i };
            st.zones_n += 1;
        }
        if (figure) |sp| {
            drawFigure(f, sp, sel, x, y, w, p.accent);
            y += h + 1;
        } else if (r.kind == .space) {
            drawSpaceRow(f, r, st.spaces[r.space], sel, !orbit, x, y, w, p.accent);
            y += h;
        } else {
            drawRow(f, r, sel, x, y, w, p.accent);
            y += h;
        }
    }

    // The footer: keys a hand has not found yet, in one line, dim but
    // legible. The empty state says what there is to do here.
    if (y + 1 < bottom) {
        f.cup(x, bottom - 1);
        ink(f, chromepkg.overlay0);
        var fb: [160]u8 = undefined;
        const long: []const u8 = if (text.len > 0)
            "esc clears the query · esc again returns"
        else if (p.back.len > 0)
            std.fmt.bufPrint(&fb, "↑ ↓ move · ↵ enter · type to find · : command · :new <name> starts a space · esc returns to {s}", .{p.back}) catch "esc returns"
        else
            "↑ ↓ move · ↵ enter · type to find · : command · esc returns";
        const short: []const u8 = if (text.len > 0) "esc clears · esc again returns" else "↑ ↓ ↵ · type to find · : command · esc returns";
        _ = putW(f, if (chromepkg.cols(long) <= w) long else short, w);
    }
    f.put(csi ++ "0m");
    return cursor;
}

/// One-line rows: attention, asks, tabs, panes, pins, commands, the
/// companion. A selected row wears the accent marker and bold ink;
/// the band is reserved for the input.
fn drawRow(f: *renderpkg.Frame, r: Row, sel: bool, x: u16, y: u16, w: u16, accent: Rgb) void {
    f.cup(x, y);
    ink(f, r.ink);
    var used: u16 = 0;
    if (r.kind == .note) {
        fg(f, chromepkg.overlay0);
        _ = putW(f, r.name, w);
        return;
    }
    // marker column: the selection cursor, else the row's own glyph
    if (sel) {
        fg(f, accent);
        f.put("▸ ");
    } else {
        f.put("  ");
    }
    used += 2;
    fg(f, r.ink);
    used += putW(f, r.glyph, 2);
    while (used < 5) : (used += 1) f.put(" ");
    const hint_w: u16 = if (r.hint.len > 0) chromepkg.cols(r.hint) + 2 else 0;
    const body_w = w -| (5 + hint_w);
    fg(f, if (sel) accent else chromepkg.text);
    f.put(csi ++ "1m");
    used += putW(f, r.name, @min(body_w, 44));
    f.put(csi ++ "22m");
    if (r.line.len > 0 and used + 3 < 5 + body_w) {
        f.put("  ");
        used += 2;
        fg(f, r.line_ink);
        used += putW(f, r.line, (5 + body_w) -| used);
    }
    if (hint_w > 0 and sel) {
        f.cup(x + w -| (hint_w - 2), y);
        fg(f, accent);
        _ = putW(f, r.hint, hint_w);
    }
    f.put(csi ++ "0m");
}

/// A space as a row: in ledger two lines (identity and event, then
/// its tabs); in orbit the compact form a data-poor space gets, one
/// line with its tabs after the event.
fn drawSpaceRow(f: *renderpkg.Frame, r: Row, sp: Space, sel: bool, two_lines: bool, x: u16, y: u16, w: u16, accent: Rgb) void {
    f.cup(x, y);
    ink(f, chromepkg.overlay0);
    if (sel) {
        fg(f, accent);
        f.put("▸ ");
    } else {
        f.put("  ");
    }
    // the current space wears the block, the same block a selected
    // tab wears: it is the one the glass was on
    if (sp.current) {
        bg(f, if (sel) accent else chromepkg.surface0);
        fg(f, if (sel) chromepkg.crust else chromepkg.text);
        f.put(csi ++ "1m ");
        _ = putW(f, sp.name, 24);
        f.put(" " ++ csi ++ "22m");
        bg(f, ground);
    } else {
        fg(f, if (sel) accent else chromepkg.text);
        f.put(csi ++ "1m");
        _ = putW(f, sp.name, 24);
        f.put(csi ++ "22m");
    }
    f.put("  ");
    fg(f, eventInk(sp.event_kind, accent));
    var used: u16 = 4 + chromepkg.cols(sp.name) + (if (sp.current) @as(u16, 2) else 0);
    used += putW(f, sp.event, w -| used -| 12);
    if (!two_lines and r.second.len > 0 and used + 6 < w) {
        f.put("   ");
        fg(f, chromepkg.overlay0);
        used += 3;
        used += putW(f, r.second, w -| used -| 10);
    }
    if (sel and r.hint.len > 0) {
        const hw = chromepkg.cols(r.hint);
        f.cup(x + w -| hw, y);
        fg(f, accent);
        _ = putW(f, r.hint, hw);
    }
    if (two_lines and r.second.len > 0) {
        f.cup(x + 4, y + 1);
        ink(f, chromepkg.overlay0);
        _ = putW(f, r.second, w -| 4);
    }
    f.put(csi ++ "0m");
}

fn eventInk(k: Event, accent: Rgb) Rgb {
    return switch (k) {
        .quiet => chromepkg.overlay0,
        .working => chromepkg.yellow,
        .needs_you => chromepkg.yellow,
        .unread => accent,
        .said => chromepkg.text,
    };
}

/// A figure: the space's name in the top edge, its event beside it,
/// its tabs on the first line inside (actor and mark with each), and
/// for the space you left, the last lines of the pane you were in.
/// Sized by what it holds; a selected figure's border is the accent,
/// the current one's name is the block.
fn drawFigure(f: *renderpkg.Frame, sp: Space, sel: bool, x: u16, y: u16, w: u16, accent: Rgb) void {
    const border: Rgb = if (sel) accent else chromepkg.overlay0;
    const h = sp.figureRows();
    // edges
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        f.cup(x, y + row);
        ink(f, border);
        if (row == 0) {
            f.put("┌");
            hline(f, w -| 2);
            f.put("┐");
        } else if (row == h - 1) {
            f.put("└");
            hline(f, w -| 2);
            f.put("┘");
        } else {
            f.put("│");
            pad(f, w -| 2);
            f.put("│");
        }
    }
    // the name, in the edge
    f.cup(x + 1, y);
    ink(f, border);
    f.put("┤");
    if (sp.current) {
        bg(f, if (sel) accent else chromepkg.surface0);
        fg(f, if (sel) chromepkg.crust else chromepkg.text);
    } else {
        fg(f, if (sel) accent else chromepkg.text);
    }
    f.put(csi ++ "1m ");
    var used: u16 = 3;
    used += putW(f, sp.name, 24);
    f.put(" " ++ csi ++ "22m");
    used += 1;
    ink(f, border);
    f.put("├");
    used += 1;
    if (sp.unread > 0) {
        f.put(" ");
        fg(f, accent);
        f.put("●");
        used += 2;
    }
    // the event, after a gap, in its own ink, a gap before the rule
    if (sp.event.len > 0 and used + 5 < w - 2) {
        f.put("  ");
        used += 2;
        fg(f, eventInk(sp.event_kind, accent));
        used += putW(f, sp.event, w -| used -| 4);
        f.put(" ");
    }
    // inside: tabs
    f.cup(x + 2, y + 1);
    ink(f, chromepkg.text);
    var tx: u16 = 0;
    for (sp.tabs) |t| {
        var lb: [64]u8 = undefined;
        const label = tabLabel(&lb, t.name, t.actor);
        const need = chromepkg.cols(label) + 4;
        if (tx + need > w - 4) {
            fg(f, chromepkg.overlay0);
            _ = putW(f, "⋯", 1);
            break;
        }
        if (t.current) {
            bg(f, chromepkg.surface0);
            f.put(" ");
            fg(f, chromepkg.text);
            _ = putW(f, label, 40);
            f.put(" ");
            bg(f, ground);
        } else {
            f.put(" ");
            fg(f, chromepkg.text);
            _ = putW(f, label, 40);
            f.put(" ");
        }
        tx += chromepkg.cols(label) + 2;
        switch (t.mark) {
            .working => {
                fg(f, chromepkg.yellow);
                f.put("◐ ");
                tx += 2;
            },
            .unread => {
                fg(f, accent);
                f.put("● ");
                tx += 2;
            },
            .none => {
                f.put("  ");
                tx += 2;
            },
        }
    }
    // the excerpt: retained cells, read only, dim
    for (sp.excerpt, 0..) |line, i| {
        f.cup(x + 2, y + 2 + @as(u16, @intCast(i)));
        ink(f, chromepkg.overlay0);
        _ = putW(f, line, w -| 4);
    }
    // what ↵ does, in the bottom edge, when selected
    if (sel) {
        const hint: []const u8 = if (sp.current) " ↵ back in · esc too " else " ↵ enter ";
        const hw = chromepkg.cols(hint);
        f.cup(x + w -| hw -| 2, y + h - 1);
        ink(f, accent);
        _ = putW(f, hint, hw);
    }
    f.put(csi ++ "0m");
}

test "fuzzy finds subsequences and ranks the tighter match first" {
    try std.testing.expect(fuzzy("vera", "") != null);
    try std.testing.expect(fuzzy("vera", "va") != null);
    try std.testing.expect(fuzzy("vera", "x") == null);
    try std.testing.expect(fuzzy("waiting on me", "wait me") != null);
    try std.testing.expect(fuzzy("api", "api").? < fuzzy("vera › api-tests", "api").?);
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

test "a tab label is the name, then the actor, never the tool" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("deploy", tabLabel(&b, "deploy", ""));
    try std.testing.expectEqualStrings("deploy · main", tabLabel(&b, "deploy", "main"));
    // an actor that is the name adds nothing
    try std.testing.expectEqualStrings("main", tabLabel(&b, "main", "main"));
}

test "the cursor skips prose, arms the companion row only by hand, and esc peels one layer" {
    var st: State = .{};
    defer st.rows.deinit(std.testing.allocator);
    try st.rows.append(std.testing.allocator, .{ .kind = .note, .name = "PINS" });
    try st.rows.append(std.testing.allocator, .{ .kind = .space, .name = "vera" });
    try st.rows.append(std.testing.allocator, .{ .kind = .note, .name = "·····" });
    try st.rows.append(std.testing.allocator, .{ .kind = .vera, .name = "vera: \"x\"" });
    st.cur = 0;
    st.clampCursor();
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    // the companion row is not selected until a hand moves there
    st.cur = 3;
    try std.testing.expect(st.selected() == null);
    try std.testing.expect(!st.highlighted(3));
    st.cur = 1;
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    try std.testing.expect(st.selected() != null);
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    st.move(-1);
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    try std.testing.expect(st.moveTo(.vera));
    // esc: a query first, the view second
    st.push('a');
    try std.testing.expectEqual(Escape.cleared, st.escape());
    try std.testing.expectEqual(@as(usize, 0), st.len);
    try std.testing.expectEqual(Escape.leave, st.escape());
}

test "a space is rich when it has something to say" {
    const quiet: Space = .{ .name = "infra", .full = "infra", .ws = 0, .event = "quiet · 2d" };
    try std.testing.expect(!quiet.rich());
    const busy: Space = .{ .name = "api", .full = "api", .ws = 1, .working = true, .event = "claude ◐ working", .event_kind = .working };
    try std.testing.expect(busy.rich());
    // the space you left is a row too, until it has something to say
    const here: Space = .{ .name = "vera", .full = "vera", .ws = 2, .current = true, .event = "quiet · 1s" };
    try std.testing.expect(!here.rich());
    const lines = [_][]const u8{"› Reading migrations"};
    const spoke: Space = .{ .name = "vera", .full = "vera", .ws = 2, .current = true, .event = "quiet · 1s", .excerpt = &lines };
    try std.testing.expect(spoke.rich());
    try std.testing.expectEqual(@as(u16, 4), spoke.figureRows());
    try std.testing.expectEqual(@as(u16, 3), quiet.figureRows());
}

test "ages read at human resolution" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12s", age(&b, 12_500));
    try std.testing.expectEqualStrings("4m", age(&b, 4 * 60_000 + 10));
    try std.testing.expectEqualStrings("2h", age(&b, 2 * 3_600_000));
    try std.testing.expectEqualStrings("3d", age(&b, 3 * 86_400_000));
}
