//! The real file-icon provider (`Hooks.file_icon`): NSWorkspace's icon for a file type (by its
//! extension: `iconForContentType:` of the UTType, else `iconForFileType:`), for plain folders and
//! files (the UTIs `public.folder` and `public.data`), or for one item by path (`iconForFile:`: an
//! application, the root, the home folder), drawn into a small BGRA bitmap through `cg_pixels.zig`.
//! For main.zig only: no test reaches it.
//!
//! The provider is called from INSIDE the view pass, so it only copies the key into a job and posts
//! the job to the main queue (`objc.dispatchMain`); the NSWorkspace calls and the drawing happen
//! there, between frames, and the pixels go to the cache's `Done` (which copies them and wakes a
//! frame). The cache keeps at most a few requests in flight, so the queue never fills up.
//!
//! Compiled and linked; NOT exercised (it needs a running app). A missing class or an icon that
//! can't be drawn ends in `done.finish(null)`: the generic symbol stays.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const file_icons = @import("file_icons.zig");
const cg = @import("cg_pixels.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

const gpa = std.heap.smp_allocator;

const Kind = enum { folder, file, ext, path };

/// One request, owned by the main-queue block that runs it.
const Job = struct {
    done: file_icons.Done,
    kind: Kind,
    side: u32,
    /// The extension or the path (owned; empty for folders and files).
    text: []u8,
};

pub fn provider(key: file_icons.Key, side: u32, done: file_icons.Done) void {
    var kind: Kind = .folder;
    var text: []const u8 = "";
    switch (key) {
        .folder => {},
        .file => kind = .file,
        .ext => |e| {
            kind = .ext;
            text = e;
        },
        .path => |p| {
            kind = .path;
            text = p;
        },
    }
    const job = gpa.create(Job) catch return done.finish(null);
    const copy = gpa.dupe(u8, text) catch {
        gpa.destroy(job);
        return done.finish(null);
    };
    job.* = .{ .done = done, .kind = kind, .side = side, .text = copy };
    objc.dispatchMain(job, run);
}

/// On the main thread, outside any frame.
fn run(ctx: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    defer {
        gpa.free(job.text);
        gpa.destroy(job);
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const px = render(job) orelse return job.done.finish(null);
    defer gpa.free(px.bytes);
    job.done.finish(.{ .bgra = px.bytes, .width = px.width, .height = px.height });
}

fn render(job: *const Job) ?cg.Bgra {
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const image: ?objc.Object = switch (job.kind) {
        .folder => forFileType(ws, "public.folder"),
        .file => forFileType(ws, "public.data"),
        .ext => forExtension(ws, job.text),
        .path => objc.msg(?objc.Object, ws, "iconForFile:", .{objc.nsString(job.text)}),
    };
    const img = image orelse return null;
    // The best representation for a square of `side` points (the screen's density gives it more
    // pixels), as a CGImage that lives as long as the pool; then scaled to exactly `side` pixels.
    const s: objc.CGFloat = @floatFromInt(job.side);
    var rect: objc.CGRect = .{ .size = .{ .width = s, .height = s } };
    const none: ?objc.Object = null;
    const cgimg = objc.msg(?cg.CGImageRef, img, "CGImageForProposedRect:context:hints:", .{ @as(?*objc.CGRect, &rect), none, none }) orelse return null;
    return cg.read(gpa, cgimg, job.side, job.side);
}

/// `iconForFileType:` takes an extension or a UTI (deprecated since macOS 12, still there).
fn forFileType(ws: objc.Object, file_type: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, ws, "iconForFileType:", .{objc.nsString(file_type)});
}

/// The icon of files named `*.ext`: through the UTType when that class is loaded, else by extension.
fn forExtension(ws: objc.Object, ext: []const u8) ?objc.Object {
    if (objc_getClass("UTType")) |ut_class| {
        const t = objc.msg(?objc.Object, ut_class, "typeWithFilenameExtension:", .{objc.nsString(ext)});
        if (t) |ut| if (objc.msg(?objc.Object, ws, "iconForContentType:", .{ut})) |i| return i;
    }
    return forFileType(ws, ext);
}
