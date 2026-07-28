//! AppKit + Metal shell for rookz. Pure Zig via zig-objc — no Swift, no nib.
//! The window owns a CAMetalLayer; a CVDisplayLink drives rendering off the
//! main thread (ghostty's renderer-thread shape). A live shell session runs
//! underneath: pty → ghostty-vt → RenderState → instanced Metal grid.

const std = @import("std");
const objc = @import("objc");
const vt = @import("ghostty-vt");
const sessionpkg = @import("session.zig");
const renderpkg = @import("render.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

extern "c" fn MTLCreateSystemDefaultDevice() objc.c.id;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// CVDisplayLink (CoreVideo). Deprecated in recent macOS but present and the
// simplest C-callable frame clock; swap for CAMetalDisplayLink later.
const CVDisplayLinkRef = ?*anyopaque;
extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(out: *CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, cb: *const fn (CVDisplayLinkRef, ?*const anyopaque, ?*const anyopaque, u64, ?*u64, ?*anyopaque) callconv(.c) i32, ctx: ?*anyopaque) i32;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) i32;

const NSEventMaskKeyDown: u64 = 1 << 10;

const win_w: f64 = 1024;
const win_h: f64 = 700;
const font_pt: f64 = 13;

fn nsString(s: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

const MonitorBlock = objc.Block(struct { app: *App }, .{objc.c.id}, objc.c.id);

pub const App = struct {
    gpa: std.mem.Allocator,
    app: objc.Object,
    window: objc.Object,
    layer: objc.Object,
    device: objc.Object,
    queue: objc.Object,
    renderer: renderpkg.Renderer,
    session: *sessionpkg.Session,
    rs: vt.RenderState = .empty,
    cols: u32,
    rows: u32,
    frame_count: std.atomic.Value(u64) = .init(0),
    activate: bool = true,

    // ctl `shot` handoff: the socket thread stores a path and flips the
    // flag; the render thread services it after the next commit.
    shot_state: std.atomic.Value(u8) = .init(0),
    shot_path: [1024]u8 = undefined,
    shot_len: usize = 0,

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
        // false so the ctl `shot` command can read our own drawable back —
        // dev-tool visibility outranks the marginal framebufferOnly win.
        layer.msgSend(void, "setFramebufferOnly:", .{false});

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
        window.msgSend(void, "setContentView:", .{view.value});

        // Retina: drawable size in pixels, not points.
        const scale = window.msgSend(f64, "backingScaleFactor", .{});
        layer.msgSend(void, "setContentsScale:", .{scale});
        const px_w = win_w * scale;
        const px_h = win_h * scale;
        layer.msgSend(void, "setDrawableSize:", .{NSSize{ .width = px_w, .height = px_h }});

        const renderer = try renderpkg.Renderer.init(gpa, device, "Menlo", font_pt * scale, 64 * 1024);
        const cols: u32 = @intFromFloat(@divFloor(@as(f32, @floatCast(px_w)), renderer.cell_w));
        const rows: u32 = @intFromFloat(@divFloor(@as(f32, @floatCast(px_h)), renderer.cell_h));

        const shell = getenv("SHELL") orelse "/bin/zsh";
        const session = try sessionpkg.Session.start(gpa, init.io, shell, @intCast(cols), @intCast(rows));

        const self = try gpa.create(App);
        self.* = .{
            .gpa = gpa,
            .app = app,
            .window = window,
            .layer = layer,
            .device = device,
            .queue = queue,
            .renderer = renderer,
            .session = session,
            .cols = cols,
            .rows = rows,
        };
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

        // Frame clock off the main thread.
        var link: CVDisplayLinkRef = null;
        _ = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        _ = CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, self);
        _ = CVDisplayLinkStart(link);

        self.app.msgSend(void, "run", .{});
    }

    fn drawFrame(self: *App) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        _ = self.frame_count.fetchAdd(1, .monotonic);

        // Snapshot terminal state under the session lock.
        self.session.mutex.lock();
        self.rs.update(self.gpa, &self.session.term) catch {
            self.session.mutex.unlock();
            return;
        };
        self.session.mutex.unlock();

        const cols: usize = @min(self.cols, self.rs.cols);
        const rows: usize = @min(self.rows, self.rs.rows);
        if (cols == 0 or rows == 0) return;

        // Fill the GPU cell buffer from the render state.
        const colors = &self.rs.colors;
        const default_bg = colors.background;
        const default_fg = colors.foreground;
        const cells = self.renderer.cells();
        const row_cells = self.rs.row_data.items(.cells);
        for (0..rows) |y| {
            const raws = row_cells[y].items(.raw);
            const styles = row_cells[y].items(.style);
            for (0..cols) |x| {
                const raw = &raws[x];
                const styled = raw.style_id != 0;
                const st: vt.Style = if (styled) styles[x] else .{};

                const bg = st.bg(raw, &colors.palette) orelse default_bg;
                const fg = st.fg(.{ .default = default_fg, .palette = &colors.palette });

                const cp: u21 = switch (raw.content_tag) {
                    .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
                    else => 0,
                };
                const glyph: u32 = if (cp >= 33 and cp <= 126)
                    @intCast(cp - 32)
                else if (cp == 0 or cp == 32)
                    0
                else
                    '?' - 32; // non-ASCII placeholder until the atlas grows

                var inv = false;
                if (self.rs.cursor.viewport) |cur| {
                    if (cur.x == x and cur.y == y) inv = true;
                }
                const eff_bg = if (inv) fg else bg;
                const eff_fg = if (inv) bg else fg;

                cells[y * cols + x] = .{
                    .bg = .{ eff_bg.r, eff_bg.g, eff_bg.b, 255 },
                    .fg = .{ eff_fg.r, eff_fg.g, eff_fg.b, 255 },
                    .glyph = glyph,
                };
            }
        }

        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) return;

        const desc = objc.getClass("MTLRenderPassDescriptor").?
            .msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = desc.msgSend(objc.Object, "colorAttachments", .{})
            .msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(u64, 0)});
        attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{}).value});
        // MTLLoadActionClear = 2, MTLStoreActionStore = 1
        attachment.msgSend(void, "setLoadAction:", .{@as(u64, 2)});
        attachment.msgSend(void, "setStoreAction:", .{@as(u64, 1)});
        attachment.msgSend(void, "setClearColor:", .{MTLClearColor{
            .r = @as(f64, @floatFromInt(default_bg.r)) / 255.0,
            .g = @as(f64, @floatFromInt(default_bg.g)) / 255.0,
            .b = @as(f64, @floatFromInt(default_bg.b)) / 255.0,
            .a = 1.0,
        }});

        const size = self.layer.msgSend(NSSize, "drawableSize", .{});
        const cmd = self.queue.msgSend(objc.Object, "commandBuffer", .{});
        const enc = cmd.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{desc.value});
        self.renderer.draw(enc, @floatCast(size.width), @floatCast(size.height), @intCast(cols), @intCast(rows));
        enc.msgSend(void, "endEncoding", .{});
        cmd.msgSend(void, "presentDrawable:", .{drawable.value});
        cmd.msgSend(void, "commit", .{});

        // Service a pending ctl `shot`: wait for this frame's GPU work,
        // read our own drawable back, write PNG. Render-thread only.
        if (self.shot_state.load(.acquire) == 2) {
            cmd.msgSend(void, "waitUntilCompleted", .{});
            self.captureShot(drawable);
            self.shot_state.store(0, .release);
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

    // modifierFlags bit 20 (1<<20) = command
    const flags = event.msgSend(u64, "modifierFlags", .{});
    if (flags & (1 << 20) != 0) {
        const chars = event.msgSend(objc.Object, "charactersIgnoringModifiers", .{});
        if (chars.value != null) {
            if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
                if (s[0] == 'q' and s[1] == 0) {
                    app.app.msgSend(void, "terminate:", .{@as(objc.c.id, null)});
                    return null;
                }
            }
        }
        return event_id; // other cmd chords stay AppKit's
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
    if (arrow) |seq| {
        app.session.write(seq);
        return null;
    }

    const chars = event.msgSend(objc.Object, "characters", .{});
    if (chars.value != null) {
        if (chars.msgSend(?[*:0]const u8, "UTF8String", .{})) |s| {
            const bytes = std.mem.span(s);
            if (bytes.len > 0) app.session.write(bytes);
        }
    }
    return null;
}

fn displayLinkCallback(link: CVDisplayLinkRef, now: ?*const anyopaque, output: ?*const anyopaque, flags_in: u64, flags_out: ?*u64, ctx: ?*anyopaque) callconv(.c) i32 {
    _ = link;
    _ = now;
    _ = output;
    _ = flags_in;
    _ = flags_out;
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.drawFrame();
    return 0;
}
