//! Metal cell-grid renderer with a dynamic glyph atlas. Glyphs rasterize
//! lazily on first sight via CoreText — base font first (FiraCode Nerd
//! Font Mono, so PUA icons resolve directly), then the system cascade for
//! everything else — and shelf-pack into one R8 texture. Wide glyphs get
//! a 2-cell slot; the spacer cell samples the right half. The renderer is
//! a framebuffer, never a text engine — cell layout authority stays with
//! ghostty-vt.

const std = @import("std");
const objc = @import("objc");

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CFRange = extern struct { location: isize, length: isize };

// CoreText / CoreGraphics externs.
const CFStringRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CGContextRef = ?*anyopaque;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: isize, encoding: u32, external: bool) CFStringRef;
extern "c" fn CFRelease(obj: ?*anyopaque) void;
extern "c" fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const anyopaque) CTFontRef;
extern "c" fn CTFontCreateForString(current: CTFontRef, str: CFStringRef, range: CFRange) CTFontRef;
extern "c" fn CTFontGetAscent(font: CTFontRef) f64;
extern "c" fn CTFontGetDescent(font: CTFontRef) f64;
extern "c" fn CTFontGetLeading(font: CTFontRef) f64;
extern "c" fn CTFontGetGlyphsForCharacters(font: CTFontRef, chars: [*]const u16, glyphs: [*]u16, count: isize) bool;
extern "c" fn CTFontGetSymbolicTraits(font: CTFontRef) u32;
extern "c" fn CTFontCreateCopyWithAttributes(font: CTFontRef, size: f64, matrix: ?*const anyopaque, attrs: ?*anyopaque) CTFontRef;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: c_int, glyphs: [*]const u16, advances: ?[*]CGSize, count: isize) f64;
extern "c" fn CTFontDrawGlyphs(font: CTFontRef, glyphs: [*]const u16, positions: [*]const CGPoint, count: usize, ctx: CGContextRef) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits_per_comp: usize, bytes_per_row: usize, space: ?*anyopaque, info: u32) CGContextRef;
extern "c" fn CGBitmapContextGetData(ctx: CGContextRef) ?[*]u8;
extern "c" fn CGContextClearRect(ctx: CGContextRef, rect: extern struct { origin: CGPoint, size: CGSize }) void;

const utf8_encoding: u32 = 0x08000100;
const alpha_only: u32 = 7; // kCGImageAlphaOnly
// premultiplied BGRA little-endian for color (emoji) glyphs
const bgra_premul: u32 = 8192 | 2; // ByteOrder32Little | AlphaPremultipliedFirst
const color_glyphs_trait: u32 = 1 << 13; // kCTFontTraitColorGlyphs

pub const MTLRegion = extern struct { x: u64, y: u64, z: u64, w: u64, h: u64, d: u64 };
pub const MTLRegionPub = MTLRegion;

/// Per-cell GPU data; must match the MSL CellData layout (stride 16).
/// uv is the glyph's texel origin in the atlas; flags bit0 = has glyph.
pub const CellData = extern struct {
    bg: [4]u8,
    fg: [4]u8,
    uvx: u16,
    uvy: u16,
    flags: u16,
    pad: u16 = 0,
};

/// Must match the MSL Uni layout.
const Uniforms = extern struct {
    vp: [2]f32,
    cell: [2]f32,
    cols: u32,
    pad: u32 = 0,
    atlas: [2]f32,
    /// Pixel offset of this region's top-left — the scene seam: a frame
    /// is N grid regions (panes) plus rects, all one pipeline.
    origin: [2]f32,
};

const shader_src =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct Uni { float2 vp; float2 cell; uint cols; uint pad; float2 atlas; float2 origin; };
    \\struct CellData { uchar4 bg; uchar4 fg; ushort2 uv; ushort flags; ushort pad; };
    \\struct VOut { float4 pos [[position]]; float4 color; float2 uv; float sel; };
    \\
    \\vertex VOut bg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                  constant Uni& u [[buffer(0)]],
    \\                  const device CellData* cells [[buffer(1)]]) {
    \\  uint col = iid % u.cols; uint row = iid / u.cols;
    \\  float2 corner = float2(vid & 1, vid >> 1);
    \\  float2 px = u.origin + (float2(col, row) + corner) * u.cell;
    \\  VOut o;
    \\  o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    \\  o.color = float4(cells[iid].bg) / 255.0;
    \\  o.uv = float2(0.0);
    \\  return o;
    \\}
    \\fragment float4 bg_fs(VOut in [[stage_in]]) { return in.color; }
    \\
    \\vertex VOut fg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                  constant Uni& u [[buffer(0)]],
    \\                  const device CellData* cells [[buffer(1)]]) {
    \\  VOut o;
    \\  if ((cells[iid].flags & 1) == 0) { o.pos = float4(-2.0, -2.0, 0.0, 1.0); o.color = float4(0.0); o.uv = float2(0.0); o.sel = 0.0; return o; }
    \\  uint col = iid % u.cols; uint row = iid / u.cols;
    \\  float2 corner = float2(vid & 1, vid >> 1);
    \\  float2 px = u.origin + (float2(col, row) + corner) * u.cell;
    \\  o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    \\  o.color = float4(cells[iid].fg) / 255.0;
    \\  o.uv = (float2(cells[iid].uv) + corner * u.cell) / u.atlas;
    \\  o.sel = (cells[iid].flags & 2) != 0 ? 1.0 : 0.0;
    \\  return o;
    \\}
    \\fragment float4 fg_fs(VOut in [[stage_in]],
    \\                      texture2d<float> atlas [[texture(0)]],
    \\                      texture2d<float> colors [[texture(1)]]) {
    \\  constexpr sampler s(coord::normalized, filter::nearest);
    \\  float a = atlas.sample(s, in.uv).r;
    \\  float4 mono = float4(in.color.rgb * a, a);
    \\  float4 emoji = colors.sample(s, in.uv); // premultiplied
    \\  return mix(mono, emoji, in.sel);
    \\}
    \\
    \\// --- Rounded rectangles, borders and shadows ---
    \\// One signed-distance field does all three: inside it is a fill,
    \\// a band at the edge is a border, and a falloff OUTSIDE it is a
    \\// shadow. Output is premultiplied, like fg_fs.
    \\// EVERY member is a float4 on purpose. Metal aligns float4 to 16
    \\// bytes and Zig aligns [4]f32 to 4, so a mixed struct develops
    \\// padding holes on one side only — the first version of this drew
    \\// nothing at all, because `rect` landed 8 bytes early.
    \\struct RRUni {
    \\  float4 vp;      // xy = viewport
    \\  float4 rect;    // xywh in px
    \\  float4 params;  // x = radius, y = border, z = soften
    \\  float4 fill;
    \\  float4 edge;
    \\};
    \\struct RROut { float4 pos [[position]]; float2 px; };
    \\
    \\vertex RROut rr_vs(uint vid [[vertex_id]], constant RRUni& u [[buffer(0)]]) {
    \\  // A shadow paints outside its rect, so the quad grows to hold it.
    \\  float grow = u.params.z * 3.0;
    \\  float2 o = u.rect.xy - grow;
    \\  float2 s = u.rect.zw + grow * 2.0;
    \\  float2 corner = float2(vid & 1, vid >> 1);
    \\  float2 px = o + corner * s;
    \\  RROut r;
    \\  r.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    \\  r.px = px;
    \\  return r;
    \\}
    \\
    \\
    \\static float sd_round_box(float2 p, float2 b, float r) {
    \\  float2 q = abs(p) - b + r;
    \\  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\fragment float4 rr_fs(RROut in [[stage_in]], constant RRUni& u [[buffer(0)]]) {
    \\  float radius = u.params.x, border = u.params.y, soften = u.params.z;
    \\  float2 c = u.rect.xy + u.rect.zw * 0.5;
    \\  float2 b = u.rect.zw * 0.5;
    \\  float r = min(radius, min(b.x, b.y));
    \\  float d = sd_round_box(in.px - c, b, r);
    \\  if (soften > 0.0) {
    \\    float a = u.fill.a * (1.0 - smoothstep(0.0, soften, d));
    \\    return float4(u.fill.rgb * a, a);
    \\  }
    \\  float inside = 1.0 - smoothstep(-0.7, 0.7, d);
    \\  float4 col = u.fill;
    \\  if (border > 0.0) {
    \\    float core = 1.0 - smoothstep(-0.7, 0.7, d + border);
    \\    col = mix(u.edge, u.fill, core);
    \\  }
    \\  float a = col.a * inside;
    \\  return float4(col.rgb * a, a);
    \\}
;

const atlas_px: usize = 2048;

pub const GlyphLoc = struct { uvx: u16, uvy: u16, color: bool = false };

/// Must match the MSL RRUni layout — all float4, see the note there.
/// Five 16-byte rows with no holes on either side.
const RRUniforms = extern struct {
    vp: [4]f32,
    rect: [4]f32,
    /// radius, border, soften, unused.
    params: [4]f32,
    fill: [4]f32,
    edge: [4]f32 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(RRUniforms) == 80);
    std.debug.assert(@offsetOf(RRUniforms, "rect") == 16);
    std.debug.assert(@offsetOf(RRUniforms, "fill") == 48);
}

/// How a rounded rect is painted. Defaults give a plain filled rect
/// with square corners — the same thing `drawRect` draws, so a caller
/// only pays for what it asks for.
pub const RectStyle = struct {
    radius: f32 = 0,
    /// Border thickness in px, drawn INSIDE the shape. 0 = none.
    border: f32 = 0,
    border_color: [4]u8 = .{ 0, 0, 0, 0 },
    /// Blur radius in px. Non-zero makes this a SHADOW: the shape is
    /// not filled, it falls off outward over this distance.
    soften: f32 = 0,
};

fn norm(c: [4]u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c[0])) / 255.0,
        @as(f32, @floatFromInt(c[1])) / 255.0,
        @as(f32, @floatFromInt(c[2])) / 255.0,
        @as(f32, @floatFromInt(c[3])) / 255.0,
    };
}

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    device: objc.Object,
    bg_pso: objc.Object,
    fg_pso: objc.Object,
    rr_pso: objc.Object,
    atlas: objc.Object,
    cells_buf: objc.Object,
    cells_cap: usize,

    /// Cell size in device pixels.
    cell_w: f32,
    cell_h: f32,

    // Glyph machinery. Render thread only.
    font: CTFontRef,
    descent: f64,
    cellw_px: usize,
    cellh_px: usize,
    scratch: CGContextRef,
    scratch_data: [*]u8,
    scratch_w: usize,
    glyphs: std.AutoHashMapUnmanaged(u21, ?GlyphLoc) = .empty,
    shelf_x: usize = 0,
    shelf_y: usize = 0,

    // Color (emoji) path: premultiplied BGRA scratch + its own atlas.
    color_atlas: objc.Object,
    color_scratch: CGContextRef,
    color_scratch_data: [*]u8,
    color_shelf_x: usize = 0,
    color_shelf_y: usize = 0,

    pub fn init(gpa: std.mem.Allocator, device: objc.Object, font_name: [*:0]const u8, font_px: f64, max_cells: usize) !Renderer {
        // --- Font + metrics ---
        const name = CFStringCreateWithCString(null, font_name, utf8_encoding);
        defer CFRelease(name);
        const font = CTFontCreateWithName(name, font_px, null);
        if (font == null) return error.FontNotFound;

        const ascent = CTFontGetAscent(font);
        const descent = CTFontGetDescent(font);
        const leading = CTFontGetLeading(font);

        var mchar = [1]u16{'M'};
        var mglyph = [1]u16{0};
        _ = CTFontGetGlyphsForCharacters(font, &mchar, &mglyph, 1);
        const advance = CTFontGetAdvancesForGlyphs(font, 0, &mglyph, null, 1);

        const cell_w: usize = @intFromFloat(@ceil(advance));
        const cell_h: usize = @intFromFloat(@ceil(ascent + descent + leading));

        // Scratch bitmap: one 2-cell-wide slot, rasterize target for every
        // glyph before its subregion uploads into the atlas.
        const scratch_w = cell_w * 2;
        const scratch = CGBitmapContextCreate(null, scratch_w, cell_h, 8, scratch_w, null, alpha_only);
        if (scratch == null) return error.BitmapFailed;
        const scratch_data = CGBitmapContextGetData(scratch) orelse return error.BitmapFailed;

        // Color scratch for emoji (premultiplied BGRA).
        const rgb_space = CGColorSpaceCreateDeviceRGB();
        const color_scratch = CGBitmapContextCreate(null, scratch_w, cell_h, 8, scratch_w * 4, rgb_space, bgra_premul);
        if (color_scratch == null) return error.BitmapFailed;
        const color_scratch_data = CGBitmapContextGetData(color_scratch) orelse return error.BitmapFailed;

        // --- Atlas texture (R8, dynamic) ---
        // MTLPixelFormatR8Unorm = 10
        const tdesc = objc.getClass("MTLTextureDescriptor").?.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ @as(u64, 10), @as(u64, atlas_px), @as(u64, atlas_px), false },
        );
        const atlas = device.msgSend(objc.Object, "newTextureWithDescriptor:", .{tdesc.value});

        // MTLPixelFormatBGRA8Unorm = 80
        const cdesc = objc.getClass("MTLTextureDescriptor").?.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ @as(u64, 80), @as(u64, atlas_px), @as(u64, atlas_px), false },
        );
        const color_atlas = device.msgSend(objc.Object, "newTextureWithDescriptor:", .{cdesc.value});

        // --- Pipelines ---
        var err_id: objc.c.id = null;
        const lib = device.msgSend(objc.Object, "newLibraryWithSource:options:error:", .{
            nsString(shader_src).value,
            @as(objc.c.id, null),
            &err_id,
        });
        if (lib.value == null) {
            logNSError(err_id);
            return error.ShaderCompileFailed;
        }

        const bg_pso = try makePipeline(device, lib, "bg_vs", "bg_fs", false);
        const fg_pso = try makePipeline(device, lib, "fg_vs", "fg_fs", true);
        // Blended: a rounded corner IS an alpha ramp, and a shadow is
        // nothing but one.
        const rr_pso = try makePipeline(device, lib, "rr_vs", "rr_fs", true);

        // --- Cell buffer (shared storage) ---
        const cells_buf = device.msgSend(objc.Object, "newBufferWithLength:options:", .{
            @as(u64, max_cells * @sizeOf(CellData)),
            @as(u64, 0), // MTLResourceStorageModeShared
        });

        return .{
            .gpa = gpa,
            .device = device,
            .bg_pso = bg_pso,
            .fg_pso = fg_pso,
            .rr_pso = rr_pso,
            .atlas = atlas,
            .cells_buf = cells_buf,
            .cells_cap = max_cells,
            .cell_w = @floatFromInt(cell_w),
            .cell_h = @floatFromInt(cell_h),
            .font = font,
            .descent = descent,
            .cellw_px = cell_w,
            .cellh_px = cell_h,
            .scratch = scratch,
            .scratch_data = scratch_data,
            .scratch_w = scratch_w,
            .color_atlas = color_atlas,
            .color_scratch = color_scratch,
            .color_scratch_data = color_scratch_data,
        };
    }

    /// Find-or-rasterize a glyph. Returns null when nothing can draw it
    /// (caller renders nothing). Render thread only.
    pub fn glyph(self: *Renderer, cp: u21, wide: bool) ?GlyphLoc {
        const gop = self.glyphs.getOrPut(self.gpa, cp) catch return null;
        if (gop.found_existing) return gop.value_ptr.*;
        const loc = self.rasterize(cp, wide);
        gop.value_ptr.* = loc;
        return loc;
    }

    fn rasterize(self: *Renderer, cp: u21, wide: bool) ?GlyphLoc {
        _ = @import("stats.zig").global.glyphs_rasterized.fetchAdd(1, .monotonic);
        const slot_width = self.cellw_px * @as(usize, if (wide) 2 else 1);
        @memset(self.scratch_data[0 .. self.scratch_w * self.cellh_px], 0);

        // Box-drawing and block-element glyphs are drawn procedurally,
        // edge to edge — a font glyph centered in a ceil'd cell leaves
        // hairline seams between stacked cells (the nvim-logo bug).
        if (self.drawSprite(cp)) return self.uploadSlot(slot_width);

        return self.rasterizeFont(cp, slot_width);
    }

    fn rasterizeFont(self: *Renderer, cp: u21, slot_width: usize) ?GlyphLoc {
        // UTF-16 for CoreText.
        var u16buf: [2]u16 = undefined;
        var u16len: usize = 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            u16buf[0] = @intCast(0xD800 + (v >> 10));
            u16buf[1] = @intCast(0xDC00 + (v & 0x3FF));
            u16len = 2;
        } else u16buf[0] = @intCast(cp);

        // Base font, then the system cascade for whatever it lacks.
        var glyph_ids: [2]u16 = .{ 0, 0 };
        var font = self.font;
        var cascade: CTFontRef = null;
        defer if (cascade != null) CFRelease(cascade);
        if (!CTFontGetGlyphsForCharacters(font, &u16buf, &glyph_ids, @intCast(u16len))) {
            var utf8buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8buf) catch return null;
            const str = CFStringCreateWithBytes(null, &utf8buf, n, utf8_encoding, false) orelse return null;
            defer CFRelease(str);
            cascade = CTFontCreateForString(self.font, str, .{ .location = 0, .length = @intCast(u16len) });
            if (cascade == null) return null;
            font = cascade;
            if (!CTFontGetGlyphsForCharacters(font, &u16buf, &glyph_ids, @intCast(u16len))) return null;
        }

        // Color glyphs (emoji) go to the BGRA atlas, scaled to fit the
        // cell box — Apple Color Emoji's em square overflows text metrics.
        if (CTFontGetSymbolicTraits(font) & color_glyphs_trait != 0) {
            const target: f64 = @floatFromInt(self.cellh_px * 3 / 4);
            const sized = CTFontCreateCopyWithAttributes(font, target, null, null) orelse return null;
            defer CFRelease(sized);
            if (!CTFontGetGlyphsForCharacters(sized, &u16buf, &glyph_ids, @intCast(u16len))) return null;

            const adv = CTFontGetAdvancesForGlyphs(sized, 0, &glyph_ids, null, 1);
            var x: f64 = (@as(f64, @floatFromInt(slot_width)) - adv) / 2.0;
            if (x < 0) x = 0;

            @memset(self.color_scratch_data[0 .. self.scratch_w * 4 * self.cellh_px], 0);
            const pos = [1]CGPoint{.{ .x = x, .y = CTFontGetDescent(sized) }};
            CTFontDrawGlyphs(sized, &glyph_ids, &pos, 1, self.color_scratch);
            return self.uploadColorSlot(slot_width);
        }

        // Center the glyph's advance inside its slot.
        const adv = CTFontGetAdvancesForGlyphs(font, 0, &glyph_ids, null, 1);
        var x: f64 = (@as(f64, @floatFromInt(slot_width)) - adv) / 2.0;
        if (x < 0) x = 0;

        const pos = [1]CGPoint{.{ .x = x, .y = self.descent }};
        CTFontDrawGlyphs(font, &glyph_ids, &pos, 1, self.scratch);

        return self.uploadSlot(slot_width);
    }

    fn uploadColorSlot(self: *Renderer, slot_width: usize) ?GlyphLoc {
        if (self.color_shelf_x + slot_width > atlas_px) {
            self.color_shelf_x = 0;
            self.color_shelf_y += self.cellh_px;
        }
        if (self.color_shelf_y + self.cellh_px > atlas_px) {
            self.glyphs.clearRetainingCapacity();
            self.color_shelf_x = 0;
            self.color_shelf_y = 0;
        }
        const loc: GlyphLoc = .{ .uvx = @intCast(self.color_shelf_x), .uvy = @intCast(self.color_shelf_y), .color = true };
        self.color_shelf_x += slot_width;

        self.color_atlas.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            MTLRegion{ .x = loc.uvx, .y = loc.uvy, .z = 0, .w = slot_width, .h = self.cellh_px, .d = 1 },
            @as(u64, 0),
            @as(*const anyopaque, self.color_scratch_data),
            @as(u64, self.scratch_w * 4),
        });

        return loc;
    }

    /// Shelf-allocate an atlas slot and upload the scratch bitmap into it.
    fn uploadSlot(self: *Renderer, slot_width: usize) ?GlyphLoc {
        if (self.shelf_x + slot_width > atlas_px) {
            self.shelf_x = 0;
            self.shelf_y += self.cellh_px;
        }
        if (self.shelf_y + self.cellh_px > atlas_px) {
            // Atlas full: drop the whole cache and start over. Rare enough
            // that one flashed frame is acceptable for now.
            self.glyphs.clearRetainingCapacity();
            self.shelf_x = 0;
            self.shelf_y = 0;
        }
        const loc: GlyphLoc = .{ .uvx = @intCast(self.shelf_x), .uvy = @intCast(self.shelf_y) };
        self.shelf_x += slot_width;

        self.atlas.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            MTLRegion{ .x = loc.uvx, .y = loc.uvy, .z = 0, .w = slot_width, .h = self.cellh_px, .d = 1 },
            @as(u64, 0),
            @as(*const anyopaque, self.scratch_data),
            @as(u64, self.scratch_w),
        });

        return loc;
    }

    // --- Procedural sprites: exact-pixel, seam-free ---

    fn fillRect(self: *Renderer, x: usize, y: usize, w: usize, h: usize, val: u8) void {
        const x1 = @min(x + w, self.scratch_w);
        const y1 = @min(y + h, self.cellh_px);
        var yy = y;
        while (yy < y1) : (yy += 1) {
            @memset(self.scratch_data[yy * self.scratch_w + x .. yy * self.scratch_w + x1], val);
        }
    }

    /// Draw cp into the scratch bitmap if it's a supported box-drawing or
    /// block-element character. Returns false to fall back to the font.
    fn drawSprite(self: *Renderer, cp: u21) bool {
        const w = self.cellw_px;
        const h = self.cellh_px;

        // Block elements: pure rectangle fills.
        switch (cp) {
            0x2580 => self.fillRect(0, 0, w, h / 2, 0xFF), // ▀
            0x2581...0x2588 => { // ▁..█ lower eighths
                const k: usize = cp - 0x2580;
                const hh = h * k / 8;
                self.fillRect(0, h - hh, w, hh, 0xFF);
            },
            0x2589...0x258F => { // ▉..▏ left eighths, 7/8 down to 1/8
                const k: usize = 8 - (cp - 0x2588);
                self.fillRect(0, 0, w * k / 8, h, 0xFF);
            },
            0x2590 => self.fillRect(w / 2, 0, w - w / 2, h, 0xFF), // ▐
            0x2591 => self.fillRect(0, 0, w, h, 0x40), // ░
            0x2592 => self.fillRect(0, 0, w, h, 0x80), // ▒
            0x2593 => self.fillRect(0, 0, w, h, 0xC0), // ▓
            0x2594 => self.fillRect(0, 0, w, h / 8, 0xFF), // ▔
            0x2595 => self.fillRect(w - w / 8, 0, w / 8, h, 0xFF), // ▕
            0x2596...0x259F => { // quadrants
                const quads: u4 = switch (cp) {
                    0x2596 => 0b0010, // ▖ ll
                    0x2597 => 0b0001, // ▗ lr
                    0x2598 => 0b1000, // ▘ ul
                    0x2599 => 0b1011, // ▙
                    0x259A => 0b1001, // ▚
                    0x259B => 0b1110, // ▛
                    0x259C => 0b1101, // ▜
                    0x259D => 0b0100, // ▝ ur
                    0x259E => 0b0110, // ▞
                    0x259F => 0b0111, // ▟
                    else => unreachable,
                };
                const hw = w / 2;
                const hh = h / 2;
                if (quads & 0b1000 != 0) self.fillRect(0, 0, hw, hh, 0xFF);
                if (quads & 0b0100 != 0) self.fillRect(hw, 0, w - hw, hh, 0xFF);
                if (quads & 0b0010 != 0) self.fillRect(0, hh, hw, h - hh, 0xFF);
                if (quads & 0b0001 != 0) self.fillRect(hw, hh, w - hw, h - hh, 0xFF);
            },
            else => return self.drawBoxLines(cp),
        }
        return true;
    }

    fn drawBoxLines(self: *Renderer, cp: u21) bool {
        // Light (and heavy, drawn identically) line segments as a
        // {up,down,left,right} bitset. Rounded corners map to sharp.
        const U: u4 = 0b1000;
        const D: u4 = 0b0100;
        const L: u4 = 0b0010;
        const R: u4 = 0b0001;
        const seg: u4 = switch (cp) {
            0x2500, 0x2501 => L | R, // ─ ━
            0x2502, 0x2503 => U | D, // │ ┃
            0x250C, 0x250F, 0x256D => R | D, // ┌ ┏ ╭
            0x2510, 0x2513, 0x256E => L | D, // ┐ ┓ ╮
            0x2514, 0x2517, 0x2570 => R | U, // └ ┗ ╰
            0x2518, 0x251B, 0x256F => L | U, // ┘ ┛ ╯
            0x251C, 0x2523 => U | D | R, // ├ ┣
            0x2524, 0x252B => U | D | L, // ┤ ┫
            0x252C, 0x2533 => L | R | D, // ┬ ┳
            0x2534, 0x253B => L | R | U, // ┴ ┻
            0x253C, 0x254B => U | D | L | R, // ┼ ╋
            0x2574 => L, // ╴
            0x2575 => U, // ╵
            0x2576 => R, // ╶
            0x2577 => D, // ╷
            else => return false,
        };

        const w = self.cellw_px;
        const h = self.cellh_px;
        const t = @max(2, h / 14);
        const cx = (w - t) / 2;
        const cy = (h - t) / 2;
        if (seg & L != 0) self.fillRect(0, cy, cx + t, t, 0xFF);
        if (seg & R != 0) self.fillRect(cx, cy, w - cx, t, 0xFF);
        if (seg & U != 0) self.fillRect(cx, 0, t, cy + t, 0xFF);
        if (seg & D != 0) self.fillRect(cx, cy, t, h - cy, 0xFF);
        return true;
    }

    /// The CPU-visible cell array to fill before draw().
    pub fn cells(self: *Renderer) []CellData {
        const ptr = self.cells_buf.msgSend(?[*]CellData, "contents", .{}).?;
        return ptr[0..self.cells_cap];
    }

    /// Draw one cell-grid region at a pixel origin, reading cells from
    /// `cell_off` (in cells) into the shared buffer. A frame with N panes
    /// is N of these — same pipelines, different uniforms and offsets.
    pub fn drawGrid(self: *Renderer, encoder: objc.Object, vp_w: f32, vp_h: f32, origin_x: f32, origin_y: f32, cell_off: usize, cols: u32, rows: u32) void {
        const uni = Uniforms{
            .vp = .{ vp_w, vp_h },
            .cell = .{ self.cell_w, self.cell_h },
            .cols = cols,
            .atlas = .{ @floatFromInt(atlas_px), @floatFromInt(atlas_px) },
            .origin = .{ origin_x, origin_y },
        };
        const n: u64 = @as(u64, cols) * rows;
        const byte_off: u64 = cell_off * @sizeOf(CellData);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.bg_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(Uniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{ self.cells_buf.value, byte_off, @as(u64, 1) });
        // MTLPrimitiveTypeTriangleStrip = 4
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), n });

        encoder.msgSend(void, "setRenderPipelineState:", .{self.fg_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(Uniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{ self.cells_buf.value, byte_off, @as(u64, 1) });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ self.atlas.value, @as(u64, 0) });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ self.color_atlas.value, @as(u64, 1) });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), n });
    }

    /// The glyph half of `drawGrid`, without the background pass. The bg
    /// pipeline does NOT blend — it writes cell backgrounds straight
    /// through, alpha included — so running it over an already-painted
    /// shape squares that shape off (and, at alpha 0, punches a hole in
    /// it). Chrome that sits on a pill or a card draws with this.
    pub fn drawGlyphs(self: *Renderer, encoder: objc.Object, vp_w: f32, vp_h: f32, origin_x: f32, origin_y: f32, cell_off: usize, cols: u32, rows: u32) void {
        const uni = Uniforms{
            .vp = .{ vp_w, vp_h },
            .cell = .{ self.cell_w, self.cell_h },
            .cols = cols,
            .atlas = .{ @floatFromInt(atlas_px), @floatFromInt(atlas_px) },
            .origin = .{ origin_x, origin_y },
        };
        const n: u64 = @as(u64, cols) * rows;
        const byte_off: u64 = cell_off * @sizeOf(CellData);
        encoder.msgSend(void, "setRenderPipelineState:", .{self.fg_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(Uniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{ self.cells_buf.value, byte_off, @as(u64, 1) });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ self.atlas.value, @as(u64, 0) });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ self.color_atlas.value, @as(u64, 1) });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), n });
    }

    /// Solid rect (separators, focus edges, pane backgrounds): the bg
    /// pipeline with cell = the rect and one instance passed inline.
    pub fn drawRect(self: *Renderer, encoder: objc.Object, vp_w: f32, vp_h: f32, x: f32, y: f32, w: f32, h: f32, rgba: [4]u8) void {
        if (w < 0.5 or h < 0.5) return;
        const uni = Uniforms{
            .vp = .{ vp_w, vp_h },
            .cell = .{ w, h },
            .cols = 1,
            .atlas = .{ @floatFromInt(atlas_px), @floatFromInt(atlas_px) },
            .origin = .{ x, y },
        };
        const cell = CellData{ .bg = rgba, .fg = .{ 0, 0, 0, 0 }, .uvx = 0, .uvy = 0, .flags = 0 };
        encoder.msgSend(void, "setRenderPipelineState:", .{self.bg_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(Uniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &cell), @as(u64, @sizeOf(CellData)), @as(u64, 1) });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), @as(u64, 1) });
    }

    /// A rounded rect, a border, or a shadow — one signed-distance
    /// field, so the chrome's cards and chips are still just quads on
    /// the same encoder as the grid.
    pub fn drawRoundRect(self: *Renderer, encoder: objc.Object, vp_w: f32, vp_h: f32, x: f32, y: f32, w: f32, h: f32, rgba: [4]u8, style: RectStyle) void {
        if (w < 0.5 or h < 0.5) return;
        const uni = RRUniforms{
            .vp = .{ vp_w, vp_h, 0, 0 },
            .rect = .{ x, y, w, h },
            .params = .{ style.radius, style.border, style.soften, 0 },
            .fill = norm(rgba),
            .edge = norm(style.border_color),
        };
        encoder.msgSend(void, "setRenderPipelineState:", .{self.rr_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(RRUniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(RRUniforms)), @as(u64, 0) });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), @as(u64, 1) });
    }
};

fn makePipeline(device: objc.Object, lib: objc.Object, vs: [*:0]const u8, fs: [*:0]const u8, blend: bool) !objc.Object {
    const vfn = lib.msgSend(objc.Object, "newFunctionWithName:", .{nsString(vs).value});
    const ffn = lib.msgSend(objc.Object, "newFunctionWithName:", .{nsString(fs).value});
    if (vfn.value == null or ffn.value == null) return error.ShaderFunctionMissing;

    const desc = objc.getClass("MTLRenderPipelineDescriptor").?
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    desc.msgSend(void, "setVertexFunction:", .{vfn.value});
    desc.msgSend(void, "setFragmentFunction:", .{ffn.value});
    const att = desc.msgSend(objc.Object, "colorAttachments", .{})
        .msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(u64, 0)});
    // MTLPixelFormatBGRA8Unorm = 80
    att.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
    if (blend) {
        att.msgSend(void, "setBlendingEnabled:", .{true});
        // premultiplied: src=one(1), dst=oneMinusSourceAlpha(5)
        att.msgSend(void, "setSourceRGBBlendFactor:", .{@as(u64, 1)});
        att.msgSend(void, "setDestinationRGBBlendFactor:", .{@as(u64, 5)});
        att.msgSend(void, "setSourceAlphaBlendFactor:", .{@as(u64, 1)});
        att.msgSend(void, "setDestinationAlphaBlendFactor:", .{@as(u64, 5)});
    }

    var err_id: objc.c.id = null;
    const pso = device.msgSend(objc.Object, "newRenderPipelineStateWithDescriptor:error:", .{ desc.value, &err_id });
    if (pso.value == null) {
        logNSError(err_id);
        return error.PipelineFailed;
    }
    return pso;
}

fn nsString(s: [*:0]const u8) objc.Object {
    return objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

fn logNSError(err_id: objc.c.id) void {
    if (err_id == null) return;
    const desc = objc.Object.fromId(err_id).msgSend(objc.Object, "localizedDescription", .{});
    const cstr = desc.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr) |s| std.debug.print("metal error: {s}\n", .{s});
}
