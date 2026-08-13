//! e2e scenarios — `make e2e`, or `make e2e ARGS=splits` for one.
//!
//! Each scenario gets a fresh sandboxed instance (own socket, config,
//! state) and is responsible for closing it. Scenarios abort at their
//! first failed assertion, because their state is sequential and every
//! later assertion would just report the same cause again.
//!
//! What belongs here: things an agent would otherwise have to ask a
//! human to eyeball. What does NOT belong here: anything already
//! covered by `zig build test` — rope/editor/paste/config are pure
//! models with headless suites, and they run in CI where this cannot.

const std = @import("std");
const h = @import("harness.zig");
extern "c" fn getpid() c_int;
const lsp = @import("lsp");

const Scenario = struct {
    name: []const u8,
    what: []const u8,
    run: *const fn (std.mem.Allocator, []const u8) anyerror!void,
    /// A bench prints numbers rather than guarding behavior; it runs
    /// only when named explicitly (`make e2e ARGS=startup`), never in
    /// the default all-scenarios pass — 8 sequential app launches are
    /// measurement, not coverage.
    bench: bool = false,
};

const scenarios = [_]Scenario{
    .{ .name = "boot", .what = "one pane, one tab, a live shell", .run = boot },
    .{ .name = "echo", .what = "typed command reaches the pty and echoes back", .run = echo },
    .{ .name = "splits", .what = "split right, focus moves, close returns", .run = splits },
    .{ .name = "tabs", .what = "new tab, cycle, pane counts stay separate", .run = tabs },
    .{ .name = "editor", .what = "edit a file, change it, :w reaches disk", .run = editor },
    .{ .name = "intro", .what = "bare `re`: the start screen shows, a keystroke retires it, :w names the scratch", .run = intro },
    .{ .name = "indent", .what = "o inherits the indent, >> shifts, and neither leaves whitespace", .run = indent },
    .{ .name = "vim", .what = "regex :s, a macro, a block edit and `.` all reach disk", .run = vim },
    .{ .name = "wide", .what = "CJK text lays out two cells wide and motions still land", .run = wideText },
    .{ .name = "grapheme", .what = "a cluster is one character to move over and to delete", .run = graphemes },
    .{ .name = "termglyph", .what = "a terminal pane shapes clusters too, not just the editor", .run = termGlyph },
    .{ .name = "clobber", .what = ":w refuses a file an agent changed underneath it", .run = clobber },
    .{ .name = "reload", .what = "an open buffer follows the file, or says it can't", .run = reload },
    .{ .name = "pixels", .what = "the renderer actually drew (shot, decoded)", .run = pixels },
    .{ .name = "commands", .what = "registry lists, runs by name, and drives the ⌘K palette", .run = commands },
    .{ .name = "whichkey", .what = "an unanswered leader reveals the key menu; rows and bar hints click", .run = whichkey },
    .{ .name = "statusbar", .what = "the bar knows where you are: cwd + branch follow the pane, segments click", .run = statusbar },
    .{ .name = "worktrees", .what = "worktree add carves a checkout git can see, remove refuses unmerged and dirty, then lets go", .run = worktrees },
    .{ .name = "cli", .what = "the binary is its own ctl client: rook <verb> answers, err exits 1, a file opens", .run = cli },
    .{ .name = "filetree", .what = "the tree takes over a pane, folds in place, reveals the current file, toggles back", .run = filetree },
    .{ .name = "bufline", .what = "the buffer line: documents chip up, :b/:bn switch, a chip click lands blind", .run = bufline },
    .{ .name = "monitor", .what = "the resource monitor: live rows, disk classifies, keep refuses deletion", .run = monitor },
    .{ .name = "excmd", .what = "the editor's : reaches the registry (:PaneSplitRight)", .run = excmd },
    .{ .name = "sidepane", .what = "side pane retiles the grid and flips edges", .run = sidepane },
    .{ .name = "quitall", .what = ":qa reaches every editor pane and leaves the terminals alone", .run = quitAll },
    .{ .name = "plugins", .what = "declared plugins spawn lazily, answer over the wire, and are refused what config did not grant", .run = plugins },
    .{ .name = "envgraph", .what = "environment.json wins: the graph's leader and chords drive, config.toml yields", .run = envgraph },
    .{ .name = "configdir", .what = "--config=DIR: one directory is the whole config, and the XDG one is not read", .run = configDir },
    .{ .name = "apply", .what = "config is a program: rook runs it, shows the diff, and applies nothing until told", .run = applyScenario },
    .{ .name = "setup", .what = "a rook with nothing configured asks, writes a starter, and opens it in the editor", .run = setupScenario },
    .{ .name = "crash", .what = "a crash writes its record, and the next launch says so", .run = crashScenario },
    .{ .name = "pluginfetch", .what = "a plugin declared by source downloads itself on first use — no path in config", .run = pluginFetch },
    .{ .name = "claudewatch", .what = "the claude watcher: sessions are items with honest states, and a finished turn raises attention", .run = claudeWatch },
    .{ .name = "chrome", .what = "the personas: preset arrangements drive both bars, tabs live in the status bar and click", .run = chrome },
    .{ .name = "presetparity", .what = "a TOML preset and the SDK's expanded graph land the identical chrome", .run = presetParity },
    .{ .name = "filefinder", .what = "⌘P: the repo's files ranked, nested .gitignores honoured, Enter opens here", .run = fileFinder },
    .{ .name = "explorerauto", .what = "explorer-auto: the sidebar opens at launch inside a repo, and never takes the keys", .run = explorerAuto },
    .{ .name = "lsp", .what = "language server: diagnostics, gr lists uses, gR renames, ctrl-n completes", .run = lspScenario },
    .{ .name = "lspaction", .what = "ga: the server's offers in a picker — one applies, one resolves first, one is refused", .run = lspAction },
    .{ .name = "lspformat", .what = "format-on-save: :w formats then writes, and writes anyway when nothing answers", .run = lspFormat },
    .{ .name = "lsppython", .what = "a second language is data: python roots at pyproject.toml and lands the same way", .run = lspPython },
    .{ .name = "lspts", .what = "ts and tsx share one server, root at the tsconfig, and split only on the grammar", .run = lspTs },
    .{ .name = "suggest", .what = "the menu appears as you type, narrows, never writes, and Tab takes it", .run = suggestScenario },
    .{ .name = "lsplang", .what = "no built-in catalog: a language is a declaration, and each way of having no server says which one it is", .run = lspLang },
    .{ .name = "lspretarget", .what = "a pane that retargets ITSELF — file tree, :e — still gets its server, and drops it when there is none", .run = lspRetarget },
    .{ .name = "lspwatch", .what = "the server registers file watchers, and a write rook never made is heard — filtered by glob and by kind", .run = lspWatch },
    .{ .name = "progress", .what = "OSC 9;4: a program's progress reaches the pane list and the tab's chip, and remove clears it", .run = progressScenario },
    .{ .name = "docshare", .what = "one file in two panes is ONE document: edits, dirty flag and :w are shared", .run = docShare },
    .{ .name = "findfiles", .what = "⌘⇧F: scan honours the ignore rules, results group by file, Enter jumps to the line", .run = findInFiles },
    .{ .name = "vscodefeel", .what = "the vscode persona feels right: insert on open, cmd-s saves, the rail's explorer opens the tree", .run = vscodeFeel },
    .{ .name = "keys", .what = "shift+Tab reaches the pty as CSI Z, and ⌃HJKL yields by program rather than by alternate screen", .run = keys },
    .{ .name = "panedim", .what = "pane-dim: the unfocused pane fades toward its background, and the fade follows focus", .run = paneDim },
    .{ .name = "panelwrap", .what = "a child row wraps as prose, and the side pane's divider drags wider", .run = panelWrap },
    .{ .name = "panelfold", .what = "children fold into the selected group, the list scrolls to the selection, and a click selects", .run = panelFold },
    .{ .name = "startup", .what = "bench: launch → ctl-ready → shell, with in-app phase timings", .run = startup, .bench = true },
};

// ---------------------------------------------------------------- boot

fn boot(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectEq("panes", 1, try app.paneCount());
    try h.expectEq("tabs", 1, try app.tabCount());
    // start() already proved the shell answers; this pins the prompt so a
    // regression in PS1 handling or pty setup shows up here rather than
    // as a mystery timeout in every other scenario.
    var buf: [64 * 1024]u8 = undefined;
    try h.expectContains(try app.screen(&buf), "e2e$", "prompt");
}

// ---------------------------------------------------------------- keys

/// Two bugs that looked like one, because they were both "a key I
/// pressed did nothing in Claude Code".
///
/// This has to go through `nskey` — a real NSEvent through AppKit's
/// dispatch and our own monitor — because both fixes live in that path.
/// `ctl key` writes bytes straight at the pane and would prove nothing:
/// it starts downstream of the encoder and downstream of the nav check.
fn keys(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // -- shift+Tab is ESC [ Z ------------------------------------------
    //
    // `cat -v` spells what it receives, so the assertion is on the
    // BYTES the pty got rather than on anything drawn. macOS hands
    // shift+Tab over as 0x19 (NSBackTabCharacter), which is what rook
    // used to forward verbatim — `^Y` here would be the old bug.
    _ = try app.ctl("type cat -v");
    _ = try app.ctl("enter");
    h.sleepMs(300);
    // keycode 48 = Tab, modmask 0x20000 = shift. The characters on the
    // event are deliberately the WRONG answer: the encoder works from
    // the keycode, and passing 0x19 here proves it ignores them.
    _ = try app.ctl("nskey 48 20000 \\t");
    _ = try app.ctl("key 0d");
    try app.waitText("^[[Z", 10_000);

    var buf: [64 * 1024]u8 = undefined;
    try h.expectNotContains(try app.screen(&buf), "^Y", "shift+Tab must not arrive as 0x19");
    _ = try app.ctl("key 04"); // ⌃D ends cat
    h.sleepMs(300);

    // -- ⌃HJKL yields by PROGRAM, not by alternate screen --------------
    const first = try app.focusedPane();
    _ = try app.ctl("split right");
    const second = try app.focusedPane();
    try h.expect(second != first, "split should focus the new pane", .{});

    // A full-screen program with no splits of its own: the alternate
    // screen is on, and the foreground program is `sleep`. This is the
    // Claude Code shape, and under the old alt-screen rule ⌃H died here.
    _ = try app.ctl("type printf '\\033[?1049h'; sleep 30");
    _ = try app.ctl("enter");
    h.sleepMs(700);
    // keycode 4 = 'h', modmask 0x40000 = control.
    _ = try app.ctl("nskey 4 40000 h");
    h.sleepMs(400);
    try h.expectEq("⌃H moves focus out of a full-screen program that has no splits", first, try app.focusedPane());

    // And the half the old rule got right, which the new rule has to
    // keep: vim owns ⌃HJKL, because vim has windows of its own to move
    // between. Nothing about the screen says so — only the name does.
    _ = try app.ctl("focus right");
    try h.expectEq("back on the sleeping pane", second, try app.focusedPane());
    _ = try app.ctl("key 03"); // ⌃C ends sleep
    h.sleepMs(300);
    _ = try app.ctl("type vim -u NONE");
    _ = try app.ctl("enter");
    h.sleepMs(1500);
    _ = try app.ctl("nskey 4 40000 h");
    h.sleepMs(400);
    try h.expectEq("⌃H stays inside vim", second, try app.focusedPane());
    _ = try app.ctl("key 1b"); // ESC, then :q!
    _ = try app.ctl("type :q!");
    _ = try app.ctl("key 0d");
}

// ---------------------------------------------------------------- echo

fn echo(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    _ = try app.ctl("type echo hello-from-e2e");
    _ = try app.ctl("enter");
    // Twice: the echoed command line, then the command's output. Waiting
    // for one would pass on the echo alone and prove nothing ran.
    try app.waitTextCount("hello-from-e2e", 2, 10_000);
}

// -------------------------------------------------------------- splits

fn splits(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    const first = try app.focusedPane();

    _ = try app.ctl("split right");
    try h.expectEq("panes after split", 2, try app.paneCount());
    const second = try app.focusedPane();
    try h.expect(second != first, "split should focus the NEW pane (still on {d})", .{first});

    // Focus moves by direction, and back.
    _ = try app.ctl("focus left");
    try h.expectEq("focus left returns to the first pane", first, try app.focusedPane());
    _ = try app.ctl("focus right");
    try h.expectEq("focus right returns to the new pane", second, try app.focusedPane());

    // The new pane is a real shell, not just a rectangle.
    _ = try app.ctlFmt("type@{d} echo split-lives", .{second});
    _ = try app.ctlFmt("enter@{d}", .{second});
    try app.waitTextCount("split-lives", 2, 10_000);

    _ = try app.ctl("close");
    // The shell has to die and be reaped before the tree collapses, and
    // the reap joins the reader thread on a display-link tick. 5s was
    // enough in isolation but failed once on a machine busy with several
    // other rook instances — the budget is arbitrary, the assertion is
    // "eventually one pane", so give it room rather than encode a
    // timing assumption about how loaded the host is.
    var waited: u32 = 0;
    while (waited < 15000 and try app.paneCount() != 1) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq("panes after close", 1, try app.paneCount());
    try h.expectEq("focus back on the survivor", first, try app.focusedPane());
}

// ---------------------------------------------------------------- tabs

fn tabs(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    _ = try app.ctl("tab new");
    try h.expectEq("tabs after new", 2, try app.tabCount());
    // Two tabs, one pane each — `panes` spans every tab, so this also
    // catches a new tab that accidentally inherits the old one's panes.
    try h.expectEq("panes across both tabs", 2, try app.paneCount());

    const on_second = try app.focusedPane();
    _ = try app.ctl("tab prev");
    const on_first = try app.focusedPane();
    try h.expect(on_first != on_second, "tab prev should change the focused pane", .{});
    _ = try app.ctl("tab next");
    try h.expectEq("tab next returns", on_second, try app.focusedPane());
}

// -------------------------------------------------------------- editor

fn editor(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/edit-me.txt", .{app.dirPath()});
    try h.writeFile(path, "alpha\nbravo\ncharlie\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    // TAKEOVER, not a split: the editor overlays the focused pane and the
    // shell parks underneath still running, the way vim does. A pane
    // count of 2 here would mean the takeover regressed into a split.
    try h.expectEq("editor takes over the pane", 1, try app.paneCount());
    try app.waitText("bravo", 5_000);

    // dd on line one, then :w. `type` is the editor's input stream.
    _ = try app.ctl("type dd");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    // The assertion that matters is on DISK, not on screen: a buffer
    // that renders correctly but never writes is the bug worth catching.
    var waited: u32 = 0;
    var content: [256]u8 = undefined;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "alpha") == null and got.len > 0) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expect(std.mem.indexOf(u8, got, "alpha") == null, "dd should have removed the first line, file is: \"{s}\"", .{got});
    try h.expectContains(got, "bravo", "the other lines survive");
    try h.expectContains(got, "charlie", "the other lines survive");

    // The dirty marker is a SAVE POINT, not a "something happened" flag.
    // Type, see [+]; undo back to what is on disk, and it must go —
    // otherwise `:q` refuses a buffer that matches the file, and you
    // learn the `:q!` reflex on a buffer you had no reason to force.
    _ = try app.ctl("type ostray");
    _ = try app.ctl("key 1b"); // esc
    try app.waitText("[+]", 5_000);
    _ = try app.ctl("type u");
    var undone: u32 = 0;
    while (undone < 5000) : (undone += 100) {
        var screen: [64 * 1024]u8 = undefined;
        const s = try app.screen(&screen);
        if (std.mem.indexOf(u8, s, "[+]") == null) break;
        h.sleepMs(100);
    }
    var screen: [64 * 1024]u8 = undefined;
    const after_undo = try app.screen(&screen);
    try h.expect(
        std.mem.indexOf(u8, after_undo, "[+]") == null,
        "undo back to the save point should clear [+], screen still shows it",
        .{},
    );

    // :q drops back to the parked shell — the other half of takeover, and
    // the half that actually loses work if it breaks. It only gets there
    // because the undo above genuinely cleared the dirty state; a stored
    // flag would refuse here.
    _ = try app.ctl("type :q");
    _ = try app.ctl("enter");
    try app.waitText("e2e$", 5_000);
    try h.expectEq("still one pane after :q", 1, try app.paneCount());
}

// --------------------------------------------------------- start screen

/// Bare `re` — vim's own contract: no file means an empty scratch
/// buffer wearing the start screen, not a usage error. The screen
/// retires at the first keystroke, and the buffer under it is real
/// enough that `:w <name>` turns it into a file on disk.
fn intro(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // Bare `edit` over the socket is exactly what a bare `re` sends.
    _ = try app.ctl("edit");
    // Takeover, not a split — the same contract as edit-with-a-file.
    try h.expectEq("editor takes over the pane", 1, try app.paneCount());
    try app.waitText("rook editor", 5_000);
    try app.waitText("[scratch]", 5_000);

    // The first keystroke retires the screen…
    _ = try app.ctl("type i");
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        var buf: [64 * 1024]u8 = undefined;
        const s = try app.screen(&buf);
        if (std.mem.indexOf(u8, s, "rook editor") == null) break;
        h.sleepMs(100);
    }
    var buf: [64 * 1024]u8 = undefined;
    const s = try app.screen(&buf);
    try h.expect(
        std.mem.indexOf(u8, s, "rook editor") == null,
        "a keystroke should retire the start screen",
        .{},
    );

    // …and what is under it is an ordinary unnamed buffer: type into
    // it, then give it a file. The assertion that matters is on disk.
    _ = try app.ctl("type hello from scratch");
    _ = try app.ctl("key 1b");
    try app.waitText("hello from scratch", 5_000);
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/born-of-scratch.txt", .{app.dirPath()});
    _ = try app.ctlFmt("type :w {s}", .{path});
    _ = try app.ctl("enter");
    var content: [256]u8 = undefined;
    waited = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "hello from scratch") != null) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expectContains(got, "hello from scratch", ":w <name> should give the scratch a file");
}

// --------------------------------------------------------------- indent

/// Indentation through the REAL key path, asserted on DISK.
///
/// The unit tests cover the rules; what this catches is the layer
/// between: `>` arriving as a key at all, and — the one that would
/// otherwise ship unnoticed — an abandoned `o` leaving a line of
/// trailing whitespace in the file. That is invisible on screen and
/// obvious in a diff, which is the worst combination.
fn indent(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/indent.txt", .{app.dirPath()});
    try h.writeFile(path, "    alpha\n    bravo\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("bravo", 5_000);

    // `o` on an indented line, then a word: the word keeps the indent.
    // `Gk`, not `G` — the file's trailing newline makes the last line
    // empty, and an empty line has no indent to hand down.
    _ = try app.ctl("type Gkoecho");
    _ = try app.ctl("key 1b");
    // `o` then straight back out: nothing left behind.
    _ = try app.ctl("type o");
    _ = try app.ctl("key 1b");
    // >> on the first line.
    _ = try app.ctl("type gg>>");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    var content: [512]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "echo") != null) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expectContains(got, "        alpha", ">> should have doubled the first line's indent");
    try h.expectContains(got, "    echo", "o should have inherited the indent");
    try h.expect(
        std.mem.indexOf(u8, got, "    \n") == null,
        "an abandoned `o` left trailing whitespace in the file: \"{s}\"",
        .{got},
    );
}

// ------------------------------------------------------------------ vim

/// The editing surface, driven the way someone actually drives it —
/// a capture-swapping substitute, a recorded macro, a rectangular
/// edit, and `.` — with the answer read off DISK rather than off the
/// screen, so nothing here can pass on a render that lied.
fn vim(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/vim.txt", .{app.dirPath()});
    try h.writeFile(path,
        \\alpha=one
        \\beta=two
        \\gamma=three
        \\aaa
        \\bbb
        \\
    );

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("gamma", 5_000);

    // A regex substitute with two captures, swapped.
    _ = try app.ctl("type gg");
    _ = try app.ctl("type :1,3s/\\(\\w\\+\\)=\\(\\w\\+\\)/\\2:\\1/");
    _ = try app.ctl("enter");

    // A macro that appends a marker, recorded on one line and replayed
    // on the next.
    _ = try app.ctl("type 4GqmA!");
    _ = try app.ctl("key 1b");
    _ = try app.ctl("type jq@m");

    // A rectangular insert down the first column of the first two lines.
    _ = try app.ctl("type gg0");
    _ = try app.ctl("key 16"); // ctrl-v
    _ = try app.ctl("type jI> ");
    _ = try app.ctl("key 1b");

    // And `.` repeating the last change — the `x` below, twice.
    _ = try app.ctl("type 3G0x.");

    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    var content: [512]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "one:alpha") != null) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expectContains(got, "> one:alpha", "the substitute or the block insert did not land");
    try h.expectContains(got, "> two:beta", "the block insert reached only one row");
    try h.expectContains(got, "ree:gamma", "`.` should have deleted two characters");
    try h.expectContains(got, "aaa!", "the macro did not record");
    try h.expectContains(got, "bbb!", "the macro did not replay");
}

// ----------------------------------------------------------------- wide

/// A CJK line takes two cells per character on screen while motions
/// still move one CHARACTER at a time. Both halves are checked: the
/// dump for the layout, and disk for where the edit actually landed.
fn wideText(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wide.txt", .{app.dirPath()});
    try h.writeFile(path,
        \\日本語です
        \\abcdefgh
        \\
    );

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("日本語", 5_000);

    // Two `l` from column zero is two CHARACTERS, so `x` takes the
    // third one. If motion were counting cells it would take the
    // second.
    _ = try app.ctl("type gg0llx");

    // And a `j` from there lands under the character's FIRST cell:
    // 語 started at render column 4, so this deletes the `e`.
    _ = try app.ctl("type jx");

    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    var content: [512]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "日本です") != null) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expectContains(got, "日本です", "l moved by cells rather than by characters");
    try h.expectContains(got, "abcdfgh", "j landed on the wrong column under a wide line");
}

// ------------------------------------------------------------ graphemes

/// A grapheme cluster is ONE character: `x` takes all of it and `l`
/// steps over all of it, whether it is a letter with an accent, a flag,
/// a skin tone or a ZWJ chain. Read off disk, so a render that lied
/// could not carry it.
fn graphemes(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/graphemes.txt", .{app.dirPath()});
    try h.writeFile(path, "e\u{301}|\u{1F1EF}\u{1F1F5}|\u{1F44D}\u{1F3FB}|\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}|end\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("end", 5_000);

    // Pixels, not just cells. A cluster that shapes wrong is invisible
    // to `dump` — and so is the failure this caught: drawing a shaped
    // cluster left the graphics context's text matrix behind it, which
    // put every PLAIN glyph rasterized afterwards outside its slot. The
    // separators and the `d` of `end` simply stopped being drawn while
    // every text assertion stayed green.
    var shot_buf: [192]u8 = undefined;
    const shot_path = try std.fmt.bufPrint(&shot_buf, "{s}/shot.png", .{app.dirPath()});
    var shot = try app.shot(shot_path);
    defer shot.deinit();
    const row_top = shot.height / 24;
    const row_bot = shot.height / 8;
    // A DENSITY rather than a pixel count, so the number does not move
    // with the display scale. Measured 130 with the clusters shaping
    // correctly and 100 with the text-matrix bug in place, which is what
    // sets the threshold between them.
    const drawn = shot.ink(row_top, row_bot);
    const area = shot.width * (row_bot - row_top);
    const density = drawn * 10_000 / @max(area, 1);
    try h.expect(density > 115, "text row is too empty ({d}/10000) — glyphs after a shaped cluster stopped drawing", .{density});

    // One `x` per cluster: four characters, four keystrokes, and the
    // separators are all that should be left in front of `end`.
    _ = try app.ctl("type gg0xlxlxlx");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");

    var content: [512]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "|||") != null) break;
        h.sleepMs(100);
    }
    const got = try h.readFile(path, &content);
    try h.expectContains(got, "||||end", "an x left part of a cluster behind");
}

// ----------------------------------------------------------- termglyph

/// The SHELL side. Agent output is where emoji actually turn up, and a
/// terminal cell holds a cluster the same way an editor cell does — so
/// it has to shape it the same way. Asserted on pixels, because `dump`
/// sees the text either way and cannot tell a flag from a boxed letter.
fn termGlyph(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    // Literal UTF-8 in the source: POSIX printf has no \\U escape, and
    // the sandbox shell is /bin/sh.
    // Combining LOW LINE under a run of letters: thirty of them make a
    // continuous rule across the row, so "the marks drew" and "they did
    // not" differ by a whole line of pixels rather than by a few dots.
    // Regional indicators and ZWJ are deliberately not tested here —
    // the terminal does not cluster those without mode 2027, which is a
    // decision about column accounting and not about rasterizing.
    // The content goes in a FILE and the command is `cat`. Typing it
    // instead put thirty-times-six characters on the command line,
    // which wrapped across the rows being measured — and `waitText`
    // matched the sentinel inside the command it had just typed, so the
    // shot was taken before any output existed at all.
    var path_buf: [192]u8 = undefined;
    const bases = try std.fmt.bufPrint(&path_buf, "{s}/bases.txt", .{app.dirPath()});
    const brow = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n";
    try h.writeFile(bases, brow ++ brow ++ brow ++ brow ++ brow ++ brow ++ "ZZBASE\n");
    var path_buf2: [192]u8 = undefined;
    const marks = try std.fmt.bufPrint(&path_buf2, "{s}/marks.txt", .{app.dirPath()});
    const row = "x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}\n";
    try h.writeFile(marks, row ++ row ++ row ++ row ++ row ++ row ++ "ZZTOP\n");

    // SELF-CALIBRATING, not a density threshold: the same letters
    // without their marks are the baseline, shot at the same window
    // geometry. A fixed density constant here was the suite's last
    // geometry-dependent number — the window's size is the window
    // manager's, and this test went red the day the window settled
    // taller. Two shots, two PATHS (ImageIO caches by URL).
    _ = try app.ctlFmt("type cat {s}", .{bases});
    _ = try app.ctl("enter");
    try app.waitText("ZZBASE", 10_000);
    // Let the echo's own frame present before forcing the shot frame:
    // with a two-deep swapchain a readback can run one drawable behind,
    // and the settle makes even that stale drawable carry this screen.
    h.sleepMs(200);
    var shot_buf: [192]u8 = undefined;
    var base_shot = try app.shot(try std.fmt.bufPrint(&shot_buf, "{s}/term-base.png", .{app.dirPath()}));
    // Band INSIDE the terminal area: ink() samples its background at
    // the band's own top-right, and a band that starts at row zero
    // samples the TAB BAR — against which every black terminal pixel
    // reads as ink and an underline flipping black to white adds
    // nothing. Found as two different screens with identical counts.
    const top = base_shot.height / 24;
    const bot = base_shot.height / 3;
    const ink_base = base_shot.ink(top, bot);
    const width = base_shot.width;
    base_shot.deinit();

    // Clear (POSIX printf, octal escapes — /bin/sh has no `clear` in a
    // bare sandbox), then the marked rows in the same screen region.
    _ = try app.ctl("type printf '\\33[2J\\33[H'");
    _ = try app.ctl("enter");
    _ = try app.ctlFmt("type cat {s}", .{marks});
    _ = try app.ctl("enter");
    try app.waitText("ZZTOP", 10_000);
    h.sleepMs(200); // same settle as the base shot
    var shot_buf2: [192]u8 = undefined;
    var mark_shot = try app.shot(try std.fmt.bufPrint(&shot_buf2, "{s}/term-marks.png", .{app.dirPath()}));
    const ink_marks = mark_shot.ink(top, bot);
    mark_shot.deinit();

    // Six rows of thirty combining low lines form six horizontal
    // rules — measured ~1.5k px of extra ink at 2x, against ~150 px of
    // run-to-run noise. A quarter-width demand sits 4x above the noise
    // and 4x below the signal; dropped marks leave the delta at noise.
    try h.expect(ink_marks > ink_base + width / 4, "marks added no ink (base {d}, marks {d}, width {d}) — the terminal drew each cluster's base and dropped its marks", .{ ink_base, ink_marks, width });
}

// -------------------------------------------------------------- clobber

/// The case rook exists inside: you open a file, an agent rewrites it,
/// you save. Covered in `zig test src/buffer.zig` at the unit level;
/// this drives it through the REAL key path, because the guard is only
/// worth anything if `:w` actually reaches it and the refusal actually
/// reaches your eyes.
fn clobber(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/shared.txt", .{app.dirPath()});
    try h.writeFile(path, "mine\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("mine", 5_000);
    _ = try app.ctl("type ohello");
    _ = try app.ctl("key 1b"); // esc

    // Somebody else's write, while we hold the buffer.
    try h.writeFile(path, "theirs, and longer\n");

    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    try app.waitText("changed on disk", 5_000);

    // Refusing has to mean refusing. If the message showed but the write
    // went through anyway, the guard is theatre.
    var content: [256]u8 = undefined;
    const kept = try h.readFile(path, &content);
    try h.expectContains(kept, "theirs", "their bytes survive a refused :w");

    // `:w!` is the way through.
    _ = try app.ctl("type :w!");
    _ = try app.ctl("enter");
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "hello") != null) break;
        h.sleepMs(100);
    }
    const forced = try h.readFile(path, &content);
    try h.expectContains(forced, "hello", ":w! overwrites");

    // And the claim is re-established, so the NEXT save is not refused
    // for a conflict that was already resolved.
    _ = try app.ctl("type oagain");
    _ = try app.ctl("key 1b");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    waited = 0;
    while (waited < 5000) : (waited += 100) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "again") != null) break;
        h.sleepMs(100);
    }
    const settled = try h.readFile(path, &content);
    try h.expectContains(settled, "again", "a plain :w works once the conflict is resolved");
}

// -------------------------------------------------------------- reload

/// The other half of the clobber guard: noticing while the buffer is
/// still OPEN. An editor pane left on a file an agent is working
/// through should show what the agent wrote — and must not, if you have
/// edits of your own in it.
fn reload(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/watched.txt", .{app.dirPath()});
    try h.writeFile(path, "first version\n");

    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("first version", 5_000);

    // Somebody else rewrites it. We have no edits, so the pane follows.
    try h.writeFile(path, "second version\n");
    try app.waitText("second version", 8_000);

    // Now put an edit in the buffer, and change the file again. The
    // pane must NOT take it — reloading over an edit is the one outcome
    // worse than showing something stale.
    _ = try app.ctl("type omy own line");
    _ = try app.ctl("key 1b"); // esc
    try h.writeFile(path, "third version\n");
    try app.waitText("[!]", 8_000);

    var screen: [64 * 1024]u8 = undefined;
    const s = try app.screen(&screen);
    try h.expectContains(s, "my own line", "the edit survives a change on disk");
    try h.expect(
        std.mem.indexOf(u8, s, "third version") == null,
        "a modified buffer must not take the new file, screen is: \"{s}\"",
        .{s},
    );
}

// -------------------------------------------------------------- pixels

fn pixels(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    // Something visually distinctive, so a blank window and a drawn one
    // cannot both pass.
    _ = try app.ctl("type echo PIXELPROOF");
    _ = try app.ctl("enter");
    try app.waitTextCount("PIXELPROOF", 2, 10_000);

    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/shot.png", .{app.dirPath()});
    var s = try app.shot(path);
    defer s.deinit();

    try h.expect(s.width > 100 and s.height > 100, "drawable looks wrong: {d}x{d}", .{ s.width, s.height });
    // The atlas-flip bug was invisible to `dump` and obvious in pixels;
    // a uniform frame is the cheap signature of "drew nothing at all".
    const colors = s.distinctColors(8);
    try h.expect(colors >= 3, "frame has only {d} distinct colour(s) — the renderer drew nothing", .{colors});
}

// ------------------------------------------------------------ commands

fn commands(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // The table an agent reads to know what rook can do.
    const list = try app.ctl("commands");
    try h.expectContains(list, "pane.split-right", "registry lists split");
    try h.expectContains(list, "palette.commands", "registry lists itself");
    try h.expectContains(list, ":PaneSplitRight", "ex-name is derived and printed");

    // Run by canonical id.
    _ = try app.ctl("run pane.split-right");
    try h.expectEq("split ran", 2, try app.paneCount());

    // Run by ALIAS — a config written in the wails keymap's vocabulary
    // and an agent using the canonical id must reach the same code.
    _ = try app.ctl("run session.new");
    try h.expectEq("session.new is tab.new", 2, try app.tabCount());

    // An unknown name declines rather than doing something surprising.
    const bad = try app.ctl("run nope.nothing");
    try h.expectContains(bad, "err", "unknown command is refused");

    // The ⌘K palette, driven blind: open it, type a filter, press Enter.
    // This is the path that deadlocks if a command is dispatched while
    // the palette still holds draw_lock -- every dispatch target takes
    // it again -- so the assertion after Enter is really a liveness test.
    const before = try app.paneCount();
    _ = try app.ctl("run palette.commands");
    const st = try app.ctl("palette");
    try h.expectContains(st, "mode:commands", "palette opened in command mode");

    _ = try app.ctl("type split right");
    const filtered = try app.ctl("palette");
    try h.expectContains(filtered, "*pane.split-right", "filter selects the split command");

    _ = try app.ctl("enter");
    // If this times out rather than failing, suspect the deadlock.
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() == before) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq("palette Enter dispatched the command", before + 1, try app.paneCount());
    try h.expectContains(try app.ctl("palette"), "closed", "palette closed after activating");

    // The OTHER picker still works and still knows which one it is. The
    // two share one widget, so a mode leak would show up as the command
    // list appearing under the workspace prompt. (The sandbox has no
    // rook.db, so the list itself is legitimately empty here.)
    _ = try app.ctl("run workspace.switch");
    try h.expectContains(try app.ctl("palette"), "mode:workspaces", "workspace picker unaffected");
    _ = try app.ctl("key 1b"); // ESC
    try h.expectContains(try app.ctl("palette"), "closed", "ESC closes it");

    // The REAL ⌘K, as an NSEvent through AppKit's dispatch and our local
    // monitor. `run` above proves dispatch; only this proves the CHORD
    // reaches it. keycode 40 = 'k', modmask 0x100000 = command.
    _ = try app.ctl("nskey 40 100000 k");
    var waited2: u32 = 0;
    while (waited2 < 3000) : (waited2 += 100) {
        const s = try app.ctl("palette");
        if (std.mem.indexOf(u8, s, "mode:commands") != null) break;
        h.sleepMs(100);
    }
    try h.expectContains(try app.ctl("palette"), "mode:commands", "⌘K opens the command palette");
    _ = try app.ctl("key 1b");
}

// ------------------------------------------------------------ whichkey

/// Parse "…{needle}…\t{x},{y}" (or "hint-name {x},{y}") out of ctl
/// `whichkey` output: the last space- or tab-separated field is the
/// click point.
fn wkPoint(s: []const u8, needle: []const u8) ?[2]u32 {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        const cut = std.mem.lastIndexOfAny(u8, line, " \t") orelse continue;
        const xy = line[cut + 1 ..];
        const comma = std.mem.indexOfScalar(u8, xy, ',') orelse continue;
        const x = std.fmt.parseInt(u32, xy[0..comma], 10) catch continue;
        const y = std.fmt.parseInt(u32, xy[comma + 1 ..], 10) catch continue;
        return .{ x, y };
    }
    return null;
}

/// Arm the leader and wait for the sheet to reveal (the wk_delay is
/// 350ms; the reveal needs a display-link tick after it). Returns the
/// ctl `whichkey` output with row coordinates filled in.
fn wkReveal(app: *h.Instance) ![]const u8 {
    _ = try app.ctl("press `");
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        const s = try app.ctl("whichkey");
        if (std.mem.indexOf(u8, s, "armed visible") != null) return s;
        h.sleepMs(100);
    }
    std.debug.print("      wkReveal timed out; whichkey said: {s}\n", .{try app.ctl("whichkey")});
    app.showScreen();
    return error.AssertFailed;
}

fn whichkey(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // Nothing armed: the sheet is down, and the status bar already
    // carries its two teaching hints (the harness config binds `).
    const idle = try app.waitCtl("whichkey", "hint-commands", 5000);
    try h.expectContains(idle, "closed", "sheet down before the leader arms");
    try h.expectContains(idle, "hint-menu", "status bar draws the menu hint");

    // Arm. Consumed by the leader machine, sheet not necessarily up yet
    // — the reveal belongs to the tick clock, not the keystroke.
    try h.expectContains(try app.ctl("press `"), "consumed", "leader arms");
    try h.expectContains(try app.ctl("whichkey"), "armed", "armed state visible to ctl");
    _ = try app.ctl("press ESC"); // disarm; wkReveal re-arms below

    // An unanswered chord reveals the sheet, with the LIVE rows.
    const shown = try wkReveal(app);
    try h.expectContains(shown, "s\tSwitch Workspace", "rows resolve live bindings to titles");
    try h.expectContains(shown, "1-9\ttab 1-9", "digit chords collapse to one teaching row");

    // ...and it actually drew: the band the sheet occupies (above the
    // status bar, below the pane's mostly-empty bottom) carries several
    // rows' worth of non-background pixels. Absolute, not before/after
    // — AppKit resizes the window as it settles onto the screen, so two
    // shots this early are not the same geometry to diff.
    var shot_path: [192]u8 = undefined;
    const sp = try std.fmt.bufPrint(&shot_path, "{s}/wk.png", .{app.dirPath()});
    var img = try app.shot(sp);
    const ink = img.ink(img.height * 7 / 10, img.height * 9 / 10);
    const floor_px = img.width * 5;
    img.deinit();
    try h.expect(ink > floor_px, "sheet band has ink ({d}, floor {d})", .{ ink, floor_px });

    // Esc dismisses — the unknown-chord swallow, tmux-style.
    _ = try app.ctl("press ESC");
    try h.expectContains(try app.ctl("whichkey"), "closed", "esc dismisses the sheet");

    // A chord answered through the visible sheet still fires.
    _ = try wkReveal(app);
    _ = try app.ctl("press s");
    try h.expectContains(try app.ctl("whichkey"), "closed", "the chord spends the sheet");
    _ = try app.waitCtl("palette", "mode:workspaces", 3000);
    _ = try app.ctl("key 1b");

    // A row CLICK runs the command it teaches. The workspace row, because
    // its result is blind-checkable the same way. (It was the agent deck's
    // row, then review's; both left in the strip.)
    const rows = try wkReveal(app);
    const ws_pt = wkPoint(rows, "Switch Workspace") orelse {
        std.debug.print("      no workspace row point; whichkey said: {s}\n", .{rows});
        return error.AssertFailed;
    };
    _ = try app.ctlFmt("click {d} {d}", .{ ws_pt[0], ws_pt[1] });
    try h.expectContains(try app.ctl("whichkey"), "closed", "the click spends the chord");
    _ = try app.waitCtl("palette", "mode:workspaces", 3000);
    _ = try app.ctl("key 1b");

    // A click OUTSIDE the sheet dismisses without running anything:
    // re-arm, wait, click the middle of the pane area.
    _ = try wkReveal(app);
    _ = try app.ctlFmt("click {d} {d}", .{ 200, 200 });
    try h.expectContains(try app.ctl("whichkey"), "closed", "an outside click dismisses");

    // The status-bar hints are the mouse route in: "⌘K commands"
    // opens the palette without a single keystroke.
    const hint = wkPoint(try app.ctl("whichkey"), "hint-commands") orelse {
        std.debug.print("      no hint-commands point; whichkey said: {s}\n", .{try app.ctl("whichkey")});
        return error.AssertFailed;
    };
    _ = try app.ctlFmt("click {d} {d}", .{ hint[0], hint[1] });
    _ = try app.waitCtl("palette", "mode:commands", 3000);
    _ = try app.ctl("key 1b"); // esc: closed again

    // ...and "` menu" arms the leader with the sheet up NOW — a click
    // asked for the menu; it should not also have to wait out a delay.
    const menu = wkPoint(try app.ctl("whichkey"), "hint-menu") orelse {
        std.debug.print("      no hint-menu point; whichkey said: {s}\n", .{try app.ctl("whichkey")});
        return error.AssertFailed;
    };
    _ = try app.ctlFmt("click {d} {d}", .{ menu[0], menu[1] });
    try h.expectContains(try app.ctl("whichkey"), "armed visible", "the menu hint shows the sheet immediately");
    _ = try app.ctl("press ESC");
}

// ----------------------------------------------------------- statusbar

/// The status bar's where-you-are zone: workspace + branch + cwd,
/// anchored to the FOCUSED PANE's live cwd — it follows `cd`, and it
/// follows a branch switch made entirely outside the app, because the
/// truth is .git/HEAD, not shell activity. Then the segments as click
/// targets: branch → the diff, workspace → the switcher.
fn statusbar(gpa: std.mem.Allocator, bin: []const u8) !void {
    // A repo with a real change in it, declared as a workspace through
    // the environment graph — the only registry there is now, which is
    // why it exists before the app does. The branch name is pinned —
    // the machine's init.defaultBranch is not this test's to assume.
    var repo_buf: [128]u8 = undefined;
    const repo = try seedWorkspaceRepo(&repo_buf);
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "checkout", "-q", "-b", "trunk" }) != 0)
        return error.GitFailed;
    var f_buf: [256]u8 = undefined;
    const f_path = try std.fmt.bufPrint(&f_buf, "{s}/f.zig", .{repo});
    try h.writeFile(f_path, "l1\nl2\nl3\nl4\nl5\n");
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "add", "f.zig" }) != 0) return error.GitFailed;
    if (try h.runCmd(repo, &.{
        "/usr/bin/git", "-c", "user.email=t@example.com", "-c", "user.name=t",
        "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base",
    }) != 0) return error.GitFailed;
    try h.writeFile(f_path, "a\nb\nl1\nl2\nl3\nl4\nl5\n");

    // 'wsdecl', not 'scratch': the space's default name IS 'scratch',
    // and a declared workspace that happened to share it would let the
    // workspace-segment assertion pass with the graph never read.
    var env_buf: [512]u8 = undefined;
    const graph = try std.fmt.bufPrint(&env_buf,
        \\{{"rookEnvironment":1,"nodes":[{{"id":"workspace:wsdecl","kind":"workspace","scope":"app","name":"wsdecl","root":"{s}"}}]}}
    , .{repo});

    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    // The graph is the registry: the declared workspace comes back over
    // ctl, root and all.
    try h.expectContains(try app.ctl("workspaces"), "wsdecl", "the declared workspace is listed");
    try h.expectContains(try app.ctl("workspaces"), repo, "with its declared root");

    // Walk the SHELL into the repo. The segments follow the pane's own
    // cwd, not the space's root — cd is sacred.
    _ = try app.ctlFmt("type cd {s}", .{repo});
    _ = try app.ctl("enter");
    _ = try app.waitCtl("statusbar", "branch trunk", 8000);
    try h.expectContains(try app.ctl("statusbar"), "workspace scratch", "the workspace segment names the space");
    try h.expectContains(try app.ctl("statusbar"), "rook-e2e-ws", "the cwd label shows where the pane is");

    // The branch switches OUTSIDE the app — an agent in another
    // terminal, exactly the case the segment exists for.
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "checkout", "-q", "-b", "feat/wip" }) != 0)
        return error.GitFailed;
    _ = try app.waitCtl("statusbar", "branch feat/wip", 8000);

    // The branch segment still REPORTS its zone (the bar's hit-testing is
    // the mechanism) — it just has nothing to open since the diff view
    // left in the strip.
    _ = wkPoint(try app.ctl("statusbar"), "seg-branch") orelse return error.AssertFailed;

    // The workspace segment clicks into the switcher, and the switcher
    // lists what the graph declared.
    const ws = wkPoint(try app.ctl("statusbar"), "seg-workspace") orelse return error.AssertFailed;
    _ = try app.ctlFmt("click {d} {d}", .{ ws[0], ws[1] });
    _ = try app.waitCtl("palette", "mode:workspaces", 3000);
    try h.expectContains(try app.ctl("palette"), "wsdecl", "the declared workspace is a picker row");
    _ = try app.ctl("key 1b");
}

// ------------------------------------------------------------ worktrees

/// The worktree verbs, full lifecycle. `add` carves a checkout on a new
/// branch under the sandbox's data dir and the child DERIVES into
/// `workspaces` (nothing is stored — git's records are the registry).
/// `remove` refuses unmerged commits (rook's guard), then a dirty
/// checkout (git's own guard, surfaced verbatim), and once the branch
/// is merged and the tree clean it removes checkout and branch both.
fn worktrees(gpa: std.mem.Allocator, bin: []const u8) !void {
    var repo_buf: [128]u8 = undefined;
    const repo = try seedWorkspaceRepo(&repo_buf);
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "checkout", "-q", "-b", "trunk" }) != 0)
        return error.GitFailed;
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "add", "f.zig" }) != 0) return error.GitFailed;
    if (try h.runCmd(repo, &.{
        "/usr/bin/git", "-c", "user.email=t@example.com", "-c", "user.name=t",
        "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base",
    }) != 0) return error.GitFailed;

    var env_buf: [512]u8 = undefined;
    const graph = try std.fmt.bufPrint(&env_buf,
        \\{{"rookEnvironment":1,"nodes":[{{"id":"workspace:wsdecl","kind":"workspace","scope":"app","name":"wsdecl","root":"{s}"}}]}}
    , .{repo});
    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    // add answers `ok <path>` — the path is the point, an agent wants
    // somewhere to cd. Copied out at once: ctl replies share one buffer.
    const added = try app.ctl("worktree add wsdecl feat1");
    if (!std.mem.startsWith(u8, added, "ok /")) {
        std.debug.print("worktree add said: {s}\n", .{added});
        return error.AssertFailed;
    }
    var wt_buf: [512]u8 = undefined;
    const wt = blk: {
        const t = std.mem.trim(u8, added[3..], " \r\n");
        if (t.len >= wt_buf.len) return error.AssertFailed;
        @memcpy(wt_buf[0..t.len], t);
        break :blk wt_buf[0..t.len];
    };
    try h.expectContains(try app.ctl("workspaces"), "wsdecl/feat1", "the child derives from git's records");
    try h.expectContains(try app.ctl("workspaces"), wt, "with the checkout as its root");

    // A commit on feat1 that trunk cannot reach: rook's guard refuses.
    var p_buf: [600]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/g.zig", .{wt}), "g\n");
    if (try h.runCmd(wt, &.{ "/usr/bin/git", "add", "g.zig" }) != 0) return error.GitFailed;
    if (try h.runCmd(wt, &.{
        "/usr/bin/git", "-c", "user.email=t@example.com", "-c", "user.name=t",
        "-c", "commit.gpgsign=false", "commit", "-q", "-m", "wip",
    }) != 0) return error.GitFailed;
    try h.expectContains(try app.ctl("worktree remove wsdecl feat1"), "unmerged", "unmerged commits refuse removal");

    // Merge it, then dirty the checkout: git's guard refuses, its words.
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "merge", "-q", "feat1" }) != 0) return error.GitFailed;
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/dirty.txt", .{wt}), "x\n");
    try h.expectContains(try app.ctl("worktree remove wsdecl feat1"), "err", "a dirty checkout refuses removal");
    try h.expectContains(try app.ctl("workspaces"), "wsdecl/feat1", "refused means still there");

    // Clean and merged: checkout gone, branch gone, parent stays.
    if (try h.runCmd(wt, &.{ "/bin/rm", "dirty.txt" }) != 0) return error.GitFailed;
    try h.expectContains(try app.ctl("worktree remove wsdecl feat1"), "ok removed", "clean and merged removes");
    const after = try app.ctl("workspaces");
    try h.expectContains(after, "wsdecl", "the parent stays");
    try h.expectNotContains(after, "feat1", "the child is gone");
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "rev-parse", "-q", "--verify", "feat1" }) == 0)
        return error.AssertFailed; // the branch went with the checkout
}

// ------------------------------------------------------------------ cli

/// The CLI is a ctl client: `rook <verb>` reaches the instance named by
/// ROOK_SOCK, an `err` reply is exit 1, an unknown lone argument that
/// names a real file becomes `edit`, and --help answers with no app at
/// all. Driven through /usr/bin/env so each call targets the sandbox.
fn cli(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var env_buf: [160]u8 = undefined;
    const sockenv = try std.fmt.bufPrintZ(&env_buf, "ROOK_SOCK={s}", .{app.sockPath()});
    var bin_buf: [512]u8 = undefined;
    const binz = try std.fmt.bufPrintZ(&bin_buf, "{s}", .{bin});

    // A verb with a side effect proves the line actually landed.
    if (try h.runCmd(".", &.{ "/usr/bin/env", sockenv.ptr, binz.ptr, "run", "tab.new" }) != 0)
        return error.AssertFailed;
    try h.expectEq("tabs after cli run", 2, try app.tabCount());

    // A reply verb answers and exits clean.
    if (try h.runCmd(".", &.{ "/usr/bin/env", sockenv.ptr, binz.ptr, "panes" }) != 0)
        return error.AssertFailed;

    // An err reply is exit 1 — zoom with a single pane refuses.
    if (try h.runCmd(".", &.{ "/usr/bin/env", sockenv.ptr, binz.ptr, "zoom" }) == 0)
        return error.AssertFailed;

    // So is an unknown verb.
    if (try h.runCmd(".", &.{ "/usr/bin/env", sockenv.ptr, binz.ptr, "definitely-not-a-verb" }) == 0)
        return error.AssertFailed;

    // A lone argument naming a real file opens it in the editor.
    var f_buf: [128]u8 = undefined;
    const f = try std.fmt.bufPrintZ(&f_buf, "/tmp/rook-e2e-cli-{d}.txt", .{getpid()});
    try h.writeFile(f, "cli\n");
    if (try h.runCmd(".", &.{ "/usr/bin/env", sockenv.ptr, binz.ptr, f.ptr }) != 0)
        return error.AssertFailed;
    try h.expectContains(try app.ctl("docs"), "rook-e2e-cli", "the file landed in an editor");

    // No app on the socket: a clear failure, not a hang.
    if (try h.runCmd(".", &.{ "/usr/bin/env", "ROOK_SOCK=/tmp/rook-e2e-no-such.sock", binz.ptr, "panes" }) == 0)
        return error.AssertFailed;

    // --help needs no app and exits 0.
    if (try h.runCmd(".", &.{ binz.ptr, "--help" }) != 0)
        return error.AssertFailed;

    // `install claude` writes the embedded skill under $HOME — the
    // sandbox's HOME, so the developer's real ~/.claude stays theirs.
    var home_buf: [192]u8 = undefined;
    const homeenv = try std.fmt.bufPrintZ(&home_buf, "HOME={s}/home", .{app.dirPath()});
    if (try h.runCmd(".", &.{ "/usr/bin/env", homeenv.ptr, binz.ptr, "install", "claude" }) != 0)
        return error.AssertFailed;
    var skill_buf: [256]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_buf, "{s}/home/.claude/skills/rook/SKILL.md", .{app.dirPath()});
    var content_buf: [16 * 1024]u8 = undefined;
    const skill = try h.readFile(skill_path, &content_buf);
    try h.expect(std.mem.indexOf(u8, skill, "name: rook") != null, "the skill has its frontmatter", .{});
    try h.expect(std.mem.indexOf(u8, skill, "man rook-ctl") != null, "and points at the reference", .{});

    // An unknown target is usage, not a silent no-op.
    if (try h.runCmd(".", &.{ binz.ptr, "install", "emacs" }) == 0)
        return error.AssertFailed;
}

// ------------------------------------------------------------- bufline

/// The per-pane buffer line: retargeting a pane enrolls each document
/// as a chip, :b N / :bn walk them (restoring the parked cursor line),
/// and a chip answers a real pixel click through the pane's own grid.
fn bufline(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var f_buf: [224]u8 = undefined;
    const apath = try std.fmt.bufPrint(&f_buf, "{s}/alpha.txt", .{app.dirPath()});
    try h.writeFile(apath, "A-ONE\nA-TWO\nA-THREE\n");
    var f_buf2: [224]u8 = undefined;
    const bpath = try std.fmt.bufPrint(&f_buf2, "{s}/beta.txt", .{app.dirPath()});
    try h.writeFile(bpath, "B-ONE\n");

    _ = try app.ctlFmt("edit {s}", .{apath});
    _ = try app.waitCtl("panes", "edit:alpha.txt", 5000);
    // Park the cursor on line 3, then retarget: the chip remembers.
    _ = try app.ctl("type 2j");
    _ = try app.ctlFmt("edit {s}", .{bpath});
    _ = try app.waitCtl("panes", "edit:beta.txt", 5000);

    // Both chips up, close marks drawn, beta's content on screen.
    try app.waitText("alpha.txt", 5000);
    var buf: [16 * 1024]u8 = undefined;
    var scr = try app.screen(&buf);
    try h.expectContains(scr, "beta.txt \u{d7}", "the active chip carries its close mark");
    try h.expectContains(scr, "B-ONE", "the second document is on screen");

    // :b 1 goes back and restores the parked line (blind: 3 in the
    // status row's line:col).
    _ = try app.ctl("type :b 1");
    _ = try app.ctl("enter");
    try app.waitText("A-THREE", 5000);
    scr = try app.screen(&buf);
    try h.expectContains(scr, "3:1", "the parked cursor line came back with the buffer");

    // A pixel click on the beta chip switches — through the real
    // pane-grid mapping, no ctl shortcut. The chip row is the pane's
    // row zero; the beta chip sits right of alpha's ~10 columns.
    const panes_out = try app.ctl("panes");
    const rect = parseRect(panes_out) orelse return error.AssertFailed;
    const cols = rect.cols;
    const col: f32 = 16.5; // " alpha.txt × " spans 13 cells + a gap; this lands in "beta"
    const px = rect.x + rect.w * (col / @as(f32, @floatFromInt(cols)));
    const py = rect.y + rect.h * (0.5 / @as(f32, @floatFromInt(rect.rows)));
    _ = try app.ctlFmt("click {d} {d}", .{ @as(u32, @intFromFloat(px)), @as(u32, @intFromFloat(py)) });
    try app.waitText("B-ONE", 5000);

    // :bp cycles back.
    _ = try app.ctl("type :bp");
    _ = try app.ctl("enter");
    try app.waitText("A-THREE", 5000);
}

/// "rect WxH+X+Y grid CxR" for the focused pane, out of ctl `panes`.
fn parseRect(s: []const u8) ?struct { x: f32, y: f32, w: f32, h: f32, cols: usize, rows: usize } {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " *") == null) continue;
        const ri = std.mem.indexOf(u8, line, "rect ") orelse continue;
        const gi = std.mem.indexOf(u8, line, " grid ") orelse continue;
        var it = std.mem.tokenizeAny(u8, line[ri + 5 .. gi], "x+");
        const w = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
        const hh = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
        const x = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
        const y = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
        const grid = line[gi + 6 ..];
        const xi = std.mem.indexOfScalar(u8, grid, 'x') orelse return null;
        const ge = std.mem.indexOfAny(u8, grid, " \r") orelse grid.len;
        const cols = std.fmt.parseInt(usize, grid[0..xi], 10) catch return null;
        const rows = std.fmt.parseInt(usize, grid[xi + 1 .. ge], 10) catch return null;
        return .{ .x = x, .y = y, .w = w, .h = hh, .cols = cols, .rows = rows };
    }
    return null;
}

/// The rect + grid of the pane whose `panes` line names `needle`
/// (parseRect only ever looks at the focused one). Cell height comes
/// out of it, which is what turns "row 3 of the tree" into a click.
fn paneRectNamed(app: *h.Instance, needle: []const u8) !struct { x: f32, y: f32, w: f32, h: f32, rows: usize } {
    const r = try app.ctl("panes");
    var lines = std.mem.splitScalar(u8, r, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        const ri = std.mem.indexOf(u8, line, "rect ") orelse continue;
        const gi = std.mem.indexOf(u8, line, " grid ") orelse continue;
        var it = std.mem.tokenizeAny(u8, line[ri + 5 .. gi], "x+");
        const w = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const hh = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const x = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const y = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const grid = line[gi + 6 ..];
        const xi = std.mem.indexOfScalar(u8, grid, 'x') orelse continue;
        const ge = std.mem.indexOfAny(u8, grid, " \r") orelse grid.len;
        const rows = std.fmt.parseInt(usize, grid[xi + 1 .. ge], 10) catch continue;
        return .{ .x = x, .y = y, .w = w, .h = hh, .rows = rows };
    }
    return error.AssertFailed;
}

/// Click row `row` (0-based, as `dump` prints them) of a named pane.
fn clickPaneRow(app: *h.Instance, needle: []const u8, row: usize) !void {
    const r = try paneRectNamed(app, needle);
    const ch = r.h / @as(f32, @floatFromInt(r.rows));
    const y = r.y + ch * (@as(f32, @floatFromInt(row)) + 0.5);
    _ = try app.ctlFmt("click {d} {d}", .{
        @as(u32, @intFromFloat(r.x + r.w / 2)),
        @as(u32, @intFromFloat(y)),
    });
}

// ------------------------------------------------------------ filetree

/// The file tree as NERDTree's dedicated sidebar: `<leader>⇥` opens a
/// LEFT split (nothing you were looking at moves) and closes it by
/// removing the pane; Enter beside-opens files while the tree stands;
/// `<leader>o` reveals the current file; the editor's own leader
/// (`,⇥`) reaches the same commands; and `:e <dir>`'s in-pane tree
/// keeps netrw's open-in-place.
fn filetree(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{
        .config_extra = "[editor]\nleader = \",\"\n",
    });
    defer {
        app.stop();
        app.deinit();
    }

    // A little repo with depth, so root-at-repo and reveal-unfolding
    // are both distinguishable from "just listed the cwd".
    var proj_buf: [192]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{app.dirPath()});
    var sub_buf: [200]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/src", .{proj});
    try h.mkdirP(sub);
    var f_buf: [224]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/README.md", .{proj}), "hi\n");
    const mainzig = try std.fmt.bufPrint(&f_buf, "{s}/main.zig", .{sub});
    try h.writeFile(mainzig, "pub fn main() void {}\n");
    if (try h.runCmd(proj, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;

    // Walk the shell into proj/SRC — the tree roots at PROJ (the
    // repo), which is only provable from a subdirectory.
    _ = try app.ctlFmt("type cd {s}", .{sub});
    _ = try app.ctl("enter");
    _ = try app.waitCtl("statusbar", "proj/src", 8000);

    // <leader>⇥ from the terminal: a LEFT SIDEBAR — the terminal
    // stays; the tree pane takes focus.
    _ = try app.ctl("press `");
    _ = try app.ctl("press TAB");
    _ = try app.waitCtl("panes", "edit:proj", 5000);
    try h.expectContains(try app.ctl("panes"), " term", "the terminal is still standing");
    try h.expectEq("sidebar joined the terminal", 2, try app.paneCount());
    var buf: [16 * 1024]u8 = undefined;
    const scr = try app.screen(&buf);
    try h.expectContains(scr, "▸ src/", "the repo's dirs list folded");
    try h.expectContains(scr, "README.md", "the repo's files list");

    // Enter on src/ unfolds IN PLACE, navigated by `/` search — the
    // tree is a BUFFER, so vim's motions are the navigation.
    _ = try app.ctl("type /src");
    _ = try app.ctl("enter");
    _ = try app.ctl("press RET");
    try app.waitText("▾ src/", 5000);

    // Enter on a file: BESIDE-OPEN — the tree stays standing, the
    // file lands in a new pane, focus follows the file.
    _ = try app.ctl("type /README");
    _ = try app.ctl("enter");
    _ = try app.ctl("press RET");
    _ = try app.waitCtl("panes", "edit:README.md", 5000);
    try h.expectContains(try app.ctl("panes"), "edit:proj", "the tree pane is still standing");
    try h.expectContains(try app.ctl("dump"), "hi", "focus moved to the opened file");

    // <leader>⇥ from the file: the sidebar CLOSES — the pane is
    // REMOVED, not turned back into anything.
    const before_close = try app.paneCount();
    _ = try app.ctl("press `");
    _ = try app.ctl("press TAB");
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("panes"), "edit:proj") == null) break;
        h.sleepMs(100);
    }
    try h.expectNotContains(try app.ctl("panes"), "edit:proj", "toggle removed the sidebar");
    try h.expectEq("exactly the tree pane went away", before_close - 1, try app.paneCount());

    // THE MOUSE, which is how a VS Code hand arrives: single click
    // folds a directory and single click opens a file (VS Code's
    // explorer, NERDTree's mouse mode 3). Reopen the sidebar first.
    _ = try app.ctl("press `");
    _ = try app.ctl("press TAB");
    _ = try app.waitCtl("panes", "edit:proj", 5000);
    // The tree has no line numbers and no `~` filler — it is a list of
    // files, not a document (NERDTree sets nonumber; so do we).
    const tree_scr = try app.screen(&buf);
    try h.expectNotContains(tree_scr, "~", "no end-of-buffer markers in a tree");
    // Row 0 is "../", row 1 the first entry. src/ is the only dir
    // besides .git, and the listing is dirs-first: ../ .git/ src/.
    try h.expectContains(tree_scr, "▸ src/", "src/ folded again after the reopen");
    try clickPaneRow(app, "edit:proj", 2);
    try app.waitText("▾ src/", 5000);
    // And a click on a FILE opens it beside — the tree stays.
    try clickPaneRow(app, "edit:proj", 4);
    _ = try app.waitCtl("panes", "edit:README.md", 5000);
    try h.expectContains(try app.ctl("panes"), "edit:proj", "the tree survived the file click");
    _ = try app.ctl("press `");
    _ = try app.ctl("press TAB");
    waited = 0;
    while (waited < 5000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("panes"), "edit:proj") == null) break;
        h.sleepMs(100);
    }

    // THE EDITOR LEADER: `,⇥` (maplocalleader — a separate scope from
    // the app's backtick) opens the sidebar from inside a buffer...
    _ = try app.ctl("press ,");
    _ = try app.ctl("press TAB");
    _ = try app.waitCtl("panes", "edit:proj", 5000);
    // ...and closes it again.
    _ = try app.ctl("press ,");
    _ = try app.ctl("press TAB");
    waited = 0;
    while (waited < 5000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("panes"), "edit:proj") == null) break;
        h.sleepMs(100);
    }
    try h.expectNotContains(try app.ctl("panes"), "edit:proj", "the editor leader toggles too");

    // <leader>o reveals: the sidebar comes back pointed at the
    // focused file, ancestors unfolded, tree focused.
    _ = try app.ctlFmt("edit {s}", .{mainzig});
    _ = try app.waitCtl("panes", "edit:main.zig", 5000);
    _ = try app.ctl("press `");
    _ = try app.ctl("press o");
    _ = try app.waitCtl("panes", "edit:proj", 5000);
    try app.waitText("▾ src/", 5000);

    // Close it; the in-pane tree (`:e <dir>`) keeps netrw semantics:
    // Enter opens IN PLACE, no new pane.
    _ = try app.ctl("press `");
    _ = try app.ctl("press TAB");
    waited = 0;
    while (waited < 5000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("panes"), "edit:proj") == null) break;
        h.sleepMs(100);
    }
    // Focus the FILE pane explicitly — the reap picked a sibling, and
    // `:e` typed at a shell would just be shell input.
    const file_id = try editPaneId(app, "main.zig");
    _ = try app.ctlFmt("focus {d}", .{file_id});
    const before_inplace = try app.paneCount();
    _ = try app.ctlFmt("type :e {s}", .{proj});
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "edit:proj", 5000);
    _ = try app.ctl("type /README");
    _ = try app.ctl("enter");
    _ = try app.ctl("press RET");
    _ = try app.waitCtl("panes", "edit:README.md", 5000);
    try h.expectEq("netrw-style tree opened in place", before_inplace, try app.paneCount());

    // :vsp — the open-outside seam, spelled vim's way. Bare, it opens
    // the SAME file in a new pane.
    const before_split = try app.paneCount();
    _ = try app.ctl("type :vsp");
    _ = try app.ctl("enter");
    var sw: u32 = 0;
    while (sw < 5000 and try app.paneCount() == before_split) : (sw += 100) {
        h.sleepMs(100);
    }
    try h.expectEq(":vsp added a pane", before_split + 1, try app.paneCount());

    // The teaching layer picked the new commands up for free.
    _ = try app.ctl("press ESC");
    _ = try app.ctl("press `");
    var wk_waited: u32 = 0;
    while (wk_waited < 5000) : (wk_waited += 100) {
        const w = try app.ctl("whichkey");
        if (std.mem.indexOf(u8, w, "armed visible") != null) break;
        h.sleepMs(100);
    }
    const wk = try app.ctl("whichkey");
    try h.expectContains(wk, "TAB\tFile Tree", "the sheet teaches the toggle");
    try h.expectContains(wk, "o\tFile Tree: Reveal File", "the sheet teaches reveal");
    _ = try app.ctl("press ESC");
}

// --------------------------------------------------------------- excmd

fn excmd(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ex.txt", .{app.dirPath()});
    try h.writeFile(path, "one\ntwo\n");
    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("two", 5_000);
    // Takeover, so still one pane — the split below is what changes it.
    try h.expectEq("editor took over", 1, try app.paneCount());

    // The negative cases FIRST, while the editor still has focus. A
    // successful split moves focus to the new pane, so anything typed
    // after it goes to a SHELL — which is how the first version of this
    // scenario ended up asserting against `sh: command not found`.

    // An unknown CamelCase name is refused by the registry, not silently
    // swallowed.
    _ = try app.ctl("type :NoSuchCommand");
    _ = try app.ctl("enter");
    try app.waitText("not a command", 5_000);

    // The editor's own namespace is untouched: a lowercase typo still
    // gets the EDITOR's message, because the bridge only ever sees
    // leading-capital verbs.
    _ = try app.ctl("type :wq2");
    _ = try app.ctl("enter");
    try app.waitText("not an editor command", 5_000);

    // :w still works — the bridge sits in the fallthrough, so a
    // regression here would mean it captured a verb it should not.
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    try app.waitText("wrote", 5_000);

    // The bridge itself, last. Same deferred route as the palette's
    // Enter: this runs inside the editor's key handling, under
    // draw_lock, and a self-deadlock here would time out rather than
    // fail.
    _ = try app.ctl("type :PaneSplitRight");
    _ = try app.ctl("enter");
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() == 1) : (waited += 100) {
        h.sleepMs(100);
    }
    try h.expectEq(":PaneSplitRight split the pane", 2, try app.paneCount());
}

// ------------------------------------------------------------ sidepane

/// Columns of the focused pane, from `panes` ("… grid 80x24").
fn paneCols(app: *h.Instance) !usize {
    const r = try app.ctl("panes");
    const g = std.mem.indexOf(u8, r, " grid ") orelse return error.AssertFailed;
    const rest = r[g + 6 ..];
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return error.AssertFailed;
    return std.fmt.parseInt(usize, rest[0..x], 10) catch error.AssertFailed;
}

fn sidepane(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectContains(try app.ctl("sidepane"), "closed", "starts closed");
    // Measured immediately before each toggle, never once at the top.
    // A tiling WM re-assigns the launch size ASYNCHRONOUSLY, so a column
    // count taken at startup can go stale mid-scenario — that made this
    // flake roughly one run in six with an exact-equality assertion.
    // Every claim here is relative to an adjacent measurement.
    const wide = try paneCols(app);

    // The assertion that separates a real container from a slab painted
    // OVER the panes: opening it must narrow the terminal's grid, which
    // means a pty resize reached the shell.
    _ = try app.ctl("run panel.search");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "open side:right panel:search", "opened on the right");
    const narrow = try paneCols(app);
    try h.expect(narrow < wide, "pane should narrow: {d} cols before, {d} after", .{ wide, narrow });

    // Placement-agnostic: same tenant, other edge, same width.
    _ = try app.ctl("run panel.flip");
    try h.expectContains(try app.ctl("sidepane"), "open side:left", "flipped to the left");
    try h.expectEq("flip keeps the width", narrow, try paneCols(app));

    // It is chrome, not a pane: it must not appear in `panes`.
    try h.expectEq("side pane is not a pane", 1, try app.paneCount());

    // Toggling the SAME panel closes and gives the columns back. Compared
    // against the OPEN width, not the startup one: the direction is what
    // this asserts, and it is the part that cannot drift.
    // Search deliberately does not toggle (⌘⇧F with results up means
    // "search again"), so panel.close is the way out — and with search the
    // only surviving tenant, it is the ONLY way out.
    const still_narrow = try paneCols(app);
    _ = try app.ctl("run panel.close");
    try h.expectContains(try app.ctl("sidepane"), "closed", "panel.close shuts it");
    const restored = try paneCols(app);
    try h.expect(restored > still_narrow, "closing should give columns back: {d} open, {d} closed", .{ still_narrow, restored });

    // And the real chord, through AppKit's leader machine.
    _ = try app.ctl("run panel.search");
    try h.expectContains(try app.ctl("sidepane"), "open", "panel.search reopens it");
    _ = try app.ctl("run panel.close");
    try h.expectContains(try app.ctl("sidepane"), "closed", "and closes again");
}

// ------------------------------------------------- seeding a workspace
//
// A git repo the environment graph will DECLARE as a workspace. This was
// a sqlite registry (rook.db) until the db left with its last writer;
// now the repo has to exist BEFORE the app starts, because the workspace
// node naming it is written into the sandbox's environment.json.

fn seedWorkspaceRepo(buf: []u8) ![]const u8 {
    const repo = try std.fmt.bufPrint(buf, "/tmp/rook-e2e-ws-{d}", .{getpid()});
    var repoz_buf: [256]u8 = undefined;
    const repoz = try std.fmt.bufPrintZ(&repoz_buf, "{s}", .{repo});
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", repoz.ptr }) catch {};
    try h.mkdirP(repo);
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;
    var f_buf: [256]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/f.zig", .{repo}), "a\nb\nl1\nl2\nX\nY\nl3\nl4\nl5\n");
    return repo;
}

// ----------------------------------------------------------- pluginfetch

/// Declaring a plugin should not mean installing one by hand first.
///
/// `file://` rather than `https://`, because the suite must not need a
/// network — the scheme is the only difference, and curl treats both the
/// same. The https-only rule is checked separately below, where it costs
/// nothing.
fn pluginFetch(gpa: std.mem.Allocator, bin: []const u8) !void {
    var dir_buf: [128]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dir_buf, "/tmp/rook-e2e-fetch-{d}", .{getpid()});
    const dir: []const u8 = dirz;
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
    _ = try h.runCmd("/tmp", &.{ "/bin/mkdir", "-p", dirz.ptr });

    // The "remote": a plugin sitting somewhere rook has to go and get.
    var src_buf: [192]u8 = undefined;
    const srcz = try std.fmt.bufPrintZ(&src_buf, "{s}/remote-plugin", .{dir});
    try h.writeFile(srcz, sh_plugin);
    _ = try h.runCmd("/tmp", &.{ "/bin/chmod", "+x", srcz.ptr });

    var json_buf: [1024]u8 = undefined;
    const graph = try std.fmt.bufPrint(&json_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:remote-plugin","kind":"plugin","scope":"app","name":"remote-plugin","source":"file://{s}/remote-plugin","load":"lazy","grants":["items.list"]}},
        \\{{"id":"plugin:insecure","kind":"plugin","scope":"app","name":"insecure","source":"http://example.invalid/x","load":"lazy","grants":["items.list"]}},
        \\{{"id":"plugin:wrongpin","kind":"plugin","scope":"app","name":"wrongpin","source":"file://{s}/remote-plugin","sha256":"0000000000000000000000000000000000000000000000000000000000000000","load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{ dir, dir });
    var envp: [192]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&envp, "{s}/environment.json", .{dir}), graph);

    var argbuf: [192]u8 = undefined;
    var datap: [192]u8 = undefined;
    const app = try h.Instance.start(gpa, bin, .{
        .arg = try std.fmt.bufPrint(&argbuf, "--config={s}", .{dir}),
        .env = &.{.{ "XDG_DATA_HOME", try std.fmt.bufPrint(&datap, "{s}/data", .{dir}) }},
    });
    defer {
        app.stop();
        app.deinit();
    }

    // NOTHING is downloaded at launch. Lazy is the rule, and a launch that
    // fetches is a launch that waits on someone else's server.
    var cachep: [192]u8 = undefined;
    const cached = try std.fmt.bufPrint(&cachep, "{s}/data/rook/plugins/remote-plugin", .{dir});
    var probe: [64]u8 = undefined;
    try h.expect(h.readFile(cached, &probe) catch null == null, "nothing downloads until something asks", .{});

    // Opening it fetches it, and it works. Note what is NOT in the graph:
    // a path. The config named a source; where the binary lives is rook's
    // business.
    _ = try app.ctl("plugin-show remote-plugin");
    const rows = try app.waitCtl("sidepane", "alpha", 20_000);
    try h.expectContains(rows, "*ok\talpha", "the downloaded plugin ran");

    var buf: [8 * 1024]u8 = undefined;
    const got = try h.readFile(cached, &buf);
    try h.expect(got.len > 100, "and it landed in rook's cache, not the config dir", .{});

    // ROOK HANDS YOU THE PIN. A hash you have to go and compute yourself
    // is a hash nobody pins, so `plugins` offers it and the panel yanks it
    // — as a line in the language the config is actually written in, not a
    // bare hex string you then have to wrap.
    const offered = try app.ctl("plugins");
    try h.expectContains(offered, "sha256=", "an unpinned plugin offers its hash");
    _ = try app.ctl("key 79"); // y, vim's yank
    h.sleepMs(300);
    const clip = try app.ctl("clipboard");
    // The Go SDK's node-list shape: a rook.Plugin{...} declaration with
    // the SHA256 filled in, ready to paste into rook.Main(...).
    try h.expectContains(clip, "rook.Plugin{Source:", "y copies a ready-to-paste pin");
    try h.expectContains(clip, "SHA256:", "with the hash filled in");
    // The PID-SCOPED source, not just "remote-plugin". `ctl clipboard`
    // reads the real system pasteboard, so a previous run's copy sits
    // there and an assertion on anything stable passes without y ever
    // firing — which is exactly how this test first passed with the
    // keybinding deleted.
    try h.expectContains(clip, dir, "naming THIS run's source");
    try h.expectContains(clip, "items.list", "and carrying the grants forward");

    // http:// is refused. Executing something fetched over plain http is
    // not a thing to make easy, and the refusal names the reason.
    _ = try app.ctl("plugin-show insecure");
    const bad = try app.waitCtl("sidepane", "unreachable", 15_000);
    try h.expectContains(bad, "https", "an http source is refused by name");

    // A PIN THAT DOES NOT MATCH is refused, and nothing runs. This is the
    // strong form: it catches a remote that changed on a machine that has
    // never seen the old version.
    _ = try app.ctl("plugin-show wrongpin");
    const pinned = try app.waitCtl("sidepane", "unreachable", 20_000);
    try h.expectContains(pinned, "pin", "a mismatched pin is refused by name");

    // AND THE CACHE ITSELF. rook recorded what it first downloaded; a
    // binary that changed underneath is refused rather than silently run,
    // and rather than silently re-downloaded — replacing it would be the
    // failure this exists to prevent.
    app.stop();
    try h.writeFile(cached, "#!/bin/sh\nexit 0\n");
    const app2 = try h.Instance.start(gpa, bin, .{
        .arg = try std.fmt.bufPrint(&argbuf, "--config={s}", .{dir}),
        .env = &.{.{ "XDG_DATA_HOME", try std.fmt.bufPrint(&datap, "{s}/data", .{dir}) }},
    });
    defer {
        app2.stop();
        app2.deinit();
    }
    _ = try app2.ctl("plugin-show remote-plugin");
    const tampered = try app2.waitCtl("sidepane", "unreachable", 15_000);
    try h.expectContains(tampered, "changed", "a cache that changed is refused");
    // …and it was NOT quietly re-fetched over the top.
    var after: [64]u8 = undefined;
    const still = try h.readFile(cached, &after);
    try h.expectContains(still, "exit 0", "and not silently replaced");

    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
}

// --------------------------------------------------------- claude watch

// Fixture transcripts in Claude Code's own jsonl shapes — the fields the
// watcher reads, nothing more. Timestamps are fixed: state comes from the
// file's mtime and its last event, and only TurnDur (which the scenario
// disarms with --min-turn=0s) ever subtracts two of them.
const sess_a_working =
    \\{"type":"user","timestamp":"2026-08-03T10:00:00.000Z","cwd":"/tmp","gitBranch":"main","message":{"role":"user","content":"fix the frobnicator"}}
    \\{"type":"ai-title","aiTitle":"Fix the frobnicator"}
    \\{"type":"last-prompt","lastPrompt":"fix the frobnicator"}
    \\{"type":"permission-mode","permissionMode":"default"}
    \\{"type":"assistant","timestamp":"2026-08-03T10:00:05.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1"}]}}
    \\{"type":"user","timestamp":"2026-08-03T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}
    \\
;
const sess_a_done = sess_a_working ++
    \\{"type":"assistant","timestamp":"2026-08-03T10:01:40.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"the frobnicator is fixed"}]}}
    \\
;
const sess_b_pending =
    \\{"type":"user","timestamp":"2026-08-03T10:00:00.000Z","cwd":"/tmp/somewhere","message":{"role":"user","content":"audit everything"}}
    \\{"type":"permission-mode","permissionMode":"default"}
    \\{"type":"assistant","timestamp":"2026-08-03T10:00:05.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t9"}]}}
    \\
;
const sess_c_idle =
    \\{"type":"assistant","timestamp":"2026-08-03T09:00:00.000Z","cwd":"/tmp","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"all done long ago"}]}}
    \\
;

/// rook's first first-party plugin, driven end to end: the real binary
/// (built from plugins/claude right here — needs a Go toolchain on PATH,
/// the same thing a Go config program needs), fixture transcripts standing
/// in for ~/.claude/projects, and the loop the plugin exists for: a
/// session's turn ends in the transcript, and an attention arrives without
/// any panel ever being opened.
fn claudeWatch(gpa: std.mem.Allocator, bin: []const u8) !void {
    // Built by the scenario so the scenario cannot pass against a stale
    // binary. Pure stdlib inside the root module: no network, build cache
    // makes the second run instant.
    try h.expect(try h.runCmd("..", &.{ "/usr/bin/env", "go", "build", "-o", "app/zig-out/bin/rook-plugin-claude", "./plugins/claude" }) == 0, "go build ./plugins/claude", .{});
    var cwd_buf: [512]u8 = undefined;
    const cwd = getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    var bin_buf: [600]u8 = undefined;
    const plug = try std.fmt.bufPrint(&bin_buf, "{s}/zig-out/bin/rook-plugin-claude", .{cwd});

    // A stand-in projects directory with three sessions mid-life.
    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/rook-e2e-claude-{d}", .{h.runPid()});
    var proj_buf: [128]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/projects/-tmp-proj", .{root});
    try h.mkdirP(proj);
    var pa: [160]u8 = undefined;
    const sess_a = try std.fmt.bufPrint(&pa, "{s}/sessA.jsonl", .{proj});
    try h.writeFile(sess_a, sess_a_working);
    var pb: [160]u8 = undefined;
    const sess_b = try std.fmt.bufPrintZ(&pb, "{s}/sessB.jsonl", .{proj});
    try h.writeFile(sess_b, sess_b_pending);
    var pc: [160]u8 = undefined;
    const sess_c = try std.fmt.bufPrintZ(&pc, "{s}/sessC.jsonl", .{proj});
    try h.writeFile(sess_c, sess_c_idle);
    // B has sat on a pending tool call for two minutes under a permission
    // mode that prompts; C has been quiet half an hour. mtime is the clock
    // the watcher reads, so mtime is what the fixture sets.
    const now: i64 = @divTrunc(h.nowMs(), 1000);
    try setMtime(sess_b, now - 120);
    try setMtime(sess_c, now - 1800);

    // A MIXED graph, deliberately: the keybind rides along because its
    // `command` is a string where the plugin's is an argv, and a loader
    // that parses the whole file against the plugin shape chokes on it —
    // which is exactly how every real config looks and exactly what a
    // plugin-only fixture graph failed to catch once already.
    var json_buf: [1280]u8 = undefined;
    const graph = try std.fmt.bufPrint(&json_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"font","kind":"font","scope":"app","family":"Menlo","size":12}},
        \\{{"id":"kb","kind":"keybind","scope":"app","chord":"<leader>z","command":"pane.zoom"}},
        \\{{"id":"plugin:claude","kind":"plugin","scope":"app","name":"claude","command":["{s}","--dir","{s}/projects","--poll","200ms","--min-turn","0s"],"load":"eager","grants":["items.list","items.act","attention.raise","panes.activity"]}}
        \\]}}
    , .{ plug, root });

    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    // Eager means UP at launch, before any panel is opened — a watcher
    // that only watches while being watched is not one.
    _ = try app.waitCtl("plugins", "claude\teager\tup", 10_000);

    // The substrate report the watcher fuses against: one line per pane
    // with output/input ages. The sandbox pane's shell has drawn a
    // prompt, so the report is real rows, not "none" — and the same
    // answer reaches the plugin as JSON over the granted panes.activity.
    const act0 = try app.ctl("activity");
    try h.expect(!std.mem.startsWith(u8, act0, "none"), "activity lists the pane", .{});
    try h.expectContains(act0, "\t", "tab-separated ages per pane");

    // Three sessions, three lives, each read from its transcript's tail.
    const listed = try app.ctl("plugin claude items.list");
    try h.expectContains(listed, "Fix the frobnicator", "the session carries Claude's own title");
    try h.expectContains(listed, "\"state\":\"working\"", "a pending tool call, fresh, is working");
    try h.expectContains(listed, "\"state\":\"blocked?\"", "a pending tool call gone quiet may be an approval");
    try h.expectContains(listed, "\"state\":\"idle\"", "an old session is idle");
    try h.expectContains(listed, "somewhere · sessB", "no ai-title falls back to the directory");

    // THE POINT: the turn ends in the transcript, and the attention
    // arrives on its own — no panel, no poll from the human's side.
    try h.writeFile(sess_a, sess_a_done);
    const att = try app.waitCtl("attention", "is waiting on you", 10_000);
    try h.expectContains(att, "claude\t", "provenance is the declared name, server-assigned");
    try h.expectContains(att, "the frobnicator is fixed", "the banner carries what was said");

    const relisted = try app.ctl("plugin claude items.list");
    try h.expectContains(relisted, "\"state\":\"needs you\"", "the panel agrees with the banner");

    // And an action reads back into the transcript.
    const peeked = try app.ctl("plugin claude items.act {\"itemId\":\"sessA\",\"actionId\":\"peek\"}");
    try h.expectContains(peeked, "the frobnicator is fixed", "peek answers with the last reply");

    // The focus choreography, straight from live dogfood: the panel
    // opens holding the keys, ⌃H (away from a right panel) hands them
    // back, ⌃L from the edge pane walks back in, ⌃J moves the panel's
    // own selection. The old behavior moved pane focus invisibly under
    // a panel that kept eating the typing.
    // nskey lands asynchronously (dispatch_async to the main thread), so
    // every chord is followed by a wait on the state it changes.
    _ = try app.ctl("plugin-show claude");
    _ = try app.waitCtl("sidepane", "needs you", 5_000);
    _ = try app.waitCtl("sidepane", "focus:panel", 2_000);
    try h.expectContains(try app.ctl("press j"), "consumed", "the focused panel eats plain keys");
    _ = try app.ctl("nskey 4 40000 h"); // ⌃H
    _ = try app.waitCtl("sidepane", "focus:panes", 2_000);
    try h.expectContains(try app.ctl("press j"), "typed", "away-from-the-panel hands the keys back");
    _ = try app.ctl("nskey 37 40000 l"); // ⌃L — no pane lies right, so it enters the panel
    _ = try app.waitCtl("sidepane", "focus:panel", 2_000);
    try h.expectContains(try app.ctl("press j"), "consumed", "the edge pane's chord walks into the panel");
    _ = try app.ctl("nskey 38 40000 j"); // ⌃J — selection, same as j
    _ = try app.waitCtl("sidepane", "*idle", 2_000);

    // The panel is LIVE: the transcript changes on disk and the open
    // panel's rows follow on their own — no `r`, no reopen. (The
    // selection stays put through the refresh: it follows the item id.)
    try h.writeFile(sess_a, sess_a_working);
    const live = try app.waitCtl("sidepane", "working\tFix the frobnicator", 12_000);
    try h.expectContains(live, "*idle", "the refresh must not move the human's selection");

    var rootz: [104]u8 = undefined;
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", (try std.fmt.bufPrintZ(&rootz, "{s}", .{root})).ptr }) catch {};
}

const Timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn utimes(path: [*:0]const u8, times: *const [2]Timeval) c_int;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]const u8;

fn setMtime(path_z: [:0]const u8, sec: i64) !void {
    const tv = [2]Timeval{ .{ .sec = sec, .usec = 0 }, .{ .sec = sec, .usec = 0 } };
    if (utimes(path_z.ptr, &tv) != 0) return error.Utimes;
}

// ---------------------------------------------------------------- setup

/// Crash capture, end to end: a process that dies of SIGSEGV leaves a
/// record, and the NEXT launch sweeps it, lists it, and says so.
///
/// The crashing launch is bare (runCmd, not the harness): the crash
/// fires in crash.install, before AppKit or the ctl socket exist, so
/// there is nothing to wait for — and if the crash test hook ever
/// silently broke, the --config sandbox keeps the accidental live app
/// off the developer's socket.
fn crashScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    var dir_buf: [128]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dir_buf, "/tmp/rook-e2e-crash-{d}", .{getpid()});
    const dir: []const u8 = dirz;
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
    var mk_buf: [256]u8 = undefined;
    const mk = try std.fmt.bufPrintZ(&mk_buf, "mkdir -p {s}/config {s}/state", .{ dir, dir });
    _ = try h.runCmd("/tmp", &.{ "/bin/sh", "-c", mk.ptr });

    // ABSOLUTE, for the same reason harness.spawn resolves it: runCmd
    // chdirs its child, and build.zig hands the artifact by relative
    // path.
    var binz_buf: [640]u8 = undefined;
    const binz = if (bin.len > 0 and bin[0] == '/')
        try std.fmt.bufPrintZ(&binz_buf, "{s}", .{bin})
    else blk: {
        var cwd_buf: [512]u8 = undefined;
        const cwd = getcwd(&cwd_buf, cwd_buf.len) orelse return error.AssertFailed;
        break :blk try std.fmt.bufPrintZ(&binz_buf, "{s}/{s}", .{ std.mem.span(cwd), bin });
    };
    var state_env_buf: [192]u8 = undefined;
    const state_env = try std.fmt.bufPrintZ(&state_env_buf, "XDG_STATE_HOME={s}/state", .{dir});
    var cfg_arg_buf: [192]u8 = undefined;
    const cfg_arg = try std.fmt.bufPrintZ(&cfg_arg_buf, "--config={s}/config", .{dir});

    // Phase 1: die. SIGSEGV means a nonzero (signal) status — the
    // interesting outcome is the sidecar, not the exit code.
    _ = h.runCmd("/tmp", &.{
        "/usr/bin/env",        state_env.ptr,
        "ROOK_CRASH_CAPTURE=1", "ROOK_CRASH_TEST=segv",
        binz.ptr,              "win",
        cfg_arg.ptr,           "--no-activate",
    }) catch {};

    // …and again through the panic path — the other half of capture,
    // the root-module override rather than a signal handler.
    _ = h.runCmd("/tmp", &.{
        "/usr/bin/env",        state_env.ptr,
        "ROOK_CRASH_CAPTURE=1", "ROOK_CRASH_TEST=panic",
        binz.ptr,              "win",
        cfg_arg.ptr,           "--no-activate",
    }) catch {};

    // The records exist, are non-empty, and say what happened. The
    // filenames carry pid+timestamp, so glob through a shell.
    var cat_buf: [256]u8 = undefined;
    const cat = try std.fmt.bufPrintZ(&cat_buf, "cat {s}/state/rook/crashes/crash-*.json > {s}/record.txt", .{ dir, dir });
    _ = try h.runCmd("/tmp", &.{ "/bin/sh", "-c", cat.ptr });
    var rec_buf: [8192]u8 = undefined;
    var path_buf: [160]u8 = undefined;
    const rec = try h.readFile(try std.fmt.bufPrint(&path_buf, "{s}/record.txt", .{dir}), &rec_buf);
    try h.expectContains(rec, "signal: SIGSEGV", "the segv record names its signal");
    try h.expectContains(rec, "panic: crash test", "the panic record carries its message");
    try h.expectContains(rec, "\"addrs\":[\"0x", "the record carries a stack");
    try h.expectContains(rec, "\"slide\":", "the record carries the ASLR slide");

    // Phase 2: the next launch, same state home, through the harness.
    // It sweeps, finds the record, and raises attention about it.
    var state_val_buf: [160]u8 = undefined;
    const app = try h.Instance.start(gpa, bin, .{
        .env = &.{.{ "XDG_STATE_HOME", try std.fmt.bufPrint(&state_val_buf, "{s}/state", .{dir}) }},
    });
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectContains(try app.ctl("crashes"), "signal: SIGSEGV", "ctl crashes lists the segv record");
    try h.expectContains(try app.ctl("crashes"), "panic: crash test", "ctl crashes lists the panic record");
    try h.expectContains(try app.ctl("notify"), "crashed last session", "the launch raised attention");
    try h.expectContains(try app.ctl("crashes clear"), "cleared 2", "clear counts what it removed");
    try h.expectContains(try app.ctl("crashes"), "no crashes", "cleared means cleared");
}

/// First run: rook asks rather than assuming.
///
/// TypeScript, not Go, because the Go starter runs `go mod tidy` — network
/// and a toolchain, in a suite that must pass on a fresh machine offline.
/// The TS starter writes the SDK out of the binary and touches neither.
fn setupScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    var dir_buf: [128]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dir_buf, "/tmp/rook-e2e-setup-{d}", .{getpid()});
    const dir: []const u8 = dirz;
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};

    var argbuf: [192]u8 = undefined;
    const app = try h.Instance.start(gpa, bin, .{
        .arg = try std.fmt.bufPrint(&argbuf, "--config={s}", .{dir}),
    });
    defer {
        app.stop();
        app.deinit();
    }

    // Nothing configured, so it asks — on its OWN SCREEN, not a palette.
    // The auto-open is gated on the window being frontmost (it owns the
    // keys while it is up, and a greeting that appeared behind you would
    // eat the first thing typed into a terminal). The harness launches
    // --no-activate precisely so scenarios do not steal focus, so here it
    // is opened the other way it is always available: by name.
    _ = try app.ctl("run config.setup");
    const asked = try app.waitCtl("welcome", "open", 10_000);
    try h.expectContains(asked, "Go", "the languages rook can be configured in");
    try h.expectContains(asked, "TypeScript", "both of them");

    // It takes the keys, so j moves rather than typing. The screen has no
    // filter box — there is nothing here to filter.
    _ = try app.ctl("key 6a");
    try h.expectContains(try app.ctl("welcome"), "*TypeScript", "j moves the selection");

    // Choosing writes a starter AND opens it. Opening it is half the
    // point: the answer to "how do I configure this" should be a file on
    // screen with a cursor in it, not a path in a document.
    _ = try app.ctl("key 0d");
    _ = try app.waitCtl("panes", "edit:config.ts", 10_000);
    try h.expectContains(try app.ctl("welcome"), "closed", "and the screen gets out of the way");

    // The SDK travels with it. A starter whose first line imports a
    // package that does not exist is not a starter — and @incantery/rook
    // is not published.
    var buf: [16 * 1024]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const sdk = try h.readFile(try std.fmt.bufPrint(&pbuf, "{s}/rook.ts", .{dir}), &buf);
    try h.expect(sdk.len > 1000, "the TS SDK is written beside the config, got {d} bytes", .{sdk.len});
    const cfg = try h.readFile(try std.fmt.bufPrint(&pbuf, "{s}/config.ts", .{dir}), &buf);
    try h.expectContains(cfg, "./rook.ts", "and the starter imports it relatively");

    // THE ASSERTION: a configured rook does not ask again. An onboarding
    // step that re-fires is an onboarding step people learn to dismiss.
    app.stop();
    const app2 = try h.Instance.start(gpa, bin, .{
        .arg = try std.fmt.bufPrint(&argbuf, "--config={s}", .{dir}),
    });
    defer {
        app2.stop();
        app2.deinit();
    }
    h.sleepMs(2500); // past the tick that would have opened it
    try h.expectContains(try app2.ctl("welcome"), "closed", "a configured rook stays quiet");

    // …and the config is reachable without knowing where it lives.
    _ = try app2.ctl("run config.edit");
    _ = try app2.waitCtl("panes", "edit:config.ts", 5_000);

    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
}

// ---------------------------------------------------------------- apply

/// Config is a program, and rook runs it.
///
/// Driven with a SHELL SCRIPT as the config program rather than Go: the
/// suite must not need a toolchain, and what is under test is the loop —
/// notice, run, diff, hold, apply — not `go build`. rook picks its runner
/// off the source file's name, so a `config.ts` whose "npx" is a stub in
/// PATH exercises exactly the same path a real one does.
fn applyScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    var dir_buf: [128]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dir_buf, "/tmp/rook-e2e-apply-{d}", .{getpid()});
    const dir: []const u8 = dirz;
    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
    _ = try h.runCmd("/tmp", &.{ "/bin/mkdir", "-p", dirz.ptr });
    var bin_buf: [160]u8 = undefined;
    const stubdirz = try std.fmt.bufPrintZ(&bin_buf, "{s}/bin", .{dir});
    const stubdir: []const u8 = stubdirz;
    _ = try h.runCmd("/tmp", &.{ "/bin/mkdir", "-p", stubdirz.ptr });

    // The stub `npx`: it IS the config program's runner, and it writes
    // whatever `graph.json` currently holds. That makes the config program
    // a file the scenario can rewrite between assertions.
    var stub_path: [192]u8 = undefined;
    const stubz = try std.fmt.bufPrintZ(&stub_path, "{s}/npx", .{stubdir});
    const stub: []const u8 = stubz;
    var stub_body: [512]u8 = undefined;
    try h.writeFile(stub, try std.fmt.bufPrint(&stub_body,
        \\#!/bin/sh
        \\# args: tsx config.ts --out <path>
        \\[ -f {s}/fail ] && {{ echo "config.ts:3: it did not compile" >&2; exit 1; }}
        \\cat {s}/graph.json > "$4"
    , .{ dir, dir }));
    _ = try h.runCmd("/tmp", &.{ "/bin/chmod", "+x", stubz.ptr });

    var cfgts: [192]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&cfgts, "{s}/config.ts", .{dir}), "// v1\n");
    var graph_path: [192]u8 = undefined;
    const graph = try std.fmt.bufPrint(&graph_path, "{s}/graph.json", .{dir});
    try h.writeFile(graph,
        \\{"rookEnvironment":1,"nodes":[{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":16}]}
    );
    // The applied graph rook launches with.
    var env_path: [192]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&env_path, "{s}/environment.json", .{dir}),
        \\{"rookEnvironment":1,"nodes":[{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":16}]}
    );

    var argbuf: [192]u8 = undefined;
    var pathbuf: [256]u8 = undefined;
    const app = try h.Instance.start(gpa, bin, .{
        .arg = try std.fmt.bufPrint(&argbuf, "--config={s}", .{dir}),
        .env = &.{.{ "PATH", try std.fmt.bufPrint(&pathbuf, "{s}:/usr/bin:/bin", .{stubdir}) }},
    });
    defer {
        app.stop();
        app.deinit();
    }

    // Launching next to a config it has already applied must say nothing.
    // A notification on every start is a notification nobody reads.
    try h.expectContains(try app.ctl("env"), "no pending changes", "a quiet launch");

    // Edit the program. rook notices and runs it — WITHOUT being asked, and
    // without the human running a build step.
    try h.writeFile(graph,
        \\{"rookEnvironment":1,"nodes":[{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":22},{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"Dracula"}]}
    );
    try h.writeFile(try std.fmt.bufPrint(&cfgts, "{s}/config.ts", .{dir}), "// v2\n");
    const pending = try app.waitCtl("env", "pending:", 15_000);
    // Readable, not a blob: which node, and both sides of the value.
    try h.expectContains(pending, "~ option:app:font-size\tvalue: 16 → 22", "a changed value reads");
    try h.expectContains(pending, "+ option:app:theme", "and an added node");

    // It SHOWS the diff, in a panel, without being asked — and without
    // taking the keys. A count in a banner says how many; this says what.
    const panel = try app.waitCtl("sidepane", "panel:config", 10_000);
    try h.expectContains(panel, "~ option:app:font-size", "the changed node");
    try h.expectContains(panel, "value: 16 → 22", "and what happens to it");
    try h.expectContains(panel, "+ option:app:theme", "and the added one");

    // Unfocused: changes landing is not a reason to take someone's keys
    // mid-sentence. The shell still has them.
    _ = try app.ctl("type still-mine");
    _ = try app.ctl("enter");
    try app.waitTextCount("still-mine", 2, 5_000);

    // THE ASSERTION THIS SCENARIO EXISTS FOR: it did NOT apply.
    var envbuf: [4096]u8 = undefined;
    try h.expectContains(try h.readFile(try std.fmt.bufPrint(&env_path, "{s}/environment.json", .{dir}), &envbuf), "\"value\":16", "a preview must not apply itself");
    // …and the human was told, through the same door a plugin's attention
    // uses.
    try h.expectContains(try app.ctl("attention"), "config changes pending", "pending changes raise attention");

    // Apply is a decision, and taking it writes the graph. From the panel,
    // which is where you just read what it would do.
    _ = try app.ctl("run config.preview");
    _ = try app.ctl("key 0d");
    h.sleepMs(500);
    try h.expectContains(try h.readFile(try std.fmt.bufPrint(&env_path, "{s}/environment.json", .{dir}), &envbuf), "\"value\":22", "apply writes the candidate");
    try h.expectContains(try app.ctl("env"), "no pending changes", "and the preview goes clean");
    // A panel showing a diff that no longer exists is a panel in the way.
    try h.expectContains(try app.ctl("sidepane"), "closed", "applying closes the preview");

    // A program that does not compile: its OWN error, and apply refuses.
    // "apply failed" would send you looking in rook; a line number does not.
    var failflag: [192]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&failflag, "{s}/fail", .{dir}), "");
    try h.writeFile(try std.fmt.bufPrint(&cfgts, "{s}/config.ts", .{dir}), "// v3 broken\n");
    const broken = try app.waitCtl("env", "broken", 15_000);
    try h.expectContains(broken, "config.ts:3", "the program's own error, with its line");
    try h.expectContains(try app.ctl("env apply"), "err", "apply refuses a broken candidate");
    try h.expectContains(try h.readFile(try std.fmt.bufPrint(&env_path, "{s}/environment.json", .{dir}), &envbuf), "\"value\":22", "and what is running is untouched");

    _ = h.runCmd("/tmp", &.{ "/bin/rm", "-rf", dirz.ptr }) catch {};
}

// ------------------------------------------------------------ configdir

/// `--config=DIR` — a whole rook in one directory you can delete.
///
/// The assertion that matters is the NEGATIVE one. Pointing rook at a
/// scratch directory is only useful if it stops reading the other one, and
/// a flag that adds a config directory without replacing one would be
/// worse than no flag: the instance would look configured-from-scratch
/// while quietly inheriting whatever the developer has at home.
///
/// So the sandbox gets TWO graphs — the XDG one the harness always writes,
/// and a scratch one — declaring different plugins under different names.
/// Exactly one may show up.
fn configDir(gpa: std.mem.Allocator, bin: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buf, "/tmp/rook-e2e-cfgdir-{d}.sh", .{getpid()});
    try h.writeFile(script, sh_plugin);

    // The graph the harness writes into XDG_CONFIG_HOME. If --config is
    // doing its job, nothing here is ever read.
    var xdg_buf: [1024]u8 = undefined;
    const xdg_graph = try std.fmt.bufPrint(&xdg_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:xdgonly","kind":"plugin","scope":"app","name":"xdgonly","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{script});

    const app = try h.Instance.start(gpa, bin, .{
        .env_json = xdg_graph,
        .arg = "--config=/tmp/rook-e2e-cfgdir-scratch",
    });
    defer {
        app.stop();
        app.deinit();
    }

    // Written AFTER start, because the flag creates the directory — which
    // is the behaviour a scratch instance needs: "from scratch" begins
    // with a directory that does not exist yet.
    var scratch_buf: [1024]u8 = undefined;
    const scratch_graph = try std.fmt.bufPrint(&scratch_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:scratchonly","kind":"plugin","scope":"app","name":"scratchonly","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{script});
    try h.writeFile("/tmp/rook-e2e-cfgdir-scratch/environment.json", scratch_graph);

    // The graph is re-read live, so this lands without a relaunch — but
    // the plugin REGISTRY is built at launch, so the declaration itself
    // needs one. Prove the directory is the one being read by restarting
    // into it.
    app.stop();
    const app2 = try h.Instance.start(gpa, bin, .{
        .env_json = xdg_graph,
        .arg = "--config=/tmp/rook-e2e-cfgdir-scratch",
    });
    defer {
        app2.stop();
        app2.deinit();
    }

    const plugins_out = try app2.ctl("plugins");
    try h.expectContains(plugins_out, "scratchonly", "the plugin declared in the --config directory loads");
    // THE ASSERTION: the XDG graph is not merged, not layered, not read.
    try h.expectNotContains(plugins_out, "xdgonly", "--config REPLACES the config directory, it does not add one");
}

// -------------------------------------------------------------- plugins

/// A plugin, in nine lines of sh.
///
/// The fixture is a SHELL SCRIPT on purpose. rook's e2e cannot depend on
/// rook-demos being checked out, and a script proves the thing the protocol
/// claims: a plugin is any process that reads a JSON line and writes one.
/// No SDK, no build step, no language.
///
/// It echoes the request's id, because rook checks it — a plugin answering
/// out of order is caught rather than rendered.
///
/// Note what it DECLARES: items.list and items.act. `shplug` below is
/// granted only items.list. That gap is the point of the scenario.
///
/// The item carries one action of each interesting shape — plain, confirm,
/// and one wanting input — because those are three different paths through
/// the panel and only the plugin knows which is which.
/// Two of the actions ask rook for something back — and read the answer,
/// so the plugin's own message reports whether it was allowed. That is the
/// hard case the pump exists for: an inbound REQUEST arrives while rook is
/// waiting for the RESPONSE to items.act, in the same read.
const sh_plugin =
    \\n=0
    \\acts='[{"id":"poke","label":"Poke"},{"id":"burn","label":"Burn it","confirm":true},{"id":"say","label":"Say","input":"INPUT_TEXT"},{"id":"clip","label":"Clip"},{"id":"send","label":"Send"}]'
    \\while IFS= read -r line; do
    \\  id=`expr "$line" : '.*"id":\([0-9]*\)'`
    \\  case "$line" in
    \\    *'"op":"describe"'*)
    \\      printf '{"v":1,"id":%s,"ok":true,"result":{"name":"shplug","version":"9.9","capabilities":["items.list","items.act"]}}\n' "$id" ;;
    \\    *'"op":"items.list"'*)
    \\      root=`expr "$line" : '.*"root":"\([^"]*\)"'`
    \\      case "$root" in /*) ;; *) root="NOT-A-PATH" ;; esac
    \\      printf '{"v":1,"id":%s,"ok":true,"result":{"items":[{"id":"a","title":"alpha","state":"ok","fields":[{"key":"n","kind":"NUMBER","value":"7"},{"key":"root","kind":"TEXT","value":"%s"}],"actions":%s,"children":[{"id":"a1","title":"kid","state":"sub"}]}]}}\n' "$id" "$root" "$acts" ;;
    \\    *'"op":"items.act"'*)
    \\      act=`expr "$line" : '.*"actionId":"\([a-z]*\)"'`
    \\      extra=""
    \\      n=`expr $n + 1`
    \\      rid=`expr 1000 + $n`
    \\      case "$act" in
    \\        poke)
    \\          printf '{"v":1,"id":%s,"op":"attention.raise","params":{"title":"needs you","body":"from the fixture"}}\n' "$rid"
    \\          IFS= read -r rep
    \\          case "$rep" in *'"ok":true'*) extra=" raise:ok" ;; *) extra=" raise:no" ;; esac ;;
    \\        burn)
    \\          printf '{"v":1,"id":%s,"op":"session.spawn","params":{"command":"echo spawned-by-plugin; sleep 30"}}\n' "$rid"
    \\          IFS= read -r rep
    \\          case "$rep" in *'"ok":true'*) extra=" spawn:ok" ;; *) extra=" spawn:no" ;; esac ;;
    \\        clip)
    \\          printf '{"v":1,"id":%s,"op":"clipboard.set","params":{"text":"from-the-plugin-pasteboard"}}\n' "$rid"
    \\          IFS= read -r rep
    \\          case "$rep" in *'"ok":true'*) extra=" clip:ok" ;; *) extra=" clip:no" ;; esac ;;
    \\        say)
    \\          said=`expr "$line" : '.*"input":"\([^"]*\)"'`
    \\          printf '{"v":1,"id":%s,"ok":true,"result":{"message":"ran say [%s]"}}\n' "$id" "$said"
    \\          continue ;;
    \\        send)
    \\          printf '{"v":1,"id":%s,"op":"session.send","params":{"pane":1,"text":"echo INJECTED-BY-PLUGIN"}}\n' "$rid"
    \\          IFS= read -r rep
    \\          case "$rep" in *'"ok":true'*) extra=" send:ok" ;; *) extra=" send:no" ;; esac ;;
    \\      esac
    \\      printf '{"v":1,"id":%s,"ok":true,"result":{"message":"ran %s%s","item":{"id":"a","title":"alpha","state":"done","fields":[{"key":"n","kind":"NUMBER","value":"8"}],"actions":%s}}}\n' "$id" "$act" "$extra" "$acts" ;;
    \\    *'"op":"wedge.op"'*)
    \\      ;;
    \\    *)
    \\      printf '{"v":1,"id":%s,"ok":false,"error":"unsupported op"}\n' "$id" ;;
    \\  esac
    \\done
;

fn plugins(gpa: std.mem.Allocator, bin: []const u8) !void {
    // The script has to exist before the app launches, and the graph has to
    // name it absolutely — so it goes to a pid-scoped path rather than into
    // the sandbox the harness has not created yet.
    var path_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buf, "/tmp/rook-e2e-plug-{d}.sh", .{getpid()});
    try h.writeFile(script, sh_plugin);
    // Left behind on purpose when a scenario fails — the harness keeps its
    // sandbox for inspection and the fixture is part of what you would read.

    // Four declarations over two binaries. `shplug` and `acty` run the
    // SAME script and differ only in what they were granted — which is the
    // point: what a plugin may do is the human's decision, recorded in
    // config, not something the plugin gets a say in.
    // Five declarations over two binaries. `shplug`, `acty` and `norais`
    // run the SAME script and differ only in what they were granted —
    // which is the point: what a plugin may do is the human's decision,
    // recorded in config, not something the plugin gets a say in. `acty`
    // may ask rook for things; `norais` may not.
    var json_buf: [4096]u8 = undefined;
    const graph = try std.fmt.bufPrint(&json_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:shplug","kind":"plugin","scope":"app","name":"shplug","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","wedge.op"]}},
        \\{{"id":"plugin:acty","kind":"plugin","scope":"app","name":"acty","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","items.act","attention.raise","session.spawn","session.send","clipboard.set"]}},
        \\{{"id":"plugin:norais","kind":"plugin","scope":"app","name":"norais","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","items.act"]}},
        \\{{"id":"plugin:nogrant","kind":"plugin","scope":"app","name":"nogrant","command":["/bin/sh","{s}"],"load":"lazy","grants":[]}},
        \\{{"id":"plugin:missing","kind":"plugin","scope":"app","name":"missing","command":["/nope/not-a-binary"],"load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{ script, script, script, script });

    // Launched OUTSIDE a git repo, deliberately.
    //
    // The list root comes from paneRootLocked, which takes two very
    // different paths: a repo root (written into the caller's buffer) or a
    // fallback to the pane's cwd (a slice into memory the caller does not
    // own). Every other scenario runs inside rook's own checkout, so the
    // fallback — the one that was broken — was unreachable from the suite.
    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph, .cwd = "/tmp" });
    defer {
        app.stop();
        app.deinit();
    }

    // LAZY IS THE DEFAULT, and this is what that means: three declarations,
    // nothing spawned. A surface nobody opened costs nothing.
    const before = try app.ctl("plugins");
    try h.expectContains(before, "shplug\tlazy\tdeclared", "declared, not spawned");
    try h.expectContains(before, "nogrant\tlazy\tdeclared", "declared, not spawned");
    try h.expectContains(before, "missing\tlazy\tdeclared", "declared, not spawned");

    // A granted op spawns it, handshakes, and comes back with real data
    // over the real wire.
    const listed = try app.ctl("plugin shplug items.list");
    try h.expectContains(listed, "\"ok\":true", "the call succeeded");
    try h.expectContains(listed, "\"title\":\"alpha\"", "the plugin's items came back");

    // …and now it is up, with BOTH sides recorded: what config granted and
    // what the plugin said it wants. The gap is the trust surface — a
    // plugin asking for more than it was given is a fact to show, not an
    // error to swallow.
    const after = try app.ctl("plugins");
    try h.expectContains(after, "shplug\tlazy\tup", "spawned on first use");
    try h.expectContains(after, "grants=items.list", "what config allowed");
    try h.expectContains(after, "wants=items.list,items.act", "what the plugin asked for");
    try h.expectContains(after, "v=9.9", "describe's version was kept");

    // THE ASSERTION THIS SCENARIO EXISTS FOR: the plugin declares
    // items.act, and rook refuses because the config did not grant it.
    // Declared by the plugin is not the same as granted by the human.
    const ungranted = try app.ctl("plugin shplug items.act");
    try h.expectContains(ungranted, "not granted", "an ungranted op is refused");

    // A plugin granted nothing is inert, and stays UNSPAWNED — the refusal
    // happens before anything is told anything.
    const inert = try app.ctl("plugin nogrant items.list");
    try h.expectContains(inert, "not granted", "no grants means nothing runs");
    try h.expectContains(try app.ctl("plugins"), "nogrant\tlazy\tdeclared", "a refused call must not spawn it");

    // A binary that is not there fails the plugin, not the app — and says
    // which, because an empty panel and a dead plugin look identical from
    // outside.
    _ = try app.ctl("plugin missing items.list");
    const failed = try app.ctl("plugins");
    try h.expectContains(failed, "missing\tlazy\tfailed", "a missing binary fails its plugin");

    // The app is still perfectly alive: a broken plugin is a missing panel.
    _ = try app.ctl("type echo still-here");
    _ = try app.ctl("enter");
    try app.waitTextCount("still-here", 2, 5_000);

    // ---- timeouts, strikes, and the way back ----
    //
    // `wedge.op` is granted, and the fixture reads it and says NOTHING —
    // the shape of a wedged handler. One unanswered call must not kill a
    // healthy plugin (a stray ctl call once took the whole link rail
    // down); a plugin that stopped answering ALTOGETHER is hung, and
    // three consecutive misses fail it for real.
    const strike1 = try app.ctl("plugin shplug wedge.op");
    try h.expectContains(strike1, "no answer", "an unanswered call reports itself");
    try h.expectContains(try app.ctl("plugins"), "shplug\tlazy\tup", "one timeout is not a death");

    // A real answer clears the strike count…
    try h.expectContains(try app.ctl("plugin shplug items.list"), "\"ok\":true", "it still answers after a timeout");

    // …so two MORE misses (three lifetime, two in a row) still leave it up…
    _ = try app.ctl("plugin shplug wedge.op");
    _ = try app.ctl("plugin shplug wedge.op");
    try h.expectContains(try app.ctl("plugins"), "shplug\tlazy\tup", "strikes reset on success");

    // …and the third consecutive miss is the hang verdict.
    _ = try app.ctl("plugin shplug wedge.op");
    try h.expectContains(try app.ctl("plugins"), "shplug\tlazy\tfailed", "three in a row fails it");

    // The way back, without restarting rook and every shell in it.
    try h.expectContains(try app.ctl("plugin-restart shplug"), "ok", "plugin-restart revives a failed plugin");
    try h.expectContains(try app.ctl("plugin shplug items.list"), "\"ok\":true", "and it answers again");

    // The restart re-reads the declaration from the applied config, so a
    // grant added after launch takes effect HERE — the alternative was
    // "config applied, nothing changed, restart rook to find out why".
    var json2_buf: [4096]u8 = undefined;
    const graph2 = try std.fmt.bufPrint(&json2_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:shplug","kind":"plugin","scope":"app","name":"shplug","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","wedge.op","extra.op"]}},
        \\{{"id":"plugin:acty","kind":"plugin","scope":"app","name":"acty","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","items.act","attention.raise","session.spawn","session.send","clipboard.set"]}},
        \\{{"id":"plugin:norais","kind":"plugin","scope":"app","name":"norais","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","items.act"]}},
        \\{{"id":"plugin:nogrant","kind":"plugin","scope":"app","name":"nogrant","command":["/bin/sh","{s}"],"load":"lazy","grants":[]}},
        \\{{"id":"plugin:missing","kind":"plugin","scope":"app","name":"missing","command":["/nope/not-a-binary"],"load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{ script, script, script, script });
    var envp_buf: [256]u8 = undefined;
    const envp = try std.fmt.bufPrint(&envp_buf, "{s}/config/rook/environment.json", .{app.dirPath()});
    try h.writeFile(envp, graph2);
    try h.expectContains(try app.ctl("plugin-restart shplug"), "ok", "restart with a fresh declaration");
    try h.expectContains(try app.ctl("plugins"), "grants=items.list,wedge.op,extra.op", "the new grant is live without a rook restart");

    // ---- the surface ----
    //
    // The item model has to survive a renderer, which is a different
    // question from surviving a wire. Here it becomes rows in a side pane.

    // A panel nobody can fill says WHY, and is shot FIRST so it can be the
    // baseline below. "This plugin has nothing" and "we could not reach
    // it" are different facts; a blank panel makes the second invisible.
    _ = try app.ctl("plugin-show missing");
    const dead = try app.waitCtl("sidepane", "unreachable", 5_000);
    try h.expectContains(dead, "unreachable", "a dead plugin says so rather than rendering empty");
    var empty_path: [192]u8 = undefined;
    const ep = try std.fmt.bufPrint(&empty_path, "{s}/plug-empty.png", .{app.dirPath()});
    var empty_img = try app.shot(ep);
    const empty_ink = empty_img.inkRect(empty_img.width * 3 / 4, 0, empty_img.width - 1, empty_img.height * 9 / 10);
    empty_img.deinit();

    _ = try app.ctl("plugin-show shplug");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "open side:right panel:plugin", "the panel took the pane");

    // The fetch is off the key path, so the panel may still be asking.
    const rows = try app.waitCtl("sidepane", "alpha", 5_000);
    try h.expectContains(rows, "plugin:shplug", "the panel names its plugin");
    try h.expectContains(rows, "*ok\talpha", "the item rendered, selected");
    try h.expectContains(rows, "n=7", "a typed field reached the row");
    // THE PARAMS ROOK SENT, echoed back as a field.
    //
    // This assertion exists because its absence hid a real bug. The fixture
    // pattern-matched on `op` and never looked at the request, so a request
    // carrying uninitialised bytes where the root should be still got a
    // valid answer here — while every real plugin, being something that
    // actually parses JSON, refused the frame and looked dead. A fixture
    // more permissive than the thing it stands in for passes for the wrong
    // reason.
    //
    // Not an equality check: the root is the pane's REPO root when there is
    // one, which is not the sandbox, and the field truncates. Absolute-path
    // -ness is the guarantee that broke and the one worth pinning.
    try h.expectContains(rows, "root=/", "rook must send a real path as the list root");
    try h.expectNotContains(rows, "NOT-A-PATH", "the root rook sent was not a path at all");
    // Children are the only structural difference between a list and a
    // tree, so a renderer that drops them turns one surface into another.
    try h.expectContains(rows, " \x20sub\tkid", "the child rendered, indented");

    // …and the ROWS actually drew. State being right and pixels being
    // right are different claims, which is why this suite asserts on both.
    //
    // A DIFFERENTIAL, not a threshold — and both earlier attempts were
    // wrong in instructive ways. A band a fifth down the window was all
    // background (the rows sit near the top), so it read 0 and flaked two
    // runs in three. Widening it to the whole panel then passed with the
    // row-drawing loop DELETED, because it was counting the panel's own
    // title and divider. Comparing the same region with rows against
    // without is the only version that measures the rows themselves.
    var shot_path: [192]u8 = undefined;
    const sp = try std.fmt.bufPrint(&shot_path, "{s}/plug.png", .{app.dirPath()});
    var img = try app.shot(sp);
    const ink = img.inkRect(img.width * 3 / 4, 0, img.width - 1, img.height * 9 / 10);
    img.deinit();
    try h.expect(ink > empty_ink, "rows should add ink: {d} with rows vs {d} without", .{ ink, empty_ink });

    // Naming one that was never declared is refused, not silently ignored.
    try h.expectContains(try app.ctl("plugin-show nope"), "no such plugin", "an undeclared name is refused");

    // ---- the door that is not the ctl socket ----
    //
    // A plugin nobody can open from the UI is a plugin only an agent can
    // reach. The command table is compiled in and plugins are declared at
    // runtime, so the bridge is one command that lists them.
    //
    // Driven through `press` — the REAL key path, leader state machine
    // included — because `plugin-show` would prove nothing: it starts
    // downstream of the picker this is about.
    _ = try app.ctl("key 1b"); // make sure nothing else holds the keys
    _ = try app.ctl("press `");
    _ = try app.ctl("press p");
    const picker = try app.waitCtl("palette", "mode:plugins", 5_000);
    try h.expectContains(picker, "declared:5", "every declared plugin is offered");
    try h.expectContains(picker, "shplug", "…by name");
    // State comes along: an empty panel and a dead plugin look identical
    // from outside, and you should know which you are about to open.
    try h.expectContains(picker, "missing\tfailed", "and by state");

    // Enter opens the panel on the one under the cursor.
    _ = try app.ctl("type acty");
    _ = try app.waitCtl("palette", "acty", 5_000);
    _ = try app.ctl("key 0d");
    const opened = try app.waitCtl("sidepane", "plugin:acty", 5_000);
    try h.expectContains(opened, "panel:plugin", "the picker opens the panel");
    _ = try app.waitCtl("sidepane", "alpha", 5_000);

    // The panel takes the keys and hands them back — the same contract
    // every side-pane tenant has.
    _ = try app.ctl("plugin-show shplug");
    _ = try app.waitCtl("sidepane", "alpha", 5_000);
    _ = try app.ctl("key 1b"); // ESC yields
    _ = try app.ctl("type after-panel");
    _ = try app.ctl("enter");
    try app.waitTextCount("after-panel", 2, 5_000);

    // ---- acting ----
    //
    // A list you cannot act on is half a surface. This is the other half,
    // and the reason it took a design rather than a keybinding is that an
    // action can DELETE something.

    _ = try app.ctl("plugin-show acty");
    const acty = try app.waitCtl("sidepane", "alpha", 5_000);
    try h.expectContains(acty, "mode:rows", "the panel starts on the list");
    // The menu is CLOSED until asked for — the actions exist on the item
    // the whole time, and showing them unprompted would make every list a
    // wall of buttons.
    try h.expectNotContains(acty, ">Poke", "actions are not shown until asked for");

    // Enter descends into what the item offers.
    _ = try app.ctl("key 0d");
    const menu = try app.waitCtl("sidepane", "mode:actions", 5_000);
    try h.expectContains(menu, "*  >Poke", "the first action, selected");
    // A confirm action is marked BEFORE it is chosen: the human should know
    // which way Enter is about to go while still deciding.
    try h.expectContains(menu, "   !Burn it", "a confirm action is marked");

    // ESC backs out one level rather than closing the panel. Proving it
    // did not yield takes a second key: if the keys had gone back to the
    // panes, this Enter would land in the shell instead.
    _ = try app.ctl("key 1b");
    try h.expectContains(try app.ctl("sidepane"), "mode:rows", "ESC backs out of the menu");
    _ = try app.ctl("key 0d");
    try h.expectContains(try app.ctl("sidepane"), "mode:actions", "ESC must not have yielded the keys");

    // An action that wants input opens the one-line editor — VOCABULARY
    // question 3, answered: the payload is the ACTION's. In the editor,
    // j is a letter (typing beats navigation), ESC backs out to the
    // menu, and an empty Enter still refuses: the refusal this mode
    // replaced lives on at the last moment, a plugin never acts on
    // nothing.
    _ = try app.ctl("key 6a"); // j
    _ = try app.ctl("key 6a"); // j — onto "Say", which wants text
    _ = try app.ctl("key 0d");
    try h.expectContains(try app.ctl("sidepane"), "mode:input", "Enter on Say opens the editor");
    _ = try app.ctl("key 0d");
    const still = try app.waitCtl("sidepane", "type something", 5_000);
    try h.expectContains(still, "mode:input", "an empty payload does not run");
    _ = try app.ctl("type jj-first-try");
    _ = try app.waitCtl("sidepane", "input:jj-first-try", 5_000);
    _ = try app.ctl("key 1b");
    try h.expectContains(try app.ctl("sidepane"), "mode:actions", "ESC backs out to the menu, dropping the draft");
    // Round two, sent for real: the typed text rides items.act and the
    // fixture quotes it back.
    _ = try app.ctl("key 0d");
    _ = try app.ctl("type approved-by-e2e");
    _ = try app.waitCtl("sidepane", "input:approved-by-e2e", 5_000);
    _ = try app.ctl("key 0d");
    const said = try app.waitCtl("sidepane", "ran say", 5_000);
    try h.expectContains(said, "[approved-by-e2e]", "the typed payload reached the plugin");
    try h.expectContains(said, "mode:rows", "a completed action returns to the list");

    // The confirm gate, and the half of it that matters: n means no.
    _ = try app.ctl("key 0d"); // back into the menu, on Poke
    _ = try app.waitCtl("sidepane", "mode:actions", 5_000);
    _ = try app.ctl("key 6a"); // j — onto "Burn it"
    _ = try app.ctl("key 0d");
    const asking = try app.waitCtl("sidepane", "mode:confirm", 5_000);
    try h.expectContains(asking, "confirm? y/n", "the panel asks before a confirm action");
    _ = try app.ctl("key 6e"); // n
    const declined = try app.waitCtl("sidepane", "cancelled", 5_000);
    try h.expectContains(declined, "mode:actions", "declining returns to the menu");
    // THE ASSERTION: nothing ran. The row is untouched — same state, same
    // field. A confirm that does not actually gate the call is decoration.
    // (Waited for, not just read: say ran a moment ago with a message-only
    // answer, and its stale-list refetch may still be landing.)
    const untouched = try app.waitCtl("sidepane", "n=7", 5_000);
    try h.expectContains(untouched, "*ok\talpha", "the row must be untouched");

    // y runs it, and the plugin's answer lands.
    //
    // This action also asks rook for something back — see the fixture: it
    // sends a session.spawn and READS the reply, so its own message says
    // whether it was allowed. Which makes this the interleaving case: an
    // inbound request arrives while rook is waiting for the response to
    // items.act, in the same read. A client that assumed the next frame
    // was its answer would fail the id check and kill a working plugin.
    const panes_before = try app.paneCount();
    const focus_before = try app.focusedPane();
    _ = try app.ctl("key 0d");
    _ = try app.waitCtl("sidepane", "mode:confirm", 5_000);
    _ = try app.ctl("key 79"); // y
    const ran = try app.waitCtl("sidepane", "ran burn", 5_000);
    try h.expectContains(ran, "spawn:ok", "the plugin was told its spawn was allowed");
    // The plugin sent back the row as it now is, so ONE line repainted
    // rather than the list relisting. Both halves changed, which is what
    // says the returned item was used and not just the message.
    try h.expectContains(ran, "*done\talpha", "the returned item replaced the row");
    try h.expectContains(ran, "n=8", "including its fields");
    try h.expectContains(ran, "mode:rows", "a completed action returns you to the list");
    // The child came from the LIST, not from the act — a replacement that
    // took the whole snapshot with it would have lost this.
    try h.expectContains(ran, " \x20sub\tkid", "the rest of the list survived");

    // ---- the inbound verbs ----
    //
    // session.spawn actually ran: a pane appeared. The plugin does not get
    // to say so — this is the host's side of the same event.
    var waited: u32 = 0;
    while (waited < 5000 and try app.paneCount() == panes_before) : (waited += 100) h.sleepMs(100);
    try h.expectEq("session.spawn opened a pane", panes_before + 1, try app.paneCount());
    // A plugin may put something on your screen. It does not get to take
    // your keystrokes mid-sentence.
    try h.expectEq("and did NOT steal focus", focus_before, try app.focusedPane());

    // And it is a real session running the plugin's command, not an empty
    // rectangle. The panel has the keys, so hand them back first.
    _ = try app.ctl("key 1b");
    _ = try app.ctl("focus right");
    try app.waitText("spawned-by-plugin", 10_000);
    _ = try app.ctl("focus left");

    // attention.raise: Poke asks, and reads the answer.
    _ = try app.ctl("plugin-show acty");
    _ = try app.waitCtl("sidepane", "alpha", 5_000);
    _ = try app.ctl("key 0d"); // menu, on Poke
    _ = try app.waitCtl("sidepane", "mode:actions", 5_000);
    _ = try app.ctl("key 0d");
    const poked = try app.waitCtl("sidepane", "ran poke", 5_000);
    try h.expectContains(poked, "raise:ok", "the plugin was told its raise was allowed");

    // session.send: THE safety property, asserted from both ends. The
    // fixture aims typed text at pane 1 — a shell, where text EXECUTES —
    // and the host must refuse: the foreground is not an agent TUI. The
    // dump then proves the injection never reached the pty, which is the
    // half a status code cannot prove.
    const sent = try app.ctl("plugin acty items.act {\"itemId\":\"a\",\"actionId\":\"send\"}");
    try h.expectContains(sent, "send:no", "typing into a shell is refused");
    try h.expectNotContains(try app.ctl("dump@1"), "INJECTED-BY-PLUGIN", "the text never reached the shell");
    const unsent = try app.ctl("plugin norais items.act {\"itemId\":\"a\",\"actionId\":\"send\"}");
    try h.expectContains(unsent, "send:no", "no grant, no keystrokes");

    // clipboard.set: the drafted-reply exit path. The REAL pasteboard is
    // read back, so this proves the bytes reached the system — and the
    // same action from a plugin without the grant is refused before the
    // pasteboard hears about it.
    const clipped = try app.ctl("plugin acty items.act {\"itemId\":\"a\",\"actionId\":\"clip\"}");
    try h.expectContains(clipped, "clip:ok", "the granted plugin's clip was allowed");
    try h.expectContains(try app.ctl("clipboard"), "from-the-plugin-pasteboard", "the text reached the system pasteboard");
    const unclipped = try app.ctl("plugin norais items.act {\"itemId\":\"a\",\"actionId\":\"clip\"}");
    try h.expectContains(unclipped, "clip:no", "no grant, no pasteboard");

    const raised = try app.waitCtl("attention", "needs you", 5_000);
    try h.expectContains(raised, "acty", "the raise records WHO raised it");
    try h.expectContains(raised, "from the fixture", "and what it said");
    // Provenance the caller can set is not provenance, so the plugin name
    // comes from the declaration rather than from the params. Nothing in
    // the fixture's request says "acty".
    try h.expectNotContains(sh_plugin, "acty", "the fixture must not be able to name itself");
    // The banner is the one thing a blind test cannot see, so rook records
    // the last one posted — the same seam OSC 9 uses.
    try h.expectContains(try app.ctl("notify"), "needs you", "a raise posts a notification");

    // THE ASSERTION THE INBOUND HALF EXISTS FOR: the same script, the same
    // action, a plugin that was not granted the verb. Refused, and told so
    // BY NAME — the plugin author needs to know to ask for the grant, not
    // to go looking in their own code.
    _ = try app.ctl("plugin-show norais");
    _ = try app.waitCtl("sidepane", "alpha", 5_000);
    _ = try app.ctl("key 0d");
    _ = try app.waitCtl("sidepane", "mode:actions", 5_000);
    _ = try app.ctl("key 0d");
    const norais = try app.waitCtl("sidepane", "ran poke", 5_000);
    try h.expectContains(norais, "raise:no", "an ungranted inbound verb is refused");
    // …and nothing was recorded. A refusal that still raises attention is
    // not a refusal.
    const after_refusal = try app.ctl("attention");
    try h.expectEq("the refused raise left no trace", @as(usize, 1), h.countLines(after_refusal));

    // And the same panel, on a plugin granted only items.list: the refusal
    // reaches the human rather than the key doing nothing. This is the
    // grant check from the top of the scenario, seen from the surface.
    _ = try app.ctl("plugin-show shplug");
    _ = try app.waitCtl("sidepane", "alpha", 5_000);
    _ = try app.ctl("key 0d");
    _ = try app.waitCtl("sidepane", "mode:actions", 5_000);
    _ = try app.ctl("key 0d"); // Poke — declared by the plugin, not granted
    const refused = try app.waitCtl("sidepane", "not granted", 5_000);
    try h.expectContains(refused, "*ok\talpha", "and the row is untouched");
}

// ---------------------------------------------------------------- runner

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = init.minimal.args.vector;
    // argv[1] is the rook binary (build.zig passes the artifact path);
    // anything after is a substring filter over scenario names.
    if (argv.len < 2) {
        std.debug.print("usage: e2e <path-to-rook> [filter...]\n", .{});
        return error.Usage;
    }
    // Re-exec as the fake language server. Must come before anything
    // else: in this mode the process IS a server on stdio, and a single
    // byte printed to stdout would corrupt the protocol.
    if (std.mem.eql(u8, std.mem.span(argv[1]), "--fake-lsp")) {
        if (argv.len < 3) return error.Usage;
        return fakeLsp(gpa, std.mem.span(argv[2]));
    }
    const bin = std.mem.span(argv[1]);
    const filters = argv[2..];
    // Our own path, ABSOLUTE. build.zig passes a relative artifact path,
    // and a server command is exec'd by a child that has already chdir'd
    // to the project root — the same trap explorerauto hit, where a
    // relative path silently execs nothing. Resolve it once, here.
    {
        const raw = std.mem.span(argv[0]);
        if (raw.len > 0 and raw[0] == '/') {
            self_exe = raw;
        } else {
            var cwd: [1024]u8 = undefined;
            if (h.cwdPath(&cwd)) |dir| {
                const trimmed = if (std.mem.startsWith(u8, raw, "./")) raw[2..] else raw;
                // A static buffer, not an allocation: this lives for the
                // whole run and freeing it would be ceremony.
                self_exe = std.fmt.bufPrint(&self_exe_buf, "{s}/{s}", .{ dir, trimmed }) catch raw;
            } else self_exe = raw;
        }
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    std.debug.print("\nrook e2e — {s}\n\n", .{bin});
    for (scenarios) |s| {
        if (filters.len > 0) {
            var match = false;
            for (filters) |f| {
                if (std.mem.indexOf(u8, s.name, std.mem.span(f)) != null) match = true;
            }
            if (!match) {
                skipped += 1;
                continue;
            }
        } else if (s.bench) {
            skipped += 1;
            continue;
        }
        // Printed BEFORE the run, and deliberately not overwritten after.
        // No \r or erase-line: the main consumer of this output is an
        // agent reading a pipe, where a cursor trick is just noise — and
        // a scenario that hangs has to have already named itself.
        std.debug.print("  · {s} — {s}\n", .{ s.name, s.what });
        const t0 = h.nowMs();
        if (s.run(gpa, bin)) |_| {
            passed += 1;
            std.debug.print("    \u{2713} {s} ({d}ms)\n", .{ s.name, h.nowMs() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("    \u{2717} {s} ({s}, {d}ms)\n", .{ s.name, @errorName(err), h.nowMs() - t0 });
        }
    }

    std.debug.print("\n  {d} passed, {d} failed", .{ passed, failed });
    if (skipped > 0) std.debug.print(", {d} filtered out", .{skipped});
    std.debug.print("\n", .{});

    if (failed == 0) {
        h.cleanupSandboxes();
    } else {
        // The sandbox holds the app's own log and any shot the scenario
        // took. Keeping it is the difference between a failure you can
        // read and one you have to reproduce.
        std.debug.print("\n  {d} sandbox(es) kept for inspection: /tmp/rook-e2e-*\n", .{h.sandboxCount()});
        std.debug.print("  (make e2e-clean to remove them)\n", .{});
    }
    std.debug.print("\n", .{});
    if (failed > 0) return error.E2eFailed;
}



/// The id of the pane holding `name`, from `panes` ("… 2 rect … edit:b.txt").
fn editPaneId(app: *h.Instance, name: []const u8) !u32 {
    const r = try app.ctl("panes");
    var it = std.mem.splitScalar(u8, r, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, name) == null) continue;
        // "*scratch t1 *2 rect …" — the id is the token after the tab.
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next(); // space/label
        _ = f.next(); // t<N>
        const id_tok = f.next() orelse continue;
        const digits = std.mem.trimStart(u8, id_tok, "*");
        return std.fmt.parseInt(u32, digits, 10) catch continue;
    }
    return error.AssertFailed;
}

/// `:qa` — every editor pane, and no terminal.
///
/// A unit test can only reach the verb table; "all" is by definition
/// about panes one editor cannot see, so the reach is only observable
/// here. The terminal half matters as much as the editor half: `:qa` in a
/// tenant must not take down the shells and agents around it.
fn quitAll(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var a_buf: [192]u8 = undefined;
    var b_buf: [192]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a.txt", .{app.dirPath()});
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b.txt", .{app.dirPath()});
    try h.writeFile(a, "alpha\n");
    try h.writeFile(b, "bravo\n");

    // Three panes: two editors and a shell. `edit` takes over the focused
    // pane, so each editor needs its own split first.
    _ = try app.ctlFmt("edit {s}", .{a});
    try app.waitText("alpha", 5_000);
    _ = try app.ctl("run pane.split-right");
    _ = try app.ctlFmt("edit {s}", .{b});
    try app.waitText("bravo", 5_000);
    _ = try app.ctl("run pane.split-down");
    try h.expectEq("two editors and a shell", 3, try app.paneCount());
    // The precondition, stated rather than assumed. The first version of
    // this scenario checked for "a.txt" in `panes` — which never listed
    // what a pane held, so the check passed with :qa never sent at all.
    const before = try app.ctl("panes");
    try h.expectContains(before, "edit:a.txt", "the first editor is open");
    try h.expectContains(before, "edit:b.txt", "the second editor is open");
    try h.expectContains(before, " term", "and a shell is open alongside them");

    // :qa from ONE OF THE EDITORS, addressed by pane id.
    //
    // Not from the focused pane: `pane.split-down` moved focus to the new
    // SHELL, so an untargeted `type` goes there and the shell answers
    // "sh: :qa: command not found" while every assertion below still reads
    // as a failure of :qa. The excmd scenario carries a comment about
    // exactly this trap, and it caught this scenario too.
    //
    // The pane it is typed in is also one of the panes it closes, which is
    // the reentrancy the app defers around — done inline, this is where it
    // would free the buffer the ex parser is reading.
    const ed_pane = try editPaneId(app, "b.txt");
    _ = try app.ctlFmt("type@{d} :qa", .{ed_pane});
    _ = try app.ctlFmt("enter@{d}", .{ed_pane});

    // The editors go; `edit` parked each shell under its pane, so those
    // come back rather than the panes collapsing. Either way the count
    // must settle and the app must still be alive to answer.
    var waited: u32 = 0;
    while (waited < 5_000) : (waited += 100) {
        const d = try app.ctl("panes");
        if (std.mem.indexOf(u8, d, "edit:") == null) break;
        h.sleepMs(100);
    }
    const dump = try app.ctl("panes");
    try h.expectNotContains(dump, "edit:a.txt", ":qa closed the first editor");
    try h.expectNotContains(dump, "edit:b.txt", ":qa closed the second editor");
    try h.expectNotContains(dump, "edit:", "no editor pane survived :qa");

    // THE OTHER HALF. The shells are untouched: the editor is a tenant of
    // rook, and `:qa` quitting the whole multiplexer would take down every
    // agent running in it.
    try h.expectEq("the terminals survived", 3, try app.paneCount());
    var buf: [8 * 1024]u8 = undefined;
    _ = try app.ctl("type echo alive");
    _ = try app.ctl("enter");
    try app.waitText("alive", 5_000);
    _ = try app.screen(&buf);
}

// ------------------------------------------------------------- startup

/// Bench, not a guard: how long from exec to (a) the ctl socket
/// answering and (b) a live shell, and where create() spent it —
/// config parse vs AppKit vs fonts vs the shell fork. This is the
/// baseline the environments work measures against: when the TOML
/// becomes a materialized graph, config_us is the number that must not
/// move. Wall columns are ms (5ms poll floor); phase columns are µs
/// from the app's own clock.
fn benchField(s: []const u8, key: []const u8) !i64 {
    const at = std.mem.indexOf(u8, s, key) orelse return error.MissingField;
    var i = at + key.len;
    var v: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
        any = true;
    }
    if (!any) return error.MissingField;
    return v;
}

fn median(vals: []i64) i64 {
    std.mem.sort(i64, vals, {}, std.sort.asc(i64));
    return vals[vals.len / 2];
}

/// A realistic daily-driver config: every app knob at a value, host
/// tables to parse past, a keybinds table, the editor scope. This is
/// what a real launch pays for, as opposed to the harness's 3-line
/// pinned sandbox config.
const bench_full_config =
    \\theme = "Nocturne"
    \\background-opacity = 1
    \\window-padding-x = 4
    \\window-padding-y = 4
    \\cursor-blink = true
    \\buffer-line = true
    \\scrollback = "10mb"
    \\bell = "visual"
    \\clipboard-write = "allow"
    \\coder = "claude"
    \\workspace-allow = ["rook", "rook-cloud", "rook-site", "presentation"]
    \\[keybinds]
    \\"<leader>\"" = "app.split.horizontal"
    \\"<leader>v" = "app.split.vertical"
    \\"<leader>c" = "tab.new"
    \\"<leader>m" = "workspace.manager"
    \\[editor]
    \\leader = ","
    \\[editor.keybinds.normal]
    \\"<leader>TAB" = "explorer.toggle"
    \\"<leader>o" = "explorer.reveal"
    \\[jira]
    \\[lsp]
    \\enable = ["go", "typescript", "svelte"]
    \\[cloud]
    \\url = "https://api.rookide.com"
;

fn startupBatch(gpa: std.mem.Allocator, bin: []const u8, label: []const u8, opts: h.Opts) !void {
    const runs = 8;
    const phases = [_][]const u8{ "config_us=", "keybinds_us=", "appkit_us=", "renderer_us=", "session_us=", "create_us=", "ctl_ready_us=" };
    var vals: [phases.len][runs]i64 = undefined;
    var sock: [runs]i64 = undefined;
    var prompt: [runs]i64 = undefined;

    std.debug.print("      [{s}]\n", .{label});
    std.debug.print("      run  sock_ms  shell_ms | config  binds  appkit   fonts  session  create  ctl (µs)\n", .{});
    for (0..runs) |i| {
        var app = try h.Instance.start(gpa, bin, opts);
        const bt = try app.ctl("boottime");
        for (phases, 0..) |key, p| vals[p][i] = try benchField(bt, key);
        sock[i] = app.boot_sock_ms;
        prompt[i] = app.boot_prompt_ms;
        std.debug.print("      {d:>3}  {d:>7}  {d:>8} | {d:>6} {d:>6} {d:>7} {d:>7} {d:>8} {d:>7} {d:>5}\n", .{
            i, sock[i], prompt[i], vals[0][i], vals[1][i], vals[2][i], vals[3][i], vals[4][i], vals[5][i], vals[6][i] - vals[5][i],
        });
        app.stop();
        app.deinit();
    }

    // Medians, the scoreboard line. ctl column is bind-after-create.
    var ctl_gap: [runs]i64 = undefined;
    for (0..runs) |i| ctl_gap[i] = vals[6][i] - vals[5][i];
    std.debug.print("      med  {d:>7}  {d:>8} | {d:>6} {d:>6} {d:>7} {d:>7} {d:>8} {d:>7} {d:>5}\n\n", .{
        median(&sock),    median(&prompt),  median(&vals[0]), median(&vals[1]),
        median(&vals[2]), median(&vals[3]), median(&vals[4]), median(&vals[5]),
        median(&ctl_gap),
    });

    // Sanity floor so the bench cannot rot into printing zeros: the
    // phases were actually stamped, and the socket came up.
    if (median(&vals[5]) == 0) return error.NoBoottime;
    for (&sock) |s| if (s <= 0) return error.NoBoottime;
}

fn startup(gpa: std.mem.Allocator, bin: []const u8) !void {
    try startupBatch(gpa, bin, "pinned 3-line config", .{});
    try startupBatch(gpa, bin, "full daily-driver config", .{ .config_extra = bench_full_config });
    try startupBatch(gpa, bin, "environment graph (same config, materialized)", .{ .env_json = bench_env_json });
}

/// The full daily-driver config as a materialized graph — what an SDK
/// program emits (sdk/rook/example, retargeted at the sandbox's pinned
/// font and leader). Same knobs as bench_full_config, so the config
/// column compares TOML parse vs graph load like for like.
const bench_env_json =
    \\{"rookEnvironment":1,"nodes":[
    \\{"id":"option:app:font-family","kind":"option","scope":"app","key":"font-family","value":"Menlo"},
    \\{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":14},
    \\{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"Nocturne"},
    \\{"id":"option:app:background-opacity","kind":"option","scope":"app","key":"background-opacity","value":1},
    \\{"id":"option:app:window-padding","kind":"option","scope":"app","key":"window-padding","value":4},
    \\{"id":"option:app:cursor-blink","kind":"option","scope":"app","key":"cursor-blink","value":true},
    \\{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":true},
    \\{"id":"option:app:scrollback","kind":"option","scope":"app","key":"scrollback","value":"10mb"},
    \\{"id":"option:app:bell","kind":"option","scope":"app","key":"bell","value":"visual"},
    \\{"id":"option:app:clipboard-write","kind":"option","scope":"app","key":"clipboard-write","value":"allow"},
    \\{"id":"leader:app","kind":"leader","scope":"app","key":"`"},
    \\{"id":"leader:editor","kind":"leader","scope":"editor","key":","},
    \\{"id":"keybind:app:<leader>\"","kind":"keybind","scope":"app","chord":"<leader>\"","command":"app.split.horizontal"},
    \\{"id":"keybind:app:<leader>v","kind":"keybind","scope":"app","chord":"<leader>v","command":"app.split.vertical"},
    \\{"id":"keybind:app:<leader>c","kind":"keybind","scope":"app","chord":"<leader>c","command":"tab.new"},
    \\{"id":"keybind:app:<leader>m","kind":"keybind","scope":"app","chord":"<leader>m","command":"workspace.manager"},
    \\{"id":"keybind:editor.normal:<leader>TAB","kind":"keybind","scope":"editor.normal","chord":"<leader>TAB","command":"explorer.toggle"},
    \\{"id":"keybind:editor.normal:<leader>o","kind":"keybind","scope":"editor.normal","chord":"<leader>o","command":"explorer.reveal"},
    \\{"id":"option:host:coder","kind":"option","scope":"host","key":"coder","value":"claude"},
    \\{"id":"option:host:workspace-allow","kind":"option","scope":"host","key":"workspace-allow","value":["rook","rook-cloud","rook-site","presentation"]},
    \\{"id":"table:host:agent","kind":"table","scope":"host","name":"agent","entries":{"daily-cap-usd":1,"enabled":true,"engine":"auto","model":""}},
    \\{"id":"table:host:lsp","kind":"table","scope":"host","name":"lsp","entries":{"enable":["go","typescript","svelte"]}},
    \\{"id":"table:host:cloud","kind":"table","scope":"host","name":"cloud","entries":{"url":"https://api.rookide.com"}}
    \\]}
;

// ------------------------------------------------------------ envgraph

/// The materialized graph is config now (docs/environments/IR.md):
/// when environment.json is present, ITS leader and chords drive the
/// real key path and config.toml's are ignored; an unknown node kind
/// from a newer graph is survived in silence. The sandbox toml pins
/// leader "`" — the graph says "~", and which one arms is the proof.
const envgraph_json =
    \\{"rookEnvironment":1,"nodes":[
    \\{"id":"option:app:font-family","kind":"option","scope":"app","key":"font-family","value":"Menlo"},
    \\{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":14},
    \\{"id":"leader:app","kind":"leader","scope":"app","key":"~"},
    \\{"id":"leader:editor","kind":"leader","scope":"editor","key":","},
    \\{"id":"keybind:app:<leader>c","kind":"keybind","scope":"app","chord":"<leader>c","command":"tab.new"},
    \\{"id":"keybind:editor.normal:<leader>t","kind":"keybind","scope":"editor.normal","chord":"<leader>t","command":"tab.new"},
    \\{"id":"future:hologram","kind":"hologram","scope":"app","key":"x","value":[1,2,3]}
    \\]}
;

fn envgraph(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{ .env_json = envgraph_json });
    defer {
        app.stop();
        app.deinit();
    }
    try h.expectEq("tabs", 1, try app.tabCount());
    // The graph's leader arms and its chord fires.
    _ = try app.ctl("press ~");
    _ = try app.ctl("press c");
    try h.expectEq("tabs after graph chord", 2, try app.tabCount());
    // config.toml's leader must NOT arm while a graph is present — the
    // backtick is just a character for the shell now.
    _ = try app.ctl("press `");
    _ = try app.ctl("press c");
    try h.expectEq("tabs after toml leader", 2, try app.tabCount());

    // The graph's EDITOR-scope bind (editor.normal): inside an editor
    // pane, the editor leader arms and its configured chord fires the
    // same registry command the app scope speaks.
    var f_buf: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&f_buf, "/tmp/rook-e2e-envgraph-{d}.txt", .{getpid()});
    try h.writeFile(f, "hello\n");
    _ = try app.ctlFmt("edit {s}", .{f});
    _ = try app.ctl("press ,");
    _ = try app.ctl("press t");
    try h.expectEq("tabs after editor chord", 3, try app.tabCount());
}

// -------------------------------------------------------------- chrome

/// The active tab's number, off the `tabs` verb ("*[label] N (…" —
/// the label is the sandbox's business, the number is ours).
fn activeTabNo(app: *h.Instance) !usize {
    const out = try app.ctl("tabs");
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] != '*') continue;
        const close = std.mem.indexOf(u8, line, "] ") orelse continue;
        var i = close + 2;
        var v: usize = 0;
        var any = false;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
            v = v * 10 + (line[i] - '0');
            any = true;
        }
        if (any) return v;
    }
    return error.AssertFailed;
}

fn waitActiveTab(app: *h.Instance, want: usize, timeout_ms: u32) !void {
    var waited: u32 = 0;
    while (waited < timeout_ms) {
        if ((activeTabNo(app) catch 0) == want) return;
        h.sleepMs(50);
        waited += 50;
    }
    return error.Timeout;
}

/// The two personas as ARRANGEMENTS (docs/environments/VISION.md):
/// same engine, different lists. tmux-neovim = no top strip, the tab
/// list as text in the bottom bar; vscode = no top strip, a single
/// current-tab chip that cycles. Both prove the demoted tabs still
/// CLICK — a segment keeps its affordances wherever it lands.
fn chrome(gpa: std.mem.Allocator, bin: []const u8) !void {
    {
        const app = try h.Instance.start(gpa, bin, .{ .config_extra = "preset = \"tmux-neovim\"" });
        defer {
            app.stop();
            app.deinit();
        }
        const sb = try app.ctl("statusbar");
        try h.expectContains(sb, "topbar\nleft tabs\nright workspace branch cwd\nactivitybar off\ntabstyle index_name", "tmux arrangement");
        try h.expectContains(sb, "seg-tab1 ", "the tab list draws in the bar");
        _ = try app.ctl("run tab.new");
        _ = try app.waitCtl("statusbar", "seg-tab2", 5_000);
        try h.expectEq("active tab after tab.new", 2, try activeTabNo(app));
        const p = wkPoint(try app.ctl("statusbar"), "seg-tab1") orelse return error.AssertFailed;
        _ = try app.ctlFmt("click {d} {d}", .{ p[0], p[1] });
        try waitActiveTab(app, 1, 3_000);
    }
    {
        const app = try h.Instance.start(gpa, bin, .{ .config_extra = "preset = \"vscode\"" });
        defer {
            app.stop();
            app.deinit();
        }
        const sb = try app.ctl("statusbar");
        try h.expectContains(sb, "topbar\nleft tabs branch\nright cwd hints\nactivitybar on\ntabstyle current", "vscode arrangement");
        _ = try app.ctl("run tab.new");
        _ = try app.waitCtl("statusbar", "seg-tab1", 5_000);
        try h.expectEq("active tab after tab.new", 2, try activeTabNo(app));
        // The compact chip cycles: 2 → 1 (wrapping past the end).
        const p = wkPoint(try app.ctl("statusbar"), "seg-tab1") orelse return error.AssertFailed;
        _ = try app.ctlFmt("click {d} {d}", .{ p[0], p[1] });
        try waitActiveTab(app, 1, 3_000);
    }
}

// -------------------------------------------------------- presetparity

/// The preset bundle exists twice — Zig's applyPreset (TOML front end)
/// and the Go SDK's expansion (sdk/rook, pinned by its golden test).
/// Two definitions drift; this diffs them where it matters, on the
/// LIVE app: a TOML `preset = "vscode"` instance and a graph instance
/// carrying the options the SDK emits must report identical chrome.
const parity_env_json =
    \\{"rookEnvironment":1,"nodes":[
    \\{"id":"option:app:top-bar","kind":"option","scope":"app","key":"top-bar","value":[]},
    \\{"id":"option:app:status-left","kind":"option","scope":"app","key":"status-left","value":["tabs","branch"]},
    \\{"id":"option:app:status-right","kind":"option","scope":"app","key":"status-right","value":["cwd","hints"]},
    \\{"id":"option:app:tab-style","kind":"option","scope":"app","key":"tab-style","value":"current"},
    \\{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":"always"},
    \\{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"vscode-dark"},
    \\{"id":"option:app:editor-mode","kind":"option","scope":"app","key":"editor-mode","value":"insert"},
    \\{"id":"option:app:activity-bar","kind":"option","scope":"app","key":"activity-bar","value":true},
    \\{"id":"option:app:explorer-auto","kind":"option","scope":"app","key":"explorer-auto","value":true},
    \\{"id":"option:app:font-family","kind":"option","scope":"app","key":"font-family","value":"Menlo"},
    \\{"id":"option:app:font-size","kind":"option","scope":"app","key":"font-size","value":14},
    \\{"id":"leader:app","kind":"leader","scope":"app","key":"`"}
    \\]}
;

fn chromeLines(out: []const u8, buf: []u8) ![]const u8 {
    // The arrangement lines only (topbar…tabstyle) — click points and
    // branch/cwd values are each instance's own business.
    const start = std.mem.indexOf(u8, out, "topbar") orelse return error.AssertFailed;
    const end = std.mem.indexOfPos(u8, out, start, "\ntabstyle ") orelse return error.AssertFailed;
    const line_end = std.mem.indexOfPos(u8, out, end + 1, "\n") orelse return error.AssertFailed;
    const s = out[start .. line_end + 1];
    if (s.len > buf.len) return error.AssertFailed;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

fn presetParity(gpa: std.mem.Allocator, bin: []const u8) !void {
    var toml_buf: [256]u8 = undefined;
    var graph_buf: [256]u8 = undefined;

    const a = try h.Instance.start(gpa, bin, .{ .config_extra = "preset = \"vscode\"" });
    const toml_chrome = blk: {
        defer {
            a.stop();
            a.deinit();
        }
        break :blk try chromeLines(try a.ctl("statusbar"), &toml_buf);
    };

    const b = try h.Instance.start(gpa, bin, .{ .env_json = parity_env_json });
    const graph_chrome = blk: {
        defer {
            b.stop();
            b.deinit();
        }
        break :blk try chromeLines(try b.ctl("statusbar"), &graph_buf);
    };

    if (!std.mem.eql(u8, toml_chrome, graph_chrome)) {
        std.debug.print("    preset drift!\n    toml:  {s}\n    graph: {s}\n", .{ toml_chrome, graph_chrome });
        return error.AssertFailed;
    }
}

// ---------------------------------------------------------- vscodefeel

/// The FEEL half of the vscode persona, blind: a file opens ready to
/// type (editor-mode = insert), what you type lands as text, ⌘S is
/// `:w` (one save path — the clobber check included), and the
/// activity-bar rail's explorer click opens the tree sidebar. The
/// LOOK half (Dark+ colors, the blue bar) is pixels; the persona
/// screenshot pass covers it.
fn vscodeFeel(gpa: std.mem.Allocator, bin: []const u8) !void {
    // explorer-auto OFF: the preset turns it on, and the suite runs
    // from inside rook's own repo, so the sidebar would already be up
    // — this scenario is about the RAIL opening it. Auto-open has its
    // own scenario, with launch directories it chooses.
    const app = try h.Instance.start(gpa, bin, .{
        .config_extra = "preset = \"vscode\"\nexplorer-auto = false",
    });
    defer {
        app.stop();
        app.deinit();
    }
    const sb = try app.ctl("statusbar");
    try h.expectContains(sb, "activitybar on", "the rail is declared");
    try h.expectContains(sb, "rail-explorer ", "the rail drew and reports click points");

    // A file opens IN INSERT MODE, and typing is typing.
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/feel.txt", .{app.dirPath()});
    try h.writeFile(path, "world\n");
    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("INSERT", 5_000);
    // The TAB STRIP is there from the FIRST file — VS Code's contract
    // (`buffer-line = always`), not rook's own "one chip is noise".
    var scr_buf: [16 * 1024]u8 = undefined;
    try h.expectContains(try app.screen(&scr_buf), "feel.txt \u{d7}", "one open file still gets a tab");
    _ = try app.ctl("type hello ");

    // ⌘S (keycode 1, cmd mask) — the GUI save speaks :w itself.
    _ = try app.ctl("nskey 1 100000 s");
    var content: [128]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 5_000) {
        const got = h.readFile(path, &content) catch "";
        if (std.mem.indexOf(u8, got, "hello world") != null) break;
        h.sleepMs(50);
        waited += 50;
    }
    try h.expectContains(try h.readFile(path, &content), "hello world", "cmd-s reached disk");

    // The rail's explorer icon opens the tree sidebar beside the file.
    try h.expectEq("panes before rail click", 1, try app.paneCount());
    const p = wkPoint(try app.ctl("statusbar"), "rail-explorer") orelse return error.AssertFailed;
    _ = try app.ctlFmt("click {d} {d}", .{ p[0], p[1] });
    waited = 0;
    while (waited < 3_000) {
        if ((try app.paneCount()) == 2) break;
        h.sleepMs(50);
        waited += 50;
    }
    try h.expectEq("panes after rail click", 2, try app.paneCount());
}

// --------------------------------------------------------- filefinder

/// ⌘P: the repo's files, fuzzy-matched and RANKED (a picker that
/// returns walk order is a picker you scroll). The two things a unit
/// test cannot reach are here: the index is the walk of a real tree
/// with real .gitignores in it, and Enter has to land the file in the
/// pane you were looking at.
fn fileFinder(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // A repo whose NESTED .gitignore hides a directory — the case that
    // made rook's own picker useless (26k vendored files from
    // app/.gitignore's `zig-pkg/`, root .gitignore silent about it).
    var proj_buf: [192]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{app.dirPath()});
    var p_buf: [256]u8 = undefined;
    try h.mkdirP(try std.fmt.bufPrint(&p_buf, "{s}/src", .{proj}));
    try h.mkdirP(try std.fmt.bufPrint(&p_buf, "{s}/sub/junk", .{proj}));
    try h.mkdirP(try std.fmt.bufPrint(&p_buf, "{s}/node_modules/dep", .{proj}));
    if (try h.runCmd(proj, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/README.md", .{proj}), "hi\n");
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/src/widget.zig", .{proj}), "const w = 1;\n");
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/src/other.zig", .{proj}), "const o = 2;\n");
    // The nested ignore, and something for it to hide.
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/sub/.gitignore", .{proj}), "junk/\n");
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/sub/keep.zig", .{proj}), "const k = 3;\n");
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/sub/junk/hidden.zig", .{proj}), "no\n");
    // …and the builtin skip list, which needs no .gitignore at all.
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/node_modules/dep/index.zig", .{proj}), "no\n");

    _ = try app.ctlFmt("type cd {s}/src", .{proj});
    _ = try app.ctl("enter");
    _ = try app.waitCtl("statusbar", "proj/src", 8000);

    // The index roots at the REPO (not the cwd) and skips both kinds
    // of ignored directory.
    _ = try app.ctl("run palette.files");
    const listed = try app.waitCtl("palette", "mode:files", 5000);
    // Four: widget.zig, other.zig, keep.zig, README.md. NOT the
    // sub/.gitignore itself — dotfiles are skipped, which is also
    // what keeps .git out without an entry for it.
    try h.expectContains(listed, "indexed:4\n", "exactly the four visible files");
    try h.expectContains(listed, "src/widget.zig", "the repo's files are there");
    try h.expectContains(listed, "sub/keep.zig", "a file beside a nested .gitignore survives");
    try h.expectNotContains(listed, "hidden.zig", "the NESTED .gitignore's directory is skipped");
    try h.expectNotContains(listed, "node_modules", "the builtin skip list holds");

    // Fuzzy AND ranked: "wid" is a subsequence of both widget.zig and
    // (via w-i-d) nothing else here, but the basename hit must lead.
    _ = try app.ctl("type wid");
    const ranked = try app.waitCtl("palette", "filter:wid", 3000);
    const star = std.mem.indexOf(u8, ranked, "*") orelse return error.AssertFailed;
    try h.expectContains(ranked[star..], "widget.zig", "the basename match ranks first");

    // Enter opens it HERE — the terminal pane takes it over, which is
    // what every other open in rook does (ctl edit, `rook edit`).
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "edit:widget.zig", 5000);
    try h.expectEq("no pane was split", 1, try app.paneCount());
    try h.expectContains(try app.ctl("dump"), "const w = 1;", "the file is open and showing");

    // VS Code's `>` prefix: ⌘P then ">" is the command palette.
    _ = try app.ctl("run palette.files");
    _ = try app.waitCtl("palette", "mode:files", 3000);
    _ = try app.ctl("type >");
    _ = try app.waitCtl("palette", "mode:commands", 3000);
    _ = try app.ctl("key 1b");
}

// ------------------------------------------------------------ findfile

/// Find in files (⌘⇧F): the query box, a scan that honours the file
/// index's ignore rules, results grouped by file, and Enter jumping
/// to the hit's LINE — the half a unit test cannot reach, because the
/// engine's rules are pure but "did the jump land" is the app.
fn findInFiles(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var proj_buf: [192]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{app.dirPath()});
    var p_buf: [256]u8 = undefined;
    try h.mkdirP(try std.fmt.bufPrint(&p_buf, "{s}/src", .{proj}));
    try h.mkdirP(try std.fmt.bufPrint(&p_buf, "{s}/node_modules/dep", .{proj}));
    if (try h.runCmd(proj, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;
    try h.writeFile(
        try std.fmt.bufPrint(&p_buf, "{s}/src/a.zig", .{proj}),
        "const x = 1;\n// needle here\nconst y = 2;\n",
    );
    try h.writeFile(
        try std.fmt.bufPrint(&p_buf, "{s}/src/b.zig", .{proj}),
        "fn f() void {}\n    needle indented\n",
    );
    try h.writeFile(try std.fmt.bufPrint(&p_buf, "{s}/README.md", .{proj}), "nothing to see\n");
    // Ignored, and full of what we are searching for: a search that
    // reaches it would drown every real hit.
    try h.writeFile(
        try std.fmt.bufPrint(&p_buf, "{s}/node_modules/dep/x.zig", .{proj}),
        "needle needle needle\n",
    );

    _ = try app.ctlFmt("type cd {s}/src", .{proj});
    _ = try app.ctl("enter");
    _ = try app.waitCtl("statusbar", "proj/src", 8000);

    _ = try app.ctl("run panel.search");
    _ = try app.waitCtl("sidepane", "panel:search", 5000);
    _ = try app.ctl("type needle");
    _ = try app.ctl("enter");
    const res = try app.waitCtl("sidepane", "results:2", 8000);

    try h.expectContains(res, "src/a.zig:2", "the hit carries its file and LINE");
    try h.expectContains(res, "src/b.zig:2", "and so does the one in the other file");
    try h.expectNotContains(res, "node_modules", "an ignored directory is not searched");
    // Indentation is trimmed off the shown line — a deeply indented
    // hit should show its code, not its whitespace.
    try h.expectContains(res, "needle indented", "the shown line is trimmed");
    // The box hands the keys to the list once there is a list.
    try h.expectContains(res, "typing:no", "results take the keys");

    // Hits arrive in PATH order (the index is sorted, so this holds
    // on any machine): a.zig is first, so j lands on b.zig.
    _ = try app.ctl("type j");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "edit:b.zig", 5000);
    try h.expectEq("no pane was split", 1, try app.paneCount());
    var buf: [16 * 1024]u8 = undefined;
    // 2:5, not 2:1 — the line is `    needle indented`, and the jump
    // lands on the MATCH. The shown text has its indent trimmed off,
    // so the column that travels is the file's, not the row's.
    try h.expectContains(try app.screen(&buf), "2:5", "the cursor landed on the hit itself");

    // ⌘⇧F again FOCUSES the box — it must never toggle away results
    // you are reading (the other tenants toggle; this one does not).
    _ = try app.ctl("run panel.search");
    const again = try app.waitCtl("sidepane", "typing:yes", 5000);
    try h.expectContains(again, "panel:search", "the panel is still open");
    try h.expectContains(again, "results:2", "and still holds its results");
}

// -------------------------------------------------------- explorerauto

/// `explorer-auto`: the sidebar is already there when the window
/// opens — but only inside a repo, and never holding the keys.
///
/// Both halves matter. A Dock launch lands in $HOME, and a sidebar
/// listing a home directory is noise; and a tree that took focus
/// would swallow the first thing typed into a terminal you just
/// opened.
fn explorerAuto(gpa: std.mem.Allocator, bin: []const u8) !void {
    // A repo to launch inside. Built before the instance, because the
    // launch cwd is the thing under test.
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-xauto-{d}", .{h.runPid()});
    // Each path gets its OWN buffer: both outlive the setup here and
    // are handed to instances later, so reusing one scribbles over a
    // launch directory that is still in use.
    var repo_buf: [256]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repo_buf, "{s}/repo", .{scratch});
    try h.mkdirP(repo);
    var plain_buf: [256]u8 = undefined;
    const plain = try std.fmt.bufPrint(&plain_buf, "{s}/plain", .{scratch});
    try h.mkdirP(plain);
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;
    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/README.md", .{repo}), "hi\n");

    {
        const app = try h.Instance.start(gpa, bin, .{
            .config_extra = "explorer-auto = true",
            .cwd = repo,
        });
        defer {
            app.stop();
            app.deinit();
        }
        try h.expectEq("the sidebar came up with the window", 2, try app.paneCount());
        try h.expectContains(try app.ctl("panes"), "edit:repo", "and it is the tree, rooted at the repo");
        // FOCUS stayed on the shell: what start() typed to settle the
        // instance reached a pty, which only happens if the tree did
        // not take the keys.
        _ = try app.ctl("type echo landed");
        _ = try app.ctl("enter");
        try app.waitText("landed", 5_000);
    }

    // Outside a repo: no sidebar. The gate is the whole difference
    // between orientation and clutter.
    {
        const app = try h.Instance.start(gpa, bin, .{
            .config_extra = "explorer-auto = true",
            .cwd = plain,
        });
        defer {
            app.stop();
            app.deinit();
        }
        try h.expectEq("no repo, no sidebar", 1, try app.paneCount());
    }
}

// ---------------------------------------------------------------- lsp

/// A language server, end to end: spawned lazily when a Go file opens,
/// its diagnostics converted into the buffer's own coordinates, shown
/// in the gutter, walkable with `]d`.
///
/// The server is FAKE — a shell script speaking real LSP framing.
/// Depending on a real gopls would make this suite fail on a fresh
/// machine for a reason that has nothing to do with rook, and the
/// protocol itself is already proven against the real one in
/// src/lsp.zig's own tests. What this proves is the wiring: that the
/// app finds a root, spawns for it, opens the document, routes the
/// publish to the pane showing that file, and converts the columns.
/// The graph a fake-server scenario runs on: one declared language
/// whose command re-execs THIS binary as a language server.
///
/// Written out rather than overridden by an environment variable —
/// which is what these scenarios used to do, back when rook carried a
/// catalog and `ROOK_LSP_GO` was the only way to point one of its three
/// languages somewhere else. There is no catalog now, so the fake
/// arrives the same way a real server does: as a declaration. The suite
/// exercises the real path instead of an escape hatch beside it.
fn langGraph(buf: []u8, name: []const u8, exts: []const u8, roots: []const u8, serves: []const u8) ![]const u8 {
    return langGraphWith(buf, name, exts, roots, serves, "");
}

/// The same, plus more nodes.
///
/// Needed because a graph SUPERSEDES config.toml rather than merging
/// with it: a scenario that declares a language and then sets an option
/// in `config_extra` silently loses the option. That cost an afternoon
/// once — format-on-save read as broken when it was simply never
/// configured.
fn langGraphWith(
    buf: []u8,
    name: []const u8,
    exts: []const u8,
    roots: []const u8,
    serves: []const u8,
    extra: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"rookEnvironment\":1,\"nodes\":[{{\"id\":\"language:{s}\",\"kind\":\"language\"," ++
            "\"scope\":\"app\",\"name\":\"{s}\",\"ext\":[{s}],\"roots\":[{s}]," ++
            "\"command\":[\"{s}\",\"--fake-lsp\",\"{s}\"]}}{s}{s}]}}",
        .{ name, name, exts, roots, self_exe, serves, if (extra.len > 0) "," else "", extra },
    );
}

fn lspScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lsp-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);

    // go.mod is what makes this directory a ROOT — the server is per
    // module, not per file, and finding it is the manager's job.
    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/go.mod", .{proj}), "module smoke\n\ngo 1.21\n");
    var main_buf: [288]u8 = undefined;
    const main_go = try std.fmt.bufPrint(&main_buf, "{s}/main.go", .{proj});
    // A plain string, not a multiline literal: the indent has to be a
    // real tab so the column under test is the one a Go file actually
    // has, and Zig's \\ literals refuse tabs.
    try h.writeFile(main_go, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(nope())\n}\n");
    // A second file, never opened in a pane. `gr` reaches it, and the
    // only way its text can appear in the results panel is off disk.
    var other_buf: [288]u8 = undefined;
    const other_go = try std.fmt.bufPrint(&other_buf, "{s}/other.go", .{proj});
    try h.writeFile(other_go, "package main\n\nfunc nope() int {\n\treturn 1\n}\n");

    // The fake server is THIS BINARY, re-exec'd. See fakeLsp below.
    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "go", "\".go\"", "\"go.mod\"", main_go);

    const app = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    // Nothing runs until a file of a known language opens. That is the
    // whole lazy-start promise, and it is cheap to check.
    try h.expectContains(try app.ctl("lsp"), "enabled:yes", "servers are on");
    {
        // Borrowed from the instance's own buffer — valid until the
        // next ctl call, which is why this is scoped.
        const before = try app.ctl("lsp");
        if (std.mem.indexOf(u8, before, "server go") != null) {
            std.debug.print("      a server spawned before any Go file was opened\n", .{});
            return error.AssertFailed;
        }
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{main_go}));

    // The publish arrives some frames later — poll rather than sleep.
    _ = try app.waitCtl("lsp", "pane gutter:yes errors:1", 8_000);

    const out = try app.ctl("lsp");
    try h.expectContains(out, "server go ready", "the server came up for this module");
    try h.expectContains(out, proj, "and it is rooted at the module, not at the file");
    try h.expectContains(out, "pane gutter:yes", "the sign column is reserved");
    // Column 13 in the protocol's UTF-16 is column 13 in bytes on this
    // (ASCII) line — what is under test is that the conversion HAPPENED
    // and landed on the right line, which is 1-based here.
    try h.expectContains(out, "pane err 6:13 undefined: nope", "the diagnostic reached the buffer's own coordinates");

    // `]d` walks to it. The cursor starts at the top of the file, so a
    // jump to line 6 is only possible if the editor has the diagnostic.
    _ = try app.ctl("type ]d");
    {
        const dump = try app.ctl("dump");
        try h.expectContains(dump, "undefined: nope", "and `]d` puts the message in the status line");
        // 6:17, not 6:13 — the status bar counts RENDER columns and the
        // line starts with a tab. The diagnostic's byte column is 13;
        // the two disagreeing is correct, and worth pinning.
        try h.expectContains(dump, "6:17", "having landed on the diagnostic, not near it");
    }

    // `K` — the answer arrives frames later, so wait for it rather than
    // assuming a timing.
    _ = try app.ctl("type K");
    {
        // Waited for on `lsp`, not on the grid: `func main()` is on
        // line 5 of the buffer, so waiting for THAT in the dump is a
        // wait that returns before the server has said anything. It
        // did, for as long as hover was a status line.
        const lsp2 = try app.waitCtl("lsp", "hover on", 5_000);
        try h.expectContains(lsp2, "lang:go", "wearing the language the fence claimed");
        const dump = try app.ctl("dump");
        // The markdown is taken apart, not printed. A fence, a backtick
        // and a pair of asterisks reaching the screen would each mean
        // the float is showing you the source of the answer.
        try h.expectNotContains(dump, "```", "the fence is markup, not content");
        try h.expectNotContains(dump, "**", "and so is the emphasis");
        try h.expectNotContains(dump, "https://pkg.go.dev", "a link keeps its label, not its URL");
        try h.expectContains(dump, "deliberate", "the emphasised word survives its markers");
        try h.expectContains(dump, "main on pkg.go.dev", "the link's label survives its URL");
        // A box, not a status line. The border is the whole difference
        // between a float over the buffer and a message under it.
        try h.expectContains(dump, "╭", "the float has a border");
        try h.expectContains(dump, "╰", "on both ends");
        // The author hard-wrapped their doc comment; the float rewraps
        // it to its own measure, so the source's line break is gone.
        try h.expectContains(dump, "which does not exist", "the doc comment reflowed rather than keeping the server's breaks");
    }


    // Any other key closes the float AND does what it was going to do —
    // nothing is swallowed. `0` is a motion, so the proof is that the
    // float is gone and the cursor moved in the same keystroke.
    _ = try app.ctl("type 0");
    {
        _ = try app.waitCtl("lsp", "hover off", 3_000);
        const dump = try app.ctl("dump");
        try h.expectNotContains(dump, "╭", "one keystroke closes it");
        try h.expectContains(dump, "6:1", "and the keystroke still moved the cursor");
    }

    // `gd` — a LocationLink, which is what a linkSupport client gets.
    // targetSelectionRange is the identifier: line 5 of the file (the
    // protocol's 0-based line 4), which is where the cursor must land.
    _ = try app.ctl("type gd");
    _ = try app.waitCtl("dump", "5:6", 5_000);

    // `gr` — every use, which is a LIST rather than a jump. Put the
    // cursor back on `nope` first: the list is titled with the word you
    // asked about, and `gd` left it on `main`.
    _ = try app.ctl("type ]d");
    _ = try app.ctl("type gr");
    {
        const panel = try app.waitCtl("sidepane", "kind:references", 8_000);
        try h.expectContains(panel, "label:nope", "the list is titled with the symbol, not the last thing typed");
        try h.expectContains(panel, "results:3 files:2", "three uses across two files");
        // Sorted and grouped by file, then by line, whatever order the
        // server answered in — and 1-based, like every line number a
        // human reads.
        try h.expectContains(panel, "main.go:5: func main() {", "the declaration, from the file in the pane");
        // The leading tab is trimmed off the shown text, and the line
        // number is still line 6.
        try h.expectContains(panel, "main.go:6: fmt.Println(nope())", "and the call below it");
        try h.expectContains(panel, "other.go:3: func nope() int {", "including a file no pane ever opened");
        // The list has the keys, not the box: you asked a question, and
        // the answer is something to walk.
        try h.expectContains(panel, "typing:no", "the list takes the keys, not the search box");
        try h.expectContains(panel, "focus:panel", "and the panel has the keyboard");
        // The selection starts at the top.
        try h.expectContains(panel, "*main.go:5", "the first row is selected");
    }

    // Walk to the third row and go there. That row is other.go — a file
    // no pane had open — so Enter has to OPEN a document, not just move
    // a cursor inside one.
    _ = try app.ctl("type jj");
    try h.expectContains(try app.ctl("sidepane"), "*other.go:3", "j walks the list");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "edit:other.go", 5_000);
    {
        var buf: [16 * 1024]u8 = undefined;
        // Line 3, and the column of `nope` within `func nope() int {` —
        // landing in column one and making you hunt for the symbol is
        // the whole reason the column travels with the row.
        try h.expectContains(try app.screen(&buf), "3:6", "landing on the symbol, not at the start of its line");
    }

    // `gR` — rename across files, one of which nobody has open.
    //
    // Back to main.go first, which also closes other.go: the two halves
    // of the apply (an open document edited in place, a closed file
    // written to disk) are only distinguishable if exactly one of them
    // is on screen.
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{main_go}));
    _ = try app.waitCtl("panes", "edit:main.go", 5_000);
    _ = try app.ctl("type ]d");
    _ = try app.ctl("type gR");
    {
        var buf: [16 * 1024]u8 = undefined;
        // Prefilled with the current name — a rename is usually a small
        // edit to a name you can already see.
        try h.expectContains(try app.screen(&buf), "rename to: nope", "the prompt opens on the word under the cursor");
    }
    // Four backspaces clear the prefill without closing the prompt —
    // the fifth would have, which is how you back out of a rename you
    // opened by mistake.
    for (0..4) |_| _ = try app.ctl("key 7f");
    _ = try app.ctl("type wibble");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("dump", "renamed to wibble", 8_000);

    {
        var buf: [16 * 1024]u8 = undefined;
        const screen = try app.screen(&buf);
        try h.expectContains(screen, "wibble", "the open buffer holds the new name");
        try h.expectNotContains(screen, "nope()", "and not the old one");
    }
    // The open document is left UNSAVED — the change is in front of you
    // and `u` takes it back. The closed one had nowhere to show a dirty
    // flag, so it was written.
    try h.expectContains(try app.ctl("docs"), "modified:yes", "the file you can see is dirty, not written behind your back");
    {
        var disk: [512]u8 = undefined;
        const got = try h.readFile(other_go, &disk);
        try h.expectContains(got, "func wibble() int", "the file no pane had open was written to disk");
    }
    {
        // Still the file on disk, untouched: the open half of a rename
        // is exactly as reviewable as any other edit.
        var disk: [512]u8 = undefined;
        const got = try h.readFile(main_go, &disk);
        try h.expectContains(got, "nope()", "the open file is not written until you say so");
    }

    // One undo group per file: `u` takes back this pane's whole share
    // of the rename, not one occurrence of it.
    _ = try app.ctl("type u");
    {
        var buf: [16 * 1024]u8 = undefined;
        try h.expectContains(try app.screen(&buf), "nope()", "u takes the whole rename back in one step");
    }
    try h.expectContains(try app.ctl("docs"), "modified:no", "and undoing all of it leaves the buffer clean again");

    // A rename the server wants to carry out by MOVING a file. rook
    // cannot, and the failure mode to avoid is doing the text half
    // anyway — a repo naming a file that never moved.
    _ = try app.ctl("type ]d");
    _ = try app.ctl("type gR");
    for (0..4) |_| _ = try app.ctl("key 7f");
    _ = try app.ctl("type movefile");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("dump", "moves files", 8_000);
    {
        var buf: [16 * 1024]u8 = undefined;
        try h.expectContains(try app.screen(&buf), "nope()", "the refused rename left the buffer alone");
    }
    try h.expectContains(try app.ctl("docs"), "modified:no", "not even a little bit of it was applied");

    // ctrl-n — the buffer's own words instantly, the server's a few
    // frames later, in one ring.
    _ = try app.ctl("type Go");   // a line to type on, away from the code
    _ = try app.ctl("type Pri");
    _ = try app.ctl("key 0e");
    {
        // The ring answers from the BUFFER without waiting: `Println`
        // is in this file, so it is in hand on the keystroke.
        const now = try app.ctl("lsp");
        try h.expectContains(now, "cpl on prefix:Pri", "the ring opened on what was typed");
        try h.expectContains(now, "cpl Println", "with the buffer's own word, on the keystroke");
    }
    {
        // …and the server's answer folds in behind it.
        const done = try app.waitCtl("lsp", "semantic:yes", 8_000);
        // sortText 10 beats 20, so Println leads even though Printf
        // sorts first alphabetically.
        try h.expectContains(done, "*cpl Println\tfunc(...any)", "the server's order, and its signature");
        try h.expectContains(done, " cpl Printf\tfunc(string, ...any)", "with the rest of its answer under it");
        // The buffer's own bare `Println` was dropped as the duplicate,
        // so exactly one row carries that word — the one with a type.
        try h.expectNotContains(done, "cpl Println\t\n", "the scraped copy went, not the described one");
    }
    {
        var buf: [16 * 1024]u8 = undefined;
        try h.expectContains(try app.screen(&buf), "func(...any)", "and the menu is on screen with it");
    }
    // WIDER, on purpose. The sandbox window is 56 columns and the list
    // alone is 40 of them, so there is genuinely no room for a panel
    // beside it — which is the behaviour a unit test already pins. What
    // needs a real app is the panel actually DRAWING, and that needs a
    // window somebody would plausibly edit in.
    //
    // Fullscreen rather than `winsize`: that verb reports ok and does
    // nothing in this build (docs/man/rook-ctl.7 documents it, and it is
    // its own bug). Toggled back below, so nothing after this cares.
    _ = try app.ctl("fullscreen");
    _ = try app.waitCtl("panes", "grid 1", 8_000);
    // The panel beside the list. `Println` carried its prose IN the
    // list, the way zls does, so it is up as soon as the answer is.
    {
        const panel = try app.ctl("lsp");
        try h.expectContains(panel, "cpl doc card ", "the panel opened beside the list");
        var buf: [16 * 1024]u8 = undefined;
        try h.expectContains(
            try app.screen(&buf),
            // One ROW's worth: the panel wraps at its own width, and
            // `screen` joins rows, so a phrase that straddles the fold
            // is never contiguous in it.
            "formats using the default formats",
            "with the prose the server sent, laid out as markdown",
        );
    }
    // Cycling takes the next one.
    _ = try app.ctl("key 0e");
    try h.expectContains(try app.ctl("lsp"), "*cpl Printf", "ctrl-n walks the menu");
    // ...and `Printf` had NO prose in the list — only the opaque `data`
    // its server keys a resolve on. This is the gopls case, and it is
    // the one that proves the item was handed back WHOLE: the fake
    // refuses to resolve anything that arrives without its `data`.
    {
        const resolved = try app.waitCtl("lsp", "cpl Printf\tfunc(string, ...any)\tdoc", 5_000);
        try h.expectContains(resolved, "cpl doc card ", "and the panel followed the selection");
        var buf: [16 * 1024]u8 = undefined;
        try h.expectContains(
            try app.screen(&buf),
            "format specifier",
            "showing prose that only a resolve could have fetched",
        );
    }
    // Back out of fullscreen. Not waited on and not asserted: AppKit
    // restores to a frame of its own choosing, and nothing below this
    // line reads the screen — every assertion left is `ctl lsp` or a
    // file on disk.
    _ = try app.ctl("fullscreen");
    // Typing ends THAT ring — the candidates were built against text
    // that has moved — and opens a fresh one for the longer word, which
    // is what makes the menu narrow as you type rather than vanish.
    // `auto` marks the difference: nothing has been written.
    _ = try app.ctl("type x");
    {
        const after = try app.ctl("lsp");
        try h.expectContains(after, "cpl on prefix:Printfx", "typing reopens on the longer word");
        try h.expectContains(after, "auto", "as an offer, not as an edit");
    }
    // A character that cannot start an identifier closes it for good.
    _ = try app.ctl("type ,");
    try h.expectContains(try app.ctl("lsp"), "cpl off", "and punctuation closes it");

    // A dot is the other way in. It opens the menu with NO prefix and
    // no buffer words: after a dot the useful answer is entirely the
    // server's, and every word in the file would be noise.
    _ = try app.ctl("type fmt.");
    {
        // Waited on the MEMBERS: the ring opens instantly saying
        // `asking`, and the answer is a round trip behind it.
        const dot = try app.waitCtl("lsp", "cpl Println", 5_000);
        try h.expectContains(dot, "cpl on prefix: ", "the dot opened it with no prefix");
        try h.expectContains(dot, "auto", "and having written nothing");
        // And the buffer's own words stayed out of it: `nope` is on the
        // line above and would be in any keyword-scrape.
        try h.expectNotContains(dot, "cpl nope", "and none of the buffer's own");
    }
    {
        // The file it WOULD have written is untouched too — a refusal
        // that still edited the half it could reach is the whole thing
        // this guard exists to prevent.
        var disk: [512]u8 = undefined;
        const got = try h.readFile(other_go, &disk);
        try h.expectContains(got, "func wibble() int", "and the closed file still holds only the earlier rename");
    }
}



// ------------------------------------------------------------ lspformat

/// `editor-format-on-save`: the whole point, and the whole risk.
///
/// `:w` stops being synchronous when this is on — it asks a subprocess
/// how the file should look and writes what comes back. So the two
/// things worth proving are that the formatted text is what lands, and
/// that a formatter which never answers costs you a pause rather than
/// your work.
fn lspFormat(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lspfmt-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);
    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/go.mod", .{proj}), "module fmtsmoke\n\ngo 1.21\n");

    // Line 9 (the protocol's 0-based 8) carries the double space the
    // fake formatter collapses.
    const body = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(1)\n}\n\nvar x  = 1\n";
    var main_buf: [288]u8 = undefined;
    const main_go = try std.fmt.bufPrint(&main_buf, "{s}/main.go", .{proj});
    try h.writeFile(main_go, body);

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraphWith(&graph_buf, "go", "\".go\"", "\"go.mod\"", main_go,
        "{\"id\":\"option:app:editor-format-on-save\",\"kind\":\"option\",\"scope\":\"app\",\"key\":\"editor-format-on-save\",\"value\":true}");

    const app = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{main_go}));
    try app.waitText("var x", 5_000);

    // Make a change of our own, so the write has something to write and
    // the formatter has something to fix beside it.
    _ = try app.ctl("type GoZZ");
    _ = try app.ctl("press ESC");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("dump", "wrote main.go", 8_000);

    {
        var disk: [512]u8 = undefined;
        const got = try h.readFile(main_go, &disk);
        // The formatter's edit landed…
        try h.expectContains(got, "var x = 1", "the formatter's edit is in the file that was written");
        try h.expectNotContains(got, "var x  = 1", "and the text it replaced is not");
        // …and so did ours. A format that threw away the edit you were
        // saving would be worse than no format at all.
        try h.expectContains(got, "ZZ", "along with the edit you actually made");
    }
    try h.expectContains(try app.ctl("docs"), "modified:no", "the buffer is clean — the write really happened");

    // ---- and now a formatter that never answers ----
    var slow_buf: [288]u8 = undefined;
    const slow_go = try std.fmt.bufPrint(&slow_buf, "{s}/slow.go", .{proj});
    try h.writeFile(slow_go, "package main\n\nvar y  = 2\n");
    var slowgraph_buf: [1024]u8 = undefined;
    const slowgraph = try langGraphWith(&slowgraph_buf, "go", "\".go\"", "\"go.mod\"", slow_go,
        "{\"id\":\"option:app:editor-format-on-save\",\"kind\":\"option\",\"scope\":\"app\",\"key\":\"editor-format-on-save\",\"value\":true}");

    const app2 = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = slowgraph,
    });
    defer {
        app2.stop();
        app2.deinit();
    }
    _ = try app2.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{slow_go}));
    try app2.waitText("var y", 5_000);
    _ = try app2.ctl("type GoQQ");
    _ = try app2.ctl("press ESC");
    _ = try app2.ctl("type :w");
    _ = try app2.ctl("enter");

    // The deadline is 1.5s, so this waits past it. What must NOT happen
    // is the save quietly never arriving.
    const said = try app2.waitCtl("dump", "wrote slow.go", 8_000);
    try h.expectContains(said, "timed out", "and it says why it went out unformatted");
    {
        var disk: [512]u8 = undefined;
        const got = try h.readFile(slow_go, &disk);
        try h.expectContains(got, "QQ", "the edit was written even though nothing formatted it");
        // Unformatted, and that is the correct outcome: rook does not
        // have an answer, so it does not invent one.
        try h.expectContains(got, "var y  = 2", "with the layout untouched");
    }
    try h.expectContains(try app2.ctl("docs"), "modified:no", "and the buffer is clean, not left dirty forever");
}


// ------------------------------------------------------------ lspaction

/// `ga` — what the server can do about this line.
///
/// Three rows, and the differences between them are the whole feature.
/// One carries its edit and applies on Enter. One was DEFERRED — the
/// server kept the edit back and handed over a token, so picking it
/// costs a second round trip through codeAction/resolve. One is a
/// legacy Command, which rook cannot run and says so rather than
/// offering a row that quietly does nothing.
fn lspAction(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lspact-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);
    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/go.mod", .{proj}), "module actsmoke\n\ngo 1.21\n");
    var main_buf: [288]u8 = undefined;
    const main_go = try std.fmt.bufPrint(&main_buf, "{s}/main.go", .{proj});
    try h.writeFile(main_go, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(nope())\n}\n");

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "go", "\".go\"", "\"go.mod\"", main_go);
    const app = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{main_go}));
    // Wait for the diagnostic: it is the CONTEXT a quick fix hangs off,
    // and asking before it lands would ask a different question.
    _ = try app.waitCtl("lsp", "pane gutter:yes errors:1", 8_000);
    _ = try app.ctl("type ]d");

    _ = try app.ctl("type ga");
    {
        const pal = try app.waitCtl("palette", "mode:actions", 8_000);
        try h.expectContains(pal, "offered:3", "all three are offered, including the one rook cannot run");
        try h.expectContains(pal, "*Replace nope with fixed\tquickfix", "the quick fix, selected");
        // The flags are the point: they are what tell a row that costs
        // a round trip from one that cannot be run at all.
        try h.expectContains(pal, "Organize imports\tsource.organizeImports\tdeferred", "the deferred one is marked");
        try h.expectContains(pal, "Run go mod tidy\t\tcommand", "and the legacy Command is marked unrunnable");
    }

    // Enter applies the one that carried its edit — no second round trip.
    _ = try app.ctl("enter");
    _ = try app.waitCtl("dump", "fixed()", 5_000);
    {
        var buf: [16 * 1024]u8 = undefined;
        const screen = try app.screen(&buf);
        try h.expectContains(screen, "applied Replace nope with fixed", "and says what it applied");
        try h.expectNotContains(screen, "nope()", "the old text is gone");
    }

    // The DEFERRED one: filter to it, and picking it has to resolve
    // before there is anything to apply.
    _ = try app.ctl("type ga");
    _ = try app.waitCtl("palette", "mode:actions", 8_000);
    _ = try app.ctl("type organi");
    try h.expectContains(try app.ctl("palette"), "*Organize imports", "the filter finds it by title");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("dump", "// tidied", 8_000);
    try h.expectContains(try app.ctl("dump"), "// tidied", "the resolved edit landed");

    // And the Command: offered, then honestly refused.
    _ = try app.ctl("type ga");
    _ = try app.waitCtl("palette", "mode:actions", 8_000);
    _ = try app.ctl("type tidy");
    _ = try app.ctl("enter");
    {
        var buf: [16 * 1024]u8 = undefined;
        const screen = try app.screen(&buf);
        try h.expectContains(screen, "rook cannot do yet", "a command rook cannot run says so");
        // Nothing changed for it.
        try h.expectContains(screen, "// tidied", "and the file is exactly as the last action left it");
    }
}

// ------------------------------------------------------- the fake server

/// This binary's own path, for scenarios that re-exec it.
var self_exe: []const u8 = "";
var self_exe_buf: [2048]u8 = undefined;

/// A language server made of the client's own framing code.
///
/// It answers initialize, publishes one error against `target`, and
/// serves hover and definition. Real LSP over real stdio — the app
/// cannot tell it from gopls, which is the point: a scenario that
/// needed a Go toolchain installed would fail on a fresh machine for a
/// reason that has nothing to do with rook.
///
/// It parses with lsp.parseFrame, the same function the client uses, so
/// the fake cannot drift into speaking a dialect the client doesn't.
fn fakeLsp(gpa: std.mem.Allocator, target: []const u8) !void {
    var in: std.ArrayListUnmanaged(u8) = .empty;
    defer in.deinit(gpa);
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = h.readStdin(&buf);
        if (n <= 0) return; // client closed: we are done
        try in.appendSlice(gpa, buf[0..@intCast(n)]);

        while (true) {
            const frame = lsp.parseFrame(in.items) catch return orelse break;
            try fakeHandle(gpa, frame.body, target);
            const used = frame.total;
            if (used >= in.items.len) {
                in.clearRetainingCapacity();
            } else {
                std.mem.copyForwards(u8, in.items[0 .. in.items.len - used], in.items[used..]);
                in.shrinkRetainingCapacity(in.items.len - used);
            }
        }
    }
}

/// What the fake server has heard on workspace/didChangeWatchedFiles.
/// Process-global is fine: in --fake-lsp mode this process IS one
/// server, serving one session.
var fake_watched_log: [32 * 1024]u8 = undefined;
var fake_watched_len: usize = 0;

fn fakeSend(gpa: std.mem.Allocator, body: []const u8) !void {
    var hdr: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len});
    h.writeStdout(head);
    h.writeStdout(body);
    _ = gpa;
}

fn fakeHandle(gpa: std.mem.Allocator, body: []const u8, target: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const method = switch (obj.get("method") orelse .null) {
        .string => |m| m,
        else => return,
    };
    const id: ?i64 = switch (obj.get("id") orelse .null) {
        .integer => |i| i,
        else => null,
    };

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();

    if (std.mem.eql(u8, method, "initialize")) {
        // resolveProvider is what tells the client an item's prose is
        // worth asking about one row at a time.
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":" ++
                "{{\"completionProvider\":{{\"resolveProvider\":true}}}}}}}}",
            .{id orelse 1},
        );
        try fakeSend(gpa, w.written());
        // The diagnostic, unprompted — which is how a real server does
        // it: nobody asks for diagnostics, they arrive.
        w.clearRetainingCapacity();
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{" ++
                "\"uri\":\"file://{s}\",\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":5,\"character\":13}}," ++
                "\"end\":{{\"line\":5,\"character\":17}}}},\"severity\":1,\"source\":\"fake\"," ++
                "\"message\":\"undefined: nope\"}}]}}}}",
            .{target},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        // The watcher registrations, the moment the spec allows them.
        // Two on purpose: a bare glob that wants everything, and a
        // RelativePattern masked to create|delete (kind 5) — the two
        // shapes gopls actually sends, and the mask is the half a
        // client gets wrong silently.
        const dir = std.fs.path.dirname(target) orelse "/";
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"client/registerCapability\",\"params\":{{" ++
                "\"registrations\":[{{\"id\":\"w-go\",\"method\":\"workspace/didChangeWatchedFiles\"," ++
                "\"registerOptions\":{{\"watchers\":[{{\"globPattern\":\"**/*.go\"}}]}}}}," ++
                "{{\"id\":\"w-mod\",\"method\":\"workspace/didChangeWatchedFiles\"," ++
                "\"registerOptions\":{{\"watchers\":[{{\"globPattern\":{{\"baseUri\":\"file://{s}\"," ++
                "\"pattern\":\"*.mod\"}},\"kind\":5}}]}}}}]}}}}",
            .{dir},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
        // The receipt: everything heard, rewritten WHOLE each time, so
        // a scenario can assert absences as well as arrivals.
        const room = fake_watched_log.len - fake_watched_len;
        if (body.len + 1 <= room) {
            @memcpy(fake_watched_log[fake_watched_len..][0..body.len], body);
            fake_watched_log[fake_watched_len + body.len] = '\n';
            fake_watched_len += body.len + 1;
        }
        var pbuf: [320]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}.watched", .{target}) catch return;
        h.writeFile(p, fake_watched_log[0..fake_watched_len]) catch {};
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        // Shaped like gopls: a fenced signature, a doc comment the
        // author hard-wrapped at their own margin, inline markup, and a
        // pkg.go.dev link on the end. Everything the float has to take
        // apart is in here on purpose.
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"markdown\"," ++
                "\"value\":\"```go\\nfunc main()\\n```\\n\\nmain is the entry point. It calls `nope`,\\n" ++
                "which does not exist, and that is **deliberate**.\\n\\n" ++
                "[`main` on pkg.go.dev](https://pkg.go.dev/main)\"}}}}}}",
            .{id orelse 0},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        // A LocationLink, because that is what a server answers a
        // client that declared linkSupport — and rook does.
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"targetUri\":\"file://{s}\"," ++
                "\"targetRange\":{{\"start\":{{\"line\":4,\"character\":0}},\"end\":{{\"line\":6,\"character\":1}}}}," ++
                "\"targetSelectionRange\":{{\"start\":{{\"line\":4,\"character\":5}},\"end\":{{\"line\":4,\"character\":9}}}}}}]}}",
            .{ id orelse 0, target },
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/references")) {
        // Three uses in two files, and deliberately NOT in sorted
        // order: grouping and ordering are the client's job, and a
        // server that handed them over already sorted would hide it.
        //
        // The sibling is never opened in a pane — its line text can only
        // reach the panel by being read off disk, which is the half of
        // this that a unit test cannot reach.
        const dir = std.fs.path.dirname(target) orelse "/";
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
                "{{\"uri\":\"file://{s}/other.go\",\"range\":{{\"start\":{{\"line\":2,\"character\":5}}," ++
                "\"end\":{{\"line\":2,\"character\":9}}}}}}," ++
                "{{\"uri\":\"file://{s}\",\"range\":{{\"start\":{{\"line\":5,\"character\":13}}," ++
                "\"end\":{{\"line\":5,\"character\":17}}}}}}," ++
                "{{\"uri\":\"file://{s}\",\"range\":{{\"start\":{{\"line\":4,\"character\":5}}," ++
                "\"end\":{{\"line\":4,\"character\":9}}}}}}]}}",
            .{ id orelse 0, dir, target, target },
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        // Three shapes on purpose: one action that carries its edit,
        // one the server DEFERRED (no edit, just `data` to resolve
        // with), and one legacy Command — a title with a string
        // `command` and nothing to apply. A client that read the third
        // as an action would show a row that does nothing when picked.
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
                "{{\"title\":\"Replace nope with fixed\",\"kind\":\"quickfix\",\"edit\":{{\"changes\":{{" ++
                "\"file://{s}\":[{{\"range\":{{\"start\":{{\"line\":5,\"character\":13}}," ++
                "\"end\":{{\"line\":5,\"character\":17}}}},\"newText\":\"fixed\"}}]}}}}}}," ++
                "{{\"title\":\"Organize imports\",\"kind\":\"source.organizeImports\"," ++
                "\"data\":{{\"tok\":\"deferred-42\"}}}}," ++
                "{{\"title\":\"Run go mod tidy\",\"command\":\"gopls.tidy\",\"arguments\":[]}}]}}",
            .{ id orelse 0, target },
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "codeAction/resolve")) {
        // The action comes BACK to be resolved, `data` and all — which
        // is the only reason the client kept the raw bytes. Refuse to
        // fill in an edit unless the token made the round trip.
        const body_has_token = std.mem.indexOf(u8, body, "deferred-42") != null;
        if (!body_has_token) {
            try w.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0});
            try fakeSend(gpa, w.written());
            return;
        }
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"title\":\"Organize imports\"," ++
                "\"kind\":\"source.organizeImports\",\"edit\":{{\"documentChanges\":[" ++
                "{{\"textDocument\":{{\"uri\":\"file://{s}\",\"version\":1}},\"edits\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":1,\"character\":0}}," ++
                "\"end\":{{\"line\":1,\"character\":0}}}},\"newText\":\"// tidied\\n\"}}]}}]}}}}}}",
            .{ id orelse 0, target },
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        // Collapse the double space on line 8 of the scenario's file.
        // A real formatter rewrites more, but one edit is enough to
        // prove the round trip, the apply and the write that follows.
        //
        // A file whose name ends `slow.go` is never answered at all —
        // which is how the scenario reaches the deadline, and the only
        // way to test that a save survives a formatter that does not.
        if (std.mem.endsWith(u8, target, "slow.go")) return;
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"range\":{{" ++
                "\"start\":{{\"line\":8,\"character\":5}},\"end\":{{\"line\":8,\"character\":7}}}}," ++
                "\"newText\":\" \"}}]}}",
            .{id orelse 0},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        // A CompletionList, deliberately out of relevance order and
        // with sortText disagreeing with the alphabet: the client sorts
        // by what the SERVER said, and a client that sorted by label
        // would pass this test by accident.
        //
        // `Println` is also a word already in the scenario's buffer, so
        // it is the one that proves the semantic item wins the
        // duplicate and brings its signature with it.
        //
        // The two rows differ in WHERE their prose comes from, which is
        // the whole of the documentation panel's protocol story.
        // `Println` carries its documentation in the list, the way zls
        // does. `Printf` carries none and an opaque `data` instead, the
        // way gopls and rust-analyzer do — its prose costs a resolve.
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"isIncomplete\":false,\"items\":[" ++
                "{{\"label\":\"Printf\",\"kind\":3,\"detail\":\"func(string, ...any)\"," ++
                "\"sortText\":\"20\",\"data\":{{\"tok\":7}}}}," ++
                "{{\"label\":\"Println\",\"kind\":3,\"detail\":\"func(...any)\",\"sortText\":\"10\"," ++
                "\"documentation\":{{\"kind\":\"markdown\"," ++
                "\"value\":\"Println formats using the default formats and writes to standard output.\"}}}}]}}}}",
            .{id orelse 0},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "completionItem/resolve")) {
        // The prose the list left out. A server keys this on the `data`
        // it attached, so the client must hand the item back whole —
        // refusing anything without it is how this scenario proves the
        // raw item survived the round trip rather than being rebuilt.
        const params = obj.get("params") orelse .null;
        const data = switch (params) {
            .object => |o| o.get("data") orelse .null,
            else => .null,
        };
        if (data == .null) {
            try w.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id orelse 0});
            try fakeSend(gpa, w.written());
            return;
        }
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"label\":\"Printf\",\"kind\":3," ++
                "\"detail\":\"func(string, ...any)\",\"documentation\":{{\"kind\":\"markdown\"," ++
                "\"value\":\"Printf formats according to a format specifier.\"}}}}}}",
            .{id orelse 0},
        );
        try fakeSend(gpa, w.written());
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/rename")) {
        // Echo the name the client asked for, so the scenario can
        // assert on the text that actually lands rather than on a
        // constant this file chose.
        const new_name = switch (obj.get("params") orelse .null) {
            .object => |po| switch (po.get("newName") orelse .null) {
                .string => |s| s,
                else => "RENAMED",
            },
            else => "RENAMED",
        };
        // documentChanges, which is what a client declaring support for
        // it gets from gopls — and the shape that can also carry file
        // operations. Renaming to `movefile` asks for one, which is how
        // the scenario reaches the refusal: gopls really does answer
        // this way when the symbol owns its file, and applying the text
        // half alone would leave a repo naming a file that never moved.
        const dir = std.fs.path.dirname(target) orelse "/";
        const file_op = std.mem.eql(u8, new_name, "movefile");
        try w.writer.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"documentChanges\":[" ++
                "{{\"textDocument\":{{\"uri\":\"file://{s}\",\"version\":1}},\"edits\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":5,\"character\":13}}," ++
                "\"end\":{{\"line\":5,\"character\":17}}}},\"newText\":\"{s}\"}}]}}," ++
                "{{\"textDocument\":{{\"uri\":\"file://{s}/other.go\",\"version\":1}},\"edits\":[" ++
                "{{\"range\":{{\"start\":{{\"line\":2,\"character\":5}}," ++
                "\"end\":{{\"line\":2,\"character\":9}}}},\"newText\":\"{s}\"}}]}}",
            .{ id orelse 0, target, new_name, dir, new_name },
        );
        if (file_op) {
            try w.writer.print(
                ",{{\"kind\":\"rename\",\"oldUri\":\"file://{s}/other.go\"," ++
                    "\"newUri\":\"file://{s}/moved.go\"}}",
                .{ dir, dir },
            );
        }
        try w.writer.writeAll("]}}");
        try fakeSend(gpa, w.written());
        return;
    }
    // Anything else with an id still has to be answered or the client
    // waits forever — the same rule the client obeys in the other
    // direction.
    if (id) |i| {
        try w.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{i});
        try fakeSend(gpa, w.written());
    }
}


// ------------------------------------------------------------ lsppython

/// The second language, which is the point of it.
///
/// The plan said adding a language should be DATA — a row in the
/// catalog, not new mechanism — and a catalog with one entry proves
/// nothing. This asserts the parts that are genuinely per-language and
/// nothing else: the extension maps, the ROOT comes from that language's
/// own marker (pyproject.toml, not go.mod), and the diagnostics land in
/// the same gutter through the same path.
///
/// What is NOT data — that a Python server has to be told which
/// interpreter to use — is unit-tested in lspmgr.zig, because it needs a
/// virtualenv rather than a fake server.
fn lspPython(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lsppy-{d}", .{h.runPid()});
    // The file lives one directory DOWN from the marker, so a root found
    // by walking up is distinguishable from one that just used the
    // file's own directory.
    var pkg_buf: [256]u8 = undefined;
    const pkg = try std.fmt.bufPrint(&pkg_buf, "{s}/proj/demo", .{scratch});
    try h.mkdirP(pkg);
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});

    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/pyproject.toml", .{proj}), "[project]\nname = \"demo\"\n");
    var app_buf: [288]u8 = undefined;
    const app_py = try std.fmt.bufPrint(&app_buf, "{s}/app.py", .{pkg});
    // Shaped so the fake's fixed position (line 5, char 13) is a real
    // place in THIS file too — the fake serves both scenarios and a
    // diagnostic clamped to the last line would prove less.
    try h.writeFile(app_py, "import json\n\n\ndef main() -> None:\n    \"\"\"Doc.\"\"\"\n    print(nope())\n");

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "python", "\".py\",\".pyi\"", "\"pyproject.toml\",\"setup.py\"", app_py);

    const app = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{app_py}));
    _ = try app.waitCtl("lsp", "pane gutter:yes errors:1", 8_000);

    const out = try app.ctl("lsp");
    // The whole server line, root and all: asserting on the root alone
    // is not enough, because the FILE line legitimately contains the
    // package directory and would match either way.
    var want_buf: [320]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "server python ready {s}\n", .{proj});
    try h.expectContains(out, want, "rooted at the pyproject, not at the file's own directory");
    try h.expectContains(out, "pane err 6:13 undefined: nope", "same conversion, same gutter, different language");

    // And the Go server did NOT start: a .py file is not gopls's
    // business, and a catalog that spawned everything would be a
    // catalog that costs a second per language you never use.
    try h.expectNotContains(out, "server go", "no server for a language this project has no files in");
}


// ---------------------------------------------------------------- lspts

/// TypeScript, where the per-language parts are sharper than Python's.
///
/// Two things this pins that no other scenario can. The ROOT is the
/// tsconfig, not the package.json above it — a monorepo has one
/// package.json per workspace and the tsconfig is what says which files
/// are one program, so rooting at the wrong one gets a server that
/// cannot resolve half your imports. And .ts and .tsx share ONE server
/// while taking different GRAMMARS: the split is about `<T>x` being a
/// type assertion in one and a JSX element in the other, which is a
/// parser's problem and never a server's.
/// A pane that retargets ITSELF still gets its language server.
///
/// The app attaches a server when IT opens a document. But a pane can
/// change what it holds without the app doing anything: Enter on a row
/// of an in-pane file tree, or `:e` typed into the editor. Both go
/// through Editor.open and nowhere near the app's open path, so for as
/// long as there was no seam there, every file opened from the tree
/// arrived with no server at all and every `:e` arrived still wired to
/// the PREVIOUS file's.
///
/// The other half is the path. `re .` anchors a tree at `<cwd>/.`, and
/// its rows join through that dot — a spelling that is a second
/// document as far as the doc registry is concerned, and one gopls
/// answers with "No packages found for open file".
/// OSC 9;4 — the ConEmu progress protocol Claude Code emits. The
/// sequence is typed INTO the shell as a printf, which is exactly how
/// a real program raises it; the assertions read the two text mirrors
/// of the chrome: `panes` (raw per-session state) and `tabs` (the
/// 2Hz-drained aggregate the chip actually draws). Set with a number,
/// error keeping its number, indeterminate as ~, then remove — and
/// remove must CLEAR, which is the half a stuck progress bar gets
/// wrong.
fn progressScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    var buf: [8 * 1024]u8 = undefined;
    _ = try app.ctl("type echo ready");
    _ = try app.ctl("enter");
    try app.waitText("ready", 5_000);

    // set 42
    _ = try app.ctl("type printf '\\033]9;4;1;42\\007'");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "prog:42", 5_000);
    _ = try app.waitCtl("tabs", "prog:42", 5_000);

    // error keeps its number — a stalled 80% is still an 80%.
    _ = try app.ctl("type printf '\\033]9;4;2;80\\007'");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "prog:80", 5_000);

    // indeterminate: running, no number.
    _ = try app.ctl("type printf '\\033]9;4;3\\007'");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("panes", "prog:~", 5_000);

    // remove — and the mirrors must actually clear, tabs included.
    _ = try app.ctl("type printf '\\033]9;4;0\\007'");
    _ = try app.ctl("enter");
    var waited: u32 = 0;
    while (waited < 5_000) : (waited += 100) {
        const pane_list = try app.ctl("panes");
        if (std.mem.indexOf(u8, pane_list, "prog:") == null) {
            const tab_list = try app.ctl("tabs");
            if (std.mem.indexOf(u8, tab_list, "prog:") == null) break;
        }
        h.sleepMs(100);
    }
    try h.expect(std.mem.indexOf(u8, try app.ctl("panes"), "prog:") == null, "remove cleared the pane's progress", .{});
    try h.expect(std.mem.indexOf(u8, try app.ctl("tabs"), "prog:") == null, "remove cleared the tab's progress", .{});
    _ = try app.screen(&buf);
}

/// Poll a receipt file for a substring. The fake server rewrites it
/// whole on every notification, so a read that misses just tries again.
fn waitReceipt(path: []const u8, needle: []const u8, timeout_ms: u32) !void {
    var buf: [32 * 1024]u8 = undefined;
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (h.readFile(path, &buf)) |txt| {
            if (std.mem.indexOf(u8, txt, needle) != null) return;
        } else |_| {}
        h.sleepMs(100);
    }
    std.debug.print("    receipt never showed: {s}\n", .{needle});
    return error.AssertFailed;
}

/// workspace/didChangeWatchedFiles, end to end. The fake server
/// registers two watchers on `initialized` — `**/*.go` wanting every
/// kind, and a RelativePattern `*.mod` masked to create|delete — and
/// writes every notification it hears into `<target>.watched`. The
/// filesystem is then driven from OUTSIDE the editor, which is the
/// whole point: rook IS a terminal, and `go get` in the next pane is
/// exactly a write rook never made. Before this landed, that write was
/// silence and the server answered from a module graph that no longer
/// existed.
///
/// FSEvents flags are cumulative near a create, so the positive
/// change-event proof uses a file that PREDATES the stream (util.go);
/// fresh.go proves create and delete, where the stat tiebreaker holds
/// regardless of flag history.
fn lspWatch(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lspwatch-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);

    var mod_buf: [288]u8 = undefined;
    const go_mod = try std.fmt.bufPrintZ(&mod_buf, "{s}/go.mod", .{proj});
    try h.writeFile(go_mod, "module smoke\n\ngo 1.21\n");
    var main_buf: [288]u8 = undefined;
    const main_go = try std.fmt.bufPrint(&main_buf, "{s}/main.go", .{proj});
    try h.writeFile(main_go, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(nope())\n}\n");
    var util_buf: [288]u8 = undefined;
    const util_go = try std.fmt.bufPrint(&util_buf, "{s}/util.go", .{proj});
    try h.writeFile(util_go, "package main\n\nfunc nope() int {\n\treturn 1\n}\n");

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "go", "\".go\"", "\"go.mod\"", main_go);

    const app = try h.Instance.start(gpa, bin, .{ .cwd = proj, .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    _ = try app.ctlFmt("edit {s}", .{main_go});
    // The diagnostic reaching the gutter proves the server is up and
    // PAST initialized — which is when the registration went out.
    _ = try app.waitCtl("lsp", "errors:1", 8_000);

    var receipt_buf: [320]u8 = undefined;
    const receipt = try std.fmt.bufPrint(&receipt_buf, "{s}.watched", .{main_go});

    // Noise first: a file nobody registered a glob for. Its absence at
    // the end MEANS something because events that follow it do arrive.
    var noise_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&noise_buf, "{s}/noise.txt", .{proj}), "x\n");

    // Create.
    var fresh_buf: [288]u8 = undefined;
    const fresh = try std.fmt.bufPrintZ(&fresh_buf, "{s}/fresh.go", .{proj});
    try h.writeFile(fresh, "package main\n");
    try waitReceipt(receipt, "fresh.go\",\"type\":1", 8_000);

    // Change, on the file older than the stream.
    try h.writeFile(util_go, "package main\n\nfunc nope() int {\n\treturn 2\n}\n");
    try waitReceipt(receipt, "util.go\",\"type\":2", 8_000);

    // Delete — stat beats whatever history the flags still carry.
    try h.expectEq("rm fresh.go", 0, try h.runCmd(proj, &.{ "/bin/rm", fresh.ptr }));
    try waitReceipt(receipt, "fresh.go\",\"type\":3", 8_000);

    // The kind mask. Modify go.mod, then land a sentinel .go create
    // AFTER it: when the sentinel shows in the receipt, the go.mod
    // change had every chance to arrive — and must not have.
    try h.writeFile(go_mod, "module smoke\n\ngo 1.22\n");
    var done_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&done_buf, "{s}/done.go", .{proj}), "package main\n");
    try waitReceipt(receipt, "done.go\",\"type\":1", 8_000);
    {
        var buf: [32 * 1024]u8 = undefined;
        const txt = try h.readFile(receipt, &buf);
        try h.expect(std.mem.indexOf(u8, txt, "go.mod\",\"type\":2") == null,
            "the kind mask held: a change event for go.mod got through", .{});
        try h.expect(std.mem.indexOf(u8, txt, "noise.txt") == null,
            "the glob filter held: noise.txt reached the server", .{});
    }

    // And the mask's other half, so the absence above is not vacuous:
    // a go.mod DELETE is allowed through — which is also the proof the
    // RelativePattern watcher parsed at all.
    try h.expectEq("rm go.mod", 0, try h.runCmd(proj, &.{ "/bin/rm", go_mod.ptr }));
    try waitReceipt(receipt, "go.mod\",\"type\":3", 8_000);
}

fn lspRetarget(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lspre-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);

    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/go.mod", .{proj}), "module smoke\n\ngo 1.21\n");
    var main_buf: [288]u8 = undefined;
    const main_go = try std.fmt.bufPrint(&main_buf, "{s}/main.go", .{proj});
    try h.writeFile(main_go, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(nope())\n}\n");
    var other_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&other_buf, "{s}/other.go", .{proj}), "package main\n\nfunc nope() int {\n\treturn 1\n}\n");
    // A file of no known language, to retarget ONTO. Its job is to
    // prove the seams come back off.
    var note_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&note_buf, "{s}/notes.txt", .{proj}), "just words\n");

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "go", "\".go\"", "\"go.mod\"", main_go);

    const app = try h.Instance.start(gpa, bin, .{
        .cwd = proj,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    // Open the DIRECTORY as an in-pane tree, spelled with the trailing
    // dot `re .` produces. Nothing about a tree needs a server; what is
    // being set up is a pane that is about to retarget itself.
    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}/.", .{proj}));
    _ = try app.waitCtl("dump", "main.go", 8_000);
    try h.expectContains(try app.ctl("lsp"), "pane gutter:no", "a tree has no server, and reserves no sign column");

    // Down to main.go and Enter. Rows are `../`, go.mod, main.go,
    // other.go, notes.txt — sorted, with the climb row first.
    _ = try app.ctl("type jj");
    _ = try app.ctl("enter");

    // THE regression. Before the seam existed this stayed `gutter:no`
    // forever: the document opened, the app never heard, and hover said
    // "no language server for this file" in a module with a server
    // already running in it.
    _ = try app.waitCtl("lsp", "pane gutter:yes", 8_000);
    {
        // The gutter is the seam; readiness is the handshake behind it,
        // and it lands a frame or two later.
        // The diagnostic is the proof the server holds this document,
        // not merely that a process started: it is published unprompted
        // after initialize, and it lands on the pane only if the pane's
        // path is the one the server was given.
        const out = try app.waitCtl("lsp", "pane gutter:yes errors:1", 8_000);
        try h.expectContains(out, "server go ready", "the tree's Enter started the server");
        try h.expectContains(out, "main.go", "and the server was told about the file");
        // Spelled clean. `proj/./main.go` would be a second document
        // and a URI gopls rejects.
        try h.expectNotContains(out, "/./", "the tree's anchor dot never reaches the server");
        const docs = try app.ctl("docs");
        try h.expectNotContains(docs, "/./", "nor the document registry, where the path IS the identity");
        try h.expectContains(docs, "proj/main.go", "one file, spelled the one way");
    }

    // Hover proves the server holds this as a real document rather than
    // merely knowing its name.
    _ = try app.ctl("type 5G");
    _ = try app.ctl("type w");
    _ = try app.ctl("type K");
    {
        const out = try app.waitCtl("lsp", "hover on", 8_000);
        try h.expectContains(out, "lang:go", "and answers about it");
    }
    _ = try app.ctl("press ESC");

    // `:e` is the same seam from the other direction: this pane already
    // has a server, and the file it moves to has to be opened in it.
    _ = try app.ctl("type :e other.go");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("docs", "proj/other.go", 8_000);
    {
        const out = try app.ctl("lsp");
        try h.expectContains(out, "pane gutter:yes", "`:e` keeps the sign column");
        try h.expectContains(out, "server go ready", "and the server it came in with");
    }
    // The server ANSWERING about the new file is the proof — the
    // manager's own listing only names files it has diagnostics for,
    // and a clean file has none.
    _ = try app.ctl("type 3G");
    _ = try app.ctl("type w");
    _ = try app.ctl("type K");
    _ = try app.waitCtl("lsp", "hover on", 8_000);
    _ = try app.ctl("press ESC");

    // And onto a file no server serves. The seams have to come OFF:
    // hooks pointing at a manager that was never told about this
    // document are worse than no hooks, and a sign column that will
    // never hold a sign is a column of wasted width.
    _ = try app.ctl("type :e notes.txt");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("lsp", "pane gutter:no", 8_000);
    _ = try app.ctl("type K");
    {
        const dump = try app.ctl("dump");
        // And says WHICH silence this is: `.txt` is a language nobody
        // declared, which is a config edit rather than an install.
        try h.expectContains(dump, "no language declared for .txt files", "and it says so plainly");
        try h.expectNotContains(dump, "╭", "rather than floating the last file's documentation");
    }
}

/// rook has no catalog of languages, and each way of having no server
/// says which way it is.
///
/// Both halves are the point of the declaration model. Before it, three
/// languages were compiled into the binary and adding a fourth meant
/// shipping a rook; a `.zig` file in a Zig repo got the same sentence as
/// a `.md` file, and a project whose toolchain was simply not installed
/// got it too. One sentence for four problems, only one of which the
/// reader could act on.
fn lspLang(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lsplang-{d}", .{h.runPid()});
    var proj_buf: [256]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{scratch});
    try h.mkdirP(proj);

    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/build.zig", .{proj}), "// marker\n");
    var zig_buf: [288]u8 = undefined;
    const zig_file = try std.fmt.bufPrint(&zig_buf, "{s}/main.zig", .{proj});
    try h.writeFile(zig_file, "const std = @import(\"std\");\n");
    var md_buf: [288]u8 = undefined;
    const md_file = try std.fmt.bufPrint(&md_buf, "{s}/README.md", .{proj});
    try h.writeFile(md_file, "# hi\n");

    // A language declared against a server that is not on this machine.
    // Nothing here is built in: take this node out and rook has never
    // heard of Zig.
    var graph_buf: [1024]u8 = undefined;
    const graph = try std.fmt.bufPrint(&graph_buf,
        "{{\"rookEnvironment\":1,\"nodes\":[{{\"id\":\"language:zig\",\"kind\":\"language\"," ++
            "\"scope\":\"app\",\"name\":\"zig\",\"ext\":[\".zig\"],\"roots\":[\"build.zig\"]," ++
            "\"command\":[\"rook-no-such-language-server\"]}}]}}", .{});

    const app = try h.Instance.start(gpa, bin, .{ .cwd = proj, .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    // Declared, and reported as declared even with nothing running —
    // "which languages does this rook know about" is a question with an
    // answer now, and it is the config's answer.
    {
        const out = try app.ctl("lsp");
        try h.expectContains(out, "language zig declared", "the declaration is what rook knows");
        try h.expectContains(out, "rook-no-such-language-server", "naming the binary it was told to run");
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{zig_file}));
    try app.waitText("const std", 5_000);
    _ = try app.ctl("type K");
    {
        // DECLARED but not installed. The fix is an install, and the
        // message says which one — it used to say "no language server
        // for this file", which is true of a .md file too.
        const dump = try app.waitCtl("dump", "not installed", 5_000);
        try h.expectContains(dump, "zig is declared", "the language was found");
        try h.expectContains(dump, "rook-no-such-language-server is not installed", "and the binary named");
    }

    // No sign column: one reserved for diagnostics that can never
    // arrive is a column of wasted width.
    try h.expectContains(try app.ctl("lsp"), "pane gutter:no", "and nothing is reserved for it");

    // A file of a language nobody declared. A DIFFERENT problem with a
    // different fix — a config edit, not an install.
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{md_file}));
    try app.waitText("hi", 5_000);
    _ = try app.ctl("type K");
    {
        const dump = try app.waitCtl("dump", "no language declared", 5_000);
        try h.expectContains(dump, ".md", "naming the extension nothing claims");
        try h.expectNotContains(dump, "not installed", "which is not the same problem as a missing binary");
    }
}

/// Suggestions as you type.
///
/// The rule the whole feature turns on is that an AUTO menu never
/// writes to the buffer. vim's ctrl-n puts the candidate in as you
/// cycle, which is right for a key you pressed on purpose and wrong for
/// a list that appeared by itself — text arriving under your fingers
/// because you typed two characters is the behaviour that makes people
/// switch completion off and never turn it back on.
fn suggestScenario(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-suggest-{d}", .{h.runPid()});
    try h.mkdirP(scratch);
    var f_buf: [288]u8 = undefined;
    const file = try std.fmt.bufPrint(&f_buf, "{s}/notes.txt", .{scratch});
    // Plain text and no language server: what is under test is the
    // menu, not the LSP behind it.
    // LONG, and typed into at the very END, which is where the box was
    // flipping above the cursor and jumping on every keystroke.
    // `alpine_meadow_traverse` makes the candidate list's own width move
    // as it is filtered out.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "alphabet\nalpine\naltitude\nalpine_meadow_traverse\n");
    var fbuf: [64]u8 = undefined;
    for (0..120) |i| try body.appendSlice(gpa, try std.fmt.bufPrint(&fbuf, "filler line {d}\n", .{i}));
    try body.appendSlice(gpa, "\n");
    try h.writeFile(file, body.items);

    const app = try h.Instance.start(gpa, bin, .{ .cwd = scratch });
    defer {
        app.stop();
        app.deinit();
    }
    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{file}));
    try app.waitText("alphabet", 5_000);

    _ = try app.ctl("type G");
    _ = try app.ctl("type i");
    _ = try app.ctl("type a");
    // ONE character. The filtering and the matched-prefix emphasis keep
    // a short prefix readable; waiting for a second just means the menu
    // is late.
    {
        const out = try app.waitCtl("lsp", "cpl on", 3_000);
        try h.expectContains(out, "prefix:a", "the menu opens on the first character");
        try h.expectContains(out, "auto", "by itself");
    }

    _ = try app.ctl("type l");
    {
        const out = try app.waitCtl("lsp", "cpl on", 3_000);
        try h.expectContains(out, "prefix:al", "the menu opened on what was typed");
        try h.expectContains(out, "auto", "by itself");
        try h.expectContains(out, "cpl alphabet", "with the buffer's own words");
        try h.expectContains(out, "cpl altitude", "all of them");
    }
    // NOTHING was written. The dump is the buffer, and it still ends in
    // the two characters that were typed.
    {
        // The gutter is one column wide in a five-line file, so match on
        // what is NOT there: the candidate has not been written.
        const d = try app.ctl("dump");
        try h.expectNotContains(d, "126 alphabet", "and put nothing in the buffer");
        try h.expectContains(d, "126 al", "leaving exactly what was typed");
    }

    _ = try app.ctl("type p");
    {
        const out = try app.ctl("lsp");
        try h.expectContains(out, "prefix:alp", "typing narrows it");
        try h.expectContains(out, "cpl alphabet", "keeping what still matches");
        try h.expectNotContains(out, "cpl altitude", "and dropping what does not");
    }

    // The geometry rules, at the BOTTOM of a long file where the box has
    // to go above the cursor. It follows the cursor sideways, and — the one rook got wrong for a while — the DOCUMENT
    // must not move to make room for it. Scrolling the buffer stops the
    // box moving by moving every line instead, which is the larger jolt
    // of the two; Zed flips the popup and leaves the text alone.
    {
        var left_at: ?usize = null;
        var top_at: ?usize = null;
        var right_at: usize = 0;
        var doc_at: ?usize = null;
        // "" samples the state already reached (`alp`), before the long
        // candidate is filtered out.
        for ([_][]const u8{ "", "h", "a", "b" }) |ch| {
            if (ch.len > 0) _ = try app.ctlFmt("type {s}", .{ch});
            const d = try app.ctl("dump");
            // The menu's rows are the ones carrying a candidate; find
            // the first, and where it starts.
            var it = std.mem.splitScalar(u8, d, '\n');
            var row: usize = 0;
            var found = false;
            while (it.next()) |line| : (row += 1) {
                const at = std.mem.indexOf(u8, line, "alphabet") orelse continue;
                // Skip the document's own line 1.
                if (std.mem.indexOf(u8, line, " 1 ") != null) continue;
                // The row's own right edge: the fill runs the box's
                // full width, so the last non-space column is it.
                // The box TRACKS the cursor: one column right per
                // character, so the list stays attached to the caret
                // rather than parked beside it. Zed's does this, and it
                // is the difference between a popup that belongs to
                // what you are typing and one that merely appeared.
                if (left_at) |l| {
                    try h.expect(at == l + 1, "the menu did not follow the cursor ({d} then {d})", .{ l, at });
                }
                left_at = at;
                _ = &right_at;
                _ = &top_at;
                found = true;
                break;
            }
            try h.expect(found, "the menu vanished while typing `{s}`", .{ch});
            // A document line the menu never covers, by ROW rather than
            // by byte offset: the menu's own rows change width as the
            // list narrows, which moves every offset after them without
            // anything having scrolled.
            var arow: usize = 0;
            var ait = std.mem.splitScalar(u8, d, '\n');
            var anchor: usize = 0;
            var found_anchor = false;
            while (ait.next()) |line| : (arow += 1) {
                if (std.mem.indexOf(u8, line, "filler line 90") != null) {
                    anchor = arow;
                    found_anchor = true;
                    break;
                }
            }
            try h.expect(found_anchor, "the anchor line scrolled out of view entirely", .{});
            if (doc_at) |a2| {
                try h.expect(a2 == anchor, "the document scrolled under the menu", .{});
            } else doc_at = anchor;
        }
    }
    // Back to the state the rest of this scenario expects. Backspace
    // widens the menu rather than closing it, so it is still up.
    for (0..3) |_| _ = try app.ctl("key 7f");
    const lsp_out = try app.ctl("lsp");
    try h.expectContains(lsp_out, "cpl on prefix:alp", "backspace widened rather than closed");

    // The box is a real rounded card drawn UNDER the grid — the one
    // thing about it a text dump cannot show, and the reason it stopped
    // drawing `╭─╮` with box-drawing glyphs (at a cell's size an arc is
    // a two-pixel curve the font squares off).
    //
    // ONE comparison, because it fails on all three ways this breaks.
    // The card's extreme corner is outside the arc, so it must show the
    // buffer behind it; the middle of its top edge is on the border. If
    // the radius went to zero both are the border. If the card stopped
    // drawing both are the editor's background. If the menu's cells
    // went back to painting their own backgrounds they would square the
    // corner off and both are the fill. Only a drawn, rounded card
    // makes those two pixels differ.
    {
        // The shot FIRST, and the geometry from the frame it captured:
        // `cpl_geom` is written by the fill, so asking before the frame
        // is asking about the previous one.
        var shot_buf: [288]u8 = undefined;
        var s = try app.shot(try std.fmt.bufPrint(&shot_buf, "{s}/card.png", .{scratch}));
        defer s.deinit();

        var cx: usize = 0;
        var cy: usize = 0;
        var cw: usize = 0;
        var found = false;
        var it = std.mem.splitScalar(u8, try app.ctl("lsp"), '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpl card ")) continue;
            var f = std.mem.tokenizeScalar(u8, line["cpl card ".len..], ' ');
            cx = try std.fmt.parseInt(usize, f.next() orelse break, 10);
            cy = try std.fmt.parseInt(usize, f.next() orelse break, 10);
            cw = try std.fmt.parseInt(usize, f.next() orelse break, 10);
            found = true;
            break;
        }
        try h.expect(found, "ctl lsp did not say where the card is", .{});

        const corner = s.pixel(cx, cy);
        const edge = s.pixel(cx + cw / 2, cy);
        try h.expect(
            corner != edge,
            "the card's corner is not rounded: corner {x} == top edge {x} at ({d},{d})",
            .{ corner, edge, cx, cy },
        );
    }

    // Tab takes the highlighted one. This is the first thing written.
    _ = try app.ctl("press TAB");
    {
        _ = try app.waitCtl("lsp", "cpl off", 3_000);
        try h.expectContains(try app.ctl("dump"), "126 alphabet", "the candidate landed");
    }
    // Still in insert mode: accepting a completion is not a mode change.
    try h.expectContains(try app.ctl("dump"), "INSERT", "without leaving insert");
}

fn lspTs(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-lspts-{d}", .{h.runPid()});
    // package.json at the top, tsconfig one level down: the two markers
    // disagree on purpose, and the tsconfig has to win.
    var src_buf: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/repo/app/src", .{scratch});
    try h.mkdirP(src);
    var repo_buf: [256]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repo_buf, "{s}/repo", .{scratch});
    var appdir_buf: [256]u8 = undefined;
    const appdir = try std.fmt.bufPrint(&appdir_buf, "{s}/repo/app", .{scratch});

    var f_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/package.json", .{repo}), "{\"name\":\"mono\"}\n");
    var f2_buf: [288]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f2_buf, "{s}/tsconfig.json", .{appdir}), "{\"compilerOptions\":{}}\n");

    var ts_buf: [288]u8 = undefined;
    const ts_file = try std.fmt.bufPrint(&ts_buf, "{s}/app.ts", .{src});
    try h.writeFile(ts_file, "export function main(): void {\n\n\n\n\n  nope();\n}\n");
    var tsx_buf: [288]u8 = undefined;
    const tsx_file = try std.fmt.bufPrint(&tsx_buf, "{s}/view.tsx", .{src});
    try h.writeFile(tsx_file, "export const V = () => <span>hi</span>;\n");

    var graph_buf: [1024]u8 = undefined;
    const graph = try langGraph(&graph_buf, "typescript", "\".ts\",\".tsx\"", "\"tsconfig.json\",\"package.json\"", ts_file);

    const app = try h.Instance.start(gpa, bin, .{
        .cwd = appdir,
        .env_json = graph,
    });
    defer {
        app.stop();
        app.deinit();
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{ts_file}));
    _ = try app.waitCtl("lsp", "pane gutter:yes errors:1", 8_000);

    {
        const out = try app.ctl("lsp");
        var want_buf: [320]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "server typescript ready {s}\n", .{appdir});
        try h.expectContains(out, want, "rooted at the tsconfig, not the package.json above it");
        // The fake publishes at UTF-16 column 13 and this line is nine
        // bytes long, so the two disagree ON PURPOSE: the manager keeps
        // what the server said, and the pane clamps to the end of the
        // line it actually has. A server naming a column past the end
        // is ordinary — it computed against text that has since been
        // edited — and it must read as end-of-line, never as an overrun.
        try h.expectContains(out, "  err 6:13 undefined: nope", "the manager keeps the server's column");
        try h.expectContains(out, "pane err 6:9 undefined: nope", "the pane clamps it to the line");
    }

    // Now the .tsx beside it. Different grammar, SAME server — a second
    // one starting here would mean the family had been split.
    var cmd2_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd2_buf, "edit {s}", .{tsx_file}));
    {
        const out = try app.ctl("lsp");
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "server ")) n += 1;
        }
        try h.expectEq("one server for the whole ts/tsx/js family", 1, n);
    }
}


// ------------------------------------------------------------- docshare

/// A file is a DOCUMENT and a pane is a window onto it.
///
/// rook said this long before it was true. Every pane used to load its
/// own copy, so one file in two panes was two ropes, two undo histories
/// and two dirty flags: typing in one left the other showing stale
/// text, and `:w` from the second was refused because the file really
/// had changed underneath it. Emacs's split — buffer holds the text,
/// window holds the point — is what this pins.
fn docShare(gpa: std.mem.Allocator, bin: []const u8) !void {
    var scratch_buf: [192]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&scratch_buf, "/tmp/rook-docs-{d}", .{h.runPid()});
    try h.mkdirP(scratch);
    var f_buf: [256]u8 = undefined;
    const shared = try std.fmt.bufPrint(&f_buf, "{s}/shared.txt", .{scratch});
    try h.writeFile(shared, "alpha\nbeta\ngamma\n");
    var o_buf: [256]u8 = undefined;
    const other = try std.fmt.bufPrint(&o_buf, "{s}/other.txt", .{scratch});
    try h.writeFile(other, "one\ntwo\n");

    const app = try h.Instance.start(gpa, bin, .{ .cwd = scratch });
    defer {
        app.stop();
        app.deinit();
    }

    var cmd_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd_buf, "edit {s}", .{shared}));
    _ = try app.ctl("split right");
    var cmd2_buf: [320]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cmd2_buf, "edit {s}", .{shared}));

    {
        const out = try app.ctl("docs");
        try h.expectContains(out, "open:1", "one file open, not two copies of it");
        try h.expectContains(out, "views:2", "and two panes holding it");
    }

    // Type in pane 2; pane 1 is showing the same rope, so it sees it.
    _ = try app.ctl("type@2 ggIZZZ");
    _ = try app.ctl("key@2 1b");
    {
        const one = try app.ctl("dump@1");
        try h.expectContains(one, "ZZZalpha", "the other pane sees the edit");
    }
    {
        const out = try app.ctl("docs");
        // ONE dirty flag. Two would mean two documents, and the second
        // pane's `:w` would be refused as a clobber.
        try h.expectContains(out, "modified:yes", "one dirty flag for the document");
        try h.expectContains(out, "open:1", "still one document");
    }

    // …and one `:w`, from the pane that did NOT type.
    _ = try app.ctl("focus 1");
    _ = try app.ctl("type :w");
    _ = try app.ctl("enter");
    _ = try app.waitCtl("docs", "modified:no", 5_000);
    {
        var disk_buf: [256]u8 = undefined;
        const disk = try h.readFile(shared, &disk_buf);
        try h.expectContains(disk, "ZZZalpha", "and the write carried the other pane's edit");
    }

    // A DIFFERENT file in the second pane is a different document —
    // sharing is by path, not by "whatever is open".
    var cmd3_buf: [320]u8 = undefined;
    _ = try app.ctl("focus 2");
    _ = try app.ctl(try std.fmt.bufPrint(&cmd3_buf, "edit {s}", .{other}));
    {
        const out = try app.ctl("docs");
        try h.expectContains(out, "open:2", "two files open");
        try h.expectContains(out, "other.txt", "the second pane moved to its own document");
        // The first pane let go of nothing — it is still on shared.txt,
        // now alone.
        try h.expectContains(out, "views:1", "each held by one pane");
    }
}

// ------------------------------------------------------------- panedim

fn paneDim(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{ .config_extra = "pane-dim = 0.6\n" });
    defer {
        app.stop();
        app.deinit();
    }

    // Text in the first pane, then a split — the new pane takes focus,
    // and gets text of its own. Same words on both sides on purpose:
    // the claim is about brightness, and different content would make
    // the meter compare apples to prompts.
    _ = try app.ctl("type echo DIMMER-PROOF");
    _ = try app.ctl("enter");
    try app.waitTextCount("DIMMER-PROOF", 2, 10_000);
    _ = try app.ctl("split right");
    _ = try app.ctl("type echo DIMMER-PROOF");
    _ = try app.ctl("enter");
    try app.waitTextCount("DIMMER-PROOF", 2, 10_000);

    // A DIFFERENTIAL between the two halves of one shot: thresholds on
    // absolute pixel values would encode the theme. The text band sits
    // in the top third (echo output), clear of the mid separator and
    // the status bar.
    var p1: [192]u8 = undefined;
    var img = try app.shot(try std.fmt.bufPrint(&p1, "{s}/dim-right-focused.png", .{app.dirPath()}));
    const l1 = img.maxContrast(img.width / 16, img.height / 20, img.width * 7 / 16, img.height / 3);
    const r1 = img.maxContrast(img.width * 9 / 16, img.height / 20, img.width * 15 / 16, img.height / 3);
    img.deinit();
    try h.expect(l1 < r1 * 3 / 5, "the unfocused left pane should be dimmer: left {d} vs right {d}", .{ l1, r1 });
    try h.expect(l1 > 15, "dim means faded, not blank: left contrast {d}", .{l1});

    // The fade follows focus, live — no restart, no relayout.
    _ = try app.ctl("focus left");
    var p2: [192]u8 = undefined;
    var img2 = try app.shot(try std.fmt.bufPrint(&p2, "{s}/dim-left-focused.png", .{app.dirPath()}));
    const l2 = img2.maxContrast(img2.width / 16, img2.height / 20, img2.width * 7 / 16, img2.height / 3);
    const r2 = img2.maxContrast(img2.width * 9 / 16, img2.height / 20, img2.width * 15 / 16, img2.height / 3);
    img2.deinit();
    try h.expect(r2 < l2 * 3 / 5, "after focus left the RIGHT pane is the dim one: left {d} vs right {d}", .{ l2, r2 });
}

// ----------------------------------------------------------- panelwrap

/// The stub speaks just enough protocol: one parent with a field, one
/// child whose title is ~170 bytes of prose (a digest bullet at the
/// caps the agent plugin asks for), and one short last child as a
/// position marker.
const sh_wrap_plugin =
    \\while IFS= read -r line; do
    \\  id=`expr "$line" : '.*"id":\([0-9]*\)'`
    \\  case "$line" in
    \\    *'"op":"describe"'*)
    \\      printf '{"v":1,"id":%s,"ok":true,"result":{"name":"wrapper","version":"1.0","capabilities":["items.list"]}}\n' "$id" ;;
    \\    *'"op":"items.list"'*)
    \\      printf '{"v":1,"id":%s,"ok":true,"result":{"items":[{"id":"d","title":"the digest headline","state":"new","fields":[{"key":"cost","kind":"MONEY","value":"$0.0002"}],"children":[{"id":"b0","title":"the summarizer writes prose exactly this long on purpose so the panel has no honest choice but to fold the sentence across several rows and prove it kept END-OF-THE-BULLET"},{"id":"b1","title":"ZZZ-LAST-ROW"}]}]}}\n' "$id" ;;
    \\    *)
    \\      printf '{"v":1,"id":%s,"ok":false,"error":"unsupported"}\n' "$id" ;;
    \\  esac
    \\done
;

/// Parse "key:" followed by a decimal int out of a ctl line.
fn ctlInt(s: []const u8, key: []const u8) !i64 {
    const at = std.mem.indexOf(u8, s, key) orelse return error.KeyMissing;
    const i = at + key.len;
    var end = i;
    // A leading minus is a sign; one later is a range ("shown:12-119").
    if (end < s.len and s[end] == '-') end += 1;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    return std.fmt.parseInt(i64, s[i..end], 10);
}

/// The sidepane header's numbers: cols and the panel rect.
const SideGeom = struct { cols: i64, x: i64, y: i64, w: i64, h: i64 };
fn sideGeom(s: []const u8) !SideGeom {
    const at = std.mem.indexOf(u8, s, "rect:") orelse return error.KeyMissing;
    var it = std.mem.tokenizeAny(u8, s[at + 5 ..], ",\n ");
    return .{
        .cols = try ctlInt(s, "cols:"),
        .x = try std.fmt.parseInt(i64, it.next() orelse "", 10),
        .y = try std.fmt.parseInt(i64, it.next() orelse "", 10),
        .w = try std.fmt.parseInt(i64, it.next() orelse "", 10),
        .h = try std.fmt.parseInt(i64, it.next() orelse "", 10),
    };
}

/// The lowest 4px band inside [x0,x1]×[y0,y1] with real ink, scanning
/// bottom-up — where the panel's LAST row sits. The band's background
/// reference lands in the panel's right gutter, which nothing paints.
fn bottomInk(img: *h.Shot, x0: usize, y0: usize, x1: usize, y1: usize) usize {
    var y = y1;
    while (y > y0 + 4) {
        y -= 4;
        if (img.inkRect(x0, y, x1, y + 4) > 12) return y;
    }
    return y0;
}

/// Two claims in one panel: a child row WRAPS as prose (through the
/// title buffer that used to truncate at 96 bytes), and the divider is
/// a drag handle — wider panel, fewer wrapped lines, floor at 20 cols.
fn panelWrap(gpa: std.mem.Allocator, bin: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buf, "/tmp/rook-e2e-wrap-{d}.sh", .{getpid()});
    try h.writeFile(script, sh_wrap_plugin);

    var json_buf: [1024]u8 = undefined;
    const graph = try std.fmt.bufPrint(&json_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:wrapper","kind":"plugin","scope":"app","name":"wrapper","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list"]}}
        \\]}}
    , .{script});

    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    _ = try app.ctl("plugin-show wrapper");
    // The marker sits past byte 150 of the child's title: seeing it in
    // the rows proves the 256-byte intake, not just the fetch.
    const rows = try app.waitCtl("sidepane", "END-OF-THE-BULLET", 20_000);
    try h.expectContains(rows, "ZZZ-LAST-ROW", "the short last child listed");

    // AppKit owns window geometry and delivers the real one a beat
    // after launch — a rect read mid-settle aims the drag at where the
    // divider USED to be (observed: a click at x=1504 in a window that
    // had settled to 980 wide, and the settle arriving 400ms in). Two
    // agreeing reads are not settledness; hold out for a rect that
    // stays put for 300ms straight.
    var g1 = try sideGeom(try app.ctl("sidepane"));
    var stable: usize = 0;
    var settles: usize = 0;
    while (settles < 100 and stable < 6) : (settles += 1) {
        h.sleepMs(50);
        const g = try sideGeom(try app.ctl("sidepane"));
        if (g.x == g1.x and g.h == g1.h) {
            stable += 1;
        } else {
            stable = 0;
            g1 = g;
        }
    }

    // At the 34-col default the long bullet already folds; note where
    // the panel's LAST row sits.
    var p1: [192]u8 = undefined;
    var img = try app.shot(try std.fmt.bufPrint(&p1, "{s}/wrap-default.png", .{app.dirPath()}));
    const bottom_default = bottomInk(&img, @intCast(g1.x + 8), @intCast(g1.y + 4), @intCast(g1.x + g1.w - 2), @intCast(g1.y + g1.h - 4));
    img.deinit();

    // Drag the divider toward the window edge: a right-side pane
    // SHRINKS rightward. (Wider would be the prettier claim, but the
    // e2e window is small and 34 cols can already sit at sideWidth's
    // half-window cap — narrower is the direction that is always legal,
    // and the wrap adapting is the same fact either way.)
    var dbuf: [96]u8 = undefined;
    const midy = @divTrunc(g1.y * 2 + g1.h, 2);
    _ = try app.ctl(try std.fmt.bufPrint(&dbuf, "drag {d} {d} {d} {d}", .{ g1.x, midy, g1.x + 220, midy }));
    const g2 = try sideGeom(try app.ctl("sidepane"));
    try h.expect(g2.cols <= g1.cols - 8, "the drag narrowed the pane: {d} -> {d} cols", .{ g1.cols, g2.cols });

    // Narrower means MORE folded lines, so the last row SINKS. This is
    // the differential that proves the wrap adapts — a clipped one-line
    // child would sit at the same height at every width.
    var p2: [192]u8 = undefined;
    var img2 = try app.shot(try std.fmt.bufPrint(&p2, "{s}/wrap-narrow.png", .{app.dirPath()}));
    const bottom_narrow = bottomInk(&img2, @intCast(g2.x + 8), @intCast(g2.y + 4), @intCast(g2.x + g2.w - 2), @intCast(g2.y + g2.h - 4));
    img2.deinit();
    try h.expect(bottom_narrow > bottom_default + 20, "the last row sinks when the pane narrows: default bottom {d}, narrow bottom {d}", .{ bottom_default, bottom_narrow });

    // The floor: a drag far past the window edge cannot make the pane
    // vanish — 20 cols is as thin as it gets, and it stays grabbable.
    _ = try app.ctl(try std.fmt.bufPrint(&dbuf, "drag {d} {d} 99999 {d}", .{ g2.x, midy, midy }));
    try h.expect((try sideGeom(try app.ctl("sidepane"))).cols == 20, "the floor holds at 20 cols", .{});
}

// ----------------------------------------------------------- panelfold

/// Sixty digest-shaped groups: collapse keeps the list scannable, the
/// scroll keeps the selection on screen, and a click is j/k for the
/// mouse. The fixture is generated — sixty parents each holding one
/// child marker — because the claims are about SHAPE at scale, and a
/// three-item fixture cannot overflow anything.
fn panelFold(gpa: std.mem.Allocator, bin: []const u8) !void {
    var items_buf: [24 * 1024]u8 = undefined;
    var iw: usize = 0;
    for (0..60) |i| {
        const chunk = try std.fmt.bufPrint(items_buf[iw..],
            \\{s}{{"id":"p{d}","title":"P{d}-HEAD","actions":[{{"id":"noop","label":"Noop"}}],"children":[{{"id":"p{d}c","title":"C{d}-MARK"}}]}}
        , .{ @as([]const u8, if (i == 0) "" else ","), i, i, i, i });
        iw += chunk.len;
    }
    var script_buf: [32 * 1024]u8 = undefined;
    const script_body = try std.fmt.bufPrint(&script_buf,
        \\while IFS= read -r line; do
        \\  id=`expr "$line" : '.*"id":\([0-9]*\)'`
        \\  case "$line" in
        \\    *'"op":"describe"'*)
        \\      printf '{{"v":1,"id":%s,"ok":true,"result":{{"name":"fold","version":"1.0","capabilities":["items.list"]}}}}\n' "$id" ;;
        \\    *'"op":"items.list"'*)
        \\      printf '{{"v":1,"id":%s,"ok":true,"result":{{"items":[{s}]}}}}\n' "$id" ;;
        \\    *)
        \\      printf '{{"v":1,"id":%s,"ok":false,"error":"no"}}\n' "$id" ;;
        \\  esac
        \\done
    , .{items_buf[0..iw]});
    var path_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buf, "/tmp/rook-e2e-fold-{d}.sh", .{getpid()});
    try h.writeFile(script, script_body);

    var json_buf: [1024]u8 = undefined;
    const graph = try std.fmt.bufPrint(&json_buf,
        \\{{"rookEnvironment":1,"nodes":[
        \\{{"id":"plugin:fold","kind":"plugin","scope":"app","name":"fold","command":["/bin/sh","{s}"],"load":"lazy","grants":["items.list","items.act"]}}
        \\]}}
    , .{script});

    const app = try h.Instance.start(gpa, bin, .{ .env_json = graph });
    defer {
        app.stop();
        app.deinit();
    }

    _ = try app.ctl("plugin-show fold");
    const first = try app.waitCtl("sidepane", "C0-MARK", 20_000);
    // Collapse: the selected group reads, every other group is a
    // headline wearing its child count.
    try h.expectContains(first, "*\tP0-HEAD", "group 0 selected");
    try h.expectNotContains(first, "C1-MARK", "other groups' children are folded");
    try h.expectContains(first, "\u{25b8}+1", "a folded parent wears its child count");

    // Geometry settles a beat after launch (the panelwrap lesson) —
    // wait it out before trusting any coordinate.
    var g = try sideGeom(try app.ctl("sidepane"));
    var stable: usize = 0;
    var settles: usize = 0;
    while (settles < 100 and stable < 6) : (settles += 1) {
        h.sleepMs(50);
        const g2 = try sideGeom(try app.ctl("sidepane"));
        if (g2.x == g.x and g2.h == g.h) {
            stable += 1;
        } else {
            stable = 0;
            g = g2;
        }
    }

    // G: the selection jumps to the last flat row (group 59's child) and
    // the list scrolls to keep it on screen — sixty groups cannot fit.
    _ = try app.ctl("key 47"); // G
    var p1: [192]u8 = undefined;
    var shot1 = try app.shot(try std.fmt.bufPrint(&p1, "{s}/fold-bottom.png", .{app.dirPath()}));
    shot1.deinit();
    const bottomv = try app.ctl("sidepane");
    try h.expectContains(bottomv, "C59-MARK", "the last group is expanded and drawn");
    try h.expectNotContains(bottomv, "P0-HEAD", "the top scrolled away");
    const shown_a = try ctlInt(bottomv, "shown:");
    try h.expect(shown_a > 0, "the drawn window starts past the top: shown {d}", .{shown_a});

    // A click on the first drawn row selects it (j/k for the mouse), and
    // the fold follows the selection.
    const top = try ctlInt(bottomv, "top:");
    var cbuf: [64]u8 = undefined;
    _ = try app.ctl(try std.fmt.bufPrint(&cbuf, "click {d} {d}", .{ g.x + @divTrunc(g.w, 2), top + 5 }));
    const clicked = try app.ctl("sidepane");
    try h.expectContains(clicked, "focus:panel", "the click gave the panel the keys");
    try h.expectNotContains(clicked, "C59-MARK", "the old group folded when the selection left it");
    var star_buf: [64]u8 = undefined;
    const want_star = try std.fmt.bufPrint(&star_buf, "*\tP{d}-HEAD", .{@divTrunc(shown_a, 2)});
    try h.expectContains(clicked, want_star, "the first drawn row took the selection");

    // A second click on the selected row is the Enter: the action menu.
    _ = try app.ctl(try std.fmt.bufPrint(&cbuf, "click {d} {d}", .{ g.x + @divTrunc(g.w, 2), top + 5 }));
    try h.expectContains(try app.ctl("sidepane"), "mode:actions", "clicking the selected row opens its menu");
}

/// The resource monitor, both halves.
///
/// The assertions that matter are the SAFETY ones: a `keep` category
/// must refuse to arm, and an unclassified directory must refuse with a
/// reason. Those are the two ways this feature could destroy something,
/// and neither is provable from a unit test of the view model alone —
/// the classifier, the fill and the key path all have to agree.
fn monitor(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // One of each: unambiguous build output, irreplaceable agent
    // history, and something the classifier has no opinion about.
    var pb: [224]u8 = undefined;
    const proj = try std.fmt.bufPrint(&pb, "{s}/proj", .{app.dirPath()});
    var db: [280]u8 = undefined;
    try h.mkdirP(try std.fmt.bufPrint(&db, "{s}/node_modules/dep", .{proj}));
    try h.mkdirP(try std.fmt.bufPrint(&db, "{s}/.claude/projects", .{proj}));
    try h.mkdirP(try std.fmt.bufPrint(&db, "{s}/build", .{proj}));

    // Distinct sizes so the rows sort in a KNOWN order: the tree ranks
    // biggest-first, and a test that walked it blind could not say
    // which category it had just refused.
    var fb: [280]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&fb, "{s}/node_modules/dep/big.js", .{proj}), "x" ** 200000);
    try h.writeFile(try std.fmt.bufPrint(&fb, "{s}/.claude/projects/a.jsonl", .{proj}), "y" ** 90000);
    try h.writeFile(try std.fmt.bufPrint(&fb, "{s}/build/out.o", .{proj}), "z" ** 8000);

    // The scan root follows the pane's shell cwd — through the PARKED
    // shell once the monitor takes the pane over — so put the shell in
    // the fixture first.
    _ = try app.ctlFmt("type cd {s}", .{proj});
    _ = try app.ctl("enter");
    _ = try app.ctl("type PS1='rdy$ '");
    _ = try app.ctl("enter");
    try app.waitText("rdy$", 5000);

    _ = try app.ctl("monitor");

    // --- LIVE ---------------------------------------------------------
    var buf: [32 * 1024]u8 = undefined;
    var scr = try app.screen(&buf);
    try h.expectContains(scr, "LIVE", "the section tabs render");
    try h.expectContains(scr, "DISK", "both sections are offered");

    // A rate needs two samples, so the first frame says so rather than
    // drawing a column of zeroes — a working monitor and a broken one
    // must not look the same. Then the real totals arrive.
    try app.waitText("CPU", 8000);
    scr = try app.screen(&buf);
    try h.expectContains(scr, "MEM", "the memory line is up");
    try h.expectContains(scr, "COMMAND", "the process table header is up");

    // --- DISK ---------------------------------------------------------
    _ = try app.ctl("monitor disk");
    _ = try app.ctl("type s");
    try app.waitText("rebuilds", 30000);

    scr = try app.screen(&buf);
    try h.expectContains(scr, "node_modules", "unambiguous build output is listed");

    // The classifier's opinions read blind, which is the form an agent
    // would use to answer "what can I clean up".
    const disk = try app.ctl("disk");
    try h.expectContains(disk, "regenerable\tnode-modules", "node_modules classifies as regenerable");
    try h.expectContains(disk, "keep\tagent-transcripts", "agent history classifies as keep");

    // --- the safety properties ---------------------------------------
    // Row 0, node_modules: regenerable, so it MUST arm — and the
    // confirm must name the path it is about to remove.
    _ = try app.ctl("type g");
    _ = try app.ctl("type x");
    scr = try app.screen(&buf);
    try h.expectContains(scr, "[y] confirm", "a regenerable row arms a confirm");
    try h.expectContains(scr, "node_modules", "the confirm names the path it will remove");

    // Any key but y cancels: the destructive path needs explicit intent.
    _ = try app.ctl("type n");
    scr = try app.screen(&buf);
    try h.expect(std.mem.indexOf(u8, scr, "[y] confirm") == null, "any key but y cancels", .{});

    // Row 1 is `.claude`, which is NOT itself a category — only
    // `.claude/projects` under it is, and that distinction is the
    // classifier being precise rather than greedy. So drill in, which
    // exercises the drill-down path on the way to the real assertion.
    _ = try app.ctl("type j");
    _ = try app.ctl("type l");
    scr = try app.screen(&buf);
    try h.expectContains(scr, "projects", "drilling into .claude lists its children");

    // The transcripts themselves: irreplaceable. Must refuse, name the
    // category, and stage NOTHING. The assertion the classifier exists
    // for.
    _ = try app.ctl("type g");
    _ = try app.ctl("type x");
    scr = try app.screen(&buf);
    try h.expect(std.mem.indexOf(u8, scr, "[y] confirm") == null, "a keep category must never arm a confirm", .{});
    try h.expectContains(scr, "agent-transcripts", "the refusal names the category");

    // Back out, then `build`: deliberately unclassified. It must refuse
    // too, and SAY SO — a delete key that silently does nothing reads
    // as broken.
    _ = try app.ctl("type h");
    _ = try app.ctl("type G");
    _ = try app.ctl("type x");
    scr = try app.screen(&buf);
    try h.expect(std.mem.indexOf(u8, scr, "[y] confirm") == null, "an unclassified dir must not arm", .{});
    try h.expectContains(scr, "no opinion", "the refusal explains itself");
}
