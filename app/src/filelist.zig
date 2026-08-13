//! The file index behind ⌘P — a repo's files, walked on a worker and
//! cached between opens (the palette shows the last walk instantly
//! and the refresh swaps in a frame later).
//!
//! Not `git ls-files`: rook does not fork for this (git.zig's rule —
//! the branch segment reads .git/HEAD itself), and a fork per palette
//! open is a spinner on a cold FS cache. A plain walk with honest
//! skipping gets the same list for the case that matters, and it also
//! works in a directory that is not a repo at all.
//!
//! IGNORING is the whole problem. A walk that descends node_modules
//! is a walk that never finishes; one that only skips a hardcoded
//! list is wrong in every repo with an unusual build dir. So: the
//! built-in list covers what every project has, and .gitignore's
//! SIMPLE directory lines (`node_modules/`, `zig-out/`, no globs, no
//! negations) are read and honoured on top. Glob patterns are left
//! alone deliberately — a half-implemented glob that silently hides a
//! file you are looking for is worse than one that shows you extra.

const std = @import("std");

const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(d: *anyopaque) ?*Dirent;
extern "c" fn closedir(d: *anyopaque) c_int;
// libc directly, like the dirent calls above: this module walks a
// filesystem, and std.Io.Dir would need an io handle threaded through
// a walker whose whole job is one syscall per entry.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const dt_dir = 4;
const dt_reg = 8;
const dt_lnk = 10;

/// Directories every project has and nobody wants in a file picker.
/// `.git` is not here because ALL dotfiles are skipped below.
const always_skip = [_][]const u8{
    "node_modules",
    "zig-out",
    "zig-cache",
    "target",
    "dist",
    "build",
    "vendor",
    "__pycache__",
    "Pods",
    "DerivedData",
};

/// A cap, because a picker that hangs is worse than one that is
/// incomplete. 200k is chromium-sized — grafana is 22k, and the cap
/// that used to sit at 20k silently hid a fifth of it (the sorted
/// tail: the frontend). `truncated` says so out loud rather than
/// pretending.
pub const max_files = 200_000;

pub const Index = struct {
    /// Root-relative paths ("src/main.zig"), arena-owned.
    paths: [][]const u8 = &.{},
    /// The absolute root they hang off, arena-owned.
    root: []const u8 = "",
    truncated: bool = false,
    /// Every byte above lives here, so teardown is one free — and so
    /// building 20k paths costs the outer allocator a handful of chunk
    /// allocations rather than 20k small ones. That ratio is the whole
    /// story on an allocator that captures a stack trace per call,
    /// which is what the app's gpa does even at ReleaseFast.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        _ = gpa; // everything is in the arena; kept for call-site compat
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }
};

/// One .gitignore's worth of simple directory names. Anything with a
/// glob, a negation, or an interior slash is skipped — see the header.
pub const IgnoreSet = struct {
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The enclosing directory's rules, CHAINED rather than copied.
    /// The copy looked innocent and was the whole 17-second ⌘P open
    /// on grafana: a 197-line root .gitignore duplicated into each of
    /// 4,350 directories is half a million allocations, on an
    /// allocator that unwinds a stack trace for every one of them.
    parent: ?*const IgnoreSet = null,

    pub fn deinit(self: *IgnoreSet, gpa: std.mem.Allocator) void {
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
    }

    pub fn has(self: *const IgnoreSet, name: []const u8) bool {
        var cur: ?*const IgnoreSet = self;
        while (cur) |c| : (cur = c.parent) {
            for (c.names.items) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
        }
        return false;
    }
};

/// Parse .gitignore text into the directory names we can honour
/// honestly. Pure — this is the part with a unit test.
pub fn parseIgnore(gpa: std.mem.Allocator, text: []const u8) IgnoreSet {
    var set: IgnoreSet = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Negations reintroduce paths a broader rule removed; we never
        // applied the broader rule, so honouring the negation alone
        // would be meaningless.
        if (line[0] == '!') continue;
        // A leading slash anchors to the root, which for a top-level
        // name is what we do anyway.
        if (line[0] == '/') line = line[1..];
        if (line.len > 0 and line[line.len - 1] == '/') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        if (std.mem.indexOfAny(u8, line, "*?[]!/\\") != null) continue;
        const owned = gpa.dupe(u8, line) catch continue;
        set.names.append(gpa, owned) catch {
            gpa.free(owned);
            continue;
        };
    }
    return set;
}

fn readIgnore(gpa: std.mem.Allocator, root: []const u8) IgnoreSet {
    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/.gitignore\x00", .{root}) catch return .{};
    const fd = open(@ptrCast(path.ptr), 0); // O_RDONLY
    if (fd < 0) return .{};
    defer _ = close(fd);
    var buf: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return parseIgnore(gpa, buf[0..len]);
}

fn skipDir(name: []const u8, ignore: *const IgnoreSet) bool {
    // Dotfiles: .git, .zig-cache, .venv, .next — all of them, which is
    // also why .git needs no entry in always_skip.
    if (name.len > 0 and name[0] == '.') return true;
    for (always_skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return ignore.has(name);
}

const Walker = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
    truncated: bool = false,

    /// EVERY directory's .gitignore, not just the root's — which is
    /// how git itself reads them, and the difference between indexing
    /// a repo and indexing its dependency cache. rook's own tree is
    /// the proof: `zig-pkg/` is ignored by app/.gitignore, and reading
    /// only the root's put 26k vendored files in the picker (the whole
    /// 20k cap, with the actual source pushed out).
    ///
    /// Each directory's rules apply to ITS subtree, so the set is
    /// scoped by the recursion rather than accumulated globally.
    fn walk(self: *Walker, dir_abs: []const u8, rel: []const u8, depth: usize, inherited: *const IgnoreSet) void {
        // A repo deeper than this is a symlink loop or a build tree we
        // should not have descended.
        if (depth > 24 or self.truncated) return;
        var zbuf: [1024]u8 = undefined;
        if (dir_abs.len == 0 or dir_abs.len >= zbuf.len) return;
        @memcpy(zbuf[0..dir_abs.len], dir_abs);
        zbuf[dir_abs.len] = 0;
        const d = opendir(zbuf[0..dir_abs.len :0]) orelse return;
        defer _ = closedir(d);

        // This directory's own rules; the inherited ones stay in force
        // below it through the parent chain. No deinit — the walker's
        // allocator is the index's arena, and a set's names total a few
        // hundred bytes across a whole repo's .gitignores.
        var local = readIgnore(self.gpa, dir_abs);
        local.parent = inherited;

        while (readdir(d)) |de| {
            if (self.truncated) return;
            const name = de.d_name[0..de.d_namlen];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            // Symlinks are not followed: a link to an ancestor is a
            // loop, and a link out of the repo lists someone else's
            // files under your paths.
            if (de.d_type == dt_dir) {
                if (skipDir(name, &local)) continue;
                var sub_abs: [1024]u8 = undefined;
                var sub_rel: [1024]u8 = undefined;
                const a = std.fmt.bufPrint(&sub_abs, "{s}/{s}", .{ dir_abs, name }) catch continue;
                const r = if (rel.len == 0)
                    std.fmt.bufPrint(&sub_rel, "{s}", .{name}) catch continue
                else
                    std.fmt.bufPrint(&sub_rel, "{s}/{s}", .{ rel, name }) catch continue;
                self.walk(a, r, depth + 1, &local);
            } else if (de.d_type == dt_reg) {
                if (name.len > 0 and name[0] == '.') continue;
                if (self.out.items.len >= max_files) {
                    self.truncated = true;
                    return;
                }
                var pbuf: [1024]u8 = undefined;
                const p = if (rel.len == 0)
                    std.fmt.bufPrint(&pbuf, "{s}", .{name}) catch continue
                else
                    std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ rel, name }) catch continue;
                const owned = self.gpa.dupe(u8, p) catch continue;
                self.out.append(self.gpa, owned) catch {
                    self.gpa.free(owned);
                    continue;
                };
            }
        }
    }
};

/// Walk `root` and return its files SORTED BY PATH.
///
/// Sorted because readdir order is the filesystem's, which means it
/// differs between machines and between runs on the same machine —
/// and it reaches the user twice: as the tie-break in ⌘P's ranking,
/// and as the order find-in-files lists its hits. Search results that
/// come back in a different order on your colleague's laptop are
/// results neither of you can talk about.
///
/// `gpa` only backs the index's arena — the walk itself never asks it
/// for anything smaller than a chunk. grafana (22k files, 4.3k dirs):
/// ~150 ms, where the pre-arena walk under the app's trace-capturing
/// allocator took 17 s. Callers still should not hold draw_lock across
/// this; the app caches one index and refreshes it on a worker.
pub fn load(gpa: std.mem.Allocator, root: []const u8) Index {
    var idx: Index = .{};
    if (root.len == 0) return idx;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var w = Walker{ .gpa = arena, .root = root, .out = &out };
    const none: IgnoreSet = .{};
    w.walk(root, "", 0, &none);

    const S = struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };
    std.mem.sort([]const u8, out.items, {}, S.lt);
    idx.paths = out.toOwnedSlice(arena) catch &.{};
    idx.root = arena.dupe(u8, root) catch "";
    idx.truncated = w.truncated;
    // Moved by value AFTER the last allocation through it: the
    // interface above pointed at the stack copy, and from here on the
    // only caller is deinit, which reads the state it carries.
    idx.arena = arena_state;
    return idx;
}

// ---- tests ----

test "parseIgnore takes plain directory lines and refuses the rest" {
    const t = std.testing;
    var set = parseIgnore(t.allocator,
        \\# a comment
        \\node_modules
        \\zig-out/
        \\/target
        \\
        \\*.log
        \\!keep.log
        \\src/generated
        \\build
    );
    defer set.deinit(t.allocator);

    try t.expect(set.has("node_modules"));
    try t.expect(set.has("zig-out")); // trailing slash trimmed
    try t.expect(set.has("target")); // leading slash trimmed
    try t.expect(set.has("build"));
    // Globs, negations and nested paths are LEFT ALONE on purpose —
    // showing an extra file beats hiding one you went looking for.
    try t.expect(!set.has("*.log"));
    try t.expect(!set.has("keep.log"));
    try t.expect(!set.has("src/generated"));
    try t.expect(!set.has("# a comment"));
    try t.expectEqual(@as(usize, 4), set.names.items.len);
}

test "an ignore chain answers for every ancestor, and only reads, never copies" {
    const t = std.testing;
    var root_set = parseIgnore(t.allocator, "coverage\n");
    defer root_set.deinit(t.allocator);
    var mid = parseIgnore(t.allocator, "generated\n");
    defer mid.deinit(t.allocator);
    mid.parent = &root_set;
    var leaf: IgnoreSet = .{ .parent = &mid };

    // A leaf with no rules of its own still enforces every ancestor's.
    try t.expect(leaf.has("coverage"));
    try t.expect(leaf.has("generated"));
    try t.expect(!leaf.has("src"));
    // The chain is scoping, not accumulation: the root never sees a
    // child's rule.
    try t.expect(!root_set.has("generated"));
}

test "skipDir: dotfiles, the builtin list, and the repo's own additions" {
    const t = std.testing;
    var set = parseIgnore(t.allocator, "coverage\n");
    defer set.deinit(t.allocator);

    try t.expect(skipDir(".git", &set));
    try t.expect(skipDir(".zig-cache", &set));
    try t.expect(skipDir("node_modules", &set));
    try t.expect(skipDir("coverage", &set)); // from .gitignore
    try t.expect(!skipDir("src", &set));
    try t.expect(!skipDir("app", &set));
}
