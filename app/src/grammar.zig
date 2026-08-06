//! Where a tree-sitter grammar comes from — DECLARED, not discovered.
//!
//! The strip removed five grammars because they were 4.6MB of generated
//! parse table linked into a 2.7MB program, and because rook was the
//! outlier: neovim, helix and emacs each `dlopen` a shared object per
//! grammar, zed loads wasm, and vscode has no tables at all. This is
//! the way back.
//!
//! A grammar is a `grammar` node in the environment graph, exactly the
//! way a plugin is:
//!
//!     rook.Grammars{"go", "zig", "typescript", "tsx"}
//!     rook.Grammar{Name: "go", Source: "https://…/go.dylib", SHA256: "…"}
//!
//! and rook materializes it — fetching a prebuilt dylib against its
//! pin, or cloning the repository at a revision and compiling it — the
//! first time you open a file in that language.
//!
//! DECLARED IS THE WHOLE POINT, and the first version of this file got
//! it wrong. It scanned nvim-treesitter's and helix's parser
//! directories and loaded whatever it found, which highlights beautifully
//! on a machine that happens to have neovim configured and does nothing
//! on one that does not. That is the opposite of every other thing rook
//! loads: config is a program that emits a graph, the graph is
//! previewed and applied, and provenance can say where each byte came
//! from. A grammar is code rook did not compile running in rook's own
//! address space — the LAST thing that should arrive by looking around
//! the filesystem for another editor's cache.
//!
//! Borrowing another editor's parsers is still allowed. It just has to
//! be said out loud:
//!
//!     rook.GrammarPath{"~/.local/share/nvim/site/parser"}
//!
//! which is a declaration, and diffs like one.
//!
//! Nothing here is fatal. No declaration, no network, no compiler, a
//! pin that does not match, an ABI from the future: every one of them
//! ends as "no grammar for this language", the editor renders plain
//! text, and `rook syntax` says which — because a highlighter that
//! silently does nothing is indistinguishable from a file that happens
//! to have no keywords in it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const plugins = @import("plugins.zig");
const cfgpkg = @import("config.zig");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, sym: [*:0]const u8) ?*anyopaque;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn getdtablesize() c_int;
const RTLD_LAZY = 0x1;
const RTLD_LOCAL = 0x4;
const F_OK = 0;

/// The opaque tree-sitter language table. Its first field is the ABI
/// version, which is the one thing readable without the runtime — and
/// the thing worth reading before handing it to a parser.
pub const TSLanguage = opaque {};

/// What this runtime can parse. Vendored tree-sitter declares 13..15;
/// these are checked HERE rather than left to
/// `ts_parser_set_language`'s bool, because "your grammar is four years
/// old" and "your grammar is newer than rook" deserve different words.
pub const min_abi = 13;
pub const max_abi = 15;

/// One grammar as the graph declares it. Strings live in the registry's
/// arena and are replaced wholesale when config reloads.
pub const Spec = struct {
    name: []const u8 = "",
    /// A prebuilt dylib. Preferred when both are given — the SDK emits
    /// only one, so seeing both here means a hand-written graph.
    source: []const u8 = "",
    sha256: []const u8 = "",
    repo: []const u8 = "",
    rev: []const u8 = "",
    /// Subdirectory holding src/parser.c, for a repository carrying
    /// several grammars (tree-sitter-typescript ships two).
    dir: []const u8 = "",
};

/// Why a language has no grammar. Every one of these is a sentence a
/// user can act on, which is the entire reason this is an enum and not
/// a bool.
pub const Fault = enum {
    /// Nothing in the graph declares this language. The common case,
    /// and the one the old discovery-based loader could not express at
    /// all — it just found nothing and shrugged.
    undeclared,
    /// Declared, and getting it failed: no network, a 404, no `cc`.
    unavailable,
    /// Fetched, and the bytes are not the ones the pin names.
    bad_pin,
    /// On disk and the system refused to load it — wrong architecture,
    /// most often, from a parser directory built on another machine.
    unloadable,
    /// Loaded, but exports no `tree_sitter_<name>`.
    no_symbol,
    /// Built against a tree-sitter older than this runtime understands.
    too_old,
    /// Built against a NEWER one. rook is what needs updating.
    too_new,

    pub fn text(self: Fault) []const u8 {
        return switch (self) {
            .undeclared => "not declared — add it to your config (rook.Grammars{...})",
            .unavailable => "declared, but could not be fetched or built",
            .bad_pin => "the bytes do not match the declared sha256",
            .unloadable => "on disk, but the system refused to load it (wrong architecture?)",
            .no_symbol => "loaded, but it exports no tree_sitter_<lang> symbol",
            .too_old => "built for a tree-sitter older than rook's runtime",
            .too_new => "built for a newer tree-sitter than rook's runtime",
        };
    }
};

pub const Loaded = struct {
    lang: *const TSLanguage,
    /// Where it came from, owned — for `rook syntax`.
    path: []const u8,
    abi: u32,
};

/// One resolved language, successful or not. Cached either way: a
/// failed lookup that retried every frame would fork a subprocess on
/// the render path forever.
const Entry = struct {
    name: []const u8,
    loaded: ?Loaded = null,
    fault: Fault = .undeclared,
};

/// A directory the CONFIG named. Not a guess — see the module note.
pub const Dir = struct {
    path: []const u8,
    exists: bool,
};

pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    specs: []Spec = &.{},
    dirs: std.ArrayListUnmanaged(Dir) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Set false by config; nothing is opened when off.
    enabled: bool = true,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Read the applied graph. Declarations only — a JSON pass over a
    /// file already in cache. Fetching and compiling is what costs, and
    /// that is lazy, on the first file of a language you actually open.
    pub fn loadGraph(self: *Registry, io: std.Io) void {
        const data = cfgpkg.envData(io, self.gpa) orelse return;
        defer self.gpa.free(data);
        self.loadFromJson(data);
    }

    pub fn deinit(self: *Registry) void {
        for (self.dirs.items) |d| self.gpa.free(d.path);
        self.dirs.deinit(self.gpa);
        for (self.entries.items) |e| {
            self.gpa.free(e.name);
            if (e.loaded) |l| self.gpa.free(l.path);
        }
        self.entries.deinit(self.gpa);
        self.arena.deinit();
        // The dylibs themselves are never dlclosed. A TSLanguage is a
        // pointer INTO the mapped image, and trees parsed with it
        // outlive any bookkeeping we could do here; unmapping one to
        // reclaim a few hundred KB at shutdown is a use-after-free
        // waiting for the one pane that had not closed yet.
        self.* = undefined;
    }

    /// Read `grammar` and `grammar-path` nodes out of the environment
    /// graph. Replaces whatever was declared before, which is what
    /// makes a config reload mean something.
    ///
    /// A node that does not parse as a grammar is simply not a grammar
    /// — the same rule plugins.loadFromJson learned the hard way, when
    /// one keybind's string `command` threw the whole-file parse and
    /// every plugin declaration vanished with it.
    pub fn loadFromJson(self: *Registry, data: []const u8) void {
        const Wire = struct { nodes: []std.json.Value = &.{} };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const Node = struct {
            kind: []const u8 = "",
            name: []const u8 = "",
            source: []const u8 = "",
            sha256: []const u8 = "",
            repo: []const u8 = "",
            rev: []const u8 = "",
            dir: []const u8 = "",
            path: []const u8 = "",
        };

        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var specs: std.ArrayListUnmanaged(Spec) = .empty;
        for (self.dirs.items) |d| self.gpa.free(d.path);
        self.dirs.clearRetainingCapacity();

        for (parsed.value.nodes) |nv| {
            const np = std.json.parseFromValue(Node, self.gpa, nv, .{ .ignore_unknown_fields = true }) catch continue;
            defer np.deinit();
            const n = np.value;
            if (std.mem.eql(u8, n.kind, "grammar-path")) {
                if (n.path.len > 0) self.addDir(n.path);
                continue;
            }
            if (!std.mem.eql(u8, n.kind, "grammar")) continue;
            if (n.name.len == 0) continue;
            if (n.source.len == 0 and n.repo.len == 0) continue;
            specs.append(a, .{
                .name = a.dupe(u8, n.name) catch continue,
                .source = a.dupe(u8, n.source) catch "",
                .sha256 = a.dupe(u8, n.sha256) catch "",
                .repo = a.dupe(u8, n.repo) catch "",
                .rev = a.dupe(u8, n.rev) catch "",
                .dir = a.dupe(u8, n.dir) catch "",
            }) catch continue;
        }
        self.specs = specs.items;
        // Declarations changed, so every previous answer is suspect —
        // including the failures, which is the point: adding a grammar
        // to your config and having nothing happen until relaunch is
        // how a config system loses trust.
        self.forget();
    }

    fn addDir(self: *Registry, path: []const u8) void {
        if (path.len == 0 or path.len > 1000) return;
        for (self.dirs.items) |d| {
            if (std.mem.eql(u8, d.path, path)) return;
        }
        var z: [1024]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        const owned = self.gpa.dupe(u8, path) catch return;
        self.dirs.append(self.gpa, .{
            .path = owned,
            // Recorded rather than filtered: a directory that does not
            // exist is worth SHOWING, because "I put it there" and
            // "rook never looked there" are the two things a person
            // debugging this is trying to tell apart.
            .exists = access(z[0..path.len :0], F_OK) == 0,
        }) catch self.gpa.free(owned);
    }

    /// Drop every resolution, keeping declarations. The next ask
    /// re-materializes.
    pub fn forget(self: *Registry) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.name);
            if (e.loaded) |l| self.gpa.free(l.path);
        }
        self.entries.clearRetainingCapacity();
        var z: [1024]u8 = undefined;
        for (self.dirs.items) |*d| {
            if (d.path.len >= z.len) continue;
            @memcpy(z[0..d.path.len], d.path);
            z[d.path.len] = 0;
            d.exists = access(z[0..d.path.len :0], F_OK) == 0;
        }
    }

    fn specFor(self: *Registry, name: []const u8) ?Spec {
        for (self.specs) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// The grammar for `name`, materializing and opening it the first
    /// time it is asked for. Null with a recorded fault when there is
    /// none — including the ordinary case of nobody having declared it.
    pub fn get(self: *Registry, name: []const u8) ?*const TSLanguage {
        if (!self.enabled) return null;
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            return if (e.loaded) |l| l.lang else null;
        }
        var e = self.resolve(name);
        e.name = self.gpa.dupe(u8, name) catch return null;
        self.entries.append(self.gpa, e) catch {
            self.gpa.free(e.name);
            if (e.loaded) |l| self.gpa.free(l.path);
            return null;
        };
        return if (e.loaded) |l| l.lang else null;
    }

    fn resolve(self: *Registry, name: []const u8) Entry {
        // A declared grammar first — the graph is the answer, and a
        // borrowed copy must not shadow the one you asked for.
        if (self.specFor(name)) |spec| {
            var buf: [1200]u8 = undefined;
            return switch (materialize(spec, &buf)) {
                .path => |p| self.openAt(p),
                .fault => |f| .{ .name = "", .fault = f },
            };
        }
        // Then any directory the config named. Declared too, just
        // coarsely: "everything in here" rather than one grammar.
        for (self.dirs.items) |d| {
            if (!d.exists) continue;
            for ([_][]const u8{ ".so", ".dylib" }) |ext| {
                var z: [1200]u8 = undefined;
                const p = std.fmt.bufPrint(&z, "{s}/{s}{s}", .{ d.path, name, ext }) catch continue;
                if (!existsZ(p)) continue;
                const got = self.openAt(p);
                if (got.loaded != null) return got;
            }
        }
        return .{ .name = "", .fault = .undeclared };
    }

    /// Where a materialized grammar lives. Beside the plugin cache,
    /// because it is the same kind of thing: code rook fetched, keyed
    /// by the name that declared it.
    fn cachePath(buf: []u8, name: []const u8) ?[]const u8 {
        const base = if (getenv("XDG_DATA_HOME")) |x|
            std.fmt.bufPrint(buf, "{s}/rook/grammars", .{std.mem.span(x)}) catch return null
        else blk: {
            const home = getenv("HOME") orelse return null;
            break :blk std.fmt.bufPrint(buf, "{s}/.local/share/rook/grammars", .{std.mem.span(home)}) catch return null;
        };
        var tmp: [1024]u8 = undefined;
        if (base.len >= tmp.len) return null;
        @memcpy(tmp[0..base.len], base);
        return std.fmt.bufPrint(buf, "{s}/{s}.dylib", .{ tmp[0..base.len], name }) catch null;
    }

    /// Where a materialized grammar ended up, or why it did not.
    const Got = union(enum) { path: []const u8, fault: Fault };

    /// Get the dylib onto disk, or say why not. Lazy and cached: the
    /// file surviving from last time is the fast path, and it is the
    /// only path that runs on an ordinary launch.
    fn materialize(spec: Spec, buf: []u8) Got {
        const dest = cachePath(buf, spec.name) orelse return .{ .fault = .unavailable };
        if (existsZ(dest)) {
            // A pin is checked against what is already here, so
            // changing the pin in config re-fetches rather than
            // trusting a file whose provenance just changed.
            if (spec.sha256.len == 0) return .{ .path = dest };
            var got: [64]u8 = undefined;
            if (plugins.hashFile(dest, &got) and std.ascii.eqlIgnoreCase(&got, spec.sha256))
                return .{ .path = dest };
        }

        // Source wins when both are declared: a prebuilt artifact with
        // a pin is a stronger claim than a repository at a revision,
        // and the SDK only ever emits one of them anyway.
        if (spec.source.len > 0) {
            var why: [128]u8 = undefined;
            if (!plugins.fetch(spec.source, dest, &why)) return .{ .fault = .unavailable };
            if (spec.sha256.len > 0) {
                var got: [64]u8 = undefined;
                if (!plugins.hashFile(dest, &got)) return .{ .fault = .unavailable };
                if (!std.ascii.eqlIgnoreCase(&got, spec.sha256)) return .{ .fault = .bad_pin };
            }
            return .{ .path = dest };
        }
        if (spec.repo.len > 0) {
            if (!buildFromRepo(spec, dest)) return .{ .fault = .unavailable };
            return .{ .path = dest };
        }
        return .{ .fault = .unavailable };
    }

    fn openAt(self: *Registry, path: []const u8) Entry {
        var z: [1200]u8 = undefined;
        const zp = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return .{ .name = "", .fault = .unloadable };
        const h = dlopen(zp, RTLD_LAZY | RTLD_LOCAL) orelse
            return .{ .name = "", .fault = .unloadable };

        // The symbol is named for the grammar, not the file — they
        // agree by convention and the convention is what dlsym needs.
        const base = std.fs.path.basename(path);
        const stem = base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
        var sym: [128]u8 = undefined;
        const s = std.fmt.bufPrintZ(&sym, "tree_sitter_{s}", .{stem}) catch
            return .{ .name = "", .fault = .no_symbol };
        const fnptr = dlsym(h, s) orelse return .{ .name = "", .fault = .no_symbol };

        const f: *const fn () callconv(.c) *const TSLanguage = @ptrCast(@alignCast(fnptr));
        const lang = f();
        // The ABI version is the first u32 of the table. Read before
        // use: handing a version this runtime does not understand to
        // ts_parser_set_language gets a bool with no reason attached,
        // and the reason is the whole difference between "update rook"
        // and "rebuild your grammars".
        const abi = @as(*const u32, @ptrCast(@alignCast(lang))).*;
        if (abi < min_abi) return .{ .name = "", .fault = .too_old };
        if (abi > max_abi) return .{ .name = "", .fault = .too_new };

        // The registry's allocator, because deinit frees it with the
        // registry's allocator.
        const owned = self.gpa.dupe(u8, path) catch return .{ .name = "", .fault = .unloadable };
        return .{ .name = "", .loaded = .{ .lang = lang, .path = owned, .abi = abi } };
    }

    /// What `rook syntax` prints: what is declared, what resolved, and
    /// for anything that did not, the sentence saying why.
    pub fn describe(self: *Registry, w: *std.Io.Writer) void {
        w.print("enabled:{s} declared:{d} paths:{d}\n", .{
            if (self.enabled) "yes" else "no",
            self.specs.len,
            self.dirs.items.len,
        }) catch return;
        for (self.specs) |s| {
            if (s.source.len > 0) {
                w.print("  declared {s}\tsource\t{s}{s}\n", .{
                    s.name, s.source,
                    @as([]const u8, if (s.sha256.len > 0) " (pinned)" else " (UNPINNED)"),
                }) catch return;
            } else {
                w.print("  declared {s}\trepo\t{s}{s}\n", .{
                    s.name, s.repo,
                    @as([]const u8, if (s.rev.len > 0) " (pinned)" else " (UNPINNED)"),
                }) catch return;
            }
        }
        for (self.dirs.items) |d| {
            w.print("  path {s}\t{s}\n", .{ if (d.exists) "ok " else "gone", d.path }) catch return;
        }
        for (self.entries.items) |e| {
            if (e.loaded) |l| {
                w.print("  lang {s}\tabi:{d}\t{s}\n", .{ e.name, l.abi, l.path }) catch return;
            } else {
                w.print("  lang {s}\tNONE\t{s}\n", .{ e.name, e.fault.text() }) catch return;
            }
        }
    }
};

fn existsZ(path: []const u8) bool {
    var z: [1200]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return access(z[0..path.len :0], F_OK) == 0;
}

/// Clone a grammar repository at its pinned revision and compile it.
///
/// The fallback for a grammar nobody publishes a dylib for, which today
/// is all of them. Needs `git` and a C compiler; a machine with neither
/// gets plain text and a sentence saying so, which is the same outcome
/// as any other unavailable grammar.
fn buildFromRepo(spec: Spec, dest: []const u8) bool {
    var tmpl: [64]u8 = ("/tmp/rook-grammar-XXXXXX" ++ [_]u8{0} ** 40).*;
    const dir = mkdtemp(&tmpl) orelse return false;
    const dirs = std.mem.span(dir);

    if (spec.rev.len > 0) {
        // A pinned revision needs the history to contain it, so this
        // cannot be a depth-1 clone of the default branch.
        if (!run(&.{ "git", "clone", "--quiet", spec.repo, dirs })) return false;
        if (!runIn(dirs, &.{ "git", "checkout", "--quiet", spec.rev })) return false;
    } else if (!run(&.{ "git", "clone", "--quiet", "--depth", "1", spec.repo, dirs })) return false;

    var srcbuf: [1200]u8 = undefined;
    const src = if (spec.dir.len > 0)
        std.fmt.bufPrint(&srcbuf, "{s}/{s}/src", .{ dirs, spec.dir }) catch return false
    else
        std.fmt.bufPrint(&srcbuf, "{s}/src", .{dirs}) catch return false;

    var parser: [1200]u8 = undefined;
    const pc = std.fmt.bufPrint(&parser, "{s}/parser.c", .{src}) catch return false;
    if (!existsZ(pc)) return false;

    // The external scanner is not optional where it exists: Python's
    // INDENT/DEDENT and every language with heredocs live there, and a
    // parser.c on its own links fine and then fails on the first
    // indented block.
    var scanner: [1200]u8 = undefined;
    const sc = std.fmt.bufPrint(&scanner, "{s}/scanner.c", .{src}) catch return false;
    const has_scanner = existsZ(sc);

    var destbuf: [1200]u8 = undefined;
    const dz = std.fmt.bufPrint(&destbuf, "{s}", .{dest}) catch return false;
    if (std.mem.lastIndexOfScalar(u8, dz, '/')) |cut| {
        var mk: [1200]u8 = undefined;
        const d = std.fmt.bufPrintZ(&mk, "{s}", .{dz[0..cut]}) catch return false;
        _ = run(&.{ "mkdir", "-p", std.mem.span(d.ptr) });
    }

    return if (has_scanner)
        run(&.{ "cc", "-shared", "-fPIC", "-O2", "-I", src, "-o", dz, pc, sc })
    else
        run(&.{ "cc", "-shared", "-fPIC", "-O2", "-I", src, "-o", dz, pc });
}

extern "c" fn mkdtemp(template: [*]u8) ?[*:0]u8;
extern "c" fn chdir(path: [*:0]const u8) c_int;

fn run(argv: []const []const u8) bool {
    return runIn(null, argv);
}

/// fork+exec, output to /dev/null, true on exit 0. Deliberately not a
/// shell: every argument here is a path or a URL out of config, and a
/// shell would give a semicolon in one of them a meaning.
fn runIn(cwd: ?[]const u8, argv: []const []const u8) bool {
    if (argv.len == 0 or argv.len > 16) return false;
    var store: [16][512]u8 = undefined;
    var ptrs: [17]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, i| {
        if (arg.len >= store[i].len) return false;
        @memcpy(store[i][0..arg.len], arg);
        store[i][arg.len] = 0;
        ptrs[i] = @ptrCast(&store[i]);
    }
    var cwdz: [1024]u8 = undefined;
    if (cwd) |c| {
        if (c.len >= cwdz.len) return false;
        @memcpy(cwdz[0..c.len], c);
        cwdz[c.len] = 0;
    }

    const child = fork();
    if (child < 0) return false;
    if (child == 0) {
        if (cwd != null) _ = chdir(@ptrCast(&cwdz));
        const devnull = open("/dev/null", 1);
        if (devnull >= 0) {
            _ = dup2(devnull, 1);
            _ = dup2(devnull, 2);
        }
        var fd: c_int = 3;
        const maxfd = getdtablesize();
        while (fd < maxfd) : (fd += 1) _ = close(fd);
        _ = execvp(ptrs[0].?, @ptrCast(&ptrs));
        _exit(127);
    }
    var status: c_int = 0;
    _ = waitpid(child, &status, 0);
    return @as(u8, @truncate(@as(u32, @bitCast(status)) >> 8)) == 0;
}

// ---- tests ----

const testing = std.testing;

test "a graph declares grammars, and a mixed graph still yields them" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    // A keybind rides in the same array with a string `command`: the
    // shape that once threw a whole-file parse and took every plugin
    // declaration with it.
    reg.loadFromJson(
        \\{"nodes":[
        \\{"id":"keybind:app:x","kind":"keybind","scope":"app","chord":"x","command":"pane.split-right"},
        \\{"id":"grammar:go","kind":"grammar","scope":"app","name":"go","repo":"https://example/tree-sitter-go"},
        \\{"id":"grammar:tsx","kind":"grammar","scope":"app","name":"tsx","repo":"https://example/ts","dir":"tsx"},
        \\{"id":"grammar:pin","kind":"grammar","scope":"app","name":"pin","source":"https://example/pin.dylib","sha256":"abc"}
        \\]}
    );
    try testing.expectEqual(@as(usize, 3), reg.specs.len);
    try testing.expectEqualStrings("go", reg.specs[0].name);
    try testing.expectEqualStrings("tsx", reg.specs[1].dir);
    try testing.expectEqualStrings("abc", reg.specs[2].sha256);
}

test "an undeclared language faults as undeclared, not as missing" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.loadFromJson("{\"nodes\":[]}");
    try testing.expect(reg.get("nosuchlang") == null);
    // Cached, so the render path does not retry; and the fault names
    // the fix, which "no grammar found" never did.
    try testing.expect(reg.get("nosuchlang") == null);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqual(Fault.undeclared, reg.entries.items[0].fault);
}

test "a declared search path is kept, and re-declaring replaces it" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.loadFromJson(
        \\{"nodes":[
        \\{"id":"grammar-path:0","kind":"grammar-path","scope":"app","path":"/one"},
        \\{"id":"grammar-path:1","kind":"grammar-path","scope":"app","path":"/two"}
        \\]}
    );
    try testing.expectEqual(@as(usize, 2), reg.dirs.items.len);
    // A reload is the whole declaration, not an addition to it.
    reg.loadFromJson("{\"nodes\":[{\"id\":\"grammar-path:0\",\"kind\":\"grammar-path\",\"scope\":\"app\",\"path\":\"/only\"}]}");
    try testing.expectEqual(@as(usize, 1), reg.dirs.items.len);
    try testing.expectEqualStrings("/only", reg.dirs.items[0].path);
}

test "reloading declarations forgets old answers" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.loadFromJson("{\"nodes\":[]}");
    _ = reg.get("go");
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    // Declaring it must not leave the old "undeclared" answer standing:
    // adding a grammar and seeing nothing change until relaunch is how
    // a config system loses trust.
    reg.loadFromJson(
        \\{"nodes":[{"id":"grammar:go","kind":"grammar","scope":"app","name":"go","repo":"https://example/go"}]}
    );
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 1), reg.specs.len);
}

test "disabled means nothing is opened at all" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.enabled = false;
    reg.loadFromJson(
        \\{"nodes":[{"id":"grammar:go","kind":"grammar","scope":"app","name":"go","repo":"https://example/go"}]}
    );
    try testing.expect(reg.get("go") == null);
    // Not even recorded — off is off, and a fault list built while
    // disabled would read as "tried and failed".
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
}
