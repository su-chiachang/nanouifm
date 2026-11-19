//! The real thing behind `Hooks.window_frame`: nanoui's `Window.frame` / `setFrame` (points from the
//! primary screen's top left, the hook's own convention) and the visible frame of the window's
//! screen from `nanoui.screens`. For main.zig only: compiled and linked, never run by a test (a test
//! has no window); main.zig `attach`es the window once it exists.
//!
//! `set` does not resize under the running frame (the hook is called from `Model.applyPending`,
//! inside the view): it keeps the frame and `objc.dispatchMain`s the resize to the next turn of the
//! main loop. A newer request replaces one that has not run yet.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const hooks = @import("hooks.zig");

pub const hook: hooks.WindowFrame = .{ .get = get, .set = set, .visible = visible };

var window: ?*nanoui.Window = null;
var wanted: ?hooks.Frame = null;
var scheduled = false;

/// Tells the hook which window it resizes (main.zig, right after the window is made).
pub fn attach(w: *nanoui.Window) void {
    window = w;
}

fn get() ?hooks.Frame {
    const w = window orelse return null;
    const f = w.frame();
    return .{ .x = f.x, .y = f.y, .w = f.width, .h = f.height };
}

fn visible() ?hooks.Frame {
    const w = window orelse return null;
    var buf: [16]nanoui.Screen = undefined;
    const screens = nanoui.screens.list(&buf);
    if (screens.len == 0) return null;
    const mine = w.screenId();
    for (screens) |s| {
        if (mine != null and s.id == mine.?) return rect(s.visible);
    }
    return rect(screens[0].visible); // the primary screen's
}

fn rect(r: nanoui.screens.Rect) hooks.Frame {
    return .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height };
}

fn set(f: hooks.Frame) void {
    wanted = f;
    if (scheduled) return;
    scheduled = true;
    objc.dispatchMain(null, resize);
}

fn resize(_: ?*anyopaque) callconv(.c) void {
    scheduled = false;
    const w = window orelse return;
    const f = wanted orelse return;
    wanted = null;
    w.setFrame(.{ .x = f.x, .y = f.y, .width = f.w, .height = f.h });
}
