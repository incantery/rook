//! Which server runs, where it runs, and who gets the answer.
//!
//! lsp.zig speaks the protocol; this decides there should be a
//! conversation at all. Three jobs:
//!
//!   CATALOG — language → a command line. One entry today (Go/gopls),
//!   deliberately: the plan is that adding a language is DATA, and a
//!   catalog with one entry is the honest way to find out whether that
//!   is true when the second one arrives. When packages land this table
//!   is what they populate; it is not meant to grow by hand much past
//!   here.
//!
//!   ROOTS — a server is per (language, root), not per file. gopls
//!   wants the module; opening a second file in the same module must
//!   reuse the running server rather than paying the ~1s startup and
//!   the memory again.
//!
//!   ROUTING — replies are asynchronous and arrive some frames after
//!   the pane that asked may have retargeted or closed. Asks are keyed
//!   by PATH rather than by a pointer to the editor: a pane that moved
//!   on gets no answer, which is right, and nothing here can outlive a
//!   pointer into a freed pane, which is the bug the path avoids.
//!
//! Fail open, like everything downstream of it: no binary, no server,
//! no diagnostics, and an editor that behaves exactly as it did before
//! any of this existed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp.zig");
const gitpkg = @import("git.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
const X_OK = 1;

/// Servers alive at once. Each is a real process with a real index in
/// memory; past a handful, something is opening files in a loop.
const max_servers = 8;
/// Asks in flight. Small on purpose — a UI can only be waiting on so
/// many questions, and the oldest is dropped rather than accumulating.
const max_asks = 32;

pub const Lang = enum {
    go,
    python,
    /// One server for the whole family. TypeScript's tooling has always
    /// served JavaScript too — tsserver type-checks a .js file from
    /// JSDoc — so splitting them would mean two servers indexing the
    /// same project twice.
    typescript,

    pub fn fromPath(path: []const u8) ?Lang {
        if (std.mem.endsWith(u8, path, ".go")) return .go;
        if (std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyi")) return .python;
        const ts = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" };
        for (ts) |e| {
            if (std.mem.endsWith(u8, path, e)) return .typescript;
        }
        return null;
    }

    /// Files that mark the root of a project in this language. Ordered:
    /// the first one found walking up wins.
    fn rootMarkers(self: Lang) []const []const u8 {
        return switch (self) {
            .go => &.{"go.mod"},
            // pyproject first — a repo with both a pyproject and a
            // stray setup.py is a modern project carrying a shim, and
            // rooting at the shim finds the wrong package.
            .python => &.{ "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "requirements.txt" },
            // tsconfig before package.json: a monorepo has one
            // package.json per workspace, and the tsconfig is what says
            // which files the compiler considers one program. Rooting at
            // the wrong one gets a server that cannot resolve half your
            // imports.
            .typescript => &.{ "tsconfig.json", "jsconfig.json", "deno.json", "package.json" },
        };
    }

    /// The environment override, checked before the catalog. A raw
    /// command line, split on spaces. This is the seam the e2e suite
    /// drives a fake server through, and it is also the honest answer
    /// to "I want my own server" until config packages exist.
    fn envKey(self: Lang) [*:0]const u8 {
        return switch (self) {
            .go => "ROOK_LSP_GO",
            .python => "ROOK_LSP_PYTHON",
            .typescript => "ROOK_LSP_TYPESCRIPT",
        };
    }

    /// What to run, in preference order. A LIST rather than one name,
    /// because Python has no single answer the way Go has gopls: people
    /// run basedpyright, pyright, pylsp or jedi, and which one is
    /// installed is not something rook gets to decide for them. First
    /// one found wins; ROOK_LSP_PYTHON overrides the lot.
    fn candidates(self: Lang) []const Candidate {
        return switch (self) {
            .go => &.{.{ .bin = "gopls" }},
            .python => &.{
                .{ .bin = "basedpyright-langserver", .args = &.{"--stdio"} },
                .{ .bin = "pyright-langserver", .args = &.{"--stdio"} },
                .{ .bin = "pylsp" },
                .{ .bin = "jedi-language-server" },
            },
            // tsgo first, and only ever found project-locally: it ships
            // with @typescript/native-preview, so having it means the
            // project chose TypeScript 7 — whose lib has no tsserver.js
            // at all and which the older servers cannot drive.
            .typescript => &.{
                .{ .bin = "tsgo", .args = &.{ "--lsp", "--stdio" } },
                .{ .bin = "vtsls", .args = &.{"--stdio"} },
                .{ .bin = "typescript-language-server", .args = &.{"--stdio"} },
            },
        };
    }
};

/// One way to run a language's server: a binary to find, and the flags
/// it needs to speak stdio. The flags are part of the catalog entry
/// because they are not optional — `pyright-langserver` with no
/// `--stdio` starts a server nobody can talk to.
const Candidate = struct {
    bin: []const u8,
    args: []const []const u8 = &.{},
};

/// Where to look for a server binary, in order. The ROOT-relative
/// entries come first and they are the whole reason this is a list:
/// Python's server usually lives in the project's own virtualenv, and a
/// Node-based one in its node_modules — a PATH-only search finds the
/// wrong interpreter's tooling, or nothing at all. Go never needed this
/// because `go install` puts one binary in one place.
fn searchDir(i: usize, root: []const u8, home: []const u8, buf: *[512]u8) ?[]const u8 {
    return switch (i) {
        0 => std.fmt.bufPrint(buf, "{s}/.venv/bin", .{root}) catch null,
        1 => std.fmt.bufPrint(buf, "{s}/venv/bin", .{root}) catch null,
        2 => std.fmt.bufPrint(buf, "{s}/node_modules/.bin", .{root}) catch null,
        3 => if (home.len == 0) null else std.fmt.bufPrint(buf, "{s}/.local/bin", .{home}) catch null,
        4 => if (home.len == 0) null else std.fmt.bufPrint(buf, "{s}/go/bin", .{home}) catch null,
        else => null,
    };
}
const search_dirs = 5;

const Entry = struct {
    lang: Lang,
    /// Absolute, owned.
    root: []const u8,
    srv: *lsp.Server,
};

const AskKind = enum { hover, definition };

const Ask = struct {
    id: u32,
    kind: AskKind,
    /// The file the question was asked about, owned. The answer goes to
    /// whichever pane is showing this path when it lands — or nowhere.
    path: []const u8,
};

/// The one line of a hover worth putting in a status row.
///
/// Hover is markdown and every server lays it out differently: gopls
/// opens with a fenced signature, basedpyright prefixes a kind
/// ("(function) def ..."), and typescript-language-server begins its
/// value with a BLANK LINE before the fence. Taking "the first line"
/// literally gives you an empty string for that last one — the status
/// row silently stays blank, which reads as "hover is broken" rather
/// than as a formatting difference.
///
/// So: the first line that is neither blank nor a fence. Borrowed from
/// the caller's text.
pub fn hoverSummary(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "```")) continue;
        // A markdown rule separates the signature from the prose; one
        // arriving first means there was no signature.
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "___")) continue;
        return line;
    }
    return "";
}

/// Two paths naming the same file.
///
/// Not `mem.eql`, because a server is free to hand back a URI whose
/// case differs from the one we sent: macOS filesystems are
/// case-insensitive by default and servers normalize. TypeScript 7's
/// tsgo lowercases the whole path, which under an exact compare means
/// its diagnostics arrive for a file no pane is showing — they vanish,
/// silently, and the gutter just never fills in.
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Diagnostics for one file, in PROTOCOL coordinates (UTF-16 columns).
/// They are converted to byte columns where the text is — in the editor
/// that owns the rope — because that conversion needs the line.
const FileDiags = struct {
    path: []const u8,
    items: []lsp.Diagnostic,
};

pub const Answer = union(enum) {
    /// Hover text for `path`. Owned by the caller.
    hover: struct { path: []const u8, text: []const u8 },
    /// Where the definition is. Owned by the caller.
    definition: struct { path: []const u8, target: []const u8, line: u32, col: u32 },
    /// The question was answered with nothing. Still delivered, because
    /// the pane that asked said "asking…" and has to be told.
    none: struct { path: []const u8, kind: AskKind },

    pub fn deinit(self: *Answer, gpa: Allocator) void {
        switch (self.*) {
            .hover => |h| {
                gpa.free(h.path);
                gpa.free(h.text);
            },
            .definition => |d| {
                gpa.free(d.path);
                gpa.free(d.target);
            },
            .none => |n| gpa.free(n.path),
        }
        self.* = .{ .none = .{ .path = "", .kind = .hover } };
    }
};

pub const Manager = struct {
    gpa: Allocator,
    io: std.Io,
    servers: std.ArrayListUnmanaged(Entry) = .empty,
    asks: std.ArrayListUnmanaged(Ask) = .empty,
    diags: std.ArrayListUnmanaged(FileDiags) = .empty,
    answers: std.ArrayListUnmanaged(Answer) = .empty,
    /// Paths whose diagnostics changed since the app last looked. The
    /// app drains this to decide which panes to repaint — a server that
    /// republishes an unchanged file must not repaint the world.
    changed: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Set false by config; nothing spawns when off.
    enabled: bool = true,

    pub fn init(gpa: Allocator, io: std.Io) Manager {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Manager) void {
        for (self.servers.items) |e| {
            e.srv.deinit();
            self.gpa.free(e.root);
        }
        self.servers.deinit(self.gpa);
        for (self.asks.items) |a| self.gpa.free(a.path);
        self.asks.deinit(self.gpa);
        for (self.diags.items) |d| {
            self.gpa.free(d.path);
            freeDiags(self.gpa, d.items);
        }
        self.diags.deinit(self.gpa);
        for (self.answers.items) |*a| a.deinit(self.gpa);
        self.answers.deinit(self.gpa);
        for (self.changed.items) |c| self.gpa.free(c);
        self.changed.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeDiags(gpa: Allocator, items: []lsp.Diagnostic) void {
        for (items) |d| {
            gpa.free(d.message);
            gpa.free(d.source);
        }
        gpa.free(items);
    }

    // ------------------------------------------------------- discovery

    /// The command line for a language at a root, or null when there is
    /// nothing to run. Written into `store`; the returned slices point
    /// into it.
    fn command(self: *Manager, lang: Lang, root: []const u8, store: *[1024]u8, out: *[8][]const u8) ?[][]const u8 {
        _ = self;
        if (getenv(lang.envKey())) |raw| {
            const line = std.mem.span(raw);
            if (line.len == 0 or line.len >= store.len) return null;
            @memcpy(store[0..line.len], line);
            var n: usize = 0;
            var it = std.mem.tokenizeScalar(u8, store[0..line.len], ' ');
            while (it.next()) |tok| {
                if (n >= out.len) break;
                out[n] = tok;
                n += 1;
            }
            return if (n == 0) null else out[0..n];
        }

        const home = if (getenv("HOME")) |h| std.mem.span(h) else "";
        for (lang.candidates()) |cand| {
            var found: ?[]const u8 = null;
            // Project-local first, then PATH, then the per-user installs.
            var i: usize = 0;
            while (i < search_dirs and found == null) : (i += 1) {
                var db: [512]u8 = undefined;
                const dir = searchDir(i, root, home, &db) orelse continue;
                var pb: [1024]u8 = undefined;
                const full = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, cand.bin }) catch continue;
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
                        const full = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, cand.bin }) catch continue;
                        if (access(full.ptr, X_OK) != 0) continue;
                        if (full.len >= store.len) continue;
                        @memcpy(store[0..full.len], full);
                        found = store[0..full.len];
                        break;
                    }
                }
            }
            const bin = found orelse continue;
            out[0] = bin;
            var n: usize = 1;
            for (cand.args) |a| {
                if (n >= out.len) break;
                out[n] = a;
                n += 1;
            }
            return out[0..n];
        }
        return null;
    }

    /// Server settings for a language at a root, as a JSON object; ""
    /// for none. Sent on `initialized` and handed back whenever the
    /// server asks with workspace/configuration.
    ///
    /// This is the part of adding Python that was NOT data. gopls needs
    /// nothing — it reads go.mod and it is done. A Python server cannot
    /// find your interpreter on its own: point pyright at a project
    /// whose dependencies live in `.venv` without telling it so, and it
    /// reports every third-party import as missing. Which is a diagnostic
    /// panel full of errors that are not errors, and worse than silence.
    fn settingsFor(self: *Manager, lang: Lang, root: []const u8, buf: *[1024]u8) []const u8 {
        _ = self;
        switch (lang) {
            .go => return "",
            .python => {
                const py = pythonFor(root) orelse return "";
                return std.fmt.bufPrint(buf, "{{\"python\":{{\"pythonPath\":\"{s}\"}}}}", .{py}) catch "";
            },
            .typescript => {
                // The project's OWN typescript, when it has one. A
                // server running its bundled compiler against a project
                // pinned to a different version reports errors that
                // version does not have — and the fix it suggests is for
                // a compiler you are not using. With none installed the
                // server's bundled one IS right, so say nothing.
                const tsdk = tsdkFor(root) orelse return "";
                return std.fmt.bufPrint(buf, "{{\"typescript\":{{\"tsdk\":\"{s}\"}}}}", .{tsdk}) catch "";
            },
        }
    }

    /// `<root>/node_modules/typescript/lib`, if the project installed
    /// its own compiler. Static buffer, consumed immediately — the same
    /// contract as pythonFor.
    fn tsdkFor(root: []const u8) ?[]const u8 {
        const S = struct {
            var buf: [1024]u8 = undefined;
        };
        // Probed through tsserver.js rather than through the directory,
        // which buys two things. A half-removed node_modules can leave
        // an empty typescript/lib behind, and pointing a server at one
        // is worse than not configuring it. And TypeScript 7 has no
        // tsserver.js — it is a native binary — so the probe answers
        // "no tsdk" for exactly the projects where a tsdk would mean
        // nothing, without this function having to know a version.
        var probe: [1100]u8 = undefined;
        const lib = std.fmt.bufPrint(&S.buf, "{s}/node_modules/typescript/lib", .{root}) catch return null;
        const file = std.fmt.bufPrintZ(&probe, "{s}/tsserver.js", .{lib}) catch return null;
        if (access(file.ptr, 0) != 0) return null; // F_OK
        return lib;
    }

    /// The interpreter a project means. Project virtualenv first, then
    /// an activated one from the environment — in that order, because a
    /// shell that happens to have another project's venv active must not
    /// win over the venv sitting in this project's own directory.
    ///
    /// Returned in a static buffer: it is consumed immediately by
    /// settingsFor and never outlives the call.
    fn pythonFor(root: []const u8) ?[]const u8 {
        const S = struct {
            var buf: [1024]u8 = undefined;
        };
        const local = [_][]const u8{ ".venv", "venv", ".virtualenv" };
        for (local) |d| {
            const cand = std.fmt.bufPrintZ(&S.buf, "{s}/{s}/bin/python", .{ root, d }) catch continue;
            if (access(cand.ptr, X_OK) == 0) return cand;
        }
        if (getenv("VIRTUAL_ENV")) |ve| {
            const cand = std.fmt.bufPrintZ(&S.buf, "{s}/bin/python", .{std.mem.span(ve)}) catch return null;
            if (access(cand.ptr, X_OK) == 0) return cand;
        }
        return null;
    }

    /// The project root for a file: nearest ancestor holding one of the
    /// language's markers, else the repository, else the file's own
    /// directory. Written into `buf`.
    fn rootFor(self: *Manager, lang: Lang, path: []const u8, buf: *[1024]u8) ?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse return null;
        var probe: [1024]u8 = undefined;
        var cur = dir;
        while (cur.len > 1) {
            for (lang.rootMarkers()) |marker| {
                const cand = std.fmt.bufPrintZ(&probe, "{s}/{s}", .{ cur, marker }) catch continue;
                if (access(cand.ptr, 0) == 0) { // F_OK
                    if (cur.len >= buf.len) return null;
                    @memcpy(buf[0..cur.len], cur);
                    return buf[0..cur.len];
                }
            }
            cur = std.fs.path.dirname(cur) orelse break;
        }
        var rbuf: [1024]u8 = undefined;
        if (gitpkg.repoRootFs(self.io, self.gpa, dir, &rbuf)) |repo| {
            if (repo.len >= buf.len) return null;
            @memcpy(buf[0..repo.len], repo);
            return buf[0..repo.len];
        }
        if (dir.len >= buf.len) return null;
        @memcpy(buf[0..dir.len], dir);
        return buf[0..dir.len];
    }

    /// The live server for this file, starting one if the language is
    /// known and nothing is running for its root yet. null means "carry
    /// on without a server", which is always a valid outcome.
    pub fn ensure(self: *Manager, path: []const u8) ?*lsp.Server {
        if (!self.enabled) return null;
        const lang = Lang.fromPath(path) orelse return null;
        var rbuf: [1024]u8 = undefined;
        const root = self.rootFor(lang, path, &rbuf) orelse return null;

        for (self.servers.items) |e| {
            if (e.lang == lang and std.mem.eql(u8, e.root, root)) {
                // A server that died is not reused, and not restarted
                // here either: a crash loop that respawns on every
                // keystroke is worse than a dead server.
                if (e.srv.state() == .failed) return null;
                return e.srv;
            }
        }
        if (self.servers.items.len >= max_servers) return null;

        var store: [1024]u8 = undefined;
        var parts: [8][]const u8 = undefined;
        const argv = self.command(lang, root, &store, &parts) orelse return null;
        var setbuf: [1024]u8 = undefined;
        const settings = self.settingsFor(lang, root, &setbuf);

        const owned_root = self.gpa.dupe(u8, root) catch return null;
        const srv = lsp.Server.start(self.gpa, argv, root, settings) orelse {
            self.gpa.free(owned_root);
            return null;
        };
        self.servers.append(self.gpa, .{ .lang = lang, .root = owned_root, .srv = srv }) catch {
            srv.deinit();
            self.gpa.free(owned_root);
            return null;
        };
        return srv;
    }

    // ---------------------------------------------------------- asking

    fn recordAsk(self: *Manager, id: u32, kind: AskKind, path: []const u8) void {
        if (self.asks.items.len >= max_asks) {
            const old = self.asks.orderedRemove(0);
            self.gpa.free(old.path);
        }
        const owned = self.gpa.dupe(u8, path) catch return;
        self.asks.append(self.gpa, .{ .id = id, .kind = kind, .path = owned }) catch self.gpa.free(owned);
    }

    pub fn hover(self: *Manager, path: []const u8, pos: lsp.Position) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.hover(path, pos) orelse return false;
        self.recordAsk(id, .hover, path);
        return true;
    }

    pub fn definition(self: *Manager, path: []const u8, pos: lsp.Position) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.definition(path, pos) orelse return false;
        self.recordAsk(id, .definition, path);
        return true;
    }

    fn takeAsk(self: *Manager, id: u32) ?Ask {
        for (self.asks.items, 0..) |a, i| {
            if (a.id == id) return self.asks.orderedRemove(i);
        }
        return null;
    }

    // --------------------------------------------------------- draining

    /// Pull everything the servers have produced. Returns true when
    /// something changed that the screen should show. Cheap on an idle
    /// frame — no server has anything, and nothing allocates.
    pub fn drain(self: *Manager) bool {
        var changed = false;
        for (self.servers.items) |e| {
            while (e.srv.nextEvent()) |ev| {
                var event = ev;
                defer event.deinit(self.gpa);
                switch (event) {
                    .diagnostics => |d| {
                        self.storeDiags(d.path, d.items);
                        changed = true;
                    },
                    .hover => |h| {
                        const ask = self.takeAsk(h.id) orelse continue;
                        defer self.gpa.free(ask.path);
                        const text = self.gpa.dupe(u8, h.text) catch continue;
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            self.gpa.free(text);
                            continue;
                        };
                        self.pushAnswer(.{ .hover = .{ .path = p, .text = text } });
                        changed = true;
                    },
                    .definition => |d| {
                        const ask = self.takeAsk(d.id) orelse continue;
                        defer self.gpa.free(ask.path);
                        if (d.locs.len == 0) continue;
                        // The first location. A symbol with several
                        // definitions wants a picker, and that is the
                        // references slice's problem, not this one's.
                        const target = self.gpa.dupe(u8, d.locs[0].path) catch continue;
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            self.gpa.free(target);
                            continue;
                        };
                        self.pushAnswer(.{ .definition = .{
                            .path = p,
                            .target = target,
                            .line = d.locs[0].range.start.line,
                            .col = d.locs[0].range.start.col,
                        } });
                        changed = true;
                    },
                    .empty => |x| {
                        const ask = self.takeAsk(x.id) orelse continue;
                        defer self.gpa.free(ask.path);
                        const p = self.gpa.dupe(u8, ask.path) catch continue;
                        self.pushAnswer(.{ .none = .{ .path = p, .kind = ask.kind } });
                        changed = true;
                    },
                    // A server that failed leaves its diagnostics on
                    // screen deliberately: they were true when it said
                    // them, and blanking the gutter because a process
                    // died would read as "the errors are fixed".
                    .ready, .failed => changed = true,
                }
            }
        }
        return changed;
    }

    fn pushAnswer(self: *Manager, a: Answer) void {
        self.answers.append(self.gpa, a) catch {
            var mut = a;
            mut.deinit(self.gpa);
        };
    }

    /// Oldest first; the caller owns it.
    pub fn nextAnswer(self: *Manager) ?Answer {
        if (self.answers.items.len == 0) return null;
        return self.answers.orderedRemove(0);
    }

    /// A diagnostic message on ONE line. pyright writes paragraphs —
    /// "Type X is not assignable to Y" with the reasoning underneath —
    /// and everything downstream is single-line: a status row, a ctl
    /// reply that is a line protocol, and eventually a list. A raw
    /// newline in either would look like a second diagnostic.
    ///
    /// The detail is not lost so much as deferred: the full text belongs
    /// in a float, alongside hover's, when that lands.
    fn flatten(gpa: Allocator, msg: []const u8) ?[]u8 {
        const out = gpa.alloc(u8, msg.len) catch return null;
        var n: usize = 0;
        var space = false;
        for (msg) |c| {
            // Spaces count as whitespace here too, or the newline
            // collapses and the four-space indent that FOLLOWS it
            // survives — which is the shape pyright actually sends.
            const ws = c == '\n' or c == '\r' or c == '\t' or c == ' ';
            if (ws) {
                // Collapse a run, and never lead with one.
                if (n > 0) space = true;
                continue;
            }
            if (space) {
                out[n] = ' ';
                n += 1;
                space = false;
            }
            out[n] = c;
            n += 1;
        }
        return gpa.realloc(out, n) catch out[0..n];
    }

    fn storeDiags(self: *Manager, path: []const u8, items: []const lsp.Diagnostic) void {
        var copy = self.gpa.alloc(lsp.Diagnostic, items.len) catch return;
        var n: usize = 0;
        for (items) |d| {
            const msg = flatten(self.gpa, d.message) orelse continue;
            const src = self.gpa.dupe(u8, d.source) catch {
                self.gpa.free(msg);
                continue;
            };
            copy[n] = .{ .range = d.range, .severity = d.severity, .message = msg, .source = src };
            n += 1;
        }
        copy = self.gpa.realloc(copy, n) catch copy[0..n];

        for (self.diags.items) |*f| {
            if (!samePath(f.path, path)) continue;
            freeDiags(self.gpa, f.items);
            f.items = copy;
            self.noteChanged(path);
            return;
        }
        const owned = self.gpa.dupe(u8, path) catch {
            freeDiags(self.gpa, copy);
            return;
        };
        self.diags.append(self.gpa, .{ .path = owned, .items = copy }) catch {
            self.gpa.free(owned);
            freeDiags(self.gpa, copy);
            return;
        };
        self.noteChanged(path);
    }

    fn noteChanged(self: *Manager, path: []const u8) void {
        for (self.changed.items) |c| {
            if (samePath(c, path)) return;
        }
        const owned = self.gpa.dupe(u8, path) catch return;
        self.changed.append(self.gpa, owned) catch self.gpa.free(owned);
    }

    pub fn takeChanged(self: *Manager) [][]const u8 {
        return self.changed.toOwnedSlice(self.gpa) catch &.{};
    }

    pub fn freeChanged(self: *Manager, list: [][]const u8) void {
        for (list) |c| self.gpa.free(c);
        self.gpa.free(list);
    }

    /// What the server says about this file. Empty for a file nobody
    /// has diagnosed — which is not the same as a clean file, and the
    /// caller can tell them apart by whether a server is attached.
    pub fn diagsFor(self: *Manager, path: []const u8) []const lsp.Diagnostic {
        for (self.diags.items) |f| {
            if (samePath(f.path, path)) return f.items;
        }
        return &.{};
    }

    /// One line per running server, for `rookctl` and the e2e suite.
    pub fn describe(self: *Manager, w: *std.Io.Writer) void {
        for (self.servers.items) |e| {
            w.print("server {s} {s} {s}\n", .{
                @tagName(e.lang), @tagName(e.srv.state()), e.root,
            }) catch return;
        }
        for (self.diags.items) |f| {
            var errs: usize = 0;
            var warns: usize = 0;
            for (f.items) |d| {
                switch (d.severity) {
                    .err => errs += 1,
                    .warn => warns += 1,
                    else => {},
                }
            }
            w.print("file {s} errors:{d} warnings:{d}\n", .{ f.path, errs, warns }) catch return;
            for (f.items) |d| {
                w.print("  {s} {d}:{d} {s}\n", .{
                    @tagName(d.severity), d.range.start.line + 1, d.range.start.col, d.message,
                }) catch return;
            }
        }
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "a path picks its language, and unknown ones stay unknown" {
    try testing.expectEqual(Lang.go, Lang.fromPath("/x/main.go").?);
    try testing.expectEqual(Lang.python, Lang.fromPath("/x/main.py").?);
    try testing.expectEqual(Lang.python, Lang.fromPath("/x/stubs.pyi").?);
    // One entry for the whole JS/TS family: tsserver has always served
    // JavaScript too, and two servers would index the same project
    // twice.
    for ([_][]const u8{ "/x/a.ts", "/x/a.tsx", "/x/a.mts", "/x/a.cts", "/x/a.js", "/x/a.jsx", "/x/a.mjs", "/x/a.cjs" }) |p| {
        try testing.expectEqual(Lang.typescript, Lang.fromPath(p).?);
    }
    try testing.expect(Lang.fromPath("/x/README") == null);
    try testing.expect(Lang.fromPath("/x/main.rs") == null);
}

test "root markers are ordered, and pyproject wins over a setup.py shim" {
    try testing.expectEqualStrings("go.mod", Lang.go.rootMarkers()[0]);
    const py = Lang.python.rootMarkers();
    try testing.expectEqualStrings("pyproject.toml", py[0]);
    // requirements.txt last: it turns up in subdirectories of projects
    // that are rooted somewhere else entirely.
    try testing.expectEqualStrings("requirements.txt", py[py.len - 1]);
}

test "candidates carry the flags that are not optional" {
    // `pyright-langserver` with no --stdio starts a server nobody can
    // talk to, so the flag belongs to the catalog entry, not to a
    // caller who might forget it.
    for (Lang.python.candidates()) |c| {
        if (std.mem.indexOf(u8, c.bin, "pyright") != null) {
            try testing.expectEqual(@as(usize, 1), c.args.len);
            try testing.expectEqualStrings("--stdio", c.args[0]);
        }
    }
    try testing.expectEqualStrings("gopls", Lang.go.candidates()[0].bin);
    try testing.expectEqual(@as(usize, 0), Lang.go.candidates()[0].args.len);
}

test "the project's own virtualenv is what a Python server is told about" {
    // The part of adding Python that was not data. gopls needs nothing;
    // pyright pointed at a project without its interpreter reports every
    // third-party import as missing — a panel full of errors that aren't.
    const t = testing.allocator;
    const io = testing.io;
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/rook-venv-{d}", .{@intFromPtr(&root_buf)});
    var bin_buf: [192]u8 = undefined;
    const bindir = try std.fmt.bufPrint(&bin_buf, "{s}/.venv/bin", .{root});
    try std.Io.Dir.cwd().createDirPath(io, bindir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var m = Manager.init(t, io);
    defer m.deinit();
    var sbuf: [1024]u8 = undefined;
    // No interpreter yet: no settings, rather than a path that lies.
    try testing.expectEqualStrings("", m.settingsFor(.python, root, &sbuf));

    var py_buf: [256]u8 = undefined;
    const py = try std.fmt.bufPrint(&py_buf, "{s}/python", .{bindir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = py, .data = "#!/bin/sh\n" });
    var pz: [256]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&pz, "{s}", .{py});
    _ = chmod(@ptrCast(&pz), 0o755);

    const settings = m.settingsFor(.python, root, &sbuf);
    try testing.expect(std.mem.indexOf(u8, settings, "pythonPath") != null);
    try testing.expect(std.mem.indexOf(u8, settings, ".venv/bin/python") != null);
    // Go is told nothing, and that is not an oversight.
    try testing.expectEqualStrings("", m.settingsFor(.go, root, &sbuf));
}

test "hover summary survives every server's markdown habits" {
    // gopls: fenced signature, nothing before it.
    try testing.expectEqualStrings(
        "func greet(name string) string",
        hoverSummary("```go\nfunc greet(name string) string\n```"),
    );
    // typescript-language-server: a BLANK LINE first. Taking the first
    // line literally here returns "" and the status row stays empty,
    // which is what this function exists to prevent.
    try testing.expectEqualStrings(
        "function makeGreeter(name: string): Greeter",
        hoverSummary("\n```typescript\nfunction makeGreeter(name: string): Greeter\n```\n"),
    );
    // basedpyright: a kind prefix, then a rule, then prose.
    try testing.expectEqualStrings(
        "(function) def greet(name: str) -> str",
        hoverSummary("```python\n(function) def greet(name: str) -> str\n```\n---\nSays hi."),
    );
    // Plain text, no markdown at all.
    try testing.expectEqualStrings("just words", hoverSummary("just words"));
    // Nothing but decoration is nothing.
    try testing.expectEqualStrings("", hoverSummary("\n```\n```\n---\n"));
    try testing.expectEqualStrings("", hoverSummary(""));
}

test "a multi-line server message becomes one line" {
    const t = testing.allocator;
    // Verbatim shape of what basedpyright sends: the claim, then the
    // reasoning indented underneath.
    const raw = "Type \"Literal['not a number']\" is not assignable to declared type \"int\"\n" ++
        "    \"Literal['not a number']\" is not assignable to \"int\"";
    const flat = Manager.flatten(t, raw).?;
    defer t.free(flat);
    try testing.expect(std.mem.indexOfScalar(u8, flat, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, flat, "declared type \"int\" \"Literal") != null);
    // A run of whitespace collapses to ONE space, not to the indent.
    try testing.expect(std.mem.indexOf(u8, flat, "  ") == null);

    const lead = Manager.flatten(t, "\n\n  already indented").?;
    defer t.free(lead);
    try testing.expectEqualStrings("already indented", lead);
}

test "a manager with nothing to run stays silent" {
    var m = Manager.init(testing.allocator, testing.io);
    defer m.deinit();
    m.enabled = false;
    try testing.expect(m.ensure("/tmp/x.go") == null);
    try testing.expect(!m.hover("/tmp/x.go", .{}));
    try testing.expect(!m.drain());
    try testing.expectEqual(@as(usize, 0), m.diagsFor("/tmp/x.go").len);
}
