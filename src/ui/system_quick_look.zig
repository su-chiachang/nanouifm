//! The real thing behind `Hooks.quick_look`: the system's QLPreviewPanel (QuickLookUI), driven
//! through nanoui's `objc.msg` and one class made at run time (`objc.defineClass`) that is both
//! the panel's data source and its delegate. For main.zig only: no test reaches it, and nothing
//! here can be exercised without showing a window.
//!
//! The panel normally finds its controller on the responder chain
//! (`acceptsPreviewPanelControl:` and friends, which nanoui's views don't implement), so, as the
//! Swift app does, the data source and delegate are set on the shared panel directly when it is
//! shown. The list is an NSArray of NSURLs the controller keeps retained; an arrow key pressed
//! while the panel is key reaches `previewPanel:handleEvent:`, which queues the same `nav`
//! action the list's own arrow keys do (so the selection moves, and `quick_look.sync` then hands
//! the panel the new item) and wakes a frame. A missing framework makes every call a no-op.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const hooks = @import("hooks.zig");
const Model = @import("model.zig").Model;
const NavKey = @import("nav_key.zig").NavKey;

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

pub const hook: hooks.QuickLook = .{ .toggle = toggle, .update = update, .is_open = isOpen };

/// The NSMutableArray of NSURLs the panel previews (retained).
var items: ?objc.Object = null;
/// The data source and delegate (made once, kept for the life of the process).
var controller: ?objc.Object = null;
/// Where the panel's arrow keys go.
var model: ?*Model = null;

/// The model the panel's arrow keys act on (main.zig, once, before the first Quick Look).
pub fn attach(m: *Model) void {
    model = m;
}

fn sharedPanel() ?objc.Object {
    const cls = objc_getClass("QLPreviewPanel") orelse return null;
    return objc.msg(?objc.Object, cls, "sharedPreviewPanel", .{});
}

fn isOpen() bool {
    const cls = objc_getClass("QLPreviewPanel") orelse return false;
    if (!objc.msg(objc.BOOL, cls, "sharedPreviewPanelExists", .{})) return false;
    const panel = objc.msg(?objc.Object, cls, "sharedPreviewPanel", .{}) orelse return false;
    return objc.msg(objc.BOOL, panel, "isVisible", .{});
}

fn toggle(paths: []const []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = sharedPanel() orelse return;
    const none: ?objc.Object = null;
    if (isOpen()) {
        objc.msg(void, panel, "orderOut:", .{none});
        return;
    }
    if (paths.len == 0) return;
    setItems(paths);
    const ctl = ensureController();
    objc.msg(void, panel, "setDataSource:", .{ctl});
    objc.msg(void, panel, "setDelegate:", .{ctl});
    objc.msg(void, panel, "reloadData", .{});
    objc.msg(void, panel, "setCurrentPreviewItemIndex:", .{@as(objc.NSInteger, 0)});
    objc.msg(void, panel, "makeKeyAndOrderFront:", .{none});
}

fn update(paths: []const []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = sharedPanel() orelse return;
    if (paths.len == 0) return;
    setItems(paths);
    objc.msg(void, panel, "reloadData", .{});
    objc.msg(void, panel, "setCurrentPreviewItemIndex:", .{@as(objc.NSInteger, 0)});
}

/// A new NSArray of file URLs for `paths`, replacing (and releasing) the old one.
fn setItems(paths: []const []const u8) void {
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, paths.len)});
    for (paths) |p| {
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
        objc.msg(void, arr, "addObject:", .{url});
    }
    const kept = objc.retain(arr);
    if (items) |old| objc.release(old);
    items = kept;
}

fn ensureController() objc.Object {
    if (controller) |c| return c;
    const cls = objc.defineClass(.{
        .name = "NanofmQuickLook",
        .protocols = &.{ "QLPreviewPanelDataSource", "QLPreviewPanelDelegate" },
        .methods = &.{
            .{ .name = "numberOfPreviewItemsInPreviewPanel:", .imp = &itemCount, .types = "q@:@" },
            .{ .name = "previewPanel:previewItemAtIndex:", .imp = &itemAt, .types = "@@:@q" },
            .{ .name = "previewPanel:handleEvent:", .imp = &handleEvent, .types = "B@:@@" },
        },
    });
    const c = objc.msg(objc.Object, cls, "new", .{});
    controller = c;
    return c;
}

fn itemCount(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSInteger {
    const arr = items orelse return 0;
    return @intCast(objc.msg(objc.NSUInteger, arr, "count", .{}));
}

/// An NSURL is a QLPreviewItem (QuickLookUI adds `previewItemURL` to it).
fn itemAt(_: objc.Object, _: objc.SEL, _: objc.Object, index: objc.NSInteger) callconv(.c) ?objc.Object {
    const arr = items orelse return null;
    const n: objc.NSInteger = @intCast(objc.msg(objc.NSUInteger, arr, "count", .{}));
    if (index < 0 or index >= n) return null;
    return objc.msg(?objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, @intCast(index))});
}

/// The arrow keys (key codes 123 left, 124 right, 125 down, 126 up) move the selection in the
/// window behind the panel, as in the Swift app; every other key is the panel's own.
fn handleEvent(_: objc.Object, _: objc.SEL, _: objc.Object, event: objc.Object) callconv(.c) objc.BOOL {
    const key_down: objc.NSUInteger = 10; // NSEventTypeKeyDown
    if (objc.msg(objc.NSUInteger, event, "type", .{}) != key_down) return false;
    const nav: NavKey = switch (objc.msg(u16, event, "keyCode", .{})) {
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        else => return false,
    };
    const m = model orelse return false;
    const shift = objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & (1 << 17) != 0; // NSEventModifierFlagShift
    m.queue(.{ .nav = .{ .key = nav, .shift = shift } }) catch return false;
    if (m.waker) |w| w.wake(w.ctx);
    return true;
}
