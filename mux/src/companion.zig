//! The companion: the one program rook watches for by name, so it can
//! answer when it is open and where.
//!
//! Rook already holds one opinion about what an *agent* is (a
//! foreground program the config names, so a session somebody started
//! by hand is not invisible). This is the same shape for a different
//! question. A companion is not an agent working somewhere: it is the
//! resident you summon — vera first — and what anything asking about
//! it wants to know is whether it is up, which pane it is in, and
//! whether it is in front of the person right now.
//!
//! `Watch` is the memory the answer needs: which panes are running it
//! and since when. Everything else — the workspace, the window, the
//! rectangle — the server reads off the pane id at the moment it is
//! asked, because it already knows those and they change without the
//! companion changing.
const std = @import("std");

/// How many panes may run the companion at once before rook stops
/// counting. More than one is unusual — the point of the slot is that
/// there is one of it — but two is not an error, and rook reports
/// what it sees rather than what it wishes.
pub const max = 8;

/// One pane running the companion.
pub const Seen = struct {
    pane: u32,
    /// Wall clock, epoch ms, of the first scan that found it here.
    /// Wall clock and not the server's monotonic timer: a consumer
    /// compares this to its own clock.
    since: i64,
};

pub const Watch = struct {
    seen: [max]Seen = @splat(.{ .pane = 0, .since = 0 }),
    n: usize = 0,

    /// Fold one scan into the watch: `ids` is every pane found running
    /// the companion, in pane-table order. A pane already known keeps
    /// the `since` it came with — the answer to "how long has she been
    /// open" must not restart every two seconds — and one that is gone
    /// is forgotten. True when the set changed, which is what earns a
    /// push; the usual scan finds exactly what the last one did.
    pub fn update(self: *Watch, now: i64, ids: []const u32) bool {
        var next: [max]Seen = @splat(.{ .pane = 0, .since = 0 });
        var n: usize = 0;
        for (ids) |id| {
            if (n == max) break;
            next[n] = .{ .pane = id, .since = self.sinceOf(id) orelse now };
            n += 1;
        }
        var changed = n != self.n;
        if (!changed) {
            for (next[0..n], self.seen[0..self.n]) |a, b| {
                if (a.pane != b.pane or a.since != b.since) changed = true;
            }
        }
        self.seen = next;
        self.n = n;
        return changed;
    }

    /// When rook first saw this pane running the companion.
    pub fn sinceOf(self: *const Watch, pane: u32) ?i64 {
        for (self.seen[0..self.n]) |s| {
            if (s.pane == pane) return s.since;
        }
        return null;
    }

    pub fn slice(self: *const Watch) []const Seen {
        return self.seen[0..self.n];
    }

    pub fn open(self: *const Watch) bool {
        return self.n > 0;
    }
};

test "a pane that stays keeps the time it was first seen" {
    var w: Watch = .{};
    try std.testing.expect(w.update(1000, &.{ 3, 7 }));
    try std.testing.expect(w.open());
    // the same scan again: nothing changed, nothing to push
    try std.testing.expect(!w.update(3000, &.{ 3, 7 }));
    try std.testing.expectEqual(@as(?i64, 1000), w.sinceOf(3));
    // a new one is stamped now; the old ones are not restamped
    try std.testing.expect(w.update(5000, &.{ 3, 7, 9 }));
    try std.testing.expectEqual(@as(?i64, 1000), w.sinceOf(7));
    try std.testing.expectEqual(@as(?i64, 5000), w.sinceOf(9));
    // closed: forgotten outright, and reopening is a new `since`
    try std.testing.expect(w.update(6000, &.{}));
    try std.testing.expect(!w.open());
    try std.testing.expectEqual(@as(?i64, null), w.sinceOf(3));
    try std.testing.expect(w.update(7000, &.{3}));
    try std.testing.expectEqual(@as(?i64, 7000), w.sinceOf(3));
}

test "order is part of the answer, and there is a ceiling" {
    var w: Watch = .{};
    try std.testing.expect(w.update(1, &.{ 1, 2 }));
    // the pane table's order is the report's order: a swap is a change
    try std.testing.expect(w.update(2, &.{ 2, 1 }));
    var many: [max + 4]u32 = undefined;
    for (&many, 0..) |*id, i| id.* = @intCast(i + 1);
    _ = w.update(3, &many);
    try std.testing.expectEqual(@as(usize, max), w.slice().len);
}
