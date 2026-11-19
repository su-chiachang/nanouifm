//! The real share sheet behind `Hooks.share`: an NSSharingServicePicker over the files' URLs,
//! shown relative to the Share button inside the key window's content view. For main.zig only:
//! compiled and linked, not exercised (it shows system UI). The button's place arrives in the
//! window's points with the origin at the top left; a content view that is not flipped (nanoui's
//! view may or may not be) gets the y turned over.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const hooks = @import("hooks.zig");

pub fn share(paths: []const []const u8, anchor: hooks.Anchor) void {
    if (paths.len == 0) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const window = objc.msg(?objc.Object, app, "keyWindow", .{}) orelse return;
    const view = objc.msg(?objc.Object, window, "contentView", .{}) orelse return;
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, paths.len)});
    for (paths) |p| {
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
        objc.msg(void, arr, "addObject:", .{url});
    }
    const picker = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSSharingServicePicker"), "alloc", .{}), "initWithItems:", .{arr});
    // The picker is retained by AppKit while it is shown; ours is autoreleased with the pool.
    objc.autorelease(picker);
    const bounds = objc.msg(objc.CGRect, view, "bounds", .{});
    const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
    const y: objc.CGFloat = if (flipped) anchor.y else bounds.size.height - anchor.y - anchor.h;
    const rect: objc.CGRect = .{
        .origin = .{ .x = anchor.x, .y = y },
        .size = .{ .width = anchor.w, .height = anchor.h },
    };
    const min_y_edge: objc.NSUInteger = 1; // NSRectEdgeMinY
    objc.msg(void, picker, "showRelativeToRect:ofView:preferredEdge:", .{ rect, view, min_y_edge });
}
