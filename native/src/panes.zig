//! Panes: a binary split tree over live sessions (the tmux/rook shape).
//! A Pane owns one Session plus its RenderState and a pixel rect; the
//! tree is layout only — session lifetime and focus live in App. All
//! tree mutation and layout happens under App.draw_lock.

const std = @import("std");
const vt = @import("ghostty-vt");
const sessionpkg = @import("session.zig");
const editorpkg = @import("editor.zig");

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
};

/// What lives inside a pane. The tree, layout, focus, chords, and tabs
/// are all content-agnostic — an editor is just a pane whose fill pass
/// comes from a text buffer instead of an emulator (the rook-buffers
/// model: one scene, different documents).
pub const Content = union(enum) {
    term: Term,
    edit: *editorpkg.Editor,
};

pub const Pane = struct {
    id: u32,
    content: Content,
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
            .edit => null,
        };
    }

    pub fn editor(self: *Pane) ?*editorpkg.Editor {
        return switch (self.content) {
            .term => null,
            .edit => |e| e,
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
