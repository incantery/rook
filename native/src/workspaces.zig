//! The workspace registry — READ side. rook's wails app and rook-host
//! own ~/.local/share/rook/rook.db (XDG_DATA_HOME respected); rookz
//! reads `workspaces(name, root, last_used)` through the system
//! libsqlite3, read-only, re-queried on every palette open so the list
//! always reflects what the rest of rook last touched. The db is WAL —
//! same-user read-only opens are safe alongside the host's writes.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// libsqlite3 (system): the six calls a read-only query needs.
extern "c" fn sqlite3_open_v2(path: [*:0]const u8, db: *?*anyopaque, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(db: ?*anyopaque) c_int;
extern "c" fn sqlite3_prepare_v2(db: ?*anyopaque, sql: [*:0]const u8, n: c_int, stmt: *?*anyopaque, tail: ?*?[*:0]const u8) c_int;
extern "c" fn sqlite3_step(stmt: ?*anyopaque) c_int;
extern "c" fn sqlite3_finalize(stmt: ?*anyopaque) c_int;
extern "c" fn sqlite3_column_text(stmt: ?*anyopaque, col: c_int) ?[*:0]const u8;
extern "c" fn sqlite3_busy_timeout(db: ?*anyopaque, ms: c_int) c_int;

const SQLITE_OPEN_READONLY: c_int = 1;
const SQLITE_ROW: c_int = 100;

pub const Entry = struct {
    name: []u8,
    root: []u8,
};

pub fn free(gpa: std.mem.Allocator, list: []Entry) void {
    for (list) |e| {
        gpa.free(e.name);
        gpa.free(e.root);
    }
    gpa.free(list);
}

fn dbPath(buf: []u8) ?[:0]const u8 {
    if (getenv("XDG_DATA_HOME")) |x| {
        return std.fmt.bufPrintZ(buf, "{s}/rook/rook.db", .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/share/rook/rook.db", .{std.mem.span(home)}) catch null;
}

/// Load workspaces, most recently used first. A missing db or any
/// sqlite error is an EMPTY list, never a failure — rookz must run
/// fine on a machine that has never seen the rest of rook.
pub fn load(gpa: std.mem.Allocator) []Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    var pathbuf: [1024]u8 = undefined;
    const path = dbPath(&pathbuf) orelse return &.{};

    var db: ?*anyopaque = null;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, null) != 0) {
        _ = sqlite3_close(db); // sqlite allocates a handle even on error
        return &.{};
    }
    defer _ = sqlite3_close(db);
    _ = sqlite3_busy_timeout(db, 200);

    var stmt: ?*anyopaque = null;
    if (sqlite3_prepare_v2(db, "SELECT name, root FROM workspaces WHERE root != '' ORDER BY last_used DESC", -1, &stmt, null) != 0)
        return &.{};
    defer _ = sqlite3_finalize(stmt);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const name = sqlite3_column_text(stmt, 0) orelse continue;
        const root = sqlite3_column_text(stmt, 1) orelse continue;
        const e: Entry = .{
            .name = gpa.dupe(u8, std.mem.span(name)) catch continue,
            .root = gpa.dupe(u8, std.mem.span(root)) catch continue,
        };
        out.append(gpa, e) catch {
            gpa.free(e.name);
            gpa.free(e.root);
            continue;
        };
    }
    return out.toOwnedSlice(gpa) catch &.{};
}
