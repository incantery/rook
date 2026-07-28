//! Write a BGRA8 pixel buffer to a PNG via ImageIO. Dev tooling only —
//! the `shot` ctl command lands here.

const std = @import("std");

extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: isize, is_dir: bool) ?*anyopaque;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFRelease(obj: ?*anyopaque) void;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: [*]const u8, size: usize, release_cb: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageCreate(w: usize, h: usize, bits_per_comp: usize, bits_per_px: usize, bytes_per_row: usize, space: ?*anyopaque, info: u32, provider: ?*anyopaque, decode: ?*const f64, interpolate: bool, intent: i32) ?*anyopaque;
extern "c" fn CGImageDestinationCreateWithURL(url: ?*anyopaque, ty: ?*anyopaque, count: usize, opts: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageDestinationAddImage(dest: ?*anyopaque, img: ?*anyopaque, props: ?*anyopaque) void;
extern "c" fn CGImageDestinationFinalize(dest: ?*anyopaque) bool;

const utf8_encoding: u32 = 0x08000100;
// kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst: BGRX in memory,
// alpha ignored (the drawable's alpha channel is not meaningful).
const bgrx_info: u32 = 8192 | 6;

pub fn writeBGRA(path: []const u8, w: usize, h: usize, bytes_per_row: usize, pixels: []const u8) !void {
    const url = CFURLCreateFromFileSystemRepresentation(null, pixels_path: {
        // CFURL wants the path without NUL; pass ptr+len of the slice.
        break :pixels_path path.ptr;
    }, @intCast(path.len), false) orelse return error.UrlFailed;
    defer CFRelease(url);

    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpaceFailed;
    defer CFRelease(space);

    const provider = CGDataProviderCreateWithData(null, pixels.ptr, pixels.len, null) orelse return error.ProviderFailed;
    defer CFRelease(provider);

    const img = CGImageCreate(w, h, 8, 32, bytes_per_row, space, bgrx_info, provider, null, false, 0) orelse return error.ImageFailed;
    defer CFRelease(img);

    const png_type = CFStringCreateWithCString(null, "public.png", utf8_encoding) orelse return error.TypeFailed;
    defer CFRelease(png_type);

    const dest = CGImageDestinationCreateWithURL(url, png_type, 1, null) orelse return error.DestFailed;
    defer CFRelease(dest);
    CGImageDestinationAddImage(dest, img, null);
    if (!CGImageDestinationFinalize(dest)) return error.FinalizeFailed;
}
