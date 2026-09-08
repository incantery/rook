//! The root: rook's home, the layer above every space.
//!
//! Rook lands here. The whole glass belongs to rook: the scope slot
//! reads the system's chip with the world in one line after it, and
//! the canvas is the place to say what should happen next, see what
//! needs you, what is running, what finished, and where — every
//! space, as a destination. Global pins do not move a column: scope
//! is taught by what refuses to move. The calm bar stays. Entering a
//! space is exact — the panes kept running underneath, unresized,
//! and this file painted over them — and `prefix-o` comes back up.
//!
//! One input, already focused, and one grammar: bare text is a
//! request to the companion (ask.zig); `/` finds spaces, work, tabs
//! and panes; `:` is an exact command with completions. Typing never
//! acts; `↵` does. Because bare typing is text, the rows are walked
//! with ↑ ↓ (⇥ ⇤, C-n C-p), never with letters. Esc closes the
//! deepest layer first: a running request, a query, a receipt, a
//! subview — and at home with nothing open it does nothing, because
//! there is nothing above home.
//!
//! Three views of one scope. Home is the default: intent, attention,
//! work, outcomes, spaces, as rows. Orbit is the spatial subview: a
//! figure per space when the glass has room. Ledger is the same
//! spaces as two-line rows — narrow glass, `zoom_view = "ledger"`,
//! and every renderer that is not this one. Identical keys.
//!
//! This file holds the model, the painter and the input state. It
//! knows nothing about sessions: the server fills the model from its
//! own tables (`Server.altBuild`) and acts on the row chosen
//! (`Server.altAct`). The ontology — what a space, a tab, a pane, an
//! actor, a tool and a work item are at runtime — is `docs/altitude.md`.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const askpkg = @import("ask.zig");
const homepkg = @import("home.zig");
const ui = @import("ui.zig");

pub const Rgb = chromepkg.Rgb;

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
    /// a work item — a producer's task, or an agent rook found: ↵
    /// goes to its exact pane, tab or space
    work,
    /// an action the companion proposed: ↵ runs its command, by hand
    action,
    /// a section header the cursor skips
    header,
    /// prose the cursor skips
    note,
};

pub const Command = enum { none, new, go, rename, close, ledger, orbit, home, now, vera };

/// The three views of the root scope.
pub const View = enum {
    home,
    orbit,
    ledger,

    pub fn word(self: View) []const u8 {
        return switch (self) {
            .home => "home",
            .orbit => "orbit",
            .ledger => "ledger",
        };
    }
};

/// What the input's first character makes of the rest.
pub const Mode = enum {
    /// bare text: a request to the companion
    intent,
    /// `/`: find spaces, work, tabs, panes
    find,
    /// `:`: an exact command
    command,

    pub fn word(self: Mode) []const u8 {
        return switch (self) {
            .intent => "ask",
            .find => "find",
            .command => "command",
        };
    }
};

/// Where `prefix-a` and `prefix-!` put the cursor: the first row of
/// a section, once the rows are built.
pub const Land = enum { none, needs, running };

/// A work item, as rook can truthfully describe one: a producer's
/// row (goal, state, space, and the fields it may add — actor, event,
/// result), or an agent rook found running in a pane nobody claimed.
/// Missing fields stay empty; nothing here is inferred from output.
pub const Work = struct {
    goal: []const u8,
    state: chromepkg.State = .none,
    /// the space's label, and its identity
    space: []const u8 = "",
    full: []const u8 = "",
    actor: []const u8 = "",
    event: []const u8 = "",
    result: []const u8 = "",
    unread: bool = false,
    found: bool = false,
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
    .{ .word = "ledger", .cmd = .ledger, .arg = "", .help = "spaces as rows, no figures" },
    .{ .word = "orbit", .cmd = .orbit, .arg = "", .help = "spaces as figures, when the glass has room" },
    .{ .word = "home", .cmd = .home, .arg = "", .help = "rook's home: the conversation and the dashboard" },
    .{ .word = "now", .cmd = .now, .arg = "", .help = "the dashboard: what needs you, what runs, what finished" },
    .{ .word = "vera", .cmd = .vera, .arg = "", .help = "the conversation, and the composer" },
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
    /// ms since anything was written in it; 0 when nothing ever was
    quiet_ms: i64 = 0,

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
    /// which proposed action, for an `.action` row
    action: usize = 0,

    pub fn actionable(self: Row) bool {
        return self.kind != .note and self.kind != .header;
    }
};

/// Where a painted row landed, for the mouse. Rows relative to the
/// glass.
pub const Zone = struct { y0: u16, y1: u16, row: usize };

pub const max_spaces: usize = 24;
pub const max_tabs: usize = 12;
pub const max_excerpt: usize = 2;

/// What Esc did: the deepest open layer, closed. `stay` is home with
/// nothing open — there is nothing above it.
pub const Escape = enum { cancelled, cleared, unfocused, home, stay };

/// What was painted: home, or one of the two fidelities of the
/// spatial view (orbit falls back to ledger when the figures do not
/// fit).
pub const Painted = enum {
    home,
    orbit,
    ledger,

    pub fn word(self: Painted) []const u8 {
        return switch (self) {
            .home => "home",
            .orbit => "orbit",
            .ledger => "ledger",
        };
    }
};

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
    /// The view: home, or a subview. Kept across visits to a space;
    /// `prefix-o` always lands on home.
    view: View = .home,
    /// What was actually painted last.
    painted: Painted = .home,
    /// The request in flight or answered, and its receipt.
    req: askpkg.Request = .{},
    /// A section to put the cursor on at the next build.
    land: Land = .none,
    /// The cockpit: the thread, the cards, the focus (home.zig).
    home: homepkg.State = .{},

    pub fn textSlice(self: *const State) []const u8 {
        return self.text[0..self.len];
    }

    /// Bare text is intent; `/` finds; `:` leads a command.
    pub fn mode(self: *const State) Mode {
        if (self.len == 0) return .intent;
        return switch (self.text[0]) {
            '/' => .find,
            ':' => .command,
            else => .intent,
        };
    }

    pub fn isCommand(self: *const State) bool {
        return self.mode() == .command;
    }

    /// The text past the mode's leading character.
    pub fn query(self: *const State) []const u8 {
        const t = self.textSlice();
        return switch (self.mode()) {
            .intent => t,
            .find, .command => std.mem.trimStart(u8, t[1..], " "),
        };
    }

    /// Is anything being looked for — a query with letters in it?
    pub fn finding(self: *const State) bool {
        return self.mode() == .find and self.query().len > 0;
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
    }

    /// Esc closes the deepest layer first: a request still running,
    /// a query (and with it the results, the completions), focus on
    /// the thread or the dashboard (back to the composer), then a
    /// subview. At home with nothing open it does nothing: a space is
    /// a destination, never the parent of the root.
    pub fn escape(self: *State) Escape {
        if (self.req.busy()) {
            self.req.cancel();
            return .cancelled;
        }
        if (self.len > 0) {
            self.clear();
            return .cleared;
        }
        if (self.view == .home and self.home.focus != .composer) {
            self.home.focus = .composer;
            self.home.thread_cur = null;
            return .unfocused;
        }
        if (self.view != .home) {
            self.view = .home;
            self.cur = 0;
            return .home;
        }
        return .stay;
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
        return if (r.actionable()) r else null;
    }

    /// Is the cursor's row painted as selected?
    pub fn highlighted(self: *const State, i: usize) bool {
        if (i != self.cur or i >= self.rows.items.len) return false;
        return self.rows.items[i].actionable();
    }

    /// Move the cursor `d` rows, skipping prose, staying in range.
    pub fn move(self: *State, d: i32) void {
        const n = self.rows.items.len;
        if (n == 0) return;
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

/// Reset to the canvas ground with an ink: chrome, opaque, so the view
/// reads over a wallpaper.
fn ink(f: *renderpkg.Frame, t: *const ui.Theme, c: Rgb) void {
    var b: [64]u8 = undefined;
    f.put((ui.Style{ .fg = c, .bg = t.chrome }).sgr(&b));
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

/// Fill a rect with the chrome ground: what the server uses to blank
/// the rects that contracted with the space.
pub fn clearRect(f: *renderpkg.Frame, t: *const ui.Theme, r: layoutpkg.Rect) void {
    fillRect(f, r, t.chrome);
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

pub const Paint = struct {
    t: *const ui.Theme,
    /// the companion's name, and whether her command can be found
    ask_name: []const u8 = "vera",
    ask_on: bool = true,
};

/// The tab component's mark, from the tab bar's vocabulary.
pub fn markOf(m: chromepkg.TabMark) ui.Mark {
    return switch (m) {
        .none => .none,
        .working => .working,
        .unread => .unread,
        .attention => .attention,
    };
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

/// Decide what this frame paints, before the bars are composed, so
/// the bar's word and the canvas agree: home as itself; orbit when
/// asked for, nothing is being found, the region is wide enough for
/// a figure, and the figures fit; ledger otherwise.
pub fn chooseFidelity(st: *State, region: layoutpkg.Rect) void {
    if (st.view == .home) {
        st.painted = .home;
        return;
    }
    const avail = region.h -| 5; // the input, its line, the footer
    const orbit = st.view == .orbit and st.len == 0 and region.w >= 60 and orbitRows(st) <= avail;
    st.painted = if (orbit) .orbit else .ledger;
}

/// The input field's width: bounded to the content, never the whole
/// canvas.
fn fieldWidth(w: u16) u16 {
    return @min(w, 64);
}

/// Paint the view into `region` and record where each row landed.
/// Returns where the input's cursor is on the glass.
pub fn draw(f: *renderpkg.Frame, st: *State, region: layoutpkg.Rect, p: Paint) renderpkg.CursorOverride {
    const t = p.t;
    clearRect(f, t, region);
    st.zones_n = 0;
    // Home is the cockpit: the conversation with its composer at the
    // foot, the dashboard beside it. Finding and commanding take the
    // canvas over as one list under one field, whatever the view.
    if (st.painted == .home and st.mode() == .intent) {
        return homepkg.draw(f, st, region, .{ .t = t, .ask_name = p.ask_name, .ask_on = p.ask_on, .now = @import("pane.zig").epochMs() });
    }
    const x = region.x + 2;
    const w = region.w -| 4;
    const bottom = region.y + region.h;
    var y = region.y + 1;
    const ascii = t.glyphs == .ascii;

    // The input: a raised field the eye finds, the prompt in the
    // accent, the cursor in it. The placeholder is the grammar, so an
    // empty field still says what typing does here.
    const fw = fieldWidth(w);
    f.cup(x, y);
    style(f, .{ .bg = t.raised });
    pad(f, fw);
    f.cup(x, y);
    style(f, .{ .fg = t.accent, .bg = t.raised, .bold = true });
    f.put(" ");
    f.put(ui.glyph(t, .prompt));
    f.put(" ");
    var cx: u16 = x + 3;
    const text = st.textSlice();
    if (text.len == 0) {
        var pb: [128]u8 = undefined;
        const ph = if (p.ask_on)
            std.fmt.bufPrint(&pb, "Ask {s}…    / find    : command", .{p.ask_name}) catch "/ find    : command"
        else
            std.fmt.bufPrint(&pb, "{s} is not on PATH    / find    : command", .{p.ask_name}) catch "/ find    : command";
        style(f, .{ .fg = t.muted, .bg = t.raised });
        _ = putW(f, ph, fw -| 4);
    } else {
        style(f, .{ .fg = t.primary, .bg = t.raised, .bold = true });
        cx += putW(f, text, fw -| 4);
    }
    const cursor: renderpkg.CursorOverride = .{ .x = @min(cx, region.x + region.w -| 1), .y = y, .bar = true };
    y += 1;

    // Under the field: what the rows are, in one muted line.
    const under: []const u8 = switch (st.mode()) {
        .command => (if (ascii) "completions · enter runs the selected one · esc clears" else "completions · ↵ runs the selected one · esc clears"),
        .find => if (st.query().len > 0)
            (if (ascii) "matches · up/down move · enter acts on the selected · typing never does" else "matches · ↑ ↓ move · ↵ acts on the selected · typing never does")
        else
            "type to find a space, a work item, a tab, a pane",
        .intent => if (text.len > 0)
            (if (p.ask_on) (if (ascii) "enter sends it, as typed" else "↵ sends it, as typed") else "nobody to send it to · / find · : command")
        else
            "",
    };
    if (under.len > 0) {
        f.cup(x, y);
        ink(f, t, t.muted);
        _ = putW(f, under, w);
    }
    y += if (under.len > 0) 2 else 1;

    const orbit = st.painted == .orbit;
    var last_kind: ?Kind = null;

    for (st.rows.items, 0..) |r, i| {
        const sel = st.highlighted(i);
        var h: u16 = 1;
        var figure: ?Space = null;
        if (r.kind == .space) {
            const sp = st.spaces[r.space];
            if (orbit and sp.rich()) {
                figure = sp;
                h = sp.figureRows();
            } else if (st.painted == .ledger and r.second.len > 0) {
                h = 2;
            }
        }
        // a blank line before a section header that is not the first
        if (r.kind == .header and last_kind != null and y + 1 < bottom) y += 1;
        last_kind = r.kind;
        if (y + h > bottom -| 1) {
            if (y < bottom) {
                f.cup(x, y);
                ink(f, t, t.muted);
                var mb: [32]u8 = undefined;
                const m = std.fmt.bufPrint(&mb, "{s} {d} more", .{ ui.glyph(t, .more), st.rows.items.len - i }) catch "";
                _ = putW(f, m, w);
            }
            break;
        }
        if (st.zones_n < st.zones.len) {
            st.zones[st.zones_n] = .{ .y0 = y, .y1 = y + h, .row = i };
            st.zones_n += 1;
        }
        if (figure) |sp| {
            drawFigure(f, t, sp, sel, x, y, w);
            y += h + 1;
        } else if (r.kind == .space) {
            drawSpaceRow(f, t, r, st.spaces[r.space], sel, st.painted == .ledger, x, y, w);
            y += h;
        } else if (r.kind == .header) {
            drawHeader(f, t, r, x, y, w);
            y += h;
        } else {
            drawRow(f, t, r, sel, x, y, w);
            y += h;
        }
    }

    // The footer: keys a hand has not found yet, one muted line.
    if (y + 1 < bottom) {
        f.cup(x, bottom - 1);
        ink(f, t, t.muted);
        const keys: []const u8 = if (ascii) "up/down move · enter" else "↑ ↓ move · ↵";
        var fb: [200]u8 = undefined;
        const long: []const u8 = if (text.len > 0)
            "esc clears"
        else if (st.painted == .home)
            (std.fmt.bufPrint(&fb, "{s} · type to ask · / find · : command · :new <name> starts a space · prefix-s orbit", .{keys}) catch "")
        else
            (std.fmt.bufPrint(&fb, "{s} enter · / find · : command · esc home", .{keys}) catch "esc home");
        const short: []const u8 = if (text.len > 0) "esc clears" else if (st.painted == .home) (if (ascii) "up/down enter · / find · : command" else "↑ ↓ ↵ · / find · : command") else (if (ascii) "up/down enter · esc home" else "↑ ↓ ↵ · esc home");
        _ = putW(f, if (chromepkg.cols(long) <= w) long else short, w);
    }
    f.put(csi ++ "0m");
    return cursor;
}

/// A section header: a muted word and a count, no band, no glyph.
fn drawHeader(f: *renderpkg.Frame, t: *const ui.Theme, r: Row, x: u16, y: u16, w: u16) void {
    f.cup(x, y);
    ink(f, t, t.muted);
    var used = putW(f, r.name, w);
    if (r.line.len > 0 and used + 2 < w) {
        f.put(" ");
        used += 1;
        var hb: [64]u8 = undefined;
        _ = putW(f, hintText(t, r.line, &hb), w -| used);
    }
    f.put(csi ++ "0m");
}

/// A hint as the glass can show it: `↵ go` reads `enter go` on a
/// glass without the glyph. The server writes hints in the unicode
/// vocabulary; the painter owns the fallback, as it does for marks.
fn hintText(t: *const ui.Theme, hint: []const u8, buf: []u8) []const u8 {
    if (t.glyphs != .ascii) return hint;
    if (std.mem.startsWith(u8, hint, "↵")) {
        return std.fmt.bufPrint(buf, "enter{s}", .{hint["↵".len..]}) catch hint;
    }
    return hint;
}

/// The selected row's band: bounded to its content, one step up from
/// the chrome — never the accent, never the whole width.
fn band(f: *renderpkg.Frame, t: *const ui.Theme, x: u16, y: u16, w: u16) void {
    f.cup(x, y);
    style(f, .{ .bg = t.selection });
    pad(f, w);
}

/// One-line rows: attention, asks, tabs, panes, pins, commands, the
/// companion. The selected row wears the accent marker, its name in
/// primary bold, and a bounded band; the others sit on the chrome.
fn drawRow(f: *renderpkg.Frame, t: *const ui.Theme, r: Row, sel: bool, x: u16, y: u16, w: u16) void {
    if (r.kind == .note) {
        f.cup(x, y);
        ink(f, t, t.muted);
        _ = putW(f, r.name, w);
        return;
    }
    var hb: [48]u8 = undefined;
    const hint = hintText(t, r.hint, &hb);
    const hint_w: u16 = if (hint.len > 0) chromepkg.cols(hint) + 2 else 0;
    const body_w = w -| (5 + hint_w);
    const name_w = @min(chromepkg.cols(r.name), @min(body_w, 44));
    const line_w: u16 = if (r.line.len > 0) @min(chromepkg.cols(r.line) + 2, (5 + body_w) -| (5 + name_w)) else 0;
    const ground: Rgb = if (sel) t.selection else t.chrome;
    if (sel) band(f, t, x, y, @min(w, 5 + name_w + line_w + 1));
    f.cup(x, y);
    style(f, .{ .fg = t.accent, .bg = ground, .bold = true });
    f.put(if (sel) ui.glyph(t, .marker) else " ");
    f.put(" ");
    var used: u16 = 2;
    style(f, .{ .fg = r.ink, .bg = ground, .bold = r.kind == .attention or r.kind == .ask });
    used += putW(f, r.glyph, 2);
    while (used < 5) : (used += 1) {
        style(f, .{ .bg = ground });
        f.put(" ");
    }
    style(f, .{ .fg = t.primary, .bg = ground, .bold = sel });
    used += putW(f, r.name, @min(body_w, 44));
    if (r.line.len > 0 and used + 3 < 5 + body_w) {
        style(f, .{ .bg = ground });
        f.put("  ");
        used += 2;
        style(f, .{ .fg = r.line_ink, .bg = ground });
        used += putW(f, r.line, (5 + body_w) -| used);
    }
    if (hint_w > 0 and sel) {
        f.cup(x + w -| (hint_w - 2), y);
        ink(f, t, t.accent);
        _ = putW(f, hint, hint_w);
    }
    f.put(csi ++ "0m");
}

/// A space as a row: in ledger two lines (identity and event, then
/// its tabs); in orbit the compact form a data-poor space gets, one
/// line with its tabs after the event. The space you left wears its
/// chip, the same chip the scope bar gave it.
fn drawSpaceRow(f: *renderpkg.Frame, t: *const ui.Theme, r: Row, sp: Space, sel: bool, two_lines: bool, x: u16, y: u16, w: u16) void {
    const ground: Rgb = if (sel) t.selection else t.chrome;
    // the space you left wears its chip in the spatial views, where
    // it is the figure's identity; at home a space is a destination
    // like the others, and the chip would read as a selection
    const chip = sp.current and two_lines;
    const name_w = chromepkg.cols(sp.name) + (if (chip) @as(u16, 2) else 0);
    const ev_w = @min(chromepkg.cols(sp.event), w -| name_w -| 16);
    if (sel) band(f, t, x, y, @min(w, 4 + name_w + 2 + ev_w + 1));
    f.cup(x, y);
    style(f, .{ .fg = t.accent, .bg = ground, .bold = true });
    f.put(if (sel) ui.glyph(t, .marker) else " ");
    f.put(" ");
    var used: u16 = 2;
    if (chip) {
        used += ui.scopeChip(f, t, sp.name, .space);
    } else {
        style(f, .{ .fg = t.primary, .bg = ground, .bold = sel });
        used += putW(f, sp.name, 24);
    }
    style(f, .{ .bg = ground });
    f.put("  ");
    used += 2;
    style(f, .{ .fg = eventInk(t, sp.event_kind), .bg = ground });
    used += putW(f, sp.event, ev_w);
    if (!two_lines and r.second.len > 0 and used + 6 < w) {
        ink(f, t, t.muted);
        f.put("   ");
        used += 3;
        used += putW(f, r.second, w -| used -| 10);
    }
    if (sel and r.hint.len > 0) {
        var hb: [48]u8 = undefined;
        const hint = hintText(t, r.hint, &hb);
        const hw = chromepkg.cols(hint);
        f.cup(x + w -| hw, y);
        ink(f, t, t.accent);
        _ = putW(f, hint, hw);
    }
    if (two_lines and r.second.len > 0) {
        f.cup(x + 4, y + 1);
        ink(f, t, t.secondary);
        _ = putW(f, r.second, w -| 4);
    }
    f.put(csi ++ "0m");
}

fn eventInk(t: *const ui.Theme, k: Event) Rgb {
    return switch (k) {
        .quiet => t.muted,
        .working => t.working,
        .needs_you => t.attention,
        .unread => t.unread,
        .said => t.secondary,
    };
}

/// A figure: the space's chip in the top edge, its event beside it,
/// its tabs on the first line inside as the tab component, and for
/// the space you left, the last lines of the pane you were in. Sized
/// by what it holds. The edge is `border`, or `border_focused` when
/// selected — the same hierarchy a pane's seam uses.
fn drawFigure(f: *renderpkg.Frame, t: *const ui.Theme, sp: Space, sel: bool, x: u16, y: u16, w: u16) void {
    const edge: Rgb = if (sel) t.border_focused else t.border;
    const h = sp.figureRows();
    box(f, .{ .x = x, .y = y, .w = w, .h = h }, edge, t.chrome);
    // the name, in the edge: the space's chip
    f.cup(x + 1, y);
    ink(f, t, edge);
    f.put("┤");
    var used: u16 = 2;
    used += ui.scopeChip(f, t, sp.name, .space);
    ink(f, t, edge);
    f.put("├");
    used += 1;
    if (sp.unread > 0) {
        f.put(" ");
        ink(f, t, t.attention);
        f.put(ui.markGlyph(t, .attention));
        used += 2;
    }
    // the event, after a gap, in its own ink, a gap before the rule
    if (sp.event.len > 0 and used + 5 < w - 2) {
        ink(f, t, eventInk(t, sp.event_kind));
        f.put("  ");
        used += 2;
        used += putW(f, sp.event, w -| used -| 4);
        f.put(" ");
    }
    // inside: the tabs, as the component, dense
    f.cup(x + 2, y + 1);
    var tx: u16 = 0;
    for (sp.tabs) |tb| {
        const need = chromepkg.cols(tb.name) + 4;
        if (tx + need > w - 4) {
            ink(f, t, t.muted);
            _ = putW(f, ui.glyph(t, .more), 1);
            break;
        }
        tx += ui.tabDense(f, t, .{ .label = tb.name, .actor = tb.actor, .mark = markOf(tb.mark), .selected = tb.current }, t.chrome);
        ink(f, t, t.muted);
        f.put(" ");
        tx += 1;
    }
    // the excerpt: retained cells, read only, muted
    for (sp.excerpt, 0..) |line, i| {
        f.cup(x + 2, y + 2 + @as(u16, @intCast(i)));
        ink(f, t, t.muted);
        _ = putW(f, line, w -| 4);
    }
    // what ↵ does, in the bottom edge, when selected
    if (sel) {
        const hint: []const u8 = if (t.glyphs == .ascii) " enter " else " ↵ enter ";
        const hw = chromepkg.cols(hint);
        f.cup(x + w -| hw -| 2, y + h - 1);
        ink(f, t, t.accent);
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
    var out: [16]CommandSpec = undefined;
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

test "the cursor skips prose and headers, and esc peels one layer, never past home" {
    var st: State = .{};
    defer st.rows.deinit(std.testing.allocator);
    try st.rows.append(std.testing.allocator, .{ .kind = .header, .name = "needs you" });
    try st.rows.append(std.testing.allocator, .{ .kind = .space, .name = "vera" });
    try st.rows.append(std.testing.allocator, .{ .kind = .note, .name = "·····" });
    try st.rows.append(std.testing.allocator, .{ .kind = .work, .name = "fix auth" });
    st.cur = 0;
    st.clampCursor();
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    st.move(1);
    try std.testing.expectEqual(@as(usize, 3), st.cur);
    st.move(-1);
    try std.testing.expectEqual(@as(usize, 1), st.cur);
    try std.testing.expect(st.moveTo(.work));
    // the grammar: bare text is intent, / finds, : commands
    st.push('a');
    try std.testing.expectEqual(Mode.intent, st.mode());
    try std.testing.expectEqualStrings("a", st.query());
    st.clear();
    st.push('/');
    st.push('a');
    try std.testing.expectEqual(Mode.find, st.mode());
    try std.testing.expect(st.finding());
    try std.testing.expectEqualStrings("a", st.query());
    st.clear();
    st.push(':');
    try std.testing.expectEqual(Mode.command, st.mode());
    try std.testing.expect(!st.finding());
    // esc: a query first, then a subview, then nothing — home has
    // nothing above it
    st.view = .orbit;
    try std.testing.expectEqual(Escape.cleared, st.escape());
    try std.testing.expectEqual(@as(usize, 0), st.len);
    try std.testing.expectEqual(Escape.home, st.escape());
    try std.testing.expectEqual(View.home, st.view);
    try std.testing.expectEqual(Escape.stay, st.escape());
    // focus on the dashboard is a layer of its own, above the view
    st.home.focus = .dash;
    try std.testing.expectEqual(Escape.unfocused, st.escape());
    try std.testing.expectEqual(homepkg.Region.composer, st.home.focus);
    try std.testing.expectEqual(Escape.stay, st.escape());
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
