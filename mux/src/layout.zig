//! A binary split tree over pane ids, resolved to cell rects on demand.
//! tmux vocabulary: split -h is side-by-side, -v is stacked.
const std = @import("std");

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Placed = struct { pane: u32, rect: Rect };

const Node = union(enum) {
    leaf: u32, // pane id
    split: struct {
        side_by_side: bool, // true: children left|right; false: top/bottom
        ratio: f32,
        a: *Node,
        b: *Node,
    },
};

pub const Layout = struct {
    gpa: std.mem.Allocator,
    root: ?*Node = null,

    pub fn init(gpa: std.mem.Allocator) Layout {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Layout) void {
        if (self.root) |r| self.free(r);
        self.root = null;
    }

    fn free(self: *Layout, n: *Node) void {
        if (n.* == .split) {
            self.free(n.split.a);
            self.free(n.split.b);
        }
        self.gpa.destroy(n);
    }

    fn leaf(self: *Layout, pane: u32) !*Node {
        const n = try self.gpa.create(Node);
        n.* = .{ .leaf = pane };
        return n;
    }

    /// Add the first pane.
    pub fn seed(self: *Layout, pane: u32) !void {
        self.root = try self.leaf(pane);
    }

    /// Split the leaf holding `at`, putting `new` beside/below it.
    pub fn split(self: *Layout, at: u32, new: u32, side_by_side: bool) !void {
        const n = self.find(self.root orelse return error.Empty, at) orelse return error.NotFound;
        const a = try self.leaf(n.leaf);
        errdefer self.gpa.destroy(a);
        const b = try self.leaf(new);
        n.* = .{ .split = .{ .side_by_side = side_by_side, .ratio = 0.5, .a = a, .b = b } };
    }

    fn find(self: *Layout, n: *Node, pane: u32) ?*Node {
        switch (n.*) {
            .leaf => |p| return if (p == pane) n else null,
            .split => |s| return self.find(s.a, pane) orelse self.find(s.b, pane),
        }
    }

    /// Does this tree hold the pane?
    pub fn contains(self: *Layout, pane: u32) bool {
        const r = self.root orelse return false;
        return self.find(r, pane) != null;
    }

    /// Any leaf, for refocusing after a removal.
    pub fn firstLeaf(self: *Layout) ?u32 {
        var n = self.root orelse return null;
        while (n.* == .split) n = n.split.a;
        return n.leaf;
    }

    /// Remove a pane; its sibling takes the whole split. Returns false
    /// when the tree is empty afterwards.
    pub fn remove(self: *Layout, pane: u32) bool {
        const root = self.root orelse return false;
        if (root.* == .leaf) {
            if (root.leaf == pane) {
                self.gpa.destroy(root);
                self.root = null;
                return false;
            }
            return true;
        }
        _ = self.removeIn(root, pane);
        return true;
    }

    fn removeIn(self: *Layout, n: *Node, pane: u32) bool {
        if (n.* != .split) return false;
        const s = n.split;
        inline for (.{ .{ s.a, s.b }, .{ s.b, s.a } }) |pair| {
            const child, const sibling = pair;
            if (child.* == .leaf and child.leaf == pane) {
                n.* = sibling.*;
                self.gpa.destroy(child);
                self.gpa.destroy(sibling);
                return true;
            }
        }
        return self.removeIn(s.a, pane) or self.removeIn(s.b, pane);
    }

    /// Resolve pane rects for a region. Splits cost one border column/row.
    pub fn place(self: *Layout, region: Rect, out: *std.ArrayList(Placed)) !void {
        if (self.root) |r| try placeNode(r, region, self.gpa, out);
    }

    fn placeNode(n: *Node, r: Rect, gpa: std.mem.Allocator, out: *std.ArrayList(Placed)) !void {
        switch (n.*) {
            .leaf => |p| try out.append(gpa, .{ .pane = p, .rect = r }),
            .split => |s| {
                if (s.side_by_side) {
                    const aw: u16 = @intFromFloat(@as(f32, @floatFromInt(r.w -| 1)) * s.ratio);
                    const bw = (r.w -| 1) -| aw;
                    try placeNode(s.a, .{ .x = r.x, .y = r.y, .w = aw, .h = r.h }, gpa, out);
                    try placeNode(s.b, .{ .x = r.x + aw + 1, .y = r.y, .w = bw, .h = r.h }, gpa, out);
                } else {
                    const ah: u16 = @intFromFloat(@as(f32, @floatFromInt(r.h -| 1)) * s.ratio);
                    const bh = (r.h -| 1) -| ah;
                    try placeNode(s.a, .{ .x = r.x, .y = r.y, .w = r.w, .h = ah }, gpa, out);
                    try placeNode(s.b, .{ .x = r.x, .y = r.y + ah + 1, .w = r.w, .h = bh }, gpa, out);
                }
            },
        }
    }
};

/// Directional focus over resolved rects: the nearest pane whose edge
/// faces the focused one's.
pub fn navigate(placed: []const Placed, from: u32, dx: i32, dy: i32) ?u32 {
    var cur: ?Rect = null;
    for (placed) |p| {
        if (p.pane == from) cur = p.rect;
    }
    const c = cur orelse return null;
    const ccx: i32 = @as(i32, c.x) + c.w / 2;
    const ccy: i32 = @as(i32, c.y) + c.h / 2;
    var best: ?u32 = null;
    var best_d: i32 = std.math.maxInt(i32);
    for (placed) |p| {
        if (p.pane == from) continue;
        const px: i32 = @as(i32, p.rect.x) + p.rect.w / 2;
        const py: i32 = @as(i32, p.rect.y) + p.rect.h / 2;
        const vx = px - ccx;
        const vy = py - ccy;
        // must lie in the asked direction
        if (dx != 0 and std.math.sign(vx) != dx) continue;
        if (dy != 0 and std.math.sign(vy) != dy) continue;
        if (dx != 0 and @abs(vy) > @abs(vx)) continue;
        if (dy != 0 and @abs(vx) > @abs(vy)) continue;
        const d: i32 = @intCast(@abs(vx) + @abs(vy));
        if (d < best_d) {
            best_d = d;
            best = p.pane;
        }
    }
    return best;
}

test "split, place, remove" {
    var l = Layout.init(std.testing.allocator);
    defer l.deinit();
    try l.seed(1);
    try l.split(1, 2, true);
    try l.split(2, 3, false);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    try l.place(.{ .x = 0, .y = 0, .w = 80, .h = 24 }, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    // right of pane 1 is one of the two right-hand panes (nearest
    // center wins; here that is 3), and 2/3 see each other vertically
    const right = navigate(out.items, 1, 1, 0);
    try std.testing.expect(right == 2 or right == 3);
    try std.testing.expectEqual(@as(?u32, 3), navigate(out.items, 2, 0, 1));
    try std.testing.expectEqual(@as(?u32, 2), navigate(out.items, 3, 0, -1));
    _ = l.remove(2);
    out.clearRetainingCapacity();
    try l.place(.{ .x = 0, .y = 0, .w = 80, .h = 24 }, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
