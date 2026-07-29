//! RookTasks — READ side, straight off the registry.
//!
//! A RookTask is a unit of attention with a state and an optional anchor,
//! nesting to arbitrary depth through parent_id. The base object is
//! deliberately dumb: `state` is an opaque token that the WORK TYPE
//! interprets, and review is simply the first work type to have a
//! vocabulary for it. That is why the gate below reads states as strings
//! rather than as an enum — an enum here would quietly claim the schema
//! knows what the tokens mean.
//!
//! Read-only, like every registry port so far; rook-host owns every
//! write. The point of reading these here rather than over HTTP is that
//! a review surface re-anchoring live working-tree changes wants the
//! rows and the re-anchoring in one process, not a JSON round trip per
//! poll.

const std = @import("std");
const regdb = @import("regdb.zig");

/// Column list and ORDER, verbatim from the Go host's taskCols. The scan
/// below indexes positionally, so these two must not drift.
const cols =
    "id, parent_id, workspace, work_type, state, title, " ++
    "anchor_kind, path, start_line, end_line, side, blob_sha, commit_sha, " ++
    "anchor_text, anchor_ref, origin, source_ref, detail, created_at, updated_at";

pub const Task = struct {
    id: i64 = 0,
    parent_id: i64 = 0,
    workspace: []const u8 = "",
    work_type: []const u8 = "",
    state: []const u8 = "",
    title: []const u8 = "",

    /// Kind-tagged anchor: "code" uses the line columns, "ref" uses
    /// anchor_ref, "none" uses neither.
    anchor_kind: []const u8 = "none",
    path: []const u8 = "",
    start_line: u32 = 0,
    end_line: u32 = 0,
    side: []const u8 = "modified",
    blob_sha: []const u8 = "",
    commit_sha: []const u8 = "",
    anchor_text: []const u8 = "",
    anchor_ref: []const u8 = "",

    origin: []const u8 = "rook",
    source_ref: []const u8 = "",

    /// work_type-owned JSON bag. Always valid JSON on read — an empty
    /// column becomes "{}", matching the Go scan, so a client can parse
    /// unconditionally.
    detail: []const u8 = "{}",

    /// RFC3339, unparsed. The Go side turns these into time.Time because
    /// its JSON contract needs it; nothing here does yet, and parsing a
    /// timestamp nobody reads is how you acquire a timezone bug for free.
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

/// A query result and the memory behind it. Every string in `items`
/// points into the arena, so one deinit releases the lot — sqlite's own
/// buffers are only valid until the next step().
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Task = &.{},

    pub fn deinit(self: *List) void {
        self.arena.deinit();
    }
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

    /// One task by id, or an empty list. Same shape as the others so
    /// callers free the same way regardless of arity.
    pub fn get(self: Store, gpa: std.mem.Allocator, id: i64) List {
        return self.query(gpa, "SELECT " ++ cols ++ " FROM rook_tasks WHERE id = ?", id);
    }

    /// Direct children, id order — the order the gate counts in and the
    /// order a review renders in.
    pub fn childrenOf(self: Store, gpa: std.mem.Allocator, parent_id: i64) List {
        return self.query(gpa, "SELECT " ++ cols ++ " FROM rook_tasks WHERE parent_id = ? ORDER BY id", parent_id);
    }

    /// Root tasks for a workspace (parent_id 0), newest first.
    pub fn roots(self: Store, gpa: std.mem.Allocator, workspace: []const u8) List {
        var out: List = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const db = self.db orelse return out;
        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db, "SELECT " ++ cols ++ " FROM rook_tasks WHERE parent_id = 0 AND workspace = ? ORDER BY id DESC", -1, &stmt, null) != regdb.OK)
            return out;
        defer _ = regdb.sqlite3_finalize(stmt);
        _ = regdb.sqlite3_bind_text(stmt, 1, workspace.ptr, @intCast(workspace.len), regdb.STATIC);
        collect(&out, stmt);
        return out;
    }

    fn query(self: Store, gpa: std.mem.Allocator, sql: [*:0]const u8, id: i64) List {
        var out: List = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const db = self.db orelse return out;
        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != regdb.OK) return out;
        defer _ = regdb.sqlite3_finalize(stmt);
        _ = regdb.sqlite3_bind_int64(stmt, 1, id);
        collect(&out, stmt);
        return out;
    }
};

/// Drain a prepared statement into `out`. Any allocation failure stops
/// the scan and keeps what was read — a short list beats no list, and it
/// matches how every other read here fails open.
fn collect(out: *List, stmt: ?*anyopaque) void {
    const a = out.arena.allocator();
    var list: std.ArrayListUnmanaged(Task) = .empty;
    while (regdb.sqlite3_step(stmt) == regdb.ROW) {
        const t: Task = .{
            .id = regdb.sqlite3_column_int64(stmt, 0),
            .parent_id = regdb.sqlite3_column_int64(stmt, 1),
            .workspace = a.dupe(u8, regdb.text(stmt, 2)) catch break,
            .work_type = a.dupe(u8, regdb.text(stmt, 3)) catch break,
            .state = a.dupe(u8, regdb.text(stmt, 4)) catch break,
            .title = a.dupe(u8, regdb.text(stmt, 5)) catch break,
            .anchor_kind = a.dupe(u8, regdb.text(stmt, 6)) catch break,
            .path = a.dupe(u8, regdb.text(stmt, 7)) catch break,
            .start_line = clampLine(regdb.sqlite3_column_int64(stmt, 8)),
            .end_line = clampLine(regdb.sqlite3_column_int64(stmt, 9)),
            .side = a.dupe(u8, regdb.text(stmt, 10)) catch break,
            .blob_sha = a.dupe(u8, regdb.text(stmt, 11)) catch break,
            .commit_sha = a.dupe(u8, regdb.text(stmt, 12)) catch break,
            .anchor_text = a.dupe(u8, regdb.text(stmt, 13)) catch break,
            .anchor_ref = a.dupe(u8, regdb.text(stmt, 14)) catch break,
            .origin = a.dupe(u8, regdb.text(stmt, 15)) catch break,
            .source_ref = a.dupe(u8, regdb.text(stmt, 16)) catch break,
            .detail = blk: {
                const d = regdb.text(stmt, 17);
                break :blk a.dupe(u8, if (d.len == 0) "{}" else d) catch break;
            },
            .created_at = a.dupe(u8, regdb.text(stmt, 18)) catch break,
            .updated_at = a.dupe(u8, regdb.text(stmt, 19)) catch break,
        };
        list.append(a, t) catch break;
    }
    out.items = list.items;
}

/// Line numbers are INTEGER in the schema and u32 here. A negative or
/// absurd value is corrupt rather than meaningful, and 0 is what an
/// un-anchored task already stores, so it is the honest floor.
fn clampLine(v: i64) u32 {
    if (v <= 0) return 0;
    if (v > std.math.maxInt(u32)) return 0;
    return @intCast(v);
}

// ---------------------------------------------------------------------
// The review work type's gate.
// ---------------------------------------------------------------------

pub const review = struct {
    pub const parent_state = "reviewing";
    pub const proposed = "proposed";
    pub const approved = "approved";
    pub const rejected = "rejected"; // wants change — blocks
    pub const deferred = "deferred"; // set aside deliberately — does not block
    pub const pending = "pending"; // conversation open — blocks

    /// Approved and deferred are the ONLY two non-blocking verdicts.
    ///
    /// Written as "not one of these two" rather than as a list of
    /// blocking states, exactly as the Go side is, and the difference
    /// matters: an unrecognised state BLOCKS. A gate that fails open on a
    /// token it does not know would let a review pass because of a typo
    /// or a newer host's vocabulary. Failing closed is at worst annoying;
    /// failing open is the thing this whole object exists to prevent.
    pub fn blocking(state: []const u8) bool {
        return !std.mem.eql(u8, state, approved) and !std.mem.eql(u8, state, deferred);
    }
};

pub const Gate = struct {
    ready: bool = false,
    /// The human action, from the parent's detail bag ("commit", "PR").
    /// A label, not a code path.
    verb: []const u8 = "",
    blocking: u32 = 0,
    total: u32 = 0,
};

/// The gate is a pure function of the children's states — no bespoke
/// readiness engine, and deliberately no per-state counts: the Go side
/// carries a Counts map for its JSON contract, and nothing on this side
/// reads it.
pub fn gateFromChildren(kids: []const Task, verb: []const u8) Gate {
    var g: Gate = .{ .verb = verb, .total = @intCast(kids.len) };
    for (kids) |c| {
        if (review.blocking(c.state)) g.blocking += 1;
    }
    g.ready = g.blocking == 0;
    return g;
}

// ---------------------------------------------------------------------

const testing = std.testing;
const testdb = @import("testdb.zig");

fn seed(p: [*:0]const u8) !void {
    try testdb.run(p, testdb.schema);
    try testdb.run(p,
        \\INSERT INTO rook_tasks (id, parent_id, workspace, work_type, state, title,
        \\  anchor_kind, path, start_line, end_line, blob_sha, detail, created_at, updated_at)
        \\VALUES
        \\ (1, 0, 'src', 'review', 'reviewing', 'review head', 'ref', '', 0, 0, '', '{"verb":"commit"}', 't1', 't1'),
        \\ (2, 1, 'src', 'review', 'approved', 'ok',       'code', 'a.zig', 10, 12, 'sha-a', '', 't1', 't1'),
        \\ (3, 1, 'src', 'review', 'rejected', 'wants fix','code', 'b.zig', 4,  4,  'sha-b', '', 't1', 't1'),
        \\ (4, 1, 'src', 'review', 'deferred', 'later',    'code', 'c.zig', 1,  2,  'sha-c', '', 't1', 't1'),
        \\ (5, 0, 'other', 'review', 'reviewing', 'elsewhere', 'ref', '', 0, 0, '', '', 't1', 't1');
    );
}

test "children come back in id order, with every column in its place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try testdb.path(&tmp, &buf);
    try seed(p);

    var store = Store.openPath(p);
    defer store.close();
    var kids = store.childrenOf(testing.allocator, 1);
    defer kids.deinit();

    try testing.expectEqual(@as(usize, 3), kids.items.len);
    try testing.expectEqual(@as(i64, 2), kids.items[0].id);
    try testing.expectEqualStrings("approved", kids.items[0].state);
    // Positional scan: a column-order drift shows up here first.
    try testing.expectEqualStrings("code", kids.items[1].anchor_kind);
    try testing.expectEqualStrings("b.zig", kids.items[1].path);
    try testing.expectEqual(@as(u32, 4), kids.items[1].start_line);
    try testing.expectEqualStrings("sha-b", kids.items[1].blob_sha);
    // Schema defaults still arrive as values.
    try testing.expectEqualStrings("modified", kids.items[1].side);
    try testing.expectEqualStrings("rook", kids.items[1].origin);
}

test "an empty detail column reads as an empty bag, not as empty text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try testdb.path(&tmp, &buf);
    try seed(p);

    var store = Store.openPath(p);
    defer store.close();
    var kids = store.childrenOf(testing.allocator, 1);
    defer kids.deinit();
    // "" would make every client's JSON parse fail; the Go scan does the
    // same substitution.
    try testing.expectEqualStrings("{}", kids.items[0].detail);

    var parent = store.get(testing.allocator, 1);
    defer parent.deinit();
    try testing.expectEqualStrings("{\"verb\":\"commit\"}", parent.items[0].detail);
}

test "roots are per workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try testdb.path(&tmp, &buf);
    try seed(p);

    var store = Store.openPath(p);
    defer store.close();
    var r = store.roots(testing.allocator, "src");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.items.len);
    try testing.expectEqual(@as(i64, 1), r.items[0].id);

    var none = store.roots(testing.allocator, "nosuch");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
}

test "a missing db is an empty list, never a crash" {
    var store = Store.openPath("/nonexistent/rook/rook.db");
    defer store.close();
    var r = store.childrenOf(testing.allocator, 1);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.items.len);
}

test "the gate blocks on anything that is not approved or deferred" {
    const kids = [_]Task{
        .{ .state = review.approved },
        .{ .state = review.deferred },
    };
    const open_gate = gateFromChildren(&kids, "commit");
    try testing.expect(open_gate.ready);
    try testing.expectEqual(@as(u32, 0), open_gate.blocking);
    try testing.expectEqual(@as(u32, 2), open_gate.total);
    try testing.expectEqualStrings("commit", open_gate.verb);

    const blocked = [_]Task{
        .{ .state = review.approved },
        .{ .state = review.rejected },
        .{ .state = review.proposed },
        .{ .state = review.pending },
    };
    const shut = gateFromChildren(&blocked, "PR");
    try testing.expect(!shut.ready);
    try testing.expectEqual(@as(u32, 3), shut.blocking);
}

test "an unknown state blocks — the gate fails closed" {
    // The property worth stating out loud: a token this build does not
    // recognise (a typo, or a newer host's vocabulary) must not open the
    // gate. Failing closed is annoying; failing open defeats the object.
    try testing.expect(review.blocking("wat"));
    try testing.expect(review.blocking(""));
    const kids = [_]Task{.{ .state = "some-future-verdict" }};
    try testing.expect(!gateFromChildren(&kids, "commit").ready);
}

test "no children is an open gate" {
    // A review with nothing in it is ready by definition — "no
    // descendant leaf is in a blocking state" is vacuously true, and the
    // Go side agrees.
    const g = gateFromChildren(&.{}, "commit");
    try testing.expect(g.ready);
    try testing.expectEqual(@as(u32, 0), g.total);
}
