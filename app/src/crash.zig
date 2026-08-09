//! Crash capture v1: the dying process writes its own record.
//!
//! A crash today kills every shell in every pane (rook owns its ptys
//! in-process — STATUS.md's accepted regression) and, until this file,
//! left no evidence at all: the worst possible combination. This is
//! the smallest honest fix, zed's lesson stack applied before the
//! bugs rather than after (docs/zed-analysis.md, operations):
//!
//!   - The record is a JSON sidecar under $XDG_STATE_HOME/rook/crashes,
//!     written through a fd OPENED AT STARTUP — a crashing process
//!     cannot be trusted to open files, allocate, or take locks, so
//!     the handler only ever write(2)s to a descriptor it already
//!     holds. Everything expensive happened at install time.
//!   - One record per crash, enforced by an atomic swap: rook runs a
//!     render thread, pty pumps, and ctl threads, and a fatal signal
//!     can land on any of them (zed hung an app mid-crash learning
//!     this — their c5ee3f3e2e). Nobody suspends anybody.
//!   - A clean exit leaves the sidecar EMPTY, and the next launch's
//!     sweep deletes empty files — so there is no exit hook to forget,
//!     and anything non-empty in the directory is a real crash.
//!   - Dev builds don't capture (their crashes are being watched
//!     live, and unversioned records are noise — zed refuses them
//!     too, 021681d456); ROOK_CRASH_CAPTURE=1 overrides, which is
//!     also how the e2e drives this.
//!
//! Reading a record: addresses are raw with the ASLR slide alongside.
//! Against the archived unstripped binary of the same build
//! (bin/dist/debug/, kept per release):
//!
//!   atos -o rook-vX.Y.Z-unstripped -s <slide> <addr addr ...>
//!
//! Out-of-process capture (rook spawning itself as a dump server, the
//! zed/crashpad shape) is the v2 when a corrupt heap eats one of
//! these; the sidecar format is already what that server would write.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
// VARIADIC, and the declaration must say so: open(2)'s mode is a
// vararg, and on arm64 varargs travel on the stack while fixed args
// ride registers — a fixed-3-arg declaration puts the mode where
// libc never looks, and the sidecar came out mode 0310, unreadable
// by its own owner. (fcntl above the pty gets this right for the
// same reason.)
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

// Directory iteration, libc-direct like everything else in this file:
// std.fs sits behind the Io handle in Zig 0.16, and a crash module
// wants the fewest moving parts it can have. The dirent layout is
// macOS arm64's (64-bit-inode is the only ABI there).
const DIR = opaque {};
const Dirent = extern struct {
    ino: u64,
    seekoff: u64,
    reclen: u16,
    namlen: u16,
    dtype: u8,
    name: [1024]u8,
};
extern "c" fn opendir(path: [*:0]const u8) ?*DIR;
extern "c" fn readdir(d: *DIR) ?*Dirent;
extern "c" fn closedir(d: *DIR) c_int;

const O_RDONLY = 0x0000;
const O_WRONLY = 0x0001;
const O_CREAT = 0x0200;
const O_TRUNC = 0x0400;
const DT_REG = 8;

/// The pre-opened sidecar. -1 = capture not installed (dev build, or
/// an unwritable state dir) — every handler falls through to default
/// behavior.
var sidecar_fd: std.atomic.Value(i32) = .init(-1);

/// First crash wins. The losers restore the default disposition and
/// re-raise, so the process still dies of its original cause.
var taken: std.atomic.Value(bool) = .init(false);

/// The JSON head, built at install time so the handler only copies
/// bytes: {"version":…,"build":…,"pid":…,"started":…,"reason":"
var head: [512]u8 = undefined;
var head_len: usize = 0;

/// Signal stack: a stack overflow IS a SIGSEGV, and it arrives with no
/// room to run a handler on the faulted stack.
var alt_stack: [64 * 1024]u8 align(16) = undefined;

/// Crashes found by the launch sweep — non-empty sidecars from earlier
/// sessions. The app surfaces this once the attention machinery is up.
pub var unread: usize = 0;

/// The signals that mean "the program is wrong", as opposed to the
/// lifecycle ones (HUP/INT/TERM) that mean "stop".
const fatal_signals = [_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .TRAP, .ABRT };

/// Resolve the crashes directory into `buf`:
/// $XDG_STATE_HOME/rook/crashes, else ~/.local/state/rook/crashes —
/// the state-dir shape everything else in the app uses for data.
pub fn dirPath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_STATE_HOME")) |x|
        return std.fmt.bufPrint(buf, "{s}/rook/crashes", .{std.mem.span(x)}) catch null;
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/rook/crashes", .{std.mem.span(home)}) catch null;
}

/// Sweep old sidecars and arm capture for this process. Called once,
/// early in the `win` path — before AppKit, so an init crash is still
/// a record. Never fails: a refused directory just means no capture,
/// which is where rook stood for its whole life until now.
pub fn install(version: []const u8, build_id: []const u8) void {
    var dbuf: [1024]u8 = undefined;
    const dir_path = dirPath(&dbuf) orelse return;
    makeDirs(dir_path);

    // The sweep: empty files are clean exits (see the header), gone.
    // Non-empty ones are crashes nobody has looked at yet. Emptiness
    // is probed by reading a byte — one open beats declaring struct
    // stat's ABI for a size field.
    var zbuf: [1100]u8 = undefined;
    if (opendir(toZ(&zbuf, dir_path) orelse return)) |d| {
        defer _ = closedir(d);
        while (readdir(d)) |ent| {
            if (ent.dtype != DT_REG) continue;
            var pbuf: [1300]u8 = undefined;
            const p = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ dir_path, ent.name[0..ent.namlen] }) catch continue;
            const fd = open(p.ptr, O_RDONLY);
            if (fd < 0) continue;
            var probe: [1]u8 = undefined;
            const got = read(fd, &probe, 1);
            _ = close(fd);
            if (got <= 0) _ = unlink(p.ptr) else unread += 1;
        }
    }

    // Dev builds sweep (the notice must still fire) but do not arm:
    // a dev crash is being watched live in a terminal, and an
    // unversioned record cannot be symbolicated against anything.
    const dev = std.mem.eql(u8, build_id, "dev");
    if (dev and getenv("ROOK_CRASH_CAPTURE") == null) return;

    var pbuf: [1200]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pbuf, "{s}/crash-{d}-{d}.json", .{
        dir_path, getpid(), time(null),
    }) catch return;
    const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o600));
    if (fd < 0) return;

    head_len = (std.fmt.bufPrint(&head, "{{\"version\":\"{s}\",\"build\":\"{s}\",\"pid\":{d},\"started\":{d},\"reason\":\"", .{
        version, build_id, getpid(), time(null),
    }) catch return).len;
    sidecar_fd.store(fd, .release);

    // The handlers, on their own stack — a stack overflow needs one.
    std.posix.sigaltstack(&.{
        .sp = &alt_stack,
        .size = alt_stack.len,
        .flags = 0,
    }, null) catch {};
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = &signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
    };
    for (fatal_signals) |sig| std.posix.sigaction(sig, &act, null);

    // The e2e's way in: a sandboxed instance told to crash, so the
    // scenario can assert the record exists. Two spellings, one per
    // capture path.
    if (getenv("ROOK_CRASH_TEST")) |mode| {
        if (std.mem.eql(u8, std.mem.span(mode), "segv")) {
            @as(*volatile u8, @ptrFromInt(0xbad)).* = 1;
        } else {
            @panic("crash test requested by ROOK_CRASH_TEST");
        }
    }
}

/// The root-module panic override's target (main.zig declares the
/// override; the handler lives here with its machinery). Records,
/// then hands the panic to the default path — which still prints to
/// stderr for a terminal launch, and aborts, which our ABRT handler
/// passes through because the record is already taken.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    record("panic: ", msg, first_trace_addr, 0);
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn signalHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const name: []const u8 = switch (sig) {
        .SEGV => "signal: SIGSEGV",
        .BUS => "signal: SIGBUS",
        .ILL => "signal: SIGILL",
        .FPE => "signal: SIGFPE",
        .TRAP => "signal: SIGTRAP",
        .ABRT => "signal: SIGABRT",
        else => "signal: ?",
    };
    const fault: usize = @intFromPtr(info.addr);
    record(name, "", null, fault);
    // Die of the original cause: default disposition back, re-raise.
    // For the guard's losers this is the ONLY effect, which is the
    // point — one record, everybody still dies honestly.
    var dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    std.posix.raise(sig) catch {};
}

/// Async-signal-safe by construction: an atomic, write(2), fsync(2),
/// stack formatting into local buffers. No allocator, no locks, no
/// std.fs. The fsync after the reason line is deliberate — if the
/// frame walk below faults on a corrupt chain, the cause is already
/// on disk.
fn record(kind: []const u8, msg: []const u8, first_trace_addr: ?usize, fault: usize) void {
    if (taken.swap(true, .acq_rel)) return;
    const fd = sidecar_fd.load(.acquire);
    if (fd < 0) return;

    w(fd, head[0..head_len]);
    w(fd, kind);
    writeEscaped(fd, msg);
    w(fd, "\"");
    _ = fsync(fd);

    var nbuf: [32]u8 = undefined;
    if (fault != 0) {
        w(fd, ",\"fault\":\"");
        w(fd, std.fmt.bufPrint(&nbuf, "0x{x}", .{fault}) catch "");
        w(fd, "\"");
    }

    w(fd, ",\"addrs\":[");
    var addrs: [64]usize = undefined;
    const n = walkFp(first_trace_addr, &addrs);
    for (addrs[0..n], 0..) |a, i| {
        if (i > 0) w(fd, ",");
        w(fd, "\"");
        w(fd, std.fmt.bufPrint(&nbuf, "0x{x}", .{a}) catch "");
        w(fd, "\"");
    }
    w(fd, "],\"slide\":\"");
    w(fd, std.fmt.bufPrint(&nbuf, "0x{x}", .{@as(usize, @bitCast(_dyld_get_image_vmaddr_slide(0)))}) catch "");
    w(fd, "\"}\n");
    _ = fsync(fd);
}

fn w(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// JSON string escaping, the minimal signal-safe kind: quotes and
/// backslashes escaped, control bytes flattened to '.', everything
/// else copied. A panic message is diagnostic prose, not data — '.'
/// where a newline was reads fine in `rook crashes`.
fn writeEscaped(fd: i32, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    for (msg) |c| {
        if (n + 2 > buf.len) {
            w(fd, buf[0..n]);
            n = 0;
        }
        switch (c) {
            '"', '\\' => {
                buf[n] = '\\';
                buf[n + 1] = c;
                n += 2;
            },
            0...0x1f => {
                buf[n] = '.';
                n += 1;
            },
            else => {
                buf[n] = c;
                n += 1;
            },
        }
    }
    w(fd, buf[0..n]);
}

/// `ctl crashes` — every non-empty sidecar, one line each: the file
/// name, then the record's reason field, which is the first thing a
/// human wants and the only part worth parsing here. Written into
/// `out`; the current session's own (empty) sidecar never lists,
/// because empty is the not-crashed state.
pub fn list(dir_path: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var zbuf: [1100]u8 = undefined;
    const d = opendir(toZ(&zbuf, dir_path) orelse return "err bad path\n") orelse
        return "no crashes\n";
    defer _ = closedir(d);
    var any = false;
    while (readdir(d)) |ent| {
        if (ent.dtype != DT_REG) continue;
        var pbuf: [1300]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ dir_path, ent.name[0..ent.namlen] }) catch continue;
        const fd = open(p.ptr, O_RDONLY);
        if (fd < 0) continue;
        var doc: [512]u8 = undefined;
        const got = read(fd, &doc, doc.len);
        _ = close(fd);
        if (got <= 0) continue;
        any = true;
        const reason = reasonOf(doc[0..@intCast(got)]);
        const line = std.fmt.bufPrint(out[n..], "{s}\t{s}\n", .{ ent.name[0..ent.namlen], reason }) catch break;
        n += line.len;
    }
    if (!any) return "no crashes\n";
    return out[0..n];
}

/// The `"reason":"…"` field of a sidecar's head, unescaped enough to
/// read (this side wrote the escaping, so it knows the rules).
fn reasonOf(doc: []const u8) []const u8 {
    const key = "\"reason\":\"";
    const at = (std.mem.indexOf(u8, doc, key) orelse return "?") + key.len;
    var end = at;
    while (end < doc.len) : (end += 1) {
        if (doc[end] == '"' and doc[end - 1] != '\\') break;
    }
    return doc[at..end];
}

/// `ctl crashes clear` — delete every sidecar, including the live
/// session's empty one (its fd stays valid for writing; a crash after
/// a clear still records, the record is just unlinked — the next
/// session's sweep won't see it, which is the accepted cost of clear
/// meaning clear).
pub fn clearAll(dir_path: []const u8) usize {
    var n: usize = 0;
    var zbuf: [1100]u8 = undefined;
    const d = opendir(toZ(&zbuf, dir_path) orelse return 0) orelse return 0;
    defer _ = closedir(d);
    while (readdir(d)) |ent| {
        if (ent.dtype != DT_REG) continue;
        var pbuf: [1300]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ dir_path, ent.name[0..ent.namlen] }) catch continue;
        if (unlink(p.ptr) == 0) n += 1;
    }
    return n;
}

/// mkdir -p for the exactly-three levels the crashes dir can need
/// (state root, /rook, /crashes). Failures are ignored — the open()
/// that follows is the only verdict that matters.
fn makeDirs(dir_path: []const u8) void {
    var buf: [1100]u8 = undefined;
    var i: usize = 1;
    while (i <= dir_path.len) : (i += 1) {
        if (i == dir_path.len or dir_path[i] == '/') {
            const z = toZ(&buf, dir_path[0..i]) orelse return;
            _ = mkdir(z, 0o755);
        }
    }
}

fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Frame-pointer walk, guarded against the corrupt chains a crash
/// implies: alignment, monotonic growth, a plausible code address.
/// arm64 frame layout: [fp] = caller's fp, [fp+8] = return address.
/// A walk that faults anyway dies inside the handler with the reason
/// line already fsynced — see record().
fn walkFp(first_trace_addr: ?usize, out: []usize) usize {
    var n: usize = 0;
    if (first_trace_addr) |ra| {
        out[0] = ra;
        n = 1;
    }
    var fp: usize = @frameAddress();
    while (n < out.len) {
        if (fp == 0 or fp % 16 != 0) break;
        const next_fp = @as(*const usize, @ptrFromInt(fp)).*;
        const ra = @as(*const usize, @ptrFromInt(fp + 8)).*;
        if (ra < 0x10000) break;
        out[n] = ra;
        n += 1;
        if (next_fp <= fp) break;
        fp = next_fp;
    }
    return n;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the sidecar head is one valid JSON prefix" {
    // The handler appends to this blind, so its shape is load-bearing:
    // head + reason + closer must parse. Build a head the way install
    // does and close it the way record does.
    var h: [512]u8 = undefined;
    const head_s = try std.fmt.bufPrint(&h, "{{\"version\":\"{s}\",\"build\":\"{s}\",\"pid\":{d},\"started\":{d},\"reason\":\"", .{
        "0.41.0", "abc123.456", 42, 1700000000,
    });
    var full: [1024]u8 = undefined;
    const doc = try std.fmt.bufPrint(&full, "{s}panic: index out of bounds\",\"addrs\":[\"0x1000\",\"0x2000\"],\"slide\":\"0x4000\"}}\n", .{head_s});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("0.41.0", parsed.value.object.get("version").?.string);
    try testing.expect(parsed.value.object.get("addrs").?.array.items.len == 2);
}

test "the frame walk survives this stack and caps" {
    var addrs: [8]usize = undefined;
    const n = walkFp(@returnAddress(), &addrs);
    try testing.expect(n >= 1);
    try testing.expect(n <= addrs.len);
    try testing.expectEqual(@returnAddress(), addrs[0]);
}
