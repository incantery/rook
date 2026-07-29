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

const Scenario = struct {
    name: []const u8,
    what: []const u8,
    run: *const fn (std.mem.Allocator, []const u8) anyerror!void,
};

const scenarios = [_]Scenario{
    .{ .name = "boot", .what = "one pane, one tab, a live shell", .run = boot },
    .{ .name = "echo", .what = "typed command reaches the pty and echoes back", .run = echo },
    .{ .name = "splits", .what = "split right, focus moves, close returns", .run = splits },
    .{ .name = "tabs", .what = "new tab, cycle, pane counts stay separate", .run = tabs },
    .{ .name = "editor", .what = "edit a file, change it, :w reaches disk", .run = editor },
    .{ .name = "indent", .what = "o inherits the indent, >> shifts, and neither leaves whitespace", .run = indent },
    .{ .name = "vim", .what = "regex :s, a macro, a block edit and `.` all reach disk", .run = vim },
    .{ .name = "wide", .what = "CJK text lays out two cells wide and motions still land", .run = wideText },
    .{ .name = "grapheme", .what = "a cluster is one character to move over and to delete", .run = graphemes },
    .{ .name = "termglyph", .what = "a terminal pane shapes clusters too, not just the editor", .run = termGlyph },
    .{ .name = "clobber", .what = ":w refuses a file an agent changed underneath it", .run = clobber },
    .{ .name = "reload", .what = "an open buffer follows the file, or says it can't", .run = reload },
    .{ .name = "pixels", .what = "the renderer actually drew (shot, decoded)", .run = pixels },
    .{ .name = "commands", .what = "registry lists, runs by name, and drives the ⌘K palette", .run = commands },
    .{ .name = "excmd", .what = "the editor's : reaches the registry (:PaneSplitRight)", .run = excmd },
    .{ .name = "sidepane", .what = "side pane retiles the grid, flips edges, and holds the inbox", .run = sidepane },
    .{ .name = "asks", .what = "a question renders, takes keys, and produces the answer JSON", .run = asks },
    .{ .name = "deck", .what = "the agent deck opens focused and yields the keys back", .run = deck },
    .{ .name = "threads", .what = "the threads panel, and :Thread* refuses a non-thread buffer", .run = threads },
    .{ .name = "review", .what = "the review panel opens focused and keeps its verdict keys", .run = review },
    .{ .name = "threadrows", .what = "the sidebar lists real threads and re-anchors their lines", .run = threadRows },
    .{ .name = "reviewrows", .what = "the review panel shows findings, the gate, and re-anchored lines", .run = reviewRows },
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
    const path = try std.fmt.bufPrint(&path_buf, "{s}/marks.txt", .{app.dirPath()});
    const row = "x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}x\u{332}\n";
    try h.writeFile(path, row ++ row ++ row ++ row ++ row ++ row ++ "ZZTOP\n");

    _ = try app.ctlFmt("type cat {s}", .{path});
    _ = try app.ctl("enter");
    try app.waitText("ZZTOP", 10_000);

    var shot_buf: [192]u8 = undefined;
    const shot_path = try std.fmt.bufPrint(&shot_buf, "/tmp/term.png", .{});
    _ = &shot_buf;
    var shot = try app.shot(shot_path);
    defer shot.deinit();

    // Ink density over the output area, as a fraction of ten thousand so
    // the number does not move with the display scale. Measured 60 with
    // the marks drawn and 44 with only their bases.
    // Six underlined rows, so the marks are a QUARTER of the ink in the
    // band rather than a rounding error on one line of it.
    const top = shot.height / 24;
    const bot = shot.height / 3;
    const drawn = shot.ink(top, bot);
    const density = drawn * 10_000 / @max(shot.width * (bot - top), 1);
    try h.expect(density > 500, "output too thin ({d}/10000) — the terminal drew each cluster's base and dropped its marks", .{density});
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
    _ = try app.ctl("run attention.inbox");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "open side:right panel:attention", "opened on the right");
    const narrow = try paneCols(app);
    try h.expect(narrow < wide, "pane should narrow: {d} cols before, {d} after", .{ wide, narrow });

    // The sandbox has no rook-host (XDG_STATE_HOME is unwritable on
    // purpose), so the honest render is "unreachable" — NOT an empty
    // list, which would read as "nothing needs you" and be a lie.
    try h.expectContains(try app.ctl("sidepane"), "host unreachable", "fails open, and says which");

    // Placement-agnostic: same tenant, other edge, same width.
    _ = try app.ctl("run panel.flip");
    try h.expectContains(try app.ctl("sidepane"), "open side:left", "flipped to the left");
    try h.expectEq("flip keeps the width", narrow, try paneCols(app));

    // It is chrome, not a pane: it must not appear in `panes`.
    try h.expectEq("side pane is not a pane", 1, try app.paneCount());

    // Toggling the SAME panel closes and gives the columns back. Compared
    // against the OPEN width, not the startup one: the direction is what
    // this asserts, and it is the part that cannot drift.
    const still_narrow = try paneCols(app);
    _ = try app.ctl("run attention.inbox");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    const restored = try paneCols(app);
    try h.expect(restored > still_narrow, "closing should give columns back: {d} open, {d} closed", .{ still_narrow, restored });

    // And the real chord, through AppKit's leader machine.
    _ = try app.ctl("press `");
    _ = try app.ctl("press a");
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 100) {
        if (std.mem.indexOf(u8, try app.ctl("sidepane"), "open") != null) break;
        h.sleepMs(100);
    }
    try h.expectContains(try app.ctl("sidepane"), "open", "<leader>a toggles it");
}

// ---------------------------------------------------------------- asks

fn asks(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    // --- single select, with a recommendation ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Ship it?","options":[{"label":"Yes","recommended":true},{"label":"No"}]}]}
    );
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "panel:ask", "the ask takes the side pane");
    try h.expectContains(st, "Ship it?", "the question renders");
    // The asker's recommendation starts under the cursor, so Enter alone
    // is a complete answer — that is what `recommended` is FOR.
    try h.expectContains(st, "*( ) Yes", "recommended option is preselected");

    // Enter alone answers, because the recommendation was already under
    // the cursor. Nothing typed, so no `other`.
    _ = try app.ctl("enter");
    const ans = try app.ctl("ask-answer");
    try h.expectContains(ans, "\"selected\":[\"Yes\"]", "the picked label is in the answer");
    try h.expectContains(ans, "\"question\":\"Ship it?\"", "the question is echoed back");
    try h.expect(std.mem.indexOf(u8, ans, "other") == null, "no `other` when nothing was typed, got: {s}", .{ans});

    // --- the form owns the key path ---
    // If this leaks, a human's keystrokes go to a pty instead of the
    // form — and typing JUMPS TO OTHER, which is the whole point of that
    // row: never be forced to pick from options that miss the point.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Pick?","options":[{"label":"One"}]}]}
    );
    _ = try app.ctl("type xyzzy");
    try h.expectContains(try app.ctl("dump"), "e2e$", "typing did NOT reach the shell");
    try h.expectContains(try app.ctl("sidepane"), "*other: xyzzy", "typing moved to Other and wrote there");
    _ = try app.ctl("enter");
    const other = try app.ctl("ask-answer");
    try h.expectContains(other, "\"other\":\"xyzzy\"", "typed text becomes `other`");
    // Choosing your own words is NOT also choosing an option.
    try h.expectContains(other, "\"selected\":[]", "Other does not pick an option too");

    // The form yields the key path back when it is done.
    try h.expectContains(try app.ctl("sidepane"), "panel:attention", "form closes to the inbox");
    _ = try app.ctl("type back-to-shell");
    _ = try app.ctl("enter");
    try app.waitTextCount("back-to-shell", 2, 5_000);

    // --- multi select ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Which?","multiSelect":true,"options":[{"label":"A"},{"label":"B"},{"label":"C"}]}]}
    );
    try h.expectContains(try app.ctl("sidepane"), "multi", "multi-select is marked as such");
    _ = try app.ctl("key 20"); // space: tick A
    _ = try app.ctl("key 0e"); // ⌃N: down to B
    _ = try app.ctl("key 20"); // space: tick B
    try h.expectContains(try app.ctl("sidepane"), "[x] A", "A stayed ticked after moving");
    _ = try app.ctl("enter");
    const multi = try app.ctl("ask-answer");
    try h.expectContains(multi, "\"selected\":[\"A\",\"B\"]", "both ticks are in the answer");

    // --- dismissal ---
    // ESC must post a real {"canceled":true}: silence would leave
    // `rookctl ask` blocked until someone kills it.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Nope?","options":[{"label":"X"}]}]}
    );
    _ = try app.ctl("key 1b"); // ESC
    try h.expectContains(try app.ctl("ask-answer"), "{\"canceled\":true}", "ESC produces a dismissal");
    try h.expectContains(try app.ctl("sidepane"), "panel:attention", "dismissal closes the form");

    // --- free text (a question with no options) ---
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Name it"}]}
    );
    _ = try app.ctl("type widget");
    _ = try app.ctl("enter");
    try h.expectContains(try app.ctl("ask-answer"), "\"other\":\"widget\"", "free-text answers land in `other`");

    // --- provenance and jump-to-source ---
    // Two panes in different directories, so "focus moved" is provable
    // rather than vacuous. The ask names one of them by cwd.
    var deep_buf: [192]u8 = undefined;
    const deep = try std.fmt.bufPrint(&deep_buf, "{s}/home", .{app.dirPath()});
    _ = try app.ctl("split right");
    const other_pane = try app.focusedPane();
    _ = try app.ctlFmt("type cd {s}", .{deep});
    _ = try app.ctl("enter");
    // The cwd is read from the kernel per pane, so the shell has to have
    // actually chdir'd before the jump can find it.
    h.sleepMs(400);
    _ = try app.ctl("focus left");
    const home_pane = try app.focusedPane();
    try h.expect(home_pane != other_pane, "two panes to choose between", .{});

    var payload_buf: [512]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf,
        \\ask {{"cwd":"{s}","questions":[{{"question":"Where from?","options":[{{"label":"ok"}}]}}]}}
    , .{deep});
    _ = try app.ctl(payload);
    const prov = try app.ctl("sidepane");
    try h.expectContains(prov, deep, "the form knows where the ask came from");

    // ⌃G: focus the pane sitting in that directory. Not a dismissal —
    // you jump to LOOK at what is being asked about, and the question
    // has to still be there when you look back.
    _ = try app.ctl("key 07");
    try h.expectEq("jumped to the pane in the ask's cwd", other_pane, try app.focusedPane());
    try h.expectContains(try app.ctl("sidepane"), "Where from?", "the question survived the jump");
    // Focus went to the panes, so typing reaches the shell again.
    _ = try app.ctl("type after-jump");
    _ = try app.ctl("enter");
    try app.waitTextCount("after-jump", 2, 5_000);
    // …and the question is RECOVERABLE after stepping away from it.
    // The form holds the ask while open, so the poller will not offer
    // another — without a way back, a pending question would be alive
    // but unreachable and the asker blocked with no way to answer.
    _ = try app.ctl("run attention.inbox");
    try h.expectContains(try app.ctl("sidepane"), "panel:attention", "switched away from the question");
    _ = try app.ctl("run ask.show");
    try h.expectContains(try app.ctl("sidepane"), "Where from?", "the pending question comes back");
    _ = try app.ctl("enter");
    try h.expectContains(try app.ctl("ask-answer"), "\"selected\":[\"ok\"]", "and is still answerable");

    // --- a label with characters that would break the JSON ---
    // A stray quote in a body the host rejects means the answer is lost
    // and the asker blocks forever, so this is the sharp edge.
    _ = try app.ctl(
        \\ask {"questions":[{"question":"Quote \"this\"?","options":[{"label":"a\"b"}]}]}
    );
    _ = try app.ctl("enter");
    const esc = try app.ctl("ask-answer");
    try h.expectContains(esc, "\\\"", "quotes are escaped in the answer");
}

// ---------------------------------------------------------------- deck

fn deck(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    const wide = try paneCols(app);

    _ = try app.ctl("run agent.view");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "panel:deck", "the deck takes the side pane");
    // No daemon in the sandbox, so the honest render is "unreachable" —
    // NOT "no agents running", which would claim we looked and found
    // nothing. Same rule as the inbox.
    try h.expectContains(st, "host unreachable", "fails open, and says which");
    try h.expect(try paneCols(app) < wide, "deck retiles like any tenant", .{});

    // It opens FOCUSED — unlike the inbox, it is a list you navigate, so
    // handing it the keys is the action you asked for. Proof: typing
    // must not reach the shell.
    _ = try app.ctl("type jjjj");
    try h.expectContains(try app.ctl("dump"), "e2e$", "deck keys did NOT reach the shell");

    // ⌃G means "go to its pane" in the deck exactly as it does in the ask
    // form; Enter means "open it" (its transcript). With no host there is
    // nothing to open, so this only asserts neither key wedges the form.
    _ = try app.ctl("key 07");
    _ = try app.ctl("key 0d");
    try h.expectContains(try app.ctl("sidepane"), "panel:deck", "deck survives enter/^G with no host");

    // ESC yields the keys back without closing the panel — you want to
    // keep looking at the list while you work.
    _ = try app.ctl("key 1b");
    try h.expectContains(try app.ctl("sidepane"), "panel:deck", "ESC leaves the panel open");
    _ = try app.ctl("type back-in-shell");
    _ = try app.ctl("enter");
    try app.waitTextCount("back-in-shell", 2, 5_000);

    // Toggling the same panel closes it and gives the columns back.
    _ = try app.ctl("run agent.view");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    try h.expect(try paneCols(app) > 1, "columns came back", .{});

    // The deck is a registry command like any other, so the palette
    // lists it — that is the whole point of the spine.
    try h.expectContains(try app.ctl("commands"), "agent.view", "registered as a command");
}

// ------------------------------------------------------------- threads

fn threads(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    const wide = try paneCols(app);

    _ = try app.ctl("run threads.toggle");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "panel:threads", "threads takes the side pane");
    try h.expectContains(st, "host unreachable", "fails open, and says which");
    try h.expect(try paneCols(app) < wide, "threads retiles like any tenant", .{});

    // Opens focused, like the deck: it is a list you pick from.
    _ = try app.ctl("type jjkk");
    try h.expectContains(try app.ctl("dump"), "e2e$", "panel keys did NOT reach the shell");
    _ = try app.ctl("key 1b");
    _ = try app.ctl("run threads.toggle");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");

    // The thread verbs reach the registry AND the ex-command bridge.
    const cmds = try app.ctl("commands");
    try h.expectContains(cmds, "thread.note", "thread verbs are commands");
    try h.expectContains(cmds, ":ThreadNote", "…and have derived ex-names");

    // :ThreadNote on a buffer that is NOT a thread must SAY so. A silent
    // no-op here is indistinguishable from a bug, and this is the only
    // half of the thread verbs testable without a host.
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/plain.txt", .{app.dirPath()});
    try h.writeFile(path, "not a thread\n");
    _ = try app.ctlFmt("edit {s}", .{path});
    try app.waitText("not a thread", 5_000);
    _ = try app.ctl("type :ThreadNote");
    _ = try app.ctl("enter");
    try app.waitText("not a thread buffer", 5_000);
}

// ------------------------------------------------- seeding a registry
//
// Both panel scenarios need the same thing: a git repo whose file has
// MOVED since the anchors were taken, and a registry the app will
// actually find. Shared because the schema DDL is the part that must not
// drift between them — two copies would be two chances to test against a
// shape rook does not have.

/// git's own hash of the snapshot below:
///   printf 'l1\nl2\nl3\nl4\nl5\n' | git hash-object --stdin
///
/// Hardcoded rather than computed, so these stay BLACK-BOX checks of the
/// shipped binary: if the app's blobSha ever disagreed with git, the
/// snapshot would not be found, rows would go outdated, and the line
/// assertions are what would catch it.
const snapshot_sha = "b8cb000a15a7fc5e44750b59e867c859c6050a92";

const Registry = struct {
    db_buf: [256]u8 = undefined,
    db_len: usize = 0,
    repo_buf: [256]u8 = undefined,
    repo_len: usize = 0,

    fn db(self: *const Registry) [:0]const u8 {
        return self.db_buf[0..self.db_len :0];
    }
    pub fn repo(self: *const Registry) []const u8 {
        return self.repo_buf[0..self.repo_len];
    }

    /// Run more SQL against the seeded db. "SNAPSHOT" in `sql` is
    /// replaced by the snapshot's sha, which keeps the fixtures readable
    /// — a 40-char hex string repeated inline hides which rows share an
    /// anchor.
    pub fn exec(self: *const Registry, app: *h.Instance, comptime sql: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        var rest: []const u8 = sql;
        while (std.mem.indexOf(u8, rest, "SNAPSHOT")) |i| {
            try w.writeAll(rest[0..i]);
            try w.writeAll(snapshot_sha);
            rest = rest["SNAPSHOT".len + i ..];
        }
        try w.writeAll(rest);
        try w.writeByte(0);
        const sqlz: [*:0]const u8 = @ptrCast(buf[0 .. w.end - 1 :0].ptr);
        if (try h.runCmd(app.dirPath(), &.{ "/usr/bin/sqlite3", self.db().ptr, sqlz }) != 0)
            return error.SeedFailed;
    }
};

/// A repo whose f.zig has drifted from the snapshot by TWO separate
/// insertions — two lines at the top and two more between l2 and l3 —
/// plus an empty registry at XDG_DATA_HOME/rook/rook.db holding a
/// workspace named for the space the sandbox boots into.
///
/// Two insertions rather than one on purpose: an anchor on line 1 sits
/// below only the first and rides to 3, while one on line 3 sits below
/// both and rides to 7. Different DELTAS are what separate real
/// re-anchoring from a constant offset applied to every row — with a
/// single insertion both anchors move by 2 and the assertion proves
/// nothing about the mapping.
fn seedRegistry(app: *h.Instance) !Registry {
    var reg: Registry = .{};

    const repo = try std.fmt.bufPrint(&reg.repo_buf, "{s}/repo", .{app.dirPath()});
    reg.repo_len = repo.len;
    try h.mkdirP(repo);
    if (try h.runCmd(repo, &.{ "/usr/bin/git", "init", "-q" }) != 0) return error.NoGit;
    var f_buf: [256]u8 = undefined;
    try h.writeFile(try std.fmt.bufPrint(&f_buf, "{s}/f.zig", .{repo}), "a\nb\nl1\nl2\nX\nY\nl3\nl4\nl5\n");

    var rookdir_buf: [256]u8 = undefined;
    const rookdir = try std.fmt.bufPrint(&rookdir_buf, "{s}/data/rook", .{app.dirPath()});
    try h.mkdirP(rookdir);
    // bufPrintZ, not bufPrint: this crosses into execv as a C string, and
    // an unterminated slice pointer is a path sqlite cannot open — which
    // surfaces only as a nonzero exit with the output discarded.
    const db = try std.fmt.bufPrintZ(&reg.db_buf, "{s}/rook.db", .{rookdir});
    reg.db_len = db.len;

    // The subset of rook's schema the read side touches, verbatim from
    // internal/host/registry.go — including the three thread columns it
    // adds by ALTER TABLE, because a migrated db is the only shape that
    // exists in the wild.
    var sql_buf: [4096]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf,
        \\CREATE TABLE workspaces (name TEXT PRIMARY KEY, root TEXT NOT NULL DEFAULT '', scratch INTEGER NOT NULL DEFAULT 0, worktree_of TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, last_used TEXT NOT NULL);
        \\CREATE TABLE anchor_blobs (sha TEXT PRIMARY KEY, content BLOB NOT NULL);
        \\CREATE TABLE threads (id INTEGER PRIMARY KEY, workspace TEXT NOT NULL, path TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, side TEXT NOT NULL DEFAULT 'modified', blob_sha TEXT NOT NULL, commit_sha TEXT NOT NULL DEFAULT '', anchor_text TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', resolved_by TEXT NOT NULL DEFAULT '', agent_reopens INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, submitted_at TEXT, rook_task_id INTEGER NOT NULL DEFAULT 0, deliver_error TEXT NOT NULL DEFAULT '', draft TEXT NOT NULL DEFAULT '');
        \\CREATE TABLE thread_comments (id INTEGER PRIMARY KEY, thread_id INTEGER NOT NULL, author TEXT NOT NULL, agent_session TEXT NOT NULL DEFAULT '', body TEXT NOT NULL, created_at TEXT NOT NULL);
        \\CREATE TABLE rook_tasks (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL DEFAULT 0, workspace TEXT NOT NULL, work_type TEXT NOT NULL, state TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', anchor_kind TEXT NOT NULL DEFAULT 'none', path TEXT NOT NULL DEFAULT '', start_line INTEGER NOT NULL DEFAULT 0, end_line INTEGER NOT NULL DEFAULT 0, side TEXT NOT NULL DEFAULT 'modified', blob_sha TEXT NOT NULL DEFAULT '', commit_sha TEXT NOT NULL DEFAULT '', anchor_text TEXT NOT NULL DEFAULT '', anchor_ref TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL DEFAULT 'rook', source_ref TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        \\INSERT INTO workspaces VALUES ('scratch','{s}',0,'','t','t');
        \\INSERT INTO anchor_blobs VALUES ('{s}','l1
        \\l2
        \\l3
        \\l4
        \\l5
        \\');
    , .{ repo, snapshot_sha });
    if (try h.runCmd(app.dirPath(), &.{ "/usr/bin/sqlite3", db.ptr, sql.ptr }) != 0)
        return error.SeedFailed;
    return reg;
}

/// The sidebar with actual threads in it, read from a registry rather
/// than asked of a host — and re-anchored, which is the behaviour no
/// unit test can show you on screen.
///
/// The `threads` scenario above covers the empty/host-unreachable side.
/// This one seeds the sandbox's own registry so the LOCAL arm engages.
fn threadRows(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var reg = try seedRegistry(app);
    try reg.exec(app,
        \\INSERT INTO threads (id,workspace,path,start_line,end_line,blob_sha,anchor_text,state,created_at,updated_at,draft,deliver_error)
        \\ VALUES (1,'scratch','f.zig',3,4,'SNAPSHOT','l3','open','t','t','',''),
        \\        (2,'scratch','other.zig',9,9,'nosnapshot','x','pending','t','t','tail',''),
        \\        (3,'scratch','gone.zig',1,1,'nosnapshot','y','resolved','t','t','','');
    );

    _ = try app.ctl("run threads.toggle");
    try h.expectContains(try app.ctl("sidepane"), "panel:threads", "threads takes the side pane");

    // THE assertion, and it doubles as the wait: the row shows line 7,
    // not the 3 the thread was written against. That is the re-anchor
    // happening inside the shipped binary, against a real working tree,
    // with no host anywhere.
    //
    // Read through ctl rather than the screen: a side panel is window
    // chrome, and `screen` dumps the focused pane's grid — asserting
    // there passes only by accident and fails with a shell prompt as
    // evidence.
    const rows = try app.waitCtl("sidepane", "f.zig:7", 10_000);

    // The local arm answered, so the panel is not reporting a host it
    // never needed.
    try h.expectNotContains(rows, "host unreachable", "the local arm answered");
    try h.expectContains(rows, "l3", "the row renders its anchor text");

    // The un-snapshotted thread cannot be re-anchored, so it keeps its
    // stored line rather than guessing — and it shows its draft mark.
    try h.expectContains(rows, "other.zig:9", "no snapshot, no movement");
    try h.expectContains(rows, "(draft)", "an unsent draft is marked");

    // The resolved one is absent: the list is what still wants you.
    try h.expectNotContains(rows, "gone.zig", "resolved threads are history");

    // ...and it actually DREW. Two shots — panel shut, panel open — and
    // the right-hand strip has to differ. Self-calibrating: it needs no
    // constant for the panel's width, and it is the only assertion here
    // that a data-correct panel rendering nothing would fail.
    _ = try app.ctl("run threads.toggle");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    var p1: [256]u8 = undefined;
    var shut = try app.shot(try std.fmt.bufPrint(&p1, "{s}/shut.png", .{app.dirPath()}));
    defer shut.deinit();

    _ = try app.ctl("run threads.toggle");
    _ = try app.waitCtl("sidepane", "f.zig:7", 10_000);
    var p2: [256]u8 = undefined;
    var open = try app.shot(try std.fmt.bufPrint(&p2, "{s}/open.png", .{app.dirPath()}));
    defer open.deinit();

    try h.expect(
        shut.width == open.width and shut.height == open.height,
        "shots disagree on size: {d}x{d} vs {d}x{d}",
        .{ shut.width, shut.height, open.width, open.height },
    );
    var changed: usize = 0;
    var y: usize = 0;
    while (y < open.height) : (y += 4) {
        var x = open.width - open.width / 5;
        while (x < open.width) : (x += 4) {
            if (shut.pixel(x, y) != open.pixel(x, y)) changed += 1;
        }
    }
    try h.expect(changed > 50, "the panel strip barely changed ({d} px) — the rows were right but nothing drew", .{changed});
}

/// The review panel with an actual review in it, computed here rather
/// than handed over by a host: the gate, the attention order, and the
/// re-anchored lines.
///
/// The `review` scenario above covers the empty/host-unreachable side and
/// the verdict keys. This one seeds the sandbox's own registry so the
/// LOCAL arm engages and the gate is computed in this process.
fn reviewRows(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }

    var reg = try seedRegistry(app);
    // A review parent and three findings. Two share the snapshot and sit
    // below different amounts of drift, so they re-anchor by different
    // DELTAS — line 3 rides to 7 (below both insertions) and line 1 to 3
    // (below only the first). Equal deltas would not distinguish real
    // mapping from a constant offset. The third has no snapshot at all
    // and must not move.
    //
    // States are chosen so the gate has something to say: rejected and
    // proposed block, approved does not, so 2 of 3 block and the gate is
    // shut. Risks 9 and 2 fix the attention order between the blockers.
    try reg.exec(app,
        \\INSERT INTO rook_tasks (id,parent_id,workspace,work_type,state,title,anchor_kind,detail,created_at,updated_at)
        \\ VALUES (1,0,'scratch','review','reviewing','review','ref','{"label":"unstaged","verb":"commit"}','t','t');
        \\INSERT INTO rook_tasks (id,parent_id,workspace,work_type,state,title,anchor_kind,path,start_line,end_line,blob_sha,detail,created_at,updated_at)
        \\ VALUES (2,1,'scratch','review','rejected','f.zig:3','code','f.zig',3,4,'SNAPSHOT','{"summary":"off by one","category":"logic","score":{"risk":9}}','t','t'),
        \\        (3,1,'scratch','review','proposed','other.zig:9','code','other.zig',9,9,'','{"summary":"unclear name","category":"style","score":{"risk":2}}','t','t'),
        \\        (4,1,'scratch','review','approved','f.zig:1','code','f.zig',1,1,'SNAPSHOT','{"summary":"reads fine","category":"style","score":{"risk":1}}','t','t');
    );

    _ = try app.ctl("run review.changes");
    try h.expectContains(try app.ctl("sidepane"), "panel:review", "review takes the side pane");

    // Doubles as the wait: the finding was written against line 3 and the
    // row has to say 7. Read through ctl, because a side panel is window
    // chrome and `screen` dumps the focused pane's grid.
    const out = try app.waitCtl("sidepane", "f.zig:7", 10_000);

    // The local arm answered, so the panel is not reporting a host it
    // never needed.
    try h.expectNotContains(out, "host unreachable", "the local arm answered");

    // The GATE, computed in this process from the children's states —
    // not a number the host handed over. 2 of 3 block, so it is shut.
    try h.expectContains(out, "gate commit blocked blocking=2 total=3", "the gate is computed locally");
    try h.expectContains(out, "unstaged", "the review's label, from its detail bag");

    // The second re-anchored row moves by a DIFFERENT delta: 1 -> 3,
    // where the first went 3 -> 7. That difference is the thing that
    // separates a real mapping from a constant offset applied to
    // everything, and it is why the fixture has two insertions.
    try h.expectContains(out, "f.zig:3", "the second anchor re-anchored by its own delta");
    // No snapshot, so no movement — a finding that cannot be mapped keeps
    // where it was written rather than guessing.
    try h.expectContains(out, "other.zig:9", "no snapshot, no movement");

    // Summaries, not titles: the title is just path:line, which the row
    // already shows.
    try h.expectContains(out, "off by one", "the summary is what you triage on");

    // Attention order: blocking first, riskiest first. The rejected
    // risk-9 finding leads, the approved one is last.
    const rejected_at = std.mem.indexOf(u8, out, "rejected").?;
    const proposed_at = std.mem.indexOf(u8, out, "proposed").?;
    const approved_at = std.mem.indexOf(u8, out, "approved").?;
    try h.expect(rejected_at < proposed_at, "riskier blocker should sort first", .{});
    try h.expect(proposed_at < approved_at, "blockers should sort before cleared findings", .{});

    // ...and it actually DREW. Two shots, panel shut then open, and the
    // right-hand strip has to differ. Self-calibrating — no constant for
    // the panel's width — and the only assertion here that a
    // data-correct panel rendering nothing would fail.
    _ = try app.ctl("run review.changes");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    var p1: [256]u8 = undefined;
    var shut = try app.shot(try std.fmt.bufPrint(&p1, "{s}/shut.png", .{app.dirPath()}));
    defer shut.deinit();

    _ = try app.ctl("run review.changes");
    _ = try app.waitCtl("sidepane", "f.zig:7", 10_000);
    var p2: [256]u8 = undefined;
    var open = try app.shot(try std.fmt.bufPrint(&p2, "{s}/open.png", .{app.dirPath()}));
    defer open.deinit();

    try h.expect(
        shut.width == open.width and shut.height == open.height,
        "shots disagree on size: {d}x{d} vs {d}x{d}",
        .{ shut.width, shut.height, open.width, open.height },
    );
    var changed: usize = 0;
    var y: usize = 0;
    while (y < open.height) : (y += 4) {
        var x = open.width - open.width / 5;
        while (x < open.width) : (x += 4) {
            if (shut.pixel(x, y) != open.pixel(x, y)) changed += 1;
        }
    }
    try h.expect(changed > 50, "the panel strip barely changed ({d} px) — the rows were right but nothing drew", .{changed});
}

// -------------------------------------------------------------- review

fn review(gpa: std.mem.Allocator, bin: []const u8) !void {
    const app = try h.Instance.start(gpa, bin, .{});
    defer {
        app.stop();
        app.deinit();
    }
    const wide = try paneCols(app);

    _ = try app.ctl("run review.changes");
    const st = try app.ctl("sidepane");
    try h.expectContains(st, "panel:review", "review takes the side pane");
    try h.expectContains(st, "host unreachable", "fails open, and says which");
    try h.expect(try paneCols(app) < wide, "review retiles like any tenant", .{});

    // Opens FOCUSED and holds the verdict keys. a/r/d are single letters
    // on purpose — triaging 52 findings pays every extra keystroke 52
    // times — which makes "do they leak to the shell" the sharp question.
    _ = try app.ctl("type ard");
    _ = try app.ctl("type jjkk");
    try h.expectContains(try app.ctl("dump"), "e2e$", "verdict keys did NOT reach the shell");

    _ = try app.ctl("key 1b");
    try h.expectContains(try app.ctl("sidepane"), "panel:review", "ESC leaves the panel open");
    _ = try app.ctl("type back-in-shell");
    _ = try app.ctl("enter");
    try app.waitTextCount("back-in-shell", 2, 5_000);

    _ = try app.ctl("run review.changes");
    try h.expectContains(try app.ctl("sidepane"), "closed", "toggled shut");
    try h.expect(try paneCols(app) > 1, "columns came back", .{});
    try h.expectContains(try app.ctl("commands"), "review.changes", "registered as a command");
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
    const bin = std.mem.span(argv[1]);
    const filters = argv[2..];

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
