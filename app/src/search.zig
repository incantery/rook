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

fn scanFile(
    gpa: std.mem.Allocator,
    abs: []const u8,
    rel: []const u8,
    query: []const u8,
    sensitive: bool,
    files: *std.ArrayListUnmanaged([]const u8),
    hits: *std.ArrayListUnmanaged(Hit),
) !bool {
    var zbuf: [1024]u8 = undefined;
    if (abs.len >= zbuf.len) return false;
    @memcpy(zbuf[0..abs.len], abs);
    zbuf[abs.len] = 0;
    const fd = open(zbuf[0..abs.len :0], 0);
    if (fd < 0) return false;
    defer _ = close(fd);

    var buf = gpa.alloc(u8, max_file_bytes) catch return false;
    defer gpa.free(buf);
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    const data = buf[0..len];
    if (looksBinary(data[0..@min(data.len, 8192)])) return false;

    var this_file: ?u32 = null;
    var lineno: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        lineno += 1;
        const at = find(line, query, sensitive) orelse continue;
        if (this_file == null) {
            if (files.items.len >= max_files_with_hits) return true;
            const owned = try gpa.dupe(u8, rel);
            errdefer gpa.free(owned);
            try files.append(gpa, owned);
            this_file = @intCast(files.items.len - 1);
        }
        const s = shownLine(line, at);
        const text = try gpa.dupe(u8, s.text);
        errdefer gpa.free(text);
        try hits.append(gpa, .{
            .file = this_file.?,
            .line = lineno,
            .col = @intCast(s.col),
            .text = text,
        });
        if (hits.items.len >= max_hits) return true;
    }
    return false;
}

/// Search `root` for `query`. Caller owns the result.
///
/// Runs on whatever thread calls it and takes no locks — the app runs
/// it OFF draw_lock and publishes the finished value, because a
/// repo-wide scan is milliseconds but not microseconds, and a frame
/// must never wait on a filesystem.
pub fn run(gpa: std.mem.Allocator, root: []const u8, query: []const u8) Results {
    var res: Results = .{};
    if (root.len == 0 or query.len == 0) return res;

    var idx = filelist.load(gpa, root);
    defer idx.deinit(gpa);

    const sensitive = caseSensitive(query);
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    for (idx.paths) |rel| {
        var abuf: [1024]u8 = undefined;
        const abs = std.fmt.bufPrint(&abuf, "{s}/{s}", .{ root, rel }) catch continue;
        res.scanned += 1;
        const full = scanFile(gpa, abs, rel, query, sensitive, &files, &hits) catch continue;
        if (full) {
            res.truncated = true;
            break;
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
