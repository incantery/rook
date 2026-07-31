//! The anchor blob store — READ side.
//!
//! `anchor_blobs(sha, content)` holds the file snapshots an anchor was
//! taken against. Re-anchoring needs exactly one thing from it: given a
//! stored blob sha, the content that sha names, so the current file can
//! be diffed against it.
//!
//! Read-only on purpose, and it is not a gap. anchorNow only ever reads;
//! every WRITE to this table happens inside the transaction that creates
//! the thread or prepares the review, precisely so pruneAnchorBlobs can
//! never race a half-created row. Those live in the Go host and stay
//! there until the thread and review writers come across — porting the
//! reads first is what lets the two halves coexist without a second
//! writer appearing against a schema the host still owns.
//!
//! A missing row is not an error here. The Go side treats it as "the
//! snapshot was pruned — fail open, mark the anchor outdated, render it
//! from stored text", and so must this: an anchor degrades, it never
//! errors.

const std = @import("std");
const regdb = @import("regdb.zig");

/// An open handle on the registry. Held across a re-anchoring pass so a
/// poll that re-anchors N threads opens the db once, not N times.
pub const Store = struct {
    db: ?*anyopaque,

    pub fn open() Store {
        return .{ .db = regdb.open() };
    }

    pub fn openPath(path: [*:0]const u8) Store {
        return .{ .db = regdb.openPath(path) };
    }

    pub fn close(self: *Store) void {
        regdb.close(self.db);
        self.db = null;
    }

    /// Content for `sha`, or null when there is no such row (pruned,
    /// never captured, or no db at all). Caller owns the result.
    ///
    /// The row-exists test is sqlite3_step's verdict, NOT whether the
    /// blob pointer came back non-null: sqlite3_column_blob returns NULL
    /// for a ZERO-LENGTH blob, and an empty file is a perfectly ordinary
    /// anchor target — git even has a canonical hash for it
    /// (e69de29bb2…). Reading the pointer as presence would report every
    /// empty snapshot as pruned, and the anchor on it as outdated,
    /// forever.
    pub fn get(self: Store, gpa: std.mem.Allocator, sha: []const u8) ?[]u8 {
        const db = self.db orelse return null;
        var stmt: ?*anyopaque = null;
        if (regdb.sqlite3_prepare_v2(db, "SELECT content FROM anchor_blobs WHERE sha = ?", -1, &stmt, null) != regdb.OK)
            return null;
        defer _ = regdb.sqlite3_finalize(stmt);

        // STATIC is safe: `sha` outlives the step below.
        if (regdb.sqlite3_bind_text(stmt, 1, sha.ptr, @intCast(sha.len), regdb.STATIC) != regdb.OK)
            return null;
        if (regdb.sqlite3_step(stmt) != regdb.ROW) return null;

        const n = regdb.sqlite3_column_bytes(stmt, 0);
        if (n <= 0) return gpa.alloc(u8, 0) catch null; // present and empty
        const ptr = regdb.sqlite3_column_blob(stmt, 0) orelse return null;
        const bytes = @as([*]const u8, @ptrCast(ptr))[0..@intCast(n)];
        return gpa.dupe(u8, bytes) catch null;
    }
};

/// One-shot lookup for callers with a single anchor to resolve. Prefer
/// holding a Store when resolving more than one.
pub fn one(gpa: std.mem.Allocator, sha: []const u8) ?[]u8 {
    var s = Store.open();
    defer s.close();
    return s.get(gpa, sha);
}

// ---------------------------------------------------------------------
// Tests. These build a fixture db rather than touching the real
// registry — the write calls below exist ONLY here, which is also the
// enforcement of "read-only in production": production code has no
// symbol to write with.
// ---------------------------------------------------------------------

const testing = std.testing;
const testdb = @import("testdb.zig");

fn fixture(path: [*:0]const u8, sql: [*:0]const u8) !void {
    try testdb.run(path, testdb.schema);
    try testdb.run(path, sql);
}

const tmpDbPath = testdb.path;

test "a stored snapshot round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    try fixture(path,
        \\INSERT INTO anchor_blobs (sha, content) VALUES ('abc', 'l1
        \\l2
        \\');
    );

    var s = Store.openPath(path);
    defer s.close();
    const got = s.get(testing.allocator, "abc").?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("l1\nl2\n", got);
}

test "an empty snapshot is present, not pruned" {
    // The sqlite trap this module exists to not fall into:
    // sqlite3_column_blob returns NULL for a zero-length blob, so
    // presence has to come from step(). An empty file is a real anchor
    // target — git's e69de29bb2… is its blob hash.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    try fixture(path, "INSERT INTO anchor_blobs (sha, content) VALUES ('empty', x'');");

    var s = Store.openPath(path);
    defer s.close();
    const got = s.get(testing.allocator, "empty");
    try testing.expect(got != null); // NOT null — that would read as pruned
    defer testing.allocator.free(got.?);
    try testing.expectEqual(@as(usize, 0), got.?.len);
}

test "binary content survives, NULs and all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    try fixture(path, "INSERT INTO anchor_blobs (sha, content) VALUES ('bin', x'00ff0a00');");

    var s = Store.openPath(path);
    defer s.close();
    const got = s.get(testing.allocator, "bin").?;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff, 0x0a, 0x00 }, got);
}

test "a pruned sha is null, and so is a db that is not there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    try fixture(path, "INSERT INTO anchor_blobs (sha, content) VALUES ('abc', 'x');");

    var s = Store.openPath(path);
    defer s.close();
    try testing.expectEqual(@as(?[]u8, null), s.get(testing.allocator, "gone"));

    // No db at all — the machine that has never run the rest of rook.
    var missing = Store.openPath("/nonexistent/rook/rook.db");
    defer missing.close();
    try testing.expectEqual(@as(?[]u8, null), missing.get(testing.allocator, "abc"));
}
