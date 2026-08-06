//! Hover documentation, laid out for a float.
//!
//! A language server answers `textDocument/hover` with markdown, and
//! every server writes a different dialect of it. gopls leads with a
//! fenced signature and follows with the doc comment. pyright puts the
//! signature AND the docstring inside one fence. rust-analyzer opens
//! with a `---`-delimited header. tsserver emits `**bold**` prose with
//! inline backticks. Rendering any of that into a one-line status row
//! throws away everything after the first line; rendering it raw into a
//! float shows you the backticks.
//!
//! So this file is the layout pass: markdown in, styled rows out, at a
//! width the float chooses. It is pure — no editor, no renderer, no I/O
//! beyond the allocator it is handed — because every interesting case
//! here is a TEXT case, and text cases are cheap to pin in a test.
//!
//! The markdown subset is the one hovers actually use: fenced code,
//! ATX headings, thematic breaks, block quotes, bullet and ordered
//! lists, inline code, emphasis, and links. Anything unrecognised
//! survives as its own text rather than being dropped — an unhandled
//! construct should read as slightly literal prose, never as a missing
//! paragraph. That rule is why `_` emphasis is deliberately fussy: a
//! Go doc comment is full of `snake_case` identifiers, and a lenient
//! reading of `_` would eat the middle of every one of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");

/// What a run of text IS, rather than what colour it should be. The
/// editor maps these onto its own Style — this file has no opinion
/// about the theme, which is what keeps it testable.
pub const Ink = enum {
    /// Ordinary body text.
    prose,
    /// `**bold**` or `*italic*` — markdown does not distinguish enough
    /// for a terminal grid to, so both land here.
    emph,
    /// A line inside a fenced block.
    code,
    /// `inline code`.
    icode,
    /// An ATX heading, markers stripped.
    head,
    /// A thematic break. Carries no text: the painter draws the rule
    /// across whatever width the float turned out to be, which is not
    /// known here.
    rule,
    /// The label of a `[link](url)`, or a bare URL.
    link,
};

/// One styled span of a row. Offsets index `Doc.blob`.
pub const Run = struct { off: u32, len: u32, ink: Ink };

/// A hover, wrapped into rows.
///
/// Rows are stored flat: every run of every row in one list, with
/// `starts` marking where each row begins. One allocation-shaped thing
/// instead of a list of lists, because the float redraws every frame
/// and walking a slice is the whole of the paint loop.
pub const Doc = struct {
    blob: std.ArrayListUnmanaged(u8) = .empty,
    runs: std.ArrayListUnmanaged(Run) = .empty,
    /// `rowCount() + 1` entries: row `i` is `runs[starts[i]..starts[i+1]]`.
    starts: std.ArrayListUnmanaged(u32) = .empty,
    /// The first fence's info string ("go", "python"), for the badge in
    /// the footer. Fixed storage: a language name that does not fit in
    /// twenty-four bytes is not a language name.
    lang_buf: [24]u8 = undefined,
    lang_len: usize = 0,
    /// Display width of the widest row. The float shrinks to this when
    /// it is narrower than the width layout was allowed — a two-word
    /// hover should not open a box the width of the pane.
    width: usize = 0,

    pub fn deinit(self: *Doc, gpa: Allocator) void {
        self.blob.deinit(gpa);
        self.runs.deinit(gpa);
        self.starts.deinit(gpa);
        self.* = .{};
    }

    pub fn rowCount(self: *const Doc) usize {
        return self.starts.items.len -| 1;
    }

    pub fn row(self: *const Doc, i: usize) []const Run {
        if (i + 1 >= self.starts.items.len) return &.{};
        return self.runs.items[self.starts.items[i]..self.starts.items[i + 1]];
    }

    pub fn text(self: *const Doc, r: Run) []const u8 {
        if (r.off + r.len > self.blob.items.len) return &.{};
        return self.blob.items[r.off..][0..r.len];
    }

    pub fn lang(self: *const Doc) []const u8 {
        return self.lang_buf[0..self.lang_len];
    }

    /// True when the row is a fenced code line — the painter fills the
    /// whole inner width for those, so a block reads as a block rather
    /// than as ragged bright text.
    pub fn rowIsCode(self: *const Doc, i: usize) bool {
        const r = self.row(i);
        return r.len > 0 and r[0].ink == .code;
    }

    /// True when the row is a thematic break.
    pub fn rowIsRule(self: *const Doc, i: usize) bool {
        const r = self.row(i);
        return r.len > 0 and r[0].ink == .rule;
    }
};

/// A hover big enough to hit either of these is a server having a bad
/// day, not a document anybody is going to read. Layout stops rather
/// than growing without bound under the draw lock.
const max_rows = 300;
const max_blob = 64 * 1024;

/// Display width of `s` in terminal cells.
fn cells(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const c = editor.Editor.clusterAt(s, i);
        n += c.width;
        i += c.len;
    }
    return n;
}

const Build = struct {
    gpa: Allocator,
    d: *Doc,
    /// The width text may occupy. Not the box width: the border and its
    /// padding are the painter's, and layout never sees them.
    max_w: usize,
    /// Display width of the row being built.
    w: usize = 0,
    /// Continuation indent for the paragraph being wrapped, so a bullet
    /// hangs under its own text instead of under its marker.
    hang: usize = 0,
    full: bool = false,

    const spaces = " " ** 16;

    fn atCap(self: *Build) bool {
        if (self.full) return true;
        if (self.d.rowCount() >= max_rows or self.d.blob.items.len >= max_blob) {
            self.full = true;
        }
        return self.full;
    }

    /// Append text to the row being built. Merges into the previous run
    /// when it is the same ink and contiguous in the blob, which is the
    /// common case — a wrapped paragraph is one long `.prose` run per
    /// row, not one per word.
    fn put(self: *Build, s: []const u8, ink: Ink) void {
        if (s.len == 0 or self.atCap()) return;
        const off = self.d.blob.items.len;
        self.d.blob.appendSlice(self.gpa, s) catch return;
        self.w += cells(s);
        const row_start = self.d.starts.items[self.d.starts.items.len - 1];
        if (self.d.runs.items.len > row_start) {
            const last = &self.d.runs.items[self.d.runs.items.len - 1];
            if (last.ink == ink and last.off + last.len == off) {
                last.len += @intCast(s.len);
                return;
            }
        }
        self.d.runs.append(self.gpa, .{
            .off = @intCast(off),
            .len = @intCast(s.len),
            .ink = ink,
        }) catch {};
    }

    fn endRow(self: *Build) void {
        if (self.full) return;
        self.d.width = @max(self.d.width, self.w);
        self.w = 0;
        self.d.starts.append(self.gpa, @intCast(self.d.runs.items.len)) catch {
            self.full = true;
        };
    }

    fn indent(self: *Build, n: usize) void {
        if (n == 0) return;
        self.put(spaces[0..@min(n, spaces.len)], .prose);
    }

    /// Put `s`, breaking it across rows at cluster boundaries when it
    /// does not fit. For a code line, or for one "word" longer than the
    /// float — a hundred-character Rust type is both.
    fn putHard(self: *Build, s: []const u8, ink: Ink) void {
        var i: usize = 0;
        while (i < s.len and !self.atCap()) {
            var j = i;
            var used = self.w;
            while (j < s.len) {
                const c = editor.Editor.clusterAt(s, j);
                if (used + c.width > self.max_w) break;
                used += c.width;
                j += c.len;
            }
            if (j == i) {
                // Not one cluster fits on what is left of this row.
                // Break and try again on a fresh one; if it does not fit
                // there either the float is narrower than a character
                // and there is nothing sensible to draw.
                if (self.w == 0) return;
                self.endRow();
                self.indent(self.hang);
                continue;
            }
            self.put(s[i..j], ink);
            i = j;
            if (i < s.len) {
                self.endRow();
                self.indent(self.hang);
            }
        }
    }
};

/// One word, with the ink it inherited from the inline markup it came
/// out of and whether the source had whitespace in front of it. That
/// last flag is what keeps `` `x`, `` from being laid out as `x ,`.
const Tok = struct { s: []const u8, ink: Ink, space: bool };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Split `s` into words, all carrying `ink`.
fn words(gpa: Allocator, out: *std.ArrayListUnmanaged(Tok), s: []const u8, ink: Ink, lead: bool) void {
    var lead_space = lead or (s.len > 0 and isSpace(s[0]));
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and isSpace(s[i])) : (i += 1) lead_space = true;
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and !isSpace(s[i])) i += 1;
        out.append(gpa, .{ .s = s[start..i], .ink = ink, .space = lead_space }) catch return;
        lead_space = true;
    }
}

/// True when `s[i]` opens or closes emphasis at a word boundary —
/// the guard that stops `snake_case_names` losing their middle.
fn boundary(s: []const u8, i: usize, opening: bool) bool {
    const outside = if (opening)
        (if (i == 0) @as(u8, ' ') else s[i - 1])
    else
        (if (i + 1 >= s.len) @as(u8, ' ') else s[i + 1]);
    if (opening) return !std.ascii.isAlphanumeric(outside) and outside != '_';
    return !std.ascii.isAlphanumeric(outside);
}

fn isUrlStart(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// Emphasis and link labels nest — `` [`Close` on the docs](url) `` is
/// ordinary in a Go hover — so the inline pass recurses into them. The
/// depth cap is the only thing between this and a server that sends
/// `[[[[[…`; four is more nesting than documentation has ever wanted.
const max_nest = 4;

/// Re-ink whatever the recursion produced: the span's own ink wins over
/// plain prose, and anything the inner pass recognised as more specific
/// than prose keeps what it found.
fn reink(out: *std.ArrayListUnmanaged(Tok), from: usize, ink: Ink, lead: bool) void {
    for (out.items[from..]) |*t| {
        if (t.ink == .prose) t.ink = ink;
    }
    if (out.items.len > from) out.items[from].space = lead;
}

/// Turn one paragraph's source into words carrying inks.
fn inlines(gpa: Allocator, out: *std.ArrayListUnmanaged(Tok), src: []const u8) void {
    inlinesDepth(gpa, out, src, 0);
}

fn inlinesDepth(gpa: Allocator, out: *std.ArrayListUnmanaged(Tok), src: []const u8, depth: usize) void {
    var plain_from: usize = 0;
    var i: usize = 0;

    // Emit whatever plain text has accumulated, then whatever the
    // markup produced. `lead` carries "there was a space before this"
    // across the boundary between the two.
    const flush = struct {
        fn f(g: Allocator, o: *std.ArrayListUnmanaged(Tok), s: []const u8, from: usize, to: usize) void {
            if (to > from) words(g, o, s[from..to], .prose, from > 0 and isSpace(s[from - 1]));
        }
    }.f;

    while (i < src.len) {
        const c = src[i];
        // A backslash escape is the markdown source saying "this
        // character is not markup". Honour it: a doc comment about
        // globs is full of `\*`.
        if (c == '\\' and i + 1 < src.len and !std.ascii.isAlphanumeric(src[i + 1])) {
            flush(gpa, out, src, plain_from, i);
            words(gpa, out, src[i + 1 ..][0..1], .prose, i > 0 and isSpace(src[i - 1]));
            i += 2;
            plain_from = i;
            continue;
        }
        if (c == '`') {
            // Runs of backticks delimit each other, so ``a `b` c``
            // works the way it reads.
            var open = i;
            while (open < src.len and src[open] == '`') open += 1;
            const ticks = src[i..open];
            if (std.mem.indexOfPos(u8, src, open, ticks)) |close| {
                flush(gpa, out, src, plain_from, i);
                words(gpa, out, src[open..close], .icode, i > 0 and isSpace(src[i - 1]));
                i = close + ticks.len;
                plain_from = i;
                continue;
            }
        }
        if (c == '[') {
            // [label](url) — the label is what a reader wants; the URL
            // is a thing a terminal cannot click anyway.
            if (std.mem.indexOfScalarPos(u8, src, i, ']')) |rb| {
                if (rb + 1 < src.len and src[rb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, src, rb, ')')) |rp| {
                        flush(gpa, out, src, plain_from, i);
                        const lead = i > 0 and isSpace(src[i - 1]);
                        const mark = out.items.len;
                        if (depth < max_nest) {
                            inlinesDepth(gpa, out, src[i + 1 .. rb], depth + 1);
                            reink(out, mark, .link, lead);
                        } else words(gpa, out, src[i + 1 .. rb], .link, lead);
                        i = rp + 1;
                        plain_from = i;
                        continue;
                    }
                }
            }
        }
        if ((c == '*' or c == '_') and boundary(src, i, true)) {
            const double = i + 1 < src.len and src[i + 1] == c;
            const mark: []const u8 = if (double) src[i .. i + 2] else src[i .. i + 1];
            var from = i + mark.len;
            while (std.mem.indexOfPos(u8, src, from, mark)) |close| {
                if (close == i + mark.len or !boundary(src, close + mark.len - 1, false)) {
                    from = close + 1;
                    continue;
                }
                flush(gpa, out, src, plain_from, i);
                const lead = i > 0 and isSpace(src[i - 1]);
                const at = out.items.len;
                if (depth < max_nest) {
                    inlinesDepth(gpa, out, src[i + mark.len .. close], depth + 1);
                    reink(out, at, .emph, lead);
                } else words(gpa, out, src[i + mark.len .. close], .emph, lead);
                i = close + mark.len;
                plain_from = i;
                break;
            } else {
                i += mark.len;
                continue;
            }
            continue;
        }
        if ((i == 0 or isSpace(src[i - 1])) and isUrlStart(src[i..])) {
            flush(gpa, out, src, plain_from, i);
            var j = i;
            while (j < src.len and !isSpace(src[j])) j += 1;
            words(gpa, out, src[i..j], .link, i > 0);
            i = j;
            plain_from = i;
            continue;
        }
        i += 1;
    }
    flush(gpa, out, src, plain_from, src.len);
}

/// The `- `, `* `, `1. ` at the head of a list item: its width, or 0.
fn bulletLen(s: []const u8) usize {
    if (s.len >= 2 and (s[0] == '-' or s[0] == '*' or s[0] == '+') and isSpace(s[1])) return 2;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i > 0 and i + 1 < s.len and (s[i] == '.' or s[i] == ')') and isSpace(s[i + 1])) return i + 2;
    return 0;
}

/// A `---`, `***` or `___` line on its own.
fn isRule(s: []const u8) bool {
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1 else if (!isSpace(ch)) return false;
    }
    return n >= 3;
}

/// A ``` or ~~~ fence: the run length and the info string after it.
const Fence = struct { ch: u8, len: usize, info: []const u8 };

fn fenceAt(s: []const u8) ?Fence {
    if (s.len < 3) return null;
    const c = s[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < s.len and s[n] == c) n += 1;
    if (n < 3) return null;
    return .{ .ch = c, .len = n, .info = std.mem.trim(u8, s[n..], " \t") };
}

/// Lay `md` out into rows no wider than `max_w` cells.
///
/// Never fails: an allocation that does not happen truncates the
/// document. A hover that is half there beats a hover that is an error
/// message about a hover.
pub fn layout(gpa: Allocator, md: []const u8, max_w_in: usize) Doc {
    var d: Doc = .{};
    var b: Build = .{ .gpa = gpa, .d = &d, .max_w = @max(max_w_in, 8) };
    d.starts.append(gpa, 0) catch return d;

    var para: std.ArrayListUnmanaged(u8) = .empty;
    defer para.deinit(gpa);
    var toks: std.ArrayListUnmanaged(Tok) = .empty;
    defer toks.deinit(gpa);

    var para_hang: usize = 0;
    var in_fence: ?Fence = null;
    // Blank lines are held rather than drawn, so a document that ends
    // in three of them does not open a float with three empty rows at
    // the bottom, and a leading blank never pushes the first line down.
    var pending_blank = false;
    var any = false;

    // Wrap whatever prose has accumulated and start a fresh paragraph.
    const flushPara = struct {
        fn f(
            g: Allocator, bb: *Build, p: *std.ArrayListUnmanaged(u8),
            t: *std.ArrayListUnmanaged(Tok), hang: usize,
        ) void {
            defer p.clearRetainingCapacity();
            if (p.items.len == 0) return;
            t.clearRetainingCapacity();
            inlines(g, t, p.items);
            bb.hang = hang;
            defer bb.hang = 0;
            var first = true;
            var prev: Ink = .prose;
            for (t.items) |tok| {
                const gap: usize = if (!first and tok.space) 1 else 0;
                const need = gap + cells(tok.s);
                if (!first and bb.w + need > bb.max_w) {
                    bb.endRow();
                    bb.indent(hang);
                    bb.putHard(tok.s, tok.ink);
                } else {
                    // The space INSIDE a span belongs to it, so that
                    // `a b` in backticks fills as one block instead of
                    // two with a hole between them. A space at the edge
                    // of a span is ordinary prose.
                    if (gap > 0) bb.put(" ", if (prev == tok.ink) tok.ink else .prose);
                    bb.putHard(tok.s, tok.ink);
                }
                prev = tok.ink;
                first = false;
            }
            if (!first) bb.endRow();
        }
    }.f;

    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        if (b.atCap()) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (in_fence) |f| {
            // Only a fence of the same character and at least the same
            // length closes it, so a ``` inside a ~~~~ block stays text.
            if (fenceAt(trimmed)) |close| {
                if (close.ch == f.ch and close.len >= f.len and close.info.len == 0) {
                    in_fence = null;
                    continue;
                }
            }
            if (pending_blank) {
                b.endRow();
                pending_blank = false;
            }
            // A blank line inside a fence is part of the block: it
            // separates a signature from the body pyright put in the
            // same fence, and losing it welds them together.
            if (line.len == 0) {
                b.put(" ", .code);
                b.endRow();
            } else {
                b.putHard(line, .code);
                b.endRow();
            }
            any = true;
            continue;
        }

        if (fenceAt(trimmed)) |f| {
            flushPara(gpa, &b, &para, &toks, para_hang);
            if (pending_blank and any) {
                b.endRow();
                pending_blank = false;
            }
            if (d.lang_len == 0 and f.info.len > 0) {
                // Only the language, not the rest of the info string:
                // some servers write ```go title=... and the badge has
                // room for one word.
                const w = f.info[0 .. std.mem.indexOfAny(u8, f.info, " \t") orelse f.info.len];
                d.lang_len = @min(w.len, d.lang_buf.len);
                @memcpy(d.lang_buf[0..d.lang_len], w[0..d.lang_len]);
            }
            in_fence = f;
            continue;
        }

        if (line.len == 0 or std.mem.trim(u8, line, " \t").len == 0) {
            flushPara(gpa, &b, &para, &toks, para_hang);
            // A rule is already a separator. The blank line servers put
            // under one would otherwise open a hole beneath every
            // horizontal line rust-analyzer draws.
            const after_rule = d.rowCount() > 0 and d.rowIsRule(d.rowCount() - 1);
            if (any and !after_rule) pending_blank = true;
            continue;
        }

        if (isRule(trimmed)) {
            flushPara(gpa, &b, &para, &toks, para_hang);
            // A rule already separates; a blank on either side of it is
            // spacing nobody asked for.
            pending_blank = false;
            // An empty run: the rule's whole content is its width, and
            // its width is the float's, which is not known here.
            d.runs.append(gpa, .{ .off = @intCast(d.blob.items.len), .len = 0, .ink = .rule }) catch {};
            b.endRow();
            any = true;
            continue;
        }

        if (pending_blank) {
            b.endRow();
            pending_blank = false;
        }

        if (trimmed.len > 0 and trimmed[0] == '#') {
            var h: usize = 0;
            while (h < trimmed.len and trimmed[h] == '#') h += 1;
            if (h <= 6 and h < trimmed.len and isSpace(trimmed[h])) {
                flushPara(gpa, &b, &para, &toks, para_hang);
                b.putHard(std.mem.trim(u8, trimmed[h..], " \t#"), .head);
                b.endRow();
                any = true;
                continue;
            }
        }

        // A block quote is prose that happens to be quoted; the marker
        // itself is not worth a column in a box this small.
        var body = trimmed;
        if (body.len > 0 and body[0] == '>') {
            flushPara(gpa, &b, &para, &toks, para_hang);
            body = std.mem.trimStart(u8, body[1..], " \t");
        }

        const bl = bulletLen(body);
        if (bl > 0) {
            // A new item ends the previous one: list items do not run
            // into each other the way prose lines do.
            flushPara(gpa, &b, &para, &toks, para_hang);
            para_hang = bl;
            // The marker rides in the paragraph source so it wraps with
            // the item, but normalised — `+` and `1)` both read as
            // bullets once the numbering is gone from the column.
            para.appendSlice(gpa, body[0..bl]) catch {};
            para.appendSlice(gpa, body[bl..]) catch {};
            any = true;
            continue;
        }

        // An ordinary prose line joins the paragraph above it, the way
        // markdown says it does — a doc comment hard-wrapped at 70
        // columns must reflow to the width of THIS float, not keep the
        // author's line breaks.
        if (para.items.len > 0) para.append(gpa, ' ') catch {};
        if (para.items.len == 0) para_hang = 0;
        para.appendSlice(gpa, body) catch {};
        any = true;
    }
    flushPara(gpa, &b, &para, &toks, para_hang);

    // A trailing partial row (never happens through flushPara, but a
    // truncated document can leave one) still has to be closed or its
    // runs belong to no row at all.
    if (d.runs.items.len > d.starts.items[d.starts.items.len - 1]) b.endRow();
    return d;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A row as plain text, for asserting on shape.
fn rowText(gpa: Allocator, d: *const Doc, i: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (d.row(i)) |r| try out.appendSlice(gpa, d.text(r));
    return out.toOwnedSlice(gpa);
}

fn expectRow(d: *const Doc, i: usize, want: []const u8) !void {
    const got = try rowText(testing.allocator, d, i);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The ink of the first run of a row.
fn rowInk(d: *const Doc, i: usize) Ink {
    const r = d.row(i);
    return if (r.len > 0) r[0].ink else .prose;
}

test "gopls: a fenced signature and the doc comment under it" {
    const md =
        \\```go
        \\func Greet(name string) string
        \\```
        \\
        \\Greet returns a greeting.
    ;
    var d = layout(testing.allocator, md, 60);
    defer d.deinit(testing.allocator);

    try testing.expectEqualStrings("go", d.lang());
    try testing.expectEqual(@as(usize, 3), d.rowCount());
    try expectRow(&d, 0, "func Greet(name string) string");
    try testing.expectEqual(Ink.code, rowInk(&d, 0));
    // The fence lines themselves are markup, not content.
    try expectRow(&d, 1, "");
    try expectRow(&d, 2, "Greet returns a greeting.");
    try testing.expectEqual(Ink.prose, rowInk(&d, 2));
    // The box is as wide as its widest row, not as wide as it was let.
    try testing.expectEqual(@as(usize, 30), d.width);
}

test "a hard-wrapped doc comment reflows to the float's width" {
    // The author wrapped at their own margin. A float 24 wide has to
    // rewrap: keeping the source's breaks would leave a ragged column
    // with a hole down the middle of it.
    const md =
        \\The quick brown fox
        \\jumps over the lazy dog.
    ;
    var d = layout(testing.allocator, md, 24);
    defer d.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), d.rowCount());
    try expectRow(&d, 0, "The quick brown fox");
    try expectRow(&d, 1, "jumps over the lazy dog.");
    try testing.expect(d.width <= 24);
}

test "snake_case survives underscore emphasis" {
    // The reason emphasis checks word boundaries at all. A Go doc
    // comment naming `max_conn_idle` must not come out as `maxconnidle`
    // with the middle in italics.
    var d = layout(testing.allocator, "sets max_conn_idle on the pool", 60);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "sets max_conn_idle on the pool");
    try testing.expectEqual(Ink.prose, rowInk(&d, 0));
}

test "inline markup is stripped and inked, not printed" {
    var d = layout(testing.allocator, "call `Close` when **done**", 60);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "call Close when done");

    const r = d.row(0);
    var saw_code = false;
    var saw_emph = false;
    for (r) |run| {
        if (run.ink == .icode) {
            try testing.expectEqualStrings("Close", d.text(run));
            saw_code = true;
        }
        if (run.ink == .emph) {
            try testing.expectEqualStrings("done", d.text(run));
            saw_emph = true;
        }
    }
    try testing.expect(saw_code);
    try testing.expect(saw_emph);
}

test "punctuation stays welded to the code span before it" {
    // The whole reason a token carries whether the SOURCE had a space
    // in front of it. Joining on words alone gives `Close , then`.
    var d = layout(testing.allocator, "call `Close`, then `Wait`.", 60);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "call Close, then Wait.");
}

test "a link keeps its label and drops its URL" {
    var d = layout(testing.allocator, "see [the docs](https://example.com/x) for more", 60);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "see the docs for more");
    var saw = false;
    for (d.row(0)) |run| {
        if (run.ink == .link) {
            try testing.expectEqualStrings("the docs", d.text(run));
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "markup nested inside a link label is still markup" {
    // gopls ends most hovers with exactly this shape. The label is not
    // plain text: the identifier inside it is backticked, and printing
    // those backticks is the tell that the label was never parsed.
    var d = layout(testing.allocator, "[`Greet` on pkg.go.dev](https://pkg.go.dev/x#Greet)", 60);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "Greet on pkg.go.dev");

    // The identifier keeps the code ink it earned; the rest of the
    // label takes the link's.
    var code: []const u8 = "";
    var link: []const u8 = "";
    for (d.row(0)) |run| {
        if (run.ink == .icode) code = d.text(run);
        if (run.ink == .link) link = d.text(run);
    }
    try testing.expectEqualStrings("Greet", code);
    try testing.expectEqualStrings("on pkg.go.dev", link);
}

test "nesting is bounded" {
    // A server that sends a thousand open brackets gets laid out, not
    // recursed into forever.
    const gpa = testing.allocator;
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..1000) |_| try deep.append(gpa, '[');
    try deep.appendSlice(gpa, "x](u)");
    var d = layout(gpa, deep.items, 40);
    defer d.deinit(gpa);
    try testing.expect(d.rowCount() >= 1);
}

test "a bare URL is a link and is never broken across rows" {
    var d = layout(testing.allocator, "docs at https://pkg.go.dev/fmt#Println here", 60);
    defer d.deinit(testing.allocator);
    var saw = false;
    for (0..d.rowCount()) |i| {
        for (d.row(i)) |run| {
            if (run.ink == .link) {
                try testing.expectEqualStrings("https://pkg.go.dev/fmt#Println", d.text(run));
                saw = true;
            }
        }
    }
    try testing.expect(saw);
}

test "rust-analyzer's rule, heading and list" {
    const md =
        \\# Greeter
        \\
        \\---
        \\
        \\- first item that is quite long indeed
        \\- second
    ;
    var d = layout(testing.allocator, md, 20);
    defer d.deinit(testing.allocator);

    try expectRow(&d, 0, "Greeter");
    try testing.expectEqual(Ink.head, rowInk(&d, 0));
    try testing.expect(d.rowIsRule(1));
    // The item wraps, and the continuation hangs under its text rather
    // than under the bullet.
    try expectRow(&d, 2, "- first item that is");
    try expectRow(&d, 3, "  quite long indeed");
    try expectRow(&d, 4, "- second");
    try testing.expectEqual(@as(usize, 5), d.rowCount());
}

test "pyright: signature and docstring inside one fence keep their blank line" {
    const md =
        \\```python
        \\(function) def greet(name: str) -> str
        \\
        \\Says hi.
        \\```
    ;
    var d = layout(testing.allocator, md, 60);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("python", d.lang());
    try testing.expectEqual(@as(usize, 3), d.rowCount());
    try expectRow(&d, 0, "(function) def greet(name: str) -> str");
    try expectRow(&d, 1, " ");
    try expectRow(&d, 2, "Says hi.");
    // All three are code: they were all inside the fence, whatever the
    // blank line in the middle suggests.
    try testing.expect(d.rowIsCode(2));
}

test "a signature wider than the float breaks rather than vanishing" {
    const md =
        \\```go
        \\func WithTimeout(parent context.Context, d time.Duration) (context.Context, context.CancelFunc)
        \\```
    ;
    var d = layout(testing.allocator, md, 30);
    defer d.deinit(testing.allocator);
    try testing.expect(d.rowCount() > 1);
    try testing.expect(d.width <= 30);
    // Nothing is lost: the rows concatenate back to the signature.
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(testing.allocator);
    for (0..d.rowCount()) |i| {
        const t = try rowText(testing.allocator, &d, i);
        defer testing.allocator.free(t);
        try all.appendSlice(testing.allocator, t);
    }
    try testing.expectEqualStrings(
        "func WithTimeout(parent context.Context, d time.Duration) (context.Context, context.CancelFunc)",
        all.items,
    );
}

test "leading and trailing blank lines do not become empty rows" {
    var d = layout(testing.allocator, "\n\n\nhello\n\n\n", 40);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.rowCount());
    try expectRow(&d, 0, "hello");
}

test "several blank lines in a row collapse to one" {
    var d = layout(testing.allocator, "one\n\n\n\ntwo", 40);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), d.rowCount());
    try expectRow(&d, 1, "");
}

test "an unclosed fence still renders its contents" {
    // Servers truncate. The half a signature that arrived is the answer
    // the user gets to see.
    var d = layout(testing.allocator, "```go\nfunc Greet(", 40);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.rowCount());
    try expectRow(&d, 0, "func Greet(");
    try testing.expect(d.rowIsCode(0));
}

test "an empty hover lays out to nothing" {
    var d = layout(testing.allocator, "", 40);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), d.rowCount());

    var blanks = layout(testing.allocator, "\n\n \n", 40);
    defer blanks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), blanks.rowCount());
}

test "an escaped asterisk is a character, not markup" {
    var d = layout(testing.allocator, "matches \\*.go files", 40);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "matches *.go files");
}

test "unmatched markup survives as text" {
    // The rule the whole file is built on: an unhandled construct reads
    // as slightly literal prose, never as a missing paragraph.
    var d = layout(testing.allocator, "2 * 3 and a lone ` tick", 40);
    defer d.deinit(testing.allocator);
    try expectRow(&d, 0, "2 * 3 and a lone ` tick");
}

test "CJK doc text wraps by display width, not by byte count" {
    // Every character here is two cells wide. Eight of them fill a
    // twelve-wide float at six, not at twelve.
    var d = layout(testing.allocator, "名前を返します関数", 12);
    defer d.deinit(testing.allocator);
    try testing.expect(d.width <= 12);
    try testing.expect(d.rowCount() >= 2);
}

test "a runaway hover is truncated rather than allowed to grow" {
    const gpa = testing.allocator;
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(gpa);
    for (0..5000) |_| try big.appendSlice(gpa, "a line of documentation\n\n");
    var d = layout(gpa, big.items, 40);
    defer d.deinit(gpa);
    try testing.expect(d.rowCount() <= max_rows + 1);
}
