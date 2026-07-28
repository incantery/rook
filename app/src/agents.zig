//! The agent deck — every claude session rook can see, at once.
//!
//! `GET /agents` is agentwatch's snapshot: the host tails Claude Code's
//! own jsonl transcripts and keeps a state per session. Unlike the asks
//! loop this needed no host change — the endpoint is plain HTTP and
//! assumes nothing about session sockets.
//!
//! The deck is the NAVIGATION surface: which agents exist, what each is
//! doing, and a way to get to one. The rendered transcript timeline is
//! a separate (and much larger) build — see app/PARITY.md §2.
//!
//! Shaped after attention.zig, and fail-open the same way. Fixed
//! buffers: the render path reads this under draw_lock.

const std = @import("std");
const hostc = @import("hostc.zig");

/// What the host reports per session. There is more on the wire
/// (askSeq, lastEvent, project, tool) — these are what a row shows or
/// navigates by.
const Wire = struct {
    sessionId: []const u8 = "",
    cwd: []const u8 = "",
    project: []const u8 = "",
    /// working | needs_input | quiet
    state: []const u8 = "",
    title: []const u8 = "",
    ask: []const u8 = "",
    model: []const u8 = "",
    costUsd: f64 = 0,
    interactive: bool = false,
};

pub const State = enum {
    working,
    needs_input,
    quiet,

    pub fn parse(s: []const u8) State {
        if (std.mem.eql(u8, s, "working")) return .working;
        if (std.mem.eql(u8, s, "needs_input")) return .needs_input;
        return .quiet;
    }

    /// Sort key: what needs you first, then what is moving, then the
    /// rest. A deck ordered by anything else makes you scan it.
    pub fn rank(self: State) u8 {
        return switch (self) {
            .needs_input => 0,
            .working => 1,
            .quiet => 2,
        };
    }
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: u8 = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(n, s.len);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = @intCast(k);
        }
        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Agent = struct {
    id: Text(40) = .{},
    /// Where it is running — the only correspondence between a host-side
    /// agent and one of our panes, since panes are not host sessions.
    cwd: Text(200) = .{},
    state: State = .quiet,
    /// What it is doing: the ask if it is waiting, else the title.
    what: Text(96) = .{},
    model: Text(16) = .{},
    cost: f64 = 0,
    interactive: bool = false,
};

pub const max_agents = 24;

pub const Snapshot = struct {
    items: [max_agents]Agent = undefined,
    n: usize = 0,
    more: usize = 0,
    /// A fetch reached the host. "No agents" and "no idea" are different
    /// facts — same rule as the inbox.
    live: bool = false,

    pub fn slice(self: *const Snapshot) []const Agent {
        return self.items[0..self.n];
    }

    pub fn digest(self: *const Snapshot) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(if (self.live) "1" else "0");
        for (self.slice()) |*a| {
            h.update(a.id.get());
            h.update(a.what.get());
            std.hash.autoHash(&h, a.state);
        }
        std.hash.autoHash(&h, self.more);
        return h.final();
    }
};

pub fn fetch(gpa: std.mem.Allocator, io: std.Io) Snapshot {
    const info = hostc.readInfo(gpa, io) orelse return .{};
    var resp = hostc.get(gpa, &info, "/agents", 512 * 1024) orelse return .{};
    defer resp.deinit(gpa);
    if (resp.status != 200) return .{};
    return parse(gpa, resp.body);
}

/// Body → snapshot. Split out from `fetch` so the field mapping can be
/// pinned against a REAL `/agents` response without a daemon — the wire
/// is the host's to change, and a silent rename would otherwise show up
/// as an empty deck rather than a failing test.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) Snapshot {
    var snap: Snapshot = .{};
    const parsed = std.json.parseFromSlice([]Wire, gpa, body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();

    snap.live = true;
    for (parsed.value) |w| {
        if (snap.n >= max_agents) {
            snap.more += 1;
            continue;
        }
        var a: Agent = .{};
        a.id.set(w.sessionId);
        // CWD is only set when the watcher saw session_started; a
        // fast-forwarded transcript only has the project path. Falling
        // back keeps such an agent navigable rather than inert.
        a.cwd.set(if (w.cwd.len > 0) w.cwd else w.project);
        a.state = State.parse(w.state);
        a.what.set(if (w.ask.len > 0) w.ask else w.title);
        a.model.set(w.model);
        a.cost = w.costUsd;
        a.interactive = w.interactive;
        snap.items[snap.n] = a;
        snap.n += 1;
    }
    sortByAttention(snap.items[0..snap.n]);
    return snap;
}

/// Needs-you first, then working, then quiet — stable within a rank so
/// the list does not shuffle under the cursor between polls. Insertion
/// sort: n is capped at 24 and stability matters more than speed.
pub fn sortByAttention(items: []Agent) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const v = items[i];
        var j = i;
        while (j > 0 and items[j - 1].state.rank() > v.state.rank()) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = v;
    }
}

// ----------------------------------------------------------------- tests

test "parses a real /agents response" {
    // Captured verbatim from a live rook-host, so this pins the actual
    // contract rather than my reading of the Go struct's tags. A field
    // renamed upstream shows up here instead of as a silently empty deck.
    const body =
        \\[{"sessionId":"2925c86c-db91-44c1-a334-38c2aa282e87",
        \\  "cwd":"/Users/seth/go/src/github.com/incantery/rook",
        \\  "project":"/Users/seth/go/src/github.com/incantery/rook",
        \\  "state":"working","title":"Discard unstaged changes",
        \\  "tool":"Bash","model":"claude-opus-5","costUsd":87.4221865,
        \\  "askSeq":24,"since":"2026-07-28T22:18:58.307Z",
        \\  "lastEvent":"2026-07-28T22:21:03.622Z"}]
    ;
    const snap = parse(std.testing.allocator, body);
    try std.testing.expect(snap.live);
    try std.testing.expectEqual(@as(usize, 1), snap.n);
    const a = snap.slice()[0];
    try std.testing.expectEqual(State.working, a.state);
    try std.testing.expectEqualStrings("/Users/seth/go/src/github.com/incantery/rook", a.cwd.get());
    try std.testing.expectEqualStrings("Discard unstaged changes", a.what.get());
    try std.testing.expectEqualStrings("claude-opus-5", a.model.get());
    try std.testing.expect(a.cost > 87.0);
}

test "an ask outranks a title, and project stands in for a missing cwd" {
    // `ask` is what a waiting agent needs you to see; `title` is what it
    // was doing. And CWD is only set when the watcher saw session_started
    // — a fast-forwarded transcript has only `project`, and falling back
    // is what keeps such an agent navigable rather than inert.
    const body =
        \\[{"sessionId":"x","project":"/tmp/proj","state":"needs_input",
        \\  "title":"some title","ask":"Which approach?"}]
    ;
    const snap = parse(std.testing.allocator, body);
    const a = snap.slice()[0];
    try std.testing.expectEqualStrings("Which approach?", a.what.get());
    try std.testing.expectEqualStrings("/tmp/proj", a.cwd.get());
}

test "an empty list is LIVE, which is not the same as unreachable" {
    const snap = parse(std.testing.allocator, "[]");
    try std.testing.expect(snap.live);
    try std.testing.expectEqual(@as(usize, 0), snap.n);
    // Contrast: the zero value means "we never reached the host", and the
    // panel renders those two differently on purpose.
    const unreachable_snap: Snapshot = .{};
    try std.testing.expect(!unreachable_snap.live);
}

test "sortByAttention puts what needs you first, stably" {
    var items: [5]Agent = @splat(.{});
    const states = [_]State{ .quiet, .working, .needs_input, .quiet, .needs_input };
    for (&items, states, 0..) |*it, s, i| {
        it.state = s;
        it.id.set(&[_]u8{'a' + @as(u8, @intCast(i))});
    }
    sortByAttention(&items);
    try std.testing.expectEqual(State.needs_input, items[0].state);
    try std.testing.expectEqual(State.needs_input, items[1].state);
    try std.testing.expectEqual(State.working, items[2].state);
    // Stable: 'c' came before 'e', and must stay there — a list that
    // reorders equal rows between polls moves the row under the cursor.
    try std.testing.expectEqualStrings("c", items[0].id.get());
    try std.testing.expectEqualStrings("e", items[1].id.get());
    try std.testing.expectEqualStrings("a", items[3].id.get());
    try std.testing.expectEqualStrings("d", items[4].id.get());
}

test "State.parse defaults to quiet rather than guessing" {
    try std.testing.expectEqual(State.working, State.parse("working"));
    try std.testing.expectEqual(State.needs_input, State.parse("needs_input"));
    try std.testing.expectEqual(State.quiet, State.parse("quiet"));
    try std.testing.expectEqual(State.quiet, State.parse("something-new"));
    try std.testing.expectEqual(State.quiet, State.parse(""));
}
