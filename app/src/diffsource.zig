//! Where a diff comes from — and the reason that is a named thing.
//!
//! A review needs two answers: which files changed, and what the two
//! sides of one file look like. Neither answer should carry any trace of
//! WHO decided what "changed" means. Uncommitted work against HEAD, a
//! branch against where it forked, later a single commit or a pull
//! request someone opened on a machine that is not this one — the pane
//! renders the same shape from all of them, and a finding anchored into
//! one is anchored the same way in every other.
//!
//! Today two sources exist, both git-local:
//!
//!   .head   — the working tree against HEAD. What you have not
//!             committed yet.
//!   .branch — the working tree against the merge-base with the base
//!             branch. The whole of a task's work, committed or not,
//!             which is what a worktree wants by default.
//!
//! The request is a STRING rather than an enum, matching the host's
//! `?base=` param, and that is the extension point: a commit-ish arm
//! reads `?base=<sha>` with no new vocabulary, and a source that is not
//! git at all resolves the same Base shape from somewhere else. Callers
//! pass the param through and read the resolved Base back out of the
//! answer — never assuming the source they asked for is the one they
//! got, because branch mode fails open to head and says why.
//!
//! Ported from internal/host/review.go: reviewBaseFor, resolveReviewBase,
//! statusWord, headChanges, branchChanges, capSide, and the two handlers
//! that assemble them. Not ported: the file/files/write endpoints that
//! share the same file, which the editor reaches by other means and
//! which a diff source has no business owning.
//!
//! The parse rules are pinned by testdata/diff_changes.txt, shared with
//! the Go implementation — see that file for why these particular loops
//! deserve it.

const std = @import("std");
const git = @import("git.zig");

/// Per-side content cap. The Go host's reviewMaxSide, kept because it is
/// a wire contract with clients that already exist, not because a Zig
/// renderer has Monaco's limits.
pub const max_side = 2 << 20;
/// A NUL anywhere in this prefix means binary — git's own sniff length.
pub const sniff_len = 8000;
/// Longest changes list we will report. Past this the pane says so
/// rather than pretending a 4000-file list is reviewable.
pub const max_files = 1000;

pub const Mode = enum {
    head,
    branch,

    /// The wire word, which is also the `?base=` param that asks for it.
    pub fn word(self: Mode) []const u8 {
        return switch (self) {
            .head => "head",
            .branch => "branch",
        };
    }
};

/// A resolved diff source: what git was actually asked to compare
/// against, and what to call it on screen.
///
/// Field strings are EITHER static literals or allocations from the
/// arena that produced them. Never free one individually — the arena
/// owns what needs owning, and that mixture is deliberate: the common
/// answer ("HEAD") allocates nothing.
pub const Base = struct {
    mode: Mode = .head,
    /// What git compares against: "HEAD", or a merge-base sha.
    ref: []const u8 = "HEAD",
    /// Display name: "HEAD", or the base branch.
    name: []const u8 = "HEAD",
    /// Set when branch mode was asked for and could not be resolved, so
    /// this is head mode standing in. The pane must be able to say
    /// "showing uncommitted changes because <reason>" — a silent
    /// downgrade looks like a source that lost your commits.
    fallback: []const u8 = "",
};

/// What to resolve, and the little the resolver needs to know about the
/// workspace to do it.
pub const Request = struct {
    /// The `?base=` param, verbatim. Empty means "you decide", which
    /// depends on whether this is a worktree.
    param: []const u8 = "",
    /// The SOURCE workspace's root, when this workspace is a worktree of
    /// another. Its CURRENT branch is the first base candidate — the
    /// registry's own Branch field is the worktree's branch, not the one
    /// it forked from, which is a mistake worth naming rather than
    /// rediscovering.
    ///
    /// Empty for a top-level workspace, and that emptiness is also what
    /// makes head the default there.
    parent_root: []const u8 = "",
};

pub const Status = enum {
    modified,
    added,
    deleted,
    renamed,
    untracked,

    pub fn word(self: Status) []const u8 {
        return switch (self) {
            .modified => "modified",
            .added => "added",
            .deleted => "deleted",
            .renamed => "renamed",
            .untracked => "untracked",
        };
    }

    /// For the remote arm, reading the host's JSON back. An unknown word
    /// is `modified` rather than an error: a host newer than this build
    /// may name a status we have never heard of, and a file we can still
    /// diff is a better answer than a dropped row.
    pub fn parse(s: []const u8) Status {
        inline for (.{ Status.added, .deleted, .renamed, .untracked }) |st| {
            if (std.mem.eql(u8, s, st.word())) return st;
        }
        return .modified;
    }
};

pub const File = struct {
    path: []const u8,
    status: Status,
    /// The pre-rename (or copied-from) path. Empty otherwise. The diff
    /// for such a file compares the OLD path's content in the base
    /// against the new path on disk.
    old_path: []const u8 = "",
};

/// A changes list and the memory behind it.
pub const Changes = struct {
    arena: std.heap.ArenaAllocator,
    base: Base = .{},
    files: []File = &.{},
    /// The list was cut at max_files.
    truncated: bool = false,

    pub fn deinit(self: *Changes) void {
        self.arena.deinit();
    }
};

/// Both texts of one file. Texts rather than a patch: the anchors are
/// line ranges into whole sides, and a renderer that wants a unified
/// view can compute one, where a renderer handed a patch cannot recover
/// what it does not contain.
pub const Sides = struct {
    arena: std.heap.ArenaAllocator,
    base: Base = .{},
    path: []const u8 = "",
    original: []const u8 = "",
    modified: []const u8 = "",
    /// Either side sniffed binary. Both texts are then empty — there is
    /// nothing useful to show and plenty to break.
    binary: bool = false,
    /// Either side was cut at max_side.
    truncated: bool = false,

    pub fn deinit(self: *Sides) void {
        self.arena.deinit();
    }
};

// ------------------------------------------------------------------ base

/// Turn a `?base=` param into a concrete Base.
///
/// No param: a worktree defaults to branch (the task's whole work),
/// everything else to head (uncommitted changes). An UNRECOGNISED param
/// is head, which is faithful to the Go host and is also where a
/// commit-ish arm will slot in — until then, `?base=abc123` quietly
/// means HEAD rather than that commit.
pub fn resolveBase(arena: std.mem.Allocator, io: std.Io, top: []const u8, req: Request) Base {
    const want_branch = if (req.param.len == 0)
        req.parent_root.len > 0
    else
        std.mem.eql(u8, req.param, Mode.branch.word());

    if (!want_branch) return .{};

    const r = resolveBranchBase(arena, io, top, req);
    // Branch mode that cannot find a base is head mode WITH A REASON,
    // never an error: a repo with no main, no origin and no common
    // ancestor still has uncommitted work worth reviewing.
    if (r.ref.len == 0) return .{ .fallback = r.fallback };
    return .{ .mode = .branch, .ref = r.ref, .name = r.name, .fallback = "" };
}

const BranchBase = struct {
    ref: []const u8 = "",
    name: []const u8 = "",
    fallback: []const u8 = "",
};

/// The merge-base of HEAD and the first candidate that exists.
///
/// Candidates, in order: the source workspace's current branch (for a
/// worktree), origin's default branch, then main, then master. First one
/// that both resolves to a commit AND shares an ancestor with HEAD wins.
fn resolveBranchBase(arena: std.mem.Allocator, io: std.Io, top: []const u8, req: Request) BranchBase {
    var cands: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cands.deinit(arena);

    if (req.parent_root.len > 0) {
        if (currentBranch(arena, io, req.parent_root)) |b| cands.append(arena, b) catch {};
    }
    if (git.run(arena, io, top, &.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, 4096)) |r| {
        if (r.code == 0) {
            const ref = std.mem.trim(u8, r.stdout, " \t\r\n");
            if (ref.len > 0) {
                if (arena.dupe(u8, ref)) |owned| cands.append(arena, owned) catch {} else |_| {}
            }
        }
    }
    cands.append(arena, "main") catch {};
    cands.append(arena, "master") catch {};

    var reason: []const u8 = "no base branch found";
    for (cands.items) |c| {
        var specbuf: [512]u8 = undefined;
        const spec = std.fmt.bufPrint(&specbuf, "{s}^{{commit}}", .{c}) catch continue;
        const exists = git.run(arena, io, top, &.{ "rev-parse", "--verify", "--quiet", spec }, 4096) orelse continue;
        if (exists.code != 0) continue;

        const mb = git.run(arena, io, top, &.{ "merge-base", "HEAD", c }, 4096) orelse continue;
        if (mb.code != 0) {
            // The branch exists but shares no history — a grafted repo,
            // or an orphan branch. Keep looking, and remember this as
            // the better explanation than "not found".
            reason = std.fmt.allocPrint(arena, "no common ancestor with {s}", .{c}) catch reason;
            continue;
        }
        const sha = std.mem.trim(u8, mb.stdout, " \t\r\n");
        if (sha.len == 0) continue;
        return .{
            .ref = arena.dupe(u8, sha) catch return .{ .fallback = "out of memory" },
            .name = c,
        };
    }
    return .{ .fallback = std.fmt.allocPrint(arena, "no merge base ({s})", .{reason}) catch "no merge base" };
}

/// The branch checked out in `dir`, or null when detached or not a repo.
fn currentBranch(arena: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]const u8 {
    const r = git.run(arena, io, dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" }, 4096) orelse return null;
    if (r.code != 0) return null;
    const b = std.mem.trim(u8, r.stdout, " \t\r\n");
    // Detached HEAD abbreviates to "HEAD", which is not a branch and
    // would make the merge-base with HEAD be HEAD — an empty diff.
    if (b.len == 0 or std.mem.eql(u8, b, "HEAD")) return null;
    return arena.dupe(u8, b) catch null;
}

// --------------------------------------------------------------- parsing

/// Fold a porcelain XY pair into one word.
///
/// Order is the content: the WORKTREE side wins a mixed verdict, so "AD"
/// — added, then deleted from disk — reads deleted. Testing A before D
/// would offer a diff of a file that is not there.
pub fn statusOf(x: u8, y: u8) Status {
    if (x == '?') return .untracked;
    if (x == 'R' or y == 'R') return .renamed;
    if (x == 'D' or y == 'D') return .deleted;
    if (x == 'A' or y == 'A') return .added;
    return .modified; // M, T, C, U, and mixed index/worktree edits
}

/// Split a NUL-separated listing into fields, keeping the trailing empty
/// one exactly as Go's strings.Split does — the walks below look ahead by
/// index and their bounds checks are written against that length.
fn fields(arena: std.mem.Allocator, raw: []const u8) []const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |f| out.append(arena, f) catch break;
    return out.toOwnedSlice(arena) catch &.{};
}

/// `git status --porcelain -z` — head mode's file list.
///
/// One record per path (the staged and unstaged states share the XY
/// pair), with a rename or copy followed by its origin path as its own
/// field.
pub fn parsePorcelain(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(File), raw: []const u8) void {
    const fs = fields(arena, raw);
    var i: usize = 0;
    while (i < fs.len) : (i += 1) {
        const f = fs[i];
        // "XY path" is four bytes at the very least. Shorter is a runt —
        // skipped, and the walk carries on rather than abandoning the
        // rest of the listing.
        if (f.len < 4) continue;
        var file: File = .{ .path = f[3..], .status = statusOf(f[0], f[1]) };
        if (f[0] == 'R' or f[0] == 'C') {
            i += 1;
            if (i < fs.len) file.old_path = fs[i];
        }
        out.append(arena, file) catch return;
    }
}

/// `git diff --name-status -z <ref>` — branch mode's committed and
/// uncommitted work against the base.
///
/// The status is its own field here, so a plain record is two fields and
/// a rename or copy is three. That rhythm change mid-listing is what the
/// index walk is really for.
pub fn parseNameStatus(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(File), raw: []const u8) void {
    const fs = fields(arena, raw);
    var i: usize = 0;
    while (i < fs.len) {
        const st = fs[i];
        if (st.len == 0) break;
        // The letter is a PREFIX — R and C carry a similarity score.
        if ((st[0] == 'R' or st[0] == 'C') and i + 2 < fs.len) {
            append(arena, out, fs[i + 2], .renamed, fs[i + 1]);
            i += 3;
            continue;
        }
        if (i + 1 >= fs.len) break;
        append(arena, out, fs[i + 1], switch (st[0]) {
            'A' => .added,
            'D' => .deleted,
            else => .modified,
        }, "");
        i += 2;
    }
}

/// `git ls-files --others --exclude-standard -z` — untracked files,
/// which are part of a task's whole work even before an add.
pub fn parseOthers(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(File), raw: []const u8) void {
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |f| append(arena, out, f, .untracked, "");
}

/// Append unless the path is empty.
///
/// A DELIBERATE divergence from the Go original, which appended a
/// path-less record for a truncated name-status tail. An empty path is
/// not a file: it renders as a blank row offering a diff that cannot be
/// opened, because the path is refused by confine() before it becomes a
/// read. Dropping it cannot lose information — the record named nothing.
/// The Go side skips it too now, so the shared fixture stays shared.
fn append(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(File), path: []const u8, status: Status, old_path: []const u8) void {
    if (path.len == 0) return;
    out.append(arena, .{ .path = path, .status = status, .old_path = old_path }) catch {};
}

// ----------------------------------------------------------------- reads

/// Which files this source considers changed.
///
/// An empty list and a failure are the same answer on purpose: a
/// non-repo, a missing git and a genuinely clean tree all mean "nothing
/// to review here", and the pane has one way to say that.
pub fn changes(gpa: std.mem.Allocator, io: std.Io, top: []const u8, req: Request) Changes {
    var c: Changes = .{ .arena = .init(gpa) };
    const arena = c.arena.allocator();
    c.base = resolveBase(arena, io, top, req);

    var list: std.ArrayListUnmanaged(File) = .empty;
    switch (c.base.mode) {
        .head => {
            if (git.run(arena, io, top, &.{ "status", "--porcelain", "-z" }, 8 << 20)) |r| {
                if (r.code == 0) parsePorcelain(arena, &list, r.stdout);
            }
        },
        .branch => {
            if (git.run(arena, io, top, &.{ "diff", "--name-status", "-z", c.base.ref }, 8 << 20)) |r| {
                if (r.code == 0) parseNameStatus(arena, &list, r.stdout);
            }
            if (git.run(arena, io, top, &.{ "ls-files", "--others", "--exclude-standard", "-z" }, 8 << 20)) |r| {
                if (r.code == 0) parseOthers(arena, &list, r.stdout);
            }
        },
    }

    c.files = list.toOwnedSlice(arena) catch &.{};
    if (c.files.len > max_files) {
        c.files = c.files[0..max_files];
        c.truncated = true;
    }
    return c;
}

/// Enforce the per-side content rules: a NUL in the sniff window means
/// binary and the content is withheld; anything past the cap truncates.
pub fn capSide(b: []const u8) struct { text: []const u8, binary: bool, truncated: bool } {
    const n = @min(b.len, sniff_len);
    if (std.mem.indexOfScalar(u8, b[0..n], 0) != null) return .{ .text = "", .binary = true, .truncated = false };
    if (b.len > max_side) return .{ .text = b[0..max_side], .binary = false, .truncated = true };
    return .{ .text = b, .binary = false, .truncated = false };
}

/// Both sides of one file.
///
/// A missing original means the file is new to this source; a missing
/// file on disk means it was deleted. Both are ordinary labelled states
/// rather than errors — an empty side IS the answer, and the status in
/// the changes list is what names which case it is.
pub fn sides(gpa: std.mem.Allocator, io: std.Io, top: []const u8, rel: []const u8, req: Request) Sides {
    var s: Sides = .{ .arena = .init(gpa) };
    const arena = s.arena.allocator();
    s.base = resolveBase(arena, io, top, req);
    s.path = arena.dupe(u8, rel) catch "";

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = git.confine(&pathbuf, top, rel) orelse return s;

    var orig: []const u8 = "";
    var specbuf: [std.fs.max_path_bytes + 64]u8 = undefined;
    if (std.fmt.bufPrint(&specbuf, "{s}:{s}", .{ s.base.ref, rel })) |spec| {
        if (git.run(arena, io, top, &.{ "show", spec }, max_side + 1)) |r| {
            if (r.code == 0) orig = r.stdout;
        }
    } else |_| {}

    const mod: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_side + 1)) catch "";

    const o = capSide(orig);
    const m = capSide(mod);
    s.original = o.text;
    s.modified = m.text;
    s.binary = o.binary or m.binary;
    s.truncated = o.truncated or m.truncated;
    // One binary side withholds BOTH: half a diff of a binary file is
    // not a diff, and the renderer would be showing text next to a gap.
    if (s.binary) {
        s.original = "";
        s.modified = "";
    }
    return s;
}

// ---------------------------------------------------------------------
// Tests. The parse rules run off the shared fixture; base resolution and
// the two reads drive real git, because what git calls a change is
// exactly what a fake would get wrong.
// ---------------------------------------------------------------------

const testing = std.testing;

const fixtures = @embedFile("testdata/diff_changes.txt");

/// Expand the fixture's two escapes. Kept tiny and shared by input and
/// want, so a mistake here fails every row rather than skewing one.
fn unescape(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "EMPTY")) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '0' => {
                    out.append(arena, 0) catch {};
                    i += 2;
                    continue;
                },
                's' => {
                    out.append(arena, ' ') catch {};
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        out.append(arena, s[i]) catch {};
        i += 1;
    }
    return out.toOwnedSlice(arena) catch "";
}

/// Render a parse result in the fixture's `want` spelling, so a failure
/// prints the two sides in the same language.
fn render(arena: std.mem.Allocator, files: []const File) []const u8 {
    if (files.len == 0) return "EMPTY";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (files, 0..) |f, i| {
        if (i > 0) out.append(arena, ',') catch {};
        out.appendSlice(arena, f.status.word()) catch {};
        out.append(arena, ':') catch {};
        for (f.path) |c| {
            if (c == ' ') out.appendSlice(arena, "\\s") catch {} else out.append(arena, c) catch {};
        }
        if (f.old_path.len > 0) {
            out.appendSlice(arena, "<-") catch {};
            for (f.old_path) |c| {
                if (c == ' ') out.appendSlice(arena, "\\s") catch {} else out.append(arena, c) catch {};
            }
        }
    }
    return out.toOwnedSlice(arena) catch "";
}

test "the shared changed-file fixtures" {
    var buf: [1 << 20]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const arena = fba.allocator();

    var declared: i64 = -1;
    var seen: i64 = 0;
    var lines = std.mem.splitScalar(u8, fixtures, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const marker = "# cases:";
            if (std.mem.startsWith(u8, line, marker)) {
                declared = std.fmt.parseInt(i64, std.mem.trim(u8, line[marker.len..], " \t"), 10) catch -1;
            }
            continue;
        }

        var it = std.mem.splitScalar(u8, line, '|');
        const name = std.mem.trim(u8, it.next() orelse continue, " \t");
        const parser = std.mem.trim(u8, it.next() orelse continue, " \t");
        const input = unescape(arena, std.mem.trim(u8, it.next() orelse continue, " \t"));
        const want = std.mem.trim(u8, it.next() orelse continue, " \t");

        var list: std.ArrayListUnmanaged(File) = .empty;
        if (std.mem.eql(u8, parser, "porcelain")) {
            parsePorcelain(arena, &list, input);
        } else if (std.mem.eql(u8, parser, "namestatus")) {
            parseNameStatus(arena, &list, input);
        } else if (std.mem.eql(u8, parser, "others")) {
            parseOthers(arena, &list, input);
        } else {
            std.debug.print("unknown parser {s} in case {s}\n", .{ parser, name });
            return error.UnknownParser;
        }

        const got = render(arena, list.items);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("case '{s}': want {s}, got {s}\n", .{ name, want, got });
            return error.FixtureMismatch;
        }
        seen += 1;
    }

    // The guard that keeps this from passing vacuously: a fixture file
    // that failed to load, or a row a format change made unparseable,
    // would otherwise be a green run over zero cases.
    try testing.expect(declared > 0);
    try testing.expectEqual(declared, seen);
}

// ------------------------------------------------------- git-driven tests

const Repo = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    dirbuf: [std.fs.max_path_bytes]u8 = undefined,

    fn deinit(self: *Repo) void {
        self.tmp.cleanup();
    }

    fn git_(self: *Repo, args: []const []const u8) !void {
        const r = git.run(testing.allocator, testing.io, self.dir, args, 1 << 20) orelse return error.SkipZigTest;
        defer r.deinit(testing.allocator);
        if (r.code != 0) return error.GitFailed;
    }

    fn write(self: *Repo, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn commit(self: *Repo, msg: []const u8) !void {
        try self.git_(&.{ "add", "-A" });
        try self.git_(&.{ "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", msg });
    }

    fn find(c: *const Changes, path: []const u8) ?File {
        for (c.files) |f| if (std.mem.eql(u8, f.path, path)) return f;
        return null;
    }
};

fn repo() !*Repo {
    const r = try testing.allocator.create(Repo);
    r.* = .{ .tmp = testing.tmpDir(.{}), .dir = undefined };
    r.dir = try std.fmt.bufPrint(&r.dirbuf, ".zig-cache/tmp/{s}", .{r.tmp.sub_path});
    // -b so the default branch is deterministic; a machine with
    // init.defaultBranch=master would otherwise resolve a different base
    // and quietly test something else.
    r.git_(&.{ "init", "-q", "-b", "main" }) catch |e| {
        r.deinit();
        testing.allocator.destroy(r);
        return e;
    };
    return r;
}

fn destroy(r: *Repo) void {
    r.deinit();
    testing.allocator.destroy(r);
}

test "head mode is the working tree against HEAD" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("kept.txt", "one\n");
    try r.write("edited.txt", "before\n");
    try r.write("removed.txt", "bye\n");
    try r.commit("base");

    try r.write("edited.txt", "after\n");
    try r.write("fresh.txt", "new\n");
    try r.tmp.dir.deleteFile(testing.io, "removed.txt");

    var c = changes(testing.allocator, testing.io, r.dir, .{});
    defer c.deinit();

    try testing.expectEqual(Mode.head, c.base.mode);
    try testing.expectEqualStrings("HEAD", c.base.ref);
    try testing.expectEqual(@as(usize, 3), c.files.len);
    try testing.expectEqual(Status.modified, Repo.find(&c, "edited.txt").?.status);
    try testing.expectEqual(Status.untracked, Repo.find(&c, "fresh.txt").?.status);
    try testing.expectEqual(Status.deleted, Repo.find(&c, "removed.txt").?.status);
    // The unchanged file is absent, not present-and-unmodified: this is
    // a CHANGES list, and a pane that had to filter it would be reading
    // the whole tree on every poll.
    try testing.expectEqual(@as(?File, null), Repo.find(&c, "kept.txt"));
}

test "branch mode reaches back past the commits on this branch" {
    // The property that makes the two sources genuinely different rather
    // than two spellings of one: work COMMITTED on the branch is
    // invisible to head mode and is exactly what branch mode is for.
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("base.txt", "one\n");
    try r.commit("base");
    try r.git_(&.{ "checkout", "-q", "-b", "work" });
    try r.write("committed.txt", "done\n");
    try r.commit("work in progress");
    try r.write("dirty.txt", "not yet\n");

    var head = changes(testing.allocator, testing.io, r.dir, .{ .param = "head" });
    defer head.deinit();
    try testing.expectEqual(@as(usize, 1), head.files.len);
    try testing.expectEqualStrings("dirty.txt", head.files[0].path);

    var branch = changes(testing.allocator, testing.io, r.dir, .{ .param = "branch" });
    defer branch.deinit();
    try testing.expectEqual(Mode.branch, branch.base.mode);
    try testing.expectEqualStrings("main", branch.base.name);
    try testing.expectEqualStrings("", branch.base.fallback);
    // 40-char merge-base sha, not the literal "HEAD".
    try testing.expectEqual(@as(usize, 40), branch.base.ref.len);
    // The committed file AND the untracked one: the task's whole work.
    try testing.expectEqual(Status.added, Repo.find(&branch, "committed.txt").?.status);
    try testing.expectEqual(Status.untracked, Repo.find(&branch, "dirty.txt").?.status);
}

test "branch mode with no base fails open to head, and says why" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("a.txt", "one\n");
    try r.commit("base");
    // Rename the only branch away from every candidate, so nothing
    // resolves: no origin, no main, no master.
    try r.git_(&.{ "branch", "-m", "elsewhere" });

    var c = changes(testing.allocator, testing.io, r.dir, .{ .param = "branch" });
    defer c.deinit();
    try testing.expectEqual(Mode.head, c.base.mode);
    try testing.expectEqualStrings("HEAD", c.base.ref);
    // The reason is the point. A silent downgrade to head mode looks
    // like a source that lost your commits.
    try testing.expect(c.base.fallback.len > 0);
    try testing.expect(std.mem.indexOf(u8, c.base.fallback, "no merge base") != null);
}

test "an empty param picks branch for a worktree and head otherwise" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("a.txt", "one\n");
    try r.commit("base");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // No parent root: a top-level workspace reviews what it has not
    // committed.
    try testing.expectEqual(Mode.head, resolveBase(arena.allocator(), testing.io, r.dir, .{}).mode);

    // A parent root makes this a worktree, and a worktree's default is
    // its whole task. The parent here is the same repo, whose current
    // branch is main.
    const wt = resolveBase(arena.allocator(), testing.io, r.dir, .{ .parent_root = r.dir });
    try testing.expectEqual(Mode.branch, wt.mode);
    try testing.expectEqualStrings("main", wt.name);
}

test "sides serves both texts, and an absent side is a state not an error" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("f.txt", "one\ntwo\n");
    try r.write("gone.txt", "bye\n");
    try r.commit("base");
    try r.write("f.txt", "one\nTWO\nthree\n");
    try r.tmp.dir.deleteFile(testing.io, "gone.txt");
    try r.write("fresh.txt", "brand new\n");

    var s = sides(testing.allocator, testing.io, r.dir, "f.txt", .{});
    defer s.deinit();
    try testing.expectEqualStrings("one\ntwo\n", s.original);
    try testing.expectEqualStrings("one\nTWO\nthree\n", s.modified);
    try testing.expect(!s.binary and !s.truncated);

    // Deleted: an original and nothing on disk.
    var del = sides(testing.allocator, testing.io, r.dir, "gone.txt", .{});
    defer del.deinit();
    try testing.expectEqualStrings("bye\n", del.original);
    try testing.expectEqualStrings("", del.modified);

    // Added: nothing in the base, content on disk.
    var add = sides(testing.allocator, testing.io, r.dir, "fresh.txt", .{});
    defer add.deinit();
    try testing.expectEqualStrings("", add.original);
    try testing.expectEqualStrings("brand new\n", add.modified);
}

test "a binary side withholds both, and a path that escapes is refused" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    try r.write("b.bin", "text\x00binary\n");
    try r.commit("base");
    try r.write("b.bin", "text\x00changed\n");

    var s = sides(testing.allocator, testing.io, r.dir, "b.bin", .{});
    defer s.deinit();
    try testing.expect(s.binary);
    try testing.expectEqualStrings("", s.original);
    try testing.expectEqualStrings("", s.modified);

    // Refused before it becomes a read — the same guard the anchors use.
    var esc = sides(testing.allocator, testing.io, r.dir, "../../../etc/passwd", .{});
    defer esc.deinit();
    try testing.expectEqualStrings("", esc.original);
    try testing.expectEqualStrings("", esc.modified);
}

test "a renamed file carries the path its content came from" {
    const r = repo() catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer destroy(r);
    // Rename detection needs enough content to score a similarity.
    try r.write("old.txt", "alpha\nbeta\ngamma\ndelta\nepsilon\n");
    try r.commit("base");
    try r.git_(&.{ "mv", "old.txt", "new.txt" });

    var c = changes(testing.allocator, testing.io, r.dir, .{});
    defer c.deinit();
    const f = Repo.find(&c, "new.txt").?;
    try testing.expectEqual(Status.renamed, f.status);
    // Without this, the diff for new.txt compares against a path that
    // does not exist in the base and the whole file reads as added.
    try testing.expectEqualStrings("old.txt", f.old_path);
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

test "not a repo is an empty list, not a failure" {
    // NOT testing.tmpDir: that lands in .zig-cache, which is inside
    // rook's own checkout, so `git -C` there walks UP and reports rook's
    // working tree. The first draft of this test asserted zero files and
    // found three — this file, its fixture, and build.zig — which is the
    // same trap the re-anchoring fixtures hit from the other direction.
    // A test for "not in a repo" has to be somewhere genuinely outside
    // one.
    const base = if (getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    var rnd: [8]u8 = undefined;
    testing.io.random(&rnd);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dirbuf, "{s}/rook-diffsource-{x}", .{ base, std.mem.readInt(u64, &rnd, .little) });

    const cwd = std.Io.Dir.cwd();
    var d = try cwd.createDirPathOpen(testing.io, dir, .{});
    d.close(testing.io);
    defer cwd.deleteTree(testing.io, dir) catch {};

    // Guard the guard: if TMPDIR ever sits inside a repo, this test
    // would go back to measuring that repo instead of nothing.
    if (git.repoTop(testing.allocator, testing.io, dir)) |top| {
        testing.allocator.free(top);
        return error.SkipZigTest;
    }

    var c = changes(testing.allocator, testing.io, dir, .{});
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.files.len);
    try testing.expectEqual(Mode.head, c.base.mode);
}

test "capSide's caps" {
    try testing.expect(capSide("plain text\n").binary == false);
    try testing.expect(capSide("has a \x00 in it").binary);
    // A NUL past the sniff window is NOT binary: git's rule, and the
    // reason a huge text file with one stray byte deep inside still
    // renders.
    var late = [_]u8{'a'} ** (sniff_len + 10);
    late[sniff_len + 5] = 0;
    try testing.expect(!capSide(&late).binary);

    const big = [_]u8{'x'} ** (max_side + 100);
    const r = capSide(&big);
    try testing.expect(r.truncated);
    try testing.expectEqual(@as(usize, max_side), r.text.len);
}
