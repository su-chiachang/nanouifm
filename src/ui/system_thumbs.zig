//! The real thumbnail provider (`Hooks.thumbnail`): QuickLookThumbnailing's
//! `QLThumbnailGenerator`, asked for the best representation (the file's thumbnail, else its
//! icon) at the preview's size and the screen's scale. For main.zig only: no test reaches it.
//!
//! Nothing blocks the UI thread: the request is handed to the generator, whose completion block
//! runs on a queue of its own; there the CGImage is drawn into an owned BGRA buffer (CoreGraphics
//! is thread-safe for that), and the buffer goes to the main thread with `objc.dispatchMain`,
//! where it is given to the cache's `Done` (which copies it and wakes a frame).
//!
//! Compiled and linked; NOT exercised (it needs a running app and the system's thumbnail
//! service). A missing framework or class ends in `done.finish(null)`: the icon stays.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const thumbs = @import("thumbs.zig");
const cg = @import("cg_pixels.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

const gpa = std.heap.smp_allocator;

/// QLThumbnailGenerationRequestRepresentationTypeIcon | ...TypeThumbnail (1 << 0, 1 << 2): the
/// best of them, so a file with no thumbnail still comes back as its icon.
const icon_or_thumbnail: objc.NSUInteger = (1 << 0) | (1 << 2);

/// One request in flight: owned by the completion block until it is taken to the main thread.
const Pending = struct {
    done: thumbs.Done,
    /// The QLThumbnailGenerationRequest (owned: released on the main thread).
    request: objc.Object,
    pixels: ?cg.Bgra = null,
};

pub fn provider(path: []const u8, side: u32, done: thumbs.Done) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const gen_class = objc_getClass("QLThumbnailGenerator") orelse return done.finish(null);
    const req_class = objc_getClass("QLThumbnailGenerationRequest") orelse return done.finish(null);
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const scale = screenScale();
    const s: objc.CGFloat = @floatFromInt(side);
    const request = objc.msg(objc.Object, objc.msg(objc.Object, req_class, "alloc", .{}), "initWithFileAtURL:size:scale:representationTypes:", .{
        url,
        objc.CGSize{ .width = s, .height = s * 0.77 },
        scale,
        icon_or_thumbnail,
    });
    const p = gpa.create(Pending) catch {
        objc.release(request);
        return done.finish(null);
    };
    p.* = .{ .done = done, .request = request };
    const generator = objc.msg(objc.Object, gen_class, "sharedGenerator", .{});
    // The generator copies the block (and with it the pointer to `p`) and calls it on its own queue.
    var block = objc.Block(Pending, &.{ ?objc.Object, ?objc.Object }).init(p, completed);
    objc.msg(void, generator, "generateBestRepresentationForRequest:completionHandler:", .{ request, @as(*anyopaque, @ptrCast(&block)) });
}

fn screenScale() objc.CGFloat {
    const screen = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return 2;
    return objc.msg(objc.CGFloat, screen, "backingScaleFactor", .{});
}

/// On the generator's queue.
fn completed(p: *Pending, rep: ?objc.Object, err: ?objc.Object) void {
    _ = err;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (rep) |r| {
        if (objc.msg(?cg.CGImageRef, r, "CGImage", .{})) |img| p.pixels = cg.read(gpa, img, 0, 0);
    }
    objc.dispatchMain(p, finishOnMain);
}

fn finishOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    defer gpa.destroy(p);
    objc.release(p.request);
    if (p.pixels) |px| {
        defer gpa.free(px.bytes);
        p.done.finish(.{ .bgra = px.bytes, .width = px.width, .height = px.height });
    } else p.done.finish(null);
}
