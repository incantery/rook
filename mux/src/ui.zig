//! The design system: semantic roles over the palette, and the few
//! primitives every piece of chrome is built from.
//!
//! Nothing outside this file names a palette color. A bar, a figure,
//! a border or a field asks the theme for a *role* — `chrome`,
//! `raised`, `primary`, `muted`, `border`, `accent`, `working` — and
//! draws with a primitive that knows the grammar: a tab is an index,
//! a label and a mark inside one boundary; a scope chip is the space
//! you are in, or the system; a module is a word on the calm bar. The
//! rules the roles enforce (`docs/ui-design-system.md`): the accent
//! is not selection, selection is not focus, activity is not unread,
//! attention is rare and strongest, calm things wear no glyph, and no
//! state is told by color alone.
//!
//! Two output shapes take the primitives: a bounded byte list (the
//! bars, pre-sized to their row) and a `render.Frame` (everything
//! painted at a position). Both expose `put`, so the primitives take
//! `anytype`.
const std = @import("std");
const chromepkg = @import("chrome.zig");

pub const Rgb = chromepkg.Rgb;

// The palette steps the older chrome did not name. Catppuccin Mocha,
// like the rest of `chrome.zig`.
pub const surface1: Rgb = .{ .r = 0x45, .g = 0x47, .b = 0x5a };
pub const surface2: Rgb = .{ .r = 0x58, .g = 0x5b, .b = 0x70 };
pub const overlay1: Rgb = .{ .r = 0x7f, .g = 0x84, .b = 0x9c };
pub const subtext0: Rgb = .{ .r = 0xa6, .g = 0xad, .b = 0xc8 };

/// Glyph vocabulary: the Unicode marks, or an ASCII fallback for a
/// glass that cannot show them. The hierarchy survives either way.
pub const Glyphs = enum { unicode, ascii };

/// The ends of a chip or a tab. The last three are Nerd Font glyphs.
pub const Cap = enum {
    plain,
    bracket,
    powerline,
    round,
    slant,

    pub fn parse(s: []const u8) Cap {
        return std.meta.stringToEnum(Cap, s) orelse .plain;
    }

    /// The left and right ends, or null for plain padding.
    pub fn ends(self: Cap) ?[2][]const u8 {
        return switch (self) {
            .plain => null,
            .bracket => .{ "[", "]" },
            .powerline => .{ "\u{e0b2}", "\u{e0b0}" },
            .round => .{ "\u{e0b6}", "\u{e0b4}" },
            .slant => .{ "\u{e0ba}", "\u{e0bc}" },
        };
    }
};

/// The semantic roles. One instance per server, built from the
/// palette and the configured accent; every chrome painter reads it.
pub const Theme = struct {
    // ---- surfaces, from the ground up
    /// the work surface: panes keep the terminal's own background
    /// (transparency included); chrome never paints this
    work: Rgb = chromepkg.base,
    /// persistent chrome — both bars, the altitude canvas. Opaque, so
    /// it reads as chrome over any wallpaper.
    chrome: Rgb = chromepkg.mantle,
    /// elevated chrome — a chip, a field, an overlay's interior, the
    /// selected tab's fill. One step up from `chrome`.
    raised: Rgb = chromepkg.surface0,
    /// a selected row's band: bounded, low contrast, one more step
    selection: Rgb = surface1,

    // ---- ink
    primary: Rgb = chromepkg.text,
    secondary: Rgb = subtext0,
    muted: Rgb = chromepkg.overlay0,
    disabled: Rgb = surface2,
    on_accent: Rgb = chromepkg.crust,

    // ---- edges
    border_subtle: Rgb = chromepkg.surface0,
    border: Rgb = surface1,
    /// the focused pane's edge, the selected figure's edge
    border_focused: Rgb = chromepkg.mauve,

    /// the one accent: scope, focus, the prompt, the selected tab's
    /// edge. Never a fill behind text except the global scope chip.
    accent: Rgb = chromepkg.mauve,

    // ---- states, each with a glyph as well as an ink
    working: Rgb = chromepkg.yellow,
    waiting: Rgb = chromepkg.peach,
    success: Rgb = chromepkg.green,
    warning: Rgb = chromepkg.peach,
    err: Rgb = chromepkg.red,
    /// a program asked for you: a bell, a notification, a producer's
    /// `waiting`. The strongest state, and rare.
    attention: Rgb = chromepkg.red,
    /// output you have not seen. Softer than attention, and never the
    /// accent, so it cannot be mistaken for selection.
    unread: Rgb = chromepkg.blue,

    glyphs: Glyphs = .unicode,

    // ---- shape (style.zig sets these from the stylesheet)
    /// the scope chip's fill and ink
    chip_bg: Rgb = chromepkg.surface0,
    chip_fg: Rgb = chromepkg.text,
    /// the caps on the scope chip and on the selected tab
    chip_cap: Cap = .plain,
    tab_cap: Cap = .plain,
    /// between the chip and the tabs; "" is none (null: the glyph's)
    separator: ?[]const u8 = null,
    /// what the bars' empty cells are drawn with
    fill: []const u8 = " ",

    pub fn init(accent: Rgb, glyphs: Glyphs) Theme {
        return .{ .accent = accent, .border_focused = accent, .glyphs = glyphs };
    }

    /// The same theme under a scrim: every ink and every fill pulled
    /// most of the way to the chrome ground, which stays where it is.
    /// The bars and the canvas wear this while a popup is the one lit
    /// plane, so nothing outside it competes — the same pull the
    /// panes get (render.Paint.scrim), on chrome's own ground.
    pub fn under(self: Theme) Theme {
        var t = self;
        inline for (std.meta.fields(Theme)) |f| {
            if (f.type == Rgb and !std.mem.eql(u8, f.name, "chrome") and !std.mem.eql(u8, f.name, "work")) {
                @field(t, f.name) = toward(@field(self, f.name), self.chrome, 55);
            }
        }
        return t;
    }
};

/// A colour pulled `pct` of the way to another.
pub fn toward(c: Rgb, to: Rgb, pct: u16) Rgb {
    const mix = struct {
        fn f(a: u8, b: u8, p: u16) u8 {
            return @intCast((@as(u16, a) * (100 - p) + @as(u16, b) * p) / 100);
        }
    }.f;
    return .{ .r = mix(c.r, to.r, pct), .g = mix(c.g, to.g, pct), .b = mix(c.b, to.b, pct) };
}

/// A mark: the exceptional state a tab, a pane or a row carries.
/// Calm is `.none`, and calm draws nothing.
pub const Mark = enum {
    none,
    working,
    waiting,
    unread,
    attention,
    failed,
    /// finished, well: a work item that is done, an action that ran
    success,

    /// Priority when several apply: attention outranks everything —
    /// a program asked — then work in flight, then unread.
    pub fn outranks(self: Mark, other: Mark) bool {
        return self.rank() > other.rank();
    }
    fn rank(self: Mark) u8 {
        return switch (self) {
            .none => 0,
            .success => 0,
            .unread => 1,
            .waiting => 2,
            .working => 3,
            .failed => 4,
            .attention => 5,
        };
    }
};

pub fn markGlyph(t: *const Theme, m: Mark) []const u8 {
    return switch (t.glyphs) {
        .unicode => switch (m) {
            .none => "",
            .working => "◐",
            .waiting => "◌",
            .unread => "•",
            .attention => "!",
            .failed => "✕",
            .success => "✓",
        },
        .ascii => switch (m) {
            .none => "",
            .working => "*",
            .waiting => "o",
            .unread => ".",
            .attention => "!",
            .failed => "x",
            .success => "+",
        },
    };
}

pub fn markInk(t: *const Theme, m: Mark) Rgb {
    return switch (m) {
        .none => t.muted,
        .working => t.working,
        .waiting => t.waiting,
        .unread => t.unread,
        .attention => t.attention,
        .failed => t.err,
        .success => t.success,
    };
}

/// Chrome's other glyphs, with their ASCII forms.
pub const Glyph = enum { separator, marker, prompt, back, pin, companion, more, plus, arrow_to, edge, home };

pub fn glyph(t: *const Theme, g: Glyph) []const u8 {
    return switch (t.glyphs) {
        .unicode => switch (g) {
            .separator => "│",
            .marker => "▸",
            .prompt => "›",
            .back => "↩",
            .pin => "⊕",
            .companion => "✦",
            .more => "⋯",
            .plus => "+",
            .arrow_to => "›",
            .edge => "▎",
            .home => "⌂",
        },
        .ascii => switch (g) {
            .separator => "|",
            .marker => ">",
            .prompt => ">",
            .back => "<-",
            .pin => "@",
            .companion => "*",
            .more => "..",
            .plus => "+",
            .arrow_to => ">",
            .edge => "|",
            .home => "~",
        },
    };
}

/// A style, emitted as one SGR sequence. `underline` is a colored
/// underline (SGR 4 + 58): the one sub-cell primitive a terminal
/// gives us, used for the selected tab's edge. A glass without it
/// shows a plain underline, which still reads as selected.
pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    underline: ?Rgb = null,

    pub fn sgr(self: Style, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll("\x1b[0") catch return "\x1b[0m";
        if (self.bold) w.writeAll(";1") catch {};
        if (self.fg) |c| w.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
        if (self.bg) |c| w.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
        if (self.underline) |c| w.print(";4;58;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
        w.writeAll("m") catch {};
        return w.buffered();
    }
};

/// Put a style, then text. Returns the columns the text takes.
pub fn ink(out: anytype, st: Style, s: []const u8) u16 {
    var b: [64]u8 = undefined;
    out.put(st.sgr(&b));
    out.put(s);
    return chromepkg.cols(s);
}

/// A bounded byte list as an output: the shape the bars compose into.
pub const Buf = struct {
    list: *std.ArrayList(u8),
    pub fn put(self: Buf, s: []const u8) void {
        self.list.appendSliceBounded(s) catch {};
    }
};

// ---- the scope chip ----

/// The scope chip. The system's is the one place the accent is a
/// fill — confident, bounded, and only at altitude. A space's is the
/// same shape one step up from the chrome: bounded, quiet, never the
/// accent, so a space named `rook` and the system never look alike.
/// Returns the columns spent.
pub fn scopeChip(out: anytype, t: *const Theme, name: []const u8) u16 {
    const st: Style = .{ .fg = t.chip_fg, .bg = t.chip_bg, .bold = true };
    var n: u16 = 0;
    if (t.chip_cap.ends()) |e| {
        // a cap is the chip's fill on the bar's ground; a bracket is
        // the accent's, around a padded chip
        const cap: Style = if (t.chip_cap == .bracket) .{ .fg = t.accent, .bg = t.chrome } else .{ .fg = t.chip_bg, .bg = t.chrome };
        n += ink(out, cap, e[0]);
        n += ink(out, st, " ");
        n += ink(out, st, name);
        n += ink(out, st, " ");
        n += ink(out, cap, e[1]);
        return n;
    }
    n += ink(out, st, " ");
    n += ink(out, st, name);
    n += ink(out, st, " ");
    return n;
}

/// The separator between the scope and what it holds: ` │ ` in the
/// muted ink on the chrome.
pub fn separator(out: anytype, t: *const Theme, on: Rgb) u16 {
    const g = t.separator orelse glyph(t, .separator);
    var n: u16 = 0;
    n += ink(out, .{ .fg = t.muted, .bg = on }, " ");
    if (g.len > 0) {
        n += ink(out, .{ .fg = t.muted, .bg = on }, g);
        n += ink(out, .{ .fg = t.muted, .bg = on }, " ");
    }
    return n;
}

// ---- the tab ----

/// A tab: an index, a stable label, an optional actor, and a mark.
/// One component, one boundary.
/// A tab's own colour (`[[style.tab]]`): its fill and text when it is
/// the selected one, its ink when it is not.
pub const TabColour = struct { fill: Rgb, text: Rgb, inactive: Rgb };

pub const Tab = struct {
    /// the stylesheet's colour for this tab; null is rook's own look
    colour: ?TabColour = null,
    /// 1–9, shown on the bar; null in a figure
    index: ?u8 = null,
    label: []const u8,
    /// the actor that claimed a pane in it, after the label
    actor: []const u8 = "",
    mark: Mark = .none,
    selected: bool = false,
};

/// How much of a tab to draw: the truncation ladder, top to bottom.
pub const Fit = enum {
    /// everything
    full,
    /// no actor
    no_actor,
    /// the label cut short (the selected tab keeps its whole label)
    short,
    /// index and mark only, for tabs that are not selected
    collapsed,
};

pub const short_label: u16 = 8;

/// Columns a tab takes at a fit, without drawing it.
pub fn tabWidth(t: *const Theme, tb: Tab, fit: Fit) u16 {
    var n: u16 = 2; // the padding either side
    if (tb.selected and t.tab_cap.ends() != null) n += 2;
    if (tb.index != null) n += 2; // "1 "
    const collapsed = fit == .collapsed and !tb.selected;
    if (!collapsed) {
        const label_w = chromepkg.cols(tb.label);
        n += if (fit == .short and !tb.selected) @min(label_w, short_label) else label_w;
        if (fit == .full and tb.actor.len > 0 and !std.mem.eql(u8, tb.actor, tb.label)) n += 3 + chromepkg.cols(tb.actor);
    }
    if (tb.mark != .none) n += 1 + chromepkg.cols(markGlyph(t, tb.mark));
    return n;
}

/// Draw a tab on the bar. The selected tab is a raised fill with the
/// accent edge under the whole chip — index, label, mark — so the
/// boundary is one thing. Inactive tabs are secondary ink on the
/// chrome, their index muted. A calm tab has no glyph. Returns the
/// columns spent (the same as `tabWidth`).
pub fn tab(out: anytype, t: *const Theme, tb: Tab, fit: Fit) u16 {
    // a tab with a colour of its own: filled in it when selected (no
    // edge — the fill is the edge), inked in it toned down when not
    if (tb.colour) |tc| return tabColoured(out, t, tb, fit, tc);
    const bg: Rgb = if (tb.selected) t.raised else t.chrome;
    const edge: ?Rgb = if (tb.selected) t.accent else null;
    const pad: Style = .{ .bg = bg, .underline = edge };
    var n: u16 = 0;
    const caps = if (tb.selected) t.tab_cap.ends() else null;
    const cap_st: Style = if (t.tab_cap == .bracket) .{ .fg = t.accent, .bg = t.chrome } else .{ .fg = bg, .bg = t.chrome };
    if (caps) |e| n += ink(out, cap_st, e[0]);
    n += ink(out, pad, " ");
    if (tb.index) |i| {
        var ib: [2]u8 = .{ '0' + i, ' ' };
        n += ink(out, .{ .fg = if (tb.selected) t.secondary else t.muted, .bg = bg, .underline = edge }, &ib);
    }
    const collapsed = fit == .collapsed and !tb.selected;
    if (!collapsed) {
        const label = if (fit == .short and !tb.selected) chromepkg.clip(tb.label, short_label) else tb.label;
        n += ink(out, .{ .fg = if (tb.selected) t.primary else t.secondary, .bg = bg, .bold = tb.selected, .underline = edge }, label);
        if (fit == .full and tb.actor.len > 0 and !std.mem.eql(u8, tb.actor, tb.label)) {
            n += ink(out, .{ .fg = t.muted, .bg = bg, .underline = edge }, " · ");
            n += ink(out, .{ .fg = if (tb.selected) t.primary else t.secondary, .bg = bg, .underline = edge }, tb.actor);
        }
    }
    if (tb.mark != .none) {
        n += ink(out, pad, " ");
        n += ink(out, .{ .fg = markInk(t, tb.mark), .bg = bg, .bold = tb.mark == .attention, .underline = edge }, markGlyph(t, tb.mark));
    }
    n += ink(out, pad, " ");
    if (caps) |e| n += ink(out, cap_st, e[1]);
    return n;
}

fn tabColoured(out: anytype, t: *const Theme, tb: Tab, fit: Fit, tc: TabColour) u16 {
    const bg: Rgb = if (tb.selected) tc.fill else t.chrome;
    const fg: Rgb = if (tb.selected) tc.text else tc.inactive;
    const pad: Style = .{ .bg = bg };
    var n: u16 = 0;
    const caps = if (tb.selected) t.tab_cap.ends() else null;
    const cap_st: Style = if (t.tab_cap == .bracket) .{ .fg = tc.fill, .bg = t.chrome } else .{ .fg = bg, .bg = t.chrome };
    if (caps) |e| n += ink(out, cap_st, e[0]);
    n += ink(out, pad, " ");
    if (tb.index) |i| {
        var ib: [2]u8 = .{ '0' + i, ' ' };
        n += ink(out, .{ .fg = fg, .bg = bg }, &ib);
    }
    const collapsed = fit == .collapsed and !tb.selected;
    if (!collapsed) {
        const label = if (fit == .short and !tb.selected) chromepkg.clip(tb.label, short_label) else tb.label;
        n += ink(out, .{ .fg = fg, .bg = bg, .bold = tb.selected }, label);
        if (fit == .full and tb.actor.len > 0 and !std.mem.eql(u8, tb.actor, tb.label)) {
            n += ink(out, .{ .fg = fg, .bg = bg }, " · ");
            n += ink(out, .{ .fg = fg, .bg = bg }, tb.actor);
        }
    }
    if (tb.mark != .none) {
        n += ink(out, pad, " ");
        // a mark keeps its state's ink, except on the fill it would sink into
        const mk = if (tb.selected) tc.text else markInk(t, tb.mark);
        n += ink(out, .{ .fg = mk, .bg = bg, .bold = tb.mark == .attention }, markGlyph(t, tb.mark));
    }
    n += ink(out, pad, " ");
    if (caps) |e| n += ink(out, cap_st, e[1]);
    return n;
}

/// The gap between tabs on the bar, in columns.
pub const tab_gap: u16 = 1;

/// A tab inside a figure: no index, no underline, the selected one on
/// the raised fill. The same anatomy at a denser weight.
pub fn tabDense(out: anytype, t: *const Theme, tb: Tab, on: Rgb) u16 {
    const bg: Rgb = if (tb.selected) t.raised else on;
    var n: u16 = 0;
    n += ink(out, .{ .bg = bg }, " ");
    n += ink(out, .{ .fg = if (tb.selected) t.primary else t.secondary, .bg = bg }, tb.label);
    if (tb.actor.len > 0 and !std.mem.eql(u8, tb.actor, tb.label)) {
        n += ink(out, .{ .fg = t.muted, .bg = bg }, " · ");
        n += ink(out, .{ .fg = if (tb.selected) t.primary else t.secondary, .bg = bg }, tb.actor);
    }
    if (tb.mark != .none) {
        n += ink(out, .{ .bg = bg }, " ");
        n += ink(out, .{ .fg = markInk(t, tb.mark), .bg = bg, .bold = tb.mark == .attention }, markGlyph(t, tb.mark));
    }
    n += ink(out, .{ .bg = bg }, " ");
    return n;
}

// ---- the calm bar's modules ----

/// A word on the calm bar, in a role's ink.
pub fn module(out: anytype, t: *const Theme, s: []const u8, fg: Rgb, bold: bool) u16 {
    return ink(out, .{ .fg = fg, .bg = t.chrome, .bold = bold }, s);
}

/// The dot between modules.
pub fn moduleSep(out: anytype, t: *const Theme) u16 {
    return ink(out, .{ .fg = t.muted, .bg = t.chrome }, " · ");
}

/// A count with its mark: `◐ 2`, `!1`, `•3`. Attention and unread
/// bind the glyph to the number; work leaves a breath.
pub fn countModule(out: anytype, t: *const Theme, m: Mark, n: usize) u16 {
    var nb: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&nb, "{d}", .{n}) catch "?";
    var w: u16 = 0;
    const st: Style = .{ .fg = markInk(t, m), .bg = t.chrome, .bold = m == .attention };
    w += ink(out, st, markGlyph(t, m));
    if (m == .working or m == .waiting) w += ink(out, st, " ");
    w += ink(out, st, num);
    return w;
}

/// A small chip on the chrome — the pending prefix, the gate's actor.
pub fn chip(out: anytype, t: *const Theme, s: []const u8, fg: Rgb) u16 {
    var n: u16 = 0;
    n += ink(out, .{ .fg = fg, .bg = t.raised, .bold = true }, " ");
    n += ink(out, .{ .fg = fg, .bg = t.raised, .bold = true }, s);
    n += ink(out, .{ .fg = fg, .bg = t.raised, .bold = true }, " ");
    return n;
}

/// A line of chrome, padded to `cols` with the chrome ground.
pub fn padTo(out: anytype, t: *const Theme, vis: u16, cols: u16) void {
    var b: [64]u8 = undefined;
    out.put((Style{ .bg = t.chrome }).sgr(&b));
    var i = vis;
    while (i < cols) : (i += 1) out.put(" ");
    out.put("\x1b[0m");
}

/// The bar's ground from here to `to`: the fill, in the border's ink.
pub fn fillTo(out: anytype, t: *const Theme, vis: u16, to: u16) u16 {
    var b: [64]u8 = undefined;
    out.put((Style{ .fg = t.border, .bg = t.chrome }).sgr(&b));
    var i = vis;
    while (i < to) : (i += 1) out.put(t.fill);
    return to -| vis;
}

// ---- boxes and rows, for frames ----

/// The edge a box wears.
pub const Edge = enum { subtle, normal, focused };

pub fn edgeInk(t: *const Theme, e: Edge) Rgb {
    return switch (e) {
        .subtle => t.border_subtle,
        .normal => t.border,
        .focused => t.border_focused,
    };
}

test "under a scrim the chrome's inks fade to its ground, and the ground stays" {
    const t: Theme = .{};
    const u = t.under();
    try std.testing.expectEqual(t.chrome, u.chrome);
    try std.testing.expect(!std.meta.eql(t.primary, u.primary));
    try std.testing.expect(!std.meta.eql(t.attention, u.attention));
    // faded, not gone: a mark's ink is still not the ground
    try std.testing.expect(!std.meta.eql(u.attention, u.chrome));
    try std.testing.expectEqual(t.glyphs, u.glyphs);
}

test "a tab's width is what it draws, at every fit" {
    const t = Theme.init(chromepkg.mauve, .unicode);
    const L = struct {
        list: std.ArrayList(u8),
        fn put(self: *@This(), s: []const u8) void {
            self.list.appendSliceBounded(s) catch {};
        }
    };
    var buf: [512]u8 = undefined;
    const tb: Tab = .{ .index = 2, .label = "deploy", .actor = "main", .mark = .working, .selected = true };
    inline for (.{ Fit.full, Fit.no_actor, Fit.short, Fit.collapsed }) |fit| {
        var l: L = .{ .list = .initBuffer(&buf) };
        const drawn = tab(&l, &t, tb, fit);
        try std.testing.expectEqual(tabWidth(&t, tb, fit), drawn);
    }
    // " 2 deploy · main ◐ " is 19 columns
    try std.testing.expectEqual(@as(u16, 19), tabWidth(&t, tb, .full));
    // the selected tab keeps its label when others collapse
    try std.testing.expectEqual(@as(u16, 12), tabWidth(&t, tb, .collapsed));
    const other: Tab = .{ .index = 3, .label = "implementation", .mark = .none };
    try std.testing.expectEqual(@as(u16, 4), tabWidth(&t, other, .collapsed)); // " 3  "
    try std.testing.expectEqual(@as(u16, 12), tabWidth(&t, other, .short)); // " 3 implemen "
    // a calm tab has no glyph: no columns for one
    try std.testing.expectEqual(@as(u16, 18), tabWidth(&t, other, .full));
}

test "marks: attention outranks work outranks unread, and ascii has a glyph for each" {
    try std.testing.expect(Mark.attention.outranks(.working));
    try std.testing.expect(Mark.working.outranks(.unread));
    try std.testing.expect(!Mark.none.outranks(.unread));
    const a = Theme.init(chromepkg.mauve, .ascii);
    inline for (.{ Mark.working, Mark.waiting, Mark.unread, Mark.attention, Mark.failed }) |m| {
        try std.testing.expect(markGlyph(&a, m).len == 1);
    }
    try std.testing.expectEqualStrings("", markGlyph(&a, .none));
}

test "the chip wears the theme's chip colours, and its caps" {
    var t = Theme.init(chromepkg.mauve, .unicode);
    const L = struct {
        list: std.ArrayList(u8),
        fn put(self: *@This(), s: []const u8) void {
            self.list.appendSliceBounded(s) catch {};
        }
    };
    var b1: [256]u8 = undefined;
    var plain: L = .{ .list = .initBuffer(&b1) };
    try std.testing.expectEqual(@as(u16, 6), scopeChip(&plain, &t, "rook"));
    try std.testing.expect(std.mem.indexOf(u8, plain.list.items, "48;2;203;166;247") == null);
    t.chip_bg = t.accent;
    t.chip_cap = .powerline;
    var b2: [256]u8 = undefined;
    var capped: L = .{ .list = .initBuffer(&b2) };
    try std.testing.expectEqual(@as(u16, 8), scopeChip(&capped, &t, "rook"));
    try std.testing.expect(std.mem.indexOf(u8, capped.list.items, "48;2;203;166;247") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped.list.items, "\u{e0b0}") != null);
}
