//! Re-anchoring: where does a stored anchor live in today's file?
//!
//! The invariant, ported verbatim from the Go host's reanchor.go and
//! restated here because it is the whole design: the stored anchor
//! (blob_sha + line range) is IMMUTABLE GROUND TRUTH, and mapping it onto
//! the current file is a VIEW — computed on read, never written back. That
//! is what stops drift compounding. Map a mapped range and small errors
//! multiply; map the stored range every time and an anchor is either right
//! or honestly outdated, forever.
//!
//! Same content hash → the stored range holds, and it costs one sha1 with
//! no subprocess. Different → diff the stored snapshot against the current
//! content and push the range through the hunks: shifted when edits landed
//! above it, outdated when the anchored lines themselves changed (GitHub's
//! semantics — an outdated thread still renders from its stored text).
//!
//! This module is the pure half: content in, hunks and ranges out. No
//! allocator, no git, no filesystem — so the rules that decide whether
//! your comment is still pointing at the right code are headless-testable
//! (`zig test src/anchor.zig`). Producing the hunks (git diff --no-index)
//! and resolving "current content" per side belongs to the layer that
//! owns the blob store; it is not here yet.

const std = @import("std");

/// git's blob hash: sha1("blob <len>\x00" + content), lowercase hex.
///
/// In-process on purpose — this is the fast path. Every anchor read hashes
/// the current file first, and the overwhelmingly common answer is "same
/// as stored", so this function decides whether re-anchoring costs one
/// hash or a fork.
pub fn blobSha(content: []const u8) [40]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    var hdr: [32]u8 = undefined;
    h.update(std.fmt.bufPrint(&hdr, "blob {d}\x00", .{content.len}) catch unreachable);
    h.update(content);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// One `@@ -old_start,old_count +new_start,new_count @@` header.
///
/// Counts are as the header states them, so `old_count == 0` is a PURE
/// INSERTION and carries the position-between-lines meaning that mapRange
/// depends on. Do not normalise it away.
pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// Walks the `@@` headers of a unified diff. Allocation-free: the whole
/// point of a `--unified=0` diff here is that we only ever want the
/// headers, never the bodies.
///
/// Only line-initial `@@` is a header, which is also why scanning is
/// equivalent to the Go side's multiline regex rather than an
/// approximation of it: in a unified diff every content line carries a
/// ' ', '-' or '+' prefix, so content that itself begins with "@@" can
/// never appear at column zero.
pub const Hunks = struct {
    rest: []const u8,

    pub fn next(self: *Hunks) ?Hunk {
        while (self.rest.len != 0) {
            const nl = std.mem.indexOfScalar(u8, self.rest, '\n');
            const line = if (nl) |i| self.rest[0..i] else self.rest;
            self.rest = if (nl) |i| self.rest[i + 1 ..] else self.rest[self.rest.len..];
            if (parseHeader(line)) |h| return h;
        }
        return null;
    }
};

pub fn hunks(diff: []const u8) Hunks {
    return .{ .rest = diff };
}

/// `@@ -a[,b] +c[,d] @@` → Hunk. An omitted count means 1, which is the
/// one piece of unified-diff shorthand that actually changes behaviour:
/// read it as 0 and every single-line edit becomes a pure insertion.
fn parseHeader(line: []const u8) ?Hunk {
    var p: usize = 0;
    if (!eat(line, &p, "@@ -")) return null;
    const old_start = num(line, &p) orelse return null;
    const old_count = if (eat(line, &p, ",")) num(line, &p) orelse return null else 1;
    if (!eat(line, &p, " +")) return null;
    const new_start = num(line, &p) orelse return null;
    const new_count = if (eat(line, &p, ",")) num(line, &p) orelse return null else 1;
    if (!eat(line, &p, " @@")) return null;
    return .{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
    };
}

fn eat(s: []const u8, p: *usize, lit: []const u8) bool {
    if (s.len - p.* < lit.len) return false;
    if (!std.mem.eql(u8, s[p.* .. p.* + lit.len], lit)) return false;
    p.* += lit.len;
    return true;
}

fn num(s: []const u8, p: *usize) ?u32 {
    const start = p.*;
    var v: u64 = 0;
    while (p.* < s.len and s[p.*] >= '0' and s[p.*] <= '9') : (p.* += 1) {
        v = v * 10 + (s[p.*] - '0');
        if (v > std.math.maxInt(u32)) return null; // absurd line number
    }
    if (p.* == start) return null;
    return @intCast(v);
}

/// The mapped view of a stored range. `outdated` means the anchored lines
/// themselves changed, and the caller keeps rendering the STORED range and
/// stored text — an anchor degrades, it never errors.
pub const Mapped = struct {
    start: u32,
    end: u32,
    outdated: bool,
};

/// Map a 1-based inclusive [start, end] from old-file coordinates through
/// `hs`, which must be in ascending old-file order (git emits them that
/// way).
///
/// Hunks entirely above shift the range by their net line delta. A hunk
/// touching the anchored lines outdates it. Pure insertions (old_count 0)
/// sit BETWEEN old lines old_start and old_start+1, which gives the three
/// boundary cases that the Go tests pin and that are easy to get subtly
/// wrong: above the range they shift it, strictly inside they outdate it,
/// and at or past the end they are invisible.
pub fn mapRange(hs: []const Hunk, start: u32, end: u32) Mapped {
    var delta: i64 = 0;
    for (hs) |hk| {
        if (hk.old_count == 0) {
            if (hk.old_start < start) {
                delta += hk.new_count;
            } else if (hk.old_start < end) {
                return .{ .start = start, .end = end, .outdated = true };
            }
            continue;
        }
        const old_end = hk.old_start + hk.old_count - 1;
        if (old_end < start) {
            delta += @as(i64, hk.new_count) - @as(i64, hk.old_count);
        } else if (hk.old_start > end) {
            // below the range — invisible
        } else {
            return .{ .start = start, .end = end, .outdated = true };
        }
    }
    // Clamped at line 1, where Go's int arithmetic would just go negative.
    // Only reachable from hunks that contradict the range they are being
    // applied to; 1 is the honest floor, and a nonsense line number is not
    // representable here the way it is there.
    return .{
        .start = shift(start, delta),
        .end = shift(end, delta),
        .outdated = false,
    };
}

fn shift(line: u32, delta: i64) u32 {
    const v = @as(i64, line) + delta;
    return if (v < 1) 1 else @intCast(v);
}

// ---------------------------------------------------------------------
// Tests. The first three are ports of reanchor_test.go's TestGitBlobSHA,
// TestParseHunks and TestMapRange — same inputs, same expectations, so a
// divergence between the two implementations shows up as a red test on
// one side rather than as an anchor that lands two lines off.
// ---------------------------------------------------------------------

test "blob sha matches git hash-object" {
    // git's own canonical examples: `echo hello | git hash-object --stdin`
    try std.testing.expectEqualStrings(
        "ce013625030ba8dba906f756967f9e9ca394464a",
        &blobSha("hello\n"),
    );
    try std.testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        &blobSha(""),
    );
}

test "parse unified=0 headers" {
    const diff =
        \\diff --git a/a b/b
        \\index ce01362..0f2416e 100644
        \\--- a/a
        \\+++ b/b
        \\@@ -2,0 +3,2 @@
        \\+x
        \\+y
        \\@@ -10,3 +12 @@
        \\-a
        \\-b
        \\-c
        \\+z
        \\
    ;
    var it = hunks(diff);
    try std.testing.expectEqual(Hunk{ .old_start = 2, .old_count = 0, .new_start = 3, .new_count = 2 }, it.next().?);
    // The omitted count on the +12 side is the shorthand that means 1.
    try std.testing.expectEqual(Hunk{ .old_start = 10, .old_count = 3, .new_start = 12, .new_count = 1 }, it.next().?);
    try std.testing.expectEqual(@as(?Hunk, null), it.next());
}

test "map a stored range through hunks" {
    const Case = struct {
        name: []const u8,
        hs: []const Hunk,
        start: u32,
        end: u32,
        want: Mapped,
    };
    const cases = [_]Case{
        .{ .name = "no hunks", .hs = &.{}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = false } },
        .{ .name = "insertion above shifts down", .hs = &.{.{ .old_start = 2, .old_count = 0, .new_start = 3, .new_count = 2 }}, .start = 5, .end = 7, .want = .{ .start = 7, .end = 9, .outdated = false } },
        .{ .name = "deletion above shifts up", .hs = &.{.{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 0 }}, .start = 10, .end = 12, .want = .{ .start = 7, .end = 9, .outdated = false } },
        .{ .name = "replacement above shifts by delta", .hs = &.{.{ .old_start = 1, .old_count = 2, .new_start = 1, .new_count = 5 }}, .start = 10, .end = 12, .want = .{ .start = 13, .end = 15, .outdated = false } },
        .{ .name = "change below is invisible", .hs = &.{.{ .old_start = 20, .old_count = 2, .new_start = 20, .new_count = 4 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = false } },
        .{ .name = "edit inside range outdates", .hs = &.{.{ .old_start = 6, .old_count = 1, .new_start = 6, .new_count = 1 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = true } },
        .{ .name = "edit overlapping start outdates", .hs = &.{.{ .old_start = 3, .old_count = 4, .new_start = 3, .new_count = 1 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = true } },
        .{ .name = "insertion strictly inside outdates", .hs = &.{.{ .old_start = 5, .old_count = 0, .new_start = 6, .new_count = 2 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = true } },
        .{ .name = "insertion at range start shifts", .hs = &.{.{ .old_start = 4, .old_count = 0, .new_start = 5, .new_count = 2 }}, .start = 5, .end = 7, .want = .{ .start = 7, .end = 9, .outdated = false } },
        .{ .name = "insertion at range end is below", .hs = &.{.{ .old_start = 7, .old_count = 0, .new_start = 8, .new_count = 2 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = false } },
        .{ .name = "whole range deleted outdates", .hs = &.{.{ .old_start = 4, .old_count = 6, .new_start = 4, .new_count = 0 }}, .start = 5, .end = 7, .want = .{ .start = 5, .end = 7, .outdated = true } },
    };
    for (cases) |c| {
        const got = mapRange(c.hs, c.start, c.end);
        std.testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("case: {s}\n", .{c.name});
            return err;
        };
    }
}

test "parse and map compose over a real diff" {
    // Two lines inserted at the top: an anchor on l3-l4 rides down to 5-6.
    // This is reanchor_test.go's TestAnchorNow "shift" step, minus the
    // filesystem — the arithmetic it was really checking.
    const diff =
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
        \\
    ;
    var buf: [8]Hunk = undefined;
    var n: usize = 0;
    var it = hunks(diff);
    while (it.next()) |h| : (n += 1) buf[n] = h;
    try std.testing.expectEqual(Mapped{ .start = 5, .end = 6, .outdated = false }, mapRange(buf[0..n], 3, 4));
}

test "malformed headers are skipped, not fatal" {
    // A truncated header and a content line that merely starts with '@'
    // must both fall through; only line-initial, well-formed "@@" counts.
    const diff =
        \\@@ -1,2 +3
        \\@@@ -1 +1 @@
        \\ @@ -1 +1 @@
        \\@@ -4,1 +4,2 @@
        \\
    ;
    var it = hunks(diff);
    try std.testing.expectEqual(Hunk{ .old_start = 4, .old_count = 1, .new_start = 4, .new_count = 2 }, it.next().?);
    try std.testing.expectEqual(@as(?Hunk, null), it.next());
}
