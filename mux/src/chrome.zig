//! The chrome the engine draws itself — every cell that is not a pane.
//!
//! Two things live here: the palette (Catppuccin Mocha, the colors the
//! herdr design is drawn in) and the side panel, a left rail of
//! *spaces* over *agents*. The panel is app chrome, not a pty: no
//! process backs it, the frame builder paints it straight from a
//! model.
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
    filled, // ●  running / present
    hollow, // ○  idle
    ring, // ◉  wants you (blocked on an ask)
    loose, // ◌  nobody is driving it — see Origin

    fn glyph(self: Dot) []const u8 {
        return switch (self) {
            .filled => "●",
            .hollow => "○",
            .ring => "◉",
            .loose => "◌",
        };
    }
};

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

    pub fn color(self: State) Rgb {
        return switch (self) {
            .none => overlay0,
            .working => yellow,
            .idle => green,
            .blocked, .failed => red,
            .done => teal,
        };
    }

    pub fn shape(self: State) Dot {
        return switch (self) {
            .idle => .hollow,
            .blocked => .ring,
            else => .filled,
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
    /// The workspace this row's agent is running in, when the producer
    /// says so (`"workspace"` on a pushed item). A row's *name* is
    /// prose — a task, a branch, a sentence — so it is not an identity
    /// rook can match its own pane table against. This is: it is a
    /// workspace name, rook's own vocabulary, and naming it is how a
    /// producer claims the session rook can see there. Empty means the
    /// producer said nothing, and the name is the only claim it has.
    ws: []const u8 = "",

    /// The workspace this row points at: the explicit `ws` when the
    /// producer named one, else the row's name. A row rook found is
    /// named for its workspace, so this is that workspace either way,
    /// and it is what a click on the row has to act on.
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
    note_buf: [24]u8 = @splat(0),
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
    pub fn panel(self: *Merge, gpa: std.mem.Allocator, pushed: Panel, found: []const Item) Panel {
        self.items.clearRetainingCapacity();
        var added: usize = 0;
        var manual: usize = 0;
        // Out of memory leaves the pushed panel exactly as it was:
        // discovery is a bonus row, never a reason to lose the rail.
        self.items.appendSlice(gpa, pushed.items) catch return pushed;
        for (found) |f| {
            if (claimedIn(pushed.items, f.name)) continue;
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
        // The header says how many rows nobody is managing — a rail
        // that quietly grew rows should account for them at panel
        // level too. A producer's own note is never overwritten.
        if (pushed.note.len == 0 and manual > 0) {
            if (std.fmt.bufPrint(&self.note_buf, "{d} manual", .{manual})) |n| {
                out.note = n;
            } else |_| {}
        }
        return out;
    }
};

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

/// The whole panel: spaces over agents, split down the middle by a
/// seam, the way the design has it.
pub fn draw(f: anytype, m: Model, x: u16, y: u16, w: u16, h: u16) void {
    if (w < 8 or h < min_rows) return;
    const split = y + splitRow(h);
    drawPanel(f, m.spaces, m.accent, x, y, w, split -| y);
    // the seam between the two panels
    band(f, x, split, w, mantle);
    f.cup(x, split);
    sgrFg(f, surface0);
    var n: u16 = 0;
    while (n < w) : (n += 1) f.put("─");
    drawPanel(f, m.agents, m.accent, x, split + 1, w, (y + h) -| (split + 1));
    f.put("\x1b[0m");
}

fn drawPanel(f: anytype, p: Panel, accent: Rgb, x: u16, y: u16, w: u16, h: u16) void {
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

        // name row: the dot, then the name
        f.cup(x + pad, top + 1);
        sgrFg(f, it.state.color());
        f.put(it.dot().glyph());
        sgrFg(f, text);
        f.put("\x1b[1m");
        at(f, x + pad + 2, top + 1, w -| (pad + 2), it.name);
        f.put("\x1b[22m");

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
    const p = merge.panel(std.testing.allocator, pushed, &found);

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
    // the states the screenshot's dots stood for
    try std.testing.expectEqual(yellow, m.spaces.items[0].state.color());
    try std.testing.expectEqual(red, m.spaces.items[1].state.color());
    try std.testing.expectEqual(green, m.spaces.items[2].state.color());

    try std.testing.expectEqualStrings("agents", m.agents.title);
    try std.testing.expectEqualStrings("grouped", m.agents.note);
    try std.testing.expectEqual(@as(usize, 4), m.agents.items.len);
    try std.testing.expectEqual(@as(?usize, 2), m.agents.cur);
    try std.testing.expectEqual(Dot.hollow, m.agents.items[1].state.shape());
    try std.testing.expectEqual(Dot.ring, m.agents.items[2].state.shape());
    try std.testing.expectEqual(teal, m.agents.items[3].state.subFg());
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
    // not `.none`'s filled one, which would read as running
    try std.testing.expectEqual(Origin.manual, it[0].origin);
    try std.testing.expectEqual(Dot.loose, it[0].dot());
    try std.testing.expectEqual(overlay0, it[0].state.color());
    // the default, and the norm: a pushed row has a producer behind it
    try std.testing.expectEqual(Origin.managed, it[1].origin);
    try std.testing.expectEqual(Dot.filled, it[1].dot());
    // origin never overrides a state — the dot still says blocked
    try std.testing.expectEqual(Dot.ring, it[2].dot());
    try std.testing.expectEqual(red, it[2].state.color());
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
    const p = merge.panel(std.testing.allocator, feed.model().agents, &found);

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
    const p = merge.panel(std.testing.allocator, feed.model().agents, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("Fix the duplicate rows", p.items[0].name);
    try std.testing.expectEqualStrings("main", p.items[1].name);
    try std.testing.expectEqualStrings("1 manual", p.note);
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
    const p = merge.panel(std.testing.allocator, pushed, &found);
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
    const p = merge.panel(std.testing.allocator, pushed, &found);
    try std.testing.expectEqual(@as(usize, 3), p.items.len);
    try std.testing.expectEqualStrings("2 manual", p.note);
}

test "an unfed rail still shows what rook found by itself" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{.{ .name = "rook", .sub = "claude", .origin = .manual }};
    const p = merge.panel(std.testing.allocator, feed.model().agents, &found);
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
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, feed.model().agents, &found).cur);
    merge.cur = 1;
    try std.testing.expectEqual(@as(?usize, 1), merge.panel(std.testing.allocator, feed.model().agents, &found).cur);
    // a cursor past the rows there are is no cursor at all
    merge.cur = 9;
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, feed.model().agents, &found).cur);
    // and it never claims a pushed row — that highlight is the model's
    merge.cur = 0;
    try std.testing.expectEqual(@as(?usize, 0), merge.panel(std.testing.allocator, feed.model().agents, &found).cur);
}

test "nothing found leaves the pushed panel exactly as it was" {
    var feed = Feed.init(std.testing.allocator);
    defer feed.deinit();
    _ = try feed.push(demo_frames[1]);
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);

    const pushed = feed.model().agents;
    // nothing to add
    var p = merge.panel(std.testing.allocator, pushed, &.{});
    try std.testing.expectEqual(pushed.items.ptr, p.items.ptr);
    try std.testing.expectEqualStrings("grouped", p.note);
    // everything found is already claimed
    const claimed = [_]Item{.{ .name = "herdr", .origin = .manual }};
    p = merge.panel(std.testing.allocator, pushed, &claimed);
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
    const p = merge.panel(std.testing.allocator, feed.model().spaces, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("rook", p.items[0].name);
    try std.testing.expectEqualStrings("testing", p.items[1].name);
    try std.testing.expectEqual(Origin.found, p.items[1].origin);
    try std.testing.expectEqual(Dot.loose, p.items[1].dot());
    try std.testing.expectEqualStrings("", p.items[1].origin.tag());
    // a held workspace is not an unmanaged agent: no "N manual"
    try std.testing.expectEqualStrings("", p.note);
}

test "an unfed spaces panel is rook's own workspaces" {
    var merge: Merge = .{};
    defer merge.deinit(std.testing.allocator);
    const found = [_]Item{ .{ .name = "main", .origin = .found }, .{ .name = "testing", .origin = .found } };
    const p = merge.panel(std.testing.allocator, .{ .title = "spaces" }, &found);
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expectEqualStrings("main", p.items[0].name);
    try std.testing.expectEqual(Origin.found, Origin.parse("found"));
}
