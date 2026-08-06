//! Which server runs, where it runs, and who gets the answer.
//!
//! lsp.zig speaks the protocol; this decides there should be a
//! conversation at all. Three jobs:
//!
//!   ROUTING BY DECLARATION — there is no catalog. Which languages
//!   exist, which files are one, and what to run for a project all come
//!   out of the environment graph (language.zig). rook used to carry an
//!   enum of three with a switch per question; adding a fourth meant
//!   editing this file and shipping a binary, and Python's knowledge of
//!   its own toolchains lived in a terminal emulator. Both were wrong.
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
const langpkg = @import("language.zig");
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

const Entry = struct {
    /// The declared language's name, borrowed from the registry's
    /// arena — which outlives every server, and is replaced wholesale
    /// only on a config reload.
    lang: []const u8,
    /// Absolute, owned.
    root: []const u8,
    srv: *lsp.Server,
};

const AskKind = enum { hover, definition, references, rename, completion, formatting, code_action, code_action_resolve };

const Ask = struct {
    id: u32,
    kind: AskKind,
    /// The file the question was asked about, owned. The answer goes to
    /// whichever pane is showing this path when it lands — or nowhere.
    path: []const u8,
    /// The word the question was asked ABOUT, owned; "" when the caller
    /// had nothing to name. Carried so a list can title itself with the
    /// symbol you asked about rather than with whatever is under the
    /// cursor by the time the server answers — the cursor moves while a
    /// round trip is in flight, and a list labelled with the wrong
    /// symbol is worse than one labelled with none.
    symbol: []const u8 = "",
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

/// One place a symbol is used.
///
/// Still in the PROTOCOL's coordinates — 0-based lines, UTF-16 columns —
/// because converting a column needs the line it sits on, and these name
/// files that may not be open in any pane. Whoever reads the text does
/// the conversion, the same rule diagnostics follow.
pub const Site = struct {
    /// Absolute, owned.
    path: []const u8,
    line: u32 = 0,
    col: u32 = 0,
};

/// A rename the server has worked out but nobody has performed.
///
/// Named rather than anonymous because the code that carries it out is
/// the only thing in this file's blast radius that WRITES to a repo —
/// and a mutation that big should not be reached through `anytype`.
pub const RenameEdit = struct {
    /// The file the question was asked from, owned. Where the report
    /// goes; it is not necessarily one of the files being edited.
    path: []const u8,
    /// The new name, owned; for the report.
    symbol: []const u8,
    files: []lsp.FileEdits,
    /// The server also wants to create, rename or delete a file. See
    /// lsp.Event.WorkspaceEdit — the app refuses the whole edit on this.
    file_ops: bool,
};

pub const Answer = union(enum) {
    /// Hover text for `path`. Owned by the caller.
    hover: struct { path: []const u8, text: []const u8 },
    /// Where the definition is. Owned by the caller.
    definition: struct { path: []const u8, target: []const u8, line: u32, col: u32 },
    /// Every use of a symbol. Owned by the caller, sites and all.
    references: struct { path: []const u8, symbol: []const u8, sites: []Site },
    /// The edits a rename needs, across every file it touches. Owned by
    /// the caller, and NOT yet applied — this is the server's proposal,
    /// and whether it can be carried out is the app's question.
    rename: RenameEdit,
    /// What could be typed at the cursor. Owned by the caller.
    ///
    /// `prefix` is the word the request was made for, carried back so
    /// the editor can tell an answer to what you are typing NOW from
    /// one to what you were typing two keystrokes ago — the round trip
    /// is long enough for that to be a different question.
    completion: struct { path: []const u8, prefix: []const u8, items: []lsp.Completion },
    /// How the file should be laid out. Owned by the caller.
    ///
    /// Delivered even when it is EMPTY — a caller that asked in order
    /// to save afterwards is waiting on this, and "already formatted"
    /// is an answer it has to hear.
    formatting: struct { path: []const u8, edits: []lsp.TextEdit },
    /// What the server offers to do here. Owned by the caller.
    ///
    /// `resolved` marks the answer to a resolve — one action, now with
    /// the edit it was deferring. The caller applies that one rather
    /// than putting it back in a picker it was already chosen from.
    code_actions: struct { path: []const u8, items: []lsp.CodeAction, resolved: bool },
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
            .references => |r| {
                gpa.free(r.path);
                gpa.free(r.symbol);
                for (r.sites) |s| gpa.free(s.path);
                gpa.free(r.sites);
            },
            .rename => |r| {
                gpa.free(r.path);
                gpa.free(r.symbol);
                lsp.freeFileEdits(gpa, r.files);
            },
            .completion => |c| {
                gpa.free(c.path);
                gpa.free(c.prefix);
                lsp.freeCompletions(gpa, c.items);
            },
            .formatting => |f| {
                gpa.free(f.path);
                for (f.edits) |e| gpa.free(e.text);
                gpa.free(f.edits);
            },
            .code_actions => |c| {
                gpa.free(c.path);
                lsp.freeCodeActions(gpa, c.items);
            },
            .none => |n| gpa.free(n.path),
        }
        self.* = .{ .none = .{ .path = "", .kind = .hover } };
    }
};

/// A resolution in flight, or one that came back refused.
///
/// Keyed by (language, root) rather than by file: a resolver is asked
/// what to run for a PROJECT, and every file in that project gets the
/// same answer. Asking again per file would spawn a plugin round trip
/// per keystroke.
const Pending = struct {
    lang: []const u8,
    /// Absolute, owned.
    root: []const u8,
    /// Set when the resolver refused, with its own words — which is the
    /// whole reason this seam exists. "no venv found — run `uv sync`"
    /// is an answer a user can act on; "no language server for this
    /// file" is not.
    err: []const u8 = "",
    /// True once the plugin has been asked, so a second `ensure` on the
    /// same project does not ask again while the first is in flight.
    asked: bool = false,

    fn deinit(self: *Pending, gpa: Allocator) void {
        gpa.free(self.lang);
        gpa.free(self.root);
        if (self.err.len > 0) gpa.free(self.err);
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
    /// The declared languages. Borrowed — the app owns the registry and
    /// reloads it on a config apply, and every `lang` string a server
    /// entry holds points into its arena.
    langs: *const langpkg.Registry,
    /// Why the last `ensure` produced nothing. Read by `ctl lsp` and by
    /// the editor's message, so a silence can say which silence it is.
    why: langpkg.Fault = .undeclared,
    /// Resolutions in flight, and the ones that came back refused.
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    /// Ask a plugin what to run for a project. Set by the app, which
    /// owns the plugin host; null in a headless manager, where a
    /// resolver-backed language simply never resolves.
    resolve_ctx: ?*anyopaque = null,
    resolve: ?*const fn (*anyopaque, plugin: []const u8, lang: []const u8, root: []const u8) void = null,

    pub fn init(gpa: Allocator, io: std.Io, langs: *const langpkg.Registry) Manager {
        return .{ .gpa = gpa, .io = io, .langs = langs };
    }

    pub fn deinit(self: *Manager) void {
        for (self.servers.items) |e| {
            e.srv.deinit();
            self.gpa.free(e.root);
        }
        self.servers.deinit(self.gpa);
        for (self.asks.items) |a| {
            self.gpa.free(a.path);
            self.gpa.free(a.symbol);
        }
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
        for (self.pending.items) |*pd| pd.deinit(self.gpa);
        self.pending.deinit(self.gpa);
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

    /// Why the last `ensure` for a path produced no server. Set on
    /// every call, so `ctl lsp` and the editor's message can say which
    /// of several very different silences this is.
    pub const Why = langpkg.Fault;

    /// The live server for this file, starting one if a declared
    /// language claims it and nothing is running for its root yet.
    ///
    /// null means "carry on without a server", which is always a valid
    /// outcome and is the ordinary one for most files on most machines.
    /// `self.why` says which kind of null it was.
    pub fn ensure(self: *Manager, path: []const u8) ?*lsp.Server {
        self.why = .undeclared;
        if (!self.enabled) return null;
        const spec = self.langs.forPath(path) orelse return null;

        // No marker found is not a failure: a scratch file outside any
        // project still deserves a server, rooted at the repository if
        // there is one and at its own directory if there is not.
        var rbuf: [1024]u8 = undefined;
        const root = langpkg.rootFor(spec, path, &rbuf) orelse self.fallbackRoot(path, &rbuf) orelse return null;

        for (self.servers.items) |e| {
            if (std.mem.eql(u8, e.lang, spec.name) and std.mem.eql(u8, e.root, root)) {
                // A server that died is not reused, and not restarted
                // here either: a crash loop that respawns on every
                // keystroke is worse than a dead server.
                if (e.srv.state() == .failed) {
                    self.why = .no_binary;
                    return null;
                }
                return e.srv;
            }
        }
        if (self.servers.items.len >= max_servers) return null;

        // A resolver answers out of band. The first call kicks it off
        // and reports `resolving`; the answer arrives frames later and
        // starts the server, and whatever asks next finds it running.
        // ensure() runs under the draw lock, so it may not wait here.
        if (spec.resolver.len > 0) return self.viaResolver(spec, root);

        var store: [1024]u8 = undefined;
        var parts: [8][]const u8 = undefined;
        const argv = langpkg.resolveArgv(spec.argv, root, &store, &parts) orelse {
            self.why = .no_binary;
            return null;
        };
        return self.startLocked(spec.name, root, argv, spec.settings);
    }

    /// Start, or wait on, a plugin-resolved server for this project.
    ///
    /// Always returns null: resolution is a round trip to another
    /// process and `ensure` is called under the draw lock, so the
    /// answer cannot be waited for here. The frame loop re-attaches
    /// when it lands, which is the same path a server that took a
    /// second to start already takes.
    fn viaResolver(self: *Manager, spec: *const langpkg.Spec, root: []const u8) ?*lsp.Server {
        for (self.pending.items) |pd| {
            if (!std.mem.eql(u8, pd.lang, spec.name)) continue;
            if (!std.mem.eql(u8, pd.root, root)) continue;
            // Already refused. Reported as the refusal rather than as a
            // fresh attempt: a plugin that said "no interpreter here"
            // will say it again, and asking on every keystroke turns a
            // clear message into a spawn loop.
            self.why = if (pd.err.len > 0) .refused else .resolving;
            return null;
        }
        const lang = self.gpa.dupe(u8, spec.name) catch return null;
        const owned = self.gpa.dupe(u8, root) catch {
            self.gpa.free(lang);
            return null;
        };
        self.pending.append(self.gpa, .{ .lang = lang, .root = owned, .asked = true }) catch {
            self.gpa.free(lang);
            self.gpa.free(owned);
            return null;
        };
        self.why = .resolving;
        if (self.resolve) |f| f(self.resolve_ctx.?, spec.resolver, spec.name, root);
        return null;
    }

    /// A resolver answered: start the server it named.
    ///
    /// `argv` empty with an `err` is a refusal, and it is kept — the
    /// message is the answer, and the next ask reports it rather than
    /// spawning the plugin again.
    pub fn resolved(
        self: *Manager,
        lang: []const u8,
        root: []const u8,
        argv: []const []const u8,
        settings: []const u8,
        err: []const u8,
    ) void {
        var slot: ?*Pending = null;
        for (self.pending.items) |*pd| {
            if (std.mem.eql(u8, pd.lang, lang) and std.mem.eql(u8, pd.root, root)) {
                slot = pd;
                break;
            }
        }
        // An answer to a question nobody asked — a plugin volunteering,
        // or a config reload having dropped the language underneath it.
        const pd = slot orelse return;

        if (argv.len == 0) {
            if (pd.err.len > 0) self.gpa.free(pd.err);
            pd.err = self.gpa.dupe(u8, if (err.len > 0) err else "the resolver named no server") catch "";
            return;
        }
        // The declaration is still the authority on the NAME: a
        // resolver says what to run, not what language this is.
        const spec = self.langs.byName(lang) orelse return;
        var store: [1024]u8 = undefined;
        var parts: [8][]const u8 = undefined;
        const resolved_argv = langpkg.resolveArgv(argv, root, &store, &parts) orelse {
            if (pd.err.len > 0) self.gpa.free(pd.err);
            pd.err = std.fmt.allocPrint(self.gpa, "{s} is not installed", .{argv[0]}) catch "";
            return;
        };
        if (self.startLocked(spec.name, root, resolved_argv, settings) != null) {
            // The question has been answered and the server is running.
            // Leaving the entry behind would have `ctl lsp` reporting a
            // resolution in flight for a project that already has one.
            for (self.pending.items, 0..) |*e, i| {
                if (e == pd) {
                    var gone = self.pending.orderedRemove(i);
                    gone.deinit(self.gpa);
                    break;
                }
            }
        }
    }

    /// Forget every resolution. Called on a config reload, because the
    /// declarations a refusal was made against may be gone.
    pub fn forgetResolutions(self: *Manager) void {
        for (self.pending.items) |*pd| pd.deinit(self.gpa);
        self.pending.clearRetainingCapacity();
    }

    /// The resolver's own words about why this project has no server,
    /// or "" — what an editor puts in the status row instead of the
    /// generic sentence.
    pub fn refusal(self: *const Manager, path: []const u8) []const u8 {
        const spec = self.langs.forPath(path) orelse return "";
        var rbuf: [1024]u8 = undefined;
        const root = langpkg.rootFor(spec, path, &rbuf) orelse return "";
        for (self.pending.items) |pd| {
            if (std.mem.eql(u8, pd.lang, spec.name) and std.mem.eql(u8, pd.root, root)) return pd.err;
        }
        return "";
    }

    /// Where a file's project is when no marker says. The repository,
    /// else the file's own directory — never the filesystem root, which
    /// would index a home directory.
    fn fallbackRoot(self: *Manager, path: []const u8, buf: *[1024]u8) ?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse return null;
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

    /// Spawn and record. `argv` and `settings` are borrowed and used
    /// before this returns.
    fn startLocked(
        self: *Manager,
        lang: []const u8,
        root: []const u8,
        argv: []const []const u8,
        settings: []const u8,
    ) ?*lsp.Server {
        const owned_root = self.gpa.dupe(u8, root) catch return null;
        const srv = lsp.Server.start(self.gpa, argv, root, settings) orelse {
            self.gpa.free(owned_root);
            self.why = .no_binary;
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

    fn recordAsk(self: *Manager, id: u32, kind: AskKind, path: []const u8, symbol: []const u8) void {
        if (self.asks.items.len >= max_asks) {
            const old = self.asks.orderedRemove(0);
            self.gpa.free(old.path);
            self.gpa.free(old.symbol);
        }
        const owned = self.gpa.dupe(u8, path) catch return;
        const sym = self.gpa.dupe(u8, symbol) catch {
            self.gpa.free(owned);
            return;
        };
        self.asks.append(self.gpa, .{ .id = id, .kind = kind, .path = owned, .symbol = sym }) catch {
            self.gpa.free(owned);
            self.gpa.free(sym);
        };
    }

    pub fn hover(self: *Manager, path: []const u8, pos: lsp.Position) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.hover(path, pos) orelse return false;
        self.recordAsk(id, .hover, path, "");
        return true;
    }

    pub fn definition(self: *Manager, path: []const u8, pos: lsp.Position) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.definition(path, pos) orelse return false;
        self.recordAsk(id, .definition, path, "");
        return true;
    }

    /// `symbol` is only ever a label — the server answers from the
    /// POSITION, so a caller with nothing to name may pass "".
    pub fn references(self: *Manager, path: []const u8, pos: lsp.Position, symbol: []const u8) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.references(path, pos, true) orelse return false;
        self.recordAsk(id, .references, path, symbol);
        return true;
    }

    /// Ask what can be done about `range` in `path`.
    ///
    /// The diagnostics context is built HERE, from what the server
    /// itself published, rather than from the editor's converted copy:
    /// these go back on the wire, so they have to be the server's own
    /// UTF-16 columns, and round-tripping them through the buffer's
    /// byte columns and back is a conversion that can only lose.
    pub fn codeAction(self: *Manager, path: []const u8, range: lsp.Range) bool {
        const srv = self.ensure(path) orelse return false;
        // Only the diagnostics the range touches. A server handed every
        // diagnostic in the file offers fixes for lines you are not
        // looking at.
        var overlapping: std.ArrayListUnmanaged(lsp.Diagnostic) = .empty;
        defer overlapping.deinit(self.gpa);
        for (self.diagsFor(path)) |d| {
            if (d.range.end.line < range.start.line) continue;
            if (d.range.start.line > range.end.line) continue;
            overlapping.append(self.gpa, d) catch break;
        }
        const id = srv.codeAction(path, range, overlapping.items) orelse return false;
        self.recordAsk(id, .code_action, path, "");
        return true;
    }

    /// Ask for the edit an action deferred. `raw` is that action, as it
    /// arrived — see lsp.Session.codeActionResolve.
    pub fn codeActionResolve(self: *Manager, path: []const u8, raw: []const u8) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.codeActionResolve(raw) orelse return false;
        self.recordAsk(id, .code_action_resolve, path, "");
        return true;
    }

    pub fn formatting(self: *Manager, path: []const u8, tab_size: u32, spaces: bool) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.formatting(path, tab_size, spaces) orelse return false;
        self.recordAsk(id, .formatting, path, "");
        return true;
    }

    /// `prefix` is the partial word being completed; it comes back on
    /// the answer, unused by anything in between.
    pub fn completion(self: *Manager, path: []const u8, pos: lsp.Position, prefix: []const u8) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.completion(path, pos) orelse return false;
        self.recordAsk(id, .completion, path, prefix);
        return true;
    }

    /// Here `symbol` is not decoration: it is the NEW name, and it comes
    /// back on the answer so the report can say what was renamed to what
    /// without the app holding state across the round trip.
    pub fn rename(self: *Manager, path: []const u8, pos: lsp.Position, new_name: []const u8) bool {
        const srv = self.ensure(path) orelse return false;
        const id = srv.rename(path, pos, new_name) orelse return false;
        self.recordAsk(id, .rename, path, new_name);
        return true;
    }

    fn takeAsk(self: *Manager, id: u32) ?Ask {
        for (self.asks.items, 0..) |a, i| {
            if (a.id == id) return self.asks.orderedRemove(i);
        }
        return null;
    }

    /// An Ask owns two strings, and the arm that took it owns both.
    fn freeAsk(self: *Manager, a: Ask) void {
        self.gpa.free(a.path);
        self.gpa.free(a.symbol);
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
                        defer self.freeAsk(ask);
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
                        defer self.freeAsk(ask);
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
                    .references => |r| {
                        const ask = self.takeAsk(r.id) orelse continue;
                        defer self.freeAsk(ask);
                        // An empty list is "nobody uses this", which is
                        // an ANSWER — but the caller is released by the
                        // .empty the session pushes instead, so there is
                        // nothing here to deliver.
                        if (r.locs.len == 0) continue;
                        const sites = self.gpa.alloc(Site, r.locs.len) catch continue;
                        var n: usize = 0;
                        for (r.locs) |l| {
                            const p = self.gpa.dupe(u8, l.path) catch continue;
                            sites[n] = .{ .path = p, .line = l.range.start.line, .col = l.range.start.col };
                            n += 1;
                        }
                        const kept = self.gpa.realloc(sites, n) catch sites[0..n];
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            for (kept) |s| self.gpa.free(s.path);
                            self.gpa.free(kept);
                            continue;
                        };
                        const sym = self.gpa.dupe(u8, ask.symbol) catch {
                            for (kept) |s| self.gpa.free(s.path);
                            self.gpa.free(kept);
                            self.gpa.free(p);
                            continue;
                        };
                        self.pushAnswer(.{ .references = .{ .path = p, .symbol = sym, .sites = kept } });
                        changed = true;
                    },
                    .workspace_edit => |we| {
                        const ask = self.takeAsk(we.id) orelse continue;
                        defer self.freeAsk(ask);
                        const files = dupeFileEdits(self.gpa, we.files) orelse continue;
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            lsp.freeFileEdits(self.gpa, files);
                            continue;
                        };
                        const sym = self.gpa.dupe(u8, ask.symbol) catch {
                            lsp.freeFileEdits(self.gpa, files);
                            self.gpa.free(p);
                            continue;
                        };
                        self.pushAnswer(.{ .rename = .{
                            .path = p,
                            .symbol = sym,
                            .files = files,
                            .file_ops = we.file_ops,
                        } });
                        changed = true;
                    },
                    .completion => |c| {
                        const ask = self.takeAsk(c.id) orelse continue;
                        defer self.freeAsk(ask);
                        const items = dupeCompletions(self.gpa, c.items) orelse continue;
                        // The SERVER's ranking, applied here so every
                        // consumer gets it. sortText is the only signal
                        // that knows what the cursor is inside of; a
                        // menu sorted alphabetically instead puts
                        // `Abs` above the field you were reaching for.
                        std.mem.sort(lsp.Completion, items, {}, completionLess);
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            lsp.freeCompletions(self.gpa, items);
                            continue;
                        };
                        const pre = self.gpa.dupe(u8, ask.symbol) catch {
                            lsp.freeCompletions(self.gpa, items);
                            self.gpa.free(p);
                            continue;
                        };
                        self.pushAnswer(.{ .completion = .{ .path = p, .prefix = pre, .items = items } });
                        changed = true;
                    },
                    .formatting => |fe| {
                        const ask = self.takeAsk(fe.id) orelse continue;
                        defer self.freeAsk(ask);
                        // The reply names no file — a formatting result
                        // is a bare TextEdit[]. The ASK knows which
                        // file it was about, and it is the only thing
                        // that does.
                        const src: []const lsp.TextEdit = if (fe.files.len > 0) fe.files[0].edits else &.{};
                        const edits = self.gpa.alloc(lsp.TextEdit, src.len) catch continue;
                        var n: usize = 0;
                        for (src) |te| {
                            edits[n] = .{
                                .range = te.range,
                                .text = self.gpa.dupe(u8, te.text) catch break,
                            };
                            n += 1;
                        }
                        if (n != src.len) {
                            // All or nothing: half a format is a file
                            // laid out two ways.
                            for (edits[0..n]) |te| self.gpa.free(te.text);
                            self.gpa.free(edits);
                            continue;
                        }
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            for (edits) |te| self.gpa.free(te.text);
                            self.gpa.free(edits);
                            continue;
                        };
                        self.pushAnswer(.{ .formatting = .{ .path = p, .edits = edits } });
                        changed = true;
                    },
                    .code_actions => |ca| {
                        const ask = self.takeAsk(ca.id) orelse continue;
                        defer self.freeAsk(ask);
                        const items = dupeCodeActions(self.gpa, ca.items) orelse continue;
                        const p = self.gpa.dupe(u8, ask.path) catch {
                            lsp.freeCodeActions(self.gpa, items);
                            continue;
                        };
                        self.pushAnswer(.{ .code_actions = .{
                            .path = p,
                            .items = items,
                            .resolved = ca.resolved,
                        } });
                        changed = true;
                    },
                    .empty => |x| {
                        const ask = self.takeAsk(x.id) orelse continue;
                        defer self.freeAsk(ask);
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

    /// sortText, then label to break a tie — servers hand out equal
    /// keys freely, and an unstable order makes the same completion
    /// land in a different row each time you ask.
    fn completionLess(_: void, a: lsp.Completion, b: lsp.Completion) bool {
        const c = std.mem.order(u8, a.sort, b.sort);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, a.label, b.label) == .lt;
    }

    /// Deep-copy a Completion list out of the event that owns it.
    fn dupeCompletions(gpa: Allocator, src: []const lsp.Completion) ?[]lsp.Completion {
        const out = gpa.alloc(lsp.Completion, src.len) catch return null;
        var n: usize = 0;
        for (src) |c| {
            const label = gpa.dupe(u8, c.label) catch break;
            const detail = gpa.dupe(u8, c.detail) catch {
                gpa.free(label);
                break;
            };
            const insert = gpa.dupe(u8, c.insert) catch {
                gpa.free(label);
                gpa.free(detail);
                break;
            };
            const sort = gpa.dupe(u8, c.sort) catch {
                gpa.free(label);
                gpa.free(detail);
                gpa.free(insert);
                break;
            };
            out[n] = .{
                .label = label,
                .detail = detail,
                .insert = insert,
                .range = c.range,
                .sort = sort,
                .kind = c.kind,
            };
            n += 1;
        }
        // A SHORT list is fine here, unlike a workspace edit's: missing
        // a completion offers you less, where missing an edit corrupts
        // a repo. Nothing is lost that the next keystroke cannot ask
        // for again.
        return gpa.realloc(out, n) catch out[0..n];
    }

    /// Deep-copy code actions out of the event that owns them. All or
    /// nothing per action: one missing its edit is one that does
    /// nothing when picked, which is worse than one not offered.
    fn dupeCodeActions(gpa: Allocator, src: []const lsp.CodeAction) ?[]lsp.CodeAction {
        const out = gpa.alloc(lsp.CodeAction, src.len) catch return null;
        var n: usize = 0;
        while (n < src.len) : (n += 1) {
            const a = src[n];
            const title = gpa.dupe(u8, a.title) catch break;
            const kind = gpa.dupe(u8, a.kind) catch {
                gpa.free(title);
                break;
            };
            const raw = gpa.dupe(u8, a.raw) catch {
                gpa.free(title);
                gpa.free(kind);
                break;
            };
            const edit = if (a.edit.len == 0)
                @as([]lsp.FileEdits, &.{})
            else
                lsp.dupeFileEdits(gpa, a.edit) orelse {
                    gpa.free(title);
                    gpa.free(kind);
                    gpa.free(raw);
                    break;
                };
            out[n] = .{
                .title = title,
                .kind = kind,
                .edit = edit,
                .file_ops = a.file_ops,
                .raw = raw,
                .deferred = a.deferred,
                .command_only = a.command_only,
            };
        }
        if (n != src.len) {
            for (out[0..n]) |a| {
                gpa.free(a.title);
                gpa.free(a.kind);
                gpa.free(a.raw);
                lsp.freeFileEdits(gpa, a.edit);
            }
            gpa.free(out);
            return null;
        }
        return out;
    }

    /// Deep-copy a WorkspaceEdit out of the event that owns it.
    ///
    /// lsp.zig owns the logic — the palette needs the same copy, and a
    /// second implementation of "all or nothing" is a second place a
    /// partial edit can escape from.
    fn dupeFileEdits(gpa: Allocator, src: []const lsp.FileEdits) ?[]lsp.FileEdits {
        return lsp.dupeFileEdits(gpa, src);
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
                e.lang, @tagName(e.srv.state()), e.root,
            }) catch return;
        }
        // Declared languages that have not produced a server, and why.
        // "nothing happened" is the one answer a user cannot act on,
        // and with no built-in catalog the commonest reason for silence
        // is now a language nobody declared.
        for (self.pending.items) |pd| {
            if (pd.err.len > 0) {
                w.print("language {s} refused {s} — {s}\n", .{ pd.lang, pd.root, pd.err }) catch return;
            } else w.print("language {s} resolving {s}\n", .{ pd.lang, pd.root }) catch return;
        }
        for (self.langs.specs) |spec| {
            var running = false;
            for (self.servers.items) |e| {
                if (std.mem.eql(u8, e.lang, spec.name)) running = true;
            }
            if (running) continue;
            var waiting = false;
            for (self.pending.items) |pd| {
                if (std.mem.eql(u8, pd.lang, spec.name)) waiting = true;
            }
            if (waiting) continue;
            if (spec.resolver.len > 0) {
                w.print("language {s} declared resolver:{s}\n", .{ spec.name, spec.resolver }) catch return;
            } else w.print("language {s} declared {s}\n", .{ spec.name, spec.argv[0] }) catch return;
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

// The routing that used to live here is language.zig's now, and so are
// its tests: extension to language, the marker walk, the binary search.
// What is left to test in THIS file is what the manager does with the
// answers — which is mostly about declining to do anything.

/// A manager over a registry loaded from one graph. The registry has to
/// outlive the manager, which is why these come in pairs.
const Rig = struct {
    langs: langpkg.Registry,
    mgr: Manager,

    fn init(gpa: Allocator, graph: []const u8) *Rig {
        const r = gpa.create(Rig) catch unreachable;
        r.* = .{ .langs = langpkg.Registry.init(gpa), .mgr = undefined };
        r.langs.loadFromJson(graph);
        r.mgr = Manager.init(gpa, testing.io, &r.langs);
        return r;
    }

    fn deinit(self: *Rig, gpa: Allocator) void {
        self.mgr.deinit();
        self.langs.deinit();
        gpa.destroy(self);
    }
};

test "with nothing declared, nothing is a language" {
    const gpa = testing.allocator;
    // The default state of a rook with no config, and the whole point
    // of there being no built-ins: rook has no opinion about which
    // languages exist until something says so.
    const r = Rig.init(gpa, "{\"nodes\":[]}");
    defer r.deinit(gpa);
    try testing.expect(r.mgr.ensure("/tmp/x.go") == null);
    try testing.expectEqual(langpkg.Fault.undeclared, r.mgr.why);
    try testing.expect(!r.mgr.hover("/tmp/x.go", .{}));
}

test "a declared language whose server is not installed says so" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:go","kind":"language","scope":"app","name":"go",
        \\"ext":[".go"],"roots":["go.mod"],"command":["rook-not-a-real-server"]}]}
    );
    defer r.deinit(gpa);
    try testing.expect(r.mgr.ensure("/tmp/x.go") == null);
    // NOT `undeclared`. The two are different problems with different
    // fixes — one is a config edit, the other is an install — and the
    // whole reason `why` exists is that they used to be one silence.
    try testing.expectEqual(langpkg.Fault.no_binary, r.mgr.why);
}

const ResolveProbe = struct {
    asked: usize = 0,
    last_plugin: [64]u8 = undefined,
    last_len: usize = 0,

    fn hook(ctx: *anyopaque, plugin: []const u8, lang: []const u8, root: []const u8) void {
        const self: *ResolveProbe = @ptrCast(@alignCast(ctx));
        _ = lang;
        _ = root;
        self.asked += 1;
        self.last_len = @min(plugin.len, self.last_plugin.len);
        @memcpy(self.last_plugin[0..self.last_len], plugin[0..self.last_len]);
    }

    fn pluginName(self: *const ResolveProbe) []const u8 {
        return self.last_plugin[0..self.last_len];
    }
};

test "a resolver is asked once per project, not once per keystroke" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:python","kind":"language","scope":"app","name":"python",
        \\"ext":[".py"],"resolver":"lang-python"}]}
    );
    defer r.deinit(gpa);
    var probe: ResolveProbe = .{};
    r.mgr.resolve_ctx = &probe;
    r.mgr.resolve = &ResolveProbe.hook;

    try testing.expect(r.mgr.ensure("/tmp/proj/a.py") == null);
    try testing.expectEqual(langpkg.Fault.resolving, r.mgr.why);
    try testing.expectEqual(@as(usize, 1), probe.asked);
    try testing.expectEqualStrings("lang-python", probe.pluginName());

    // Every later ask for the same project waits on the answer in
    // flight. Asking again per file would spawn a round trip per
    // keystroke, which is how a resolver becomes a fork bomb.
    try testing.expect(r.mgr.ensure("/tmp/proj/a.py") == null);
    try testing.expect(r.mgr.ensure("/tmp/proj/b.py") == null);
    try testing.expectEqual(@as(usize, 1), probe.asked);
    try testing.expectEqual(langpkg.Fault.resolving, r.mgr.why);
}

test "a refusal is kept, and reported in the resolver's own words" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:python","kind":"language","scope":"app","name":"python",
        \\"ext":[".py"],"resolver":"lang-python"}]}
    );
    defer r.deinit(gpa);
    var probe: ResolveProbe = .{};
    r.mgr.resolve_ctx = &probe;
    r.mgr.resolve = &ResolveProbe.hook;

    _ = r.mgr.ensure("/tmp/proj/a.py");
    r.mgr.resolved("python", "/tmp/proj", &.{}, "", "no interpreter — run `uv sync`");

    try testing.expect(r.mgr.ensure("/tmp/proj/a.py") == null);
    try testing.expectEqual(langpkg.Fault.refused, r.mgr.why);
    // The message is the answer. "no language server for this file" is
    // a sentence nobody can act on; this one names the fix.
    try testing.expectEqualStrings("no interpreter — run `uv sync`", r.mgr.refusal("/tmp/proj/a.py"));
    // And it is NOT retried: a plugin that said no will say no again,
    // and asking on every keystroke turns a message into a spawn loop.
    try testing.expectEqual(@as(usize, 1), probe.asked);
}

test "a resolver naming a binary that is not there refuses with its name" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:python","kind":"language","scope":"app","name":"python",
        \\"ext":[".py"],"resolver":"lang-python"}]}
    );
    defer r.deinit(gpa);
    var probe: ResolveProbe = .{};
    r.mgr.resolve_ctx = &probe;
    r.mgr.resolve = &ResolveProbe.hook;

    _ = r.mgr.ensure("/tmp/proj/a.py");
    r.mgr.resolved("python", "/tmp/proj", &.{"rook-no-such-pyright"}, "", "");
    try testing.expect(r.mgr.ensure("/tmp/proj/a.py") == null);
    try testing.expectEqual(langpkg.Fault.refused, r.mgr.why);
    try testing.expect(std.mem.indexOf(u8, r.mgr.refusal("/tmp/proj/a.py"), "rook-no-such-pyright") != null);
}

test "an answer nobody asked for is dropped" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:python","kind":"language","scope":"app","name":"python",
        \\"ext":[".py"],"resolver":"lang-python"}]}
    );
    defer r.deinit(gpa);
    // A plugin volunteering, or a config reload having dropped the
    // project underneath one in flight. Neither may start a server.
    r.mgr.resolved("python", "/tmp/never-asked", &.{"/bin/sh"}, "", "");
    try testing.expectEqual(@as(usize, 0), r.mgr.servers.items.len);
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

test "a manager turned off stays silent even with a language declared" {
    const gpa = testing.allocator;
    const r = Rig.init(gpa,
        \\{"nodes":[{"id":"language:go","kind":"language","scope":"app","name":"go",
        \\"ext":[".go"],"command":["/bin/sh"]}]}
    );
    defer r.deinit(gpa);
    r.mgr.enabled = false;
    try testing.expect(r.mgr.ensure("/tmp/x.go") == null);
    try testing.expect(!r.mgr.hover("/tmp/x.go", .{}));
    try testing.expect(!r.mgr.drain());
    try testing.expectEqual(@as(usize, 0), r.mgr.diagsFor("/tmp/x.go").len);
}
