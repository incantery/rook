//! The workspace registry — READ side. rook's wails app and rook-host
//! own ~/.local/share/rook/rook.db (XDG_DATA_HOME respected); rook
//! reads `workspaces(name, root, last_used)` through the system
//! libsqlite3, read-only, re-queried on every palette open so the list
//! always reflects what the rest of rook last touched. The db is WAL —
//! same-user read-only opens are safe alongside the host's writes.

const std = @import("std");
const regdb = @import("regdb.zig");

const sqlite3_prepare_v2 = regdb.sqlite3_prepare_v2;
const sqlite3_step = regdb.sqlite3_step;
const sqlite3_finalize = regdb.sqlite3_finalize;
const sqlite3_column_text = regdb.sqlite3_column_text;

const SQLITE_ROW = regdb.ROW;

pub const Entry = struct {
    name: []u8,
    root: []u8,
    /// Parent workspace name for worktree children (db `worktree_of`),
    /// empty for top-level. The palette groups children under their
    /// parent; "rook/zig" is rook's zig worktree.
    parent: []u8,
};

pub fn free(gpa: std.mem.Allocator, list: []Entry) void {
    for (list) |e| {
        gpa.free(e.name);
        gpa.free(e.root);
        gpa.free(e.parent);
    }
    gpa.free(list);
}

/// The root directory of one workspace by name, or null if the registry
/// has never heard of it. Caller owns the result.
///
/// Its own query rather than a scan of load(): callers that want one
/// root (re-anchoring, which needs somewhere to run git) should not pay
/// for the grouping pass, and load()'s result is ordered for a palette
/// rather than keyed for lookup.
pub fn rootOf(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    const db = regdb.open() orelse return null;
    defer regdb.close(db);
    var stmt: ?*anyopaque = null;
    if (regdb.sqlite3_prepare_v2(db, "SELECT root FROM workspaces WHERE name = ?", -1, &stmt, null) != regdb.OK)
        return null;
    defer _ = regdb.sqlite3_finalize(stmt);
    _ = regdb.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), regdb.STATIC);
    if (regdb.sqlite3_step(stmt) != regdb.ROW) return null;
    const root = regdb.text(stmt, 0);
    if (root.len == 0) return null;
    return gpa.dupe(u8, root) catch null;
}

/// The workspace this one is a worktree OF, or null for a top-level
/// workspace. Caller owns the result.
///
/// Its own query for the same reason rootOf has one. An empty
/// `worktree_of` reads as null rather than as an empty string, because
/// every caller's question is "is this a worktree" and a "" that has to
/// be length-checked downstream is how that turns into a lookup for the
/// workspace named "".
pub fn parentOf(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    const db = regdb.open() orelse return null;
    defer regdb.close(db);
    var stmt: ?*anyopaque = null;
    if (regdb.sqlite3_prepare_v2(db, "SELECT worktree_of FROM workspaces WHERE name = ?", -1, &stmt, null) != regdb.OK)
        return null;
    defer _ = regdb.sqlite3_finalize(stmt);
    _ = regdb.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), regdb.STATIC);
    if (regdb.sqlite3_step(stmt) != regdb.ROW) return null;
    const parent = regdb.text(stmt, 0);
    if (parent.len == 0) return null;
    return gpa.dupe(u8, parent) catch null;
}

/// Load workspaces GROUPED: top-level entries by last_used, each
/// followed by its worktree children (their own last_used order). A
/// missing db or any sqlite error is an EMPTY list, never a failure —
/// rook must run fine on a machine that has never seen the rest of
/// rook.
pub fn load(gpa: std.mem.Allocator) []Entry {
    var flat: std.ArrayListUnmanaged(Entry) = .empty;
    defer flat.deinit(gpa);
    const db = regdb.open() orelse return &.{};
    defer regdb.close(db);

    var stmt: ?*anyopaque = null;
    if (sqlite3_prepare_v2(db, "SELECT name, root, worktree_of FROM workspaces WHERE root != '' ORDER BY last_used DESC", -1, &stmt, null) != 0)
        return &.{};
    defer _ = sqlite3_finalize(stmt);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const name = sqlite3_column_text(stmt, 0) orelse continue;
        const root = sqlite3_column_text(stmt, 1) orelse continue;
        const parent = sqlite3_column_text(stmt, 2) orelse "";
        const e: Entry = .{
            .name = gpa.dupe(u8, std.mem.span(name)) catch continue,
            .root = gpa.dupe(u8, std.mem.span(root)) catch continue,
            .parent = gpa.dupe(u8, std.mem.span(parent)) catch continue,
        };
        flat.append(gpa, e) catch {
            gpa.free(e.name);
            gpa.free(e.root);
            gpa.free(e.parent);
            continue;
        };
    }

    // Group: parents keep recency order, children follow their parent.
    // An orphan child (parent row missing) stays top-level.
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    var taken = gpa.alloc(bool, flat.items.len) catch return flat.toOwnedSlice(gpa) catch &.{};
    defer gpa.free(taken);
    @memset(taken, false);
    for (flat.items, 0..) |e, i| {
        if (taken[i]) continue;
        if (e.parent.len > 0) {
            var has_parent = false;
            for (flat.items) |p| {
                if (std.mem.eql(u8, p.name, e.parent)) {
                    has_parent = true;
                    break;
                }
            }
            if (has_parent) continue; // placed under its parent below
        }
        taken[i] = true;
        out.append(gpa, e) catch continue;
        for (flat.items, 0..) |c, j| {
            if (!taken[j] and std.mem.eql(u8, c.parent, e.name)) {
                taken[j] = true;
                out.append(gpa, c) catch {};
            }
        }
    }
    // Anything never taken (append failures): free so nothing leaks.
    for (flat.items, 0..) |e, i| {
        if (!taken[i]) {
            gpa.free(e.name);
            gpa.free(e.root);
            gpa.free(e.parent);
        }
    }
    return out.toOwnedSlice(gpa) catch &.{};
}
