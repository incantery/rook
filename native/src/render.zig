//! Metal cell-grid renderer: CoreText-rasterized ASCII atlas, one instanced
//! draw for cell backgrounds, one for glyphs (premultiplied alpha). The
//! renderer is a framebuffer, never a text engine — cell layout authority
//! stays with ghostty-vt.

const std = @import("std");
const objc = @import("objc");

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };

// CoreText / CoreGraphics externs.
const CFStringRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CGContextRef = ?*anyopaque;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const anyopaque) CTFontRef;
extern "c" fn CTFontGetAscent(font: CTFontRef) f64;
extern "c" fn CTFontGetDescent(font: CTFontRef) f64;
extern "c" fn CTFontGetLeading(font: CTFontRef) f64;
extern "c" fn CTFontGetGlyphsForCharacters(font: CTFontRef, chars: [*]const u16, glyphs: [*]u16, count: isize) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: c_int, glyphs: [*]const u16, advances: ?[*]CGSize, count: isize) f64;
extern "c" fn CTFontDrawGlyphs(font: CTFontRef, glyphs: [*]const u16, positions: [*]const CGPoint, count: usize, ctx: CGContextRef) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits_per_comp: usize, bytes_per_row: usize, space: ?*anyopaque, info: u32) CGContextRef;
extern "c" fn CGBitmapContextGetData(ctx: CGContextRef) ?[*]u8;

const utf8_encoding: u32 = 0x08000100;
const alpha_only: u32 = 7; // kCGImageAlphaOnly

pub const MTLRegion = extern struct { x: u64, y: u64, z: u64, w: u64, h: u64, d: u64 };
pub const MTLRegionPub = MTLRegion;

/// Per-cell GPU data; must match the MSL CellData layout (stride 12).
pub const CellData = extern struct {
    bg: [4]u8,
    fg: [4]u8,
    glyph: u32,
};

/// Must match the MSL Uni layout.
const Uniforms = extern struct {
    vp: [2]f32,
    cell: [2]f32,
    cols: u32,
    atlas_cols: u32,
    atlas_uv: [2]f32,
};

const shader_src =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct Uni { float2 vp; float2 cell; uint cols; uint atlas_cols; float2 atlas_uv; };
    \\struct CellData { uchar4 bg; uchar4 fg; uint glyph; };
    \\struct VOut { float4 pos [[position]]; float4 color; float2 uv; };
    \\
    \\vertex VOut bg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                  constant Uni& u [[buffer(0)]],
    \\                  const device CellData* cells [[buffer(1)]]) {
    \\  uint col = iid % u.cols; uint row = iid / u.cols;
    \\  float2 corner = float2(vid & 1, vid >> 1);
    \\  float2 px = (float2(col, row) + corner) * u.cell;
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
    \\  uint g = cells[iid].glyph;
    \\  VOut o;
    \\  if (g == 0) { o.pos = float4(-2.0, -2.0, 0.0, 1.0); o.color = float4(0.0); o.uv = float2(0.0); return o; }
    \\  uint col = iid % u.cols; uint row = iid / u.cols;
    \\  float2 corner = float2(vid & 1, vid >> 1);
    \\  float2 px = (float2(col, row) + corner) * u.cell;
    \\  o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    \\  o.color = float4(cells[iid].fg) / 255.0;
    \\  o.uv = (float2(g % u.atlas_cols, g / u.atlas_cols) + corner) * u.atlas_uv;
    \\  return o;
    \\}
    \\fragment float4 fg_fs(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    \\  constexpr sampler s(coord::normalized, filter::nearest);
    \\  float a = atlas.sample(s, in.uv).r;
    \\  return float4(in.color.rgb * a, a);
    \\}
;

const atlas_cols: u32 = 16;
const atlas_rows: u32 = 6; // 96 slots; glyph 0 stays empty (space)

pub const Renderer = struct {
    device: objc.Object,
    bg_pso: objc.Object,
    fg_pso: objc.Object,
    atlas: objc.Object,
    cells_buf: objc.Object,
    cells_cap: usize,

    /// Cell size in device pixels.
    cell_w: f32,
    cell_h: f32,
    /// Glyph slot size in the atlas (pixels) as normalized uv step.
    atlas_uv: [2]f32,

    pub fn init(gpa: std.mem.Allocator, device: objc.Object, font_name: [*:0]const u8, font_px: f64, max_cells: usize) !Renderer {
        _ = gpa; // will return for the dynamic atlas
        // --- Font + metrics ---
        const name = CFStringCreateWithCString(null, font_name, utf8_encoding);
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

        // --- Rasterize ASCII 33..126 into an alpha-only bitmap ---
        const atlas_w = cell_w * atlas_cols;
        const atlas_h = cell_h * atlas_rows;
        const ctx = CGBitmapContextCreate(null, atlas_w, atlas_h, 8, atlas_w, null, alpha_only);
        if (ctx == null) return error.BitmapFailed;

        // CG's bottom-left origin lives in the coordinate transform; the
        // bitmap MEMORY is already top-down (row 0 = image top), which is
        // Metal's convention too. So: position baselines in CG coords and
        // upload the buffer as-is. (A manual row flip here both mirrors
        // every glyph and scrambles the slot rows — day-two lesson.)
        var chars: [94]u16 = undefined;
        var glyphs: [94]u16 = undefined;
        var positions: [94]CGPoint = undefined;
        for (0..94) |i| {
            chars[i] = @intCast(33 + i);
            const slot = i + 1; // glyph index 0 = empty
            const sx: f64 = @floatFromInt((slot % atlas_cols) * cell_w);
            const sy_top: f64 = @floatFromInt((slot / atlas_cols) * cell_h);
            const baseline_y = @as(f64, @floatFromInt(atlas_h)) - sy_top - @as(f64, @floatFromInt(cell_h)) + descent;
            positions[i] = .{ .x = sx, .y = baseline_y };
        }
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 94);
        CTFontDrawGlyphs(font, &glyphs, &positions, 94, ctx);

        const data = CGBitmapContextGetData(ctx) orelse return error.BitmapFailed;

        // --- Metal texture ---
        // MTLPixelFormatR8Unorm = 10
        const tdesc = objc.getClass("MTLTextureDescriptor").?.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ @as(u64, 10), @as(u64, atlas_w), @as(u64, atlas_h), false },
        );
        const atlas = device.msgSend(objc.Object, "newTextureWithDescriptor:", .{tdesc.value});
        atlas.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            MTLRegion{ .x = 0, .y = 0, .z = 0, .w = atlas_w, .h = atlas_h, .d = 1 },
            @as(u64, 0),
            @as(*const anyopaque, data),
            @as(u64, atlas_w),
        });

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

        // --- Cell buffer (shared storage) ---
        const cells_buf = device.msgSend(objc.Object, "newBufferWithLength:options:", .{
            @as(u64, max_cells * @sizeOf(CellData)),
            @as(u64, 0), // MTLResourceStorageModeShared
        });

        return .{
            .device = device,
            .bg_pso = bg_pso,
            .fg_pso = fg_pso,
            .atlas = atlas,
            .cells_buf = cells_buf,
            .cells_cap = max_cells,
            .cell_w = @floatFromInt(cell_w),
            .cell_h = @floatFromInt(cell_h),
            .atlas_uv = .{ 1.0 / @as(f32, @floatFromInt(atlas_cols)), 1.0 / @as(f32, @floatFromInt(atlas_rows)) },
        };
    }

    /// The CPU-visible cell array to fill before draw().
    pub fn cells(self: *Renderer) []CellData {
        const ptr = self.cells_buf.msgSend(?[*]CellData, "contents", .{}).?;
        return ptr[0..self.cells_cap];
    }

    pub fn draw(self: *Renderer, encoder: objc.Object, vp_w: f32, vp_h: f32, cols: u32, rows: u32) void {
        const uni = Uniforms{
            .vp = .{ vp_w, vp_h },
            .cell = .{ self.cell_w, self.cell_h },
            .cols = cols,
            .atlas_cols = atlas_cols,
            .atlas_uv = self.atlas_uv,
        };
        const n: u64 = @as(u64, cols) * rows;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.bg_pso.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &uni), @as(u64, @sizeOf(Uniforms)), @as(u64, 0) });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{ self.cells_buf.value, @as(u64, 0), @as(u64, 1) });
        // MTLPrimitiveTypeTriangleStrip = 4
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), n });

        encoder.msgSend(void, "setRenderPipelineState:", .{self.fg_pso.value});
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ self.atlas.value, @as(u64, 0) });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(u64, 4), @as(u64, 0), @as(u64, 4), n });
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
