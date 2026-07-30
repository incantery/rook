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
const X_OK = 1;

/// Servers alive at once. Each is a real process with a real index in
/// memory; past a handful, something is opening files in a loop.
const max_servers = 8;
/// Asks in flight. Small on purpose — a UI can only be waiting on so
/// many questions, and the oldest is dropped rather than accumulating.
const max_asks = 32;

pub const Lang = enum {
    go,

    pub fn fromPath(path: []const u8) ?Lang {
        if (std.mem.endsWith(u8, path, ".go")) return .go;
        return null;
    }

    /// Files that mark the root of a project in this language. Ordered:
    /// the first one found walking up wins.
    fn rootMarkers(self: Lang) []const []const u8 {
        return switch (self) {
            .go => &.{"go.mod"},
        };
    }

    /// The environment override, checked before the catalog. A raw
    /// command line, split on spaces. This is the seam the e2e suite
    /// drives a fake server through, and it is also the honest answer
    /// to "I want my own gopls" until config packages exist.
    fn envKey(self: Lang) [*:0]const u8 {
        return switch (self) {
            .go => "ROOK_LSP_GO",
        };
    }

    fn catalogBinary(self: Lang) []const u8 {
        return switch (self) {
            .go => "gopls",
        };
    }
};

/// Where the catalog looks when the binary is not on PATH. These are
/// where each language's own toolchain installs by default — rook does
/// not install anything yet, so finding what you already have is the
/// whole of "materialization" for now.
fn fallbackDirs(lang: Lang, home: []const u8, buf: *[512]u8) ?[]const u8 {
    return switch (lang) {
        .go => std.fmt.bufPrint(buf, "{s}/go/bin/gopls", .{home}) catch null,
    };
}

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

    /// The command line for a language, or null when there is nothing
    /// to run. Written into `store`; the returned slices point into it.
    fn command(self: *Manager, lang: Lang, store: *[512]u8, out: *[8][]const u8) ?[][]const u8 {
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

        const bin = lang.catalogBinary();
        // PATH first: whatever the user's shell would run is what they
        // mean by "gopls", including a version manager's shim.
        if (getenv("PATH")) |praw| {
            var it = std.mem.tokenizeScalar(u8, std.mem.span(praw), ':');
            while (it.next()) |dir| {
                var pb: [512]u8 = undefined;
                const cand = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, bin }) catch continue;
                if (access(cand.ptr, X_OK) != 0) continue;
                if (cand.len >= store.len) return null;
                @memcpy(store[0..cand.len], cand);
                out[0] = store[0..cand.len];
                return out[0..1];
            }
        }
        if (getenv("HOME")) |hraw| {
            var pb: [512]u8 = undefined;
            const cand = fallbackDirs(lang, std.mem.span(hraw), &pb) orelse return null;
            var zb: [512]u8 = undefined;
            const z = std.fmt.bufPrintZ(&zb, "{s}", .{cand}) catch return null;
            if (access(z.ptr, X_OK) != 0) return null;
            if (cand.len >= store.len) return null;
            @memcpy(store[0..cand.len], cand);
            out[0] = store[0..cand.len];
            return out[0..1];
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

        var store: [512]u8 = undefined;
        var parts: [8][]const u8 = undefined;
        const argv = self.command(lang, &store, &parts) orelse return null;

        const owned_root = self.gpa.dupe(u8, root) catch return null;
        const srv = lsp.Server.start(self.gpa, argv, root, "") orelse {
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

    fn storeDiags(self: *Manager, path: []const u8, items: []const lsp.Diagnostic) void {
        var copy = self.gpa.alloc(lsp.Diagnostic, items.len) catch return;
        var n: usize = 0;
        for (items) |d| {
            const msg = self.gpa.dupe(u8, d.message) catch continue;
            const src = self.gpa.dupe(u8, d.source) catch {
                self.gpa.free(msg);
                continue;
            };
            copy[n] = .{ .range = d.range, .severity = d.severity, .message = msg, .source = src };
            n += 1;
        }
        copy = self.gpa.realloc(copy, n) catch copy[0..n];

        for (self.diags.items) |*f| {
            if (!std.mem.eql(u8, f.path, path)) continue;
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
            if (std.mem.eql(u8, c, path)) return;
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
            if (std.mem.eql(u8, f.path, path)) return f.items;
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

test "language and root markers" {
    try testing.expectEqual(Lang.go, Lang.fromPath("/x/main.go").?);
    try testing.expect(Lang.fromPath("/x/main.py") == null);
    try testing.expectEqualStrings("go.mod", Lang.go.rootMarkers()[0]);
}

test "a manager with nothing to run stays silent" {
    var m = Manager.init(testing.allocator, std.Io{ .vtable = undefined, .userdata = undefined });
    defer m.deinit();
    m.enabled = false;
    // Disabled: no discovery, no spawn, no answer — and specifically no
    // crash from the io handle above never being used.
    try testing.expect(m.ensure("/tmp/x.go") == null);
    try testing.expect(!m.hover("/tmp/x.go", .{}));
    try testing.expect(!m.drain());
    try testing.expectEqual(@as(usize, 0), m.diagsFor("/tmp/x.go").len);
}
