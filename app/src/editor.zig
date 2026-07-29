//! Editor — the vim-core modal editor over a rope Buffer (slice one of
//! the Monaco replacement; Seth's calls: vim-core first, rope day one,
//! tree-sitter next slice).
//!
//! Pure model: keys in, a styled character grid out (RCell). No
//! renderer imports — macos.zig maps styles to colors and glyphs, ctl
//! dumps the same grid as text, and `zig test src/editor.zig` drives
//! the whole machine headless. All calls happen under App.draw_lock.
//!
//! Vim scope v1: normal/insert/visual/visual-line/command modes;
//! h j k l w b e ge 0 ^ $ gg G % { } H M L arrows ctrl-d/u, zt zz zb,
//! / n N * #; operators d y c gu gU g~ (+ their doubled forms and
//! D C Y S); x X r R s J gJ ~ p P u ctrl-r, counts, `.`;
//! f F t T ; , >> << (and > < u U ~ J in visual), text objects
//! (iw aw iW aW, i" i' i` and the four bracket pairs), autoindent,
//! "a registers, ma marks, q@ macros; in insert, ctrl-w ctrl-u ctrl-t ctrl-d
//! ctrl-r ctrl-o; :w :q :q! :wq :x :e :<n>, :[range]s/pat/rep/[gi]
//! with % . $ N,M 'a '<,'> addresses.
//! Debts: marks do not shift when text above them is edited, case
//! operators are ASCII-only, no numbered registers, f/t target ASCII
//! only, wide glyphs count as one column, lines beyond max_line get
//! motion/render math clamped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufferpkg = @import("buffer.zig");

pub const tab_width = 4;
const max_line = 64 * 1024;
/// Path joining only — it must NOT ride max_line up.
const max_path = 4096;

pub const Style = enum(u8) {
    text,
    dim,
    sel,
    cursor,
    mode,
    status,
    err,
    // Syntax buckets (tree-sitter captures; see syntax.zig).
    syn_comment,
    syn_string,
    syn_number,
    syn_keyword,
    syn_type,
    syn_func,
};

/// One highlight span in absolute byte offsets; later spans override.
pub const HlSpan = struct { start: u32, end: u32, st: Style };

pub const RCell = struct {
    cp: u21 = ' ',
    st: Style = .text,
};

pub const Mode = enum { normal, insert, visual, visual_line, command };

/// One `R` keystroke: bytes put in, bytes displaced.
const RepEvent = struct { ins: u8, over: u8 };

pub const Editor = struct {
    gpa: Allocator,
    io: std.Io,
    buf: bufferpkg.Buffer,

    /// Viewport: first visible line, first visible render column.
    top: usize = 0,
    left: usize = 0,
    /// Cursor: line + BYTE offset within the line; goal render col
    /// preserved across j/k.
    cline: usize = 0,
    ccol: usize = 0,
    goal: usize = 0,

    mode: Mode = .normal,
    count: u32 = 0,
    op: u8 = 0, // pending operator: 'd','y','c' or 0
    pend_g: bool = false,
    pend_z: bool = false,
    pend_r: bool = false,

    vanchor_line: usize = 0,
    vanchor_col: usize = 0,
    /// The selection the last visual mode left behind — what `'<` and
    /// `'>` name in an ex range, and what `gv` puts back.
    vlast: ?struct { mode: Mode, a: Pos, b: Pos } = null,
    /// `>` or `<` waiting for its second key. Not routed through `op`,
    /// because `op` means "delete a range" everywhere it is read.
    pend_shift: u8 = 0,
    /// `i` or `a` waiting for the object to name (`ciw`, `da(`). Only
    /// armed when there is something for an object to apply TO — after
    /// an operator, or in visual mode — because `i` on its own is how
    /// you get into insert mode.
    pend_obj: u8 = 0,
    /// `f`/`F`/`t`/`T` waiting for the character to find, and what `;`
    /// and `,` should repeat.
    pend_find: u8 = 0,
    find_cmd: u8 = 0,
    find_char: u8 = 0,

    /// An indent this editor inserted that you have not committed to by
    /// typing after it. Stripped when you leave the line — vim's rule,
    /// and it is about diffs: pressing `o`, changing your mind and
    /// pressing ESC must not leave a line of trailing whitespace for
    /// someone to review.
    ai_line: ?usize = null,
    ai_len: usize = 0,

    /// `R` — insert mode that overwrites. The history is what each
    /// keystroke displaced, so backspace can put it back the way vim
    /// does; `ins` is what went in, `over` how much came out (0 = the
    /// key landed past the end of the line and there is nothing owed).
    /// Any cursor move drops it, because the offsets it holds are
    /// only meaningful for an unbroken run.
    replacing: bool = false,
    /// ctrl-r in insert mode is waiting for a register name.
    pend_ins_reg: bool = false,
    /// ctrl-o: one normal-mode command, then back to insert. Counts
    /// down because the step that ARMS it is already in normal mode
    /// and quiescent, and would otherwise return immediately.
    ins_oneshot: u8 = 0,
    rep_ev: std.ArrayListUnmanaged(RepEvent) = .empty,
    rep_text: std.ArrayListUnmanaged(u8) = .empty,

    /// `q` — the register being recorded into (0 = not recording), the
    /// keys so far, the last register `@` played, and how deep a macro
    /// is currently calling other macros.
    macro_reg: u8 = 0,
    macro_buf: std.ArrayListUnmanaged(u8) = .empty,
    macro_last: u8 = 0,
    macro_depth: u8 = 0,
    pend_macro: u8 = 0,

    /// `.` — the keys of the last change (`dot`), the keys of the one
    /// being typed now (`rec`), and the buffer version when it started.
    dot: std.ArrayListUnmanaged(u8) = .empty,
    rec: std.ArrayListUnmanaged(u8) = .empty,
    rec_on: bool = false,
    rec_ver: u64 = 0,
    dot_replay: bool = false,

    cmd: std.ArrayListUnmanaged(u8) = .empty,
    /// What the command line is collecting: an ex command (:) or a
    /// search pattern (/).
    cmd_kind: enum { ex, search } = .ex,
    /// The live pattern; non-empty = visible matches highlight
    /// (:noh clears).
    last_search: std.ArrayListUnmanaged(u8) = .empty,
    reg: std.ArrayListUnmanaged(u8) = .empty,
    reg_linewise: bool = false,
    /// `"a` — the 26 named registers, plus the letter a `"` is waiting
    /// for and the one the command after it should use (0 = unnamed).
    regs: [26]Named = @splat(.{}),
    pend_reg: bool = false,
    sel_reg: u8 = 0,

    /// `m` / `` ` `` / `'` waiting for their letter, the 26 marks, and
    /// where the last jump started (`` `` `` and `''`).
    pend_mark: u8 = 0,
    marks: [26]?Pos = @splat(null),
    jump: ?Pos = null,

    grid: std.ArrayListUnmanaged(RCell) = .empty,
    last_cols: usize = 80,
    last_rows: usize = 24,

    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    status_err: bool = false,

    scratch: [max_line]u8 = undefined,
    scratch2: [max_path]u8 = undefined,

    closed: bool = false,
    render_dirty: bool = true,
    /// Buffer is a directory LISTING (netrw/oil heritage): Enter opens
    /// the entry under the cursor, `-` climbs to the parent. No side
    /// panel — every pane can hold its own tree.
    is_dir: bool = false,

    /// A buffer with no file behind it — a rendered transcript today,
    /// host-projected docs later. `:w` refuses on it for the same reason
    /// it refuses on a directory listing: there is nowhere to write.
    /// The editor is otherwise itself, which is the point of projecting
    /// into a buffer rather than building a viewer.
    synthetic: bool = false,

    /// The file moved on disk and we could NOT take it, because the
    /// buffer has edits. Refreshed by the app's poll, so it clears
    /// itself once the two agree again (a `:w`, or the other writer
    /// putting it back). Purely a signal — nothing in the editor acts
    /// on it, because merging is the human's.
    disk_changed: bool = false,

    // Highlighter seam — function pointers so the editor never links
    // the tree-sitter C (headless tests stay headless). syntax.zig
    // attaches; null = plain text.
    hl_ctx: ?*anyopaque = null,
    hl_reparse: ?*const fn (*anyopaque, []const u8) void = null,
    hl_spans: ?*const fn (*anyopaque, u32, u32, *std.ArrayListUnmanaged(HlSpan), Allocator) void = null,
    hl_set_path: ?*const fn (*anyopaque, ?[]const u8) void = null,
    hl_destroy: ?*const fn (*anyopaque) void = null,
    hl_version: u64 = std.math.maxInt(u64),
    hl_spans_buf: std.ArrayListUnmanaged(HlSpan) = .empty,
    hl_styles: std.ArrayListUnmanaged(Style) = .empty,
    hl_vstart: usize = 0,

    // App-command seam, same shape and same reason as the highlighter's:
    // a `:` verb this editor does not own is offered to the app's command
    // registry (`:PaneSplitRight`), and the editor stays a pure model
    // that headless tests can drive with both hooks null.
    //
    // Returns true if the app claimed it. The hook must NOT act
    // synchronously — the editor's key path runs under the app's
    // draw_lock and every command target takes it again — so the app
    // side queues and drains after unlocking.
    cmd_ctx: ?*anyopaque = null,
    app_command: ?*const fn (*anyopaque, []const u8) bool = null,

    /// A buffer whose `:w` goes somewhere other than a file — a thread
    /// projected from the host. Same seam shape as the two above, and
    /// the same reason: the editor stays a pure model that knows about
    /// buffers, not about what is on the other end of one.
    ///
    /// Returns true if it handled the save. It runs synchronously on the
    /// key path, so the app side must not block on the network — it
    /// queues and reports through setStatus later.
    app_save: ?*const fn (*anyopaque, name: []const u8, content: []const u8) bool = null,

    pub fn create(gpa: Allocator, io: std.Io, path: ?[]const u8) !*Editor {
        const self = try gpa.create(Editor);
        errdefer gpa.destroy(self);
        var is_dir = false;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .buf = if (path) |p|
                try loadPath(gpa, io, p, &is_dir)
            else
                try bufferpkg.Buffer.initEmpty(gpa),
        };
        self.is_dir = is_dir;
        return self;
    }

    // ------------------------------------------------------- directory buffers

    // macOS dirent (arm64/APFS layout); opendir follows symlinks, which
    // is exactly the "is this a directory" probe we want.
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

    fn trimSlash(p: []const u8) []const u8 {
        if (p.len > 1 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
        return p;
    }

    /// Render `path` as listing text ("../" first, dirs before files,
    /// dirs slash-suffixed), or null if it isn't an openable directory.
    fn dirListing(gpa: Allocator, path: []const u8) !?[]u8 {
        var zbuf: [1024]u8 = undefined;
        if (path.len == 0 or path.len >= zbuf.len) return null;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const d = opendir(zbuf[0..path.len :0]) orelse return null;
        defer _ = closedir(d);

        const Ent = struct { name: []u8, dir: bool };
        var ents: std.ArrayListUnmanaged(Ent) = .empty;
        defer {
            for (ents.items) |e| gpa.free(e.name);
            ents.deinit(gpa);
        }
        while (readdir(d)) |de| {
            const name = de.d_name[0..de.d_namlen];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try ents.append(gpa, .{ .name = try gpa.dupe(u8, name), .dir = de.d_type == 4 });
        }
        const S = struct {
            fn lt(_: void, a: Ent, b: Ent) bool {
                if (a.dir != b.dir) return a.dir; // dirs first
                return std.mem.lessThan(u8, a.name, b.name);
            }
        };
        std.mem.sort(Ent, ents.items, {}, S.lt);

        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(gpa);
        try text.appendSlice(gpa, "../");
        for (ents.items) |e| {
            try text.append(gpa, '\n');
            try text.appendSlice(gpa, e.name);
            if (e.dir) try text.append(gpa, '/');
        }
        return try text.toOwnedSlice(gpa);
    }

    /// A path becomes a buffer: directory → listing, else file contents.
    fn loadPath(gpa: Allocator, io: std.Io, path: []const u8, is_dir: *bool) !bufferpkg.Buffer {
        if (try dirListing(gpa, path)) |text| {
            defer gpa.free(text);
            var b: bufferpkg.Buffer = .{ .rope = try .init(gpa, text) };
            errdefer b.rope.deinit(gpa);
            b.path = try gpa.dupe(u8, trimSlash(path));
            is_dir.* = true;
            return b;
        }
        is_dir.* = false;
        return bufferpkg.Buffer.initFromFile(gpa, io, path);
    }

    /// Enter on a listing line: descend into the entry (".." climbs).
    fn openDirEntry(self: *Editor) void {
        const base = self.buf.path orelse return;
        const line = std.mem.trimEnd(u8, self.lineText(self.cline), "/");
        if (line.len == 0) return;
        if (std.mem.eql(u8, line, "..")) return self.openParentDir();
        const joined = std.fmt.bufPrint(&self.scratch2, "{s}/{s}", .{ trimSlash(base), line }) catch return;
        self.open(joined, false) catch |err| {
            self.setStatus("open failed: {s}", .{@errorName(err)}, true);
        };
    }

    /// `-` from anywhere: the containing directory's listing, cursor on
    /// the entry we came from (vim-vinegar muscle memory).
    fn openParentDir(self: *Editor) void {
        const cur = self.buf.path orelse {
            self.setStatus("no file", .{}, true);
            return;
        };
        if (self.buf.isModified()) {
            self.setStatus("unsaved changes (:w first, or :e! to discard)", .{}, true);
            return;
        }
        const from_dir = self.is_dir;
        const parent = if (from_dir)
            std.fs.path.dirname(trimSlash(cur)) orelse "/"
        else
            std.fs.path.dirname(cur) orelse "/";
        var childbuf: [512]u8 = undefined;
        const cbase = std.fs.path.basename(trimSlash(cur));
        const cn = @min(cbase.len, childbuf.len);
        @memcpy(childbuf[0..cn], cbase[0..cn]);
        self.open(parent, false) catch |err| {
            self.setStatus("open failed: {s}", .{@errorName(err)}, true);
            return;
        };
        if (!self.is_dir) return;
        var i: usize = 0;
        const n = self.lineCountB();
        while (i < n) : (i += 1) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, self.lineText(i), "/"), childbuf[0..cn])) {
                self.cline = i;
                break;
            }
        }
    }

    pub fn destroy(self: *Editor) void {
        const gpa = self.gpa;
        if (self.hl_destroy) |f| f(self.hl_ctx.?);
        self.hl_spans_buf.deinit(gpa);
        self.hl_styles.deinit(gpa);
        self.buf.deinit(gpa);
        self.cmd.deinit(gpa);
        self.dot.deinit(gpa);
        self.macro_buf.deinit(gpa);
        self.rep_ev.deinit(gpa);
        self.rep_text.deinit(gpa);
        self.rec.deinit(gpa);
        self.last_search.deinit(gpa);
        self.reg.deinit(gpa);
        for (&self.regs) |*r| r.text.deinit(gpa);
        self.grid.deinit(gpa);
        gpa.destroy(self);
    }

    /// Tab-chip / status name: file basename or [scratch].
    pub fn displayName(self: *const Editor) []const u8 {
        const p = self.buf.path orelse return "[scratch]";
        return std.fs.path.basename(p);
    }

    // ------------------------------------------------------------ text access

    pub fn lineCountB(self: *const Editor) usize {
        return self.buf.rope.lineCount();
    }

    fn lineLenB(self: *const Editor, line: usize) usize {
        return self.buf.rope.lineEnd(line) - self.buf.rope.lineStart(line);
    }

    /// How far into `line` the editor will go: its real length, or the
    /// clamp, whichever is smaller.
    ///
    /// THE bug this file had. `ccol` is a byte offset into the real
    /// line, `lineText` hands back a TRUNCATED COPY of it, and every
    /// helper indexes the copy with the offset — so the moment a column
    /// went past the clamp, `prevCpStart` read off the end of the slice
    /// and the app aborted with your buffer in it. Two entry points
    /// reached it with one keystroke: `A` on a long line, and a
    /// backspace joining onto a long previous line, both of which
    /// assigned the REAL length.
    ///
    /// One definition, and every column that comes from a length goes
    /// through it.
    fn lineCap(self: *const Editor, line: usize) usize {
        return @min(self.lineLenB(line), max_line);
    }

    /// Is this line longer than the editor will let you work with?
    fn lineClamped(self: *const Editor, line: usize) bool {
        return self.lineLenB(line) > max_line;
    }

    /// Copy a line into scratch (clamped to max_line — the long-line debt).
    ///
    /// The returned slice is only valid until the NEXT call: it is one
    /// shared buffer. Every caller consumes it before asking for
    /// another line, and that is a contract, not an accident.
    fn lineText(self: *Editor, line: usize) []const u8 {
        const start = self.buf.rope.lineStart(line);
        const end = self.buf.rope.lineEnd(line);
        const n = @min(end - start, max_line);
        self.buf.rope.copyRange(start, start + n, self.scratch[0..n]);
        return self.scratch[0..n];
    }

    fn absOff(self: *const Editor) usize {
        return self.buf.rope.lineStart(self.cline) + self.ccol;
    }

    /// Bytes the codepoint at `i` occupies; 1 for anything undecodable.
    ///
    /// The single source of truth for how the editor ADVANCES through a
    /// line, so motions, render columns and the grid fill all step the
    /// same way. A sequence that runs off the end of the line counts as
    /// one byte too — otherwise the advance overshoots and the column
    /// arithmetic disagrees with what was drawn.
    fn cpLenAt(s: []const u8, i: usize) usize {
        if (i >= s.len) return 1;
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
        return if (i + n <= s.len) n else 1;
    }

    /// The codepoint at `i`, or U+FFFD.
    ///
    /// NOT `utf8Decode(s[i..i+1]) catch 0xFFFD`: given a ONE-BYTE slice
    /// `utf8Decode` returns that byte unchanged without validating it,
    /// so the catch never fires and 0xFF renders as `ÿ`. Every
    /// undecodable byte becomes one replacement character, which keeps
    /// a binary file rendering as garbage of the RIGHT WIDTH rather
    /// than resynchronising somewhere the cursor math cannot follow.
    fn decodeAt(s: []const u8, i: usize) u21 {
        const n = cpLenAt(s, i);
        if (n == 1 and s[i] >= 0x80) return 0xFFFD;
        return std.unicode.utf8Decode(s[i .. i + n]) catch 0xFFFD;
    }

    /// Start of the codepoint before byte `i`.
    ///
    /// TOTAL in `i` on purpose. This is the function that panicked: it
    /// was handed a column past the end of the slice and indexed
    /// straight into it. Clamping here does not excuse a caller from
    /// keeping the column inside the line — `lineCap` is for that — it
    /// means a caller that gets it wrong renders a wrong cursor instead
    /// of killing the app with your buffer in it.
    fn prevCpStart(s: []const u8, i: usize) usize {
        var j = @min(i, s.len);
        if (j == 0) return 0;
        j -= 1;
        while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
        return j;
    }

    /// Byte col of the LAST codepoint (normal mode's right edge); 0 for
    /// an empty line.
    fn lastCpCol(s: []const u8) usize {
        if (s.len == 0) return 0;
        return prevCpStart(s, s.len);
    }

    fn renderCol(s: []const u8, bcol: usize) usize {
        var rc: usize = 0;
        var i: usize = 0;
        while (i < bcol and i < s.len) {
            if (s[i] == '\t') rc = rc / tab_width * tab_width + tab_width else rc += 1;
            i += cpLenAt(s, i);
        }
        return rc;
    }

    fn bcolForRenderCol(s: []const u8, target: usize) usize {
        var rc: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const next_rc = if (s[i] == '\t') rc / tab_width * tab_width + tab_width else rc + 1;
            if (next_rc > target) return i;
            rc = next_rc;
            i += cpLenAt(s, i);
        }
        return i;
    }

    /// Column of the first non-blank, or 0 if the line has none — the
    /// `^` motion, where landing on column 0 of a blank line is right.
    fn firstNonblank(s: []const u8) usize {
        for (s, 0..) |c, i| if (c != ' ' and c != '\t') return i;
        return 0;
    }

    /// Bytes of leading whitespace. Differs from `firstNonblank` on a
    /// line that is ALL whitespace: that line's indent is the whole
    /// line, and a new line below it should inherit it.
    fn indentLen(s: []const u8) usize {
        for (s, 0..) |c, i| if (c != ' ' and c != '\t') return i;
        return s.len;
    }

    /// Display width of leading whitespace, tabs snapping to the stop.
    fn indentWidth(s: []const u8) usize {
        var w: usize = 0;
        for (s[0..indentLen(s)]) |c| {
            if (c == '\t') w = w / tab_width * tab_width + tab_width else w += 1;
        }
        return w;
    }

    /// Deeper than this is not an indent, it is content.
    const max_indent = 256;

    /// Leading whitespace of `line`, copied OUT of the shared scratch —
    /// every caller inserts it somewhere, and the insert may want
    /// `lineText` again.
    fn indentOf(self: *Editor, line: usize, out: *[max_indent]u8) []const u8 {
        const s = self.lineText(line);
        const n = @min(indentLen(s), max_indent);
        @memcpy(out[0..n], s[0..n]);
        return out[0..n];
    }

    /// Tabs or spaces? The FILE decides.
    ///
    /// rook's own tree has Zig (spaces) and Go (tabs) side by side, so
    /// a setting would be wrong in one of them no matter which way it
    /// pointed. Whatever the buffer already indents with is the answer,
    /// and a buffer with no indented lines yet gets spaces.
    ///
    /// The budget is INDENTED lines seen, not lines read: a Go file can
    /// open with a licence header and an import block, and a flat count
    /// of the first N lines would find no tabs in any of it.
    fn indentUnit(self: *const Editor) []const u8 {
        var tabs: usize = 0;
        var spaces: usize = 0;
        const scan = @min(self.lineCountB(), 2000);
        for (0..scan) |l| {
            if (tabs + spaces >= 200) break;
            const start = self.buf.rope.lineStart(l);
            if (self.buf.rope.lineEnd(l) == start) continue;
            var one: [1]u8 = undefined;
            self.buf.rope.copyRange(start, start + 1, &one);
            if (one[0] == '\t') tabs += 1 else if (one[0] == ' ') spaces += 1;
        }
        return if (tabs > spaces) "\t" else " " ** tab_width;
    }

    /// Whitespace spelling `width` columns in `unit`'s currency.
    fn makeIndent(width: usize, unit: []const u8, out: *[max_indent]u8) []const u8 {
        var n: usize = 0;
        if (unit.len == 1 and unit[0] == '\t') {
            while (n < width / tab_width and n < max_indent) : (n += 1) out[n] = '\t';
            var rem = width % tab_width;
            while (rem > 0 and n < max_indent) : (rem -= 1) {
                out[n] = ' ';
                n += 1;
            }
        } else {
            while (n < width and n < max_indent) : (n += 1) out[n] = ' ';
        }
        return out[0..n];
    }

    fn clampNormal(self: *Editor) void {
        // Mid ctrl-o the cursor still belongs to insert mode, which is
        // allowed to sit one past the last character. That is the only
        // reason `<C-o>$` appends instead of overwriting.
        if (self.ins_oneshot > 0) return;
        const s = self.lineText(self.cline);
        const maxc = lastCpCol(s);
        if (self.ccol > maxc) self.ccol = maxc;
    }

    pub fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype, is_err: bool) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.status_len = s.len;
        self.status_err = is_err;
    }

    // ------------------------------------------------------------ input

    /// Input is a STREAM, not a keystroke: NSEvents deliver one char,
    /// but ctl `type` (and someday paste) deliver whole strings — the
    /// machine consumes greedily either way.
    pub fn key(self: *Editor, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.render_dirty = true;
        self.status_len = 0;

        var i: usize = 0;
        while (i < bytes.len) {
            const pre_mode = self.mode;
            const pre_ver = self.buf.version;
            const pre_reg = self.sel_reg;
            // Recording is suppressed inside a replay: a macro that
            // runs another one records the `@b`, not what b expands to.
            const taping = self.macro_reg != 0 and self.macro_depth == 0;
            const n = self.dispatch(bytes[i..]);
            // Still recording AFTER the step, so the `q` that stops it
            // is not the last thing the macro does.
            if (taping and self.macro_reg != 0 and self.macro_buf.items.len < 64 * 1024) {
                self.macro_buf.appendSlice(self.gpa, bytes[i..][0..n]) catch {};
            }
            // A `"a` selection survives exactly ONE command. It was set
            // by the step before this one, so if this step finished
            // without taking it, it is gone — otherwise `"a` followed
            // by a stray `j` would leave the next `x` writing into a.
            if (self.sel_reg != 0 and self.sel_reg == pre_reg and self.quiescent()) self.sel_reg = 0;
            if (self.ins_oneshot > 0) {
                if (self.ins_oneshot == 2) {
                    self.ins_oneshot = 1;
                } else if (self.mode == .insert) {
                    self.ins_oneshot = 0; // the command opened its own insert
                } else if (self.mode == .normal and self.quiescent()) {
                    self.ins_oneshot = 0;
                    self.mode = .insert;
                }
            }
            self.recordStep(bytes[i..][0..n], pre_mode, pre_ver);
            i += n;
        }
    }

    /// One key's worth of input; returns the bytes it consumed.
    fn dispatch(self: *Editor, bytes: []const u8) usize {
        // Whole CSI arrow sequences (from the event monitor).
        if (bytes[0] == 0x1b and bytes.len > 2 and bytes[1] == '[') {
            const m: ?u8 = switch (bytes[2]) {
                'A' => 'k',
                'B' => 'j',
                'C' => 'l',
                'D' => 'h',
                else => null,
            };
            if (m) |mm| {
                switch (self.mode) {
                    .command => {},
                    .insert => self.insertArrow(mm),
                    else => self.normalKey(mm),
                }
                return 3;
            }
        }

        switch (self.mode) {
            .command, .insert => {
                // Consume a printable run at once (multi-byte UTF-8
                // included); control bytes go one at a time.
                var end: usize = 0;
                while (end < bytes.len and (bytes[end] == '\t' or bytes[end] >= 0x20)) end += 1;
                if (end == 0) end = 1;
                const run = bytes[0..end];
                if (self.mode == .insert) self.insertKey(run) else self.commandKey(run);
                return end;
            },
            else => {
                // Normal/visual commands are single ASCII keys;
                // skip over any multi-byte codepoint whole. A
                // pending `f` dies with it rather than staying
                // armed to swallow whatever you press next —
                // f/t target ASCII today, and a key that vanishes
                // is better than a key that lands somewhere else.
                const n = cpLenAt(bytes, 0);
                if (n == 1) self.normalKey(bytes[0]) else self.pend_find = 0;
                return n;
            },
        }
    }

    /// True when nothing is half-typed — the moment a command is over.
    fn quiescent(self: *const Editor) bool {
        return self.mode == .normal and self.op == 0 and self.count == 0 and
            !self.pend_g and !self.pend_z and !self.pend_r and self.pend_shift == 0 and
            self.pend_obj == 0 and self.pend_find == 0 and !self.pend_reg and
            self.pend_mark == 0 and self.pend_macro == 0;
    }

    /// Remember the keys of the last change, so `.` can type them again.
    ///
    /// Recorded by RESULT, not by key table: keys accumulate while a
    /// command is in flight and are kept only if the buffer actually
    /// moved. `w` and `yy` leave no dot; `x`, `cwfoo<esc>` and `vjd`
    /// leave one — and no list of "which keys are changes" has to be
    /// maintained here, which is the list that always goes stale.
    fn recordStep(self: *Editor, k: []const u8, pre_mode: Mode, pre_ver: u64) void {
        if (self.dot_replay or k.len == 0) return;
        if (!self.rec_on) {
            // A command starts in normal or visual mode. `u`, ctrl-r
            // and `.` move the buffer without being changes of their
            // own — repeating an undo is not what anybody means.
            if (pre_mode == .insert or pre_mode == .command) return;
            if (k.len == 1 and (k[0] == 'u' or k[0] == 0x12 or k[0] == '.')) return;
            self.rec_on = true;
            self.rec_ver = pre_ver;
            self.rec.clearRetainingCapacity();
        }
        // A recording longer than this is a paste or a wedged state,
        // not a keystroke someone will want back.
        if (self.rec.items.len + k.len > 64 * 1024) {
            self.rec_on = false;
            return;
        }
        self.rec.appendSlice(self.gpa, k) catch {
            self.rec_on = false;
            return;
        };
        if (!self.quiescent()) return;
        self.rec_on = false;
        if (self.buf.version == self.rec_ver) return;
        self.dot.clearRetainingCapacity();
        self.dot.appendSlice(self.gpa, self.rec.items) catch {};
    }

    // -------------------------------------------------------------- macros

    /// Macros live in the SAME registers as yanks, which is vim's
    /// arrangement and a good one: `"ap` prints the macro you just
    /// recorded, and `"ay$` on a line of keystrokes loads one.
    fn startMacro(self: *Editor, name: u8) void {
        const lo = std.ascii.toLower(name);
        if (lo < 'a' or lo > 'z') return;
        self.macro_reg = name;
        self.macro_buf.clearRetainingCapacity();
    }

    fn stopMacro(self: *Editor) void {
        const name = self.macro_reg;
        self.macro_reg = 0;
        const lo = std.ascii.toLower(name);
        if (lo < 'a' or lo > 'z') return;
        const n = &self.regs[lo - 'a'];
        if (!std.ascii.isUpper(name)) n.text.clearRetainingCapacity();
        n.text.appendSlice(self.gpa, self.macro_buf.items) catch {};
        n.linewise = false;
        self.macro_buf.clearRetainingCapacity();
    }

    /// `@a`, `@@`, and `10@a`. The depth cap is the only thing standing
    /// between a macro that plays itself and the stack.
    fn playMacro(self: *Editor, name0: u8) void {
        const cnt = self.takeCount();
        const name = if (name0 == '@') self.macro_last else name0;
        const lo = std.ascii.toLower(name);
        if (lo < 'a' or lo > 'z') {
            self.setStatus("no macro to repeat", .{}, true);
            return;
        }
        self.macro_last = lo;
        if (self.macro_depth >= 16) {
            self.setStatus("macro nested too deep", .{}, true);
            return;
        }
        // Played off a copy: the macro is free to yank into its own
        // register while it runs.
        const body = self.gpa.dupe(u8, self.regs[lo - 'a'].text.items) catch return;
        defer self.gpa.free(body);
        if (body.len == 0) return;
        self.macro_depth += 1;
        defer self.macro_depth -= 1;
        for (0..cnt) |_| self.key(body);
    }

    /// Type the last change again. A count on `.` REPLACES the recorded
    /// one (`3dd` then `5.` deletes five lines, not three) — vim's rule,
    /// and the only reason the leading digits are split off here.
    fn dotRepeat(self: *Editor) void {
        const cnt = self.count;
        self.count = 0;
        if (self.dot_replay or self.dot.items.len == 0) return;

        var rest: []const u8 = self.dot.items;
        if (cnt > 0) while (rest.len > 0 and rest[0] >= '1' and rest[0] <= '9') {
            var j: usize = 1;
            while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
            rest = rest[j..];
        };

        var head: [24]u8 = undefined;
        var play: std.ArrayListUnmanaged(u8) = .empty;
        defer play.deinit(self.gpa);
        if (cnt > 0) {
            const d = std.fmt.bufPrint(&head, "{d}", .{cnt}) catch "";
            play.appendSlice(self.gpa, d) catch return;
        }
        play.appendSlice(self.gpa, rest) catch return;

        // Replayed off a copy: `key` re-enters this file and must not
        // be walking a slice of a list something else could grow.
        self.dot_replay = true;
        defer self.dot_replay = false;
        self.key(play.items);
    }

    fn insertArrow(self: *Editor, m: u8) void {
        if ((m == 'j' or m == 'k') and self.ai_line != null) self.dropPendingIndent();
        self.dropReplaceHistory();
        const s = self.lineText(self.cline);
        switch (m) {
            'h' => {
                if (self.ccol > 0) self.ccol = prevCpStart(s, self.ccol);
            },
            'l' => {
                if (self.ccol < s.len) self.ccol += cpLenAt(s, self.ccol);
            },
            'j' => {
                if (self.cline + 1 < self.lineCountB()) {
                    self.cline += 1;
                    const s2 = self.lineText(self.cline);
                    if (self.ccol > s2.len) self.ccol = s2.len;
                }
            },
            'k' => {
                if (self.cline > 0) {
                    self.cline -= 1;
                    const s2 = self.lineText(self.cline);
                    if (self.ccol > s2.len) self.ccol = s2.len;
                }
            },
            else => {},
        }
    }

    // ------------------------------------------------------------ insert mode

    fn insertKey(self: *Editor, bytes: []const u8) void {
        const gpa = self.gpa;
        const b0 = bytes[0];

        // ctrl-r took the next key as a register name.
        if (self.pend_ins_reg) {
            self.pend_ins_reg = false;
            if (b0 >= 0x20) self.insertRegister(b0);
            if (bytes.len > 1) self.insertKey(bytes[1..]);
            return;
        }
        switch (b0) {
            0x17 => { // ctrl-w — the word behind the cursor
                self.ai_line = null;
                self.dropReplaceHistory();
                if (self.ccol == 0) {
                    self.joinBack();
                    return;
                }
                const p = self.scanWordBack(self.cline, self.ccol);
                const from = if (p.line == self.cline) p.col else 0;
                const start = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, start + from, start + self.ccol) catch return;
                self.ccol = from;
                return;
            },
            0x15 => { // ctrl-u — everything before the cursor on this line
                self.ai_line = null;
                self.dropReplaceHistory();
                if (self.ccol == 0) return;
                const start = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, start, start + self.ccol) catch return;
                self.ccol = 0;
                return;
            },
            0x14 => { // ctrl-t / ctrl-d — indent this line while typing
                self.insertShift(true);
                return;
            },
            0x04 => {
                self.insertShift(false);
                return;
            },
            0x12 => { // ctrl-r — paste a register inline
                self.pend_ins_reg = true;
                return;
            },
            0x0f => { // ctrl-o — one normal command, then back
                self.ins_oneshot = 2;
                self.mode = .normal;
                return;
            },
            else => {},
        }
        if (b0 == 0x1b) { // ESC → normal, cursor left one cp
            self.dropPendingIndent();
            self.endReplace();
            self.mode = .normal;
            if (self.ccol > 0) {
                const s = self.lineText(self.cline);
                self.ccol = prevCpStart(s, self.ccol);
            }
            self.goal = renderCol(self.lineText(self.cline), self.ccol);
            return;
        }
        if (b0 == '\r' or b0 == '\n') {
            // The indent is read BEFORE the split and before the strip:
            // holding Enter on a fresh `o` should keep giving you the
            // indent while leaving no whitespace behind on the lines
            // you skipped past.
            var ibuf: [max_indent]u8 = undefined;
            const ind = self.indentOf(self.cline, &ibuf);
            self.dropPendingIndent();
            self.dropReplaceHistory();
            self.buf.insert(gpa, self.absOff(), "\n") catch return;
            self.cline += 1;
            self.ccol = 0;
            self.insertIndent(ind);
            return;
        }
        if (b0 == 0x7f or b0 == 0x08) { // backspace
            // Backspacing INTO an auto-indent is a deliberate edit of
            // it; the editor stops claiming those bytes.
            self.ai_line = null;
            if (self.replacing) {
                // Replace mode owes the line its old characters back —
                // and once that debt is paid, backspace only MOVES.
                // It never deletes text this R never touched.
                const ev = self.rep_ev.pop() orelse {
                    if (self.ccol > 0) {
                        const s = self.lineText(self.cline);
                        self.ccol = prevCpStart(s, self.ccol);
                    }
                    return;
                };
                const start = self.absOff() - ev.ins;
                self.buf.deleteRange(gpa, start, start + ev.ins) catch return;
                if (ev.over > 0) {
                    const keep = self.rep_text.items.len - ev.over;
                    self.buf.insert(gpa, start, self.rep_text.items[keep..]) catch return;
                    self.rep_text.shrinkRetainingCapacity(keep);
                }
                self.ccol = start - self.buf.rope.lineStart(self.cline);
                return;
            }
            if (self.ccol > 0) {
                const s = self.lineText(self.cline);
                const p = prevCpStart(s, self.ccol);
                const start = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, start + p, start + self.ccol) catch return;
                self.ccol = p;
            } else {
                self.joinBack();
            }
            return;
        }
        if (b0 == '\t' or b0 >= 0x20) {
            // Printable run (possibly multi-byte UTF-8); drop other
            // control bytes.
            //
            // REFUSED at the clamp, rather than inserted with the
            // cursor pinned. The cursor cannot represent a column past
            // max_line, so carrying on would drop every further
            // keystroke into the same spot in the MIDDLE of a line you
            // cannot see — silent corruption dressed as a stuck cursor.
            if (self.ccol >= max_line) {
                self.setStatus("line too long to edit past {d} bytes", .{max_line}, true);
                return;
            }
            if (self.replacing) {
                self.replaceRun(bytes);
                return;
            }
            self.buf.insert(gpa, self.absOff(), bytes) catch return;
            self.ccol += bytes.len;
            self.ai_line = null; // typed on it — it is yours now
        }
    }

    /// Backspace (and ctrl-w) in column zero: take the newline above.
    fn joinBack(self: *Editor) void {
        if (self.cline == 0) return;
        const prev_len = self.lineCap(self.cline - 1);
        const nl = self.buf.rope.lineStart(self.cline) - 1;
        self.buf.deleteRange(self.gpa, nl, nl + 1) catch return;
        self.cline -= 1;
        self.ccol = prev_len;
    }

    /// ctrl-r in insert mode. The register can hold newlines, so the
    /// cursor is put back by OFFSET rather than by counting columns.
    fn insertRegister(self: *Editor, name: u8) void {
        var body: []const u8 = self.reg.items;
        if (name != '"') {
            const lo = std.ascii.toLower(name);
            if (lo < 'a' or lo > 'z') return;
            body = self.regs[lo - 'a'].text.items;
        }
        if (body.len == 0) return;
        const at = self.absOff();
        self.buf.insert(self.gpa, at, body) catch return;
        const end = at + body.len;
        self.cline = self.buf.rope.lineOfOffset(end);
        self.ccol = end - self.buf.rope.lineStart(self.cline);
        self.ai_line = null;
        self.dropReplaceHistory();
    }

    /// ctrl-t / ctrl-d — shift this line without moving the cursor off
    /// the text it was sitting on. `shiftLines` parks at the first
    /// non-blank, which is right in normal mode and wrong while you
    /// are typing.
    fn insertShift(self: *Editor, right: bool) void {
        const gpa = self.gpa;
        self.dropReplaceHistory();
        const s = self.lineText(self.cline);
        const before = indentLen(s);
        const tail = self.ccol -| before;
        if (before == s.len) {
            // shiftLines leaves whitespace-only lines alone, for the
            // sake of diffs. On the line you are TYPING on, indenting
            // it is the entire point.
            const target = if (right) indentWidth(s) + tab_width else indentWidth(s) -| tab_width;
            var ibuf: [max_indent]u8 = undefined;
            const ind = makeIndent(target, self.indentUnit(), &ibuf);
            const start = self.buf.rope.lineStart(self.cline);
            self.buf.newUndoGroup();
            if (s.len > 0) self.buf.deleteRange(gpa, start, start + s.len) catch return;
            if (ind.len > 0) self.buf.insert(gpa, start, ind) catch return;
            self.ccol = ind.len;
            self.ai_line = null;
            return;
        }
        self.shiftLines(self.cline, self.cline, right);
        self.ccol = @min(indentLen(self.lineText(self.cline)) + tail, self.lineCap(self.cline));
        self.ai_line = null;
    }

    /// One codepoint in, one codepoint out — and what came out is kept
    /// so backspace can put it back. Past the end of the line there is
    /// nothing to displace and `R` is just insert, which is also what
    /// vim does.
    fn replaceRun(self: *Editor, bytes: []const u8) void {
        const gpa = self.gpa;
        var i: usize = 0;
        while (i < bytes.len) {
            const n = cpLenAt(bytes, i);
            const s = self.lineText(self.cline);
            const over = if (self.ccol < s.len) cpLenAt(s, self.ccol) else 0;
            const at = self.absOff();
            if (over > 0) {
                self.rep_text.appendSlice(gpa, s[self.ccol..][0..over]) catch return;
                self.buf.deleteRange(gpa, at, at + over) catch return;
            }
            self.buf.insert(gpa, at, bytes[i..][0..n]) catch return;
            self.rep_ev.append(gpa, .{ .ins = @intCast(n), .over = @intCast(over) }) catch {};
            self.ccol += n;
            i += n;
        }
        self.ai_line = null;
    }

    /// Any cursor move invalidates the history: backspace walks
    /// backward from where the run left off, and nothing it holds is
    /// true after a jump.
    fn dropReplaceHistory(self: *Editor) void {
        self.rep_ev.clearRetainingCapacity();
        self.rep_text.clearRetainingCapacity();
    }

    fn endReplace(self: *Editor) void {
        self.replacing = false;
        self.dropReplaceHistory();
    }

    /// Put a fresh line's inherited indent in, and arm the take-back.
    fn insertIndent(self: *Editor, ind: []const u8) void {
        if (ind.len == 0) {
            self.armPendingIndent(self.cline, 0);
            return;
        }
        self.buf.insert(self.gpa, self.absOff(), ind) catch return;
        self.ccol = ind.len;
        self.armPendingIndent(self.cline, ind.len);
    }

    // ------------------------------------------------------------ command mode

    fn commandKey(self: *Editor, bytes: []const u8) void {
        const b0 = bytes[0];
        if (b0 == 0x1b) {
            self.cmd.clearRetainingCapacity();
            self.mode = .normal;
            return;
        }
        if (b0 == '\r' or b0 == '\n') {
            self.mode = .normal;
            switch (self.cmd_kind) {
                .ex => self.execCommand(),
                .search => {
                    self.last_search.clearRetainingCapacity();
                    self.last_search.appendSlice(self.gpa, self.cmd.items) catch {};
                    self.searchNext(true);
                },
            }
            self.cmd.clearRetainingCapacity();
            return;
        }
        if (b0 == 0x7f or b0 == 0x08) {
            if (self.cmd.items.len > 0) {
                _ = self.cmd.pop();
            } else self.mode = .normal;
            return;
        }
        if (b0 >= 0x20) self.cmd.appendSlice(self.gpa, bytes) catch {};
    }

    const LineSpan = struct { a: usize, b: usize };

    /// One ex address: `.`, `$`, a number, or a mark — including the
    /// `'<` / `'>` a visual selection leaves behind.
    fn parseLineAddr(self: *Editor, s: []const u8, i: *usize) ?usize {
        const last = self.lineCountB() - 1;
        if (i.* >= s.len) return null;
        switch (s[i.*]) {
            '.' => {
                i.* += 1;
                return self.cline;
            },
            '$' => {
                i.* += 1;
                return last;
            },
            '\'' => {
                if (i.* + 1 >= s.len) return null;
                const name = s[i.* + 1];
                i.* += 2;
                const v = self.vlast orelse {
                    const p = self.markPos(name) orelse return null;
                    return @min(p.line, last);
                };
                if (name == '<') return @min(@min(v.a.line, v.b.line), last);
                if (name == '>') return @min(@max(v.a.line, v.b.line), last);
                const p = self.markPos(name) orelse return null;
                return @min(p.line, last);
            },
            '0'...'9' => {
                var n: usize = 0;
                while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
                    n = n *| 10 +| (s[i.*] - '0');
                }
                return @min(n -| 1, last);
            },
            else => return null,
        }
    }

    /// A leading ex range. Returns the bytes consumed — zero means the
    /// command had none and the caller's default stands.
    fn parseRange(self: *Editor, s: []const u8, span: *LineSpan) usize {
        if (s.len > 0 and s[0] == '%') {
            span.* = .{ .a = 0, .b = self.lineCountB() - 1 };
            return 1;
        }
        var i: usize = 0;
        const first = self.parseLineAddr(s, &i) orelse return 0;
        var a = first;
        var b = first;
        if (i < s.len and s[i] == ',') {
            const save = i;
            i += 1;
            if (self.parseLineAddr(s, &i)) |second| {
                b = second;
            } else {
                i = save;
            }
        }
        if (a > b) std.mem.swap(usize, &a, &b);
        span.* = .{ .a = a, .b = b };
        return i;
    }

    fn indexOfCase(hay: []const u8, from: usize, needle: []const u8, icase: bool) ?usize {
        if (needle.len == 0 or from > hay.len or hay.len < needle.len) return null;
        if (!icase) return std.mem.indexOfPos(u8, hay, from, needle);
        var i = from;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return i;
        }
        return null;
    }

    /// Copy one `/`-delimited field out, dropping the backslash from an
    /// escaped separator. Everything else is literal — see exSubstitute.
    fn unescapeField(src: []const u8, sep: u8, out: []u8) []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < src.len and n < out.len) : (i += 1) {
            if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == sep) i += 1;
            out[n] = src[i];
            n += 1;
        }
        return out[0..n];
    }

    /// The end of the current field: the next separator that is not
    /// backslash-escaped.
    fn fieldEnd(s: []const u8, sep: u8) usize {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\') {
                i += 1;
                continue;
            }
            if (s[i] == sep) return i;
        }
        return s.len;
    }

    fn subLine(self: *Editor, line: usize, pat: []const u8, rep: []const u8, all: bool, icase: bool) usize {
        const gpa = self.gpa;
        var done: usize = 0;
        var from: usize = 0;
        while (true) {
            // Re-read the line every pass: the previous replacement
            // moved everything after it, and lineText hands back a copy
            // that goes stale the moment the rope changes.
            const s = self.lineText(line);
            const idx = indexOfCase(s, from, pat, icase) orelse break;
            const start = self.buf.rope.lineStart(line);
            self.buf.deleteRange(gpa, start + idx, start + idx + pat.len) catch break;
            if (rep.len > 0) self.buf.insert(gpa, start + idx, rep) catch break;
            done += 1;
            if (!all) break;
            // Past the text just written, so `:s/a/aa/g` terminates.
            from = idx + rep.len;
        }
        return done;
    }

    /// `:[range]s/pat/rep/[flags]`.
    ///
    /// The pattern is LITERAL, not a regex — the same engine `/` uses,
    /// and saying so is better than half a regex that surprises you on
    /// a `.`. Any character can be the separator, `\` escapes it, and
    /// the flags are `g` (every match on the line) and `i` (ignore
    /// case). No `c`: a confirm prompt needs a modal the editor does
    /// not have yet.
    fn exSubstitute(self: *Editor, span: LineSpan, spec: []const u8) void {
        if (spec.len == 0 or std.ascii.isAlphanumeric(spec[0])) {
            self.setStatus("usage: :[range]s/pattern/replacement/[gi]", .{}, true);
            return;
        }
        const sep = spec[0];
        const body = spec[1..];

        const pat_end = fieldEnd(body, sep);
        var pbuf: [512]u8 = undefined;
        const pat = unescapeField(body[0..pat_end], sep, &pbuf);
        if (pat.len == 0) {
            self.setStatus("nothing to substitute", .{}, true);
            return;
        }

        var rbuf: [512]u8 = undefined;
        var rep: []const u8 = "";
        var flags: []const u8 = "";
        if (pat_end < body.len) {
            const after = body[pat_end + 1 ..];
            const rep_end = fieldEnd(after, sep);
            rep = unescapeField(after[0..rep_end], sep, &rbuf);
            if (rep_end < after.len) flags = after[rep_end + 1 ..];
        }
        const all = std.mem.indexOfScalar(u8, flags, 'g') != null;
        const icase = std.mem.indexOfScalar(u8, flags, 'i') != null;

        // The pattern becomes the search pattern, so `n` walks the rest
        // of them and the matches stay highlighted — vim's behaviour,
        // and the reason a substitute is a good way to FIND things.
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, pat) catch {};

        self.buf.newUndoGroup();
        var hits: usize = 0;
        var lines: usize = 0;
        var last_hit: usize = self.cline;
        var line = span.a;
        while (line <= span.b and line < self.lineCountB()) : (line += 1) {
            const n = self.subLine(line, pat, rep, all, icase);
            if (n == 0) continue;
            hits += n;
            lines += 1;
            last_hit = line;
        }
        if (hits == 0) {
            self.setStatus("pattern not found: {s}", .{pat[0..@min(pat.len, 48)]}, true);
            return;
        }
        self.cline = @min(last_hit, self.lineCountB() - 1);
        self.ccol = firstNonblank(self.lineText(self.cline));
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
        self.setStatus("{d} substitution{s} on {d} line{s}", .{
            hits,
            if (hits == 1) "" else "s",
            lines,
            if (lines == 1) "" else "s",
        }, false);
    }

    fn execCommand(self: *Editor) void {
        const gpa = self.gpa;
        const line = std.mem.trim(u8, self.cmd.items, " ");
        if (line.len == 0) return;

        // :<n> — goto line.
        if (std.fmt.parseInt(usize, line, 10) catch null) |n| {
            self.cline = @min(n -| 1, self.lineCountB() - 1);
            self.ccol = firstNonblank(self.lineText(self.cline));
            return;
        }

        // A leading range belongs to whoever takes one. Today that is
        // `:s` and a bare address.
        var span: LineSpan = .{ .a = self.cline, .b = self.cline };
        const used = self.parseRange(line, &span);
        const ranged = std.mem.trim(u8, line[used..], " ");
        if (ranged.len > 0 and ranged[0] == 's' and
            (ranged.len == 1 or !std.ascii.isAlphanumeric(ranged[1])))
        {
            self.exSubstitute(span, ranged[1..]);
            return;
        }
        if (used > 0 and ranged.len == 0) {
            self.cline = @min(span.b, self.lineCountB() - 1);
            self.ccol = firstNonblank(self.lineText(self.cline));
            return;
        }

        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const verb = if (sp) |i| line[0..i] else line;
        const arg = std.mem.trim(u8, if (sp) |i| line[i + 1 ..] else "", " ");

        const is = std.mem.eql;
        // `!` on a write means "I know, do it anyway" — the answer to
        // the clobber guard below. Stripped here so one branch handles
        // both forms of each verb.
        const bang = verb.len > 1 and verb[verb.len - 1] == '!';
        const wverb = if (bang) verb[0 .. verb.len - 1] else verb;
        if (is(u8, wverb, "w") or is(u8, wverb, "wq") or is(u8, wverb, "x")) {
            if (self.is_dir) {
                self.setStatus("a directory listing isn't writable", .{}, true);
                return;
            }
            if (self.synthetic) {
                // A projected buffer may still be SAVEABLE — it just does
                // not save to a file. Offer it to the app before refusing.
                if (self.app_save) |save| {
                    if (self.cmd_ctx) |ctx| {
                        const text = self.buf.rope.dupeRange(gpa, 0, self.buf.rope.byteLen()) catch {
                            self.setStatus("out of memory", .{}, true);
                            return;
                        };
                        defer gpa.free(text);
                        if (save(ctx, self.buf.path orelse "", text)) {
                            self.buf.markSaved();
                            if (!is(u8, wverb, "w")) self.closed = true;
                            return;
                        }
                    }
                }
                self.setStatus("{s} has no file behind it", .{self.displayName()}, true);
                return;
            }
            if (arg.len > 0) {
                const p = gpa.dupe(u8, arg) catch return;
                if (self.buf.path) |old| gpa.free(old);
                self.buf.path = p;
                // `:w other` is a new target, so we hold no claim on it —
                // and a claim inherited from the OLD file would refuse
                // the write for a reason that makes no sense.
                self.buf.disk = null;
            }
            self.buf.save(gpa, self.io, bang) catch |err| {
                if (err == error.ChangedOnDisk) {
                    // Naming both ways out matters: one of them keeps
                    // your edit and one of them keeps theirs, and which
                    // you want is not something the editor can know.
                    self.setStatus("changed on disk since you opened it (:w! overwrites, :e! reloads)", .{}, true);
                } else self.setStatus("write failed: {s}", .{@errorName(err)}, true);
                return;
            };
            self.setStatus("wrote {s}", .{self.displayName()}, false);
            if (!is(u8, wverb, "w")) self.closed = true;
        } else if (is(u8, verb, "q")) {
            if (self.buf.isModified()) {
                self.setStatus("unsaved changes (:q! to discard)", .{}, true);
            } else self.closed = true;
        } else if (is(u8, verb, "q!")) {
            self.closed = true;
        } else if (is(u8, verb, "noh") or is(u8, verb, "nohlsearch")) {
            self.last_search.clearRetainingCapacity();
        } else if (is(u8, verb, "e") or is(u8, verb, "e!")) {
            if (arg.len == 0) {
                self.setStatus("e needs a path", .{}, true);
                return;
            }
            self.open(arg, is(u8, verb, "e!")) catch |err| {
                self.setStatus("open failed: {s}", .{@errorName(err)}, true);
            };
        } else if (self.appCommand(verb)) {
            // Claimed by the app's command registry.
        } else {
            self.setStatus("not an editor command: {s}", .{verb}, true);
        }
    }

    /// Offer an unknown verb to the app's command registry.
    ///
    /// Gated on vim's user-command shape — a leading capital — which is
    /// what keeps app commands out of the editor's namespace BY
    /// CONSTRUCTION rather than by a list that has to be maintained: no
    /// derived name can ever collide with `:w`, `:q` or `:noh`, because
    /// those are lowercase and a derived name never is. It also means a
    /// typo'd editor command still reports "not an editor command"
    /// instead of a confusing miss from the registry.
    fn appCommand(self: *Editor, verb: []const u8) bool {
        if (verb.len == 0 or verb[0] < 'A' or verb[0] > 'Z') return false;
        const run = self.app_command orelse return false;
        const ctx = self.cmd_ctx orelse return false;
        if (run(ctx, verb)) return true;
        self.setStatus("not a command: {s}", .{verb}, true);
        return true; // handled: the message is ours, not the fallthrough's
    }

    /// Show text that has no file behind it, under a display name.
    ///
    /// The whole session-view design in one call: a transcript is a
    /// DOCUMENT, and the editor is already a renderer with scrolling,
    /// search, motions and yank. Building a bespoke viewer would have
    /// meant reimplementing all of that worse.
    pub fn openText(self: *Editor, name: []const u8, text: []const u8) !void {
        var b: bufferpkg.Buffer = .{ .rope = try .init(self.gpa, text) };
        errdefer b.rope.deinit(self.gpa);
        b.path = try self.gpa.dupe(u8, name);
        self.buf.deinit(self.gpa);
        self.buf = b;
        self.ai_line = null; // line numbers belonged to the old buffer
        self.is_dir = false;
        self.synthetic = true;
        self.cline = 0;
        self.ccol = 0;
        self.top = 0;
        self.left = 0;
        // A synthetic name is not a path, so the highlighter must not try
        // to pick a grammar from its extension.
        if (self.hl_set_path) |set| {
            if (self.hl_ctx) |ctx| set(ctx, null);
        }
        self.hl_version = std.math.maxInt(u64);
    }

    /// Re-read the file under this buffer, keeping where you were.
    ///
    /// The difference from `:e` is the cursor: `:e` is you asking for a
    /// file and starting at the top, this is the file changing under
    /// you while you read it. Landing back on line one every time an
    /// agent touches the file you are watching would make the pane
    /// useless for watching.
    ///
    /// Refuses on a modified buffer — merging is the human's, and the
    /// only thing worse than not reloading is reloading over an edit.
    pub fn reload(self: *Editor) !void {
        if (self.buf.isModified() or self.synthetic) return;
        const path = self.buf.path orelse return;
        const owned = try self.gpa.dupe(u8, path);
        defer self.gpa.free(owned);

        var is_dir = false;
        const nb = try loadPath(self.gpa, self.io, owned, &is_dir);
        const cline = self.cline;
        const ccol = self.ccol;
        const top = self.top;
        self.buf.deinit(self.gpa);
        self.buf = nb;
        self.ai_line = null; // line numbers belonged to the old buffer
        self.is_dir = is_dir;
        // Clamp back onto whatever the file is NOW — it may be shorter
        // than the one we were looking at, and every motion below reads
        // these as valid.
        const last = self.lineCountB() -| 1;
        self.cline = @min(cline, last);
        self.top = @min(top, last);
        self.ccol = ccol;
        self.clampNormal();
        self.render_dirty = true;
        self.hl_version = std.math.maxInt(u64);
        self.setStatus("reloaded — changed on disk", .{}, false);
    }

    /// Retarget this pane at another file (:e / ctl edit — the
    /// rook-buffers model: panes retarget in place).
    pub fn open(self: *Editor, path: []const u8, force: bool) !void {
        if (self.buf.isModified() and !force) {
            self.setStatus("unsaved changes (:w first, or :e! to discard)", .{}, true);
            return;
        }
        var is_dir = false;
        const nb = try loadPath(self.gpa, self.io, path, &is_dir);
        self.buf.deinit(self.gpa);
        self.buf = nb;
        self.ai_line = null; // line numbers belonged to the old buffer
        self.is_dir = is_dir;
        self.cline = 0;
        self.ccol = 0;
        self.top = 0;
        self.left = 0;
        self.goal = 0;
        self.mode = .normal;
        self.render_dirty = true;
        if (self.hl_set_path) |f| f(self.hl_ctx.?, self.buf.path);
        self.hl_version = std.math.maxInt(u64);
    }

    // ------------------------------------------------------------ normal/visual

    fn takeCount(self: *Editor) usize {
        const c = self.count;
        self.count = 0;
        return if (c == 0) 1 else c;
    }

    fn enterInsert(self: *Editor) void {
        self.buf.newUndoGroup();
        self.mode = .insert;
    }

    /// Take back an auto-indent nobody typed on.
    ///
    /// Deliberately timid: it fires only when the line is still EXACTLY
    /// the whitespace this editor put there. Anything else — a typed
    /// character, a backspace, a paste — means the human owns those
    /// bytes now, and code that deletes text on a guess is code that
    /// eats someone's line.
    fn dropPendingIndent(self: *Editor) void {
        const line = self.ai_line orelse return;
        const n = self.ai_len;
        self.ai_line = null;
        self.ai_len = 0;
        if (n == 0 or line >= self.lineCountB()) return;
        const s = self.lineText(line);
        if (s.len != n or indentLen(s) != s.len) return;
        const start = self.buf.rope.lineStart(line);
        self.buf.deleteRange(self.gpa, start, start + n) catch return;
        if (self.cline == line) self.ccol = 0;
    }

    /// Arm the strip, and remember how much we owe back.
    fn armPendingIndent(self: *Editor, line: usize, n: usize) void {
        self.ai_line = if (n == 0) null else line;
        self.ai_len = n;
    }

    fn normalKey(self: *Editor, ch: u8) void {
        const gpa = self.gpa;

        if (self.pend_r) {
            self.pend_r = false;
            if (ch >= 0x20) {
                const s = self.lineText(self.cline);
                if (s.len > 0 and self.ccol < s.len) {
                    self.buf.newUndoGroup();
                    const start = self.buf.rope.lineStart(self.cline);
                    const n = cpLenAt(s, self.ccol);
                    self.buf.deleteRange(gpa, start + self.ccol, start + self.ccol + n) catch return;
                    self.buf.insert(gpa, start + self.ccol, &[1]u8{ch}) catch return;
                }
            }
            return;
        }

        // A pending f/F/t/T takes the NEXT key literally — a digit is a
        // character to find, not a count — so this sits above the count
        // branch. ESC is the one escape hatch.
        if (self.pend_find != 0) {
            const cmd = self.pend_find;
            self.pend_find = 0;
            if (ch == 0x1b or ch < 0x20) {
                self.op = 0;
                self.count = 0;
                return;
            }
            self.find_cmd = cmd;
            self.find_char = ch;
            self.motionFind(cmd, ch, false);
            return;
        }

        // `"a` and `ma` / `` `a `` / `'a` — the key after each of these
        // is a NAME, taken literally, so they sit above the count
        // branch with the rest of the pending states.
        if (self.pend_reg) {
            self.pend_reg = false;
            if (ch == 0x1b or ch < 0x20) {
                self.op = 0;
                self.count = 0;
                return;
            }
            self.sel_reg = ch;
            return;
        }

        if (self.pend_macro != 0) {
            const kind = self.pend_macro;
            self.pend_macro = 0;
            if (ch == 0x1b or ch < 0x20) {
                self.op = 0;
                self.count = 0;
                return;
            }
            if (kind == 'q') self.startMacro(ch) else self.playMacro(ch);
            return;
        }

        if (self.pend_mark != 0) {
            const kind = self.pend_mark;
            self.pend_mark = 0;
            if (ch == 0x1b or ch < 0x20) {
                self.op = 0;
                self.count = 0;
                return;
            }
            if (kind == 'm') {
                if (ch >= 'a' and ch <= 'z') self.marks[ch - 'a'] = .{ .line = self.cline, .col = self.ccol };
                self.count = 0;
                return;
            }
            self.gotoMark(ch, kind == '`');
            return;
        }

        // `iw` / `a(` — the key after i/a names the object, literally,
        // so this also sits above the count branch.
        if (self.pend_obj != 0) {
            const around = self.pend_obj == 'a';
            self.pend_obj = 0;
            if (ch == 0x1b or ch < 0x20) {
                self.op = 0;
                self.count = 0;
                return;
            }
            self.applyTextObject(around, ch);
            return;
        }

        if (ch == 0x1b) { // ESC: clear pending, leave visual
            self.count = 0;
            self.op = 0;
            self.pend_g = false;
            self.pend_z = false;
            self.pend_shift = 0;
            self.pend_find = 0;
            self.pend_obj = 0;
            self.pend_reg = false;
            self.pend_mark = 0;
            self.pend_macro = 0;
            self.sel_reg = 0;
            self.leaveVisual();
            return;
        }

        // Counts (0 alone is a motion).
        if (ch >= '1' and ch <= '9' or (ch == '0' and self.count > 0)) {
            self.count = self.count *| 10 +| (ch - '0');
            return;
        }

        // `>>` / `>j` / `>k` — after the count branch, so `>3j` counts
        // the same as `3>>`.
        if (self.pend_shift != 0) {
            const dir = self.pend_shift;
            self.pend_shift = 0;
            const cnt = self.takeCount();
            const a = self.cline;
            const right = dir == '>';
            if (ch == dir) {
                self.shiftLines(a, @min(a + cnt - 1, self.lineCountB() - 1), right);
            } else if (ch == 'j') {
                self.shiftLines(a, @min(a + cnt, self.lineCountB() - 1), right);
            } else if (ch == 'k') {
                self.shiftLines(a -| cnt, a, right);
            }
            return;
        }

        if (self.pend_z) {
            self.pend_z = false;
            self.count = 0;
            switch (ch) {
                'z', 't', 'b' => self.scrollHere(ch),
                else => {},
            }
            return;
        }

        if (self.pend_g) {
            self.pend_g = false;
            switch (ch) {
                'g' => {
                    const n = self.count;
                    self.count = 0;
                    self.motionLinewise(if (n == 0) 0 else @min(n - 1, self.lineCountB() - 1));
                },
                'e' => self.motionCharwise(k_ge),
                'u', 'U', '~' => {
                    if (self.mode == .visual or self.mode == .visual_line) {
                        self.visualOp(ch);
                        return;
                    }
                    if (isCaseOp(self.op)) { // gugu
                        self.caseLines();
                        return;
                    }
                    self.op = ch;
                },
                'J' => self.joinLines(self.takeCount(), false),
                else => {
                    self.op = 0;
                    self.count = 0;
                },
            }
            return;
        }

        switch (ch) {
            'g' => self.pend_g = true,

            // Directory buffers: Enter descends, `-` climbs (from file
            // buffers too — vim-vinegar).
            '\r' => if (self.is_dir) self.openDirEntry(),
            '-' => self.openParentDir(),

            // Motions.
            'h', 'l', 'w', 'b', 'e', '0', '^', '$' => self.motionCharwise(ch),
            '%' => self.motionMatch(),
            '{' => self.motionPara(false),
            '}' => self.motionPara(true),
            '*' => self.searchWord(true),
            '#' => self.searchWord(false),
            'z' => self.pend_z = true,
            'H', 'M', 'L' => {
                const rows = @max(1, self.last_rows -| 1);
                const bot = @min(self.top + rows - 1, self.lineCountB() - 1);
                const cnt = self.takeCount();
                self.motionLinewise(switch (ch) {
                    'H' => @min(self.top + cnt - 1, bot),
                    'L' => @max(self.top, bot -| (cnt - 1)),
                    else => self.top + (bot - self.top) / 2,
                });
            },
            'f', 'F', 't', 'T' => self.pend_find = ch,
            ';', ',' => {
                if (self.find_cmd == 0) {
                    self.op = 0;
                    self.count = 0;
                    return;
                }
                const cmd = if (ch == ';') self.find_cmd else switch (self.find_cmd) {
                    'f' => @as(u8, 'F'),
                    'F' => 'f',
                    't' => 'T',
                    'T' => 't',
                    else => self.find_cmd,
                };
                self.motionFind(cmd, self.find_char, true);
            },
            'j', 'k' => {
                const cnt = self.takeCount();
                if (self.op != 0) {
                    // dj/dk: linewise over count+1 lines.
                    const a = self.cline;
                    const b = if (ch == 'j')
                        @min(a + cnt, self.lineCountB() - 1)
                    else
                        a -| cnt;
                    self.opLines(@min(a, b), @max(a, b));
                    return;
                }
                const target = if (ch == 'j')
                    @min(self.cline + cnt, self.lineCountB() - 1)
                else
                    self.cline -| cnt;
                self.cline = target;
                self.ccol = bcolForRenderCol(self.lineText(target), self.goal);
                self.clampNormal();
            },
            'G' => {
                const n = self.count;
                self.count = 0;
                self.motionLinewise(if (n == 0) self.lineCountB() - 1 else @min(n - 1, self.lineCountB() - 1));
            },
            0x04 => { // ctrl-d
                const half = @max(1, (self.last_rows -| 1) / 2);
                self.cline = @min(self.cline + half, self.lineCountB() - 1);
                self.top = @min(self.top + half, self.lineCountB() - 1);
                self.ccol = bcolForRenderCol(self.lineText(self.cline), self.goal);
                self.clampNormal();
            },
            0x15 => { // ctrl-u
                const half = @max(1, (self.last_rows -| 1) / 2);
                self.cline -|= half;
                self.top -|= half;
                self.ccol = bcolForRenderCol(self.lineText(self.cline), self.goal);
                self.clampNormal();
            },

            // Operators.
            'd', 'y', 'c' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp(ch);
                    return;
                }
                if (self.op == ch) { // dd/yy/cc
                    const cnt = self.takeCount();
                    const a = self.cline;
                    self.opLines(a, @min(a + cnt - 1, self.lineCountB() - 1));
                    return;
                }
                self.op = ch;
            },
            '>', '<' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    const a = @min(self.vanchor_line, self.cline);
                    const b = @max(self.vanchor_line, self.cline);
                    self.leaveVisual();
                    self.count = 0;
                    self.shiftLines(a, b, ch == '>');
                    return;
                }
                self.pend_shift = ch;
            },
            'D' => self.opToEol('d'),
            'C' => self.opToEol('c'),
            'Y' => {
                const a = self.cline;
                const saved = self.op;
                self.op = 'y';
                self.opLines(a, a);
                self.op = saved;
            },

            'x' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('d');
                    return;
                }
                const cnt = self.takeCount();
                const s = self.lineText(self.cline);
                if (s.len == 0) return;
                var end = self.ccol;
                for (0..cnt) |_| {
                    if (end >= s.len) break;
                    end += cpLenAt(s, end);
                }
                if (end == self.ccol) return;
                self.buf.newUndoGroup();
                self.yankStore(s[self.ccol..end], false);
                const start = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, start + self.ccol, start + end) catch return;
                self.clampNormal();
            },
            'X' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('d');
                    return;
                }
                const cnt = self.takeCount();
                if (self.ccol == 0) return;
                const s = self.lineText(self.cline);
                var start = self.ccol;
                for (0..cnt) |_| {
                    if (start == 0) break;
                    start = prevCpStart(s, start);
                }
                self.buf.newUndoGroup();
                self.yankStore(s[start..self.ccol], false);
                const base = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, base + start, base + self.ccol) catch return;
                self.ccol = start;
                self.clampNormal();
            },
            's' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('c');
                    return;
                }
                // `s` is `cl` — except on an empty line, where `cl` has
                // nothing to delete and would leave you in normal mode.
                if (self.lineLenB(self.cline) == 0) {
                    self.count = 0;
                    self.enterInsert();
                    return;
                }
                self.op = 'c';
                self.motionCharwise('l');
            },
            'S' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('c');
                    return;
                }
                const cnt = self.takeCount();
                const a = self.cline;
                self.op = 'c';
                self.opLines(a, @min(a + cnt - 1, self.lineCountB() - 1));
            },
            '~' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('~');
                    return;
                }
                if (isCaseOp(self.op)) {
                    self.caseLines();
                    return;
                }
                const cnt = self.takeCount();
                const s = self.lineText(self.cline);
                if (self.ccol >= s.len) return;
                var end = self.ccol;
                for (0..cnt) |_| {
                    if (end >= s.len) break;
                    end += cpLenAt(s, end);
                }
                const base = self.buf.rope.lineStart(self.cline);
                self.caseRange(base + self.ccol, base + end, '~');
                self.ccol = end;
                self.clampNormal();
            },
            'U' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('U');
                    return;
                }
                if (isCaseOp(self.op)) {
                    self.caseLines();
                    return;
                }
                self.op = 0;
                self.count = 0;
            },
            'r' => self.pend_r = true,
            'R' => {
                self.count = 0;
                self.endReplace();
                self.enterInsert();
                self.replacing = true;
            },
            'J' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    const a = @min(self.vanchor_line, self.cline);
                    const b = @max(self.vanchor_line, self.cline);
                    self.leaveVisual();
                    self.count = 0;
                    self.cline = a;
                    self.joinLines(b - a + 1, true);
                    return;
                }
                self.joinLines(self.takeCount(), true);
            },

            // Insert transitions — unless something is waiting for a
            // range, in which case i/a name a text object.
            'i' => {
                if (self.op != 0 or self.mode == .visual or self.mode == .visual_line) {
                    self.pend_obj = 'i';
                    return;
                }
                self.enterInsert();
            },
            'I' => {
                self.ccol = firstNonblank(self.lineText(self.cline));
                self.enterInsert();
            },
            'a' => {
                if (self.op != 0 or self.mode == .visual or self.mode == .visual_line) {
                    self.pend_obj = 'a';
                    return;
                }
                const s = self.lineText(self.cline);
                if (s.len > 0 and self.ccol < s.len) self.ccol += cpLenAt(s, self.ccol);
                self.enterInsert();
            },
            'A' => {
                self.ccol = self.lineCap(self.cline);
                self.enterInsert();
            },
            'o' => {
                var ibuf: [max_indent]u8 = undefined;
                const ind = self.indentOf(self.cline, &ibuf);
                self.enterInsert();
                self.buf.insert(gpa, self.buf.rope.lineEnd(self.cline), "\n") catch return;
                self.cline += 1;
                self.ccol = 0;
                self.insertIndent(ind);
            },
            'O' => {
                var ibuf: [max_indent]u8 = undefined;
                const ind = self.indentOf(self.cline, &ibuf);
                self.enterInsert();
                self.buf.insert(gpa, self.buf.rope.lineStart(self.cline), "\n") catch return;
                self.ccol = 0;
                self.insertIndent(ind);
            },

            // Paste.
            'p' => self.paste(true),
            'P' => self.paste(false),

            // Undo — unless a case operator is waiting, where `u` is
            // its own doubled key (`guu`).
            'u' => {
                if (self.mode == .visual or self.mode == .visual_line) {
                    self.visualOp('u');
                    return;
                }
                if (isCaseOp(self.op)) {
                    self.caseLines();
                    return;
                }
                if (self.buf.undo(gpa) catch null) |off| self.cursorToOffset(off) else self.setStatus("already at oldest change", .{}, false);
            },
            0x12 => { // ctrl-r
                if (self.buf.redo(gpa) catch null) |off| self.cursorToOffset(off) else self.setStatus("already at newest change", .{}, false);
            },

            // Visual.
            'v' => {
                if (self.mode == .visual) {
                    self.leaveVisual();
                } else {
                    self.mode = .visual;
                    self.vanchor_line = self.cline;
                    self.vanchor_col = self.ccol;
                }
            },
            'V' => {
                if (self.mode == .visual_line) {
                    self.leaveVisual();
                } else {
                    self.mode = .visual_line;
                    self.vanchor_line = self.cline;
                    self.vanchor_col = self.ccol;
                }
            },

            ':' => {
                const from_visual = self.mode == .visual or self.mode == .visual_line;
                self.leaveVisual();
                self.mode = .command;
                self.cmd_kind = .ex;
                self.cmd.clearRetainingCapacity();
                // `:` out of a visual prefills the range vim prefills,
                // because that is what you were about to type.
                if (from_visual) self.cmd.appendSlice(gpa, "'<,'>") catch {};
            },
            '/' => {
                self.mode = .command;
                self.cmd_kind = .search;
                self.cmd.clearRetainingCapacity();
            },
            'n' => self.searchNext(true),
            'N' => self.searchNext(false),

            '.' => self.dotRepeat(),

            // Macros.
            'q' => {
                if (self.macro_reg != 0) self.stopMacro() else self.pend_macro = 'q';
            },
            '@' => self.pend_macro = '@',

            // Registers and marks.
            '"' => self.pend_reg = true,
            'm', '`', '\'' => self.pend_mark = ch,

            else => {
                self.op = 0;
                self.count = 0;
            },
        }
    }

    fn cursorToOffset(self: *Editor, off: usize) void {
        const o = @min(off, self.buf.rope.byteLen());
        self.cline = self.buf.rope.lineOfOffset(o);
        self.ccol = o - self.buf.rope.lineStart(self.cline);
        self.clampNormal();
    }

    // ------------------------------------------------------------ motions

    /// Charwise motions: either move the cursor or feed a pending
    /// operator. `e` is inclusive; the rest exclusive. cw acts as ce
    /// (vim's special case).
    /// `ge` is spelled with a `g`, so it arrives through the pend_g
    /// branch rather than the motion table. The pseudo-key keeps it on
    /// motionCharwise's operator path instead of growing a second copy
    /// of that path.
    const k_ge: u8 = 0x01;

    fn motionCharwise(self: *Editor, m0: u8) void {
        var m = m0;
        if (self.op == 'c' and m == 'w') m = 'e';
        const cnt = self.takeCount();
        var line = self.cline;
        var col = self.ccol;
        var inclusive = false;

        for (0..cnt) |_| {
            const s = self.lineText(line);
            switch (m) {
                'h' => col = prevCpStart(s, col),
                'l' => {
                    if (col < s.len) {
                        const n = col + cpLenAt(s, col);
                        // Normal-mode l stops at the last cp; operators
                        // reach one past (dl deletes the char).
                        if (self.op != 0 or n < s.len) col = n;
                    }
                },
                '0' => col = 0,
                '^' => col = firstNonblank(s),
                '$' => {
                    col = s.len;
                    inclusive = false; // already one-past-last
                },
                'w' => {
                    const r = self.scanWordFwd(line, col, false);
                    line = r.line;
                    col = r.col;
                },
                'e' => {
                    const r = self.scanWordFwd(line, col, true);
                    line = r.line;
                    col = r.col;
                    inclusive = true;
                },
                'b' => {
                    const r = self.scanWordBack(line, col);
                    line = r.line;
                    col = r.col;
                },
                k_ge => {
                    const r = self.scanWordEndBack(line, col);
                    line = r.line;
                    col = r.col;
                    inclusive = true;
                },
                else => {},
            }
        }

        if (self.op != 0) {
            const a0 = self.buf.rope.lineStart(self.cline) + self.ccol;
            const b0 = self.buf.rope.lineStart(line) + col;
            var hi = @max(a0, b0);
            if (inclusive) {
                // The bump belongs to whichever end is the FAR one:
                // for `e` that is the target, for the backward `ge` it
                // is where you started. Verified against vim — `dge`
                // eats both the previous word's last character and the
                // one under the cursor.
                const far_line = if (b0 > a0) line else self.cline;
                const far_col = if (b0 > a0) col else self.ccol;
                const s = self.lineText(far_line);
                if (far_col < s.len) hi += cpLenAt(s, far_col);
            }
            self.opRange(@min(a0, b0), hi);
            return;
        }

        self.cline = line;
        self.ccol = col;
        if (self.mode == .normal) self.clampNormal();
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    /// One `f`/`F`/`t`/`T` step: the column of the next (or previous)
    /// `target` on this line, or null.
    ///
    /// Line-local, like vim — these are the motions you use to get
    /// somewhere you can SEE, and one that silently walked to the next
    /// line would make `dt)` a much worse mistake than it looks.
    fn findStep(s: []const u8, fwd: bool, target: u8, from: usize) ?usize {
        if (fwd) {
            var j = from;
            if (j >= s.len) return null;
            j += cpLenAt(s, j);
            while (j < s.len) : (j += cpLenAt(s, j)) {
                if (s[j] == target) return j;
            }
            return null;
        }
        if (from == 0) return null;
        var j = prevCpStart(s, from);
        while (true) {
            if (s[j] == target) return j;
            if (j == 0) return null;
            j = prevCpStart(s, j);
        }
    }

    /// `f`/`F`/`t`/`T`, `;`/`,` — move, or feed a pending operator.
    ///
    /// `repeat` is `;`/`,` and matters only for `t`: the cursor is
    /// already parked one short of the target, so a plain search would
    /// find the same one and go nowhere. Vim advances past it, and a
    /// `;` that does nothing is worse than useless — you press it
    /// again.
    fn motionFind(self: *Editor, cmd: u8, target: u8, repeat: bool) void {
        const cnt = self.takeCount();
        const fwd = cmd == 'f' or cmd == 't';
        const till = cmd == 't' or cmd == 'T';
        const s = self.lineText(self.cline);

        var col = self.ccol;
        if (repeat and till) {
            // Step off the character we are parked against.
            if (fwd) {
                if (col >= s.len) {
                    self.op = 0;
                    return;
                }
                col += cpLenAt(s, col);
            } else {
                if (col == 0) {
                    self.op = 0;
                    return;
                }
                col = prevCpStart(s, col);
            }
        }
        for (0..cnt) |_| {
            col = findStep(s, fwd, target, col) orelse {
                // Not found: the cursor stays and the operator is
                // cancelled, so `dt;` on a line with no `;` is a no-op
                // rather than a deletion to somewhere arbitrary.
                self.op = 0;
                return;
            };
        }
        if (till) col = if (fwd) prevCpStart(s, col) else col + cpLenAt(s, col);

        if (self.op != 0) {
            // f/t are inclusive of the landing character, F/T are not —
            // `df,` eats the comma, `dF,` stops at it.
            var end_col = col;
            if (fwd and end_col < s.len) end_col += cpLenAt(s, end_col);
            const base = self.buf.rope.lineStart(self.cline);
            const a = base + self.ccol;
            const b = base + end_col;
            self.opRange(@min(a, b), @max(a, b));
            return;
        }
        self.ccol = col;
        if (self.mode == .normal) self.clampNormal();
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    // -------------------------------------------------------- text objects

    /// A bracket further away than this is not the one you meant.
    const obj_scan_max = 1 << 20;

    const Range = struct { a: usize, b: usize };

    /// Scan the ROPE for a matching bracket, counting nesting.
    ///
    /// Chunked rather than byte-at-a-time: the rope has no cheap
    /// iterator and `copyRange` walks from the root, so a per-byte loop
    /// would turn `di{` on a long function into a tree traversal per
    /// character.
    ///
    /// Brackets inside strings and comments COUNT, same as vim's own
    /// `%`. Doing better needs the syntax tree, and the syntax tree is
    /// an optional hook here.
    fn matchBracket(self: *Editor, from: usize, ob: u8, cb: u8, fwd: bool) ?usize {
        const rope = &self.buf.rope;
        var depth: usize = 1;
        var chunk: [4096]u8 = undefined;
        if (fwd) {
            var off = from + 1;
            const stop = @min(rope.byteLen(), from + obj_scan_max);
            while (off < stop) {
                const n = @min(chunk.len, stop - off);
                rope.copyRange(off, off + n, chunk[0..n]);
                for (chunk[0..n], 0..) |c, i| {
                    if (c == ob) {
                        depth += 1;
                    } else if (c == cb) {
                        depth -= 1;
                        if (depth == 0) return off + i;
                    }
                }
                off += n;
            }
            return null;
        }
        var end = from;
        const floor = from -| obj_scan_max;
        while (end > floor) {
            const n = @min(chunk.len, end - floor);
            rope.copyRange(end - n, end, chunk[0..n]);
            var i = n;
            while (i > 0) {
                i -= 1;
                const c = chunk[i];
                if (c == cb) {
                    depth += 1;
                } else if (c == ob) {
                    depth -= 1;
                    if (depth == 0) return end - n + i;
                }
            }
            end -= n;
        }
        return null;
    }

    /// `i(` / `a{` / `i[` / `a<` — the pair enclosing the cursor.
    ///
    /// Sitting ON a bracket counts as being inside its pair, which is
    /// what makes `ci(` work with the cursor parked on the paren you
    /// were just looking at.
    fn objBracket(self: *Editor, around: bool, ob: u8, cb: u8) ?Range {
        const rope = &self.buf.rope;
        const cur = self.absOff();
        var here: u8 = 0;
        if (cur < rope.byteLen()) {
            var one: [1]u8 = undefined;
            rope.copyRange(cur, cur + 1, &one);
            here = one[0];
        }
        // Sitting ON a bracket is being inside its pair — either one.
        // The closing case needs saying out loud: searching backward
        // from past the cursor would count that `)` as a nesting level
        // and hand back the pair OUTSIDE it, which deletes strictly
        // more than you asked for.
        var a: usize = undefined;
        var b: usize = undefined;
        if (here == ob) {
            a = cur;
            b = self.matchBracket(a, ob, cb, true) orelse return null;
        } else if (here == cb) {
            b = cur;
            a = self.matchBracket(b, ob, cb, false) orelse return null;
        } else {
            a = self.matchBracket(cur + 1, ob, cb, false) orelse return null;
            b = self.matchBracket(a, ob, cb, true) orelse return null;
        }
        return if (around) .{ .a = a, .b = b + 1 } else .{ .a = a + 1, .b = b };
    }

    /// `i"` / `a'` — line-local, because a quote that spanned lines
    /// would usually mean an UNBALANCED quote somewhere above, and
    /// `ci"` would then eat half the file.
    ///
    /// Pairs are counted from the start of the line, so the cursor
    /// sitting on the opening quote, inside, or on the closing quote
    /// all resolve to the same string.
    fn objQuote(self: *Editor, around: bool, q: u8) ?Range {
        const s = self.lineText(self.cline);
        const base = self.buf.rope.lineStart(self.cline);
        var ob_at: ?usize = null;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\') {
                i += 1;
                continue;
            }
            if (s[i] != q) continue;
            if (ob_at) |o| {
                if (self.ccol <= i) {
                    if (!around) return .{ .a = base + o + 1, .b = base + i };
                    // `a"` takes the trailing whitespace, vim's rule —
                    // otherwise `da"` leaves a stray space behind.
                    var e = i + 1;
                    while (e < s.len and (s[e] == ' ' or s[e] == '\t')) e += 1;
                    return .{ .a = base + o, .b = base + e };
                }
                ob_at = null;
            } else ob_at = i;
        }
        return null;
    }

    /// `iw` / `aw` — the run of one character class around the cursor.
    /// `aw` extends over the whitespace after it, or before it when the
    /// word ends the line.
    fn objWord(self: *Editor, around: bool, big: bool) ?Range {
        const s = self.lineText(self.cline);
        if (s.len == 0) return null;
        const base = self.buf.rope.lineStart(self.cline);
        const cur = @min(self.ccol, s.len - 1);
        const cls = if (big) @as(u8, if (charClass(s[cur]) == 0) 0 else 1) else charClass(s[cur]);
        const sameClass = struct {
            fn f(c: u8, want: u8, b: bool) bool {
                const k = charClass(c);
                return if (b) (if (want == 0) k == 0 else k != 0) else k == want;
            }
        }.f;

        var a = cur;
        while (a > 0 and sameClass(s[a - 1], cls, big)) a -= 1;
        var b = cur + 1;
        while (b < s.len and sameClass(s[b], cls, big)) b += 1;
        if (!around) return .{ .a = base + a, .b = base + b };

        var e = b;
        while (e < s.len and charClass(s[e]) == 0) e += 1;
        if (e == b) while (a > 0 and charClass(s[a - 1]) == 0) {
            a -= 1;
        };
        return .{ .a = base + a, .b = base + e };
    }

    /// Resolve `iw`, `a(`, `i"` … to an absolute byte range.
    fn textObject(self: *Editor, around: bool, kind: u8) ?Range {
        return switch (kind) {
            'w' => self.objWord(around, false),
            'W' => self.objWord(around, true),
            '"', '\'', '`' => self.objQuote(around, kind),
            '(', ')', 'b' => self.objBracket(around, '(', ')'),
            '{', '}', 'B' => self.objBracket(around, '{', '}'),
            '[', ']' => self.objBracket(around, '[', ']'),
            '<', '>' => self.objBracket(around, '<', '>'),
            else => null,
        };
    }

    /// `diw` / `ci(` / `va"` — apply the pending operator to an object,
    /// or select it in visual mode.
    fn applyTextObject(self: *Editor, around: bool, kind: u8) void {
        self.count = 0;
        const r = self.textObject(around, kind) orelse {
            // No such object here: cancel, the way a failed find does.
            // An operator that falls back to "some other range" is how
            // you lose a paragraph to a typo.
            self.op = 0;
            return;
        };
        if (self.op != 0) {
            self.opRange(r.a, r.b);
            return;
        }
        // Visual: put the anchor and cursor on the object's ends.
        self.mode = .visual;
        self.vanchor_line = self.buf.rope.lineOfOffset(r.a);
        self.vanchor_col = r.a - self.buf.rope.lineStart(self.vanchor_line);
        const last = if (r.b > r.a) r.b - 1 else r.a;
        self.cline = self.buf.rope.lineOfOffset(last);
        self.ccol = last - self.buf.rope.lineStart(self.cline);
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    fn motionLinewise(self: *Editor, target: usize) void {
        if (self.op != 0) {
            self.opLines(@min(self.cline, target), @max(self.cline, target));
            return;
        }
        self.setJump();
        self.cline = target;
        self.ccol = firstNonblank(self.lineText(target));
        self.goal = renderCol(self.lineText(target), self.ccol);
    }

    const Pos = struct { line: usize, col: usize };

    // ------------------------------------------------------------------ marks

    /// Remember where a jump started, so `` `` `` can undo it. Only the
    /// motions that move you somewhere you did not aim at with your
    /// eyes set this: `G`, `gg`, `n`, and a mark jump.
    fn setJump(self: *Editor) void {
        self.jump = .{ .line = self.cline, .col = self.ccol };
    }

    /// Leave visual mode, remembering the selection. Everything that
    /// ends a visual goes through here so `'<`/`'>` and `gv` cannot
    /// drift out of date with one of the exits.
    fn leaveVisual(self: *Editor) void {
        if (self.mode == .visual or self.mode == .visual_line) {
            self.vlast = .{
                .mode = self.mode,
                .a = .{ .line = self.vanchor_line, .col = self.vanchor_col },
                .b = .{ .line = self.cline, .col = self.ccol },
            };
        }
        self.mode = .normal;
    }

    fn markPos(self: *const Editor, letter: u8) ?Pos {
        if (letter == '`' or letter == '\'') return self.jump;
        if (letter < 'a' or letter > 'z') return null;
        return self.marks[letter - 'a'];
    }

    /// `` `a `` (exact) and `'a` (first non-blank of the line), as
    /// motions — so `d'a` is linewise over the range and ``d`a`` is
    /// charwise to the byte, which is the whole reason marks pay for
    /// themselves. An unset mark CANCELS a pending operator rather than
    /// running it against a position nobody chose.
    fn gotoMark(self: *Editor, letter: u8, exact: bool) void {
        self.count = 0;
        const target = self.markPos(letter) orelse {
            self.op = 0;
            self.setStatus("mark not set: {c}", .{letter}, true);
            return;
        };
        const line = @min(target.line, self.lineCountB() - 1);
        if (self.op != 0) {
            if (!exact) {
                self.opLines(@min(line, self.cline), @max(line, self.cline));
                return;
            }
            const dst = self.buf.rope.lineStart(line) + @min(target.col, self.lineCap(line));
            const cur = self.absOff();
            self.opRange(@min(cur, dst), @max(cur, dst));
            return;
        }
        self.setJump();
        self.cline = line;
        self.ccol = if (exact)
            @min(target.col, self.lineCap(line))
        else
            firstNonblank(self.lineText(line));
        self.clampNormal();
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    fn charClass(c: u8) u8 {
        if (c == ' ' or c == '\t') return 0;
        if (c == '_' or std.ascii.isAlphanumeric(c) or c >= 0x80) return 1;
        return 2;
    }

    fn scanWordFwd(self: *Editor, line0: usize, col0: usize, to_end: bool) Pos {
        var line = line0;
        var col = col0;
        var s = self.lineText(line);
        if (to_end) {
            // e: step one cp, skip blanks/newlines, run to end of class run.
            if (col < s.len) col += cpLenAt(s, col);
            while (true) {
                if (col >= s.len) {
                    if (line + 1 >= self.lineCountB()) return .{ .line = line, .col = lastCpCol(s) };
                    line += 1;
                    col = 0;
                    s = self.lineText(line);
                    continue;
                }
                if (charClass(s[col]) == 0) {
                    col += cpLenAt(s, col);
                    continue;
                }
                break;
            }
            const cls = charClass(s[col]);
            while (true) {
                const n = col + cpLenAt(s, col);
                if (n >= s.len or charClass(s[n]) != cls) return .{ .line = line, .col = col };
                col = n;
            }
        }
        // w: skip current class run, then blanks (crossing lines).
        if (col < s.len) {
            const cls = charClass(s[col]);
            while (col < s.len and charClass(s[col]) == cls) col += cpLenAt(s, col);
        }
        while (true) {
            if (col >= s.len) {
                if (line + 1 >= self.lineCountB()) return .{ .line = line, .col = lastCpCol(s) };
                line += 1;
                col = 0;
                s = self.lineText(line);
                if (s.len == 0) return .{ .line = line, .col = 0 }; // vim stops on empty lines
                continue;
            }
            if (charClass(s[col]) == 0) {
                col += cpLenAt(s, col);
                continue;
            }
            return .{ .line = line, .col = col };
        }
    }

    fn scanWordBack(self: *Editor, line0: usize, col0: usize) Pos {
        var line = line0;
        var col = col0;
        var s = self.lineText(line);
        // Step back one cp (crossing lines), skip blanks back, then run
        // back to the start of the class run.
        while (true) {
            if (col == 0) {
                if (line == 0) return .{ .line = 0, .col = 0 };
                line -= 1;
                s = self.lineText(line);
                col = s.len;
                if (s.len == 0) return .{ .line = line, .col = 0 };
                continue;
            }
            col = prevCpStart(s, col);
            if (charClass(s[col]) != 0) break;
        }
        const cls = charClass(s[col]);
        while (col > 0) {
            const p = prevCpStart(s, col);
            if (charClass(s[p]) != cls) break;
            col = p;
        }
        return .{ .line = line, .col = col };
    }

    /// `ge` — back to the END of the previous word. The first loop is
    /// what makes it `ge` and not `b`: from inside a word you have to
    /// walk out of that word's own run before the previous one counts.
    fn scanWordEndBack(self: *Editor, line0: usize, col0: usize) Pos {
        var line = line0;
        var col = col0;
        var s = self.lineText(line);
        var in_run = if (col < s.len) charClass(s[col]) else 0;
        while (true) {
            if (col == 0) {
                if (line == 0) return .{ .line = 0, .col = 0 };
                line -= 1;
                s = self.lineText(line);
                if (s.len == 0) return .{ .line = line, .col = 0 };
                col = prevCpStart(s, s.len);
            } else {
                col = prevCpStart(s, col);
            }
            const c = charClass(s[col]);
            if (in_run != 0 and c == in_run) continue;
            in_run = 0;
            if (c != 0) return .{ .line = line, .col = col };
        }
    }

    /// `{` / `}` — the blank line before or after this paragraph. A
    /// blank line is the entire definition of a paragraph here, which
    /// is also vim's default.
    fn paraTarget(self: *Editor, from: usize, fwd: bool) usize {
        const last = self.lineCountB() - 1;
        var l = from;
        if (fwd) {
            while (l < last and self.lineLenB(l) == 0) l += 1;
            while (l < last and self.lineLenB(l) != 0) l += 1;
            return l;
        }
        while (l > 0 and self.lineLenB(l) == 0) l -= 1;
        while (l > 0 and self.lineLenB(l) != 0) l -= 1;
        return l;
    }

    /// Exclusive and charwise, landing in column 0 — so `d}` from the
    /// middle of a line takes the rest of the paragraph and stops at
    /// the blank line rather than swallowing it.
    fn motionPara(self: *Editor, fwd: bool) void {
        const cnt = self.takeCount();
        var line = self.cline;
        for (0..cnt) |_| line = self.paraTarget(line, fwd);
        if (self.op != 0) {
            const a = self.absOff();
            const b = self.buf.rope.lineStart(line);
            self.opRange(@min(a, b), @max(a, b));
            return;
        }
        self.setJump();
        self.cline = line;
        self.ccol = 0;
        self.goal = 0;
        self.clampNormal();
    }

    /// `%` — the first bracket at or after the cursor ON THIS LINE, and
    /// its match. Inclusive for an operator, because `d%` meaning
    /// "everything but the closing brace" would be useless.
    fn motionMatch(self: *Editor) void {
        self.count = 0;
        const s = self.lineText(self.cline);
        var col = self.ccol;
        var ob: u8 = 0;
        var cb: u8 = 0;
        var fwd = false;
        while (col < s.len) : (col += 1) {
            switch (s[col]) {
                '(', ')' => {
                    ob = '(';
                    cb = ')';
                },
                '[', ']' => {
                    ob = '[';
                    cb = ']';
                },
                '{', '}' => {
                    ob = '{';
                    cb = '}';
                },
                else => continue,
            }
            fwd = s[col] == ob;
            break;
        }
        if (ob == 0) {
            self.op = 0;
            return;
        }
        const from = self.buf.rope.lineStart(self.cline) + col;
        const dst = self.matchBracket(from, ob, cb, fwd) orelse {
            self.op = 0;
            return;
        };
        if (self.op != 0) {
            // From the CURSOR to the match, not from the bracket:
            // `d%` sitting before an open paren takes the text in
            // between too. Verified against vim.
            const cur = self.absOff();
            self.opRange(@min(cur, dst), @max(cur, dst) + 1);
            return;
        }
        self.setJump();
        self.cursorToOffset(dst);
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    /// `*` / `#` — the word under the cursor becomes the search
    /// pattern. Literal, like everything `/` does: `*` on `foo` also
    /// finds `foobar`, because this engine has no word boundaries to
    /// anchor with yet.
    fn searchWord(self: *Editor, fwd: bool) void {
        self.count = 0;
        self.op = 0;
        const s = self.lineText(self.cline);
        var a = self.ccol;
        while (a < s.len and charClass(s[a]) != 1) a += 1;
        if (a >= s.len) {
            self.setStatus("no word under the cursor", .{}, true);
            return;
        }
        while (a > 0 and charClass(s[a - 1]) == 1) a -= 1;
        var b = a;
        while (b < s.len and charClass(s[b]) == 1) b += 1;
        self.last_search.clearRetainingCapacity();
        self.last_search.appendSlice(self.gpa, s[a..b]) catch return;
        // Start from the word's first byte so a forward search leaves
        // this occurrence and a backward one does not find it again.
        self.ccol = a;
        self.searchNext(fwd);
    }

    /// `zt` / `zz` / `zb` — put the cursor line at the top, middle or
    /// bottom of the window without moving it in the buffer.
    fn scrollHere(self: *Editor, where: u8) void {
        const rows = @max(1, self.last_rows -| 1);
        self.top = switch (where) {
            't' => self.cline,
            'b' => self.cline -| (rows - 1),
            else => self.cline -| rows / 2,
        };
    }

    // ------------------------------------------------------------ operators

    const Named = struct {
        text: std.ArrayListUnmanaged(u8) = .empty,
        linewise: bool = false,
    };

    /// Whatever the pending `"x` names, else the unnamed register.
    /// Consumes the selection: a register lasts exactly one command.
    fn takeReg(self: *Editor) ?*Named {
        const r = self.sel_reg;
        self.sel_reg = 0;
        if (r == 0) return null;
        const lower = std.ascii.toLower(r);
        if (lower < 'a' or lower > 'z') return null;
        return &self.regs[lower - 'a'];
    }

    /// Store a yank or a delete. The unnamed register always gets it —
    /// that is what makes `p` after any `d` work — and a named one gets
    /// a copy, appending instead of replacing when the letter is
    /// uppercase. `"_` is the black hole: it takes the text and leaves
    /// the unnamed register ALONE, which is the whole reason to have it
    /// (`"_dd` deletes without losing what you were about to paste).
    fn yankStore(self: *Editor, text: []const u8, linewise: bool) void {
        const gpa = self.gpa;
        const upper = std.ascii.isUpper(self.sel_reg);
        const blackhole = self.sel_reg == '_';
        if (self.takeReg()) |n| {
            if (!upper) {
                n.text.clearRetainingCapacity();
                n.linewise = linewise;
            } else if (n.linewise and n.text.items.len > 0 and n.text.items[n.text.items.len - 1] != '\n') {
                n.text.append(gpa, '\n') catch {};
            }
            n.text.appendSlice(gpa, text) catch {};
            if (upper and linewise) n.linewise = true;
            endLine(gpa, &n.text, n.linewise);
        }
        if (blackhole) return;
        self.reg.clearRetainingCapacity();
        self.reg.appendSlice(gpa, text) catch {};
        self.reg_linewise = linewise;
        endLine(gpa, &self.reg, linewise);
    }

    /// A linewise register holds WHOLE lines, even when the last one of
    /// the file came without a newline — otherwise `p` on it splices
    /// the text onto whatever line the cursor is on.
    fn endLine(gpa: Allocator, list: *std.ArrayListUnmanaged(u8), linewise: bool) void {
        if (!linewise or list.items.len == 0) return;
        if (list.items[list.items.len - 1] != '\n') list.append(gpa, '\n') catch {};
    }

    fn isCaseOp(op: u8) bool {
        return op == 'u' or op == 'U' or op == '~';
    }

    /// `gu` / `gU` / `g~` over a byte range, in 4KB chunks because the
    /// range can be a whole paragraph and copyRange walks from the root
    /// every time.
    ///
    /// ASCII case only. Every substitution is one byte for one byte, so
    /// the offsets stay put while the walk runs — a Unicode-aware
    /// version changes lengths and would need the whole range rebuilt.
    fn caseRange(self: *Editor, start: usize, end: usize, how: u8) void {
        const gpa = self.gpa;
        if (start >= end) return;
        self.buf.newUndoGroup();
        var chunk: [4096]u8 = undefined;
        var off = start;
        while (off < end) {
            const n = @min(chunk.len, end - off);
            self.buf.rope.copyRange(off, off + n, chunk[0..n]);
            var changed = false;
            for (chunk[0..n]) |*c| {
                const was = c.*;
                c.* = switch (how) {
                    'u' => std.ascii.toLower(was),
                    'U' => std.ascii.toUpper(was),
                    else => if (std.ascii.isUpper(was)) std.ascii.toLower(was) else std.ascii.toUpper(was),
                };
                if (c.* != was) changed = true;
            }
            if (changed) {
                self.buf.deleteRange(gpa, off, off + n) catch return;
                self.buf.insert(gpa, off, chunk[0..n]) catch return;
            }
            off += n;
        }
    }

    /// Charwise operator over [start, end) byte offsets.
    fn opRange(self: *Editor, start: usize, end: usize) void {
        const gpa = self.gpa;
        const op = self.op;
        self.op = 0;
        if (start == end) return;
        if (isCaseOp(op)) {
            // Case operators leave the registers alone: nothing was
            // taken out of the buffer to put anywhere.
            self.caseRange(start, end, op);
            self.cursorToOffset(start);
            return;
        }
        const text = self.buf.rope.dupeRange(gpa, start, end) catch return;
        defer gpa.free(text);
        self.yankStore(text, false);
        if (op == 'y') {
            self.cursorToOffset(start);
            return;
        }
        self.buf.newUndoGroup();
        self.buf.deleteRange(gpa, start, end) catch return;
        self.cursorToOffset(start);
        if (op == 'c') {
            self.mode = .insert;
        }
    }

    /// Linewise operator over lines [a, b] inclusive.
    fn opLines(self: *Editor, a: usize, b: usize) void {
        const gpa = self.gpa;
        const op = self.op;
        self.op = 0;
        const rope = &self.buf.rope;
        var start = rope.lineStart(a);
        const end = if (b + 1 < self.lineCountB()) rope.lineStart(b + 1) else rope.byteLen();

        if (isCaseOp(op)) {
            self.caseRange(start, end, op);
            self.cline = a;
            self.ccol = firstNonblank(self.lineText(a));
            return;
        }

        const text = rope.dupeRange(gpa, start, end) catch return;
        defer gpa.free(text);
        self.yankStore(text, true);
        if (op == 'y') {
            self.cline = a;
            self.clampNormal();
            return;
        }

        self.buf.newUndoGroup();
        if (op == 'c') {
            // cc: clear the lines but keep one empty line to type into,
            // at the indent you were already at — retyping a line is
            // not a request to move it to column zero.
            var ibuf: [max_indent]u8 = undefined;
            const ind = self.indentOf(a, &ibuf);
            if (end > start and self.buf.rope.byteLen() >= end and end >= 1) {
                const keep_nl = b + 1 < self.lineCountB();
                self.buf.deleteRange(gpa, start, if (keep_nl) end - 1 else end) catch return;
            }
            self.cline = a;
            self.ccol = 0;
            self.mode = .insert;
            self.insertIndent(ind);
            return;
        }
        // dd at EOF also eats the newline BEFORE the range.
        if (end == rope.byteLen() and start > 0) start -= 1;
        self.buf.deleteRange(gpa, start, end) catch return;
        self.cline = @min(a, self.lineCountB() - 1);
        self.ccol = firstNonblank(self.lineText(self.cline));
    }

    /// Shift lines [a, b] by one indent step.
    ///
    /// Works in COLUMNS, not bytes: the existing indent is measured with
    /// tabs snapping to their stop, a step is added or removed, and the
    /// result is respelled in whatever the file indents with. That is
    /// what makes `<<` do the right thing on a line someone indented
    /// with a mix of both.
    ///
    /// Blank lines are left alone. Vim's behaviour, and the reason is
    /// the same one as the auto-indent take-back: nobody wants a diff
    /// where the change is whitespace on an empty line.
    fn shiftLines(self: *Editor, a: usize, b: usize, right: bool) void {
        const gpa = self.gpa;
        const unit = self.indentUnit();
        var grouped = false;
        var line = a;
        while (line <= b and line < self.lineCountB()) : (line += 1) {
            const s = self.lineText(line);
            const cur_bytes = indentLen(s);
            if (cur_bytes == s.len) continue; // blank
            const w = indentWidth(s);
            const target = if (right) w + tab_width else w -| tab_width;
            var ibuf: [max_indent]u8 = undefined;
            const ind = makeIndent(target, unit, &ibuf);
            if (ind.len == cur_bytes and std.mem.eql(u8, ind, s[0..cur_bytes])) continue;

            // One group for the whole range: `3>>` is one edit to undo.
            if (!grouped) {
                self.buf.newUndoGroup();
                grouped = true;
            }
            const start = self.buf.rope.lineStart(line);
            self.buf.deleteRange(gpa, start, start + cur_bytes) catch return;
            if (ind.len > 0) self.buf.insert(gpa, start, ind) catch return;
        }
        self.cline = @min(a, self.lineCountB() - 1);
        self.ccol = firstNonblank(self.lineText(self.cline));
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    /// `J` and `gJ`. A count joins that many LINES, so `3J` is two
    /// joins — vim's arithmetic, and `1J` still joins one pair.
    /// `gJ` is the same minus the space and minus the next line's
    /// indent being eaten, which is the whole reason it exists.
    fn joinLines(self: *Editor, cnt: usize, space: bool) void {
        const gpa = self.gpa;
        var grouped = false;
        for (0..@max(1, cnt -| 1)) |_| {
            if (self.cline + 1 >= self.lineCountB()) break;
            if (!grouped) {
                self.buf.newUndoGroup();
                grouped = true;
            }
            const eol = self.buf.rope.lineEnd(self.cline);
            const nb = if (space) firstNonblank(self.lineText(self.cline + 1)) else 0;
            self.buf.deleteRange(gpa, eol, eol + 1 + nb) catch return;
            if (space) self.buf.insert(gpa, eol, " ") catch return;
            self.ccol = eol - self.buf.rope.lineStart(self.cline);
        }
        self.clampNormal();
    }

    /// The doubled key of a pending case operator — `guu`, `gUU`,
    /// `g~~`, and the `gugu` spelling too. Vim takes any of `u`, `U`
    /// and `~` here, so this does not care which arrived.
    fn caseLines(self: *Editor) void {
        const cnt = self.takeCount();
        const a = self.cline;
        self.opLines(a, @min(a + cnt - 1, self.lineCountB() - 1));
    }

    fn opToEol(self: *Editor, op: u8) void {
        const start = self.absOff();
        const end = self.buf.rope.lineEnd(self.cline);
        if (start >= end) {
            if (op == 'c') self.enterInsert();
            return;
        }
        self.op = op;
        self.opRange(start, end);
        if (op != 'c') self.clampNormal();
    }

    fn visualOp(self: *Editor, op: u8) void {
        const linewise = self.mode == .visual_line;
        self.leaveVisual();
        if (linewise) {
            self.op = op;
            self.opLines(@min(self.vanchor_line, self.cline), @max(self.vanchor_line, self.cline));
            return;
        }
        var a = self.buf.rope.lineStart(self.vanchor_line) + self.vanchor_col;
        var b = self.absOff();
        if (a > b) std.mem.swap(usize, &a, &b);
        // Inclusive of the end codepoint.
        const bl = self.buf.rope.lineOfOffset(b);
        const s = self.lineText(bl);
        const bc = b - self.buf.rope.lineStart(bl);
        if (bc < s.len) b += cpLenAt(s, bc);
        self.op = op;
        self.opRange(a, b);
    }

    fn paste(self: *Editor, after: bool) void {
        const gpa = self.gpa;
        if (self.sel_reg == '_') { // the black hole holds nothing
            self.sel_reg = 0;
            self.count = 0;
            return;
        }
        // The register is read into locals before the first insert:
        // pasting a NAMED register into the buffer must not be walking
        // a list that anything downstream could reallocate.
        var body: []const u8 = self.reg.items;
        var linewise = self.reg_linewise;
        if (self.takeReg()) |n| {
            body = n.text.items;
            linewise = n.linewise;
        }
        if (body.len == 0) return;
        const cnt = self.takeCount();
        self.buf.newUndoGroup();
        if (linewise) {
            const rope = &self.buf.rope;
            for (0..cnt) |i| {
                if (after) {
                    if (self.cline + 1 < self.lineCountB()) {
                        self.buf.insert(gpa, rope.lineStart(self.cline + 1), body) catch return;
                    } else {
                        // Paste after the last line: newline first, and
                        // the register's own trailing newline is dropped.
                        var end = rope.byteLen();
                        self.buf.insert(gpa, end, "\n") catch return;
                        end += 1;
                        self.buf.insert(gpa, end, body[0 .. body.len - 1]) catch return;
                    }
                    if (i == 0) self.cline += 1;
                } else {
                    self.buf.insert(gpa, rope.lineStart(self.cline), body) catch return;
                }
            }
            self.ccol = firstNonblank(self.lineText(self.cline));
            return;
        }
        const s = self.lineText(self.cline);
        var at = self.absOff();
        if (after and s.len > 0 and self.ccol < s.len) at += cpLenAt(s, self.ccol);
        for (0..cnt) |_| self.buf.insert(gpa, at, body) catch return;
        self.cursorToOffset(at + body.len * cnt - 1);
    }

    /// Where the cursor sits in the pane's OWN cell grid, gutter
    /// included — for anything that has to point at the cursor from
    /// outside the editor (the IME's candidate window is the first).
    pub fn cursorCell(self: *Editor) struct { col: u16, row: u16 } {
        const gw = digits(self.lineCountB()) + 1;
        const rc = renderCol(self.lineText(self.cline), self.ccol);
        return .{ .col = @intCast(gw + rc), .row = @intCast(self.cline -| self.top) };
    }

    /// ⌘V: the system pasteboard, vim-shaped.
    ///
    /// Insert and command modes take the text literally — the input path
    /// is already a stream, so a pasted run lands the same way a typed
    /// one does. Every other mode loads the clipboard into the unnamed
    /// register and puts it, so ⌘V in normal mode is `p` with the
    /// pasteboard as its register. That distinction is not cosmetic:
    /// feeding clipboard bytes to normal mode would run them as
    /// commands, and a stray `dd` in someone's clipboard would eat a
    /// line. Text pasted while a document is open must never be keys.
    ///
    /// Linewise when the text ends in a newline, matching what a yanked
    /// line looks like — so pasting whole lines lands between lines
    /// rather than inside the current one.
    pub fn pasteText(self: *Editor, text: []const u8) void {
        if (text.len == 0) return;
        self.render_dirty = true;
        self.status_len = 0;
        switch (self.mode) {
            .insert, .command => self.key(text),
            else => {
                self.yankStore(text, text[text.len - 1] == '\n');
                self.paste(true);
            },
        }
    }

    /// Jump to the next/previous match of last_search, wrapping.
    fn searchNext(self: *Editor, fwd: bool) void {
        const pat = self.last_search.items;
        if (pat.len == 0) {
            self.setStatus("no previous search", .{}, true);
            return;
        }
        if (self.findMatch(fwd)) |pos| {
            self.setJump();
            self.cline = pos.line;
            self.ccol = pos.col;
            self.goal = renderCol(self.lineText(pos.line), pos.col);
        } else {
            self.setStatus("pattern not found: {s}", .{pat[0..@min(pat.len, 60)]}, true);
        }
    }

    fn findMatch(self: *Editor, fwd: bool) ?Pos {
        const pat = self.last_search.items;
        const lc = self.lineCountB();
        if (fwd) {
            // Current line after the cursor, then wrap through all lines.
            var l = self.cline;
            var from = @min(self.ccol + 1, self.lineLenB(l));
            for (0..lc + 1) |_| {
                const s = self.lineText(l);
                if (std.mem.indexOfPos(u8, s, @min(from, s.len), pat)) |i| return .{ .line = l, .col = i };
                l = (l + 1) % lc;
                from = 0;
            }
            return null;
        }
        // Backward: before the cursor on this line, then wrap backward.
        var l = self.cline;
        var limit: ?usize = self.ccol;
        for (0..lc + 1) |_| {
            const s = self.lineText(l);
            const hay = if (limit) |lim| s[0..@min(lim, s.len)] else s;
            if (std.mem.lastIndexOf(u8, hay, pat)) |i| return .{ .line = l, .col = i };
            l = if (l == 0) lc - 1 else l - 1;
            limit = null;
        }
        return null;
    }

    /// The :q refusal, callable from the app's ⌘W path.
    pub fn setStatusUnsaved(self: *Editor) void {
        self.setStatus("unsaved changes (:w first, or :q! to discard)", .{}, true);
    }

    /// Wheel scroll: move the viewport, dragging the cursor along only
    /// when it would leave the view (vim's scroll feel). Positive =
    /// down (later lines).
    pub fn scroll(self: *Editor, dy: i64) void {
        const lc = self.lineCountB();
        var t: i64 = @intCast(self.top);
        t += dy;
        if (t < 0) t = 0;
        if (t > @as(i64, @intCast(lc - 1))) t = @intCast(lc - 1);
        self.top = @intCast(t);
        const text_rows = @max(1, self.last_rows -| 1);
        if (self.cline < self.top) self.cline = self.top;
        if (self.cline >= self.top + text_rows) self.cline = self.top + text_rows - 1;
        if (self.cline >= lc) self.cline = lc - 1;
        self.clampNormal();
        self.render_dirty = true;
    }

    // ------------------------------------------------------------ selection

    /// Is (line, bcol) inside the visual selection?
    fn selContains(self: *const Editor, line: usize, bcol: usize, abs_line_start: usize) bool {
        if (self.mode != .visual and self.mode != .visual_line) return false;
        const al = @min(self.vanchor_line, self.cline);
        const bl = @max(self.vanchor_line, self.cline);
        if (line < al or line > bl) return false;
        if (self.mode == .visual_line) return true;
        // Charwise: compare absolute offsets, inclusive of the far end.
        const anchor_abs = self.buf.rope.lineStart(self.vanchor_line) + self.vanchor_col;
        const cur_abs = self.buf.rope.lineStart(self.cline) + self.ccol;
        const lo = @min(anchor_abs, cur_abs);
        const hi = @max(anchor_abs, cur_abs);
        const off = abs_line_start + bcol;
        return off >= lo and off <= hi;
    }

    // ------------------------------------------------------------ grid

    fn ensureVisible(self: *Editor, text_cols: usize, text_rows: usize) void {
        if (self.cline < self.top) self.top = self.cline;
        if (self.cline >= self.top + text_rows) self.top = self.cline - text_rows + 1;
        const rc = renderCol(self.lineText(self.cline), self.ccol);
        if (rc < self.left) self.left = rc;
        if (text_cols > 0 and rc >= self.left + text_cols) self.left = rc - text_cols + 1;
    }

    fn digits(n: usize) usize {
        var d: usize = 1;
        var v = n;
        while (v >= 10) : (v /= 10) d += 1;
        return d;
    }

    /// Lay out the full pane grid (gutter + text + status row) into
    /// self.grid, cols*rows RCells. Everything the renderer and ctl
    /// dump need; pure text.
    pub fn fillGrid(self: *Editor, cols: usize, rows: usize) []const RCell {
        const gpa = self.gpa;
        self.last_cols = cols;
        self.last_rows = rows;
        self.grid.resize(gpa, cols * rows) catch return self.grid.items;
        const g = self.grid.items;
        @memset(g, .{});
        if (rows < 2 or cols < 4) return g;

        const gw = digits(self.lineCountB()) + 1;
        const text_cols = cols - @min(gw, cols - 1);
        const text_rows = rows - 1;
        self.ensureVisible(text_cols, text_rows);
        self.refreshHighlights(text_rows);

        const cur_rc = renderCol(self.lineText(self.cline), self.ccol);

        for (0..text_rows) |row| {
            const line = self.top + row;
            const out = g[row * cols ..][0..cols];
            if (line >= self.lineCountB()) {
                out[0] = .{ .cp = '~', .st = .dim };
                continue;
            }

            // Gutter: right-aligned number, dim except the cursor line.
            {
                var nbuf: [20]u8 = undefined;
                const ns = std.fmt.bufPrint(&nbuf, "{d}", .{line + 1}) catch "";
                const pad = gw - 1 -| ns.len;
                for (ns, 0..) |c, i| {
                    if (pad + i < gw) out[pad + i] = .{
                        .cp = c,
                        .st = if (line == self.cline) .text else .dim,
                    };
                }
            }

            const s = self.lineText(line);
            const abs_start = self.buf.rope.lineStart(line);
            var rc: usize = 0;
            var i: usize = 0;
            while (i < s.len) {
                const base = self.hlStyleAt(abs_start + i);
                const st: Style = if (self.selContains(line, i, abs_start)) .sel else base;
                if (s[i] == '\t') {
                    const next = rc / tab_width * tab_width + tab_width;
                    while (rc < next) : (rc += 1) {
                        putText(out, gw, text_cols, self.left, rc, ' ', st);
                    }
                    i += 1;
                    continue;
                }
                const n = cpLenAt(s, i);
                putText(out, gw, text_cols, self.left, rc, decodeAt(s, i), st);
                rc += 1;
                i += n;
            }
            // Search matches tint like a selection (vim hlsearch-ish;
            // :noh clears). Cursor/selection styles win.
            if (self.last_search.items.len > 0) {
                const pat = self.last_search.items;
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, s, from, pat)) |mi| : (from = mi + pat.len) {
                    var bi = mi;
                    while (bi < mi + pat.len and bi < s.len) : (bi += cpLenAt(s, bi)) {
                        const mrc = renderCol(s, bi);
                        if (mrc >= self.left and mrc - self.left < text_cols) {
                            const cell = &out[gw + (mrc - self.left)];
                            if (cell.st != .cursor and cell.st != .sel) cell.st = .sel;
                        }
                    }
                }
            }

            // Visual-line selection tints the whole used row even past EOL.
            if (self.mode == .visual_line and self.selContains(line, 0, abs_start) and rc == 0) {
                putText(out, gw, text_cols, self.left, 0, ' ', .sel);
            }

            // Cursor (block) — in command mode it sits on the status row.
            if (line == self.cline and self.mode != .command) {
                if (cur_rc >= self.left and cur_rc - self.left < text_cols) {
                    out[gw + (cur_rc - self.left)].st = .cursor;
                }
            }
        }

        self.fillStatusRow(g[(rows - 1) * cols ..][0..cols]);
        return g;
    }

    fn putText(out: []RCell, gw: usize, text_cols: usize, left: usize, rc: usize, cp: u21, st: Style) void {
        if (rc < left or rc - left >= text_cols) return;
        out[gw + (rc - left)] = .{ .cp = cp, .st = st };
    }

    /// Reparse on buffer-version change, then bake the VISIBLE byte
    /// range's capture spans into a per-byte style table (later spans
    /// override — nvim's convention).
    fn refreshHighlights(self: *Editor, text_rows: usize) void {
        const reparse = self.hl_reparse orelse return;
        const gpa = self.gpa;
        const rope = &self.buf.rope;

        if (self.buf.version != self.hl_version) {
            // Full reparse, size-capped; ts_tree_edit is the upgrade
            // path if this ever shows in frame_fill.
            if (rope.byteLen() <= 4 << 20) {
                if (rope.dupeRange(gpa, 0, rope.byteLen()) catch null) |flat| {
                    defer gpa.free(flat);
                    reparse(self.hl_ctx.?, flat);
                    self.hl_version = self.buf.version;
                }
            } else return;
        }

        const lc = self.lineCountB();
        const vstart = rope.lineStart(@min(self.top, lc - 1));
        const last_line = @min(self.top + text_rows, lc) - 1;
        const vend = rope.lineEnd(last_line);
        self.hl_vstart = vstart;

        self.hl_styles.resize(gpa, vend - vstart) catch return;
        @memset(self.hl_styles.items, .text);
        self.hl_spans_buf.clearRetainingCapacity();
        if (self.hl_spans) |f| f(self.hl_ctx.?, @intCast(vstart), @intCast(vend), &self.hl_spans_buf, gpa);
        for (self.hl_spans_buf.items) |sp| {
            const a = @max(@as(usize, sp.start), vstart) - vstart;
            const b = @min(@as(usize, sp.end), vend) - vstart;
            if (a >= b) continue;
            @memset(self.hl_styles.items[a..b], sp.st);
        }
    }

    fn hlStyleAt(self: *const Editor, abs: usize) Style {
        if (self.hl_reparse == null) return .text;
        const rel = abs -% self.hl_vstart;
        if (rel >= self.hl_styles.items.len) return .text;
        return self.hl_styles.items[rel];
    }

    fn fillStatusRow(self: *Editor, out: []RCell) void {
        for (out) |*c| c.* = .{ .cp = ' ', .st = .status };

        var x: usize = 0;
        if (self.mode == .command) {
            putStr(out, &x, if (self.cmd_kind == .search) "/" else ":", .status);
            for (self.cmd.items) |c| {
                if (x >= out.len) break;
                out[x] = .{ .cp = c, .st = .status };
                x += 1;
            }
            if (x < out.len) out[x].st = .cursor;
            return;
        }

        const mode_str: []const u8 = switch (self.mode) {
            .normal => " NORMAL ",
            .insert => if (self.replacing) " REPLACE " else " INSERT ",
            .visual => " VISUAL ",
            .visual_line => " V-LINE ",
            .command => unreachable,
        };
        putStr(out, &x, mode_str, .mode);
        x += 1;
        if (self.macro_reg != 0) {
            putStr(out, &x, "recording @", .err);
            putStr(out, &x, &[1]u8{self.macro_reg}, .err);
            x += 1;
        }
        if (self.status_len > 0) {
            putStr(out, &x, self.status_buf[0..self.status_len], if (self.status_err) .err else .text);
        } else {
            putStr(out, &x, self.displayName(), .text);
            if (self.buf.isModified()) putStr(out, &x, " [+]", .dim);
            // A line the editor cannot reach the end of used to render
            // exactly like a line that had ended. Silence was the real
            // defect here — worse than the wall itself.
            if (self.lineClamped(self.cline)) putStr(out, &x, " [long line]", .err);
            // Both marks, both meaningful: [+] is your edit, [!] is
            // somebody else's, and seeing them together is exactly the
            // moment to decide which one survives.
            if (self.disk_changed) putStr(out, &x, " [!] changed on disk", .err);
        }

        // Right side: line:col.
        var rbuf: [32]u8 = undefined;
        const rs = std.fmt.bufPrint(&rbuf, "{d}:{d} ", .{
            self.cline + 1,
            renderCol(self.lineText(self.cline), self.ccol) + 1,
        }) catch return;
        if (rs.len < out.len) {
            var rx = out.len - rs.len;
            putStr(out, &rx, rs, .status);
        }
    }

    /// Lay a string into the status row, ONE CELL PER CODEPOINT.
    ///
    /// It used to be one cell per BYTE, with the byte stored as if it
    /// were a codepoint — so every non-ASCII character in the status
    /// row came out as two or three wrong glyphs. Found by an em-dash
    /// in a status message rendering as `â`, but the case that
    /// matters is a filename: open `résumé.txt` and the name of the
    /// file you are editing is mojibake.
    ///
    /// Invalid bytes become U+FFFD rather than being skipped, so a
    /// filename that is not valid UTF-8 still occupies the width it
    /// takes and the rest of the row does not slide left.
    fn putStr(out: []RCell, x: *usize, s: []const u8, st: Style) void {
        var i: usize = 0;
        while (i < s.len) : (i += cpLenAt(s, i)) {
            if (x.* >= out.len) return;
            out[x.*] = .{ .cp = decodeAt(s, i), .st = st };
            x.* += 1;
        }
    }

    /// The grid as plain text — ctl dump's editor answer, and what the
    /// tests assert on.
    pub fn dumpText(self: *Editor, gpa: Allocator, cols: usize, rows: usize) ![]u8 {
        const g = self.fillGrid(cols, rows);
        var outl: std.ArrayListUnmanaged(u8) = .empty;
        errdefer outl.deinit(gpa);
        var enc: [4]u8 = undefined;
        for (0..rows) |row| {
            var line_end = cols;
            const cells = g[row * cols ..][0..cols];
            while (line_end > 0 and cells[line_end - 1].cp == ' ') line_end -= 1;
            for (cells[0..line_end]) |c| {
                const n = std.unicode.utf8Encode(c.cp, &enc) catch continue;
                try outl.appendSlice(gpa, enc[0..n]);
            }
            try outl.append(gpa, '\n');
        }
        return outl.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn mkEditor(gpa: Allocator) !*Editor {
    return Editor.create(gpa, testing.io, null);
}

fn keys(e: *Editor, s: []const u8) void {
    for (s) |c| e.key(&[1]u8{c});
}

fn bufText(gpa: Allocator, e: *Editor) ![]u8 {
    return e.buf.rope.dupeRange(gpa, 0, e.buf.rope.byteLen());
}

test "insert mode basics" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();

    keys(e, "ihello");
    e.key("\r");
    keys(e, "world");
    e.key("\x1b");

    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("hello\nworld", s);
    try testing.expectEqual(Mode.normal, e.mode);
    try testing.expectEqual(@as(usize, 1), e.cline);
    try testing.expectEqual(@as(usize, 4), e.ccol); // on 'd' after ESC
}

test "motions hjkl w b e 0 $ gg G" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar_baz  qux\nsecond line\nthird");
    e.key("\x1b");
    keys(e, "gg0");
    try testing.expectEqual(@as(usize, 0), e.cline);
    try testing.expectEqual(@as(usize, 0), e.ccol);
    keys(e, "w");
    try testing.expectEqual(@as(usize, 4), e.ccol); // bar_baz
    keys(e, "w");
    try testing.expectEqual(@as(usize, 13), e.ccol); // qux
    keys(e, "b");
    try testing.expectEqual(@as(usize, 4), e.ccol);
    keys(e, "e");
    try testing.expectEqual(@as(usize, 10), e.ccol); // end of bar_baz
    keys(e, "$");
    try testing.expectEqual(@as(usize, 15), e.ccol); // on 'x' (last cp)
    keys(e, "j0");
    try testing.expectEqual(@as(usize, 1), e.cline);
    keys(e, "G");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "gg");
    try testing.expectEqual(@as(usize, 0), e.cline);
    keys(e, "2j");
    try testing.expectEqual(@as(usize, 2), e.cline);
}

test "dd dw x undo redo" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two\nthree\nfour");
    e.key("\x1b");
    keys(e, "gg");

    keys(e, "dw"); // delete "one "
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("two\nthree\nfour", s);
    gpa.free(s);

    keys(e, "dd");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("three\nfour", s);
    gpa.free(s);

    keys(e, "x");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("hree\nfour", s);
    gpa.free(s);

    keys(e, "u");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("three\nfour", s);
    gpa.free(s);

    keys(e, "uu");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("one two\nthree\nfour", s);
    gpa.free(s);

    e.key(&[1]u8{0x12}); // ctrl-r
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("two\nthree\nfour", s);
    gpa.free(s);
}

test "yank paste linewise and charwise" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ialpha\nbeta\ngamma");
    e.key("\x1b");
    keys(e, "ggyy"); // yank "alpha\n"
    try testing.expect(e.reg_linewise);
    keys(e, "Gp"); // paste after last line
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\nalpha", s);
    gpa.free(s);

    keys(e, "gg0vey"); // charwise yank "alpha"
    try testing.expect(!e.reg_linewise);
    keys(e, "$p");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("alphaalpha\nbeta\ngamma\nalpha", s);
    gpa.free(s);
}

test "cw and cc enter insert" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar\nbaz");
    e.key("\x1b");
    keys(e, "gg0cwnew");
    e.key("\x1b");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("new bar\nbaz", s);
    gpa.free(s);

    keys(e, "jccreplaced");
    e.key("\x1b");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("new bar\nreplaced", s);
    gpa.free(s);
}

test "visual charwise delete and visual line yank" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef\nsecond");
    e.key("\x1b");
    keys(e, "gg0v2ld"); // select a,b,c delete
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("def\nsecond", s);
    gpa.free(s);

    keys(e, "Vy"); // yank line "def\n"
    keys(e, "jp");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("def\nsecond\ndef", s);
    gpa.free(s);
}

test "command mode goto and unknown" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\nc\nd");
    e.key("\x1b");
    keys(e, ":3");
    e.key("\r");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, ":nope");
    e.key("\r");
    try testing.expect(e.status_len > 0);
    try testing.expect(e.status_err);
}

test "q with unsaved changes refuses, q! closes" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ix");
    e.key("\x1b");
    keys(e, ":q");
    e.key("\r");
    try testing.expect(!e.closed);
    try testing.expect(e.status_err);
    keys(e, ":q!");
    e.key("\r");
    try testing.expect(e.closed);
}

test "grid renders text gutter cursor and status" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ihello\nworld");
    e.key("\x1b");
    keys(e, "gg0");

    const dump = try e.dumpText(gpa, 32, 5);
    defer gpa.free(dump);
    var it = std.mem.splitScalar(u8, dump, '\n');
    const r0 = it.next().?;
    const r1 = it.next().?;
    const r2 = it.next().?;
    _ = it.next().?; // empty row 3 ('~' row visual only when past EOF... row3 is '~')
    const status = it.next().?;
    try testing.expectEqualStrings("1 hello", r0);
    try testing.expectEqualStrings("2 world", r1);
    try testing.expectEqualStrings("~", r2);
    try testing.expect(std.mem.indexOf(u8, status, "NORMAL") != null);
    try testing.expect(std.mem.indexOf(u8, status, "[scratch]") != null);
    try testing.expect(std.mem.indexOf(u8, status, "1:1") != null);

    // Cursor cell marked in the grid.
    const g = e.fillGrid(32, 5);
    try testing.expectEqual(Style.cursor, g[2].st); // row 0, after "1 " gutter
}

test "replace r and join J" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc\n  def");
    e.key("\x1b");
    keys(e, "gg0rx");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("xbc\n  def", s);
    gpa.free(s);
    keys(e, "J");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("xbc def", s);
    gpa.free(s);
}

test "D C and o O" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar");
    e.key("\x1b");
    keys(e, "gg0llD");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("fo", s);
    gpa.free(s);
    keys(e, "obelow");
    e.key("\x1b");
    keys(e, "kOabove");
    e.key("\x1b");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("above\nfo\nbelow", s);
    gpa.free(s);
}

test "scroll keeps cursor visible" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    e.key("i");
    for (0..50) |i| {
        var b: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "L{d}\r", .{i}) catch unreachable;
        for (s) |c| e.key(&[1]u8{c});
    }
    e.key("\x1b");
    keys(e, "G");
    _ = e.fillGrid(20, 10);
    // Cursor line (50) must be within [top, top+9).
    try testing.expect(e.cline >= e.top and e.cline < e.top + 9);
    keys(e, "gg");
    _ = e.fillGrid(20, 10);
    try testing.expectEqual(@as(usize, 0), e.top);
}

test "search jump wrap and n/N" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ialpha beta\ngamma\nbeta again");
    e.key("\x1b");
    keys(e, "gg0");
    keys(e, "/beta");
    e.key("\r");
    try testing.expectEqual(@as(usize, 0), e.cline);
    try testing.expectEqual(@as(usize, 6), e.ccol);
    keys(e, "n");
    try testing.expectEqual(@as(usize, 2), e.cline);
    try testing.expectEqual(@as(usize, 0), e.ccol);
    keys(e, "n"); // wraps back to line 0
    try testing.expectEqual(@as(usize, 0), e.cline);
    keys(e, "N"); // backward → line 2 again
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "/nosuch");
    e.key("\r");
    try testing.expect(e.status_err);

    // Highlight shows in the grid; :noh clears it.
    keys(e, "/beta");
    e.key("\r");
    const g = e.fillGrid(30, 6);
    var hl: usize = 0;
    for (g) |c| {
        if (c.st == .sel) hl += 1;
    }
    try testing.expect(hl >= 7); // two visible "beta"s (cursor eats one cell)
    keys(e, ":noh");
    e.key("\r");
    const g2 = e.fillGrid(30, 6);
    var hl2: usize = 0;
    for (g2) |c| {
        if (c.st == .sel) hl2 += 1;
    }
    try testing.expectEqual(@as(usize, 0), hl2);
}

test "directory buffer: listing, enter opens, dash climbs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&pathbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "hello dir\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "first\n" });

    var e = try Editor.create(gpa, io, root);
    defer e.destroy();
    try testing.expect(e.is_dir);

    // "../", dirs first, then files alphabetically.
    const text = try bufText(gpa, e);
    defer gpa.free(text);
    try testing.expectEqualStrings("../\nsub/\nalpha.txt\nbeta.txt", text);

    // :w refuses on a listing.
    keys(e, ":w");
    e.key("\r");
    try testing.expect(e.status_err);

    // Enter on beta.txt (line 3) opens the file.
    keys(e, "3j");
    e.key("\r");
    try testing.expect(!e.is_dir);
    const ft = try bufText(gpa, e);
    defer gpa.free(ft);
    try testing.expectEqualStrings("hello dir\n", ft);

    // `-` from the file: back to the listing, cursor ON beta.txt.
    keys(e, "-");
    try testing.expect(e.is_dir);
    try testing.expectEqual(@as(usize, 3), e.cline);

    // Enter descends into sub/ (empty: just "../").
    keys(e, "gg");
    keys(e, "j");
    e.key("\r");
    try testing.expect(e.is_dir);
    const st = try bufText(gpa, e);
    defer gpa.free(st);
    try testing.expectEqualStrings("../", st);

    // ".." climbs back up, cursor on sub/.
    e.key("\r");
    try testing.expect(e.is_dir);
    try testing.expectEqual(@as(usize, 1), e.cline);
}

test "the status row is codepoints, not bytes" {
    // It used to lay one cell per BYTE with the byte stored as a
    // codepoint, so any non-ASCII in the status row — a filename most
    // of all — rendered as two or three wrong glyphs.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    e.setStatus("café — dash", .{}, false);
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "café — dash") != null);
}

test "an invalid byte in the status row keeps its width" {
    // U+FFFD rather than a skip: dropping it would slide the rest of
    // the row left and quietly misreport the columns.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    e.setStatus("a{s}b", .{"\xff"}, false);
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "a\u{FFFD}b") != null);
}

test "a binary file renders as replacement chars, one per bad byte" {
    // Not `ÿ`: `utf8Decode` hands a one-byte slice straight back
    // without validating it, so the obvious `catch 0xFFFD` is dead
    // code. One cell per undecodable byte also keeps the width right,
    // which is what stops the cursor column from drifting off what was
    // actually drawn.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try e.buf.insert(gpa, 0, "a\xff\xfeb\n");
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "a\u{FFFD}\u{FFFD}b") != null);
}

test "a truncated sequence at end of line does not overshoot" {
    // A 3-byte lead with only one byte left must advance by ONE, or the
    // render loop steps past the line while renderCol steps inside it.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try e.buf.insert(gpa, 0, "ok\xe2\n");
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "ok\u{FFFD}") != null);
}

/// A line longer than the clamp, for the crash tests below.
fn longLine(gpa: Allocator, e: *Editor, n: usize) !void {
    const long = try gpa.alloc(u8, n);
    defer gpa.free(long);
    @memset(long, 'x');
    try e.buf.insert(gpa, 0, long);
}

test "A on a line past the clamp does not abort the app" {
    // `A` assigned the REAL line length to a column that indexes a
    // TRUNCATED copy, so the next keystroke read off the end of the
    // slice and killed the process with the buffer in it. One `A`, one
    // character, one ESC was the whole recipe.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try longLine(gpa, e, max_line + 900);
    keys(e, "A");
    try testing.expect(e.ccol <= max_line);
    keys(e, "z");
    keys(e, "\x1b");
    try testing.expect(e.ccol <= max_line);
}

test "backspace joining onto a long line does not abort the app" {
    // The same defect through the other door, and this one needs no
    // long line on screen at all — just a long line ABOVE the cursor.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try longLine(gpa, e, max_line + 900);
    try e.buf.insert(gpa, max_line + 900, "\nsecond\n");
    e.cline = 1;
    e.ccol = 0;
    keys(e, "i");
    keys(e, "\x7f");
    try testing.expect(e.ccol <= max_line);
    keys(e, "\x1b");
    try testing.expect(e.ccol <= max_line);
}

test "typing at the clamp is refused, not dropped mid-line" {
    // Inserting with the cursor pinned would put every further
    // keystroke at the same offset in the MIDDLE of a line you cannot
    // see — silent corruption wearing a stuck cursor as a disguise.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try longLine(gpa, e, max_line + 900);
    const before = e.buf.rope.byteLen();
    keys(e, "A");
    keys(e, "nope");
    try testing.expectEqual(before, e.buf.rope.byteLen());
    const status = e.status_buf[0..e.status_len];
    try testing.expect(std.mem.indexOf(u8, status, "too long") != null);
}

test "a clamped line says so, in the row and in the status" {
    // Silence is the actual defect: a truncated line rendered exactly
    // like a line that had ended.
    const gpa = testing.allocator;
    const e = try mkEditor(gpa);
    defer e.destroy();
    try longLine(gpa, e, max_line + 900);
    try e.buf.insert(gpa, max_line + 900, "\nshort\n");
    try testing.expect(e.lineClamped(0));
    try testing.expect(!e.lineClamped(1));
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "long line") != null);
}

test "o O and Enter inherit the indent" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();

    keys(e, "i    alpha");
    e.key("\r");
    keys(e, "beta");
    e.key("\x1b");
    keys(e, "ogamma");
    e.key("\x1b");
    keys(e, "ggOzero");
    e.key("\x1b");

    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings(
        "    zero\n    alpha\n    beta\n    gamma",
        s,
    );
}

test "an indent nobody typed on is taken back" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();

    keys(e, "i\tdeep");
    e.key("\x1b");

    // `o` then ESC: the line is empty, not a tab of trailing space.
    keys(e, "o");
    try testing.expectEqual(@as(usize, 1), e.ccol); // indent is there while typing
    e.key("\x1b");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("\tdeep\n", s);
    gpa.free(s);

    // Enter on a fresh `o` leaves the skipped line bare but keeps
    // handing the indent forward.
    keys(e, "kA");
    e.key("\r");
    e.key("\r");
    keys(e, "x");
    e.key("\x1b");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("\tdeep\n\n\tx\n", s);
    gpa.free(s);
}

test "typing on an inherited indent keeps it" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i  a");
    e.key("\x1b");
    keys(e, "ob");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("  a\n  b", s);
}

test "shift right and left respell the indent in the file's currency" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();

    // A space-indented buffer: the unit is spaces.
    keys(e, "i    one");
    e.key("\r");
    keys(e, "two");
    e.key("\x1b");
    keys(e, "gg>>");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("        one\n    two", s);
    gpa.free(s);

    keys(e, "<<<<");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("one\n    two", s);
    gpa.free(s);

    // `<<` at column zero is a floor, not an underflow.
    keys(e, "<<");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("one\n    two", s);
    gpa.free(s);
}

test "a tab-indented buffer shifts with tabs" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i\tfunc()");
    e.key("\r");
    keys(e, "body"); // the tab comes from the line above
    e.key("\x1b");
    keys(e, "gg>>");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("\t\tfunc()\n\tbody", s);
}

test "a shift over a range is one undo, and skips blank lines" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia");
    e.key("\r");
    e.key("\r");
    keys(e, "c");
    e.key("\x1b");
    keys(e, "gg3>>");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("    a\n\n    c", s); // blank line untouched
    gpa.free(s);

    keys(e, "u");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("a\n\nc", s);
    gpa.free(s);
}

test "visual line shift covers the selection" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione");
    e.key("\r");
    keys(e, "two");
    e.key("\r");
    keys(e, "three");
    e.key("\x1b");
    keys(e, "ggVj>");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("    one\n    two\nthree", s);
    try testing.expectEqual(Mode.normal, e.mode);
}

test "cc retypes the line without moving it to column zero" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i        deep");
    e.key("\x1b");
    keys(e, "ccnew");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("        new", s);
}

test "a header of unindented lines does not hide the file's tabs" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i");
    for (0..250) |_| { // longer than any flat first-N-lines window
        keys(e, "package");
        e.key("\r");
    }
    keys(e, "\tbody");
    e.key("\x1b");
    try testing.expectEqualStrings("\t", e.indentUnit());
}

test "f F t T move within the line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione,two,three");
    e.key("\x1b");
    keys(e, "0");

    keys(e, "f,");
    try testing.expectEqual(@as(usize, 3), e.ccol);
    keys(e, "f,");
    try testing.expectEqual(@as(usize, 7), e.ccol);
    keys(e, "F,");
    try testing.expectEqual(@as(usize, 3), e.ccol);
    keys(e, "t,");
    try testing.expectEqual(@as(usize, 6), e.ccol); // one short of the second
    keys(e, "0T,");
    try testing.expectEqual(@as(usize, 0), e.ccol); // nothing before it: no move
    keys(e, "$T,");
    try testing.expectEqual(@as(usize, 8), e.ccol); // one past the second

    // A character that is not on the line moves nothing.
    keys(e, "0fz");
    try testing.expectEqual(@as(usize, 0), e.ccol);
}

test "counts, ; and , repeat a find" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia.b.c.d");
    e.key("\x1b");
    keys(e, "0");

    keys(e, "2f.");
    try testing.expectEqual(@as(usize, 3), e.ccol);
    keys(e, ";");
    try testing.expectEqual(@as(usize, 5), e.ccol);
    keys(e, ",");
    try testing.expectEqual(@as(usize, 3), e.ccol);

    // `;` after `t` must ADVANCE — the cursor is already parked one
    // short, so a plain re-search would find the same target.
    keys(e, "0t.");
    try testing.expectEqual(@as(usize, 0), e.ccol);
    keys(e, ";");
    try testing.expectEqual(@as(usize, 2), e.ccol);
    keys(e, ";");
    try testing.expectEqual(@as(usize, 4), e.ccol);
}

test "operators take f and t, inclusive one way only" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();

    keys(e, "ifoo(bar)baz");
    e.key("\x1b");
    keys(e, "0f(l"); // inside the parens
    keys(e, "dt)");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("foo()baz", s);
    gpa.free(s);

    keys(e, "0df(");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings(")baz", s); // f is inclusive
    gpa.free(s);

    // A find that fails cancels the operator instead of deleting to
    // somewhere arbitrary.
    keys(e, "0dfQ");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings(")baz", s);
    gpa.free(s);
    try testing.expectEqual(@as(u8, 0), e.op);
}

test "a digit after f is a character to find, not a count" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iab2cd");
    e.key("\x1b");
    keys(e, "0f2");
    try testing.expectEqual(@as(usize, 2), e.ccol);
    try testing.expectEqual(@as(u32, 0), e.count);
}

test "f on a non-ASCII target does not stay armed" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcd");
    e.key("\x1b");
    keys(e, "0f");
    e.key("é"); // not reachable today
    try testing.expectEqual(@as(u8, 0), e.pend_find);
    keys(e, "l"); // must be a motion, not a find target
    try testing.expectEqual(@as(usize, 1), e.ccol);
}

test "ciw diw and aw" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two three");
    e.key("\x1b");

    keys(e, "0wciwTWO");
    e.key("\x1b");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("one TWO three", s);
    gpa.free(s);

    // `aw` takes the whitespace after the word.
    keys(e, "0daw");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("TWO three", s);
    gpa.free(s);

    // The last word on a line has no trailing space, so `aw` takes the
    // leading one instead — otherwise `daw` leaves a dangling space.
    keys(e, "$daw");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("TWO", s);
    gpa.free(s);

    // `iw` on whitespace is the whitespace run, not the next word.
    keys(e, "cca   b");
    e.key("\x1b");
    keys(e, "0lldiw");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("ab", s);
    gpa.free(s);
}

test "bracket objects nest and cross lines" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifn(a, g(b), c)");
    e.key("\x1b");

    // Inside the INNER call: the nearest enclosing pair wins.
    keys(e, "0fbdi(");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("fn(a, g(), c)", s);
    gpa.free(s);

    // Parked ON the open paren counts as inside it.
    keys(e, "0f(di(");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("fn()", s);
    gpa.free(s);

    // `a{` over a body that spans lines.
    keys(e, "ccif x {");
    e.key("\r");
    keys(e, "body");
    e.key("\r");
    keys(e, "}");
    e.key("\x1b");
    keys(e, "ggjda{"); // inside the braces, as vim requires
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("if x ", s);
    gpa.free(s);
}

test "sitting on a closing bracket means that pair, not the one outside" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifn(a, g(b), c)");
    e.key("\x1b");
    // The inner `)`. Searching backward from PAST the cursor would
    // count it as a nesting level and hand back the outer pair, which
    // deletes strictly more than was asked for.
    keys(e, "0f)di(");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("fn(a, g(), c)", s);
}

test "quote objects are line-local and take the whole string" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ilet a = \"hello\" + x");
    e.key("\x1b");

    keys(e, "0ci\"bye");
    e.key("\x1b");
    var s = try bufText(gpa, e);
    try testing.expectEqualStrings("let a = \"bye\" + x", s);
    gpa.free(s);

    // `a"` eats the trailing space, so `da"` leaves no orphan.
    keys(e, "0da\"");
    s = try bufText(gpa, e);
    try testing.expectEqualStrings("let a = + x", s);
    gpa.free(s);
}

test "a text object that is not there cancels the operator" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ino brackets here");
    e.key("\x1b");
    keys(e, "0di(");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("no brackets here", s);
    try testing.expectEqual(@as(u8, 0), e.op);
    try testing.expectEqual(Mode.normal, e.mode);
}

test "i and a still enter insert with nothing pending" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iab");
    e.key("\x1b");
    keys(e, "0iX");
    e.key("\x1b");
    keys(e, "$aY");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("XabY", s);
}

test "visual mode selects a text object" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two three");
    e.key("\x1b");
    keys(e, "0wviwd");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one  three", s);
}

// ------------------------------------------------------------------ dot repeat

test "dot repeats a charwise change" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "0x..");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("def", s);
}

test "dot repeats a change that ended in insert mode" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two three");
    e.key("\x1b");
    keys(e, "0cwX");
    e.key("\x1b");
    keys(e, "w.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("X X three", s);
}

test "dot repeats a linewise change" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree\nfour");
    e.key("\x1b");
    keys(e, "ggdd.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("three\nfour", s);
}

test "dot repeats an open-line insert" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione");
    e.key("\x1b");
    keys(e, "otwo");
    e.key("\x1b");
    keys(e, ".");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\ntwo\ntwo", s);
}

test "dot repeats a visual delete" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdefgh");
    e.key("\x1b");
    keys(e, "0vld.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("efgh", s);
}

test "motions and yanks do not become the dot" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc def");
    e.key("\x1b");
    keys(e, "0x"); // dot = x
    keys(e, "wyy"); // a motion and a yank in between
    keys(e, "0.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("c def", s);
}

test "undo does not become the dot" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcd");
    e.key("\x1b");
    keys(e, "0xu.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("bcd", s);
}

test "a count on dot replaces the recorded one" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdefghij");
    e.key("\x1b");
    keys(e, "03x"); // abc gone
    keys(e, "2."); // de gone, not another three
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("fghij", s);
}

test "dot repeats a shift" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo");
    e.key("\x1b");
    keys(e, "gg>>.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("        one\ntwo", s);
}

test "dot repeats an operator over a text object" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two three");
    e.key("\x1b");
    keys(e, "0daw.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("three", s);
}

// ------------------------------------------------------------ registers, marks

test "a named register keeps its text across an unrelated delete" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "gg\"ayy"); // a = "one\n"
    keys(e, "jdd"); // unnamed = "two\n", a untouched
    keys(e, "\"ap");
    keys(e, "p");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\nthree\none\ntwo", s);
}

test "an uppercase register appends" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "gg\"ayy");
    keys(e, "j\"Ayy");
    keys(e, "G\"ap");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\ntwo\nthree\none\ntwo", s);
}

test "the black hole register deletes without clobbering the unnamed one" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "ggyy"); // unnamed = "one\n"
    keys(e, "j\"_dd"); // "two" gone, unnamed still "one\n"
    keys(e, "p");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\nthree\none", s);
}

test "a register selection survives exactly one command" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo");
    e.key("\x1b");
    keys(e, "gg\"a"); // armed...
    keys(e, "j"); // ...and spent on a motion that does not want it
    keys(e, "yy"); // so this goes to the unnamed register only
    keys(e, "\"ap"); // register a is empty: nothing to paste
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\ntwo", s);
}

test "a count on p pastes that many copies" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo");
    e.key("\x1b");
    keys(e, "ggyy3p");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\none\none\none\ntwo", s);
}

test "a mark remembers the exact column; the quote form takes first non-blank" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i    hello\nworld");
    e.key("\x1b");
    keys(e, "ggfoma");
    try testing.expectEqual(@as(usize, 8), e.ccol);
    keys(e, "G");
    keys(e, "`a");
    try testing.expectEqual(@as(usize, 0), e.cline);
    try testing.expectEqual(@as(usize, 8), e.ccol);
    keys(e, "G'a");
    try testing.expectEqual(@as(usize, 0), e.cline);
    try testing.expectEqual(@as(usize, 4), e.ccol);
}

test "backtick mark is a charwise motion for an operator" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "0ma$d`a");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("f", s);
}

test "quote mark is a linewise motion for an operator" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree\nfour");
    e.key("\x1b");
    keys(e, "ggjmaGd'a");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one", s);
}

test "an unset mark cancels the operator instead of guessing" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "$d`z");
    // The point is not just that nothing was deleted — it is that the
    // `d` did not stay armed to eat whatever you press next.
    keys(e, "0l");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abcdef", s);
}

test "backtick backtick returns from a jump, and back again" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree\nfour");
    e.key("\x1b");
    keys(e, "ggG");
    try testing.expectEqual(@as(usize, 3), e.cline);
    keys(e, "``");
    try testing.expectEqual(@as(usize, 0), e.cline);
    keys(e, "``");
    try testing.expectEqual(@as(usize, 3), e.cline);
}

// -------------------------------------------------------------- motion round

test "percent jumps to the match and back" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo(bar[baz])end");
    e.key("\x1b");
    keys(e, "0%");
    try testing.expectEqual(@as(usize, 12), e.ccol);
    keys(e, "%");
    try testing.expectEqual(@as(usize, 3), e.ccol);
}

test "d percent takes everything from the cursor through the match" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo(bar[baz])end");
    e.key("\x1b");
    keys(e, "0d%");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("end", s);
}

test "paragraph motions land on the blank line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\n\nc\nd\n\ne");
    e.key("\x1b");
    keys(e, "gg}");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "}");
    try testing.expectEqual(@as(usize, 5), e.cline);
    keys(e, "{");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "{");
    try testing.expectEqual(@as(usize, 0), e.cline);
}

test "d brace-close stops at the blank line without eating it" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\n\nc\nd");
    e.key("\x1b");
    keys(e, "ggd}");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("\nc\nd", s);
}

test "star searches the word under the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar\nbaz foo");
    e.key("\x1b");
    keys(e, "gg0*");
    try testing.expectEqual(@as(usize, 1), e.cline);
    try testing.expectEqual(@as(usize, 4), e.ccol);
    keys(e, "#");
    try testing.expectEqual(@as(usize, 0), e.cline);
    try testing.expectEqual(@as(usize, 0), e.ccol);
}

test "star from mid-word takes the whole word" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ihello bar\nbaz hello");
    e.key("\x1b");
    keys(e, "gg0ll*"); // sitting on the second l of hello
    try testing.expectEqual(@as(usize, 1), e.cline);
    try testing.expectEqual(@as(usize, 4), e.ccol);
    try testing.expectEqualStrings("hello", e.last_search.items);
}

test "ge walks back to the end of the previous word" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar baz");
    e.key("\x1b");
    keys(e, "$ge");
    try testing.expectEqual(@as(usize, 6), e.ccol);
    keys(e, "ge");
    try testing.expectEqual(@as(usize, 2), e.ccol);
}

test "dge is inclusive at both ends" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar baz");
    e.key("\x1b");
    keys(e, "$dge");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo ba", s);
}

test "H M L move within the window" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12");
    e.key("\x1b");
    keys(e, "gg");
    _ = e.fillGrid(20, 6); // 5 text rows: lines 0..4 visible
    keys(e, "L");
    try testing.expectEqual(@as(usize, 4), e.cline);
    keys(e, "H");
    try testing.expectEqual(@as(usize, 0), e.cline);
    keys(e, "M");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "3H");
    try testing.expectEqual(@as(usize, 2), e.cline);
    keys(e, "2L");
    try testing.expectEqual(@as(usize, 3), e.cline);
}

test "zt zz zb move the window, not the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20");
    e.key("\x1b");
    _ = e.fillGrid(20, 6); // 5 text rows
    keys(e, "10G");
    try testing.expectEqual(@as(usize, 9), e.cline);
    keys(e, "zt");
    try testing.expectEqual(@as(usize, 9), e.top);
    keys(e, "zb");
    try testing.expectEqual(@as(usize, 5), e.top);
    keys(e, "zz");
    try testing.expectEqual(@as(usize, 7), e.top);
    try testing.expectEqual(@as(usize, 9), e.cline);
}

// ---------------------------------------------------------------- edit round

test "s substitutes count characters" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "03sXY");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("XYdef", s);
}

test "s on an empty line still enters insert" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\n\ntwo");
    e.key("\x1b");
    keys(e, "ggjsX");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\nX\ntwo", s);
}

test "S changes count lines" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "gg2SX");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("X\nthree", s);
}

test "X deletes before the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "0lll2X");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("adef", s);
}

test "X at column zero does nothing" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc\ndef");
    e.key("\x1b");
    keys(e, "j0X");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abc\ndef", s);
}

test "tilde toggles count characters and advances" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "03~");
    try testing.expectEqual(@as(usize, 3), e.ccol);
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("ABCdef", s);
}

test "tilde clamps at the end of the line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "0~~~");
    try testing.expectEqual(@as(usize, 2), e.ccol);
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("ABC", s);
}

test "gU over a motion, and gUU over the line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar\nbaz qux");
    e.key("\x1b");
    keys(e, "gg0gUw");
    keys(e, "jgUU");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("FOO bar\nBAZ QUX", s);
}

test "gu and the gugu spelling both take the line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iFOO BAR");
    e.key("\x1b");
    keys(e, "gggugu");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo bar", s);
}

test "g tilde over a text object flips the case in place" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iFoo bar");
    e.key("\x1b");
    keys(e, "0g~w");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("fOO bar", s);
}

test "a case operator leaves the register alone" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "ggyy"); // unnamed = "one\n"
    keys(e, "jgUU"); // TWO, and the register must not have moved
    keys(e, "p");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\nTWO\none\nthree", s);
}

test "visual u lowercases the selection" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iFOO BAR BAZ");
    e.key("\x1b");
    keys(e, "0vwwu");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo bar bAZ", s);
}

test "visual line U uppercases whole lines" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\nbar");
    e.key("\x1b");
    keys(e, "ggVjU");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("FOO\nBAR", s);
}

test "a count on J joins that many lines" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\nc\nd");
    e.key("\x1b");
    keys(e, "gg3J");
    try testing.expectEqual(@as(usize, 3), e.ccol);
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a b c\nd", s);
}

test "gJ joins without a space and keeps the indent" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\n");
    keys(e, "   bar");
    e.key("\x1b");
    keys(e, "gggJ");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo   bar", s);
}

test "R overwrites, and backspace puts back what it took" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "0RXY");
    {
        const s = try bufText(gpa, e);
        defer gpa.free(s);
        try testing.expectEqualStrings("XYcdef", s);
    }
    e.key("\x7f");
    e.key("\x7f");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abcdef", s);
}

test "R past the end of the line is just insert" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iab");
    e.key("\x1b");
    keys(e, "0RXYZ");
    e.key("\x7f");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("XY", s);
}

test "backspacing past the start of an R just moves" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "$RX");
    e.key("\x7f"); // pays back the 'f'
    e.key("\x7f"); // owes nothing now, so it only moves
    try testing.expectEqual(@as(usize, 4), e.ccol);
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abcdef", s);
}

test "the status row says REPLACE" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "0R");
    const dump = try e.dumpText(gpa, 40, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "REPLACE") != null);
}

test "dot repeats an R" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "0RXY");
    e.key("\x1b");
    keys(e, "ll.");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("XYcXYf", s); // same as vim
}

// -------------------------------------------------------- insert-mode round

test "ctrl-w deletes the word behind the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar baz");
    e.key("\x17");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo bar ", s);
}

test "ctrl-w from mid-line takes only what is behind" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo bar baz");
    e.key("\x1b");
    keys(e, "$i");
    e.key("\x17");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo bar z", s);
}

test "ctrl-w in column zero takes the newline" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\nbar");
    e.key("\x1b");
    keys(e, "j0i");
    e.key("\x17");
    keys(e, "Z");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("fooZbar", s);
}

test "ctrl-u clears the line before the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i    hello world");
    e.key("\x15");
    keys(e, "Z");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("Z", s);
}

test "ctrl-u in column zero does nothing" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i    hello");
    e.key("\x1b");
    keys(e, "0i");
    e.key("\x15");
    keys(e, "Z");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("Z    hello", s);
}

test "ctrl-o runs one normal command and comes back" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "0i");
    e.key("\x0f");
    keys(e, "lX");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("aXbc", s);
}

test "ctrl-o dollar appends rather than overwriting" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc def");
    e.key("\x1b");
    keys(e, "0i");
    e.key("\x0f");
    keys(e, "$X");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abc defX", s);
}

test "ctrl-o holds through a multi-key command" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two three");
    e.key("\x1b");
    keys(e, "0i");
    e.key("\x0f");
    keys(e, "dawZ"); // daw is three keys; the Z lands back in insert
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("Ztwo three", s);
}

test "ctrl-r inserts a register inline" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two");
    e.key("\x1b");
    keys(e, "0\"aye"); // register a = "one"
    keys(e, "$a-");
    e.key("\x12");
    keys(e, "a");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one two-one", s);
}

test "ctrl-r with the unnamed register" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "0yl$a");
    e.key("\x12");
    keys(e, "\"");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abca", s);
}

test "ctrl-t and ctrl-d indent the line under the cursor" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ihello");
    e.key("\x14");
    keys(e, "!");
    e.key("\x1b");
    {
        const s = try bufText(gpa, e);
        defer gpa.free(s);
        try testing.expectEqualStrings("    hello!", s);
    }
    keys(e, "A");
    e.key("\x04");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("hello!", s);
}

test "ctrl-t indents a line that is still empty" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione");
    e.key("\x1b");
    keys(e, "o");
    e.key("\x14");
    keys(e, "two");
    e.key("\x1b");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\n    two", s);
}

// ------------------------------------------------------------- :s substitute

fn ex(e: *Editor, cmd: []const u8) void {
    e.key(":");
    e.key(cmd);
    e.key("\r");
}

test "percent s replaces on every line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\nboo");
    e.key("\x1b");
    ex(e, "%s/o/0/g");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("f00\nb00", s);
}

test "s without g takes only the first match on the line" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\nboo");
    e.key("\x1b");
    keys(e, "G");
    ex(e, "s/o/0/");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("foo\nb0o", s);
}

test "s defaults to the current line only" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree");
    e.key("\x1b");
    keys(e, "gg");
    ex(e, "s/o/0/");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("0ne\ntwo\nthree", s);
}

test "a numeric range bounds the substitute" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\na\na\na");
    e.key("\x1b");
    ex(e, "2,3s/a/X/");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a\nX\nX\na", s);
}

test "dollar and dot are addresses" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\na\na\na");
    e.key("\x1b");
    keys(e, "ggj"); // line 1
    ex(e, ".,$s/a/X/");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a\nX\nX\nX", s);
}

test "the i flag ignores case" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iFoo\nFOO");
    e.key("\x1b");
    ex(e, "%s/foo/x/gi");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("x\nx", s);
}

test "any character can be the separator" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia/b");
    e.key("\x1b");
    ex(e, "s#/#-#");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a-b", s);
}

test "an escaped separator is literal" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione/two");
    e.key("\x1b");
    ex(e, "s/\\//-/");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("one-two", s);
}

test "a replacement containing the pattern still terminates" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iaaa");
    e.key("\x1b");
    ex(e, "s/a/aa/g");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("aaaaaa", s);
}

test "an empty replacement deletes" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione two one");
    e.key("\x1b");
    ex(e, "s/one//g");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings(" two ", s);
}

test "a missing pattern says so and changes nothing" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    ex(e, "%s/zz/x/");
    const dump = try e.dumpText(gpa, 60, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "pattern not found") != null);
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("abc", s);
}

test "the whole substitute is one undo" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\na\na");
    e.key("\x1b");
    ex(e, "%s/a/X/");
    keys(e, "u");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a\na\na", s);
}

test "a substitute sets the search pattern" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ifoo\nbar\nfoo");
    e.key("\x1b");
    keys(e, "gg");
    ex(e, "s/foo/foo/");
    keys(e, "n");
    try testing.expectEqual(@as(usize, 2), e.cline);
}

test "colon from a visual selection prefills its range" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\na\na\na");
    e.key("\x1b");
    keys(e, "ggjVj:"); // lines 1..2 selected
    keys(e, "s/a/X/");
    e.key("\r");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("a\nX\nX\na", s);
}

test "a bare range is a goto" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ione\ntwo\nthree\nfour");
    e.key("\x1b");
    keys(e, "gg");
    ex(e, "$");
    try testing.expectEqual(@as(usize, 3), e.cline);
}

// ---------------------------------------------------------------- macros

test "q records and @ replays" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\nc\nd");
    e.key("\x1b");
    keys(e, "ggqaI> ");
    e.key("\x1b");
    keys(e, "jq");
    keys(e, "@a");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("> a\n> b\nc\nd", s);
}

test "the q that stops a recording is not in it" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia");
    e.key("\x1b");
    keys(e, "qaI> ");
    e.key("\x1b");
    keys(e, "q");
    try testing.expectEqualStrings("I> \x1b", e.regs['a' - 'a'].text.items);
}

test "a count on @ repeats the macro" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "i1\n2\n3\n4\n5");
    e.key("\x1b");
    keys(e, "ggqzI-");
    e.key("\x1b");
    keys(e, "jq");
    keys(e, "3@z");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("-1\n-2\n-3\n-4\n5", s);
}

test "at-at repeats the last macro" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "ia\nb\nc");
    e.key("\x1b");
    keys(e, "ggqaI> ");
    e.key("\x1b");
    keys(e, "jq");
    keys(e, "@a@@");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("> a\n> b\n> c", s);
}

test "a macro lives in the register, so it can be pasted" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iZZ");
    e.key("\x1b");
    keys(e, "qbx");
    keys(e, "q");
    keys(e, "\"bp");
    const s = try bufText(gpa, e);
    defer gpa.free(s);
    try testing.expectEqualStrings("Zx", s);
}

test "an uppercase register appends to the macro" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "qcxq");
    keys(e, "qCxq");
    try testing.expectEqualStrings("xx", e.regs['c' - 'a'].text.items);
}

test "a macro that plays itself stops at the depth cap" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "qa@aq"); // register a = "@a"
    try testing.expectEqualStrings("@a", e.regs['a' - 'a'].text.items);
    keys(e, "@a");
    const dump = try e.dumpText(gpa, 60, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "nested too deep") != null);
}

test "a macro records the call to another macro, not its expansion" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabcdef");
    e.key("\x1b");
    keys(e, "qbxxq"); // b = "xx"
    keys(e, "qa@bq"); // a should hold "@b", two bytes
    try testing.expectEqualStrings("@b", e.regs['a' - 'a'].text.items);
}

test "the status row says which register is recording" {
    const gpa = testing.allocator;
    var e = try mkEditor(gpa);
    defer e.destroy();
    keys(e, "iabc");
    e.key("\x1b");
    keys(e, "qa");
    const dump = try e.dumpText(gpa, 60, 6);
    defer gpa.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "recording @a") != null);
}
