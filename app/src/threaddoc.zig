//! Threads — file-anchored conversations, projected as editable buffers.
//!
//! The host keeps truth structured in its DB and hands out a DOCUMENT:
//! rendered history, a scissors line, then your draft below it. Saving
//! posts the whole document back and the host diffs it against a fresh
//! render. That contract is `internal/host/threaddoc.go`, and two parts
//! of it are load-bearing for any client:
//!
//!   1. The prefix is `content` MINUS `draft`, computed exactly — never
//!      by scanning for the scissors line, because a comment body could
//!      legally contain a scissors-shaped line. The host hands `draft`
//!      back with the doc precisely so we can do this arithmetic.
//!
//!   2. A save that no longer matches answers 409 WITH the fresh doc.
//!      That is not an error, it is a concurrent agent reply: re-render
//!      and splice your tail back on. History is append-only, so this
//!      always merges.
//!
//! Everything is plain HTTP — no session socket, checked before building.

const std = @import("std");
const hostc = @import("hostc.zig");

pub const max_threads = 32;

const WireThread = struct {
    id: i64 = 0,
    path: []const u8 = "",
    startLine: i32 = 0,
    state: []const u8 = "",
    anchorText: []const u8 = "",
    draft: []const u8 = "",
    deliverError: []const u8 = "",
};

const WireDoc = struct {
    content: []const u8 = "",
    draft: []const u8 = "",
    resolved: bool = false,
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: u16 = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(n, s.len);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = @intCast(k);
        }

        /// Set as ONE line: an anchor is a span of source and often
        /// several lines of it, which a single-row list cannot show —
        /// real data has multi-line anchors, and pasting a newline into
        /// a row breaks the row. Whitespace runs collapse to one space.
        pub fn setOneLine(self: *Self, s: []const u8) void {
            var w: usize = 0;
            var last_space = true; // also trims the leading run
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
    pending,
    open,
    resolved,

    pub fn parse(s: []const u8) State {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "resolved")) return .resolved;
        return .open;
    }
};

pub const Thread = struct {
    id: i64 = 0,
    path: Text(120) = .{},
    line: i32 = 0,
    state: State = .open,
    anchor: Text(80) = .{},
    has_draft: bool = false,
    /// The nudge never reached a responder. A thread in this state is
    /// open and submitted but NOBODY WAS TOLD — the one failure the old
    /// model rendered as a normal wait, so it gets its own mark.
    undelivered: bool = false,
};

pub const Snapshot = struct {
    items: [max_threads]Thread = undefined,
    n: usize = 0,
    more: usize = 0,
    live: bool = false,

    pub fn slice(self: *const Snapshot) []const Thread {
        return self.items[0..self.n];
    }

    pub fn digest(self: *const Snapshot) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (self.live) "1" else "0");
        for (self.slice()) |*t| {
            std.hash.autoHash(&h, t.id);
            std.hash.autoHash(&h, t.state);
            std.hash.autoHash(&h, t.has_draft);
            h.update(t.path.get());
        }
        return h.final();
    }
};

pub fn list(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) Snapshot {
    if (workspace.len == 0) return .{};
    const info = hostc.readInfo(gpa, io) orelse return .{};
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/workspaces/{s}/threads", .{workspace}) catch return .{};
    var resp = hostc.get(gpa, &info, path, 512 * 1024) orelse return .{};
    defer resp.deinit(gpa);
    if (resp.status != 200) return .{};
    return parseList(gpa, resp.body);
}

pub fn parseList(gpa: std.mem.Allocator, body: []const u8) Snapshot {
    var snap: Snapshot = .{};
    const parsed = std.json.parseFromSlice([]WireThread, gpa, body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();
    snap.live = true;
    for (parsed.value) |w| {
        // Resolved threads are history; the list is what still wants you.
        if (std.mem.eql(u8, w.state, "resolved")) continue;
        if (snap.n >= max_threads) {
            snap.more += 1;
            continue;
        }
        var t: Thread = .{ .id = w.id, .line = w.startLine };
        t.path.set(w.path);
        t.state = State.parse(w.state);
        t.anchor.setOneLine(w.anchorText);
        t.has_draft = w.draft.len > 0;
        t.undelivered = w.deliverError.len > 0;
        snap.items[snap.n] = t;
        snap.n += 1;
    }
    return snap;
}

pub const Doc = struct {
    /// The whole document, as the editor should show it.
    content: []u8,
    /// How much of the tail is the draft. `content[0..content.len -
    /// draft_len]` is the immutable prefix the host will check.
    draft_len: usize,
    resolved: bool,

    pub fn prefix(self: *const Doc) []const u8 {
        return self.content[0 .. self.content.len - @min(self.draft_len, self.content.len)];
    }
    pub fn deinit(self: *Doc, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        self.* = undefined;
    }
};

/// Fetch a thread as a document. Caller owns `Doc.content`.
pub fn fetchDoc(gpa: std.mem.Allocator, io: std.Io, id: i64) ?Doc {
    const info = hostc.readInfo(gpa, io) orelse return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/threads/{d}/doc", .{id}) catch return null;
    var resp = hostc.get(gpa, &info, path, 4 * 1024 * 1024) orelse return null;
    defer resp.deinit(gpa);
    if (resp.status != 200) return null;
    return parseDoc(gpa, resp.body);
}

pub fn parseDoc(gpa: std.mem.Allocator, body: []const u8) ?Doc {
    const parsed = std.json.parseFromSlice(WireDoc, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const content = gpa.dupe(u8, parsed.value.content) catch return null;
    return .{ .content = content, .draft_len = parsed.value.draft.len, .resolved = parsed.value.resolved };
}

pub const SaveResult = union(enum) {
    ok,
    /// A concurrent reply landed. Carries the FRESH doc so the caller can
    /// splice its tail back on — not an error, a merge.
    stale: Doc,
    failed,
};

/// Save a document. `POST /threads/{id}/doc {content}`.
pub fn saveDoc(gpa: std.mem.Allocator, io: std.Io, id: i64, content: []const u8) SaveResult {
    const info = hostc.readInfo(gpa, io) orelse return .failed;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/threads/{d}/doc", .{id}) catch return .failed;

    // {"content": <json string>} — hand-built so the whole document does
    // not need a second copy through a serializer.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = aw.writer.write("{\"content\":") catch return .failed;
    @import("asks.zig").writeJsonString(&aw.writer, content);
    _ = aw.writer.write("}") catch return .failed;

    var resp = hostc.post(gpa, &info, path, aw.writer.buffered(), 4 * 1024 * 1024) orelse return .failed;
    defer resp.deinit(gpa);
    if (resp.status >= 200 and resp.status < 300) return .ok;
    if (resp.status == 409) {
        if (parseDoc(gpa, resp.body)) |fresh| return .{ .stale = fresh };
    }
    return .failed;
}

/// POST a thread verb with no body: note | ask | resolve.
pub fn verb(gpa: std.mem.Allocator, io: std.Io, id: i64, name: []const u8) bool {
    const info = hostc.readInfo(gpa, io) orelse return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/threads/{d}/{s}", .{ id, name }) catch return false;
    var resp = hostc.post(gpa, &info, path, "{}", 64 * 1024) orelse return false;
    defer resp.deinit(gpa);
    return resp.status >= 200 and resp.status < 300;
}

/// Splice our tail onto a freshly rendered document.
///
/// The merge for a concurrent agent reply. History is append-only, so
/// the fresh prefix simply grew — our draft is still ours and belongs
/// below it. Caller owns the result.
pub fn splice(gpa: std.mem.Allocator, fresh: *const Doc, our_tail: []const u8) ?[]u8 {
    const p = fresh.prefix();
    const out = gpa.alloc(u8, p.len + our_tail.len) catch return null;
    @memcpy(out[0..p.len], p);
    @memcpy(out[p.len..], our_tail);
    return out;
}

/// The tail of `content` given the prefix length we were handed out.
/// Returns null when the buffer no longer starts with that prefix —
/// the user edited history, which the host would reject anyway.
pub fn tailOf(content: []const u8, prefix_at_open: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, prefix_at_open)) return null;
    return content[prefix_at_open.len..];
}

// ----------------------------------------------------------------- tests

const T = std.testing;

test "prefix is content minus draft, not a scissors scan" {
    // The exact reason the host hands `draft` back: a comment body may
    // legally contain a scissors-shaped line, so scanning for one would
    // cut the document in the wrong place.
    const body =
        \\{"content":"history\n-- ✂ -- reply below --\nmy draft","draft":"my draft","resolved":false}
    ;
    var doc = parseDoc(T.allocator, body).?;
    defer doc.deinit(T.allocator);
    try T.expectEqualStrings("history\n-- ✂ -- reply below --\n", doc.prefix());
}

test "a doc with no draft is all prefix" {
    var doc = parseDoc(T.allocator, "{\"content\":\"just history\",\"draft\":\"\"}").?;
    defer doc.deinit(T.allocator);
    try T.expectEqualStrings("just history", doc.prefix());
}

test "splice puts our tail under a grown history" {
    // The concurrent-reply merge: the agent replied while we were typing.
    var fresh = parseDoc(T.allocator, "{\"content\":\"h1\\nh2\\n--cut--\\n\",\"draft\":\"\"}").?;
    defer fresh.deinit(T.allocator);
    const merged = splice(T.allocator, &fresh, "my unsent words").?;
    defer T.allocator.free(merged);
    try T.expectEqualStrings("h1\nh2\n--cut--\nmy unsent words", merged);
}

test "tailOf recovers what we wrote, and declines mangled history" {
    try T.expectEqualStrings("tail", tailOf("PREFIX\ntail", "PREFIX\n").?);
    try T.expectEqualStrings("", tailOf("PREFIX\n", "PREFIX\n").?);
    // History edited above the line — the host would 409 this anyway.
    try T.expect(tailOf("MANGLED\ntail", "PREFIX\n") == null);
}

test "the list drops resolved threads and marks the undelivered" {
    const body =
        \\[{"id":1,"path":"a.zig","startLine":10,"state":"open","anchorText":"fn a"},
        \\ {"id":2,"path":"b.zig","state":"resolved"},
        \\ {"id":3,"path":"c.zig","state":"open","draft":"wip","deliverError":"nobody home"}]
    ;
    const snap = parseList(T.allocator, body);
    try T.expect(snap.live);
    try T.expectEqual(@as(usize, 2), snap.n);
    try T.expectEqual(@as(i64, 1), snap.slice()[0].id);
    try T.expect(!snap.slice()[0].has_draft);
    try T.expectEqual(@as(i64, 3), snap.slice()[1].id);
    try T.expect(snap.slice()[1].has_draft);
    try T.expect(snap.slice()[1].undelivered);
}

test "a multi-line anchor collapses to one row" {
    // Real anchors are spans of source and are often several lines. A
    // newline in a single-row list breaks the row (and the ctl output),
    // which is exactly how this showed up against live data.
    const body =
        \\[{"id":1,"path":"a.go","state":"open","anchorText":"app := New({\n  Name: \"rook\",\n\t Desc: x})"}]
    ;
    const snap = parseList(T.allocator, body);
    const a = snap.slice()[0].anchor.get();
    try T.expect(std.mem.indexOfScalar(u8, a, '\n') == null);
    try T.expect(std.mem.indexOfScalar(u8, a, '\t') == null);
    try T.expectEqualStrings("app := New({ Name: \"rook\", Desc: x})", a);
}

test "an empty list is live, unlike an unreachable host" {
    try T.expect(parseList(T.allocator, "[]").live);
    const unreachable_snap: Snapshot = .{};
    try T.expect(!unreachable_snap.live);
}
