//! The monitor pane: what the machine is doing, and where the disk went.
//!
//! A view model and nothing else. It owns no threads, takes no locks and
//! calls no syscalls — it is handed a `procmon.Snapshot` and a
//! `diskscan.Scan` and turns them into a grid of styled cells. That is
//! what makes it testable without a window, which for a screen whose
//! whole content is numbers is the difference between "it renders" and
//! "it renders the right numbers".
//!
//! ## Why a pane and not a panel
//!
//! Both halves are TABLES — several numeric columns that only mean
//! something side by side, and a right-aligned size column you compare
//! down. A 30-column side pane turns those into a list of truncated
//! titles, which is the one shape that throws away the reason to look.
//!
//! ## The grid contract
//!
//! `fillGrid(cols, rows)` returns exactly `cols * rows` cells, the same
//! contract `editor.fillGrid` has, so the app's existing editor fill
//! path draws this pane with no new render code. The styles are
//! BORROWED from the editor's enum for the same reason `tree_dir`
//! borrows the function colour: a monitor that invented its own palette
//! would need every theme to be updated before it looked right in any
//! of them. What each borrowed style means here is written down at
//! `sev` and `catStyle` rather than left to the reader.
//!
//! ## Two questions, two sections
//!
//! LIVE answers "why is the fan spinning": the machine's totals, then
//! processes ranked by cost, with the pane each belongs to. DISK
//! answers "what do I clean up": free space, then how much is
//! reclaimable AT WHAT COST, then the tree.

const std = @import("std");
const editor = @import("editor.zig");
const procmon = @import("procmon.zig");
const diskscan = @import("diskscan.zig");

const RCell = editor.RCell;
const Style = editor.Style;

pub const Section = enum { live, disk };

/// How a number reads at a glance. Mapped onto editor styles at the
/// point of use, so the meaning lives here and the colour lives in the
/// theme — the split every other tenant in the app already uses.
const Sev = enum { ok, warn, crit };

fn sev(s: Sev) Style {
    return switch (s) {
        // Borrowed, and why: `diff_add` is green in every builtin theme,
        // `syn_number` is the amber one, `ed_err` is the red. A monitor
        // needs exactly those three and no theme has a "warning" slot.
        .ok => .diff_add,
        .warn => .syn_number,
        .crit => .err,
    };
}

/// Reclaim class → style. The colour IS the recommendation, so it is
/// derived from the class rather than from size: a 40GB `keep` must
/// never look more actionable than a 2GB `regenerable`.
fn catStyle(r: diskscan.Reclaim) Style {
    return switch (r) {
        .regenerable => .diff_add,
        .refetchable => .syn_number,
        // Not red — `keep` is not a problem, it is an answer. Dim says
        // "this is where it went, and there is nothing to do here".
        .keep => .dim,
        .unknown => .text,
    };
}

// ---------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------

/// Bytes as a human reads them, right-alignable and never wider than 7
/// ("1023.9M"). Binary units because that is what every disk tool on
/// the machine prints and disagreeing by 7% with `du` invites a bug
/// report that is not a bug.
pub fn humanBytes(b: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var v: f64 = @floatFromInt(b);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    // Sub-K is always whole: "512B", never "512.0B".
    if (u == 0) return std.fmt.bufPrint(buf, "{d}B", .{b}) catch "?";
    // One decimal below 10, none above: "9.4G" then "17G". Keeps the
    // column narrow without losing the resolution that matters at the
    // small end, which is where a decision is close.
    if (v < 10) return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ v, units[u] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}{s}", .{ v, units[u] }) catch "?";
}

/// A percentage that may exceed 100 (a process can use eight cores).
fn humanPct(p: f32, buf: []u8) []const u8 {
    if (p < 10) return std.fmt.bufPrint(buf, "{d:.1}", .{p}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}", .{p}) catch "?";
}

/// A proportional bar in `w` cells. Eighth-blocks so a bar that is 3%
/// full still shows something — a meter that reads empty until 12% is a
/// meter that lies at exactly the moment you are watching it.
fn bar(frac: f64, w: usize, out: []u8) []const u8 {
    const eighths = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };
    const filled = "█";
    // The empty track. A dot rather than a space so the bar has a
    // visible LENGTH — an unfilled meter drawn in spaces is invisible,
    // and then 3% and 30% look equally like nothing.
    const empty = "·";

    const f = std.math.clamp(frac, 0, 1);
    const total_eighths: usize = @intFromFloat(f * @as(f64, @floatFromInt(w * 8)));
    var n: usize = 0;
    var drawn = total_eighths / 8;
    const rem = total_eighths % 8;

    var i: usize = 0;
    while (i < drawn and n + filled.len <= out.len) : (i += 1) {
        @memcpy(out[n..][0..filled.len], filled);
        n += filled.len;
    }
    if (rem > 0 and drawn < w) {
        const g = eighths[rem];
        if (n + g.len <= out.len) {
            @memcpy(out[n..][0..g.len], g);
            n += g.len;
            drawn += 1;
        }
    }
    while (drawn < w and n + empty.len <= out.len) : (drawn += 1) {
        @memcpy(out[n..][0..empty.len], empty);
        n += empty.len;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------
// The pane
// ---------------------------------------------------------------------

/// A row the user can select. Kept beside the grid so a click or a
/// keypress can resolve to a THING rather than to a screen line — the
/// same reason the which-key sheet records hit rects.
pub const Row = struct {
    kind: enum { none, proc, node } = .none,
    /// pid for `.proc`, node index for `.node`.
    id: u32 = 0,
};

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    section: Section = .live,
    sort: procmon.SortKey = .cpu,

    /// Latest sample. Owned; replaced wholesale by the sampler thread
    /// under the app's draw lock.
    snap: procmon.Snapshot = .{},
    scan: ?*diskscan.Scan = null,
    prog: ?*diskscan.Progress = null,
    vol: ?diskscan.Volume = null,

    /// Which node the DISK tree is showing the children of.
    disk_root: u32 = 0,
    /// Breadcrumb back out of a drill-in.
    disk_stack: std.ArrayListUnmanaged(u32) = .empty,

    sel: usize = 0,
    scroll: usize = 0,

    /// A pending destructive action, waiting for its confirm. Holding it
    /// as STATE rather than firing from the keypress is what makes the
    /// confirm real: the path is captured when you ask, and the second
    /// key acts on that captured path, so a list that re-sorts under
    /// you between the two cannot redirect the delete.
    pending: ?Pending = null,
    /// Transient one-line message under the header.
    msg: [160]u8 = @splat(0),
    msg_len: usize = 0,

    grid: std.ArrayListUnmanaged(RCell) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    /// `:q` / ⌘W asked for this pane to go. The reap loop collapses it
    /// on the next frame, the same handshake `Editor.closed` uses —
    /// pane surgery cannot happen on the key path, which already holds
    /// the draw lock.
    closed: bool = false,
    /// Something changed that the last fill does not show. The monitor
    /// is a POLLED view, so unlike an editor it also goes dirty when a
    /// new sample lands with no keystroke involved.
    render_dirty: bool = true,

    /// Pane ids → a short label, for the PANE column. Filled by the app
    /// before each fill; the view model never reads the pane tree.
    pane_labels: []const PaneLabel = &.{},

    pub const PaneLabel = struct { id: u32, text: []const u8 };

    pub const Pending = struct {
        path: [1024]u8 = @splat(0),
        path_len: usize = 0,
        bytes: u64 = 0,
        /// The tool command to prefer, empty for a plain delete.
        tool: [64]u8 = @splat(0),
        tool_len: usize = 0,
        pub fn pathStr(self: *const Pending) []const u8 {
            return self.path[0..self.path_len];
        }
        pub fn toolStr(self: *const Pending) []const u8 {
            return self.tool[0..self.tool_len];
        }
    };

    pub fn init(gpa: std.mem.Allocator) Monitor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Monitor) void {
        self.snap.deinit(self.gpa);
        self.disk_stack.deinit(self.gpa);
        self.grid.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    /// Wheel/trackpad scrolling. Positive `lines` scrolls toward the
    /// top, matching the editor's sign convention at its own call site.
    pub fn scrollBy(self: *Monitor, lines: i64) void {
        const n = self.count();
        if (n == 0) return;
        if (lines > 0) {
            self.scroll -|= @intCast(lines);
        } else {
            self.scroll += @intCast(-lines);
            // Keep a screenful reachable rather than letting the list
            // scroll off its own end into blank space.
            if (self.scroll >= n) self.scroll = n - 1;
        }
        self.render_dirty = true;
    }

    /// The pane as plain text — what `ctl dump` returns and what an e2e
    /// scenario asserts on. Built from the SAME fill the window draws,
    /// so a headless assertion cannot pass while the visible pane is
    /// wrong; that equivalence is the whole value of the dump.
    pub fn dumpText(self: *Monitor, gpa: std.mem.Allocator, cols: usize, rows_n: usize) ![]u8 {
        const cells = self.fillGrid(cols, rows_n);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [4]u8 = undefined;
        for (0..rows_n) |r| {
            var line_start = out.items.len;
            for (0..cols) |c| {
                const cell = cells[r * cols + c];
                if (cell.tail) continue;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try out.appendSlice(gpa, buf[0..n]);
            }
            // Trailing blanks are padding, not content, and an e2e
            // `expectContains` should not have to know how wide the
            // pane happened to be.
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ')
                out.items.len -= 1;
            line_start = out.items.len;
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn setMsg(self: *Monitor, text: []const u8) void {
        self.msg_len = @min(self.msg.len, text.len);
        @memcpy(self.msg[0..self.msg_len], text[0..self.msg_len]);
    }

    fn msgStr(self: *const Monitor) []const u8 {
        return self.msg[0..self.msg_len];
    }

    // -----------------------------------------------------------------
    // Grid writing
    // -----------------------------------------------------------------

    const W = struct {
        m: *Monitor,
        cols: usize,
        rows_n: usize,
        y: usize = 0,
        x: usize = 0,

        fn at(self: *W, x: usize, y: usize) void {
            self.x = x;
            self.y = y;
        }

        fn put(self: *W, text: []const u8, st: Style) void {
            if (self.y >= self.rows_n) return;
            var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                if (self.x >= self.cols) return;
                self.m.grid.items[self.y * self.cols + self.x] = .{ .cp = cp, .st = st };
                self.x += 1;
                // A double-width glyph owns the cell after it, or the
                // column to its right is painted over its own right half.
                if (editor.wideCp(cp) and self.x < self.cols) {
                    self.m.grid.items[self.y * self.cols + self.x] = .{ .cp = ' ', .st = st, .tail = true };
                    self.x += 1;
                }
            }
        }

        /// Right-align `text` so its last cell lands on column `right`.
        /// Numbers are compared by scanning DOWN a column, which only
        /// works if their digits line up.
        fn putRight(self: *W, right: usize, text: []const u8, st: Style) void {
            const n = std.unicode.utf8CountCodepoints(text) catch text.len;
            const start = if (right >= n) right - n else 0;
            self.at(start, self.y);
            self.put(text, st);
        }

        fn fillRow(self: *W, y: usize, st: Style) void {
            if (y >= self.rows_n) return;
            for (0..self.cols) |x| self.m.grid.items[y * self.cols + x] = .{ .cp = ' ', .st = st };
        }

        fn rule(self: *W, y: usize) void {
            if (y >= self.rows_n) return;
            for (0..self.cols) |x| self.m.grid.items[y * self.cols + x] = .{ .cp = '─', .st = .dim };
        }
    };

    /// The pane's cells for this frame. Exactly `cols * rows`, same
    /// contract as `editor.fillGrid`.
    pub fn fillGrid(self: *Monitor, cols: usize, rows_n: usize) []const RCell {
        self.grid.resize(self.gpa, cols * rows_n) catch return &.{};
        @memset(self.grid.items, .{ .cp = ' ', .st = .text });
        self.rows.clearRetainingCapacity();
        if (cols == 0 or rows_n == 0) return self.grid.items;

        var w = W{ .m = self, .cols = cols, .rows_n = rows_n };

        // --- the section tabs, always row zero -----------------------
        w.at(0, 0);
        w.put(" LIVE ", if (self.section == .live) .buftab_on else .buftab_off);
        w.put(" DISK ", if (self.section == .disk) .buftab_on else .buftab_off);

        var y: usize = 1;
        y = switch (self.section) {
            .live => self.headerLive(&w, y),
            .disk => self.headerDisk(&w, y),
        };

        // A pending confirm outranks everything: it is a question, and a
        // question you can scroll away from is one you will answer by
        // accident.
        if (self.pending) |p| {
            w.fillRow(y, chipRow());
            w.at(1, y);
            var b: [16]u8 = undefined;
            w.put("delete ", .err);
            w.put(humanBytes(p.bytes, &b), .err);
            w.put("  ", .text);
            w.put(p.pathStr(), .text);
            w.put("   [y] confirm  [n] cancel", .status);
            y += 1;
        } else if (self.msg_len > 0) {
            w.at(1, y);
            w.put(self.msgStr(), .dim);
            y += 1;
        }

        w.rule(y);
        y += 1;

        switch (self.section) {
            .live => self.bodyLive(&w, y),
            .disk => self.bodyDisk(&w, y),
        }
        return self.grid.items;
    }

    fn headerLive(self: *Monitor, w: *W, y0: usize) usize {
        var y = y0;
        const s = self.snap.sys;
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var bb: [128]u8 = undefined;

        const cap: f32 = @floatFromInt(@max(1, s.ncpu) * 100);
        w.at(1, y);
        w.put("CPU  ", .status);
        w.put(humanPct(s.busy_pct, &b1), sev(if (s.busy_pct > cap * 0.85)
            .crit
        else if (s.busy_pct > cap * 0.5) .warn else .ok));
        w.put("% of ", .dim);
        w.put(humanPct(cap, &b2), .dim);
        w.put("%  ", .dim);
        w.put(bar(s.busy_pct / cap, 12, &bb), .text);
        // The gap this monitor refuses to hide: work by processes that
        // would not report themselves. Without this the columns below
        // look like they should add up to the total, and they cannot.
        const gap = s.busy_pct - self.snap.attributed_pct;
        if (gap > 5) {
            var b3: [24]u8 = undefined;
            w.put("  unattributed ", .dim);
            w.put(humanPct(gap, &b3), .dim);
            w.put("%", .dim);
        }
        y += 1;

        w.at(1, y);
        w.put("MEM  ", .status);
        w.put(humanBytes(s.mem_used, &b1), .text);
        w.put(" of ", .dim);
        w.put(humanBytes(s.mem_total, &b2), .dim);
        w.put("  ", .dim);
        const mfrac: f64 = if (s.mem_total == 0) 0 else @as(f64, @floatFromInt(s.mem_used)) / @as(f64, @floatFromInt(s.mem_total));
        w.put(bar(mfrac, 12, &bb), .text);
        if (s.swap_used > 0) {
            var b4: [24]u8 = undefined;
            w.put("  swap ", .dim);
            // Swap in use is only alarming WITH pressure. Colouring it
            // red on its own would cry wolf on every Mac that has been
            // up a week.
            w.put(humanBytes(s.swap_used, &b4), sev(if (s.pressure >= 4)
                .crit
            else if (s.pressure >= 2) .warn else .ok));
        }
        if (s.pressure >= 2) {
            w.put(if (s.pressure >= 4) "  PRESSURE: urgent" else "  pressure: warn", sev(if (s.pressure >= 4) .crit else .warn));
        }
        y += 1;

        w.at(1, y);
        w.put("     PID", .dim);
        w.putRight(17, "CPU%", .dim);
        w.putRight(26, "MEM", .dim);
        w.at(29, y);
        w.put("PANE", .dim);
        w.at(37, y);
        w.put("COMMAND", .dim);
        return y + 1;
    }

    fn bodyLive(self: *Monitor, w: *W, y0: usize) void {
        const avail = if (w.rows_n > y0) w.rows_n - y0 else 0;
        if (avail == 0) return;

        if (self.snap.interval_ns == 0) {
            w.at(1, y0);
            // One sample can only report zero, and a column of zeroes is
            // indistinguishable from a broken monitor. Say which it is.
            w.put("measuring… (rates need a second sample)", .dim);
            return;
        }

        const n = self.snap.procs.len;
        var i = self.scroll;
        var y = y0;
        while (i < n and y < w.rows_n) : (i += 1) {
            const p = &self.snap.procs[i];
            // Idle processes are the overwhelming majority and the
            // question is "what is BUSY". They stay reachable by sorting
            // on another column; they do not get to fill the screen.
            //
            // `info_ok` gates the filter, and that is the whole point:
            // a process the kernel refused reports cpu_pct 0 because it
            // is UNKNOWN, not because it is idle. Filtering on the
            // number alone would hide every unattributable process —
            // precisely the set the header's "unattributed" figure is
            // telling you to go look for.
            if (p.info_ok and self.sort == .cpu and
                p.cpu_pct < 0.1 and p.footprint < 64 * 1024 * 1024) continue;
            // NOTE: y advances only when a row is actually drawn. A
            // `continue` in a loop whose continue-expression bumped y
            // would leave a blank line for every skipped process, which
            // on a real machine is most of the pane.
            defer y += 1;

            const selected = i == self.sel;
            if (selected) w.fillRow(y, chipRow());
            const base: Style = if (selected) .status else .text;

            self.rows.append(self.gpa, .{ .kind = .proc, .id = @intCast(@max(0, p.pid)) }) catch {};

            var b: [24]u8 = undefined;
            w.at(0, y);
            w.putRight(8, std.fmt.bufPrint(&b, "{d}", .{p.pid}) catch "?", .dim);

            w.y = y;
            if (p.info_ok) {
                w.putRight(17, humanPct(p.cpu_pct, &b), sev(if (p.cpu_pct > 100)
                    .crit
                else if (p.cpu_pct > 25) .warn else .ok));
                w.putRight(26, humanBytes(p.footprint, &b), base);
            } else {
                // Never zero: a process whose numbers the kernel refused
                // is not an idle process, and printing 0.0 would say it
                // was.
                w.putRight(17, "—", .dim);
                w.putRight(26, "—", .dim);
            }

            w.at(29, y);
            if (p.pane_id != 0) {
                var lbl: []const u8 = "";
                for (self.pane_labels) |pl| {
                    if (pl.id == p.pane_id) lbl = pl.text;
                }
                if (lbl.len == 0) {
                    w.put(std.fmt.bufPrint(&b, "▸{d}", .{p.pane_id}) catch "▸", .syn_func);
                } else {
                    w.put(lbl, .syn_func);
                }
            } else w.put("", .dim);

            w.at(37, y);
            w.put(p.nameStr(), base);
        }
    }

    fn headerDisk(self: *Monitor, w: *W, y0: usize) usize {
        var y = y0;
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var bb: [128]u8 = undefined;

        w.at(1, y);
        w.put("DISK ", .status);
        if (self.vol) |v| {
            const used = v.total -| v.avail;
            const frac: f64 = if (v.total == 0) 0 else @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(v.total));
            w.put(humanBytes(v.avail, &b1), sev(if (frac > 0.95) .crit else if (frac > 0.85) .warn else .ok));
            w.put(" free of ", .dim);
            w.put(humanBytes(v.total, &b2), .dim);
            w.put("  ", .dim);
            w.put(bar(frac, 12, &bb), .text);
        } else w.put("(no volume)", .dim);
        y += 1;

        // The headline: not how full the disk is (df says that) but how
        // much could come back and what each class costs to lose.
        w.at(1, y);
        if (self.scan) |sc| {
            const t = diskscan.reclaimable(sc);
            w.put("BACK ", .status);
            w.put(humanBytes(t[@intFromEnum(diskscan.Reclaim.regenerable)], &b1), catStyle(.regenerable));
            w.put(" rebuilds  ", .dim);
            w.put(humanBytes(t[@intFromEnum(diskscan.Reclaim.refetchable)], &b2), catStyle(.refetchable));
            w.put(" re-downloads  ", .dim);
            var b3: [24]u8 = undefined;
            w.put(humanBytes(t[@intFromEnum(diskscan.Reclaim.keep)], &b3), catStyle(.keep));
            w.put(" keep", .dim);
        } else if (self.prog) |pr| {
            var b3: [24]u8 = undefined;
            w.put("scanning… ", .dim);
            w.put(humanBytes(pr.bytes.load(.monotonic), &b3), .dim);
            w.put(" so far", .dim);
        } else w.put("press s to scan", .dim);
        y += 1;

        w.at(1, y);
        w.putRight(8, "SIZE", .dim);
        w.at(11, y);
        w.put("RECLAIM", .dim);
        w.at(25, y);
        w.put("PATH", .dim);
        return y + 1;
    }

    fn bodyDisk(self: *Monitor, w: *W, y0: usize) void {
        const sc = self.scan orelse return;
        if (sc.nodes.items.len == 0) return;
        const parent = &sc.nodes.items[self.disk_root];
        const kids = parent.children.items;

        var y = y0;
        var i = self.scroll;
        while (i < kids.len and y < w.rows_n) : ({
            i += 1;
            y += 1;
        }) {
            const node = &sc.nodes.items[kids[i]];
            const selected = i == self.sel;
            if (selected) w.fillRow(y, chipRow());
            self.rows.append(self.gpa, .{ .kind = .node, .id = kids[i] }) catch {};

            var b: [24]u8 = undefined;
            w.y = y;
            w.putRight(8, humanBytes(node.bytes, &b), if (selected) .status else .text);

            const rc = node.reclaim();
            w.at(11, y);
            w.put(switch (rc) {
                .regenerable => "rebuilds",
                .refetchable => "re-downloads",
                .keep => "keep",
                .unknown => "—",
            }, catStyle(rc));

            w.at(25, y);
            w.put(node.name, if (node.cat != null) .tree_dir else .text);

            // The note is the actual advice, and it is what turns a size
            // into a decision. Shown inline when there is room rather
            // than behind a detail view nobody opens.
            if (node.cat) |c| {
                if (w.x + 3 < w.cols) {
                    w.put("  ", .dim);
                    if (c.tool.len > 0) w.put(c.tool, .syn_string) else w.put(c.note, .dim);
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Keys
    // -----------------------------------------------------------------

    /// What a key did, for the app to act on. The view model decides
    /// WHAT should happen and the app performs it — this file cannot
    /// delete a directory or start a thread.
    pub const Act = enum { none, redraw, rescan, drill, reclaim, close };

    pub fn key(self: *Monitor, ch: u8) Act {
        // Any handled key changes something on screen; the few that do
        // not return `.none` below and cost one redundant fill.
        self.render_dirty = true;

        // A pending confirm eats everything. Any key that is not `y`
        // cancels — an ambiguous keystroke must never be a delete.
        if (self.pending != null) {
            if (ch == 'y') return .reclaim;
            self.pending = null;
            self.setMsg("cancelled");
            return .redraw;
        }

        switch (ch) {
            'j' => {
                self.sel += 1;
                self.clamp();
                return .redraw;
            },
            'k' => {
                self.sel -|= 1;
                self.clamp();
                return .redraw;
            },
            'g' => {
                self.sel = 0;
                self.scroll = 0;
                return .redraw;
            },
            'G' => {
                self.sel = self.count() -| 1;
                self.clamp();
                return .redraw;
            },
            '\t' => {
                self.section = if (self.section == .live) .disk else .live;
                self.sel = 0;
                self.scroll = 0;
                return .redraw;
            },
            'c' => {
                self.sort = .cpu;
                return .redraw;
            },
            'm' => {
                self.sort = .mem;
                return .redraw;
            },
            's' => return if (self.section == .disk) .rescan else .none,
            'l', '\r' => return if (self.section == .disk) .drill else .none,
            'h' => {
                if (self.section == .disk) {
                    if (self.disk_stack.pop()) |up| {
                        self.disk_root = up;
                        self.sel = 0;
                        self.scroll = 0;
                    }
                    return .redraw;
                }
                return .none;
            },
            'x' => return self.arm(),
            'q' => return .close,
            else => return .none,
        }
    }

    /// Stage a reclaim, or explain why there is not one.
    ///
    /// Every refusal here is deliberate and each is a different message,
    /// because "nothing happened" is the worst possible answer to a
    /// destructive key.
    fn arm(self: *Monitor) Act {
        if (self.section != .disk) {
            self.setMsg("nothing to reclaim on the LIVE tab");
            return .redraw;
        }
        const sc = self.scan orelse {
            self.setMsg("scan first (s)");
            return .redraw;
        };
        const parent = &sc.nodes.items[self.disk_root];
        if (self.sel >= parent.children.items.len) return .none;
        const node = &sc.nodes.items[parent.children.items[self.sel]];

        const c = node.cat orelse {
            self.setMsg("unclassified — rook has no opinion here, so it will not delete it");
            return .redraw;
        };
        if (!c.reclaim.deletable()) {
            var b: [200]u8 = undefined;
            self.setMsg(std.fmt.bufPrint(&b, "{s}: {s}", .{ c.id, c.note }) catch c.note);
            return .redraw;
        }

        var p: Pending = .{ .bytes = node.bytes };
        p.path_len = @min(p.path.len, node.path.len);
        @memcpy(p.path[0..p.path_len], node.path[0..p.path_len]);
        p.tool_len = @min(p.tool.len, c.tool.len);
        @memcpy(p.tool[0..p.tool_len], c.tool[0..p.tool_len]);
        self.pending = p;
        self.msg_len = 0;
        return .redraw;
    }

    pub fn count(self: *const Monitor) usize {
        return switch (self.section) {
            .live => self.snap.procs.len,
            .disk => if (self.scan) |sc|
                sc.nodes.items[self.disk_root].children.items.len
            else
                0,
        };
    }

    fn clamp(self: *Monitor) void {
        const n = self.count();
        if (n == 0) {
            self.sel = 0;
            self.scroll = 0;
            return;
        }
        if (self.sel >= n) self.sel = n - 1;
        if (self.sel < self.scroll) self.scroll = self.sel;
    }
};

/// The selected-row fill. One helper because both sections draw the same
/// selection, and a selection that looked different in each would be two
/// vocabularies for one idea — `drawRowSelection`'s reason for existing.
fn chipRow() Style {
    return .buftab_on;
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn gridText(cells: []const RCell, cols: usize, row: usize, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..cols) |x| {
        const c = cells[row * cols + x];
        if (c.tail) continue;
        n += std.unicode.utf8Encode(c.cp, buf[n..]) catch 0;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "humanBytes stays narrow and agrees with du's units" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("0B", humanBytes(0, &b));
    try testing.expectEqualStrings("512B", humanBytes(512, &b));
    try testing.expectEqualStrings("1.0K", humanBytes(1024, &b));
    try testing.expectEqualStrings("9.8K", humanBytes(10000, &b));
    try testing.expectEqualStrings("17G", humanBytes(18_099_628 * 1024, &b));
    // The column is right-aligned, so nothing may exceed 7 cells or the
    // header stops lining up with what is under it.
    const big = humanBytes(std.math.maxInt(u64), &b);
    try testing.expect(big.len <= 7);
}

test "bar shows something at 3% and fills at 100%" {
    var b: [128]u8 = undefined;
    // A meter that reads empty until 12% lies exactly when watched.
    const low = bar(0.03, 12, &b);
    // Something is drawn (a partial eighth), and the track is still
    // visible for the rest.
    try testing.expect(std.mem.indexOf(u8, low, "·") != null);
    try testing.expect(std.mem.indexOf(u8, low, "▎") != null or
        std.mem.indexOf(u8, low, "▍") != null or
        std.mem.indexOf(u8, low, "▏") != null);

    var b2: [128]u8 = undefined;
    const full = bar(1.0, 12, &b2);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, full, "·"));
    try testing.expectEqual(@as(usize, 12), std.mem.count(u8, full, "█"));

    // Out of range must clamp, not overflow the buffer or the width.
    var b3: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 12), std.mem.count(u8, bar(5.0, 12, &b3), "█"));
}

test "a keep category can never be armed for deletion" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var scan = diskscan.Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);

    try scan.nodes.append(testing.allocator, .{ .name = "root", .path = "/r" });
    try scan.nodes.append(testing.allocator, .{
        .name = "projects",
        .path = "/r/.claude/projects",
        .bytes = 900 * 1024 * 1024,
        .cat = diskscan.classify("/r/.claude/projects", true),
    });
    try scan.nodes.items[0].children.append(testing.allocator, 1);
    m.scan = &scan;
    m.section = .disk;
    m.sel = 0;

    // The whole safety property in one assertion: pressing the delete
    // key on irreplaceable data stages nothing and says why.
    _ = m.key('x');
    try testing.expect(m.pending == null);
    try testing.expect(std.mem.indexOf(u8, m.msgStr(), "agent-transcripts") != null);
}

test "a regenerable category arms, and only 'y' fires it" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var scan = diskscan.Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);

    try scan.nodes.append(testing.allocator, .{ .name = "root", .path = "/r" });
    try scan.nodes.append(testing.allocator, .{
        .name = "node_modules",
        .path = "/r/proj/node_modules",
        .bytes = 400 * 1024 * 1024,
        .cat = diskscan.classify("/r/proj/node_modules", true),
    });
    try scan.nodes.items[0].children.append(testing.allocator, 1);
    m.scan = &scan;
    m.section = .disk;

    try testing.expectEqual(Monitor.Act.redraw, m.key('x'));
    try testing.expect(m.pending != null);
    try testing.expectEqualStrings("/r/proj/node_modules", m.pending.?.pathStr());

    // Any key but `y` cancels. An ambiguous keystroke must not delete.
    try testing.expectEqual(Monitor.Act.redraw, m.key('j'));
    try testing.expect(m.pending == null);

    _ = m.key('x');
    try testing.expectEqual(Monitor.Act.reclaim, m.key('y'));
}

test "the confirm acts on the path captured when it was armed" {
    // The re-sort race: a live list reorders under you between the ask
    // and the answer. Capturing the path at arm time is what makes the
    // confirm mean what it said.
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var scan = diskscan.Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);
    try scan.nodes.append(testing.allocator, .{ .name = "root", .path = "/r" });
    try scan.nodes.append(testing.allocator, .{
        .name = "node_modules",
        .path = "/r/a/node_modules",
        .bytes = 10,
        .cat = diskscan.classify("/r/a/node_modules", true),
    });
    try scan.nodes.append(testing.allocator, .{
        .name = "node_modules",
        .path = "/r/b/node_modules",
        .bytes = 20,
        .cat = diskscan.classify("/r/b/node_modules", true),
    });
    try scan.nodes.items[0].children.append(testing.allocator, 1);
    try scan.nodes.items[0].children.append(testing.allocator, 2);
    m.scan = &scan;
    m.section = .disk;
    m.sel = 0;
    _ = m.key('x');
    try testing.expectEqualStrings("/r/a/node_modules", m.pending.?.pathStr());

    // The tree re-sorts; selection now points at a different node.
    std.mem.reverse(u32, scan.nodes.items[0].children.items);
    try testing.expectEqual(Monitor.Act.reclaim, m.key('y'));
    // Still the path that was named in the confirm.
    try testing.expectEqualStrings("/r/a/node_modules", m.pending.?.pathStr());
}

test "unclassified directories refuse deletion with a reason" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var scan = diskscan.Scan.init(testing.allocator);
    defer scan.deinit(testing.allocator);
    try scan.nodes.append(testing.allocator, .{ .name = "root", .path = "/r" });
    try scan.nodes.append(testing.allocator, .{ .name = "build", .path = "/r/build", .bytes = 999 });
    try scan.nodes.items[0].children.append(testing.allocator, 1);
    m.scan = &scan;
    m.section = .disk;

    _ = m.key('x');
    try testing.expect(m.pending == null);
    try testing.expect(std.mem.indexOf(u8, m.msgStr(), "no opinion") != null);
}

test "one sample says measuring rather than drawing a column of zeroes" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    const cells = m.fillGrid(80, 12);
    try testing.expectEqual(@as(usize, 80 * 12), cells.len);

    var found = false;
    var buf: [512]u8 = undefined;
    for (0..12) |r| {
        if (std.mem.indexOf(u8, gridText(cells, 80, r, &buf), "measuring") != null) found = true;
    }
    try testing.expect(found);
}

test "the section tabs render and tab switches them" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var buf: [512]u8 = undefined;

    var cells = m.fillGrid(80, 12);
    try testing.expect(std.mem.indexOf(u8, gridText(cells, 80, 0, &buf), "LIVE") != null);
    try testing.expect(std.mem.indexOf(u8, gridText(cells, 80, 0, &buf), "DISK") != null);
    try testing.expectEqual(Section.live, m.section);

    _ = m.key('\t');
    try testing.expectEqual(Section.disk, m.section);
    cells = m.fillGrid(80, 12);
    // The DISK tab with no scan must say how to get one.
    var any = false;
    for (0..12) |r| {
        if (std.mem.indexOf(u8, gridText(cells, 80, r, &buf), "press s to scan") != null) any = true;
    }
    try testing.expect(any);
}

test "fillGrid never writes outside its grid at absurd sizes" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    // A one-cell pane is a real state during a split animation, and a
    // header that assumed 40 columns would write off the end of it.
    for ([_]usize{ 1, 2, 5, 13, 40 }) |cols| {
        for ([_]usize{ 1, 2, 3, 9 }) |rows| {
            const cells = m.fillGrid(cols, rows);
            try testing.expectEqual(cols * rows, cells.len);
        }
    }
}

test "live rows carry pid identity and honour the pane label" {
    var m = Monitor.init(testing.allocator);
    defer m.deinit();
    var procs = [_]procmon.Proc{
        .{ .pid = 4242, .ppid = 1, .uid = 501, .cpu_pct = 188.4, .footprint = 3 * 1024 * 1024 * 1024, .info_ok = true, .pane_id = 2 },
        .{ .pid = 99, .ppid = 1, .uid = 0, .cpu_pct = 0, .footprint = 0, .info_ok = false },
    };
    procs[0].name_len = 6;
    @memcpy(procs[0].name[0..6], "claude");
    procs[1].name_len = 3;
    @memcpy(procs[1].name[0..3], "mds");

    m.snap = .{ .procs = &procs, .interval_ns = 1_000_000_000, .sys = .{ .ncpu = 14, .busy_pct = 412 } };
    // The snapshot is BORROWED from the stack here. Reset before
    // `m.deinit()` runs (defers unwind last-registered-first), and via a
    // defer rather than a trailing statement so a failing assertion
    // above cannot skip it and turn a test failure into an invalid free.
    defer m.snap.procs = &.{};
    const labels = [_]Monitor.PaneLabel{.{ .id = 2, .text = "▸2 agent" }};
    m.pane_labels = &labels;

    var buf: [512]u8 = undefined;
    const cells = m.fillGrid(80, 14);

    var saw_claude = false;
    var saw_dash = false;
    for (0..14) |r| {
        const t = gridText(cells, 80, r, &buf);
        if (std.mem.indexOf(u8, t, "claude") != null) {
            saw_claude = true;
            try testing.expect(std.mem.indexOf(u8, t, "188") != null);
            try testing.expect(std.mem.indexOf(u8, t, "▸2 agent") != null);
        }
        // A refused process shows an em dash, never 0.0 — which would
        // claim it was idle when it merely would not answer.
        if (std.mem.indexOf(u8, t, "mds") != null) {
            saw_dash = true;
            try testing.expect(std.mem.indexOf(u8, t, "—") != null);
            try testing.expect(std.mem.indexOf(u8, t, "0.0") == null);
        }
    }
    try testing.expect(saw_claude);
    try testing.expect(saw_dash);
}
