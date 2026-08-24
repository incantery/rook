//! The chrome the engine draws itself — every cell that is not a pane.
//!
//! Two things live here: the palette (Catppuccin Mocha, the colors the
//! herdr design is drawn in) and the side panel, a left rail of
//! *spaces* over *agents*. The panel is app chrome, not a pty: no
//! process backs it, the frame builder paints it straight from a
//! model.
//!
//! Nothing in this file decides what the rail *says*. The model is
//! pushed in from outside — `items.push` frames, the list shape of
//! the plugin protocol (docs/surfaces.md) — and `Feed` holds the last
//! one pushed to each surface. Rook paints; something else supplies.
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

    fn glyph(self: Dot) []const u8 {
        return switch (self) {
            .filled => "●",
            .hollow => "○",
            .ring => "◉",
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
        // their id anyway.
        const name = objStr(o, "title") orelse objStr(o, "id") orelse continue;
        if (objBool(o, "current") and cur == null) cur = items.items.len;
        try items.append(a, .{
            .name = name,
            .sub = objStr(o, "subtitle") orelse "",
            .state = State.parse(objStr(o, "state") orelse ""),
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
        f.put(it.state.shape().glyph());
        sgrFg(f, text);
        f.put("\x1b[1m");
        at(f, x + pad + 2, top + 1, w -| (pad + 2), it.name);
        f.put("\x1b[22m");

        // subtitle row, indented under the name
        // a selected row's plain subtitle takes the accent; a state
        // color (working, blocked, done) already says more than that
        const sub_fg = it.state.subFg();
        sgrFg(f, if (sel and sub_fg.eql(overlay0)) accent else sub_fg);
        at(f, x + pad + 2, top + 2, w -| (pad + 2), it.sub);
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

test "clip cuts on a codepoint boundary" {
    try std.testing.expectEqualStrings("abc", clip("abc", 8));
    try std.testing.expectEqualStrings("ab", clip("abc", 2));
    try std.testing.expectEqualStrings("", clip("abc", 0));
    // "working · claude": the dot is two bytes, so a clip that lands
    // inside it backs off rather than emitting half a sequence
    try std.testing.expectEqualStrings("working ", clip("working · claude", 9));
    try std.testing.expectEqualStrings("working ·", clip("working · claude", 10));
}
