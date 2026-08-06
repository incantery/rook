//! Fuzzy matching: does this needle occur in this haystack as a
//! subsequence, how good is that occurrence, and WHERE did it land.
//!
//! One matcher, two profiles. rook has two lists worth ranking and they
//! want different things rewarded — a file picker cares about basenames
//! and short paths, a completion menu cares about camelCase humps — but
//! the walk, the scoring shape and the traceback are the same code. The
//! difference is a table of weights.
//!
//! The positions are the reason this is not just a score. A menu that
//! ranks by fuzzy match and then underlines a PREFIX is lying about why
//! a row is there: type `pln` and the thing to pick out of `Println` is
//! p, l and n, not `Pln`, which does not occur in it.
//!
//! ## Why a DP rather than a greedy scan
//!
//! Greedy takes the first occurrence of each needle character, which
//! finds *a* match but often not the best one. `all` against `readAll`
//! greedily takes the `a` of `read`, and then the run is broken and the
//! highlight is wrong — the answer a reader expects is the `All`, which
//! is contiguous AND on a word boundary. Getting that right means
//! considering later occurrences, which is a DP.
//!
//! It is bounded rather than clever: past `max_hay` or `max_needle` the
//! table would stop being free, and a candidate that long is not the one
//! being picked. Those fall back to the greedy walk, which still matches
//! and still scores — just not optimally.

const std = @import("std");

/// What a profile rewards. Every field is "points", and the only thing
/// that matters is their ratio to each other.
pub const Weights = struct {
    /// A character that starts a word: position zero, after a
    /// separator, or the upper half of a camelCase hump. The single
    /// most useful signal in both lists.
    boundary: i32,
    /// Adjacent to the previously matched character. What makes a typed
    /// run beat the same letters scattered across the candidate.
    adjacent: i32,
    /// The needle's case matched the haystack's exactly. Small: it
    /// breaks ties between `Printf` and `printf` when you typed `P`,
    /// and must never outrank a boundary.
    same_case: i32,
    /// Every matched character is worth something on its own, or a long
    /// needle would score no better than a short one.
    base: i32,
    /// Subtracted per character of haystack, scaled — the tiebreak that
    /// puts the shorter of two equally good candidates first.
    length_penalty_div: usize,
    /// Subtracted per character skipped before the FIRST match. Typing
    /// `main` should rank `main.zig` over `src/domain/main.zig`.
    leading_skip: i32,
    /// Subtracted each time the match BREAKS — every run after the
    /// first. Without it, three word-boundary hits scattered across
    /// `parallelResearchIndex` outscore the contiguous `print`, because
    /// boundaries are worth more than adjacency one character at a
    /// time. How scattered a match is, is its own signal.
    gap: i32,
    /// Characters that start a word when they precede one.
    separators: []const u8,
    /// Score everything at or after the last `/` as being in the
    /// basename. Paths only; an identifier has no such split.
    basename_bonus: i32,
};

/// Identifiers: what a completion menu ranks.
///
/// camelCase is the whole difference from the path profile. `fpr` should
/// find `fmt.Fprintf`, and it only does if the `F` after a `.` and the
/// `P` inside `Fprintf` both count as word starts.
pub const ident: Weights = .{
    .boundary = 16,
    .adjacent = 10,
    .same_case = 4,
    .base = 2,
    .length_penalty_div = 8,
    .leading_skip = 1,
    .gap = 12,
    .separators = "._-$/",
    .basename_bonus = 0,
};

/// Paths: what ⌘P ranks.
///
/// These are the numbers the file finder shipped with, kept as they
/// were. What it rewards, in the order it matters: matching in the
/// BASENAME (you type `main` for main.zig, not for src/domain/x.zig),
/// contiguous runs, a match at a word boundary, and a short path.
pub const path: Weights = .{
    .boundary = 8,
    .adjacent = 10,
    .same_case = 0,
    .base = 0,
    .length_penalty_div = 4,
    .leading_skip = 0,
    // Zero, so ⌘P keeps ranking exactly as it did: a path match is
    // scattered across directories by nature, and penalising that would
    // bury every file whose name you typed only part of.
    .gap = 0,
    .separators = "/_-.",
    .basename_bonus = 12,
};

/// The most matched positions reported. A needle longer than this still
/// matches and still scores; only the highlight stops growing, and a
/// menu row is not that wide anyway.
pub const max_pos = 32;

/// Haystacks longer than this take the greedy path rather than the DP.
const max_hay = 256;
/// Needles longer than this, likewise.
const max_needle = 32;

pub const Match = struct {
    score: i32,
    /// Byte offsets into the haystack, ascending, that the needle
    /// landed on. `n` of them are filled.
    pos: [max_pos]u16 = undefined,
    n: usize = 0,

    /// Is `i` one of the matched positions? Linear on purpose: `n` is at
    /// most 32 and this is called once per drawn cell of one menu row.
    pub fn hit(self: *const Match, i: usize) bool {
        for (self.pos[0..self.n]) |p| {
            if (p == i) return true;
        }
        return false;
    }
};

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Does the haystack character at `i` start a word?
fn boundaryAt(hay: []const u8, i: usize, w: Weights) bool {
    if (i == 0) return true;
    const prev = hay[i - 1];
    if (std.mem.indexOfScalar(u8, w.separators, prev) != null) return true;
    // A camelCase hump. Also covers `HTTPServer` → the `S`, since the
    // test is on the PREVIOUS character being lower.
    if (std.ascii.isLower(prev) and std.ascii.isUpper(hay[i])) return true;
    // A digit after a letter, or a letter after a digit: `utf8Decode`.
    if (!isWordChar(prev) and isWordChar(hay[i])) return true;
    return false;
}

/// What matching needle character `nc` at haystack position `i` is
/// worth, given whether it continues a run.
fn charScore(hay: []const u8, i: usize, nc: u8, adjacent: bool, w: Weights) i32 {
    var s: i32 = w.base;
    if (boundaryAt(hay, i, w)) s += w.boundary;
    if (adjacent) s += w.adjacent else s -= w.gap;
    if (hay[i] == nc) s += w.same_case;
    return s;
}

/// Score and locate `needle` in `hay`, or null if it does not occur as a
/// case-insensitive subsequence.
///
/// An empty needle matches everything with score 0, which is what makes
/// an empty filter show the list in its original order.
pub fn match(hay: []const u8, needle: []const u8, w: Weights) ?Match {
    if (needle.len == 0) return Match{ .score = 0 };
    if (needle.len > hay.len) return null;
    if (hay.len > max_hay or needle.len > max_needle) return greedy(hay, needle, w);
    return best(hay, needle, w);
}

/// Just the question, for callers that do not rank.
pub fn matches(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var hi: usize = 0;
    for (needle) |nc| {
        const n = lower(nc);
        while (hi < hay.len and lower(hay[hi]) != n) hi += 1;
        if (hi == hay.len) return false;
        hi += 1;
    }
    return true;
}

/// The bounded optimum: for each needle character and each haystack
/// position, the best total score of a match ending exactly there.
///
/// Two rows are enough — a cell only ever reads the row above — but the
/// traceback needs to know, for each cell, whether it continued a run.
/// That is one bit per cell, so it is kept for the whole table.
fn best(hay: []const u8, needle: []const u8, w: Weights) ?Match {
    const H = hay.len;
    const N = needle.len;
    const none = std.math.minInt(i32);

    var prev: [max_hay]i32 = undefined;
    var cur: [max_hay]i32 = undefined;
    // `from[k][i]`: the haystack position the best match for needle
    // 0..=k ending at `i` came from, or maxInt for "this was the first".
    var from: [max_needle][max_hay]u16 = undefined;

    for (0..N) |k| {
        const nc = needle[k];
        const n = lower(nc);
        var any = false;
        for (0..H) |i| {
            cur[i] = none;
            if (lower(hay[i]) != n) continue;
            if (k == 0) {
                // The first character pays for what it skipped past, so
                // an early match beats a late one, all else equal.
                cur[i] = charScore(hay, i, nc, false, w) + w.gap -
                    @as(i32, @intCast(i)) * w.leading_skip;
                from[k][i] = std.math.maxInt(u16);
                any = true;
                continue;
            }
            // Best predecessor: any position strictly before `i`.
            var bestp: i32 = none;
            var bestj: u16 = 0;
            for (0..i) |j| {
                if (prev[j] == none) continue;
                const s = prev[j] + charScore(hay, i, nc, j + 1 == i, w);
                if (s > bestp) {
                    bestp = s;
                    bestj = @intCast(j);
                }
            }
            if (bestp == none) continue;
            cur[i] = bestp;
            from[k][i] = bestj;
            any = true;
        }
        if (!any) return null;
        @memcpy(prev[0..H], cur[0..H]);
    }

    // The best end position for the whole needle.
    var end: usize = 0;
    var top: i32 = none;
    for (0..H) |i| {
        if (prev[i] > top) {
            top = prev[i];
            end = i;
        }
    }
    if (top == none) return null;

    var m = Match{ .score = top - @as(i32, @intCast(hay.len / w.length_penalty_div)) };
    if (w.basename_bonus != 0) {
        const base_at = if (std.mem.lastIndexOfScalar(u8, hay, '/')) |i| i + 1 else 0;
        var at = end;
        var k = N;
        while (k > 0) : (k -= 1) {
            if (at >= base_at) m.score += w.basename_bonus;
            const f = from[k - 1][at];
            if (f == std.math.maxInt(u16)) break;
            at = f;
        }
    }

    // Traceback, filling positions from the end.
    var buf: [max_needle]u16 = undefined;
    var at = end;
    var k = N;
    while (k > 0) : (k -= 1) {
        buf[k - 1] = @intCast(at);
        const f = from[k - 1][at];
        if (f == std.math.maxInt(u16)) break;
        at = f;
    }
    m.n = @min(N, max_pos);
    @memcpy(m.pos[0..m.n], buf[0..m.n]);
    return m;
}

/// The unbounded fallback: first occurrence of each character, scored
/// the same way. Not optimal, and only reached by candidates too long
/// for anyone to be reading closely.
fn greedy(hay: []const u8, needle: []const u8, w: Weights) ?Match {
    var m = Match{ .score = 0 };
    var hi: usize = 0;
    var prev_end: usize = std.math.maxInt(usize);
    const base_at = if (w.basename_bonus != 0)
        (if (std.mem.lastIndexOfScalar(u8, hay, '/')) |i| i + 1 else 0)
    else
        0;
    for (needle, 0..) |nc, k| {
        const n = lower(nc);
        while (hi < hay.len and lower(hay[hi]) != n) hi += 1;
        if (hi == hay.len) return null;
        m.score += charScore(hay, hi, nc, prev_end == hi, w);
        if (k == 0) m.score += w.gap; // the first match starts a run, it does not break one
        if (w.basename_bonus != 0 and hi >= base_at) m.score += w.basename_bonus;
        if (k == 0) m.score -= @as(i32, @intCast(hi)) * w.leading_skip;
        if (m.n < max_pos) {
            m.pos[m.n] = @intCast(hi);
            m.n += 1;
        }
        prev_end = hi + 1;
        hi += 1;
    }
    m.score -= @intCast(hay.len / w.length_penalty_div);
    return m;
}

// ----------------------------------------------------------------- tests

const T = std.testing;

/// The score of `needle` against `hay`, or the minimum when it misses.
fn sc(hay: []const u8, needle: []const u8, w: Weights) i32 {
    const m = match(hay, needle, w) orelse return std.math.minInt(i32);
    return m.score;
}

/// Assert `a` outranks `b` for `needle`.
fn beats(needle: []const u8, a: []const u8, b: []const u8, w: Weights) !void {
    const sa = sc(a, needle, w);
    const sb = sc(b, needle, w);
    if (sa <= sb) {
        std.debug.print("\n`{s}`: expected {s} ({d}) to beat {s} ({d})\n", .{ needle, a, sa, b, sb });
        return error.WrongOrder;
    }
}

test "a subsequence matches and a non-subsequence does not" {
    try T.expect(match("Println", "pln", ident) != null);
    try T.expect(match("Println", "Pri", ident) != null);
    // Right letters, wrong order.
    try T.expect(match("Println", "nlp", ident) == null);
    // A letter that is not there at all.
    try T.expect(match("Println", "pz", ident) == null);
    // Longer than the haystack cannot be a subsequence of it.
    try T.expect(match("ab", "abc", ident) == null);
}

test "an empty needle matches everything, in the caller's order" {
    const m = match("anything", "", ident).?;
    try T.expectEqual(@as(i32, 0), m.score);
    try T.expectEqual(@as(usize, 0), m.n);
}

test "the positions are where the needle actually landed" {
    const m = match("Println", "pln", ident).?;
    try T.expectEqual(@as(usize, 3), m.n);
    // P at 0, l at 5, n at 6 — NOT a prefix, which is the whole point:
    // underlining `Pln` would be underlining something that is not there.
    try T.expectEqualSlices(u16, &.{ 0, 5, 6 }, m.pos[0..3]);
    try T.expect(m.hit(0));
    try T.expect(!m.hit(1));
    try T.expect(m.hit(6));
}

test "the DP finds the run a greedy scan would walk past" {
    // THE case this is a DP for. Greedy takes the `a` of `read`, and
    // then `ll` is scattered; the answer a reader expects is `All`,
    // contiguous and on a camelCase boundary.
    const m = match("readAll", "all", ident).?;
    try T.expectEqualSlices(u16, &.{ 4, 5, 6 }, m.pos[0..3]);
    // ...and the greedy walk really would have taken the other one, or
    // this test is pinning a difference that does not exist.
    const g = greedy("readAll", "all", ident).?;
    try T.expectEqual(@as(u16, 2), g.pos[0]);
    try T.expect(m.score > g.score);
}

test "a boundary beats the same letters buried mid-word" {
    // camelCase humps are what make an identifier searchable.
    try beats("fp", "fmt.Printf", "flapping", ident);
    try beats("rc", "readCloser", "reactor", ident);
    // A separator starts a word too.
    try beats("ab", "alpha_beta", "alphabet", ident);
}

test "a contiguous run beats a scattered one" {
    try beats("pri", "print", "parallelResearchIndex", ident);
    try beats("abc", "abc_thing", "a_b_c_thing", ident);
}

test "a match at the start beats one further in" {
    try beats("print", "printLine", "sprintLine", ident);
    try beats("get", "getUser", "widgetUser", ident);
}

test "case is a tiebreak, never more than one" {
    // Typing an upper P prefers the upper one...
    try beats("P", "Print", "print", ident);
    // ...but it must not outrank a word boundary: `p` typed lower still
    // finds `Println` ahead of a `p` buried in the middle of a word.
    try beats("p", "Println", "alpha", ident);
}

test "shorter wins a tie" {
    try beats("print", "print", "printerControllerFactory", ident);
}

test "the path profile still ranks the basename first" {
    // ⌘P's rule: you type `main` for main.zig, not for src/domain/x.zig.
    try beats("main", "main.zig", "src/domain/x.zig", path);
    try beats("main", "a/main.zig", "main/other/thing.zig", path);
    // Shorter paths win ties.
    try beats("xzig", "src/x.zig", "a/b/c/d/src/x.zig", path);
}

test "a needle longer than the bound still matches, via the greedy walk" {
    var hay: [max_hay + 64]u8 = undefined;
    @memset(&hay, 'x');
    hay[0] = 'a';
    hay[hay.len - 1] = 'b';
    const m = match(&hay, "ab", ident).?;
    try T.expectEqual(@as(usize, 2), m.n);
    try T.expectEqual(@as(u16, 0), m.pos[0]);
    try T.expectEqual(@as(u16, hay.len - 1), m.pos[1]);
    // And a miss in a long haystack is still a miss.
    try T.expect(match(&hay, "abz", ident) == null);
}

test "positions stay inside the reported count for a long needle" {
    var hay: [64]u8 = undefined;
    for (&hay, 0..) |*c, i| c.* = @intCast('a' + (i % 26));
    var needle: [max_pos + 8]u8 = undefined;
    for (&needle, 0..) |*c, i| c.* = @intCast('a' + (i % 26));
    if (match(&hay, &needle, ident)) |m| {
        try T.expect(m.n <= max_pos);
        for (m.pos[0..m.n]) |p| try T.expect(p < hay.len);
    }
}

test "positions are strictly ascending, always" {
    const cases = [_][2][]const u8{
        .{ "readAll", "all" },
        .{ "fmt.Fprintf", "fpr" },
        .{ "alpha_beta_gamma", "abg" },
        .{ "HTTPServerHandler", "sh" },
        .{ "aaaaaa", "aaa" },
    };
    for (cases) |c| {
        const m = match(c[0], c[1], ident) orelse return error.NoMatch;
        try T.expectEqual(c[1].len, m.n);
        for (1..m.n) |i| try T.expect(m.pos[i] > m.pos[i - 1]);
        // ...and each position really holds the character it claims.
        for (m.pos[0..m.n], 0..) |p, i| {
            try T.expectEqual(lower(c[1][i]), lower(c[0][p]));
        }
    }
}

test "matches agrees with match about what is a subsequence" {
    const cases = [_][2][]const u8{
        .{ "Println", "pln" },
        .{ "Println", "nlp" },
        .{ "readAll", "all" },
        .{ "readAll", "allx" },
        .{ "", "a" },
        .{ "abc", "" },
    };
    for (cases) |c| {
        try T.expectEqual(match(c[0], c[1], ident) != null, matches(c[0], c[1]));
    }
}
