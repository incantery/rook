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
extern "c" fn _exit(code: c_int) noreturn;

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

pub const Load = enum { lazy, eager };

/// One declaration, off the environment graph.
pub const Spec = struct {
    name: []const u8,
    argv: []const []const u8,
    load: Load = .lazy,
    grants: []const []const u8 = &.{},

    pub fn granted(self: *const Spec, op: []const u8) bool {
        for (self.grants) |g| if (std.mem.eql(u8, g, op)) return true;
        return false;
    }
};

pub const State = enum { declared, up, failed };

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
        if (self.to_child >= 0) {
            _ = close(self.to_child);
            self.to_child = -1;
        }
        if (self.from_child >= 0) {
            _ = close(self.from_child);
            self.from_child = -1;
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
        if (!self.spawn(gpa)) return false;
        if (!self.handshake(gpa)) return false;
        self.state = .up;
        return true;
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
            _ = close(in_fds[0]);
            _ = close(in_fds[1]);
            _ = close(out_fds[0]);
            _ = close(out_fds[1]);
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

    /// One request, one response. No pipelining: `id` is echoed and
    /// checked, so the framing can grow to concurrent calls later without
    /// a wire change, but nothing needs it yet.
    fn rpc(
        self: *Plugin,
        gpa: std.mem.Allocator,
        op: []const u8,
        params_json: []const u8,
        deadline_ms: i32,
        buf: []u8,
    ) ?[]const u8 {
        _ = gpa;
        self.seq += 1;
        var req: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&req, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\",\"deadlineMs\":{d}{s}{s}}}\n", .{
            version,
            self.seq,
            op,
            @max(deadline_ms - grace_ms, 1),
            if (params_json.len > 0) ",\"params\":" else "",
            params_json,
        }) catch {
            self.fail("request too large", .{});
            return null;
        };
        if (!writeAll(self.to_child, line)) {
            self.fail("plugin closed its input", .{});
            return null;
        }

        const n = readFrame(self.from_child, buf, deadline_ms) orelse {
            self.fail("no answer in {d}ms", .{deadline_ms});
            return null;
        };
        const frame = buf[0..n];

        // The echoed id is what will make this framing safe to grow to
        // concurrent calls. Checking it now means a plugin that answers out
        // of order is caught the first time, rather than after the change
        // that makes it matter — at which point the symptom would be one
        // panel showing another panel's data.
        if (frameId(frame)) |got| {
            if (got != self.seq) {
                self.fail("answered id {d}, asked {d}", .{ got, self.seq });
                return null;
            }
        } else {
            self.fail("answer carried no id", .{});
            return null;
        }
        return frame;
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

/// Read one newline-delimited frame, with a deadline.
///
/// The deadline is the whole reason this is not a blocking read: a plugin
/// that never answers must not take the app with it, and cooperation is
/// not something a host gets to assume.
fn readFrame(fd: c_int, buf: []u8, deadline_ms: i32) ?usize {
    var used: usize = 0;
    var left = deadline_ms;
    while (true) {
        var pfd = [_]PollFd{.{ .fd = fd, .events = POLLIN, .revents = 0 }};
        const start = nowMs();
        const r = poll(&pfd, 1, left);
        if (r <= 0) return null; // timed out, or the poll itself failed
        const spent: i32 = @intCast(@min(@as(i64, std.math.maxInt(i32)), nowMs() - start));
        left -= spent;
        if (left <= 0) left = 1;

        if (used >= buf.len) return null; // frame larger than the caller's buffer
        const n = read(fd, buf.ptr + used, buf.len - used);
        if (n <= 0) return null; // EOF: the plugin exited
        const was = used;
        used += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[was..used], '\n')) |rel| {
            return was + rel;
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
    title: Text(96) = .{},
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

    var params: [512]u8 = undefined;
    const pj = std.fmt.bufPrint(&params, "{{\"root\":\"{s}\",\"limit\":{d}}}", .{ root, max_items }) catch {
        snap.err.set("workspace path too long");
        return snap;
    };

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
/// No payload parameter: an action that wants input is refused before it
/// gets here, because rook has nowhere to type one yet and sending an empty
/// payload would make the plugin act on nothing. When the Form surface
/// exists this grows a parameter; until then the absence is the honest
/// shape. (`ctl plugin <name> items.act <json>` reaches the raw wire for
/// anyone who needs it today.)
pub fn act(p: *Plugin, gpa: std.mem.Allocator, item_id: []const u8, action_id: []const u8) Acted {
    var out = Acted{};

    // The ids came from the plugin and go back out inside a JSON string.
    // Escaping is not paranoia about a hostile plugin so much as about a
    // branch named `it's "fine"` — a quote in an id would otherwise emit a
    // frame that does not parse, and the failure would read as a protocol
    // bug rather than as a name.
    // Sized for the worst case: an id whose every byte escapes to six.
    var params: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&params);
    actParams(&w, item_id, action_id) catch {
        out.msg.set("ids too long to send");
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

fn actParams(w: *std.Io.Writer, item_id: []const u8, action_id: []const u8) !void {
    try w.writeAll("{\"itemId\":");
    try jsonString(w, item_id);
    try w.writeAll(",\"actionId\":");
    try jsonString(w, action_id);
    try w.writeAll("}");
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
    const a = reg.arena.allocator();

    const data = cfgpkg.envData(io, gpa) orelse return reg;
    defer gpa.free(data);

    const Wire = struct {
        nodes: []struct {
            kind: []const u8 = "",
            name: []const u8 = "",
            command: [][]const u8 = &.{},
            load: []const u8 = "",
            grants: [][]const u8 = &.{},
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, gpa, data, .{ .ignore_unknown_fields = true }) catch return reg;
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(Plugin) = .empty;
    for (parsed.value.nodes) |n| {
        if (!std.mem.eql(u8, n.kind, "plugin")) continue;
        if (n.name.len == 0 or n.command.len == 0) continue;

        const argv = a.alloc([]const u8, n.command.len) catch continue;
        for (n.command, 0..) |c, i| argv[i] = a.dupe(u8, c) catch return reg;
        const grants = a.alloc([]const u8, n.grants.len) catch continue;
        for (n.grants, 0..) |g, i| grants[i] = a.dupe(u8, g) catch return reg;

        list.append(a, .{ .spec = .{
            .name = a.dupe(u8, n.name) catch continue,
            .argv = argv,
            // Unknown load values fall back to lazy rather than refusing:
            // an old app meeting a new graph must still run.
            .load = if (std.mem.eql(u8, n.load, "eager")) .eager else .lazy,
            .grants = grants,
        } }) catch continue;
    }
    reg.items = list.items;
    return reg;
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

test "readFrame returns the frame without its newline" {
    var fds: [2]c_int = undefined;
    try testing.expect(pipe(&fds) == 0);
    defer _ = close(fds[0]);
    const payload = "{\"ok\":true}\n";
    try testing.expect(writeAll(fds[1], payload));
    _ = close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = readFrame(fds[0], &buf, 1000) orelse return error.NoFrame;
    try testing.expectEqualStrings("{\"ok\":true}", buf[0..n]);
}

test "readFrame reassembles a frame split across writes" {
    var fds: [2]c_int = undefined;
    try testing.expect(pipe(&fds) == 0);
    defer _ = close(fds[0]);
    // The case a single read() would get wrong: a frame arriving in
    // pieces is the normal case on a pipe, not an edge one.
    try testing.expect(writeAll(fds[1], "{\"a\":"));
    try testing.expect(writeAll(fds[1], "1}\n"));
    _ = close(fds[1]);

    var buf: [128]u8 = undefined;
    const n = readFrame(fds[0], &buf, 1000) orelse return error.NoFrame;
    try testing.expectEqualStrings("{\"a\":1}", buf[0..n]);
}

test "readFrame gives up on a silent writer rather than blocking" {
    var fds: [2]c_int = undefined;
    try testing.expect(pipe(&fds) == 0);
    defer _ = close(fds[0]);
    defer _ = close(fds[1]); // held open: nothing to read, no EOF either

    var buf: [64]u8 = undefined;
    const start = nowMs();
    try testing.expect(readFrame(fds[0], &buf, 60) == null);
    // The point is that it RETURNED. A blocking read here would hang the
    // caller forever on a plugin that never answers.
    try testing.expect(nowMs() - start < 5000);
}

test "an id with a quote in it still produces a frame that parses" {
    // Not hypothetical: item ids are branch names, ticket keys and paths.
    // Concatenating one straight into a request would emit JSON that does
    // not parse, and the failure would read as a protocol bug.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try actParams(&w, "it's \"fine\"\n", "burn\\it");

    const Wire = struct { itemId: []const u8, actionId: []const u8 };
    const parsed = try std.json.parseFromSlice(Wire, testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("it's \"fine\"\n", parsed.value.itemId);
    try testing.expectEqualStrings("burn\\it", parsed.value.actionId);
}

test "actParams refuses rather than truncating when the ids will not fit" {
    // A truncated frame is a frame that acts on the WRONG item. Failing is
    // the only safe answer.
    var small: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&small);
    try testing.expectError(error.WriteFailed, actParams(&w, "a-rather-long-item-id", "act"));
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

test "readFrame reports EOF as no frame" {
    var fds: [2]c_int = undefined;
    try testing.expect(pipe(&fds) == 0);
    defer _ = close(fds[0]);
    _ = close(fds[1]); // the plugin exited without answering

    var buf: [64]u8 = undefined;
    try testing.expect(readFrame(fds[0], &buf, 1000) == null);
}
