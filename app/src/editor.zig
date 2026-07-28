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
//! h j k l w b e 0 ^ $ gg G arrows ctrl-d/u; operators d y c (+ dd yy
//! cc D C Y), x r J p P u ctrl-r, counts; :w :q :q! :wq :x :e :<n>.
//! Debts: no search, no marks/registers beyond the unnamed one, no
//! autoindent, wide glyphs count as one column, lines beyond 4KB get
//! motion/render math clamped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufferpkg = @import("buffer.zig");

pub const tab_width = 4;
const max_line = 4096;

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
    pend_r: bool = false,

    vanchor_line: usize = 0,
    vanchor_col: usize = 0,

    cmd: std.ArrayListUnmanaged(u8) = .empty,
    /// What the command line is collecting: an ex command (:) or a
    /// search pattern (/).
    cmd_kind: enum { ex, search } = .ex,
    /// The live pattern; non-empty = visible matches highlight
    /// (:noh clears).
    last_search: std.ArrayListUnmanaged(u8) = .empty,
    reg: std.ArrayListUnmanaged(u8) = .empty,
    reg_linewise: bool = false,

    grid: std.ArrayListUnmanaged(RCell) = .empty,
    last_cols: usize = 80,
    last_rows: usize = 24,

    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    status_err: bool = false,

    scratch: [max_line]u8 = undefined,
    scratch2: [max_line]u8 = undefined,

    closed: bool = false,
    render_dirty: bool = true,
    /// Buffer is a directory LISTING (netrw/oil heritage): Enter opens
    /// the entry under the cursor, `-` climbs to the parent. No side
    /// panel — every pane can hold its own tree.
    is_dir: bool = false,

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
        if (self.buf.modified) {
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
        self.last_search.deinit(gpa);
        self.reg.deinit(gpa);
        self.grid.deinit(gpa);
        gpa.destroy(self);
    }

    /// Tab-chip / status name: file basename or [scratch].
    pub fn displayName(self: *const Editor) []const u8 {
        const p = self.buf.path orelse return "[scratch]";
        return std.fs.path.basename(p);
    }

    // ------------------------------------------------------------ text access

    fn lineCountB(self: *const Editor) usize {
        return self.buf.rope.lineCount();
    }

    fn lineLenB(self: *const Editor, line: usize) usize {
        return self.buf.rope.lineEnd(line) - self.buf.rope.lineStart(line);
    }

    /// Copy a line into scratch (clamped to max_line — the long-line debt).
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

    fn cpLenAt(s: []const u8, i: usize) usize {
        if (i >= s.len) return 1;
        return std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }

    fn prevCpStart(s: []const u8, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
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

    fn firstNonblank(s: []const u8) usize {
        for (s, 0..) |c, i| if (c != ' ' and c != '\t') return i;
        return 0;
    }

    fn clampNormal(self: *Editor) void {
        const s = self.lineText(self.cline);
        const maxc = lastCpCol(s);
        if (self.ccol > maxc) self.ccol = maxc;
    }

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype, is_err: bool) void {
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
            // Whole CSI arrow sequences (from the event monitor).
            if (bytes[i] == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                const m: ?u8 = switch (bytes[i + 2]) {
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
                    i += 3;
                    continue;
                }
            }

            switch (self.mode) {
                .command, .insert => {
                    // Consume a printable run at once (multi-byte UTF-8
                    // included); control bytes go one at a time.
                    var end = i;
                    while (end < bytes.len and (bytes[end] == '\t' or bytes[end] >= 0x20)) end += 1;
                    const run = bytes[i..end];
                    if (run.len > 0) {
                        if (self.mode == .insert) self.insertKey(run) else self.commandKey(run);
                        i = end;
                    } else {
                        if (self.mode == .insert) self.insertKey(bytes[i .. i + 1]) else self.commandKey(bytes[i .. i + 1]);
                        i += 1;
                    }
                },
                else => {
                    // Normal/visual commands are single ASCII keys;
                    // skip over any multi-byte codepoint whole.
                    const n = cpLenAt(bytes, i);
                    if (n == 1) self.normalKey(bytes[i]);
                    i += n;
                },
            }
        }
    }

    fn insertArrow(self: *Editor, m: u8) void {
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
        if (b0 == 0x1b) { // ESC → normal, cursor left one cp
            self.mode = .normal;
            if (self.ccol > 0) {
                const s = self.lineText(self.cline);
                self.ccol = prevCpStart(s, self.ccol);
            }
            self.goal = renderCol(self.lineText(self.cline), self.ccol);
            return;
        }
        if (b0 == '\r' or b0 == '\n') {
            self.buf.insert(gpa, self.absOff(), "\n") catch return;
            self.cline += 1;
            self.ccol = 0;
            return;
        }
        if (b0 == 0x7f or b0 == 0x08) { // backspace
            if (self.ccol > 0) {
                const s = self.lineText(self.cline);
                const p = prevCpStart(s, self.ccol);
                const start = self.buf.rope.lineStart(self.cline);
                self.buf.deleteRange(gpa, start + p, start + self.ccol) catch return;
                self.ccol = p;
            } else if (self.cline > 0) {
                const prev_len = self.lineLenB(self.cline - 1);
                const nl = self.buf.rope.lineStart(self.cline) - 1;
                self.buf.deleteRange(gpa, nl, nl + 1) catch return;
                self.cline -= 1;
                self.ccol = prev_len;
            }
            return;
        }
        if (b0 == '\t' or b0 >= 0x20) {
            // Printable run (possibly multi-byte UTF-8); drop other
            // control bytes.
            self.buf.insert(gpa, self.absOff(), bytes) catch return;
            self.ccol += bytes.len;
        }
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

        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const verb = if (sp) |i| line[0..i] else line;
        const arg = std.mem.trim(u8, if (sp) |i| line[i + 1 ..] else "", " ");

        const is = std.mem.eql;
        if (is(u8, verb, "w") or is(u8, verb, "wq") or is(u8, verb, "x")) {
            if (self.is_dir) {
                self.setStatus("a directory listing isn't writable", .{}, true);
                return;
            }
            if (arg.len > 0) {
                const p = gpa.dupe(u8, arg) catch return;
                if (self.buf.path) |old| gpa.free(old);
                self.buf.path = p;
            }
            self.buf.save(gpa, self.io) catch |err| {
                self.setStatus("write failed: {s}", .{@errorName(err)}, true);
                return;
            };
            self.setStatus("wrote {s}", .{self.displayName()}, false);
            if (!is(u8, verb, "w")) self.closed = true;
        } else if (is(u8, verb, "q")) {
            if (self.buf.modified) {
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
        } else {
            self.setStatus("not an editor command: {s}", .{verb}, true);
        }
    }

    /// Retarget this pane at another file (:e / ctl edit — the
    /// rook-buffers model: panes retarget in place).
    pub fn open(self: *Editor, path: []const u8, force: bool) !void {
        if (self.buf.modified and !force) {
            self.setStatus("unsaved changes (:w first, or :e! to discard)", .{}, true);
            return;
        }
        var is_dir = false;
        const nb = try loadPath(self.gpa, self.io, path, &is_dir);
        self.buf.deinit(self.gpa);
        self.buf = nb;
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

        if (ch == 0x1b) { // ESC: clear pending, leave visual
            self.count = 0;
            self.op = 0;
            self.pend_g = false;
            self.mode = .normal;
            return;
        }

        // Counts (0 alone is a motion).
        if (ch >= '1' and ch <= '9' or (ch == '0' and self.count > 0)) {
            self.count = self.count *| 10 +| (ch - '0');
            return;
        }

        if (self.pend_g) {
            self.pend_g = false;
            if (ch == 'g') {
                const n = self.count;
                self.count = 0;
                self.motionLinewise(if (n == 0) 0 else @min(n - 1, self.lineCountB() - 1));
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
            'r' => self.pend_r = true,
            'J' => {
                if (self.cline + 1 >= self.lineCountB()) return;
                self.buf.newUndoGroup();
                const eol = self.buf.rope.lineEnd(self.cline);
                const next = self.lineText(self.cline + 1);
                const nb = firstNonblank(next);
                self.buf.deleteRange(gpa, eol, eol + 1 + nb) catch return;
                self.buf.insert(gpa, eol, " ") catch return;
                self.ccol = eol - self.buf.rope.lineStart(self.cline);
                self.clampNormal();
            },

            // Insert transitions.
            'i' => self.enterInsert(),
            'I' => {
                self.ccol = firstNonblank(self.lineText(self.cline));
                self.enterInsert();
            },
            'a' => {
                const s = self.lineText(self.cline);
                if (s.len > 0 and self.ccol < s.len) self.ccol += cpLenAt(s, self.ccol);
                self.enterInsert();
            },
            'A' => {
                self.ccol = self.lineLenB(self.cline);
                self.enterInsert();
            },
            'o' => {
                self.enterInsert();
                self.buf.insert(gpa, self.buf.rope.lineEnd(self.cline), "\n") catch return;
                self.cline += 1;
                self.ccol = 0;
            },
            'O' => {
                self.enterInsert();
                self.buf.insert(gpa, self.buf.rope.lineStart(self.cline), "\n") catch return;
                self.ccol = 0;
            },

            // Paste.
            'p' => self.paste(true),
            'P' => self.paste(false),

            // Undo.
            'u' => {
                if (self.buf.undo(gpa) catch null) |off| self.cursorToOffset(off) else self.setStatus("already at oldest change", .{}, false);
            },
            0x12 => { // ctrl-r
                if (self.buf.redo(gpa) catch null) |off| self.cursorToOffset(off) else self.setStatus("already at newest change", .{}, false);
            },

            // Visual.
            'v' => {
                if (self.mode == .visual) {
                    self.mode = .normal;
                } else {
                    self.mode = .visual;
                    self.vanchor_line = self.cline;
                    self.vanchor_col = self.ccol;
                }
            },
            'V' => {
                if (self.mode == .visual_line) {
                    self.mode = .normal;
                } else {
                    self.mode = .visual_line;
                    self.vanchor_line = self.cline;
                    self.vanchor_col = self.ccol;
                }
            },

            ':' => {
                self.mode = .command;
                self.cmd_kind = .ex;
                self.cmd.clearRetainingCapacity();
            },
            '/' => {
                self.mode = .command;
                self.cmd_kind = .search;
                self.cmd.clearRetainingCapacity();
            },
            'n' => self.searchNext(true),
            'N' => self.searchNext(false),

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
                else => {},
            }
        }

        if (self.op != 0) {
            const s = self.lineText(line);
            var end_col = col;
            if (inclusive and end_col < s.len) end_col += cpLenAt(s, end_col);
            const a = self.buf.rope.lineStart(self.cline) + self.ccol;
            const b = self.buf.rope.lineStart(line) + end_col;
            self.opRange(@min(a, b), @max(a, b));
            return;
        }

        self.cline = line;
        self.ccol = col;
        if (self.mode == .normal) self.clampNormal();
        self.goal = renderCol(self.lineText(self.cline), self.ccol);
    }

    fn motionLinewise(self: *Editor, target: usize) void {
        if (self.op != 0) {
            self.opLines(@min(self.cline, target), @max(self.cline, target));
            return;
        }
        self.cline = target;
        self.ccol = firstNonblank(self.lineText(target));
        self.goal = renderCol(self.lineText(target), self.ccol);
    }

    const Pos = struct { line: usize, col: usize };

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

    // ------------------------------------------------------------ operators

    fn yankStore(self: *Editor, text: []const u8, linewise: bool) void {
        self.reg.clearRetainingCapacity();
        self.reg.appendSlice(self.gpa, text) catch {};
        self.reg_linewise = linewise;
    }

    /// Charwise operator over [start, end) byte offsets.
    fn opRange(self: *Editor, start: usize, end: usize) void {
        const gpa = self.gpa;
        const op = self.op;
        self.op = 0;
        if (start == end) return;
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

        const text = rope.dupeRange(gpa, start, end) catch return;
        defer gpa.free(text);
        self.yankStore(text, true);
        if (self.reg.items.len > 0 and self.reg.items[self.reg.items.len - 1] != '\n') {
            self.reg.append(gpa, '\n') catch {};
        }
        if (op == 'y') {
            self.cline = a;
            self.clampNormal();
            return;
        }

        self.buf.newUndoGroup();
        if (op == 'c') {
            // cc: clear the lines but keep one empty line to type into.
            if (end > start and self.buf.rope.byteLen() >= end and end >= 1) {
                const keep_nl = b + 1 < self.lineCountB();
                self.buf.deleteRange(gpa, start, if (keep_nl) end - 1 else end) catch return;
            }
            self.cline = a;
            self.ccol = 0;
            self.mode = .insert;
            return;
        }
        // dd at EOF also eats the newline BEFORE the range.
        if (end == rope.byteLen() and start > 0) start -= 1;
        self.buf.deleteRange(gpa, start, end) catch return;
        self.cline = @min(a, self.lineCountB() - 1);
        self.ccol = firstNonblank(self.lineText(self.cline));
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
        self.mode = .normal;
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
        if (self.reg.items.len == 0) return;
        self.buf.newUndoGroup();
        if (self.reg_linewise) {
            const rope = &self.buf.rope;
            if (after) {
                if (self.cline + 1 < self.lineCountB()) {
                    self.buf.insert(gpa, rope.lineStart(self.cline + 1), self.reg.items) catch return;
                } else {
                    // Paste after the last line: newline first, and the
                    // register's own trailing newline is dropped.
                    const text = self.reg.items[0 .. self.reg.items.len - 1];
                    var end = rope.byteLen();
                    self.buf.insert(gpa, end, "\n") catch return;
                    end += 1;
                    self.buf.insert(gpa, end, text) catch return;
                }
                self.cline += 1;
            } else {
                self.buf.insert(gpa, rope.lineStart(self.cline), self.reg.items) catch return;
            }
            self.ccol = firstNonblank(self.lineText(self.cline));
            return;
        }
        const s = self.lineText(self.cline);
        var at = self.absOff();
        if (after and s.len > 0 and self.ccol < s.len) at += cpLenAt(s, self.ccol);
        self.buf.insert(gpa, at, self.reg.items) catch return;
        self.cursorToOffset(at + self.reg.items.len - 1);
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
                const cp = std.unicode.utf8Decode(s[i..@min(i + n, s.len)]) catch 0xFFFD;
                putText(out, gw, text_cols, self.left, rc, cp, st);
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
            .insert => " INSERT ",
            .visual => " VISUAL ",
            .visual_line => " V-LINE ",
            .command => unreachable,
        };
        putStr(out, &x, mode_str, .mode);
        x += 1;
        if (self.status_len > 0) {
            putStr(out, &x, self.status_buf[0..self.status_len], if (self.status_err) .err else .text);
        } else {
            putStr(out, &x, self.displayName(), .text);
            if (self.buf.modified) putStr(out, &x, " [+]", .dim);
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

    fn putStr(out: []RCell, x: *usize, s: []const u8, st: Style) void {
        for (s) |c| {
            if (x.* >= out.len) return;
            out[x.*] = .{ .cp = c, .st = st };
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
