//! Declared languages: which files are a language, where its projects
//! begin, and what to run for one.
//!
//! There is NO catalog here. rook used to carry an enum of three
//! languages with a switch for each question it could be asked, and
//! adding a fourth meant editing Zig and shipping a binary. That was
//! wrong twice over. It made "I write Zig" a feature request, and it
//! put Python's knowledge — which of four servers, which of six ways a
//! project can name an interpreter — inside a terminal emulator.
//!
//! So a language is a declaration in the environment graph, like a
//! grammar and like a plugin, for the reason all three share: rook runs
//! code it did not write, and which code that is should be a thing you
//! wrote down rather than a thing rook guessed.
//!
//! The split that makes this work is between ROUTING and RESOLUTION:
//!
//!   ROUTING is data. Extension to language, walk up for `go.mod`. It
//!   runs on every open, has to be instant, and lives in this file.
//!
//!   RESOLUTION is code. "Which interpreter does this project mean."
//!   It runs once per project root, can afford a round trip, and lives
//!   in a plugin — see `resolver`.
//!
//! Most languages never need the second half. Go is gopls plus go.mod;
//! Zig is zls plus build.zig. Both are pure routing, and neither costs
//! a process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cfgpkg = @import("config.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const X_OK = 1;
const F_OK = 0;

/// Declared languages at once. A config naming more than this is a
/// config with a loop in it.
const max_langs = 64;

/// One `language` node, as declared.
pub const Spec = struct {
    name: []const u8,
    /// File extensions, leading dot included.
    ext: []const []const u8,
    /// Project markers, nearest-ancestor-first. Empty is legal: the
    /// repository root is the fallback, then the file's own directory.
    roots: []const []const u8 = &.{},
    /// The argv to run. Empty when a resolver answers instead.
    argv: []const []const u8 = &.{},
    /// A plugin that answers what to run. Wins over `argv`.
    resolver: []const u8 = "",
    /// Initialization options, verbatim JSON; "" for none.
    settings: []const u8 = "",
};

/// Why a file got no server. Reported by `ctl lsp`, because "nothing
/// happened" is the one answer a user cannot act on.
pub const Fault = enum {
    /// No declared language claims this extension. The ordinary case
    /// for a `.md` file, and the answer to "why is there no hover in
    /// this repo" for a language nobody declared.
    undeclared,
    /// Declared, but the binary it names is not on this machine.
    no_binary,
    /// Declared with a resolver, and the resolver has not answered yet.
    resolving,
    /// The resolver refused, with its own words.
    refused,
    /// A server RAN for this root and died. Its own fault because the
    /// old answer — reporting it as `no_binary` — told the user to
    /// install a binary they had, when the truth was "it crashed, and
    /// here is its last stderr line". A fresh open retries a dead
    /// root; this is what the file shows in between, and forever once
    /// the retry budget is spent.
    died,
};

pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    specs: []const Spec = &.{},

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Read the applied graph. Declarations only — a JSON pass over a
    /// file already in cache; nothing spawns here.
    pub fn loadGraph(self: *Registry, io: std.Io) void {
        const data = cfgpkg.envData(io, self.gpa) orelse return;
        defer self.gpa.free(data);
        self.loadFromJson(data);
    }

    /// Replace the declarations. What makes a config reload mean
    /// something.
    ///
    /// A node that does not parse as a language is simply not a
    /// language — never a reason to throw the file away. plugins.zig
    /// learned that one the hard way, when a keybind's string `command`
    /// failed the whole-file parse and every plugin vanished with it.
    pub fn loadFromJson(self: *Registry, data: []const u8) void {
        const Wire = struct { nodes: []std.json.Value = &.{} };
        const parsed = std.json.parseFromSlice(Wire, self.gpa, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        const Node = struct {
            kind: []const u8 = "",
            name: []const u8 = "",
            ext: []const []const u8 = &.{},
            roots: []const []const u8 = &.{},
            command: []const []const u8 = &.{},
            resolver: []const u8 = "",
            settings: std.json.Value = .null,
        };

        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var out: std.ArrayListUnmanaged(Spec) = .empty;

        for (parsed.value.nodes) |nv| {
            if (out.items.len >= max_langs) break;
            const np = std.json.parseFromValue(Node, self.gpa, nv, .{ .ignore_unknown_fields = true }) catch continue;
            defer np.deinit();
            const n = np.value;
            if (!std.mem.eql(u8, n.kind, "language")) continue;
            // A language nothing routes to is not a language. Both of
            // these are refused by the SDK; a hand-written graph is not
            // obliged to have gone through one.
            if (n.name.len == 0 or n.ext.len == 0) continue;
            if (n.command.len == 0 and n.resolver.len == 0) continue;

            // The settings object arrives PARSED and has to go back to
            // bytes: the protocol wants it verbatim inside
            // initializationOptions, and the graph's own canonical form
            // is the one to send.
            var settings: []const u8 = "";
            if (n.settings != .null) {
                settings = std.json.Stringify.valueAlloc(a, n.settings, .{}) catch "";
            }

            out.append(a, .{
                .name = a.dupe(u8, n.name) catch continue,
                .ext = dupeList(a, n.ext) orelse continue,
                .roots = dupeList(a, n.roots) orelse &.{},
                .argv = dupeList(a, n.command) orelse &.{},
                .resolver = a.dupe(u8, n.resolver) catch "",
                .settings = settings,
            }) catch break;
        }
        self.specs = out.items;
    }

    /// The language claiming this file, by extension.
    ///
    /// Longest extension wins, so a `.d.ts` declared alongside `.ts`
    /// lands where it was meant to and does not depend on which was
    /// declared first.
    pub fn forPath(self: *const Registry, path: []const u8) ?*const Spec {
        var best: ?*const Spec = null;
        var best_len: usize = 0;
        for (self.specs) |*s| {
            for (s.ext) |e| {
                if (e.len <= best_len) continue;
                if (std.mem.endsWith(u8, path, e)) {
                    best = s;
                    best_len = e.len;
                }
            }
        }
        return best;
    }

    pub fn byName(self: *const Registry, name: []const u8) ?*const Spec {
        for (self.specs) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

fn dupeList(a: Allocator, src: []const []const u8) ?[]const []const u8 {
    const out = a.alloc([]const u8, src.len) catch return null;
    for (src, 0..) |s, i| out[i] = a.dupe(u8, s) catch return null;
    return out;
}

/// The project root for a file: nearest ancestor holding one of the
/// language's markers, else whatever `fallback` says, else the file's
/// own directory. Written into `buf`.
///
/// Pure but for `access`, and separated from the manager so the marker
/// walk can be tested against a real directory tree without a server,
/// a config or a window.
pub fn rootFor(spec: *const Spec, path: []const u8, buf: *[1024]u8) ?[]const u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    var probe: [1024]u8 = undefined;
    var cur = dir;
    while (cur.len > 1) {
        for (spec.roots) |marker| {
            const cand = std.fmt.bufPrintZ(&probe, "{s}/{s}", .{ cur, marker }) catch continue;
            if (access(cand.ptr, F_OK) == 0) {
                if (cur.len >= buf.len) return null;
                @memcpy(buf[0..cur.len], cur);
                return buf[0..cur.len];
            }
        }
        cur = std.fs.path.dirname(cur) orelse break;
    }
    return null;
}

/// The directory rook offers a resolver plugin to install into, for
/// `lang`. Written into `buf`; not created here.
///
/// Beside `grammars/` and `plugins/`, which is the point: everything
/// rook fetches lives under one directory, so `rook uninstall` is one
/// `rm -rf` and a machine that has finished with rook has nothing of
/// rook's left on it. mason.nvim and Zed both landed here too
/// (`~/.local/share/nvim/mason`, `~/.local/share/zed/languages`) — it
/// is the field's answer, not ours.
///
/// rook NAMES this directory and never writes to it. The plugin
/// installs, because the plugin is the thing that knows whether that
/// means a tarball, `go install`, or `npm install --prefix`. What rook
/// contributes is the invariant: nothing any of them do lands outside
/// here, and none of it ever needs root.
pub fn serversDir(buf: []u8, lang: []const u8) ?[]const u8 {
    const base = if (getenv("XDG_DATA_HOME")) |x|
        std.fmt.bufPrint(buf, "{s}/rook/servers", .{std.mem.span(x)}) catch return null
    else blk: {
        const home = getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(buf, "{s}/.local/share/rook/servers", .{std.mem.span(home)}) catch return null;
    };
    var tmp: [1024]u8 = undefined;
    if (base.len >= tmp.len) return null;
    @memcpy(tmp[0..base.len], base);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ tmp[0..base.len], lang }) catch null;
}

/// Where to look for a server binary, in order.
///
/// The root-relative entries come first and they are the whole reason
/// this is a list: a project's own tooling beats the machine's. Python's
/// server usually lives in the project's virtualenv and a Node-based one
/// in its node_modules, and a PATH-only search finds the wrong
/// interpreter's tooling or nothing at all.
fn searchDir(i: usize, root: []const u8, home: []const u8, buf: *[512]u8) ?[]const u8 {
    return switch (i) {
        0 => std.fmt.bufPrint(buf, "{s}/.venv/bin", .{root}) catch null,
        1 => std.fmt.bufPrint(buf, "{s}/venv/bin", .{root}) catch null,
        2 => std.fmt.bufPrint(buf, "{s}/node_modules/.bin", .{root}) catch null,
        3 => std.fmt.bufPrint(buf, "{s}/go/bin", .{home}) catch null,
        4 => std.fmt.bufPrint(buf, "{s}/.local/bin", .{home}) catch null,
        5 => std.fmt.bufPrint(buf, "{s}/.cargo/bin", .{home}) catch null,
        else => null,
    };
}
const search_dirs = 6;

/// Turn an argv into one that can be exec'd: resolve argv[0] to a real
/// file, leaving the rest alone. null when the binary is not installed.
///
/// A path with a slash in it is taken at its word — declaring
/// `/opt/homebrew/bin/zls` means that one, not whichever `zls` a
/// search happens to reach first.
pub fn resolveArgv(
    argv: []const []const u8,
    root: []const u8,
    store: *[1024]u8,
    out: *[8][]const u8,
) ?[]const []const u8 {
    if (argv.len == 0) return null;
    const bin = argv[0];
    var found: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        var pb: [1024]u8 = undefined;
        const full = std.fmt.bufPrintZ(&pb, "{s}", .{bin}) catch return null;
        if (access(full.ptr, X_OK) != 0) return null;
        if (bin.len >= store.len) return null;
        @memcpy(store[0..bin.len], bin);
        found = store[0..bin.len];
    } else {
        const home = if (getenv("HOME")) |h| std.mem.span(h) else "";
        for (0..search_dirs) |i| {
            if (found != null) break;
            var db: [512]u8 = undefined;
            const dir = searchDir(i, root, home, &db) orelse continue;
            var pb: [1024]u8 = undefined;
            const full = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, bin }) catch continue;
            if (access(full.ptr, X_OK) != 0) continue;
            if (full.len >= store.len) continue;
            @memcpy(store[0..full.len], full);
            found = store[0..full.len];
        }
        if (found == null) {
            if (getenv("PATH")) |praw| {
                var it = std.mem.tokenizeScalar(u8, std.mem.span(praw), ':');
                while (it.next()) |dir| {
                    var pb: [1024]u8 = undefined;
                    const full = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, bin }) catch continue;
                    if (access(full.ptr, X_OK) != 0) continue;
                    if (full.len >= store.len) continue;
                    @memcpy(store[0..full.len], full);
                    found = store[0..full.len];
                    break;
                }
            }
        }
    }

    const resolved = found orelse return null;
    out[0] = resolved;
    var n: usize = 1;
    for (argv[1..]) |arg| {
        if (n >= out.len) break;
        out[n] = arg;
        n += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "declarations are read, and a node that is not a language is not one" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    r.loadFromJson(
        \\{"rookEnvironment":1,"nodes":[
        \\{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"nocturne"},
        \\{"id":"language:go","kind":"language","scope":"app","name":"go","ext":[".go"],"roots":["go.mod"],"command":["gopls"]},
        \\{"id":"grammar:go","kind":"grammar","scope":"app","name":"go","repo":"https://example/go"},
        \\{"id":"language:python","kind":"language","scope":"app","name":"python","ext":[".py",".pyi"],"roots":["pyproject.toml"],"resolver":"lang-python"}
        \\]}
    );
    try testing.expectEqual(@as(usize, 2), r.specs.len);

    const go = r.byName("go").?;
    try testing.expectEqualStrings("gopls", go.argv[0]);
    try testing.expectEqualStrings("go.mod", go.roots[0]);
    try testing.expectEqualStrings("", go.resolver);

    const py = r.byName("python").?;
    try testing.expectEqualStrings("lang-python", py.resolver);
    try testing.expectEqual(@as(usize, 0), py.argv.len);
    try testing.expectEqual(@as(usize, 2), py.ext.len);
}

test "an undeclared extension has no language, which is the ordinary case" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    r.loadFromJson(
        \\{"nodes":[{"id":"language:go","kind":"language","scope":"app","name":"go","ext":[".go"],"command":["gopls"]}]}
    );
    try testing.expect(r.forPath("/x/main.go") != null);
    try testing.expect(r.forPath("/x/README.md") == null);
    try testing.expect(r.forPath("/x/editor.zig") == null);
    // A name that merely CONTAINS the extension is not the extension.
    try testing.expect(r.forPath("/x/go.mod") == null);
}

test "the longest extension wins, whatever order it was declared in" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    // `.ts` first, so a first-match rule would take it.
    r.loadFromJson(
        \\{"nodes":[
        \\{"id":"language:typescript","kind":"language","scope":"app","name":"typescript","ext":[".ts"],"command":["vtsls"]},
        \\{"id":"language:dts","kind":"language","scope":"app","name":"dts","ext":[".d.ts"],"command":["other"]}
        \\]}
    );
    try testing.expectEqualStrings("typescript", r.forPath("/x/a.ts").?.name);
    try testing.expectEqualStrings("dts", r.forPath("/x/a.d.ts").?.name);
}

test "a malformed language is skipped and the rest survive" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    r.loadFromJson(
        \\{"nodes":[
        \\{"id":"language:noext","kind":"language","scope":"app","name":"noext","command":["x"]},
        \\{"id":"language:nocmd","kind":"language","scope":"app","name":"nocmd","ext":[".n"]},
        \\{"id":"language:noname","kind":"language","scope":"app","ext":[".q"],"command":["x"]},
        \\{"id":"language:go","kind":"language","scope":"app","name":"go","ext":[".go"],"command":["gopls"]}
        \\]}
    );
    try testing.expectEqual(@as(usize, 1), r.specs.len);
    try testing.expectEqualStrings("go", r.specs[0].name);
}

test "settings survive the round trip as JSON" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    r.loadFromJson(
        \\{"nodes":[{"id":"language:python","kind":"language","scope":"app","name":"python","ext":[".py"],
        \\"command":["pyright-langserver","--stdio"],"settings":{"python":{"pythonPath":"/v/bin/python"}}}]}
    );
    const py = r.specs[0];
    try testing.expectEqualStrings("{\"python\":{\"pythonPath\":\"/v/bin/python\"}}", py.settings);
    try testing.expectEqual(@as(usize, 2), py.argv.len);
    try testing.expectEqualStrings("--stdio", py.argv[1]);
}

test "a graph with no languages leaves nothing behind" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    // The default state, and the whole point of there being no
    // built-ins: take the declarations out and rook serves nothing.
    r.loadFromJson("{\"nodes\":[]}");
    try testing.expectEqual(@as(usize, 0), r.specs.len);
    try testing.expect(r.forPath("/x/main.go") == null);
    // And garbage is not a reason to crash or to keep stale state.
    r.loadFromJson("not json at all");
    try testing.expectEqual(@as(usize, 0), r.specs.len);
}

test "a reload replaces the declarations rather than adding to them" {
    const gpa = testing.allocator;
    var r = Registry.init(gpa);
    defer r.deinit();
    r.loadFromJson(
        \\{"nodes":[{"id":"language:go","kind":"language","scope":"app","name":"go","ext":[".go"],"command":["gopls"]}]}
    );
    try testing.expectEqual(@as(usize, 1), r.specs.len);
    r.loadFromJson(
        \\{"nodes":[{"id":"language:zig","kind":"language","scope":"app","name":"zig","ext":[".zig"],"command":["zls"]}]}
    );
    try testing.expectEqual(@as(usize, 1), r.specs.len);
    try testing.expectEqualStrings("zig", r.specs[0].name);
    try testing.expect(r.forPath("/x/main.go") == null);
}

test "the marker walk finds the nearest project, and reports none when there is none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "pkg", .default_dir);
    try tmp.dir.createDir(io, "pkg/inner", .default_dir);

    // Relative is fine: the walk is dirname-until-it-runs-out, and it
    // runs out at the top of a relative path the same way it stops at
    // the filesystem root of an absolute one.
    var base_buf: [512]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var mod_buf: [640]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&mod_buf, "{s}/go.mod", .{base}),
        .data = "module x\n",
    });

    var file_buf: [700]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/pkg/inner/a.go", .{base});
    var out: [1024]u8 = undefined;

    const spec: Spec = .{ .name = "go", .ext = &.{".go"}, .roots = &.{"go.mod"} };
    // The MODULE, not the file's directory — a server is per project.
    try testing.expectEqualStrings(base, rootFor(&spec, file, &out).?);

    // A marker nobody has: no root, and the caller decides what that
    // means rather than being handed the filesystem root.
    const none: Spec = .{ .name = "q", .ext = &.{".q"}, .roots = &.{"nothing-here.toml"} };
    try testing.expect(rootFor(&none, file, &out) == null);

    // No markers declared at all is the same answer, not a walk to `/`.
    const bare: Spec = .{ .name = "b", .ext = &.{".b"} };
    try testing.expect(rootFor(&bare, file, &out) == null);
}

test "an argv with a slash is taken at its word" {
    var store: [1024]u8 = undefined;
    var out: [8][]const u8 = undefined;
    // Something that exists and is executable on every machine this
    // runs on, so the test is about the RULE and not about a fixture.
    const argv = [_][]const u8{ "/bin/sh", "-c", "true" };
    const got = resolveArgv(&argv, "/tmp", &store, &out).?;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("/bin/sh", got[0]);
    try testing.expectEqualStrings("-c", got[1]);

    const missing = [_][]const u8{"/nonexistent/definitely/not-a-binary"};
    try testing.expect(resolveArgv(&missing, "/tmp", &store, &out) == null);
    try testing.expect(resolveArgv(&.{}, "/tmp", &store, &out) == null);
}

test "a bare name is searched, and a missing one is null rather than a guess" {
    var store: [1024]u8 = undefined;
    var out: [8][]const u8 = undefined;
    // `sh` is on the PATH of anything that can run this test.
    const argv = [_][]const u8{"sh"};
    const got = resolveArgv(&argv, "/tmp", &store, &out).?;
    try testing.expect(std.mem.endsWith(u8, got[0], "/sh"));

    const nope = [_][]const u8{"rook-definitely-not-a-real-server"};
    try testing.expect(resolveArgv(&nope, "/tmp", &store, &out) == null);
}
