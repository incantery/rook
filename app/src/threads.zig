//! Threads — READ side, straight off the registry.
//!
//! A thread is a file-anchored conversation: a stored anchor (path,
//! range, blob_sha, side) plus its comments in id order. threaddoc.zig
//! is the other half — how a thread is PROJECTED as an editable
//! document; this is where the rows come from. The Go host splits the
//! same way (threads.go / threaddoc.go) and the names now match on both
//! sides, because during a port two files called the same thing in two
//! languages is a standing invitation to read the wrong one.
//!
//! Comments come back with the thread rather than on demand. Threads are
//! small, a pane renders all of them at once, and the alternative is an
//! N+1 that shows up as scroll jank on exactly the review with the most
//! conversation in it. The Go side made the same call.
//!
//! Read-only, like the rest of the substrate port. Anchors here carry no
//! current range: mapping them onto today's file is reanchor.resolve's
//! job, and doing it inside a query would bury a git fork in something
//! that looks like a row fetch.

const std = @import("std");
const regdb = @import("regdb.zig");
const reanchor = @import("reanchor.zig");

/// Column list and ORDER, verbatim from the Go host's threadCols. The
/// scan indexes positionally, so these must not drift.
const cols =
    "id, workspace, path, start_line, end_line, side, blob_sha, " ++
    "commit_sha, anchor_text, state, deliver_error, draft, rook_task_id, resolved_by, " ++
    "agent_reopens, created_at, updated_at, submitted_at";

pub const Comment = struct {
    id: i64 = 0,
    /// user|agent. Declared by the writer, not authenticated — the Go
    /// schema says so out loud and nothing downstream should treat it as
    /// proof of anything.
    author: []const u8 = "",
    agent_session: []const u8 = "",
    body: []const u8 = "",
    created_at: []const u8 = "",
};

pub const Thread = struct {
    id: i64 = 0,
    workspace: []const u8 = "",

    // The stored anchor: immutable ground truth.
    path: []const u8 = "",
    start_line: u32 = 0,
    end_line: u32 = 0,
    side: []const u8 = "modified",
    blob_sha: []const u8 = "",
    commit_sha: []const u8 = "",
    /// The anchored lines verbatim. What an outdated thread renders
    /// from, which is why it is stored rather than re-read.
    anchor_text: []const u8 = "",

    state: []const u8 = "pending", // pending|open|resolved
    /// Why a nudge never reached a responder; "" when it did. A thread
    /// with this set is open and submitted and NOBODY WAS TOLD — the one
    /// failure that otherwise renders as an ordinary wait.
    deliver_error: []const u8 = "",
    /// Text saved below the scissors line but not yet crystallised into
    /// a comment. threaddoc.zig's tail.
    draft: []const u8 = "",
    /// The review this thread hangs off, 0 for none.
    rook_task_id: i64 = 0,
    resolved_by: []const u8 = "",
    agent_reopens: i64 = 0,

    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    /// NULL in the schema, so genuinely absent rather than "". An
    /// unsubmitted thread has never been sent to anyone.
    submitted_at: ?[]const u8 = null,

    comments: []const Comment = &.{},

    /// The stored anchor, in the shape reanchor.resolve takes. Side is a
    /// string in the schema and an enum there; anything that is not
    /// "original" is modified, matching the Go side, where an empty side
    /// column has always meant modified.
    pub fn anchor(self: Thread) reanchor.Anchor {
        return .{
            .path = self.path,
            .start_line = self.start_line,
            .end_line = self.end_line,
            .blob_sha = self.blob_sha,
            .side = if (std.mem.eql(u8, self.side, "original")) .original else .modified,
        };
    }
};

/// A query result and the memory behind it — every string points into
/// the arena.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Thread = &.{},

    pub fn deinit(self: *List) void {
        self.arena.deinit();
    }
};

/// Filters for a listing. Empty means "no filter", exactly as the Go
/// side's empty-string parameters do.
pub const Filter = struct {
    state: []const u8 = "",
    path: []const u8 = "",
};

pub const Store = struct {
    db: ?*anyopaque,

    pub fn open() Store {
        return .{ .db = regdb.open() };
    }

    pub fn openPath(p: [*:0]const u8) Store {
        return .{ .db = regdb.openPath(p) };
    }

    pub fn close(self: *Store) void {
        regdb.close(self.db);
        self.db = null;
    }

    pub fn get(self: Store, gpa: std.mem.Allocator, id: i64) List {
        var out: List = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const db = self.db orelse return out;
        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db, "SELECT " ++ cols ++ " FROM threads WHERE id = ?", -1, &stmt, null) != regdb.OK)
            return out;
        defer _ = regdb.sqlite3_finalize(stmt);
        _ = regdb.sqlite3_bind_int64(stmt, 1, id);
        self.collect(&out, stmt);
        return out;
    }

    /// A workspace's threads in id order, comments included.
    pub fn list(self: Store, gpa: std.mem.Allocator, workspace: []const u8, filter: Filter) List {
        var out: List = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const db = self.db orelse return out;

        // Built rather than concatenated at comptime because the filters
        // are optional; bound as parameters, never interpolated, so a
        // path with a quote in it is a path and not a syntax error.
        var sql: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&sql);
        w.writeAll("SELECT " ++ cols ++ " FROM threads WHERE workspace = ?") catch return out;
        if (filter.state.len > 0) w.writeAll(" AND state = ?") catch return out;
        if (filter.path.len > 0) w.writeAll(" AND path = ?") catch return out;
        w.writeAll(" ORDER BY id\x00") catch return out;
        const sqlz: [*:0]const u8 = @ptrCast(sql[0 .. w.end - 1 :0].ptr);

        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db, sqlz, -1, &stmt, null) != regdb.OK) return out;
        defer _ = regdb.sqlite3_finalize(stmt);

        var idx: c_int = 1;
        _ = regdb.sqlite3_bind_text(stmt, idx, workspace.ptr, @intCast(workspace.len), regdb.STATIC);
        if (filter.state.len > 0) {
            idx += 1;
            _ = regdb.sqlite3_bind_text(stmt, idx, filter.state.ptr, @intCast(filter.state.len), regdb.STATIC);
        }
        if (filter.path.len > 0) {
            idx += 1;
            _ = regdb.sqlite3_bind_text(stmt, idx, filter.path.ptr, @intCast(filter.path.len), regdb.STATIC);
        }
        self.collect(&out, stmt);
        return out;
    }

    fn collect(self: Store, out: *List, stmt: ?*anyopaque) void {
        const a = out.arena.allocator();
        var rows: std.ArrayListUnmanaged(Thread) = .empty;
        while (regdb.sqlite3_step(stmt) == regdb.ROW) {
            const t: Thread = .{
                .id = regdb.sqlite3_column_int64(stmt, 0),
                .workspace = a.dupe(u8, regdb.text(stmt, 1)) catch break,
                .path = a.dupe(u8, regdb.text(stmt, 2)) catch break,
                .start_line = clampLine(regdb.sqlite3_column_int64(stmt, 3)),
                .end_line = clampLine(regdb.sqlite3_column_int64(stmt, 4)),
                .side = a.dupe(u8, regdb.text(stmt, 5)) catch break,
                .blob_sha = a.dupe(u8, regdb.text(stmt, 6)) catch break,
                .commit_sha = a.dupe(u8, regdb.text(stmt, 7)) catch break,
                .anchor_text = a.dupe(u8, regdb.text(stmt, 8)) catch break,
                .state = a.dupe(u8, regdb.text(stmt, 9)) catch break,
                .deliver_error = a.dupe(u8, regdb.text(stmt, 10)) catch break,
                .draft = a.dupe(u8, regdb.text(stmt, 11)) catch break,
                .rook_task_id = regdb.sqlite3_column_int64(stmt, 12),
                .resolved_by = a.dupe(u8, regdb.text(stmt, 13)) catch break,
                .agent_reopens = regdb.sqlite3_column_int64(stmt, 14),
                .created_at = a.dupe(u8, regdb.text(stmt, 15)) catch break,
                .updated_at = a.dupe(u8, regdb.text(stmt, 16)) catch break,
                // NULL and "" are different answers here: never submitted
                // versus submitted at an unknown time.
                .submitted_at = if (regdb.sqlite3_column_text(stmt, 17)) |p|
                    a.dupe(u8, std.mem.span(p)) catch break
                else
                    null,
            };
            rows.append(a, t) catch break;
        }
        out.items = rows.items;
        for (out.items) |*t| t.comments = self.commentsFor(a, t.id);
    }

    /// Comments for one thread, id order. An unreadable comment list is
    /// an EMPTY one, never a missing thread — losing the anchor because
    /// a comment would not scan is the wrong trade.
    fn commentsFor(self: Store, a: std.mem.Allocator, thread_id: i64) []const Comment {
        const db = self.db orelse return &.{};
        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db,
            \\SELECT id, author, agent_session, body, created_at
            \\FROM thread_comments WHERE thread_id = ? ORDER BY id
        , -1, &stmt, null) != regdb.OK) return &.{};
        defer _ = regdb.sqlite3_finalize(stmt);
        _ = regdb.sqlite3_bind_int64(stmt, 1, thread_id);

        var out: std.ArrayListUnmanaged(Comment) = .empty;
        while (regdb.sqlite3_step(stmt) == regdb.ROW) {
            out.append(a, .{
                .id = regdb.sqlite3_column_int64(stmt, 0),
                .author = a.dupe(u8, regdb.text(stmt, 1)) catch break,
                .agent_session = a.dupe(u8, regdb.text(stmt, 2)) catch break,
                .body = a.dupe(u8, regdb.text(stmt, 3)) catch break,
                .created_at = a.dupe(u8, regdb.text(stmt, 4)) catch break,
            }) catch break;
        }
        return out.items;
    }
};

fn clampLine(v: i64) u32 {
    if (v <= 0 or v > std.math.maxInt(u32)) return 0;
    return @intCast(v);
}

// ---------------------------------------------------------------------

const testing = std.testing;
const testdb = @import("testdb.zig");

fn seed(p: [*:0]const u8) !void {
    try testdb.run(p, testdb.schema);
    try testdb.run(p,
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, side, blob_sha,
        \\  commit_sha, anchor_text, state, deliver_error, draft, rook_task_id, resolved_by,
        \\  agent_reopens, created_at, updated_at, submitted_at)
        \\VALUES
        \\ (1,'src','a.zig',10,12,'modified','sha-a','c1','line ten','open','','',7,'',0,'t1','t2','t3'),
        \\ (2,'src','a.zig',3,3,'original','sha-b','','line three','resolved','','draft text',0,'user',2,'t1','t2',NULL),
        \\ (3,'src','b.zig',1,1,'','sha-c','','x','pending','nudge failed','',0,'',0,'t1','t2',NULL),
        \\ (4,'other','z.zig',1,1,'modified','sha-d','','y','open','','',0,'',0,'t1','t2',NULL);
        \\INSERT INTO thread_comments (id, thread_id, author, agent_session, body, created_at)
        \\VALUES
        \\ (1,1,'user','','first',  't1'),
        \\ (2,1,'agent','sess-1','second','t2'),
        \\ (3,2,'user','','only',   't1');
    );
}

fn openSeeded(tmp: *std.testing.TmpDir, buf: []u8) !Store {
    const p = try testdb.path(tmp, buf);
    try seed(p);
    return Store.openPath(p);
}

test "threads come back in id order with their comments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var store = try openSeeded(&tmp, &buf);
    defer store.close();

    var l = store.list(testing.allocator, "src", .{});
    defer l.deinit();
    try testing.expectEqual(@as(usize, 3), l.items.len);
    try testing.expectEqual(@as(i64, 1), l.items[0].id);

    // Positional scan: a column-order drift shows up here first.
    try testing.expectEqualStrings("a.zig", l.items[0].path);
    try testing.expectEqual(@as(u32, 10), l.items[0].start_line);
    try testing.expectEqual(@as(u32, 12), l.items[0].end_line);
    try testing.expectEqualStrings("sha-a", l.items[0].blob_sha);
    try testing.expectEqualStrings("line ten", l.items[0].anchor_text);
    try testing.expectEqual(@as(i64, 7), l.items[0].rook_task_id);

    // Comments ride along, in id order.
    try testing.expectEqual(@as(usize, 2), l.items[0].comments.len);
    try testing.expectEqualStrings("first", l.items[0].comments[0].body);
    try testing.expectEqualStrings("agent", l.items[0].comments[1].author);
    try testing.expectEqualStrings("sess-1", l.items[0].comments[1].agent_session);
    // A thread with no comments gets an empty slice, not a null one.
    try testing.expectEqual(@as(usize, 0), l.items[2].comments.len);
}

test "submitted_at distinguishes NULL from empty" {
    // Never submitted and submitted-at-unknown-time are different
    // answers, and the second is what "" would claim.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var store = try openSeeded(&tmp, &buf);
    defer store.close();

    var l = store.list(testing.allocator, "src", .{});
    defer l.deinit();
    try testing.expectEqualStrings("t3", l.items[0].submitted_at.?);
    try testing.expectEqual(@as(?[]const u8, null), l.items[1].submitted_at);
}

test "filters narrow by state and path, and compose" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var store = try openSeeded(&tmp, &buf);
    defer store.close();

    var open_only = store.list(testing.allocator, "src", .{ .state = "open" });
    defer open_only.deinit();
    try testing.expectEqual(@as(usize, 1), open_only.items.len);
    try testing.expectEqual(@as(i64, 1), open_only.items[0].id);

    var by_path = store.list(testing.allocator, "src", .{ .path = "a.zig" });
    defer by_path.deinit();
    try testing.expectEqual(@as(usize, 2), by_path.items.len);

    var both = store.list(testing.allocator, "src", .{ .state = "resolved", .path = "a.zig" });
    defer both.deinit();
    try testing.expectEqual(@as(usize, 1), both.items.len);
    try testing.expectEqual(@as(i64, 2), both.items[0].id);

    // A workspace filter that matches nothing is empty, not everything.
    var none = store.list(testing.allocator, "nosuch", .{});
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
}

test "filter values are bound, not interpolated" {
    // The injection this shape prevents. A quote in a path must be a
    // path; if these were concatenated it would be a syntax error at
    // best and a different query at worst.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var store = try openSeeded(&tmp, &buf);
    defer store.close();

    var l = store.list(testing.allocator, "src", .{ .path = "' OR 1=1 --" });
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.items.len);
}

test "a thread hands reanchor the anchor it stored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var store = try openSeeded(&tmp, &buf);
    defer store.close();

    var l = store.list(testing.allocator, "src", .{});
    defer l.deinit();

    const modified = l.items[0].anchor();
    try testing.expectEqual(reanchor.Side.modified, modified.side);
    try testing.expectEqualStrings("a.zig", modified.path);
    try testing.expectEqual(@as(u32, 10), modified.start_line);

    try testing.expectEqual(reanchor.Side.original, l.items[1].anchor().side);
    // An EMPTY side column means modified — that is what the Go schema
    // default has always meant, and rows predating the column have it.
    try testing.expectEqual(reanchor.Side.modified, l.items[2].anchor().side);
}

test "a missing db is an empty list, never a crash" {
    var store = Store.openPath("/nonexistent/rook/rook.db");
    defer store.close();
    var l = store.list(testing.allocator, "src", .{});
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.items.len);
}
