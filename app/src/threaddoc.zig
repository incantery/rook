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
//! Reads come from the registry in this process; the document and every
//! write still go over plain HTTP, for the reason spelled out above
//! fetchDoc — the doc is half of the save contract, not a view of rows.

const std = @import("std");
const hostc = @import("hostc.zig");
const threads = @import("threads.zig");
const reanchor = @import("reanchor.zig");
const blobs = @import("blobs.zig");
const workspaces = @import("workspaces.zig");
const git = @import("git.zig");

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

/// The LOCAL arm of the sidebar list (substrate.zig picks the arm).
///
/// Null means the registry was unreachable, not empty — the caller needs
/// that distinction to know whether the remote arm would say anything
/// different.
///
/// Rows are RE-ANCHORED: a row opens where its code is NOW, not where
/// the conversation started. That is the point of storing an anchor
/// rather than a line number, and a sidebar that sends you to a line the
/// code has left is worse than one that admits it does not know.
///
/// Only MODIFIED-side anchors, which is the same rule the review panel
/// follows — re-anchor where the base is unambiguously the working tree.
/// An original-side anchor's snapshot came from a diff base and must be
/// compared against that base; resolving WHICH base (HEAD, or a
/// worktree's merge-base) is reviewBaseFor's job and still lives in the
/// Go host. Those rows keep their stored line, which is what every row
/// did before this change, so nothing regresses.
pub fn readList(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) ?Snapshot {
    var store = threads.Store.open();
    defer store.close();
    if (store.db == null) return null;

    var snap: Snapshot = .{ .live = true };
    // Comments off: this panel only asks whether a draft exists, and
    // fetching bodies to discard them is a query per row.
    var rows = store.list(gpa, workspace, .{ .comments = false });
    defer rows.deinit();

    var memo = reanchor.Memo.init(gpa);
    defer memo.deinit();
    var blob_store = blobs.Store.open();
    defer blob_store.close();
    // Resolved on first use: a workspace whose threads are all resolved,
    // or all original-side, should not fork git for a repo top it will
    // never consult.
    var top: ?[]u8 = null;
    var top_tried = false;
    defer if (top) |t| gpa.free(t);

    for (rows.items) |t| {
        // Resolved threads are history; the list is what still wants you.
        if (std.mem.eql(u8, t.state, "resolved")) continue;
        if (snap.n >= max_threads) {
            snap.more += 1;
            continue;
        }
        var out: Thread = .{ .id = t.id, .line = @intCast(t.start_line) };
        out.path.set(t.path);
        out.state = State.parse(t.state);
        out.anchor.setOneLine(t.anchor_text);
        out.has_draft = t.draft.len > 0;
        out.undelivered = t.deliver_error.len > 0;

        var a = t.anchor();
        if (a.side == .modified and a.blob_sha.len > 0) {
            if (!top_tried) {
                top_tried = true;
                if (workspaces.rootOf(gpa, workspace)) |root_dir| {
                    defer gpa.free(root_dir);
                    top = git.repoTop(gpa, io, root_dir);
                }
            }
            if (top) |repo_top| {
                reanchor.resolve(gpa, io, .{
                    .top = repo_top,
                    .blobs = &blob_store,
                    .memo = &memo,
                }, &a);
                // An outdated anchor keeps its STORED range, so this is
                // the right line either way: where the row should send
                // you, with anchor_text as what it renders.
                if (a.current_start > 0) out.line = @intCast(a.current_start);
            }
        }

        snap.items[snap.n] = out;
        snap.n += 1;
    }
    return snap;
}

/// The REMOTE arm. Not a legacy path — the only one that works from
/// another machine, and indifferent to the host's language.
pub fn listHost(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) Snapshot {
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
///
/// Stays on HTTP, deliberately, even though the rows behind it are now
/// readable locally. The document is not a view of the rows — it is one
/// half of the SAVE contract: a save posts the whole document back and
/// the host diffs it against its own fresh render, answering 409 with
/// that render when they disagree. Rendering locally would mean the
/// prefix we compute comes from OUR renderer while the check comes from
/// the host's, so any byte of difference — comment ordering, a separator,
/// a timestamp format — becomes a 409 the user cannot clear by retrying.
///
/// It can only move when the writer moves with it, which is the same
/// rule holding every other write in Go.
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

// ------------------------------------------------- the registry path
//
// The assertion that matters for a MOVE: the local path and the host
// path must produce the same Snapshot from the same data. Testing them
// separately would let them drift into two panels that disagree, which
// is the specific failure a cutover invites.

const testdb = @import("testdb.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Point regdb at a fixture and return the db path.
fn fixtureDb(tmp: *std.testing.TmpDir, buf: []u8) ![:0]const u8 {
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(T.io, "rook");
    _ = setenv("XDG_DATA_HOME", dir, 1);
    return std.fmt.bufPrintZ(buf, "{s}/rook/rook.db", .{dir});
}

fn expectSameSnapshot(want: Snapshot, got: Snapshot) !void {
    try T.expectEqual(want.live, got.live);
    try T.expectEqual(want.n, got.n);
    try T.expectEqual(want.more, got.more);
    for (want.slice(), got.slice()) |w, g| {
        try T.expectEqual(w.id, g.id);
        try T.expectEqualStrings(w.path.get(), g.path.get());
        try T.expectEqual(w.line, g.line);
        try T.expectEqual(w.state, g.state);
        try T.expectEqualStrings(w.anchor.get(), g.anchor.get());
        try T.expectEqual(w.has_draft, g.has_draft);
        try T.expectEqual(w.undelivered, g.undelivered);
    }
    // Belt and braces: the digest is what the render path polls on.
    try T.expectEqual(want.digest(), got.digest());
}

test "the registry path agrees with the host path, row for row" {
    // No workspaces row and no anchor_blobs, so nothing here re-anchors
    // and both paths report stored lines. That is deliberate: this test
    // pins the FIELD MAPPING and the resolved-skip. Re-anchoring is a
    // behaviour the host does not share, so it gets its own test below
    // rather than being smuggled into a parity assertion.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try fixtureDb(&tmp, &buf);
    try testdb.run(db, testdb.schema);
    try testdb.run(db,
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, side, blob_sha,
        \\  commit_sha, anchor_text, state, deliver_error, draft, rook_task_id, resolved_by,
        \\  agent_reopens, created_at, updated_at, submitted_at)
        \\VALUES
        \\ (1,'src','a.zig',10,12,'modified','s1','','if (x)  {
        \\  return; }','open','','',0,'',0,'t','t',NULL),
        \\ (2,'src','b.zig',3,3,'modified','s2','','two','pending','','tail here',0,'',0,'t','t',NULL),
        \\ (3,'src','c.zig',7,7,'modified','s3','','three','open','nudge failed','',0,'',0,'t','t',NULL),
        \\ (4,'src','d.zig',1,1,'modified','s4','','gone','resolved','','',0,'user',0,'t','t',NULL);
    );

    // The same four threads as the host would serialise them.
    const wire =
        \\[{"id":1,"path":"a.zig","startLine":10,"state":"open","anchorText":"if (x)  {\n  return; }","draft":"","deliverError":""},
        \\ {"id":2,"path":"b.zig","startLine":3,"state":"pending","anchorText":"two","draft":"tail here","deliverError":""},
        \\ {"id":3,"path":"c.zig","startLine":7,"state":"open","anchorText":"three","draft":"","deliverError":"nudge failed"},
        \\ {"id":4,"path":"d.zig","startLine":1,"state":"resolved","anchorText":"gone","draft":"","deliverError":""}]
    ;

    const local = readList(T.allocator, T.io, "src") orelse return error.RegistryUnreachable;
    const host = parseList(T.allocator, wire);

    try expectSameSnapshot(host, local);
    // ...and the shared expectations, so a bug common to both still fails.
    try T.expectEqual(@as(usize, 3), local.n); // resolved dropped
    try T.expect(local.slice()[1].has_draft);
    try T.expect(local.slice()[2].undelivered);
    // The multi-line anchor collapsed to one row on both paths.
    try T.expectEqualStrings("if (x) { return; }", local.slice()[0].anchor.get());
}

test "the registry path caps at max_threads and counts the rest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try fixtureDb(&tmp, &buf);
    try testdb.run(db, testdb.schema);

    // max_threads + 3 open threads, so `more` has to be 3.
    var sql: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&sql);
    try w.writeAll("INSERT INTO threads (workspace, path, start_line, end_line, blob_sha, anchor_text, state, created_at, updated_at) VALUES ");
    for (0..max_threads + 3) |i| {
        if (i > 0) try w.writeAll(",");
        try w.print("('src','f{d}.zig',1,1,'s','a','open','t','t')", .{i});
    }
    try w.writeAll(";\x00");
    try testdb.run(db, @ptrCast(sql[0 .. w.end - 1 :0].ptr));

    const snap = readList(T.allocator, T.io, "src") orelse return error.RegistryUnreachable;
    try T.expectEqual(@as(usize, max_threads), snap.n);
    try T.expectEqual(@as(usize, 3), snap.more);
}

test "an unreadable registry is null, so list can fall back" {
    _ = setenv("XDG_DATA_HOME", "/nonexistent/rook-test", 1);
    try T.expectEqual(@as(?Snapshot, null), readList(T.allocator, T.io, "src"));
}

const anchorpkg = @import("anchor.zig");

test "a sidebar row opens where its code is now" {
    // The behaviour this change exists for: the conversation was started
    // against line 3, two lines have since been inserted above it, and
    // the row must send you to 5. Real registry, real repo, real diff.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try fixtureDb(&tmp, &buf);

    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var repobuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repobuf, "{s}/repo", .{dir});
    try tmp.dir.createDirPath(T.io, "repo");
    // Without `git init`, rev-parse walks up out of .zig-cache and
    // reports rook's own top; every anchor then resolves against the
    // wrong tree, reads as outdated, and this passes while proving
    // nothing.
    if (git.run(T.allocator, T.io, repo, &.{ "init", "-q" }, 1 << 16)) |r| r.deinit(T.allocator);

    const original = "l1\nl2\nl3\nl4\nl5\n";
    const sha = anchorpkg.blobSha(original);

    // HEAD gets THREE lines prepended, the working tree TWO. The two
    // sides therefore map the same stored range to DIFFERENT lines — 6
    // against the base, 5 against the tree — which is what makes the
    // original-side assertion below able to fail. With an empty repo it
    // could not: `git show HEAD:f.zig` errors, the anchor reads as
    // outdated, and the row keeps line 3 whether the side rule exists or
    // not. Found by removing the rule and watching the test still pass.
    try tmp.dir.writeFile(T.io, .{ .sub_path = "repo/f.zig", .data = "x\ny\nz\n" ++ original });
    inline for (.{
        &[_][]const u8{ "add", "f.zig" },
        &[_][]const u8{ "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" },
    }) |argv| {
        if (git.run(T.allocator, T.io, repo, argv, 1 << 16)) |r| {
            defer r.deinit(T.allocator);
            if (r.code != 0) return error.SkipZigTest; // no usable git
        } else return error.SkipZigTest;
    }
    try tmp.dir.writeFile(T.io, .{ .sub_path = "repo/f.zig", .data = "a\nb\n" ++ original });

    try testdb.run(db, testdb.schema);
    var sql: [2048]u8 = undefined;
    try testdb.run(db, try std.fmt.bufPrintZ(&sql,
        \\INSERT INTO workspaces (name, root, created_at, last_used) VALUES ('src','{s}','t','t');
        \\INSERT INTO anchor_blobs (sha, content) VALUES ('{s}','{s}');
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, side, blob_sha, anchor_text, state, created_at, updated_at)
        \\ VALUES (1,'src','f.zig',3,4,'modified','{s}','l3','open','t','t');
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, side, blob_sha, anchor_text, state, created_at, updated_at)
        \\ VALUES (2,'src','f.zig',3,4,'original','{s}','l3','open','t','t');
    , .{ repo, &sha, original, &sha, &sha }));

    const snap = readList(T.allocator, T.io, "src") orelse return error.RegistryUnreachable;
    try T.expectEqual(@as(usize, 2), snap.n);

    // Modified side: re-anchored onto today's tree.
    try T.expectEqual(@as(i32, 5), snap.slice()[0].line);

    // Original side: NOT re-anchored, because WHICH base to compare
    // against is reviewBaseFor's answer and that is still in Go. Keeps
    // its stored line — 3, not the 6 that re-anchoring against HEAD
    // would give, so this fails if the side rule is dropped.
    try T.expectEqual(@as(i32, 3), snap.slice()[1].line);
}

test "an outdated anchor still points at its stored line" {
    // The anchored lines themselves changed, so there is no honest
    // mapping. The row must not guess — it keeps the stored range and
    // renders anchor_text, which is exactly why anchor_text is stored.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try fixtureDb(&tmp, &buf);

    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var repobuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repobuf, "{s}/repo", .{dir});
    try tmp.dir.createDirPath(T.io, "repo");
    if (git.run(T.allocator, T.io, repo, &.{ "init", "-q" }, 1 << 16)) |r| r.deinit(T.allocator);

    const original = "l1\nl2\nl3\nl4\nl5\n";
    const sha = anchorpkg.blobSha(original);
    try tmp.dir.writeFile(T.io, .{ .sub_path = "repo/f.zig", .data = "l1\nl2\nCHANGED\nl4\nl5\n" });

    try testdb.run(db, testdb.schema);
    var sql: [2048]u8 = undefined;
    try testdb.run(db, try std.fmt.bufPrintZ(&sql,
        \\INSERT INTO workspaces (name, root, created_at, last_used) VALUES ('src','{s}','t','t');
        \\INSERT INTO anchor_blobs (sha, content) VALUES ('{s}','{s}');
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, side, blob_sha, anchor_text, state, created_at, updated_at)
        \\ VALUES (1,'src','f.zig',3,3,'modified','{s}','l3','open','t','t');
    , .{ repo, &sha, original, &sha }));

    const snap = readList(T.allocator, T.io, "src") orelse return error.RegistryUnreachable;
    try T.expectEqual(@as(i32, 3), snap.slice()[0].line);
    try T.expectEqualStrings("l3", snap.slice()[0].anchor.get());
}
