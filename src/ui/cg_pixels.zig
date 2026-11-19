//! A CGImage as the pixels `ui.image` takes (premultiplied BGRA, top row first), through
//! CoreGraphics' own functions (`extern`, no shims). For the system thumbnail and icon providers
//! only (main.zig's side); callable from any thread, as the thumbnail callback's queue needs.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

pub const CGImageRef = *opaque {};
const CFStringRef = *opaque {};
const CGContextRef = *opaque {};
const CGColorSpaceRef = *opaque {};

extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
extern "c" const kCGColorSpaceSRGB: CFStringRef;
extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) ?CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: ?CGColorSpaceRef, info: u32) ?CGContextRef;
extern "c" fn CGContextRelease(ctx: CGContextRef) void;
extern "c" fn CGContextDrawImage(ctx: CGContextRef, rect: objc.CGRect, image: CGImageRef) void;
extern "c" fn CGContextSetInterpolationQuality(ctx: CGContextRef, quality: c_int) void;

/// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little` (as nanoui's own decoder has it).
const bgra_premultiplied: u32 = 2 | (2 << 12);

pub const Bgra = struct { bytes: []u8, width: u32, height: u32 };

/// `img` drawn into a new `width` x `height` buffer of `gpa` (the image's own size when 0): the
/// caller frees `bytes`. Null when the image or the buffer can't be had.
pub fn read(gpa: std.mem.Allocator, img: CGImageRef, width: usize, height: usize) ?Bgra {
    const w = if (width == 0) CGImageGetWidth(img) else width;
    const h = if (height == 0) CGImageGetHeight(img) else height;
    if (w == 0 or h == 0 or w * h > 16 * 1024 * 1024) return null; // 64 MB of pixels at most
    const out = gpa.alloc(u8, w * h * 4) catch return null;
    @memset(out, 0);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse {
        gpa.free(out);
        return null;
    };
    defer CGColorSpaceRelease(space);
    const ctx = CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse {
        gpa.free(out);
        return null;
    };
    defer CGContextRelease(ctx);
    CGContextSetInterpolationQuality(ctx, 3); // high
    CGContextDrawImage(ctx, .{ .origin = .{}, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .bytes = out, .width = @intCast(w), .height = @intCast(h) };
}
