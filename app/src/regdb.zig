//! rook's registry db, from the Zig side: where it lives and the handful
//! of libsqlite3 calls a reader needs.
//!
//! rook-host owns ~/.local/share/rook/rook.db (XDG_DATA_HOME respected)
//! and is the only writer. Everything here opens READ-ONLY. The db is
//! WAL, so same-user read-only opens are safe alongside the host's
//! writes, and read-only is also the honest statement of the migration's
//! current state: the Go host still owns every mutation, and a second
//! writer against a schema it also owns is how you get a half-created
//! thread whose snapshot has already been pruned.
//!
//! This exists as its own module because the path is the thing two
//! readers must never disagree about. A reader looking in the wrong
//! place does not error — it finds no db and returns empty, which reads
//! as "you have no workspaces" or "that snapshot was pruned" rather than
//! as a bug.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// libsqlite3 (system): what a read-only parameterised query needs.
pub extern "c" fn sqlite3_open_v2(path: [*:0]const u8, db: *?*anyopaque, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close(db: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: ?*anyopaque, sql: [*:0]const u8, n: c_int, stmt: *?*anyopaque, tail: ?*?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_column_text(stmt: ?*anyopaque, col: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_column_blob(stmt: ?*anyopaque, col: c_int) ?*const anyopaque;
pub extern "c" fn sqlite3_column_bytes(stmt: ?*anyopaque, col: c_int) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: ?*anyopaque, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
pub extern "c" fn sqlite3_busy_timeout(db: ?*anyopaque, ms: c_int) c_int;

pub const OPEN_READONLY: c_int = 1;
pub const ROW: c_int = 100;
pub const OK: c_int = 0;

/// Bind without copying. Safe only while the bound slice outlives the
/// step() that reads it — which is every call site here, since they bind
/// a caller's slice and step before returning.
pub const STATIC: ?*const anyopaque = null;

/// Where the registry lives. Mirrors internal/config's resolution: XDG
/// first, then ~/.local/share.
pub fn dbPath(buf: []u8) ?[:0]const u8 {
    if (getenv("XDG_DATA_HOME")) |x| {
        return std.fmt.bufPrintZ(buf, "{s}/rook/rook.db", .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/share/rook/rook.db", .{std.mem.span(home)}) catch null;
}

/// Open the registry read-only. Null on any failure — a machine that has
/// never run the rest of rook is a normal state, not an error.
pub fn open() ?*anyopaque {
    var buf: [1024]u8 = undefined;
    return openPath(dbPath(&buf) orelse return null);
}

/// Open a specific db read-only. Separate from open() so tests can point
/// at a fixture without reaching through the environment.
pub fn openPath(path: [*:0]const u8) ?*anyopaque {
    var db: ?*anyopaque = null;
    if (sqlite3_open_v2(path, &db, OPEN_READONLY, null) != OK) {
        _ = sqlite3_close(db); // sqlite allocates a handle even on error
        return null;
    }
    _ = sqlite3_busy_timeout(db, 200);
    return db;
}

pub fn close(db: ?*anyopaque) void {
    _ = sqlite3_close(db);
}
