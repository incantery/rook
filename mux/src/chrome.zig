//! The chrome the engine draws itself — every cell that is not a pane.
//!
//! Three things live here: the palette (Catppuccin Mocha, the colors
//! the herdr design is drawn in), the side panel — a left rail of
//! *spaces* over *agents* — and the vocabulary the tab bar marks its
//! windows with, which is the rail's vocabulary and belongs beside it
//! rather than in the server that happens to draw the row. None of it
//! is a pty: no process backs this chrome, the frame builder paints it
//! straight from a model.
//!
//! One rule runs through all of it: **one state per channel**. A shape
//! says what a row is doing, a color agrees with the shape, a word
//! spells it out, the selection block means selected and nothing else,
//! and the accent dot means unread and nothing else. Two states
//! sharing a channel is how a rail starts lying — red for both an ask
//! and a crash taught a glance to read alarm where there was none.
//!
//! Almost nothing in this file decides what the rail *says*. The
//! model is pushed in from outside — `items.push` frames, the list
//! shape of the plugin protocol (docs/surfaces.md) — and `Feed` holds
//! the last one pushed to each surface. Rook paints; something else
//! supplies.
//!
//! The one exception is `Merge`, and it is deliberately small: a pane
//! running an agent is something rook can *see*, in its own pane
//! table, so a session somebody started by hand is not invisible to
//! the rail just because no producer knew to mention it. Those rows
//! carry `.manual` and say only that the session is there — never
//! what it is doing, which stays a producer's job.
const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// "#rrggbb" (or "rrggbb") → Rgb. Null on anything else.
    pub fn parse(s: []const u8) ?Rgb {
        const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (h.len != 6) return null;
        const v = std.fmt.parseInt(u24, h, 16) catch return null;
        return .{
            .r = @intCast(v >> 16),
            .g = @truncate(v >> 8),
            .b = @truncate(v),
        };
    }
};

// Catppuccin Mocha. crust is the page, mantle the panel, base the
// tab bar and the selected row; surface0 draws every seam.
pub const crust: Rgb = .{ .r = 0x11, .g = 0x11, .b = 0x1b };
pub const mantle: Rgb = .{ .r = 0x18, .g = 0x18, .b = 0x25 };
pub const base: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
pub const surface0: Rgb = .{ .r = 0x31, .g = 0x32, .b = 0x44 };
pub const overlay0: Rgb = .{ .r = 0x6c, .g = 0x70, .b = 0x86 };
pub const text: Rgb = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 };
pub const mauve: Rgb = .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 };
pub const red: Rgb = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 };
pub const peach: Rgb = .{ .r = 0xfa, .g = 0xb3, .b = 0x87 };
pub const yellow: Rgb = .{ .r = 0xf9, .g = 0xe2, .b = 0xaf };
pub const green: Rgb = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 };
pub const teal: Rgb = .{ .r = 0x94, .g = 0xe2, .b = 0xd5 };
pub const sky: Rgb = .{ .r = 0x89, .g = 0xdc, .b = 0xeb };
pub const blue: Rgb = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };

/// The eight ANSI names an `accent = "..."` can still spell, mapped
/// into the palette so a named accent and a hex one are the same kind
/// of color. `bright-` is accepted and means the same hue: Mocha has
/// one shade of each.
pub fn named(name: []const u8) ?Rgb {
    const want = if (std.mem.startsWith(u8, name, "bright-")) name["bright-".len..] else name;
    const table = [_]struct { n: []const u8, c: Rgb }{
        .{ .n = "black", .c = surface0 },   .{ .n = "red", .c = red },
        .{ .n = "green", .c = green },      .{ .n = "yellow", .c = yellow },
        .{ .n = "blue", .c = blue },        .{ .n = "magenta", .c = mauve },
        .{ .n = "cyan", .c = teal },        .{ .n = "white", .c = text },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.n, want)) return e.c;
    }
    return null;
}

// ---- the side panel's model ----

/// The status glyph beside a row. Ambiguous-width on purpose: one
/// cell on every terminal that defaults ambiguous to narrow, which
/// the glass does.
pub const Dot = enum {
    none, //    nothing to report: the name is the whole row
    working, // ◐  work in flight
    hollow, // ○  idle
    waiting, // ◇  wants you (blocked on an ask)
    done, // ✓  finished
    failed, // ×  did not finish
    loose, // ◌  nobody is driving it — see Origin

    fn glyph(self: Dot) []const u8 {
        return switch (self) {
            .none => " ",
            .working => "◐",
            .hollow => "○",
            .waiting => "◇",
            .done => "✓",
            .failed => "×",
            .loose => "◌",
        };
    }
};

/// The one glyph that is not a state: output on a row nobody has
/// looked at yet. It rides *beside* a state rather than replacing one
/// — a task can be done and unread at once, and the row has to say
/// both — so it is the only mark that wears the accent.
pub const unread_dot = "●";

/// Who put a row on the rail — the one thing about an item that is
/// not about the work.
///
/// `.managed` is the default and the norm: a producer pushed the row,
/// so something is driving that agent and can say what it is doing.
/// `.manual` means nobody claims it — rook found the pane running an
/// agent in its own pane table and nothing supplied a row for it (or a
/// producer pushed `"origin":"manual"` to say the same).
///
/// Origin never takes a color from the palette and never overrides a
/// state: a glance still reads state first. It gets a dot shape for a
/// row with no state to report, and one dim word ahead of the
/// subtitle. That is the whole distinction, deliberately.
pub const Origin = enum {
    managed,
    manual,
    /// Rook's own row about rook's own state — a workspace it holds,
    /// listed on `spaces` because nothing pushed a row for it. Not
    /// "manual": nobody launches a workspace at an agent, so there is
    /// nothing to be unmanaged about, and it wears no tag. A producer
    /// may push it too; an unknown word still lands on managed.
    found,

    /// Anything but "manual" is managed: an item that arrived by push
    /// has a producer behind it by definition, and an unknown word
    /// must not cost the frame.
    pub fn parse(s: []const u8) Origin {
        if (std.mem.eql(u8, s, "manual")) return .manual;
        if (std.mem.eql(u8, s, "found")) return .found;
        return .managed;
    }

    /// The label the row wears ahead of its subtitle. Managed is the
    /// norm and says nothing.
    pub fn tag(self: Origin) []const u8 {
        return switch (self) {
            .managed, .found => "",
            .manual => "manual · ",
        };
    }

    /// Cells `tag` occupies. The middle dot is two bytes and one
    /// column, so this is not the byte length.
    pub fn tagCols(self: Origin) u16 {
        return switch (self) {
            .managed, .found => 0,
            .manual => 9,
        };
    }
};

/// An item's state, and the only thing that colors a row. Rook owns
/// the palette — a pushed model names a state, never a color — so
/// every rail anybody ships reads the same. An unknown name lands on
/// `.none`, the plain row, rather than costing the frame.
pub const State = enum {
    none,
    working,
    idle,
    blocked,
    done,
    failed,

    pub fn parse(s: []const u8) State {
        const table = [_]struct { n: []const u8, s: State }{
            .{ .n = "working", .s = .working },
            .{ .n = "running", .s = .working },
            .{ .n = "idle", .s = .idle },
            .{ .n = "blocked", .s = .blocked },
            .{ .n = "waiting", .s = .blocked },
            .{ .n = "done", .s = .done },
            .{ .n = "failed", .s = .failed },
            .{ .n = "error", .s = .failed },
        };
        for (table) |e| {
            if (std.mem.eql(u8, e.n, s)) return e.s;
        }
        return .none;
    }

    /// Red is failure-only. That is the whole rule, and it costs
    /// `blocked` the color it used to wear: a row waiting on you has
    /// not gone wrong, it is asking, and painting the ask the same as
    /// a crash taught a glance to read alarm where there was none.
    /// Waiting is yellow — the attention color, shared with work in
    /// flight — and `×` red is left to mean one thing.
    ///
    /// Idle drops to `overlay0` for the same reason in the other
    /// direction: green on a row that is doing nothing was the
    /// loudest thing on a quiet rail. Green now says `done`.
    pub fn color(self: State) Rgb {
        return switch (self) {
            .none, .idle => overlay0,
            .working, .blocked => yellow,
            .done => green,
            .failed => red,
        };
    }

    /// One state per channel: every state has its own shape, so a rail
    /// still reads on a screen that has lost its color — and so the
    /// accent dot is free to mean `unread` and nothing else.
    pub fn shape(self: State) Dot {
        return switch (self) {
            .none => .none,
            .working => .working,
            .idle => .hollow,
            .blocked => .waiting,
            .done => .done,
            .failed => .failed,
        };
    }

    /// The word the row wears at its right edge. A glyph is a glance;
    /// the word is what the glance resolves into, and it is rook's
    /// word rather than the producer's so that every rail says the
    /// same thing about the same state. `.none` has nothing to add.
    pub fn word(self: State) []const u8 {
        return switch (self) {
            .none => "",
            .working => "working",
            .idle => "idle",
            .blocked => "needs you",
            .done => "done",
            .failed => "failed",
        };
    }

    /// The subtitle's color. A state that says something about work in
    /// flight paints the subtitle too; a resting row leaves it plain,
    /// which is what lets a selected row wear the accent instead.
    pub fn subFg(self: State) Rgb {
        return switch (self) {
            .none, .idle => overlay0,
            else => self.color(),
        };
    }
};

pub const Item = struct {
    name: []const u8,
    /// The second line: a branch for a space, "state · tool" for an agent.
    sub: []const u8 = "",
    state: State = .none,
    origin: Origin = .managed,
    /// Output on this row that nobody has read yet. A second channel,
    /// deliberately independent of `state`: a task can be `.done` and
    /// unread in the same breath, and collapsing the two would lose
    /// whichever one the other overwrote.
    unread: bool = false,
    /// The workspace this row's agent is running in, when the producer
    /// says so (`"workspace"` on a pushed item). A row's *name* is
    /// prose — a task, a branch, a sentence — so it is not an identity
    /// rook can match its own pane table against. This is: it is a
    /// workspace name, rook's own vocabulary, and naming it is how a
    /// producer claims the session rook can see there. Empty means the
    /// producer said nothing, and the name is the only claim it has.
    ws: []const u8 = "",

    /// The workspace this row points at: the explicit `ws` when one
    /// was named, else the row's name. It is what a click on the row
    /// has to act on, and what a claim is matched against.
    ///
    /// Rook's own rows always name it, because their `name` is a
    /// *label* and no longer the workspace — a row can read
    /// `vera-e4126385`, or the title a producer gave the agent in it,
    /// and still act on `rook--vera-e4126385`. The fallback to `name`
    /// is for a pushed row that said nothing, which is the rail whose
    /// rows are workspaces anyway.
    pub fn workspace(self: Item) []const u8 {
        return if (self.ws.len > 0) self.ws else self.name;
    }

    /// Does this row claim the workspace `name`? An explicit `ws`
    /// answers alone — a producer that names a workspace has said
    /// which one, and its title is then about the work, not about a
    /// workspace that happens to share the word.
    pub fn claims(self: Item, name: []const u8) bool {
        return std.mem.eql(u8, self.workspace(), name);
    }

    /// The glyph beside the name. State owns it whenever state has
    /// something to say; a manual row with nothing reporting on it
    /// gets the loose dot rather than borrowing `.none`'s filled one,
    /// which would read as running.
    pub fn dot(self: Item) Dot {
        if (self.origin != .managed and self.state == .none) return .loose;
        return self.state.shape();
    }
};

/// The separator rook puts between a repository and one of its
/// worktrees: `<repo>--<worktree>` is the directory it makes, so it is
/// also the workspace name — `rook--vera-e4126385` here. See
/// `internal/worktree`.
pub const space_sep = "--";

/// The label a workspace name earns on the rail.
///
/// A workspace name is an *identity*: unambiguous across every
/// repository on the machine, which is exactly why the repo is in it.
/// It is not a label. Down a 30-column dock the repo is the same word
/// on every row, and the part that tells the rows apart is the part
/// that falls off the right edge — a column of `rook--vera-e4126…`
/// says nothing that the panel's own existence did not. `rook worktree
/// ls` has always printed the short name; the rail now agrees with it,
/// and the repo moves to the subtitle rather than being lost.
///
/// The split is on the *last* separator, so a worktree of a worktree
/// (`rook--vera-e4126385--fix`) labels as its leaf, `fix`: the leaf is
/// the part that distinguishes it. A name with nothing on one side of
/// the separator is left whole — there is no shorter honest form of it.
pub fn shortSpace(name: []const u8) []const u8 {
    const sep = std.mem.lastIndexOf(u8, name, space_sep) orelse return name;
    if (sep == 0 or sep + space_sep.len == name.len) return name;
    return name[sep + space_sep.len ..];
}

/// The repository half of a workspace name, or "" when the name does
/// not carry one. This is what `shortSpace` takes off, and it goes in
/// the subtitle: which checkout a space is on is a real question, and
/// the short label alone cannot answer it.
pub fn spaceRepo(name: []const u8) []const u8 {
    const sep = std.mem.lastIndexOf(u8, name, space_sep) orelse return "";
    if (sep == 0 or sep + space_sep.len == name.len) return "";
    return name[0..sep];
}

/// Label rook's own workspace rows in place: `ws` is the identity,
/// `name` becomes what the rail paints.
///
/// Shortening must never cost uniqueness — two rows reading the same
/// word are worse than one long one — so any label that two different
/// workspaces would share is given back its full name. Both of them,
/// not just the second: a rail where one row is short and its twin is
/// long reads as two unrelated things. Quadratic over a couple of
/// dozen rows, on a repaint that already walks the pane table.
pub fn labelSpaces(items: []Item) void {
    for (items) |*it| it.name = shortSpace(it.workspace());
    for (items, 0..) |*a, i| {
        for (items[i + 1 ..]) |*b| {
            if (std.mem.eql(u8, a.workspace(), b.workspace())) continue;
            if (!std.mem.eql(u8, a.name, b.name)) continue;
            a.name = a.workspace();
            b.name = b.workspace();
        }
    }
}

/// The title a producer gave the agent it is running in `ws`, if one
/// did. Empty titles say nothing, and a title that *is* the workspace
/// name says nothing rook does not already know — that is the
/// title-as-claim rail, which has no prose to lend.
fn claimTitle(agents: []const Item, ws: []const u8) ?[]const u8 {
    for (agents) |it| {
        if (!it.claims(ws)) continue;
        if (it.name.len == 0 or std.mem.eql(u8, it.name, ws)) continue;
        return it.name;
    }
    return null;
}

/// Let a space rook listed for itself wear the words a producer
/// already used for the work going on in it. True when it did.
///
/// This is the one place a surface reads across the seam, so it is
/// worth being exact about what it does and does not do. `vera-e4126385`
/// is a shorter id, not a meaning, and rook cannot invent the meaning:
/// a task is a producer's vocabulary. But when a fleet pushes an
/// agents row claiming that workspace, rook is already holding the
/// producer's own words for it — it painted them one panel down. So
/// the space row repeats them, verbatim, and the label it displaces
/// moves into the subtitle, where the repo already lives:
///
///     ◌ Name the spaces Vera makes
///       rook · vera-e4126385
///
/// What is *not* borrowed is state. The row keeps `.found` and
/// whatever state it had, which is none: rook still says only that a
/// space is there, and a glance still reads the producer's dot on the
/// agents panel for what is happening in it. Words are repeated;
/// nothing is inferred.
pub fn borrowLabel(row: *Item, agents: []const Item, buf: []u8) bool {
    const title = claimTitle(agents, row.workspace()) orelse return false;
    const label = row.name;
    const repo = spaceRepo(row.workspace());
    // The windows count is what gives way: a title is the better use
    // of one line, and the space still names itself on the other.
    row.sub = if (repo.len > 0 and !std.mem.eql(u8, label, row.workspace()))
        std.fmt.bufPrint(buf, "{s} · {s}", .{ repo, label }) catch label
    else
        label;
    row.name = title;
    return true;
}

pub const Panel = struct {
    title: []const u8,
    /// Right-aligned note in the header row ("grouped").
    note: []const u8 = "",
    items: []const Item = &.{},
    /// The highlighted row, if any. It arrives in the pushed model —
    /// what is *selected* belongs to whoever supplies the items — and
    /// a click moves it until the next push says otherwise.
    cur: ?usize = null,
    /// What an empty panel says instead of nothing at all.
    hint: []const u8 = "nothing pushed",
};

pub const Model = struct {
    spaces: Panel,
    agents: Panel,
    /// The configured accent — a selected row's subtitle wears it.
    accent: Rgb = mauve,
};

/// The two surfaces the rail is made of. `docs/surfaces.md` declares
/// them as two `dock:left` surfaces sharing one dock, which is what
/// the seam down the middle of the panel is.
pub const Surface = enum {
    spaces,
    agents,

    pub fn parse(s: []const u8) ?Surface {
        if (std.mem.eql(u8, s, "spaces")) return .spaces;
        if (std.mem.eql(u8, s, "agents")) return .agents;
        return null;
    }

    pub fn name(self: Surface) []const u8 {
        return switch (self) {
            .spaces => "spaces",
            .agents => "agents",
        };
    }
};

/// Rows one item occupies: a leading gap, the name, the subtitle.
pub const item_rows: u16 = 3;

/// The panel needs at least this much glass to be worth drawing.
pub const min_rows: u16 = 8;

/// Row of the seam between spaces and agents, in a panel `h` tall.
/// The hit test and the painter must agree on this.
pub fn splitRow(h: u16) u16 {
    return h / 2;
}

/// Cell coordinates of the item under a click, or null for a click
/// that landed on a header, a gap, or past the last row. `y` is
/// panel-relative (row 0 is the header).
pub fn hit(p: Panel, y: u16) ?usize {
    if (y == 0) return null;
    const i = (y - 1) / item_rows;
    // row 0 of an item block is its leading gap, not the item
    if ((y - 1) % item_rows == 0) return null;
    return if (i < p.items.len) i else null;
}

/// The row under a click, with everything rook needs to act on it.
pub const Hit = struct {
    row: usize,
    /// Past the pushed rows: a row rook found for itself, so the
    /// cursor on it is rook's to hold rather than a producer's.
    found: bool,
    /// The workspace the row names — `Item.workspace`. Where a click
    /// on it goes, when rook holds a workspace by that name.
    ws: []const u8,
};

/// Hit-test a merged panel: `pushed_n` rows came from a producer and
/// everything after them is rook's own. `y` is panel-relative, as for
/// `hit`.
pub fn hitRow(p: Panel, pushed_n: usize, y: u16) ?Hit {
    const i = hit(p, y) orelse return null;
    return .{ .row = i, .found = i >= pushed_n, .ws = p.items[i].workspace() };
}

// ---- the feed in ----

/// Why a push was refused. A bad frame is answered, never absorbed:
/// whatever is on the glass stays there and the producer hears why.
pub const PushError = error{
    /// Not JSON, or JSON that is not an object.
    BadJson,
    /// A raw newline in the payload. One frame is one line — the
    /// framing of the plugin protocol — and the state feed
    /// republishes these bytes into a line-delimited stream.
    NotOneLine,
    /// No `surface`, or one this build does not draw.
    UnknownSurface,
    /// No `items` array.
    NoItems,
    /// Past `max_frame`. A rail is a couple of dozen rows; a producer
    /// sending more than this has a bug, and holding it would be one.
    TooBig,
    OutOfMemory,
};

/// The plugin protocol's frame cap, unchanged: 1 MiB.
pub const max_frame: usize = 1024 * 1024;

/// The last model pushed to each surface, and the arena it lives in.
///
/// A push swaps a whole panel at once, so its old bytes free at once:
/// one arena per slot, replaced wholesale. Until a new frame parses
/// clean the panel keeps pointing at the previous model, which is
/// what makes a rejected push cost nothing.
pub const Feed = struct {
    gpa: std.mem.Allocator,
    accent: Rgb = mauve,
    spaces: Slot = .{ .title = "spaces" },
    agents: Slot = .{ .title = "agents" },

    pub const Slot = struct {
        /// The header when a push does not name one.
        title: []const u8,
        arena: ?std.heap.ArenaAllocator = null,
        panel: ?Panel = null,
        /// The frame exactly as it arrived. The state feed republishes
        /// it verbatim and never interprets it — a consumer that wants
        /// the fields rook does not paint reads them there.
        raw: []const u8 = "",

        fn view(self: Slot) Panel {
            return self.panel orelse .{ .title = self.title };
        }
    };

    pub fn init(gpa: std.mem.Allocator) Feed {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Feed) void {
        inline for (.{ &self.spaces, &self.agents }) |sl| {
            if (sl.arena) |*a| a.deinit();
            sl.arena = null;
            sl.panel = null;
            sl.raw = "";
        }
    }

    pub fn slot(self: *Feed, s: Surface) *Slot {
        return switch (s) {
            .spaces => &self.spaces,
            .agents => &self.agents,
        };
    }

    pub fn model(self: *const Feed) Model {
        return .{
            .spaces = self.spaces.view(),
            .agents = self.agents.view(),
            .accent = self.accent,
        };
    }

    /// Take one `items.push` frame. Returns the surface it landed on,
    /// so the caller can say what changed.
    pub fn push(self: *Feed, bytes: []const u8) PushError!Surface {
        if (bytes.len > max_frame) return error.TooBig;
        if (std.mem.indexOfAny(u8, bytes, "\n\r") != null) return error.NotOneLine;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const parsed = try parseFrame(a, bytes);
        const raw = try a.dupe(u8, bytes);

        const s = self.slot(parsed.surface);
        if (s.arena) |*old| old.deinit();
        s.arena = arena;
        s.panel = parsed.panel;
        s.raw = raw;
        return parsed.surface;
    }

    /// Move a panel's highlight — what a click does. False when it was
    /// already there or there is nothing to move it to. Rook moves a
    /// cursor; the model still owns what "selected" means, and the
    /// next push takes it back.
    pub fn moveCursor(self: *Feed, s: Surface, i: usize) bool {
        const sl = self.slot(s);
        if (sl.panel == null) return false;
        if (i >= sl.panel.?.items.len) return false;
        if (sl.panel.?.cur != null and sl.panel.?.cur.? == i) return false;
        sl.panel.?.cur = i;
        return true;
    }
};

/// Where the two sources of agent rows meet.
///
/// The agents panel is fed from outside — a producer pushes what it
/// manages — but rook can also *see* an agent: a pane whose foreground
/// program is one the config names (`claude` by default) is a session
/// somebody started, whether or not anything claims it. Those rows are
/// rook's own, about rook's own panes, and they carry `.manual`.
///
/// Pushed rows keep their order and come first: a producer that names
/// a workspace owns that row, whatever the pane table says, so rook's
/// row for that workspace is dropped rather than listed twice. A
/// producer names it with `"workspace"` on the item — its *title* is
/// prose, and matching on prose is what let one agent appear twice,
/// once as the task somebody is running and once as the pane rook
/// found running it. A title still counts as a claim when there is no
/// `workspace`, for a rail that names its rows after workspaces
/// anyway. This is the only merge in the design, and it is one-way —
/// nothing rook finds is ever written back into a producer's model.
pub const Merge = struct {
    items: std.ArrayList(Item) = .empty,
    note_buf: [40]u8 = @splat(0),
    /// A cursor parked on a *found* row. Rook owns cursor motion in
    /// every surface, and a found row is rook's own row, so this is
    /// the one highlight rook holds by itself — the rest still arrives
    /// in a pushed model and goes back to it. Cleared whenever the
    /// rows underneath it move; see `Server.clickSide`.
    cur: ?usize = null,

    pub fn deinit(self: *Merge, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.items = .empty;
    }

    /// The merged panel. Its `items` borrow this Merge, so the result
    /// lives until the next call — one frame, which is what the frame
    /// builder wants.
    pub fn panel(self: *Merge, gpa: std.mem.Allocator, surface: Surface, pushed: Panel, found: []const Item) Panel {
        self.items.clearRetainingCapacity();
        var added: usize = 0;
        var manual: usize = 0;
        // Out of memory leaves the pushed panel exactly as it was:
        // discovery is a bonus row, never a reason to lose the rail.
        self.items.appendSlice(gpa, pushed.items) catch return pushed;
        for (found) |f| {
            // On the identity, never the label: rook's own rows now
            // paint a short name, and a producer claims the workspace
            // by its full one.
            if (claimedIn(pushed.items, f.workspace())) continue;
            self.items.append(gpa, f) catch break;
            added += 1;
            if (f.origin == .manual) manual += 1;
        }
        if (added == 0) return pushed;
        var out = pushed;
        out.items = self.items.items;
        // A cursor rook parked on a found row wins over the pushed
        // one — clicking is how it got there, and the two are kept
        // mutually exclusive by whoever sets them.
        if (self.cur) |c| {
            if (c >= pushed.items.len and c < self.items.items.len) out.cur = c;
        }
        // The header accounts for the rows underneath it: how many are
        // working, and how many nobody is managing. A rail that
        // quietly grew rows should add them up at panel level too.
        // Counted over the merged list, not just the rows rook found —
        // the number a reader checks is about the panel they can see.
        // A producer's own note is never overwritten.
        if (pushed.note.len == 0) {
            var working: usize = 0;
            var unmanaged: usize = 0;
            for (self.items.items) |it| {
                if (it.state == .working) working += 1;
                if (it.origin == .manual) unmanaged += 1;
            }
            // Only the agents panel counts work in flight. A space is
            // a place, not a job: rook holding one says nothing about
            // whether anything is running in it, and a header that
            // claimed otherwise would be summarising the producer's
            // rows rather than accounting for the ones rook added.
            out.note = countNote(
                &self.note_buf,
                if (surface == .agents) working else 0,
                unmanaged,
            );
        }
        return out;
    }
};

/// "2 working · 1 manual" — either half dropped when it is zero, and
/// nothing at all when both are. A zero is not news; a header that
/// reads "0 manual" has spent a line saying so.
fn countNote(buf: []u8, working: usize, manual: usize) []const u8 {
    if (working > 0 and manual > 0)
        return std.fmt.bufPrint(buf, "{d} working · {d} manual", .{ working, manual }) catch "";
    if (working > 0) return std.fmt.bufPrint(buf, "{d} working", .{working}) catch "";
    if (manual > 0) return std.fmt.bufPrint(buf, "{d} manual", .{manual}) catch "";
    return "";
}

/// Does any pushed row claim the workspace `name`?
fn claimedIn(items: []const Item, name: []const u8) bool {
    for (items) |it| {
        if (it.claims(name)) return true;
    }
    return false;
}

const Parsed = struct { surface: Surface, panel: Panel };

fn objStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn objObj(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (o.get(key) orelse return null) {
        .object => |m| m,
        else => null,
    };
}

fn objBool(o: std.json.ObjectMap, key: []const u8) bool {
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

/// One frame of the plugin protocol's list shape:
///
///   {"v":1,"op":"items.push","params":{"surface":"spaces","items":[…]}}
///
/// A reply-shaped frame (`"result"` instead of `"params"`) is taken
/// too: `items.push` carries the same payload as an `items.list`
/// reply, and a producer that already builds replies should not have
/// to build a second shape. Fail open, as the IR always required —
/// an unknown key is skipped in silence and an item rook cannot use
/// is dropped, never the whole frame.
fn parseFrame(a: std.mem.Allocator, bytes: []const u8) PushError!Parsed {
    // .alloc_always: without it a string with nothing to unescape
    // aliases the input, and the input is a frame buffer the reader
    // reuses under us.
    const doc = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    const root = switch (doc.value) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const body = objObj(root, "params") orelse objObj(root, "result") orelse root;

    const sname = objStr(body, "surface") orelse return error.UnknownSurface;
    const surface = Surface.parse(sname) orelse return error.UnknownSurface;

    const arr = switch (body.get("items") orelse return error.NoItems) {
        .array => |x| x,
        else => return error.NoItems,
    };

    var items: std.ArrayList(Item) = .empty;
    var cur: ?usize = null;
    for (arr.items) |v| {
        const o = switch (v) {
            .object => |m| m,
            else => continue,
        };
        // `title` is what the row says; `id` is what a producer keys
        // on, and a fair fallback for a rail that names things after
        // their id anyway. Neither is an identity rook shares — that
        // is `workspace`, and it is what the merge matches on.
        const name = objStr(o, "title") orelse objStr(o, "id") orelse continue;
        if (objBool(o, "current") and cur == null) cur = items.items.len;
        try items.append(a, .{
            .name = name,
            .sub = objStr(o, "subtitle") orelse "",
            .state = State.parse(objStr(o, "state") orelse ""),
            .origin = Origin.parse(objStr(o, "origin") orelse ""),
            .unread = objBool(o, "unread"),
            .ws = objStr(o, "workspace") orelse "",
        });
    }

    return .{
        .surface = surface,
        .panel = .{
            .title = objStr(body, "title") orelse surface.name(),
            .note = objStr(body, "note") orelse "",
            .items = items.items,
            .cur = cur,
            .hint = "no items",
        },
    };
}

/// The herdr screenshot as two frames, so the rail can still be
/// demoed and dialed in without a producer — and so the wire has one
/// worked example that a test checks rather than a README:
///
///     rook side demo | rook side -
pub const demo_frames: []const []const u8 = &.{
    \\{"v":1,"op":"items.push","params":{"surface":"spaces","items":[{"id":"herdr","title":"herdr","subtitle":"master","state":"working"},{"id":"web-dashboard","title":"web-dashboard","subtitle":"feat/usage-charts","state":"blocked","current":true},{"id":"data-pipeline","title":"data-pipeline","subtitle":"backfill/events-v2","state":"idle"}]}}
    ,
    \\{"v":1,"op":"items.push","params":{"surface":"agents","note":"grouped","items":[{"id":"herdr","title":"herdr","subtitle":"working · claude","state":"working"},{"id":"explore","title":"explore","subtitle":"idle · opencode","state":"idle"},{"id":"web-dashboard","title":"web-dashboard","subtitle":"blocked · claude","state":"blocked","current":true},{"id":"data-pipeline","title":"data-pipeline","subtitle":"done · codex","state":"done"}]}}
    ,
};

// ---- the tab bar's vocabulary ----
//
// The row itself is drawn in `server.zig`, which has the pane table it
// needs. What a mark *means* is chrome, and belongs beside the rail's
// states rather than in the server that happens to paint it.

/// What a tab says about its window past its name. The two marks are
/// separate channels from the selection block and from each other —
/// the block means selected and only selected — but they share one
/// cell, so exactly one of them can be showing.
pub const TabMark = enum { none, working, unread };

/// Working outranks unread on that cell: a window you can watch
/// working is not news you missed, and the ◐ is the more useful of the
/// two to a reader deciding where to look.
pub fn tabMark(w: struct {
    current: bool,
    agent: bool,
    last_output_ms: i64,
    seen_ms: i64,
    now: i64,
}) TabMark {
    const last = w.last_output_ms;
    if (last == 0) return .none; // never produced anything
    if (w.agent and w.now - last < working_ms) return .working;
    // The window on the glass is being read as it arrives.
    if (!w.current and last > w.seen_ms) return .unread;
    return .none;
}

/// How long after a batch of output an agent pane still reads as
/// working on the tab bar. The same cadence the agents scan runs on,
/// so the tab and the rail never disagree about whether something is
/// happening in a window.
pub const working_ms: i64 = 2000;

// ---- drawing ----
//
// `f` is a render.Frame; taken as anytype so the panel does not have
// to import the frame builder that imports it.

fn sgrFg(f: anytype, c: Rgb) void {
    f.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}
fn sgrBg(f: anytype, c: Rgb) void {
    f.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Paint `w` cells of `back` at (x, y) and leave the bg set, so
/// whatever is written next inherits it.
fn band(f: anytype, x: u16, y: u16, w: u16, back: Rgb) void {
    f.cup(x, y);
    f.put("\x1b[0m");
    sgrBg(f, back);
    var n: u16 = 0;
    while (n < w) : (n += 1) f.put(" ");
}

/// Write `s` at (x, y), clipped to `w` cells. Assumes the row's band
/// is already painted (so the bg shows through).
fn at(f: anytype, x: u16, y: u16, w: u16, s: []const u8) void {
    if (w == 0) return;
    f.cup(x, y);
    f.put(clip(s, w));
}

/// Display columns of a chrome string.
///
/// Every glyph rook's own chrome draws is one cell — the dots, `↳`,
/// `⋯`, `·`, `⌥`, and ASCII — so the column count is the codepoint
/// count. That is not true of text in general, and this is not for
/// text in general: it is for the strings this file and the tab bar
/// compose, where a byte count is wrong (`⌥n` is four bytes and two
/// columns) and getting it wrong shifts a whole pre-sized row.
pub fn cols(s: []const u8) u16 {
    return @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
}

/// Clip to at most `n` columns, truncated rather than ellipsized.
/// Names arrive from a producer now, so this cuts on a codepoint
/// boundary instead of mid-sequence: a byte count is an upper bound
/// on the cells any UTF-8 needs, so a row can come up short but never
/// overflows its box.
pub fn clip(s: []const u8, n: u16) []const u8 {
    if (s.len <= n) return s;
    var end: usize = n;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

/// Bytes of the ellipsis `fitMiddle` splices in. One column, three
/// bytes, and the byte count is what has to fit the budget.
const ellipsis = "…";

/// Fit `s` into `n` columns by dropping its *middle*, not its tail.
///
/// A rail row's name is prose a producer wrote — "Investigate Vera's
/// /effort" — and prose front-loads its category and back-loads what
/// makes it this one rather than its neighbour. Cutting the tail is
/// therefore the one cut that reliably throws away the distinguishing
/// half: a column of `Investigate Vera'…` / `Investigate Vera'…` is
/// two rows that a glance cannot tell apart. Keeping both ends —
/// `Investigate … /effort` — keeps the part that distinguishes them.
///
/// Below `min_middle` columns there is no honest middle to drop (the
/// ellipsis would cost more than the text it saves), so a name that
/// small falls back to `clip`. The result is written into `buf` and
/// borrows it; `buf` must hold `n` bytes.
pub fn fitMiddle(s: []const u8, n: u16, buf: []u8) []const u8 {
    if (s.len <= n) return s;
    if (n < min_middle or buf.len < n) return clip(s, n);

    const budget = n - ellipsis.len;
    // The tail takes the odd byte: it is the half that distinguishes.
    var head: usize = budget / 2;
    var tail_len: usize = budget - head;

    // Both cuts land on codepoint boundaries. Walking the head end
    // *down* and the tail start *up* can only shorten the result, so
    // it stays inside the box either way.
    while (head > 0 and (s[head] & 0xc0) == 0x80) head -= 1;
    var tail = s.len - tail_len;
    while (tail < s.len and (s[tail] & 0xc0) == 0x80) tail += 1;
    tail_len = s.len - tail;

    @memcpy(buf[0..head], s[0..head]);
    @memcpy(buf[head..][0..ellipsis.len], ellipsis);
    @memcpy(buf[head + ellipsis.len ..][0..tail_len], s[tail..]);
    return buf[0 .. head + ellipsis.len + tail_len];
}

/// Narrower than this and a middle truncation says less than a plain
/// one: `I…t` is not a name.
pub const min_middle: u16 = 8;

/// The whole panel: spaces over agents, split down the middle by a
/// seam, the way the design has it.
pub fn draw(f: anytype, m: Model, x: u16, y: u16, w: u16, h: u16) void {
    if (w < 8 or h < min_rows) return;
    const split = y + splitRow(h);
    drawPanel(f, m.spaces, m.accent, x, y, w, split -| y, false);
    // the seam between the two panels
    band(f, x, split, w, mantle);
    f.cup(x, split);
    sgrFg(f, surface0);
    var n: u16 = 0;
    while (n < w) : (n += 1) f.put("─");
    drawPanel(f, m.agents, m.accent, x, split + 1, w, (y + h) -| (split + 1), true);
    f.put("\x1b[0m");
}

/// The mark an agents row puts in front of its subtitle. That line is
/// the task the agent is running and the space it runs in — metadata
/// *about* the name above it, not more of the name — and one glyph is
/// what keeps a reader from taking the two lines for one sentence.
const assoc_lead = "↳ ";
const assoc_cols: u16 = 2;

/// `assoc` marks this panel's subtitles with `assoc_lead`. Only the
/// agents panel does: a space's second line is its own repo and
/// branch, which is not an association with anything.
fn drawPanel(f: anytype, p: Panel, accent: Rgb, x: u16, y: u16, w: u16, h: u16, assoc: bool) void {
    if (h == 0) return;
    const pad: u16 = 2; // breathing room down the left edge
    // header: the title, and its note pushed to the right edge
    band(f, x, y, w, mantle);
    sgrFg(f, overlay0);
    at(f, x + pad, y, w -| pad, p.title);
    if (p.note.len > 0 and p.note.len + p.title.len + 3 <= w) {
        at(f, x + w - pad - @as(u16, @intCast(p.note.len)), y, w, p.note);
    }

    for (p.items, 0..) |it, i| {
        const top = y + 1 + @as(u16, @intCast(i)) * item_rows;
        if (top + item_rows > y + h) break; // no room for a whole item
        const sel = p.cur != null and p.cur.? == i;
        const back: Rgb = if (sel) base else mantle;
        // the item's band covers its leading gap, name and subtitle,
        // so a selected row reads as one block
        band(f, x, top, w, back);
        band(f, x, top + 1, w, back);
        band(f, x, top + 2, w, back);

        // Name row: the dot, the name, and the row's right edge — an
        // unread mark and the state's own word, right-aligned the way
        // the header's note is. The word is what makes the rail read
        // without a legend; the glyph is what makes it read at a
        // glance. Both, or the dot is a code nobody has the key to.
        const word = it.state.word();
        var right: u16 = @intCast(word.len);
        if (it.unread) right += 2; // "● "
        // One column of air, so a long name never touches the word.
        const gutter: u16 = if (right > 0) right + 1 else 0;
        const name_w = (w -| (pad + 2)) -| gutter;

        f.cup(x + pad, top + 1);
        sgrFg(f, it.state.color());
        f.put(it.dot().glyph());
        sgrFg(f, text);
        f.put("\x1b[1m");
        var name_buf: [256]u8 = undefined;
        const nw: u16 = @min(name_w, @as(u16, name_buf.len));
        at(f, x + pad + 2, top + 1, nw, fitMiddle(it.name, nw, &name_buf));
        f.put("\x1b[22m");

        // The right edge, only when the row is wide enough to hold it
        // without eating the name it is meant to annotate.
        if (right > 0 and pad + 2 + gutter <= w) {
            var rx = x + w - pad - right;
            if (it.unread) {
                sgrFg(f, accent);
                at(f, rx, top + 1, right, unread_dot);
                rx += 2;
            }
            if (word.len > 0) {
                sgrFg(f, it.state.color());
                at(f, rx, top + 1, @intCast(word.len), word);
            }
        }

        // subtitle row, indented under the name. An origin worth
        // saying goes first and stays dim whatever the row is doing —
        // it is the one thing on the row that is not about the work,
        // so it never competes with a state color or the accent.
        const sub_x = x + pad + 2;
        const sub_w = w -| (pad + 2);
        var off: u16 = 0;
        if (it.origin.tagCols() > 0 and it.origin.tagCols() < sub_w) {
            sgrFg(f, overlay0);
            at(f, sub_x, top + 2, sub_w, it.origin.tag());
            off = it.origin.tagCols();
        } else if (assoc and it.sub.len > 0 and assoc_cols < sub_w) {
            // A row that already wears an origin tag has said what its
            // second line is for and never takes both marks.
            sgrFg(f, overlay0);
            at(f, sub_x, top + 2, sub_w, assoc_lead);
            off = assoc_cols;
        }
        // a selected row's plain subtitle takes the accent; a state
        // color (working, blocked, done) already says more than that
        const sub_fg = it.state.subFg();
        sgrFg(f, if (sel and sub_fg.eql(overlay0)) accent else sub_fg);
        at(f, sub_x + off, top + 2, sub_w -| off, it.sub);
    }

    // An empty panel says why it is empty: a rail nothing has pushed
    // to looks exactly like a broken one otherwise.
    var row = y + 1 + @as(u16, @intCast(p.items.len)) * item_rows;
    while (row < y + h) : (row += 1) band(f, x, row, w, mantle);
    if (p.items.len == 0 and h > 2) {
        sgrFg(f, surface0);
        at(f, x + pad, y + 2, w -| pad, p.hint);
    }
    f.put("\x1b[0m");
}

test "hex parse" {
    try std.testing.expectEqual(Rgb{ .r = 0xcb, .g = 0xa6, .b = 0xf7 }, Rgb.parse("#cba6f7").?);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x11, .b = 0x1b }, Rgb.parse("11111b").?);
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#fff"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("cyan"));
    try std.testing.expectEqual(mauve, named("magenta").?);
    try std.testing.expectEqual(teal, named("bright-cyan").?);
    try std.testing.expectEqual(@as(?Rgb, null), named("chartreuse"));
}

test "hit test skips headers and gaps" {
    const p: Panel = .{ .title = "spaces", .items = &.{
        .{ .name = "a" },
        .{ .name = "b" },
        .{ .name = "c" },
    } };
    try std.testing.expectEqual(@as(?usize, null), hit(p, 0)); // header
    try std.testing.expectEqual(@as(?usize, null), hit(p, 1)); // gap
    try std.testing.expectEqual(@as(?usize, 0), hit(p, 2)); // name
    try std.testing.expectEqual(@as(?usize, 0), hit(p, 3)); // sub
    try std.testing.expectEqual(@as(?usize, null), hit(p, 4)); // gap
    try std.testing.expectEqual(@as(?usize, 1), hit(p, 5));
    try std.testing.expectEqual(@as(?usize, 2), hit(p, 8));
    try std.testing.expectEqual(@as(?usize, null), hit(p, 11)); // past the end
}

test "a click on an agent row points at the workspace it runs in" {
    // The fleet's shape: a row titled for the task, the workspace it
    // runs in named outright, and one row rook found for itself after
    // it. Clicking the task must go to `rook--vera-f356bc2c`, not to a
    // workspace named after a sentence.
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const pushed: Panel = .{ .title = "agents", .items = &.{
        .{ .name = "Fix the leader+s workspace", .sub = "working · rook", .ws = "rook--vera-66c854b2" },
        .{ .name = "herdr", .sub = "working · claude" },
    } };
    const found = [_]Item{.{ .name = "scratch", .sub = "claude", .origin = .manual }};
    const p = merge.panel(std.testing.allocator, .agents, pushed, &found);

    const task = hitRow(p, pushed.items.len, 2).?; // the first row's name
    try std.testing.expectEqual(@as(usize, 0), task.row);
    try std.testing.expect(!task.found);
    try std.testing.expectEqualStrings("rook--vera-66c854b2", task.ws);

    // a producer that named no workspace still claims one by title,
    // for a rail whose rows are workspaces anyway
    const titled = hitRow(p, pushed.items.len, 5).?;
    try std.testing.expectEqualStrings("herdr", titled.ws);
    try std.testing.expect(!titled.found);

    // rook's own row: named for its workspace, and rook's to hold a
    // cursor on
    const own = hitRow(p, pushed.items.len, 9).?; // third row's sub
    try std.testing.expectEqual(@as(usize, 2), own.row);
    try std.testing.expect(own.found);
    try std.testing.expectEqualStrings("scratch", own.ws);

    // headers, gaps and the space past the last row ask for nothing
    try std.testing.expectEqual(@as(?Hit, null), hitRow(p, pushed.items.len, 0));
    try std.testing.expectEqual(@as(?Hit, null), hitRow(p, pushed.items.len, 1));
    try std.testing.expectEqual(@as(?Hit, null), hitRow(p, pushed.items.len, 11));
}

test "a row's workspace is its claim, and the two never disagree" {
    const claimed: Item = .{ .name = "Fix the duplicate rows", .ws = "rook--vera-f356bc2c" };
    try std.testing.expectEqualStrings("rook--vera-f356bc2c", claimed.workspace());
    try std.testing.expect(claimed.claims("rook--vera-f356bc2c"));
    try std.testing.expect(!claimed.claims("Fix the duplicate rows"));

    const bare: Item = .{ .name = "scratch" };
    try std.testing.expectEqualStrings("scratch", bare.workspace());
    try std.testing.expect(bare.claims("scratch"));
}

test "an unfed rail is its two headers and nothing else" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    const m = feed.model();
    try std.testing.expectEqualStrings("spaces", m.spaces.title);
    try std.testing.expectEqualStrings("agents", m.agents.title);
    try std.testing.expectEqual(@as(usize, 0), m.spaces.items.len);
    try std.testing.expectEqual(@as(?usize, null), m.spaces.cur);
}

test "the demo frames are the model the panel used to hardcode" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    for (demo_frames) |frame| _ = try feed.push(frame);

    const m = feed.model();
    try std.testing.expectEqual(@as(usize, 3), m.spaces.items.len);
    try std.testing.expectEqualStrings("herdr", m.spaces.items[0].name);
    try std.testing.expectEqualStrings("master", m.spaces.items[0].sub);
    try std.testing.expectEqual(@as(?usize, 1), m.spaces.cur);
    // The states the screenshot's dots stood for. Blocked is yellow,
    // not red: it is an ask, and red is failure-only.
    try std.testing.expectEqual(yellow, m.spaces.items[0].state.color()); // working
    try std.testing.expectEqual(yellow, m.spaces.items[1].state.color()); // blocked
    try std.testing.expectEqual(overlay0, m.spaces.items[2].state.color()); // idle

    try std.testing.expectEqualStrings("agents", m.agents.title);
    try std.testing.expectEqualStrings("grouped", m.agents.note);
    try std.testing.expectEqual(@as(usize, 4), m.agents.items.len);
    try std.testing.expectEqual(@as(?usize, 2), m.agents.cur);
    try std.testing.expectEqual(Dot.hollow, m.agents.items[1].state.shape());
    try std.testing.expectEqual(Dot.waiting, m.agents.items[2].state.shape());
    try std.testing.expectEqual(green, m.agents.items[3].state.subFg()); // done
}

test "a push replaces the surface it names and leaves the other alone" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    for (demo_frames) |frame| _ = try feed.push(frame);

    const s = try feed.push(
        \\{"v":1,"op":"items.push","params":{"surface":"spaces","items":[{"title":"rook","state":"done"}]}}
    );
    try std.testing.expectEqual(Surface.spaces, s);
    const m = feed.model();
    try std.testing.expectEqual(@as(usize, 1), m.spaces.items.len);
    try std.testing.expectEqualStrings("rook", m.spaces.items[0].name);
    try std.testing.expectEqual(@as(?usize, null), m.spaces.cur); // nothing current
    try std.testing.expectEqual(@as(usize, 4), m.agents.items.len); // untouched
}

test "a rejected push leaves what is on the glass alone" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[0]);

    try std.testing.expectError(error.BadJson, feed.push("{not json"));
    try std.testing.expectError(error.BadJson, feed.push("[1,2,3]"));
    try std.testing.expectError(error.UnknownSurface, feed.push(
        \\{"params":{"surface":"weather","items":[]}}
    ));
    try std.testing.expectError(error.UnknownSurface, feed.push(
        \\{"params":{"items":[]}}
    ));
    try std.testing.expectError(error.NoItems, feed.push(
        \\{"params":{"surface":"spaces"}}
    ));
    try std.testing.expectError(error.NotOneLine, feed.push(
        \\{"params":{"surface":"spaces","items":[]}}
    ++ "\n"));
    const huge = try std.testing.allocator.alloc(u8, max_frame + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    try std.testing.expectError(error.TooBig, feed.push(huge));

    const m = feed.model();
    try std.testing.expectEqual(@as(usize, 3), m.spaces.items.len);
    try std.testing.expectEqualStrings("herdr", m.spaces.items[0].name);
}

test "a reply-shaped frame is a push too, and junk items are dropped" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"v":1,"id":7,"ok":true,"result":{"surface":"agents","title":"fleet","items":[{"id":"a","state":"nonsense"},7,{"noTitle":true},{"title":"b","subtitle":"x","state":"failed"}]}}
    );
    const m = feed.model();
    try std.testing.expectEqualStrings("fleet", m.agents.title);
    try std.testing.expectEqual(@as(usize, 2), m.agents.items.len);
    try std.testing.expectEqualStrings("a", m.agents.items[0].name); // id, no title
    try std.testing.expectEqual(State.none, m.agents.items[0].state); // unknown state
    try std.testing.expectEqual(red, m.agents.items[1].state.color());
}

test "an empty items array empties the panel" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[0]);
    _ = try feed.push(
        \\{"params":{"surface":"spaces","items":[]}}
    );
    const m = feed.model();
    try std.testing.expectEqual(@as(usize, 0), m.spaces.items.len);
    try std.testing.expectEqualStrings("no items", m.spaces.hint);
}

test "the model outlives the bytes it was pushed from" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    var buf: [512]u8 = undefined;
    const frame = try std.fmt.bufPrint(&buf,
        \\{{"params":{{"surface":"spaces","items":[{{"title":"{s}"}}]}}}}
    , .{"herdr"});
    _ = try feed.push(frame);
    @memset(&buf, 'z'); // the reader reuses the buffer a frame arrived in
    try std.testing.expectEqualStrings("herdr", feed.model().spaces.items[0].name);
}

test "a click moves the cursor, a push takes it back" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[1]);
    try std.testing.expectEqual(@as(?usize, 2), feed.model().agents.cur);
    try std.testing.expect(feed.moveCursor(.agents, 0));
    try std.testing.expectEqual(@as(?usize, 0), feed.model().agents.cur);
    try std.testing.expect(!feed.moveCursor(.agents, 0)); // already there
    try std.testing.expect(!feed.moveCursor(.agents, 99)); // past the end
    try std.testing.expect(!feed.moveCursor(.spaces, 0)); // never pushed to
    _ = try feed.push(demo_frames[1]);
    try std.testing.expectEqual(@as(?usize, 2), feed.model().agents.cur);
}

test "the frame is kept verbatim for the state feed to republish" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[0]);
    try std.testing.expectEqualStrings(demo_frames[0], feed.spaces.raw);
    try std.testing.expectEqualStrings("", feed.agents.raw);
}

test "origin rides in on a frame and marks the row nobody manages" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"title":"rook","origin":"manual"},{"title":"herdr","subtitle":"working · claude","state":"working"},{"title":"loose","origin":"manual","state":"blocked"},{"title":"odd","origin":"whatever"}]}}
    );
    const it = feed.model().agents.items;
    // a manual row with nothing reporting on it gets the loose dot,
    // not a state's, which would read as running
    try std.testing.expectEqual(Origin.manual, it[0].origin);
    try std.testing.expectEqual(Dot.loose, it[0].dot());
    try std.testing.expectEqual(overlay0, it[0].state.color());
    // the default, and the norm: a pushed row has a producer behind it
    try std.testing.expectEqual(Origin.managed, it[1].origin);
    try std.testing.expectEqual(Dot.working, it[1].dot());
    // origin never overrides a state — the dot still says blocked
    try std.testing.expectEqual(Dot.waiting, it[2].dot());
    try std.testing.expectEqual(yellow, it[2].state.color());
    // an origin rook does not know is managed, not a dropped frame
    try std.testing.expectEqual(Origin.managed, it[3].origin);
}

test "the origin tag's declared width is the width it draws" {
    // tagCols is columns, tag is bytes; the middle dot is two of one
    // and one of the other, and the painter budgets in columns.
    for ([_]Origin{ .managed, .manual, .found }) |o| {
        const cells = std.unicode.utf8CountCodepoints(o.tag()) catch unreachable;
        try std.testing.expectEqual(@as(usize, o.tagCols()), cells);
    }
    try std.testing.expectEqualStrings("", Origin.managed.tag());
}

test "found agents land after pushed rows and never displace one" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    for (demo_frames) |frame| _ = try feed.push(frame);

    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{
        // the producer already names this workspace: its row wins
        .{ .name = "web-dashboard", .sub = "claude", .origin = .manual },
        .{ .name = "scratch", .sub = "claude ×2", .origin = .manual },
    };
    const p = merge.panel(std.testing.allocator, .agents, feed.model().agents, &found);

    try std.testing.expectEqual(@as(usize, 5), p.items.len);
    // the four pushed rows, in order, untouched
    try std.testing.expectEqualStrings("herdr", p.items[0].name);
    try std.testing.expectEqualStrings("data-pipeline", p.items[3].name);
    try std.testing.expectEqual(Origin.managed, p.items[2].origin);
    // then the one nothing claimed
    try std.testing.expectEqualStrings("scratch", p.items[4].name);
    try std.testing.expectEqual(Origin.manual, p.items[4].origin);
    // the highlight still points at the row it pointed at
    try std.testing.expectEqual(@as(?usize, 2), p.cur);
    // the producer said "grouped"; rook does not talk over it
    try std.testing.expectEqualStrings("grouped", p.note);
}

test "a producer claims a workspace by naming it, not by titling a row after it" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    // The shape the fleet actually pushes: the row is titled for the
    // task, and the workspace it runs in is named outright.
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"id":"f356bc2c","title":"Fix the duplicate rows","subtitle":"working · rook","state":"working","workspace":"rook--vera-f356bc2c"}]}}
    );
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("rook--vera-f356bc2c", feed.model().agents.items[0].ws);

    const found = [_]Item{
        // the same session the pushed row is about: claimed, dropped
        .{ .name = "rook--vera-f356bc2c", .sub = "claude", .origin = .manual },
        // a session in another workspace: nobody claims it
        .{ .name = "main", .sub = "claude", .origin = .manual },
    };
    const p = merge.panel(std.testing.allocator, .agents, feed.model().agents, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("Fix the duplicate rows", p.items[0].name);
    try std.testing.expectEqualStrings("main", p.items[1].name);
    try std.testing.expectEqualStrings("1 working · 1 manual", p.note);
}

test "an explicit workspace is the only claim that row makes" {
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    // The title collides with a workspace name, but the producer said
    // which workspace it means — so the collision claims nothing.
    const pushed: Panel = .{ .title = "agents", .items = &.{
        .{ .name = "scratch", .ws = "rook" },
    } };
    const found = [_]Item{
        .{ .name = "scratch", .sub = "claude", .origin = .manual },
        .{ .name = "rook", .sub = "claude", .origin = .manual },
    };
    const p = merge.panel(std.testing.allocator, .agents, pushed, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("scratch", p.items[1].name);
    try std.testing.expectEqual(Origin.manual, p.items[1].origin);
    try std.testing.expectEqualStrings("1 manual", p.note);
}

test "a merged panel accounts for the rows nobody manages" {
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const pushed: Panel = .{ .title = "agents", .items = &.{.{ .name = "herdr" }} };
    const found = [_]Item{
        .{ .name = "rook", .sub = "claude", .origin = .manual },
        .{ .name = "scratch", .sub = "claude", .origin = .manual },
    };
    const p = merge.panel(std.testing.allocator, .agents, pushed, &found);
    try std.testing.expectEqual(@as(usize, 3), p.items.len);
    try std.testing.expectEqualStrings("2 manual", p.note);
}

test "an unfed rail still shows what rook found by itself" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{.{ .name = "rook", .sub = "claude", .origin = .manual }};
    const p = merge.panel(std.testing.allocator, .agents, feed.model().agents, &found);
    try std.testing.expectEqual(@as(usize, 1), p.items.len);
    try std.testing.expectEqualStrings("rook", p.items[0].name);
    try std.testing.expectEqualStrings("agents", p.title);
    try std.testing.expectEqualStrings("1 manual", p.note);
}

test "a click can park on a found row, and a push takes the rail back" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"title":"herdr","current":true}]}}
    );
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{.{ .name = "scratch", .sub = "claude", .origin = .manual }};

    // the pushed highlight, until rook's own cursor says otherwise
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, .agents, feed.model().agents, &found).cur);
    merge.cur = 1;
    try std.testing.expectEqual(@as(?usize, 1), merge.panel(std.testing.allocator, .agents, feed.model().agents, &found).cur);
    // a cursor past the rows there are is no cursor at all
    merge.cur = 9;
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, .agents, feed.model().agents, &found).cur);
    // and it never claims a pushed row — that highlight is the model's
    merge.cur = 0;
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, .agents, feed.model().agents, &found).cur);
}

test "nothing found leaves the pushed panel exactly as it was" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[1]);
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);

    const pushed = feed.model().agents;
    // nothing to add
    var p = merge.panel(std.testing.allocator, .agents, pushed, &.{});
    try std.testing.expectEqual(pushed.items.ptr, p.items.ptr);
    try std.testing.expectEqualStrings("grouped", p.note);
    // everything found is already claimed
    const claimed = [_]Item{.{ .name = "herdr", .origin = .manual }};
    p = merge.panel(std.testing.allocator, .agents, pushed, &claimed);
    try std.testing.expectEqual(pushed.items.len, p.items.len);
    try std.testing.expectEqualStrings("grouped", p.note);
}

test "clip cuts on a codepoint boundary" {
    try std.testing.expectEqualStrings("abc", clip("abc", 8));
    try std.testing.expectEqualStrings("ab", clip("abc", 2));
    try std.testing.expectEqualStrings("", clip("abc", 0));
    // "working · claude": the dot is two bytes, so a clip that lands
    // inside it backs off rather than emitting half a sequence
    try std.testing.expectEqualStrings("working ", clip("working · claude", 9));
    try std.testing.expectEqualStrings("working ·", clip("working · claude", 10));
}

test "workspaces rook holds land on spaces without a manual note" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    // The fleet's spaces row names the workspace it is about; the
    // other workspace is rook's alone.
    _ = try feed.push(
        \\{"params":{"surface":"spaces","items":[{"id":"/x/rook","title":"rook","subtitle":"2 tasks","state":"working","workspace":"main"}]}}
    );
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{
        .{ .name = "main", .origin = .found },
        .{ .name = "testing", .origin = .found },
    };
    const p = merge.panel(std.testing.allocator, .spaces, feed.model().spaces, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("rook", p.items[0].name);
    try std.testing.expectEqualStrings("testing", p.items[1].name);
    try std.testing.expectEqual(Origin.found, p.items[1].origin);
    try std.testing.expectEqual(Dot.loose, p.items[1].dot());
    try std.testing.expectEqualStrings("", p.items[1].origin.tag());
    // A held workspace is not an unmanaged agent, so no "N manual" —
    // and spaces never count work in flight, so the producer's own
    // working row buys no note either.
    try std.testing.expectEqualStrings("", p.note);
}

test "an unfed spaces panel is rook's own workspaces" {
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{ .{ .name = "main", .origin = .found }, .{ .name = "testing", .origin = .found } };
    const p = merge.panel(std.testing.allocator, .spaces, .{ .title = "spaces" }, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("main", p.items[0].name);
    try std.testing.expectEqual(Origin.found, Origin.parse("found"));
}

test "a workspace name splits into the repo and the label it earns" {
    // The name rook makes for a worktree: <repo>--<worktree>.
    try std.testing.expectEqualStrings("vera-e4126385", shortSpace("rook--vera-e4126385"));
    try std.testing.expectEqualStrings("rook", spaceRepo("rook--vera-e4126385"));
    // A workspace that is not a worktree is already as short as it is.
    try std.testing.expectEqualStrings("main", shortSpace("main"));
    try std.testing.expectEqualStrings("", spaceRepo("main"));
    // A worktree of a worktree labels as its leaf: that is the part
    // that tells it from the one it was cut from.
    try std.testing.expectEqualStrings("fix", shortSpace("rook--vera-e4126385--fix"));
    try std.testing.expectEqualStrings("rook--vera-e4126385", spaceRepo("rook--vera-e4126385--fix"));
    // Nothing on one side is not a split; there is no shorter honest
    // form of these, so they are left whole and wear no repo.
    try std.testing.expectEqualStrings("--x", shortSpace("--x"));
    try std.testing.expectEqualStrings("x--", shortSpace("x--"));
    try std.testing.expectEqualStrings("", spaceRepo("--x"));
    try std.testing.expectEqualStrings("", spaceRepo("x--"));
}

test "labelling keeps the workspace as the identity behind it" {
    var items = [_]Item{
        .{ .name = "rook--vera-e4126385", .ws = "rook--vera-e4126385", .origin = .found },
        .{ .name = "rook", .ws = "rook", .origin = .found },
    };
    labelSpaces(&items);
    try std.testing.expectEqualStrings("vera-e4126385", items[0].name);
    try std.testing.expectEqualStrings("rook--vera-e4126385", items[0].workspace());
    // The claim a producer makes is on the workspace, so the short
    // label must not cost the row its claim.
    try std.testing.expect(items[0].claims("rook--vera-e4126385"));
    try std.testing.expect(!items[0].claims("vera-e4126385"));
    try std.testing.expectEqualStrings("rook", items[1].name);
}

test "a label two workspaces would share is given back whole" {
    var items = [_]Item{
        .{ .name = "rook--fix", .ws = "rook--fix", .origin = .found },
        .{ .name = "herdr--fix", .ws = "herdr--fix", .origin = .found },
        .{ .name = "rook--vera-e4126385", .ws = "rook--vera-e4126385", .origin = .found },
    };
    labelSpaces(&items);
    // Both of the pair, not just the second: one short row beside its
    // long twin reads as two unrelated things.
    try std.testing.expectEqualStrings("rook--fix", items[0].name);
    try std.testing.expectEqualStrings("herdr--fix", items[1].name);
    // The row that was never ambiguous keeps its short label.
    try std.testing.expectEqualStrings("vera-e4126385", items[2].name);
}

test "a producer's claim still lands on a row rook labelled short" {
    // The fleet's row for this task, claiming the workspace by name.
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"id":"e4126385","title":"Name the spaces","subtitle":"working · claude","state":"working","workspace":"rook--vera-e4126385"}]}}
    );
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    var found = [_]Item{
        .{ .name = "rook--vera-e4126385", .ws = "rook--vera-e4126385", .sub = "claude", .origin = .manual },
        .{ .name = "rook--vera-f356bc2c", .ws = "rook--vera-f356bc2c", .sub = "claude", .origin = .manual },
    };
    labelSpaces(&found);
    const p = merge.panel(std.testing.allocator, .agents, feed.model().agents, &found);
    // One row for the claimed workspace — the producer's — and rook's
    // own row for the one nobody claimed, wearing its short label.
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("Name the spaces", p.items[0].name);
    try std.testing.expectEqualStrings("vera-f356bc2c", p.items[1].name);
    try std.testing.expectEqualStrings("rook--vera-f356bc2c", p.items[1].workspace());
    try std.testing.expectEqualStrings("1 working · 1 manual", p.note);
}

test "a row that names no workspace is its own identity" {
    // Every found row rook builds carries `ws`, but a pushed one need
    // not, and the merge asks for the identity on both.
    const it: Item = .{ .name = "scratch" };
    try std.testing.expectEqualStrings("scratch", it.workspace());
}

test "a space wears the words a producer used for the agent in it" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    // The fleet's agents rail: a task, claiming the workspace it runs in.
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"id":"e4126385","title":"Name the spaces Vera makes","subtitle":"working · claude","state":"working","workspace":"rook--vera-e4126385"}]}}
    );
    const agents = feed.model().agents.items;

    var row: Item = .{ .name = "rook--vera-e4126385", .ws = "rook--vera-e4126385", .sub = "rook", .origin = .found };
    labelSpaces(@as(*[1]Item, &row));
    var buf: [64]u8 = undefined;
    try std.testing.expect(borrowLabel(&row, agents, &buf));
    try std.testing.expectEqualStrings("Name the spaces Vera makes", row.name);
    // The label it displaced is still on the row, under the repo.
    try std.testing.expectEqualStrings("rook · vera-e4126385", row.sub);
    // The identity never moves: this is still what a click switches to.
    try std.testing.expectEqualStrings("rook--vera-e4126385", row.workspace());
    // Words are repeated; state is not. A space rook found says only
    // that it is there — the agents panel says what is happening.
    try std.testing.expectEqual(State.none, row.state);
    try std.testing.expectEqual(Origin.found, row.origin);
}

test "a space nobody claims keeps the label rook gave it" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"id":"x","title":"Something else","workspace":"herdr--fix"}]}}
    );
    var row: Item = .{ .name = "vera-e4126385", .ws = "rook--vera-e4126385", .sub = "rook", .origin = .found };
    var buf: [64]u8 = undefined;
    try std.testing.expect(!borrowLabel(&row, feed.model().agents.items, &buf));
    try std.testing.expectEqualStrings("vera-e4126385", row.name);
    try std.testing.expectEqualStrings("rook", row.sub);
}

test "a rail that titles its rows after workspaces lends nothing" {
    // The title-as-claim case: the producer's prose *is* the workspace
    // name, so there is nothing to borrow and nothing to displace.
    const agents = [_]Item{.{ .name = "scratch" }};
    var row: Item = .{ .name = "scratch", .ws = "scratch", .origin = .found };
    var buf: [64]u8 = undefined;
    try std.testing.expect(!borrowLabel(&row, &agents, &buf));
    try std.testing.expectEqualStrings("scratch", row.name);
    // An empty title is not a label either.
    const blank = [_]Item{.{ .name = "", .ws = "scratch" }};
    try std.testing.expect(!borrowLabel(&row, &blank, &buf));
}

test "a borrowed label with no repo to name falls back to the label alone" {
    const agents = [_]Item{.{ .name = "Fix the flaky test", .ws = "scratch" }};
    var row: Item = .{ .name = "scratch", .ws = "scratch", .sub = "", .origin = .found };
    var buf: [64]u8 = undefined;
    try std.testing.expect(borrowLabel(&row, &agents, &buf));
    try std.testing.expectEqualStrings("Fix the flaky test", row.name);
    try std.testing.expectEqualStrings("scratch", row.sub);
}

test "a click on a labelled space points at the workspace, not the label" {
    // The seam between two changes: rows wear labels, and a click acts
    // on the workspace a row names. A click must never take a label as
    // an address — including a label borrowed from a producer, which
    // is prose and names no workspace at all.
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    var found = [_]Item{
        .{ .name = "rook--vera-e4126385", .ws = "rook--vera-e4126385", .sub = "rook", .origin = .found },
        .{ .name = "rook", .ws = "rook", .origin = .found },
    };
    labelSpaces(&found);
    const agents = [_]Item{.{ .name = "Name the spaces Vera makes", .ws = "rook--vera-e4126385" }};
    var buf: [64]u8 = undefined;
    try std.testing.expect(borrowLabel(&found[0], &agents, &buf));

    const p = merge.panel(std.testing.allocator, .spaces, .{ .title = "spaces" }, &found);
    const borrowed = hitRow(p, 0, 2).?; // the first row
    try std.testing.expectEqualStrings("Name the spaces Vera makes", p.items[0].name);
    try std.testing.expectEqualStrings("rook--vera-e4126385", borrowed.ws);
    try std.testing.expect(borrowed.found);
    // and the plain row beside it, which was never shortened
    const plain = hitRow(p, 0, 5).?;
    try std.testing.expectEqualStrings("rook", plain.ws);
}

test "red is failure-only, and every state has its own shape and word" {
    // The rule the rail is drawn to: one state per channel. Two states
    // sharing a color taught a glance to read alarm where there was an
    // ask, and two sharing a shape left the color carrying it alone.
    try std.testing.expectEqual(red, State.failed.color());
    for ([_]State{ .none, .working, .idle, .blocked, .done }) |st| {
        try std.testing.expect(!st.color().eql(red));
    }

    // Every state is distinguishable without color at all.
    const states = [_]State{ .none, .working, .idle, .blocked, .done, .failed };
    for (states, 0..) |a, i| {
        for (states[i + 1 ..]) |b| {
            try std.testing.expect(a.shape() != b.shape());
        }
    }

    try std.testing.expectEqualStrings("working", State.working.word());
    try std.testing.expectEqualStrings("needs you", State.blocked.word());
    try std.testing.expectEqualStrings("idle", State.idle.word());
    try std.testing.expectEqualStrings("done", State.done.word());
    try std.testing.expectEqualStrings("failed", State.failed.word());
    // A row with nothing to report spends no columns saying so.
    try std.testing.expectEqualStrings("", State.none.word());
}

test "unread is its own channel and outlives the state on the row" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(
        \\{"params":{"surface":"agents","items":[{"title":"flakes","state":"done","unread":true},{"title":"quiet","state":"done"},{"title":"fresh","unread":true}]}}
    );
    const it = feed.model().agents.items;
    // done *and* unread: the check carries the outcome, the accent dot
    // carries "nobody has looked at it". Collapsing them loses one.
    try std.testing.expect(it[0].unread);
    try std.testing.expectEqual(Dot.done, it[0].dot());
    try std.testing.expect(!it[1].unread);
    try std.testing.expectEqual(Dot.done, it[1].dot());
    // unread says nothing about state, and does not invent one
    try std.testing.expect(it[2].unread);
    try std.testing.expectEqual(State.none, it[2].state);
    // and a row that never mentions it is not unread
    try std.testing.expect(!(Item{ .name = "x" }).unread);
}

test "a long name loses its middle, never its distinguishing tail" {
    var buf: [64]u8 = undefined;

    // Two rows that differ only at the end stay two rows. Tail-cutting
    // is what made them the same row.
    const a = fitMiddle("Investigate Vera's /effort", 22, &buf);
    try std.testing.expect(a.len <= 22);
    try std.testing.expect(std.mem.startsWith(u8, a, "Investiga"));
    try std.testing.expect(std.mem.endsWith(u8, a, "/effort"));
    try std.testing.expect(std.mem.indexOf(u8, a, "…") != null);

    var buf2: [64]u8 = undefined;
    const b = fitMiddle("Investigate Vera's /model", 22, &buf2);
    try std.testing.expect(!std.mem.eql(u8, a, b));

    // A name that fits is returned untouched, and borrows nothing.
    const fits = fitMiddle("short", 22, &buf);
    try std.testing.expectEqualStrings("short", fits);

    // Below `min_middle` an ellipsis costs more than it saves, so the
    // plain cut takes over — and still never overflows its box.
    const tiny = fitMiddle("Investigate Vera's /effort", 5, &buf);
    try std.testing.expect(tiny.len <= 5);
    try std.testing.expect(std.mem.indexOf(u8, tiny, "…") == null);
}

test "middle truncation cuts on codepoint boundaries" {
    // A name that is multibyte throughout: every cut is a chance to
    // split a codepoint and put a replacement glyph on the rail.
    var buf: [64]u8 = undefined;
    var n: u16 = min_middle;
    while (n <= 40) : (n += 1) {
        const out = fitMiddle("héllo wörld — ünicode näme", n, &buf);
        try std.testing.expect(out.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    }
}

test "the merged header adds up the rows underneath it" {
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const pushed: Panel = .{ .title = "agents", .items = &.{
        .{ .name = "scout", .sub = "working · claude", .state = .working, .ws = "rook--vera-a3f2" },
    } };
    const found = [_]Item{.{ .name = "main", .sub = "claude", .origin = .manual }};
    const p = merge.panel(std.testing.allocator, .agents, pushed, &found);
    try std.testing.expectEqualStrings("1 working · 1 manual", p.note);

    // A producer that wrote its own note keeps it — rook counts only
    // where nobody has spoken.
    var mine: Merge = .{};
    defer mine.deinit(std.testing.allocator);
    var said = pushed;
    said.note = "grouped";
    try std.testing.expectEqualStrings("grouped", mine.panel(std.testing.allocator, .agents, said, &found).note);
}

test "a header with nothing to count says nothing" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("", countNote(&buf, 0, 0));
    try std.testing.expectEqualStrings("2 working", countNote(&buf, 2, 0));
    try std.testing.expectEqualStrings("3 manual", countNote(&buf, 0, 3));
    try std.testing.expectEqualStrings("1 working · 1 manual", countNote(&buf, 1, 1));
}

test "a tab's mark is one channel, and the block is not it" {
    const now: i64 = 1_000_000;

    // An agent that just wrote something is working — whether or not
    // you are looking at it. The design puts ◐ on the selected tab.
    try std.testing.expectEqual(TabMark.working, tabMark(.{
        .current = true,
        .agent = true,
        .last_output_ms = now - 100,
        .seen_ms = now,
        .now = now,
    }));

    // A shell echoing keystrokes is not working. Every pane produces
    // output; a ◐ on all of them would say nothing about any of them.
    try std.testing.expectEqual(TabMark.none, tabMark(.{
        .current = false,
        .agent = false,
        .last_output_ms = now - 100,
        .seen_ms = now,
        .now = now,
    }));

    // An agent that went quiet stops claiming to be working, and what
    // it wrote while you were away becomes unread instead.
    try std.testing.expectEqual(TabMark.unread, tabMark(.{
        .current = false,
        .agent = true,
        .last_output_ms = now - working_ms - 1,
        .seen_ms = now - working_ms - 2,
        .now = now,
    }));

    // Output on the window you are looking at is read by definition.
    try std.testing.expectEqual(TabMark.none, tabMark(.{
        .current = true,
        .agent = false,
        .last_output_ms = now - 10,
        .seen_ms = now - 20,
        .now = now,
    }));

    // Anything, agent or not, that wrote while you were elsewhere.
    try std.testing.expectEqual(TabMark.unread, tabMark(.{
        .current = false,
        .agent = false,
        .last_output_ms = now - 10,
        .seen_ms = now - 20,
        .now = now,
    }));

    // Seen since: nothing to report.
    try std.testing.expectEqual(TabMark.none, tabMark(.{
        .current = false,
        .agent = false,
        .last_output_ms = now - 30,
        .seen_ms = now - 20,
        .now = now,
    }));

    // A window that has never produced anything is not unread.
    try std.testing.expectEqual(TabMark.none, tabMark(.{
        .current = false,
        .agent = true,
        .last_output_ms = 0,
        .seen_ms = 0,
        .now = now,
    }));
}

// ---- reading the panel back off the glass ----
//
// `draw` takes its frame as `anytype`, which is what lets a test pass
// one that keeps the cells instead of a client. Everything above this
// point tests the *model*; these tests test the picture, because
// "faithful to the design" is a claim about the picture, and a model
// can be right while the paint that reads it is wrong.

const glass_cols: usize = 40;
const glass_rows: usize = 20;

/// A frame builder that records bytes, and a tiny VT to lay them out.
/// It understands exactly what `draw` emits: absolute cursor moves and
/// SGR runs, which it positions by and ignores respectively.
const Glass = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Glass) void {
        self.bytes.deinit(self.gpa);
    }
    fn put(self: *Glass, b: []const u8) void {
        self.bytes.appendSlice(self.gpa, b) catch unreachable;
    }
    fn print(self: *Glass, comptime fmt: []const u8, args: anytype) void {
        self.bytes.print(self.gpa, fmt, args) catch unreachable;
    }
    fn cup(self: *Glass, x: u16, y: u16) void {
        self.print("\x1b[{d};{d}H", .{ @as(u32, y) + 1, @as(u32, x) + 1 });
    }

    /// Row `y` as it would read on a screen, trailing blanks trimmed.
    fn row(self: *const Glass, y: usize, buf: []u8) []const u8 {
        var cells: [glass_rows][glass_cols][]const u8 = undefined;
        for (&cells) |*r| {
            for (r) |*c| c.* = " ";
        }
        var cx: usize = 0;
        var cy: usize = 0;
        var i: usize = 0;
        const b = self.bytes.items;
        while (i < b.len) {
            if (b[i] == 0x1b and i + 1 < b.len and b[i + 1] == '[') {
                var j = i + 2;
                while (j < b.len and !(b[j] >= 0x40 and b[j] <= 0x7e)) j += 1;
                if (j < b.len and b[j] == 'H') {
                    var it = std.mem.splitScalar(u8, b[i + 2 .. j], ';');
                    cy = (std.fmt.parseInt(usize, it.next() orelse "1", 10) catch 1) - 1;
                    cx = (std.fmt.parseInt(usize, it.next() orelse "1", 10) catch 1) - 1;
                }
                i = j + 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
            if (cy < glass_rows and cx < glass_cols) cells[cy][cx] = b[i .. i + n];
            cx += 1;
            i += n;
        }
        var w: usize = 0;
        for (cells[y]) |c| {
            @memcpy(buf[w..][0..c.len], c);
            w += c.len;
        }
        return std.mem.trimEnd(u8, buf[0..w], " ");
    }
};

test "the rail paints what the reference draws" {
    var g: Glass = .{ .gpa = std.testing.allocator };
    defer g.deinit();

    const spaces: Panel = .{
        .title = "spaces",
        .note = "1 task",
        .items = &.{.{ .name = "vera" }},
        .cur = 0,
    };
    const agents: Panel = .{
        .title = "agents",
        .items = &.{
            .{ .name = "scout", .sub = "Investigate Vera's /effort · vera", .state = .working },
            .{ .name = "main", .sub = "claude", .state = .idle, .origin = .manual },
        },
    };
    draw(&g, .{ .spaces = spaces, .agents = agents }, 0, 0, glass_cols, glass_rows);

    var buf: [512]u8 = undefined;

    // Header: the title left, its count pushed to the right edge.
    const head = g.row(0, &buf);
    try std.testing.expect(std.mem.startsWith(u8, head, "  spaces"));
    try std.testing.expect(std.mem.endsWith(u8, head, "1 task"));

    // A space is a name. With no state to report it spends no column
    // on a dot — which is what leaves ● free to mean unread.
    try std.testing.expectEqualStrings("    vera", g.row(2, &buf));

    // An agent row: the shape on the left, the same state spelled out
    // on the right. The glyph is the glance, the word is what it
    // resolves into, and neither is asked to carry it alone.
    const scout = g.row(13, &buf);
    try std.testing.expect(std.mem.startsWith(u8, scout, "  ◐ scout"));
    try std.testing.expect(std.mem.endsWith(u8, scout, "working"));

    // Its second line is the task and the space — metadata about the
    // name above it, so it is marked as such.
    try std.testing.expectEqualStrings(
        "    ↳ Investigate Vera's /effort · vera",
        g.row(14, &buf),
    );

    // Idle is the quietest row on the rail, and still says so.
    const main_row = g.row(16, &buf);
    try std.testing.expect(std.mem.startsWith(u8, main_row, "  ○ main"));
    try std.testing.expect(std.mem.endsWith(u8, main_row, "idle"));

    // A row nobody manages says so instead of taking the ↳: one mark
    // per line, and this line's job is already spoken for.
    try std.testing.expectEqualStrings("    manual · claude", g.row(17, &buf));
}

test "a painted row never runs into its own state word" {
    var g: Glass = .{ .gpa = std.testing.allocator };
    defer g.deinit();

    const agents: Panel = .{ .title = "agents", .items = &.{
        .{ .name = "Investigate Vera's /effort and everything after it", .state = .working, .unread = true },
    } };
    draw(&g, .{ .spaces = .{ .title = "spaces" }, .agents = agents }, 0, 0, glass_cols, glass_rows);

    var buf: [512]u8 = undefined;
    const r = g.row(13, &buf);
    // Both channels on one row: the state, and the fact that nobody
    // has read it. Neither has eaten the other, or the name.
    try std.testing.expect(std.mem.endsWith(u8, r, "● working"));
    try std.testing.expect(std.mem.startsWith(u8, r, "  ◐ Investiga"));
    // The name kept its tail rather than its middle.
    try std.testing.expect(std.mem.indexOf(u8, r, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "after it") != null);
    // And the whole row still fits the panel it is drawn in.
    try std.testing.expect((std.unicode.utf8CountCodepoints(r) catch 99) <= glass_cols);
}

test "a chrome string measures in columns, not bytes" {
    // The tab bar is built to exactly `avail` columns. Measuring these
    // in bytes overcounts by one per multibyte glyph, and a row that
    // thinks it is wider than it is shifts everything after it.
    try std.testing.expectEqual(@as(u16, 2), cols("⌥n"));
    try std.testing.expectEqual(@as(u16, 13), cols("copy·hjkl y q"));
    try std.testing.expectEqual(@as(u16, 11), cols("copy·VISUAL"));
    try std.testing.expectEqual(@as(u16, 10), cols("  ⋯ 2 more"));
    try std.testing.expectEqual(@as(u16, 4), cols("zoom"));
    try std.testing.expectEqual(@as(u16, 0), cols(""));
}
