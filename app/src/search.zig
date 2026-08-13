//! Find in files — the search behind ⌘⇧F.
//!
//! The candidate list is filelist.zig's, so search inherits the file
//! finder's ignore rules for free: what ⌘P can open is what ⌘⇧F can
//! search, and neither can surprise the other by disagreeing about
//! node_modules.
//!
//! LITERAL, smart-case, by default — which is what a search box means
//! in every editor a switcher is arriving from. rook has a real regex
//! engine (regex.zig, the editor's `/` and `:s`), and a regex toggle
//! belongs here eventually; shipping literal first means the common
//! case is exact and fast rather than surprising (`main()` searched as
//! a pattern finds nothing, which reads as "search is broken").
//!
//! Results are GROUPED BY FILE because that is how they are read: a
//! flat list of 200 hits is a list you scroll, the same failure the
//! file finder's ranking exists to avoid.

const std = @import("std");
const filelist = @import("filelist.zig");
// For the UTF-16 → byte column conversion only. lsp.zig is a leaf that
// imports nothing but std, and a second copy of that conversion is
// exactly the kind of subtlety that drifts.
const lsp = @import("lsp.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

/// Files bigger than this are data, not source — a minified bundle or
/// a checked-in dump, and grepping it costs more than its hits are
/// worth.
pub const max_file_bytes = 2 * 1024 * 1024;
/// Enough hits to answer "where is this", far past enough to read.
pub const max_hits = 2000;
pub const max_files_with_hits = 400;
/// A matched line is shown, not stored whole: a 4KB minified line
/// would be a 4KB row.
pub const max_line_shown = 200;

pub const Hit = struct {
    /// Index into Results.files.
    file: u32,
    /// 1-based, the number a jump takes and a gutter shows.
    line: u32,
    /// Byte column of the match within the (possibly clipped) text.
    col: u32,
    /// Byte column of the match in the FILE's line — what a JUMP needs.
    ///
    /// It differs from `col` by exactly the indentation that was trimmed
    /// off for display, and the difference is the whole reason both
    /// exist: `col` points into `text` and is where a highlight goes,
    /// while a cursor placed at `col` in the real buffer would land in
    /// the middle of the indent of a deeply nested hit.
    file_col: u32,
    /// The matched line, trimmed of leading blanks and clipped.
    text: []const u8,
};

pub const Results = struct {
    /// Root-relative paths that had at least one hit, owned.
    files: [][]const u8 = &.{},
    hits: []Hit = &.{},
    /// The absolute root the paths hang off, owned.
    root: []const u8 = "",
    /// The query these answer, owned — so a panel can title itself
    /// with what it actually searched rather than what is in the box.
    query: []const u8 = "",
    truncated: bool = false,
    /// Files that were opened and scanned (not the index size) — the
    /// number that says "0 hits" means "looked and found nothing".
    scanned: usize = 0,

    pub fn deinit(self: *Results, gpa: std.mem.Allocator) void {
        for (self.files) |f| gpa.free(f);
        gpa.free(self.files);
        for (self.hits) |hh| gpa.free(hh.text);
        gpa.free(self.hits);
        if (self.root.len > 0) gpa.free(self.root);
        if (self.query.len > 0) gpa.free(self.query);
        self.* = .{};
    }
};

/// Vim's smartcase, which every switcher already has in their fingers:
/// an all-lowercase query is case-insensitive, one with any capital is
/// exact. It means you never reach for a toggle to do the obvious.
pub fn caseSensitive(query: []const u8) bool {
    for (query) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

/// First byte offset of `needle` in `hay`, honouring smart-case.
pub fn find(hay: []const u8, needle: []const u8, sensitive: bool) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    if (sensitive) return std.mem.indexOf(u8, hay, needle);
    var i: usize = 0;
    outer: while (i + needle.len <= hay.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(nc)) continue :outer;
        }
        return i;
    }
    return null;
}

/// A NUL in the head means binary: the same probe grep uses, and the
/// reason a search never dumps a PNG's bytes into the results.
pub fn looksBinary(head: []const u8) bool {
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

/// Leading blanks off, then clip — a deeply indented hit should show
/// its code, not its indentation, and the column follows the trim.
fn shownLine(line: []const u8, col: usize) struct { text: []const u8, col: usize } {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    if (start > col) start = col;
    var text = line[start..];
    if (text.len > max_line_shown) text = text[0..max_line_shown];
    return .{ .text = text, .col = col - start };
}

/// One worker's share of a scan. Paths and hit text land in the
/// worker's arena; the merge copies the survivors out to the caller's
/// allocator, so nothing here needs a free.
const WorkerOut = struct {
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    hits: std.ArrayListUnmanaged(Hit) = .empty,
    scanned: usize = 0,
    truncated: bool = false,
};

/// Scan one file whose bytes are already in `data`, appending to
/// `out`. Returns true when the worker's caps are full and the range
/// should stop.
///
/// The search is ONE indexOf pass over the whole buffer — line
/// boundaries and numbers are computed only for actual hits, because
/// almost every file has none and iterating its lines to learn that
/// was most of a 30-second grafana scan. For a smart-case query the
/// haystack was lowered by the caller; offsets in it are offsets in
/// `data`, which is what hits quote.
fn scanData(
    arena: std.mem.Allocator,
    rel: []const u8,
    data: []const u8,
    hay: []const u8,
    query: []const u8,
    out: *WorkerOut,
) bool {
    var this_file: ?u32 = null;
    var pos: usize = 0;
    // Line numbers are counted incrementally between hits, never from
    // the top — a file with 300 hits still counts each newline once.
    var counted: usize = 0;
    var lineno: u32 = 1;
    while (std.mem.indexOfPos(u8, hay, pos, query)) |at| {
        const ls = if (std.mem.lastIndexOfScalar(u8, hay[0..at], '\n')) |p| p + 1 else 0;
        const le = std.mem.indexOfScalarPos(u8, hay, at, '\n') orelse hay.len;
        lineno += @intCast(std.mem.count(u8, hay[counted..ls], "\n"));
        counted = ls;
        if (this_file == null) {
            if (out.files.items.len >= max_files_with_hits) {
                out.truncated = true;
                return true;
            }
            const owned = arena.dupe(u8, rel) catch return true;
            out.files.append(arena, owned) catch return true;
            this_file = @intCast(out.files.items.len - 1);
        }
        const line = data[ls..le];
        const s = shownLine(line, at - ls);
        const text = arena.dupe(u8, s.text) catch return true;
        out.hits.append(arena, .{
            .file = this_file.?,
            .line = lineno,
            .col = @intCast(s.col),
            .file_col = @intCast(at - ls),
            .text = text,
        }) catch return true;
        if (out.hits.items.len >= max_hits) {
            out.truncated = true;
            return true;
        }
        // One hit per line, the panel's grain — on to the next line.
        if (le >= hay.len) break;
        pos = le + 1;
    }
    return false;
}

/// Read and scan every path in `range`. Runs on a worker thread; the
/// only shared state is `out`, which the caller reads after join.
///
/// The 2MB file buffer is allocated ONCE per worker — its predecessor
/// allocated and freed one per FILE, which on 21k files was 21k
/// two-megabyte round trips through an allocator that records a stack
/// trace for each. That, not the filesystem, was the old 30 seconds.
fn scanRange(
    arena_ptr: *std.heap.ArenaAllocator,
    root: []const u8,
    range: []const []const u8,
    query: []const u8,
    sensitive: bool,
    out: *WorkerOut,
) void {
    const arena = arena_ptr.allocator();
    const buf = arena.alloc(u8, max_file_bytes) catch return;
    // The lowered haystack for smart-case, beside the raw bytes: lower
    // once per file, then take the same SIMD indexOf the sensitive
    // path gets. Smart-case means an insensitive query has no
    // uppercase, so the query itself needs no work.
    const low: []u8 = if (!sensitive)
        arena.alloc(u8, max_file_bytes) catch return
    else
        buf[0..0];

    for (range) |rel| {
        var zbuf: [1024]u8 = undefined;
        var abuf: [2048]u8 = undefined;
        const abs = std.fmt.bufPrint(&abuf, "{s}/{s}", .{ root, rel }) catch continue;
        if (abs.len >= zbuf.len) continue;
        @memcpy(zbuf[0..abs.len], abs);
        zbuf[abs.len] = 0;
        const fd = open(zbuf[0..abs.len :0], 0);
        if (fd < 0) continue;
        defer _ = close(fd);
        var len: usize = 0;
        while (len < buf.len) {
            const n = read(fd, buf[len..].ptr, buf.len - len);
            if (n <= 0) break;
            len += @intCast(n);
        }
        const data = buf[0..len];
        out.scanned += 1;
        if (looksBinary(data[0..@min(data.len, 8192)])) continue;
        const hay: []const u8 = if (sensitive) data else blk: {
            for (data, 0..) |c, i| low[i] = std.ascii.toLower(c);
            break :blk low[0..len];
        };
        if (scanData(arena, rel, data, hay, query, out)) return;
    }
}

// ------------------------------------------------- a list somebody else made

/// One place to show, named from outside. A language server's answer
/// arrives as positions with no text attached, and the panel shows text
/// — so somebody has to open the file, and it may as well be the module
/// that already knows how to read one and how to clip a line.
///
/// Coordinates are the PROTOCOL's: 0-based line, UTF-16 column. They are
/// converted here because the conversion needs the line, and the line is
/// what this function goes and gets.
pub const Mark = struct {
    /// Absolute.
    path: []const u8,
    line: u32 = 0,
    col: u32 = 0,
};

fn markLess(_: void, a: Mark, b: Mark) bool {
    const c = std.mem.order(u8, a.path, b.path);
    if (c != .eq) return c == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// Turn marks into the same Results the panel gets from a grep, reading
/// each distinct file once. `label` is what the panel calls the list —
/// the symbol, not a query, since nothing here was searched for.
///
/// `marks` is SORTED IN PLACE: grouping by file is what makes this one
/// read per file rather than one per hit, and the panel groups by file
/// anyway. Caller keeps ownership of the marks and their paths.
///
/// Same threading rule as run(): no locks, no frame — it opens files.
pub fn atMarks(gpa: std.mem.Allocator, root: []const u8, label: []const u8, marks: []Mark) Results {
    var res: Results = .{};
    std.mem.sort(Mark, marks, {}, markLess);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    var i: usize = 0;
    while (i < marks.len) {
        // One file's run of marks.
        var j = i + 1;
        while (j < marks.len and std.mem.eql(u8, marks[j].path, marks[i].path)) j += 1;
        defer i = j;
        if (files.items.len >= max_files_with_hits or hits.items.len >= max_hits) {
            res.truncated = true;
            break;
        }

        // A reference can land OUTSIDE the workspace — the standard
        // library, a module cache, a vendored dependency. Showing the
        // absolute path is the honest answer there; trimming it to a
        // relative one would produce a path that resolves to nothing.
        const rel = relativeTo(root, marks[i].path);
        const owned = gpa.dupe(u8, rel) catch break;
        files.append(gpa, owned) catch {
            gpa.free(owned);
            break;
        };
        const file_idx: u32 = @intCast(files.items.len - 1);
        res.scanned += 1;

        const data = readWhole(gpa, marks[i].path);
        defer if (data) |d| gpa.free(d);

        for (marks[i..j]) |m| {
            if (hits.items.len >= max_hits) {
                res.truncated = true;
                break;
            }
            // A file we could not read still shows its locations: the
            // reference is real whether or not we can quote it, and a
            // silently shorter list is the worse failure.
            const raw = if (data) |d| lineAt(d, m.line) else "";
            const byte_col = lsp.byteColFromUtf16(raw, m.col);
            const s = shownLine(raw, byte_col);
            const text = gpa.dupe(u8, s.text) catch break;
            hits.append(gpa, .{
                .file = file_idx,
                .line = m.line + 1,
                .col = @intCast(s.col),
                .file_col = @intCast(byte_col),
                .text = text,
            }) catch {
                gpa.free(text);
                break;
            };
        }
    }

    res.files = files.toOwnedSlice(gpa) catch &.{};
    res.hits = hits.toOwnedSlice(gpa) catch &.{};
    res.root = gpa.dupe(u8, root) catch "";
    res.query = gpa.dupe(u8, label) catch "";
    return res;
}

/// `abs` shown against `root`: root-relative when it is inside, and the
/// absolute path untouched when it is not. The leading `/` is what the
/// panel and its jump both read to tell the two apart.
fn relativeTo(root: []const u8, abs: []const u8) []const u8 {
    if (root.len == 0 or abs.len <= root.len) return abs;
    if (!std.mem.startsWith(u8, abs, root)) return abs;
    if (abs[root.len] != '/') return abs;
    return abs[root.len + 1 ..];
}

/// Line `n` (0-based) of `data`, without its newline; "" past the end.
fn lineAt(data: []const u8, n: u32) []const u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    var i: u32 = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == n) return std.mem.trimEnd(u8, line, "\r");
    }
    return "";
}

/// The whole file, capped, or null. Same read path scanFile uses.
fn readWhole(gpa: std.mem.Allocator, abs: []const u8) ?[]u8 {
    var zbuf: [1024]u8 = undefined;
    if (abs.len >= zbuf.len) return null;
    @memcpy(zbuf[0..abs.len], abs);
    zbuf[abs.len] = 0;
    const fd = open(zbuf[0..abs.len :0], 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var buf = gpa.alloc(u8, max_file_bytes) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    if (looksBinary(buf[0..@min(len, 8192)])) {
        gpa.free(buf);
        return null;
    }
    return gpa.realloc(buf, len) catch buf[0..len];
}

/// How many workers a scan fans out to. Eight is plenty to saturate
/// an SSD from a warm page cache, and small enough that a background
/// search never noticeably competes with the app for cores.
const max_workers = 8;

/// Search `root` for `query`. Caller owns the result.
///
/// Runs on whatever thread calls it and takes no locks of the app's —
/// it spawns its own workers over contiguous ranges of the (sorted)
/// index and joins them all before returning, so the caller still
/// sees one blocking call and one finished value. Ranges keep the
/// merge deterministic: results come back in path order, the same
/// order on every machine, which the panel and the audit both rely
/// on. grafana (21k files): ~30s before workers and the per-worker
/// buffer, well under a second after.
pub fn run(gpa: std.mem.Allocator, root: []const u8, query: []const u8) Results {
    var res: Results = .{};
    if (root.len == 0 or query.len == 0) return res;

    var idx = filelist.load(gpa, root);
    defer idx.deinit(gpa);
    const sensitive = caseSensitive(query);

    // Small repos don't earn thread spawns; ~512 files per worker is
    // where the ramp starts paying for itself.
    const nw: usize = @max(1, @min(max_workers, (idx.paths.len + 511) / 512));
    var arenas: [max_workers]std.heap.ArenaAllocator = undefined;
    var outs: [max_workers]WorkerOut = undefined;
    var threads: [max_workers]?std.Thread = @splat(null);
    const chunk = (idx.paths.len + nw - 1) / nw;
    for (0..nw) |i| {
        arenas[i] = std.heap.ArenaAllocator.init(gpa);
        outs[i] = .{};
        const a = @min(i * chunk, idx.paths.len);
        const b = @min(a + chunk, idx.paths.len);
        const range = idx.paths[a..b];
        if (range.len == 0) continue;
        threads[i] = std.Thread.spawn(.{}, scanRange, .{
            &arenas[i], root, range, query, sensitive, &outs[i],
        }) catch blk: {
            // No thread is a smaller problem than no answer: scan the
            // range right here.
            scanRange(&arenas[i], root, range, query, sensitive, &outs[i]);
            break :blk null;
        };
    }
    for (threads[0..nw]) |t| if (t) |th| th.join();
    defer for (arenas[0..nw]) |*a| a.deinit();

    // Totals first, in full: a merge that stops early must not make
    // "scanned" lie about work the workers actually did.
    for (outs[0..nw]) |*out| {
        res.scanned += out.scanned;
        if (out.truncated) res.truncated = true;
    }

    // Merge in worker order = path order. Workers capped locally; the
    // global caps are enforced again here, so a flood in an early
    // range still leaves the panel a readable list.
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    merge: for (outs[0..nw]) |*out| {
        var remap: [max_files_with_hits]u32 = undefined;
        var mapped: [max_files_with_hits]bool = @splat(false);
        for (out.hits.items) |h| {
            if (hits.items.len >= max_hits) {
                res.truncated = true;
                break :merge;
            }
            if (!mapped[h.file]) {
                if (files.items.len >= max_files_with_hits) {
                    res.truncated = true;
                    break :merge;
                }
                const owned = gpa.dupe(u8, out.files.items[h.file]) catch break :merge;
                files.append(gpa, owned) catch {
                    gpa.free(owned);
                    break :merge;
                };
                remap[h.file] = @intCast(files.items.len - 1);
                mapped[h.file] = true;
            }
            const text = gpa.dupe(u8, h.text) catch break :merge;
            hits.append(gpa, .{
                .file = remap[h.file],
                .line = h.line,
                .col = h.col,
                .file_col = h.file_col,
                .text = text,
            }) catch {
                gpa.free(text);
                break :merge;
            };
        }
    }

    res.files = files.toOwnedSlice(gpa) catch &.{};
    res.hits = hits.toOwnedSlice(gpa) catch &.{};
    res.root = gpa.dupe(u8, root) catch "";
    res.query = gpa.dupe(u8, query) catch "";
    if (idx.truncated) res.truncated = true;
    return res;
}

// ---- tests ----

test "smartcase: lowercase is loose, any capital is exact" {
    const t = std.testing;
    try t.expect(!caseSensitive("todo"));
    try t.expect(caseSensitive("TODO"));
    try t.expect(caseSensitive("Todo"));
    // Punctuation and digits do not make a query "typed with intent".
    try t.expect(!caseSensitive("foo_bar(1)"));
}

test "find honours the case mode it is given" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 4), find("say HELLO there", "hello", false));
    try t.expect(find("say HELLO there", "hello", true) == null);
    try t.expectEqual(@as(?usize, 4), find("say hello there", "hello", true));
    // Empty needle matches nothing rather than everything — an empty
    // search box must not report every line in the repo.
    try t.expect(find("anything", "", false) == null);
    try t.expect(find("short", "longer than hay", false) == null);
}

test "looksBinary catches a NUL and passes plain text" {
    const t = std.testing;
    try t.expect(looksBinary(&[_]u8{ 'P', 'N', 'G', 0, 1 }));
    try t.expect(!looksBinary("const x = 1;\nconst y = 2;\n"));
}

test "shownLine trims indentation and moves the column with it" {
    const t = std.testing;
    const line = "        const answer = 42;";
    const s = shownLine(line, 14); // "answer" starts at 14
    try t.expectEqualStrings("const answer = 42;", s.text);
    // 14 in the original is 6 in the trimmed text — still "answer".
    try t.expectEqual(@as(usize, 6), s.col);
    try t.expectEqualStrings("answer", s.text[s.col..][0..6]);
}

test "shownLine never clips past the match it is showing" {
    const t = std.testing;
    var long: [max_line_shown + 50]u8 = @splat('x');
    const s = shownLine(&long, 3);
    try t.expectEqual(@as(usize, max_line_shown), s.text.len);
    try t.expectEqual(@as(usize, 3), s.col);
}

test "relativeTo shows the workspace path inside, the whole path outside" {
    const t = std.testing;
    try t.expectEqualStrings("src/a.go", relativeTo("/w", "/w/src/a.go"));
    // Outside the root the absolute path is the only one that resolves.
    try t.expectEqualStrings("/usr/lib/go/fmt.go", relativeTo("/w", "/usr/lib/go/fmt.go"));
    // A sibling whose name merely STARTS with the root is not inside it.
    try t.expectEqualStrings("/workspace/a.go", relativeTo("/w", "/workspace/a.go"));
    try t.expectEqualStrings("/w/a.go", relativeTo("", "/w/a.go"));
}

test "lineAt counts from zero and runs off the end quietly" {
    const t = std.testing;
    const data = "one\ntwo\r\nthree\n";
    try t.expectEqualStrings("one", lineAt(data, 0));
    // The \r goes with the newline, or every hit on a CRLF file would
    // show a stray control byte at the end of its text.
    try t.expectEqualStrings("two", lineAt(data, 1));
    try t.expectEqualStrings("three", lineAt(data, 2));
    try t.expectEqualStrings("", lineAt(data, 9));
}

test "atMarks reads each file once and keeps what it cannot read" {
    const t = std.testing;
    const gpa = t.allocator;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var a_buf: [160]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a.txt", .{root});
    var b_buf: [160]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b.txt", .{root});
    try cwd.writeFile(io, .{ .sub_path = a, .data = "alpha\nbeta ref\ngamma ref\n" });
    // The é is two bytes and ONE utf-16 unit, so a column passed
    // through unconverted lands one byte early — which is the whole
    // reason this conversion happens where the line is.
    try cwd.writeFile(io, .{ .sub_path = b, .data = "  héllo ref\n" });

    var marks = [_]Mark{
        // Deliberately out of order, and with the two a.txt marks split
        // apart: grouping is what makes this one read per file.
        .{ .path = b, .line = 0, .col = 8 },
        .{ .path = a, .line = 2, .col = 6 },
        .{ .path = "/nonexistent/gone.txt", .line = 4, .col = 0 },
        .{ .path = a, .line = 1, .col = 5 },
    };
    var res = atMarks(gpa, root, "ref", &marks);
    defer res.deinit(gpa);

    try t.expectEqualStrings("ref", res.query);
    try t.expectEqual(@as(usize, 3), res.files.len);
    try t.expectEqual(@as(usize, 4), res.hits.len);

    // Sorted by path, so a.txt's two hits are adjacent and in line order.
    try t.expectEqualStrings("a.txt", res.files[res.hits[0].file]);
    try t.expectEqual(@as(u32, 2), res.hits[0].line); // 0-based 1 → shown 2
    try t.expectEqualStrings("beta ref", res.hits[0].text);
    try t.expectEqual(@as(u32, 5), res.hits[0].col);
    // Nothing was trimmed off this line, so the two agree.
    try t.expectEqual(@as(u32, 5), res.hits[0].file_col);
    try t.expectEqual(res.hits[0].file, res.hits[1].file);
    try t.expectEqual(@as(u32, 3), res.hits[1].line);

    // b.txt: indentation trimmed, and the column converted THEN moved.
    const bh = res.hits[2];
    try t.expectEqualStrings("b.txt", res.files[bh.file]);
    try t.expectEqualStrings("héllo ref", bh.text);
    try t.expectEqual(@as(u32, 7), bh.col);
    try t.expectEqualStrings("ref", bh.text[bh.col..][0..3]);
    // Two spaces of indent were trimmed for display; a cursor placed at
    // 7 in the real line would land inside "héllo".
    try t.expectEqual(@as(u32, 9), bh.file_col);

    // The file we could not open is still a location you can see.
    const gone = res.hits[3];
    try t.expectEqualStrings("/nonexistent/gone.txt", res.files[gone.file]);
    try t.expectEqual(@as(u32, 5), gone.line);
    try t.expectEqualStrings("", gone.text);
}
