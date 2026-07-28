//! AppKit + Metal shell for rookz. Pure Zig via zig-objc — no Swift, no nib.
//! The window owns a CAMetalLayer; a CVDisplayLink drives rendering off the
//! main thread (ghostty's renderer-thread shape). The frame is a SCENE:
//! a binary split tree of panes (pty → ghostty-vt → RenderState each),
//! drawn as N grid regions + separator rects from one pipeline.
//!
//! Threading: draw_lock serializes every scene reader/mutator — display
//! link, input kick, key monitor, resize observer, ctl socket. Lock
//! order is always draw_lock → session mutex, and the reader thread
//! never holds its session mutex when it takes draw_lock (via kick).

const std = @import("std");
const objc = @import("objc");
const vt = @import("ghostty-vt");
const sessionpkg = @import("session.zig");
const renderpkg = @import("render.zig");
const panespkg = @import("panes.zig");
const editorpkg = @import("editor.zig");
const themepkg = @import("theme.zig");
const stats = @import("stats.zig");

extern "c" fn CACurrentMediaTime() f64;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

extern "c" fn MTLCreateSystemDefaultDevice() objc.c.id;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
const PROC_PIDVNODEPATHINFO: c_int = 9;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn _exit(code: c_int) noreturn;

// libdispatch, for hopping to the main thread from the ctl socket.
// dispatch_get_main_queue() is a macro for &_dispatch_main_q.
extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

// CVDisplayLink (CoreVideo). Deprecated in recent macOS but present and the
// simplest C-callable frame clock; swap for CAMetalDisplayLink later.
const CVDisplayLinkRef = ?*anyopaque;
extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(out: *CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, cb: *const fn (CVDisplayLinkRef, ?*const anyopaque, ?*const anyopaque, u64, ?*u64, ?*anyopaque) callconv(.c) i32, ctx: ?*anyopaque) i32;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkGetActualOutputVideoRefreshPeriod(link: CVDisplayLinkRef) f64;

const NSEventMaskKeyDown: u64 = 1 << 10;
const NSEventMaskLeftMouseDown: u64 = 1 << 1;
const NSEventMaskLeftMouseUp: u64 = 1 << 2;
const NSEventMaskLeftMouseDragged: u64 = 1 << 6;
const NSEventMaskScrollWheel: u64 = 1 << 22;
const flag_shift: u64 = 1 << 17;
const flag_ctrl: u64 = 1 << 18;
const flag_cmd: u64 = 1 << 20;

const win_w: f64 = 1024;
const win_h: f64 = 700;

/// The active theme (theme.zig builtins, picked by config). Set once
/// in App.create before any session or draw exists; read everywhere.
var th: themepkg.Theme = themepkg.default;

fn rgb3(c: [3]u8) vt.color.RGB {
    return .{ .r = c[0], .g = c[1], .b = c[2] };
}

fn rgb4(c: [4]u8) vt.color.RGB {
    return .{ .r = c[0], .g = c[1], .b = c[2] };
}

/// The emulator default colors for new sessions under this theme.
fn termColors() vt.Terminal.Colors {
    if (!th.override_term) return .default;
    var pal = vt.color.default;
    for (th.ansi, 0..) |c, i| pal[i] = rgb3(c);
    return .{
        .background = .init(rgb3(th.term_bg)),
        .foreground = .init(rgb3(th.term_fg)),
        .cursor = .init(rgb3(th.cursor)),
        .palette = .init(pal),
    };
}

fn nsString(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

const MonitorBlock = objc.Block(struct { app: *App }, .{objc.c.id}, objc.c.id);
const ResizeBlock = objc.Block(struct { app: *App }, .{objc.c.id}, void);
const PresentedBlock = objc.Block(struct { app: *App, dirty: u8, commit_t: f64 }, .{objc.c.id}, void);
const CompletedBlock = objc.Block(struct { app: *App }, .{objc.c.id}, void);

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: objc.Object,
    window: objc.Object,
    layer: objc.Object,
    device: objc.Object,
    queue: objc.Object,
    renderer: renderpkg.Renderer,
    shell: [*:0]const u8,
    keybinds: @import("config.zig").Keybinds,

    /// Leader chord armed: the next key resolves a binding (or the
    /// leader again types it literally). Shown in the bar while armed.
    leader_pending: std.atomic.Value(bool) = .init(false),

    // The scene: tabs of split trees. Mutated only under draw_lock.
    tabs: std.ArrayListUnmanaged(*panespkg.Tab) = .empty,
    active_tab: usize = 0,
    next_pane_id: u32 = 2,
    next_tab_id: u32 = 2,
    px_w: f32,
    px_h: f32,
    sep: f32 = 2,
    /// Status bar height in px; panes tile the content area above it.
    bar_h: f32,
    /// Top tab bar height in px — tabs are first-class chrome (wails
    /// rook's named tabs), not a corner of the status bar.
    tab_h: f32,
    /// Layout/focus changed: the next frame redraws even if no pane's
    /// grid is dirty.
    scene_dirty: bool = true,

    // Status-bar HUD text, recomputed at ~2Hz on the display-link tick;
    // a change flips scene_dirty, so an idle app with stable numbers
    // still draws ZERO frames (the scoreboard's idle row).
    hud_left: [96]u8 = undefined,
    hud_left_len: usize = 0,
    hud_right: [96]u8 = undefined,
    hud_right_len: usize = 0,
    /// Digest of all tab titles — OSC title changes don't dirty the
    /// grid, so the 2Hz refresh detects them here and redraws chips.
    hud_tabs: [160]u8 = undefined,
    hud_tabs_len: usize = 0,
    hud_last_t: f64 = 0,
    hud_last_bytes: u64 = 0,
    hud_mbs: f64 = 0,

    // fps truth: the display link's refresh period is the ceiling the
    // HUD shows optimistically; it dips only when measured FRAME COST
    // exceeds the vsync budget (capability, not demand — dirty-skip
    // gaps must never read as lag).
    link: CVDisplayLinkRef = null,
    display_period_us: f64 = 0,

    /// Focused pane's session, readable without draw_lock (the input
    /// kick compares pointers only — never dereferences).
    focused_session: std.atomic.Value(?*sessionpkg.Session) = .init(null),

    frame_count: std.atomic.Value(u64) = .init(0),
    activate: bool = true,
    pending_w: f64 = 0,
    pending_h: f64 = 0,

    /// Pending keystroke timestamp (CACurrentMediaTime clock; NSEvent
    /// timestamps share it). Consumed by the presented handler of the
    /// first frame after the mark that carried the FOCUSED pane's echo.
    input_mark: std.atomic.Value(f64) = .init(0),
    last_presented: std.atomic.Value(f64) = .init(0),

    /// Serializes scene access across display link, input kick, keys,
    /// resize, and ctl. See the file comment for lock order.
    draw_lock: sessionpkg.Lock = .{},

    /// proc_pidinfo(PROC_PIDVNODEPATHINFO) scratch: 2 × (152-byte
    /// vnode_info + 1024-byte path). Written under draw_lock.
    cwd_info: [2352]u8 = undefined,

    /// Tab-chip x extents (px) recorded by drawTabBar for click hit
    /// tests. Written/read under draw_lock.
    chip_x: [16][2]f32 = undefined,
    chip_n: usize = 0,

    /// Wheel accumulator (points); one scroll step per cell height.
    wheel_accum: f64 = 0,

    /// Active mouse-drag selection: the pane and its anchor cell
    /// (viewport coords at mousedown). Under draw_lock; cleared by
    /// reap if the pane dies mid-drag.
    drag_pane: ?*panespkg.Pane = null,
    drag_anchor: [2]u16 = .{ 0, 0 },

    // ctl `shot` handoff: the socket thread stores a path and flips the
    // flag; the render thread services it after the next commit.
    shot_state: std.atomic.Value(u8) = .init(0),
    shot_path: [1024]u8 = undefined,
    shot_len: usize = 0,

    pub fn markInput(self: *App, t: f64) void {
        self.input_mark.store(t, .release);
    }

    fn drawNow(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.drawFrame();
    }

    pub fn requestShot(self: *App, path: []const u8) bool {
        if (path.len == 0 or path.len > self.shot_path.len) return false;
        if (self.shot_state.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) return false;
        @memcpy(self.shot_path[0..path.len], path);
        self.shot_len = path.len;
        self.shot_state.store(2, .release); // armed
        return true;
    }

    pub fn shotPending(self: *App) bool {
        return self.shot_state.load(.acquire) != 0;
    }

    pub fn create(init: std.process.Init) !*App {
        const gpa = init.gpa;
        const cfg = @import("config.zig").load(init.io, gpa);
        const keybinds = @import("config.zig").loadKeybinds(init.io, gpa);
        if (themepkg.byName(cfg.theme)) |t| {
            th = t.*;
        } else std.debug.print("rookz config: unknown theme '{s}' (builtin: default, nocturne)\n", .{cfg.theme});

        const NSApplication = objc.getClass("NSApplication").?;
        const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
        // NSApplicationActivationPolicyRegular = 0: real app with Dock icon.
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        const device_id = MTLCreateSystemDefaultDevice();
        if (device_id == null) return error.NoMetalDevice;
        const device = objc.Object.fromId(device_id);
        const queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        const layer = objc.getClass("CAMetalLayer").?.msgSend(objc.Object, "layer", .{});
        layer.msgSend(void, "setDevice:", .{device.value});
        // MTLPixelFormatBGRA8Unorm = 80
        layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
        // Double- not triple-buffer: one whole frame less key-to-photon.
        layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 2)});
        // false so the ctl `shot` command can read our own drawable back —
        // dev-tool visibility outranks the marginal framebufferOnly win.
        layer.msgSend(void, "setFramebufferOnly:", .{false});
        // Opaque is a hard requirement for direct-to-display scan-out —
        // a non-opaque layer always goes through the compositor. The
        // present_lag ring is the detector: ~12ms composited, ~4ms direct.
        layer.msgSend(void, "setOpaque:", .{true});

        const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = win_w, .height = win_h } };
        // titled | closable | miniaturizable | resizable = 15
        const style: u64 = 15;
        const window = objc.getClass("NSWindow").?
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(u64, 2), false });
        window.msgSend(void, "setTitle:", .{nsString("rookz")});
        window.msgSend(void, "center", .{});
        window.msgSend(void, "setReleasedWhenClosed:", .{false});

        const view = objc.getClass("NSView").?
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{rect});
        view.msgSend(void, "setWantsLayer:", .{true});
        view.msgSend(void, "setLayer:", .{layer.value});
        view.msgSend(void, "setPostsFrameChangedNotifications:", .{true});
        window.msgSend(void, "setContentView:", .{view.value});

        // Retina: drawable size in pixels, not points.
        const scale = window.msgSend(f64, "backingScaleFactor", .{});
        layer.msgSend(void, "setContentsScale:", .{scale});
        const px_w = win_w * scale;
        const px_h = win_h * scale;
        layer.msgSend(void, "setDrawableSize:", .{NSSize{ .width = px_w, .height = px_h }});

        // Nerd Font base (default) so prompt icons resolve without
        // fallback; the CoreText cascade catches everything else.
        const renderer = try renderpkg.Renderer.init(gpa, device, cfg.font_family, cfg.font_size * scale, 64 * 1024);
        const bar_h: f32 = @ceil(renderer.cell_h + @as(f32, @floatCast(8 * scale)));
        const cols: u16 = @intFromFloat(@divFloor(@as(f32, @floatCast(px_w)), renderer.cell_w));
        const rows: u16 = @intFromFloat(@max(2, @divFloor(@as(f32, @floatCast(px_h)) - bar_h * 2, renderer.cell_h)));

        const shell = getenv("SHELL") orelse "/bin/zsh";
        const session = try sessionpkg.Session.start(gpa, init.io, shell, null, termColors(), @intCast(cols), @intCast(rows), @intCast(renderer.cellw_px), @intCast(renderer.cellh_px));

        const self = try gpa.create(App);
        const pane = try gpa.create(panespkg.Pane);
        pane.* = .{ .id = 1, .content = .{ .term = .{ .session = session } }, .cols = cols, .rows = rows };
        session.kick = &inputKick;
        session.kick_ctx = self;
        const tab_one = try gpa.create(panespkg.Tab);
        tab_one.* = .{ .id = 1, .root = .{ .leaf = pane }, .focused = pane };
        try tab_one.panes.append(gpa, pane);
        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .app = app,
            .window = window,
            .layer = layer,
            .device = device,
            .queue = queue,
            .renderer = renderer,
            .shell = shell,
            .keybinds = keybinds,
            .px_w = @floatCast(px_w),
            .px_h = @floatCast(px_h),
            .sep = @floatCast(@max(1.0, @round(scale))),
            .bar_h = bar_h,
            .tab_h = bar_h,
        };
        try self.tabs.append(gpa, tab_one);
        self.focused_session.store(session, .release);
        panespkg.layout(tab_one.root, .{ .x = 0, .y = self.tab_h, .w = self.px_w, .h = self.contentH() }, self.sep);
        return self;
    }

    pub fn run(self: *App) void {
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, null)});
        // --no-activate: probe/tooling launches must not steal focus.
        if (self.activate) self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        @import("ctl.zig").start(self) catch |err| {
            std.debug.print("rookz ctl: failed to start: {}\n", .{err});
        };

        // Keys → pty (Cmd+Q quits). AppKit copies the handler block, so the
        // stack context is fine here.
        var block_ctx = MonitorBlock.init(.{ .app = self }, &monitorCallback);
        const NSEvent = objc.getClass("NSEvent").?;
        _ = NSEvent.msgSend(objc.Object, "addLocalMonitorForEventsMatchingMask:handler:", .{
            NSEventMaskKeyDown,
            &block_ctx,
        });

        // Mouse: click-to-focus (panes + tab chips), wheel scroll.
        var mouse_ctx = MonitorBlock.init(.{ .app = self }, &mouseCallback);
        _ = NSEvent.msgSend(objc.Object, "addLocalMonitorForEventsMatchingMask:handler:", .{
            NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                NSEventMaskLeftMouseDragged | NSEventMaskScrollWheel,
            &mouse_ctx,
        });

        // Resize: view frame changes retarget the drawable, the layout,
        // every pane's emulator (reflow) and pty. Runs on the main thread.
        var resize_ctx = ResizeBlock.init(.{ .app = self }, &resizeCallback);
        const center = objc.getClass("NSNotificationCenter").?
            .msgSend(objc.Object, "defaultCenter", .{});
        const view = self.window.msgSend(objc.Object, "contentView", .{});
        _ = center.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{
            nsString("NSViewFrameDidChangeNotification").value,
            view.value,
            @as(objc.c.id, null),
            &resize_ctx,
        });

        // Frame clock off the main thread.
        var link: CVDisplayLinkRef = null;
        _ = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        _ = CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, self);
        _ = CVDisplayLinkStart(link);
        self.link = link;

        self.app.msgSend(void, "run", .{});
    }

    /// ctl `winsize`: resize the window from any thread (points, not px).
    pub fn requestWinSize(self: *App, w: f64, h: f64) void {
        self.pending_w = w;
        self.pending_h = h;
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, &applyWinSize);
    }

    fn applyWinSize(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.window.msgSend(void, "setContentSize:", .{NSSize{ .width = self.pending_w, .height = self.pending_h }});
    }

    /// ctl `fullscreen`: toggle native fullscreen from any thread — the
    /// most reliable direct-to-display geometry.
    pub fn requestFullscreen(self: *App) void {
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, &applyFullscreen);
    }

    fn applyFullscreen(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.window.msgSend(void, "toggleFullScreen:", .{@as(objc.c.id, null)});
    }

    /// Main thread, on every content-view frame change.
    pub fn viewResized(self: *App) void {
        const view = self.window.msgSend(objc.Object, "contentView", .{});
        if (view.value == null) return;
        const bounds = view.msgSend(NSRect, "bounds", .{});
        const scale = self.window.msgSend(f64, "backingScaleFactor", .{});
        const px_w = bounds.size.width * scale;
        const px_h = bounds.size.height * scale;
        if (px_w < 1 or px_h < 1) return;

        // The drawable must track the view in PIXELS or CoreAnimation
        // scales the framebuffer to fit — the squished-glyph bug.
        self.layer.msgSend(void, "setContentsScale:", .{scale});
        self.layer.msgSend(void, "setDrawableSize:", .{NSSize{ .width = px_w, .height = px_h }});

        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.px_w = @floatCast(px_w);
        self.px_h = @floatCast(px_h);
        self.sep = @floatCast(@max(1.0, @round(scale)));
        self.bar_h = @ceil(self.renderer.cell_h + @as(f32, @floatCast(8 * scale)));
        self.tab_h = self.bar_h;
        self.relayoutLocked();
        self.scene_dirty = true;
    }

    /// Pane-area height: the window minus the tab bar and status bar.
    fn contentH(self: *App) f32 {
        return @max(1, self.px_h - self.bar_h - self.tab_h);
    }

    fn activeTab(self: *App) *panespkg.Tab {
        return self.tabs.items[self.active_tab];
    }

    /// A click in scene px coords: tab chips select, panes focus.
    /// Shared by the NSEvent monitor and ctl \`click\` (blind-testable).
    pub fn clickAt(self: *App, x: f32, y: f32) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (y < self.tab_h) {
            for (self.chip_x[0..self.chip_n], 0..) |cx, i| {
                if (x >= cx[0] and x <= cx[1]) {
                    self.activateTabLocked(i);
                    break;
                }
            }
            return;
        }
        const t = self.activeTab();
        for (t.panes.items) |p| {
            const r = p.rect;
            if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) {
                self.setFocusLocked(p);
                if (p.term()) |tm| {
                    // A fresh click clears the old selection and
                    // anchors a possible drag.
                    tm.session.clearSelection();
                    self.drag_pane = p;
                    self.drag_anchor = self.cellAt(p, x, y);
                }
                break;
            }
        }
    }

    fn cellAt(self: *App, p: *panespkg.Pane, x: f32, y: f32) [2]u16 {
        const cx: f32 = @max(0, (x - p.rect.x) / self.renderer.cell_w);
        const cy: f32 = @max(0, (y - p.rect.y) / self.renderer.cell_h);
        return .{
            @intCast(@min(@as(u32, @intFromFloat(cx)), p.cols - 1)),
            @intCast(@min(@as(u32, @intFromFloat(cy)), p.rows - 1)),
        };
    }

    /// Mouse drag: extend the selection from the anchor to the cell
    /// under the pointer.
    pub fn dragTo(self: *App, x: f32, y: f32) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const p = self.drag_pane orelse return;
        const tm = p.term() orelse return;
        const cur = self.cellAt(p, x, y);
        tm.session.setSelection(self.drag_anchor[0], self.drag_anchor[1], cur[0], cur[1]);
    }

    pub fn dragEnd(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.drag_pane = null;
    }

    /// ⌘C: focused terminal's selection (or editor's register) → the
    /// system pasteboard. Returns the copied text (caller frees) so
    /// ctl \`copy\` can verify without reading the pasteboard.
    pub fn copyFocused(self: *App) ?[]const u8 {
        self.draw_lock.lock();
        const text: ?[]const u8 = switch (self.activeTab().focused.content) {
            .term => |*tm| if (tm.session.selectionText(self.gpa)) |t| t[0..t.len] else null,
            .edit => |ed| blk: {
                // Visual selection yanks first; otherwise the last yank.
                if (ed.mode == .visual or ed.mode == .visual_line) ed.key("y");
                if (ed.reg.items.len == 0) break :blk null;
                break :blk self.gpa.dupe(u8, ed.reg.items) catch null;
            },
        };
        self.draw_lock.unlock();
        const t = text orelse return null;

        const pb = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        _ = pb.msgSend(i64, "clearContents", .{});
        // NSString from bytes (not NUL-terminated).
        const nss = objc.getClass("NSString").?.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithBytes:length:encoding:", .{
            @as(*const anyopaque, t.ptr),
            @as(u64, t.len),
            @as(u64, 4), // NSUTF8StringEncoding
        });
        _ = pb.msgSend(bool, "setString:forType:", .{ nss.value, nsString("public.utf8-plain-text").value });
        return t;
    }

    /// Wheel steps (+ = scroll up) routed to the pane under the point:
    /// editors move their viewport, alt-screen terminals get arrows,
    /// primary-screen terminal scrollback lands with the scrollback
    /// slice.
    pub fn wheelAt(self: *App, x: f32, y: f32, lines_in: i64) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        var lines = lines_in;
        const t = self.activeTab();
        for (t.panes.items) |p| {
            const r = p.rect;
            if (!(x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h)) continue;
            switch (p.content) {
                .edit => |ed| {
                    ed.scroll(-lines);
                    self.scene_dirty = true;
                },
                .term => |*tm| {
                    const alt = tm.session.term.screens.active_key == .alternate;
                    if (alt) {
                        // Alt-screen apps take arrows (vim/less).
                        const seq: []const u8 = if (lines > 0) "\x1b[A" else "\x1b[B";
                        if (lines < 0) lines = -lines;
                        var n: i64 = 0;
                        while (n < lines and n < 20) : (n += 1) tm.session.write(seq);
                    } else {
                        // Primary screen: scroll the viewport into
                        // history; typing snaps back.
                        tm.session.scrollViewport(@intCast(-lines));
                    }
                },
            }
            break;
        }
    }

    /// The focused pane's shell cwd via libproc — new tabs and splits
    /// open where you are, the tmux/wails behavior (TODO.md item one).
    /// Buffer-owned by App; valid until the next call.
    fn focusedCwd(self: *App) ?[*:0]const u8 {
        const tm = self.activeTab().focused.term() orelse return null;
        // struct proc_vnodepathinfo { vnode_info_path pvi_cdir; ... };
        // vip_path (MAXPATHLEN) sits after the 152-byte vnode_info.
        const n = proc_pidinfo(tm.session.pid, PROC_PIDVNODEPATHINFO, 0, &self.cwd_info, self.cwd_info.len);
        if (n <= 152) return null;
        const path: [*:0]const u8 = @ptrCast(self.cwd_info[152..]);
        if (path[0] != '/') return null;
        return path;
    }

    /// Spawn a shell session wrapped in a fresh pane. Caller inserts it
    /// into a tree and a tab (holding draw_lock — focusedCwd reads the
    /// focused pane).
    fn makePane(self: *App) !*panespkg.Pane {
        const session = try sessionpkg.Session.start(self.gpa, self.io, self.shell, self.focusedCwd(), termColors(), 80, 24, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px));
        session.kick = &inputKick;
        session.kick_ctx = self;
        const pane = try self.gpa.create(panespkg.Pane);
        pane.* = .{ .id = self.next_pane_id, .content = .{ .term = .{ .session = session } } };
        self.next_pane_id += 1;
        return pane;
    }

    /// The focused pane's session, or null when an editor holds focus.
    fn focusedTermSession(self: *App) ?*sessionpkg.Session {
        return if (self.activeTab().focused.term()) |t| t.session else null;
    }

    /// Open `path` in an editor: retarget a focused editor pane in
    /// place (the rook-buffers model), else split one off to the right.
    pub fn openEditor(self: *App, path: []const u8) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        if (t.focused.editor()) |ed| {
            ed.open(path, false) catch return false;
            self.scene_dirty = true;
            return true;
        }
        const ed = editorpkg.Editor.create(self.gpa, self.io, path) catch return false;
        const pane = self.gpa.create(panespkg.Pane) catch {
            ed.destroy();
            return false;
        };
        pane.* = .{ .id = self.next_pane_id, .content = .{ .edit = ed } };
        self.next_pane_id += 1;
        if (!panespkg.splitAt(self.gpa, &t.root, t.focused, pane, true)) {
            ed.destroy();
            self.gpa.destroy(pane);
            return false;
        }
        t.panes.append(self.gpa, pane) catch {};
        self.setFocusLocked(pane);
        self.relayoutLocked();
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
        return true;
    }

    /// Recompute the ACTIVE tab's pane rects and resize changed grids.
    /// Background tabs relayout on activation. Caller holds draw_lock.
    fn relayoutLocked(self: *App) void {
        const t = self.activeTab();
        panespkg.layout(t.root, .{ .x = 0, .y = self.tab_h, .w = self.px_w, .h = self.contentH() }, self.sep);
        for (t.panes.items) |p| {
            const cols: u16 = @intFromFloat(@max(2, @divFloor(p.rect.w, self.renderer.cell_w)));
            const rows: u16 = @intFromFloat(@max(2, @divFloor(p.rect.h, self.renderer.cell_h)));
            if (cols == p.cols and rows == p.rows) continue;
            p.cols = cols;
            p.rows = rows;
            switch (p.content) {
                .term => |*tm| tm.session.resize(cols, rows, @intCast(self.renderer.cellw_px), @intCast(self.renderer.cellh_px)),
                .edit => |ed| ed.render_dirty = true,
            }
        }
    }

    /// Split the focused pane; the new pane takes focus. Any thread.
    pub fn splitFocused(self: *App, horiz: bool) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const pane = self.makePane() catch |err| {
            std.debug.print("rookz: split failed: {}\n", .{err});
            return;
        };
        if (!panespkg.splitAt(self.gpa, &t.root, t.focused, pane, horiz)) {
            std.debug.print("rookz: split target missing\n", .{});
            return;
        }
        t.panes.append(self.gpa, pane) catch {};
        self.setFocusLocked(pane);
        self.relayoutLocked();
        // No synchronous draw: encoding from the calling thread contends
        // on nextDrawable (measured wedge from the ctl thread). The
        // display link sees scene_dirty within a tick.
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
    }

    /// Open a new tab with one fresh shell and activate it. Any thread.
    pub fn newTab(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const pane = self.makePane() catch |err| {
            std.debug.print("rookz: new tab failed: {}\n", .{err});
            return;
        };
        const t = self.gpa.create(panespkg.Tab) catch return;
        t.* = .{ .id = self.next_tab_id, .root = .{ .leaf = pane }, .focused = pane };
        self.next_tab_id += 1;
        t.panes.append(self.gpa, pane) catch {};
        self.tabs.append(self.gpa, t) catch return;
        self.activateTabLocked(self.tabs.items.len - 1);
    }

    /// Switch to tab index i (0-based). Any thread.
    pub fn selectTab(self: *App, i: usize) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (i >= self.tabs.items.len) return false;
        self.activateTabLocked(i);
        return true;
    }

    /// Cycle tabs by delta (±1). Any thread.
    pub fn cycleTab(self: *App, delta: i32) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const n: i64 = @intCast(self.tabs.items.len);
        const cur: i64 = @intCast(self.active_tab);
        self.activateTabLocked(@intCast(@mod(cur + delta, n)));
    }

    fn activateTabLocked(self: *App, i: usize) void {
        self.active_tab = i;
        self.focused_session.store(self.focusedTermSession(), .release);
        // The window may have resized while this tab was hidden.
        self.relayoutLocked();
        self.refreshHudLocked(CACurrentMediaTime());
        self.scene_dirty = true;
    }

    /// Route input to the focused pane under the scene lock: terminal
    /// bytes go to the pty, editor bytes drive the modal machine. Both
    /// mark input — the editor's echo is synchronous, so its dirty
    /// frame carries the key→photon mark the same way a pty echo does.
    pub fn writeFocused(self: *App, bytes: []const u8, ts: f64) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        self.markInput(ts);
        self.paneInput(self.activeTab().focused, bytes);
    }

    /// Route input into a pane: editors take the modal machine, a
    /// copy-mode terminal scrolls, a live terminal writes to the pty
    /// (and typing snaps a scrolled viewport back — every terminal's
    /// convention). ONE path for NSEvents and ctl. Caller holds
    /// draw_lock.
    pub fn paneInput(self: *App, p: *panespkg.Pane, bytes: []const u8) void {
        switch (p.content) {
            .term => |*t| {
                if (t.copy_mode) {
                    self.copyModeKey(t, bytes);
                    return;
                }
                t.session.write(bytes);
                t.session.scrollTo(.active);
            },
            .edit => |ed| ed.key(bytes),
        }
    }

    /// Enter tmux-style copy mode on the focused terminal pane.
    pub fn enterCopyMode(self: *App) void {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        if (self.activeTab().focused.term()) |tm| {
            tm.copy_mode = true;
            tm.copy_g = false;
            self.scene_dirty = true;
        }
    }

    /// Copy-mode keys: vim motions scroll the viewport; q/ESC/i/Enter
    /// snap back to the live screen and exit. Caller holds draw_lock.
    fn copyModeKey(self: *App, tm: *panespkg.Term, bytes: []const u8) void {
        const rows: isize = @intCast(@max(2, self.activeTab().focused.rows));
        for (bytes) |ch| {
            if (tm.copy_g and ch == 'g') {
                tm.copy_g = false;
                tm.session.scrollTo(.top);
                continue;
            }
            tm.copy_g = false;
            switch (ch) {
                'g' => tm.copy_g = true,
                'j' => tm.session.scrollViewport(1),
                'k' => tm.session.scrollViewport(-1),
                'd', 0x04 => tm.session.scrollViewport(@divTrunc(rows, 2)),
                'u', 0x15 => tm.session.scrollViewport(-@divTrunc(rows, 2)),
                'f', 0x06 => tm.session.scrollViewport(rows - 1),
                'b', 0x02 => tm.session.scrollViewport(-(rows - 1)),
                'G' => tm.session.scrollTo(.active),
                'q', 0x1b, 'i', '\r' => {
                    tm.copy_mode = false;
                    tm.session.scrollTo(.active);
                },
                else => {},
            }
        }
        self.scene_dirty = true;
    }

    /// Is the focused pane an editor? (Locked peek for the key path.)
    pub fn focusedIsEditor(self: *App) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        return self.activeTab().focused.editor() != null;
    }

    fn barDirty(self: *App) void {
        self.draw_lock.lock();
        self.scene_dirty = true;
        self.draw_lock.unlock();
    }

    fn dispatch(self: *App, b: @import("config.zig").Bind) void {
        switch (b.action) {
            .split_right => self.splitFocused(true),
            .split_down => self.splitFocused(false),
            .focus_left => _ = self.focusMove(.left),
            .focus_right => _ = self.focusMove(.right),
            .focus_up => _ = self.focusMove(.up),
            .focus_down => _ = self.focusMove(.down),
            .tab_new => self.newTab(),
            .tab_next => self.cycleTab(1),
            .tab_prev => self.cycleTab(-1),
            .tab_select => _ = self.selectTab(@as(usize, b.arg) - 1),
            .copy_mode => self.enterCopyMode(),
        }
    }

    /// The leader state machine — ONE path for real keystrokes (the
    /// event monitor) and ctl `press`, so chords are testable blind.
    /// Returns true if the key was consumed (armed a chord, resolved
    /// one, or was swallowed as an unknown chord).
    pub fn handleCharKey(self: *App, ch: u8, ts: f64) bool {
        const ld = self.keybinds.leader orelse return false;
        // An editor owns its keys — the app leader would swallow
        // literal backticks mid-edit. (Cmd chords still work above.)
        if (self.focusedIsEditor()) return false;
        if (self.leader_pending.swap(false, .acq_rel)) {
            self.barDirty();
            if (ch == ld) {
                // Double-tap: the leader typed literally.
                self.writeFocused(&[1]u8{ch}, ts);
                return true;
            }
            if (self.keybinds.lookup(ch)) |b| {
                self.dispatch(b);
                return true;
            }
            return true; // unknown chord: swallowed, tmux-style
        }
        if (ch == ld) {
            self.leader_pending.store(true, .release);
            self.barDirty();
            return true;
        }
        return false;
    }

    fn setFocusLocked(self: *App, pane: *panespkg.Pane) void {
        self.activeTab().focused = pane;
        self.focused_session.store(if (pane.term()) |t| t.session else null, .release);
        self.scene_dirty = true;
    }

    /// Move focus in a direction within the active tab. Any thread.
    /// Returns false if no pane lies that way.
    pub fn focusMove(self: *App, dir: panespkg.NavDir) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        const t = self.activeTab();
        const target = panespkg.navigate(t.panes.items, t.focused, dir) orelse return false;
        self.setFocusLocked(target);
        return true;
    }

    /// Focus a pane by id, switching tabs if it lives elsewhere.
    pub fn focusById(self: *App, id: u32) bool {
        self.draw_lock.lock();
        defer self.draw_lock.unlock();
        for (self.tabs.items, 0..) |t, ti| {
            for (t.panes.items) |p| {
                if (p.id == id) {
                    if (ti != self.active_tab) self.activateTabLocked(ti);
                    self.setFocusLocked(p);
                    return true;
                }
            }
        }
        return false;
    }

    /// Collapse panes whose shell exited — across ALL tabs (background
    /// shells exit too); an emptied tab closes, the last tab closing
    /// exits the app. Caller holds draw_lock; never runs on a reader
    /// thread (Session.deinit joins it).
    fn reapExitedLocked(self: *App) void {
        var changed = false;
        var ti: usize = 0;
        while (ti < self.tabs.items.len) {
            const t = self.tabs.items[ti];
            var i: usize = 0;
            while (i < t.panes.items.len) {
                const p = t.panes.items[i];
                const done = switch (p.content) {
                    .term => |*tm| tm.session.exited.load(.acquire),
                    .edit => |ed| ed.closed,
                };
                if (!done) {
                    i += 1;
                    continue;
                }
                changed = true;
                if (self.drag_pane == p) self.drag_pane = null;
                _ = panespkg.removeAt(self.gpa, &t.root, p);
                _ = t.panes.swapRemove(i);
                const was_focused = t.focused == p;
                switch (p.content) {
                    .term => |*tm| {
                        tm.session.deinit();
                        tm.rs.deinit(self.gpa);
                    },
                    .edit => |ed| ed.destroy(),
                }
                self.gpa.destroy(p);
                if (t.panes.items.len > 0 and was_focused) t.focused = t.panes.items[0];
            }
            if (t.panes.items.len == 0) {
                t.panes.deinit(self.gpa);
                self.gpa.destroy(t);
                _ = self.tabs.orderedRemove(ti);
                if (self.tabs.items.len == 0) {
                    // Last shell of the last tab: the terminal's work is done.
                    _exit(0);
                }
                if (self.active_tab >= self.tabs.items.len) self.active_tab = self.tabs.items.len - 1;
                continue;
            }
            ti += 1;
        }
        if (changed) {
            self.focused_session.store(self.focusedTermSession(), .release);
            self.relayoutLocked();
            self.refreshHudLocked(CACurrentMediaTime());
            self.scene_dirty = true;
        }
    }

    fn drawFrame(self: *App) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const tick = self.frame_count.fetchAdd(1, .monotonic);
        const t_start = CACurrentMediaTime();

        self.reapExitedLocked();

        // HUD refresh at ~2Hz. Runs on skipped ticks too, so the bar
        // stays live during idle — but only a text CHANGE causes a draw.
        if (tick % 60 == 0) self.refreshHudLocked(t_start);

        // Snapshot every ACTIVE-TAB pane under its session lock, with
        // priority over the readers' parse loops. Background tabs are
        // never snapshotted — their emulators advance, their render
        // work is zero. focused_dirty means the FOCUSED PANE'S GRID
        // changed — chrome/HUD-only frames must never consume the
        // key-to-photon mark (that skew was measured: a 2Hz HUD refresh
        // stole marks and moved quiet-key p50 by ~4ms).
        const atab = self.activeTab();
        var any_dirty = self.scene_dirty;
        var focused_dirty = false;
        for (atab.panes.items) |p| {
            switch (p.content) {
                .term => |*tm| {
                    tm.session.lockForSnapshot();
                    tm.rs.update(self.gpa, &tm.session.term) catch {
                        tm.session.unlockForSnapshot();
                        p.dirty = false;
                        continue;
                    };
                    tm.session.unlockForSnapshot();
                    p.dirty = tm.rs.dirty != .@"false";
                    tm.rs.dirty = .@"false";
                    // Cursor-only changes (backspace's \b, arrows, DECTCEM
                    // hide/show) dirty no row — compare against what the last
                    // fill drew, or the on-screen cursor goes stale. The cursor
                    // move IS the key's visible echo, so it legitimately sets
                    // focused_dirty and consumes the key→photon mark.
                    if (p == atab.focused and cursorKey(tm) != p.drawn_cursor) p.dirty = true;
                },
                .edit => |ed| {
                    p.dirty = ed.render_dirty;
                    ed.render_dirty = false;
                },
            }
            if (p.dirty) {
                any_dirty = true;
                if (p == atab.focused) focused_dirty = true;
            }
        }
        const t_update = CACurrentMediaTime();

        // A clean scene means nothing to draw: skip the whole frame. This
        // is both the honest idle number (zero work) and the honest
        // latency number — the key mark is consumed only by a frame that
        // actually carried the focused pane's echo.
        const shot_wanted = self.shot_state.load(.acquire) == 2;
        if (!any_dirty and !shot_wanted) {
            _ = stats.global.frames_skipped.fetchAdd(1, .monotonic);
            return;
        }
        self.scene_dirty = false;
        stats.global.frame_update.recordSeconds(t_update - t_start);

        // Fill the shared GPU cell buffer: each pane bump-allocates a
        // slot. The snapshot is the authority on grid dims; during a
        // resize it may briefly disagree with the rect, which is fine.
        const cells = self.renderer.cells();
        var off: usize = 0;
        for (atab.panes.items) |p| {
            p.drawn_cols = 0;
            p.drawn_rows = 0;
            const cols: usize = switch (p.content) {
                .term => |*tm| tm.rs.cols,
                .edit => p.cols,
            };
            var rows: usize = switch (p.content) {
                .term => |*tm| tm.rs.rows,
                .edit => p.rows,
            };
            if (cols == 0 or rows == 0) continue;
            if (off + cols * rows > self.renderer.cells_cap) {
                rows = (self.renderer.cells_cap - off) / cols;
                if (rows == 0) continue;
            }
            switch (p.content) {
                .term => |*tm| {
                    self.fillPane(tm, p == atab.focused, cells[off .. off + cols * rows], cols, rows);
                    p.drawn_cursor = cursorKey(tm);
                },
                .edit => |ed| self.fillEditorPane(ed, cells[off .. off + cols * rows], cols, rows),
            }
            p.buf_off = off;
            p.drawn_cols = @intCast(cols);
            p.drawn_rows = @intCast(rows);
            off += cols * rows;
        }

        const t_fill = CACurrentMediaTime();
        stats.global.frame_fill.recordSeconds(t_fill - t_update);

        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) {
            // The emulator's dirty state was already consumed above —
            // losing this frame would freeze the change until the NEXT
            // one arrives. Re-arm and retry on a later tick.
            self.scene_dirty = true;
            return;
        }
        // Backpressure (waiting for a free drawable) is pacing, not
        // work — its own ring, so the fps capability math stays honest.
        const t_acquired = CACurrentMediaTime();
        stats.global.drawable_wait.recordSeconds(t_acquired - t_fill);

        const clear_bg = switch (atab.focused.content) {
            .term => |*tm| tm.rs.colors.background,
            .edit => rgb4(th.ed_bg),
        };

        const desc = objc.getClass("MTLRenderPassDescriptor").?
            .msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = desc.msgSend(objc.Object, "colorAttachments", .{})
            .msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(u64, 0)});
        attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{}).value});
        // MTLLoadActionClear = 2, MTLStoreActionStore = 1
        attachment.msgSend(void, "setLoadAction:", .{@as(u64, 2)});
        attachment.msgSend(void, "setStoreAction:", .{@as(u64, 1)});
        attachment.msgSend(void, "setClearColor:", .{MTLClearColor{
            .r = @as(f64, @floatFromInt(clear_bg.r)) / 255.0,
            .g = @as(f64, @floatFromInt(clear_bg.g)) / 255.0,
            .b = @as(f64, @floatFromInt(clear_bg.b)) / 255.0,
            .a = 1.0,
        }});

        const size = self.layer.msgSend(NSSize, "drawableSize", .{});
        const vp_w: f32 = @floatCast(size.width);
        const vp_h: f32 = @floatCast(size.height);
        const cmd = self.queue.msgSend(objc.Object, "commandBuffer", .{});
        const enc = cmd.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{desc.value});

        // Scene: pane backgrounds (full rect, covers the sub-cell
        // remainder), grids, separators, focus edges.
        for (atab.panes.items) |p| {
            const bg = switch (p.content) {
                .term => |*tm| tm.rs.colors.background,
                .edit => rgb4(th.ed_bg),
            };
            self.renderer.drawRect(enc, vp_w, vp_h, p.rect.x, p.rect.y, p.rect.w, p.rect.h, .{ bg.r, bg.g, bg.b, 255 });
        }
        for (atab.panes.items) |p| {
            if (p.drawn_cols == 0) continue;
            self.renderer.drawGrid(enc, vp_w, vp_h, p.rect.x, p.rect.y, p.buf_off, p.drawn_cols, p.drawn_rows);
        }
        if (atab.panes.items.len > 1) {
            var sep_buf: [64]panespkg.Rect = undefined;
            var nsep: usize = 0;
            panespkg.collectSeparators(atab.root, &sep_buf, &nsep);
            for (sep_buf[0..nsep]) |r| {
                self.renderer.drawRect(enc, vp_w, vp_h, r.x, r.y, r.w, r.h, th.sep);
            }
            // The focused pane claims its share of adjacent separators
            // in the accent color — cheap, unambiguous focus telegraph.
            const fr = atab.focused.rect;
            const s = self.sep;
            if (fr.x > 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x - s, fr.y, s, fr.h, th.accent);
            if (fr.x + fr.w < self.px_w - 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x + fr.w, fr.y, s, fr.h, th.accent);
            if (fr.y > self.tab_h + 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x, fr.y - s, fr.w, s, th.accent);
            if (fr.y + fr.h < self.tab_h + self.contentH() - 0.5) self.renderer.drawRect(enc, vp_w, vp_h, fr.x, fr.y + fr.h, fr.w, s, th.accent);
        }
        var ui = @import("ui.zig").Ui{
            .r = &self.renderer,
            .enc = enc,
            .vp_w = vp_w,
            .vp_h = vp_h,
            .cells = self.renderer.cells(),
            .off = off,
        };
        self.drawBar(&ui);
        self.drawTabBar(&ui);

        enc.msgSend(void, "endEncoding", .{});

        // GPU time when the buffer completes; photon time when the
        // drawable actually presents. Both handlers are copied by Metal.
        var completed_ctx = CompletedBlock.init(.{ .app = self }, &completedCallback);
        cmd.msgSend(void, "addCompletedHandler:", .{&completed_ctx});
        var presented_ctx = PresentedBlock.init(.{ .app = self, .dirty = @intFromBool(focused_dirty), .commit_t = CACurrentMediaTime() }, &presentedCallback);
        drawable.msgSend(void, "addPresentedHandler:", .{&presented_ctx});

        cmd.msgSend(void, "presentDrawable:", .{drawable.value});
        cmd.msgSend(void, "commit", .{});

        const t_commit = CACurrentMediaTime();
        stats.global.frame_encode.recordSeconds(t_commit - t_acquired);
        _ = stats.global.frames_drawn.fetchAdd(1, .monotonic);
        if (focused_dirty) {
            const mark = self.input_mark.load(.acquire);
            if (mark > 0 and t_commit > mark) stats.global.key_commit.recordSeconds(t_commit - mark);
        }

        // Service a pending ctl `shot`: wait for this frame's GPU work,
        // read our own drawable back, write PNG. Render-thread only.
        if (self.shot_state.load(.acquire) == 2) {
            cmd.msgSend(void, "waitUntilCompleted", .{});
            self.captureShot(drawable);
            self.shot_state.store(0, .release);
        }
    }

    /// The display's refresh period in µs (the fps ceiling). Queried
    /// lazily — the link reports 0 before its first tick.
    fn displayPeriodUs(self: *App) f64 {
        if (self.display_period_us <= 0 and self.link != null) {
            const p = CVDisplayLinkGetActualOutputVideoRefreshPeriod(self.link);
            if (p > 0) self.display_period_us = p * 1e6;
        }
        return if (self.display_period_us > 0) self.display_period_us else 8333;
    }

    /// Recompute the status-bar text; flip scene_dirty only when it
    /// changed. Caller holds draw_lock.
    fn refreshHudLocked(self: *App, now: f64) void {
        const bytes = stats.global.bytes_in.load(.monotonic);
        if (self.hud_last_t > 0 and now > self.hud_last_t) {
            self.hud_mbs = @as(f64, @floatFromInt(bytes -| self.hud_last_bytes)) / (now - self.hud_last_t) / 1e6;
        }
        self.hud_last_t = now;
        self.hud_last_bytes = bytes;

        const key = stats.global.key_present.summarize();

        // Optimistic fps: the display's rate, dipping only when typical
        // FRAME COST can't fit the vsync budget — the only case a user
        // would feel as lag. (Seth's call: demand pacing must never
        // read as a performance problem.) Cost = the slower of the CPU
        // side (update+fill+encode, lock waits included) and the GPU;
        // p50s, so a one-off stall doesn't linger as a fake cap.
        const vsync = self.displayPeriodUs();
        var fps: u64 = @intFromFloat(@round(1e6 / vsync));
        const upd = stats.global.frame_update.summarize();
        const fill = stats.global.frame_fill.summarize();
        const enc_s = stats.global.frame_encode.summarize();
        const gpu = stats.global.frame_gpu.summarize();
        if (upd.n > 0 and gpu.n > 0) {
            const cpu_cost: f64 = @floatFromInt(upd.p50 + fill.p50 + enc_s.p50);
            const cost = @max(cpu_cost, @as(f64, @floatFromInt(gpu.p50)));
            if (cost > vsync) fps = @intFromFloat(@round(1e6 / cost));
        }

        var left: [96]u8 = undefined;
        const t = self.activeTab();
        const l = std.fmt.bufPrint(&left, "rookz · {d} pane{s} · #{d}", .{
            t.panes.items.len,
            @as([]const u8, if (t.panes.items.len == 1) "" else "s"),
            t.focused.id,
        }) catch return;
        var right: [96]u8 = undefined;
        const r = std.fmt.bufPrint(&right, "{d}.{d}ms key · {d}fps · {d}MB/s · {d}MB", .{
            key.p50 / 1000,
            (key.p50 % 1000) / 100,
            fps,
            @as(u64, @intFromFloat(@round(self.hud_mbs))),
            stats.maxRssMb(),
        }) catch return;

        var tabs_buf: [160]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tabs_buf);
        for (self.tabs.items) |tb| {
            switch (tb.focused.content) {
                .term => |*tm| {
                    tm.session.mutex.lock();
                    if (tm.session.term.getTitle()) |tt| {
                        tw.print("{s};", .{tt[0..@min(tt.len, 24)]}) catch {};
                    } else tw.print(";", .{}) catch {};
                    tm.session.mutex.unlock();
                },
                .edit => |ed| tw.print("{s};", .{ed.displayName()}) catch {},
            }
        }
        const td = tabs_buf[0..tw.end];

        if (std.mem.eql(u8, l, self.hud_left[0..self.hud_left_len]) and
            std.mem.eql(u8, r, self.hud_right[0..self.hud_right_len]) and
            std.mem.eql(u8, td, self.hud_tabs[0..self.hud_tabs_len])) return;
        @memcpy(self.hud_left[0..l.len], l);
        self.hud_left_len = l.len;
        @memcpy(self.hud_right[0..r.len], r);
        self.hud_right_len = r.len;
        @memcpy(self.hud_tabs[0..td.len], td);
        self.hud_tabs_len = td.len;
        self.scene_dirty = true;
    }

    /// The status bar: tenant one of the ui layer.
    fn drawBar(self: *App, ui: *@import("ui.zig").Ui) void {
        const by = self.px_h - self.bar_h;
        ui.rect(0, by, self.px_w, self.bar_h, th.bar_bg);
        const ty = by + (self.bar_h - self.renderer.cell_h) / 2;
        const pad = self.renderer.cell_w;
        var x: f32 = pad;
        // Armed leader: an accent cell showing the leader key, tmux's
        // prefix indicator.
        if (self.leader_pending.load(.acquire)) {
            if (self.keybinds.leader) |ld| {
                var lbuf: [3]u8 = .{ ' ', ld, ' ' };
                x += ui.text(x, ty, &lbuf, th.bar_bg, th.accent) + self.renderer.cell_w / 2;
            }
        }
        if (self.activeTab().focused.term()) |tm| {
            if (tm.copy_mode) {
                x += ui.text(x, ty, " SCROLL ", th.bar_bg, th.accent) + self.renderer.cell_w / 2;
            }
        }
        _ = ui.text(x, ty, self.hud_left[0..self.hud_left_len], th.bar_fg, th.bar_bg);
        _ = ui.textRight(self.px_w - pad, ty, self.hud_right[0..self.hud_right_len], th.bar_value, th.bar_bg);
    }

    /// The top tab bar — tabs as first-class chrome (the wails app's
    /// named tabs). Each chip shows its tab's focused-pane TITLE (OSC
    /// 0/2, read from the emulator under its lock); the active chip
    /// gets a lifted background and an accent underline.
    fn drawTabBar(self: *App, ui: *@import("ui.zig").Ui) void {
        ui.rect(0, 0, self.px_w, self.tab_h, th.bar_bg);
        const ty = (self.tab_h - self.renderer.cell_h) / 2;
        var x: f32 = self.renderer.cell_w / 2;
        for (self.tabs.items, 0..) |t, i| {
            const is_active = i == self.active_tab;

            // " {n} {title} ", title truncated to keep chips tidy.
            var title_buf: [24]u8 = undefined;
            var title: []const u8 = "shell";
            switch (t.focused.content) {
                .term => |*tm| {
                    tm.session.mutex.lock();
                    if (tm.session.term.getTitle()) |tt| {
                        const n = @min(tt.len, title_buf.len);
                        @memcpy(title_buf[0..n], tt[0..n]);
                        if (n > 0) title = title_buf[0..n];
                    }
                    tm.session.mutex.unlock();
                },
                .edit => |ed| {
                    const dn = ed.displayName();
                    const n = @min(dn.len, title_buf.len);
                    @memcpy(title_buf[0..n], dn[0..n]);
                    if (n > 0) title = title_buf[0..n];
                },
            }
            var chip: [40]u8 = undefined;
            const label = std.fmt.bufPrint(&chip, " {d} {s} ", .{ i + 1, title }) catch continue;

            const fg = if (is_active) th.bar_value else th.bar_fg;
            const bg = if (is_active) th.chip_active_bg else th.bar_bg;
            const w = ui.text(x, ty, label, fg, bg);
            if (is_active) ui.rect(x, self.tab_h - self.sep * 2, w, self.sep * 2, th.accent);
            if (i < self.chip_x.len) {
                self.chip_x[i] = .{ x, x + w };
                self.chip_n = i + 1;
            }
            x += w + self.renderer.cell_w / 2;
            if (x > self.px_w) break;
        }
    }

    /// Fill one pane's slot of the cell buffer from its render state.
    /// The cursor renders only in the focused pane — the second half of
    /// the focus telegraph.
    /// The cursor state a fill bakes into the grid, as one comparable
    /// word: position when visible, a sentinel when hidden or offscreen.
    fn cursorKey(tm: *panespkg.Term) u32 {
        if (!tm.rs.cursor.visible) return 0xffff_ffff;
        const cur = tm.rs.cursor.viewport orelse return 0xffff_ffff;
        return (@as(u32, cur.y) << 16) | cur.x;
    }

    fn fillPane(self: *App, tm: *panespkg.Term, focused: bool, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        const colors = &tm.rs.colors;
        const default_bg = colors.background;
        const default_fg = colors.foreground;
        const row_cells = tm.rs.row_data.items(.cells);
        const row_sels = tm.rs.row_data.items(.selection);
        const cellw_px: u16 = @intCast(self.renderer.cellw_px);
        // DECTCEM hide (TUIs that paint their own cursor, e.g. claude
        // code's inverse-space block) must actually hide ours.
        const show_cursor = focused and tm.rs.cursor.visible;
        for (0..rows) |y| {
            const raws = row_cells[y].items(.raw);
            const styles = row_cells[y].items(.style);
            var prev_wide: ?renderpkg.GlyphLoc = null;
            for (0..cols) |x| {
                const raw = &raws[x];
                const styled = raw.style_id != 0;
                const st: vt.Style = if (styled) styles[x] else .{};

                var bg = st.bg(raw, &colors.palette) orelse default_bg;
                if (row_sels[y]) |sr| {
                    if (x >= sr[0] and x <= sr[1]) bg = .{ .r = th.sel_bg[0], .g = th.sel_bg[1], .b = th.sel_bg[2] };
                }
                var fg = st.fg(.{ .default = default_fg, .palette = &colors.palette });
                // Faint (SGR 2) is the renderer's job like inverse:
                // blend fg halfway toward bg (claude code's subdued
                // suggestion text is faint, not a palette gray).
                if (styled and st.flags.faint) {
                    fg = .{
                        .r = @intCast((@as(u16, fg.r) + bg.r) / 2),
                        .g = @intCast((@as(u16, fg.g) + bg.g) / 2),
                        .b = @intCast((@as(u16, fg.b) + bg.b) / 2),
                    };
                }

                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };

                var uvx: u16 = 0;
                var uvy: u16 = 0;
                var flags: u16 = 0;
                switch (raw.wide) {
                    .narrow => {
                        if (cp > 32) if (self.renderer.glyph(cp, false)) |loc| {
                            uvx = loc.uvx;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                        };
                        prev_wide = null;
                    },
                    .wide => {
                        prev_wide = null;
                        if (cp > 32) if (self.renderer.glyph(cp, true)) |loc| {
                            uvx = loc.uvx;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                            prev_wide = loc;
                        };
                    },
                    // The wide glyph's right half lives one cell over in
                    // the atlas slot.
                    .spacer_tail => {
                        if (prev_wide) |loc| {
                            uvx = loc.uvx + cellw_px;
                            uvy = loc.uvy;
                            flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
                        }
                        prev_wide = null;
                    },
                    .spacer_head => prev_wide = null,
                }

                // Style.bg/fg deliberately don't apply the inverse flag
                // — that swap is the renderer's job (upstream ghostty
                // does the same in its cell fill). The cursor is one
                // more inversion on top, so cursor-over-inverse reads
                // normal.
                var inv = styled and st.flags.inverse;
                if (show_cursor) {
                    if (tm.rs.cursor.viewport) |cur| {
                        if (cur.x == x and cur.y == y) inv = !inv;
                    }
                }
                const eff_bg = if (inv) fg else bg;
                const eff_fg = if (styled and st.flags.invisible) eff_bg else if (inv) bg else fg;

                cells[y * cols + x] = .{
                    .bg = .{ eff_bg.r, eff_bg.g, eff_bg.b, 255 },
                    .fg = .{ eff_fg.r, eff_fg.g, eff_fg.b, 255 },
                    .uvx = uvx,
                    .uvy = uvy,
                    .flags = flags,
                };
            }
        }
    }

    /// Rasterize an editor pane: the editor lays out a styled RCell
    /// grid (pure text — the tested surface); this maps styles to
    /// colors and atlas glyphs. Last row is the editor's status line.
    fn fillEditorPane(self: *App, ed: *editorpkg.Editor, cells: []renderpkg.CellData, cols: usize, rows: usize) void {
        const g = ed.fillGrid(cols, rows);
        for (g, 0..) |rc, i| {
            const status_row = rows >= 1 and i >= (rows - 1) * cols;
            var bg: [4]u8 = if (status_row) th.chip_active_bg else th.ed_bg;
            var fg: [4]u8 = switch (rc.st) {
                .text => if (status_row) th.bar_value else th.ed_fg,
                .dim => if (status_row) th.bar_fg else th.ed_dim,
                .sel => th.ed_fg,
                .cursor => th.ed_bg,
                .mode => th.bar_bg,
                .status => th.bar_value,
                .err => th.ed_err,
            };
            switch (rc.st) {
                .sel => bg = th.ed_sel_bg,
                .cursor => {
                    bg = th.ed_fg;
                    fg = if (status_row) th.chip_active_bg else th.ed_bg;
                },
                .mode => bg = th.accent,
                else => {},
            }

            var uvx: u16 = 0;
            var uvy: u16 = 0;
            var flags: u16 = 0;
            if (rc.cp > 32) if (self.renderer.glyph(rc.cp, false)) |loc| {
                uvx = loc.uvx;
                uvy = loc.uvy;
                flags = 1 | (@as(u16, @intFromBool(loc.color)) << 1);
            };
            cells[i] = .{
                .bg = bg,
                .fg = fg,
                .uvx = uvx,
                .uvy = uvy,
                .flags = flags,
            };
        }
        // The editor may produce fewer cells than the slot (tiny grid
        // clamp); blank the remainder.
        for (g.len..cells.len) |i| {
            cells[i] = .{ .bg = th.ed_bg, .fg = th.ed_fg, .uvx = 0, .uvy = 0, .flags = 0 };
        }
    }

    fn captureShot(self: *App, drawable: objc.Object) void {
        const tex = drawable.msgSend(objc.Object, "texture", .{});
        const w = tex.msgSend(u64, "width", .{});
        const h = tex.msgSend(u64, "height", .{});
        const bpr = w * 4;
        const pixels = self.gpa.alloc(u8, bpr * h) catch return;
        defer self.gpa.free(pixels);
        tex.msgSend(void, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, pixels.ptr),
            bpr,
            renderpkg.MTLRegionPub{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 },
            @as(u64, 0),
        });
        @import("png.zig").writeBGRA(self.shot_path[0..self.shot_len], @intCast(w), @intCast(h), @intCast(bpr), pixels) catch |err| {
            std.debug.print("rookz shot: write failed: {}\n", .{err});
        };
    }
};

fn monitorCallback(context: *const MonitorBlock.Context, event_id: objc.c.id) callconv(.c) objc.c.id {
    const app: *App = context.app;
    const event = objc.Object.fromId(event_id);

    const flags = event.msgSend(u64, "modifierFlags", .{});
    if (flags & flag_cmd != 0) {
        const chars = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
        if (chars.value != null) {
            if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
                if (s[1] == 0) switch (s[0]) {
                    'q' => {
                        app.app.msgSend(void, "terminate:", .{@as(objc.c.id, null)});
                        return null;
                    },
                    // The rook chords: ⌘D splits right, ⌘⇧D splits down,
                    // ⌘T new tab (session.new in the wails keymap),
                    // ⌘1–9 select tab, ⌘⇧[ / ⌘⇧] cycle.
                    'c' => {
                        if (app.copyFocused()) |t| app.gpa.free(t);
                        return null;
                    },
                    'd' => {
                        app.splitFocused(flags & flag_shift == 0);
                        return null;
                    },
                    'D' => {
                        app.splitFocused(false);
                        return null;
                    },
                    't' => {
                        app.newTab();
                        return null;
                    },
                    '1'...'9' => {
                        _ = app.selectTab(s[0] - '1');
                        return null;
                    },
                    '{' => {
                        app.cycleTab(-1);
                        return null;
                    },
                    '}' => {
                        app.cycleTab(1);
                        return null;
                    },
                    else => {},
                };
            }
        }
        return event_id; // other cmd chords stay AppKit's
    }

    // ⌃HJKL pane nav — yielding to alternate-screen apps (vim owns its
    // own splits). rookz reads alt-screen truth straight from the
    // emulator; the webview app needed a 3s-stale `fg` heuristic here.
    if (flags & flag_ctrl != 0) {
        const chars = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
        if (chars.value != null) {
            if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
                if (s[1] == 0) {
                    const dir: ?panespkg.NavDir = switch (s[0]) {
                        'h' => .left,
                        'j' => .down,
                        'k' => .up,
                        'l' => .right,
                        else => null,
                    };
                    if (dir) |d| {
                        app.draw_lock.lock();
                        const alt = switch (app.activeTab().focused.content) {
                            .term => |*tm| tm.session.term.screens.active_key == .alternate,
                            .edit => false,
                        };
                        app.draw_lock.unlock();
                        if (!alt and app.focusMove(d)) return null;
                        // fall through: cooked control byte to the pty
                    }
                }
            }
        }
    }

    // Arrows by keyCode; everything else via the cooked characters, which
    // already encode control (^C = 0x03), Enter (\r), Backspace (0x7f).
    // Throwaway: vt.input.encodeKey is the real path once modes matter.
    const keycode = event.msgSend(u16, "keyCode", .{});
    const arrow: ?[]const u8 = switch (keycode) {
        123 => "\x1b[D",
        124 => "\x1b[C",
        125 => "\x1b[B",
        126 => "\x1b[A",
        else => null,
    };
    const chars = event.msgSend(objc.Object, "characters", .{});
    const bytes: []const u8 = arrow orelse blk: {
        if (chars.value == null) break :blk "";
        const s = chars.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse break :blk "";
        break :blk std.mem.span(s);
    };
    if (bytes.len > 0) {
        const ts = event.msgSend(f64, "timestamp", .{});
        // Leader chords see plain single-byte keys only — modified or
        // multi-byte input can never arm or resolve a chord.
        if (bytes.len == 1 and flags & (flag_ctrl | (1 << 19)) == 0) {
            if (app.handleCharKey(bytes[0], ts)) return null;
        }
        // The kernel's receipt time, same clock as presentedTime: this
        // makes key_present a true key-to-photon number. Writes go to
        // the focused pane, under the scene lock so reap can't free the
        // session mid-write.
        app.writeFocused(bytes, ts);
    }
    return null;
}

/// Mouse: clicks focus what they land on (pane or tab chip); the
/// wheel scrolls the pane under the cursor — alt-screen terminals get
/// arrow keys (vim/less), editors scroll their viewport, primary-
/// screen terminal scrollback arrives with the scrollback slice.
fn mouseCallback(context: *const MonitorBlock.Context, event_id: objc.c.id) callconv(.c) objc.c.id {
    const app: *App = context.app;
    const event = objc.Object.fromId(event_id);
    const etype = event.msgSend(u64, "type", .{});

    // Window coords are points, origin bottom-left; the scene is px,
    // origin top-left of the layer (= contentView).
    const loc = event.msgSend(NSPoint, "locationInWindow", .{});
    const scale = app.layer.msgSend(f64, "contentsScale", .{});
    const x: f32 = @floatCast(loc.x * scale);
    const y: f32 = app.px_h - @as(f32, @floatCast(loc.y * scale));
    if (y < 0 or y > app.px_h or x < 0 or x > app.px_w) return event_id; // titlebar etc.

    if (etype == 1) { // NSEventTypeLeftMouseDown
        app.clickAt(x, y);
        return null;
    }
    if (etype == 6) { // NSEventTypeLeftMouseDragged
        app.dragTo(x, y);
        return null;
    }
    if (etype == 2) { // NSEventTypeLeftMouseUp
        app.dragEnd();
        return null;
    }

    // Scroll wheel: accumulate points; one step per cell height.
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    app.draw_lock.lock();
    app.wheel_accum += dy;
    const step: f64 = @floatCast(@max(1.0, app.renderer.cell_h / @as(f32, @floatCast(scale))));
    const lines: i64 = @intFromFloat(app.wheel_accum / step);
    app.wheel_accum -= @as(f64, @floatFromInt(lines)) * step;
    app.draw_lock.unlock();
    if (lines != 0) app.wheelAt(x, y, lines);
    return null;
}

fn resizeCallback(context: *const ResizeBlock.Context, notification: objc.c.id) callconv(.c) void {
    _ = notification;
    context.app.viewResized();
}

fn completedCallback(context: *const CompletedBlock.Context, cmd_id: objc.c.id) callconv(.c) void {
    _ = context;
    const cmd = objc.Object.fromId(cmd_id);
    const gpu_start = cmd.msgSend(f64, "GPUStartTime", .{});
    const gpu_end = cmd.msgSend(f64, "GPUEndTime", .{});
    if (gpu_end > gpu_start) stats.global.frame_gpu.recordSeconds(gpu_end - gpu_start);
}

fn presentedCallback(context: *const PresentedBlock.Context, drawable_id: objc.c.id) callconv(.c) void {
    const app = context.app;
    const t = objc.Object.fromId(drawable_id).msgSend(f64, "presentedTime", .{});
    if (t <= 0) return;

    // Pacing, not idleness: an interval that brackets an idle stretch
    // (dirty-skip means we simply didn't draw) says nothing about how
    // fast we draw — only sub-500ms gaps are pacing samples.
    const last = app.last_presented.swap(t, .acq_rel);
    if (last > 0 and t > last and t - last < 0.5) stats.global.present_interval.recordSeconds(t - last);
    if (t > context.commit_t) stats.global.present_lag.recordSeconds(t - context.commit_t);

    // Key → photon: only a frame that carried the focused pane's echo
    // may consume the pending mark.
    if (context.dirty != 0) {
        const mark = app.input_mark.swap(0, .acq_rel);
        if (mark > 0 and t > mark) stats.global.key_present.recordSeconds(t - mark);
    }
}

fn displayLinkCallback(link: CVDisplayLinkRef, now: ?*const anyopaque, output: ?*const anyopaque, flags_in: u64, flags_out: ?*u64, ctx: ?*anyopaque) callconv(.c) i32 {
    _ = link;
    _ = now;
    _ = output;
    _ = flags_in;
    _ = flags_out;
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.drawNow();
    return 0;
}

/// Reader thread, after a parsed chunk: render immediately if a
/// keystroke is waiting on its echo IN THE FOCUSED PANE — a background
/// pane's firehose must not burn the latency path. Pointer compare
/// only; the session may not be dereferenced here.
fn inputKick(ctx: *anyopaque, sess: *sessionpkg.Session) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.focused_session.load(.acquire) != sess) return;
    if (self.input_mark.load(.acquire) > 0) self.drawNow();
}
