//! Home: the cockpit. The left answers "what do I want, and what have
//! vera and I decided?" — a conversation, oldest to newest, with the
//! composer anchored at its foot. The right answers "what is
//! happening right now?" — what needs you, what is in progress, what
//! finished, and the spaces, as cards. One interface, not two: a
//! card and a turn that are about the same task share its id, and
//! selecting either finds the other.
//!
//! The projection is task-centric. A task is a producer's row (the
//! rail's `agents` surface: goal, state, space, actor, event,
//! result); a space, an agent, a pane are metadata on it, never peer
//! rows. Rook's own sightings — an agent producing in a space no
//! producer claims — are one quiet card each, titled by what rook
//! can see; an idle agent is not work and gets no card. A pane that
//! rang, notified or finished a bar while nobody looked is a
//! `needs you` card until someone does. A proposed action from the
//! companion's reflection is an approval card, and the same action
//! in the plan block of the thread.
//!
//! The thread is this session's exchanges, kept in memory: what you
//! said, what she answered (words, or her reflection as a block),
//! what ran and what it printed, and rook's own one-line notes when
//! a task the rail knows changes state. There is no durable history
//! yet; the shape is here for when there is.
//!
//! Layout is one boundary (`layout`): a split at `split_pct` of the
//! region when both sides keep a useful width, else one view at a
//! time with a switcher — `vera`, `now` — and the attention count on
//! the hidden one. Focus is one of three regions — composer, thread,
//! dashboard — plus the transient modes the input's first character
//! opens; printable typing always reaches the composer. The regions
//! are laid out, so they take the vim motion the panes take: Ctrl-h/
//! j/k/l walks them (`navFocus`), and at an edge the key is the
//! view's again.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const ui = @import("ui.zig");
const altpkg = @import("altitude.zig");
const askpkg = @import("ask.zig");
const panepkg = @import("pane.zig");

pub const Rgb = chromepkg.Rgb;
const Rect = layoutpkg.Rect;

// ---- layout: the one boundary ----

/// The conversation's share of the region, in percent, and the
/// narrowest each side may be and still read. A glass that cannot
/// afford both shows one at a time.
pub const split_pct: u16 = 62;
pub const min_left: u16 = 50;
pub const min_right: u16 = 34;

pub const Layout = struct {
    /// the conversation (or, narrow, whichever view is up)
    left: Rect,
    /// the dashboard; null when the glass shows one view at a time
    right: ?Rect,
    divider_x: ?u16,
    wide: bool,
};

pub fn layout(region: Rect) Layout {
    if (region.w >= min_left + min_right + 1) {
        var lw: u16 = @intCast(@as(u32, region.w) * split_pct / 100);
        if (lw < min_left) lw = min_left;
        if (region.w - lw - 1 < min_right) lw = region.w - min_right - 1;
        return .{
            .left = .{ .x = region.x, .y = region.y, .w = lw, .h = region.h },
            .right = .{ .x = region.x + lw + 1, .y = region.y, .w = region.w - lw - 1, .h = region.h },
            .divider_x = region.x + lw,
            .wide = true,
        };
    }
    return .{ .left = region, .right = null, .divider_x = null, .wide = false };
}

// ---- the conversation ----

pub const Role = enum {
    /// what you typed
    you,
    /// her words
    vera,
    /// her reflection: intent, plan, question — a block
    plan,
    /// something ran, and what it printed
    receipt,
    /// a task finished: rook's note from the rail
    result,
    /// something failed: hers, or a task's
    err,
    /// rook's own one-line note (a task began, needs you)
    note,
};

pub const max_turn = 400;
pub const max_turns = 40;

pub const Turn = struct {
    role: Role = .note,
    text: [max_turn]u8 = undefined,
    len: usize = 0,
    ms: i64 = 0,
    /// the task (a rail id) this turn is about, when it is about one
    task: [32]u8 = undefined,
    task_len: usize = 0,
    /// the space it is about, when it is about one
    space: [32]u8 = undefined,
    space_len: usize = 0,
    /// a plan turn: the request whose actions it lists (its serial),
    /// so the block can show the actions' live state
    req_serial: u64 = 0,

    pub fn textSlice(self: *const Turn) []const u8 {
        return self.text[0..self.len];
    }
    pub fn taskSlice(self: *const Turn) []const u8 {
        return self.task[0..self.task_len];
    }
    pub fn spaceSlice(self: *const Turn) []const u8 {
        return self.space[0..self.space_len];
    }
};

/// The exchanges, a ring: the oldest falls off the top.
pub const Thread = struct {
    turns: [max_turns]Turn = undefined,
    n: usize = 0,
    head: usize = 0,

    pub fn count(self: *const Thread) usize {
        return self.n;
    }

    pub fn get(self: *Thread, i: usize) *Turn {
        return &self.turns[(self.head + i) % max_turns];
    }

    pub fn push(self: *Thread, role: Role, text: []const u8, task: []const u8, space: []const u8, ms: i64) *Turn {
        const idx = (self.head + self.n) % max_turns;
        if (self.n == max_turns) {
            self.head = (self.head + 1) % max_turns;
        } else {
            self.n += 1;
        }
        const t = &self.turns[idx];
        t.* = .{ .role = role, .ms = ms };
        t.len = take(&t.text, text);
        t.task_len = take(&t.task, task);
        t.space_len = take(&t.space, space);
        return t;
    }

    /// The most recent turn about `task`, if any.
    pub fn about(self: *Thread, task: []const u8) ?usize {
        if (task.len == 0) return null;
        var i = self.n;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.get(i).taskSlice(), task)) return i;
        }
        return null;
    }
};

// ---- the projection ----

pub const Kind = enum {
    /// a producer's task: the goal is its own word
    producer,
    /// an agent rook can see producing where no producer claims
    found,
    /// a pane that signalled while nobody looked
    signal,
    /// an action the companion proposed, waiting on a hand
    approval,
};

pub const Module = enum {
    needs,
    active,
    recent,
    spaces,

    pub fn word(self: Module) []const u8 {
        return switch (self) {
            .needs => "needs you",
            .active => "in progress",
            .recent => "recent",
            .spaces => "spaces",
        };
    }
};

pub const Task = struct {
    kind: Kind,
    module: Module,
    id: []const u8 = "",
    title: []const u8,
    state: chromepkg.State = .none,
    space: []const u8 = "",
    full: []const u8 = "",
    actor: []const u8 = "",
    event: []const u8 = "",
    result: []const u8 = "",
    unread: bool = false,
    /// ms since the last meaningful thing; 0 when unknown
    age_ms: i64 = 0,
    pane: u32 = 0,
    ws: ?usize = null,
    win: ?usize = null,
    /// an approval: which of the reflection's actions
    action: usize = 0,

    pub fn mark(self: Task) ui.Mark {
        return switch (self.kind) {
            .signal => .attention,
            .approval => .waiting,
            .found => .working,
            .producer => switch (self.state) {
                .working => .working,
                .blocked => .attention,
                .failed => .failed,
                .done => .success,
                .idle, .none => .waiting,
            },
        };
    }
};

pub const max_tasks = 48;
pub const max_cards = 72;

/// One thing painted on the dashboard: a module header, a task card,
/// a space row, or the quiet line an empty dashboard shows.
pub const Card = struct {
    module: Module,
    header: bool = false,
    task: ?usize = null,
    space: ?usize = null,
    /// rows it took, as last painted
    rows: u16 = 0,
    y: u16 = 0,

    pub fn actionable(self: Card) bool {
        return self.task != null or self.space != null;
    }
};

pub const Region = enum { composer, thread, dash };
pub const NarrowView = enum { vera, now };

/// A task's state as last seen, so a change earns a note.
const Seen = struct { id: [32]u8 = undefined, len: usize = 0, state: chromepkg.State = .none };

/// The cockpit's own state: what outlives a frame, and a visit to a
/// space.
pub const State = struct {
    thread: Thread = .{},
    focus: Region = .composer,
    /// where the glass was last painted: wide, or one view
    wide: bool = true,
    tasks: [max_tasks]Task = undefined,
    tasks_n: usize = 0,
    cards: [max_cards]Card = undefined,
    cards_n: usize = 0,
    /// the selected card, an index into `cards` — and its identity,
    /// so a rebuild that inserts cards above it does not move it.
    /// Until a hand moves the cursor it rests on the first card.
    dash_cur: usize = 0,
    dash_key: [72]u8 = undefined,
    dash_key_len: usize = 0,
    dash_touched: bool = false,
    /// the first card painted, for a dashboard taller than the glass
    dash_scroll: usize = 0,
    /// the selected turn while the thread has focus
    thread_cur: ?usize = null,
    /// the left region a motion into the dashboard came from, so the
    /// motion back lands where the hand left — composer, or thread
    left_from: Region = .composer,
    /// the turn about the selected card, highlighted while the
    /// dashboard has focus
    linked: ?usize = null,
    /// rows the thread is scrolled up from its foot
    thread_scroll: usize = 0,
    seen: [max_tasks]Seen = undefined,
    seen_n: usize = 0,
    /// the first build seeds what is known without a word; after it,
    /// a task appearing is news
    seeded: bool = false,
    /// the request the latest plan turn belongs to
    req_serial: u64 = 0,

    pub fn reset(self: *State) void {
        self.tasks_n = 0;
        self.cards_n = 0;
    }

    pub fn addTask(self: *State, t: Task) ?usize {
        if (self.tasks_n == max_tasks) return null;
        self.tasks[self.tasks_n] = t;
        self.tasks_n += 1;
        return self.tasks_n - 1;
    }

    pub fn addCard(self: *State, c: Card) void {
        if (self.cards_n == max_cards) return;
        self.cards[self.cards_n] = c;
        self.cards_n += 1;
    }

    /// The selected card's identity: the task's id, else its kind and
    /// pane, else the space.
    fn cardKey(self: *const State, c: Card, buf: []u8) []const u8 {
        if (c.task) |ti| {
            const tk = self.tasks[ti];
            if (tk.id.len > 0) return std.fmt.bufPrint(buf, "t:{s}:{s}", .{ tk.id, tk.title }) catch "";
            return std.fmt.bufPrint(buf, "{s}:{d}:{s}", .{ @tagName(tk.kind), tk.pane, tk.title }) catch "";
        }
        if (c.space) |si| return std.fmt.bufPrint(buf, "s:{d}", .{si}) catch "";
        return "";
    }

    /// Remember what is selected, by identity.
    pub fn noteSelection(self: *State) void {
        if (self.cards_n == 0) return;
        const c = self.cards[@min(self.dash_cur, self.cards_n - 1)];
        var b: [72]u8 = undefined;
        const k = self.cardKey(c, &b);
        self.dash_key_len = take(&self.dash_key, k);
    }

    /// After a rebuild: the same card by identity when it is still
    /// there, the first card until a hand has chosen, else the clamp.
    pub fn restoreSelection(self: *State) void {
        if (!self.dash_touched) {
            self.dash_cur = 0;
            self.clampDash();
            self.noteSelection();
            return;
        }
        if (self.dash_key_len > 0) {
            for (self.cards[0..self.cards_n], 0..) |c, i| {
                var b: [72]u8 = undefined;
                if (std.mem.eql(u8, self.cardKey(c, &b), self.dash_key[0..self.dash_key_len])) {
                    self.dash_cur = i;
                    return;
                }
            }
        }
        self.clampDash();
        self.noteSelection();
    }

    /// The narrow view follows focus: the dashboard is `now`.
    pub fn narrowView(self: *const State) NarrowView {
        return if (self.focus == .dash) .now else .vera;
    }

    /// The selected card, when the cursor is on one.
    pub fn selectedCard(self: *const State) ?Card {
        if (self.cards_n == 0) return null;
        const c = self.cards[@min(self.dash_cur, self.cards_n - 1)];
        return if (c.actionable()) c else null;
    }

    /// Move the dashboard cursor over the actionable cards.
    pub fn moveDash(self: *State, d: i32) void {
        const n = self.cards_n;
        if (n == 0) return;
        self.dash_touched = true;
        var i: i64 = @intCast(@min(self.dash_cur, n - 1));
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            i += d;
            if (i < 0 or i >= @as(i64, @intCast(n))) break;
            if (self.cards[@intCast(i)].actionable()) {
                self.dash_cur = @intCast(i);
                break;
            }
        }
        self.noteSelection();
    }

    pub fn clampDash(self: *State) void {
        const n = self.cards_n;
        if (n == 0) {
            self.dash_cur = 0;
            return;
        }
        if (self.dash_cur >= n) self.dash_cur = n - 1;
        if (!self.cards[self.dash_cur].actionable()) {
            var i = self.dash_cur;
            while (i < n and !self.cards[i].actionable()) i += 1;
            if (i < n) {
                self.dash_cur = i;
                return;
            }
            i = self.dash_cur;
            while (i > 0 and !self.cards[i].actionable()) i -= 1;
            self.dash_cur = i;
        }
    }

    /// Put the dashboard cursor on the first card of a module.
    pub fn landDash(self: *State, m: Module) bool {
        for (self.cards[0..self.cards_n], 0..) |c, i| {
            if (c.module == m and c.actionable()) {
                self.dash_cur = i;
                self.dash_touched = true;
                self.noteSelection();
                return true;
            }
        }
        return false;
    }

    /// The card for a task id, or a space, if one is on the dashboard.
    pub fn cardFor(self: *const State, task: []const u8, space: []const u8) ?usize {
        for (self.cards[0..self.cards_n], 0..) |c, i| {
            if (c.task) |ti| {
                if (task.len > 0 and std.mem.eql(u8, self.tasks[ti].id, task)) return i;
            }
        }
        for (self.cards[0..self.cards_n], 0..) |c, i| {
            if (c.space) |_| {
                if (c.task == null and space.len > 0) {
                    // the space rows are matched by the caller, who
                    // has the names; here only tasks in that space
                    continue;
                }
            }
            if (c.task) |ti| {
                if (space.len > 0 and std.mem.eql(u8, self.tasks[ti].full, space)) return i;
            }
        }
        return null;
    }

    pub fn remember(self: *State, id: []const u8, state: chromepkg.State) ?chromepkg.State {
        for (self.seen[0..self.seen_n]) |*s| {
            if (std.mem.eql(u8, s.id[0..s.len], id)) {
                const was = s.state;
                s.state = state;
                return if (was == state) null else was;
            }
        }
        if (self.seen_n == max_tasks) return null;
        const s = &self.seen[self.seen_n];
        s.* = .{ .state = state };
        s.len = take(&s.id, id);
        self.seen_n += 1;
        return .none;
    }

    /// The count on the `now` badge: what needs you.
    pub fn needsCount(self: *const State) usize {
        var n: usize = 0;
        for (self.tasks[0..self.tasks_n]) |t| {
            if (t.module == .needs) n += 1;
        }
        return n;
    }

    /// Focus the dashboard, remembering the left region it was
    /// reached from — the motion back lands there.
    pub fn toDash(self: *State) void {
        if (self.focus != .dash) self.left_from = self.focus;
        self.focus = .dash;
    }

    /// The regions have a geometry, so they take vim's motions. The
    /// thread sits above the composer on the left; the dashboard is
    /// right of both:
    ///
    ///     ┌──────────┬──────┐
    ///     │  thread  │      │
    ///     ├──────────┤ dash │
    ///     │ composer │      │
    ///     └──────────┴──────┘
    ///
    /// Ctrl-h/j/k/l walk it — the same four keys that walk the panes
    /// inside a space, so the motion does not stop at home's door.
    /// Returns true when focus moved; at an edge nothing happens and
    /// the key is the view's again (Ctrl-H still deletes in the
    /// composer, as backspace).
    pub fn navFocus(self: *State, dir: u8) bool {
        switch (dir) {
            'l' => {
                if (self.focus == .dash) return false;
                self.toDash();
                return true;
            },
            'h' => {
                if (self.focus != .dash) return false;
                self.focus = if (self.left_from == .thread and self.thread.count() > 0) .thread else .composer;
                if (self.focus == .thread) {
                    if (self.thread_cur == null) self.thread_cur = self.thread.count() - 1;
                } else {
                    self.thread_cur = null;
                }
                return true;
            },
            'k' => {
                if (self.focus != .composer or self.thread.count() == 0) return false;
                self.focus = .thread;
                if (self.thread_cur == null) self.thread_cur = self.thread.count() - 1;
                return true;
            },
            'j' => {
                if (self.focus != .thread) return false;
                self.focus = .composer;
                self.thread_cur = null;
                return true;
            },
            else => return false,
        }
    }

    pub fn moveThread(self: *State, d: i32) void {
        const n = self.thread.count();
        if (n == 0) {
            self.thread_cur = null;
            return;
        }
        const cur: i64 = if (self.thread_cur) |c| @intCast(@min(c, n - 1)) else @intCast(n);
        var i = cur + d;
        if (i < 0) i = 0;
        if (i >= @as(i64, @intCast(n))) i = @intCast(n - 1);
        self.thread_cur = @intCast(i);
    }
};

fn take(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ---- painting ----

const csi = "\x1b[";

fn style(f: *renderpkg.Frame, st: ui.Style) void {
    var b: [64]u8 = undefined;
    f.put(st.sgr(&b));
}

fn ink(f: *renderpkg.Frame, t: *const ui.Theme, c: Rgb, ground: Rgb) void {
    _ = t;
    style(f, .{ .fg = c, .bg = ground });
}

fn pad(f: *renderpkg.Frame, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) f.put(" ");
}

/// Greedy word wrap by columns; returns the lines, at most `out.len`.
pub fn wrap(text: []const u8, width: u16, out: [][]const u8) usize {
    if (width == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |para| {
        var rest = para;
        if (rest.len == 0) {
            if (n < out.len) {
                out[n] = "";
                n += 1;
            }
            continue;
        }
        while (rest.len > 0) {
            if (n == out.len) return n;
            if (chromepkg.cols(rest) <= width) {
                out[n] = rest;
                n += 1;
                break;
            }
            // the last space within the width, else cut
            var cut: usize = 0;
            var cols_so_far: u16 = 0;
            var i: usize = 0;
            var last_space: usize = 0;
            while (i < rest.len) {
                const len = std.unicode.utf8ByteSequenceLength(rest[i]) catch 1;
                if (cols_so_far + 1 > width) break;
                if (rest[i] == ' ') last_space = i;
                cols_so_far += 1;
                i += len;
                cut = i;
            }
            if (last_space > 0) cut = last_space;
            out[n] = rest[0..cut];
            n += 1;
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
    }
    return n;
}

pub const Paint = struct {
    t: *const ui.Theme,
    ask_name: []const u8 = "vera",
    ask_on: bool = true,
    now: i64 = 0,
};

/// The companion's status word for the header and the composer.
pub fn askStatus(st: *const altpkg.State, p: Paint) struct { word: []const u8, mark: ui.Mark } {
    if (!p.ask_on and st.req.state != .running) return .{ .word = "offline — not on PATH", .mark = .failed };
    return switch (st.req.state) {
        .running => .{ .word = "thinking", .mark = .working },
        .replied => if (st.req.ref) |*r| (if (r.pending() > 0) .{ .word = "waiting for you", .mark = .attention } else if (r.question_len > 0) .{ .word = "asked you something", .mark = .attention } else .{ .word = "ready", .mark = .none }) else .{ .word = "ready", .mark = .none },
        .failed => .{ .word = "could not answer", .mark = .failed },
        .offline => .{ .word = "offline — not on PATH", .mark = .failed },
        .none => .{ .word = "ready", .mark = .none },
    };
}

/// Paint the cockpit into `region`. Returns where the cursor is.
pub fn draw(f: *renderpkg.Frame, st: *altpkg.State, region: Rect, p: Paint) renderpkg.CursorOverride {
    const t = p.t;
    const h = &st.home;
    const lay = layout(region);
    h.wide = lay.wide;
    var cursor: renderpkg.CursorOverride = .{ .x = region.x, .y = region.y, .hidden = true };

    if (lay.wide) {
        // the divider: one quiet column
        if (lay.divider_x) |dx| {
            var y: u16 = region.y;
            while (y < region.y + region.h) : (y += 1) {
                f.cup(dx, y);
                ink(f, t, t.border_subtle, t.chrome);
                f.put(ui.glyph(t, .separator));
            }
        }
        cursor = drawConversation(f, st, lay.left, p, false);
        drawDashboard(f, st, lay.right.?, p, false);
    } else {
        // one view at a time, with the switcher on its first row
        const view = h.narrowView();
        drawSwitcher(f, st, region, p, view);
        const body: Rect = .{ .x = region.x, .y = region.y + 1, .w = region.w, .h = region.h -| 1 };
        switch (view) {
            .vera => cursor = drawConversation(f, st, body, p, true),
            .now => drawDashboard(f, st, body, p, true),
        }
    }
    f.put(csi ++ "0m");
    return cursor;
}

fn drawSwitcher(f: *renderpkg.Frame, st: *altpkg.State, region: Rect, p: Paint, view: NarrowView) void {
    const t = p.t;
    const h = &st.home;
    f.cup(region.x, region.y);
    style(f, .{ .bg = t.chrome });
    pad(f, region.w);
    f.cup(region.x + 2, region.y);
    _ = ui.tabDense(f, t, .{ .label = "vera", .selected = view == .vera }, t.chrome);
    ink(f, t, t.muted, t.chrome);
    f.put("  ");
    var nb: [24]u8 = undefined;
    const needs = h.needsCount();
    // the attention count rides the hidden view's tab, as its mark
    _ = ui.tabDense(f, t, .{ .label = "now", .mark = if (needs > 0 and view == .vera) .attention else .none, .selected = view == .now }, t.chrome);
    if (needs > 0 and view == .vera) {
        ink(f, t, t.attention, t.chrome);
        _ = altpkg.putW(f, std.fmt.bufPrint(&nb, "{d}", .{needs}) catch "", 4);
    }
    ink(f, t, t.muted, t.chrome);
    f.put("   ");
    _ = altpkg.putW(f, if (t.glyphs == .ascii) "tab switches" else "⇥ switches", region.w -| 24);
}

/// The left region: a header, the thread bottom-anchored, and the
/// composer at the foot with its hint.
fn drawConversation(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, narrow: bool) renderpkg.CursorOverride {
    const t = p.t;
    const h = &st.home;
    const x = r.x + 2;
    const w = r.w -| 4;
    const focused_thread = h.focus == .thread;
    const focused_comp = h.focus == .composer;

    // header: the companion, and where she stands
    var y = r.y;
    if (!narrow) {
        f.cup(x, y);
        ink(f, t, if (focused_thread or focused_comp) t.secondary else t.muted, t.chrome);
        f.put(ui.glyph(t, .companion));
        f.put(" ");
        style(f, .{ .fg = if (focused_thread or focused_comp) t.primary else t.secondary, .bg = t.chrome, .bold = true });
        var used: u16 = 2 + altpkg.putW(f, p.ask_name, 16);
        const status = askStatus(st, p);
        ink(f, t, t.muted, t.chrome);
        f.put(" · ");
        used += 3;
        const mg = ui.markGlyph(t, status.mark);
        if (mg.len > 0) {
            ink(f, t, ui.markInk(t, status.mark), t.chrome);
            f.put(mg);
            f.put(" ");
            used += 2;
        }
        ink(f, t, if (status.mark == .none) t.muted else ui.markInk(t, status.mark), t.chrome);
        used += altpkg.putW(f, status.word, w -| used);
        y += 2;
    }

    // the composer: two rows at the foot
    const comp_y = r.y + r.h -| 2;
    const thread_bottom = comp_y -| 1;
    const thread_rows: u16 = thread_bottom -| y;

    // the thread, bottom-anchored: lay every turn out, then paint
    // the window that ends `thread_scroll` rows above the foot
    var lines: [512]Line = undefined;
    const n_lines = layoutThread(st, w, &lines, p);
    const visible: usize = @min(n_lines, thread_rows);
    const max_scroll: usize = n_lines -| visible;
    if (h.thread_scroll > max_scroll) h.thread_scroll = max_scroll;
    // a selected turn is kept in view
    if (focused_thread) {
        if (h.thread_cur) |tc| {
            var first: ?usize = null;
            var last: usize = 0;
            for (lines[0..n_lines], 0..) |ln, i| {
                if (ln.turn == tc) {
                    if (first == null) first = i;
                    last = i;
                }
            }
            if (first) |fi| {
                const end = n_lines - h.thread_scroll; // exclusive
                const start = end -| visible;
                if (fi < start) h.thread_scroll = n_lines - @min(n_lines, fi + visible);
                if (last >= end) h.thread_scroll = n_lines -| (last + 1);
            }
        }
    }
    const end = n_lines - h.thread_scroll;
    const start = end -| visible;
    var row: u16 = thread_bottom -| @as(u16, @intCast(visible));
    if (n_lines == 0) {
        // the empty thread: what this side is for, and no more
        f.cup(x, thread_bottom -| 2);
        ink(f, t, t.muted, t.chrome);
        var wrapped: [3][]const u8 = undefined;
        const k = wrap(if (p.ask_on) "say what should happen; she answers here, and the work shows on the right" else "nobody to talk to — / finds, : commands, the right side still tells the truth", w, &wrapped);
        for (wrapped[0..k], 0..) |ln, i| {
            f.cup(x, thread_bottom -| 3 + @as(u16, @intCast(i)));
            _ = altpkg.putW(f, ln, w);
        }
    }
    for (lines[start..end]) |ln| {
        drawLine(f, st, ln, x, row, w, p, focused_thread);
        row += 1;
    }
    if (h.thread_scroll > 0 and thread_rows > 0) {
        var mb: [32]u8 = undefined;
        f.cup(x + w -| 12, thread_bottom - 1);
        ink(f, t, t.muted, t.chrome);
        _ = altpkg.putW(f, std.fmt.bufPrint(&mb, "{s} {d} below", .{ ui.glyph(t, .more), h.thread_scroll }) catch "", 12);
    }

    // the composer
    return drawComposer(f, st, x, comp_y, w, p, focused_comp);
}

const Line = struct {
    turn: usize,
    /// the first line of its turn: wears the role
    first: bool,
    text: []const u8,
    role: Role,
    /// inside a plan block, an action line with its state
    action: ?usize = null,
    block: bool = false,
};

/// Every line of the thread, wrapped to `w`, oldest first.
fn layoutThread(st: *altpkg.State, w: u16, out: []Line, p: Paint) usize {
    _ = p;
    const h = &st.home;
    var n: usize = 0;
    const body_w = w -| 13;
    var i: usize = 0;
    while (i < h.thread.count()) : (i += 1) {
        const turn = h.thread.get(i);
        var wrapped: [24][]const u8 = undefined;
        const k = wrap(turn.textSlice(), body_w, &wrapped);
        var j: usize = 0;
        while (j < k) : (j += 1) {
            if (n == out.len) return n;
            out[n] = .{ .turn = i, .first = j == 0, .text = wrapped[j], .role = turn.role, .block = turn.role == .plan };
            n += 1;
        }
        // the latest plan block lists its actions, live
        if (turn.role == .plan and turn.req_serial == h.req_serial) {
            if (st.req.ref) |*r| {
                var a: usize = 0;
                while (a < r.actions_n) : (a += 1) {
                    if (n == out.len) return n;
                    out[n] = .{ .turn = i, .first = false, .text = r.actions[a].labelSlice(), .role = .plan, .action = a, .block = true };
                    n += 1;
                }
            }
        }
        // a blank line between turns
        if (n < out.len and i + 1 < h.thread.count()) {
            out[n] = .{ .turn = i, .first = false, .text = "", .role = turn.role };
            n += 1;
        }
    }
    return n;
}

fn roleMark(t: *const ui.Theme, role: Role) struct { glyph: []const u8, c: Rgb, bold: bool } {
    return switch (role) {
        .you => .{ .glyph = "you", .c = t.primary, .bold = true },
        .vera => .{ .glyph = ui.glyph(t, .companion), .c = t.accent, .bold = true },
        .plan => .{ .glyph = ui.glyph(t, .companion), .c = t.accent, .bold = true },
        .receipt => .{ .glyph = ui.markGlyph(t, .success), .c = t.muted, .bold = false },
        .result => .{ .glyph = ui.markGlyph(t, .success), .c = t.success, .bold = false },
        .err => .{ .glyph = ui.markGlyph(t, .failed), .c = t.err, .bold = false },
        .note => .{ .glyph = "·", .c = t.muted, .bold = false },
    };
}

fn drawLine(f: *renderpkg.Frame, st: *altpkg.State, ln: Line, x: u16, y: u16, w: u16, p: Paint, focused: bool) void {
    const t = p.t;
    const h = &st.home;
    const sel = if (focused) (h.thread_cur != null and h.thread_cur.? == ln.turn) else (h.focus == .dash and h.linked != null and h.linked.? == ln.turn);
    const ground: Rgb = if (ln.block) t.raised else t.chrome;
    // a plan block is tinted across the body; a selected turn's first
    // line wears the band and the marker
    f.cup(x, y);
    style(f, .{ .bg = t.chrome });
    pad(f, w);
    if (ln.block) {
        f.cup(x + 5, y);
        style(f, .{ .bg = t.raised });
        pad(f, w -| 5);
    }
    if (sel and ln.first) {
        f.cup(x, y);
        style(f, .{ .fg = t.accent, .bg = t.chrome, .bold = true });
        f.put(ui.glyph(t, .marker));
    }
    if (ln.first) {
        const m = roleMark(t, ln.role);
        f.cup(x + 2, y);
        style(f, .{ .fg = m.c, .bg = t.chrome, .bold = m.bold });
        _ = altpkg.putW(f, m.glyph, 3);
    }
    f.cup(x + 6, y);
    if (ln.action) |a| {
        const act = &st.req.ref.?.actions[a];
        const mark: ui.Mark = if (act.running) .working else if (!act.ran) .waiting else if (act.code == 0) .success else .failed;
        ink(f, t, ui.markInk(t, mark), ground);
        f.put(ui.markGlyph(t, mark));
        f.put(" ");
        ink(f, t, if (act.ran) t.muted else t.primary, ground);
        var used: u16 = 2 + altpkg.putW(f, ln.text, w -| 9);
        if (act.ran and used + 6 < w - 7) {
            ink(f, t, t.muted, ground);
            f.put(" · ");
            used += 3;
            _ = altpkg.putW(f, askpkg.firstLine(act.receiptSlice()), w -| 7 -| used);
        } else if (!act.ran and used + 14 < w - 7) {
            ink(f, t, t.muted, ground);
            f.put("  ");
            _ = altpkg.putW(f, if (t.glyphs == .ascii) "needs you: enter on its card" else "needs you · ↵ on its card", w -| 7 -| used -| 2);
        }
        return;
    }
    const c: Rgb = switch (ln.role) {
        .you => t.primary,
        .vera => t.secondary,
        .plan => t.primary,
        .receipt => t.muted,
        .result => t.secondary,
        .err => t.secondary,
        .note => t.muted,
    };
    style(f, .{ .fg = c, .bg = ground, .bold = sel and ln.first });
    const used = altpkg.putW(f, ln.text, w -| 7);
    // the age, quiet, at the end of the first line
    if (ln.first) {
        const turn = h.thread.get(ln.turn);
        var ab: [16]u8 = undefined;
        const age = altpkg.age(&ab, p.now - turn.ms);
        const aw = chromepkg.cols(age);
        if (used + aw + 2 < w) {
            f.cup(x + w -| aw, y);
            ink(f, t, t.muted, t.chrome);
            _ = altpkg.putW(f, age, aw);
        }
    }
}

fn drawComposer(f: *renderpkg.Frame, st: *altpkg.State, x: u16, y: u16, w: u16, p: Paint, focused: bool) renderpkg.CursorOverride {
    const t = p.t;
    const fw = w;
    f.cup(x, y);
    style(f, .{ .bg = if (focused) t.raised else t.chrome });
    pad(f, fw);
    f.cup(x, y);
    style(f, .{ .fg = if (focused) t.accent else t.muted, .bg = if (focused) t.raised else t.chrome, .bold = true });
    f.put(" ");
    f.put(ui.glyph(t, .prompt));
    f.put(" ");
    var cx: u16 = x + 3;
    const text = st.textSlice();
    const ground: Rgb = if (focused) t.raised else t.chrome;
    if (text.len == 0) {
        var pb: [128]u8 = undefined;
        const ph = if (p.ask_on)
            std.fmt.bufPrint(&pb, "Ask {s}…", .{p.ask_name}) catch "Ask…"
        else
            std.fmt.bufPrint(&pb, "{s} is not on PATH — / find · : command", .{p.ask_name}) catch "/ find · : command";
        ink(f, t, t.muted, ground);
        _ = altpkg.putW(f, ph, fw -| 4);
    } else {
        style(f, .{ .fg = t.primary, .bg = ground, .bold = true });
        cx += altpkg.putW(f, text, fw -| 4);
    }
    // under it: the grammar, or what the request is doing
    f.cup(x, y + 1);
    ink(f, t, t.muted, t.chrome);
    const status = askStatus(st, p);
    var hb: [160]u8 = undefined;
    const hint: []const u8 = if (st.req.state == .running)
        (std.fmt.bufPrint(&hb, "{s} {s} · esc cancels", .{ p.ask_name, status.word }) catch "")
    else if (!focused)
        (if (t.glyphs == .ascii) "type to ask · tab moves focus" else "type to ask · ⇥ moves focus")
    else if (text.len > 0 and st.mode() == .intent)
        (if (t.glyphs == .ascii) "enter sends it, as typed" else "↵ sends it, as typed")
    else
        (if (t.glyphs == .ascii) "enter sends · / find · : command · tab dashboard" else "↵ sends · / find · : command · ⇥ dashboard");
    _ = altpkg.putW(f, hint, w);
    return .{ .x = @min(cx, x + fw -| 1), .y = y, .bar = true, .hidden = !focused };
}

/// The right region: the modules, as cards.
fn drawDashboard(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, narrow: bool) void {
    const t = p.t;
    const h = &st.home;
    const x = r.x + 2;
    const w = r.w -| 3;
    const focused = h.focus == .dash;
    var y = r.y;
    const bottom = r.y + r.h;

    if (!narrow) {
        f.cup(x, y);
        style(f, .{ .fg = if (focused) t.primary else t.secondary, .bg = t.chrome, .bold = true });
        f.put("now");
        const needs = h.needsCount();
        if (needs > 0) {
            ink(f, t, t.muted, t.chrome);
            f.put(" · ");
            ink(f, t, t.attention, t.chrome);
            var nb: [24]u8 = undefined;
            _ = altpkg.putW(f, std.fmt.bufPrint(&nb, "{s} {d} need{s} you", .{ ui.markGlyph(t, .attention), needs, if (needs == 1) "s" else "" }) catch "", 24);
        }
        y += 2;
    }

    // rows per card, then paint from the scroll, keeping the selected
    // card in view
    var heights: [max_cards]u16 = undefined;
    var total: u16 = 0;
    for (h.cards[0..h.cards_n], 0..) |c, i| {
        heights[i] = cardHeight(h, c, w);
        total += heights[i];
    }
    const overflow = total > bottom -| y;
    const avail: u16 = bottom -| y -| @as(u16, if (overflow) 1 else 0);
    if (h.dash_scroll >= h.cards_n) h.dash_scroll = 0;
    if (focused and h.cards_n > 0) {
        const cur = @min(h.dash_cur, h.cards_n - 1);
        if (cur < h.dash_scroll) h.dash_scroll = cur;
        // scroll down until the selected card's last row fits
        while (true) {
            var used: u16 = 0;
            var i = h.dash_scroll;
            var fits = false;
            while (i <= cur) : (i += 1) {
                used += heights[i];
                if (i == cur) fits = used <= avail;
            }
            if (fits or h.dash_scroll >= cur) break;
            h.dash_scroll += 1;
        }
    }
    var i = h.dash_scroll;
    while (i < h.cards_n) : (i += 1) {
        const c = &h.cards[i];
        const ch = heights[i];
        const limit = if (overflow) bottom - 1 else bottom;
        if (y + ch > limit) {
            f.cup(x, bottom - 1);
            ink(f, t, t.muted, t.chrome);
            var mb: [32]u8 = undefined;
            var left_over: usize = 0;
            for (h.cards[i..h.cards_n]) |k| {
                if (k.actionable()) left_over += 1;
            }
            _ = altpkg.putW(f, std.fmt.bufPrint(&mb, "{s} {d} more", .{ ui.glyph(t, .more), left_over }) catch "", w);
            break;
        }
        c.y = y;
        c.rows = ch;
        const sel = focused and i == h.dash_cur and c.actionable();
        if (c.header) {
            drawModuleHeader(f, st, c.*, x, y, w, p);
        } else if (c.task) |ti| {
            drawCard(f, st, h.tasks[ti], sel, x, y, w, p);
        } else if (c.space) |si| {
            drawSpaceRow(f, st, si, sel, x, y, w, p);
        } else {
            f.cup(x, y);
            ink(f, t, t.muted, t.chrome);
            _ = altpkg.putW(f, "nothing running, nothing needs you", w);
        }
        y += ch;
    }
}

fn cardHeight(h: *const State, c: Card, w: u16) u16 {
    if (c.header) return 2;
    if (c.task) |ti| {
        const tk = h.tasks[ti];
        return switch (c.module) {
            .recent => 1,
            else => blk: {
                var rows: u16 = 2;
                const ev = if (tk.event.len > 0) tk.event else tk.result;
                if (ev.len > 0) rows += @intCast(@min(2, (chromepkg.cols(ev) + (w -| 5)) / @max(1, w -| 4)));
                if (tk.kind == .approval) rows = 2;
                break :blk rows;
            },
        };
    }
    return 1;
}

fn drawModuleHeader(f: *renderpkg.Frame, st: *altpkg.State, c: Card, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    const h = &st.home;
    // the blank row before it is the header's own top row
    f.cup(x, y + 1);
    const c_ink: Rgb = if (c.module == .needs) t.attention else t.muted;
    style(f, .{ .fg = c_ink, .bg = t.chrome, .bold = c.module == .needs });
    var used = altpkg.putW(f, c.module.word(), w);
    var n: usize = 0;
    for (h.cards[0..h.cards_n]) |k| {
        if (k.module == c.module and k.actionable()) n += 1;
    }
    var nb: [16]u8 = undefined;
    ink(f, t, t.muted, t.chrome);
    f.put(" ");
    used += 1;
    _ = altpkg.putW(f, std.fmt.bufPrint(&nb, "{d}", .{n}) catch "", w -| used);
}

/// A card: the mark and the title, then the space and the actor, then
/// the latest event, wrapped. Attention wears an edge; the selected
/// card a band; recent is one flat line.
fn drawCard(f: *renderpkg.Frame, st: *altpkg.State, tk: Task, sel: bool, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    const mark = tk.mark();
    const needs = tk.module == .needs;
    const ground: Rgb = if (sel) t.selection else t.chrome;
    const rows = cardHeight(&st.home, .{ .module = tk.module, .task = 0 }, w);
    _ = rows;
    var ab: [16]u8 = undefined;
    const age = if (tk.age_ms > 0) altpkg.age(&ab, tk.age_ms) else "";

    if (tk.module == .recent) {
        f.cup(x, y);
        if (sel) {
            style(f, .{ .bg = ground });
            pad(f, w);
            f.cup(x, y);
        }
        ink(f, t, ui.markInk(t, mark), ground);
        f.put(ui.markGlyph(t, mark));
        f.put(" ");
        style(f, .{ .fg = t.secondary, .bg = ground, .bold = sel });
        const reserve: u16 = if (age.len > 0) 7 else 0;
        var used: u16 = 2 + altpkg.putW(f, tk.title, @min(w -| reserve -| 6, 40));
        if (tk.result.len > 0 and used + 4 < w -| reserve) {
            ink(f, t, t.muted, ground);
            f.put(" · ");
            used += 3;
            ink(f, t, t.secondary, ground);
            used += altpkg.putW(f, tk.result, w -| used -| reserve);
        }
        if (age.len > 0) {
            f.cup(x + w -| chromepkg.cols(age), y);
            ink(f, t, t.muted, ground);
            _ = altpkg.putW(f, age, 6);
        }
        return;
    }

    const height: u16 = cardHeight(&st.home, .{ .module = tk.module, .task = indexOf(st, tk) }, w);
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        f.cup(x, y + row);
        style(f, .{ .bg = ground });
        pad(f, w);
        if (needs) {
            f.cup(x, y + row);
            style(f, .{ .fg = t.attention, .bg = ground });
            f.put(ui.glyph(t, .edge));
        }
    }
    const bx = x + 2;
    const bw = w -| 3;
    // title
    f.cup(bx, y);
    if (sel) {
        f.cup(x, y);
        style(f, .{ .fg = t.accent, .bg = ground, .bold = true });
        f.put(if (needs) "" else ui.glyph(t, .marker));
        f.cup(bx, y);
    }
    ink(f, t, ui.markInk(t, mark), ground);
    f.put(ui.markGlyph(t, mark));
    f.put(" ");
    style(f, .{ .fg = t.primary, .bg = ground, .bold = sel or needs });
    _ = altpkg.putW(f, tk.title, bw -| 2 -| 7);
    if (age.len > 0) {
        f.cup(x + w -| chromepkg.cols(age), y);
        ink(f, t, t.muted, ground);
        _ = altpkg.putW(f, age, 6);
    }
    // meta: where, who, what state
    f.cup(bx + 2, y + 1);
    var used: u16 = 0;
    if (tk.kind == .approval) {
        ink(f, t, t.muted, ground);
        f.put("$ ");
        ink(f, t, t.secondary, ground);
        used += 2 + altpkg.putW(f, tk.event, bw -| 14);
        if (sel) {
            const hint: []const u8 = if (t.glyphs == .ascii) "enter runs" else "↵ runs";
            f.cup(x + w -| chromepkg.cols(hint), y + 1);
            ink(f, t, t.accent, ground);
            _ = altpkg.putW(f, hint, 10);
        }
        return;
    }
    if (tk.space.len > 0) {
        ink(f, t, t.secondary, ground);
        used += altpkg.putW(f, tk.space, 20);
    }
    if (tk.actor.len > 0) {
        ink(f, t, t.muted, ground);
        f.put(" · ");
        ink(f, t, t.secondary, ground);
        used += 3 + altpkg.putW(f, tk.actor, 16);
    }
    const word: []const u8 = switch (tk.kind) {
        .producer => tk.state.word(),
        .found => "producing",
        .signal => "unread",
        .approval => "",
    };
    if (word.len > 0) {
        ink(f, t, t.muted, ground);
        f.put(" · ");
        ink(f, t, ui.markInk(t, mark), ground);
        used += 3 + altpkg.putW(f, word, 12);
    }
    if (tk.kind == .producer and tk.win != null and tk.pane == 0 and used + 8 < bw) {
        // nothing more: the space is the destination
    }
    // the event, wrapped to two lines
    const ev = if (tk.event.len > 0) tk.event else tk.result;
    if (ev.len > 0) {
        var wrapped: [2][]const u8 = undefined;
        const k = wrap(ev, bw -| 2, &wrapped);
        var i: usize = 0;
        while (i < k and 2 + i < height) : (i += 1) {
            f.cup(bx + 2, y + 2 + @as(u16, @intCast(i)));
            ink(f, t, if (needs) t.primary else t.secondary, ground);
            _ = altpkg.putW(f, wrapped[i], bw -| 2);
        }
    }
    if (sel and tk.kind != .approval) {
        const hint: []const u8 = switch (tk.kind) {
            .signal => if (t.glyphs == .ascii) "enter: go see" else "↵ go see",
            else => if (t.glyphs == .ascii) "enter: open" else "↵ open",
        };
        f.cup(x + w -| chromepkg.cols(hint), y + 1);
        ink(f, t, t.accent, ground);
        _ = altpkg.putW(f, hint, 12);
    }
}

fn indexOf(st: *altpkg.State, tk: Task) usize {
    for (st.home.tasks[0..st.home.tasks_n], 0..) |o, i| {
        if (o.kind == tk.kind and std.mem.eql(u8, o.title, tk.title) and o.pane == tk.pane) return i;
    }
    return 0;
}

/// A space as one compact row: the name, its tabs with marks, how
/// long quiet — never the task's title again.
fn drawSpaceRow(f: *renderpkg.Frame, st: *altpkg.State, si: usize, sel: bool, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    const sp = st.spaces[si];
    const ground: Rgb = if (sel) t.selection else t.chrome;
    f.cup(x, y);
    style(f, .{ .bg = ground });
    pad(f, w);
    f.cup(x, y);
    if (sel) {
        style(f, .{ .fg = t.accent, .bg = ground, .bold = true });
        f.put(ui.glyph(t, .marker));
    } else {
        f.put(" ");
    }
    f.put(" ");
    style(f, .{ .fg = t.primary, .bg = ground, .bold = sel });
    var used: u16 = 2 + altpkg.putW(f, sp.name, 18);
    if (sp.unread > 0) {
        ink(f, t, t.attention, ground);
        f.put(" ");
        f.put(ui.markGlyph(t, .attention));
        used += 2;
    }
    ink(f, t, t.muted, ground);
    f.put("  ");
    used += 2;
    // the tabs, dense, with actors and marks
    var i: usize = 0;
    while (i < sp.tabs.len) : (i += 1) {
        const tb = sp.tabs[i];
        var lb: [64]u8 = undefined;
        const label = altpkg.tabLabel(&lb, tb.name, tb.actor);
        const mg = ui.markGlyph(t, altpkg.markOf(tb.mark));
        const need = chromepkg.cols(label) + (if (mg.len > 0) @as(u16, 2) else 0) + 3;
        if (used + need > w -| 6) {
            ink(f, t, t.muted, ground);
            _ = altpkg.putW(f, ui.glyph(t, .more), 2);
            break;
        }
        if (i > 0) {
            ink(f, t, t.muted, ground);
            f.put(" · ");
            used += 3;
        }
        ink(f, t, t.secondary, ground);
        used += altpkg.putW(f, label, 30);
        if (mg.len > 0) {
            ink(f, t, ui.markInk(t, altpkg.markOf(tb.mark)), ground);
            f.put(" ");
            f.put(mg);
            used += 2;
        }
    }
    // how long quiet, at the edge; the event line is the cards' job
    if (sp.quiet_ms > 0) {
        var ab: [16]u8 = undefined;
        const age = altpkg.age(&ab, sp.quiet_ms);
        f.cup(x + w -| chromepkg.cols(age), y);
        ink(f, t, t.muted, ground);
        _ = altpkg.putW(f, age, 6);
    }
    if (sel) {
        const hint: []const u8 = if (t.glyphs == .ascii) "enter" else "↵ enter";
        f.cup(x + w -| chromepkg.cols(hint) -| 5, y);
        ink(f, t, t.accent, ground);
        _ = altpkg.putW(f, hint, 8);
    }
}

test "the layout splits when both sides keep a useful width, else one view" {
    const wide = layout(.{ .x = 0, .y = 1, .w = 140, .h = 30 });
    try std.testing.expect(wide.wide);
    try std.testing.expectEqual(@as(u16, 86), wide.left.w);
    try std.testing.expectEqual(@as(u16, 87), wide.right.?.x);
    try std.testing.expectEqual(@as(u16, 53), wide.right.?.w);
    // the floor for the right side wins over the percentage
    const tight = layout(.{ .x = 0, .y = 1, .w = 90, .h = 30 });
    try std.testing.expect(tight.wide);
    try std.testing.expect(tight.right.?.w >= min_right);
    try std.testing.expect(tight.left.w >= min_left);
    const narrow = layout(.{ .x = 0, .y = 1, .w = 84, .h = 30 });
    try std.testing.expect(!narrow.wide);
    try std.testing.expect(narrow.right == null);
    // the dock's offset carries through
    const docked = layout(.{ .x = 48, .y = 1, .w = 100, .h = 30 });
    try std.testing.expectEqual(@as(u16, 48), docked.left.x);
    try std.testing.expectEqual(@as(u16, 48 + 63), docked.right.?.x);
}

test "wrap breaks on spaces and keeps paragraphs" {
    var out: [8][]const u8 = undefined;
    const n = wrap("the quick brown fox jumps over the lazy dog", 12, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("the quick", out[0]);
    try std.testing.expectEqualStrings("brown fox", out[1]);
    const m = wrap("one\ntwo", 40, &out);
    try std.testing.expectEqual(@as(usize, 2), m);
    try std.testing.expectEqualStrings("two", out[1]);
    // a word longer than the width is cut, not lost
    const k = wrap("abcdefghijklmnop", 5, &out);
    try std.testing.expect(k >= 3);
    try std.testing.expectEqualStrings("abcde", out[0]);
}

test "the thread is a ring, and finds the latest turn about a task" {
    var th: Thread = .{};
    _ = th.push(.you, "deploy the api", "", "", 1);
    _ = th.push(.plan, "deploy from main", "t4", "api", 2);
    _ = th.push(.note, "t4 began", "t4", "", 3);
    try std.testing.expectEqual(@as(usize, 3), th.count());
    try std.testing.expectEqual(@as(usize, 2), th.about("t4").?);
    try std.testing.expect(th.about("t9") == null);
    try std.testing.expect(th.about("") == null);
    var i: usize = 0;
    while (i < max_turns) : (i += 1) _ = th.push(.you, "x", "", "", 10);
    try std.testing.expectEqual(@as(usize, max_turns), th.count());
    try std.testing.expectEqualStrings("x", th.get(0).textSlice());
}

test "the dashboard cursor walks cards and skips headers" {
    var h: State = .{};
    h.addCard(.{ .module = .needs, .header = true });
    _ = h.addTask(.{ .kind = .signal, .module = .needs, .title = "bell" });
    h.addCard(.{ .module = .needs, .task = 0 });
    h.addCard(.{ .module = .spaces, .header = true });
    h.addCard(.{ .module = .spaces, .space = 0 });
    h.dash_cur = 0;
    h.clampDash();
    try std.testing.expectEqual(@as(usize, 1), h.dash_cur);
    h.moveDash(1);
    try std.testing.expectEqual(@as(usize, 3), h.dash_cur);
    h.moveDash(1);
    try std.testing.expectEqual(@as(usize, 3), h.dash_cur);
    h.moveDash(-1);
    try std.testing.expectEqual(@as(usize, 1), h.dash_cur);
    try std.testing.expect(h.landDash(.spaces));
    try std.testing.expectEqual(@as(usize, 3), h.dash_cur);
    try std.testing.expectEqual(@as(usize, 1), h.needsCount());
    // a task's state is remembered, and a change is reported once
    try std.testing.expectEqual(chromepkg.State.none, h.remember("t1", .working).?);
    try std.testing.expect(h.remember("t1", .working) == null);
    try std.testing.expectEqual(chromepkg.State.working, h.remember("t1", .done).?);
    // the selection is an identity: a card inserted above it does
    // not move it
    h.restoreSelection();
    h.moveDash(0);
    try std.testing.expect(h.dash_touched);
    h.cards_n = 0;
    h.addCard(.{ .module = .needs, .header = true });
    _ = h.addTask(.{ .kind = .approval, .module = .needs, .title = "run it" });
    h.addCard(.{ .module = .needs, .task = 1 });
    h.addCard(.{ .module = .needs, .task = 0 });
    h.restoreSelection();
    try std.testing.expectEqual(@as(usize, 2), h.dash_cur);
}

test "ctrl-h/j/k/l walk the regions, and stop at the edges" {
    var h: State = .{};
    _ = h.thread.push(.you, "deploy the api", "", "", 1);
    _ = h.thread.push(.vera, "from main?", "", "", 2);

    // the composer: nothing left of it, nothing below it
    try std.testing.expect(!h.navFocus('h'));
    try std.testing.expect(!h.navFocus('j'));
    try std.testing.expectEqual(Region.composer, h.focus);

    // up into the thread, on its latest turn; down again, and the
    // selection lets go
    try std.testing.expect(h.navFocus('k'));
    try std.testing.expectEqual(Region.thread, h.focus);
    try std.testing.expectEqual(@as(usize, 1), h.thread_cur.?);
    try std.testing.expect(!h.navFocus('k'));
    try std.testing.expect(h.navFocus('j'));
    try std.testing.expectEqual(Region.composer, h.focus);
    try std.testing.expect(h.thread_cur == null);

    // right to the dashboard from the composer, and back to it
    try std.testing.expect(h.navFocus('l'));
    try std.testing.expectEqual(Region.dash, h.focus);
    try std.testing.expect(!h.navFocus('l'));
    try std.testing.expect(!h.navFocus('k'));
    try std.testing.expect(!h.navFocus('j'));
    try std.testing.expect(h.navFocus('h'));
    try std.testing.expectEqual(Region.composer, h.focus);

    // the motion back lands where the hand left: from the thread,
    // the thread — with its turn still selected
    _ = h.navFocus('k');
    h.moveThread(-1);
    try std.testing.expectEqual(@as(usize, 0), h.thread_cur.?);
    try std.testing.expect(h.navFocus('l'));
    try std.testing.expectEqual(Region.dash, h.focus);
    try std.testing.expect(h.navFocus('h'));
    try std.testing.expectEqual(Region.thread, h.focus);
    try std.testing.expectEqual(@as(usize, 0), h.thread_cur.?);

    // an empty thread is not a region: k stays put, and the motion
    // back out of the dashboard finds the composer
    var e: State = .{};
    try std.testing.expect(!e.navFocus('k'));
    try std.testing.expectEqual(Region.composer, e.focus);
    e.focus = .thread; // as ⇥ would have left it, had there been turns
    try std.testing.expect(e.navFocus('l'));
    try std.testing.expect(e.navFocus('h'));
    try std.testing.expectEqual(Region.composer, e.focus);
    try std.testing.expect(!e.navFocus('x'));
}
