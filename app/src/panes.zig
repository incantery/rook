//! Panes: a binary split tree over live sessions (the tmux/rook shape).
//! A Pane owns one Session plus its RenderState and a pixel rect; the
//! tree is layout only — session lifetime and focus live in App. All
//! tree mutation and layout happens under App.draw_lock.

const std = @import("std");
const vt = @import("ghostty-vt");
const sessionpkg = @import("session.zig");
const editorpkg = @import("editor.zig");
const monitorpkg = @import("monitor.zig");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A terminal tenant: pty session + its render snapshot.
pub const Term = struct {
    session: *sessionpkg.Session,
    rs: vt.RenderState = .empty,
    /// tmux-style copy mode (<leader>[): keys scroll the viewport
    /// instead of reaching the pty.
    copy_mode: bool = false,
    copy_g: bool = false,
    /// The `/` prompt is open and eating keys. The needle buffer doubles
    /// as what the status bar draws, both while typing and after — a
    /// search you can't see the terms of is one you can't trust `n`.
    search_input: bool = false,
    search_buf: [64]u8 = undefined,
    search_len: usize = 0,
    /// Selected match (1-based) of total, for the bar's `3/17`. Zero
    /// total means no live search; the results themselves live on the
    /// Session, next to the screen they describe.
    search_i: usize = 0,
    search_n: usize = 0,
};

/// What lives inside a pane. The tree, layout, focus, chords, and tabs
/// are all content-agnostic — an editor is just a pane whose fill pass
/// comes from a text buffer instead of an emulator (the rook-buffers
/// model: one scene, different documents).
pub const Content = union(enum) {
    term: Term,
    edit: *editorpkg.Editor,
    /// The resource monitor. A third content kind rather than a side
    /// panel because both its halves are TABLES — numeric columns that
    /// only mean anything side by side — and a 30-column panel turns a
    /// table into a list of truncated titles.
    ///
    /// It fills its grid through the same `fillGrid(cols, rows)`
    /// contract the editor uses, so the pane draws through the editor
    /// fill path and no new render code exists for it.
    monitor: *monitorpkg.Monitor,
};

pub const Pane = struct {
    id: u32,
    content: Content,
    /// A takeover editor's parked shell: `rook edit`/:e on a terminal
    /// pane overlays the editor and stashes the Term here — the session
    /// keeps running underneath. Editor :q restores it (the vim-in-a-
    /// terminal feel; TODO.md's "take over the pane").
    under: ?Term = null,
    rect: Rect = .{},
    cols: u32 = 2,
    rows: u32 = 2,
    /// This frame's slot in the shared cell buffer (in cells, not bytes)
    /// and the dims actually filled there; reassigned by every fill pass.
    buf_off: usize = 0,
    drawn_cols: u32 = 0,
    drawn_rows: u32 = 0,
    dirty: bool = false,
    /// The cursor state (position + visibility) baked into the last
    /// fill. Cursor-only moves (backspace's \b, arrows) dirty no row
    /// anywhere in the emulator — this is the only record that the
    /// on-screen cursor is now stale.
    drawn_cursor: u32 = 0xffff_ffff,

    pub fn term(self: *Pane) ?*Term {
        return switch (self.content) {
            .term => |*t| t,
            .edit, .monitor => null,
        };
    }

    pub fn editor(self: *Pane) ?*editorpkg.Editor {
        return switch (self.content) {
            .edit => |e| e,
            .term, .monitor => null,
        };
    }

    pub fn monitor(self: *Pane) ?*monitorpkg.Monitor {
        return switch (self.content) {
            .monitor => |m| m,
            .term, .edit => null,
        };
    }
};

pub const Node = union(enum) {
    leaf: *Pane,
    split: *Split,
};

/// A tab: one split tree of panes plus its own focus. Only the active
/// tab is snapshotted and drawn — background tabs' sessions keep
/// parsing (the emulator advances) but cost zero render work until
/// they're shown again.
pub const Tab = struct {
    id: u32,
    root: Node,
    panes: std.ArrayListUnmanaged(*Pane) = .empty,
    focused: *Pane,
    /// A pane in this tab rang the bell while you weren't looking at it.
    /// Drawn as a dot on the chip and cleared when the tab is selected —
    /// the point is to say WHERE attention is owed, which a dock bounce
    /// alone can't.
    bell: bool = false,
    /// OSC 9;4 progress, aggregated from this tab's panes on the HUD
    /// tick: -1 none, 0..100 a percentage, -2 running without a number
    /// (indeterminate). Worn on the chip beside the title — the point
    /// is an agent's progress in a tab you are NOT on.
    progress: i8 = -1,
    /// tmux zoom: this pane temporarily owns the whole tab area. The
    /// TREE IS UNTOUCHED — zoom is a display state, not a layout, so
    /// unzooming is exact by construction rather than by remembering
    /// ratios. Cleared whenever the thing it points at could go stale
    /// (the pane closes, focus moves, a split arrives).
    zoomed: ?*Pane = null,
};

/// A workspace SESSION — tmux's session, rook's workspace: its own
/// full set of tabs (windows) with its own active tab. Switching
/// workspaces swaps the whole window's contents; background spaces'
/// shells keep running at zero render cost, exactly like background
/// tabs. Spaces are created lazily by the palette and collapse when
/// their last tab closes.
pub const Space = struct {
    /// Registry name; empty = the scratch space (cwd matched nothing).
    name: [24]u8 = undefined,
    name_len: usize = 0,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    active_tab: usize = 0,

    pub fn label(self: *const Space) []const u8 {
        return if (self.name_len > 0) self.name[0..self.name_len] else "scratch";
    }

    pub fn setName(self: *Space, name: []const u8) void {
        const n = @min(name.len, self.name.len);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = n;
    }
};

pub const Split = struct {
    /// true = panes side by side (a left, b right); false = stacked.
    horiz: bool,
    ratio: f32 = 0.5,
    a: Node,
    b: Node,
};

/// Assign rects: walk the tree dividing `rect`, leaving `sep` pixels of
/// gap at every split boundary.
pub fn layout(node: Node, rect: Rect, sep: f32) void {
    switch (node) {
        .leaf => |p| p.rect = rect,
        .split => |s| {
            if (s.horiz) {
                const aw = @max(1, @floor((rect.w - sep) * s.ratio));
                layout(s.a, .{ .x = rect.x, .y = rect.y, .w = aw, .h = rect.h }, sep);
                layout(s.b, .{ .x = rect.x + aw + sep, .y = rect.y, .w = @max(1, rect.w - aw - sep), .h = rect.h }, sep);
            } else {
                const ah = @max(1, @floor((rect.h - sep) * s.ratio));
                layout(s.a, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = ah }, sep);
                layout(s.b, .{ .x = rect.x, .y = rect.y + ah + sep, .w = rect.w, .h = @max(1, rect.h - ah - sep) }, sep);
            }
        },
    }
}

/// Lay out a tab, honouring zoom.
///
/// A zoomed tab gives the zoomed pane the whole area and every other
/// pane a ZERO rect. Zero is load-bearing: it is what the draw, the
/// hit test and the resize all already read as "nothing here" — a
/// hidden pane can't be clicked, can't be drawn, and (because relayout
/// skips it) keeps the grid size it had, so unzooming costs no reflow.
pub fn layoutTab(t: *Tab, rect: Rect, sep: f32) void {
    const z = t.zoomed orelse return layout(t.root, rect, sep);
    for (t.panes.items) |p| p.rect = .{};
    z.rect = rect;
}

/// Replace target's leaf with a split of (target, new_pane). Returns
/// false if target isn't in this subtree.
pub fn splitAt(gpa: std.mem.Allocator, node: *Node, target: *Pane, new_pane: *Pane, horiz: bool) bool {
    switch (node.*) {
        .leaf => |p| {
            if (p != target) return false;
            const s = gpa.create(Split) catch return false;
            s.* = .{ .horiz = horiz, .a = .{ .leaf = target }, .b = .{ .leaf = new_pane } };
            node.* = .{ .split = s };
            return true;
        },
        .split => |s| {
            return splitAt(gpa, &s.a, target, new_pane, horiz) or
                splitAt(gpa, &s.b, target, new_pane, horiz);
        },
    }
}

/// The split whose IMMEDIATE child is `pane`'s leaf — the one whose
/// ratio decides how much room the pane keeps. Null for the root leaf.
pub fn splitOf(node: *Node, pane: *Pane) ?*Split {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if ((s.a == .leaf and s.a.leaf == pane) or
                (s.b == .leaf and s.b.leaf == pane)) return s;
            return splitOf(&s.a, pane) orelse splitOf(&s.b, pane);
        },
    }
}

/// Remove target's leaf, promoting its sibling. Returns false if target
/// isn't in this subtree (or the subtree is just target's leaf — the
/// caller handles the last-pane case).
pub fn removeAt(gpa: std.mem.Allocator, node: *Node, target: *Pane) bool {
    switch (node.*) {
        .leaf => return false,
        .split => |s| {
            const promote: ?Node = if (s.a == .leaf and s.a.leaf == target)
                s.b
            else if (s.b == .leaf and s.b.leaf == target)
                s.a
            else
                null;
            if (promote) |sibling| {
                node.* = sibling;
                gpa.destroy(s);
                return true;
            }
            return removeAt(gpa, &s.a, target) or removeAt(gpa, &s.b, target);
        },
    }
}

/// The Split whose separator contains (x, y), within `slop` px of the
/// gap — the mouse target for ratio drags. Depth-first; innermost wins.
pub fn hitSeparator(node: Node, x: f32, y: f32, slop: f32) ?*Split {
    switch (node) {
        .leaf => return null,
        .split => |s| {
            if (hitSeparator(s.a, x, y, slop)) |inner| return inner;
            if (hitSeparator(s.b, x, y, slop)) |inner| return inner;
            const ar = rectOf(s.a);
            const br = rectOf(s.b);
            if (s.horiz) {
                const x0 = ar.x + ar.w - slop;
                const x1 = br.x + slop;
                if (x >= x0 and x <= x1 and y >= ar.y and y <= ar.y + ar.h) return s;
            } else {
                const y0 = ar.y + ar.h - slop;
                const y1 = br.y + slop;
                if (y >= y0 and y <= y1 and x >= ar.x and x <= ar.x + ar.w) return s;
            }
            return null;
        },
    }
}

/// The union rect a split divides (both children + the gap).
pub fn splitRect(s: *const Split) Rect {
    const ar = rectOf(s.a);
    const br = rectOf(s.b);
    return .{
        .x = @min(ar.x, br.x),
        .y = @min(ar.y, br.y),
        .w = @max(ar.x + ar.w, br.x + br.w) - @min(ar.x, br.x),
        .h = @max(ar.y + ar.h, br.y + br.h) - @min(ar.y, br.y),
    };
}

pub const NavDir = enum { left, right, up, down };

/// Geometric focus navigation: nearest pane whose rect lies in `dir`
/// from `from`, preferring the one overlapping it most on the cross axis.
pub fn navigate(panes: []const *Pane, from: *Pane, dir: NavDir) ?*Pane {
    var best: ?*Pane = null;
    var best_dist: f32 = std.math.floatMax(f32);
    var best_overlap: f32 = -1;
    for (panes) |p| {
        if (p == from) continue;
        const dist: f32 = switch (dir) {
            .left => from.rect.x - (p.rect.x + p.rect.w),
            .right => p.rect.x - (from.rect.x + from.rect.w),
            .up => from.rect.y - (p.rect.y + p.rect.h),
            .down => p.rect.y - (from.rect.y + from.rect.h),
        };
        if (dist < -1) continue; // wrong side (allow separator slop)
        const overlap: f32 = switch (dir) {
            .left, .right => @min(from.rect.y + from.rect.h, p.rect.y + p.rect.h) - @max(from.rect.y, p.rect.y),
            .up, .down => @min(from.rect.x + from.rect.w, p.rect.x + p.rect.w) - @max(from.rect.x, p.rect.x),
        };
        if (overlap <= 0) continue;
        if (dist < best_dist - 1 or (dist < best_dist + 1 and overlap > best_overlap)) {
            best = p;
            best_dist = dist;
            best_overlap = overlap;
        }
    }
    return best;
}

/// Collect every split boundary as a separator rect (the gap layout()
/// left between children). Fixed buffer, no allocation — overflow just
/// drops the deepest separators.
pub fn collectSeparators(node: Node, out: []Rect, n: *usize) void {
    switch (node) {
        .leaf => {},
        .split => |s| {
            if (n.* < out.len) {
                const ar = rectOf(s.a);
                const br = rectOf(s.b);
                out[n.*] = if (s.horiz)
                    .{ .x = ar.x + ar.w, .y = ar.y, .w = br.x - (ar.x + ar.w), .h = ar.h }
                else
                    .{ .x = ar.x, .y = ar.y + ar.h, .w = ar.w, .h = br.y - (ar.y + ar.h) };
                n.* += 1;
            }
            collectSeparators(s.a, out, n);
            collectSeparators(s.b, out, n);
        },
    }
}

pub fn rectOf(node: Node) Rect {
    return switch (node) {
        .leaf => |p| p.rect,
        .split => |s| blk: {
            const ar = rectOf(s.a);
            const br = rectOf(s.b);
            const x = @min(ar.x, br.x);
            const y = @min(ar.y, br.y);
            break :blk .{
                .x = x,
                .y = y,
                .w = @max(ar.x + ar.w, br.x + br.w) - x,
                .h = @max(ar.y + ar.h, br.y + br.h) - y,
            };
        },
    };
}
