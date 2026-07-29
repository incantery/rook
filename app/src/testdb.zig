//! Building a registry fixture, for tests only.
//!
//! Everything in the substrate port reads rook.db read-only, which is the
//! design (regdb.zig says why). Tests still need rows to read, so the
//! WRITE calls live here and nowhere else — production code has no symbol
//! to mutate the registry with, and that is the enforcement rather than a
//! convention someone has to remember.
//!
//! Third copy of this plumbing was the trigger to extract it. Each test
//! root compiles separately, so nothing here reaches a shipped binary.

const std = @import("std");
const regdb = @import("regdb.zig");

pub extern "c" fn sqlite3_exec(db: ?*anyopaque, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
pub extern "c" fn sqlite3_bind_blob(stmt: ?*anyopaque, idx: c_int, data: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;

const OPEN_READWRITE: c_int = 2;
const OPEN_CREATE: c_int = 4;

/// Path to a db inside `tmp`. sqlite opens by path and 0.16's Io.Dir has
/// no realpath, so this spells out the layout testing.tmpDir builds —
/// .zig-cache/tmp/<sub_path>, relative to cwd, which is the build root
/// under both `zig build test` and a bare `zig test`. If a future std
/// moves it, tests fail on a missing db rather than quietly reading the
/// real registry.
pub fn path(tmp: *std.testing.TmpDir, buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/rook.db", .{tmp.sub_path});
}

/// Open (creating if needed) a writable fixture db.
pub fn open(p: [*:0]const u8) !?*anyopaque {
    var db: ?*anyopaque = null;
    if (regdb.sqlite3_open_v2(p, &db, OPEN_READWRITE | OPEN_CREATE, null) != regdb.OK) {
        _ = regdb.sqlite3_close(db);
        return error.OpenFixture;
    }
    return db;
}

pub fn exec(db: ?*anyopaque, sql: [*:0]const u8) !void {
    if (sqlite3_exec(db, sql, null, null, null) != regdb.OK) return error.ExecFixture;
}

/// Run `sql` against a fresh handle on `p` and close it again.
pub fn run(p: [*:0]const u8, sql: [*:0]const u8) !void {
    const db = try open(p);
    defer _ = regdb.sqlite3_close(db);
    try exec(db, sql);
}

/// The subset of rook's schema the read-side ports touch. Kept verbatim
/// from internal/host/registry.go — a fixture that drifts from the real
/// schema tests nothing, and column ORDER is what the scans depend on.
pub const schema =
    \\CREATE TABLE IF NOT EXISTS anchor_blobs (
    \\  sha     TEXT PRIMARY KEY,
    \\  content BLOB NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS rook_tasks (
    \\  id           INTEGER PRIMARY KEY,
    \\  parent_id    INTEGER NOT NULL DEFAULT 0,
    \\  workspace    TEXT    NOT NULL,
    \\  work_type    TEXT    NOT NULL,
    \\  state        TEXT    NOT NULL,
    \\  title        TEXT    NOT NULL DEFAULT '',
    \\  anchor_kind  TEXT    NOT NULL DEFAULT 'none',
    \\  path         TEXT    NOT NULL DEFAULT '',
    \\  start_line   INTEGER NOT NULL DEFAULT 0,
    \\  end_line     INTEGER NOT NULL DEFAULT 0,
    \\  side         TEXT    NOT NULL DEFAULT 'modified',
    \\  blob_sha     TEXT    NOT NULL DEFAULT '',
    \\  commit_sha   TEXT    NOT NULL DEFAULT '',
    \\  anchor_text  TEXT    NOT NULL DEFAULT '',
    \\  anchor_ref   TEXT    NOT NULL DEFAULT '',
    \\  origin       TEXT    NOT NULL DEFAULT 'rook',
    \\  source_ref   TEXT    NOT NULL DEFAULT '',
    \\  detail       TEXT    NOT NULL DEFAULT '',
    \\  created_at   TEXT    NOT NULL,
    \\  updated_at   TEXT    NOT NULL
    \\);
;
