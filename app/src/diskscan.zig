//! Where the disk went, and which of it is safe to take back — the DISK
//! half of the monitor.
//!
//! ## The axis that matters is regenerable, not big
//!
//! Sorting by size and offering a delete button is the obvious design
//! and the wrong one. On a working agent box the biggest directories are
//! a mix of things that rebuild in thirty seconds and things that are
//! the only copy in existence, and size does not tell them apart:
//! `node_modules` and a folder of agent transcripts look identical to a
//! sorter. So every entry carries a `Reclaim` class, the view groups by
//! it before size, and the classes that cannot be regenerated are never
//! offered a delete at all — see `Reclaim.keep`.
//!
//! The classifier is deliberately CONSERVATIVE about what it calls
//! regenerable. `node_modules`, `.zig-cache` and `DerivedData` are
//! unambiguously tool output. `build`, `dist` and `out` are not — plenty
//! of projects keep hand-written files in them — so they stay `unknown`
//! and get reported without an opinion. A classifier that is wrong in
//! the safe direction costs you a manual `rm`; wrong in the other
//! direction it costs you work you cannot get back.
//!
//! ## Measuring
//!
//! Four things a naive `du` reimplementation gets wrong, all of which
//! matter on APFS:
//!
//! - **Blocks, not apparent size.** `st_size` on a sparse or cloned file
//!   is a claim about the address space, not about the disk. Sizes here
//!   are `st_blocks * 512`; `apparent` is kept beside it so the gap is
//!   visible rather than silently picked.
//! - **Hardlinks counted once.** A `node_modules` full of pnpm links, or
//!   a Time Machine local snapshot, otherwise inflates a total by
//!   multiples. Files with `nlink > 1` are deduped by `(dev, ino)`.
//! - **Never cross a device.** `/Volumes`, network mounts and firmlinked
//!   system volumes turn a home-directory scan into a scan of everything
//!   mounted. The root's `st_dev` is the fence.
//! - **Never follow a symlink.** Both because it double-counts and
//!   because a link pointing at an ancestor is an infinite walk.
//!
//! ## Not finishing is a normal outcome
//!
//! A real home directory is minutes of walking — `du` over four cache
//! dirs measured 17s warm. So the walk is cancellable at every entry, it
//! publishes progress as it goes, and it records the directories the OS
//! refused (`~/Library` needs Full Disk Access for parts of itself).
//! A total that silently omits what it could not read is the same
//! dishonesty as a CPU column that hides unattributable work.

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

const dt_dir = 4;
const dt_lnk = 10;

const s_ifmt: u16 = 0o170000;
const s_ifdir: u16 = 0o040000;
const s_ifreg: u16 = 0o100000;

// ---------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------

/// What it costs to get this back. The ONLY question the monitor is
/// really asking, and the reason it is not just a size sorter.
pub const Reclaim = enum {
    /// Tool output. Deleting it costs a rebuild and nothing else.
    regenerable,
    /// A cache of something fetched. Deleting it costs bandwidth and
    /// time, which on a metered or offline machine is not nothing.
    refetchable,
    /// Data. History, downloads, VM images, anything a human made or
    /// an agent recorded. NEVER offered a delete — the monitor's job
    /// here is to say "this is where your disk went" and stop.
    keep,
    /// No opinion. Reported with its size and left alone.
    unknown,

    /// Whether the UI may offer to remove this at all. The gate lives
    /// on the class rather than at the call site so that adding a
    /// category cannot accidentally add a delete button.
    pub fn deletable(self: Reclaim) bool {
        return self == .regenerable or self == .refetchable;
    }
};

pub const Category = struct {
    /// Stable id, and what `ctl disk` prints.
    id: []const u8,
    /// One line for the human: what this is and what losing it costs.
    note: []const u8,
    reclaim: Reclaim,
    /// Matched against a directory's basename at any depth.
    by_name: []const u8 = "",
    /// Matched against the tail of the absolute path. For caches that
    /// only mean what they mean in one location — `mod` is nothing,
    /// `go/pkg/mod` is seventeen gigabytes.
    by_path: []const u8 = "",
    /// The tool's own cleanup command, where one exists. Preferred over
    /// unlinking: `go clean -modcache` handles the read-only permission
    /// bits the module cache sets, which a plain recursive delete trips
    /// over halfway through and leaves in pieces.
    tool: []const u8 = "",
};

/// Order matters: the first match wins, so path-specific entries come
/// before the generic name ones.
pub const categories = [_]Category{
    // --- data. listed FIRST so nothing below can claim it -----------
    .{
        .id = "agent-transcripts",
        .by_path = ".claude/projects",
        .reclaim = .keep,
        .note = "agent conversation history — the only copy, and not regenerable",
    },
    .{
        .id = "agent-shell-snapshots",
        .by_path = ".claude/shell-snapshots",
        .reclaim = .regenerable,
        .note = "recreated on the next agent launch",
    },
    .{
        .id = "downloads",
        .by_path = "Downloads",
        .reclaim = .keep,
        .note = "yours — the monitor will not guess what is disposable here",
    },
    .{
        .id = "vm-images",
        .by_name = "Parallels",
        .reclaim = .keep,
        .note = "virtual machine disks — deleting one discards its contents",
    },
    .{
        .id = "git",
        .by_name = ".git",
        .reclaim = .keep,
        .note = "repository history; shrink with `git gc`, never by deleting",
    },

    // --- language / package caches ----------------------------------
    .{
        .id = "go-modcache",
        .by_path = "go/pkg/mod",
        .reclaim = .refetchable,
        .tool = "go clean -modcache",
        .note = "downloaded Go modules; re-fetched on the next build",
    },
    .{
        .id = "go-build-cache",
        .by_path = "Library/Caches/go-build",
        .reclaim = .regenerable,
        .tool = "go clean -cache",
        .note = "Go build cache; rebuilds, slower the first time after",
    },
    .{
        .id = "cargo-registry",
        .by_path = ".cargo/registry",
        .reclaim = .refetchable,
        .note = "downloaded crates; re-fetched on the next build",
    },
    .{
        .id = "npm-cache",
        .by_path = ".npm/_cacache",
        .reclaim = .refetchable,
        .tool = "npm cache clean --force",
        .note = "npm package cache; re-downloaded on demand",
    },
    .{
        .id = "pnpm-store",
        .by_path = "Library/pnpm/store",
        .reclaim = .refetchable,
        .tool = "pnpm store prune",
        .note = "pnpm content-addressed store; prune drops only unreferenced packages",
    },
    .{
        .id = "homebrew-cache",
        .by_path = "Library/Caches/Homebrew",
        .reclaim = .refetchable,
        .tool = "brew cleanup --prune=all",
        .note = "downloaded bottles; re-fetched if needed",
    },
    .{
        .id = "playwright-browsers",
        .by_path = "Library/Caches/ms-playwright",
        .reclaim = .refetchable,
        .note = "headless browser builds; re-downloaded by `playwright install`",
    },
    .{
        .id = "uv-cache",
        .by_path = ".cache/uv",
        .reclaim = .refetchable,
        .tool = "uv cache clean",
        .note = "Python package cache; re-fetched on demand",
    },

    // --- Xcode / Docker ---------------------------------------------
    .{
        .id = "xcode-derived",
        .by_name = "DerivedData",
        .reclaim = .regenerable,
        .note = "Xcode build intermediates; rebuilt on the next build",
    },
    .{
        .id = "xcode-device-support",
        .by_path = "Xcode/iOS DeviceSupport",
        .reclaim = .refetchable,
        .note = "per-iOS-version symbols; re-copied when a device reconnects",
    },
    .{
        .id = "xcode-archives",
        .by_path = "Xcode/Archives",
        .reclaim = .keep,
        .note = "shipped build archives — needed to symbolicate old crashes",
    },
    .{
        .id = "docker",
        .by_path = "com.docker.docker/Data",
        .reclaim = .refetchable,
        .tool = "docker system prune -a",
        .note = "images, layers and volumes; prune is safer than deleting the disk image",
    },

    // --- unambiguous build output -----------------------------------
    .{
        .id = "node-modules",
        .by_name = "node_modules",
        .reclaim = .regenerable,
        .note = "reinstalled by npm/pnpm/yarn install",
    },
    .{
        .id = "zig-cache",
        .by_name = ".zig-cache",
        .reclaim = .regenerable,
        .note = "Zig build cache; rebuilds",
    },
    .{
        .id = "zig-out",
        .by_name = "zig-out",
        .reclaim = .regenerable,
        .note = "Zig build output; rebuilds",
    },
    .{
        .id = "python-bytecode",
        .by_name = "__pycache__",
        .reclaim = .regenerable,
        .note = "compiled Python bytecode; regenerated on import",
    },
    .{
        .id = "python-venv",
        .by_name = ".venv",
        .reclaim = .regenerable,
        .note = "virtualenv; recreated from the project's lockfile",
    },
    .{
        .id = "rust-target",
        .by_name = "target",
        .reclaim = .regenerable,
        .note = "Cargo build output; rebuilds",
    },
    // NOTE: `build`, `dist`, `out` are deliberately absent. They are
    // build output often enough to be tempting and hand-authored often
    // enough to make a delete button dangerous. They report as unknown.
};

/// Classify by path. `home` lets the path-tail rules be written relative
/// to a home directory without hardcoding a username.
pub fn classify(abs_path: []const u8, is_dir: bool) ?*const Category {
    if (!is_dir) return null;
    const base = std.fs.path.basename(abs_path);
    for (&categories) |*c| {
        if (c.by_path.len > 0) {
            // Tail match on a path BOUNDARY, so "go/pkg/mod" cannot be
            // claimed by ".../cargo/pkg/mod" and, more importantly, so
            // "Downloads" never matches "MyDownloads".
            if (std.mem.endsWith(u8, abs_path, c.by_path)) {
                const at = abs_path.len - c.by_path.len;
                if (at == 0 or abs_path[at - 1] == '/') return c;
            }
        }
        if (c.by_name.len > 0 and std.mem.eql(u8, base, c.by_name)) return c;
    }
    return null;
}

// ---------------------------------------------------------------------
// The tree
// ---------------------------------------------------------------------

pub const Node = struct {
    /// Basename, owned by the Scan's arena.
    name: []const u8,
    /// Absolute path, owned. Needed by reclaim (which must operate on a
    /// path it did not reconstruct) and by drill-in.
    path: []const u8,
    /// On-disk bytes, this node and everything under it — INCLUDING
    /// subtrees too deep to have their own node.
    bytes: u64 = 0,
    /// `st_size` sum, for the same subtree. Differs from `bytes` on
    /// sparse files and APFS clones; shown when the gap is large,
    /// because "600GB apparent, 40GB real" is a fact worth seeing.
    apparent: u64 = 0,
    files: u32 = 0,
    depth: u16 = 0,
    is_dir: bool = true,
    /// Null when nothing claimed it.
    cat: ?*const Category = null,
    /// Directories the OS refused, under here.
    denied: u32 = 0,
    children: std.ArrayListUnmanaged(u32) = .empty,

    pub fn reclaim(self: *const Node) Reclaim {
        return if (self.cat) |c| c.reclaim else .unknown;
    }
};

pub const Progress = struct {
    dirs: std.atomic.Value(u64) = .init(0),
    files: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    denied: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    /// Set by the owner to abandon the walk. Checked at every entry, so
    /// a cancel lands in microseconds rather than at the end of a
    /// directory the size of a package cache.
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const Scan = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// Nodes deeper than this are summed into their ancestor but get no
    /// entry of their own. A complete total with a bounded tree; drill-in
    /// rescans from a deeper root.
    max_depth: u16 = 3,
    root_dev: i32 = 0,
    /// (dev, ino) of every multiply-linked file already counted.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    truncated: bool = false,

    pub fn init(gpa: std.mem.Allocator) Scan {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Scan, gpa: std.mem.Allocator) void {
        for (self.nodes.items) |*n| n.children.deinit(gpa);
        self.nodes.deinit(gpa);
        self.seen.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn root(self: *const Scan) ?*const Node {
        return if (self.nodes.items.len == 0) null else &self.nodes.items[0];
    }
};

/// A cap on the tree, not on the walk: sizes stay complete past it, only
/// the per-directory detail stops. Without one, a scan of a home
/// directory with a hundred thousand shallow dirs allocates unboundedly
/// to describe rows nobody will ever scroll to.
pub const max_nodes = 200_000;

/// Walk `path`, cancellably, into `scan`.
///
/// Returns when the tree is complete or `prog.cancel` was set. Runs on a
/// worker — see the header for how long a real home directory takes.
pub fn walk(
    gpa: std.mem.Allocator,
    scan: *Scan,
    path: []const u8,
    prog: *Progress,
) !void {
    var st: std.c.Stat = undefined;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const zpath = try std.fmt.bufPrintZ(&pbuf, "{s}", .{path});
    if (std.c.fstatat(std.c.AT.FDCWD, zpath, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0)
        return error.StatFailed;
    if (st.mode & s_ifmt != s_ifdir) return error.NotADirectory;

    scan.root_dev = st.dev;
    const arena = scan.arena.allocator();
    try scan.nodes.append(gpa, .{
        .name = try arena.dupe(u8, std.fs.path.basename(path)),
        .path = try arena.dupe(u8, path),
        .depth = 0,
        .cat = classify(path, true),
    });

    _ = try walkInto(gpa, scan, 0, prog);
    prog.done.store(true, .release);
}

/// Recurse into `scan.nodes[idx]`, returning what it totals.
fn walkInto(gpa: std.mem.Allocator, scan: *Scan, idx: u32, prog: *Progress) !void {
    if (prog.cancel.load(.acquire)) return;

    const arena = scan.arena.allocator();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = scan.nodes.items[idx].path;
    const zdir = std.fmt.bufPrintZ(&pbuf, "{s}", .{dir_path}) catch return;

    const d = opendir(zdir) orelse {
        // Permission denied is the common case here and is NOT an error
        // to abort on: ~/Library has subtrees that need Full Disk
        // Access. Count it and keep going, so the total can say how
        // much of itself it could not see.
        scan.nodes.items[idx].denied += 1;
        _ = prog.denied.fetchAdd(1, .monotonic);
        return;
    };
    defer _ = closedir(d);

    const dfd = std.c.open(zdir, .{ .DIRECTORY = true, .ACCMODE = .RDONLY });
    if (dfd < 0) return;
    defer _ = std.c.close(dfd);

    var bytes: u64 = 0;
    var apparent: u64 = 0;
    var files: u32 = 0;
    var denied: u32 = 0;

    while (readdir(d)) |ent| {
        if (prog.cancel.load(.acquire)) break;

        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // A symlink is a pointer, not storage. Following one both
        // double-counts its target and, if it points at an ancestor,
        // never returns.
        if (ent.d_type == dt_lnk) continue;

        var nbuf: [1024]u8 = undefined;
        const zname = std.fmt.bufPrintZ(&nbuf, "{s}", .{name}) catch continue;
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(dfd, zname, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
            denied += 1;
            _ = prog.denied.fetchAdd(1, .monotonic);
            continue;
        }
        // The device fence. Without it a home scan wanders into every
        // mounted volume and firmlinked system path.
        if (st.dev != scan.root_dev) continue;

        const is_dir = st.mode & s_ifmt == s_ifdir;
        const on_disk: u64 = @as(u64, @intCast(@max(0, st.blocks))) * 512;

        if (!is_dir) {
            if (st.mode & s_ifmt != s_ifreg) continue;
            // Hardlinked file: count the first sighting only. pnpm
            // stores and Time Machine snapshots otherwise multiply a
            // total by however many links exist.
            if (st.nlink > 1) {
                const key = (@as(u64, @bitCast(@as(i64, st.dev))) << 40) ^ @as(u64, st.ino);
                const g = try scan.seen.getOrPut(gpa, key);
                if (g.found_existing) continue;
            }
            bytes += on_disk;
            apparent += @intCast(@max(0, st.size));
            files += 1;
            _ = prog.files.fetchAdd(1, .monotonic);
            _ = prog.bytes.fetchAdd(on_disk, .monotonic);
            continue;
        }

        _ = prog.dirs.fetchAdd(1, .monotonic);
        const child_depth = scan.nodes.items[idx].depth + 1;
        const child_path = std.fs.path.join(arena, &.{ dir_path, name }) catch continue;

        // Past max_depth the subtree still gets WALKED — the total has
        // to be right — it just does not get a node. This is what keeps
        // "how big is ~/Library" honest while the tree stays scrollable.
        if (child_depth > scan.max_depth or scan.nodes.items.len >= max_nodes) {
            if (scan.nodes.items.len >= max_nodes) scan.truncated = true;
            const t = sizeOnly(gpa, scan, child_path, prog);
            bytes += t.bytes;
            apparent += t.apparent;
            files += t.files;
            denied += t.denied;
            continue;
        }

        const child_idx: u32 = @intCast(scan.nodes.items.len);
        try scan.nodes.append(gpa, .{
            .name = try arena.dupe(u8, name),
            .path = child_path,
            .depth = child_depth,
            .cat = classify(child_path, true),
        });
        try scan.nodes.items[idx].children.append(gpa, child_idx);

        try walkInto(gpa, scan, child_idx, prog);

        const c = &scan.nodes.items[child_idx];
        bytes += c.bytes;
        apparent += c.apparent;
        files += c.files;
        denied += c.denied;
    }

    const me = &scan.nodes.items[idx];
    me.bytes += bytes;
    me.apparent += apparent;
    me.files += files;
    me.denied += denied;
}

const Totals = struct { bytes: u64 = 0, apparent: u64 = 0, files: u32 = 0, denied: u32 = 0 };

/// Total a subtree without recording any of it.
///
/// What happens past `max_depth`: the bytes still have to be right — a
/// "~/Library is 4GB" that stopped counting at depth three would be the
/// feature's worst possible failure — but nothing down there is ever
/// drawn, so nothing down there needs a node. Shares the caller's
/// hardlink set, because a file linked from both sides of the depth
/// boundary must still be counted once.
fn sizeOnly(gpa: std.mem.Allocator, scan: *Scan, path: []const u8, prog: *Progress) Totals {
    var out: Totals = .{};
    if (prog.cancel.load(.acquire)) return out;

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const zdir = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return out;
    const d = opendir(zdir) orelse {
        out.denied = 1;
        _ = prog.denied.fetchAdd(1, .monotonic);
        return out;
    };
    defer _ = closedir(d);

    const dfd = std.c.open(zdir, .{ .DIRECTORY = true, .ACCMODE = .RDONLY });
    if (dfd < 0) return out;
    defer _ = std.c.close(dfd);

    while (readdir(d)) |ent| {
        if (prog.cancel.load(.acquire)) break;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (ent.d_type == dt_lnk) continue;

        var nbuf: [1024]u8 = undefined;
        const zname = std.fmt.bufPrintZ(&nbuf, "{s}", .{name}) catch continue;
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(dfd, zname, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
            out.denied += 1;
            _ = prog.denied.fetchAdd(1, .monotonic);
            continue;
        }
        if (st.dev != scan.root_dev) continue;

        if (st.mode & s_ifmt == s_ifdir) {
            _ = prog.dirs.fetchAdd(1, .monotonic);
            var jbuf: [std.fs.max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrint(&jbuf, "{s}/{s}", .{ path, name }) catch continue;
            const t = sizeOnly(gpa, scan, child, prog);
            out.bytes += t.bytes;
            out.apparent += t.apparent;
            out.files += t.files;
            out.denied += t.denied;
            continue;
        }
        if (st.mode & s_ifmt != s_ifreg) continue;
        if (st.nlink > 1) {
            const key = (@as(u64, @bitCast(@as(i64, st.dev))) << 40) ^ @as(u64, st.ino);
            const g = scan.seen.getOrPut(gpa, key) catch continue;
            if (g.found_existing) continue;
        }
        const on_disk: u64 = @as(u64, @intCast(@max(0, st.blocks))) * 512;
        out.bytes += on_disk;
        out.apparent += @intCast(@max(0, st.size));
        out.files += 1;
        _ = prog.files.fetchAdd(1, .monotonic);
        _ = prog.bytes.fetchAdd(on_disk, .monotonic);
    }
    return out;
}

/// Children of `idx`, biggest first. Sorting on demand rather than at
/// build time because the sort key is a view concern and the tree is
/// built once but drawn many times.
pub fn sortChildren(scan: *Scan, idx: u32) void {
    const kids = scan.nodes.items[idx].children.items;
    const C = struct {
        s: *Scan,
        fn lt(self: @This(), a: u32, b: u32) bool {
            return self.s.nodes.items[a].bytes > self.s.nodes.items[b].bytes;
        }
    };
    std.mem.sort(u32, kids, C{ .s = scan }, C.lt);
}

/// Total on-disk bytes per reclaim class, over the whole tree.
///
/// The headline the DISK view opens with, and the only summary that
/// answers the actual question: not "how full is the disk" — `df` says
/// that — but "how much of this could I get back, and at what cost".
pub fn reclaimable(scan: *const Scan) [4]u64 {
    var out: [4]u64 = @splat(0);
    if (scan.nodes.items.len == 0) return out;
    // Descend from the root and STOP at the first classified node on
    // each branch. A node's bytes already include its descendants, so
    // adding a nested category underneath one that already claimed it
    // counts the same bytes twice — which on a real tree (a
    // `node_modules` inside a project inside a classified cache) turns
    // "reclaimable" into a number larger than the disk.
    var stack: [64]u32 = undefined;
    var top: usize = 1;
    stack[0] = 0;
    while (top > 0) {
        top -= 1;
        const n = &scan.nodes.items[stack[top]];
        if (n.cat) |c| {
            out[@intFromEnum(c.reclaim)] += n.bytes;
            continue;
        }
        for (n.children.items) |ci| {
            if (top >= stack.len) break;
            stack[top] = ci;
            top += 1;
        }
    }
    return out;
}

// ---------------------------------------------------------------------
// Free space
// ---------------------------------------------------------------------

const StatFs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};
extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;

pub const Volume = struct {
    total: u64 = 0,
    /// What a non-root process may actually use. Not `f_bfree` — the
    /// difference is the reserve, and reporting the larger number is
    /// how a monitor tells you there is space right up until the write
    /// fails.
    avail: u64 = 0,
};

pub fn volumeFor(path: []const u8) ?Volume {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    var fs: StatFs = undefined;
    if (statfs(z, &fs) != 0) return null;
    return .{
        .total = fs.f_blocks * fs.f_bsize,
        .avail = fs.f_bavail * fs.f_bsize,
    };
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "classify is conservative about ambiguous build dirs" {
    // Unambiguous tool output.
    try testing.expectEqualStrings("node-modules", classify("/a/b/node_modules", true).?.id);
    try testing.expectEqual(Reclaim.regenerable, classify("/a/b/node_modules", true).?.reclaim);
    try testing.expectEqualStrings("zig-cache", classify("/w/.zig-cache", true).?.id);

    // `build`, `dist`, `out` must stay unclassified: they are
    // hand-authored often enough that a delete button on them is a
    // data-loss bug waiting for the right repo.
    try testing.expectEqual(@as(?*const Category, null), classify("/a/build", true));
    try testing.expectEqual(@as(?*const Category, null), classify("/a/dist", true));
    try testing.expectEqual(@as(?*const Category, null), classify("/a/out", true));

    // Files are never classified — categories describe directories.
    try testing.expectEqual(@as(?*const Category, null), classify("/a/node_modules", false));
}

test "agent transcripts are keep, and nothing may offer to delete them" {
    const c = classify("/Users/x/.claude/projects", true).?;
    try testing.expectEqualStrings("agent-transcripts", c.id);
    try testing.expectEqual(Reclaim.keep, c.reclaim);
    try testing.expect(!c.reclaim.deletable());

    // The shell snapshots beside them ARE regenerable — the point of
    // the path rules is that two dirs one level apart differ totally.
    const s = classify("/Users/x/.claude/shell-snapshots", true).?;
    try testing.expect(s.reclaim.deletable());
}

test "path rules match on a boundary, not a substring" {
    // The bug this pins: `endsWith` alone lets "MyDownloads" be
    // classified as the user's Downloads folder and marked keep, or
    // worse, lets a lookalike inherit a deletable class.
    try testing.expectEqualStrings("downloads", classify("/Users/x/Downloads", true).?.id);
    try testing.expectEqual(@as(?*const Category, null), classify("/Users/x/MyDownloads", true));
    try testing.expectEqualStrings("go-modcache", classify("/Users/x/go/pkg/mod", true).?.id);
    try testing.expectEqual(@as(?*const Category, null), classify("/Users/x/nogo/pkg/mod", true));
}

test "keep classes are never deletable, and every category has a note" {
    for (&categories) |*c| {
        try testing.expect(c.note.len > 0);
        try testing.expect(c.id.len > 0);
        // Exactly one matcher, or the ordering guarantee is meaningless.
        try testing.expect((c.by_name.len > 0) != (c.by_path.len > 0));
        if (c.reclaim == .keep) try testing.expect(!c.reclaim.deletable());
    }
}

// Fixtures are built through libc for the same reason the walker reads
// through it: these tests are about hardlinks, symlinks and st_blocks,
// and a portable wrapper would abstract away exactly the things under
// test.
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn link(from: [*:0]const u8, to: [*:0]const u8) c_int;
extern "c" fn symlink(target: [*:0]const u8, path: [*:0]const u8) c_int;

/// Stores its root as a fixed array rather than a slice into itself.
///
/// A `root: []const u8` pointing into a sibling `buf` field dangles the
/// moment the struct is returned or copied — the slice keeps addressing
/// the dead temporary. It cost three confusing failures here; the array
/// plus a length is the version that survives being a value.
const Fixture = struct {
    buf: [128]u8 = @splat(0),
    len: usize = 0,

    fn make(name: []const u8) !Fixture {
        var f: Fixture = .{};
        f.len = (try std.fmt.bufPrint(&f.buf, ".zig-cache/tmp/diskscan-{s}", .{name})).len;
        // The parent is normally there from another test's tmpDir; make
        // it unconditionally so this file can be run alone.
        _ = mkdir(".zig-cache/tmp", 0o755);
        f.cleanup();
        var z: [160]u8 = undefined;
        _ = mkdir(try std.fmt.bufPrintZ(&z, "{s}", .{f.root()}), 0o755);
        return f;
    }

    fn root(self: *const Fixture) []const u8 {
        return self.buf[0..self.len];
    }

    fn dir(self: *const Fixture, sub: []const u8) !void {
        var acc: [512]u8 = undefined;
        var it = std.mem.splitScalar(u8, sub, '/');
        var n = (try std.fmt.bufPrint(&acc, "{s}", .{self.root()})).len;
        while (it.next()) |seg| {
            n += (try std.fmt.bufPrint(acc[n..], "/{s}", .{seg})).len;
            var z: [512]u8 = undefined;
            _ = mkdir(try std.fmt.bufPrintZ(&z, "{s}", .{acc[0..n]}), 0o755);
        }
    }

    fn file(self: *const Fixture, sub: []const u8, bytes: usize) !void {
        var p: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&p, "{s}/{s}", .{ self.root(), sub });
        const data = try testing.allocator.alloc(u8, bytes);
        defer testing.allocator.free(data);
        @memset(data, 'x');
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn at(self: *const Fixture, sub: []const u8, out: []u8) ![:0]const u8 {
        return try std.fmt.bufPrintZ(out, "{s}/{s}", .{ self.root(), sub });
    }

    fn cleanup(self: *const Fixture) void {
        std.Io.Dir.cwd().deleteTree(testing.io, self.root()) catch {};
    }
};

test "walk measures a fixture tree, dedupes hardlinks, ignores symlinks" {
    var f = try Fixture.make("measure");
    defer f.cleanup();

    // A 64KB file, a hardlink to it, and a symlink to it. An honest
    // scan counts those bytes ONCE.
    try f.file("big.bin", 64 * 1024);
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), link(try f.at("big.bin", &a), try f.at("hard.bin", &b)));
    try testing.expectEqual(@as(c_int, 0), symlink("big.bin", try f.at("soft.bin", &b)));

    try f.dir("proj/node_modules/dep");
    try f.file("proj/node_modules/dep/lib.js", 64 * 1024);

    var prog: Progress = .{};
    var scan = Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);
    try walk(testing.allocator, &scan, f.root(), &prog);

    const r = scan.root().?;
    // 64K once for big.bin+hard.bin, plus 64K for lib.js. The symlink
    // contributes nothing. Blocks round up, so assert a band.
    try testing.expect(r.bytes >= 128 * 1024);
    try testing.expect(r.bytes < 200 * 1024);
    try testing.expect(prog.done.load(.acquire));

    // Counting the hardlink twice is the failure this pins, and it
    // would show up as ~192K rather than as an error.
    try testing.expect(r.bytes < 190 * 1024);

    // The classifier ran during the walk, at depth.
    var found_nm = false;
    for (scan.nodes.items) |*n| {
        if (n.cat) |c| if (std.mem.eql(u8, c.id, "node-modules")) {
            found_nm = true;
            try testing.expect(n.bytes >= 64 * 1024);
        };
    }
    try testing.expect(found_nm);
}

test "walk stops when cancelled" {
    var f = try Fixture.make("cancel");
    defer f.cleanup();
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var nb: [64]u8 = undefined;
        try f.dir(try std.fmt.bufPrint(&nb, "d{d}/sub", .{i}));
    }

    var prog: Progress = .{};
    // Pre-cancelled: the walk must bail rather than finish and check
    // afterwards, or a cancel on a home directory takes minutes.
    prog.cancel.store(true, .release);
    var scan = Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);
    try walk(testing.allocator, &scan, f.root(), &prog);
    try testing.expectEqual(@as(usize, 1), scan.nodes.items.len);
}

test "depth limit bounds the tree but not the total" {
    var f = try Fixture.make("depth");
    defer f.cleanup();
    try f.dir("a/b/c/d/e");
    // Buried five levels down, well past max_depth.
    try f.file("a/b/c/d/e/deep.bin", 32 * 1024);

    var prog: Progress = .{};
    var scan = Scan.init(testing.allocator);
    scan.max_depth = 2;
    defer scan.deinit(testing.allocator);
    try walk(testing.allocator, &scan, f.root(), &prog);

    // The size rolled all the way up — this is the guarantee that makes
    // a depth limit safe to have at all.
    try testing.expect(scan.root().?.bytes >= 32 * 1024);
    // ...while no node exists past the limit.
    for (scan.nodes.items) |*n| try testing.expect(n.depth <= 2);
}

test "reclaimable does not count nested categories twice" {
    var f = try Fixture.make("nested");
    defer f.cleanup();
    // node_modules inside a project inside a classified cache is the
    // real-tree shape that turns a naive sum into a number bigger than
    // the disk.
    try f.dir("proj/node_modules/x");
    try f.file("proj/node_modules/x/a.js", 32 * 1024);
    try f.dir("proj/node_modules/x/node_modules");
    try f.file("proj/node_modules/x/node_modules/b.js", 32 * 1024);

    var prog: Progress = .{};
    var scan = Scan.init(testing.allocator);
    scan.max_depth = 8;
    defer scan.deinit(testing.allocator);
    try walk(testing.allocator, &scan, f.root(), &prog);

    const totals = reclaimable(&scan);
    const regen = totals[@intFromEnum(Reclaim.regenerable)];
    // Both files live under the OUTER node_modules, so the outer node
    // claims all of it and the inner must add nothing.
    try testing.expect(regen >= 64 * 1024);
    try testing.expect(regen < 100 * 1024);
    try testing.expect(regen <= scan.root().?.bytes);
}

test "volumeFor reports available, not free" {
    const v = volumeFor("/").?;
    try testing.expect(v.total > 0);
    try testing.expect(v.avail > 0);
    try testing.expect(v.avail < v.total);
}
