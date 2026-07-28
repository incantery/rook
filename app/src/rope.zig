//! Rope — the editor's text storage (Seth's call: rope from day one,
//! no storage migration later). Byte-indexed UTF-8 with a newline
//! metric summed up the tree, so offset⇄line queries are O(log n).
//!
//! Shape: binary tree over owned leaf chunks (≤ leaf_max bytes).
//! Mutations are recursive descent with metric fix-up on unwind; no
//! rotations — when the height drifts past what a balanced tree of
//! this size should have, the whole tree is rebuilt bottom-up (edits
//! are localized in practice, rebuilds are rare and O(n)). No
//! structural sharing: undo stores text, not tree snapshots.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const leaf_max = 2048;

const Node = union(enum) {
    leaf: Leaf,
    inner: Inner,
};

const Leaf = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    nls: usize = 0, // newline count, cached (leaves are small but hot)
};

const Inner = struct {
    l: *Node,
    r: *Node,
    bytes: usize,
    nls: usize,
    height: u8,
};

fn nodeBytes(n: *const Node) usize {
    return switch (n.*) {
        .leaf => |l| l.data.items.len,
        .inner => |i| i.bytes,
    };
}

fn nodeNls(n: *const Node) usize {
    return switch (n.*) {
        .leaf => |l| l.nls,
        .inner => |i| i.nls,
    };
}

fn nodeHeight(n: *const Node) u8 {
    return switch (n.*) {
        .leaf => 0,
        .inner => |i| i.height,
    };
}

fn countNls(bytes: []const u8) usize {
    var n: usize = 0;
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
        n += 1;
        rest = rest[i + 1 ..];
    }
    return n;
}

fn refreshInner(i: *Inner) void {
    i.bytes = nodeBytes(i.l) + nodeBytes(i.r);
    i.nls = nodeNls(i.l) + nodeNls(i.r);
    i.height = @max(nodeHeight(i.l), nodeHeight(i.r)) + 1;
}

pub const Rope = struct {
    root: *Node,

    pub fn init(gpa: Allocator, bytes: []const u8) Allocator.Error!Rope {
        return .{ .root = try build(gpa, bytes) };
    }

    pub fn deinit(self: *Rope, gpa: Allocator) void {
        freeNode(gpa, self.root);
    }

    pub fn byteLen(self: *const Rope) usize {
        return nodeBytes(self.root);
    }

    /// Number of lines (a trailing newline opens a final empty line,
    /// same as every editor's model).
    pub fn lineCount(self: *const Rope) usize {
        return nodeNls(self.root) + 1;
    }

    pub fn insert(self: *Rope, gpa: Allocator, off: usize, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        std.debug.assert(off <= self.byteLen());
        self.root = try insertNode(gpa, self.root, off, text);
        try self.maybeRebuild(gpa);
    }

    pub fn delete(self: *Rope, gpa: Allocator, start: usize, end: usize) Allocator.Error!void {
        std.debug.assert(start <= end and end <= self.byteLen());
        if (start == end) return;
        deleteNode(gpa, self.root, start, end);
        self.root = collapse(gpa, self.root);
        try self.maybeRebuild(gpa);
    }

    /// Copy [start, end) into out (out.len must be end-start).
    pub fn copyRange(self: *const Rope, start: usize, end: usize, out: []u8) void {
        std.debug.assert(start <= end and end <= self.byteLen());
        std.debug.assert(out.len == end - start);
        var w: usize = 0;
        copyNode(self.root, start, end, out, &w);
        std.debug.assert(w == out.len);
    }

    pub fn dupeRange(self: *const Rope, gpa: Allocator, start: usize, end: usize) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, end - start);
        self.copyRange(start, end, out);
        return out;
    }

    /// Byte offset where `line` (0-based) starts.
    pub fn lineStart(self: *const Rope, line: usize) usize {
        std.debug.assert(line < self.lineCount());
        if (line == 0) return 0;
        return self.offsetOfNewline(line - 1) + 1;
    }

    /// Byte offset where `line` ends (exclusive, before its newline).
    pub fn lineEnd(self: *const Rope, line: usize) usize {
        std.debug.assert(line < self.lineCount());
        if (line < nodeNls(self.root)) return self.offsetOfNewline(line);
        return self.byteLen();
    }

    /// Which line contains byte offset `off` (off == byteLen → last line).
    pub fn lineOfOffset(self: *const Rope, off: usize) usize {
        std.debug.assert(off <= self.byteLen());
        var line: usize = 0;
        var rem = off;
        var n = self.root;
        while (true) switch (n.*) {
            .leaf => |l| return line + countNls(l.data.items[0..rem]),
            .inner => |i| {
                const lb = nodeBytes(i.l);
                if (rem <= lb) {
                    n = i.l;
                } else {
                    line += nodeNls(i.l);
                    rem -= lb;
                    n = i.r;
                }
            },
        };
    }

    /// Offset of the k-th newline (0-based, k < total newlines).
    fn offsetOfNewline(self: *const Rope, k: usize) usize {
        std.debug.assert(k < nodeNls(self.root));
        var off: usize = 0;
        var rem = k;
        var n = self.root;
        while (true) switch (n.*) {
            .leaf => |l| {
                var idx: usize = 0;
                var seen: usize = 0;
                while (true) {
                    const i = std.mem.indexOfScalar(u8, l.data.items[idx..], '\n').?;
                    if (seen == rem) return off + idx + i;
                    seen += 1;
                    idx += i + 1;
                }
            },
            .inner => |i| {
                const ln = nodeNls(i.l);
                if (rem < ln) {
                    n = i.l;
                } else {
                    off += nodeBytes(i.l);
                    rem -= ln;
                    n = i.r;
                }
            },
        };
    }

    /// Rebuild bottom-up when the tree degenerates. Height of a
    /// balanced tree over L leaves is ~log2(L); we allow 2x + slack.
    fn maybeRebuild(self: *Rope, gpa: Allocator) Allocator.Error!void {
        const h: usize = nodeHeight(self.root);
        const est_leaves = self.byteLen() / (leaf_max / 2) + 1;
        if (h <= 2 * std.math.log2(est_leaves + 1) + 4) return;
        const flat = try self.dupeRange(gpa, 0, self.byteLen());
        defer gpa.free(flat);
        const fresh = try build(gpa, flat);
        freeNode(gpa, self.root);
        self.root = fresh;
    }
};

fn newLeaf(gpa: Allocator, bytes: []const u8) Allocator.Error!*Node {
    const n = try gpa.create(Node);
    errdefer gpa.destroy(n);
    n.* = .{ .leaf = .{} };
    try n.leaf.data.appendSlice(gpa, bytes);
    n.leaf.nls = countNls(bytes);
    return n;
}

/// Build a balanced tree over `bytes`, leaves filled to leaf_max.
fn build(gpa: Allocator, bytes: []const u8) Allocator.Error!*Node {
    if (bytes.len <= leaf_max) return newLeaf(gpa, bytes);
    // Split at a leaf-count midpoint so the tree comes out balanced.
    const nleaves = (bytes.len + leaf_max - 1) / leaf_max;
    const mid = (nleaves / 2) * leaf_max;
    const l = try build(gpa, bytes[0..mid]);
    errdefer freeNode(gpa, l);
    const r = try build(gpa, bytes[mid..]);
    errdefer freeNode(gpa, r);
    const n = try gpa.create(Node);
    n.* = .{ .inner = .{ .l = l, .r = r, .bytes = 0, .nls = 0, .height = 0 } };
    refreshInner(&n.inner);
    return n;
}

fn freeNode(gpa: Allocator, n: *Node) void {
    switch (n.*) {
        .leaf => |*l| l.data.deinit(gpa),
        .inner => |i| {
            freeNode(gpa, i.l);
            freeNode(gpa, i.r);
        },
    }
    gpa.destroy(n);
}

fn insertNode(gpa: Allocator, n: *Node, off: usize, text: []const u8) Allocator.Error!*Node {
    switch (n.*) {
        .leaf => |*l| {
            try l.data.insertSlice(gpa, off, text);
            l.nls += countNls(text);
            if (l.data.items.len <= leaf_max) return n;
            // Overflowed: rebuild this leaf as a balanced subtree.
            const fresh = try build(gpa, l.data.items);
            l.data.deinit(gpa);
            gpa.destroy(n);
            return fresh;
        },
        .inner => |*i| {
            const lb = nodeBytes(i.l);
            // <= sends appends at a boundary left, keeping left leaves full.
            if (off <= lb) {
                i.l = try insertNode(gpa, i.l, off, text);
            } else {
                i.r = try insertNode(gpa, i.r, off - lb, text);
            }
            refreshInner(i);
            return n;
        },
    }
}

fn deleteNode(gpa: Allocator, n: *Node, start: usize, end: usize) void {
    switch (n.*) {
        .leaf => |*l| {
            l.nls -= countNls(l.data.items[start..end]);
            l.data.replaceRangeAssumeCapacity(start, end - start, "");
        },
        .inner => |*i| {
            const lb = nodeBytes(i.l);
            if (start < lb) deleteNode(gpa, i.l, start, @min(end, lb));
            if (end > lb) deleteNode(gpa, i.r, @max(start, lb) - lb, end - lb);
            refreshInner(i);
        },
    }
}

/// Drop empty subtrees left behind by delete (a node whose child has
/// zero bytes is replaced by the other child).
fn collapse(gpa: Allocator, n: *Node) *Node {
    switch (n.*) {
        .leaf => return n,
        .inner => |*i| {
            i.l = collapse(gpa, i.l);
            i.r = collapse(gpa, i.r);
            if (nodeBytes(i.l) == 0) {
                const keep = i.r;
                freeNode(gpa, i.l);
                gpa.destroy(n);
                return keep;
            }
            if (nodeBytes(i.r) == 0) {
                const keep = i.l;
                freeNode(gpa, i.r);
                gpa.destroy(n);
                return keep;
            }
            refreshInner(i);
            return n;
        },
    }
}

fn copyNode(n: *const Node, start: usize, end: usize, out: []u8, w: *usize) void {
    switch (n.*) {
        .leaf => |l| {
            const s = l.data.items[start..end];
            @memcpy(out[w.*..][0..s.len], s);
            w.* += s.len;
        },
        .inner => |i| {
            const lb = nodeBytes(i.l);
            if (start < lb) copyNode(i.l, start, @min(end, lb), out, w);
            if (end > lb) copyNode(i.r, @max(start, lb) - lb, end - lb, out, w);
        },
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "rope basics" {
    const gpa = testing.allocator;
    var r = try Rope.init(gpa, "hello\nworld\n");
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 12), r.byteLen());
    try testing.expectEqual(@as(usize, 3), r.lineCount());
    try testing.expectEqual(@as(usize, 0), r.lineStart(0));
    try testing.expectEqual(@as(usize, 5), r.lineEnd(0));
    try testing.expectEqual(@as(usize, 6), r.lineStart(1));
    try testing.expectEqual(@as(usize, 11), r.lineEnd(1));
    try testing.expectEqual(@as(usize, 12), r.lineStart(2));
    try testing.expectEqual(@as(usize, 12), r.lineEnd(2));
    try testing.expectEqual(@as(usize, 0), r.lineOfOffset(4));
    try testing.expectEqual(@as(usize, 1), r.lineOfOffset(6));
    try testing.expectEqual(@as(usize, 2), r.lineOfOffset(12));

    try r.insert(gpa, 5, " there");
    var buf: [64]u8 = undefined;
    r.copyRange(0, r.byteLen(), buf[0..r.byteLen()]);
    try testing.expectEqualStrings("hello there\nworld\n", buf[0..r.byteLen()]);

    try r.delete(gpa, 0, 6);
    r.copyRange(0, r.byteLen(), buf[0..r.byteLen()]);
    try testing.expectEqualStrings("there\nworld\n", buf[0..r.byteLen()]);
}

test "rope differential vs array" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    var oracle: std.ArrayListUnmanaged(u8) = .empty;
    defer oracle.deinit(gpa);
    var r = try Rope.init(gpa, "");
    defer r.deinit(gpa);

    var scratch: [8192]u8 = undefined;
    for (0..2000) |_| {
        const op = rand.uintLessThan(u8, 3);
        switch (op) {
            0, 1 => { // insert (biased: ropes grow)
                const off = rand.uintAtMost(usize, oracle.items.len);
                var text: [97]u8 = undefined;
                const tlen = rand.uintAtMost(usize, text.len - 1) + 1;
                for (text[0..tlen]) |*c| {
                    c.* = if (rand.uintLessThan(u8, 6) == 0) '\n' else 'a' + rand.uintLessThan(u8, 26);
                }
                try oracle.insertSlice(gpa, off, text[0..tlen]);
                try r.insert(gpa, off, text[0..tlen]);
            },
            else => { // delete
                if (oracle.items.len == 0) continue;
                const a = rand.uintAtMost(usize, oracle.items.len);
                const b = rand.uintAtMost(usize, oracle.items.len);
                const start = @min(a, b);
                const end = @max(a, b);
                oracle.replaceRangeAssumeCapacity(start, end - start, "");
                try r.delete(gpa, start, end);
            },
        }

        // Full-content equality every step.
        try testing.expectEqual(oracle.items.len, r.byteLen());
        r.copyRange(0, r.byteLen(), scratch[0..r.byteLen()]);
        try testing.expectEqualStrings(oracle.items, scratch[0..r.byteLen()]);

        // Line metrics against a scan.
        try testing.expectEqual(countNls(oracle.items) + 1, r.lineCount());
        if (oracle.items.len > 0) {
            const off = rand.uintAtMost(usize, oracle.items.len);
            try testing.expectEqual(countNls(oracle.items[0..off]), r.lineOfOffset(off));
        }
        const line = rand.uintLessThan(usize, r.lineCount());
        const ls = r.lineStart(line);
        try testing.expectEqual(countNls(oracle.items[0..ls]), line);
        if (ls > 0) try testing.expectEqual(@as(u8, '\n'), oracle.items[ls - 1]);
        const le = r.lineEnd(line);
        if (le < oracle.items.len) {
            try testing.expectEqual(@as(u8, '\n'), oracle.items[le]);
        } else {
            try testing.expectEqual(oracle.items.len, le);
        }
    }
}

test "rope big file build and queries" {
    const gpa = testing.allocator;
    // ~1MB, 60-byte lines.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(gpa);
    for (0..17000) |i| {
        var line: [61]u8 = undefined;
        const s = try std.fmt.bufPrint(&line, "line {d:0>6} pad pad pad pad pad pad pad pad pad pad pad\n", .{i});
        try big.appendSlice(gpa, s);
    }
    var r = try Rope.init(gpa, big.items);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 17001), r.lineCount());
    const start = r.lineStart(9999);
    var buf: [11]u8 = undefined;
    r.copyRange(start, start + 11, &buf);
    try testing.expectEqualStrings("line 009999", &buf);
}
