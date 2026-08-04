//! rook's plugin client: read the declarations, spawn what they name,
//! speak the protocol, and refuse what was not granted.
//!
//! A plugin is a separate process reading newline-delimited JSON on stdin
//! and writing it on stdout. The protocol, its SDK and the demos live in
//! incantery/rook-demos; this is the host end.
//!
//! # Declared, granted, and what the plugin wants
//!
//! Three different things, and keeping them apart is the point:
//!
//!   config says a plugin EXISTS       (a `plugin` node — a plugin rook
//!                                      was never told about does not run)
//!   config says what it MAY do        (`grants`)
//!   the plugin says what it WANTS     (`describe`.capabilities)
//!
//! The gap between the last two is the trust surface: a plugin asking for
//! more than it was granted is not an error, it is a fact to show a human
//! before anything runs (docs/environments/VISION.md). So `describe` is
//! recorded verbatim, `call` enforces grants, and `ctl plugins` prints
//! both.
//!
//! # Lazy by default
//!
//! Nothing spawns until something asks. Every poller rook ever had learned
//! this expensively — a surface nobody opened must cost nothing — so
//! `load: "lazy"` is the default and `eager` is the deliberate exception.
//!
//! # Fail open, and say which
//!
//! A plugin that will not spawn, will not answer, or answers garbage is a
//! plugin that is missing, never a launch that breaks. Every failure is
//! recorded on the handle so `ctl plugins` can show it, because "the panel
//! is empty" and "the plugin died" look identical from the outside and are
//! not the same problem.
//!
//! # Both directions, and why that needs a pump
//!
//! rook asks (`items.list`, `items.act`) and the plugin asks back
//! (`attention.raise`, `session.spawn`). The second direction is the whole
//! reason there is a thread here instead of a blocking read.
//!
//! A plugin that can only speak when spoken to cannot raise attention: the
//! event that needs a human happens when nobody is asking, and a frame
//! nobody reads sits in a pipe. So the pump owns `from_child` and runs for
//! as long as the plugin is up. Responses go to whoever is waiting;
//! requests are dispatched. `lsp.zig` has the same shape for the same
//! reason — a language server publishes diagnostics unprompted too.
//!
//! The interleaving is the part that would break a naive client: a plugin
//! may raise attention WHILE answering an items.act, so a reader that
//! assumed the next frame was its response would take the request for an
//! answer, fail the id check, and kill a plugin that did nothing wrong.
//!
//! `grants` covers both directions, because it is a list of capabilities
//! rather than a list of things rook may do. `items.list` granted means
//! rook may ask; `session.spawn` granted means the plugin may. The
//! direction is inherent to the verb, and one list is what a human can
//! actually read.

const std = @import("std");
const cfgpkg = @import("config.zig");

// ---- syscalls (the set lsp.zig proved) ----

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
const POLLIN: i16 = 0x0001;
const O_WRONLY: c_int = 0x0001;
const SIGKILL: c_int = 9;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn poll(fds: [*]PollFd, n: c_uint, timeout: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn os_unfair_lock_lock(lock: *u32) void;
extern "c" fn os_unfair_lock_unlock(lock: *u32) void;

/// The same lock lsp.zig and session.zig use. std has no Mutex in this Zig
/// and the app has settled on os_unfair_lock; a third answer here would be
/// a third thing to reason about.
const Lock = struct {
    raw: u32 = 0,
    fn lock(self: *Lock) void {
        os_unfair_lock_lock(&self.raw);
    }
    fn unlock(self: *Lock) void {
        os_unfair_lock_unlock(&self.raw);
    }
};

// macOS `struct timeval`. CACurrentMediaTime is the app's clock, but it
// lives in QuartzCore and this file has its own test root that links only
// libc — a deadline that cannot be tested is not a deadline.
const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;

fn nowMs() i64 {
    var tv: timeval = undefined;
    if (gettimeofday(&tv, null) != 0) return 0;
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

/// Protocol version. A plugin answering a version we do not know is
/// refused rather than guessed — unlike config, where failing open is
/// right, acting on a misread frame would ACT.
pub const version = 1;

/// What the caller waits, and what it ASKS the plugin to wait.
///
/// The ask is shorter by `grace_ms`: without that, a cooperative plugin
/// answering exactly at its deadline races our timer and loses about half
/// the time, and the failure reads as a flaky plugin rather than as a host
/// that never gave it a chance. rook's old provider client found this the
/// hard way; the value is the same.
pub const default_deadline_ms: i32 = 10_000;
pub const grace_ms: i32 = 250;

/// The largest frame the pump will assemble. A plugin that sends more than
/// this loses the frame and is told so — the alternative is a buffer that
/// grows until the app dies, which is a plugin taking rook with it.
pub const max_frame = 1 << 20;

/// The inbound verbs: the ones a PLUGIN calls.
pub const op_raise = "attention.raise";
pub const op_spawn = "session.spawn";
pub const op_send = "session.send";
pub const op_clipboard = "clipboard.set";

pub const Load = enum { lazy, eager };

/// One declaration, off the environment graph.
pub const Spec = struct {
    name: []const u8,
    argv: []const []const u8,
    load: Load = .lazy,
    grants: []const []const u8 = &.{},
    /// Where the binary comes FROM, when config named a source rather than
    /// a path. rook downloads it into a cache the human never types, which
    /// is the difference between declaring a plugin and installing one by
    /// hand and then pointing config at the result.
    source: []const u8 = "",
    /// The sha256 config PINNED, if it pinned one. Hex, lowercase.
    ///
    /// A pin is the strong form: it travels with the config, it is
    /// reviewable in a diff, and a remote that changes under you is caught
    /// on a machine that has never downloaded the old one. Without a pin
    /// rook still records what it first saw and refuses a cache that stops
    /// matching — but that only protects a machine that already fetched.
    sha256: []const u8 = "",

    pub fn granted(self: *const Spec, op: []const u8) bool {
        for (self.grants) |g| if (std.mem.eql(u8, g, op)) return true;
        return false;
    }
};

pub const State = enum { declared, up, failed };

/// Split a byte stream into newline-delimited frames.
///
/// Sans-io on purpose: framing is where a protocol client is usually
/// wrong, and every interesting case — a frame split across reads, several
/// frames in one read, a frame too big to hold — is reachable here without
/// a subprocess, a pipe or a clock.
///
/// A returned frame borrows `buf` and stays valid only until the next
/// `next()`, which is when the leftover is shifted down.
pub const FrameReader = struct {
    buf: [max_frame]u8 = undefined,
    used: usize = 0,
    consume: usize = 0,
    /// A frame that would not fit was thrown away, and the bytes after it
    /// are the tail of something the caller never saw. Reported rather
    /// than silently resynced: a caller that gets half a frame's worth of
    /// JSON should know why it did not parse.
    overflowed: bool = false,

    pub fn feed(self: *FrameReader, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const room = self.buf.len - self.used;
            if (room == 0) {
                // No newline in a full buffer: the frame is too big. Drop
                // what we have and resync on the next newline rather than
                // handing the caller a truncated frame that would parse
                // into something wrong.
                self.overflowed = true;
                self.used = 0;
                self.consume = 0;
                if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                    rest = rest[nl + 1 ..];
                    continue;
                }
                return;
            }
            const n = @min(room, rest.len);
            @memcpy(self.buf[self.used..][0..n], rest[0..n]);
            self.used += n;
            rest = rest[n..];
        }
    }

    pub fn next(self: *FrameReader) ?[]const u8 {
        if (self.consume > 0) {
            std.mem.copyForwards(u8, self.buf[0..], self.buf[self.consume..self.used]);
            self.used -= self.consume;
            self.consume = 0;
        }
        const nl = std.mem.indexOfScalar(u8, self.buf[0..self.used], '\n') orelse return null;
        self.consume = nl + 1;
        return self.buf[0..nl];
    }
};

/// What the host does when a plugin asks for something.
///
/// A function pointer rather than an import, because the app owns panes and
/// notifications and this file must not know about either — plugins.zig is
/// linked into a test root that has no window.
///
/// Returns null when it worked, or a short reason when it did not. The
/// reason goes back to the plugin, so it has to be something a plugin
/// author can act on.
pub const Host = struct {
    ctx: *anyopaque,
    /// Handle one inbound verb. Returns an error string, or null for
    /// success — in which case whatever was written to `result` (JSON,
    /// possibly nothing) rides back to the plugin in the reply's
    /// `result` field. Most inbound verbs are effects and write nothing;
    /// `panes.activity` is the first that answers with data.
    call: *const fn (ctx: *anyopaque, plugin: []const u8, op: []const u8, params: []const u8, result: *std.Io.Writer) ?[]const u8,
};

/// What `describe` said. Recorded verbatim, including capabilities the
/// plugin was NOT granted — that difference is the thing worth showing.
pub const Describe = struct {
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    version: [32]u8 = @splat(0),
    version_len: usize = 0,
    caps: [16][32]u8 = @splat(@splat(0)),
    caps_len: [16]usize = @splat(0),
    caps_n: usize = 0,

    pub fn nameStr(self: *const Describe) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn versionStr(self: *const Describe) []const u8 {
        return self.version[0..self.version_len];
    }
    pub fn cap(self: *const Describe, i: usize) []const u8 {
        return self.caps[i][0..self.caps_len[i]];
    }
};

pub const Plugin = struct {
    spec: Spec,
    state: State = .declared,
    /// Why it is not up. Shown by `ctl plugins`, because "the panel is
    /// empty" and "the plugin died" are different problems that look the
    /// same from outside.
    err: [128]u8 = @splat(0),
    err_len: usize = 0,

    pid: c_int = -1,
    to_child: c_int = -1,
    from_child: c_int = -1,
    seq: u64 = 0,
    desc: Describe = .{},
    /// The sha256 of the binary actually running, once it has been
    /// verified. Recorded so rook can HAND IT TO YOU: a pin nobody can
    /// read is a pin nobody sets, and telling someone to go and run
    /// shasum is telling them not to bother.
    pin: [64]u8 = @splat(0),
    pinned_ok: bool = false,

    /// Where an inbound verb goes. Null in tests and before the app wires
    /// itself up; a plugin that asks then gets a refusal rather than a
    /// silence, which is the difference between "rook said no" and "rook
    /// is broken".
    host: ?Host = null,

    // ---- the pump ----
    //
    // It owns `from_child` for as long as the plugin is up. Nothing else
    // reads that fd, which is what makes an unsolicited frame reachable.
    pump: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    /// How the pump is woken to notice `quit` without waiting out its
    /// poll — closing the fd it is polling would be a race against fd
    /// reuse. Same trick as lsp.zig.
    wake_r: c_int = -1,
    wake_w: c_int = -1,

    mu: Lock = .{},
    /// The one in-flight call. Requests are serialised by `call_mu`, so
    /// there is at most one waiter — the echoed id is checked anyway,
    /// because that is what will make this safe to widen later.
    waiting_id: u64 = 0,
    waiting_buf: []u8 = &.{},
    waiting_len: usize = 0,
    waiting_ready: bool = false,
    waiting_toobig: bool = false,
    /// How the pump tells a waiting caller its answer has landed. A pipe
    /// rather than a condition variable because there is no Mutex in this
    /// Zig's std to pair one with, and because `poll` — already the way
    /// every deadline in this file is enforced — takes an fd.
    reply_r: c_int = -1,
    reply_w: c_int = -1,
    /// Held across a whole request/response pair. Without it two callers
    /// (the panel's fetch and its act, on different workers) would
    /// interleave writes and race for one reply slot.
    call_mu: Lock = .{},
    /// The pump answers inbound requests while a caller may be sending
    /// one; two writers on one pipe would interleave mid-frame.
    write_mu: Lock = .{},

    pub fn errStr(self: *const Plugin) []const u8 {
        return self.err[0..self.err_len];
    }

    fn fail(self: *Plugin, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.err, fmt, args) catch "failed";
        self.err_len = s.len;
        self.state = .failed;
        self.stop();
    }

    pub fn stop(self: *Plugin) void {
        // The pump goes first and joins, because it is holding
        // `from_child`: closing an fd another thread is polling is a race
        // against whatever opens next and gets that number.
        if (self.pump) |t| {
            self.quit.store(true, .release);
            const byte = [_]u8{1};
            if (self.wake_w >= 0) _ = write(self.wake_w, &byte, 1);
            t.join();
            self.pump = null;
        }
        // Anyone still waiting is waiting forever otherwise.
        self.wakeWaiter();

        for ([_]*c_int{ &self.to_child, &self.from_child, &self.wake_r, &self.wake_w, &self.reply_r, &self.reply_w }) |fd| {
            if (fd.* >= 0) {
                _ = close(fd.*);
                fd.* = -1;
            }
        }
        if (self.pid > 0) {
            _ = kill(self.pid, SIGKILL);
            _ = waitpid(self.pid, null, 0);
            self.pid = -1;
        }
    }

    /// Spawn and handshake if not already up. Idempotent, and a plugin
    /// that failed once stays failed until something clears it — a crash
    /// loop that respawns on every keystroke is worse than a dead panel.
    pub fn ensure(self: *Plugin, gpa: std.mem.Allocator) bool {
        switch (self.state) {
            .up => return true,
            .failed => return false,
            .declared => {},
        }
        if (self.spec.argv.len == 0) {
            self.fail("no command declared", .{});
            return false;
        }
        // A sourced plugin fetches on first use, not at launch: lazy is the
        // rule, and a launch that downloads things is a launch that waits
        // on someone else's server.
        if (self.spec.source.len > 0) {
            var why: [128]u8 = undefined;
            if (!exists(self.spec.argv[0])) {
                if (!fetch(self.spec.source, self.spec.argv[0], &why)) {
                    self.fail("could not download: {s}", .{std.mem.sliceTo(&why, 0)});
                    return false;
                }
            }
            // EVERY time, not only after a download. The cache is a
            // directory on disk like any other, and a binary that changed
            // since rook last looked is the case worth catching.
            if (!self.verify(&why)) {
                self.fail("{s}", .{std.mem.sliceTo(&why, 0)});
                return false;
            }
        }
        if (!self.spawn(gpa)) return false;
        // The pump before the handshake: describe is itself a call, and
        // calls get their answers from the pump.
        self.pump = std.Thread.spawn(.{}, pumpLoop, .{ self, gpa }) catch {
            self.fail("could not start its reader", .{});
            return false;
        };
        if (!self.handshake(gpa)) return false;
        self.state = .up;
        return true;
    }

    /// Read frames for as long as the plugin is up: answers to whoever is
    /// waiting, requests to the host.
    fn pumpLoop(self: *Plugin, gpa: std.mem.Allocator) void {
        const fr = gpa.create(FrameReader) catch return;
        defer gpa.destroy(fr);
        fr.* = .{};

        var chunk: [64 * 1024]u8 = undefined;
        while (!self.quit.load(.acquire)) {
            var fds = [_]PollFd{
                .{ .fd = self.from_child, .events = POLLIN, .revents = 0 },
                .{ .fd = self.wake_r, .events = POLLIN, .revents = 0 },
            };
            const r = poll(&fds, 2, 1000);
            if (r < 0) return;
            if (fds[1].revents != 0) return; // stop() rang
            if (fds[0].revents == 0) continue;

            const n = read(self.from_child, &chunk, chunk.len);
            if (n <= 0) {
                // EOF: the plugin exited. Wake the waiter rather than
                // letting it sit out a ten-second deadline for an answer
                // that is never coming.
                self.wakeWaiter();
                return;
            }
            fr.feed(chunk[0..@intCast(n)]);
            while (fr.next()) |frame| self.route(frame);
        }
    }

    /// One frame: an answer, or something the plugin is asking for.
    ///
    /// Told apart by `op`. A response never carries one, so this needs no
    /// bookkeeping about which ids are outstanding — which matters,
    /// because a request arriving mid-call is the normal case, not an edge
    /// one.
    fn route(self: *Plugin, frame: []const u8) void {
        if (frameHas(frame, "\"op\"")) {
            self.inbound(frame);
            return;
        }
        self.mu.lock();
        defer self.mu.unlock();
        const id = frameId(frame) orelse return; // addressed to nobody
        if (self.waiting_id == 0 or id != self.waiting_id) return; // late, or for a call that gave up
        if (frame.len > self.waiting_buf.len) {
            self.waiting_toobig = true;
        } else {
            @memcpy(self.waiting_buf[0..frame.len], frame);
            self.waiting_len = frame.len;
        }
        self.waiting_ready = true;
        self.ring();
    }

    /// Tell the caller its slot is filled. One byte; the reader drains
    /// whatever is there, so a stale byte from a call that timed out only
    /// costs one extra pass round the poll loop.
    fn ring(self: *Plugin) void {
        const byte = [_]u8{1};
        if (self.reply_w >= 0) _ = write(self.reply_w, &byte, 1);
    }

    /// The plugin is gone; release whoever is waiting on it. `waiting_id`
    /// cleared with `ready` set is how the caller tells this from an
    /// answer that actually arrived.
    fn wakeWaiter(self: *Plugin) void {
        self.mu.lock();
        const had = self.waiting_id != 0;
        self.waiting_id = 0;
        self.waiting_ready = true;
        self.mu.unlock();
        if (had) self.ring();
    }

    /// A verb the plugin called. Grant-checked here, in the one place that
    /// already knows what was granted — the direction differs but the
    /// question does not.
    fn inbound(self: *Plugin, frame: []const u8) void {
        const id = frameId(frame) orelse return;
        const op = frameOp(frame) orelse {
            self.answer(id, false, "no op", "");
            return;
        };
        if (!self.spec.granted(op)) {
            // Named, not vague. A plugin author reading "not granted:
            // session.spawn" knows to ask the human for it; "refused"
            // sends them into their own code looking for a bug.
            var b: [96]u8 = undefined;
            self.answer(id, false, std.fmt.bufPrint(&b, "not granted: {s}", .{op}) catch "not granted", "");
            return;
        }
        const h = self.host orelse {
            self.answer(id, false, "rook cannot do that here", "");
            return;
        };
        // Verbatim: the host parses its own params, because only it knows
        // what session.spawn's look like. The host may also write a JSON
        // answer — sized for panes.activity's worst honest day, and a
        // host that overflows it truncates its own reply, not rook.
        var rbuf: [8192]u8 = undefined;
        var rw: std.Io.Writer = .fixed(&rbuf);
        const params = frameParams(frame);
        if (h.call(h.ctx, self.spec.name, op, params, &rw)) |why| {
            self.answer(id, false, why, "");
        } else {
            self.answer(id, true, "", rbuf[0..rw.end]);
        }
    }

    fn answer(self: *Plugin, id: u64, ok: bool, why: []const u8, result: []const u8) void {
        var buf: [9216]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{{\"v\":{d},\"id\":{d},\"ok\":{s}", .{ version, id, if (ok) "true" else "false" }) catch return;
        if (!ok) {
            w.writeAll(",\"error\":") catch return;
            jsonString(&w, why) catch return;
        }
        if (ok and result.len > 0) {
            w.writeAll(",\"result\":") catch return;
            w.writeAll(result) catch return;
        }
        w.writeAll("}\n") catch return;
        self.write_mu.lock();
        defer self.write_mu.unlock();
        _ = writeAll(self.to_child, buf[0..w.end]);
    }

    fn spawn(self: *Plugin, gpa: std.mem.Allocator) bool {
        var in_fds: [2]c_int = undefined;
        var out_fds: [2]c_int = undefined;
        if (pipe(&in_fds) != 0) {
            self.fail("pipe failed", .{});
            return false;
        }
        if (pipe(&out_fds) != 0) {
            _ = close(in_fds[0]);
            _ = close(in_fds[1]);
            self.fail("pipe failed", .{});
            return false;
        }
        var wake_fds: [2]c_int = undefined;
        if (pipe(&wake_fds) != 0) {
            for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = close(fd);
            self.fail("pipe failed", .{});
            return false;
        }
        var reply_fds: [2]c_int = undefined;
        if (pipe(&reply_fds) != 0) {
            for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1], wake_fds[0], wake_fds[1] }) |fd| _ = close(fd);
            self.fail("pipe failed", .{});
            return false;
        }

        // argv must be NUL-terminated BEFORE the fork: allocating in the
        // child is not safe.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const cargv = a.allocSentinel(?[*:0]const u8, self.spec.argv.len, null) catch {
            self.fail("out of memory", .{});
            return false;
        };
        for (self.spec.argv, 0..) |arg, i| {
            cargv[i] = (a.dupeZ(u8, arg) catch {
                self.fail("out of memory", .{});
                return false;
            }).ptr;
        }

        const child = fork();
        if (child < 0) {
            for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1], wake_fds[0], wake_fds[1], reply_fds[0], reply_fds[1] }) |fd| _ = close(fd);
            self.fail("fork failed", .{});
            return false;
        }
        if (child == 0) {
            _ = dup2(in_fds[0], 0);
            _ = dup2(out_fds[1], 1);
            // A plugin's stderr is its log and belongs to whoever is
            // watching — which is not rook's window. /dev/null until there
            // is somewhere to put it.
            const devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) _ = dup2(devnull, 2);
            // EVERYTHING above stdio dies here. lsp.zig and pty.zig both
            // carry this comment for the same reason: a ctl CONNECTION
            // held open by a child keeps its client from ever seeing EOF,
            // and a plugin is a child like any other.
            var fd: c_int = 3;
            const maxfd = getdtablesize();
            while (fd < maxfd) : (fd += 1) _ = close(fd);
            _ = execvp(cargv[0].?, cargv.ptr);
            _exit(127);
        }

        _ = close(in_fds[0]);
        _ = close(out_fds[1]);
        self.pid = child;
        self.to_child = in_fds[1];
        self.from_child = out_fds[0];
        self.wake_r = wake_fds[0];
        self.wake_w = wake_fds[1];
        self.reply_r = reply_fds[0];
        self.reply_w = reply_fds[1];
        return true;
    }

    fn handshake(self: *Plugin, gpa: std.mem.Allocator) bool {
        var buf: [64 * 1024]u8 = undefined;
        const reply = self.rpc(gpa, "describe", "", default_deadline_ms, &buf) orelse return false;

        const Wire = struct {
            v: i64 = 0,
            id: u64 = 0,
            ok: bool = false,
            @"error": []const u8 = "",
            result: struct {
                name: []const u8 = "",
                version: []const u8 = "",
                capabilities: [][]const u8 = &.{},
            } = .{},
        };
        const parsed = std.json.parseFromSlice(Wire, gpa, reply, .{ .ignore_unknown_fields = true }) catch {
            self.fail("describe did not parse", .{});
            return false;
        };
        defer parsed.deinit();
        const w = parsed.value;
        if (w.v != version) {
            self.fail("speaks protocol v{d}, rook speaks v{d}", .{ w.v, version });
            return false;
        }
        if (!w.ok) {
            self.fail("describe refused: {s}", .{w.@"error"});
            return false;
        }

        copyInto(&self.desc.name, &self.desc.name_len, w.result.name);
        copyInto(&self.desc.version, &self.desc.version_len, w.result.version);
        for (w.result.capabilities) |c| {
            if (self.desc.caps_n >= self.desc.caps.len) break;
            copyInto(&self.desc.caps[self.desc.caps_n], &self.desc.caps_len[self.desc.caps_n], c);
            self.desc.caps_n += 1;
        }
        return true;
    }

    /// Is the cached binary the one we are supposed to be running?
    ///
    /// Config's pin wins when there is one. Otherwise rook compares against
    /// what it recorded the first time it downloaded this — trust on first
    /// use, which is weaker than a pin and says so, but does catch a cache
    /// that changed underneath a machine that had already fetched.
    ///
    /// A mismatch REFUSES rather than re-downloading. Silently replacing a
    /// binary that stopped matching is the failure this exists to prevent.
    fn verify(self: *Plugin, why: *[128]u8) bool {
        var got: [64]u8 = undefined;
        if (!hashFile(self.spec.argv[0], &got)) {
            _ = std.fmt.bufPrintZ(why, "downloaded, then could not be read", .{}) catch {};
            return false;
        }
        self.pin = got;
        if (self.spec.sha256.len > 0) {
            if (!std.ascii.eqlIgnoreCase(self.spec.sha256, &got)) {
                _ = std.fmt.bufPrintZ(why, "sha256 does not match the pin: got {s}…", .{got[0..16]}) catch {};
                return false;
            }
            self.pinned_ok = true;
            return true;
        }
        // No pin: compare with, or establish, what we first saw.
        var sidecar: [1088]u8 = undefined;
        const sc = std.fmt.bufPrint(&sidecar, "{s}.sha256", .{self.spec.argv[0]}) catch return true;
        var seen: [64]u8 = undefined;
        if (readAll(sc, &seen)) |n| {
            if (n == 64 and !std.ascii.eqlIgnoreCase(seen[0..64], &got)) {
                _ = std.fmt.bufPrintZ(why, "changed since it was downloaded — delete it to accept the new one", .{}) catch {};
                return false;
            }
            return true;
        }
        _ = writeAllTo(sc, &got);
        return true;
    }

    /// Call an op. Refuses anything the config did not grant, BEFORE
    /// sending — a plugin should never learn it was asked for something it
    /// is not allowed to do.
    ///
    /// Returns the raw response frame, borrowed from `buf`.
    pub fn call(
        self: *Plugin,
        gpa: std.mem.Allocator,
        op: []const u8,
        params_json: []const u8,
        buf: []u8,
    ) ?[]const u8 {
        if (!self.spec.granted(op)) return null;
        if (!self.ensure(gpa)) return null;
        return self.rpc(gpa, op, params_json, default_deadline_ms, buf);
    }

    /// One request, one response — sent here, delivered by the pump.
    ///
    /// The id is registered BEFORE the write. A plugin that answers
    /// instantly would otherwise be answering a call the pump has not been
    /// told to expect, and the frame would be dropped as addressed to
    /// nobody. That race is not theoretical: the e2e's fixture is a shell
    /// loop that answers in microseconds.
    fn rpc(
        self: *Plugin,
        gpa: std.mem.Allocator,
        op: []const u8,
        params_json: []const u8,
        deadline_ms: i32,
        buf: []u8,
    ) ?[]const u8 {
        _ = gpa;
        // One call at a time. Two panel workers can reach the same plugin.
        self.call_mu.lock();
        defer self.call_mu.unlock();

        self.seq += 1;
        const id = self.seq;
        var req: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&req, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\",\"deadlineMs\":{d}{s}{s}}}\n", .{
            version,
            id,
            op,
            @max(deadline_ms - grace_ms, 1),
            if (params_json.len > 0) ",\"params\":" else "",
            params_json,
        }) catch {
            self.fail("request too large", .{});
            return null;
        };

        self.mu.lock();
        self.waiting_id = id;
        self.waiting_buf = buf;
        self.waiting_len = 0;
        self.waiting_ready = false;
        self.waiting_toobig = false;
        self.mu.unlock();

        {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            if (!writeAll(self.to_child, line)) {
                self.clearWaiter();
                self.fail("plugin closed its input", .{});
                return null;
            }
        }

        var left = @max(deadline_ms, 1);
        while (true) {
            self.mu.lock();
            const ready = self.waiting_ready;
            self.mu.unlock();
            if (ready) break;

            var pfd = [_]PollFd{.{ .fd = self.reply_r, .events = POLLIN, .revents = 0 }};
            const start = nowMs();
            const r = poll(&pfd, 1, left);
            if (r > 0) {
                var drain: [64]u8 = undefined;
                _ = read(self.reply_r, &drain, drain.len);
            }
            // The CLOCK decides how much deadline is left, not the number
            // of times round this loop — a stale wake byte would otherwise
            // buy the plugin another full deadline every time.
            const spent: i32 = @intCast(@min(@as(i64, std.math.maxInt(i32)), nowMs() - start));
            left -= @max(spent, 0);
            if (r <= 0 or left <= 0) {
                self.mu.lock();
                const late = self.waiting_ready;
                if (!late) self.waiting_id = 0;
                self.mu.unlock();
                if (late) break; // it landed in the gap; take it
                self.fail("no answer in {d}ms", .{deadline_ms});
                return null;
            }
        }

        self.mu.lock();
        const matched = self.waiting_id == id;
        const toobig = self.waiting_toobig;
        const len = self.waiting_len;
        self.waiting_id = 0;
        self.mu.unlock();

        // The pump only ever fills this for the id it was given, so a
        // cleared one means the plugin went away underneath us.
        if (!matched) {
            self.fail("exited without answering", .{});
            return null;
        }
        if (toobig) {
            self.fail("answer larger than {d} bytes", .{buf.len});
            return null;
        }
        return buf[0..len];
    }

    fn clearWaiter(self: *Plugin) void {
        self.mu.lock();
        self.waiting_id = 0;
        self.mu.unlock();
    }
};

/// The `id` out of a response frame, without a full parse — this runs on
/// every call and the frame may be megabytes.
fn frameId(frame: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, frame, "\"id\":") orelse return null;
    var i = at + 5;
    while (i < frame.len and frame[i] == ' ') i += 1;
    const start = i;
    while (i < frame.len and frame[i] >= '0' and frame[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, frame[start..i], 10) catch null;
}

/// Whether a key appears at the top level of a frame.
///
/// A substring search, and that is a deliberate limit: it would also match
/// `"op"` inside a string value. It decides ONLY request-vs-response, where
/// the cost of being wrong is a frame routed to a handler that then refuses
/// it by name. A full parse on every frame — including megabyte item lists
/// — to answer one yes/no question is the wrong trade.
fn frameHas(frame: []const u8, key: []const u8) bool {
    return std.mem.indexOf(u8, frame, key) != null;
}

/// The `op` a request names.
fn frameOp(frame: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, frame, "\"op\":") orelse return null;
    var i = at + 5;
    while (i < frame.len and frame[i] == ' ') i += 1;
    if (i >= frame.len or frame[i] != '"') return null;
    i += 1;
    const start = i;
    // Ops are bare identifiers (`items.list`), so a quote ends it. An
    // escape inside one would mean a plugin naming an op nothing can route.
    while (i < frame.len and frame[i] != '"') i += 1;
    if (i >= frame.len) return null;
    return frame[start..i];
}

/// A request's `params`, verbatim — the host parses its own.
///
/// Byte-matched rather than parsed because the value is an object whose
/// shape belongs to whoever handles the verb, and re-serialising it here
/// would mean this file knowing every verb's schema.
fn frameParams(frame: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, frame, "\"params\":") orelse return "";
    var i = at + 9;
    while (i < frame.len and frame[i] == ' ') i += 1;
    if (i >= frame.len) return "";
    const start = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < frame.len) : (i += 1) {
        const c = frame[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth <= 0) return frame[start .. i + 1];
            },
            else => {},
        }
    }
    return "";
}

fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ---- what was downloaded, and is it still that ----

/// sha256 of a file, lowercase hex. Null when it cannot be read.
pub fn hashFile(path: []const u8, out: *[64]u8) bool {
    var z: [1024]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = open(@ptrCast(&z), 0);
    if (fd < 0) return false;
    defer _ = close(fd);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return false;
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch return false;
    return true;
}

// ---- fetching ----

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;

fn exists(path: []const u8) bool {
    var z: [1024]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return access(@ptrCast(&z), 0) == 0;
}

/// Where a sourced plugin's binary lives: `$XDG_DATA_HOME/rook/plugins/`.
///
/// rook's data dir, not the config dir. A downloaded binary is not
/// configuration — it is a build artifact of one, and a config directory
/// you can copy between machines should not carry executables.
pub fn cachePath(buf: []u8, name: []const u8) ?[]const u8 {
    const base = if (getenv("XDG_DATA_HOME")) |x|
        std.fmt.bufPrint(buf, "{s}/rook/plugins", .{std.mem.span(x)}) catch return null
    else blk: {
        const home = getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(buf, "{s}/.local/share/rook/plugins", .{std.mem.span(home)}) catch return null;
    };
    // The caller wants the FILE; rebuild with the name appended, in place.
    var tmp: [1024]u8 = undefined;
    if (base.len >= tmp.len) return null;
    @memcpy(tmp[0..base.len], base);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ tmp[0..base.len], name }) catch null;
}

/// Download `source` to `dest`, executable.
///
/// Through `curl`, not an HTTP client compiled into rook. macOS ships it,
/// install.sh already depends on it, and a TLS stack is a large thing to
/// carry for an operation that happens once per plugin. `-f` so a 404 is a
/// failure rather than a file containing the word "Not Found".
///
/// Downloaded to a temp name and RENAMED, so an interrupted fetch cannot
/// leave a half-written binary that looks present and runs.
pub fn fetch(source: []const u8, dest: []const u8, why: *[128]u8) bool {
    @memset(why, 0);
    const say = struct {
        fn it(w: *[128]u8, m: []const u8) bool {
            const n = @min(w.len - 1, m.len);
            @memcpy(w[0..n], m[0..n]);
            return false;
        }
    }.it;

    // Only what curl can be trusted to treat as a URL, and only schemes we
    // mean. file:// is here because the e2e must not need a network.
    if (!std.mem.startsWith(u8, source, "https://") and !std.mem.startsWith(u8, source, "file://"))
        return say(why, "only https:// (or file://) sources");

    const cut = std.mem.lastIndexOfScalar(u8, dest, '/') orelse return say(why, "bad destination");
    var dirz: [1024]u8 = undefined;
    if (cut >= dirz.len) return say(why, "path too long");
    @memcpy(dirz[0..cut], dest[0..cut]);
    dirz[cut] = 0;
    makePath(dirz[0..cut :0]);

    var tmpz: [1024]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmpz, "{s}.part", .{dest}) catch return say(why, "path too long");
    var srcz: [1024]u8 = undefined;
    const src = std.fmt.bufPrintZ(&srcz, "{s}", .{source}) catch return say(why, "source too long");

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return say(why, "pipe failed");
    const child = fork();
    if (child < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        return say(why, "fork failed");
    }
    if (child == 0) {
        _ = dup2(fds[1], 1);
        _ = dup2(fds[1], 2);
        var fd: c_int = 3;
        const maxfd = getdtablesize();
        while (fd < maxfd) : (fd += 1) _ = close(fd);
        var argv = [_:null]?[*:0]const u8{ "curl", "-fsSL", "--max-time", "60", "-o", tmp.ptr, src.ptr, null };
        _ = execvp("curl", &argv);
        _exit(127);
    }
    _ = close(fds[1]);
    var log: [256]u8 = undefined;
    var log_len: usize = 0;
    while (log_len < log.len) {
        const n = read(fds[0], @as([*]u8, &log) + log_len, log.len - log_len);
        if (n <= 0) break;
        log_len += @intCast(n);
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    _ = waitpid(child, &status, 0);
    const code: u8 = @truncate(@as(u32, @bitCast(status)) >> 8);
    if (code != 0) {
        _ = deleteZ(tmp);
        return say(why, if (log_len > 0) log[0..log_len] else "curl failed");
    }

    var destz: [1024]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&destz, "{s}", .{dest}) catch return say(why, "path too long");
    _ = chmod(tmp.ptr, 0o755);
    if (rename(tmp.ptr, dz.ptr) != 0) {
        _ = deleteZ(tmp);
        return say(why, "could not place the download");
    }
    return true;
}

extern "c" fn unlink(path: [*:0]const u8) c_int;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

fn readAll(path: []const u8, out: []u8) ?usize {
    var z: [1024]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = open(@ptrCast(&z), 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = read(fd, out.ptr, out.len);
    return if (n < 0) null else @intCast(n);
}

fn writeAllTo(path: []const u8, data: []const u8) bool {
    var z: [1024]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = open(@ptrCast(&z), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return false;
    defer _ = close(fd);
    return writeAll(fd, data);
}
fn deleteZ(p: [:0]const u8) c_int {
    return unlink(p.ptr);
}

/// mkdir -p, one component at a time.
fn makePath(dir: [:0]const u8) void {
    var buf: [1024]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
            buf[i] = save;
        }
    }
}

// ---- the render-side shape ----
//
// Fixed buffers, copied out of the parse. The draw path must not hold a
// borrowed slice into a JSON arena, and it must not allocate: a panel
// redrawing at 120fps against a heap is a frame budget spent on nothing.
// Same shape the old host-backed panels used, for the same reason.

pub const max_items = 128;
pub const max_fields = 6;
pub const max_actions = 6;

fn Text(comptime n: usize) type {
    return struct {
        b: [n]u8 = @splat(0),
        n: usize = 0,
        pub fn set(self: *@This(), s: []const u8) void {
            self.n = @min(n, s.len);
            @memcpy(self.b[0..self.n], s[0..self.n]);
        }
        pub fn get(self: *const @This()) []const u8 {
            return self.b[0..self.n];
        }
    };
}

pub const Field = struct {
    key: Text(24) = .{},
    kind: Text(16) = .{},
    value: Text(32) = .{},
};

pub const Action = struct {
    id: Text(32) = .{},
    label: Text(48) = .{},
    /// Ask first. The plugin decides this, not the host — only the plugin
    /// knows whether its action destroys or publishes something.
    confirm: bool = false,
    /// `INPUT_TEXT`/`INPUT_CHOICE` mean the human has to supply a payload,
    /// and rook has nowhere to type one yet. Kept verbatim so the panel can
    /// refuse it BY NAME instead of sending an empty payload and letting
    /// the plugin act on nothing.
    input: Text(16) = .{},

    pub fn wantsInput(self: *const Action) bool {
        const s = self.input.get();
        return s.len > 0 and !std.mem.eql(u8, s, "INPUT_NONE");
    }
};

pub const Item = struct {
    id: Text(64) = .{},
    // 256, not 96: a digest bullet is prose (~170 bytes at the caps the
    // agent plugin asks for), and the panel wraps children now — a title
    // truncated at intake is a wrap that lies.
    title: Text(256) = .{},
    subtitle: Text(96) = .{},
    state: Text(24) = .{},
    depth: u8 = 0,
    fields: [max_fields]Field = @splat(.{}),
    fields_n: usize = 0,
    actions: [max_actions]Action = @splat(.{}),
    actions_n: usize = 0,
};

/// One answer to items.list, ready to draw.
///
/// `live` and an empty list are DIFFERENT facts and must not render the
/// same: "this plugin says there is nothing" and "we could not reach this
/// plugin" are different problems, and a panel that shows both as blank
/// makes the second one invisible.
pub const Snapshot = struct {
    items: [max_items]Item = @splat(.{}),
    n: usize = 0,
    more: usize = 0,
    live: bool = false,
    err: Text(96) = .{},

    pub fn slice(self: *const Snapshot) []const Item {
        return self.items[0..self.n];
    }
};

/// Call items.list and shape the answer for the panel.
///
/// Children are FLATTENED with a depth, not dropped: children are the only
/// structural difference between a list and a tree, and a renderer that
/// ignores them turns one of the seven surfaces into another.
pub fn fetchItems(p: *Plugin, gpa: std.mem.Allocator, root: []const u8) Snapshot {
    var snap = Snapshot{};

    // ESCAPED, like every other string this file puts on the wire. A path
    // is not a safe JSON literal: a directory named `it's "fine"` would
    // emit a frame the plugin cannot parse, and the failure would read as
    // a dead plugin rather than as a folder name.
    var params: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&params);
    listParams(&w, root, max_items) catch {
        snap.err.set("workspace path too long");
        return snap;
    };
    const pj = params[0..w.end];

    const buf = gpa.alloc(u8, 1 << 20) catch {
        snap.err.set("out of memory");
        return snap;
    };
    defer gpa.free(buf);

    const frame = p.call(gpa, "items.list", pj, buf) orelse {
        snap.err.set(if (p.errStr().len > 0) p.errStr() else "not granted");
        return snap;
    };

    const Wire = struct {
        ok: bool = false,
        @"error": []const u8 = "",
        result: struct {
            items: []WireItem = &.{},
            truncated: bool = false,
        } = .{},
    };

    const parsed = std.json.parseFromSlice(Wire, gpa, frame, .{ .ignore_unknown_fields = true }) catch {
        snap.err.set("answer did not parse");
        return snap;
    };
    defer parsed.deinit();
    if (!parsed.value.ok) {
        snap.err.set(parsed.value.@"error");
        return snap;
    }

    for (parsed.value.result.items) |wi| {
        if (snap.n >= max_items) {
            snap.more += 1;
            continue;
        }
        snap.items[snap.n] = shape(wi, 0);
        snap.n += 1;

        for (wi.children) |wc| {
            if (snap.n >= max_items) {
                snap.more += 1;
                continue;
            }
            snap.items[snap.n] = shape(wc, 1);
            snap.n += 1;
        }
    }
    if (parsed.value.result.truncated) snap.more += 1;
    snap.live = true;
    return snap;
}

// The wire shapes, named because `act` returns one too and two copies of
// this would drift.

const WireField = struct {
    key: []const u8 = "",
    kind: []const u8 = "",
    value: []const u8 = "",
};

const WireAction = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    confirm: bool = false,
    input: []const u8 = "",
};

/// A child is the same shape one level down, minus its own children —
/// two levels is as deep as this renders, and a self-referential type
/// would claim otherwise.
const WireChild = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    subtitle: []const u8 = "",
    state: []const u8 = "",
    fields: []WireField = &.{},
    actions: []WireAction = &.{},
};

const WireItem = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    subtitle: []const u8 = "",
    state: []const u8 = "",
    fields: []WireField = &.{},
    actions: []WireAction = &.{},
    children: []WireChild = &.{},
};

/// Copy one wire item into the fixed-buffer shape the draw path uses.
/// `anytype` because a parent and a child differ only in the field this
/// does not read.
fn shape(wi: anytype, depth: u8) Item {
    var it = Item{ .depth = depth };
    it.id.set(wi.id);
    it.title.set(wi.title);
    it.subtitle.set(wi.subtitle);
    it.state.set(wi.state);
    for (wi.fields) |wf| {
        if (it.fields_n >= max_fields) break;
        it.fields[it.fields_n] = .{};
        it.fields[it.fields_n].key.set(wf.key);
        it.fields[it.fields_n].kind.set(wf.kind);
        it.fields[it.fields_n].value.set(wf.value);
        it.fields_n += 1;
    }
    for (wi.actions) |wa| {
        if (it.actions_n >= max_actions) break;
        // An action with no id cannot be invoked, so it is dropped rather
        // than drawn — offering a human a button that cannot work is worse
        // than not offering it.
        if (wa.id.len == 0) continue;
        it.actions[it.actions_n] = .{ .confirm = wa.confirm };
        it.actions[it.actions_n].id.set(wa.id);
        it.actions[it.actions_n].label.set(if (wa.label.len > 0) wa.label else wa.id);
        it.actions[it.actions_n].input.set(wa.input);
        it.actions_n += 1;
    }
    return it;
}

// ---- acting ----

/// What came back from items.act.
///
/// `item` is the plugin's chance to hand back the row as it now is, so the
/// host repaints one line instead of relisting everything. It is optional,
/// and a plugin that omits it gets a refetch.
pub const Acted = struct {
    ok: bool = false,
    msg: Text(160) = .{},
    item: ?Item = null,
};

/// Invoke an action on an item.
///
/// `input` is the human's payload for an action that declared
/// `INPUT_TEXT` — VOCABULARY.md's open question 3, answered by the demo
/// that needed it: the payload belongs to the ACTION, typed on one line
/// in the panel, not to a Form. Empty means the action took none; the
/// panel still never sends an input-wanting action without text, because
/// acting on nothing is the thing the old refusal existed to prevent.
pub fn act(p: *Plugin, gpa: std.mem.Allocator, item_id: []const u8, action_id: []const u8, input: []const u8) Acted {
    var out = Acted{};

    // The ids came from the plugin and go back out inside a JSON string.
    // Escaping is not paranoia about a hostile plugin so much as about a
    // branch named `it's "fine"` — a quote in an id would otherwise emit a
    // frame that does not parse, and the failure would read as a protocol
    // bug rather than as a name.
    // Sized for the worst case: every byte of the ids and the typed
    // payload escaping to six.
    var params: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&params);
    actParams(&w, item_id, action_id, input) catch {
        out.msg.set("too long to send");
        return out;
    };

    const buf = gpa.alloc(u8, 1 << 20) catch {
        out.msg.set("out of memory");
        return out;
    };
    defer gpa.free(buf);

    const frame = p.call(gpa, "items.act", params[0..w.end], buf) orelse {
        out.msg.set(if (p.errStr().len > 0) p.errStr() else "not granted");
        return out;
    };

    const Wire = struct {
        ok: bool = false,
        @"error": []const u8 = "",
        result: struct {
            message: []const u8 = "",
            item: ?WireItem = null,
        } = .{},
    };
    const parsed = std.json.parseFromSlice(Wire, gpa, frame, .{ .ignore_unknown_fields = true }) catch {
        out.msg.set("answer did not parse");
        return out;
    };
    defer parsed.deinit();

    // A refused action is REPORTED, not swallowed. The human pressed a key
    // and something has to answer.
    if (!parsed.value.ok) {
        out.msg.set(if (parsed.value.@"error".len > 0) parsed.value.@"error" else "refused");
        return out;
    }
    out.ok = true;
    out.msg.set(if (parsed.value.result.message.len > 0) parsed.value.result.message else "done");
    if (parsed.value.result.item) |wi| out.item = shape(wi, 0);
    return out;
}

fn listParams(w: *std.Io.Writer, root: []const u8, limit: usize) !void {
    try w.writeAll("{\"root\":");
    try jsonString(w, root);
    try w.print(",\"limit\":{d}}}", .{limit});
}

fn actParams(w: *std.Io.Writer, item_id: []const u8, action_id: []const u8, input: []const u8) !void {
    try w.writeAll("{\"itemId\":");
    try jsonString(w, item_id);
    try w.writeAll(",\"actionId\":");
    try jsonString(w, action_id);
    if (input.len > 0) {
        try w.writeAll(",\"input\":");
        try jsonString(w, input);
    }
    try w.writeAll("}");
}

/// Write `s` as a JSON string, quotes and all. Exported because the
/// app builds inbound params of its own — config's own attention goes
/// through the same door a plugin's does.
pub fn jsonStringTo(w: *std.Io.Writer, s: []const u8) !void {
    return jsonString(w, s);
}

/// Write `s` as a JSON string, quotes and all.
fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        // Everything else below a space has to be escaped; above it, UTF-8
        // bytes are already valid JSON and pass through untouched.
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---- the registry ----

/// Every declared plugin, owning its strings for the process lifetime.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    items: []Plugin = &.{},

    pub fn deinit(self: *Registry) void {
        for (self.items) |*p| p.stop();
        self.arena.deinit();
    }

    pub fn find(self: *Registry, name: []const u8) ?*Plugin {
        for (self.items) |*p| if (std.mem.eql(u8, p.spec.name, name)) return p;
        return null;
    }

    /// Wire the inbound verbs up. Called once, before anything spawns —
    /// after that the pump holds a `*Plugin` and the slice must not move.
    pub fn setHost(self: *Registry, host: Host) void {
        for (self.items) |*p| p.host = host;
    }

    /// Start everything declared `eager`. Failures are recorded, never
    /// fatal — a broken plugin is a missing panel, not a broken launch.
    pub fn startEager(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.items) |*p| {
            if (p.spec.load == .eager) _ = p.ensure(gpa);
        }
    }
};

/// Read the `plugin` nodes out of the environment graph.
///
/// Absent file, unparseable file, no plugin nodes — all the same answer: a
/// registry with nothing in it. The graph loader in config.zig already
/// warns about a file that will not parse; this stays quiet rather than
/// warning twice.
pub fn load(io: std.Io, gpa: std.mem.Allocator) Registry {
    var reg = Registry{ .arena = std.heap.ArenaAllocator.init(gpa) };
    const data = cfgpkg.envData(io, gpa) orelse return reg;
    defer gpa.free(data);
    loadFromJson(&reg, gpa, data);
    return reg;
}

/// Pick the plugin nodes out of the graph — NODE BY NODE, leniently, on
/// purpose. The graph holds every kind of node and their shapes disagree:
/// a keybind's `command` is a string where a plugin's is an argv. This
/// used to parse the whole file against the plugin shape, so any config
/// with both keybinds and plugins threw on the first keybind and loaded
/// NO plugins at all — silently, because the catch returned an empty
/// registry. Every e2e graph with plugins had only plugin nodes, which
/// made the suite vacuously green; the first real mixed config was the
/// one that found it. Now a node that does not parse as a plugin is
/// simply not a plugin.
fn loadFromJson(reg: *Registry, gpa: std.mem.Allocator, data: []const u8) void {
    const a = reg.arena.allocator();

    const Wire = struct { nodes: []std.json.Value = &.{} };
    const parsed = std.json.parseFromSlice(Wire, gpa, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const Node = struct {
        kind: []const u8 = "",
        name: []const u8 = "",
        command: [][]const u8 = &.{},
        source: []const u8 = "",
        sha256: []const u8 = "",
        load: []const u8 = "",
        grants: [][]const u8 = &.{},
    };

    var list: std.ArrayListUnmanaged(Plugin) = .empty;
    for (parsed.value.nodes) |nv| {
        const np = std.json.parseFromValue(Node, gpa, nv, .{ .ignore_unknown_fields = true }) catch continue;
        defer np.deinit();
        const n = np.value;
        if (!std.mem.eql(u8, n.kind, "plugin")) continue;
        if (n.name.len == 0) continue;
        // A source and a command are the two ways to say where the binary
        // is; one of them has to be there.
        if (n.command.len == 0 and n.source.len == 0) continue;

        // A sourced plugin runs from rook's cache — a path the human never
        // types, and never has to keep in step with config.
        var argv: [][]const u8 = undefined;
        if (n.source.len > 0) {
            var cbuf: [1024]u8 = undefined;
            const cp = cachePath(&cbuf, n.name) orelse continue;
            argv = a.alloc([]const u8, 1) catch continue;
            argv[0] = a.dupe(u8, cp) catch return;
        } else {
            argv = a.alloc([]const u8, n.command.len) catch continue;
            for (n.command, 0..) |c, i| argv[i] = a.dupe(u8, c) catch return;
        }
        const grants = a.alloc([]const u8, n.grants.len) catch continue;
        for (n.grants, 0..) |g, i| grants[i] = a.dupe(u8, g) catch return;

        list.append(a, .{ .spec = .{
            .name = a.dupe(u8, n.name) catch continue,
            .argv = argv,
            // Unknown load values fall back to lazy rather than refusing:
            // an old app meeting a new graph must still run.
            .load = if (std.mem.eql(u8, n.load, "eager")) .eager else .lazy,
            .grants = grants,
            .source = a.dupe(u8, n.source) catch "",
            .sha256 = a.dupe(u8, n.sha256) catch "",
        } }) catch continue;
    }
    reg.items = list.items;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "frameId reads the id a response echoes" {
    try testing.expectEqual(@as(?u64, 7), frameId("{\"v\":1,\"id\":7,\"ok\":true}"));
    try testing.expectEqual(@as(?u64, 42), frameId("{\"id\": 42,\"ok\":true}"));
    // A frame with no id is not addressed to anyone, which is a refusal
    // rather than something to guess at.
    try testing.expectEqual(@as(?u64, null), frameId("{\"ok\":true}"));
    try testing.expectEqual(@as(?u64, null), frameId("{\"id\":\"x\"}"));
}

test "a mixed graph still yields its plugins" {
    // The regression that reached the field: a keybind node rode in the
    // same `nodes` array with a string `command`, the whole-file parse
    // threw, and every plugin declaration vanished. A graph is mixed by
    // construction; the loader has to be.
    var reg = Registry{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer reg.arena.deinit();
    loadFromJson(&reg, testing.allocator,
        \\{"rookEnvironment":1,"nodes":[
        \\{"id":"font","kind":"font","family":"Hack","size":16},
        \\{"id":"kb","kind":"keybind","chord":"<leader>v","command":"pane.split-right"},
        \\{"id":"plugin:p","kind":"plugin","scope":"app","name":"p","command":["/bin/p"],"load":"eager","grants":["items.list"]}
        \\]}
    );
    try testing.expectEqual(@as(usize, 1), reg.items.len);
    try testing.expectEqualStrings("p", reg.items[0].spec.name);
    try testing.expect(reg.items[0].spec.load == .eager);
}

test "granted is exact, not a prefix" {
    const s = Spec{ .name = "p", .argv = &.{"p"}, .grants = &.{"items.list"} };
    try testing.expect(s.granted("items.list"));
    try testing.expect(!s.granted("items"));
    try testing.expect(!s.granted("items.list.extra"));
    try testing.expect(!s.granted("items.act"));
}

test "a plugin with no grants is declared but inert" {
    const s = Spec{ .name = "p", .argv = &.{"p"} };
    try testing.expect(!s.granted("items.list"));
    try testing.expect(!s.granted("describe"));
}




test "FrameReader reassembles a frame split across reads" {
    // The normal case on a pipe, not an edge one.
    const fr = try testing.allocator.create(FrameReader);
    defer testing.allocator.destroy(fr);
    fr.* = .{};
    fr.feed("{\"a\":");
    try testing.expect(fr.next() == null);
    fr.feed("1}\n");
    try testing.expectEqualStrings("{\"a\":1}", fr.next().?);
    try testing.expect(fr.next() == null);
}

test "FrameReader yields every frame in one read" {
    // A plugin raising attention while answering sends two frames, and
    // they arrive in one read(). A reader that took one per wakeup would
    // hold the second until the next byte arrived — which, for a plugin
    // that has finished talking, is never.
    const fr = try testing.allocator.create(FrameReader);
    defer testing.allocator.destroy(fr);
    fr.* = .{};
    fr.feed("{\"one\":1}\n{\"two\":2}\n{\"part\":");
    try testing.expectEqualStrings("{\"one\":1}", fr.next().?);
    try testing.expectEqualStrings("{\"two\":2}", fr.next().?);
    try testing.expect(fr.next() == null);
    fr.feed("3}\n");
    try testing.expectEqualStrings("{\"part\":3}", fr.next().?);
}

test "FrameReader drops an oversized frame and resyncs on the next one" {
    const fr = try testing.allocator.create(FrameReader);
    defer testing.allocator.destroy(fr);
    fr.* = .{};
    const huge = try testing.allocator.alloc(u8, max_frame + 4096);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    huge[huge.len - 1] = '\n';
    fr.feed(huge);
    // Not a truncated frame handed over as if it were whole: that would
    // parse into something wrong, which is worse than losing it.
    try testing.expect(fr.next() == null);
    try testing.expect(fr.overflowed);
    // …and the plugin is not dead to us. The next frame lands.
    fr.feed("{\"ok\":true}\n");
    try testing.expectEqualStrings("{\"ok\":true}", fr.next().?);
}

test "a request is told from a response by its op" {
    // The whole demux. A response never carries an op, so no bookkeeping
    // about outstanding ids is needed to know which is which.
    try testing.expect(frameHas("{\"v\":1,\"id\":3,\"op\":\"attention.raise\"}", "\"op\""));
    try testing.expect(!frameHas("{\"v\":1,\"id\":3,\"ok\":true,\"result\":{}}", "\"op\""));
}

test "frameOp reads the verb a plugin is asking for" {
    try testing.expectEqualStrings("attention.raise", frameOp("{\"v\":1,\"id\":3,\"op\":\"attention.raise\",\"params\":{}}").?);
    try testing.expectEqualStrings("session.spawn", frameOp("{\"op\": \"session.spawn\"}").?);
    try testing.expect(frameOp("{\"ok\":true}") == null);
    try testing.expect(frameOp("{\"op\":7}") == null);
}

test "frameParams hands the host its object verbatim" {
    // Nesting, strings containing braces, and an escaped quote — all of
    // which a naive scan for the matching '}' gets wrong, and all of which
    // reach here as soon as a command has an argument.
    const f =
        \\{"v":1,"id":2,"op":"session.spawn","params":{"command":["sh","-c","echo }{"],"cwd":"/tmp/a\"b"}}
    ;
    const p = frameParams(f);
    const Wire = struct {
        command: [][]const u8,
        cwd: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.command.len);
    try testing.expectEqualStrings("echo }{", parsed.value.command[2]);
    try testing.expectEqualStrings("/tmp/a\"b", parsed.value.cwd);
}

test "frameParams is empty when a request carries none" {
    try testing.expectEqualStrings("", frameParams("{\"v\":1,\"id\":1,\"op\":\"attention.raise\"}"));
}

test "a workspace path with a quote in it still produces a frame that parses" {
    // The list root is a DIRECTORY NAME, and a directory may be called
    // anything. Concatenating one straight into a request emits JSON the
    // plugin cannot parse — and since a plugin that refuses a frame looks
    // exactly like a plugin that died, the failure would be read as a dead
    // plugin rather than as a folder name.
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try listParams(&w, "/tmp/it's \"fine\"\\here", 128);

    const Wire = struct { root: []const u8, limit: u32 };
    const parsed = try std.json.parseFromSlice(Wire, testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/it's \"fine\"\\here", parsed.value.root);
    try testing.expectEqual(@as(u32, 128), parsed.value.limit);
}

test "an id with a quote in it still produces a frame that parses" {
    // Not hypothetical: item ids are branch names, ticket keys and paths.
    // Concatenating one straight into a request would emit JSON that does
    // not parse, and the failure would read as a protocol bug.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try actParams(&w, "it's \"fine\"\n", "burn\\it", "a \"quoted\" answer");

    const Wire = struct { itemId: []const u8, actionId: []const u8, input: []const u8 };
    const parsed = try std.json.parseFromSlice(Wire, testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's \"fine\"\n", parsed.value.itemId);
    try testing.expectEqualStrings("burn\\it", parsed.value.actionId);
    try testing.expectEqualStrings("a \"quoted\" answer", parsed.value.input);
}

test "no payload means no input key — an absent answer is not an empty one" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try actParams(&w, "i", "a", "");
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "input") == null);
}

test "actParams refuses rather than truncating when the ids will not fit" {
    // A truncated frame is a frame that acts on the WRONG item. Failing is
    // the only safe answer.
    var small: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&small);
    try testing.expectError(error.WriteFailed, actParams(&w, "a-rather-long-item-id", "act", ""));
}

test "an action with no id is dropped, and a label defaults to the id" {
    const wi = WireItem{
        .id = "i",
        .title = "t",
        .actions = @constCast(&[_]WireAction{
            .{ .id = "poke" }, // no label
            .{ .id = "", .label = "unusable" }, // no id: cannot be invoked
            .{ .id = "burn", .label = "Burn it", .confirm = true },
            .{ .id = "say", .label = "Say", .input = "INPUT_TEXT" },
        }),
    };
    const it = shape(wi, 0);
    try testing.expectEqual(@as(usize, 3), it.actions_n);
    // Offering a button that cannot work is worse than not offering it.
    try testing.expectEqualStrings("poke", it.actions[0].id.get());
    try testing.expectEqualStrings("poke", it.actions[0].label.get());
    try testing.expect(!it.actions[0].confirm);
    try testing.expectEqualStrings("burn", it.actions[1].id.get());
    try testing.expect(it.actions[1].confirm);
    try testing.expect(!it.actions[1].wantsInput());
    try testing.expect(it.actions[2].wantsInput());
}

test "INPUT_NONE is not input" {
    // The proto spells "no input" as a value rather than as an absence, so
    // a plugin that sends it explicitly must not get a refusal.
    var a = Action{};
    try testing.expect(!a.wantsInput());
    a.input.set("INPUT_NONE");
    try testing.expect(!a.wantsInput());
    a.input.set("INPUT_TEXT");
    try testing.expect(a.wantsInput());
}


test "hashFile is the sha256 everyone else computes" {
    // Pinned against the value `shasum -a 256` gives for the same bytes —
    // a hash rook agrees with only itself on is a hash nobody can pin.
    var pathbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "/tmp/rook-hash-test-{d}", .{std.Thread.getCurrentId()});
    try testing.expect(writeAllTo(path, "hello, world\n"));
    defer {
        var z: [128]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = unlink(@ptrCast(&z));
    }
    var got: [64]u8 = undefined;
    try testing.expect(hashFile(path, &got));
    try testing.expectEqualStrings(
        "853ff93762a06ddbf722c4ebe9ddd66d8f63ddaea97f521c3ecc20da7c976020",
        &got,
    );
}

test "a source rook does not know how to reach is refused before curl runs" {
    var why: [128]u8 = undefined;
    // Not a network test: the scheme check is the point, and it happens
    // before anything is spawned.
    try testing.expect(!fetch("http://example.invalid/x", "/tmp/nope", &why));
    try testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&why, 0), "https") != null);
    try testing.expect(!fetch("ftp://example.invalid/x", "/tmp/nope", &why));
    try testing.expect(!fetch("/etc/passwd", "/tmp/nope", &why));
}
