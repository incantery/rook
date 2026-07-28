//! Review — the changes list and the gate.
//!
//! A review is a RookTask parent whose children are anchored FINDINGS,
//! not diff hunks: each carries a path, a line range, a summary and a
//! state. The gate is a pure function of those states — approved and
//! deferred clear, everything else blocks.
//!
//! That shape is why this needed no diff viewer to be useful. The
//! finding says what is wrong and where; rook already opens a file at a
//! line. A side-by-side diff is a nicer way to READ a change, but it is
//! not what stands between you and a verdict — see app/PARITY.md §3.
//!
//! Plain HTTP, checked before building. Fixed buffers: the render path
//! reads this under draw_lock.

const std = @import("std");
const hostc = @import("hostc.zig");

pub const max_findings = 64;

const WireScore = struct { risk: i64 = 0, understand: i64 = 0 };
const WireDetail = struct {
    category: []const u8 = "",
    summary: []const u8 = "",
    label: []const u8 = "",
    verb: []const u8 = "",
    score: WireScore = .{},
};
const WireGate = struct {
    ready: bool = false,
    verb: []const u8 = "",
    blocking: i64 = 0,
    total: i64 = 0,
};
const WireTask = struct {
    id: i64 = 0,
    state: []const u8 = "",
    title: []const u8 = "",
    path: []const u8 = "",
    startLine: i64 = 0,
    /// The stored range mapped onto TODAY's file. A finding written
    /// against a line that has since moved must open where the code IS,
    /// not where it was — startLine is only the fallback.
    currentStart: i64 = 0,
    detail: WireDetail = .{},
    children: []const WireTask = &.{},
    gate: WireGate = .{},
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: u16 = 0,
        const Self = @This();
        pub fn setOneLine(self: *Self, s: []const u8) void {
            var w: usize = 0;
            var last_space = true;
            for (s) |c| {
                if (w >= n) break;
                const is_ws = c == '\n' or c == '\r' or c == '\t' or c == ' ';
                if (is_ws) {
                    if (last_space) continue;
                    self.buf[w] = ' ';
                    w += 1;
                    last_space = true;
                    continue;
                }
                self.buf[w] = c;
                w += 1;
                last_space = false;
            }
            while (w > 0 and self.buf[w - 1] == ' ') w -= 1;
            self.len = @intCast(w);
        }
        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const State = enum {
    proposed,
    approved,
    rejected,
    deferred,
    pending,

    pub fn parse(s: []const u8) State {
        if (std.mem.eql(u8, s, "approved")) return .approved;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "deferred")) return .deferred;
        if (std.mem.eql(u8, s, "pending")) return .pending;
        return .proposed;
    }

    /// Only an explicit approve or defer clears a finding. Everything
    /// else — proposed, rejected, conversation-pending — keeps the gate
    /// closed. This mirrors the host's `reviewBlocking` exactly; a
    /// client that disagreed would show a gate the host will not honour.
    pub fn blocks(self: State) bool {
        return switch (self) {
            .approved, .deferred => false,
            .proposed, .rejected, .pending => true,
        };
    }

    pub fn mark(self: State) []const u8 {
        return switch (self) {
            .proposed => "· ",
            .approved => "✓ ",
            .rejected => "✗ ",
            .deferred => "~ ",
            .pending => "… ",
        };
    }
};

pub const Finding = struct {
    id: i64 = 0,
    path: Text(100) = .{},
    line: i64 = 0,
    state: State = .proposed,
    what: Text(120) = .{},
    category: Text(28) = .{},
    risk: i64 = 0,
};

pub const Snapshot = struct {
    /// The review itself.
    id: i64 = 0,
    label: Text(48) = .{},
    verb: Text(12) = .{},
    ready: bool = false,
    blocking: i64 = 0,
    total: i64 = 0,

    items: [max_findings]Finding = undefined,
    n: usize = 0,
    more: usize = 0,
    live: bool = false,
    /// A review exists at all. Distinguishes "nothing to review" from
    /// "we could not ask".
    any: bool = false,

    pub fn slice(self: *const Snapshot) []const Finding {
        return self.items[0..self.n];
    }

    pub fn digest(self: *const Snapshot) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (self.live) "1" else "0");
        std.hash.autoHash(&h, self.id);
        std.hash.autoHash(&h, self.blocking);
        std.hash.autoHash(&h, self.ready);
        for (self.slice()) |*f| {
            std.hash.autoHash(&h, f.id);
            std.hash.autoHash(&h, f.state);
        }
        return h.final();
    }
};

pub fn fetch(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) Snapshot {
    if (workspace.len == 0) return .{};
    const info = hostc.readInfo(gpa, io) orelse return .{};
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/workspaces/{s}/tasks?workType=review", .{workspace}) catch return .{};
    var resp = hostc.get(gpa, &info, path, 4 * 1024 * 1024) orelse return .{};
    defer resp.deinit(gpa);
    if (resp.status != 200) return .{};
    return parse(gpa, resp.body);
}

pub fn parse(gpa: std.mem.Allocator, body: []const u8) Snapshot {
    var snap: Snapshot = .{};
    const parsed = std.json.parseFromSlice([]WireTask, gpa, body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();
    snap.live = true;
    if (parsed.value.len == 0) return snap;

    // The newest review. Several can exist; a panel that showed all of
    // them at once would bury the one you are actually working through.
    const root = parsed.value[parsed.value.len - 1];
    snap.any = true;
    snap.id = root.id;
    snap.label.setOneLine(if (root.detail.label.len > 0) root.detail.label else root.title);
    snap.verb.setOneLine(if (root.gate.verb.len > 0) root.gate.verb else root.detail.verb);
    snap.ready = root.gate.ready;
    snap.blocking = root.gate.blocking;
    snap.total = root.gate.total;

    for (root.children) |c| {
        if (snap.n >= max_findings) {
            snap.more += 1;
            continue;
        }
        var f: Finding = .{ .id = c.id };
        f.path.setOneLine(c.path);
        // Today's line, falling back to where it was written.
        f.line = if (c.currentStart > 0) c.currentStart else c.startLine;
        f.state = State.parse(c.state);
        // The summary is what a human triages on; the title is just
        // `path:line`, which the row already shows.
        f.what.setOneLine(if (c.detail.summary.len > 0) c.detail.summary else c.title);
        f.category.setOneLine(c.detail.category);
        f.risk = c.detail.score.risk;
        snap.items[snap.n] = f;
        snap.n += 1;
    }
    sortByAttention(snap.items[0..snap.n]);
    return snap;
}

/// Blocking first, then by risk descending — what stands between you and
/// the gate, most dangerous first. Stable, so a poll cannot move the row
/// under the cursor.
pub fn sortByAttention(items: []Finding) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const v = items[i];
        var j = i;
        while (j > 0 and rank(items[j - 1]) > rank(v)) : (j -= 1) items[j] = items[j - 1];
        items[j] = v;
    }
}

fn rank(f: Finding) i64 {
    // 0..: blocking sorts before cleared; within that, higher risk first.
    const base: i64 = if (f.state.blocks()) 0 else 1000;
    return base + (10 - @min(f.risk, 10));
}

/// Set a finding's state. `POST /tasks/{id}/state {state}`.
pub fn setState(gpa: std.mem.Allocator, io: std.Io, id: i64, state: []const u8) bool {
    const info = hostc.readInfo(gpa, io) orelse return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tasks/{d}/state", .{id}) catch return false;
    var body_buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"state\":\"{s}\"}}", .{state}) catch return false;
    var resp = hostc.post(gpa, &info, path, body, 64 * 1024) orelse return false;
    defer resp.deinit(gpa);
    return resp.status >= 200 and resp.status < 300;
}

// ----------------------------------------------------------------- tests

const T = std.testing;

const sample =
    \\[{"id":1,"state":"reviewing","title":"r","detail":{"label":"branch vs origin/main","verb":"PR"},
    \\  "gate":{"ready":false,"verb":"PR","blocking":2,"total":3},
    \\  "children":[
    \\   {"id":2,"state":"proposed","path":"a.go","startLine":10,"currentStart":14,
    \\    "title":"a.go:10","detail":{"category":"bug","summary":"off by one","score":{"risk":5}}},
    \\   {"id":3,"state":"approved","path":"b.go","startLine":20,"currentStart":20,
    \\    "title":"b.go:20","detail":{"summary":"fine","score":{"risk":1}}},
    \\   {"id":4,"state":"rejected","path":"c.go","startLine":30,
    \\    "title":"c.go:30","detail":{"summary":"wants change","score":{"risk":9}}}]}]
;

test "parses a review, its gate, and its findings" {
    const s = parse(T.allocator, sample);
    try T.expect(s.live and s.any);
    try T.expectEqualStrings("branch vs origin/main", s.label.get());
    try T.expectEqualStrings("PR", s.verb.get());
    try T.expect(!s.ready);
    try T.expectEqual(@as(i64, 2), s.blocking);
    try T.expectEqual(@as(usize, 3), s.n);
}

test "a finding opens where the code IS, not where it was written" {
    // currentStart is the stored range re-anchored onto today's file.
    // Jumping to startLine would land on whatever moved into its place.
    const s = parse(T.allocator, sample);
    for (s.slice()) |f| {
        if (f.id != 2) continue;
        try T.expectEqual(@as(i64, 14), f.line);
        return;
    }
    return error.TestUnexpectedResult;
}

test "a finding with no re-anchor falls back to where it was written" {
    const s = parse(T.allocator, sample);
    for (s.slice()) |f| {
        if (f.id != 4) continue;
        try T.expectEqual(@as(i64, 30), f.line);
        return;
    }
    return error.TestUnexpectedResult;
}

test "blocking matches the host's rule exactly" {
    // A client that disagreed with the host here would render a gate the
    // host will not honour — the worst kind of wrong for this panel.
    try T.expect(State.proposed.blocks());
    try T.expect(State.rejected.blocks());
    try T.expect(State.pending.blocks());
    try T.expect(!State.approved.blocks());
    try T.expect(!State.deferred.blocks());
}

test "blocking sorts first, riskiest first, and stably" {
    const s = parse(T.allocator, sample);
    const rows = s.slice();
    // rejected(risk 9) and proposed(risk 5) block; approved does not.
    try T.expectEqual(@as(i64, 4), rows[0].id);
    try T.expectEqual(@as(i64, 2), rows[1].id);
    try T.expectEqual(@as(i64, 3), rows[2].id);
}

test "no reviews is live-but-empty, unlike unreachable" {
    const s = parse(T.allocator, "[]");
    try T.expect(s.live);
    try T.expect(!s.any);
    const unreachable_snap: Snapshot = .{};
    try T.expect(!unreachable_snap.live);
}

test "the summary is preferred over the title, which is only path:line" {
    const s = parse(T.allocator, sample);
    for (s.slice()) |f| {
        if (f.id != 2) continue;
        try T.expectEqualStrings("off by one", f.what.get());
        return;
    }
    return error.TestUnexpectedResult;
}
