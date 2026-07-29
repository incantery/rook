//! A diff, as a document you can read.
//!
//! diffsource.zig answers what changed and what the two sides are. This
//! turns that into the thing a pane actually shows: unified patch text,
//! plus one Row per line saying what that line IS — context, addition,
//! deletion, a hunk header — and which line of each side it belongs to.
//!
//! Unified rather than side-by-side, and that is a choice worth defending.
//! Side-by-side needs about 160 columns before it stops truncating code,
//! and rook's differentiator is the REVIEW — the findings, the gate, the
//! verdict ledger — not the diff chrome. Unified is also what every
//! terminal-native reviewer already reads (git, delta, lazygit, magit), so
//! it costs nobody a new habit. The row map is deliberately presentation-
//! agnostic: it carries both sides' line numbers, which is exactly what a
//! side-by-side mode would need if one is ever wanted, so choosing unified
//! now does not spend that option.
//!
//! Two properties this exists to guarantee:
//!
//! The GUTTER shows file line numbers, not buffer row numbers. A reviewer
//! reads a diff to decide something about a file, and every other surface
//! in rook — a finding at f.zig:7, a thread anchored to a range, a stack
//! trace — names a file line. A gutter counting patch rows would make the
//! reader do that arithmetic by hand, on every row, and the whole point of
//! the row map is that it doesn't have to.
//!
//! And it is BUILT FROM TWO TEXTS, never from a path. So the same code
//! renders a working tree, a commit, and two sides a remote host sent over
//! from a machine that has the repo when this one does not — which is the
//! diff-source indifference the substrate promises, made real at the
//! presentation layer instead of stopping at the data one.

const std = @import("std");
const git = @import("git.zig");
const diffsource = @import("diffsource.zig");

/// Context lines around each change. Three is git's default and what
/// nearly every reviewer's eye is calibrated to.
pub const default_context: u32 = 3;

/// Largest patch we will hold. A patch is bounded by the two sides, which
/// diffsource already caps, plus prefixes — so this is slack rather than
/// a policy.
const max_patch = 8 << 20;

pub const Kind = enum(u8) {
    /// A header rook wrote: the path, the base, a state like "binary".
    /// Never part of either side.
    meta,
    /// An `@@ ... @@` hunk header.
    hunk,
    /// Unchanged, present in both sides.
    context,
    /// Present only in the modified side.
    add,
    /// Present only in the original side.
    del,
};

pub const Row = struct {
    kind: Kind,
    /// 1-based line in the original side, or 0 when this row is not in
    /// it (an addition, a header).
    old_line: u32 = 0,
    /// 1-based line in the modified side, or 0 when this row is not in
    /// it (a deletion, a header).
    new_line: u32 = 0,
    /// Which entry of `files` this row belongs to. Meaningful for every
    /// kind, so a jump from a header still knows its file.
    file: u32 = 0,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    /// The document, newline-separated — what an editor buffer holds.
    text: []const u8 = "",
    /// One entry per line of `text`, in order. Same length as the line
    /// count, which is the invariant the whole gutter rests on.
    rows: []const Row = &.{},
    /// The paths this document covers, in the order they appear.
    files: []const []const u8 = &.{},

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }

    /// The row showing `line` of the modified side of `file`, or the
    /// nearest row above it.
    ///
    /// "Nearest above" rather than "not found" on purpose: a finding can
    /// name a line that this diff does not show — inside an unchanged
    /// stretch between hunks, or in a file whose change was truncated —
    /// and landing on the nearest hunk is still useful where landing on
    /// row zero is not. That is the same degrade-never-fail rule the
    /// anchors follow.
    pub fn rowForLine(self: *const Doc, file: u32, line: u32) usize {
        var best: usize = 0;
        for (self.rows, 0..) |r, i| {
            if (r.file != file) continue;
            if (best == 0) best = i; // this file's first row, as a floor
            if (r.new_line == 0) continue;
            if (r.new_line == line) return i;
            if (r.new_line < line) best = i;
        }
        return best;
    }

    /// Which file a row belongs to, as a path. Empty when out of range.
    pub fn pathOf(self: *const Doc, row: usize) []const u8 {
        if (row >= self.rows.len) return "";
        const i = self.rows[row].file;
        return if (i < self.files.len) self.files[i] else "";
    }
};

/// Accumulates text and rows together, so they cannot get out of step.
///
/// Every line goes through addLine. That is the single invariant this
/// module has to hold — one Row per line of text — and the way to keep it
/// is to leave no other way to append.
const Builder = struct {
    arena: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    file: u32 = 0,

    fn addLine(self: *Builder, kind: Kind, old_line: u32, new_line: u32, body: []const u8) void {
        self.text.appendSlice(self.arena, body) catch return;
        self.text.append(self.arena, '\n') catch return;
        self.rows.append(self.arena, .{
            .kind = kind,
            .old_line = old_line,
            .new_line = new_line,
            .file = self.file,
        }) catch {};
    }

    fn addFmt(self: *Builder, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.addLine(kind, 0, 0, s);
    }
};

pub const Options = struct {
    context: u32 = default_context,
    /// Shown in the per-file header, when the caller knows it (the
    /// changes list does). Empty omits it.
    status: []const u8 = "",
};

/// One file's section, appended to `b`. Returns nothing: a file that
/// cannot be diffed still gets a header saying so, because a reviewer
/// needs to know it was SKIPPED rather than clean.
fn appendFile(
    b: *Builder,
    io: std.Io,
    path: []const u8,
    sides: *const diffsource.Sides,
    opts: Options,
) void {
    b.file = @intCast(b.files.items.len);
    b.files.append(b.arena, b.arena.dupe(u8, path) catch path) catch {};

    if (b.rows.items.len > 0) b.addLine(.meta, 0, 0, "");
    b.addFmt(.meta, "{s}", .{path});

    var detail: std.ArrayListUnmanaged(u8) = .empty;
    if (opts.status.len > 0) detail.appendSlice(b.arena, opts.status) catch {};
    if (detail.items.len > 0) detail.appendSlice(b.arena, " · ") catch {};
    detail.appendSlice(b.arena, "base ") catch {};
    detail.appendSlice(b.arena, sides.base.name) catch {};
    if (sides.base.fallback.len > 0) {
        detail.appendSlice(b.arena, " · ") catch {};
        detail.appendSlice(b.arena, sides.base.fallback) catch {};
    }
    b.addLine(.meta, 0, 0, detail.items);

    if (sides.binary) {
        b.addLine(.meta, 0, 0, "binary file — no text to compare");
        return;
    }

    const patch = git.diffTexts(b.arena, io, sides.original, sides.modified, opts.context, max_patch) orelse {
        // No git, or git failed. Say so rather than rendering "no
        // changes", which is a different and much more misleading claim.
        b.addLine(.meta, 0, 0, "diff unavailable — could not run git");
        return;
    };
    if (patch.stdout.len == 0) {
        b.addLine(.meta, 0, 0, "no changes");
        return;
    }
    appendPatch(b, patch.stdout);
    if (sides.truncated) b.addLine(.meta, 0, 0, "… file truncated at the size cap; diff is partial");
}

/// Walk a unified patch, numbering both sides as it goes.
///
/// git's own `diff --git`/`index`/`---`/`+++` headers are DROPPED. With
/// --no-index they name the scratch files ("a/a", "b/b"), so showing them
/// would put two lies where the path belongs; the header rook wrote above
/// says the true path already.
fn appendPatch(b: *Builder, patch: []const u8) void {
    var old_line: u32 = 0;
    var new_line: u32 = 0;
    var in_hunk = false;

    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |line| {
        // The trailing empty field after the final newline is not a row.
        if (line.len == 0) {
            if (it.rest().len == 0) break;
            // A genuinely empty line inside a hunk is a context line
            // whose single space prefix git omits for an empty line...
            // except it does not: git emits " " for those. An empty line
            // here therefore only happens outside a hunk, where it is
            // not content.
            if (!in_hunk) continue;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            const h = parseHunkHeader(line) orelse continue;
            old_line = h.old_start;
            new_line = h.new_start;
            in_hunk = true;
            b.addLine(.hunk, 0, 0, line);
            continue;
        }
        if (!in_hunk) continue; // git's file headers
        switch (line[0]) {
            '+' => {
                b.addLine(.add, 0, new_line, line);
                new_line += 1;
            },
            '-' => {
                b.addLine(.del, old_line, 0, line);
                old_line += 1;
            },
            ' ' => {
                b.addLine(.context, old_line, new_line, line);
                old_line += 1;
                new_line += 1;
            },
            // "\ No newline at end of file" — a note about the line
            // above, belonging to neither side.
            '\\' => b.addLine(.meta, 0, 0, line),
            else => {},
        }
    }
}

const HunkHeader = struct { old_start: u32, new_start: u32 };

/// `@@ -old[,count] +new[,count] @@ ...`
///
/// A count of 0 means the range is EMPTY and its start names the line
/// BEFORE it — a pure insertion at "-5,0" adds after old line 5. Bumping
/// such a start to 5 would number the first following row one line early,
/// so the zero-count case keeps the start as given and lets the walk
/// begin at the right place: with no rows to consume on that side, the
/// number is never used.
fn parseHunkHeader(line: []const u8) ?HunkHeader {
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse return null;
    const old = parseRange(line[minus + 1 ..]) orelse return null;
    const new = parseRange(line[plus + 1 ..]) orelse return null;
    return .{
        .old_start = if (old.count == 0) old.start + 1 else old.start,
        .new_start = if (new.count == 0) new.start + 1 else new.start,
    };
}

fn parseRange(s: []const u8) ?struct { start: u32, count: u32 } {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == 0) return null;
    const start = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    if (i < s.len and s[i] == ',') {
        var j = i + 1;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
        const count = std.fmt.parseInt(u32, s[i + 1 .. j], 10) catch return null;
        return .{ .start = start, .count = count };
    }
    // No comma means a count of exactly 1.
    return .{ .start = start, .count = 1 };
}

/// One file's diff as a document.
pub fn one(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    sides: *const diffsource.Sides,
    opts: Options,
) Doc {
    var d: Doc = .{ .arena = .init(gpa) };
    var b: Builder = .{ .arena = d.arena.allocator() };
    appendFile(&b, io, path, sides, opts);
    d.text = b.text.items;
    d.rows = b.rows.items;
    d.files = b.files.items;
    return d;
}

/// Every changed file, in one document.
///
/// `fetch` supplies each file's two sides — a closure rather than a
/// substrate handle, so this module stays testable without a registry and
/// stays usable by a caller whose sides come from somewhere else entirely.
pub fn all(
    gpa: std.mem.Allocator,
    io: std.Io,
    changes: *const diffsource.Changes,
    ctx: anytype,
    comptime fetch: fn (@TypeOf(ctx), []const u8) diffsource.Sides,
    opts: Options,
) Doc {
    var d: Doc = .{ .arena = .init(gpa) };
    var b: Builder = .{ .arena = d.arena.allocator() };

    if (changes.files.len == 0) {
        b.files.append(b.arena, "") catch {};
        b.addLine(.meta, 0, 0, "no changes");
    }
    for (changes.files) |f| {
        var sides = fetch(ctx, f.path);
        defer sides.deinit();
        var o = opts;
        o.status = f.status.word();
        appendFile(&b, io, f.path, &sides, o);
    }
    if (changes.truncated) b.addLine(.meta, 0, 0, "… more files changed than this list shows");

    d.text = b.text.items;
    d.rows = b.rows.items;
    d.files = b.files.items;
    return d;
}

// ---------------------------------------------------------------------

const testing = std.testing;

/// A Sides built from two literals, with no repo anywhere. This is the
/// property the module's header claims — built from texts, never from a
/// path — so the tests are written the same way.
fn literalSides(gpa: std.mem.Allocator, original: []const u8, modified: []const u8) diffsource.Sides {
    var s: diffsource.Sides = .{ .arena = .init(gpa) };
    const arena = s.arena.allocator();
    s.original = arena.dupe(u8, original) catch "";
    s.modified = arena.dupe(u8, modified) catch "";
    return s;
}

/// The document's rows, rendered as `kind old new | text` — so a failure
/// shows the map and the text together, which is the only way to see that
/// they agree.
fn dump(gpa: std.mem.Allocator, d: *const Doc) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, d.text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= d.rows.len) break;
        const r = d.rows[i];
        const s = std.fmt.allocPrint(gpa, "{s} {d} {d} | {s}\n", .{
            @tagName(r.kind), r.old_line, r.new_line, line,
        }) catch break;
        defer gpa.free(s);
        out.appendSlice(gpa, s) catch break;
    }
    return out.toOwnedSlice(gpa) catch "";
}

test "the row map and the text stay the same length" {
    // The invariant every other guarantee here rests on. A patch line the
    // walk forgot to map would slide the gutter by one from that point
    // down, which is worse than no gutter: the numbers would still look
    // plausible.
    var sides = literalSides(testing.allocator, "a\nb\nc\nd\ne\nf\ng\nh\n", "a\nb\nC\nd\ne\nf\nADDED\ng\nh\n");
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "f.txt", &sides, .{});
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest; // no git

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, d.text, '\n');
    while (it.next()) |_| lines += 1;
    // splitScalar yields a trailing empty field after the final newline.
    try testing.expectEqual(d.rows.len, lines - 1);
}

test "both sides are numbered, and the numbers are the FILE's" {
    var sides = literalSides(
        testing.allocator,
        "one\ntwo\nthree\nfour\nfive\n",
        "one\nTWO\nthree\nfour\nfive\n",
    );
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "f.txt", &sides, .{ .context = 1 });
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;

    const text = dump(testing.allocator, &d);
    defer testing.allocator.free(text);

    // The header rook wrote, then the hunk, then one context line, the
    // replaced pair, and one context line after.
    try testing.expect(std.mem.indexOf(u8, text, "meta 0 0 | f.txt\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "context 1 1 |  one") != null);
    // The changed line is line 2 on BOTH sides, and the two rows say so
    // separately — the deletion carries only an old number, the addition
    // only a new one.
    try testing.expect(std.mem.indexOf(u8, text, "del 2 0 | -two") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add 0 2 | +TWO") != null);
    try testing.expect(std.mem.indexOf(u8, text, "context 3 3 |  three") != null);
    // git's --no-index headers name scratch files; none may survive.
    try testing.expect(std.mem.indexOf(u8, text, "a/a") == null);
    try testing.expect(std.mem.indexOf(u8, text, "b/b") == null);
    try testing.expect(std.mem.indexOf(u8, text, "diff --git") == null);
}

test "an insertion does not shift the numbers of what follows it" {
    // The zero-count hunk header: "@@ -3,0 +4,2 @@" means the two added
    // lines land AFTER old line 3. Reading that start as the next old
    // line would number every following context row one early — and it
    // would look right, because the sequence stays consecutive.
    var sides = literalSides(
        testing.allocator,
        "a\nb\nc\nd\ne\n",
        "a\nb\nc\nX\nY\nd\ne\n",
    );
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "f.txt", &sides, .{ .context = 1 });
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;

    const text = dump(testing.allocator, &d);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "add 0 4 | +X") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add 0 5 | +Y") != null);
    // 'd' is old line 4 and new line 6. Both halves matter: the old
    // number proves the insertion consumed nothing on that side, the new
    // one proves it consumed two.
    try testing.expect(std.mem.indexOf(u8, text, "context 4 6 |  d") != null);
}

test "rowForLine lands on the line asked for, or the nearest above" {
    var sides = literalSides(
        testing.allocator,
        "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n",
        "1\n2\n3\nCHANGED\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\nALSO\n18\n19\n20\n",
    );
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "f.txt", &sides, .{ .context = 1 });
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;

    // A line the diff shows: exact hit.
    const at4 = d.rowForLine(0, 4);
    try testing.expectEqual(@as(u32, 4), d.rows[at4].new_line);
    const at17 = d.rowForLine(0, 17);
    try testing.expectEqual(@as(u32, 17), d.rows[at17].new_line);

    // A line in the unchanged stretch BETWEEN the two hunks, which this
    // diff does not show at all. The answer is the nearest row above, not
    // row zero — a finding on line 10 should land you in the first hunk,
    // not at the top of the document.
    const at10 = d.rowForLine(0, 10);
    try testing.expect(d.rows[at10].new_line > 0);
    try testing.expect(d.rows[at10].new_line < 10);
    try testing.expect(at10 > 0);
}

test "a binary side says so instead of showing nothing" {
    var sides = literalSides(testing.allocator, "", "");
    defer sides.deinit();
    sides.binary = true;
    var d = one(testing.allocator, testing.io, "logo.png", &sides, .{});
    defer d.deinit();
    try testing.expect(std.mem.indexOf(u8, d.text, "binary file") != null);
    // Every line still has a row, headers included.
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, d.text, '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(d.rows.len, lines - 1);
}

test "identical sides read as no changes, not as an empty document" {
    var sides = literalSides(testing.allocator, "same\n", "same\n");
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "f.txt", &sides, .{});
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;
    try testing.expect(std.mem.indexOf(u8, d.text, "no changes") != null);
}

test "a new file is all additions, numbered from one" {
    var sides = literalSides(testing.allocator, "", "first\nsecond\n");
    defer sides.deinit();
    var d = one(testing.allocator, testing.io, "new.txt", &sides, .{ .status = "added" });
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;

    const text = dump(testing.allocator, &d);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "add 0 1 | +first") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add 0 2 | +second") != null);
    try testing.expect(std.mem.indexOf(u8, text, "added · base HEAD") != null);
}

test "several files share one document, and rows name their own file" {
    const Fetcher = struct {
        gpa: std.mem.Allocator,
        fn fetch(self: @This(), path: []const u8) diffsource.Sides {
            if (std.mem.eql(u8, path, "a.txt")) return literalSides(self.gpa, "one\n", "ONE\n");
            return literalSides(self.gpa, "two\n", "TWO\n");
        }
    };

    var ch: diffsource.Changes = .{ .arena = .init(testing.allocator) };
    defer ch.deinit();
    const arena = ch.arena.allocator();
    var list: std.ArrayListUnmanaged(diffsource.File) = .empty;
    try list.append(arena, .{ .path = "a.txt", .status = .modified });
    try list.append(arena, .{ .path = "b.txt", .status = .modified });
    ch.files = list.items;

    var d = all(testing.allocator, testing.io, &ch, Fetcher{ .gpa = testing.allocator }, Fetcher.fetch, .{ .context = 0 });
    defer d.deinit();
    if (d.rows.len == 0) return error.SkipZigTest;

    try testing.expectEqual(@as(usize, 2), d.files.len);
    try testing.expectEqualStrings("a.txt", d.files[0]);
    try testing.expectEqualStrings("b.txt", d.files[1]);

    // A row in the second file resolves to the second file — the check
    // that makes a multi-file jump land in the right place rather than
    // at the same line number of the first file.
    const at_b = d.rowForLine(1, 1);
    try testing.expectEqualStrings("b.txt", d.pathOf(at_b));
    try testing.expect(std.mem.indexOf(u8, d.text, "+TWO") != null);

    // ...and the same line number in file 0 is a DIFFERENT row.
    const at_a = d.rowForLine(0, 1);
    try testing.expectEqualStrings("a.txt", d.pathOf(at_a));
    try testing.expect(at_a != at_b);
}

test "no changes anywhere is still a document" {
    var ch: diffsource.Changes = .{ .arena = .init(testing.allocator) };
    defer ch.deinit();
    const Fetcher = struct {
        fn fetch(_: @This(), _: []const u8) diffsource.Sides {
            unreachable; // nothing to fetch
        }
    };
    var d = all(testing.allocator, testing.io, &ch, Fetcher{}, Fetcher.fetch, .{});
    defer d.deinit();
    try testing.expect(std.mem.indexOf(u8, d.text, "no changes") != null);
    try testing.expectEqual(@as(usize, 1), d.rows.len);
}

test "parseHunkHeader" {
    try testing.expectEqual(@as(u32, 3), parseHunkHeader("@@ -3,4 +3,5 @@").?.old_start);
    try testing.expectEqual(@as(u32, 3), parseHunkHeader("@@ -3,4 +3,5 @@").?.new_start);
    // No comma means a count of one.
    try testing.expectEqual(@as(u32, 7), parseHunkHeader("@@ -7 +7 @@").?.old_start);
    // Zero count: the start names the line BEFORE the empty range, so the
    // first row on that side is start+1.
    try testing.expectEqual(@as(u32, 4), parseHunkHeader("@@ -3,0 +4,2 @@").?.old_start);
    try testing.expectEqual(@as(u32, 4), parseHunkHeader("@@ -3,0 +4,2 @@").?.new_start);
    // A trailing function context is ignored, not parsed.
    try testing.expectEqual(@as(u32, 12), parseHunkHeader("@@ -12,3 +12,3 @@ fn main() {").?.old_start);
    try testing.expectEqual(@as(?HunkHeader, null), parseHunkHeader("@@ nonsense @@"));
}
