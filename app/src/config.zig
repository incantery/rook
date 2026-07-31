//! rook config: $XDG_CONFIG_HOME/rook/config.toml (default
//! ~/.config/rook/config.toml). A deliberate TOML subset — flat
//! `key = value` lines, # comments, quoted strings, numbers. Dashes and
//! underscores in keys are interchangeable (font-size == font_size).
//! Missing file = defaults.
//!
//! ONE FILE, TWO READERS. This is rook-host's config too, and most of
//! what is in it belongs to the host: coder, workspace-allow,
//! [jira], [lsp], [workspaces.*]. So:
//!
//!   - Only TOP-LEVEL keys are ours. A key inside any [table] is
//!     someone else's by definition — parsing `url` out of [jira] as if
//!     it were a window setting is how a shared file goes wrong.
//!   - An unrecognised key is SILENT, not a warning. We are a guest in
//!     this file and cannot tell a typo from a host key we've never
//!     heard of. The cost is that our own typos are quiet too, which is
//!     the price of one config instead of two (NEXT.md's layered
//!     config.d/ is where this eventually gets its rigour back).

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// What sits behind a translucent window. `blur` = NSVisualEffectView
/// behind-window material (10.10+, boring, reliable); `glass` /
/// `glass-clear` = NSGlassEffectView, macOS 26's Liquid Glass (falls
/// back to blur pre-Tahoe). Needs background-opacity < 1 to be seen.
pub const Blur = enum { none, blur, glass, glass_clear };

pub fn blurFromName(name: []const u8) ?Blur {
    const map = [_]struct { n: []const u8, b: Blur }{
        .{ .n = "none", .b = .none },
        .{ .n = "blur", .b = .blur },
        .{ .n = "glass", .b = .glass },
        .{ .n = "glass-clear", .b = .glass_clear },
        .{ .n = "glass_clear", .b = .glass_clear },
        // Ghostty's names, for switchers' muscle memory.
        .{ .n = "macos-glass-regular", .b = .glass },
        .{ .n = "macos-glass-clear", .b = .glass_clear },
    };
    for (map) |m| {
        if (std.mem.eql(u8, name, m.n)) return m.b;
    }
    return null;
}

/// What BEL does. `visual` is the default because the signal that
/// matters is "which pane wants me", and that is the chip dot plus a
/// dock bounce — an agent finishing work in a background space should
/// be findable, not audible. `audible` adds NSBeep for people who want
/// the terminal to sound like a terminal.
pub const Bell = enum { none, visual, audible, all };

/// What OSC 52 may do. `allow` is the default and matches every other
/// terminal worth switching from: without it, yanking in vim or tmux
/// over ssh silently does nothing, which is the single most common
/// "why is my terminal broken" report there is.
///
/// It is a knob at all because a clipboard WRITE is an unprompted one:
/// any program that can put bytes on your screen — including `cat` of a
/// file you didn't write — can replace what your next ⌘V pastes. Reads
/// are not a question here; ghostty-vt never forwards them.
pub const ClipboardWrite = enum { allow, deny };

pub fn clipboardWriteFromName(name: []const u8) ?ClipboardWrite {
    if (std.mem.eql(u8, name, "allow") or std.mem.eql(u8, name, "true")) return .allow;
    if (std.mem.eql(u8, name, "deny") or std.mem.eql(u8, name, "false")) return .deny;
    return null;
}

/// Parse a byte size: a bare number, or one with a `kb`/`mb`/`gb`
/// suffix (case-insensitive, optional space, `k`/`m`/`g` accepted too).
///
/// Suffixes exist because this key is measured in BYTES and the useful
/// values are in the millions — `scrollback = 10485760` is a number
/// nobody can read, check, or edit with confidence.
pub fn parseSize(raw: []const u8) ?usize {
    const val = std.mem.trim(u8, raw, " \t\"");
    if (val.len == 0) return null;
    var i: usize = 0;
    while (i < val.len and val[i] >= '0' and val[i] <= '9') i += 1;
    if (i == 0) return null;
    const n = std.fmt.parseInt(usize, val[0..i], 10) catch return null;

    var unit_buf: [4]u8 = undefined;
    const rest = std.mem.trim(u8, val[i..], " \t");
    if (rest.len == 0) return n;
    if (rest.len > unit_buf.len) return null;
    const unit = std.ascii.lowerString(unit_buf[0..rest.len], rest);

    const mult: usize = if (std.mem.eql(u8, unit, "b"))
        1
    else if (std.mem.eql(u8, unit, "k") or std.mem.eql(u8, unit, "kb"))
        1024
    else if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "mb"))
        1024 * 1024
    else if (std.mem.eql(u8, unit, "g") or std.mem.eql(u8, unit, "gb"))
        1024 * 1024 * 1024
    else
        return null;
    return std.math.mul(usize, n, mult) catch null;
}

pub fn bellFromName(name: []const u8) ?Bell {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "visual")) return .visual;
    if (std.mem.eql(u8, name, "audible")) return .audible;
    if (std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "both")) return .all;
    return null;
}

/// One thing a chrome bar can render. The two bars (top strip, status
/// bar) share this vocabulary — "what is drawn where" is arrangement,
/// not architecture, which is what lets a tmux hand and a VS Code hand
/// each get their chrome from the same engine.
pub const Segment = enum {
    /// The session tabs — chips in the top strip, a text list or a
    /// compact current-tab chip in the status bar (see TabStyle).
    tabs,
    workspace,
    branch,
    /// Focused pane's cwd label. FLEXIBLE: fills the gap between the
    /// two clusters (left-aligned from the left list, right-aligned
    /// from the right), hidden below 10 cells. Its position within
    /// its list is not honored — it is the gap-filler.
    cwd,
    /// The teaching hints ("` menu", "⌘K commands").
    hints,
    /// The perf HUD (diagnostics; sheds first in the default layout).
    hud,
    /// The centered workspace name. Top strip only; elsewhere skipped.
    title,
};

pub fn segFromName(name: []const u8) ?Segment {
    const map = [_]struct { n: []const u8, s: Segment }{
        .{ .n = "tabs", .s = .tabs },      .{ .n = "workspace", .s = .workspace },
        .{ .n = "branch", .s = .branch },  .{ .n = "cwd", .s = .cwd },
        .{ .n = "hints", .s = .hints },    .{ .n = "hud", .s = .hud },
        .{ .n = "title", .s = .title },
    };
    for (map) |m| if (std.mem.eql(u8, name, m.n)) return m.s;
    return null;
}

pub const SegList = struct {
    items: [8]Segment = undefined,
    n: usize = 0,

    pub fn slice(self: *const SegList) []const Segment {
        return self.items[0..self.n];
    }
    pub fn has(self: *const SegList, s: Segment) bool {
        for (self.slice()) |x| if (x == s) return true;
        return false;
    }
    pub fn eql(a: *const SegList, b: *const SegList) bool {
        return std.mem.eql(Segment, a.slice(), b.slice());
    }
};

/// Comptime SegList literal, for defaults and preset bundles.
pub fn segs(comptime list: anytype) SegList {
    var s = SegList{};
    inline for (list) |x| {
        s.items[s.n] = x;
        s.n += 1;
    }
    return s;
}

/// How a `tabs` segment renders. `chips` is the top strip's pill; the
/// two text styles exist for the status bar — tmux's `1:name 2:name`
/// list, and a single current-tab chip (VS Code's workspace-name-in-
/// the-bottom-bar minimalism; click cycles).
pub const TabStyle = enum { chips, index_name, current };

/// When the per-pane buffer line shows. `multiple` (the default, and
/// what `true` means) holds rook's own rule — one chip is noise, so
/// the strip appears with the second document. `always` is VS Code's
/// contract: the tab is part of the editor from the first file, name
/// and dirty dot and close button included.
pub const BufferLine = enum { off, multiple, always };

pub fn bufferLineFromName(name: []const u8) ?BufferLine {
    if (std.mem.eql(u8, name, "off") or std.mem.eql(u8, name, "false")) return .off;
    if (std.mem.eql(u8, name, "multiple") or std.mem.eql(u8, name, "true")) return .multiple;
    if (std.mem.eql(u8, name, "always")) return .always;
    return null;
}

pub fn tabStyleFromName(name: []const u8) ?TabStyle {
    if (std.mem.eql(u8, name, "chips")) return .chips;
    if (std.mem.eql(u8, name, "index-name") or std.mem.eql(u8, name, "index_name")) return .index_name;
    if (std.mem.eql(u8, name, "current")) return .current;
    return null;
}

/// A preset is a DEFAULTS LAYER, nothing more: it rewrites the chrome
/// fields and later keys still override ("config lines replace
/// defaults", unchanged). The SDK expands the same bundles at emit
/// time so a graph shows every knob a preset set — this table and the
/// SDK's must agree, and the e2e presetparity scenario is the guard.
pub fn applyPreset(cfg: *Config, name: []const u8) bool {
    if (std.mem.eql(u8, name, "tmux-neovim") or std.mem.eql(u8, name, "tmux")) {
        cfg.top_bar = segs(.{});
        cfg.status_left = segs(.{.tabs});
        cfg.status_right = segs(.{ .workspace, .branch, .cwd });
        cfg.tab_style = .index_name;
        cfg.buffer_line = .off;
        return true;
    }
    if (std.mem.eql(u8, name, "vscode")) {
        cfg.top_bar = segs(.{});
        cfg.status_left = segs(.{ .tabs, .branch });
        cfg.status_right = segs(.{ .cwd, .hints });
        cfg.tab_style = .current;
        // VS Code's tab strip is there from the first file, not the
        // second — the tab IS how you know what you have open.
        cfg.buffer_line = .always;
        // The look-and-feel half of the persona: Dark+ colors with
        // the blue status bar, the icon rail, files open ready to
        // type, click places the cursor (that one is everyone's).
        cfg.theme = "vscode-dark";
        cfg.editor_insert = true;
        cfg.activity_bar = true;
        cfg.explorer_auto = true;
        return true;
    }
    // rook's own identity is the defaults — a no-op bundle, named so
    // "preset = rook" reads as a statement rather than an error.
    if (std.mem.eql(u8, name, "rook") or std.mem.eql(u8, name, "default")) return true;
    return false;
}

/// Parse `["tabs", "hud"]` (or a bare comma list) into a SegList.
/// An unknown segment name warns and is skipped — a list with a typo
/// should lose one segment, not the whole arrangement.
pub fn parseSegList(raw: []const u8) ?SegList {
    var val = std.mem.trim(u8, raw, " \t");
    if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']')
        val = val[1 .. val.len - 1];
    var out = SegList{};
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\"");
        if (name.len == 0) continue;
        const s = segFromName(name) orelse {
            std.debug.print("rook config: unknown segment '{s}' (tabs, workspace, branch, cwd, hints, hud, usage, title)\n", .{name});
            continue;
        };
        if (out.n < out.items.len) {
            out.items[out.n] = s;
            out.n += 1;
        }
    }
    return out;
}

/// A short list of program names, stored inline. These are argv[0]
/// basenames — `nvim`, never a path — so both bounds are generous.
/// Inline because Config is copied by value on every live reload and a
/// list of five words is not worth an allocator.
pub const NameList = struct {
    pub const max_names = 12;
    pub const max_len = 24;

    names: [max_names][max_len]u8 = undefined,
    lens: [max_names]u8 = @splat(0),
    n: usize = 0,

    pub fn get(self: *const NameList, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }

    pub fn has(self: *const NameList, name: []const u8) bool {
        for (0..self.n) |i| if (std.mem.eql(u8, self.get(i), name)) return true;
        return false;
    }

    pub fn push(self: *NameList, name: []const u8) void {
        if (self.n >= max_names or name.len == 0 or name.len > max_len) return;
        @memcpy(self.names[self.n][0..name.len], name);
        self.lens[self.n] = @intCast(name.len);
        self.n += 1;
    }
};

/// Comptime NameList literal, for defaults.
pub fn names(comptime list: anytype) NameList {
    var out = NameList{};
    inline for (list) |x| out.push(x);
    return out;
}

/// Parse `["vim", "nvim"]` (or a bare comma list) into a NameList.
/// Deliberately total: any word is a legal program name, so unlike
/// parseSegList there is nothing here that can be a typo we could warn
/// about. An empty list is a real answer — it means "yield to nobody".
pub fn parseNameList(raw: []const u8) NameList {
    var val = std.mem.trim(u8, raw, " \t");
    if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']')
        val = val[1 .. val.len - 1];
    var out = NameList{};
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |part| out.push(std.mem.trim(u8, part, " \t\""));
    return out;
}

pub const Config = struct {
    font_size: f64 = 13,
    font_family: [:0]const u8 = "FiraCode Nerd Font Mono",
    /// Builtin theme name (theme.zig); unknown names warn + default.
    theme: []const u8 = "default",
    /// 1.0 = opaque. Anything lower forfeits direct-to-display
    /// scan-out (the compositor takes over: ~+5ms present lag
    /// fullscreen) — measured tradeoff, opt-in on purpose.
    background_opacity: f64 = 1.0,
    background_blur: Blur = .none,
    /// Points of breathing room between the chrome and the pane area
    /// (content otherwise runs to the very window edge). 0–32.
    window_padding: f64 = 0,
    bell: Bell = .visual,
    clipboard_write: ClipboardWrite = .allow,
    /// The per-pane buffer line (document chips over an editor).
    /// `true`/`multiple` (default) shows it from the second document;
    /// `always` from the first (VS Code); `false`/`off` never.
    buffer_line: BufferLine = .multiple,
    /// Blink the focused pane's cursor (1.1s period, ~55% on — the
    /// mark every terminal shares). Ghostty's default too. The blink
    /// pauses while rook is in the background, so the zero-idle-frames
    /// property still holds where it was measured: an unfocused app.
    cursor_blink: bool = true,
    /// Scrollback per pane, in BYTES (the emulator's unit; it rounds up
    /// to a page and floors at one page's worth of the active area).
    /// Ghostty's own default, and for the same reason: rook previously
    /// took the library's EMBEDDED default of 10,000 bytes, which is a
    /// sane floor for a widget on someone else's screen and about 930
    /// rows for a terminal you live in. Launch-time only — resizing a
    /// live PageList's limit isn't something the library offers.
    scrollback: usize = 10 * 1024 * 1024,
    /// The top strip's contents — presence, not order (tabs left,
    /// title center, usage right). EMPTY hides the strip and the pane
    /// area reclaims its row.
    top_bar: SegList = segs(.{ .tabs, .title }),
    /// The status bar's two clusters, in display order. `status-left`
    /// / `status-right` on purpose — tmux's own keys. When narrow,
    /// segments shed from the END of the right list backward, then
    /// the end of the left list (cwd is flexible and never blocks).
    status_left: SegList = segs(.{ .workspace, .branch, .cwd }),
    status_right: SegList = segs(.{ .hints, .hud }),
    tab_style: TabStyle = .chips,
    /// `editor-mode = "insert"`: writable file buffers open in insert
    /// mode (the VS Code hand's contract; Esc still reaches normal).
    editor_insert: bool = false,
    /// The left icon rail (VS Code's activity bar): explorer, palette,
    /// diff, agents, review — one click each, always visible.
    activity_bar: bool = false,
    /// Open the file-tree sidebar at launch when the launch directory
    /// is inside a repository. Repo-gated on purpose: a Dock launch
    /// lands in $HOME, and a sidebar listing your home directory is
    /// noise, not orientation.
    explorer_auto: bool = false,

    /// Run language servers at all. On by default and lazy: nothing
    /// spawns until a file of a known language opens, so the cost of
    /// leaving it on is zero for anyone who never opens one. Off is for
    /// people who want the editor and nothing behind it.
    lsp: bool = true,

    /// Programs that own ⌃HJKL for themselves, by argv[0] name.
    ///
    /// The keys mean "move focus between rook's panes" everywhere
    /// except inside a program that splits its own window, where they
    /// have to keep meaning what that program says they mean. rook used
    /// to infer that from the alternate screen — a good proxy right up
    /// until Claude Code started using it, at which point ⌃HJKL stopped
    /// working in the pane rook exists to hold.
    ///
    /// So it asks instead: `tcgetpgrp` on the pty, at the moment of the
    /// keystroke. That is the same question the deleted webview app's
    /// 3s-stale `fg` poll was trying to answer, minus the staleness.
    /// An empty list yields to nobody.
    nav_yield: NameList = names(.{ "vim", "nvim", "vi", "view", "tmux" }),
};

/// One number over the config file — the live-reload poll compares this
/// at 1Hz (the file is tiny; reading beats fs-event plumbing). Keybinds
/// live in the same file now, so one read covers both.
pub fn digest(io: std.Io, gpa: std.mem.Allocator) u64 {
    var h = std.hash.Wyhash.init(0x400c);
    var pathbuf: [1024]u8 = undefined;
    if (cfgPath(&pathbuf)) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null) |data| {
            h.update(data);
            gpa.free(data);
        }
    }
    // The environment graph reloads live too — an apply while the app
    // runs must land like a config edit does.
    if (envPath(&pathbuf)) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null) |data| {
            h.update(data);
            gpa.free(data);
        }
    }
    return h.final();
}

/// Trim a trailing `# comment` from a value.
///
/// A QUOTED value ends at its closing quote: `theme = "Nocturne" # nice`
/// has to yield `"Nocturne"`, and a # inside the quotes is data, not a
/// comment. The old code only stripped comments from unquoted values, so
/// a commented quoted line parsed as garbage and was dropped in silence
/// — which is how a keybind that was plainly in the file did nothing.
pub fn stripComment(val: []const u8) []const u8 {
    if (val.len > 0 and val[0] == '"') {
        var i: usize = 1;
        while (i < val.len) : (i += 1) {
            if (val[i] == '\\') {
                i += 1;
                continue;
            }
            if (val[i] == '"') return val[0 .. i + 1];
        }
        return val; // unterminated — leave it; unquote will decline it
    }
    if (std.mem.indexOfScalar(u8, val, '#')) |h|
        return std.mem.trim(u8, val[0..h], " \t");
    return val;
}

pub fn cfgPath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.bufPrint(buf, "{s}/rook/config.toml", .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/rook/config.toml", .{std.mem.span(home)}) catch null;
}

/// The materialized environment graph (docs/environments/IR.md) —
/// emitted by an SDK program at APPLY time, read here at launch. When
/// present and valid it replaces the app's view of config.toml; when
/// absent, TOML is the front end exactly as before.
pub fn envPath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.bufPrint(buf, "{s}/rook/environment.json", .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/rook/environment.json", .{std.mem.span(home)}) catch null;
}

pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    if (loadEnv(io, gpa)) |cfg| return cfg;
    return loadToml(io, gpa);
}

fn loadToml(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};

    var pathbuf: [1024]u8 = undefined;
    const path = cfgPath(&pathbuf) orelse return cfg;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return cfg;
    defer gpa.free(data);

    // The preset applies FIRST regardless of where its line sits, so
    // every explicit key in the file overrides its bundle — a defaults
    // layer that could shadow a key you wrote would make line order
    // load-bearing in a file where it never was.
    {
        var pre_table = false;
        var pre = std.mem.splitScalar(u8, data, '\n');
        while (pre.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                pre_table = true;
                continue;
            }
            if (pre_table) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t\"");
            if (!std.mem.eql(u8, key, "preset")) continue;
            const val = std.mem.trim(u8, stripComment(std.mem.trim(u8, line[eq + 1 ..], " \t")), "\"");
            if (!applyPreset(&cfg, val))
                std.debug.print("rook config: unknown preset '{s}' (rook, tmux-neovim, vscode)\n", .{val});
        }
    }

    var in_table = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Everything from the first [table] on belongs to someone else.
        if (line[0] == '[') {
            in_table = true;
            continue;
        }
        if (in_table) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;

        var key_raw = std.mem.trim(u8, line[0..eq], " \t");
        // TOML allows quoted keys ("background-opacity" = 0.9) — same key.
        if (key_raw.len >= 2 and key_raw[0] == '"' and key_raw[key_raw.len - 1] == '"')
            key_raw = key_raw[1 .. key_raw.len - 1];
        var keybuf: [64]u8 = undefined;
        if (key_raw.len > keybuf.len) continue;
        for (key_raw, 0..) |c, i| keybuf[i] = if (c == '-') '_' else c;
        const key = keybuf[0..key_raw.len];

        const val = stripComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "font_size")) {
            cfg.font_size = std.fmt.parseFloat(f64, val) catch blk: {
                std.debug.print("rook config: bad font-size '{s}'\n", .{val});
                break :blk cfg.font_size;
            };
        } else if (std.mem.eql(u8, key, "font_family")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.font_family = gpa.dupeZ(u8, stripped) catch cfg.font_family;
            }
        } else if (std.mem.eql(u8, key, "background_opacity")) {
            cfg.background_opacity = std.fmt.parseFloat(f64, val) catch 1.0;
            if (cfg.background_opacity < 0.3 or cfg.background_opacity > 1.0) {
                std.debug.print("rook config: background-opacity {d} out of [0.3, 1.0], using 1.0\n", .{cfg.background_opacity});
                cfg.background_opacity = 1.0;
            }
        } else if (std.mem.eql(u8, key, "theme")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.theme = gpa.dupe(u8, stripped) catch cfg.theme;
            }
        } else if (std.mem.eql(u8, key, "window_padding") or
            std.mem.eql(u8, key, "window_padding_x") or
            std.mem.eql(u8, key, "window_padding_y"))
        {
            // The wails app spells it per-axis; rook insets uniformly.
            // Either name sets the one knob — last line wins, which for
            // the usual `x = y` pair is the same answer.
            cfg.window_padding = std.fmt.parseFloat(f64, val) catch 0;
            if (cfg.window_padding < 0 or cfg.window_padding > 32) {
                std.debug.print("rook config: window-padding {d} out of [0, 32], using 0\n", .{cfg.window_padding});
                cfg.window_padding = 0;
            }
        } else if (std.mem.eql(u8, key, "bell")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.bell = bellFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown bell '{s}' (none, visual, audible, all)\n", .{stripped});
                break :blk .visual;
            };
        } else if (std.mem.eql(u8, key, "scrollback") or
            std.mem.eql(u8, key, "scrollback_limit"))
        {
            // `scrollback-limit` is ghostty's spelling; same knob.
            cfg.scrollback = parseSize(val) orelse blk: {
                std.debug.print("rook config: bad scrollback '{s}' (bytes, or 10mb / 512kb)\n", .{val});
                break :blk cfg.scrollback;
            };
            // 0 means "no scrollback at all" and is a real answer. A
            // gigabyte is not; it's a typo with a unit attached.
            if (cfg.scrollback > 1024 * 1024 * 1024) {
                std.debug.print("rook config: scrollback {d} over the 1gb ceiling, using 1gb\n", .{cfg.scrollback});
                cfg.scrollback = 1024 * 1024 * 1024;
            }
        } else if (std.mem.eql(u8, key, "clipboard_write")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.clipboard_write = clipboardWriteFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown clipboard-write '{s}' (allow, deny)\n", .{stripped});
                break :blk .allow;
            };
        } else if (std.mem.eql(u8, key, "buffer_line")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.buffer_line = bufferLineFromName(stripped) orelse blk: {
                std.debug.print("rook config: bad buffer-line '{s}' (true, false, always)\n", .{stripped});
                break :blk cfg.buffer_line;
            };
        } else if (std.mem.eql(u8, key, "cursor_blink") or
            std.mem.eql(u8, key, "cursor_style_blink"))
        {
            // `cursor-style-blink` is ghostty's spelling; same knob.
            const stripped = std.mem.trim(u8, val, "\"");
            if (std.mem.eql(u8, stripped, "true")) {
                cfg.cursor_blink = true;
            } else if (std.mem.eql(u8, stripped, "false")) {
                cfg.cursor_blink = false;
            } else std.debug.print("rook config: bad cursor-blink '{s}' (true, false)\n", .{stripped});
        } else if (std.mem.eql(u8, key, "background_blur")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.background_blur = blurFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown background-blur '{s}' (none, blur, glass, glass-clear)\n", .{stripped});
                break :blk .none;
            };
        } else if (std.mem.eql(u8, key, "top_bar")) {
            cfg.top_bar = parseSegList(val) orelse cfg.top_bar;
        } else if (std.mem.eql(u8, key, "status_left")) {
            cfg.status_left = parseSegList(val) orelse cfg.status_left;
        } else if (std.mem.eql(u8, key, "status_right")) {
            cfg.status_right = parseSegList(val) orelse cfg.status_right;
        } else if (std.mem.eql(u8, key, "nav_yield")) {
            cfg.nav_yield = parseNameList(val);
        } else if (std.mem.eql(u8, key, "tab_style")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.tab_style = tabStyleFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown tab-style '{s}' (chips, index-name, current)\n", .{stripped});
                break :blk cfg.tab_style;
            };
        } else if (std.mem.eql(u8, key, "editor_mode")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (std.mem.eql(u8, stripped, "insert")) {
                cfg.editor_insert = true;
            } else if (std.mem.eql(u8, stripped, "normal")) {
                cfg.editor_insert = false;
            } else std.debug.print("rook config: unknown editor-mode '{s}' (normal, insert)\n", .{stripped});
        } else if (std.mem.eql(u8, key, "editor_lsp") or std.mem.eql(u8, key, "lsp")) {
            // `lsp` was this knob's first name, and it is the one name in
            // this file we could not have: the HOST's language-server
            // config is the [lsp] TABLE, and TOML lets a name be a scalar
            // or a table, never both. A file carrying both failed to parse
            // for the host, which fails open — so our boolean silently
            // cost the user every host setting in the file. The old
            // spelling is still honoured (files outlive renames, and the
            // host now steps over it); the notice is how it gets fixed.
            if (std.mem.eql(u8, key, "lsp"))
                std.debug.print("rook config: `lsp` is now `editor-lsp` — [lsp] is the host's own table\n", .{});
            const stripped = std.mem.trim(u8, val, "\"");
            if (std.mem.eql(u8, stripped, "true")) {
                cfg.lsp = true;
            } else if (std.mem.eql(u8, stripped, "false")) {
                cfg.lsp = false;
            } else std.debug.print("rook config: unknown editor-lsp '{s}' (true, false)\n", .{stripped});
        } else if (std.mem.eql(u8, key, "explorer_auto")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (std.mem.eql(u8, stripped, "true")) {
                cfg.explorer_auto = true;
            } else if (std.mem.eql(u8, stripped, "false")) {
                cfg.explorer_auto = false;
            } else std.debug.print("rook config: bad explorer-auto '{s}' (true, false)\n", .{stripped});
        } else if (std.mem.eql(u8, key, "activity_bar")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (std.mem.eql(u8, stripped, "true")) {
                cfg.activity_bar = true;
            } else if (std.mem.eql(u8, stripped, "false")) {
                cfg.activity_bar = false;
            } else std.debug.print("rook config: bad activity-bar '{s}' (true, false)\n", .{stripped});
        }
        // `preset` was handled by the pre-scan above.
        // No else: unknown top-level keys are the host's. See the header.
    }

    if (cfg.font_size < 6 or cfg.font_size > 72) {
        std.debug.print("rook config: font-size {d} out of range, using 13\n", .{cfg.font_size});
        cfg.font_size = 13;
    }
    return cfg;
}

// ---- the environment graph ----
//
// docs/environments/IR.md. Fail open everywhere, the host-protocol-
// skew discipline: an unknown kind, an unknown key, a wrong value type
// are each skipped in silence — old apps must survive new graphs. Only
// a file that EXISTS but cannot parse warns, because that is a broken
// apply, not a foreign key.

const WireNode = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    scope: []const u8 = "",
    key: []const u8 = "",
    value: std.json.Value = .null,
    chord: []const u8 = "",
    command: []const u8 = "",
    name: []const u8 = "",
    entries: std.json.Value = .null,
};
const WireEnv = struct {
    rookEnvironment: i64 = 0,
    nodes: []WireNode = &.{},
};

/// The raw environment.json bytes. Exported because plugins.zig reads the
/// same file for its own node kind — one file, two consumers, and neither
/// should own the other's parse.
pub fn envData(io: std.Io, gpa: std.mem.Allocator) ?[]u8 {
    var pathbuf: [1024]u8 = undefined;
    const path = envPath(&pathbuf) orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

fn jStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
fn jNum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}
fn jBool(v: std.json.Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// One app option off the graph. Key names are config.toml's, dashes
/// or underscores; a wrong value TYPE leaves the default rather than
/// guessing (the graph is machine-emitted — a type mismatch is a
/// version skew to survive, not a typo to correct).
fn applyEnvOption(cfg: *Config, gpa: std.mem.Allocator, key_raw: []const u8, value: std.json.Value) void {
    var keybuf: [64]u8 = undefined;
    if (key_raw.len > keybuf.len) return;
    for (key_raw, 0..) |c, i| keybuf[i] = if (c == '-') '_' else c;
    const key = keybuf[0..key_raw.len];

    if (std.mem.eql(u8, key, "font_size")) {
        cfg.font_size = jNum(value) orelse cfg.font_size;
    } else if (std.mem.eql(u8, key, "font_family")) {
        if (jStr(value)) |s| {
            if (s.len > 0) cfg.font_family = gpa.dupeZ(u8, s) catch cfg.font_family;
        }
    } else if (std.mem.eql(u8, key, "theme")) {
        if (jStr(value)) |s| {
            if (s.len > 0) cfg.theme = gpa.dupe(u8, s) catch cfg.theme;
        }
    } else if (std.mem.eql(u8, key, "background_opacity")) {
        cfg.background_opacity = jNum(value) orelse cfg.background_opacity;
        if (cfg.background_opacity < 0.3 or cfg.background_opacity > 1.0) cfg.background_opacity = 1.0;
    } else if (std.mem.eql(u8, key, "background_blur")) {
        if (jStr(value)) |s| cfg.background_blur = blurFromName(s) orelse cfg.background_blur;
    } else if (std.mem.eql(u8, key, "window_padding") or
        std.mem.eql(u8, key, "window_padding_x") or
        std.mem.eql(u8, key, "window_padding_y"))
    {
        cfg.window_padding = jNum(value) orelse cfg.window_padding;
        if (cfg.window_padding < 0 or cfg.window_padding > 32) cfg.window_padding = 0;
    } else if (std.mem.eql(u8, key, "bell")) {
        if (jStr(value)) |s| cfg.bell = bellFromName(s) orelse cfg.bell;
    } else if (std.mem.eql(u8, key, "scrollback") or std.mem.eql(u8, key, "scrollback_limit")) {
        cfg.scrollback = switch (value) {
            .integer => |i| if (i >= 0) @intCast(i) else cfg.scrollback,
            .string => |s| parseSize(s) orelse cfg.scrollback,
            else => cfg.scrollback,
        };
        if (cfg.scrollback > 1024 * 1024 * 1024) cfg.scrollback = 1024 * 1024 * 1024;
    } else if (std.mem.eql(u8, key, "clipboard_write")) {
        cfg.clipboard_write = switch (value) {
            .string => |s| clipboardWriteFromName(s) orelse cfg.clipboard_write,
            .bool => |b| if (b) .allow else .deny,
            else => cfg.clipboard_write,
        };
    } else if (std.mem.eql(u8, key, "buffer_line")) {
        // A graph carries the bool spellings too — an SDK's
        // BufferLine(true) is the same knob as BufferLine("always").
        cfg.buffer_line = switch (value) {
            .bool => |b| if (b) .multiple else .off,
            .string => |s| bufferLineFromName(s) orelse cfg.buffer_line,
            else => cfg.buffer_line,
        };
    } else if (std.mem.eql(u8, key, "cursor_blink") or std.mem.eql(u8, key, "cursor_style_blink")) {
        cfg.cursor_blink = jBool(value) orelse cfg.cursor_blink;
    } else if (std.mem.eql(u8, key, "editor_mode")) {
        if (jStr(value)) |s| {
            if (std.mem.eql(u8, s, "insert")) {
                cfg.editor_insert = true;
            } else if (std.mem.eql(u8, s, "normal")) cfg.editor_insert = false;
        }
    } else if (std.mem.eql(u8, key, "activity_bar")) {
        cfg.activity_bar = jBool(value) orelse cfg.activity_bar;
    } else if (std.mem.eql(u8, key, "explorer_auto")) {
        cfg.explorer_auto = jBool(value) orelse cfg.explorer_auto;
    } else if (std.mem.eql(u8, key, "editor_lsp") or std.mem.eql(u8, key, "lsp")) {
        // Both spellings, no notice: the graph is machine-written, so
        // there is no line for a human to go and fix.
        cfg.lsp = jBool(value) orelse cfg.lsp;
    } else if (std.mem.eql(u8, key, "top_bar")) {
        cfg.top_bar = jSegList(value) orelse cfg.top_bar;
    } else if (std.mem.eql(u8, key, "status_left")) {
        cfg.status_left = jSegList(value) orelse cfg.status_left;
    } else if (std.mem.eql(u8, key, "status_right")) {
        cfg.status_right = jSegList(value) orelse cfg.status_right;
    } else if (std.mem.eql(u8, key, "tab_style")) {
        if (jStr(value)) |s| cfg.tab_style = tabStyleFromName(s) orelse cfg.tab_style;
    }
    // No else: an unknown key belongs to a newer graph. Fail open.
    // (`preset` is handled by loadEnv's pre-pass, same reason as
    // TOML's pre-scan: the bundle must never shadow an explicit key.)
}

/// An array-of-strings option value into a SegList; unknown names
/// skipped in silence (graphs are machine-emitted — see applyEnvOption
/// on type skew). A non-array is a type mismatch: keep the default.
fn jSegList(v: std.json.Value) ?SegList {
    const arr = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    var out = SegList{};
    for (arr) |item| {
        const name = jStr(item) orelse continue;
        const s = segFromName(name) orelse continue;
        if (out.n < out.items.len) {
            out.items[out.n] = s;
            out.n += 1;
        }
    }
    return out;
}

fn loadEnv(io: std.Io, gpa: std.mem.Allocator) ?Config {
    const data = envData(io, gpa) orelse return null;
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(WireEnv, gpa, data, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("rook environment: environment.json did not parse — falling back to config.toml\n", .{});
        return null;
    };
    defer parsed.deinit();

    var cfg: Config = .{};
    // The preset bundle first, whatever its node position — an SDK
    // expands presets at emit so this is rare in a graph, but a
    // hand-written one gets TOML's rule: explicit keys override.
    for (parsed.value.nodes) |n| {
        if (!std.mem.eql(u8, n.kind, "option")) continue;
        if (!std.mem.eql(u8, n.scope, "app")) continue;
        if (!std.mem.eql(u8, n.key, "preset")) continue;
        if (jStr(n.value)) |name| {
            if (!applyPreset(&cfg, name))
                std.debug.print("rook environment: unknown preset '{s}'\n", .{name});
        }
    }
    for (parsed.value.nodes) |n| {
        if (!std.mem.eql(u8, n.kind, "option")) continue;
        if (!std.mem.eql(u8, n.scope, "app")) continue;
        if (std.mem.eql(u8, n.key, "preset")) continue;
        applyEnvOption(&cfg, gpa, n.key, n.value);
    }
    if (cfg.font_size < 6 or cfg.font_size > 72) {
        std.debug.print("rook environment: font-size {d} out of range, using 13\n", .{cfg.font_size});
        cfg.font_size = 13;
    }
    return cfg;
}

/// Keybinds off the graph: defaults first (same defaults as the TOML
/// path — the graph, like config lines, REBINDS them), then leader
/// nodes and app-scope keybind nodes. Editor-scope keybind nodes ride
/// along untouched until configurable editor maps land.
fn loadKeybindsEnv(io: std.Io, gpa: std.mem.Allocator) ?Keybinds {
    const data = envData(io, gpa) orelse return null;
    defer gpa.free(data);
    // load() already warned about a file that won't parse; stay quiet.
    const parsed = std.json.parseFromSlice(WireEnv, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    var kb: Keybinds = .{};
    defaultBinds(&kb);
    for (parsed.value.nodes) |n| {
        if (std.mem.eql(u8, n.kind, "leader")) {
            if (std.mem.eql(u8, n.scope, "app")) {
                kb.leader = chordChar(n.key) orelse kb.leader;
            } else if (std.mem.eql(u8, n.scope, "editor")) {
                kb.ed_leader = chordChar(n.key) orelse kb.ed_leader;
            }
        } else if (std.mem.eql(u8, n.kind, "keybind") and std.mem.eql(u8, n.scope, "app")) {
            if (!std.mem.startsWith(u8, n.chord, "<leader>")) continue;
            const ch = chordChar(n.chord["<leader>".len..]) orelse continue;
            const spec = actionFromName(n.command) orelse continue;
            kb.bind(ch, spec);
        }
    }
    if (kb.n > 0 and kb.leader == null)
        std.debug.print("rook environment: chords defined but no leader set — they are unreachable\n", .{});
    return kb;
}

// ---- keybinds ----
//
// Same file. Leader chords, tmux-shaped: top-level `leader = "x"`, then
// a [keybinds] table of `"<leader>v" = "pane.split-right"` lines — the
// shape rook-host's config already uses. (`[app]` is the old rook
// keybinds.toml shape, still accepted so a pre-rename file keeps
// working.) Double-tap the leader to type it literally.
//
// Bindings name COMMANDS, and registry.zig is the list of them. A name
// rook does not implement yet is skipped in silence rather than warned
// about: the wails keymap has ~30 names to our registry's smaller set,
// and a config file listing them is correct rather than wrong — the
// commands arrive with their features. [editor] and its subtables
// belong to the editor scope and are parsed past.

// The names, the actions, and the aliases all live in registry.zig now:
// keybinds, the palette, and ctl must agree on what a command IS, and
// two tables drift. config depends on registry (never the reverse) so
// both stay leaf modules with their own test roots.
pub const registry = @import("registry.zig");
pub const Action = registry.Action;
pub const ActionSpec = registry.Spec;

const actionFromName = registry.specFromName;

pub const Bind = struct { ch: u8, action: Action, arg: u8 = 0 };

pub const Keybinds = struct {
    leader: ?u8 = null,
    /// The EDITOR's leader ([editor] scope — vim's maplocalleader to
    /// the app's mapleader). Fires only inside an editor pane; the
    /// editor's own key machine arms and resolves it.
    ed_leader: ?u8 = null,
    entries: [32]Bind = undefined,
    n: usize = 0,

    pub fn lookup(self: *const Keybinds, ch: u8) ?Bind {
        for (self.entries[0..self.n]) |e| {
            if (e.ch == ch) return e;
        }
        return null;
    }

    /// Bind or rebind: a chord char holds one action (config lines
    /// replace defaults).
    fn bind(self: *Keybinds, ch: u8, spec: ActionSpec) void {
        for (self.entries[0..self.n]) |*e| {
            if (e.ch == ch) {
                e.* = .{ .ch = ch, .action = spec.action, .arg = spec.arg };
                return;
            }
        }
        if (self.n < self.entries.len) {
            self.entries[self.n] = .{ .ch = ch, .action = spec.action, .arg = spec.arg };
            self.n += 1;
        }
    }
};

/// Unquote a TOML basic string if quoted, resolving \" and \\.
/// Returns a slice into `buf`.
fn unquote(s: []const u8, buf: []u8) []const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return s;
    const inner = s[1 .. s.len - 1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and n < buf.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            buf[n] = switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                else => inner[i], // \" \\ and anything else: literal
            };
        } else buf[n] = inner[i];
        n += 1;
    }
    return buf[0..n];
}

/// A chord key: one char, or a named key (TAB, SPACE, ESC).
fn chordChar(s: []const u8) ?u8 {
    if (s.len == 1) return s[0];
    if (std.mem.eql(u8, s, "TAB")) return '\t';
    if (std.mem.eql(u8, s, "SPACE")) return ' ';
    if (std.mem.eql(u8, s, "ESC")) return 0x1b;
    return null;
}

/// Find the first top-level '=' (outside quotes) — keys like
/// "<leader>\"" contain quote-escaped content.
fn topLevelEq(line: []const u8) ?usize {
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quote and c == '\\') {
            i += 1;
            continue;
        }
        if (c == '"') in_quote = !in_quote;
        if (!in_quote and c == '=') return i;
    }
    return null;
}

pub fn loadKeybinds(io: std.Io, gpa: std.mem.Allocator) Keybinds {
    if (loadKeybindsEnv(io, gpa)) |kb| return kb;
    return loadKeybindsToml(io, gpa);
}

fn defaultBinds(kb: *Keybinds) void {
    // tmux's defaults: <leader>1–9 jump to tabs, <leader>[ enters copy
    // mode. Config lines rebind.
    for (1..10) |d| kb.bind(@intCast('0' + d), .{ .action = .tab_select, .arg = @intCast(d) });
    kb.bind('[', .{ .action = .copy_mode });
    // tmux: prefix-s = choose-session. Spaces are sessions, so the
    // workspace palette lives on s ('w' stays free for a future
    // choose-window/tab picker, also tmux's).
    kb.bind('s', .{ .action = .workspace_switch });
    // tmux: prefix-z = resize-pane -Z. Same key, same muscle memory.
    kb.bind('z', .{ .action = .pane_zoom });
    // Threads.
    // Review — the wails app's <leader>g (the Gate).
    // ...and the Diff the gate is about. Next to it on purpose: the list
    // of findings and the change they are about are one motion apart.
    // The file tree, in the focused pane. THE APP'S leader, on purpose:
    // the editor has its own leader (config [editor], a separate
    // namespace) and could never fire this from a terminal pane, which
    // is exactly where a takeover tree is most wanted.
    kb.bind('\t', .{ .action = .tree_toggle });
    // ...and opened on the current file (vim-vinegar's `-` energy, but
    // the whole tree, unfolded down to where you are).
    kb.bind('o', .{ .action = .tree_reveal });
}

fn loadKeybindsToml(io: std.Io, gpa: std.mem.Allocator) Keybinds {
    var kb: Keybinds = .{};
    defaultBinds(&kb);

    var pathbuf: [1024]u8 = undefined;
    const path = cfgPath(&pathbuf) orelse return kb;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return kb;
    defer gpa.free(data);

    // `none` is the top level, where `leader` lives. The editor's own
    // leader (vim's maplocalleader to the app's mapleader) sits under
    // [editor] — a separate scope on purpose, and the two must never be
    // mistaken for each other.
    var section: enum { none, app, editor, other } = .none;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = if (std.mem.eql(u8, line, "[keybinds]") or std.mem.eql(u8, line, "[app]"))
                .app
            else if (std.mem.eql(u8, line, "[editor]"))
                .editor
            else
                .other;
            continue;
        }
        if (section == .other) continue;

        const eq = topLevelEq(line) orelse continue;
        var keybuf: [64]u8 = undefined;
        var valbuf: [64]u8 = undefined;
        const key = unquote(std.mem.trim(u8, line[0..eq], " \t"), &keybuf);
        const val = stripComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        const value = unquote(val, &valbuf);

        if (section == .editor) {
            // Only the leader for now; [editor.keybinds.*] arrives with
            // configurable editor maps.
            if (std.mem.eql(u8, key, "leader")) {
                kb.ed_leader = chordChar(value) orelse blk: {
                    std.debug.print("rook keybinds: editor leader must be one key, got '{s}'\n", .{value});
                    break :blk null;
                };
            }
            continue;
        }
        if (std.mem.eql(u8, key, "leader")) {
            kb.leader = chordChar(value) orelse blk: {
                std.debug.print("rook keybinds: leader must be one key, got '{s}'\n", .{value});
                break :blk null;
            };
        } else if (section == .app and std.mem.startsWith(u8, key, "<leader>")) {
            // An unsupported chord shape or an action we haven't built
            // yet: skip it. See the header — this file names commands
            // rook does not have, and that is not an error.
            const ch = chordChar(key["<leader>".len..]) orelse continue;
            const spec = actionFromName(value) orelse continue;
            kb.bind(ch, spec);
        }
    }

    if (kb.n > 0 and kb.leader == null)
        std.debug.print("rook keybinds: chords defined but no leader set — they are unreachable\n", .{});
    return kb;
}

// ---- tests ----
//
// The pure parsing rules get their own test root (build.zig), for the
// same reason paste.zig does: everything here fails SILENTLY by design
// — we are a guest in a shared file — so a broken rule shows up as a
// keybind that just doesn't work, with nothing on stderr to explain it.

test "stripComment: quoted value keeps its quotes, loses the comment" {
    const t = std.testing;
    try t.expectEqualStrings("\"tab.new\"", stripComment("\"tab.new\"  # carried over"));
    try t.expectEqualStrings("\"Nocturne\"", stripComment("\"Nocturne\""));
    // A # inside quotes is data.
    try t.expectEqualStrings("\"#ff00ff\"", stripComment("\"#ff00ff\" # a color"));
    // An escaped quote does not end the string.
    try t.expectEqualStrings("\"a\\\"b\"", stripComment("\"a\\\"b\" # x"));
}

test "stripComment: unquoted value" {
    const t = std.testing;
    try t.expectEqualStrings("0.9", stripComment("0.9 # eyeball it"));
    try t.expectEqualStrings("18", stripComment("18"));
    try t.expectEqualStrings("", stripComment("# only a comment"));
}

test "keybind values survive a trailing comment" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const v = unquote(stripComment("\"tab.new\"  # carried over from rookz"), &buf);
    try t.expectEqualStrings("tab.new", v);
    try t.expect(actionFromName(v).?.action == .tab_new);
}

test "actionFromName takes the registry's names and rookz's aliases" {
    const t = std.testing;
    try t.expect(actionFromName("session.new").?.action == .tab_new);
    try t.expect(actionFromName("app.split.vertical").?.action == .split_right);
    try t.expect(actionFromName("tab.select-3").?.arg == 3);
    // A registry command rook has not built yet: skipped, not an error.
    try t.expect(actionFromName("workspace.manager") == null);
}

test "parseSize takes bytes, units, and neither silently" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 1024), parseSize("1024"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10mb"));
    // Case, spacing and the short spellings are all the same value —
    // this is a number a person types, not a wire format.
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10MB"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10 mb"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10m"));
    try t.expectEqual(@as(?usize, 512 * 1024), parseSize("512kb"));
    try t.expectEqual(@as(?usize, 2 * 1024 * 1024 * 1024), parseSize("2gb"));
    // 0 is a real answer: no scrollback at all.
    try t.expectEqual(@as(?usize, 0), parseSize("0"));
    // TOML quotes are the config's, not the value's.
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("\"10mb\""));
    // Rejected, so the caller warns instead of taking a wrong number.
    try t.expect(parseSize("") == null);
    try t.expect(parseSize("mb") == null);
    try t.expect(parseSize("10tb") == null);
    try t.expect(parseSize("ten") == null);
    // Overflow must not wrap into a small, plausible-looking limit.
    try t.expect(parseSize("99999999999999999999gb") == null);
}

test "clipboard-write takes both the enum names and the booleans" {
    const t = std.testing;
    try t.expectEqual(ClipboardWrite.allow, clipboardWriteFromName("allow").?);
    try t.expectEqual(ClipboardWrite.deny, clipboardWriteFromName("deny").?);
    // TOML users reach for a bare bool for a yes/no knob; both spellings
    // mean the same thing, and only a real typo warns.
    try t.expectEqual(ClipboardWrite.allow, clipboardWriteFromName("true").?);
    try t.expectEqual(ClipboardWrite.deny, clipboardWriteFromName("false").?);
    try t.expect(clipboardWriteFromName("ask") == null);
}

test "parseSegList: brackets, quotes, order kept, typos skipped" {
    const t = std.testing;
    const l = parseSegList("[\"tabs\", \"hud\"]").?;
    try t.expectEqual(@as(usize, 2), l.n);
    try t.expect(l.items[0] == .tabs and l.items[1] == .hud);
    // Empty is an ANSWER (hide the bar), not a parse failure.
    try t.expectEqual(@as(usize, 0), parseSegList("[]").?.n);
    // A typo resolves to null (parseSegList then warns and skips it —
    // not exercised here: the build's test runner reads any stderr as
    // a failure, the transcript suite's own known quirk).
    try t.expect(segFromName("bogus") == null);
    try t.expect(segFromName("cwd") == .cwd);
}

test "parseNameList: brackets, quotes, and an empty list that means it" {
    const t = std.testing;
    const l = parseNameList("[\"vim\", \"nvim\"]");
    try t.expectEqual(@as(usize, 2), l.n);
    try t.expect(l.has("vim") and l.has("nvim"));
    // Substrings must not match: `vi` is in the default list and `vim`
    // starts with it, so a prefix test here would yield to everything.
    try t.expect(!l.has("vi"));
    try t.expect(!l.has("v"));
    // Yield to nobody — a real setting, and the one a person reaches
    // for when they want ⌃HJKL to mean panes everywhere, always.
    try t.expectEqual(@as(usize, 0), parseNameList("[]").n);
    // A bare comma list, same as the segment lists accept.
    try t.expectEqual(@as(usize, 2), parseNameList("vim, tmux").n);
}

test "nav-yield defaults to the programs that own their own splits" {
    const t = std.testing;
    const d = (Config{}).nav_yield;
    try t.expect(d.has("vim") and d.has("nvim") and d.has("tmux"));
    // The regression this whole change exists for: Claude Code draws
    // full-screen but has no splits, so ⌃HJKL is rook's.
    try t.expect(!d.has("claude"));
    try t.expect(!d.has("bash") and !d.has("zsh"));
}

test "presets are the bundles the parity scenario pins" {
    const t = std.testing;
    var vs: Config = .{};
    try t.expect(applyPreset(&vs, "vscode"));
    try t.expect(vs.top_bar.n == 0);
    try t.expect(vs.tab_style == .current);
    try t.expect(vs.buffer_line == .always);
    try t.expect(vs.status_left.eql(&segs(.{ .tabs, .branch })));
    try t.expect(vs.status_right.eql(&segs(.{ .cwd, .hints })));
    try t.expect(std.mem.eql(u8, vs.theme, "vscode-dark"));
    try t.expect(vs.editor_insert);
    try t.expect(vs.activity_bar);
    try t.expect(vs.explorer_auto);

    var tm: Config = .{};
    try t.expect(applyPreset(&tm, "tmux-neovim"));
    try t.expect(tm.top_bar.n == 0);
    try t.expect(tm.tab_style == .index_name);
    try t.expect(tm.buffer_line == .off);
    try t.expect(tm.status_left.eql(&segs(.{.tabs})));
    try t.expect(tm.status_right.eql(&segs(.{ .workspace, .branch, .cwd })));
    try t.expect(!tm.editor_insert and !tm.activity_bar and !tm.explorer_auto);

    // The no-op identity, and the refusal.
    var rk: Config = .{};
    try t.expect(applyPreset(&rk, "rook"));
    try t.expect(rk.top_bar.eql(&(Config{}).top_bar));
    try t.expect(!applyPreset(&rk, "emacs"));
}

test "topLevelEq ignores '=' inside a quoted key" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 7), topLevelEq("leader = \"`\""));
    // The key is "<leader>\"" — the escaped quote must not end it.
    const line = "\"<leader>\\\"\" = \"app.split.horizontal\"";
    const eq = topLevelEq(line).?;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("<leader>\"", unquote(std.mem.trim(u8, line[0..eq], " \t"), &buf));
}

test "editor-lsp is the name; `lsp` still answers to it" {
    const t = std.testing;
    // One file, two readers, and this is the name they collided on: the
    // host's language-server config is the [lsp] TABLE, and TOML lets a
    // name be a scalar or a table and never both — so the app's boolean
    // had to move rather than the host's table. Old files outlive the
    // rename, so the old spelling still lands on the same field.
    var cfg: Config = .{};
    try t.expect(cfg.lsp); // on by default, and lazy

    applyEnvOption(&cfg, t.allocator, "editor-lsp", .{ .bool = false });
    try t.expect(!cfg.lsp);
    applyEnvOption(&cfg, t.allocator, "editor_lsp", .{ .bool = true });
    try t.expect(cfg.lsp);

    applyEnvOption(&cfg, t.allocator, "lsp", .{ .bool = false });
    try t.expect(!cfg.lsp);

    // A wrong value TYPE leaves what was there — the graph is emitted,
    // so a mismatch is version skew to survive, not a typo to correct.
    applyEnvOption(&cfg, t.allocator, "editor-lsp", .{ .string = "true" });
    try t.expect(!cfg.lsp);
}
