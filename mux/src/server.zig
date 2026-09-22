//! The engine's server: windows of panes, clients, one poll loop.
//! Reader threads parse pty output into each pane's Terminal and poke
//! the self-pipe; this loop snapshots dirty panes and ships frames —
//! dirty rows only, unless something structural (attach, resize,
//! layout, focus, window switch) forces a full repaint.
const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");
const panepkg = @import("pane.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const chromepkg = @import("chrome.zig");
const companionpkg = @import("companion.zig");
const statefeed = @import("statefeed.zig");
const proto = @import("proto.zig");
const config = @import("config.zig");
const altpkg = @import("altitude.zig");
const askpkg = @import("ask.zig");
const homepkg = @import("home.zig");
const ui = @import("ui.zig");

// CLOCK_UPTIME_RAW = 8 on macOS; libc-only monotonic clock.
extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
fn nowUs() i64 {
    return @intCast(clock_gettime_nsec_np(8) / 1_000);
}
fn nowMs() i64 {
    return @intCast(clock_gettime_nsec_np(8) / 1_000_000);
}

/// Minimum gap between frames: coalesce a burst (telescope popup,
/// build spew) into ~120fps of frames instead of one per pty read.
const frame_gap_ms: i64 = 8;

/// The side panel folds rather than crowd the work: under this much
/// glass the open panel falls back to the collapsed rail (three
/// columns of dots), and it always leaves the window at least
/// `min_window_cols` columns whatever it is showing.
const min_cols_for_side: u16 = 100;
const min_window_cols: u16 = 60;

/// How many agents rook will list from its own pane table — one row
/// per workspace, so this is a workspace count, and a rail is a couple
/// of dozen rows before it stops being readable anyway.
const max_found: usize = 24;

/// How often the pane table is walked for agents. `fgName` is two
/// syscalls a pane, and whether a Claude session exists moves at human
/// rate — the same cadence, for the same reason, as the state feed's
/// drift pass.
const found_every_ms: i64 = 2000;

const Client = struct {
    fd: ptypkg.fd_t,
    reader: proto.Reader,
    cols: u16 = 80,
    rows: u16 = 24,
    attached: bool = false,
    prefix: bool = false,
    /// Outbound frames the socket would not take without blocking; the
    /// loop drains it on POLLOUT. A stalled glass must never stall the
    /// server (tmux relearned this one the hard way).
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    dead: bool = false,
    /// Attached to a single block instead of the composed TUI: raw
    /// pty bytes flow down, stdin routes straight to the pane.
    block: ?u32 = null,
    /// Asked for the block table once: gets pushes when it changes.
    wants_blocks: bool = false,
    /// Subscribed to the state feed. `state_queued` marks a snapshot
    /// owed but not yet written — a second change while one is queued
    /// replaces it rather than piling up, which is why the feed can
    /// never stall the poll loop behind a slow reader.
    wants_state: bool = false,
    state_queued: bool = false,
    /// Holds this block's geometry: its resizes win, the TUI layout
    /// stops resizing the pane, everyone else crops.
    lease: bool = false,
    /// Where this glass is in a bracketed paste. Per client, because
    /// the markers arrive on its stdin, and across reads, because a
    /// long paste is split by every 4 KB the glass manages to read.
    paste: Paste = .{},
};

/// A bracketed paste on the way in, as the glass sends it: ESC[200~
/// text ESC[201~. Between the markers the bytes are content, not
/// keys — a backtick in pasted text is a backtick, not the prefix,
/// and rook must not spend the character after it on a command. The
/// glass wraps a paste only when the focused pane asked for brackets
/// (the server mirrors mode 2004 onto it), so the markers are exactly
/// as trustworthy as the pane's own request for them.
///
/// One matcher does both markers: which one it is looking for is
/// whichever the paste state calls for. It runs a byte at a time and
/// keeps its place between reads, so a marker split across two reads
/// still lands.
const Paste = struct {
    active: bool = false,
    /// how many bytes of the marker in play have matched so far
    mark: u8 = 0,

    const begin = "\x1b[200~";
    const end = "\x1b[201~";

    /// Feed one byte; true when the marker in play just completed,
    /// which is also when the paste opens or closes.
    fn step(self: *Paste, b: u8) bool {
        const pat: []const u8 = if (self.active) end else begin;
        if (b == pat[self.mark]) {
            self.mark += 1;
            if (self.mark < pat.len) return false;
            self.mark = 0;
            self.active = !self.active;
            return true;
        }
        // neither marker overlaps itself, so a mismatch can only
        // restart the match at this very byte
        self.mark = if (b == pat[0]) 1 else 0;
        return false;
    }

    /// A byte the server spent on something else — a command, a mouse
    /// report, a scroll key — cannot be part of a marker.
    fn reset(self: *Paste) void {
        self.mark = 0;
    }

    /// Inside a paste: how many bytes at the head of `bytes` are still
    /// content — through the closing marker, or all of them.
    fn take(self: *Paste, bytes: []const u8) usize {
        for (bytes, 0..) |b, i| if (self.step(b)) return i + 1;
        return bytes.len;
    }
};

/// How far the next run of ordinary input goes before the server has
/// to look at a byte itself: to the prefix key, to a mouse report, or
/// to just past a paste's opening marker — whichever comes first,
/// else all of it. Pure, so the paste rules are testable without a
/// server behind them.
fn runEnd(p: *Paste, rest: []const u8, prefix_key: u8) usize {
    for (rest, 0..) |b, i| {
        // the mouse report is the one escape sequence the server reads
        // itself; every other escape belongs to the pane
        if (b == 0x1b and i > 0 and i + 2 < rest.len and rest[i + 1] == '[' and rest[i + 2] == '<') return i;
        if (p.step(b)) return i + 1;
        // a byte partway through a marker is not a key, whatever it
        // happens to spell
        if (p.mark > 0) continue;
        if (b == prefix_key and i > 0) return i;
    }
    return rest.len;
}

/// A global pin remembers the space it was promoted out of.
const PinOrigin = struct {
    pane: u32,
    name: [32]u8 = @splat(0),
    len: usize = 0,
    fn label(self: *const PinOrigin) []const u8 {
        return self.name[0..self.len];
    }
};

/// A client more than 32MB behind is not consuming; cut it loose.
const max_client_backlog = 32 * 1024 * 1024;

/// One window: its own split tree, focus, and zoom state. Panes live
/// on the server; the window only holds ids.
const Window = struct {
    layout: layoutpkg.Layout,
    focused: u32 = 0,
    zoomed: bool = false,
    /// Wall-clock ms this window was last the one on the glass. Output
    /// stamped after it is output nobody has seen, which is the whole
    /// of what the tab bar's unread dot means. Advanced every frame
    /// the window is current, so "seen" tracks looking rather than
    /// switching.
    seen_ms: i64 = 0,
    /// The tab's name, minted once (docs/altitude.md, resolution 6):
    /// a name a person gave, else the first program in it that was
    /// not the shell. The engine never changes a minted name for
    /// itself; a namer may offer a better one (`suggestName`), and
    /// only where a person has not spoken. The activity glyph and the
    /// actor suffix change freely around it. Until it is minted the
    /// tab reads the live program.
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    named: bool = false,
    /// Whose word the name is. A person's (`hand`) is final: nothing
    /// but another rename by hand changes it. A `program` name — the
    /// first program that spoke — and a `model` name — a namer's
    /// suggestion, `rook rename --suggest` — are rook's best guess,
    /// and a better guess may replace them.
    name_by: NameBy = .none,

    pub fn label(self: *const Window) []const u8 {
        return self.name[0..self.name_len];
    }
    fn setName(self: *Window, n: []const u8) void {
        self.name_len = @min(n.len, self.name.len);
        @memcpy(self.name[0..self.name_len], n[0..self.name_len]);
    }
};

pub const NameBy = enum {
    none,
    program,
    model,
    hand,

    pub fn word(self: NameBy) []const u8 {
        return @tagName(self);
    }
};

/// A named workspace: its own windows and current-window index. All
/// attached clients view the server's current session — the one-glass
/// model; per-client views arrive with the structured cell protocol.
const Session = struct {
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    windows: std.ArrayList(*Window) = .empty,
    cur: usize = 0,
    /// Panes docked to the left rail of this workspace: visible in
    /// every window, stacked vertically, one shared width.
    pins: std.ArrayList(u32) = .empty,
    rail_frac: f32 = 0.4,
    /// Focus lives either on a pinned pane (here) or on the current
    /// window's focused leaf.
    focus_pin: ?u32 = null,
    /// Where focus was before the last move — prefix-; goes back.
    last_focus: ?u32 = null,

    pub fn label(self: *const Session) []const u8 {
        return self.name[0..self.name_len];
    }
    fn setName(self: *Session, n: []const u8) void {
        self.name_len = @min(n.len, self.name.len);
        @memcpy(self.name[0..self.name_len], n[0..self.name_len]);
    }
};

/// input→frame latency samples, ring of 512.
const Lat = struct {
    samples: [512]i64 = @splat(0),
    n: usize = 0,
    total: u64 = 0,
    mark: i64 = 0, // 0 = no input awaiting a frame

    fn note(self: *Lat) void {
        if (self.mark == 0) self.mark = nowUs();
    }
    fn frame(self: *Lat) void {
        if (self.mark == 0) return;
        self.samples[self.n % self.samples.len] = nowUs() - self.mark;
        self.n += 1;
        self.total += 1;
        self.mark = 0;
    }
    fn pct(self: *Lat, p: f64) i64 {
        const count = @min(self.n, self.samples.len);
        if (count == 0) return 0;
        var sorted: [512]i64 = undefined;
        @memcpy(sorted[0..count], self.samples[0..count]);
        std.mem.sort(i64, sorted[0..count], {}, std.sort.asc(i64));
        const idx: usize = @intFromFloat(@as(f64, @floatFromInt(count - 1)) * p);
        return sorted[idx];
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: ptypkg.fd_t,
    sock_path: []const u8,
    prefix_key: u8,
    conf: config.Mux = .{},
    /// The design system's roles, built once from the config's accent
    /// (docs/ui-design-system.md). Every chrome painter reads it.
    ui: ui.Theme = .{},
    panes: std.ArrayList(*panepkg.Pane) = .empty,
    sessions: std.ArrayList(*Session) = .empty,
    cur_sess: usize = 0,
    /// Pins that follow you across workspaces (prefix-G on a pin).
    global_pins: std.ArrayList(u32) = .empty,
    /// Where each global pin came from: the space it was promoted
    /// out of, so the dock can say `⊕g claude · from vera` at
    /// altitude. Parallel to nothing — looked up by pane id.
    pin_origins: std.ArrayList(PinOrigin) = .empty,
    /// Column of the rail/window seam in the current layout, if any,
    /// and the row it starts on.
    dock_x: ?u16 = null,
    dock_top: u16 = 0,
    /// Where the top tab bar starts. The side panel and global
    /// (app-chrome) pins push it right past their seams; with neither,
    /// the bar stays at column 0.
    tab_x: u16 = 0,
    /// The clickable runs of the tab bar as it was last painted, in
    /// bar-relative columns: one per chip, then the `+`. Recorded by
    /// the painter, read by the mouse — a click acts on the bar that
    /// is on the glass, never on one it would draw next.
    tab_zones: [chromepkg.max_tab_zones]chromepkg.TabZone = @splat(.{ .x = 0, .w = 0, .target = .new }),
    tab_zones_n: usize = 0,
    /// The side panel — spaces over agents down the left edge. Chrome
    /// the mux draws itself, so it costs no pty and survives every
    /// window and workspace switch. `side_w` is its width in the
    /// current layout, null when it is off or the glass is too narrow.
    /// What it *says* is pushed in from outside (`c2s.side`); the mux
    /// holds the last model per surface and paints it.
    side: chromepkg.Feed,
    /// How much of the rail is showing: the panel, the collapsed rail
    /// of dots, or nothing (`prefix-a` cycles, `prefix-A` jumps to the
    /// far end). It starts where `[mux] sidebar_mode` says.
    side_mode: chromepkg.SideMode = .open,
    /// The mode as it is actually painted: `side_mode` folded down by
    /// the glass it has to fit on. `.hidden` whenever `side_w` is null.
    side_shown: chromepkg.SideMode = .open,
    side_w: ?u16 = null,
    /// Agents rook found for itself: a workspace holding a pane whose
    /// foreground program is one of `conf.agents` gets a row on the
    /// agents rail, marked manual, whether or not any producer knows
    /// about it. It is the one thing the mux supplies to its own rail,
    /// and it supplies only what it can see in its own pane table —
    /// that a session is here, never what it is doing. `found_buf`
    /// backs the strings the items point at.
    found: [max_found]chromepkg.Item = @splat(.{ .name = "" }),
    found_n: usize = 0,
    found_buf: [max_found * 64]u8 = @splat(0),
    found_len: usize = 0,
    found_ms: i64 = 0,
    /// The agents panel as painted: pushed rows, then found ones.
    agents_merge: chromepkg.Merge = .{},
    /// Workspaces rook holds, as rows for the spaces panel: rook's
    /// own state, listed so an unfed rail still says what is open and
    /// which is current. A producer claims one with `workspace` on a
    /// pushed row, the same one-way merge the agents panel uses.
    /// Names point at the sessions themselves; only a subtitle needs
    /// backing here.
    spaces_merge: chromepkg.Merge = .{},
    found_ws: [max_found]chromepkg.Item = @splat(.{ .name = "" }),
    found_ws_n: usize = 0,
    found_ws_sub: [max_found][64]u8 = @splat(@splat(0)),
    /// The companion: which panes are running the one program the
    /// config names as the resident (vera first), and since when.
    /// Walked on the same 2s cadence as the agents scan, for the same
    /// reason — `fgName` is two syscalls a pane, and whether she is
    /// open moves at human rate. Nothing on the glass reads this: it
    /// exists so the state feed can answer *when and where* the
    /// companion is open, which is a question about rook that only
    /// rook can answer.
    comp: companionpkg.Watch = .{},
    next_id: u32 = 1,
    clients: std.ArrayList(*Client) = .empty,
    wake_r: ptypkg.fd_t,
    wake_w: ptypkg.fd_t,
    frame: renderpkg.Frame,
    placed: std.ArrayList(layoutpkg.Placed) = .empty,
    shell: [:0]const u8,
    cwd: ?[:0]const u8,
    /// Something structural changed; the next frame repaints all.
    full: bool = true,
    pending: bool = false,
    shutdown: bool = false,
    /// Copy mode (prefix-[): a mux-owned cursor walks the focused
    /// pane and its scrollback; v anchors a selection, y yanks it to
    /// the clipboard. Plain keys navigate until q/Esc.
    scrolling: bool = false,
    scur: struct { x: u16, y: u16 } = .{ .x = 0, .y = 0 },
    selecting: bool = false,
    /// Where the composed cursor last landed on the glass. A bare
    /// cursor move (backspace over trailing blanks emits a lone \b, so
    /// no cell changes) must still ship a frame, or the cursor freezes
    /// until the next content change. Row-dirty alone misses this.
    last_cursor: ?struct { id: u32, x: u16, y: u16, vis: bool } = null,
    /// After a resize the app repaints on SIGWINCH over the next few
    /// ms; that repaint can land in a frame gap or dirty no new cells,
    /// leaving the glass showing the pre-repaint reflow until the next
    /// keypress. A deferred full repaint flushes the settled result.
    /// 0 = none; else the ms deadline to force `full`.
    refresh_at: i64 = 0,
    lat: Lat = .{},
    frames_sent: u64 = 0,
    bytes_sent: u64 = 0,
    started_ms: i64 = 0,
    drag: ?Drag = null,
    /// Kitty keyboard flags currently set on the glass; mirrors the
    /// focused pane so apps that pushed the protocol get real kitty
    /// input, and everything else gets legacy bytes.
    glass_kitty: u8 = 0,
    glass_paste: bool = false,
    glass_focus: bool = false,
    glass_title: [128]u8 = @splat(0),
    glass_title_len: usize = 0,
    /// A floating pane over the current window: all input goes to it,
    /// it closes when its process exits. One at a time.
    popup: ?u32 = null,
    popup_pct: [2]u8 = .{ 80, 84 },
    /// The most cells a popup takes, width and height; 0 is no limit.
    /// A percentage of a big glass is a takeover; a conversation wants
    /// a surface with room around it.
    popup_max: [2]u16 = .{ 0, 0 },
    /// The bars as last shipped. A mark appearing on a hidden window's
    /// tab, a window opened from the front door, a count changing on
    /// the calm bar: none of it dirties a pane cell, so the bars are
    /// composed on every wake and compared, and a change ships a frame.
    tabbar_last: [2048]u8 = undefined,
    tabbar_last_len: usize = 0,
    bar_last: [2048]u8 = undefined,
    bar_last_len: usize = 0,
    /// The workspace before the last switch — prefix-C-o goes back
    /// after any cross-space hop, from wherever the hop was made.
    last_sess: ?usize = null,
    /// The scope: rook's home (the root, where a glass lands) or a
    /// space. At the root the canvas is painted over the window
    /// region while the panes keep running underneath. `alt` is the
    /// root's own state — view, draft, cursor, request — and it
    /// outlives a visit to a space; `alt_placed` is the rects still
    /// drawn live at the root: the global pins, which do not move.
    at_root: bool = false,
    alt: altpkg.State = .{},
    /// Whether the ask command can be found, as of the last look.
    ask_on: bool = false,
    /// Vera's pane holds the keyboard inside a space.
    vera_keys: bool = false,
    /// The companion's own terminal, hosted in her panel: a real pty
    /// running `[companion] chat`, sized to the panel and nothing
    /// else. It is not in any window's layout and never takes the
    /// window focus — it is rook's, the way the popup is. Null when
    /// no chat is configured, the command is not on PATH, or the
    /// program has quit; the panel then keeps rook's own surface.
    /// Started on her first summoning and kept alive after: the
    /// thread, the scroll and the draft are the program's, and a
    /// program that is still running has not lost them.
    vera_pane: ?u32 = null,
    /// Whether the chat command can be found, as of the last look.
    chat_on: bool = false,
    /// Her terminal quit, and rook does not start another on its own.
    /// A command that fails the moment it starts — a verad that is not
    /// there, a binary half-installed — would otherwise be restarted
    /// on every frame forever, and the panel would show a program
    /// dying too fast to read. The panel falls back to rook's own
    /// surface with what the program last said, and prefix-t at her
    /// is the person asking for another try.
    vera_dead: bool = false,
    prefix_name_buf: [8]u8 = undefined,
    alt_placed: std.ArrayList(layoutpkg.Placed) = .empty,
    /// A second frame builder for what the server paints over the
    /// panes itself: the altitude view, the ownership gate, the
    /// inspector. Its bytes ride the main frame as `Chrome.overlay`.
    over: renderpkg.Frame,
    /// The ownership gate: a key was typed at a pane an actor owns,
    /// and instead of forwarding it the glass shows the three legal
    /// moves. `gate_pass` is the `s` move — the next keystrokes,
    /// through Enter, go to the pane as a message.
    gate: bool = false,
    gate_pass: bool = false,
    /// prefix-i: the focused pane's provenance and input ownership,
    /// in a box. Any key closes it.
    inspect: bool = false,
    /// `rook notify`: one line said to the person on the calm bar,
    /// with a mark. It stays until a keystroke arrives after it has
    /// been up long enough to have been read — a person away from the
    /// desk finds it when they come back; a person typing is not
    /// interrupted, and does not lose it to the key they were already
    /// pressing. A newer notice replaces it.
    notice: [240]u8 = @splat(0),
    notice_len: usize = 0,
    notice_mark: ui.Mark = .none,
    notice_ms: i64 = 0,
    /// Resurrect file: sessions/windows/cwds, saved on structural
    /// change (debounced), restored on server boot. Scrollback is not
    /// saved — that's the event log's job, later.
    state_path: [1024]u8 = @splat(0),
    state_tmp: [1024]u8 = @splat(0),
    state_dirty: bool = false,
    state_saved_ms: i64 = 0,
    /// Last block table sent to subscribers; pushes happen on change.
    blocks_last: std.ArrayList(u8) = .empty,
    /// The state feed. `epoch` identifies this server across restarts
    /// (a consumer that reconnects across a `rook kill` must discard,
    /// not merge); `serial` orders changes and is what a command
    /// returns so its caller can wait for its own write to land.
    epoch: [8]u8 = @splat('0'),
    serial: u64 = 0,
    pid: i32 = 0,
    state_json: std.ArrayList(u8) = .empty,
    state_last: std.ArrayList(u8) = .empty,
    state_check_ms: i64 = 0,
    /// Liveness pushes on their own 2s cadence: `lastOutputMs` moves
    /// with every pty batch, and a running build must not push a
    /// snapshot to every subscriber twenty times a second.
    /// Drift (foreground program, cwd, activity stamp) is looked at on
    /// its own 2s cadence: a shell loop respawns its child faster than
    /// the poll floor, so diffing on it would push a snapshot to every
    /// subscriber twenty times a second for as long as a build runs.
    state_drift_last: std.ArrayList(u8) = .empty,
    state_drift_ms: i64 = 0,
    blocks_check_ms: i64 = 0,

    pub fn run(gpa: std.mem.Allocator, io: std.Io, sock_path: []const u8, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
        // A socket file with a live server behind it means we must not
        // start; one nobody answers is a stale leftover (crash,
        // reboot) — clear it instead of failing to bind.
        const probe = ptypkg.unixConnect(sock_path);
        if (probe >= 0) {
            ptypkg.closeFd(probe);
            std.debug.print("rook: a server already runs on {s}\n", .{sock_path});
            return error.AlreadyRunning;
        }
        ptypkg.unlinkPath(sock_path);

        const listener = ptypkg.unixListen(sock_path);
        if (listener < 0) {
            std.debug.print("rook: cannot listen on {s} (unix socket paths max ~100 bytes)\n", .{sock_path});
            return error.ListenFailed;
        }
        defer ptypkg.closeFd(listener);

        const pipefds = ptypkg.makePipeNb() orelse return error.PipeFailed;

        // Panes inherit the socket path so `rook nav` (the nvim
        // plugin's edge handoff) talks to the right server.
        const sock_z = try gpa.dupeZ(u8, sock_path);
        defer gpa.free(sock_z);
        ptypkg.setEnv("ROOK_MUX_SOCK", sock_z.ptr);

        var self: Server = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .sock_path = sock_path,
            .prefix_key = config.prefixKey(),
            .conf = config.muxConfig(),
            .wake_r = pipefds[0],
            .wake_w = pipefds[1],
            .frame = renderpkg.Frame.init(gpa),
            .over = renderpkg.Frame.init(gpa),
            .side = chromepkg.Feed.init(gpa),
            .shell = shell,
            .cwd = cwd,
            .started_ms = nowMs(),
        };
        defer self.deinitAll();

        // state file lives beside the socket
        if (std.fmt.bufPrintZ(self.state_path[0 .. self.state_path.len - 1], "{s}.state", .{sock_path})) |_| {
            _ = std.fmt.bufPrintZ(self.state_tmp[0 .. self.state_tmp.len - 1], "{s}.state.tmp", .{sock_path}) catch {};
        } else |_| {}

        self.ui = ui.Theme.init(self.conf.accent, if (self.conf.ascii_glyphs) .ascii else .unicode);
        self.frame.accent = self.ui.border_focused;
        self.frame.border = self.ui.border;
        self.over.accent = self.ui.border_focused;
        self.over.border = self.ui.border;
        self.side.accent = self.conf.accent;
        self.side_mode = self.conf.side_mode;
        self.pid = ptypkg.selfPid();
        _ = std.fmt.bufPrint(&self.epoch, "{x:0>8}", .{
            @as(u32, @truncate(@as(u64, @bitCast(nowMs())) *% 2654435761 ^ @as(u64, @intCast(self.pid)))),
        }) catch {};
        // Resurrect only when asked ([mux] restore = true); otherwise a
        // fresh boot opens a clean workspace instead of last session's
        // splits. The state file is still saved, so opting in restores.
        const restored = self.conf.restore and try self.restoreState();
        if (!restored) _ = try self.newSession("main", null, null, true);
        // Rook lands at home. The spaces are restored underneath it,
        // running; `startup = "last-space"` is the opt-in that lands
        // in the space the server was showing instead.
        self.at_root = !self.conf.startup_last_space;
        self.alt.view = .home;
        self.ask_on = askpkg.available(self.conf.askSlice());
        self.chat_on = askpkg.available(self.conf.chatSlice());
        try self.loop();
    }

    fn deinitAll(self: *Server) void {
        for (self.clients.items) |c| {
            ptypkg.closeFd(c.fd);
            c.reader.deinit();
            c.out.deinit(self.gpa);
            self.gpa.destroy(c);
        }
        self.clients.deinit(self.gpa);
        for (self.panes.items) |p| p.hangup();
        for (self.panes.items) |p| p.deinit();
        self.panes.deinit(self.gpa);
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                w.layout.deinit();
                self.gpa.destroy(w);
            }
            sn.windows.deinit(self.gpa);
            sn.pins.deinit(self.gpa);
            self.gpa.destroy(sn);
        }
        self.sessions.deinit(self.gpa);
        self.global_pins.deinit(self.gpa);
        self.pin_origins.deinit(self.gpa);
        self.frame.deinit();
        self.over.deinit();
        self.alt.rows.deinit(self.gpa);
        self.alt_placed.deinit(self.gpa);
        self.side.deinit();
        self.agents_merge.deinit(self.gpa);
        self.spaces_merge.deinit(self.gpa);
        self.placed.deinit(self.gpa);
        self.blocks_last.deinit(self.gpa);
        self.state_json.deinit(self.gpa);
        self.state_last.deinit(self.gpa);
        self.state_drift_last.deinit(self.gpa);
        ptypkg.unlinkPath(self.sock_path);
    }

    // ---- windows and panes ----

    fn sess(self: *Server) *Session {
        return self.sessions.items[self.cur_sess];
    }

    fn window(self: *Server) *Window {
        const sn = self.sess();
        return sn.windows.items[sn.cur];
    }

    /// Create a session named `name` (deduped — an existing name is a
    /// switch) and make it current. `cwd` seeds the first window; null
    /// falls back to the server default.
    /// Create (or find) a workspace. `show` false builds it without
    /// changing which workspace the person is looking at — the quiet
    /// form the fleet spawns into.
    /// A workspace, made if rook does not hold one by that name. cmd,
    /// when given, is the program its first pane is born running — the
    /// tmux shape, `new -s x claude` — and the pane remembers it as the
    /// way back after a restart until the program says better.
    fn newSession(self: *Server, name: []const u8, cwd: ?[*:0]const u8, cmd: ?[*:0]const u8, show: bool) !*Session {
        for (self.sessions.items, 0..) |sn, i| {
            if (std.mem.eql(u8, sn.label(), name)) {
                if (show) self.switchSession(i);
                return sn;
            }
        }
        const sn = try self.gpa.create(Session);
        sn.* = .{};
        sn.setName(name);
        try self.sessions.append(self.gpa, sn);
        const was = self.cur_sess;
        const old_focused: ?u32 = if (self.sessions.items.len > 1) self.window().focused else null;
        self.cur_sess = self.sessions.items.len - 1;
        try self.newWindow(cwd, cmd);
        if (show) {
            if (old_focused) |o| self.focusEvents(o, self.window().focused);
        } else if (self.sessions.items.len > 1) {
            // Put the view back. newWindow built the pane against this
            // workspace's geometry, so relayout has to run again for the
            // one we are actually showing.
            self.cur_sess = was;
            try self.relayout();
        }
        _ = self.touch();
        return sn;
    }

    /// Close the named session: hang up every pane in it; reap does
    /// the accounting and the view falls back if it was current.
    fn closeSession(self: *Server, name: []const u8) void {
        for (self.sessions.items) |sn| {
            if (!std.mem.eql(u8, sn.label(), name)) continue;
            for (sn.windows.items) |w| {
                for (self.panes.items) |p| {
                    if (w.layout.contains(p.id)) p.hangup();
                }
            }
            return;
        }
    }

    fn switchSession(self: *Server, i: usize) void {
        if (i == self.cur_sess or i >= self.sessions.items.len) return;
        const old_focused = self.focusedId();
        self.last_sess = self.cur_sess;
        self.cur_sess = i;
        self.scrolling = false;
        self.selecting = false;
        // Switching to a space by name is going there: from home,
        // the picker's choice lands in the space, not on a row.
        self.enterSpace();
        // a workspace pin that no longer exists can't hold focus
        if (self.sess().focus_pin) |fp| {
            if (self.pane(fp) == null) self.sess().focus_pin = null;
        }
        self.focusEvents(old_focused, self.focusedId());
        self.relayout() catch {};
    }

    fn switchSessionNamed(self: *Server, name: []const u8) void {
        if (self.sessionNamed(name)) |i| self.switchSession(i);
    }

    /// The workspace holding this name, if rook holds one.
    fn sessionNamed(self: *Server, name: []const u8) ?usize {
        if (name.len == 0) return null;
        for (self.sessions.items, 0..) |sn, i| {
            if (std.mem.eql(u8, sn.label(), name)) return i;
        }
        return null;
    }

    fn newWindow(self: *Server, cwd_override: ?[*:0]const u8, cmd: ?[*:0]const u8) !void {
        const sn = self.sess();
        // a window is seen when it is made: its first prompt is not news
        // an explicit cwd wins; otherwise inherit from what the user
        // is looking at now
        var cwd_buf: [1024]u8 = undefined;
        const cwd = cwd_override orelse (if (sn.windows.items.len > 0) self.focusedCwd(&cwd_buf) else null);
        const prev_focused: ?u32 = if (sn.windows.items.len > 0) self.window().focused else null;
        const w = try self.gpa.create(Window);
        w.* = .{ .layout = layoutpkg.Layout.init(self.gpa), .seen_ms = panepkg.epochMs() };
        try sn.windows.append(self.gpa, w);
        sn.cur = sn.windows.items.len - 1;
        const p = try self.startPane(cwd, cmd);
        if (cmd) |c| p.setResume(std.mem.span(c));
        try w.layout.seed(p.id);
        w.focused = p.id;
        if (prev_focused) |old_id| self.focusEvents(old_id, p.id);
        try self.relayout();
    }

    fn startPane(self: *Server, cwd: ?[*:0]const u8, cmd: ?[*:0]const u8) !*panepkg.Pane {
        const g = self.geometry();
        const dir: ?[*:0]const u8 = cwd orelse if (self.cwd) |c| c.ptr else null;
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, dir, g.cols, self.bodyRows() -| 1, self.wake_w, self.next_id, cmd, self.conf.scrollback_bytes);
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        return p;
    }

    /// The popup's outer box, centered: 60% of the screen, clamped.
    /// The rows under the tab bar's row and above the calm bar: where
    /// windows, rails, the side panel and the altitude view live. The
    /// bar is app chrome like the tab bar, so everything else is laid
    /// out inside what it leaves.
    pub fn bodyRows(self: *Server) u16 {
        const g = self.geometry();
        return if (self.barOn()) g.rows -| 1 else g.rows;
    }

    /// The calm bar is on unless the config turned it off, and never
    /// on a glass too short to spare the row.
    pub fn barOn(self: *Server) bool {
        return self.conf.bar and self.geometry().rows >= 8;
    }

    fn popupRect(self: *Server) layoutpkg.Rect {
        const g = self.geometry();
        const rows = self.bodyRows() -| 1;
        var w: u16 = @max(@min(g.cols, 30), @as(u16, @intCast(@as(u32, g.cols) * self.popup_pct[0] / 100)));
        var h: u16 = @max(@min(rows, 8), @as(u16, @intCast(@as(u32, rows) * self.popup_pct[1] / 100)));
        if (self.popup_max[0] > 0) w = @min(w, self.popup_max[0]);
        if (self.popup_max[1] > 0) h = @min(h, self.popup_max[1]);
        return .{ .x = (g.cols -| w) / 2, .y = (rows -| h) / 2, .w = w, .h = h };
    }

    /// A popup's share of the glass, width and height, in percent. A
    /// picker is happy at the default; something a person reads and
    /// types in for minutes — grim — asks for more (`rook popup --size
    /// 70x85 …`, which arrives as a `\x1fWxH\x1f` prefix on the command
    /// so that a request without one is exactly what it always was).
    /// `WxH@MWxMH` adds the most cells it should take: on a big glass
    /// a conversation is a surface with room around it, not a takeover.
    const popup_default = [2]u8{ 80, 84 };

    fn popupSized(self: *Server, payload: []const u8) []const u8 {
        const p = popupSize(payload);
        self.popup_pct = p.pct;
        self.popup_max = p.max;
        return p.cmd;
    }

    /// Pure: a popup request taken apart — its size, its limit, and its command.
    pub fn popupSize(payload: []const u8) struct { pct: [2]u8, max: [2]u16, cmd: []const u8 } {
        const none = [2]u16{ 0, 0 };
        if (payload.len < 2 or payload[0] != 0x1f) return .{ .pct = popup_default, .max = none, .cmd = payload };
        const end = std.mem.indexOfScalarPos(u8, payload, 1, 0x1f) orelse return .{ .pct = popup_default, .max = none, .cmd = payload };
        var halves = std.mem.splitScalar(u8, payload[1..end], '@');
        var it = std.mem.splitScalar(u8, halves.next() orelse "", 'x');
        const w = std.fmt.parseInt(u8, it.next() orelse "", 10) catch popup_default[0];
        const h = std.fmt.parseInt(u8, it.next() orelse "", 10) catch popup_default[1];
        var max = none;
        if (halves.next()) |lim| {
            var li = std.mem.splitScalar(u8, lim, 'x');
            max[0] = std.fmt.parseInt(u16, li.next() orelse "", 10) catch 0;
            max[1] = std.fmt.parseInt(u16, li.next() orelse "", 10) catch 0;
        }
        return .{ .pct = .{ std.math.clamp(w, 30, 100), std.math.clamp(h, 30, 100) }, .max = max, .cmd = payload[end + 1 ..] };
    }

    /// How long a notice is held before a keystroke may dismiss it.
    const notice_hold_ms: i64 = 8000;

    /// `[mark u8][text]`: say a line on the calm bar. The mark is one
    /// letter — s finished well, f failed, a needs you, u there is
    /// something to see — and anything else is no mark at all.
    fn notify(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 2) return;
        const text = std.mem.trim(u8, payload[1..], " \t\r\n");
        if (text.len == 0) return;
        // one line: the first, cut on a codepoint boundary
        const line = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
        const kept = chromepkg.clip(line, @intCast(self.notice.len));
        @memcpy(self.notice[0..kept.len], kept);
        self.notice_len = kept.len;
        self.notice_mark = noticeMark(payload[0]);
        self.notice_ms = nowMs();
        _ = self.touch();
        self.ack(c);
        self.full = true;
        self.pending = true;
    }

    /// Pure: the letter a notice carries, as a mark.
    pub fn noticeMark(letter: u8) ui.Mark {
        return switch (letter) {
            's' => .success,
            'f' => .failed,
            'a' => .attention,
            'u' => .unread,
            else => .none,
        };
    }

    /// A keystroke after the hold: the notice has been read.
    fn noticeSeen(self: *Server) void {
        if (self.notice_len == 0 or nowMs() - self.notice_ms < notice_hold_ms) return;
        self.notice_len = 0;
        self.notice_mark = .none;
        self.full = true;
        self.pending = true;
    }

    fn openPopup(self: *Server, cmd: []const u8) !void {
        if (self.popup) |id| {
            // one at a time: a second request replaces the first
            if (self.pane(id)) |p| p.hangup();
        }
        var cwd_buf: [1024]u8 = undefined;
        const cwd = self.focusedCwd(&cwd_buf);
        const r = self.popupRect();
        const cmd_z = try self.gpa.dupeZ(u8, cmd);
        defer self.gpa.free(cmd_z);
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, cwd orelse (if (self.cwd) |c| c.ptr else null), r.w -| 2, r.h -| 2, self.wake_w, self.next_id, cmd_z.ptr, self.conf.scrollback_bytes);
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        self.popup = p.id;
        self.scrolling = false;
        self.full = true;
        self.pending = true;
    }

    fn popupPane(self: *Server) ?*panepkg.Pane {
        const id = self.popup orelse return null;
        return self.pane(id);
    }

    // ---- the companion's own terminal ----

    /// The hosted chat, when there is one. Every reader goes through
    /// here, so a program that quit is a null and not a dangling id.
    pub fn veraChatPane(self: *Server) ?*panepkg.Pane {
        const id = self.vera_pane orelse return null;
        return self.pane(id);
    }

    /// A pane rook owns rather than a person's: the popup, and the
    /// companion's terminal. Neither is somewhere focus can be sent,
    /// neither is work, and neither belongs in a count of what is
    /// running or unread.
    fn ownPane(self: *Server, id: u32) bool {
        return self.popup == id or self.vera_pane == id;
    }

    /// Where vera's panel is this frame, whichever scope we are in.
    /// Null when she is not on the glass.
    fn veraPanel(self: *Server) ?homepkg.Panel {
        const h = &self.alt.home;
        if (!h.veraShown()) return null;
        if (self.at_root) {
            if (self.alt.mode() != .intent or self.alt.view != .home) return null;
            return homepkg.veraPanel(self.altRegion(), h.vera_pinned, true, h.focus == .vera);
        }
        return homepkg.veraPanelOver(self.altRegion());
    }

    /// Start the chat if it should be running, and keep its pty the
    /// size of the panel it is drawn in. Called before every frame
    /// that could show her, and after every relayout: the one motion
    /// a hosted TUI cannot recover from is being told a geometry it
    /// was not given, so the resize goes through `homepkg.veraBody`,
    /// which is also what the painter draws into.
    /// True when something changed — the program was started, or its
    /// geometry moved — so the frame that follows is not skipped for
    /// want of a dirty cell.
    fn tendVera(self: *Server) bool {
        const panel = self.veraPanel() orelse return false;
        const body = homepkg.veraBody(panel.r, self.alt.home.about_title_len > 0);
        if (!homepkg.chatFits(body)) return false;
        var started = false;
        const p = self.veraChatPane() orelse blk: {
            const fresh = (self.startVeraPane(body) catch return false) orelse return false;
            started = true;
            break :blk fresh;
        };
        if (p.cols != body.w or p.rows != body.h) {
            p.resize(body.w, body.h);
            return true;
        }
        return started;
    }

    /// The chat, started the first time she is summoned. Nothing is
    /// started when the config turned the chat off or the command is
    /// not on PATH: the panel keeps rook's own surface, and says so.
    fn startVeraPane(self: *Server, body: layoutpkg.Rect) !?*panepkg.Pane {
        const cmd = self.conf.chatSlice();
        if (cmd.len == 0 or !self.chat_on or self.vera_dead) return null;
        const cmd_z = try self.gpa.dupeZ(u8, cmd);
        defer self.gpa.free(cmd_z);
        const p = try panepkg.Pane.start(
            self.gpa,
            self.io,
            self.shell.ptr,
            if (self.cwd) |c| c.ptr else null,
            body.w,
            body.h,
            self.wake_w,
            self.next_id,
            cmd_z.ptr,
            self.conf.scrollback_bytes,
        );
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        self.vera_pane = p.id;
        self.full = true;
        self.pending = true;
        return p;
    }

    /// What her terminal left on the glass, as one turn of the thread
    /// rook's own surface shows. `frame` is free here: reaping runs
    /// between frames, and the builder is refilled from nothing on
    /// the next one.
    fn noteVeraQuit(self: *Server, p: *panepkg.Pane) void {
        p.snapshot() catch {};
        const text = self.frame.plainText(p);
        // The last thing on the screen, and the rows above it that
        // are the same sentence: a terminal hard-wraps, so a line
        // that filled the width is continued by the one below it,
        // and taking only the bottom row would report the tail of a
        // message as the message.
        var rows: [64][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            if (n == rows.len) {
                std.mem.copyForwards([]const u8, rows[0 .. rows.len - 1], rows[1..]);
                n -= 1;
            }
            rows[n] = std.mem.trimEnd(u8, ln, " \t\r");
            n += 1;
        }
        var end = n;
        while (end > 0 and std.mem.trim(u8, rows[end - 1], " ").len == 0) end -= 1;
        var start = end;
        while (start > 0) {
            start -= 1;
            if (start == 0) break;
            if (rows[start - 1].len < p.cols) break;
        }
        var said: [homepkg.max_turn]u8 = undefined;
        var len: usize = 0;
        const head = std.fmt.bufPrint(&said, "{s} quit", .{self.askName()}) catch "quit";
        len = head.len;
        var first = true;
        for (rows[start..end]) |ln| {
            const t = std.mem.trim(u8, ln, " ");
            if (t.len == 0) continue;
            const sep: []const u8 = if (first) " — " else " ";
            if (len + sep.len + t.len > said.len) break;
            @memcpy(said[len..][0..sep.len], sep);
            len += sep.len;
            @memcpy(said[len..][0..t.len], t);
            len += t.len;
            first = false;
        }
        _ = self.alt.home.thread.push(.err, said[0..len], "", "", panepkg.epochMs());
    }

    /// She is being asked for. A terminal that quit is started again
    /// only here — by the asking, never by a frame.
    fn showVera(self: *Server) void {
        const h = &self.alt.home;
        if (!h.veraShown()) {
            h.vera_open = true;
            self.vera_dead = false;
        }
        h.focus = .vera;
    }

    /// Does vera hold the keyboard? At home that is the focused
    /// region; in a space it is the flag prefix-t sets. Only true
    /// while there is a program to hold it for.
    /// Hand a run of keys to the hosted chat. The run ends where the
    /// server wants a byte for itself — the prefix, a mouse report,
    /// the end of a paste's opening marker — so an escape sequence is
    /// never cut in half and a paste opens the same way it does for
    /// any other pane.
    fn toVera(self: *Server, c: *Client, vp: *panepkg.Pane, bytes: []const u8) usize {
        const end = runEnd(&c.paste, bytes, self.prefix_key);
        vp.write(bytes[0..end]);
        self.full = true;
        self.pending = true;
        return end;
    }

    fn veraHoldsKeys(self: *Server) bool {
        if (self.vera_pane == null) return false;
        if (!self.at_root) return self.vera_keys;
        const h = &self.alt.home;
        return self.alt.mode() == .intent and self.alt.view == .home and h.veraShown() and h.focus == .vera;
    }

    fn leasedBy(self: *Server, pane_id: u32) ?*Client {
        for (self.clients.items) |c| {
            if (c.block == pane_id and c.lease and !c.dead) return c;
        }
        return null;
    }

    /// Where the focused pane's foreground process lives — new panes
    /// open there, tmux -c '#{pane_current_path}' without the config.
    fn focusedCwd(self: *Server, buf: []u8) ?[*:0]const u8 {
        const p = self.focusedPane() orelse return null;
        const c = p.fgCwd(buf) orelse return null;
        return c.ptr;
    }

    fn splitPane(self: *Server, side_by_side: bool) !void {
        var cwd_buf: [1024]u8 = undefined;
        const cwd = self.focusedCwd(&cwd_buf);
        const w = self.window();
        w.zoomed = false;
        const p = try self.startPane(cwd, null);
        try w.layout.split(w.focused, p.id, side_by_side);
        self.setFocus(p.id);
        try self.relayout();
    }

    pub fn pane(self: *Server, id: u32) ?*panepkg.Pane {
        for (self.panes.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// The pane input goes to: a focused rail pane, else the current
    /// window's focused leaf.
    pub fn focusedId(self: *Server) u32 {
        const sn = self.sess();
        return sn.focus_pin orelse self.window().focused;
    }

    fn focusedPane(self: *Server) ?*panepkg.Pane {
        return self.pane(self.focusedId());
    }

    fn isPin(self: *Server, id: u32) bool {
        for (self.global_pins.items) |g| if (g == id) return true;
        for (self.sess().pins.items) |g| if (g == id) return true;
        return false;
    }

    /// Move focus to a pane — rail or window leaf — remembering where
    /// it came from, telling both panes, and repainting.
    fn setFocus(self: *Server, id: u32) void {
        const sn = self.sess();
        const old = self.focusedId();
        if (old == id) return;
        self.focusEvents(old, id);
        sn.last_focus = old;
        if (self.isPin(id)) {
            sn.focus_pin = id;
        } else {
            sn.focus_pin = null;
            self.window().focused = id;
        }
        self.full = true;
        self.pending = true;
    }

    pub fn geometry(self: *Server) proto.Geometry {
        var g: proto.Geometry = .{ .cols = 80, .rows = 24 };
        for (self.clients.items) |c| {
            if (c.attached) g = .{ .cols = c.cols, .rows = c.rows };
        }
        return g;
    }

    /// Recompute the current window's rects; push sizes into its panes.
    /// A zoomed window is one rect: the focused pane, full region.
    fn relayout(self: *Server) !void {
        const g = self.geometry();
        self.placed.clearRetainingCapacity();
        const w = self.window();
        const sn = self.sess();
        self.dock_x = null;
        self.dock_top = 0;
        self.tab_x = 0;
        self.side_w = null;
        self.side_shown = .hidden;
        // The side panel owns the far-left columns of the whole app: it
        // is above windows and workspaces, so it is subtracted before
        // anything else is placed, and it pushes the tab bar past its
        // seam. It folds to the collapsed rail rather than squeeze
        // the panes, and away entirely when even that would.
        if (self.side_mode != .hidden and g.rows >= chromepkg.min_rows) {
            // Open when there are columns for the words, and the
            // collapsed rail when there are not: three columns is
            // never the thing crowding the work, and the dots are
            // what the panel is for. Too narrow for even that is the
            // one case where the rail goes away without being asked.
            const want_open = self.side_mode == .open and g.cols >= min_cols_for_side;
            const sw = if (want_open)
                @min(self.conf.sidebar_width, g.cols -| min_window_cols)
            else
                chromepkg.collapsed_w;
            const fits = if (want_open) sw >= 16 else g.cols >= min_window_cols + sw + 1;
            if (fits) {
                self.side_w = sw;
                self.side_shown = if (want_open) .open else .collapsed;
                self.tab_x = sw + 1;
            }
        }
        const base_x: u16 = if (self.side_w) |sw| sw + 1 else 0;
        // Row 0 is the tab bar; the window area sits below it, and
        // above the calm bar when there is one.
        const body = self.bodyRows();
        const win_y: u16 = 1;
        const win_h: u16 = body -| 1;
        if (w.zoomed) {
            try self.placed.append(self.gpa, .{ .pane = self.focusedId(), .rect = .{ .x = base_x, .y = win_y, .w = g.cols -| base_x, .h = win_h } });
        } else {
            // The rail stacks global pins then this workspace's, down the
            // left edge of what the side panel left (hidden when that is
            // too narrow). Global pins are app-wide chrome: they run the
            // full height and push the tab bar right. Workspace-local
            // pins belong to the workspace, so they sit *under* the tab
            // bar and leave it as wide as the panel left it.
            const n_global = self.global_pins.items.len;
            const n_local = sn.pins.items.len;
            const n_rails = n_global + n_local;
            var win_x: u16 = base_x;
            const avail_w = g.cols -| base_x;
            if (n_rails > 0 and avail_w >= 60) {
                var rail_w: u16 = @intFromFloat(@as(f32, @floatFromInt(avail_w)) * sn.rail_frac);
                rail_w = @max(20, @min(rail_w, avail_w -| 40));
                const push = n_global > 0;
                const rail_top: u16 = if (push) 0 else win_y;
                const nr: u16 = @intCast(n_rails);
                const avail_h = body -| rail_top;
                const each: u16 = (avail_h -| (nr - 1)) / nr;
                var y: u16 = rail_top;
                var i: u16 = 0;
                for (self.global_pins.items) |id| {
                    const h = if (i == nr - 1) body -| y else each;
                    try self.placed.append(self.gpa, .{ .pane = id, .rect = .{ .x = base_x, .y = y, .w = rail_w, .h = h } });
                    y += h + 1;
                    i += 1;
                }
                for (sn.pins.items) |id| {
                    const h = if (i == nr - 1) body -| y else each;
                    try self.placed.append(self.gpa, .{ .pane = id, .rect = .{ .x = base_x, .y = y, .w = rail_w, .h = h } });
                    y += h + 1;
                    i += 1;
                }
                self.dock_x = base_x + rail_w;
                self.dock_top = rail_top;
                self.tab_x = if (push) base_x + rail_w + 1 else base_x;
                win_x = base_x + rail_w + 1;
            }
            const win_region: layoutpkg.Rect = .{ .x = win_x, .y = win_y, .w = g.cols -| win_x, .h = win_h };
            try w.layout.place(win_region, &self.placed);
        }
        for (self.placed.items) |pl| {
            if (self.leasedBy(pl.pane) != null) continue; // a block client owns this geometry; the TUI crops
            if (self.pane(pl.pane)) |p| {
                if (p.cols != pl.rect.w or p.rows != pl.rect.h) p.resize(pl.rect.w, pl.rect.h);
            }
        }
        if (self.popupPane()) |p| {
            const r = self.popupRect();
            if (p.cols != r.w -| 2 or p.rows != r.h -| 2) p.resize(r.w -| 2, r.h -| 2);
        }
        _ = self.tendVera();
        self.full = true;
        self.pending = true;
        self.state_dirty = true;
        self.blocks_check_ms = 0; // push the new table promptly
        // and a follow-up clean repaint once the apps' SIGWINCH redraws
        // have landed, so a resize never leaves the glass half-updated
        self.refresh_at = nowMs() + 120;
    }

    // ---- the loop ----

    fn loop(self: *Server) !void {
        var fds: std.ArrayList(ptypkg.Pollfd) = .empty;
        defer fds.deinit(self.gpa);
        var last_frame: i64 = 0;
        while (true) {
            fds.clearRetainingCapacity();
            try fds.append(self.gpa, .{ .fd = self.wake_r, .events = ptypkg.POLLIN });
            try fds.append(self.gpa, .{ .fd = self.listener, .events = ptypkg.POLLIN });
            for (self.clients.items) |c| {
                const ev: i16 = if (c.out_off < c.out.items.len) ptypkg.POLLIN | ptypkg.POLLOUT else ptypkg.POLLIN;
                try fds.append(self.gpa, .{ .fd = c.fd, .events = ev });
            }
            // panes with queued stdin: watch their ptys for room
            const pane_fds_at = fds.items.len;
            for (self.panes.items) |pn| {
                if (pn.pendingIn()) try fds.append(self.gpa, .{ .fd = pn.pty.master, .events = ptypkg.POLLOUT });
            }
            // the request in flight at the root: its pipes wake the
            // loop, and its reply is a frame
            const job_fds_at = fds.items.len;
            var job_fds: [2]ptypkg.Pollfd = undefined;
            for (job_fds[0..self.alt.req.fds(&job_fds)]) |jf| try fds.append(self.gpa, jf);
            var run_fds: [2]ptypkg.Pollfd = undefined;
            for (run_fds[0..self.alt.home.runner.fds(&run_fds)]) |jf| try fds.append(self.gpa, jf);
            var timeout: c_int = if (self.pending)
                @intCast(@max(0, frame_gap_ms - (nowMs() - last_frame)))
            else
                1000;
            // wake in time to fire a pending post-resize refresh
            if (self.refresh_at != 0) {
                const dt = self.refresh_at - nowMs();
                timeout = @intCast(std.math.clamp(dt, 0, timeout));
            }
            const n = ptypkg.pollMany(fds.items.ptr, @intCast(fds.items.len), timeout);
            if (n < 0) continue;

            if (fds.items[0].revents & ptypkg.POLLIN != 0) {
                var drain: [4096]u8 = undefined;
                while (ptypkg.readNb(self.wake_r, &drain) > 0) {}
                self.pending = true;
            }

            if (fds.items[1].revents & ptypkg.POLLIN != 0) self.accept();

            for (fds.items[2..pane_fds_at]) |pfd| {
                if (pfd.revents == 0) continue;
                const idx = self.clientIndex(pfd.fd) orelse continue;
                const c = self.clients.items[idx];
                if (pfd.revents & ptypkg.POLLOUT != 0) self.flushClient(c);
                // Serve before dropping: a one-shot client (nav) writes
                // and closes, so POLLIN and POLLHUP arrive together and
                // its bytes must still be drained.
                const alive = if (pfd.revents & ptypkg.POLLIN != 0) self.serveClient(c) else true;
                if (!alive or c.dead or pfd.revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0) {
                    self.dropClient(idx);
                }
            }

            if (self.alt.req.busy()) {
                const ev = self.alt.req.pump();
                if (ev != .none) {
                    self.absorbRequest(ev);
                    _ = self.touch();
                    self.full = true;
                    self.pending = true;
                }
            }
            if (self.alt.home.runner.busy() and self.alt.home.runner.pump()) {
                self.absorbRunner();
                _ = self.touch();
                self.full = true;
                self.pending = true;
            }
            // drain pane stdin queues that got room
            for (fds.items[pane_fds_at..job_fds_at]) |pfd| {
                if (pfd.revents & ptypkg.POLLOUT == 0) continue;
                for (self.panes.items) |pn| {
                    if (pn.pty.master == pfd.fd) {
                        pn.flushIn();
                        break;
                    }
                }
            }

            // sweep clients marked dead outside the poll dispatch
            // (backlog cap, failed writes from redraw/shipClip)
            var ci: usize = self.clients.items.len;
            while (ci > 0) {
                ci -= 1;
                if (self.clients.items[ci].dead) self.dropClient(ci);
            }

            try self.reap();
            self.forwardTees();
            self.pollSignals();
            // Restored panes type their resume command once the shell
            // is up — as a person would, into the shell's own
            // environment, so the shell is still there when it exits.
            for (self.panes.items) |p| {
                if (p.bootIfReady(nowMs())) self.pending = true;
            }
            if (self.sessions.items.len == 0 or self.shutdown) return;

            // a resize's SIGWINCH repaint has had time to arrive: force
            // one clean full frame so the settled result is always shown
            if (self.refresh_at != 0 and nowMs() >= self.refresh_at) {
                self.refresh_at = 0;
                self.full = true;
                self.pending = true;
            }

            if (self.pending and nowMs() - last_frame >= frame_gap_ms) {
                try self.redraw();
                last_frame = nowMs();
                self.pending = false;
            }

            // The state feed: floored at 50ms, so a busy pane cannot
            // make it chatty, and never on the frame path.
            if (nowMs() - self.state_check_ms > 50) {
                self.pushState();
                self.state_check_ms = nowMs();
            }
            if (nowMs() - self.blocks_check_ms > 2000) {
                self.pushBlocks();
                self.blocks_check_ms = nowMs();
            }
            // Agents rook can see for itself. Only a change earns a
            // repaint, and only when the rail is actually on the glass.
            // The companion rides the same walk of the pane table; it
            // paints nothing, so a change there is for the feed to
            // notice on its next pass, not a repaint.
            if (nowMs() - self.found_ms > found_every_ms) {
                self.found_ms = nowMs();
                const agents_moved = self.scanAgents();
                _ = self.scanCompanion();
                if (agents_moved and self.side_w != null) {
                    self.full = true;
                    self.pending = true;
                }
            }

            // structural changes save after 1s; cwds drift without
            // structural events, so refresh every 30s regardless
            const since_save = nowMs() - self.state_saved_ms;
            if ((self.state_dirty and since_save > 1000) or since_save > 30_000) {
                self.saveState();
                self.state_dirty = false;
                self.state_saved_ms = nowMs();
            }
        }
    }

    fn accept(self: *Server) void {
        while (true) {
            const fd = ptypkg.unixAccept(self.listener);
            if (fd < 0) return;
            _ = ptypkg.setNonblockFd(fd);
            const c = self.gpa.create(Client) catch {
                ptypkg.closeFd(fd);
                return;
            };
            c.* = .{ .fd = fd, .reader = proto.Reader.init(self.gpa) };
            self.clients.append(self.gpa, c) catch {
                ptypkg.closeFd(fd);
                self.gpa.destroy(c);
                return;
            };
        }
    }

    fn clientIndex(self: *Server, fd: ptypkg.fd_t) ?usize {
        for (self.clients.items, 0..) |c, i| {
            if (c.fd == fd) return i;
        }
        return null;
    }

    fn dropClient(self: *Server, i: usize) void {
        const c = self.clients.items[i];
        const had_lease = c.lease and c.block != null;
        ptypkg.closeFd(c.fd);
        c.reader.deinit();
        c.out.deinit(self.gpa);
        self.gpa.destroy(c);
        _ = self.clients.swapRemove(i);
        self.updateTees();
        // a departing lease holder hands geometry back to the TUI
        if (had_lease) self.relayout() catch {};
    }

    /// Frame a message onto the client's outbound queue and push what
    /// the socket will take. Never blocks; POLLOUT drains the rest.
    fn sendTo(self: *Server, c: *Client, kind: u8, payload: []const u8) void {
        if (c.dead) return;
        if (c.out.items.len - c.out_off > max_client_backlog) {
            c.dead = true;
            return;
        }
        var hdr: [5]u8 = undefined;
        hdr[0] = kind;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        c.out.appendSlice(self.gpa, &hdr) catch {
            c.dead = true;
            return;
        };
        c.out.appendSlice(self.gpa, payload) catch {
            c.dead = true;
            return;
        };
        self.flushClient(c);
    }

    fn flushClient(self: *Server, c: *Client) void {
        while (c.out_off < c.out.items.len) {
            const n = ptypkg.writeNbFd(c.fd, c.out.items[c.out_off..]) catch {
                c.dead = true;
                return;
            };
            if (n == 0) return; // kernel buffer full
            c.out_off += n;
        }
        c.out_off = 0;
        // a burst can balloon this queue; don't keep the high-water
        // mark as permanent RSS
        if (c.out.capacity > 1024 * 1024) {
            c.out.clearAndFree(self.gpa);
        } else {
            c.out.clearRetainingCapacity();
        }
    }

    /// Returns false when the client is gone. Buffered messages are
    /// processed even at EOF — a one-shot client's last words count.
    fn serveClient(self: *Server, c: *Client) bool {
        const alive = c.reader.fill(c.fd);
        while (c.reader.next()) |msg| {
            defer c.reader.consume();
            switch (msg.kind) {
                @intFromEnum(proto.c2s.attach), @intFromEnum(proto.c2s.resize) => {
                    if (c.block) |bid| {
                        // resize from a block client: only the lease
                        // holder moves the pty
                        if (c.lease) {
                            if (proto.Geometry.decode(msg.payload)) |g| {
                                if (self.pane(bid)) |p| {
                                    p.resize(g.cols, g.rows);
                                    self.full = true;
                                    self.pending = true;
                                }
                            }
                        }
                        continue;
                    }
                    if (proto.Geometry.decode(msg.payload)) |g| {
                        c.cols = g.cols;
                        c.rows = g.rows;
                        const first = !c.attached and self.attachedCount() == 0;
                        c.attached = true;
                        // Where this glass lands: [dest u8][name\tcwd]
                        // after the geometry. `r` is the root, `s` a
                        // space by name (made if it must be), and no
                        // destination is the product's default — the
                        // root, unless the config says the last
                        // space. A second glass joining a first one
                        // does not move it.
                        if (msg.kind == @intFromEnum(proto.c2s.attach)) self.landGlass(msg.payload[4..], first);
                        self.greetGlass(c);
                        self.relayout() catch {};
                    }
                },
                @intFromEnum(proto.c2s.stdin) => {
                    if (c.block) |bid| {
                        // block clients speak straight to the pane: no
                        // prefix, no mouse routing, no viewport snap
                        if (self.pane(bid)) |p| p.write(msg.payload);
                    } else self.input(c, msg.payload);
                },
                @intFromEnum(proto.c2s.blocks) => self.sendBlocks(c, msg.payload),
                @intFromEnum(proto.c2s.state) => self.sendState(c, msg.payload),
                @intFromEnum(proto.c2s.side) => self.sidePush(c, msg.payload),
                @intFromEnum(proto.c2s.capture) => {
                    // [id u32][lines u32?] → the pane's viewport as
                    // plain text, or its last `lines` lines, history
                    // included, when asked for more than the screen.
                    if (msg.payload.len >= 4) {
                        const id = std.mem.readInt(u32, msg.payload[0..4], .little);
                        const lines: u32 = if (msg.payload.len >= 8) std.mem.readInt(u32, msg.payload[4..8], .little) else 0;
                        if (self.pane(id)) |p| {
                            self.sendCapture(c, p, lines);
                        } else {
                            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                        }
                    }
                },
                @intFromEnum(proto.c2s.input) => {
                    // [id u32][bytes] → typed into that pane, as if at
                    // its keyboard: the view snaps to now first, the
                    // same as a keystroke from the glass.
                    if (msg.payload.len >= 4) {
                        const id = std.mem.readInt(u32, msg.payload[0..4], .little);
                        if (self.pane(id)) |p| {
                            p.scrollBottom();
                            p.write(msg.payload[4..]);
                            _ = self.touch();
                            self.ack(c);
                            self.pending = true;
                        } else {
                            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                        }
                    }
                },
                @intFromEnum(proto.c2s.pane_cmd) => self.paneCmd(c, msg.payload),
                @intFromEnum(proto.c2s.resume_cmd) => {
                    // [id u32][cmd…] → how to bring this pane's program
                    // back; empty forgets. The program's own word, kept
                    // while it is the one in the foreground.
                    if (msg.payload.len >= 4) {
                        const id = std.mem.readInt(u32, msg.payload[0..4], .little);
                        if (self.pane(id)) |p| {
                            p.setResume(msg.payload[4..]);
                            self.state_dirty = true;
                            _ = self.touch();
                            self.ack(c);
                        } else {
                            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                        }
                    }
                },
                @intFromEnum(proto.c2s.own) => self.ownCmd(c, msg.payload),
                @intFromEnum(proto.c2s.notify) => self.notify(c, msg.payload),
                @intFromEnum(proto.c2s.block_cmd) => self.blockCmd(c, msg.payload),
                @intFromEnum(proto.c2s.attach_block) => self.attachBlock(c, msg.payload),
                @intFromEnum(proto.c2s.session) => {
                    if (msg.payload.len >= 1) {
                        const op = msg.payload[0];
                        const name = msg.payload[1..];
                        switch (op) {
                            'l' => {
                                var lb: [1024]u8 = undefined;
                                var lw: std.ArrayList(u8) = .initBuffer(&lb);
                                for (self.sessions.items) |sn| {
                                    lw.appendSliceBounded(sn.label()) catch break;
                                    lw.appendSliceBounded("\n") catch break;
                                }
                                self.sendTo(c, @intFromEnum(proto.s2c.stats_text), lw.items);
                            },
                            's' => if (name.len > 0) self.switchSessionNamed(name),
                            // 'n' creates and switches to the workspace;
                            // 'N' creates it without moving the person —
                            // starting work for an agent must never pull
                            // the desk to it. Both reply with the block
                            // they made, so a caller never has to diff
                            // the table to find out.
                            'n', 'N' => if (name.len > 0) {
                                // payload: name[\tcwd[\tcmd]] — the program the
                                // first pane is born running, if any
                                var nm = name;
                                var cwd: ?[*:0]const u8 = null;
                                var cwd_buf: [1024]u8 = undefined;
                                var cmd: ?[*:0]const u8 = null;
                                var cmd_buf: [4096]u8 = undefined;
                                if (std.mem.indexOfScalar(u8, name, '\t')) |tab| {
                                    nm = name[0..tab];
                                    var dir = name[tab + 1 ..];
                                    if (std.mem.indexOfScalar(u8, dir, '\t')) |tab2| {
                                        const prog = dir[tab2 + 1 ..];
                                        dir = dir[0..tab2];
                                        if (prog.len > 0 and prog.len < cmd_buf.len) {
                                            @memcpy(cmd_buf[0..prog.len], prog);
                                            cmd_buf[prog.len] = 0;
                                            cmd = @ptrCast(&cmd_buf);
                                        }
                                    }
                                    if (dir.len > 0 and dir.len < cwd_buf.len) {
                                        @memcpy(cwd_buf[0..dir.len], dir);
                                        cwd_buf[dir.len] = 0;
                                        cwd = @ptrCast(&cwd_buf);
                                    }
                                }
                                if (nm.len > 0) {
                                    if (self.newSession(nm, cwd, cmd, op == 'n')) |sn| {
                                        if (sn.windows.items.len > 0)
                                            self.replyCreated(c, sn.windows.items[sn.cur].focused);
                                    } else |_| {}
                                }
                            },
                            'k' => if (name.len > 0) self.closeSession(name),
                            // 'r' names the current window: the one act
                            // that changes a minted tab name.
                            'r' => if (name.len > 0) self.renameWindow(name),
                            // 'g' is a namer's suggestion for a pane's
                            // window: it yields to a name given by hand.
                            'g' => if (name.len > 0) self.suggestName(name),
                            // 'u' gives the current tab back to rook.
                            'u' => self.unnameWindow(),
                            else => {},
                        }
                        if (op != 'l') {
                            _ = self.touch();
                            self.ack(c);
                        }
                        self.pending = true;
                    }
                },
                @intFromEnum(proto.c2s.popup) => {
                    if (msg.payload.len > 0) self.openPopup(self.popupSized(msg.payload)) catch {};
                },
                @intFromEnum(proto.c2s.nav) => {
                    // vim hit a window edge and hands us the move; an
                    // explicit verb, so never forwarded anywhere.
                    if (msg.payload.len == 1) _ = self.navigate(msg.payload[0]);
                },
                @intFromEnum(proto.c2s.detach) => return false,
                @intFromEnum(proto.c2s.stats) => self.sendStats(c),
                @intFromEnum(proto.c2s.shutdown) => {
                    // polite server exit: snapshot state while the
                    // panes still breathe, HUP everything, leave
                    self.saveState();
                    for (self.panes.items) |p| p.hangup();
                    self.shutdown = true;
                },
                else => {},
            }
        }
        return alive;
    }

    /// One line per pane: id, session:window, fg program, cwd. The
    /// web client's block list, and `rook blocks`. Asking once
    /// subscribes the client to pushes when the table changes. Asked
    /// with "json" it is the same table as one JSON array, once, in
    /// the state feed's own words for where a pane is (`placeOf`) —
    /// for a program, which should not have to split tabs.
    fn sendBlocks(self: *Server, c: *Client, form: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        if (std.mem.eql(u8, form, "json")) {
            self.buildBlocksJson(&out);
        } else {
            c.wants_blocks = true;
            self.buildBlocks(&out);
        }
        self.sendTo(c, @intFromEnum(proto.s2c.blocks_text), out.items);
    }

    fn buildBlocksJson(self: *Server, out: *std.ArrayList(u8)) void {
        const gpa = self.gpa;
        out.append(gpa, '[') catch return;
        var n: usize = 0;
        for (self.panes.items) |p| {
            const at = self.placeOf(p.id) orelse continue;
            if (n > 0) out.append(gpa, ',') catch return;
            n += 1;
            var nb: [64]u8 = undefined;
            var cb: [1024]u8 = undefined;
            out.print(gpa, "{{\"id\":{d},\"workspace\":", .{p.id}) catch return;
            if (at.workspace.len > 0) statefeed.str(gpa, out, at.workspace) else out.appendSlice(gpa, "null") catch return;
            out.appendSlice(gpa, ",\"window\":") catch return;
            if (at.window) |wi| out.print(gpa, "{d}", .{wi}) catch return else out.appendSlice(gpa, "null") catch return;
            out.appendSlice(gpa, ",\"place\":") catch return;
            statefeed.str(gpa, out, at.place);
            out.appendSlice(gpa, ",\"program\":") catch return;
            statefeed.str(gpa, out, p.fgName(&nb) orelse "shell");
            out.print(gpa, ",\"cols\":{d},\"rows\":{d},\"cwd\":", .{ p.cols, p.rows }) catch return;
            statefeed.str(gpa, out, if (p.fgCwd(&cb)) |cc| cc else "");
            out.print(gpa, ",\"visible\":{s},\"focused\":{s}}}", .{ if (at.visible) "true" else "false", if (at.focused) "true" else "false" }) catch return;
        }
        out.appendSlice(gpa, "]\n") catch return;
    }

    fn buildBlocks(self: *Server, out: *std.ArrayList(u8)) void {
        for (self.global_pins.items) |id| self.blockLine(out, id, "global", "pin");
        for (self.sessions.items) |sn| {
            for (sn.pins.items) |id| self.blockLine(out, id, sn.label(), "pin");
        }
        for (self.sessions.items) |sn| {
            for (sn.windows.items, 0..) |w, wi| {
                for (self.panes.items) |p| {
                    if (!w.layout.contains(p.id)) continue;
                    var nb: [64]u8 = undefined;
                    var cb: [1024]u8 = undefined;
                    const fg = p.fgName(&nb) orelse "shell";
                    const cwd: []const u8 = if (p.fgCwd(&cb)) |cc| cc else "";
                    var line: [1200]u8 = undefined;
                    const l = std.fmt.bufPrint(&line, "{d}\t{s}:{d}\t{s}\t{d}x{d}\t{s}\n", .{ p.id, sn.label(), wi + 1, fg, p.cols, p.rows, cwd }) catch continue;
                    out.appendSlice(self.gpa, l) catch return;
                }
            }
        }
    }

    fn blockLine(self: *Server, out: *std.ArrayList(u8), id: u32, place: []const u8, slot: []const u8) void {
        const p = self.pane(id) orelse return;
        var nb: [64]u8 = undefined;
        var cb: [1024]u8 = undefined;
        const fg = p.fgName(&nb) orelse "shell";
        const cwd: []const u8 = if (p.fgCwd(&cb)) |cc| cc else "";
        var line: [1200]u8 = undefined;
        const l = std.fmt.bufPrint(&line, "{d}\t{s}:{s}\t{s}\t{d}x{d}\t{s}\n", .{ p.id, place, slot, fg, p.cols, p.rows, cwd }) catch return;
        out.appendSlice(self.gpa, l) catch {};
    }

    /// Push the block table to subscribers when it changed. Checked
    /// every couple of seconds (fg/cwd drift) and immediately after
    /// structural changes.
    fn pushBlocks(self: *Server) void {
        var any = false;
        for (self.clients.items) |c| {
            if (c.wants_blocks and !c.dead) any = true;
        }
        if (!any) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.buildBlocks(&out);
        if (std.mem.eql(u8, out.items, self.blocks_last.items)) return;
        self.blocks_last.clearRetainingCapacity();
        self.blocks_last.appendSlice(self.gpa, out.items) catch {};
        for (self.clients.items) |c| {
            if (c.wants_blocks and !c.dead) self.sendTo(c, @intFromEnum(proto.s2c.blocks_text), out.items);
        }
    }

    // ---- the state feed ----

    /// Bump the serial: something a consumer's replica must see
    /// changed. Returns the new value, which is what a command replies
    /// with — a caller waits for `serial >= n`, not `== n`, since
    /// anything else may have moved in between.
    fn touch(self: *Server) u64 {
        self.serial += 1;
        self.state_check_ms = 0; // publish on the next loop turn
        return self.serial;
    }

    /// Acknowledge a mutating command with the serial it produced, so
    /// its caller can wait for its own write to appear in the feed. A
    /// caller waits for `serial >= n`, not `== n`: anything else may
    /// have moved in between.
    fn ack(self: *Server, c: *Client) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, self.serial, .little);
        self.sendTo(c, @intFromEnum(proto.s2c.ack), &b);
    }

    /// The rail's model as it is painted and published: what producers
    /// pushed, with the agents rook found itself folded into the
    /// agents panel. The merge is one-way and lives here rather than
    /// in `Feed`, so a producer's model is still exactly the bytes it
    /// sent — see chrome.Merge.
    fn sideModel(self: *Server) chromepkg.Model {
        var m = self.side.model();
        m.agents = self.agents_merge.panel(self.gpa, .agents, m.agents, self.found[0..self.found_n]);
        const pushed_n = m.spaces.items.len;
        m.spaces = self.spaces_merge.panel(self.gpa, .spaces, m.spaces, self.foundSpaces());
        // The current workspace is the highlight when the producer has
        // not placed one: among rook's own rows it is the one fact the
        // panel exists to show. A pushed `current` still wins.
        if (m.spaces.cur == null and self.cur_sess < self.sessions.items.len) {
            const cur = self.sessions.items[self.cur_sess].label();
            for (m.spaces.items[pushed_n..], pushed_n..) |it, i| {
                if (std.mem.eql(u8, it.workspace(), cur)) {
                    m.spaces.cur = i;
                    break;
                }
            }
        }
        return m;
    }

    /// Rook's own rows for the spaces panel, rebuilt on every ask: one
    /// per workspace, in workspace order. Cheap enough to never
    /// cache — a handful of sessions — and structural change already
    /// repaints, so there is no signature to keep.
    ///
    /// A row carries the workspace name as its identity (`ws`, what a
    /// click switches to and what a producer claims) and wears the
    /// short label `chrome.labelSpaces` gives it. The repository the
    /// label drops is not lost: it leads the subtitle, so the panel
    /// still answers "which checkout is this?" in the line that is
    /// there to answer it.
    ///
    /// A space whose agent a producer claims wears that producer's own
    /// title instead, with the label falling to the subtitle — see
    /// `chrome.borrowLabel`, which is the one thing on this rail that
    /// reads across the seam between the two panels.
    pub fn foundSpaces(self: *Server) []const chromepkg.Item {
        var n: usize = 0;
        for (self.sessions.items) |sn| {
            if (n == max_found) break;
            const repo = chromepkg.spaceRepo(sn.label());
            const wins = sn.windows.items.len;
            const buf = &self.found_ws_sub[n];
            const sub = if (repo.len > 0 and wins > 1)
                std.fmt.bufPrint(buf, "{s} · {d} windows", .{ repo, wins }) catch repo
            else if (repo.len > 0)
                std.fmt.bufPrint(buf, "{s}", .{repo}) catch repo
            else if (wins > 1)
                std.fmt.bufPrint(buf, "{d} windows", .{wins}) catch ""
            else
                "";
            self.found_ws[n] = .{ .name = sn.label(), .ws = sn.label(), .sub = sub, .origin = .found };
            n += 1;
        }
        chromepkg.labelSpaces(self.found_ws[0..n]);
        // Second pass, after labelling: the borrow displaces a label,
        // so there has to be one to displace.
        const claims = if (self.side.agents.panel) |p| p.items else &.{};
        for (self.found_ws[0..n], 0..) |*row, i| {
            _ = chromepkg.borrowLabel(row, claims, &self.found_ws_sub[i]);
        }
        self.found_ws_n = n;
        return self.found_ws[0..n];
    }

    /// Is this pane's foreground program one the config calls an agent?
    fn isAgentProgram(self: *Server, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.conf.agentsSlice(), '\n');
        while (it.next()) |want| {
            if (want.len > 0 and std.mem.eql(u8, name, want)) return true;
        }
        return false;
    }

    /// Walk the pane table for the companion. Rook holds one opinion
    /// about what an agent is; this is the same shape for the other
    /// question — the resident you summon, named once in the config,
    /// and worth knowing about because "is she already open, and
    /// where" is the difference between going to her and starting a
    /// second one. True when the set of panes changed.
    fn scanCompanion(self: *Server) bool {
        const want = self.conf.companionSlice();
        var ids: [companionpkg.max]u32 = undefined;
        var n: usize = 0;
        if (want.len > 0) {
            for (self.panes.items) |p| {
                if (n == ids.len) break;
                var nb: [64]u8 = undefined;
                const fg = p.fgName(&nb) orelse continue;
                if (!std.mem.eql(u8, fg, want)) continue;
                ids[n] = p.id;
                n += 1;
            }
        }
        return self.comp.update(panepkg.epochMs(), ids[0..n]);
    }

    /// Where a pane sits, in the words the feed publishes it in. Read
    /// at the moment it is asked rather than remembered: a pane moves
    /// between windows, workspaces and the rail without the program
    /// inside it changing.
    pub const Place = struct {
        workspace: []const u8,
        /// 1-based, and null when the pane is not in a window at all —
        /// the rail and the popup are above windows.
        window: ?usize = null,
        place: []const u8,
        visible: bool,
        focused: bool,
    };

    pub fn placeOf(self: *Server, id: u32) ?Place {
        var out: Place = .{
            .workspace = "",
            .place = "window",
            .visible = false,
            .focused = id == self.focusedId(),
        };
        for (self.placed.items) |pl| {
            if (pl.pane == id) out.visible = true;
        }
        const cur: ?*Session = if (self.cur_sess < self.sessions.items.len) self.sessions.items[self.cur_sess] else null;
        if (self.popup) |pid| {
            if (pid == id) {
                // The popup floats over the current workspace and takes
                // the keyboard while it is up; it belongs to no window.
                // It is drawn outside the layout, so `placed` does not
                // know about it — but it is the most visible thing on
                // the glass, and the one holding the keyboard.
                out.place = "popup";
                out.workspace = if (cur) |sn| sn.label() else "";
                out.visible = true;
                out.focused = true;
                return out;
            }
        }
        if (self.vera_pane) |pid| {
            if (pid == id) {
                // The companion's own terminal belongs to no window
                // and no space: it is the same pane from home and
                // from every space, drawn in her panel, and it holds
                // the keyboard whenever she has the focus. Without
                // this the one question the companion slot exists to
                // answer — is she open in rook — would be answered
                // "no" with her terminal on the glass.
                out.place = "vera";
                out.workspace = if (self.at_root) "" else (if (cur) |sn| sn.label() else "");
                out.visible = self.alt.home.veraShown();
                out.focused = self.veraHoldsKeys();
                return out;
            }
        }
        for (self.global_pins.items) |pid| {
            if (pid != id) continue;
            // A globally pinned pane belongs to no workspace — it is
            // in every one — so it is named by its scope, not a name.
            out.place = "pin";
            return out;
        }
        for (self.sessions.items) |sn| {
            for (sn.pins.items) |pid| {
                if (pid != id) continue;
                out.place = "pin";
                out.workspace = sn.label();
                return out;
            }
            for (sn.windows.items, 0..) |w, wi| {
                if (!w.layout.contains(id)) continue;
                out.workspace = sn.label();
                out.window = wi + 1;
                return out;
            }
        }
        return null;
    }

    /// Does this workspace hold the pane — in one of its windows, or
    /// docked to its rail?
    fn paneIn(self: *Server, sn: *Session, id: u32) bool {
        for (sn.pins.items) |pid| {
            if (pid == id) return true;
        }
        for (sn.windows.items) |w| {
            if (w.layout.contains(id)) return true;
        }
        // A globally pinned pane belongs to no workspace — it shows in
        // every one — so the rail lists it under the current.
        if (self.cur_sess < self.sessions.items.len and sn == self.sessions.items[self.cur_sess]) {
            for (self.global_pins.items) |pid| {
                if (pid == id) return true;
            }
        }
        return false;
    }

    /// Walk the pane table for agent programs and rebuild the found
    /// rows: one per workspace, labelled for it, with the program and
    /// how many of it. The workspace itself rides on the row as its
    /// identity, so a producer's claim still matches the full name.
    /// True when the rows changed — which is the only thing that earns
    /// a repaint, because this runs on a timer and the answer is
    /// usually the same one as last time.
    fn scanAgents(self: *Server) bool {
        var buf: [max_found * 64]u8 = undefined;
        var offs: [max_found]struct { no: usize, nl: usize, so: usize, sl: usize, unread: bool } = undefined;
        var n: usize = 0;
        var len: usize = 0;

        // One pass caches the answer per pane: the tab bar, the calm
        // bar and the altitude view read `is_agent` every frame and
        // must not pay the syscalls for it.
        for (self.panes.items) |p| {
            // rook's own panes are not work: the companion's terminal
            // is the thing you watch the agents *from*.
            var nb: [64]u8 = undefined;
            p.is_agent = !self.ownPane(p.id) and if (p.fgName(&nb)) |fg| self.isAgentProgram(fg) else false;
        }
        self.mintNames();

        for (self.sessions.items) |sn| {
            if (n == max_found) break;
            var count: usize = 0;
            var prog: [64]u8 = undefined;
            var prog_len: usize = 0;
            for (self.panes.items) |p| {
                if (!self.paneIn(sn, p.id)) continue;
                if (!p.is_agent) continue;
                var nb: [64]u8 = undefined;
                const fg = p.fgName(&nb) orelse continue;
                if (count == 0 and fg.len <= prog.len) {
                    @memcpy(prog[0..fg.len], fg);
                    prog_len = fg.len;
                }
                count += 1;
            }
            if (count == 0) continue;

            const label = sn.label();
            const start = len;
            if (len + label.len + 1 > buf.len) break;
            @memcpy(buf[len..][0..label.len], label);
            const no = len;
            len += label.len;
            // The unread channel is part of the row, so it is part of
            // the signature: a dot appearing is a change worth a paint.
            const unread = self.sessionUnread(sn);
            buf[len] = if (unread) 'u' else '-';
            len += 1;
            const so = len;
            // A row that does not fit rewinds whole: a half-written
            // name would ride into found_buf and into the signature.
            const sub = if (count == 1)
                std.fmt.bufPrint(buf[len..], "{s}", .{prog[0..prog_len]}) catch {
                    len = start;
                    break;
                }
            else
                std.fmt.bufPrint(buf[len..], "{s} ×{d}", .{ prog[0..prog_len], count }) catch {
                    len = start;
                    break;
                };
            len += sub.len;
            offs[n] = .{ .no = no, .nl = label.len, .so = so, .sl = sub.len, .unread = unread };
            n += 1;
        }

        // The build is deterministic, so the bytes are the signature.
        if (n == self.found_n and len == self.found_len and
            std.mem.eql(u8, buf[0..len], self.found_buf[0..len])) return false;

        @memcpy(self.found_buf[0..len], buf[0..len]);
        self.found_len = len;
        for (0..n) |i| {
            const ws = self.found_buf[offs[i].no..][0..offs[i].nl];
            self.found[i] = .{
                .name = ws,
                .ws = ws,
                .sub = self.found_buf[offs[i].so..][0..offs[i].sl],
                .origin = .manual,
                .unread = offs[i].unread,
            };
        }
        self.found_n = n;
        // Rook found these by workspace, so the workspace is the
        // identity a producer claims; the rail paints the short label.
        chromepkg.labelSpaces(self.found[0..n]);
        // The rows moved under it; a cursor that survived would point
        // at a different agent than the one it was put on.
        self.agents_merge.cur = null;
        return true;
    }

    /// An `items.push` frame: one side-panel surface's model, pushed
    /// in from outside. Rook paints what it is given and decides
    /// nothing about what it says. A frame rook cannot use changes
    /// nothing on the glass and is answered with the reason — a
    /// producer with a typo should hear about it, not watch a rail go
    /// quietly stale.
    fn sidePush(self: *Server, c: *Client, payload: []const u8) void {
        const surface = self.side.push(payload) catch |e| {
            var b: [96]u8 = undefined;
            const why = std.fmt.bufPrint(&b, "side push rejected: {s}\n", .{@errorName(e)}) catch
                "side push rejected\n";
            self.sendTo(c, @intFromEnum(proto.s2c.text), why);
            return;
        };
        // The producer takes the highlight back, per the rule that
        // what is *selected* belongs to whoever supplies the items.
        if (surface == .agents) self.agents_merge.cur = null;
        _ = self.touch();
        // Chrome only repaints on a full frame, and nothing else about
        // this change dirties a row — but a rail that is folded away
        // is not on the glass, and a producer pushing at its own
        // cadence must not cost a full repaint each time. Home is
        // painted from the rail, so there a push is a frame.
        if (self.side_w != null or self.at_root) {
            self.full = true;
            self.pending = true;
        }
        self.ack(c);
    }

    /// `state` request: [flags u8, 1 = subscribe]. Always replies with
    /// the current snapshot first, so a subscriber never needs a
    /// separate one-shot and a reconnect is a resync.
    fn sendState(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len > 0 and (payload[0] & 1) != 0) c.wants_state = true;
        // A direct ask always carries fresh liveness; only the pushed
        // stream holds it back to a slower cadence.
        statefeed.build(self, &self.state_json, .{});
        self.sendTo(c, @intFromEnum(proto.s2c.state_json), self.state_json.items);
        c.state_queued = false;
    }

    /// Publish to subscribers when the snapshot actually changed.
    /// Floored rather than driven off every mutation: pane titles and
    /// cwds drift with pty output, and this must never ride the frame
    /// path.
    fn pushState(self: *Server) void {
        var any = false;
        for (self.clients.items) |c| {
            if (c.wants_state and !c.dead) any = true;
        }
        if (!any) return;
        const now = nowMs();
        // Structural change — anything a command did — pushes at once.
        const cmp: statefeed.Form = .{ .drift = false, .identity = false };
        statefeed.build(self, &self.state_json, cmp);
        var due = !std.mem.eql(u8, self.state_json.items, self.state_last.items);
        if (due) {
            self.state_last.clearRetainingCapacity();
            self.state_last.appendSlice(self.gpa, self.state_json.items) catch {};
        }
        // Drift is only looked at every couple of seconds.
        const drift_cmp: statefeed.Form = .{ .drift = true, .identity = false };
        if (!due and now - self.state_drift_ms > 2000) {
            self.state_drift_ms = now;
            statefeed.build(self, &self.state_json, drift_cmp);
            due = !std.mem.eql(u8, self.state_json.items, self.state_drift_last.items);
        }
        if (!due) return;
        // A change no mutation site announced still earns a serial, so
        // a replica can order it.
        self.serial += 1;
        statefeed.build(self, &self.state_drift_last, drift_cmp);
        statefeed.build(self, &self.state_json, .{});
        for (self.clients.items) |c| {
            if (!c.wants_state or c.dead) continue;
            c.state_queued = true;
            self.sendTo(c, @intFromEnum(proto.s2c.state_json), self.state_json.items);
            c.state_queued = false;
        }
    }

    /// Attach this client to one block: [id u32][cols u16][rows u16]
    /// [flags u8: 1 = take the resize lease]. Replies with a full
    /// snapshot, then the raw tee follows.
    fn attachBlock(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 9) return;
        const id = std.mem.readInt(u32, payload[0..4], .little);
        const cols = std.mem.readInt(u16, payload[4..6], .little);
        const rows = std.mem.readInt(u16, payload[6..8], .little);
        const flags = payload[8];
        const p = self.pane(id) orelse {
            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such block");
            return;
        };
        c.block = id;
        c.attached = false; // never receives composed frames
        if (flags & 1 != 0) {
            for (self.clients.items) |other| {
                if (other.block == id) other.lease = false;
            }
            c.lease = true;
            if (cols > 0 and rows > 0) p.resize(cols, rows);
            self.full = true;
        }
        self.updateTees();
        if (flags & 2 != 0) self.sendBackfill(c, p);
        self.sendSnapshot(c, p);
        self.pending = true;
    }

    /// Scrollback backfill: unwrapped history lines, written before
    /// the snapshot so they land in the client's scrollback (the
    /// snapshot's clear only wipes the viewport). Capped to the last
    /// 256KB on a line boundary.
    fn sendBackfill(self: *Server, c: *Client, p: *panepkg.Pane) void {
        const text = p.historyText(self.gpa) orelse return;
        defer self.gpa.free(@constCast(text));
        var body = text;
        if (body.len > 256 * 1024) {
            body = body[body.len - 256 * 1024 ..];
            if (std.mem.indexOfScalar(u8, body, '\n')) |nl| body = body[nl + 1 ..];
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "\x1b[0m") catch return;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            out.appendSlice(self.gpa, line) catch return;
            out.appendSlice(self.gpa, "\r\n") catch return;
        }
        self.sendTo(c, @intFromEnum(proto.s2c.draw), out.items);
    }

    /// Keep each pane's tee flag equal to "someone is watching".
    fn updateTees(self: *Server) void {
        for (self.panes.items) |p| {
            var on = false;
            for (self.clients.items) |c| {
                if (c.block == p.id and !c.dead) on = true;
            }
            p.tee_on.store(on, .release);
        }
    }

    const BlockLoc = struct { sn: *Session, w: *Window };

    fn findBlock(self: *Server, pane_id: u32) ?BlockLoc {
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                if (w.layout.contains(pane_id)) return .{ .sn = sn, .w = w };
            }
        }
        return null;
    }

    /// Typed actions for block clients — the browser's prefix keys.
    /// [op]: 'c' new window in the block's session, 'v'/'-' split the
    /// block's window, 'x' kill the block. Creations reply with the
    /// new block id so the client can hop straight onto it. The
    /// desktop view is never yanked: windows appear in the tab bar,
    /// splits show up if that window is on screen, focus stays put.
    fn blockCmd(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 1) return;
        const bid = c.block orelse return;
        switch (payload[0]) {
            'c', 'v', '-' => {
                const id = self.paneOp(bid, payload[0], null, false) orelse return;
                self.replyCreated(c, id);
            },
            'x' => _ = self.paneOp(bid, 'x', null, false),
            else => return,
        }
        self.state_dirty = true;
        self.blocks_check_ms = 0; // push the new table promptly
        self.pending = true;
    }

    /// `pane_cmd`, the front door's verbs on a pane by id: [id u32]
    /// [op u8][flags u8][cwd…]. Ops are the block verbs — 'c' new
    /// window in the pane's workspace, 'v'/'-' split beside/below it,
    /// 'x' hang it up — plus 'f' focus it (bringing its workspace and
    /// window forward) and 'u' jump to the oldest unread pane, for
    /// which the id is ignored. flags&1: focus what was created.
    /// Creations answer with the new pane's id, everything else with
    /// the serial, and a pane rook does not hold answers `exit`.
    fn paneCmd(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 6) return;
        const id = std.mem.readInt(u32, payload[0..4], .little);
        const op = payload[4];
        const focus = payload[5] & 1 != 0;
        var cwd_buf: [1024]u8 = undefined;
        var cwd: ?[*:0]const u8 = null;
        const dir = payload[6..];
        if (dir.len > 0 and dir.len < cwd_buf.len) {
            @memcpy(cwd_buf[0..dir.len], dir);
            cwd_buf[dir.len] = 0;
            cwd = @ptrCast(&cwd_buf);
        }
        switch (op) {
            'u' => {
                _ = self.jumpUnread();
                _ = self.touch();
                self.ack(c);
            },
            'f' => {
                if (self.pane(id) == null) {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                    return;
                }
                self.focusPane(id);
                _ = self.touch();
                self.ack(c);
            },
            'c', 'v', '-' => {
                if (self.pane(id) == null) {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                    return;
                }
                const made = self.paneOp(id, op, cwd, focus) orelse {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "could not open the pane");
                    return;
                };
                _ = self.touch();
                self.replyCreated(c, made);
            },
            'x' => {
                if (self.pane(id) == null) {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
                    return;
                }
                _ = self.paneOp(id, 'x', null, false);
                _ = self.touch();
                self.ack(c);
            },
            else => {
                self.sendTo(c, @intFromEnum(proto.s2c.exit), "unknown pane op");
                return;
            },
        }
        self.state_dirty = true;
        self.blocks_check_ms = 0;
        self.pending = true;
    }

    /// One verb on one pane, shared by the browser's block commands
    /// and the front door's. The desktop is never yanked unless
    /// `focus` asks: a window appears in the tab bar, a split shows up
    /// if its window is on the glass, and focus stays where it was —
    /// starting work on someone's behalf must not pull the desk.
    /// Returns the pane made, for the ops that make one.
    fn paneOp(self: *Server, bid: u32, op: u8, cwd_override: ?[*:0]const u8, focus: bool) ?u32 {
        const loc = self.findBlock(bid) orelse return null;
        var cwd_buf: [1024]u8 = undefined;
        var cwd: ?[*:0]const u8 = cwd_override;
        if (cwd == null) {
            if (self.pane(bid)) |bp| {
                if (bp.fgCwd(&cwd_buf)) |cc| cwd = cc.ptr;
            }
        }
        switch (op) {
            'c' => {
                const w = self.gpa.create(Window) catch return null;
                w.* = .{ .layout = layoutpkg.Layout.init(self.gpa), .seen_ms = panepkg.epochMs() };
                loc.sn.windows.append(self.gpa, w) catch {
                    self.gpa.destroy(w);
                    return null;
                };
                const p = self.startPane(cwd, null) catch return null;
                w.layout.seed(p.id) catch {};
                w.focused = p.id;
                if (focus) self.focusPane(p.id);
                return p.id;
            },
            'v', '-' => {
                const p = self.startPane(cwd, null) catch return null;
                loc.w.layout.split(bid, p.id, op == 'v') catch return null;
                loc.w.zoomed = false;
                if (loc.w == self.window()) self.relayout() catch {};
                if (focus) self.focusPane(p.id);
                return p.id;
            },
            'x' => {
                if (self.pane(bid)) |p| p.hangup();
                return null;
            },
            else => return null,
        }
    }

    /// A pane's text for a reader: the viewport, or when `lines` asks
    /// for more rows than it has, the last `lines` lines with the
    /// unwrapped history above the screen filling in the rest.
    fn sendCapture(self: *Server, c: *Client, p: *panepkg.Pane, lines: u32) void {
        p.snapshot() catch {};
        var view = self.frame.plainText(p);
        self.full = true; // the frame buffer is now the capture
        if (lines == 0 or lines >= 1 << 20) {
            self.sendTo(c, @intFromEnum(proto.s2c.text), view);
            return;
        }
        // A reader asking for the last N lines means the last N lines
        // *written*: the blank rows under the prompt are the screen,
        // not the text.
        while (std.mem.endsWith(u8, view, "\n\n")) view = view[0 .. view.len - 1];
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const view_rows = std.mem.count(u8, view, "\n");
        if (lines > view_rows) {
            // the rest comes from history, newest lines last
            const want = lines - view_rows;
            if (p.historyText(self.gpa)) |hist| {
                defer self.gpa.free(@constCast(hist));
                var body = std.mem.trimEnd(u8, hist, "\n");
                var have: usize = 0;
                var i = body.len;
                while (i > 0 and have < want) : (i -= 1) {
                    if (body[i - 1] == '\n') {
                        have += 1;
                        if (have == want) {
                            body = body[i..];
                            break;
                        }
                    }
                }
                out.appendSlice(self.gpa, body) catch return;
                out.append(self.gpa, '\n') catch return;
            }
            out.appendSlice(self.gpa, view) catch return;
        } else {
            // the tail of the viewport alone
            var skip = view_rows - lines;
            var rest = view;
            while (skip > 0) : (skip -= 1) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
                rest = rest[nl + 1 ..];
            }
            out.appendSlice(self.gpa, rest) catch return;
        }
        self.sendTo(c, @intFromEnum(proto.s2c.text), out.items);
    }

    fn replyCreated(self: *Server, c: *Client, id: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, id, .little);
        self.sendTo(c, @intFromEnum(proto.s2c.block_created), &b);
    }

    fn sendSnapshot(self: *Server, c: *Client, p: *panepkg.Pane) void {
        p.snapshot() catch return;
        var f = renderpkg.Frame.init(self.gpa);
        defer f.deinit();
        const bytes = f.blockSnapshot(p);
        self.sendTo(c, @intFromEnum(proto.s2c.draw), bytes);
        // blockSnapshot consumed dirty flags the TUI still needs
        self.full = true;
        self.pending = true;
    }

    /// Fan the raw tees out to block clients; an overflow becomes a
    /// fresh snapshot instead of a gap.
    fn forwardTees(self: *Server) void {
        for (self.panes.items) |p| {
            if (!p.tee_on.load(.acquire)) continue;
            const tee = p.takeTee(self.gpa) orelse continue;
            defer self.gpa.free(tee.bytes);
            for (self.clients.items) |c| {
                if (c.block != p.id or c.dead) continue;
                if (tee.overflow) {
                    self.sendSnapshot(c, p);
                } else {
                    self.sendTo(c, @intFromEnum(proto.s2c.draw), tee.bytes);
                }
            }
        }
    }

    fn sendStats(self: *Server, c: *Client) void {
        var buf: [768]u8 = undefined;
        var nwin: usize = 0;
        for (self.sessions.items) |sn| nwin += sn.windows.items.len;
        const text = std.fmt.bufPrint(&buf, "rook up {d}s · {d} session{s} · {d} window{s} · {d} pane{s} · {d} client{s}\nframes {d} · {d:.1} MB shipped\ninput→frame p50 {d}µs · p99 {d}µs · samples {d}\nstate {d} · epoch {s} · serial {d} · ops quiet-new,block-created-on-new\n", .{
            @divTrunc(nowMs() - self.started_ms, 1000),
            self.sessions.items.len,
            plural(self.sessions.items.len),
            nwin,
            plural(nwin),
            self.panes.items.len,
            plural(self.panes.items.len),
            self.clients.items.len,
            plural(self.clients.items.len),
            self.frames_sent,
            @as(f64, @floatFromInt(self.bytes_sent)) / (1024.0 * 1024.0),
            self.lat.pct(0.5),
            self.lat.pct(0.99),
            self.lat.total,
            statefeed.version,
            self.epoch,
            self.serial,
        }) catch "stats: format error";
        self.sendTo(c, @intFromEnum(proto.s2c.stats_text), text);
    }

    /// Route stdin: pasted text straight through, prefix commands
    /// here, scroll-mode keys in scroll mode, mouse events by
    /// position, everything else to the focused pane.
    fn input(self: *Server, c: *Client, bytes: []const u8) void {
        self.lat.note();
        var rest = bytes;
        while (rest.len > 0) {
            // A paste is content, not keys: once the glass has opened
            // one, every byte through the closing marker goes to the
            // pane verbatim — no prefix, no mouse, no scroll keys.
            // The markers ride along, because the pane is the one that
            // asked for them.
            if (c.paste.active) {
                const n = c.paste.take(rest);
                self.toFocused(rest[0..n]);
                rest = rest[n..];
                continue;
            }
            if (c.prefix) {
                c.prefix = false;
                c.paste.reset();
                self.command(c, rest[0]);
                rest = rest[1..];
                continue;
            }
            // The inspector is a sheet: any key closes it, and that
            // key is spent on the closing.
            if (self.inspect) {
                self.inspect = false;
                self.full = true;
                self.pending = true;
                rest = rest[1..];
                continue;
            }
            // SGR mouse: ESC [ < btn ; x ; y (M|m)
            if (rest.len >= 3 and rest[0] == 0x1b and rest[1] == '[' and rest[2] == '<') {
                if (parseMouse(rest)) |ev| {
                    c.paste.reset();
                    self.mouse(ev);
                    rest = rest[ev.len..];
                    continue;
                }
            }
            // a key, not a mouse report: the person is here and has seen the bar
            self.noticeSeen();
            if (self.scrolling) {
                c.paste.reset();
                self.scrollKey(rest[0]);
                rest = rest[1..];
                continue;
            }
            if (rest[0] == self.prefix_key) {
                c.prefix = true;
                c.paste.reset();
                rest = rest[1..];
                // the bar shows the pending key, so this earns a frame
                // — a full one, since no cell of any pane is dirty
                self.full = true;
                self.pending = true;
                continue;
            }
            // At the root the keys are the view's: the input, the
            // cursor, ↵. The prefix still arms above, so prefix-o
            // and prefix-s work from here — and a popup floated over
            // home (the picker) takes the keys while it is up.
            if (self.at_root and self.popup == null) {
                if (!self.veraHoldsKeys()) c.paste.reset();
                const used = self.altKey(c, rest);
                rest = rest[used..];
                continue;
            }
            // Vera's pane over a space holds the keyboard while it has it.
            if (self.vera_keys) {
                if (!self.veraHoldsKeys()) c.paste.reset();
                const used = self.veraKey(c, rest);
                rest = rest[used..];
                continue;
            }
            // The ownership gate holds the keyboard while it is up.
            if (self.gate) {
                c.paste.reset();
                self.gateKey(rest[0]);
                rest = rest[1..];
                continue;
            }
            // A lone Ctrl-h/j/k/l is pane navigation, vim-tmux-navigator
            // style: it moves focus (crossing the pin-rail seam too,
            // since the rail is in `placed`), and falls through to the
            // pane when there is nowhere to go — so C-l still clears a
            // rightmost shell, C-j still accepts a line with no pane
            // below. vim and friends own the keys (nav_owners): the
            // plugin hands edge moves back via `rook nav`. Real
            // backspace is 0x7f, unaffected; only a literal Ctrl-H
            // (0x08) is spent on navigation when a left neighbor exists.
            if (bytes.len == 1 and self.popup == null) {
                if (ctrlNavDir(rest[0])) |dir| {
                    if (!self.fgOwnsCtrlNav() and self.navigate(dir)) {
                        c.paste.reset();
                        rest = rest[1..];
                        continue;
                    }
                }
            }
            // The same four keys as the kitty keyboard protocol spells
            // them. A pane that pushed kitty flags — Claude Code, the
            // companion's chat — gets Ctrl-h from the glass as
            // `ESC [ 104 ; 5 u`, not 0x08, because mirrorKitty makes
            // the glass encode for the focused pane; the navigator
            // has to read that spelling too or those panes swallow
            // the motion. A release of a key the pane never saw
            // pressed is dropped with it.
            if (self.popup == null) {
                if (kittyNavDir(rest)) |hit| {
                    if (!self.fgOwnsCtrlNav()) {
                        if (hit.release or self.navigate(hit.dir)) {
                            c.paste.reset();
                            rest = rest[hit.len..];
                            continue;
                        }
                    }
                }
            }
            // forward up to the next byte the server wants for itself
            const end = runEnd(&c.paste, rest, self.prefix_key);
            // A pane an actor owns does not take typed keys: the gate
            // opens instead, and the keystroke that opened it is
            // spent on that — never silently forwarded, never
            // reinterpreted. `s` in the gate lets a run through, up
            // to and including Enter, as a message to the actor.
            if (self.popup == null and !self.gate_pass) {
                if (self.focusedPane()) |fp| {
                    if (fp.keysGated()) {
                        self.gate = true;
                        self.full = true;
                        self.pending = true;
                        rest = rest[end..];
                        continue;
                    }
                }
            }
            self.toFocused(rest[0..end]);
            if (self.gate_pass and std.mem.indexOfScalar(u8, rest[0..end], '\r') != null) {
                self.gate_pass = false;
                self.full = true;
                self.pending = true;
            }
            rest = rest[end..];
        }
    }

    const Mouse = struct { btn: u32, x: u16, y: u16, release: bool, len: usize };

    /// In-flight drag selection: pane id and anchor cell.
    const Drag = struct { pane: u32, ax: u16, ay: u16, moved: bool };

    fn parseMouse(bytes: []const u8) ?Mouse {
        // ESC [ < btn ; x ; y M|m
        var i: usize = 3;
        var nums = [3]u32{ 0, 0, 0 };
        var ni: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b >= '0' and b <= '9') {
                nums[ni] = nums[ni] * 10 + (b - '0');
            } else if (b == ';') {
                ni += 1;
                if (ni > 2) return null;
            } else if (b == 'M' or b == 'm') {
                if (ni != 2) return null;
                return .{
                    .btn = nums[0],
                    .x = @intCast(@max(1, nums[1])),
                    .y = @intCast(@max(1, nums[2])),
                    .release = b == 'm',
                    .len = i + 1,
                };
            } else return null;
        }
        return null; // incomplete: caller falls through, bytes flushed to pane
    }

    /// A mouse event: click focuses the pane under it; wheel scrolls
    /// the pane (or the event is forwarded, pane-relative, when the
    /// program asked for mouse).
    fn mouse(self: *Server, ev: Mouse) void {
        // find the pane under the pointer (0-based cell coords)
        const cx = ev.x - 1;
        const cy = ev.y - 1;
        if (self.popup != null) {
            const r = self.popupRect();
            const p = self.popupPane() orelse return;
            if (cx > r.x and cx < r.x + r.w -| 1 and cy > r.y and cy < r.y + r.h -| 1) {
                if (p.wantsMouse()) {
                    var mb: [32]u8 = undefined;
                    const ms = std.fmt.bufPrint(&mb, "\x1b[<{d};{d};{d}{c}", .{
                        ev.btn,
                        cx - r.x,
                        cy - r.y,
                        @as(u8, if (ev.release) 'm' else 'M'),
                    }) catch return;
                    p.write(ms);
                } else if (ev.btn == 64) {
                    p.scroll(-3);
                    self.pending = true;
                } else if (ev.btn == 65) {
                    p.scroll(3);
                    self.pending = true;
                }
            }
            return;
        }
        // The calm bar is not a target: nothing on it is a control.
        if (self.barOn() and cy >= self.bodyRows()) return;
        // The companion's panel is over both the root's rows and a
        // space's panes, so it is asked first: a click in it takes
        // the keyboard and then belongs to the program, and the
        // wheel scrolls her transcript, not what is behind her.
        if (self.veraChatPane()) |vp| {
            if (self.veraPanel()) |panel| {
                const body = homepkg.veraBody(panel.r, self.alt.home.about_title_len > 0);
                if (homepkg.chatFits(body) and cx >= body.x and cx < body.x + body.w and cy >= body.y and cy < body.y + body.h) {
                    if (ev.btn < 3 and !ev.release and !self.veraHoldsKeys()) {
                        self.alt.home.focus = .vera;
                        if (!self.at_root) self.vera_keys = true;
                        self.full = true;
                        self.pending = true;
                    }
                    if (vp.wantsMouse()) {
                        var mb: [32]u8 = undefined;
                        const ms = std.fmt.bufPrint(&mb, "\x1b[<{d};{d};{d}{c}", .{
                            ev.btn,
                            cx - body.x + 1,
                            cy - body.y + 1,
                            @as(u8, if (ev.release) 'm' else 'M'),
                        }) catch return;
                        vp.write(ms);
                    } else if (ev.btn == 64) {
                        vp.scroll(-3);
                    } else if (ev.btn == 65) {
                        vp.scroll(3);
                    }
                    self.full = true;
                    self.pending = true;
                    return;
                }
            }
        }
        // At the root a click lands on a row, or on the global pins,
        // which are live; anywhere else on the view is the view's.
        // Nothing on the glass is a way back into a space but a row.
        if (self.at_root) {
            const r = self.altRegion();
            if (cx >= r.x and cy >= r.y and cy < r.y + r.h) {
                if (ev.btn == 0 and !ev.release) {
                    if (self.alt.rowAt(cy)) |i| {
                        self.alt.cur = i;
                        self.altAct();
                    }
                } else if (ev.btn == 64) {
                    self.alt.move(-1);
                    self.full = true;
                    self.pending = true;
                } else if (ev.btn == 65) {
                    self.alt.move(1);
                    self.full = true;
                    self.pending = true;
                }
                return;
            }
            var on_pin = false;
            for (self.alt_placed.items) |pl| {
                if (cx >= pl.rect.x and cx < pl.rect.x + pl.rect.w and cy >= pl.rect.y and cy < pl.rect.y + pl.rect.h) on_pin = true;
            }
            if (!on_pin) return;
        }
        // the side panel eats clicks before any pane sees them
        if (self.side_w) |sw| {
            if (cx <= sw) {
                if (ev.btn == 0 and !ev.release) self.clickSide(cy);
                return;
            }
        }
        // Row 0 past the chrome to its left is the tab bar, and no
        // pane is under it: a click there is the bar's, hit or miss.
        if (cy == 0 and cx >= self.tab_x) {
            if (ev.btn == 0 and !ev.release) self.clickTab(cx - self.tab_x);
            return;
        }
        var hit: ?layoutpkg.Placed = null;
        for (self.placed.items) |pl| {
            if (cx >= pl.rect.x and cx < pl.rect.x + pl.rect.w and cy >= pl.rect.y and cy < pl.rect.y + pl.rect.h) hit = pl;
        }
        const pl = hit orelse return;
        const is_press_click = ev.btn < 3 and !ev.release;
        if (is_press_click and pl.pane != self.focusedId()) self.setFocus(pl.pane);
        const p = self.pane(pl.pane) orelse return;
        if (!p.wantsMouse()) {
            // Mux-side text selection, tmux-style: press anchors, drag
            // extends, release copies to the glass (OSC 52) and keeps
            // the highlight.
            const px = cx - pl.rect.x;
            const py = cy - pl.rect.y;
            if (ev.btn == 0 and !ev.release) {
                p.clearSelection();
                self.drag = .{ .pane = pl.pane, .ax = px, .ay = py, .moved = false };
                self.full = true;
                self.pending = true;
                return;
            }
            if (ev.btn == 32) { // motion with left button held
                if (self.drag) |*d| {
                    if (d.pane == pl.pane) {
                        p.setSelection(d.ax, d.ay, px, py);
                        d.moved = true;
                        self.full = true;
                        self.pending = true;
                    }
                }
                return;
            }
            if (ev.btn == 0 and ev.release) {
                if (self.drag) |d| {
                    self.drag = null;
                    if (d.moved) {
                        if (p.selectionText()) |text| {
                            defer self.gpa.free(text);
                            self.shipClip(text);
                        }
                        return;
                    }
                }
                // plain click: nothing more to do (focus already moved)
                return;
            }
        }
        if (p.wantsMouse()) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
                ev.btn,
                cx - pl.rect.x + 1,
                cy - pl.rect.y + 1,
                @as(u8, if (ev.release) 'm' else 'M'),
            }) catch return;
            p.write(s);
            return;
        }
        // wheel on a mouse-less pane scrolls its viewport
        if (ev.btn == 64) {
            p.scroll(-3);
            self.full = true;
            self.pending = true;
        } else if (ev.btn == 65) {
            p.scroll(3);
            self.full = true;
            self.pending = true;
        }
    }

    /// A click on the tab bar: a chip selects its window, the `+`
    /// opens a new one — the same two verbs as prefix-1..9 and
    /// prefix-c, reached with the hand that is already on the mouse.
    /// The zones are the ones the painter recorded, so the target is
    /// wherever the chip was actually drawn; a click on the air
    /// between chips, on the `⋯ n more` tail or on the corner hint
    /// lands on nothing and does nothing.
    fn clickTab(self: *Server, x: u16) void {
        const target = chromepkg.hitTab(self.tab_zones[0..self.tab_zones_n], x) orelse return;
        switch (target) {
            .window => |i| {
                if (i < self.sess().windows.items.len and i != self.sess().cur) self.selectWindow(i);
            },
            .new => self.newWindow(null, null) catch {},
        }
    }

    /// A click in the side panel moves that panel's cursor, and goes
    /// to the workspace the row names when rook holds one. Motion is
    /// rook's; what a row *means* belongs to whoever pushed it, and
    /// the next push takes the highlight back — so the highlight stays
    /// a cursor, not rook holding a producer's selection state. A
    /// workspace name is the one part of a row that is rook's own
    /// vocabulary, which is why acting on it is rook's to do; the
    /// click itself will be forwarded when there is a producer to
    /// forward it to (docs/surfaces.md).
    fn clickSide(self: *Server, cy: u16) void {
        const split = chromepkg.splitRow(self.bodyRows());
        if (cy == split) return; // the seam between the panels
        const which: chromepkg.Surface = if (cy < split) .spaces else .agents;
        const m = self.sideModel();
        const panel = if (cy < split) m.spaces else m.agents;
        const rel = if (cy < split) cy else cy - (split + 1);
        // How many of the merged panel's rows came from a producer:
        // everything after them is a row rook found for itself.
        const slot = if (cy < split) &self.side.spaces else &self.side.agents;
        const pushed_n = if (slot.panel) |p| p.items.len else 0;
        const h = chromepkg.hitRow(panel, pushed_n, rel) orelse return;
        // A row that names a workspace rook holds is a place to go,
        // whoever put it there: a found row is named for its
        // workspace, and a producer claims one with `workspace` on its
        // row — rook's own vocabulary, the same claim the merge reads.
        // Everything else is prose about work rook cannot see, and a
        // click on it is only a cursor.
        //
        // The cursor moves either way: the click is still cursor
        // motion, and when there was nowhere to go that is all it was.
        // A row past the pushed ones is one rook found for itself, so
        // the cursor on it is rook's to hold — the two cursors are
        // kept mutually exclusive here, the only place both are in
        // hand at once.
        if (which == .agents) {
            // On agents the row *is* the agent, so focus lands on the
            // pane running it, not on whatever that workspace was last
            // looking at.
            self.jumpToAgent(h.ws);
            if (h.found) {
                self.agents_merge.cur = h.row;
            } else {
                self.agents_merge.cur = null;
                _ = self.side.moveCursor(.agents, h.row);
            }
        } else {
            self.switchSessionNamed(h.ws);
            if (!h.found) _ = self.side.moveCursor(.spaces, h.row);
        }
        self.full = true;
        self.pending = true;
    }

    /// Go to the agent a rail row points at: `name`'s workspace becomes
    /// current and focus lands on the pane running an agent there.
    /// Nothing happens when rook holds no workspace by that name — the
    /// row is about work rook cannot see, so the click was only a
    /// cursor.
    fn jumpToAgent(self: *Server, name: []const u8) void {
        const idx = self.sessionNamed(name) orelse return;
        const sn = self.sessions.items[idx];
        const id = self.agentPaneIn(sn) orelse {
            self.switchSession(idx);
            return;
        };
        self.focusPane(id);
    }

    /// Bring a pane in front of the person: its workspace, then its
    /// window, then focus. A pin is reachable from every window of its
    /// workspace, a global pin from everywhere, so those stop at the
    /// workspace. The popup is not somewhere focus can be sent.
    fn focusPane(self: *Server, id: u32) void {
        if (self.ownPane(id)) return;
        for (self.sessions.items, 0..) |sn, si| {
            var here = false;
            for (sn.pins.items) |pid| {
                if (pid == id) here = true;
            }
            var win: ?usize = null;
            for (sn.windows.items, 0..) |w, wi| {
                if (w.layout.contains(id)) {
                    here = true;
                    win = wi;
                }
            }
            if (!here) continue;
            if (si != self.cur_sess) self.switchSession(si);
            // The pane may be in another window of that workspace; the
            // window has to come forward before focus can land on it.
            if (win) |wi| {
                if (wi != sn.cur) self.selectWindow(wi);
            }
            if (self.focusedId() != id) self.setFocus(id);
            return;
        }
        for (self.global_pins.items) |pid| {
            if (pid == id and self.focusedId() != id) self.setFocus(id);
        }
    }

    /// prefix-u, `rook jump`: go to the oldest thing nobody has read.
    /// First the unread channel — a pane a program rang, notified or
    /// finished a progress bar in while nobody looked — oldest signal
    /// first, so a queue of asks is answered in the order it formed.
    /// Failing that, the window whose unseen output is oldest, which
    /// is what the tab bar's softer dot means. True when focus moved.
    fn jumpUnread(self: *Server) bool {
        var best: ?*panepkg.Pane = null;
        for (self.panes.items) |p| {
            if (p.unread_ms == 0) continue;
            if (self.ownPane(p.id)) continue;
            if (best == null or p.unread_ms < best.?.unread_ms) best = p;
        }
        if (best) |p| {
            self.focusPane(p.id);
            return true;
        }
        // Unseen output: the window's focused pane, stamped after the
        // window was last on the glass.
        var oldest: ?struct { id: u32, at: i64 } = null;
        for (self.sessions.items, 0..) |sn, si| {
            for (sn.windows.items, 0..) |w, wi| {
                if (si == self.cur_sess and wi == sn.cur) continue;
                const p = self.pane(w.focused) orelse continue;
                const last = p.last_output_ms.load(.acquire);
                if (last == 0 or last <= w.seen_ms) continue;
                if (oldest == null or last < oldest.?.at) oldest = .{ .id = p.id, .at = last };
            }
        }
        if (oldest) |o| {
            self.focusPane(o.id);
            return true;
        }
        return false;
    }

    /// Is this pane in front of somebody right now: focused, on the
    /// glass, with a glass attached to see it, and no popup over it?
    /// A signal that arrives while this is true was seen as it
    /// happened; one that arrives otherwise is unread until it is.
    fn isSeen(self: *Server, id: u32) bool {
        if (self.popup != null) return false;
        // focus is observing, but at the root nobody is on the pane,
        // and under the inspector the pane is covered
        if (self.at_root or self.inspect) return false;
        if (self.focusedId() != id) return false;
        var placed = false;
        for (self.placed.items) |pl| {
            if (pl.pane == id) placed = true;
        }
        if (!placed) return false;
        for (self.clients.items) |c| {
            if (c.attached and !c.dead) return true;
        }
        return false;
    }

    /// Any pane of this window on the unread channel?
    fn windowUnread(self: *Server, w: *Window) bool {
        for (self.panes.items) |p| {
            if (p.unread_ms != 0 and w.layout.contains(p.id)) return true;
        }
        return false;
    }

    /// Any pane of this workspace — window or rail — on the channel?
    fn sessionUnread(self: *Server, sn: *Session) bool {
        for (self.panes.items) |p| {
            if (p.unread_ms != 0 and self.paneIn(sn, p.id)) return true;
        }
        return false;
    }

    /// Take what every pane's program said to its terminal since the
    /// last turn, and act on the *arrival*: publish it, put the pane
    /// on the unread channel when nobody was looking, and pass the
    /// bell and the notification on to the glass — which is what a
    /// terminal does with them, and what every pane lost when the mux
    /// went between it and one. Never on the words: rook does not
    /// read a title for what the program is doing.
    fn pollSignals(self: *Server) void {
        var ev: panepkg.Events = undefined;
        var changed = false;
        var drift = false;
        for (self.panes.items) |p| {
            if (!p.takeEvents(&ev)) continue;
            const now = panepkg.epochMs();
            const seen = self.isSeen(p.id);
            if (ev.bell) {
                p.bell_ms = now;
                if (!seen) self.markUnread(p, now);
                self.shipToGlass("\x07");
                changed = true;
            }
            if (ev.notif) {
                @memcpy(p.notif_title[0..ev.notif_title_len], ev.notif_title[0..ev.notif_title_len]);
                p.notif_title_len = ev.notif_title_len;
                @memcpy(p.notif_body[0..ev.notif_body_len], ev.notif_body[0..ev.notif_body_len]);
                p.notif_body_len = ev.notif_body_len;
                p.notif_ms = now;
                if (!seen) {
                    self.markUnread(p, now);
                    self.shipNotify(p.notif_title[0..p.notif_title_len], p.notif_body[0..p.notif_body_len]);
                }
                changed = true;
            }
            if (ev.progress) {
                const was = p.progress.active();
                p.progress = ev.prog;
                p.progress_pct = ev.prog_pct;
                if (was and !p.progress.active()) {
                    p.progress_done_ms = now;
                    if (!seen) self.markUnread(p, now);
                    changed = true;
                } else {
                    // a bar moving is drift, not news
                    drift = true;
                }
            }
            if (ev.title or ev.pwd) drift = true;
        }
        if (changed) {
            _ = self.touch();
            self.full = true; // the tab bar and the rail wear the dot
            self.pending = true;
        } else if (drift) {
            // the glass title mirrors the focused pane on redraw
            self.pending = true;
        }
    }

    fn markUnread(self: *Server, p: *panepkg.Pane, now: i64) void {
        _ = self;
        if (p.unread_ms == 0) p.unread_ms = now;
    }

    /// The pane in front of the person has been looked at: whatever
    /// was unread there is read. Runs on every frame, so "seen"
    /// tracks looking rather than switching, the same as a window's
    /// `seen_ms`. True when something was cleared.
    fn markSeen(self: *Server) bool {
        const id = self.focusedId();
        if (!self.isSeen(id)) return false;
        const p = self.pane(id) orelse return false;
        if (p.unread_ms == 0) return false;
        p.unread_ms = 0;
        _ = self.touch();
        return true;
    }

    /// Raw bytes to every attached glass, on the draw channel.
    fn shipToGlass(self: *Server, bytes: []const u8) void {
        for (self.clients.items) |c| {
            if (!c.attached or c.dead) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), bytes);
        }
    }

    /// A pane's desktop notification, re-sent to the glass as OSC 777
    /// so the terminal that can actually reach the person's desktop
    /// does. Control bytes are dropped: the words are the program's,
    /// but the sequence they ride in is ours.
    fn shipNotify(self: *Server, title: []const u8, body: []const u8) void {
        var buf: [16 + panepkg.max_notif_title + panepkg.max_notif_body]u8 = undefined;
        var out: std.ArrayList(u8) = .initBuffer(&buf);
        out.appendSliceBounded("\x1b]777;notify;") catch return;
        oscText(&out, if (title.len > 0) title else "rook");
        out.appendSliceBounded(";") catch return;
        oscText(&out, body);
        out.appendSliceBounded("\x1b\\") catch return;
        self.shipToGlass(out.items);
    }

    /// The first pane in this workspace whose foreground program is an
    /// agent, in pane order — the pane a click on its row goes to.
    fn agentPaneIn(self: *Server, sn: *Session) ?u32 {
        for (self.panes.items) |p| {
            if (!self.paneIn(sn, p.id)) continue;
            var nb: [64]u8 = undefined;
            const fg = p.fgName(&nb) orelse continue;
            if (self.isAgentProgram(fg)) return p.id;
        }
        return null;
    }

    fn toFocused(self: *Server, bytes: []const u8) void {
        if (self.popupPane()) |p| {
            p.write(bytes);
            return;
        }
        // A paste is content, and it belongs to whoever is holding
        // the keyboard: while the companion's terminal has it, a
        // pasted stack trace goes into her box and not into the pane
        // behind her.
        if (self.veraHoldsKeys()) {
            if (self.veraChatPane()) |p| {
                p.write(bytes);
                self.full = true;
                self.pending = true;
                return;
            }
        }
        if (self.focusedPane()) |p| {
            // typing returns the view to now — a wheel-scrolled pane
            // must not eat keystrokes into an old screen silently
            p.scrollBottom();
            p.write(bytes);
        }
    }

    fn clearDrag(self: *Server) void {
        if (self.drag) |d| {
            if (self.pane(d.pane)) |p| p.clearSelection();
            self.drag = null;
        }
    }

    fn command(self: *Server, c: *Client, key: u8) void {
        if (self.popup != null) {
            switch (key) {
                'x' => if (self.popupPane()) |p| p.hangup(),
                'd' => {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "");
                    c.attached = false;
                },
                else => {
                    if (key == self.prefix_key) self.toFocused(&[_]u8{key});
                },
            }
            self.pending = true;
            return;
        }
        // At the root the space is not on the glass, so the keys that
        // act on it are not taken: only the root's own, and detach.
        if (self.at_root and !rootKey(key)) {
            self.full = true;
            self.pending = true;
            return;
        }
        switch (key) {
            'v', '|' => self.splitPane(true) catch {},
            '-' => self.splitPane(false) catch {},
            'h', 'j', 'k', 'l' => _ = self.navigate(key),
            'c' => self.newWindow(null, null) catch {},
            'n' => self.selectWindow((self.sess().cur + 1) % self.sess().windows.items.len),
            'p' => self.selectWindow((self.sess().cur + self.sess().windows.items.len - 1) % self.sess().windows.items.len),
            '1'...'9' => {
                const i: usize = key - '1';
                if (i < self.sess().windows.items.len) self.selectWindow(i);
            },
            // The picker — fzf over `rook ls`, enter switches, ctrl-o
            // creates the name typed — lives in the Go front door,
            // where the quoting has a home and the parsing has tests.
            // Here it is one verb, like the worktree manager. It
            // floats from home too: picking a space enters it, and
            // orbit, which held this key for a while, is `:orbit`.
            's' => self.openPopup(self.popupSized("rook pick")) catch {},
            'w' => self.openPopup(self.popupSized("rook worktree")) catch {},
            // Grim: the resident agent, floated over whatever this is.
            // The popup is only a view of it — grim is a service with a
            // life of its own (github.com/incantery/grimoire), so
            // closing this ends nothing. Like the two above it is one
            // verb here; what grim is, is grim's. It floats from home
            // too: what you want to ask is not always about a pane.
            'g' => self.openPopup(self.popupSized("\x1f72x86@124x48\x1fgrim")) catch {},
            // The root, with the cursor on a section: running work,
            // or what needs you (`!` is the attention mark).
            'a' => self.goHomeAt(.running),
            '!' => self.goHomeAt(.needs),
            // Vera: her pane, from anywhere; pinned, she stays.
            't' => self.toggleVera(),
            'T' => {
                self.alt.home.vera_pinned = !self.alt.home.vera_pinned;
                if (self.alt.home.vera_pinned) self.alt.home.vera_open = true;
                if (!self.at_root) self.vera_keys = self.alt.home.veraShown() and self.alt.home.focus == .vera;
            },
            // The root in a mode: find, command.
            '/' => self.goHomeTyping("/"),
            ':' => self.goHomeTyping(":"),
            // The legacy side panel, away and back, for a config that
            // asked for it.
            'A' => {
                self.side_mode = if (self.side_mode == .hidden) .open else .hidden;
                self.relayout() catch {};
            },
            'P' => self.togglePin(),
            'G' => self.toggleGlobalPin(),
            ';' => {
                if (self.sess().last_focus) |last| {
                    if (self.pane(last) != null) self.setFocus(last);
                }
            },
            'H' => self.adjustSplit(.horizontal, -0.05),
            'L' => self.adjustSplit(.horizontal, 0.05),
            'K' => self.adjustSplit(.vertical, -0.05),
            'J' => self.adjustSplit(.vertical, 0.05),
            'z' => {
                self.window().zoomed = !self.window().zoomed;
                self.relayout() catch {};
            },
            '[' => self.scrollStart(),
            'u' => _ = self.jumpUnread(),
            // Out, to rook: home. The panes never pause. From the root
            // it is idempotent — home again, whatever subview was up.
            'o' => self.goHome(),
            // Return jump: back to the space before the last hop.
            0x0f => if (self.last_sess) |ls| {
                if (ls < self.sessions.items.len) self.switchSession(ls);
            },
            'i' => if (!self.at_root) {
                self.inspect = !self.inspect;
                self.full = true;
            },
            'x' => if (self.focusedPane()) |p| p.hangup(),
            'd' => {
                self.sendTo(c, @intFromEnum(proto.s2c.exit), "");
                c.attached = false;
            },
            else => {
                // the prefix key itself: double-tap types it literally
                if (key == self.prefix_key) self.toFocused(&[_]u8{key});
            },
        }
        // the bar drops its pending-key hint whatever the key did
        self.full = true;
        self.pending = true;
    }

    /// The prefix keys that mean something at the root.
    fn rootKey(key: u8) bool {
        return switch (key) {
            'o', 's', 'g', 'a', '!', 't', 'T', '/', ':', 0x0f, 'd', 'A', 'u' => true,
            else => false,
        };
    }

    // ---- scroll mode ----

    fn scrollStart(self: *Server) void {
        const p = self.focusedPane() orelse return;
        self.scrolling = true;
        self.selecting = false;
        self.scur = .{ .x = 0, .y = p.rows -| 1 };
        if (p.rs.cursor.visible) {
            if (p.rs.cursor.viewport) |v| self.scur = .{ .x = v.x, .y = v.y };
        }
        self.full = true;
    }

    fn scrollKey(self: *Server, key: u8) void {
        const p = self.focusedPane() orelse {
            self.scrolling = false;
            return;
        };
        const page: i32 = @intCast(@max(1, p.rows / 2));
        const max_y = p.rows -| 1;
        const max_x = p.cols -| 1;
        var moved = false;
        switch (key) {
            'h' => {
                self.scur.x -|= 1;
                moved = true;
            },
            'l' => {
                if (self.scur.x < max_x) self.scur.x += 1;
                moved = true;
            },
            'k' => {
                if (self.scur.y > 0) self.scur.y -= 1 else p.scroll(-1);
                moved = true;
            },
            'j' => {
                if (self.scur.y < max_y) self.scur.y += 1 else p.scroll(1);
                moved = true;
            },
            '0' => {
                self.scur.x = 0;
                moved = true;
            },
            '$' => {
                self.scur.x = max_x;
                moved = true;
            },
            'u' => {
                p.scroll(-page);
                moved = true;
            },
            'd' => {
                p.scroll(page);
                moved = true;
            },
            'g' => {
                p.scrollTop();
                self.scur.y = 0;
                moved = true;
            },
            'G' => {
                p.scrollBottom();
                self.scur.y = max_y;
                moved = true;
            },
            'v' => {
                self.selecting = !self.selecting;
                if (self.selecting) {
                    p.setSelection(self.scur.x, self.scur.y, self.scur.x, self.scur.y);
                } else {
                    p.clearSelection();
                }
            },
            'y' => {
                if (p.selectionText()) |text| {
                    defer self.gpa.free(text);
                    self.shipClip(text);
                }
                p.clearSelection();
                self.selecting = false;
                p.scrollBottom();
                self.scrolling = false;
            },
            'q', 0x1b => {
                p.clearSelection();
                self.selecting = false;
                p.scrollBottom();
                self.scrolling = false;
            },
            else => {},
        }
        if (moved and self.selecting) p.extendSelection(self.scur.x, self.scur.y);
        self.full = true;
        self.pending = true;
    }

    fn adjustSplit(self: *Server, axis: layoutpkg.Axis, delta: f32) void {
        const w = self.window();
        if (w.zoomed) return;
        const sn = self.sess();
        if (sn.focus_pin != null) {
            // focused on the rail: H/L change its width
            if (axis == .horizontal) sn.rail_frac = std.math.clamp(sn.rail_frac + delta, 0.15, 0.7);
        } else {
            layoutpkg.adjust(&w.layout, w.focused, axis, delta);
        }
        self.relayout() catch {};
    }

    fn selectWindow(self: *Server, i: usize) void {
        const sn = self.sess();
        if (i == sn.cur) return;
        const old_focused = self.focusedId();
        sn.cur = i;
        self.scrolling = false;
        self.selecting = false;
        self.focusEvents(old_focused, self.focusedId());
        self.relayout() catch {};
    }

    /// 'h'/'j'/'k'/'l' → directional focus move. Returns true when
    /// focus actually moved (false at an edge, or zoomed).
    fn navigate(self: *Server, dir: u8) bool {
        if (self.window().zoomed) return false;
        const dx: i32 = switch (dir) {
            'h' => -1,
            'l' => 1,
            else => 0,
        };
        const dy: i32 = switch (dir) {
            'k' => -1,
            'j' => 1,
            'h', 'l' => 0,
            else => return false,
        };
        const from = self.focusedId();
        if (layoutpkg.navigate(self.placed.items, from, dx, dy)) |id| {
            if (id != from) {
                self.setFocus(id);
                return true;
            }
        }
        return false;
    }

    /// Tell panes that asked for focus reporting (?1004) when mux
    /// focus moves between them — nvim's FocusGained/autoread food.
    fn focusEvents(self: *Server, old_id: u32, new_id: u32) void {
        if (old_id == new_id) return;
        if (self.pane(old_id)) |p| {
            if (p.modeSet(.focus_event)) p.write("\x1b[O");
        }
        if (self.pane(new_id)) |p| {
            if (p.modeSet(.focus_event)) p.write("\x1b[I");
        }
    }

    /// prefix-P: dock the focused pane to the workspace rail, or put a
    /// docked one back into the current window as a split. A window's
    /// last pane can't be pinned (the window would vanish).
    fn togglePin(self: *Server) void {
        const sn = self.sess();
        const w = self.window();
        const id = self.focusedId();
        if (self.isPin(id)) {
            // unpin: back into the current window beside its focus
            removeId(&self.global_pins, id);
            self.forgetOrigin(id);
            removeId(&sn.pins, id);
            w.layout.split(w.focused, id, true) catch return;
            sn.focus_pin = null;
            w.focused = id;
        } else {
            if (w.layout.isSingle()) return; // a window's last pane stays
            _ = w.layout.remove(id);
            if (w.focused == id) w.focused = w.layout.firstLeaf() orelse 0;
            sn.pins.append(self.gpa, id) catch return;
            sn.focus_pin = id;
        }
        w.zoomed = false;
        self.relayout() catch {};
    }

    /// prefix-G on a rail pane: toggle between workspace-scoped and
    /// global (follows you across workspaces).
    fn toggleGlobalPin(self: *Server) void {
        const sn = self.sess();
        const id = sn.focus_pin orelse return;
        if (containsId(self.global_pins.items, id)) {
            removeId(&self.global_pins, id);
            self.forgetOrigin(id);
            sn.pins.append(self.gpa, id) catch return;
        } else {
            removeId(&sn.pins, id);
            self.global_pins.append(self.gpa, id) catch return;
            self.setOrigin(id, sn.label());
        }
        self.relayout() catch {};
    }

    fn setOrigin(self: *Server, id: u32, name: []const u8) void {
        self.forgetOrigin(id);
        var o: PinOrigin = .{ .pane = id };
        o.len = @min(name.len, o.name.len);
        @memcpy(o.name[0..o.len], name[0..o.len]);
        self.pin_origins.append(self.gpa, o) catch {};
    }

    fn forgetOrigin(self: *Server, id: u32) void {
        var i: usize = 0;
        while (i < self.pin_origins.items.len) {
            if (self.pin_origins.items[i].pane == id) {
                _ = self.pin_origins.swapRemove(i);
            } else i += 1;
        }
    }

    /// The world in one line, for the tab bar at altitude: how many
    /// spaces, how many agents producing, how many things need you
    /// (panes unread, and what a producer said is waiting). Only the
    /// nonzero parts; a quiet world says so.
    fn altSummary(self: *Server, buf: []u8) []const u8 {
        const spaces = self.sessions.items.len;
        const working = self.countWorking();
        const needs = self.countUnread() + self.countAsks();
        var w: std.Io.Writer = .fixed(buf);
        w.print("{d} space{s}", .{ spaces, plural(spaces) }) catch {};
        if (working > 0) w.print(" · {d} agent{s} working", .{ working, plural(working) }) catch {};
        if (needs > 0) w.print(" · {d} need{s} you", .{ needs, if (needs == 1) "s" else "" }) catch {};
        if (working == 0 and needs == 0) w.writeAll(" · all quiet") catch {};
        return w.buffered();
    }

    /// Rows a producer pushed saying an agent in a space rook holds
    /// is waiting on you, or failed.
    fn countAsks(self: *Server) usize {
        const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};
        var n: usize = 0;
        for (claims) |it| {
            if (it.state != .blocked and it.state != .failed) continue;
            if (self.sessionNamed(it.workspace()) != null) n += 1;
        }
        return n;
    }

    /// The space a global pin was promoted out of, "" when unknown.
    pub fn pinOrigin(self: *Server, id: u32) []const u8 {
        for (self.pin_origins.items) |*o| {
            if (o.pane == id) return o.label();
        }
        return "";
    }

    /// Programs that own Ctrl-h/j/k/l themselves: vim navigates its own
    /// windows first (its plugin calls `rook nav` at an edge), fzf
    /// lives on C-j/C-k.
    fn fgOwnsCtrlNav(self: *Server) bool {
        const p = self.focusedPane() orelse return false;
        var buf: [64]u8 = undefined;
        const name = p.fgName(&buf) orelse return false;
        if (self.conf.owners_len > 0) {
            var it = std.mem.splitScalar(u8, self.conf.ownersSlice(), '\n');
            while (it.next()) |o| {
                if (std.mem.eql(u8, name, o)) return true;
            }
            return false;
        }
        const owners = [_][]const u8{ "nvim", "vim", "vi", "view", "gvim", "vimdiff", "nvimdiff", "fzf" };
        for (owners) |o| {
            if (std.mem.eql(u8, name, o)) return true;
        }
        return false;
    }

    fn reap(self: *Server) !void {
        var i: usize = 0;
        var removed = false;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            if (!p.exited.load(.acquire)) {
                i += 1;
                continue;
            }
            if (self.popup == p.id) {
                self.popup = null;
                self.full = true;
                p.deinit();
                _ = self.panes.swapRemove(i);
                removed = true;
                continue;
            }
            // The chat quit — `/quit`, a crash, `vera` upgraded out
            // from under it. The panel falls back to rook's own
            // surface, and the next summoning starts a fresh one
            // rather than leaving a dead rectangle on the glass.
            if (self.vera_pane == p.id) {
                // The chat quit — `/quit`, a crash, a verad it could
                // not reach. The panel falls back to rook's own
                // surface, and the last thing the program managed to
                // say goes into the thread, because a terminal that
                // died with an error on it is the one place the
                // reason is written down.
                self.noteVeraQuit(p);
                self.vera_pane = null;
                self.vera_dead = true;
                self.vera_keys = false;
                self.full = true;
                self.pending = true;
                p.deinit();
                _ = self.panes.swapRemove(i);
                removed = true;
                continue;
            }
            // a pinned pane: drop it from its rail
            removeId(&self.global_pins, p.id);
            self.forgetOrigin(p.id);
            for (self.sessions.items) |sn| {
                removeId(&sn.pins, p.id);
                if (sn.focus_pin == p.id) sn.focus_pin = null;
                if (sn.last_focus == p.id) sn.last_focus = null;
            }
            // remove from whichever session's window holds it
            outer: for (self.sessions.items, 0..) |sn, si| {
                var wi: usize = 0;
                while (wi < sn.windows.items.len) : (wi += 1) {
                    const w = sn.windows.items[wi];
                    if (!w.layout.contains(p.id)) continue;
                    const still = w.layout.remove(p.id);
                    if (!still) {
                        w.layout.deinit();
                        self.gpa.destroy(w);
                        _ = sn.windows.orderedRemove(wi);
                        if (sn.cur >= sn.windows.items.len and sn.cur > 0) sn.cur -= 1;
                        if (sn.windows.items.len == 0) {
                            sn.windows.deinit(self.gpa);
                            self.gpa.destroy(sn);
                            _ = self.sessions.orderedRemove(si);
                            if (self.cur_sess >= self.sessions.items.len and self.cur_sess > 0) self.cur_sess -= 1;
                        }
                    } else {
                        w.zoomed = false;
                        if (w.focused == p.id) w.focused = w.layout.firstLeaf() orelse 0;
                    }
                    break :outer;
                }
            }
            // block clients riding this pane get a clean goodbye
            for (self.clients.items) |bc| {
                if (bc.block == p.id) {
                    self.sendTo(bc, @intFromEnum(proto.s2c.exit), "");
                    bc.block = null;
                    bc.lease = false;
                }
            }
            p.deinit();
            _ = self.panes.swapRemove(i);
            removed = true;
        }
        if (removed) self.updateTees();
        if (removed and self.sessions.items.len > 0) try self.relayout();
    }

    fn redraw(self: *Server) !void {
        if (self.popup != null) self.full = true; // popups sit over dirty math
        // Under a popup the chrome is under the scrim too: the bars
        // and the root's canvas are built on the faded theme for this
        // frame, so the popup is the one lit plane, bars included.
        const lit = self.ui;
        defer self.ui = lit;
        if (self.popup != null) self.ui = lit.under();
        // Looking at the focused pane reads it; the dot it wore on
        // the tab and the rail goes with this frame.
        if (self.markSeen()) self.full = true;
        var any_dirty = self.full;
        for (self.placed.items) |pl| {
            const p = self.pane(pl.pane) orelse continue;
            p.snapshot() catch continue;
            if (p.rs.dirty != .false) any_dirty = true;
            p.rs.dirty = .false;
        }
        if (self.popupPane()) |p| {
            p.snapshot() catch {};
            p.rs.dirty = .false;
        }
        // The hosted chat is not in `placed`, so nothing above has
        // looked at it: a token streaming in dirties no window pane
        // and would otherwise never earn a frame.
        if (self.tendVera()) any_dirty = true;
        if (self.veraChatPane()) |p| {
            p.snapshot() catch {};
            if (p.rs.dirty != .false) any_dirty = true;
            p.rs.dirty = .false;
        }
        // A bare cursor move dirties no cell (zsh emits a lone \b when
        // backspacing over trailing blanks; a trailing space can land
        // the same way), so row-dirty misses it and the cursor freezes
        // on the glass until the next content change. Ship when the
        // focused cursor moved, too.
        var cur_now: @TypeOf(self.last_cursor) = null;
        if (self.pane(self.focusedId())) |p| {
            const vis = p.rs.cursor.visible;
            if (p.rs.cursor.viewport) |v| {
                cur_now = .{ .id = self.focusedId(), .x = v.x, .y = v.y, .vis = vis };
            } else {
                cur_now = .{ .id = self.focusedId(), .x = 0, .y = 0, .vis = vis };
            }
        }
        if (!std.meta.eql(self.last_cursor, cur_now)) any_dirty = true;
        self.last_cursor = cur_now;
        // OSC 52 from any visible pane goes straight to the glass; the
        // client is dumb, so it rides the draw channel as raw bytes.
        self.forwardClips();
        self.mirrorKitty();

        const g = self.geometry();
        const body = self.bodyRows();
        // The root's rows are built first: the bars read them (the
        // corner's counts, the bar's view word).
        if (self.at_root) {
            self.full = true;
            self.altBuild();
            altpkg.chooseFidelity(&self.alt, self.altRegion());
        }
        var tab_buf: [2048]u8 = undefined;
        const tabbar = self.tabBar(&tab_buf, g.cols -| self.tab_x);
        var bar_buf: [2048]u8 = undefined;
        const bar: ?renderpkg.Bar = if (self.barOn())
            .{ .y = body, .bytes = self.barRow(&bar_buf, g.cols) }
        else
            null;
        // the bars changed: a frame, whatever the panes did
        if (!std.mem.eql(u8, tabbar, self.tabbar_last[0..self.tabbar_last_len])) {
            any_dirty = true;
            self.tabbar_last_len = @min(tabbar.len, self.tabbar_last.len);
            @memcpy(self.tabbar_last[0..self.tabbar_last_len], tabbar[0..self.tabbar_last_len]);
        }
        const bar_bytes: []const u8 = if (bar) |b| b.bytes else "";
        if (!std.mem.eql(u8, bar_bytes, self.bar_last[0..self.bar_last_len])) {
            any_dirty = true;
            self.bar_last_len = @min(bar_bytes.len, self.bar_last.len);
            @memcpy(self.bar_last[0..self.bar_last_len], bar_bytes[0..self.bar_last_len]);
        }

        if (!any_dirty) return;

        // What the server paints over the panes itself. Built fresh
        // each frame it is needed: all three are human-rate views.
        self.over.buf.clearRetainingCapacity();
        var cur_over: ?renderpkg.CursorOverride = null;
        var placed = self.placed.items;
        var dock_x = self.dock_x;
        if (self.at_root) {
            // only the global pins stay live on the glass; every
            // other rect belongs to the space and contracts with it
            self.alt_placed.clearRetainingCapacity();
            for (self.placed.items) |pl| {
                if (containsId(self.global_pins.items, pl.pane)) {
                    self.alt_placed.append(self.gpa, pl) catch {};
                } else {
                    altpkg.clearRect(&self.over, &self.ui, pl.rect);
                }
            }
            placed = self.alt_placed.items;
            if (self.global_pins.items.len == 0) dock_x = null;
            cur_over = altpkg.draw(&self.over, &self.alt, self.altRegion(), .{ .t = &self.ui, .ask_name = self.askName(), .ask_on = self.ask_on, .prefix = prefixName(self.prefix_key, &self.prefix_name_buf), .chat = self.veraChatPane() });
        }
        // vera's pane inside a space: over the panes, the same pane
        if (!self.at_root and self.alt.home.veraShown()) {
            var pk: [8]u8 = undefined;
            const c = homepkg.drawVeraOver(&self.over, &self.alt, self.altRegion(), .{ .t = &self.ui, .ask_name = self.askName(), .ask_on = self.ask_on, .now = panepkg.epochMs(), .prefix = prefixName(self.prefix_key, &pk), .chat = self.veraChatPane() });
            if (self.vera_keys) cur_over = c;
        }
        if (self.gate and !self.at_root) self.gateRow();
        if (self.inspect and !self.at_root) self.inspectorSheet();

        if (self.scrolling and !self.at_root) {
            for (self.placed.items) |pl| {
                if (pl.pane == self.focusedId()) {
                    cur_over = .{
                        .x = pl.rect.x + @min(self.scur.x, pl.rect.w -| 1),
                        .y = pl.rect.y + @min(self.scur.y, pl.rect.h -| 1),
                    };
                }
            }
        }
        const chrome: renderpkg.Chrome = .{
            .tabbar = tabbar,
            .tab_x = self.tab_x,
            .side = if (self.side_w) |sw| .{ .model = self.sideModel(), .w = sw, .mode = self.side_shown } else null,
            .dock_x = dock_x,
            .dock_top = self.dock_top,
            .bar = bar,
            .overlay = self.over.buf.items,
        };
        // the root's cursor is the input's; the inspector and the
        // gate hide the pane's cursor, since the keys are not its
        const cur: ?renderpkg.CursorOverride = if (self.at_root or self.gate or self.inspect or self.vera_keys)
            (cur_over orelse renderpkg.CursorOverride{ .x = 0, .y = 0, .hidden = true })
        else
            cur_over;
        const bytes = self.frame.build(self.panes.items, placed, if (self.at_root) 0 else self.focusedId(), g.cols, body, chrome, self.full, cur, if (self.popup) |id| .{ .pane = id, .rect = self.popupRect() } else null);
        self.full = false;
        var shipped = false;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), bytes);
            self.bytes_sent += bytes.len;
            shipped = true;
        }
        if (shipped) {
            self.frames_sent += 1;
            self.lat.frame();
        }
    }

    fn forwardClips(self: *Server) void {
        var text_buf: [64 * 1024]u8 = undefined;
        for (self.panes.items) |p| {
            const text = p.takeClip(&text_buf) orelse continue;
            self.shipClip(text);
        }
    }

    fn attachedCount(self: *Server) usize {
        var n: usize = 0;
        for (self.clients.items) |c| {
            if (c.attached and !c.dead) n += 1;
        }
        return n;
    }

    /// Put a newly attached glass where it asked to be.
    fn landGlass(self: *Server, dest: []const u8, first: bool) void {
        if (dest.len == 0) {
            if (first) {
                if (self.conf.startup_last_space) self.enterSpace() else self.goHome();
            }
            return;
        }
        switch (dest[0]) {
            'r' => self.goHome(),
            's' => {
                const rest = dest[1..];
                var name = rest;
                var cwd: ?[*:0]const u8 = null;
                var cwd_buf: [1024]u8 = undefined;
                if (std.mem.indexOfScalar(u8, rest, '\t')) |tab| {
                    name = rest[0..tab];
                    const dir = rest[tab + 1 ..];
                    if (dir.len > 0 and dir.len < cwd_buf.len) {
                        @memcpy(cwd_buf[0..dir.len], dir);
                        cwd_buf[dir.len] = 0;
                        cwd = @ptrCast(&cwd_buf);
                    }
                }
                if (name.len == 0) return;
                _ = self.newSession(name, cwd, null, true) catch return;
                self.enterSpace();
            },
            else => {},
        }
    }

    /// A glass that has just attached is told the modes the focused
    /// pane already asked for. `mirrorKitty` only speaks on a change,
    /// so without this a second (or reattached) glass is left at its
    /// defaults — and a glass that was never told mode 2004 does not
    /// wrap Cmd-V in ESC[200~ … ESC[201~, which is the difference
    /// between a paste arriving as text and arriving as keystrokes.
    fn greetGlass(self: *Server, c: *Client) void {
        var buf: [64]u8 = undefined;
        var out: std.ArrayList(u8) = .initBuffer(&buf);
        if (self.glass_kitty != 0) {
            var kb: [16]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "\x1b[={d};1u", .{self.glass_kitty})) |seq| {
                out.appendSliceBounded(seq) catch {};
            } else |_| {}
        }
        if (self.glass_paste) out.appendSliceBounded("\x1b[?2004h") catch {};
        if (self.glass_focus) out.appendSliceBounded("\x1b[?1004h") catch {};
        if (out.items.len == 0) return;
        self.sendTo(c, @intFromEnum(proto.s2c.draw), out.items);
    }

    /// Keep the glass's kitty keyboard mode equal to the focused
    /// pane's flags. ghostty-vt already tracks the stack and answers
    /// the query per pane; this makes the outer terminal actually
    /// encode input the way that pane was promised. A terminal that
    /// doesn't know CSI = u ignores it.
    ///
    /// "Focused" means whoever is *receiving* keys: a popup takes
    /// them while it is up (`toFocused`), so the glass must encode
    /// for the popup, not for the pane underneath it. Otherwise fzf
    /// in the picker, floated over Claude Code — which pushes kitty
    /// flags — gets `ESC[112;5u` for Ctrl-P and does nothing.
    fn mirrorKitty(self: *Server) void {
        var buf: [256]u8 = undefined;
        var out: std.ArrayList(u8) = .initBuffer(&buf);
        // While the mux itself holds the keyboard — the root, the
        // gate, the inspector — the glass encodes legacy bytes, so
        // the view reads plain keys whatever the pane under it asked.
        // …unless the companion's own terminal is holding it. It is a
        // real program with a real box: it asked for bracketed paste
        // and for the kitty protocol, and a glass that answers in
        // legacy bytes turns a pasted stack trace into a run of
        // Enters and drops shift+enter — the two keys its multiline
        // input is built on.
        const held = if (self.veraHoldsKeys()) self.veraChatPane() else null;
        const mux_keys = held == null and (self.at_root or self.gate or self.inspect or self.vera_keys);
        const fp = held orelse (if (mux_keys) null else (self.popupPane() orelse self.focusedPane()));
        const kf: u8 = if (fp) |p| p.kittyFlags() else 0;
        if (kf != self.glass_kitty) {
            self.glass_kitty = kf;
            var kb: [16]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "\x1b[={d};1u", .{kf})) |seq| {
                out.appendSliceBounded(seq) catch {};
            } else |_| {}
        }
        // bracketed paste and focus reporting ride along: the glass
        // wraps pastes / sends focus in-out only if someone tells it
        const paste = if (fp) |p| p.modeSet(.bracketed_paste) else false;
        if (paste != self.glass_paste) {
            self.glass_paste = paste;
            out.appendSliceBounded(if (paste) "\x1b[?2004h" else "\x1b[?2004l") catch {};
        }
        const focus = if (fp) |p| p.modeSet(.focus_event) else false;
        if (focus != self.glass_focus) {
            self.glass_focus = focus;
            out.appendSliceBounded(if (focus) "\x1b[?1004h" else "\x1b[?1004l") catch {};
        }
        // the outer window is titled by the focused pane (OSC 2)
        var tb: [128]u8 = undefined;
        const t = if (fp) |p| p.title(&tb) else "";
        const shown = if (t.len > 0) t else "rook";
        if (!std.mem.eql(u8, shown, self.glass_title[0..self.glass_title_len])) {
            self.glass_title_len = @min(shown.len, self.glass_title.len);
            @memcpy(self.glass_title[0..self.glass_title_len], shown[0..self.glass_title_len]);
            out.appendSliceBounded("\x1b]2;") catch {};
            out.appendSliceBounded(shown[0..self.glass_title_len]) catch {};
            out.appendSliceBounded("\x07") catch {};
        }
        if (out.items.len == 0) return;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), out.items);
        }
    }

    /// Send text to every attached glass as OSC 52.
    fn shipClip(self: *Server, text: []const u8) void {
        const b64_len = std.base64.standard.Encoder.calcSize(text.len);
        const b64_buf = self.gpa.alloc(u8, b64_len) catch return;
        defer self.gpa.free(b64_buf);
        const b64 = std.base64.standard.Encoder.encode(b64_buf, text);
        var osc: std.ArrayList(u8) = .empty;
        defer osc.deinit(self.gpa);
        osc.appendSlice(self.gpa, "\x1b]52;c;") catch return;
        osc.appendSlice(self.gpa, b64) catch return;
        osc.appendSlice(self.gpa, "\x07") catch return;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), osc.items);
        }
    }

    // ---- resurrect: sessions/windows/cwds across server restarts ----

    /// v2 format, line-oriented:
    ///   v2
    ///   gpin <cwd>
    ///   session <name> [*]
    ///   pin <cwd>
    ///   window <cwd> [*]
    ///   pane <cwd>
    ///   resume <cmd>
    /// A window comes back as its focused pane in the saved cwd, plus
    /// a `pane` beside it for every other pane that knows how to bring
    /// its program back — splits are cheap to remake, but an agent's
    /// conversation is not. `resume` belongs to the pane on the line
    /// above it and is written only while the program that set it is
    /// still in the foreground (`Pane.resumeLive`). v1 files, without
    /// `pane` or `resume`, still read.
    fn saveState(self: *Server) void {
        if (self.state_path[0] == 0) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "v2\n") catch return;
        for (self.global_pins.items) |id| {
            self.savePane(&out, "gpin ", id, false) catch return;
            const from = self.pinOrigin(id);
            if (from.len > 0) {
                out.appendSlice(self.gpa, "origin ") catch return;
                out.appendSlice(self.gpa, from) catch return;
                out.append(self.gpa, '\n') catch return;
            }
        }
        for (self.sessions.items, 0..) |sn, si| {
            out.appendSlice(self.gpa, "session ") catch return;
            out.appendSlice(self.gpa, sn.label()) catch return;
            if (si == self.cur_sess) out.appendSlice(self.gpa, " *") catch return;
            out.append(self.gpa, '\n') catch return;
            for (sn.pins.items) |id| {
                self.savePane(&out, "pin ", id, false) catch return;
            }
            for (sn.windows.items, 0..) |w, wi| {
                self.savePane(&out, "window ", w.focused, wi == sn.cur) catch return;
                // a minted name survives the restart: it is identity,
                // and identity is what a restore is for
                if (w.named and std.mem.indexOfScalar(u8, w.label(), '\n') == null) {
                    // whose word it was rides along, so a restart does
                    // not turn a guess into a decision or the reverse.
                    // A bare `name` is what older state files wrote for
                    // both; it reads back as a guess.
                    out.appendSlice(self.gpa, switch (w.name_by) {
                        .hand => "name-hand ",
                        .model => "name-model ",
                        else => "name ",
                    }) catch return;
                    out.appendSlice(self.gpa, w.label()) catch return;
                    out.append(self.gpa, '\n') catch return;
                }
                for (self.panes.items) |p| {
                    if (p.id == w.focused or !w.layout.contains(p.id)) continue;
                    if (p.resumeLive().len == 0) continue;
                    self.savePane(&out, "pane ", p.id, false) catch return;
                }
            }
        }
        ptypkg.writeFileSmall(@ptrCast(&self.state_path), @ptrCast(&self.state_tmp), out.items);
    }

    /// One pane's line: its kind, its cwd, the star, and a `resume`
    /// line under it when it has one to keep.
    fn savePane(self: *Server, out: *std.ArrayList(u8), kind: []const u8, id: u32, star: bool) !void {
        var cwd_buf: [1024]u8 = undefined;
        var cwd: []const u8 = "";
        var back: []const u8 = "";
        if (self.pane(id)) |p| {
            if (p.fgCwd(&cwd_buf)) |c| cwd = c;
            back = p.resumeLive();
        }
        try out.appendSlice(self.gpa, kind);
        try out.appendSlice(self.gpa, cwd);
        if (star) try out.appendSlice(self.gpa, " *");
        try out.append(self.gpa, '\n');
        if (back.len > 0 and std.mem.indexOfScalar(u8, back, '\n') == null) {
            try out.appendSlice(self.gpa, "resume ");
            try out.appendSlice(self.gpa, back);
            try out.append(self.gpa, '\n');
        }
    }

    /// Rebuild sessions from the state file. False when there is
    /// nothing to restore (caller seeds the default session).
    fn restoreState(self: *Server) !bool {
        if (self.state_path[0] == 0) return false;
        var buf: [64 * 1024]u8 = undefined;
        const data = ptypkg.readFileSmall(@ptrCast(&self.state_path), &buf) orelse return false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        const head = lines.next() orelse return false;
        if (!std.mem.eql(u8, head, "v1") and !std.mem.eql(u8, head, "v2")) return false;
        var made_any = false;
        var want_sess: usize = 0;
        var sess_has_window = false;
        // the pane the next `resume` line belongs to
        var last_pane: ?*panepkg.Pane = null;
        // the window the next `name` line belongs to
        var last_window: ?*Window = null;
        const boot_by = nowMs() + 1500;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "origin ")) {
                if (last_pane) |lp| self.setOrigin(lp.id, line["origin ".len..]);
                continue;
            }
            if (std.mem.startsWith(u8, line, "name ") or std.mem.startsWith(u8, line, "name-hand ") or std.mem.startsWith(u8, line, "name-model ")) {
                const sp = std.mem.indexOfScalar(u8, line, ' ').?;
                const nm = line[sp + 1 ..];
                if (last_window) |w| {
                    if (nm.len > 0) {
                        w.setName(nm);
                        w.named = true;
                        w.name_by = if (line[4] == ' ') .program else if (line[5] == 'h') .hand else .model;
                    }
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "resume ")) {
                const cmd = line["resume ".len..];
                if (last_pane) |p| {
                    if (cmd.len > 0) {
                        p.setBoot(cmd, boot_by);
                        // it is the pane's promise again once it is typed
                        p.setResume(cmd);
                    }
                }
                continue;
            }
            last_pane = null;
            if (std.mem.startsWith(u8, line, "session ")) {
                var name = line["session ".len..];
                const starred = std.mem.endsWith(u8, name, " *");
                if (starred) name = name[0 .. name.len - 2];
                if (name.len == 0) continue;
                const sn = try self.gpa.create(Session);
                sn.* = .{};
                sn.setName(name);
                try self.sessions.append(self.gpa, sn);
                self.cur_sess = self.sessions.items.len - 1;
                if (starred) want_sess = self.cur_sess;
                sess_has_window = false;
                made_any = true;
            } else if (std.mem.startsWith(u8, line, "pin ") or std.mem.startsWith(u8, line, "gpin ")) {
                const is_global = line[0] == 'g';
                const dir = if (is_global) line["gpin ".len..] else line["pin ".len..];
                if (!is_global and self.sessions.items.len == 0) continue;
                var cwd_z: [1024]u8 = undefined;
                const cwd_arg: ?[*:0]const u8 = if (dir.len > 0 and dir.len < cwd_z.len) blk: {
                    @memcpy(cwd_z[0..dir.len], dir);
                    cwd_z[dir.len] = 0;
                    break :blk @ptrCast(&cwd_z);
                } else null;
                const p = try self.startPane(cwd_arg, null);
                last_pane = p;
                if (is_global) {
                    try self.global_pins.append(self.gpa, p.id);
                } else {
                    try self.sess().pins.append(self.gpa, p.id);
                }
            } else if (std.mem.startsWith(u8, line, "pane ") and self.sessions.items.len > 0 and self.sess().windows.items.len > 0) {
                // a sibling of the window above, beside its focused pane
                const dir = line["pane ".len..];
                var cwd_z: [1024]u8 = undefined;
                const cwd_arg: ?[*:0]const u8 = if (dir.len > 0 and dir.len < cwd_z.len) blk: {
                    @memcpy(cwd_z[0..dir.len], dir);
                    cwd_z[dir.len] = 0;
                    break :blk @ptrCast(&cwd_z);
                } else null;
                const sn = self.sess();
                const w = sn.windows.items[sn.windows.items.len - 1];
                const p = try self.startPane(cwd_arg, null);
                try w.layout.split(w.focused, p.id, true);
                last_pane = p;
            } else if (std.mem.startsWith(u8, line, "window ") and self.sessions.items.len > 0) {
                var cwd = line["window ".len..];
                const starred = std.mem.endsWith(u8, cwd, " *");
                if (starred) cwd = cwd[0 .. cwd.len - 2];
                var cwd_z: [1024]u8 = undefined;
                const cwd_arg: ?[*:0]const u8 = if (cwd.len > 0 and cwd.len < cwd_z.len) blk: {
                    @memcpy(cwd_z[0..cwd.len], cwd);
                    cwd_z[cwd.len] = 0;
                    break :blk @ptrCast(&cwd_z);
                } else null;
                const sn = self.sess();
                const w = try self.gpa.create(Window);
                w.* = .{ .layout = layoutpkg.Layout.init(self.gpa), .seen_ms = panepkg.epochMs() };
                try sn.windows.append(self.gpa, w);
                const p = try self.startPane(cwd_arg, null);
                try w.layout.seed(p.id);
                w.focused = p.id;
                last_pane = p;
                last_window = w;
                if (starred) sn.cur = sn.windows.items.len - 1;
                sess_has_window = true;
            }
        }
        // a session line with no windows would be an empty shell; give
        // it one so the invariant (every session has a window) holds
        if (made_any and !sess_has_window and self.sess().windows.items.len == 0) {
            try self.newWindow(null, null);
        }
        if (!made_any) return false;
        // drop any restored session that ended up windowless
        var si: usize = self.sessions.items.len;
        while (si > 0) {
            si -= 1;
            const sn = self.sessions.items[si];
            if (sn.windows.items.len == 0) {
                sn.windows.deinit(self.gpa);
                self.gpa.destroy(sn);
                _ = self.sessions.orderedRemove(si);
            }
        }
        if (self.sessions.items.len == 0) return false;
        self.cur_sess = @min(want_sess, self.sessions.items.len - 1);
        try self.relayout();
        return true;
    }

    /// The scope bar: the top row. It answers what scope you are in,
    /// what you can move within it, and what is exceptional here. In
    /// a space: the space's chip, a separator, the tabs, `+`, and the
    /// corner. At altitude: the system's chip, the summary, and the
    /// way back. One component draws every tab (`ui.tab`), so the
    /// index, the label and the mark share one boundary; the ladder
    /// (`ui.Fit`) decides how much of each fits.
    fn tabBar(self: *Server, buf: []u8, avail: u16) []const u8 {
        var list: std.ArrayList(u8) = .initBuffer(buf);
        const out: ui.Buf = .{ .list = &list };
        const t = &self.ui;
        const sn = self.sess();
        const now = panepkg.epochMs();
        self.tab_zones_n = 0;
        var vis: u16 = 0;
        const on: ui.Style = .{ .bg = t.chrome };
        vis += ui.ink(out, on, " ");

        const scope = chromepkg.shortSpace(sn.label());
        const sc = scope[0..@min(scope.len, 20)];

        // the corner is measured first: the bar lays out into what
        // is left of it. At home there is no corner: nothing is
        // above it. In a subview, esc is the way home; in a space,
        // prefix-o is the way out to rook.
        var corner_buf: [48]u8 = undefined;
        var pk: [8]u8 = undefined;
        const corner: []const u8 = if (self.at_root)
            (if (self.alt.view == .home) "" else "esc rook")
        else if (self.scrolling)
            (if (self.selecting) "copy · VISUAL" else "copy · hjkl v y q")
        else if (self.window().zoomed)
            "zoom"
        else
            (std.fmt.bufPrint(&corner_buf, "{s}o rook", .{prefixName(self.prefix_key, &pk)}) catch "rook");
        const corner_cols = chromepkg.cols(corner) + 1;

        if (self.at_root) {
            vis += ui.scopeChip(out, t, "rook", .global);
            vis += ui.separator(out, t, t.chrome);
            // a subview is named where the tabs would be, as the tab
            // component, selected: orbit and ledger are places within
            // the root, and home is the root itself
            vis += ui.tab(out, t, .{ .index = null, .label = self.alt.painted.word(), .selected = true }, .full);
            vis += ui.ink(out, on, "  ");
            // the context: what is selected, muted, never a count
            if (self.alt.painted == .home and self.alt.len == 0) {
                if (self.alt.home.selectedTask()) |tk| {
                    vis += ui.ink(out, .{ .fg = t.muted, .bg = t.chrome }, chromepkg.clip(tk.title, avail -| vis -| corner_cols -| 1));
                } else if (self.alt.home.selectedRow()) |r| {
                    if (r.space) |si| vis += ui.ink(out, .{ .fg = t.muted, .bg = t.chrome }, chromepkg.clip(self.alt.spaces[si].name, avail -| vis -| corner_cols -| 1));
                }
            }
        } else {
            vis += ui.scopeChip(out, t, sc, .space);
            vis += ui.separator(out, t, t.chrome);

            // the tabs, as components
            var tabs: [chromepkg.max_tab_zones]ui.Tab = undefined;
            var names: [chromepkg.max_tab_zones][48]u8 = undefined;
            const n_tabs = @min(sn.windows.items.len, tabs.len);
            for (sn.windows.items[0..n_tabs], 0..) |win, i| {
                const name = self.tabName(sn, win, &names[i]);
                // the name lives in names[i] only when it was the live
                // program; a minted name points into the window
                var mark: chromepkg.TabMark = .none;
                const marked = self.windowAgentPane(win) orelse self.pane(win.focused);
                if (marked) |p| {
                    mark = chromepkg.tabMark(.{
                        .current = i == sn.cur,
                        .agent = p.is_agent,
                        .last_output_ms = p.last_output_ms.load(.acquire),
                        .seen_ms = win.seen_ms,
                        .now = now,
                        .signal = self.windowUnread(win),
                    });
                }
                if (i == sn.cur) win.seen_ms = now;
                tabs[i] = .{
                    .index = if (i < 9) @intCast(i + 1) else null,
                    .label = name[0..@min(name.len, 24)],
                    .actor = self.windowOwner(win),
                    .mark = markOf(mark),
                    .selected = i == sn.cur,
                };
            }

            // the ladder: the first fit that fits, else collapsed with
            // an overflow tail
            const room = avail -| vis -| corner_cols;
            const plus_w: u16 = 4; // " + " and its gap
            var fit: ui.Fit = .full;
            var shown: usize = n_tabs;
            inline for (.{ ui.Fit.full, ui.Fit.no_actor, ui.Fit.short, ui.Fit.collapsed }) |f| {
                if (fit == f or !self.tabsFit(tabs[0..n_tabs], fit, room, plus_w)) fit = f;
            }
            if (!self.tabsFit(tabs[0..n_tabs], fit, room, plus_w)) {
                // collapsed and still too wide: as many as fit, the
                // selected one always among them, the rest in a tail
                var used: u16 = 8; // the tail: "  ⋯ nn "
                shown = 0;
                for (tabs[0..n_tabs]) |tb| {
                    const w = ui.tabWidth(t, tb, .collapsed) + ui.tab_gap;
                    if (used + w > room) break;
                    used += w;
                    shown += 1;
                }
                if (sn.cur >= shown) {
                    // make room for the selected tab by dropping the last
                    while (shown > 0 and used + ui.tabWidth(t, tabs[sn.cur], .collapsed) + ui.tab_gap > room) : (shown -= 1) {
                        used -= ui.tabWidth(t, tabs[shown - 1], .collapsed) + ui.tab_gap;
                    }
                }
            }

            for (tabs[0..n_tabs], 0..) |tb, i| {
                if (i >= shown and i != sn.cur) continue;
                const w = ui.tabWidth(t, tb, fit);
                if (self.tab_zones_n < self.tab_zones.len) {
                    self.tab_zones[self.tab_zones_n] = .{ .x = vis, .w = w, .target = .{ .window = i } };
                    self.tab_zones_n += 1;
                }
                vis += ui.tab(out, t, tb, fit);
                vis += ui.ink(out, on, " ");
            }
            const hidden = n_tabs - @min(shown, n_tabs) - (if (sn.cur >= shown) @as(usize, 1) else 0);
            if (hidden > 0) {
                var more_buf: [24]u8 = undefined;
                if (std.fmt.bufPrint(&more_buf, " {s} {d} ", .{ ui.glyph(t, .more), hidden })) |m| {
                    vis += ui.ink(out, .{ .fg = t.muted, .bg = t.chrome }, m);
                } else |_| {}
            } else if (vis + plus_w + corner_cols <= avail) {
                // the `+`: a tab with no index, muted, the same verb as
                // prefix-c for the hand already on the mouse
                if (self.tab_zones_n < self.tab_zones.len) {
                    self.tab_zones[self.tab_zones_n] = .{ .x = vis, .w = 3, .target = .new };
                    self.tab_zones_n += 1;
                }
                vis += ui.ink(out, .{ .fg = t.muted, .bg = t.chrome }, " + ");
            }
        }

        // the corner, right-aligned, muted
        if (vis + corner_cols + 1 <= avail) {
            var b: [64]u8 = undefined;
            out.put((ui.Style{ .bg = t.chrome }).sgr(&b));
            while (vis < avail - corner_cols) : (vis += 1) out.put(" ");
            vis += ui.ink(out, .{ .fg = t.muted, .bg = t.chrome }, corner);
        }
        ui.padTo(out, t, vis, avail);
        return list.items;
    }

    /// Do these tabs, at this fit, fit the room with the `+`?
    fn tabsFit(self: *Server, tabs: []const ui.Tab, fit: ui.Fit, room: u16, plus_w: u16) bool {
        var used: u16 = plus_w;
        for (tabs) |tb| used += ui.tabWidth(&self.ui, tb, fit) + ui.tab_gap;
        return used <= room;
    }

    // ---- tab names: minted, then frozen ----

    /// Is this the shell, at its prompt? The configured shell's own
    /// name, and the usual suspects.
    fn isShellName(self: *Server, name: []const u8) bool {
        if (std.mem.eql(u8, name, std.fs.path.basename(self.shell))) return true;
        const shells = [_][]const u8{ "sh", "bash", "zsh", "fish", "nu", "dash", "ksh", "tcsh", "login", "shell" };
        for (shells) |sh| {
            if (std.mem.eql(u8, name, sh)) return true;
        }
        return false;
    }

    /// The name a window's tab wears (resolution 6). Minted once — a
    /// name a person gave, else the first program in the window that
    /// was not the shell — and never changed by rook after that: a
    /// tab that read `nvim` reads `nvim` after nvim has quit, and
    /// `nvim · claude ◐` while an agent runs in it. Until it is
    /// minted the tab reads the live program, which is the shell at
    /// a prompt. `buf` backs that live name.
    pub fn tabName(self: *Server, sn: *Session, w: *Window, buf: []u8) []const u8 {
        if (w.named) return w.label();
        var nb: [64]u8 = undefined;
        const p = self.pane(w.focused);
        const fg: []const u8 = if (p) |pp| (pp.fgName(&nb) orelse "shell") else "shell";
        // A program names the tab once it has spoken: between fork
        // and exec the pane's foreground is the engine itself, and a
        // tab minted `engine` in that window would be wrong forever.
        const spoken = if (p) |pp| pp.last_output_ms.load(.acquire) != 0 else false;
        if (self.isShellName(fg) or !spoken or isEngineName(fg)) {
            const n = @min(fg.len, buf.len);
            @memcpy(buf[0..n], fg[0..n]);
            return buf[0..n];
        }
        self.mintName(sn, w, fg);
        return w.label();
    }

    /// Freeze `base` as the window's name, with an ordinal when a
    /// sibling in the workspace already wears it: `shell`, `shell·2`.
    fn mintName(self: *Server, sn: *Session, w: *Window, base: []const u8) void {
        var nb: [48]u8 = undefined;
        var name: []const u8 = base;
        var ord: usize = 2;
        while (self.nameTaken(sn, w, name) and ord < 100) : (ord += 1) {
            name = std.fmt.bufPrint(&nb, "{s}·{d}", .{ base, ord }) catch base;
        }
        w.setName(name);
        w.named = true;
        w.name_by = .program;
        self.state_dirty = true;
        _ = self.touch();
    }

    fn nameTaken(self: *Server, sn: *Session, w: *Window, name: []const u8) bool {
        _ = self;
        for (sn.windows.items) |other| {
            if (other == w or !other.named) continue;
            if (std.mem.eql(u8, other.label(), name)) return true;
        }
        return false;
    }

    /// Mint names for windows off the glass too, on the same 2 s
    /// cadence as the agents scan: a program that started in a
    /// background window still names its tab, once.
    fn mintNames(self: *Server) void {
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                if (w.named) continue;
                var nb: [48]u8 = undefined;
                _ = self.tabName(sn, w, &nb);
            }
        }
    }

    /// `rook rename`, `:rename`: the one act that changes a minted
    /// name. A person's word, so it is minted as given, ordinal and
    /// all if they typed one.
    fn renameWindow(self: *Server, name: []const u8) void {
        const w = self.window();
        w.setName(name);
        w.named = true;
        w.name_by = .hand;
        self.state_dirty = true;
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// `rook rename --auto`: the current tab stops being named, so
    /// rook mints from the program again on its next scan and a namer
    /// may speak. It is the only way out of a name given by hand —
    /// without it a slip of the wrist owns the tab forever.
    fn unnameWindow(self: *Server) void {
        const w = self.window();
        w.setName("");
        w.named = false;
        w.name_by = .none;
        self.state_dirty = true;
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// `rook rename --suggest <pane> <name>`: a namer's word for the
    /// window that holds `pane`. `arg` is `<pane-id> <name>`. It lands
    /// only where a person has not spoken — a name given by hand is
    /// never a namer's to change — and it is a no-op when the window
    /// already wears it, so a namer that repeats itself costs nothing.
    fn suggestName(self: *Server, arg: []const u8) void {
        const sp = std.mem.indexOfScalar(u8, arg, ' ') orelse return;
        const id = std.fmt.parseInt(u32, arg[0..sp], 10) catch return;
        const name = std.mem.trim(u8, arg[sp + 1 ..], " ");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '\n') != null) return;
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                if (!w.layout.contains(id)) continue;
                if (w.name_by == .hand) return;
                if (w.named and std.mem.eql(u8, w.label(), name)) {
                    w.name_by = .model;
                    return;
                }
                // a sibling already wearing it keeps it: two tabs
                // with one name is worse than one tab with a dull one
                var nb: [48]u8 = undefined;
                var final: []const u8 = name;
                var ord: usize = 2;
                while (self.nameTaken(sn, w, final) and ord < 100) : (ord += 1) {
                    final = std.fmt.bufPrint(&nb, "{s}·{d}", .{ name, ord }) catch name;
                }
                w.setName(final);
                w.named = true;
                w.name_by = .model;
                self.state_dirty = true;
                _ = self.touch();
                self.full = true;
                self.pending = true;
                return;
            }
        }
    }

    /// The first pane in the window running an agent, by the cached
    /// flag — the pane whose activity the tab reports.
    fn windowAgentPane(self: *Server, w: *Window) ?*panepkg.Pane {
        for (self.panes.items) |p| {
            if (p.is_agent and w.layout.contains(p.id)) return p;
        }
        return null;
    }

    /// The actor in a window: whoever claimed a pane there through
    /// `rook own`. Empty when nobody did — a tool running is not an
    /// actor, and the tab does not pretend it is.
    fn windowOwner(self: *Server, w: *Window) []const u8 {
        for (self.panes.items) |p| {
            if (p.owner_len > 0 and w.layout.contains(p.id)) return p.ownerName();
        }
        return "";
    }

    // ---- the calm bar ----

    /// The calm bar: the bottom row, on the same chrome as the scope
    /// bar. Left, who holds the focused pane's keyboard and through
    /// what; middle, the pending prefix; right, the counts — only the
    /// nonzero ones. No space name (the scope bar owns identity), no
    /// clock, and never a row that appears or disappears on its own.
    /// The calm bar, composed from the config's modules (`status_home`,
    /// `status_space`): the left ones in order, `-`, then the right
    /// ones. A warning module at zero is left out; a module with no
    /// data (usage nobody reported) is left out; the rest say their
    /// period and their unit.
    fn barRow(self: *Server, buf: []u8, cols: u16) []const u8 {
        var list: std.ArrayList(u8) = .initBuffer(buf);
        const out: ui.Buf = .{ .list = &list };
        const t = &self.ui;
        var vis: u16 = 0;
        vis += ui.ink(out, .{ .bg = t.chrome }, " ");

        var right_buf: [768]u8 = undefined;
        var right_list: std.ArrayList(u8) = .initBuffer(&right_buf);
        const right: ui.Buf = .{ .list = &right_list };
        var right_w: u16 = 0;
        var on_right = false;
        var left_n: usize = 0;
        var right_n: usize = 0;
        var it = std.mem.splitScalar(u8, if (self.at_root) self.conf.statusHome() else self.conf.statusSpace(), '\n');
        while (it.next()) |name| {
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, "-")) {
                on_right = true;
                continue;
            }
            var mod_buf: [256]u8 = undefined;
            var mod_list: std.ArrayList(u8) = .initBuffer(&mod_buf);
            const mod: ui.Buf = .{ .list = &mod_list };
            const w = self.statusModule(mod, name);
            if (w == 0) continue;
            if (on_right) {
                if (right_n > 0) right_w += ui.moduleSep(right, t);
                right.put(mod_list.items);
                right_w += w;
                right_n += 1;
            } else {
                if (left_n > 0) vis += ui.moduleSep(out, t);
                out.put(mod_list.items);
                vis += w;
                left_n += 1;
            }
        }

        // What was said to the person, with its mark, in the room the
        // modules left: the mark in its ink, the words plain. Cut to
        // fit before the right side, never pushing it off.
        if (self.notice_len > 0) {
            const mark = self.notice_mark;
            var glyph_w: u16 = 0;
            if (mark != .none) glyph_w = chromepkg.cols(ui.markGlyph(t, mark)) + 1;
            const room = cols -| (vis + right_w + 5 + glyph_w);
            if (room >= 8) {
                vis += ui.moduleSep(out, t);
                if (mark != .none) {
                    vis += ui.module(out, t, ui.markGlyph(t, mark), ui.markInk(t, mark), mark == .attention);
                    vis += ui.module(out, t, " ", t.muted, false);
                }
                const said = self.notice[0..self.notice_len];
                if (chromepkg.cols(said) <= room) {
                    vis += ui.module(out, t, said, if (mark == .attention) t.attention else t.secondary, mark == .attention);
                } else {
                    vis += ui.module(out, t, chromepkg.clip(said, room - 1), if (mark == .attention) t.attention else t.secondary, mark == .attention);
                    vis += ui.module(out, t, "…", t.muted, false);
                }
            }
        }

        // Pending-key feedback: the prefix is armed on some glass. A
        // chip, and the chords a hand may be reaching for, when they
        // fit — noticeable, never dominant.
        var armed = false;
        for (self.clients.items) |c| {
            if (c.attached and c.prefix) armed = true;
        }
        if (armed) {
            vis += ui.module(out, t, "   ", t.muted, false);
            vis += ui.chip(out, t, "prefix", t.accent);
            const hint: []const u8 = if (self.at_root)
                "  t vera · T pin · s pick · / find · : command · a in progress · ! needs you · d detach"
            else
                "  o rook · t vera · s pick · c new · v - split · z zoom · u unread · i inspect";
            if (vis + chromepkg.cols(hint) + 14 <= cols) vis += ui.module(out, t, hint, t.muted, false);
        }

        if (right_w > 0 and vis + right_w + 2 <= cols) {
            var b: [64]u8 = undefined;
            out.put((ui.Style{ .bg = t.chrome }).sgr(&b));
            while (vis < cols - right_w - 1) : (vis += 1) out.put(" ");
            out.put(right_list.items);
            vis += right_w;
        }
        ui.padTo(out, t, vis, cols);
        return list.items;
    }

    /// One module of the calm bar by name; the columns it took, 0
    /// when it has nothing to say. Every count says what it counts;
    /// spend says its period.
    fn statusModule(self: *Server, out: ui.Buf, name: []const u8) u16 {
        const t = &self.ui;
        var vis: u16 = 0;
        var ab: [8]u8 = undefined;
        const arrow = std.fmt.bufPrint(&ab, " {s} ", .{ui.glyph(t, .marker)}) catch " > ";
        if (std.mem.eql(u8, name, "view")) {
            const st = &self.alt;
            vis += ui.module(out, t, "rook", t.primary, true);
            vis += ui.moduleSep(out, t);
            const what: []const u8 = if (st.len > 0) st.mode().word() else st.painted.word();
            vis += ui.module(out, t, what, t.muted, false);
            if (st.len == 0 and st.painted == .home) {
                vis += ui.moduleSep(out, t);
                vis += ui.module(out, t, switch (st.home.focus) {
                    .nav => "navigator",
                    .insp => "inspector",
                    .vera => "vera",
                }, t.muted, false);
            }
            return vis;
        }
        if (std.mem.eql(u8, name, "input")) {
            if (self.at_root) return 0;
            if (self.popupPane()) |pp| {
                var nb: [64]u8 = undefined;
                const fg = pp.fgName(&nb) orelse "popup";
                vis += ui.module(out, t, "you", t.primary, true);
                vis += ui.module(out, t, arrow, t.muted, false);
                vis += ui.module(out, t, fg, t.secondary, false);
                return vis;
            }
            const fp = self.focusedPane() orelse return 0;
            var nb: [64]u8 = undefined;
            const fg = fp.fgName(&nb) orelse "shell";
            if (self.vera_keys) {
                vis += ui.module(out, t, "you", t.primary, true);
                vis += ui.module(out, t, arrow, t.muted, false);
                vis += ui.module(out, t, self.askName(), t.accent, false);
                return vis;
            }
            switch (fp.own) {
                .human => {
                    vis += ui.module(out, t, "you", t.primary, true);
                    vis += ui.module(out, t, arrow, t.muted, false);
                    vis += ui.module(out, t, fg, t.secondary, false);
                },
                .agent => {
                    vis += ui.module(out, t, fp.ownerName(), t.working, true);
                    vis += ui.module(out, t, arrow, t.muted, false);
                    vis += ui.module(out, t, fg, t.secondary, false);
                    vis += ui.module(out, t, " owns input", t.working, false);
                    vis += ui.moduleSep(out, t);
                    vis += ui.module(out, t, "you observe", t.muted, false);
                },
                .requested => {
                    vis += ui.module(out, t, "handoff requested", t.warning, false);
                    vis += ui.module(out, t, " — ", t.muted, false);
                    vis += ui.module(out, t, fp.ownerName(), t.working, true);
                    vis += ui.module(out, t, arrow, t.muted, false);
                    vis += ui.module(out, t, fg, t.secondary, false);
                    vis += ui.module(out, t, " finishing its step…", t.muted, false);
                },
                .yielded => {
                    vis += ui.module(out, t, fp.ownerName(), t.success, true);
                    vis += ui.module(out, t, " yielded", t.success, false);
                    vis += ui.module(out, t, " — ⏎ take", t.muted, false);
                },
                .paused => {
                    vis += ui.module(out, t, "you", t.primary, true);
                    vis += ui.module(out, t, arrow, t.muted, false);
                    vis += ui.module(out, t, fg, t.secondary, false);
                    vis += ui.moduleSep(out, t);
                    vis += ui.module(out, t, fp.ownerName(), t.muted, false);
                    vis += ui.module(out, t, " paused", t.muted, false);
                },
            }
            return vis;
        }
        if (std.mem.eql(u8, name, "agents")) {
            // active: a producer's working tasks, and agents rook sees
            // producing where nobody claims; idle: a producer's idle
            // tasks. No stale: nothing here can tell stale from slow.
            const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};
            var active: usize = self.countWorking();
            var idle: usize = 0;
            for (claims) |it| {
                switch (it.state) {
                    // a working task in a space rook does not hold: an
                    // agent rook cannot see, counted on the producer's word
                    .working => if (self.sessionNamed(it.workspace()) == null) {
                        active += 1;
                    },
                    .idle => idle += 1,
                    else => {},
                }
            }
            if (active == 0 and idle == 0) return 0;
            var b: [48]u8 = undefined;
            vis += ui.module(out, t, "agents ", t.muted, false);
            if (active > 0) {
                vis += ui.module(out, t, ui.markGlyph(t, .working), t.working, false);
                vis += ui.module(out, t, std.fmt.bufPrint(&b, " {d} active", .{active}) catch "", t.secondary, false);
            }
            if (idle > 0) {
                if (active > 0) vis += ui.module(out, t, " · ", t.muted, false);
                vis += ui.module(out, t, std.fmt.bufPrint(&b, "{d} idle", .{idle}) catch "", t.muted, false);
            }
            return vis;
        }
        if (std.mem.eql(u8, name, "attention")) {
            const n = self.countUnread() + self.countAsks() + self.countApprovals();
            if (n == 0) return 0;
            var b: [32]u8 = undefined;
            vis += ui.module(out, t, ui.markGlyph(t, .attention), t.attention, true);
            vis += ui.module(out, t, std.fmt.bufPrint(&b, " {d} need{s} you", .{ n, if (n == 1) "s" else "" }) catch "", t.attention, false);
            return vis;
        }
        if (std.mem.eql(u8, name, "blocked")) {
            const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};
            var failed: usize = 0;
            for (claims) |it| {
                if (it.state == .failed) failed += 1;
            }
            if (failed == 0) return 0;
            var b: [32]u8 = undefined;
            vis += ui.module(out, t, ui.markGlyph(t, .failed), t.err, false);
            vis += ui.module(out, t, std.fmt.bufPrint(&b, " {d} failed", .{failed}) catch "", t.err, false);
            return vis;
        }
        if (std.mem.eql(u8, name, "session")) {
            // the session is this server's life; the producer's
            // frame-level total when it gives one, else the sum of
            // what its tasks report; nothing when nobody reported
            const pnl = self.side.agents.panel orelse return 0;
            var u: chromepkg.Usage = .{};
            var any = false;
            if (pnl.session) |su| {
                u = su;
                any = true;
            } else {
                for (pnl.items) |it| {
                    if (it.usage) |iu| {
                        u.add(iu);
                        any = true;
                    }
                }
            }
            if (!any) return 0;
            var scratch: [64]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const a = fba.allocator();
            var b: [64]u8 = undefined;
            vis += ui.module(out, t, "session ", t.muted, false);
            vis += ui.module(out, t, fmtCents(a, u.cents), t.secondary, false);
            vis += ui.module(out, t, std.fmt.bufPrint(&b, " · {s} tokens", .{fmtTokens(a, u.tokens)}) catch "", t.muted, false);
            return vis;
        }
        if (std.mem.eql(u8, name, "vera")) {
            const st = &self.alt;
            const name_c = self.askName();
            // Hosting her own terminal, rook does not have an opinion
            // about what she is doing — her screen says that, in her
            // words. What rook knows is whether the program is up and
            // whether it is writing, so that is all the bar claims.
            if (self.veraChatPane()) |vp| {
                const lo = vp.last_output_ms.load(.acquire);
                const producing = lo != 0 and panepkg.epochMs() - lo < chromepkg.working_ms;
                const mark: ui.Mark = if (producing) .working else .none;
                vis += ui.module(out, t, name_c, if (producing) ui.markInk(t, mark) else t.secondary, producing);
                vis += ui.module(out, t, " ", t.muted, false);
                vis += ui.module(out, t, if (producing) "working" else "open", if (producing) ui.markInk(t, mark) else t.muted, false);
                return vis;
            }
            const status = homepkg.askStatus(st, .{ .t = t, .ask_name = name_c, .ask_on = self.ask_on });
            const word: []const u8 = switch (st.req.state) {
                .running => "thinking",
                .offline => "offline",
                .failed => "failed",
                else => if (!self.ask_on) "offline" else if (status.mark == .attention) "waiting for you" else "ready",
            };
            vis += ui.module(out, t, name_c, if (status.mark == .none) t.secondary else ui.markInk(t, status.mark), status.mark != .none);
            vis += ui.module(out, t, " ", t.muted, false);
            vis += ui.module(out, t, word, if (status.mark == .none) t.muted else ui.markInk(t, status.mark), false);
            return vis;
        }
        if (std.mem.eql(u8, name, "working")) {
            const n = self.countWorking();
            if (n == 0) return 0;
            return ui.countModule(out, t, .working, n);
        }
        if (std.mem.eql(u8, name, "unread")) {
            const n = self.countUnseen();
            if (n == 0) return 0;
            return ui.countModule(out, t, .unread, n);
        }
        if (std.mem.eql(u8, name, "pins")) {
            const n = self.global_pins.items.len;
            if (n == 0) return 0;
            var b: [16]u8 = undefined;
            return ui.module(out, t, std.fmt.bufPrint(&b, "{s}g {d}", .{ ui.glyph(t, .pin), n }) catch "?", t.muted, false);
        }
        return 0;
    }

    /// Actions the companion proposed that nobody ran: they need you.
    fn countApprovals(self: *Server) usize {
        if (self.alt.req.ref) |*r| return r.pending();
        return 0;
    }

    fn countUnseen(self: *Server) usize {
        var n: usize = 0;
        for (self.sessions.items, 0..) |sn, si| {
            for (sn.windows.items, 0..) |w, wi| {
                if (si == self.cur_sess and wi == sn.cur) continue;
                const p = self.pane(w.focused) orelse continue;
                const last = p.last_output_ms.load(.acquire);
                if (last != 0 and last > w.seen_ms + chromepkg.prompt_grace_ms and !self.windowUnread(w)) n += 1;
            }
        }
        return n;
    }

    /// Agent panes that produced output in the last `working_ms`,
    /// anywhere — the ◐ count.
    fn countWorking(self: *Server) usize {
        const now = panepkg.epochMs();
        var n: usize = 0;
        for (self.panes.items) |p| {
            if (!p.is_agent or self.ownPane(p.id)) continue;
            const last = p.last_output_ms.load(.acquire);
            if (last != 0 and now - last < chromepkg.working_ms) n += 1;
        }
        return n;
    }

    /// Panes on the unread channel, anywhere — the ● count.
    fn countUnread(self: *Server) usize {
        var n: usize = 0;
        for (self.panes.items) |p| {
            if (p.unread_ms != 0 and !self.ownPane(p.id)) n += 1;
        }
        return n;
    }

    // ---- ownership: the gate and the inspector ----

    /// `rook own`: [id u32][op u8][actor…]. 'c' claims the pane for
    /// the actor (it owns input), 'p' attaches the actor paused, 'r'
    /// releases — into handoff-pending when the person had asked,
    /// else straight back to the person — 'h' requests a handoff and
    /// 't' takes the keyboard now. The last two are the gate's own
    /// moves, on the wire so a script can drive the same protocol.
    fn ownCmd(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 5) return;
        const id = std.mem.readInt(u32, payload[0..4], .little);
        const op = payload[4];
        const actor = payload[5..];
        const p = self.pane(id) orelse {
            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such pane");
            return;
        };
        switch (op) {
            'c' => p.setOwner(actor, .agent),
            'p' => p.setOwner(actor, .paused),
            'r' => self.releasePane(p),
            'h' => if (p.own == .agent) {
                p.own = .requested;
            },
            't' => self.takePane(p),
            else => {
                self.sendTo(c, @intFromEnum(proto.s2c.exit), "unknown own op");
                return;
            },
        }
        if (!p.keysGated()) self.gate = false;
        _ = self.touch();
        self.ack(c);
        self.full = true;
        self.pending = true;
    }

    fn releasePane(self: *Server, p: *panepkg.Pane) void {
        _ = self;
        if (p.own == .requested) {
            p.own = .yielded;
        } else {
            p.takeOwnership();
        }
    }

    fn takePane(self: *Server, p: *panepkg.Pane) void {
        p.takeOwnership();
        self.gate = false;
        self.gate_pass = false;
    }

    /// The gate's keys: ⏎ request a handoff (or take, once the actor
    /// has yielded), T take now, s send the next keystrokes to the
    /// actor as a message, Esc leave it alone. Anything else is not
    /// a move and does nothing — typed keys are never reinterpreted.
    fn gateKey(self: *Server, key: u8) void {
        const p = self.focusedPane() orelse {
            self.gate = false;
            return;
        };
        switch (key) {
            '\r', '\n' => switch (p.own) {
                .agent => {
                    p.own = .requested;
                    _ = self.touch();
                },
                .yielded => {
                    self.takePane(p);
                    _ = self.touch();
                },
                else => {},
            },
            'T', 't' => {
                self.takePane(p);
                _ = self.touch();
            },
            's', 'S' => {
                self.gate = false;
                self.gate_pass = true;
            },
            0x1b, 'q' => self.gate = false,
            else => {},
        }
        self.full = true;
        self.pending = true;
    }

    /// The gate, one row above the calm bar, over the pane: an
    /// elevated strip with the attention mark, the actor as a chip,
    /// and the three legal moves in muted ink.
    fn gateRow(self: *Server) void {
        const p = self.focusedPane() orelse return;
        const g = self.geometry();
        const t = &self.ui;
        const y = self.bodyRows() -| 1;
        const f = &self.over;
        var b: [64]u8 = undefined;
        f.cup(0, y);
        f.put((ui.Style{ .bg = t.raised }).sgr(&b));
        var i: u16 = 0;
        while (i < g.cols) : (i += 1) f.put(" ");
        f.cup(1, y);
        f.put((ui.Style{ .fg = t.attention, .bg = t.raised, .bold = true }).sgr(&b));
        f.put(ui.markGlyph(t, .attention));
        f.put(" ");
        f.put((ui.Style{ .fg = t.working, .bg = t.raised, .bold = true }).sgr(&b));
        f.put(p.ownerName());
        f.put((ui.Style{ .fg = t.primary, .bg = t.raised }).sgr(&b));
        switch (p.own) {
            .yielded => f.put(" yielded"),
            .requested => f.put(" owns input — handoff requested, finishing its step…"),
            else => f.put(" owns input"),
        }
        f.put((ui.Style{ .fg = t.muted, .bg = t.raised }).sgr(&b));
        switch (p.own) {
            .yielded => f.put("   ⏎ take · esc leave it"),
            .requested => f.put("   T take now · s send as message · esc"),
            else => f.put("   ⏎ request handoff · T take now · s send as message · esc"),
        }
        f.put("\x1b[0m");
    }

    /// prefix-i: what rook knows about the focused pane, in a box on
    /// elevated chrome — the actor and its authority over input, the
    /// program, since when, where, and how it comes back. Provider
    /// detail would live here too, if rook knew any; it does not, and
    /// says so.
    fn inspectorSheet(self: *Server) void {
        const p = self.focusedPane() orelse return;
        const g = self.geometry();
        const t = &self.ui;
        const body = self.bodyRows();
        const w: u16 = @min(g.cols -| 4, 72);
        const h: u16 = 10;
        if (g.cols < 30 or body < h + 2) return;
        const r: layoutpkg.Rect = .{ .x = (g.cols -| w) / 2, .y = 1 + (body -| 1 -| h) / 2, .w = w, .h = h };
        const f = &self.over;
        var b: [64]u8 = undefined;
        altpkg.fillRect(f, r, t.raised);
        altpkg.box(f, r, t.border, t.raised);
        f.cup(r.x + 1, r.y);
        f.put((ui.Style{ .fg = t.border, .bg = t.raised }).sgr(&b));
        f.put("┤ ");
        f.put((ui.Style{ .fg = t.accent, .bg = t.raised, .bold = true }).sgr(&b));
        f.put("inspector");
        f.put((ui.Style{ .fg = t.muted, .bg = t.raised }).sgr(&b));
        f.put(" · ");
        f.put((ui.Style{ .fg = t.primary, .bg = t.raised }).sgr(&b));
        f.put(if (p.owner_len > 0) p.ownerName() else "you");
        f.put((ui.Style{ .fg = t.border, .bg = t.raised }).sgr(&b));
        f.put(" ├");

        var nb: [64]u8 = undefined;
        var cb: [1024]u8 = undefined;
        var tb: [256]u8 = undefined;
        var ab: [16]u8 = undefined;
        var line: [256]u8 = undefined;
        const fg = p.fgName(&nb) orelse "shell";
        const rows = [_]struct { k: []const u8, v: []const u8 }{
            .{ .k = "actor", .v = if (p.owner_len > 0) p.ownerName() else "you — nobody claims this pane" },
            .{ .k = "program", .v = std.fmt.bufPrint(&line, "{s} · pane {d}", .{ fg, p.id }) catch fg },
            .{ .k = "input", .v = switch (p.own) {
                .human => "you ▸ your keys flow to the pane",
                .agent => "agent owns — typing opens the gate",
                .requested => "agent owns — handoff requested…",
                .yielded => "agent yielded — ⏎ takes",
                .paused => "you ▸ agent attached, paused",
            } },
            .{ .k = "since", .v = if (p.own_since_ms != 0) altpkg.age(&ab, panepkg.epochMs() - p.own_since_ms) else "—" },
            .{ .k = "cwd", .v = p.fgCwd(&cb) orelse "" },
            .{ .k = "title", .v = p.title(&tb) },
            .{ .k = "resume", .v = if (p.resumeLive().len > 0) p.resumeLive() else "— (rook resume . <cmd>)" },
            .{ .k = "provider", .v = "not rook's to know — a producer's word, on the rail" },
        };
        for (rows, 0..) |row, i| {
            const ry = r.y + 1 + @as(u16, @intCast(i));
            if (ry >= r.y + r.h - 1) break;
            f.cup(r.x + 2, ry);
            f.put((ui.Style{ .fg = t.muted, .bg = t.raised }).sgr(&b));
            f.put(row.k);
            f.cup(r.x + 12, ry);
            f.put((ui.Style{ .fg = t.primary, .bg = t.raised }).sgr(&b));
            _ = altpkg.putW(f, row.v, r.w -| 14);
        }
        f.put("\x1b[0m");
    }

    // ---- the root ----

    /// Out, to rook: home. Moving nothing — the panes keep their
    /// geometry and keep running — so entering a space again is the
    /// exact frame you left. From the root it lands on home whatever
    /// subview was up; the draft, the cursor and the receipt stay.
    fn goHome(self: *Server) void {
        if (self.popup != null) return;
        self.at_root = true;
        self.vera_keys = false;
        self.alt.view = .home;
        self.scrolling = false;
        self.selecting = false;
        self.gate = false;
        self.inspect = false;
        self.ask_on = askpkg.available(self.conf.askSlice());
        self.chat_on = askpkg.available(self.conf.chatSlice());
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// Home, with the cursor on a section.
    fn goHomeAt(self: *Server, land: altpkg.Land) void {
        self.goHome();
        self.alt.clear();
        self.alt.land = land;
        self.alt.home.focus = .nav;
        self.alt.home.detail = false;
    }

    /// Home, in a mode: the field holds the mode's leading character
    /// (or nothing, for intent), the cursor in it.
    fn goHomeTyping(self: *Server, lead: []const u8) void {
        self.goHome();
        self.alt.clear();
        if (lead.len == 0) {
            self.showVera();
            _ = self.tendVera();
        }
        for (lead) |ch| self.alt.push(ch);
    }

    /// A subview of the root: orbit, or ledger.
    fn openView(self: *Server, v: altpkg.View) void {
        if (self.popup != null) return;
        const was = self.at_root;
        self.goHome();
        self.alt.view = v;
        if (!was) self.alt.cur = 0;
    }

    /// Into the space the server is showing. The root's state stays
    /// as it was, for the next visit.
    fn enterSpace(self: *Server) void {
        if (!self.at_root) return;
        self.at_root = false;
        self.alt.land = .none;
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// The region the view paints: everything right of the global
    /// pin dock (which does not move), under the tab bar, above the
    /// calm bar. Workspace-local pins are inside it — they belong to
    /// the space and contract with it.
    fn altRegion(self: *Server) layoutpkg.Rect {
        const g = self.geometry();
        const body = self.bodyRows();
        const base_x: u16 = if (self.side_w) |sw| sw + 1 else 0;
        const x0: u16 = if (self.global_pins.items.len > 0 and self.dock_x != null) self.dock_x.? + 1 else base_x;
        return .{ .x = x0, .y = 1, .w = g.cols -| x0, .h = body -| 1 };
    }

    /// The companion's name, for the field and the bar.
    fn askName(self: *Server) []const u8 {
        const c = self.conf.companionSlice();
        return if (c.len > 0) c else "vera";
    }

    /// Keys at the root. The navigator and the inspector take j/k
    /// and h/l as motion; every other printable letter is for vera
    /// and summons her with the letter in the composer; the arrows,
    /// ⇥ and C-n C-p walk whatever has focus. Returns the bytes
    /// spent, so a run of keystrokes is walked one key at a time and
    /// an escape sequence is taken whole.
    fn altKey(self: *Server, c: *Client, bytes: []const u8) usize {
        const st = &self.alt;
        const h = &st.home;
        defer {
            self.full = true;
            self.pending = true;
        }
        const home = st.mode() == .intent and st.view == .home;
        const b = bytes[0];
        // Ctrl-h/l walk the regions the way they walk panes; at an
        // edge the byte is the view's again (Ctrl-H in vera's
        // composer is still a backspace).
        if (home and (b == 0x08 or b == 0x0c)) {
            if (h.navFocus(if (b == 0x08) 'h' else 'l')) return 1;
        }
        // The companion's own terminal has the keyboard while it has
        // the focus, and everything rook did not spend above is the
        // program's: Esc and the arrows it opens, Ctrl-j for a
        // newline, its own history, its own paste. Rook keeps only
        // the prefix (armed above) and the four motions — and of
        // those, only the ones with somewhere to go, which is the
        // same bargain every pane in a space makes.
        if (home and h.focus == .vera) {
            if (self.veraChatPane()) |vp| return self.toVera(c, vp, bytes);
        }
        if (b == 0x1b) {
            if (bytes.len >= 3 and (bytes[1] == '[' or bytes[1] == 'O')) {
                var i: usize = 2;
                while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
                const fin: u8 = if (i < bytes.len) bytes[i] else 0;
                switch (fin) {
                    'A' => self.rootMove(-1),
                    'B' => self.rootMove(1),
                    'C' => if (home) {
                        _ = h.navFocus('l');
                    },
                    'D' => if (home) {
                        _ = h.navFocus('h');
                    },
                    'Z' => if (home) self.cycleFocus(-1) else st.move(-1),
                    '5' => if (home and h.focus == .vera) {
                        h.thread_scroll += 4;
                    } else if (home and h.focus == .insp) {
                        h.insp.scroll -|= 8;
                    },
                    '6' => if (home and h.focus == .vera) {
                        h.thread_scroll -|= 4;
                    } else if (home and h.focus == .insp) {
                        h.insp.scroll += 8;
                    },
                    else => {},
                }
                return @min(i + 1, bytes.len);
            }
            _ = st.escape();
            return 1;
        }
        switch (b) {
            '\r', '\n' => self.altAct(),
            0x7f, 0x08 => if (h.focus == .vera or !home) st.pop(),
            '\t' => if (home) self.cycleFocus(1) else st.move(1),
            0x0e => self.rootMove(1), // C-n
            0x10 => self.rootMove(-1), // C-p
            0x15 => st.clear(), // C-u
            0x03 => _ = st.escape(), // C-c
            else => {
                if (b < 0x20) return 1;
                const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                const end = @min(len, bytes.len);
                // motion in the navigator and the inspector: j k h l,
                // o to open the workspace, g G to the ends; anything
                // else is for vera
                if (home and h.focus != .vera and st.len == 0 and len == 1) {
                    switch (b) {
                        'j' => {
                            self.rootMove(1);
                            return 1;
                        },
                        'k' => {
                            self.rootMove(-1);
                            return 1;
                        },
                        'h' => {
                            _ = h.navFocus('h');
                            return 1;
                        },
                        'l' => {
                            _ = h.navFocus('l');
                            return 1;
                        },
                        'o' => {
                            self.openSelected();
                            return 1;
                        },
                        'g' => {
                            if (h.focus == .nav) {
                                h.nav_cur = 0;
                                h.clampNav();
                                h.nav_touched = true;
                                h.noteSelection();
                            } else h.insp.scroll = 0;
                            return 1;
                        },
                        'G' => {
                            if (h.focus == .nav) {
                                h.nav_cur = h.rows_n -| 1;
                                h.clampNav();
                                h.nav_touched = true;
                                h.noteSelection();
                            }
                            return 1;
                        },
                        else => {},
                    }
                }
                // typing is for vera: summoned, with the letter
                if (home and h.focus != .vera and (st.len > 0 or (b != '/' and b != ':'))) {
                    self.showVera();
                    // her own terminal owns its box: the letter is
                    // typed into it, not into a draft rook keeps.
                    _ = self.tendVera();
                    if (self.veraChatPane()) |vp| return self.toVera(c, vp, bytes);
                }
                for (bytes[0..end]) |ch| st.push(ch);
                if (st.mode() != .intent) st.cur = 0;
                return end;
            },
        }
        return 1;
    }

    /// ↑ ↓ (j k, C-p C-n): the rows while finding or commanding; at
    /// home, whatever has focus — the navigator's rows, the
    /// inspector's controls (or its scroll, when it has none), vera's
    /// thread.
    fn rootMove(self: *Server, d: i32) void {
        const st = &self.alt;
        const h = &st.home;
        if (st.mode() != .intent or st.view != .home) {
            st.move(d);
            return;
        }
        switch (h.focus) {
            .nav => h.moveNav(d),
            .insp => if (h.insp.acts_n > 0) h.insp.moveAct(d) else {
                if (d > 0) h.insp.scroll += 1 else h.insp.scroll -|= 1;
            },
            .vera => if (d < 0) {
                h.thread_scroll += 1;
            } else {
                h.thread_scroll -|= 1;
            },
        }
    }

    /// ⇥: navigator, inspector, vera (when she is up), and around.
    fn cycleFocus(self: *Server, d: i32) void {
        const h = &self.alt.home;
        const order = [_]homepkg.Region{ .nav, .insp, .vera };
        var i: usize = 0;
        for (order, 0..) |r, k| {
            if (r == h.focus) i = k;
        }
        const n: i32 = if (h.veraShown()) 3 else 2;
        i = @intCast(@mod(@as(i32, @intCast(i)) + d, n));
        h.focus = order[i];
        h.detail = h.focus != .nav;
    }

    /// ↵ at the root: whatever has focus acts — the navigator opens
    /// the inspector, the inspector runs its selected control, vera
    /// sends the draft.
    fn altAct(self: *Server) void {
        const st = &self.alt;
        const h = &st.home;
        if (st.mode() == .intent and st.view == .home) {
            switch (h.focus) {
                .nav => _ = h.navFocus('l'),
                .insp => self.inspAct(),
                .vera => if (st.len > 0) self.sendAsk(),
            }
            self.full = true;
            self.pending = true;
            return;
        }
        self.altBuild();
        const row = st.selected() orelse return;
        switch (row.kind) {
            .attention, .pane => {
                self.enterSpace();
                self.focusPane(row.pane);
            },
            .ask => {
                self.enterSpace();
                self.jumpToAgent(row.arg);
            },
            .work => {
                self.enterSpace();
                if (row.pane != 0 and self.pane(row.pane) != null) {
                    self.focusPane(row.pane);
                } else if (row.arg.len > 0) {
                    self.jumpToAgent(row.arg);
                } else if (row.ws < self.sessions.items.len) {
                    self.switchSession(row.ws);
                }
            },
            .space => {
                self.enterSpace();
                self.switchSession(row.ws);
            },
            .tab => {
                self.enterSpace();
                self.switchSession(row.ws);
                if (row.win < self.sess().windows.items.len) self.selectWindow(row.win);
            },
            .pin => {
                self.enterSpace();
                if (self.pane(row.pane) != null) self.setFocus(row.pane);
            },
            .action => st.req.confirm(row.action),
            .command => self.altCommand(row.cmd, row.arg),
            .header, .note => {},
        }
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// The draft goes to the companion, as typed, about whatever is
    /// attached. The one door to interpretation: nothing else changes
    /// until she answers, and what she proposes is shown before it
    /// runs.
    fn sendAsk(self: *Server) void {
        const st = &self.alt;
        const h = &st.home;
        var text_buf: [askpkg.max_text]u8 = undefined;
        const n = @min(st.len, text_buf.len);
        @memcpy(text_buf[0..n], st.text[0..n]);
        _ = h.thread.push(.you, text_buf[0..n], h.aboutTask(), h.aboutSpace(), panepkg.epochMs());
        h.thread_scroll = 0;
        st.req.send(self.conf.askSlice(), text_buf[0..n], h.aboutTask(), h.aboutSpace());
        self.ask_on = st.req.state != .offline;
        if (st.req.state == .offline) {
            var b: [160]u8 = undefined;
            _ = h.thread.push(.err, std.fmt.bufPrint(&b, "{s} is not on PATH — nothing was sent · the navigator, / and : still work", .{self.askName()}) catch "not on PATH", "", "", panepkg.epochMs());
        } else if (st.req.state == .failed) {
            _ = h.thread.push(.err, "could not start the command", "", "", panepkg.epochMs());
        }
        st.clear();
        _ = self.touch();
    }

    /// ↵ in the inspector: the selected control.
    fn inspAct(self: *Server) void {
        const st = &self.alt;
        const h = &st.home;
        const a = h.insp.selected() orelse return;
        const tk = h.selectedTask();
        switch (a.kind) {
            .approval => st.req.confirm(a.action),
            .answer, .control => {
                const task: []const u8 = if (tk) |k| k.id else "";
                if (!h.runner.start(a.label, a.run, task)) {
                    _ = h.thread.push(.err, "one thing at a time: something is still running", task, "", panepkg.epochMs());
                }
            },
            .open, .enter, .go_see => self.openSelected(),
            .ask => self.askAbout(),
        }
        _ = self.touch();
    }

    /// `o`: the exact destination of what is selected — the pane
    /// that signalled, the agent's pane, the space.
    fn openSelected(self: *Server) void {
        const st = &self.alt;
        const h = &st.home;
        const r = h.selectedRow() orelse return;
        if (r.task) |ti| {
            const tk = h.tasks[ti];
            switch (tk.kind) {
                .approval => return,
                .signal, .found => {
                    self.enterSpace();
                    self.focusPane(tk.pane);
                },
                .producer => {
                    if (tk.ws == null) return;
                    self.enterSpace();
                    if (tk.pane != 0 and self.pane(tk.pane) != null) {
                        self.focusPane(tk.pane);
                    } else {
                        self.switchSession(tk.ws.?);
                    }
                },
            }
            _ = self.touch();
            return;
        }
        if (r.space) |si| {
            self.enterSpace();
            self.switchSession(st.spaces[si].ws);
            _ = self.touch();
        }
    }

    /// "Ask vera about this": her pane, with the selected thing
    /// attached as a reference the request carries.
    fn askAbout(self: *Server) void {
        const h = &self.alt.home;
        const r = h.selectedRow() orelse return;
        if (r.task) |ti| {
            const tk = h.tasks[ti];
            h.setAbout(tk.id, tk.full, tk.title);
        } else if (r.space) |si| {
            const sp = self.alt.spaces[si];
            h.setAbout("", sp.full, sp.name);
        }
        self.showVera();
        // Rook's own surface carries the reference in the request's
        // environment (ROOK_ABOUT_TASK). A hosted chat is a program
        // already running, with no such door: what rook can give it
        // is the id, typed into its box as text the person edits or
        // deletes. The chip above says what the id names, and a
        // structured attachment waits on a seam mote does not have.
        _ = self.tendVera();
        if (self.veraChatPane()) |vp| {
            if (r.task) |ti| {
                const id = h.tasks[ti].id;
                if (id.len > 0) {
                    vp.write(id);
                    vp.write(" ");
                }
            }
        }
    }

    /// prefix-t: vera, or not. From a space the pane opens over the
    /// panes and takes the keys; the panes keep their geometry.
    fn toggleVera(self: *Server) void {
        const h = &self.alt.home;
        h.toggleVera();
        if (h.focus == .vera) self.vera_dead = false;
        if (!self.at_root) self.vera_keys = h.veraShown() and h.focus == .vera;
        // Summoned for the first time, she is started here rather
        // than a frame later: the keystroke after prefix-t is meant
        // for her box.
        _ = self.tendVera();
        self.ask_on = askpkg.available(self.conf.askSlice());
        self.chat_on = askpkg.available(self.conf.chatSlice());
        _ = self.touch();
        self.full = true;
        self.pending = true;
    }

    /// Keys into vera's pane inside a space: the hosted chat's own,
    /// or — when rook is drawing the surface itself — the composer's
    /// and Esc.
    fn veraKey(self: *Server, c: *Client, bytes: []const u8) usize {
        const st = &self.alt;
        const h = &st.home;
        defer {
            self.full = true;
            self.pending = true;
        }
        const b = bytes[0];
        if (self.veraChatPane()) |vp| {
            // Ctrl-h is the way back to the panes, the same motion
            // that walks out of any pane on the right edge of a
            // space. The other three have nowhere to go from here
            // and are the program's — Ctrl-j is its newline.
            if (b == 0x08) {
                self.vera_keys = false;
                h.focus = .nav;
                return 1;
            }
            return self.toVera(c, vp, bytes);
        }
        if (b == 0x1b) {
            if (bytes.len >= 3 and (bytes[1] == '[' or bytes[1] == 'O')) {
                var i: usize = 2;
                while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
                const fin: u8 = if (i < bytes.len) bytes[i] else 0;
                switch (fin) {
                    'A' => h.thread_scroll += 1,
                    'B' => h.thread_scroll -|= 1,
                    else => {},
                }
                return @min(i + 1, bytes.len);
            }
            // Esc: a running request, the draft, the attachment, then
            // the pane (pinned: only the keys)
            if (st.req.busy()) {
                st.req.cancel();
            } else if (st.len > 0) {
                st.clear();
            } else if (h.about_title_len > 0) {
                h.clearAbout();
            } else if (h.vera_pinned) {
                self.vera_keys = false;
                h.focus = .nav;
            } else {
                h.vera_open = false;
                h.focus = .nav;
                self.vera_keys = false;
            }
            return 1;
        }
        switch (b) {
            '\r', '\n' => if (st.len > 0) self.sendAsk(),
            0x7f, 0x08 => st.pop(),
            0x15 => st.clear(),
            0x03 => _ = st.escape(),
            else => {
                if (b < 0x20) return 1;
                const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                const end = @min(len, bytes.len);
                for (bytes[0..end]) |ch| st.push(ch);
                return end;
            },
        }
        return 1;
    }

    fn altCommand(self: *Server, cmd: altpkg.Command, arg: []const u8) void {
        switch (cmd) {
            .go => if (self.sessionNamed(arg)) |i| {
                self.alt.clear();
                self.enterSpace();
                self.switchSession(i);
            },
            .new => if (arg.len > 0) {
                self.alt.clear();
                self.enterSpace();
                _ = self.newSession(arg, null, null, true) catch {};
            },
            .rename => if (arg.len > 0) {
                self.renameWindow(arg);
                self.alt.clear();
            },
            .close => if (arg.len > 0) {
                self.closeSession(arg);
                self.alt.clear();
            },
            .ledger => {
                self.alt.view = .ledger;
                self.conf.zoom_ledger = true;
                self.alt.clear();
            },
            .orbit => {
                self.alt.view = .orbit;
                self.conf.zoom_ledger = false;
                self.alt.clear();
            },
            .home => {
                self.alt.view = .home;
                self.alt.clear();
            },
            .now => {
                self.alt.view = .home;
                self.alt.clear();
                self.alt.home.focus = .nav;
                self.alt.home.detail = false;
            },
            .vera => {
                self.alt.view = .home;
                self.alt.clear();
                self.showVera();
                _ = self.tendVera();
            },
            .none => {},
        }
    }

    /// Fill the model from rook's own tables — nothing here is
    /// inferred and nothing is summarised: a space's name, the tabs
    /// in it and who claimed them, who is unread, what a program said
    /// in its notification, how long since anything was written, the
    /// words a producer already spent on the space and on its work,
    /// and for the space you left, the last lines of the pane you
    /// were in. Home lays it out as sections: what the companion
    /// proposed, what needs you, what is running, what finished,
    /// then the spaces. Orbit and ledger lay the same facts out
    /// spatially. Finding ranks everything as one list.
    fn altBuild(self: *Server) void {
        const st = &self.alt;
        st.reset();
        var fba = std.heap.FixedBufferAllocator.init(&st.buf);
        const a = fba.allocator();
        const now = panepkg.epochMs();

        if (st.isCommand()) {
            self.altCommandRows(a);
            st.clampCursor();
            return;
        }
        const text = st.query();
        const finding = st.finding();
        const home = st.view == .home and !finding;
        if (home and st.mode() == .intent) {
            self.homeBuild(a, now);
            return;
        }
        var land_needs: ?usize = null;
        var land_running: ?usize = null;

        // What the companion proposed: actions are rows, first, so
        // ↵ reaches them; each with the command it would run.
        if (home and st.mode() == .intent) {
            if (st.req.ref) |*r| {
                if (r.actions_n > 0) {
                    st.rows.append(self.gpa, .{ .kind = .header, .name = "proposed", .line = "↵ runs one, by hand · esc dismisses" }) catch {};
                }
                for (r.actions[0..r.actions_n], 0..) |*act, i| {
                    const mark: ui.Mark = if (act.running) .working else if (!act.ran) .waiting else if (act.code == 0) .success else .failed;
                    const line = if (act.ran)
                        (std.fmt.allocPrint(a, "ran ({d}) · {s}", .{ act.code, askpkg.firstLine(act.receiptSlice()) }) catch "")
                    else
                        (std.fmt.allocPrint(a, "$ {s}", .{act.runSlice()}) catch "");
                    st.rows.append(self.gpa, .{ .kind = .action, .glyph = ui.markGlyph(&self.ui, mark), .ink = ui.markInk(&self.ui, mark), .name = act.labelSlice(), .line = line, .line_ink = if (act.ran) self.ui.secondary else self.ui.muted, .hint = if (act.ran) "" else "↵ run", .action = i }) catch {};
                }
            }
        }

        // Attention first: the unread channel, oldest first — panes a
        // program signalled while nobody looked.
        var attn: [64]*panepkg.Pane = undefined;
        var an: usize = 0;
        for (self.panes.items) |p| {
            if (p.unread_ms == 0 or self.ownPane(p.id)) continue;
            if (an == attn.len) break;
            var i = an;
            while (i > 0 and attn[i - 1].unread_ms > p.unread_ms) : (i -= 1) attn[i] = attn[i - 1];
            attn[i] = p;
            an += 1;
        }
        const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};
        var asks: usize = 0;
        for (claims) |it| {
            if ((it.state == .blocked or it.state == .failed) and self.sessionNamed(it.workspace()) != null) asks += 1;
        }
        if (home) {
            var hb: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&hb, "{d}", .{an + asks}) catch "";
            st.rows.append(self.gpa, .{ .kind = .header, .name = "needs you", .line = if (an + asks > 0) (a.dupe(u8, count) catch "") else "nothing — no pane asked, no task is waiting" }) catch {};
            land_needs = st.rows.items.len;
        }
        for (attn[0..an]) |p| {
            const at = self.placeOf(p.id) orelse continue;
            var tab: []const u8 = "";
            if (at.window) |wi| {
                if (self.sessionNamed(at.workspace)) |si| {
                    const sn = self.sessions.items[si];
                    if (wi - 1 < sn.windows.items.len) {
                        var nb: [48]u8 = undefined;
                        tab = a.dupe(u8, self.tabName(sn, sn.windows.items[wi - 1], &nb)) catch "";
                    }
                }
            } else if (std.mem.eql(u8, at.place, "pin")) {
                tab = "pin";
            }
            var nb: [64]u8 = undefined;
            const prog = p.fgName(&nb) orelse "shell";
            // the row is the place; the actor rides after it when one
            // claimed the pane, and the tool speaks in the line
            const name = if (p.owner_len > 0 and !std.mem.eql(u8, p.ownerName(), tab))
                std.fmt.allocPrint(a, "{s} › {s} · {s}", .{ chromepkg.shortSpace(at.workspace), tab, p.ownerName() }) catch continue
            else
                std.fmt.allocPrint(a, "{s} › {s}", .{ chromepkg.shortSpace(at.workspace), tab }) catch continue;
            const said: []const u8 = if (p.notif_ms != 0 and p.notif_ms >= p.unread_ms and p.notif_title_len > 0)
                a.dupe(u8, p.notif_title[0..p.notif_title_len]) catch ""
            else if (p.bell_ms != 0 and p.bell_ms >= p.unread_ms)
                "rang the bell"
            else if (p.progress_done_ms != 0 and p.progress_done_ms >= p.unread_ms)
                "finished its progress bar"
            else
                "signalled";
            var ab: [16]u8 = undefined;
            const line = std.fmt.allocPrint(a, "{s} {s} · {s} ago", .{ prog, said, altpkg.age(&ab, now - p.unread_ms) }) catch said;
            var row: altpkg.Row = .{ .kind = .attention, .glyph = ui.markGlyph(&self.ui, .attention), .ink = self.ui.attention, .name = name, .line = line, .line_ink = self.ui.secondary, .hint = "↵ go", .pane = p.id };
            if (finding) row.score = altpkg.fuzzy(name, text) orelse (altpkg.fuzzy(line, text) orelse continue) + 20;
            st.rows.append(self.gpa, row) catch {};
        }
        // …and what a producer said needs you: an agents row pushed
        // with `waiting` (or `failed`) for a space rook holds.
        for (claims) |it| {
            if (it.state != .blocked and it.state != .failed) continue;
            const ws = it.workspace();
            if (self.sessionNamed(ws) == null) continue;
            const name = std.fmt.allocPrint(a, "{s} — {s}", .{ chromepkg.shortSpace(ws), it.name }) catch continue;
            const detail = if (it.event.len > 0) it.event else it.sub;
            const line = std.fmt.allocPrint(a, "{s}{s}{s}", .{ it.state.word(), if (detail.len > 0) " · " else "", detail }) catch it.state.word();
            const argd = a.dupe(u8, ws) catch continue;
            var row: altpkg.Row = .{ .kind = .ask, .glyph = ui.markGlyph(&self.ui, if (it.state == .failed) .failed else .waiting), .ink = if (it.state == .failed) self.ui.err else self.ui.waiting, .name = name, .line = line, .line_ink = self.ui.secondary, .hint = "↵ go", .arg = argd };
            if (finding) row.score = altpkg.fuzzy(name, text) orelse (altpkg.fuzzy(line, text) orelse continue) + 20;
            st.rows.append(self.gpa, row) catch {};
        }

        // Work: a producer's open tasks (its words: the goal, the
        // state, the space, and whatever else it said), then the
        // agents rook can see running that no producer claimed.
        // Home lists them; orbit reads them off the figures instead.
        if (home or finding) {
            var running: usize = 0;
            var recent: usize = 0;
            for (claims) |it| {
                switch (it.state) {
                    .working, .idle, .none => running += 1,
                    .done => recent += 1,
                    else => {},
                }
            }
            var found_n: usize = 0;
            for (self.sessions.items) |sn| {
                if (chromepkg.claimedIn(claims, sn.label())) continue;
                for (self.panes.items) |p| {
                    if (p.is_agent and self.paneIn(sn, p.id)) found_n += 1;
                }
            }
            if (home) {
                var hb: [32]u8 = undefined;
                const count = std.fmt.bufPrint(&hb, "{d}", .{running + found_n}) catch "";
                st.rows.append(self.gpa, .{ .kind = .header, .name = "running", .line = if (running + found_n > 0) (a.dupe(u8, count) catch "") else "nothing — no task is open, no agent is running" }) catch {};
                land_running = st.rows.items.len;
            }
            for (claims) |it| {
                if (it.state == .blocked or it.state == .failed or it.state == .done) continue;
                self.workRow(a, it, text, finding);
            }
            for (self.sessions.items, 0..) |sn, si| {
                if (chromepkg.claimedIn(claims, sn.label())) continue;
                for (self.panes.items) |p| {
                    if (!p.is_agent or !self.paneIn(sn, p.id)) continue;
                    var nb: [64]u8 = undefined;
                    const prog = p.fgName(&nb) orelse "agent";
                    const at = self.placeOf(p.id) orelse continue;
                    var tab: []const u8 = "";
                    if (at.window) |wi| {
                        if (wi - 1 < sn.windows.items.len) {
                            var tb: [48]u8 = undefined;
                            tab = a.dupe(u8, self.tabName(sn, sn.windows.items[wi - 1], &tb)) catch "";
                        }
                    }
                    const lo = p.last_output_ms.load(.acquire);
                    const producing = lo != 0 and now - lo < chromepkg.working_ms;
                    var ab: [16]u8 = undefined;
                    // rook can say a program is here and whether it is
                    // producing; what it is doing is not rook's to say
                    const who: []const u8 = if (p.owner_len > 0) p.ownerName() else prog;
                    const name = std.fmt.allocPrint(a, "{s} in {s} › {s}", .{ who, chromepkg.shortSpace(sn.label()), tab }) catch continue;
                    const line = if (producing)
                        (std.fmt.allocPrint(a, "{s} producing · goal unknown — nobody pushed a task for it", .{prog}) catch "")
                    else
                        (std.fmt.allocPrint(a, "{s} idle · {s} since output · goal unknown", .{ prog, altpkg.age(&ab, now - lo) }) catch "");
                    const mark: ui.Mark = if (producing) .working else .waiting;
                    var row: altpkg.Row = .{ .kind = .work, .glyph = ui.markGlyph(&self.ui, mark), .ink = ui.markInk(&self.ui, mark), .name = name, .line = line, .line_ink = self.ui.muted, .hint = "↵ go", .pane = p.id, .ws = si };
                    if (finding) row.score = (altpkg.fuzzy(name, text) orelse continue) + 3;
                    st.rows.append(self.gpa, row) catch {};
                }
            }
            if (home) {
                var hb: [32]u8 = undefined;
                const count = std.fmt.bufPrint(&hb, "{d}", .{recent}) catch "";
                st.rows.append(self.gpa, .{ .kind = .header, .name = "recent", .line = if (recent > 0) (a.dupe(u8, count) catch "") else "nothing finished yet" }) catch {};
            }
            for (claims) |it| {
                if (it.state != .done) continue;
                self.workRow(a, it, text, finding);
            }
        }

        // Spaces, in workspace order — always the same order, so a
        // space is where it was last time whatever changed in it.
        if (home) {
            var hb: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&hb, "{d}", .{self.sessions.items.len}) catch "";
            st.rows.append(self.gpa, .{ .kind = .header, .name = "spaces", .line = a.dupe(u8, count) catch "" }) catch {};
        }
        for (self.sessions.items, 0..) |sn, si| {
            if (st.spaces_n == st.spaces.len) break;
            const sp = &st.spaces[st.spaces_n];
            self.spaceInfo(a, sn, si, sp);
            const idx = st.spaces_n;
            st.spaces_n += 1;
            // the tabs as one line, for ledger and the compact row
            var tl: std.ArrayList(u8) = .empty;
            for (sp.tabs, 0..) |t, ti| {
                if (ti > 0) tl.appendSlice(a, " · ") catch {};
                var lb: [64]u8 = undefined;
                tl.appendSlice(a, altpkg.tabLabel(&lb, t.name, t.actor)) catch {};
                const mg = ui.markGlyph(&self.ui, altpkg.markOf(t.mark));
                if (mg.len > 0) {
                    tl.appendSlice(a, " ") catch {};
                    tl.appendSlice(a, mg) catch {};
                }
            }
            if (!finding) {
                st.rows.append(self.gpa, .{
                    .kind = .space,
                    .name = sp.name,
                    .line = sp.event,
                    .second = tl.items,
                    .hint = "↵ enter",
                    .ws = si,
                    .space = idx,
                }) catch {};
                continue;
            }
            // Finding: spaces, tabs and panes as one-line rows, ranked.
            if (altpkg.fuzzy(sp.name, text)) |sc| {
                st.rows.append(self.gpa, .{ .kind = .space, .name = sp.name, .line = sp.event, .second = tl.items, .hint = "↵ enter", .ws = si, .space = idx, .score = sc }) catch {};
            }
            for (sn.windows.items, 0..) |w, wi| {
                var nb: [48]u8 = undefined;
                const tab = self.tabName(sn, w, &nb);
                const wname = std.fmt.allocPrint(a, "{s} › {s}", .{ sp.name, tab }) catch continue;
                const actor = self.windowOwner(w);
                const wline: []const u8 = if (actor.len > 0) (std.fmt.allocPrint(a, "{s} drives it", .{actor}) catch "") else "";
                if (altpkg.fuzzy(wname, text)) |sc| {
                    st.rows.append(self.gpa, .{ .kind = .tab, .name = wname, .line = wline, .hint = "↵ go", .ws = si, .win = wi, .score = sc + 2 }) catch {};
                }
                for (self.panes.items) |p| {
                    if (!w.layout.contains(p.id)) continue;
                    var pb: [64]u8 = undefined;
                    const prog = p.fgName(&pb) orelse "shell";
                    var tb: [256]u8 = undefined;
                    const title = p.title(&tb);
                    const pname = std.fmt.allocPrint(a, "{s} › {s} › {s}", .{ sp.name, tab, prog }) catch continue;
                    const pline = a.dupe(u8, title) catch "";
                    const sc = altpkg.fuzzy(pname, text) orelse (if (altpkg.fuzzy(pline, text)) |s2| s2 + 30 else null) orelse continue;
                    st.rows.append(self.gpa, .{ .kind = .pane, .name = pname, .line = pline, .hint = "↵ focus", .pane = p.id, .score = sc + 4 }) catch {};
                }
            }
        }

        // Global pins: live at every altitude, listed with where they
        // came from so the keyboard can reach the dock.
        if (self.global_pins.items.len > 0 and !finding) {
            st.rows.append(self.gpa, .{ .kind = .header, .name = "pinned everywhere" }) catch {};
        }
        for (self.global_pins.items) |id| {
            const p = self.pane(id) orelse continue;
            var pb: [64]u8 = undefined;
            const prog = p.fgName(&pb) orelse "shell";
            const from = self.pinOrigin(id);
            const name = std.fmt.allocPrint(a, "{s}", .{prog}) catch continue;
            const line = if (from.len > 0)
                std.fmt.allocPrint(a, "from {s}", .{chromepkg.shortSpace(from)}) catch ""
            else
                "";
            var pg: [8]u8 = undefined;
            const pin_glyph = std.fmt.bufPrint(&pg, "{s}g", .{ui.glyph(&self.ui, .pin)}) catch "g";
            const pin_glyph_d = a.dupe(u8, pin_glyph) catch continue;
            var row: altpkg.Row = .{ .kind = .pin, .glyph = pin_glyph_d, .ink = self.ui.muted, .name = name, .line = line, .hint = "↵ focus", .pane = id };
            if (finding) row.score = (altpkg.fuzzy(name, text) orelse continue) + 6;
            st.rows.append(self.gpa, row) catch {};
        }

        if (finding) {
            std.mem.sort(altpkg.Row, st.rows.items, {}, struct {
                fn lt(_: void, x: altpkg.Row, y: altpkg.Row) bool {
                    return x.score < y.score;
                }
            }.lt);
            if (st.rows.items.len == 0) {
                st.rows.append(self.gpa, .{ .kind = .note, .name = "nothing matches" }) catch {};
            }
        }
        // a section asked for by a key: the cursor on its first row,
        // or on the header's neighbour when it is empty
        switch (st.land) {
            .none => {},
            .needs => if (land_needs) |i| {
                st.cur = i;
            },
            .running => if (land_running) |i| {
                st.cur = i;
            },
        }
        st.land = .none;
        st.clampCursor();
    }

    /// Home's projection: the spaces, then every task as one entity
    /// — a producer's row, an agent rook sees producing where nobody
    /// claims, a pane that signalled, an action waiting on a hand —
    /// sorted into its group, then the navigator's rows, then the
    /// inspector for what is selected. A task the rail knows that
    /// changed state since last time earns one note in the thread.
    fn homeBuild(self: *Server, a: std.mem.Allocator, now: i64) void {
        const st = &self.alt;
        const h = &st.home;
        h.reset();
        // What the rail says in the server's first seconds is what was
        // already true, not news; after that, a task appearing is.
        h.seeded = nowMs() - self.started_ms > 5000;
        for (self.sessions.items, 0..) |sn, si| {
            if (st.spaces_n == st.spaces.len) break;
            self.spaceInfo(a, sn, si, &st.spaces[st.spaces_n]);
            st.spaces_n += 1;
        }
        const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};

        // needs you: what the companion proposed, still waiting on a hand
        if (st.req.ref) |*r| {
            for (r.actions[0..r.actions_n], 0..) |*act, i| {
                if (act.ran or act.running) continue;
                _ = h.addTask(.{
                    .kind = .approval,
                    .module = .needs,
                    .id = r.taskSlice(),
                    .title = act.labelSlice(),
                    .space = r.spaceSlice(),
                    .full = r.spaceSlice(),
                    .actor = self.askName(),
                    .event = act.runSlice(),
                    .action = i,
                    .ws = self.sessionNamed(r.spaceSlice()),
                });
            }
        }
        // …then what a program asked, oldest first
        var attn: [64]*panepkg.Pane = undefined;
        var an: usize = 0;
        for (self.panes.items) |p| {
            if (p.unread_ms == 0 or self.ownPane(p.id)) continue;
            if (an == attn.len) break;
            var i = an;
            while (i > 0 and attn[i - 1].unread_ms > p.unread_ms) : (i -= 1) attn[i] = attn[i - 1];
            attn[i] = p;
            an += 1;
        }
        for (attn[0..an]) |p| {
            const at = self.placeOf(p.id) orelse continue;
            var tab: []const u8 = "";
            var ws: ?usize = null;
            var win: ?usize = null;
            if (self.sessionNamed(at.workspace)) |si| {
                ws = si;
                if (at.window) |wi| {
                    win = wi - 1;
                    const sn = self.sessions.items[si];
                    if (wi - 1 < sn.windows.items.len) {
                        var nb: [48]u8 = undefined;
                        tab = a.dupe(u8, self.tabName(sn, sn.windows.items[wi - 1], &nb)) catch "";
                    }
                }
            }
            var nb: [64]u8 = undefined;
            const prog = a.dupe(u8, p.fgName(&nb) orelse "shell") catch "shell";
            const said: []const u8 = if (p.notif_ms != 0 and p.notif_ms >= p.unread_ms and p.notif_title_len > 0)
                a.dupe(u8, p.notif_title[0..p.notif_title_len]) catch ""
            else if (p.bell_ms != 0 and p.bell_ms >= p.unread_ms)
                "rang the bell"
            else if (p.progress_done_ms != 0 and p.progress_done_ms >= p.unread_ms)
                "finished its progress bar"
            else
                "signalled";
            _ = h.addTask(.{
                .kind = .signal,
                .module = .needs,
                .title = said,
                .space = chromepkg.shortSpace(at.workspace),
                .full = at.workspace,
                .actor = if (p.owner_len > 0) p.ownerName() else prog,
                .program = prog,
                .tab = tab,
                .event = if (p.notif_body_len > 0 and p.notif_ms >= p.unread_ms) (a.dupe(u8, p.notif_body[0..p.notif_body_len]) catch "") else "",
                .unread = true,
                .age_ms = now - p.unread_ms,
                .pane = p.id,
                .ws = ws,
                .win = win,
            });
        }
        // the producer's tasks, each in its group by state
        for (claims) |*it| {
            const ws_name = it.workspace();
            const held = self.sessionNamed(ws_name);
            const module: homepkg.Module = switch (it.state) {
                .blocked, .failed => .needs,
                .done => .recent,
                else => .active,
            };
            const detail = if (it.event.len > 0) it.event else it.sub;
            const agent_pane: u32 = if (held) |si| (self.agentPaneIn(self.sessions.items[si]) orelse 0) else 0;
            _ = h.addTask(.{
                .kind = .producer,
                .module = module,
                .id = it.id,
                .title = it.name,
                .state = it.state,
                .space = chromepkg.shortSpace(ws_name),
                .full = ws_name,
                .actor = it.actor,
                .event = if (std.mem.startsWith(u8, detail, it.state.word())) std.mem.trimStart(u8, detail[it.state.word().len..], " ·") else detail,
                .result = it.result,
                .unread = it.unread,
                .age_ms = if (it.started_ms > 0) now - it.started_ms else 0,
                .pane = agent_pane,
                .ws = held,
                .item = it,
            });
            if (h.remember(it.id, it.state)) |was| {
                // a task first seen already done is history, not news
                if (was != .none or (h.seeded and it.state != .done)) self.noteTransition(a, it.*, was, now);
            }
        }
        // agents rook can see producing where no producer claims: one
        // quiet row each, titled by what rook can see. Idle ones are
        // not work; they show as marks on their space's row.
        for (self.sessions.items, 0..) |sn, si| {
            if (chromepkg.claimedIn(claims, sn.label())) continue;
            for (self.panes.items) |p| {
                if (!p.is_agent or !self.paneIn(sn, p.id)) continue;
                const lo = p.last_output_ms.load(.acquire);
                if (lo == 0 or now - lo >= chromepkg.working_ms) continue;
                var nb: [64]u8 = undefined;
                const prog = a.dupe(u8, p.fgName(&nb) orelse "agent") catch "agent";
                const at = self.placeOf(p.id) orelse continue;
                var tab: []const u8 = "";
                if (at.window) |wi| {
                    if (wi - 1 < sn.windows.items.len) {
                        var tb: [48]u8 = undefined;
                        tab = a.dupe(u8, self.tabName(sn, sn.windows.items[wi - 1], &tb)) catch "";
                    }
                }
                _ = h.addTask(.{
                    .kind = .found,
                    .module = .active,
                    .title = std.fmt.allocPrint(a, "{s} at work", .{if (p.owner_len > 0) p.ownerName() else prog}) catch prog,
                    .space = chromepkg.shortSpace(sn.label()),
                    .full = sn.label(),
                    .actor = prog,
                    .program = prog,
                    .tab = tab,
                    .age_ms = now - lo,
                    .pane = p.id,
                    .ws = si,
                });
            }
        }

        // the rows, group by group; an empty group is left out, and
        // an empty navigator says so once
        var any_work = false;
        inline for (.{ homepkg.Module.needs, homepkg.Module.active, homepkg.Module.recent }) |m| {
            var n: usize = 0;
            for (h.tasks[0..h.tasks_n]) |tk| {
                if (tk.module == m) n += 1;
            }
            if (n > 0) {
                any_work = true;
                h.addRow(.{ .module = m, .header = true });
                for (h.tasks[0..h.tasks_n], 0..) |tk, ti| {
                    if (tk.module == m) h.addRow(.{ .module = m, .task = ti });
                }
            }
        }
        if (!any_work) h.addRow(.{ .module = .active });
        h.addRow(.{ .module = .spaces, .header = true });
        for (0..st.spaces_n) |si| h.addRow(.{ .module = .spaces, .space = si });

        switch (st.land) {
            .none => {},
            .needs => {
                if (!h.landNav(.needs)) _ = h.landNav(.active);
            },
            .running => {
                if (!h.landNav(.active)) _ = h.landNav(.needs);
            },
        }
        st.land = .none;
        h.restoreSelection();
        self.inspBuild(a, now);
    }

    /// The inspector for what is selected: sections only where the
    /// data is, controls only where the producer said, and rook's
    /// own two — open the workspace, ask vera about this.
    fn inspBuild(self: *Server, a: std.mem.Allocator, now: i64) void {
        const st = &self.alt;
        const h = &st.home;
        const ins = &h.insp;
        ins.reset();
        var kb: [72]u8 = undefined;
        const row = h.selectedRow() orelse {
            ins.subject("");
            self.inspQuiet(a);
            return;
        };
        ins.subject(h.rowKey(row, &kb));
        if (row.task) |ti| {
            self.inspTask(a, h.tasks[ti], now);
        } else if (row.space) |si| {
            self.inspSpace(a, si, now);
        }
    }

    /// Nothing selected: what there is, and what there is to do.
    fn inspQuiet(self: *Server, a: std.mem.Allocator) void {
        const ins = &self.alt.home.insp;
        var pk: [8]u8 = undefined;
        const pfx = prefixName(self.prefix_key, &pk);
        ins.line(.{ .kind = .title, .text = "rook", .mark = .none });
        ins.line(.{ .kind = .meta, .text = std.fmt.allocPrint(a, "{d} space{s} · nothing running · nothing needs you", .{ self.sessions.items.len, plural(self.sessions.items.len) }) catch "" });
        ins.line(.{ .kind = .blank });
        ins.line(.{ .kind = .quiet, .text = "a task a producer pushes shows here by its goal; an agent rook sees producing shows by its pane" });
        ins.line(.{ .kind = .blank });
        ins.line(.{ .kind = .section, .text = "to do something" });
        ins.line(.{ .kind = .kv, .extra = std.fmt.allocPrint(a, "{s}t", .{pfx}) catch "t", .text = "ask vera" });
        ins.line(.{ .kind = .kv, .extra = ":new", .text = "a new space, by name" });
        ins.line(.{ .kind = .kv, .extra = "/", .text = "find a space, a task, a tab, a pane" });
    }

    fn inspTask(self: *Server, a: std.mem.Allocator, tk: homepkg.Task, now: i64) void {
        const st = &self.alt;
        const h = &st.home;
        const ins = &h.insp;
        var ab: [16]u8 = undefined;
        const mark = tk.mark();
        ins.line(.{ .kind = .title, .text = tk.title, .mark = mark });
        // who, where, what state, since when
        var meta: std.ArrayList(u8) = .empty;
        meta.appendSlice(a, tk.stateWord()) catch {};
        if (tk.space.len > 0) meta.print(a, " · in {s}", .{tk.space}) catch {};
        if (tk.tab.len > 0) meta.print(a, " › {s}", .{tk.tab}) catch {};
        if (tk.actor.len > 0 and tk.kind != .found) meta.print(a, " · {s}", .{tk.actor}) catch {};
        if (tk.kind == .found) meta.print(a, " · {s}", .{tk.program}) catch {};
        if (tk.kind == .producer and tk.age_ms > 0) meta.print(a, " · {s} since it started", .{altpkg.age(&ab, tk.age_ms)}) catch {};
        if (tk.kind == .found and tk.age_ms >= 0) meta.print(a, " · wrote {s} ago", .{altpkg.age(&ab, tk.age_ms)}) catch {};
        if (tk.kind == .signal) meta.print(a, " · {s} ago, nobody was looking", .{altpkg.age(&ab, tk.age_ms)}) catch {};
        ins.line(.{ .kind = .meta, .text = meta.items });
        ins.line(.{ .kind = .blank });

        switch (tk.kind) {
            .approval => {
                ins.line(.{ .kind = .section, .text = "what vera proposed" });
                ins.line(.{ .kind = .text, .text = tk.title });
                ins.line(.{ .kind = .kv, .extra = "runs", .text = tk.event });
                if (st.req.ref) |*r| {
                    if (r.intent_len > 0) {
                        ins.line(.{ .kind = .blank });
                        ins.line(.{ .kind = .section, .text = "because you asked for" });
                        ins.line(.{ .kind = .text, .text = r.intentSlice() });
                    }
                    if (r.plan_n > 0) {
                        ins.line(.{ .kind = .blank });
                        ins.line(.{ .kind = .section, .text = "her plan" });
                        var i: usize = 0;
                        while (i < r.plan_n) : (i += 1) ins.line(.{ .kind = .step_todo, .text = r.planLine(i) });
                    }
                }
                ins.line(.{ .kind = .blank });
                ins.line(.{ .kind = .section, .text = "controls" });
                ins.act(.{ .label = "run it", .kind = .approval, .action = tk.action, .run = tk.event });
                ins.act(.{ .label = "ask vera about this", .kind = .ask });
                return;
            },
            .signal => {
                ins.line(.{ .kind = .section, .text = "what happened" });
                ins.line(.{ .kind = .text, .text = std.fmt.allocPrint(a, "{s} {s} in {s}{s}{s}", .{ tk.program, tk.title, tk.space, if (tk.tab.len > 0) " › " else "", tk.tab }) catch tk.title });
                if (tk.event.len > 0) ins.line(.{ .kind = .text, .text = tk.event });
                self.inspOutput(a, tk.pane, 6);
                ins.line(.{ .kind = .blank });
                ins.line(.{ .kind = .section, .text = "controls" });
                ins.act(.{ .label = "go see it", .kind = .go_see });
                ins.act(.{ .label = "ask vera about this", .kind = .ask });
                return;
            },
            .found => {
                ins.line(.{ .kind = .quiet, .text = "no producer pushed a task for this agent, so rook can say only what it sees: the program, where it runs, and that it is producing" });
                self.inspOutput(a, tk.pane, 8);
                ins.line(.{ .kind = .blank });
                ins.line(.{ .kind = .section, .text = "controls" });
                ins.act(.{ .label = "open its pane", .kind = .open });
                ins.act(.{ .label = "ask vera about this", .kind = .ask });
                return;
            },
            .producer => {},
        }

        const it = tk.item orelse return;
        if (it.goal.len > 0) {
            ins.line(.{ .kind = .text, .text = it.goal });
            ins.line(.{ .kind = .blank });
        }
        if (tk.state == .done) {
            ins.line(.{ .kind = .section, .text = "outcome" });
            ins.line(.{ .kind = .text, .text = if (tk.result.len > 0) tk.result else "finished; the producer gave no summary" });
            ins.line(.{ .kind = .blank });
        } else if (tk.state == .failed) {
            ins.line(.{ .kind = .section, .text = "what went wrong" });
            ins.line(.{ .kind = .text, .text = if (tk.event.len > 0) tk.event else "the producer said it failed, and no more" });
            ins.line(.{ .kind = .blank });
        } else if (tk.state == .blocked) {
            ins.line(.{ .kind = .section, .text = "waiting on you" });
            ins.line(.{ .kind = .text, .text = if (it.question.len > 0) it.question else if (tk.event.len > 0) tk.event else "the producer said it is waiting, and no more" });
            ins.line(.{ .kind = .blank });
        } else if (tk.event.len > 0) {
            ins.line(.{ .kind = .section, .text = "now" });
            ins.line(.{ .kind = .text, .text = tk.event });
            ins.line(.{ .kind = .blank });
        }
        if (it.question.len > 0 and tk.state != .blocked) {
            ins.line(.{ .kind = .section, .text = "question" });
            ins.line(.{ .kind = .text, .text = it.question });
            ins.line(.{ .kind = .blank });
        }
        if (it.plan.len > 0) {
            var done: usize = 0;
            for (it.plan) |sp| {
                if (sp.done) done += 1;
            }
            ins.line(.{ .kind = .section, .text = "plan", .extra = std.fmt.allocPrint(a, "{d} of {d}", .{ done, it.plan.len }) catch "" });
            for (it.plan) |sp| ins.line(.{ .kind = if (sp.done) .step_done else .step_todo, .text = sp.text });
            ins.line(.{ .kind = .blank });
        }
        if (it.events.len > 0) {
            ins.line(.{ .kind = .section, .text = "timeline" });
            const from = it.events.len -| 8;
            for (it.events[from..]) |ev| {
                var eb: [16]u8 = undefined;
                const age: []const u8 = if (ev.ms > 0) (a.dupe(u8, altpkg.age(&eb, now - ev.ms)) catch "") else "";
                ins.line(.{ .kind = .event, .text = ev.text, .extra = age });
            }
            ins.line(.{ .kind = .blank });
        }
        if (it.files.len > 0) {
            ins.line(.{ .kind = .section, .text = "files", .extra = std.fmt.allocPrint(a, "{d}", .{it.files.len}) catch "" });
            for (it.files[0..@min(it.files.len, 8)]) |fpath| ins.line(.{ .kind = .output, .text = fpath });
            if (it.files.len > 8) ins.line(.{ .kind = .quiet, .text = std.fmt.allocPrint(a, "and {d} more", .{it.files.len - 8}) catch "" });
            ins.line(.{ .kind = .blank });
        }
        if (it.commits.len > 0) {
            ins.line(.{ .kind = .section, .text = "commits" });
            for (it.commits[0..@min(it.commits.len, 6)]) |c| ins.line(.{ .kind = .output, .text = c });
            ins.line(.{ .kind = .blank });
        }
        if (it.tests.len > 0) ins.line(.{ .kind = .kv, .extra = "tests", .text = it.tests });
        if (it.artifacts.len > 0) {
            ins.line(.{ .kind = .section, .text = "artifacts" });
            for (it.artifacts) |ar| {
                if (ar.url.len > 0) {
                    ins.line(.{ .kind = .kv, .extra = ar.label, .text = ar.url });
                } else {
                    ins.line(.{ .kind = .output, .text = ar.label });
                }
            }
            ins.line(.{ .kind = .blank });
        }
        if (it.usage) |u| {
            ins.line(.{ .kind = .kv, .extra = "usage", .text = std.fmt.allocPrint(a, "{s} tokens · {s}", .{ fmtTokens(a, u.tokens), fmtCents(a, u.cents) }) catch "" });
        }
        const n_turns = h.thread.countAbout(tk.id);
        if (n_turns > 0) {
            ins.line(.{ .kind = .kv, .extra = "vera", .text = std.fmt.allocPrint(a, "{d} turn{s} about this in her pane", .{ n_turns, plural(n_turns) }) catch "" });
        }
        if (tk.pane != 0 and tk.state != .done) self.inspOutput(a, tk.pane, 4);
        ins.line(.{ .kind = .blank });
        ins.line(.{ .kind = .section, .text = "controls" });
        if (st.req.ref) |*r| {
            if (r.task_len > 0 and std.mem.eql(u8, r.taskSlice(), tk.id)) {
                for (r.actions[0..r.actions_n], 0..) |*act, i| {
                    if (act.ran or act.running) continue;
                    ins.act(.{ .label = act.labelSlice(), .kind = .approval, .action = i, .run = act.runSlice() });
                }
            }
        }
        for (it.options) |o| ins.act(.{ .label = o.label, .kind = .answer, .run = o.run, .ctrl = o.kind });
        for (it.controls) |c| ins.act(.{ .label = c.label, .kind = .control, .run = c.run, .ctrl = c.kind });
        if (tk.ws != null) ins.act(.{ .label = if (tk.pane != 0) "open its pane" else "open the space", .kind = .open });
        ins.act(.{ .label = "ask vera about this", .kind = .ask });
        if (it.options.len == 0 and it.controls.len == 0 and tk.state != .done) {
            ins.line(.{ .kind = .quiet, .text = "the producer offered no controls for this task; what it supports, it says on the rail" });
        }
    }

    /// The last lines a pane wrote, from retained cells — output,
    /// shown, never read for state.
    fn inspOutput(self: *Server, a: std.mem.Allocator, pane_id: u32, max: usize) void {
        const ins = &self.alt.home.insp;
        const p = self.pane(pane_id) orelse return;
        p.snapshot() catch return;
        const view = self.frame.plainText(p);
        self.full = true;
        var lines: [8][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitBackwardsScalar(u8, view, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (n == @min(max, lines.len)) break;
            lines[n] = a.dupe(u8, t[0..@min(t.len, 160)]) catch "";
            n += 1;
        }
        if (n == 0) return;
        ins.line(.{ .kind = .blank });
        var nb: [64]u8 = undefined;
        const prog = p.fgName(&nb) orelse "shell";
        ins.line(.{ .kind = .section, .text = "its pane", .extra = a.dupe(u8, prog) catch "" });
        var i = n;
        while (i > 0) {
            i -= 1;
            ins.line(.{ .kind = .output, .text = lines[i] });
        }
    }

    fn inspSpace(self: *Server, a: std.mem.Allocator, si: usize, now: i64) void {
        const st = &self.alt;
        const h = &st.home;
        const ins = &h.insp;
        const sp = st.spaces[si];
        const sn = self.sessions.items[sp.ws];
        ins.line(.{ .kind = .title, .text = sp.name, .mark = if (sp.unread > 0) .attention else if (sp.working) .working else .none });
        var ab: [16]u8 = undefined;
        ins.line(.{ .kind = .meta, .text = std.fmt.allocPrint(a, "a space · {d} tab{s}{s}{s}", .{ sp.tabs.len, plural(sp.tabs.len), if (sp.quiet_ms > 0) " · quiet " else "", if (sp.quiet_ms > 0) altpkg.age(&ab, sp.quiet_ms) else "" }) catch "" });
        ins.line(.{ .kind = .blank });
        var any = false;
        inline for (.{ homepkg.Module.needs, homepkg.Module.active, homepkg.Module.recent }) |m| {
            var first = true;
            for (h.tasks[0..h.tasks_n]) |tk| {
                if (tk.module != m or !std.mem.eql(u8, tk.full, sp.full)) continue;
                if (first) {
                    ins.line(.{ .kind = .section, .text = m.word() });
                    first = false;
                    any = true;
                }
                const mg = ui.markGlyph(&self.ui, tk.mark());
                ins.line(.{ .kind = .text, .text = std.fmt.allocPrint(a, "{s} {s}{s}{s}", .{ mg, tk.title, if (tk.actor.len > 0) " · " else "", tk.actor }) catch tk.title });
            }
            if (!first) ins.line(.{ .kind = .blank });
        }
        if (!any) {
            ins.line(.{ .kind = .quiet, .text = "no task the rail knows runs here" });
            ins.line(.{ .kind = .blank });
        }
        var agents: usize = 0;
        for (self.panes.items) |p| {
            if (!p.is_agent or !self.paneIn(sn, p.id)) continue;
            if (agents == 0) ins.line(.{ .kind = .section, .text = "agents" });
            agents += 1;
            var nb: [64]u8 = undefined;
            const prog = a.dupe(u8, p.fgName(&nb) orelse "agent") catch "agent";
            const lo = p.last_output_ms.load(.acquire);
            const producing = lo != 0 and now - lo < chromepkg.working_ms;
            var eb: [16]u8 = undefined;
            const word: []const u8 = if (producing) "producing" else (std.fmt.allocPrint(a, "idle · {s} since output", .{altpkg.age(&eb, now - lo)}) catch "idle");
            ins.line(.{ .kind = .text, .text = std.fmt.allocPrint(a, "{s} {s}{s}{s} · {s}", .{ ui.markGlyph(&self.ui, if (producing) .working else .waiting), prog, if (p.owner_len > 0) " claimed by " else "", if (p.owner_len > 0) p.ownerName() else "", word }) catch prog });
        }
        if (agents > 0) ins.line(.{ .kind = .blank });
        ins.line(.{ .kind = .section, .text = "tabs" });
        for (sp.tabs) |tb| {
            var lb: [64]u8 = undefined;
            const label = altpkg.tabLabel(&lb, tb.name, tb.actor);
            const mg = ui.markGlyph(&self.ui, altpkg.markOf(tb.mark));
            ins.line(.{ .kind = .output, .text = std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ label, if (mg.len > 0) " " else "", mg, if (tb.current) " · current" else "" }) catch label });
        }
        ins.line(.{ .kind = .blank });
        ins.line(.{ .kind = .section, .text = "controls" });
        ins.act(.{ .label = "enter the space", .kind = .enter });
        ins.act(.{ .label = "ask vera about this", .kind = .ask });
        if (h.tasks_n == 0) {
            var pk: [8]u8 = undefined;
            const pfx = prefixName(self.prefix_key, &pk);
            ins.line(.{ .kind = .blank });
            ins.line(.{ .kind = .section, .text = "to do something" });
            ins.line(.{ .kind = .kv, .extra = std.fmt.allocPrint(a, "{s}t", .{pfx}) catch "t", .text = "ask vera" });
            ins.line(.{ .kind = .kv, .extra = ":new", .text = "a new space, by name" });
            ins.line(.{ .kind = .kv, .extra = "/", .text = "find a space, a task, a tab, a pane" });
        }
    }

    /// A task the rail knows moved: say so in the thread, once, in
    /// rook's own words, with the task's id on the turn.
    fn noteTransition(self: *Server, a: std.mem.Allocator, it: chromepkg.Item, was: chromepkg.State, now: i64) void {
        const h = &self.alt.home;
        const space = chromepkg.shortSpace(it.workspace());
        switch (it.state) {
            .done => {
                const text = if (it.result.len > 0)
                    std.fmt.allocPrint(a, "{s} finished · {s}", .{ it.name, it.result }) catch it.name
                else
                    std.fmt.allocPrint(a, "{s} finished", .{it.name}) catch it.name;
                _ = h.thread.push(.result, text, it.id, it.workspace(), now);
            },
            .failed => {
                const text = std.fmt.allocPrint(a, "{s} failed{s}{s}", .{ it.name, if (it.event.len > 0) " · " else "", it.event }) catch it.name;
                _ = h.thread.push(.err, text, it.id, it.workspace(), now);
            },
            .blocked => {
                const text = std.fmt.allocPrint(a, "{s} needs you{s}{s}", .{ it.name, if (it.event.len > 0) " · " else "", it.event }) catch it.name;
                _ = h.thread.push(.note, text, it.id, it.workspace(), now);
            },
            .working => if (was != .blocked) {
                const text = std.fmt.allocPrint(a, "{s} began in {s}{s}{s}", .{ it.name, space, if (it.actor.len > 0) " · " else "", it.actor }) catch it.name;
                _ = h.thread.push(.note, text, it.id, it.workspace(), now);
            } else {
                const text = std.fmt.allocPrint(a, "{s} resumed", .{it.name}) catch it.name;
                _ = h.thread.push(.note, text, it.id, it.workspace(), now);
            },
            else => {},
        }
    }

    /// The request moved: the thread gets the turn.
    fn absorbRequest(self: *Server, ev: askpkg.Request.Event) void {
        const st = &self.alt;
        const h = &st.home;
        const now = panepkg.epochMs();
        switch (ev) {
            .none, .output => {},
            .replied => switch (st.req.state) {
                .replied => if (st.req.ref) |*r| {
                    var fba = std.heap.FixedBufferAllocator.init(&st.buf);
                    var text: std.ArrayList(u8) = .empty;
                    const a = fba.allocator();
                    if (r.intent_len > 0) text.appendSlice(a, r.intentSlice()) catch {};
                    var i: usize = 0;
                    while (i < r.plan_n) : (i += 1) {
                        text.print(a, "\n{d}. {s}", .{ i + 1, r.planLine(i) }) catch {};
                    }
                    if (r.question_len > 0) text.print(a, "\n{s} {s}", .{ ui.markGlyph(&self.ui, .attention), r.questionSlice() }) catch {};
                    if (text.items.len == 0) text.appendSlice(a, "answered with nothing to show") catch {};
                    h.req_serial += 1;
                    const turn = h.thread.push(.plan, text.items, r.taskSlice(), r.spaceSlice(), now);
                    turn.req_serial = h.req_serial;
                } else {
                    const reply = std.mem.trim(u8, st.req.replySlice(), " \t\r\n");
                    _ = h.thread.push(.vera, if (reply.len > 0) reply else "answered with nothing", h.aboutTask(), h.aboutSpace(), now);
                },
                .failed => {
                    var b: [200]u8 = undefined;
                    const why = askpkg.firstLine(if (st.req.note_len > 0) st.req.noteSlice() else st.req.replySlice());
                    _ = h.thread.push(.err, std.fmt.bufPrint(&b, "{s} could not answer ({d}) · {s}", .{ self.askName(), st.req.code, why }) catch why, "", "", now);
                },
                else => {},
            },
            .action_done => |i| if (st.req.ref) |*r| {
                const act = &r.actions[i];
                var b: [320]u8 = undefined;
                const out = askpkg.firstLine(act.receiptSlice());
                if (act.code == 0) {
                    _ = h.thread.push(.receipt, std.fmt.bufPrint(&b, "ran {s}{s}{s}", .{ act.labelSlice(), if (out.len > 0) " · " else "", out }) catch act.labelSlice(), r.taskSlice(), r.spaceSlice(), now);
                } else {
                    _ = h.thread.push(.err, std.fmt.bufPrint(&b, "{s} failed ({d}){s}{s}", .{ act.labelSlice(), act.code, if (out.len > 0) " · " else "", out }) catch act.labelSlice(), r.taskSlice(), r.spaceSlice(), now);
                }
            },
        }
        h.thread_scroll = 0;
    }

    /// An item's control finished: its receipt is a turn about the
    /// task, and the rail's next push says what changed.
    fn absorbRunner(self: *Server) void {
        const h = &self.alt.home;
        const j = &(h.runner.job orelse return);
        var b: [320]u8 = undefined;
        const out = askpkg.firstLine(j.stdout());
        const err = askpkg.firstLine(j.stderr());
        const now = panepkg.epochMs();
        if (j.code == 0) {
            _ = h.thread.push(.receipt, std.fmt.bufPrint(&b, "ran {s}{s}{s}", .{ h.runner.labelSlice(), if (out.len > 0) " · " else "", out }) catch h.runner.labelSlice(), h.runner.taskSlice(), "", now);
        } else {
            _ = h.thread.push(.err, std.fmt.bufPrint(&b, "{s} failed ({d}){s}{s}", .{ h.runner.labelSlice(), j.code, if (err.len > 0) " · " else "", if (err.len > 0) err else out }) catch h.runner.labelSlice(), h.runner.taskSlice(), "", now);
        }
        h.runner.job = null;
        h.thread_scroll = 0;
    }

    /// A producer's task as one row: the goal it named, its state
    /// and the space it runs in, then the fields it chose to add —
    /// the actor, the last event, the result. ↵ goes to the space's
    /// agent pane, or the space.
    fn workRow(self: *Server, a: std.mem.Allocator, it: chromepkg.Item, text: []const u8, finding: bool) void {
        const st = &self.alt;
        const ws = it.workspace();
        const held = self.sessionNamed(ws);
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(a, it.state.word()) catch {};
        if (held != null or ws.len > 0) {
            line.appendSlice(a, " · ") catch {};
            line.appendSlice(a, chromepkg.shortSpace(ws)) catch {};
            if (held == null) line.appendSlice(a, " (not open here)") catch {};
        }
        if (it.actor.len > 0) {
            line.appendSlice(a, " · ") catch {};
            line.appendSlice(a, it.actor) catch {};
        }
        const detail = if (it.state == .done and it.result.len > 0) it.result else if (it.event.len > 0) it.event else it.sub;
        if (detail.len > 0 and !std.mem.startsWith(u8, detail, it.state.word())) {
            line.appendSlice(a, " · ") catch {};
            line.appendSlice(a, detail) catch {};
        }
        const mark: ui.Mark = switch (it.state) {
            .working => .working,
            .done => .success,
            .failed => .failed,
            .blocked => .attention,
            .idle, .none => .waiting,
        };
        const target_pane: u32 = if (held) |si| (self.agentPaneIn(self.sessions.items[si]) orelse 0) else 0;
        var row: altpkg.Row = .{
            .kind = .work,
            .glyph = ui.markGlyph(&self.ui, mark),
            .ink = ui.markInk(&self.ui, mark),
            .name = it.name,
            .line = line.items,
            .line_ink = self.ui.secondary,
            .hint = if (held != null) "↵ go" else "",
            .pane = target_pane,
            .ws = held orelse 0,
            .arg = if (held != null) (a.dupe(u8, ws) catch "") else "",
        };
        if (it.unread) row.glyph = ui.markGlyph(&self.ui, .unread);
        if (finding) row.score = altpkg.fuzzy(it.name, text) orelse (altpkg.fuzzy(line.items, text) orelse return) + 20;
        st.rows.append(self.gpa, row) catch {};
    }

    /// One space, described: its label and identity, its tabs with
    /// their actors and marks, the count unread, whether anything in
    /// it is producing, the event line, and — for the space you left
    /// — the last lines of the pane you were in, read from retained
    /// cells without resizing anything.
    fn spaceInfo(self: *Server, a: std.mem.Allocator, sn: *Session, si: usize, sp: *altpkg.Space) void {
        const st = &self.alt;
        const now = panepkg.epochMs();
        sp.* = .{ .name = chromepkg.shortSpace(sn.label()), .full = sn.label(), .ws = si, .current = si == self.cur_sess };
        // tabs
        const tabs = st.takeTabs(sn.windows.items.len);
        for (tabs, 0..) |*t, wi| {
            const w = sn.windows.items[wi];
            var nb: [48]u8 = undefined;
            t.* = .{ .name = a.dupe(u8, self.tabName(sn, w, &nb)) catch "", .actor = self.windowOwner(w), .current = wi == sn.cur };
            const marked = self.windowAgentPane(w) orelse self.pane(w.focused);
            if (marked) |p| {
                t.mark = chromepkg.tabMark(.{
                    .current = false,
                    .agent = p.is_agent,
                    .last_output_ms = p.last_output_ms.load(.acquire),
                    .seen_ms = w.seen_ms,
                    .now = now,
                    .signal = self.windowUnread(w),
                });
            }
        }
        sp.tabs = tabs;
        // facts across the space's panes
        var latest: ?*panepkg.Pane = null;
        var working: ?*panepkg.Pane = null;
        var last_out: i64 = 0;
        for (self.panes.items) |p| {
            if (!self.paneIn(sn, p.id)) continue;
            if (p.unread_ms != 0) {
                sp.unread += 1;
                if (p.notif_ms != 0 and p.notif_title_len > 0 and (latest == null or p.notif_ms > latest.?.notif_ms)) latest = p;
            }
            const lo = p.last_output_ms.load(.acquire);
            if (lo > last_out) last_out = lo;
            if (p.is_agent and lo != 0 and now - lo < chromepkg.working_ms and working == null) working = p;
        }
        sp.working = working != null;
        // the event line: a producer's words for this space first —
        // an ask outranks work, work outranks a quiet report
        var out: std.ArrayList(u8) = .empty;
        const claims = if (self.side.agents.panel) |pnl| pnl.items else &.{};
        var claimed: ?chromepkg.Item = null;
        for (claims) |it| {
            if (it.claims(sn.label())) {
                claimed = it;
                break;
            }
        }
        if (claimed) |it| {
            if (it.name.len > 0 and !std.mem.eql(u8, it.name, sn.label())) out.appendSlice(a, it.name) catch {};
            if (it.state.word().len > 0) {
                if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
                out.appendSlice(a, it.state.word()) catch {};
            }
            sp.event_kind = switch (it.state) {
                .blocked, .failed => .needs_you,
                .working => .working,
                else => .said,
            };
        }
        if (latest) |p| {
            if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
            out.appendSlice(a, p.notif_title[0..p.notif_title_len]) catch {};
            if (sp.event_kind == .quiet) sp.event_kind = .said;
        }
        // rook's own sighting of work, unless the producer said it
        const producer_said_working = if (claimed) |it| it.state == .working else false;
        if (working) |p| {
            if (!producer_said_working) {
                if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
                var nb: [64]u8 = undefined;
                const who: []const u8 = if (p.owner_len > 0) p.ownerName() else (p.fgName(&nb) orelse "agent");
                out.appendSlice(a, who) catch {};
                out.appendSlice(a, " ") catch {};
                out.appendSlice(a, ui.markGlyph(&self.ui, .working)) catch {};
                out.appendSlice(a, " working") catch {};
            }
            if (sp.event_kind == .quiet or sp.event_kind == .said) sp.event_kind = .working;
        }
        if (sp.unread > 0) {
            if (out.items.len > 0) out.appendSlice(a, " · ") catch {};
            out.print(a, "{s}{d} need{s} you", .{ ui.markGlyph(&self.ui, .attention), sp.unread, if (sp.unread == 1) "s" else "" }) catch {};
            if (sp.event_kind == .quiet) sp.event_kind = .needs_you;
        }
        if (out.items.len == 0) {
            var ab: [16]u8 = undefined;
            if (last_out == 0) {
                out.appendSlice(a, "quiet") catch {};
            } else {
                out.print(a, "quiet · {s}", .{altpkg.age(&ab, now - last_out)}) catch {};
            }
        }
        sp.event = out.items;
        sp.quiet_ms = if (last_out == 0) 0 else now - last_out;
        // the excerpt: the pane you were in, its last lines, from the
        // cells it already holds — never a resize, never a read of
        // anything the program did not draw
        if (sp.current) {
            if (self.pane(self.focusedId())) |p| {
                p.snapshot() catch {};
                const view = self.frame.plainText(p);
                self.full = true; // the frame buffer was borrowed
                var n: usize = 0;
                var it = std.mem.splitBackwardsScalar(u8, view, '\n');
                while (it.next()) |line| {
                    const t = std.mem.trim(u8, line, " \t\r");
                    // a bare prompt is not an excerpt
                    if (t.len < 3) continue;
                    if (n == altpkg.max_excerpt) break;
                    st.excerpt[altpkg.max_excerpt - 1 - n] = a.dupe(u8, t[0..@min(t.len, 120)]) catch "";
                    n += 1;
                }
                sp.excerpt = st.excerpt[altpkg.max_excerpt - n ..];
            }
        }
    }

    /// The `:` rows: every command the typed word could become, with
    /// the argument as typed; for the commands that take a space, one
    /// row per space that matches the argument so far.
    fn altCommandRows(self: *Server, a: std.mem.Allocator) void {
        const st = &self.alt;
        const text = st.textSlice();
        var specs: [16]altpkg.CommandSpec = undefined;
        const parsed = altpkg.parseCommand(text);
        const comps = altpkg.completions(text, &specs);
        var any = false;
        for (comps) |c| {
            const arg: []const u8 = if (parsed) |pc| (if (pc.spec.cmd == c.cmd) pc.arg else "") else "";
            const takes_space = c.cmd == .go or c.cmd == .close;
            if (takes_space) {
                for (self.sessions.items) |sn| {
                    if (arg.len > 0 and altpkg.fuzzy(sn.label(), arg) == null) continue;
                    const name = std.fmt.allocPrint(a, ":{s} {s}", .{ c.word, sn.label() }) catch continue;
                    const argd = a.dupe(u8, sn.label()) catch continue;
                    st.rows.append(self.gpa, .{ .kind = .command, .glyph = ":", .ink = self.ui.accent, .name = name, .line = c.help, .hint = "↵ run", .cmd = c.cmd, .arg = argd }) catch {};
                    any = true;
                }
                continue;
            }
            const shown_arg: []const u8 = if (arg.len > 0) arg else c.arg;
            const name = std.fmt.allocPrint(a, ":{s} {s}", .{ c.word, shown_arg }) catch continue;
            const argd = a.dupe(u8, arg) catch "";
            st.rows.append(self.gpa, .{ .kind = .command, .glyph = ":", .ink = self.ui.accent, .name = name, .line = c.help, .hint = if (arg.len > 0 or c.arg.len == 0) "↵ run" else "type its argument", .cmd = c.cmd, .arg = argd }) catch {};
            any = true;
        }
        if (!any) st.rows.append(self.gpa, .{ .kind = .note, .name = "no such command" }) catch {};
    }
};

/// Text into an OSC payload: control bytes (which would end or
/// corrupt the sequence) are dropped; everything else, UTF-8
/// included, rides through.
fn oscText(out: *std.ArrayList(u8), s: []const u8) void {
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        out.appendBounded(ch) catch return;
    }
}

/// One SGR sequence for a chrome run: reset, then 24-bit ink. Chrome
/// never inherits a pane's colors, so every run starts from zero.
fn sgr(buf: []u8, spec: struct {
    fg: ?chromepkg.Rgb = null,
    bg: ?chromepkg.Rgb = null,
    bold: bool = false,
}) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("\x1b[0") catch return "\x1b[0m";
    if (spec.bold) w.writeAll(";1") catch {};
    if (spec.fg) |c| w.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
    if (spec.bg) |c| w.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch {};
    w.writeAll("m") catch {};
    return w.buffered();
}

/// A tab's mark in the design system's vocabulary.
fn markOf(m: chromepkg.TabMark) ui.Mark {
    return switch (m) {
        .none => .none,
        .working => .working,
        .unread => .unread,
        .attention => .attention,
    };
}

/// `812k`, `1.2M`, `93` — tokens at a glance.
fn fmtTokens(a: std.mem.Allocator, n: u64) []const u8 {
    if (n >= 1_000_000) return std.fmt.allocPrint(a, "{d}.{d}M", .{ n / 1_000_000, (n % 1_000_000) / 100_000 }) catch "";
    if (n >= 1_000) return std.fmt.allocPrint(a, "{d}k", .{n / 1_000}) catch "";
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
}

/// `$4.18`, from cents.
fn fmtCents(a: std.mem.Allocator, cents: u64) []const u8 {
    return std.fmt.allocPrint(a, "${d}.{d:0>2}", .{ cents / 100, cents % 100 }) catch "";
}

/// The prefix key as a person types it: the character itself, or
/// `C-x` for a control key.
fn prefixName(key: u8, buf: []u8) []const u8 {
    if (key >= 1 and key <= 26) return std.fmt.bufPrint(buf, "C-{c} ", .{key - 1 + 'a'}) catch "C-? ";
    if (key >= 0x20 and key < 0x7f) {
        buf[0] = key;
        return buf[0..1];
    }
    return "prefix ";
}

/// The engine's own names, as `proc_pidpath` reports them between a
/// pane's fork and its exec: never a tab's name.
fn isEngineName(name: []const u8) bool {
    const own = [_][]const u8{ "engine", "rook-mux", "rook" };
    for (own) |o| {
        if (std.mem.eql(u8, name, o)) return true;
    }
    return false;
}

fn containsId(list: []const u32, id: u32) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

fn removeId(list: *std.ArrayList(u32), id: u32) void {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] == id) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

/// The four vim-navigator control bytes → their direction letter.
fn ctrlNavDir(b: u8) ?u8 {
    return switch (b) {
        0x08 => 'h', // C-h
        0x0a => 'j', // C-j (Enter is 0x0d in raw mode, so this is safe)
        0x0b => 'k', // C-k
        0x0c => 'l', // C-l
        else => null,
    };
}

const KittyNav = struct { dir: u8, len: usize, release: bool };

/// Ctrl-h/j/k/l in the kitty keyboard protocol's spelling:
/// `CSI <code> ; <mods> [: <event>] u`, where the code is the plain
/// letter and the modifier field is 1 + bits (ctrl is 4). Only a
/// plain ctrl counts — ctrl+shift+h is somebody else's chord — and
/// caps/num lock bits are ignored. Event 3 is a release.
fn kittyNavDir(bytes: []const u8) ?KittyNav {
    if (bytes.len < 6 or bytes[0] != 0x1b or bytes[1] != '[') return null;
    var i: usize = 2;
    var code: u32 = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) code = code * 10 + (bytes[i] - '0');
    if (i == 2 or i >= bytes.len or bytes[i] != ';') return null;
    i += 1;
    var mods: u32 = 0;
    const mstart = i;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) mods = mods * 10 + (bytes[i] - '0');
    if (i == mstart or i >= bytes.len) return null;
    var event: u32 = 1;
    if (bytes[i] == ':') {
        i += 1;
        const estart = i;
        event = 0;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) event = event * 10 + (bytes[i] - '0');
        if (i == estart or i >= bytes.len) return null;
    }
    if (bytes[i] != 'u') return null;
    const dir: u8 = switch (code) {
        'h', 'j', 'k', 'l' => @intCast(code),
        else => return null,
    };
    if (mods == 0) return null;
    const bits = mods - 1;
    // ctrl set; shift, alt, super, hyper, meta clear; lock bits free
    if (bits & 4 == 0 or bits & (1 | 2 | 8 | 16 | 32) != 0) return null;
    return .{ .dir = dir, .len = i + 1, .release = event == 3 };
}

test "kitty-spelled ctrl-hjkl is the navigator's, in every event form" {
    const t = std.testing;
    try t.expectEqual(KittyNav{ .dir = 'h', .len = 8, .release = false }, kittyNavDir("\x1b[104;5u").?);
    try t.expectEqual(KittyNav{ .dir = 'l', .len = 10, .release = false }, kittyNavDir("\x1b[108;5:1u").?);
    try t.expectEqual(KittyNav{ .dir = 'j', .len = 10, .release = false }, kittyNavDir("\x1b[106;5:2u").?);
    try t.expectEqual(KittyNav{ .dir = 'k', .len = 10, .release = true }, kittyNavDir("\x1b[107;5:3u").?);
    // caps lock on is still ctrl-h
    try t.expectEqual(@as(u8, 'h'), kittyNavDir("\x1b[104;69u").?.dir);
    // trailing bytes belong to the next key
    try t.expectEqual(@as(usize, 8), kittyNavDir("\x1b[104;5uabc").?.len);
}

test "other kitty keys are not the navigator's" {
    const t = std.testing;
    try t.expect(kittyNavDir("\x1b[104;6u") == null); // ctrl+shift+h
    try t.expect(kittyNavDir("\x1b[104;7u") == null); // ctrl+alt+h
    try t.expect(kittyNavDir("\x1b[104;1u") == null); // plain h
    try t.expect(kittyNavDir("\x1b[105;5u") == null); // ctrl+i
    try t.expect(kittyNavDir("\x1b[104;5~") == null); // not a u
    try t.expect(kittyNavDir("\x1b[<0;3;4M") == null); // a mouse report
    try t.expect(kittyNavDir("\x08") == null);
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// ---- input routing: pasted text vs. keys ----
//
// The bug these guard: with `prefix = "`"`, pasting ```` ```bash ````
// armed the prefix on the first backtick and spent the `b` after it
// on a command, then ate the ESC of the closing marker the same way —
// so the pane never saw the end of the paste and the text never
// landed. Between the markers there are no keys, only text.

test "a paste opens at its marker and runs to the end of the run" {
    var p: Paste = .{};
    const in = "\x1b[200~hello\x1b[201~";
    try std.testing.expectEqual(@as(usize, 6), runEnd(&p, in, '`'));
    try std.testing.expect(p.active);
    try std.testing.expectEqual(in.len - 6, p.take(in[6..]));
    try std.testing.expect(!p.active);
}

test "a backtick inside a paste is text, not the prefix key" {
    var p: Paste = .{};
    const in = "\x1b[200~```bash\nls\n```\x1b[201~";
    const opened = runEnd(&p, in, '`');
    try std.testing.expectEqual(@as(usize, 6), opened);
    try std.testing.expect(p.active);
    // every remaining byte, backticks and closing marker included,
    // is handed to the pane in one piece
    try std.testing.expectEqual(in.len - opened, p.take(in[opened..]));
    try std.testing.expect(!p.active);
}

test "the prefix key is a prefix again once the paste has closed" {
    var p: Paste = .{};
    _ = runEnd(&p, "\x1b[200~x\x1b[201~", '`');
    _ = p.take("x\x1b[201~");
    try std.testing.expect(!p.active);
    // `ab`c` -> the run stops at the backtick, as it always did
    try std.testing.expectEqual(@as(usize, 2), runEnd(&p, "ab`c", '`'));
}

test "outside a paste the prefix key still ends the run" {
    var p: Paste = .{};
    try std.testing.expectEqual(@as(usize, 2), runEnd(&p, "ab`c", '`'));
    try std.testing.expect(!p.active);
    // C-b, the default prefix, the same way
    var q: Paste = .{};
    try std.testing.expectEqual(@as(usize, 3), runEnd(&q, "abc\x02d", 0x02));
}

test "a mouse report ends the run so the server can read it itself" {
    var p: Paste = .{};
    try std.testing.expectEqual(@as(usize, 2), runEnd(&p, "ab\x1b[<0;1;1M", '`'));
    try std.testing.expect(!p.active);
}

test "an escape that is not a mouse report goes to the pane" {
    var p: Paste = .{};
    // a lone ESC, and an arrow key, both ride through untouched
    try std.testing.expectEqual(@as(usize, 1), runEnd(&p, "\x1b", '`'));
    var q: Paste = .{};
    try std.testing.expectEqual(@as(usize, 3), runEnd(&q, "\x1bOA", '`'));
}

test "a marker split across reads still opens and closes the paste" {
    var p: Paste = .{};
    // the glass reads 4 KB at a time: a marker can straddle two reads
    try std.testing.expectEqual(@as(usize, 3), runEnd(&p, "\x1b[2", '`'));
    try std.testing.expect(!p.active);
    try std.testing.expectEqual(@as(usize, 3), runEnd(&p, "00~", '`'));
    try std.testing.expect(p.active);
    // content, then a closing marker split the same way
    try std.testing.expectEqual(@as(usize, 5), p.take("a`b\x1b["));
    try std.testing.expect(p.active);
    try std.testing.expectEqual(@as(usize, 4), p.take("201~x"));
    try std.testing.expect(!p.active);
}

test "a false start on a marker leaves the bytes as keys" {
    var p: Paste = .{};
    // ESC [ 2 0 1 ~ is the *closing* marker: with no paste open it is
    // just an escape sequence for the pane, and the run is not cut
    try std.testing.expectEqual(@as(usize, 6), runEnd(&p, "\x1b[201~", '`'));
    try std.testing.expect(!p.active);
    // and a near-miss restarts the match at the byte that missed
    var q: Paste = .{};
    try std.testing.expectEqual(@as(usize, 10), runEnd(&q, "\x1b[20\x1b[200~x", '`'));
    try std.testing.expect(q.active);
}

test "a byte spent on a command cannot be part of a marker" {
    var p: Paste = .{};
    _ = runEnd(&p, "\x1b[2", '`');
    p.reset();
    try std.testing.expectEqual(@as(usize, 3), runEnd(&p, "00~", '`'));
    try std.testing.expect(!p.active);
}

test "a notice's letter is its mark, and an unknown letter is calm" {
    try std.testing.expectEqual(ui.Mark.success, Server.noticeMark('s'));
    try std.testing.expectEqual(ui.Mark.failed, Server.noticeMark('f'));
    try std.testing.expectEqual(ui.Mark.attention, Server.noticeMark('a'));
    try std.testing.expectEqual(ui.Mark.unread, Server.noticeMark('u'));
    try std.testing.expectEqual(ui.Mark.none, Server.noticeMark('-'));
}

test "a popup request says how big it wants to be, or says nothing" {
    const plain = Server.popupSize("rook pick");
    try std.testing.expectEqualStrings("rook pick", plain.cmd);
    try std.testing.expectEqual([2]u8{ 80, 84 }, plain.pct);
    const sized = Server.popupSize("\x1f72x86@124x48\x1fgrim");
    try std.testing.expectEqualStrings("grim", sized.cmd);
    try std.testing.expectEqual([2]u8{ 72, 86 }, sized.pct);
    try std.testing.expectEqual([2]u16{ 124, 48 }, sized.max);
    try std.testing.expectEqual([2]u16{ 0, 0 }, Server.popupSize("\x1f80x84\x1fx").max);
    // nonsense is clamped, or ignored: a popup is never a sliver or off the glass
    try std.testing.expectEqual([2]u8{ 30, 100 }, Server.popupSize("\x1f5x250\x1fx").pct);
    try std.testing.expectEqual([2]u8{ 80, 84 }, Server.popupSize("\x1fwide\x1fx").pct);
}
