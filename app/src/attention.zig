//! The attention inbox — READ side of rook-host's `/attention`.
//!
//! "Every claude session waiting on you, across workspaces", oldest
//! first. The host already computes it (internal/host/attention.go); the
//! inbox, the notifications and rook-agent all consume the same shape,
//! so this is a projection rather than a second source of truth.
//!
//! Shaped after usage.zig, and fail-open the same way: no host.json, a
//! dead host, or unparseable JSON gives an EMPTY snapshot rather than an
//! error. A panel that can't reach the daemon shows nothing and says so
//! — it never blocks a frame or takes the app down with it.
//!
//! Fixed buffers, no allocation retained: the render path reads this
//! under draw_lock and must not touch an allocator.

const std = @import("std");
const hostc = @import("hostc.zig");

/// Fields the panel actually draws. The wire has more (rookSession,
/// agentSession, askSeq, draft, …) and they matter for ACTING on an
/// item — jumping to the session, answering the ask. Slice one lists;
/// those arrive with the verbs that need them.
const Wire = struct {
    workspace: []const u8 = "",
    title: []const u8 = "",
    ask: []const u8 = "",
    state: []const u8 = "",
    interactive: bool = false,
};

pub const Item = struct {
    ws: [24]u8 = @splat(0),
    ws_len: u8 = 0,
    /// The ask if there is one, else the session title — what the row
    /// says after the workspace name.
    what: [72]u8 = @splat(0),
    what_len: u8 = 0,
    /// A TUI picker: you jump to it rather than typing an answer.
    interactive: bool = false,

    pub fn workspace(self: *const Item) []const u8 {
        return self.ws[0..self.ws_len];
    }
    pub fn text(self: *const Item) []const u8 {
        return self.what[0..self.what_len];
    }
};

/// Sixteen is already a pathological inbox — the whole point of the
/// queue is that it drains. `more` carries the overflow rather than
/// truncating in silence, so the panel can say "+3 more" and never
/// imply the list is complete when it isn't.
pub const max_items = 16;

pub const Snapshot = struct {
    items: [max_items]Item = undefined,
    n: usize = 0,
    more: usize = 0,
    /// True once a fetch has actually reached the host. Distinguishes
    /// "nothing needs you" from "we have no idea yet", which are very
    /// different things to show someone.
    live: bool = false,

    pub fn slice(self: *const Snapshot) []const Item {
        return self.items[0..self.n];
    }

    /// Cheap change detector, so a poll that returns the same list does
    /// NOT dirty the scene. Idle frames are a measured property of this
    /// app (0 at rest); a 2s poll that repainted unconditionally would
    /// quietly cost 30 frames a minute forever.
    pub fn digest(self: *const Snapshot) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (self.live) "1" else "0");
        for (self.slice()) |*it| {
            h.update(it.workspace());
            h.update(it.text());
        }
        std.hash.autoHash(&h, self.more);
        return h.final();
    }
};

fn copyInto(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

/// One fetch, blocking (hostc's 3s socket timeouts). Background thread
/// only — never the render path.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io) Snapshot {
    var snap: Snapshot = .{};

    const info = hostc.readInfo(gpa, io) orelse return snap;
    var resp = hostc.get(gpa, &info, "/attention", 256 * 1024) orelse return snap;
    defer resp.deinit(gpa);
    if (resp.status != 200) return snap;

    const parsed = std.json.parseFromSlice([]Wire, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();

    // Reaching the host at all is the signal, even with zero items:
    // an empty inbox is good news and should read as such.
    snap.live = true;
    for (parsed.value) |w| {
        if (snap.n >= max_items) {
            snap.more += 1;
            continue;
        }
        var it: Item = .{};
        it.ws_len = copyInto(&it.ws, w.workspace);
        // The ask is the useful line; the title is the fallback, and the
        // state is the last resort so a row is never blank.
        const what = if (w.ask.len > 0) w.ask else if (w.title.len > 0) w.title else w.state;
        it.what_len = copyInto(&it.what, what);
        it.interactive = w.interactive;
        snap.items[snap.n] = it;
        snap.n += 1;
    }
    return snap;
}
