//! Home: the work navigator and the inspector, with vera one key
//! away.
//!
//! The left third is the navigator: a stable index of what needs
//! you, what is in progress, what finished, and the spaces — one row
//! each, only what selection needs. The rest is the inspector: what
//! the selected thing is, in the detail the data affords — goal,
//! state and current step, who and where, the plan, the timeline,
//! files, commits, tests, artifacts, usage, a question and its
//! options, the last lines its pane wrote — and the controls the
//! producer supports, run on ↵, never implied. Opening the workspace
//! is one of those controls, not the only way to learn anything.
//!
//! Vera is a global pane rook owns: `prefix-t` summons her over the
//! inspector (or beside it, pinned, when the glass affords three
//! columns), from home or from any space; the same key dismisses
//! her; the thread, the scroll and the draft survive. Printable
//! typing from the navigator summons her with the letter in the
//! composer. "Ask vera about this" opens her with the selected task
//! attached as a reference (`ROOK_ABOUT_TASK`), not as words.
//!
//! The projection is task-centric. A task is a producer's row (the
//! rail's `agents` surface); its agent, pane and space are on it,
//! never rows beside it. An agent rook can see producing where no
//! producer claims is one quiet row; an idle agent is not work. A
//! pane that signalled while nobody looked is a row under needs you.
//! A proposed action from vera's reflection is an approval row, and
//! a control on the task it names.
//!
//! Layout is one boundary (`layout`): navigator and inspector when
//! both keep a useful width, a list-to-detail stack when they do
//! not; vera as a third column only when all three fit. Focus is
//! one of three regions — navigator, inspector, vera — walked with
//! h/l and Ctrl-h/l; j/k walk within.
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

/// The navigator's share of the region, in percent, and the
/// narrowest each region may be and still read. Vera, pinned, takes
/// a third column only when all three fit; otherwise she overlays
/// the inspector.
pub const nav_pct: u16 = 34;
pub const vera_pct: u16 = 36;
pub const min_nav: u16 = 30;
pub const min_insp: u16 = 50;
pub const min_vera: u16 = 40;

pub const Layout = struct {
    nav: Rect,
    /// the inspector; null when the glass shows one view at a time
    insp: ?Rect,
    /// vera's column, pinned and afforded; else she overlays
    vera: ?Rect,
    wide: bool,
};

pub fn layout(region: Rect, vera_pinned: bool) Layout {
    if (region.w >= min_nav + min_insp + 1) {
        var rest = region.w;
        var vera: ?Rect = null;
        if (vera_pinned and region.w >= min_nav + min_insp + min_vera + 2) {
            var vw: u16 = @intCast(@as(u32, region.w) * vera_pct / 100);
            if (vw < min_vera) vw = min_vera;
            if (region.w - vw - 1 < min_nav + min_insp + 1) vw = region.w - (min_nav + min_insp + 1) - 1;
            vera = .{ .x = region.x + region.w - vw, .y = region.y, .w = vw, .h = region.h };
            rest = region.w - vw - 1;
        }
        var nw: u16 = @intCast(@as(u32, rest) * nav_pct / 100);
        if (nw < min_nav) nw = min_nav;
        if (rest - nw - 1 < min_insp) nw = rest - min_insp - 1;
        return .{
            .nav = .{ .x = region.x, .y = region.y, .w = nw, .h = region.h },
            .insp = .{ .x = region.x + nw + 1, .y = region.y, .w = rest - nw - 1, .h = region.h },
            .vera = vera,
            .wide = true,
        };
    }
    return .{ .nav = region, .insp = null, .vera = null, .wide = false };
}

/// Where the unpinned vera pane sits: over the inspector's side,
/// wide enough to read, never over the navigator.
pub fn veraOverlay(region: Rect) Rect {
    var vw: u16 = @intCast(@as(u32, region.w) * 45 / 100);
    if (vw < min_vera) vw = @min(min_vera, region.w);
    if (vw > 72) vw = 72;
    return .{ .x = region.x + region.w - vw, .y = region.y, .w = vw, .h = region.h };
}

// ---- the hosted chat ----
//
// The companion's own terminal is mote's screen, and rook hosts it
// rather than imitating it: a real pty in a pane, streaming markdown,
// tool cards, a multiline box with its own history — none of which a
// 400-byte turn ring and a one-line composer could ever be. Rook keeps
// what is rook's: where the panel is, how wide, who has the keyboard,
// and the four keys that walk out of it.

/// The rows rook keeps for itself above a hosted chat: its header,
/// and the `about` line when something is attached.
pub fn veraChrome(about: bool) u16 {
    return if (about) 2 else 1;
}

/// Where a hosted chat's terminal lives inside vera's panel. One
/// boundary, like `layout`: the painter draws the pane exactly here
/// and the server sizes the pty to exactly this, so the program is
/// never told a width it was not given — the resize a hosted TUI
/// cannot recover from is the one where the two disagree.
pub fn veraBody(r: Rect, about: bool) Rect {
    const top = veraChrome(about);
    return .{ .x = r.x + 1, .y = r.y + top, .w = r.w -| 2, .h = r.h -| top };
}

/// Below this a terminal cannot hold a conversation. The panel says
/// so in its own words rather than handing mote a window it would
/// have to truncate everything into.
pub const min_chat_cols: u16 = 24;
pub const min_chat_rows: u16 = 6;

pub fn chatFits(body: Rect) bool {
    return body.w >= min_chat_cols and body.h >= min_chat_rows;
}

/// Vera's panel: the rect she is painted into, and whether she is
/// over something (her own ground) or a column of her own. Null when
/// she is not on the glass. The one answer to "where is she", so the
/// painter and the server's pty never disagree about it.
pub const Panel = struct { r: Rect, over: bool };

/// At home: a third column when pinned and afforded, an overlay over
/// the inspector's side when not, and the whole region on a glass too
/// narrow to split — where she is only drawn when she has the focus.
pub fn veraPanel(region: Rect, pinned: bool, shown: bool, focus_vera: bool) ?Panel {
    if (!shown) return null;
    const lay = layout(region, pinned);
    if (!lay.wide) return if (focus_vera) .{ .r = region, .over = false } else null;
    if (lay.vera) |vr| return .{ .r = vr, .over = false };
    const vr = veraOverlay(.{ .x = lay.insp.?.x, .y = region.y, .w = region.w - lay.nav.w - 1, .h = region.h });
    return .{ .r = .{ .x = vr.x + 1, .y = vr.y, .w = vr.w -| 1, .h = vr.h }, .over = true };
}

/// Inside a space: the same pane, over the panes, on the right.
pub fn veraPanelOver(region: Rect) Panel {
    const vr = veraOverlay(region);
    return .{ .r = .{ .x = vr.x + 1, .y = vr.y, .w = vr.w -| 1, .h = vr.h }, .over = true };
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

    /// How many turns are about `task`.
    pub fn countAbout(self: *Thread, task: []const u8) usize {
        if (task.len == 0) return 0;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (std.mem.eql(u8, self.get(i).taskSlice(), task)) n += 1;
        }
        return n;
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
    /// the producer's row, for the inspector's detail; valid for
    /// the frame it was built in
    item: ?*const chromepkg.Item = null,
    /// the program in its pane, for a found agent or a signal
    program: []const u8 = "",
    /// the tab it is in
    tab: []const u8 = "",

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

    pub fn stateWord(self: Task) []const u8 {
        return switch (self.kind) {
            .producer => self.state.word(),
            .found => "producing",
            .signal => "unread",
            .approval => "waiting for you",
        };
    }
};

pub const max_tasks = 48;
pub const max_rows = 72;

/// One row of the navigator: a group header, a task, a space, or
/// the quiet line an empty navigator shows once.
pub const Row = struct {
    module: Module,
    header: bool = false,
    task: ?usize = null,
    space: ?usize = null,
    y: u16 = 0,

    pub fn actionable(self: Row) bool {
        return self.task != null or self.space != null;
    }
};

pub const Region = enum { nav, insp, vera };

/// A task's state as last seen, so a change earns a note.
const Seen = struct { id: [32]u8 = undefined, len: usize = 0, state: chromepkg.State = .none };

// ---- the inspector ----

pub const LineKind = enum { title, meta, section, text, step_done, step_todo, event, kv, action, blank, output, quiet };

/// One line of the inspector, as built. Strings borrow the build's
/// arena.
pub const ILine = struct {
    kind: LineKind,
    text: []const u8 = "",
    /// a key-value's key; an event's age; an action's command
    extra: []const u8 = "",
    action: ?usize = null,
    mark: ui.Mark = .none,
};

pub const ActKind = enum { control, answer, approval, open, go_see, ask, enter };

/// A control on the selected thing: what ↵ does. `run` is the
/// producer's command for a control or an answer; the rest are
/// rook's own moves.
pub const Act = struct {
    label: []const u8,
    kind: ActKind,
    run: []const u8 = "",
    /// an approval: the reflection's action index
    action: usize = 0,
    ctrl: @TypeOf(@as(chromepkg.Control, undefined).kind) = .other,
};

pub const max_ilines = 240;
pub const max_acts = 16;

pub const Insp = struct {
    lines: [max_ilines]ILine = undefined,
    n: usize = 0,
    acts: [max_acts]Act = undefined,
    acts_n: usize = 0,
    /// the selected control, an index into `acts`
    cur: usize = 0,
    /// rows scrolled from the top
    scroll: usize = 0,
    /// a hand has walked the controls: keep the selected one in view
    touched: bool = false,
    /// the key of what was inspected last, so a change of subject
    /// resets the scroll and the cursor
    key: [72]u8 = undefined,
    key_len: usize = 0,

    pub fn reset(self: *Insp) void {
        self.n = 0;
        self.acts_n = 0;
    }

    pub fn line(self: *Insp, l: ILine) void {
        if (self.n == max_ilines) return;
        self.lines[self.n] = l;
        self.n += 1;
    }

    pub fn act(self: *Insp, a: Act) void {
        if (self.acts_n == max_acts) return;
        self.acts[self.acts_n] = a;
        self.acts_n += 1;
        self.line(.{ .kind = .action, .text = a.label, .extra = a.run, .action = self.acts_n - 1 });
    }

    pub fn selected(self: *const Insp) ?Act {
        if (self.acts_n == 0) return null;
        return self.acts[@min(self.cur, self.acts_n - 1)];
    }

    pub fn moveAct(self: *Insp, d: i32) void {
        if (self.acts_n == 0) return;
        self.touched = true;
        var i: i64 = @intCast(@min(self.cur, self.acts_n - 1));
        i += d;
        if (i < 0) i = 0;
        if (i >= @as(i64, @intCast(self.acts_n))) i = @intCast(self.acts_n - 1);
        self.cur = @intCast(i);
    }

    /// A new subject: the cursor on its primary control, the scroll
    /// at the top. The same subject keeps both.
    pub fn subject(self: *Insp, key: []const u8) void {
        if (std.mem.eql(u8, key, self.key[0..self.key_len])) return;
        self.key_len = take(&self.key, key);
        self.cur = 0;
        self.scroll = 0;
        self.touched = false;
    }
};

/// What an item's action runs, and what it printed: one at a time,
/// pumped in the server's loop, its receipt a turn in the thread.
pub const Runner = struct {
    job: ?askpkg.Job = null,
    label: [96]u8 = undefined,
    label_len: usize = 0,
    task: [32]u8 = undefined,
    task_len: usize = 0,

    pub fn start(self: *Runner, label: []const u8, run: []const u8, task: []const u8) bool {
        if (self.job != null) return false;
        self.job = askpkg.Job.spawnLine(run) catch return false;
        self.label_len = take(&self.label, label);
        self.task_len = take(&self.task, task);
        return true;
    }

    pub fn busy(self: *const Runner) bool {
        return self.job != null;
    }

    pub fn fds(self: *const Runner, out: []@import("pty.zig").Pollfd) usize {
        if (self.job) |*j| return j.fds(out);
        return 0;
    }

    /// True the turn it finished; the job stays for its receipt
    /// until `take`.
    pub fn pump(self: *Runner) bool {
        const j = &(self.job orelse return false);
        return j.pump();
    }

    pub fn labelSlice(self: *const Runner) []const u8 {
        return self.label[0..self.label_len];
    }
    pub fn taskSlice(self: *const Runner) []const u8 {
        return self.task[0..self.task_len];
    }
};

/// The home's own state: what outlives a frame, and a visit to a
/// space.
pub const State = struct {
    thread: Thread = .{},
    focus: Region = .nav,
    /// where the glass was last painted: navigator and inspector, or
    /// one at a time
    wide: bool = true,
    /// the narrow stack: the detail is up rather than the list
    detail: bool = false,
    /// vera's pane: summoned, and kept; and where focus was before
    /// she took it, for when she goes
    vera_open: bool = false,
    vera_pinned: bool = false,
    focus_before: Region = .nav,
    /// what the next request is about — the task's rail id and the
    /// space — attached by "ask vera about this"
    about_task: [32]u8 = undefined,
    about_task_len: usize = 0,
    about_space: [32]u8 = undefined,
    about_space_len: usize = 0,
    about_title: [64]u8 = undefined,
    about_title_len: usize = 0,
    tasks: [max_tasks]Task = undefined,
    tasks_n: usize = 0,
    rows: [max_rows]Row = undefined,
    rows_n: usize = 0,
    /// the selected row, an index into `rows` — and its identity, so
    /// a rebuild that inserts rows above it does not move it. Until
    /// a hand moves the cursor it rests on the first row.
    nav_cur: usize = 0,
    nav_key: [72]u8 = undefined,
    nav_key_len: usize = 0,
    nav_touched: bool = false,
    /// the first row painted, for a navigator taller than the glass
    nav_scroll: usize = 0,
    insp: Insp = .{},
    /// rows the thread is scrolled up from its foot
    thread_scroll: usize = 0,
    seen: [max_tasks]Seen = undefined,
    seen_n: usize = 0,
    /// the first seconds seed what is known without a word; after
    /// them, a task appearing is news
    seeded: bool = false,
    /// the request the latest plan turn belongs to
    req_serial: u64 = 0,
    runner: Runner = .{},

    pub fn reset(self: *State) void {
        self.tasks_n = 0;
        self.rows_n = 0;
    }

    pub fn addTask(self: *State, t: Task) ?usize {
        if (self.tasks_n == max_tasks) return null;
        self.tasks[self.tasks_n] = t;
        self.tasks_n += 1;
        return self.tasks_n - 1;
    }

    pub fn addRow(self: *State, r: Row) void {
        if (self.rows_n == max_rows) return;
        self.rows[self.rows_n] = r;
        self.rows_n += 1;
    }

    pub fn aboutTask(self: *const State) []const u8 {
        return self.about_task[0..self.about_task_len];
    }
    pub fn aboutSpace(self: *const State) []const u8 {
        return self.about_space[0..self.about_space_len];
    }
    pub fn aboutTitle(self: *const State) []const u8 {
        return self.about_title[0..self.about_title_len];
    }
    pub fn setAbout(self: *State, task: []const u8, space: []const u8, title: []const u8) void {
        self.about_task_len = take(&self.about_task, task);
        self.about_space_len = take(&self.about_space, space);
        self.about_title_len = take(&self.about_title, title);
    }
    pub fn clearAbout(self: *State) void {
        self.about_task_len = 0;
        self.about_space_len = 0;
        self.about_title_len = 0;
    }

    /// The selected row's identity: the task's id, else its kind and
    /// pane, else the space.
    pub fn rowKey(self: *const State, r: Row, buf: []u8) []const u8 {
        if (r.task) |ti| {
            const tk = self.tasks[ti];
            if (tk.kind == .approval) return std.fmt.bufPrint(buf, "a:{d}:{s}", .{ tk.action, tk.title }) catch "";
            if (tk.id.len > 0) return std.fmt.bufPrint(buf, "t:{s}", .{tk.id}) catch "";
            return std.fmt.bufPrint(buf, "{s}:{d}:{s}", .{ @tagName(tk.kind), tk.pane, tk.title }) catch "";
        }
        if (r.space) |si| return std.fmt.bufPrint(buf, "s:{d}", .{si}) catch "";
        return "";
    }

    /// Remember what is selected, by identity.
    pub fn noteSelection(self: *State) void {
        if (self.rows_n == 0) return;
        const r = self.rows[@min(self.nav_cur, self.rows_n - 1)];
        var b: [72]u8 = undefined;
        const k = self.rowKey(r, &b);
        self.nav_key_len = take(&self.nav_key, k);
    }

    /// After a rebuild: the same row by identity when it is still
    /// there, the first row until a hand has chosen, else the clamp.
    /// A task that moved between groups keeps its selection: the
    /// identity is the task, not the row.
    pub fn restoreSelection(self: *State) void {
        if (!self.nav_touched) {
            self.nav_cur = 0;
            self.clampNav();
            self.noteSelection();
            return;
        }
        if (self.nav_key_len > 0) {
            for (self.rows[0..self.rows_n], 0..) |r, i| {
                var b: [72]u8 = undefined;
                if (std.mem.eql(u8, self.rowKey(r, &b), self.nav_key[0..self.nav_key_len])) {
                    self.nav_cur = i;
                    return;
                }
            }
        }
        self.clampNav();
        self.noteSelection();
    }

    /// The selected row, when the cursor is on one.
    pub fn selectedRow(self: *const State) ?Row {
        if (self.rows_n == 0) return null;
        const r = self.rows[@min(self.nav_cur, self.rows_n - 1)];
        return if (r.actionable()) r else null;
    }

    pub fn selectedTask(self: *const State) ?Task {
        const r = self.selectedRow() orelse return null;
        const ti = r.task orelse return null;
        return self.tasks[ti];
    }

    /// Move the navigator cursor over the actionable rows.
    pub fn moveNav(self: *State, d: i32) void {
        const n = self.rows_n;
        if (n == 0) return;
        self.nav_touched = true;
        var i: i64 = @intCast(@min(self.nav_cur, n - 1));
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            i += d;
            if (i < 0 or i >= @as(i64, @intCast(n))) break;
            if (self.rows[@intCast(i)].actionable()) {
                self.nav_cur = @intCast(i);
                break;
            }
        }
        self.noteSelection();
    }

    pub fn clampNav(self: *State) void {
        const n = self.rows_n;
        if (n == 0) {
            self.nav_cur = 0;
            return;
        }
        if (self.nav_cur >= n) self.nav_cur = n - 1;
        if (!self.rows[self.nav_cur].actionable()) {
            var i = self.nav_cur;
            while (i < n and !self.rows[i].actionable()) i += 1;
            if (i < n) {
                self.nav_cur = i;
                return;
            }
            i = self.nav_cur;
            while (i > 0 and !self.rows[i].actionable()) i -= 1;
            self.nav_cur = i;
        }
    }

    /// Put the navigator cursor on the first row of a group.
    pub fn landNav(self: *State, m: Module) bool {
        for (self.rows[0..self.rows_n], 0..) |r, i| {
            if (r.module == m and r.actionable()) {
                self.nav_cur = i;
                self.nav_touched = true;
                self.noteSelection();
                return true;
            }
        }
        return false;
    }

    /// The row for a task id, if one is in the navigator.
    pub fn rowFor(self: *const State, task: []const u8) ?usize {
        if (task.len == 0) return null;
        for (self.rows[0..self.rows_n], 0..) |r, i| {
            if (r.task) |ti| {
                if (std.mem.eql(u8, self.tasks[ti].id, task)) return i;
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

    /// What needs you: the count on the badges.
    pub fn needsCount(self: *const State) usize {
        var n: usize = 0;
        for (self.tasks[0..self.tasks_n]) |t| {
            if (t.module == .needs) n += 1;
        }
        return n;
    }

    /// Is vera's pane on the glass?
    pub fn veraShown(self: *const State) bool {
        return self.vera_open or self.vera_pinned;
    }

    /// The regions are laid out — the navigator left, the inspector
    /// right of it, vera right of that when she is up — so they take
    /// the same four keys the panes inside a space take: Ctrl-h/l
    /// (and h/l in the navigator and the inspector) walk them. On the
    /// narrow stack, `l` from the list is the detail and `h` from the
    /// detail is the list. Returns true when focus moved; at an edge
    /// nothing happens and the key is the view's again.
    pub fn navFocus(self: *State, dir: u8) bool {
        switch (dir) {
            'l' => switch (self.focus) {
                .nav => {
                    self.focus = .insp;
                    self.detail = true;
                    // a fresh look: the top of the subject, its first
                    // control
                    self.insp.scroll = 0;
                    self.insp.cur = 0;
                    self.insp.touched = false;
                    return true;
                },
                .insp => {
                    if (!self.veraShown()) return false;
                    self.focus = .vera;
                    return true;
                },
                .vera => return false,
            },
            'h' => switch (self.focus) {
                .vera => {
                    self.focus = .insp;
                    return true;
                },
                .insp => {
                    self.focus = .nav;
                    self.detail = false;
                    return true;
                },
                .nav => return false,
            },
            else => return false,
        }
    }

    /// Summon vera, or dismiss her. Opening takes focus to her
    /// composer; closing gives it back to the navigator. A pinned
    /// pane stays: the toggle only moves focus.
    pub fn toggleVera(self: *State) void {
        if (self.vera_pinned) {
            if (self.focus == .vera) {
                self.focus = self.focus_before;
            } else {
                self.focus_before = self.focus;
                self.focus = .vera;
            }
            return;
        }
        if (self.vera_open) {
            self.vera_open = false;
            if (self.focus == .vera) self.focus = self.focus_before;
        } else {
            self.vera_open = true;
            self.focus_before = self.focus;
            self.focus = .vera;
        }
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

fn ink(f: *renderpkg.Frame, c: Rgb, ground: Rgb) void {
    style(f, .{ .fg = c, .bg = ground });
}

fn pad(f: *renderpkg.Frame, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) f.put(" ");
}

fn fill(f: *renderpkg.Frame, r: Rect, ground: Rgb) void {
    var y: u16 = r.y;
    while (y < r.y + r.h) : (y += 1) {
        f.cup(r.x, y);
        style(f, .{ .bg = ground });
        pad(f, r.w);
    }
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
    /// the prefix key, as a person types it, for the hints
    prefix: []const u8 = "prefix ",
    /// The companion's own terminal, when rook is hosting one: her
    /// screen is mote's and rook draws only the chrome around it.
    /// Null means the panel keeps rook's own surface — no chat
    /// command configured, nothing on PATH, or the program quit.
    chat: ?*panepkg.Pane = null,
};

/// The companion's status word for the header and the bar.
pub fn askStatus(st: *const altpkg.State, p: Paint) struct { word: []const u8, mark: ui.Mark } {
    if (!p.ask_on and st.req.state != .running) return .{ .word = "offline", .mark = .failed };
    return switch (st.req.state) {
        .running => .{ .word = "thinking", .mark = .working },
        .replied => if (st.req.ref) |*r| (if (r.pending() > 0) .{ .word = "waiting for you", .mark = .attention } else if (r.question_len > 0) .{ .word = "asked you something", .mark = .attention } else .{ .word = "ready", .mark = .none }) else .{ .word = "ready", .mark = .none },
        .failed => .{ .word = "could not answer", .mark = .failed },
        .offline => .{ .word = "offline", .mark = .failed },
        .none => .{ .word = "ready", .mark = .none },
    };
}

/// Paint home into `region`. Returns where the cursor is.
pub fn draw(f: *renderpkg.Frame, st: *altpkg.State, region: Rect, p: Paint) renderpkg.CursorOverride {
    const t = p.t;
    const h = &st.home;
    const lay = layout(region, h.vera_pinned);
    h.wide = lay.wide;
    var cursor: renderpkg.CursorOverride = .{ .x = region.x, .y = region.y, .hidden = true };

    const panel = veraPanel(region, h.vera_pinned, h.veraShown(), h.focus == .vera);
    if (lay.wide) {
        drawNav(f, st, lay.nav, p, false);
        divider(f, t, lay.nav.x + lay.nav.w, region.y, region.h);
        drawInsp(f, st, lay.insp.?, p, false);
        if (panel) |pl| {
            if (pl.over) {
                fill(f, .{ .x = pl.r.x - 1, .y = pl.r.y, .w = pl.r.w + 1, .h = pl.r.h }, t.raised);
                divider(f, t, pl.r.x - 1, region.y, region.h);
            } else {
                divider(f, t, pl.r.x - 1, region.y, region.h);
            }
            cursor = drawVera(f, st, pl.r, p, pl.over);
        }
    } else {
        if (panel) |pl| {
            cursor = drawVera(f, st, pl.r, p, pl.over);
        } else if (h.detail) {
            drawInsp(f, st, region, p, true);
        } else {
            drawNav(f, st, region, p, true);
        }
    }
    f.put(csi ++ "0m");
    return cursor;
}

/// Vera's pane inside a space: the same pane, over the panes, on
/// the right. Returns where the cursor is.
pub fn drawVeraOver(f: *renderpkg.Frame, st: *altpkg.State, region: Rect, p: Paint) renderpkg.CursorOverride {
    const t = p.t;
    const pl = veraPanelOver(region);
    fill(f, .{ .x = pl.r.x - 1, .y = pl.r.y, .w = pl.r.w + 1, .h = pl.r.h }, t.raised);
    divider(f, t, pl.r.x - 1, region.y, region.h);
    const c = drawVera(f, st, pl.r, p, pl.over);
    f.put(csi ++ "0m");
    return c;
}

fn divider(f: *renderpkg.Frame, t: *const ui.Theme, x: u16, y0: u16, h: u16) void {
    var y: u16 = y0;
    while (y < y0 + h) : (y += 1) {
        f.cup(x, y);
        ink(f, t.border_subtle, t.chrome);
        f.put(ui.glyph(t, .separator));
    }
}

// ---- the navigator ----

fn drawNav(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, narrow: bool) void {
    const t = p.t;
    const h = &st.home;
    const x = r.x + 1;
    const w = r.w -| 2;
    const focused = h.focus == .nav;
    var y = r.y;
    const bottom = r.y + r.h;
    _ = narrow;

    // rows per row, then paint from the scroll, keeping the selected
    // row in view
    var heights: [max_rows]u16 = undefined;
    var total: u16 = 0;
    for (h.rows[0..h.rows_n], 0..) |row, i| {
        heights[i] = if (row.header) (if (i == 0) @as(u16, 1) else 2) else 1;
        total += heights[i];
    }
    const overflow = total > bottom -| y;
    const avail: u16 = bottom -| y -| @as(u16, if (overflow) 1 else 0);
    if (h.nav_scroll >= h.rows_n) h.nav_scroll = 0;
    if (h.rows_n > 0) {
        const cur = @min(h.nav_cur, h.rows_n - 1);
        if (cur < h.nav_scroll) h.nav_scroll = cur;
        while (true) {
            var used: u16 = 0;
            var i = h.nav_scroll;
            var fits = false;
            while (i <= cur) : (i += 1) {
                used += heights[i];
                if (i == cur) fits = used <= avail;
            }
            if (fits or h.nav_scroll >= cur) break;
            h.nav_scroll += 1;
        }
    }
    var i = h.nav_scroll;
    while (i < h.rows_n) : (i += 1) {
        const row = &h.rows[i];
        const rh = heights[i];
        const limit = if (overflow) bottom - 1 else bottom;
        if (y + rh > limit) {
            f.cup(x, bottom - 1);
            ink(f, t.muted, t.chrome);
            var mb: [32]u8 = undefined;
            var left_over: usize = 0;
            for (h.rows[i..h.rows_n]) |k| {
                if (k.actionable()) left_over += 1;
            }
            _ = altpkg.putW(f, std.fmt.bufPrint(&mb, "{s} {d} more", .{ ui.glyph(t, .more), left_over }) catch "", w);
            break;
        }
        row.y = y + rh - 1;
        const sel = i == h.nav_cur and row.actionable();
        if (row.header) {
            drawGroupHeader(f, st, row.*, x, y + rh - 1, w, p);
        } else if (row.task) |ti| {
            drawTaskRow(f, st, h.tasks[ti], sel, focused, x, y, w, p);
        } else if (row.space) |si| {
            drawSpaceRow(f, st, si, sel, focused, x, y, w, p);
        } else {
            f.cup(x, y);
            ink(f, t.muted, t.chrome);
            _ = altpkg.putW(f, "all quiet · nothing needs you", w);
        }
        y += rh;
    }
}

fn drawGroupHeader(f: *renderpkg.Frame, st: *altpkg.State, row: Row, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    const h = &st.home;
    f.cup(x, y);
    const c_ink: Rgb = if (row.module == .needs) t.attention else t.muted;
    style(f, .{ .fg = c_ink, .bg = t.chrome, .bold = row.module == .needs });
    var used = altpkg.putW(f, row.module.word(), w);
    var n: usize = 0;
    for (h.rows[0..h.rows_n]) |k| {
        if (k.module == row.module and k.actionable()) n += 1;
    }
    var nb: [16]u8 = undefined;
    ink(f, t.muted, t.chrome);
    f.put(" ");
    used += 1;
    _ = altpkg.putW(f, std.fmt.bufPrint(&nb, "{d}", .{n}) catch "", w -| used);
}

/// A task as one row: the mark, the title, and at the edge the space
/// (or the age when it has one). The selected row wears the band and
/// the marker; the marker is the accent while the navigator has
/// focus, muted while it does not.
fn drawTaskRow(f: *renderpkg.Frame, st: *altpkg.State, tk: Task, sel: bool, focused: bool, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    _ = st;
    const mark = tk.mark();
    const ground: Rgb = if (sel) t.selection else t.chrome;
    f.cup(x, y);
    style(f, .{ .bg = ground });
    pad(f, w);
    f.cup(x, y);
    if (sel) {
        style(f, .{ .fg = if (focused) t.accent else t.muted, .bg = ground, .bold = true });
        f.put(ui.glyph(t, .marker));
    } else if (tk.module == .needs) {
        style(f, .{ .fg = t.attention, .bg = ground });
        f.put(ui.glyph(t, .edge));
    } else {
        f.put(" ");
    }
    f.put(" ");
    ink(f, ui.markInk(t, mark), ground);
    f.put(ui.markGlyph(t, mark));
    f.put(" ");
    var ab: [16]u8 = undefined;
    const edge: []const u8 = if (tk.kind == .approval) "" else if (tk.age_ms > 0) altpkg.age(&ab, tk.age_ms) else tk.space;
    const ew = chromepkg.cols(edge);
    style(f, .{ .fg = t.primary, .bg = ground, .bold = sel or tk.module == .needs });
    _ = altpkg.putW(f, tk.title, w -| 4 -| ew -| 2);
    if (ew > 0) {
        f.cup(x + w -| ew, y);
        ink(f, t.muted, ground);
        _ = altpkg.putW(f, edge, ew);
    }
}

/// A space as one row: the name, its marks, its age.
fn drawSpaceRow(f: *renderpkg.Frame, st: *altpkg.State, si: usize, sel: bool, focused: bool, x: u16, y: u16, w: u16, p: Paint) void {
    const t = p.t;
    const sp = st.spaces[si];
    const ground: Rgb = if (sel) t.selection else t.chrome;
    f.cup(x, y);
    style(f, .{ .bg = ground });
    pad(f, w);
    f.cup(x, y);
    if (sel) {
        style(f, .{ .fg = if (focused) t.accent else t.muted, .bg = ground, .bold = true });
        f.put(ui.glyph(t, .marker));
    } else {
        f.put(" ");
    }
    f.put(" ");
    style(f, .{ .fg = t.primary, .bg = ground, .bold = sel });
    var used: u16 = 2 + altpkg.putW(f, sp.name, 18);
    if (sp.unread > 0) {
        ink(f, t.attention, ground);
        f.put(" ");
        f.put(ui.markGlyph(t, .attention));
        used += 2;
    } else if (sp.working) {
        ink(f, t.working, ground);
        f.put(" ");
        f.put(ui.markGlyph(t, .working));
        used += 2;
    }
    var nb: [24]u8 = undefined;
    const tabs = std.fmt.bufPrint(&nb, "{d} tab{s}", .{ sp.tabs.len, if (sp.tabs.len == 1) "" else "s" }) catch "";
    ink(f, t.muted, ground);
    f.put("  ");
    used += 2;
    used += altpkg.putW(f, tabs, w -| used -| 8);
    if (sp.quiet_ms > 0) {
        var ab: [16]u8 = undefined;
        const age = altpkg.age(&ab, sp.quiet_ms);
        f.cup(x + w -| chromepkg.cols(age), y);
        ink(f, t.muted, ground);
        _ = altpkg.putW(f, age, 6);
    }
}

// ---- the inspector ----

fn drawInsp(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, narrow: bool) void {
    const t = p.t;
    const h = &st.home;
    const ins = &h.insp;
    const x = r.x + 2;
    const w = r.w -| 4;
    const focused = h.focus == .insp;
    const bottom = r.y + r.h;
    var y = r.y;

    if (narrow) {
        f.cup(x, y);
        ink(f, t.muted, t.chrome);
        _ = altpkg.putW(f, if (t.glyphs == .ascii) "h: back to the list" else "h ‹ list", w);
        y += 1;
    }

    // the selected control stays in view; the scroll is rows
    if (ins.scroll >= ins.n) ins.scroll = 0;
    const avail: usize = bottom -| y;
    if (focused and ins.touched and ins.acts_n > 0) {
        var act_line: usize = 0;
        for (ins.lines[0..ins.n], 0..) |ln, i| {
            if (ln.action) |ai| {
                if (ai == @min(ins.cur, ins.acts_n - 1)) act_line = i;
            }
        }
        if (act_line < ins.scroll) ins.scroll = act_line;
        if (act_line >= ins.scroll + avail) ins.scroll = act_line + 1 -| avail;
    }
    var i = ins.scroll;
    var wrapped: [6][]const u8 = undefined;
    const overflow = ins.n - @min(ins.scroll, ins.n) > avail;
    const limit = if (overflow) bottom - 1 else bottom;
    while (i < ins.n and y < limit) : (i += 1) {
        const ln = ins.lines[i];
        const sel = focused and ln.action != null and ln.action.? == @min(ins.cur, ins.acts_n -| 1);
        f.cup(x, y);
        switch (ln.kind) {
            .blank => {},
            .title => {
                ink(f, ui.markInk(t, ln.mark), t.chrome);
                f.put(ui.markGlyph(t, ln.mark));
                f.put(" ");
                style(f, .{ .fg = t.primary, .bg = t.chrome, .bold = true });
                _ = altpkg.putW(f, ln.text, w -| 2);
            },
            .meta => {
                ink(f, t.secondary, t.chrome);
                _ = altpkg.putW(f, ln.text, w);
            },
            .section => {
                ink(f, t.muted, t.chrome);
                var used = altpkg.putW(f, ln.text, w);
                if (ln.extra.len > 0) {
                    f.put(" ");
                    used += 1;
                    _ = altpkg.putW(f, ln.extra, w -| used);
                }
            },
            .text => {
                // wrapped, the rest of the lines taken as they fit
                const k = wrap(ln.text, w -| 2, &wrapped);
                var j: usize = 0;
                while (j < k and y < limit) : (j += 1) {
                    f.cup(x + 2, y);
                    ink(f, t.primary, t.chrome);
                    _ = altpkg.putW(f, wrapped[j], w -| 2);
                    if (j + 1 < k) y += 1;
                }
            },
            .quiet => {
                const k = wrap(ln.text, w -| 2, &wrapped);
                var j: usize = 0;
                while (j < k and y < limit) : (j += 1) {
                    f.cup(x + 2, y);
                    ink(f, t.muted, t.chrome);
                    _ = altpkg.putW(f, wrapped[j], w -| 2);
                    if (j + 1 < k) y += 1;
                }
            },
            .step_done, .step_todo => {
                f.cup(x + 2, y);
                const done = ln.kind == .step_done;
                ink(f, if (done) t.success else t.muted, t.chrome);
                f.put(if (done) ui.markGlyph(t, .success) else ui.markGlyph(t, .waiting));
                f.put(" ");
                ink(f, if (done) t.muted else t.primary, t.chrome);
                _ = altpkg.putW(f, ln.text, w -| 4);
            },
            .event => {
                f.cup(x + 2, y);
                ink(f, t.muted, t.chrome);
                const aw: u16 = 6;
                _ = altpkg.putW(f, ln.extra, aw);
                f.cup(x + 2 + aw + 1, y);
                ink(f, t.secondary, t.chrome);
                _ = altpkg.putW(f, ln.text, w -| aw -| 3);
            },
            .kv => {
                f.cup(x + 2, y);
                ink(f, t.muted, t.chrome);
                _ = altpkg.putW(f, ln.extra, 10);
                f.cup(x + 13, y);
                ink(f, t.primary, t.chrome);
                _ = altpkg.putW(f, ln.text, w -| 11);
            },
            .output => {
                f.cup(x + 2, y);
                ink(f, t.muted, t.chrome);
                f.put(ui.glyph(t, .separator));
                f.put(" ");
                ink(f, t.secondary, t.chrome);
                _ = altpkg.putW(f, ln.text, w -| 4);
            },
            .action => {
                const ground: Rgb = if (sel) t.selection else t.chrome;
                if (sel) {
                    style(f, .{ .bg = ground });
                    pad(f, w);
                    f.cup(x, y);
                    style(f, .{ .fg = t.accent, .bg = ground, .bold = true });
                    f.put(ui.glyph(t, .marker));
                } else {
                    f.put(" ");
                }
                f.put(" ");
                const a = ins.acts[ln.action.?];
                const glyph: []const u8 = switch (a.kind) {
                    .approval, .answer => ui.markGlyph(t, .waiting),
                    .open, .enter => ui.glyph(t, .arrow_to),
                    .go_see => ui.markGlyph(t, .attention),
                    .ask => ui.glyph(t, .companion),
                    .control => switch (a.ctrl) {
                        .stop => ui.markGlyph(t, .failed),
                        .pause => ui.markGlyph(t, .waiting),
                        .@"resume", .retry => ui.markGlyph(t, .working),
                        else => ui.glyph(t, .marker),
                    },
                };
                const gc: Rgb = switch (a.kind) {
                    .approval, .answer => t.waiting,
                    .go_see => t.attention,
                    .ask => t.accent,
                    .control => if (a.ctrl == .stop) t.err else t.secondary,
                    else => t.secondary,
                };
                ink(f, gc, ground);
                _ = altpkg.putW(f, glyph, 2);
                f.put(" ");
                style(f, .{ .fg = t.primary, .bg = ground, .bold = sel });
                var used: u16 = 5 + altpkg.putW(f, ln.text, @min(w -| 5, 40));
                if (a.run.len > 0 and used + 6 < w) {
                    ink(f, t.muted, ground);
                    f.put("  $ ");
                    used += 4;
                    _ = altpkg.putW(f, a.run, w -| used);
                }
                if (sel) {
                    const hint: []const u8 = if (t.glyphs == .ascii) "enter" else "↵";
                    f.cup(x + w -| chromepkg.cols(hint), y);
                    ink(f, t.accent, ground);
                    _ = altpkg.putW(f, hint, 6);
                }
            },
        }
        y += 1;
    }
    if (overflow and bottom > r.y) {
        f.cup(x, bottom - 1);
        style(f, .{ .bg = t.chrome });
        pad(f, w);
        f.cup(x, bottom - 1);
        ink(f, t.muted, t.chrome);
        var mb: [32]u8 = undefined;
        _ = altpkg.putW(f, std.fmt.bufPrint(&mb, "{s} {d} more · j k", .{ ui.glyph(t, .more), ins.n - i }) catch "", w);
    }
}

// ---- vera's pane ----

fn drawVera(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, over: bool) renderpkg.CursorOverride {
    if (p.chat) |pane| return drawHostedChat(f, st, r, p, over, pane);
    return drawOwnSurface(f, st, r, p, over);
}

/// The panel with the companion's own terminal in it. Rook paints one
/// header row (two, with something attached) and hands every other
/// row to the program: what is inside them — streaming, markdown,
/// tool cards, a box that grows with what you type — is mote's, and
/// rook does not second-guess a cell of it.
fn drawHostedChat(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, over: bool, pane: *panepkg.Pane) renderpkg.CursorOverride {
    const t = p.t;
    const h = &st.home;
    const ground: Rgb = if (over) t.raised else t.chrome;
    const x = r.x + 1;
    const w = r.w -| 2;
    const focused = h.focus == .vera;

    f.cup(x, r.y);
    style(f, .{ .bg = ground });
    pad(f, w);
    f.cup(x, r.y);
    ink(f, if (focused) t.accent else t.secondary, ground);
    f.put(ui.glyph(t, .companion));
    f.put(" ");
    style(f, .{ .fg = if (focused) t.primary else t.secondary, .bg = ground, .bold = true });
    const used: u16 = 2 + altpkg.putW(f, p.ask_name, 16);
    // The right of the header is the way out — the one thing the
    // program inside cannot tell you, because it does not know it is
    // in a panel. Everything else on this row would be a second
    // opinion about a status mote already shows.
    var hb: [96]u8 = undefined;
    const hint: []const u8 = if (focused)
        (std.fmt.bufPrint(&hb, "{s}{s}h leaves · {s}t hides", .{ if (h.vera_pinned) "pinned · " else "", if (t.glyphs == .ascii) "C-" else "^", p.prefix }) catch "")
    else
        (std.fmt.bufPrint(&hb, "{s}{s}t focus", .{ if (h.vera_pinned) "pinned · " else "", p.prefix }) catch "");
    const hw = chromepkg.cols(hint);
    if (hint.len > 0 and used + hw + 2 <= w) {
        f.cup(x + w -| hw, r.y);
        ink(f, t.muted, ground);
        _ = altpkg.putW(f, hint, hw);
    }
    const about = h.about_title_len > 0;
    if (about) {
        f.cup(x, r.y + 1);
        style(f, .{ .bg = ground });
        pad(f, w);
        f.cup(x, r.y + 1);
        ink(f, t.muted, ground);
        f.put("about ");
        _ = ui.scopeChip(f, t, h.aboutTitle(), .space);
        ink(f, t.muted, ground);
        f.put("  esc clears");
    }

    const body = veraBody(r, about);
    if (!chatFits(body)) {
        fill(f, body, ground);
        if (body.h > 0) {
            var wrapped: [4][]const u8 = undefined;
            const k = wrap("not enough room for the chat — widen the pane, or unpin it", body.w, &wrapped);
            for (wrapped[0..@min(k, body.h)], 0..) |ln, i| {
                f.cup(body.x, body.y + @as(u16, @intCast(i)));
                ink(f, t.muted, ground);
                _ = altpkg.putW(f, ln, body.w);
            }
        }
        return .{ .x = r.x, .y = r.y, .hidden = true };
    }
    f.drawPaneIn(pane, body);
    // The cursor is the program's, moved into the panel: mote owns
    // the box, so it owns where the caret sits in it.
    const cur = pane.rs.cursor;
    if (!focused or !cur.visible) return .{ .x = r.x, .y = r.y, .hidden = true };
    const v = cur.viewport orelse return .{ .x = r.x, .y = r.y, .hidden = true };
    if (v.x >= body.w or v.y >= body.h) return .{ .x = r.x, .y = r.y, .hidden = true };
    return .{ .x = body.x + v.x, .y = body.y + v.y, .bar = cur.visual_style == .bar };
}

fn drawOwnSurface(f: *renderpkg.Frame, st: *altpkg.State, r: Rect, p: Paint, over: bool) renderpkg.CursorOverride {
    const t = p.t;
    const h = &st.home;
    const ground: Rgb = if (over) t.raised else t.chrome;
    const x = r.x + 1;
    const w = r.w -| 2;
    const focused = h.focus == .vera;
    var y = r.y;

    // header: the companion, where she stands, what this is about
    f.cup(x, y);
    ink(f, if (focused) t.accent else t.secondary, ground);
    f.put(ui.glyph(t, .companion));
    f.put(" ");
    style(f, .{ .fg = if (focused) t.primary else t.secondary, .bg = ground, .bold = true });
    var used: u16 = 2 + altpkg.putW(f, p.ask_name, 16);
    const status = askStatus(st, p);
    ink(f, t.muted, ground);
    f.put(" · ");
    used += 3;
    const mg = ui.markGlyph(t, status.mark);
    if (mg.len > 0) {
        ink(f, ui.markInk(t, status.mark), ground);
        f.put(mg);
        f.put(" ");
        used += 2;
    }
    ink(f, if (status.mark == .none) t.muted else ui.markInk(t, status.mark), ground);
    used += altpkg.putW(f, status.word, w -| used -| 10);
    const pin: []const u8 = if (h.vera_pinned) "pinned" else "";
    if (pin.len > 0) {
        f.cup(x + w -| chromepkg.cols(pin), y);
        ink(f, t.muted, ground);
        _ = altpkg.putW(f, pin, 8);
    }
    y += 1;
    if (h.about_title_len > 0) {
        f.cup(x, y);
        ink(f, t.muted, ground);
        f.put("about ");
        _ = ui.scopeChip(f, t, h.aboutTitle(), .space);
        ink(f, t.muted, ground);
        f.put("  esc clears");
        y += 1;
    }
    y += 1;

    const comp_y = r.y + r.h -| 2;
    const thread_bottom = comp_y -| 1;
    const thread_rows: u16 = thread_bottom -| y;

    var lines: [512]Line = undefined;
    const n_lines = layoutThread(st, w, &lines);
    const visible: usize = @min(n_lines, thread_rows);
    const max_scroll: usize = n_lines -| visible;
    if (h.thread_scroll > max_scroll) h.thread_scroll = max_scroll;
    const end = n_lines - h.thread_scroll;
    const start = end -| visible;
    var row: u16 = thread_bottom -| @as(u16, @intCast(visible));
    if (n_lines == 0 and thread_rows > 2) {
        var wrapped: [3][]const u8 = undefined;
        const k = wrap(if (p.ask_on) "say what should happen; the work shows in the navigator" else "nobody to talk to — the navigator and the inspector still tell the truth", w, &wrapped);
        for (wrapped[0..k], 0..) |ln, i| {
            f.cup(x, thread_bottom -| 3 + @as(u16, @intCast(i)));
            ink(f, t.muted, ground);
            _ = altpkg.putW(f, ln, w);
        }
    }
    for (lines[start..end]) |ln| {
        drawLine(f, st, ln, x, row, w, p, ground);
        row += 1;
    }
    if (h.thread_scroll > 0 and thread_rows > 0) {
        var mb: [32]u8 = undefined;
        f.cup(x + w -| 12, thread_bottom - 1);
        ink(f, t.muted, ground);
        _ = altpkg.putW(f, std.fmt.bufPrint(&mb, "{s} {d} below", .{ ui.glyph(t, .more), h.thread_scroll }) catch "", 12);
    }
    return drawComposer(f, st, x, comp_y, w, p, focused, ground);
}

const Line = struct {
    turn: usize,
    first: bool,
    text: []const u8,
    role: Role,
    action: ?usize = null,
    block: bool = false,
};

fn layoutThread(st: *altpkg.State, w: u16, out: []Line) usize {
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

fn drawLine(f: *renderpkg.Frame, st: *altpkg.State, ln: Line, x: u16, y: u16, w: u16, p: Paint, ground0: Rgb) void {
    const t = p.t;
    const h = &st.home;
    const block_ground: Rgb = if (std.meta.eql(ground0, t.raised)) t.selection else t.raised;
    const ground: Rgb = if (ln.block) block_ground else ground0;
    f.cup(x, y);
    style(f, .{ .bg = ground0 });
    pad(f, w);
    if (ln.block) {
        f.cup(x + 5, y);
        style(f, .{ .bg = block_ground });
        pad(f, w -| 5);
    }
    if (ln.first) {
        const m = roleMark(t, ln.role);
        f.cup(x + 1, y);
        style(f, .{ .fg = m.c, .bg = ground0, .bold = m.bold });
        _ = altpkg.putW(f, m.glyph, 3);
    }
    f.cup(x + 6, y);
    if (ln.action) |a| {
        const act = &st.req.ref.?.actions[a];
        const mark: ui.Mark = if (act.running) .working else if (!act.ran) .waiting else if (act.code == 0) .success else .failed;
        ink(f, ui.markInk(t, mark), ground);
        f.put(ui.markGlyph(t, mark));
        f.put(" ");
        ink(f, if (act.ran) t.muted else t.primary, ground);
        var used: u16 = 2 + altpkg.putW(f, ln.text, w -| 9);
        if (act.ran and used + 6 < w - 7) {
            ink(f, t.muted, ground);
            f.put(" · ");
            used += 3;
            _ = altpkg.putW(f, askpkg.firstLine(act.receiptSlice()), w -| 7 -| used);
        } else if (!act.ran and used + 14 < w - 7) {
            ink(f, t.muted, ground);
            f.put("  ");
            _ = altpkg.putW(f, if (t.glyphs == .ascii) "needs you: enter in the inspector" else "needs you · ↵ in the inspector", w -| 7 -| used -| 2);
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
    style(f, .{ .fg = c, .bg = ground });
    const used = altpkg.putW(f, ln.text, w -| 7);
    if (ln.first) {
        const turn = h.thread.get(ln.turn);
        var ab: [16]u8 = undefined;
        const age = altpkg.age(&ab, p.now - turn.ms);
        const aw = chromepkg.cols(age);
        if (used + aw + 2 < w) {
            f.cup(x + w -| aw, y);
            ink(f, t.muted, ground0);
            _ = altpkg.putW(f, age, aw);
        }
    }
}

fn drawComposer(f: *renderpkg.Frame, st: *altpkg.State, x: u16, y: u16, w: u16, p: Paint, focused: bool, ground0: Rgb) renderpkg.CursorOverride {
    const t = p.t;
    const field: Rgb = if (focused) (if (std.meta.eql(ground0, t.raised)) t.selection else t.raised) else ground0;
    f.cup(x, y);
    style(f, .{ .bg = field });
    pad(f, w);
    f.cup(x, y);
    style(f, .{ .fg = if (focused) t.accent else t.muted, .bg = field, .bold = true });
    f.put(" ");
    f.put(ui.glyph(t, .prompt));
    f.put(" ");
    var cx: u16 = x + 3;
    const text = st.textSlice();
    if (text.len == 0) {
        var pb: [128]u8 = undefined;
        const ph = if (p.ask_on)
            std.fmt.bufPrint(&pb, "Ask {s}…", .{p.ask_name}) catch "Ask…"
        else
            std.fmt.bufPrint(&pb, "{s} is not on PATH", .{p.ask_name}) catch "offline";
        ink(f, t.muted, field);
        _ = altpkg.putW(f, ph, w -| 4);
    } else {
        style(f, .{ .fg = t.primary, .bg = field, .bold = true });
        cx += altpkg.putW(f, text, w -| 4);
    }
    f.cup(x, y + 1);
    ink(f, t.muted, ground0);
    const status = askStatus(st, p);
    var hb: [160]u8 = undefined;
    const hint: []const u8 = if (st.req.state == .running)
        (std.fmt.bufPrint(&hb, "{s} {s} · esc cancels", .{ p.ask_name, status.word }) catch "")
    else if (!focused)
        (std.fmt.bufPrint(&hb, "{s}t focus · {s}T pin", .{ p.prefix, p.prefix }) catch "")
    else if (st.home.vera_pinned)
        (if (t.glyphs == .ascii) "enter sends · up/down scroll · esc back" else "↵ sends · ↑ ↓ scroll · esc back")
    else
        (if (t.glyphs == .ascii) "enter sends · up/down scroll · esc closes" else "↵ sends · ↑ ↓ scroll · esc closes");
    _ = altpkg.putW(f, hint, w);
    return .{ .x = @min(cx, x + w -| 1), .y = y, .bar = true, .hidden = !focused };
}

test "the layout is navigator and inspector, vera a third column only when all three fit" {
    const wide = layout(.{ .x = 0, .y = 1, .w = 160, .h = 40 }, false);
    try std.testing.expect(wide.wide);
    try std.testing.expectEqual(@as(u16, 54), wide.nav.w);
    try std.testing.expectEqual(@as(u16, 55), wide.insp.?.x);
    try std.testing.expect(wide.vera == null);
    // pinned, with room: three columns, every one at its floor or above
    const three = layout(.{ .x = 0, .y = 1, .w = 160, .h = 40 }, true);
    try std.testing.expect(three.vera != null);
    try std.testing.expect(three.nav.w >= min_nav);
    try std.testing.expect(three.insp.?.w >= min_insp);
    try std.testing.expect(three.vera.?.w >= min_vera);
    try std.testing.expectEqual(@as(u16, 160), three.vera.?.x + three.vera.?.w);
    // pinned without room for three: two columns, and she overlays
    const two = layout(.{ .x = 0, .y = 1, .w = 110, .h = 40 }, true);
    try std.testing.expect(two.vera == null);
    try std.testing.expect(two.wide);
    // the floors: 81 splits, 80 stacks
    try std.testing.expect(layout(.{ .x = 0, .y = 1, .w = 81, .h = 30 }, false).wide);
    try std.testing.expect(!layout(.{ .x = 0, .y = 1, .w = 80, .h = 30 }, false).wide);
    // the overlay never covers the navigator's third
    const ov = veraOverlay(.{ .x = 55, .y = 1, .w = 105, .h = 40 });
    try std.testing.expect(ov.x >= 55);
    try std.testing.expect(ov.w >= min_vera);
}

test "vera's panel has one answer, and the hosted chat is sized from it" {
    const region: Rect = .{ .x = 0, .y = 1, .w = 160, .h = 40 };
    // not up: no panel, and nothing to size
    try std.testing.expect(veraPanel(region, false, false, false) == null);
    // up and unpinned on a wide glass: over the inspector's side, its
    // own ground, never over the navigator
    const over = veraPanel(region, false, true, true).?;
    try std.testing.expect(over.over);
    const lay = layout(region, false);
    try std.testing.expect(over.r.x > lay.nav.x + lay.nav.w);
    try std.testing.expectEqual(region.x + region.w, over.r.x + over.r.w);
    // pinned with room: the third column layout already returns
    const pinned = veraPanel(region, true, true, false).?;
    try std.testing.expect(!pinned.over);
    try std.testing.expectEqual(layout(region, true).vera.?.x, pinned.r.x);
    // narrow: the whole region, but only when she has the focus
    const narrow: Rect = .{ .x = 0, .y = 1, .w = 60, .h = 30 };
    try std.testing.expectEqual(narrow.w, veraPanel(narrow, false, true, true).?.r.w);
    try std.testing.expect(veraPanel(narrow, false, true, false) == null);
    // in a space she is the same overlay, and always up
    const space = veraPanelOver(region);
    try std.testing.expect(space.over);
    try std.testing.expectEqual(region.x + region.w, space.r.x + space.r.w);
    // every arrangement leaves the hosted terminal inside the region
    for ([_]Panel{ over, pinned, space }) |pl| {
        const body = veraBody(pl.r, false);
        try std.testing.expect(body.x >= region.x);
        try std.testing.expect(body.x + body.w <= region.x + region.w);
        try std.testing.expect(body.y + body.h <= region.y + region.h);
        try std.testing.expect(chatFits(body));
    }
}

test "the hosted chat gets every row rook does not keep, and the two agree" {
    const r: Rect = .{ .x = 10, .y = 1, .w = 50, .h = 30 };
    // one header row, and the pane starts under it
    const plain = veraBody(r, false);
    try std.testing.expectEqual(@as(u16, 11), plain.x);
    try std.testing.expectEqual(@as(u16, 2), plain.y);
    try std.testing.expectEqual(@as(u16, 48), plain.w);
    try std.testing.expectEqual(@as(u16, 29), plain.h);
    // the panel's last row is the pane's last row: nothing is kept back
    try std.testing.expectEqual(r.y + r.h, plain.y + plain.h);
    // something attached costs exactly one more row
    const attached = veraBody(r, true);
    try std.testing.expectEqual(plain.y + 1, attached.y);
    try std.testing.expectEqual(plain.h - 1, attached.h);
    try std.testing.expectEqual(r.y + r.h, attached.y + attached.h);
    // and the floors hold rather than underflow
    const tiny = veraBody(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, true);
    try std.testing.expectEqual(@as(u16, 0), tiny.w);
    try std.testing.expectEqual(@as(u16, 0), tiny.h);
    try std.testing.expect(!chatFits(tiny));
    try std.testing.expect(chatFits(plain));
    try std.testing.expect(!chatFits(.{ .x = 0, .y = 0, .w = min_chat_cols - 1, .h = 40 }));
    try std.testing.expect(!chatFits(.{ .x = 0, .y = 0, .w = 80, .h = min_chat_rows - 1 }));
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
    const k = wrap("abcdefghijklmnop", 5, &out);
    try std.testing.expect(k >= 3);
    try std.testing.expectEqualStrings("abcde", out[0]);
}

test "the thread is a ring, and finds the turns about a task" {
    var th: Thread = .{};
    _ = th.push(.you, "deploy the api", "", "", 1);
    _ = th.push(.plan, "deploy from main", "t4", "api", 2);
    _ = th.push(.note, "t4 began", "t4", "", 3);
    try std.testing.expectEqual(@as(usize, 3), th.count());
    try std.testing.expectEqual(@as(usize, 2), th.about("t4").?);
    try std.testing.expectEqual(@as(usize, 2), th.countAbout("t4"));
    try std.testing.expect(th.about("t9") == null);
    var i: usize = 0;
    while (i < max_turns) : (i += 1) _ = th.push(.you, "x", "", "", 10);
    try std.testing.expectEqual(@as(usize, max_turns), th.count());
}

test "the navigator cursor walks rows, skips headers, and keeps its identity across a rebuild" {
    var h: State = .{};
    h.addRow(.{ .module = .needs, .header = true });
    _ = h.addTask(.{ .kind = .signal, .module = .needs, .title = "bell" });
    h.addRow(.{ .module = .needs, .task = 0 });
    h.addRow(.{ .module = .spaces, .header = true });
    h.addRow(.{ .module = .spaces, .space = 0 });
    h.nav_cur = 0;
    h.clampNav();
    try std.testing.expectEqual(@as(usize, 1), h.nav_cur);
    h.moveNav(1);
    try std.testing.expectEqual(@as(usize, 3), h.nav_cur);
    h.moveNav(1);
    try std.testing.expectEqual(@as(usize, 3), h.nav_cur);
    h.moveNav(-1);
    try std.testing.expectEqual(@as(usize, 1), h.nav_cur);
    try std.testing.expect(h.landNav(.spaces));
    try std.testing.expectEqual(@as(usize, 3), h.nav_cur);
    try std.testing.expectEqual(@as(usize, 1), h.needsCount());
    try std.testing.expectEqual(chromepkg.State.none, h.remember("t1", .working).?);
    try std.testing.expect(h.remember("t1", .working) == null);
    try std.testing.expectEqual(chromepkg.State.working, h.remember("t1", .done).?);
    // a task with an id keeps its selection when it moves groups
    h.reset();
    _ = h.addTask(.{ .kind = .producer, .module = .active, .id = "t2", .title = "fix", .state = .working });
    h.addRow(.{ .module = .active, .header = true });
    h.addRow(.{ .module = .active, .task = 0 });
    h.nav_cur = 1;
    h.nav_touched = true;
    h.noteSelection();
    h.reset();
    h.addRow(.{ .module = .needs, .header = true });
    _ = h.addTask(.{ .kind = .signal, .module = .needs, .title = "bell" });
    h.addRow(.{ .module = .needs, .task = 0 });
    h.addRow(.{ .module = .recent, .header = true });
    _ = h.addTask(.{ .kind = .producer, .module = .recent, .id = "t2", .title = "fix", .state = .done });
    h.addRow(.{ .module = .recent, .task = 1 });
    h.restoreSelection();
    try std.testing.expectEqual(@as(usize, 3), h.nav_cur);
}

test "focus walks navigator, inspector, vera with h and l, and vera toggles" {
    var h: State = .{};
    try std.testing.expect(!h.navFocus('h'));
    try std.testing.expect(h.navFocus('l'));
    try std.testing.expectEqual(Region.insp, h.focus);
    try std.testing.expect(h.detail);
    // vera is not up: the inspector is the right edge
    try std.testing.expect(!h.navFocus('l'));
    h.toggleVera();
    try std.testing.expect(h.vera_open);
    try std.testing.expectEqual(Region.vera, h.focus);
    try std.testing.expect(!h.navFocus('l'));
    try std.testing.expect(h.navFocus('h'));
    try std.testing.expectEqual(Region.insp, h.focus);
    try std.testing.expect(h.navFocus('l'));
    try std.testing.expectEqual(Region.vera, h.focus);
    // the same key dismisses her, and focus is back where it was
    // when she was summoned: the inspector
    h.toggleVera();
    try std.testing.expect(!h.vera_open);
    try std.testing.expectEqual(Region.insp, h.focus);
    h.focus = .nav;
    // pinned, the toggle only moves focus, and back to where it was
    h.vera_pinned = true;
    h.focus = .insp;
    h.toggleVera();
    try std.testing.expectEqual(Region.vera, h.focus);
    h.toggleVera();
    try std.testing.expectEqual(Region.insp, h.focus);
    try std.testing.expect(h.veraShown());
    h.focus = .nav;
    // h from the inspector is the list again on the narrow stack
    h.focus = .insp;
    h.detail = true;
    try std.testing.expect(h.navFocus('h'));
    try std.testing.expect(!h.detail);
}

test "the inspector keeps its place for the same subject and starts over for a new one" {
    var ins: Insp = .{};
    ins.subject("t:t2");
    ins.act(.{ .label = "approve", .kind = .answer, .run = "x" });
    ins.act(.{ .label = "open", .kind = .open });
    ins.moveAct(1);
    ins.scroll = 4;
    try std.testing.expectEqual(@as(usize, 1), ins.cur);
    ins.subject("t:t2");
    try std.testing.expectEqual(@as(usize, 1), ins.cur);
    try std.testing.expectEqual(@as(usize, 4), ins.scroll);
    ins.subject("s:0");
    try std.testing.expectEqual(@as(usize, 0), ins.cur);
    try std.testing.expectEqual(@as(usize, 0), ins.scroll);
    try std.testing.expectEqualStrings("open", ins.acts[1].label);
    try std.testing.expectEqual(@as(usize, 2), ins.n);
}
