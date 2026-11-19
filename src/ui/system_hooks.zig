//! The real thing behind `Hooks`: the system pasteboard (file URLs, text), Finder, and the
//! keyboard's Option state, Quick Look, thumbnails and the share sheet (the `system_*.zig` files), through nanoui's `clipboard` / `shell` and `objc.msg`. For main.zig
//! only: the model's hooks are empty unless `Config` names these, so no test touches any of it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Hooks = @import("hooks.zig").Hooks;
const system_quick_look = @import("system_quick_look.zig");
const system_thumbs = @import("system_thumbs.zig");
const system_share = @import("system_share.zig");
const system_window = @import("system_window.zig");
const system_open_with = @import("system_open_with.zig");

pub const hooks: Hooks = .{
    .copy_files = copyFiles,
    .copy_text = nanoui.clipboard.writeText,
    .reveal = reveal,
    .read_files = readFiles,
    .change_count = nanoui.clipboard.changeCount,
    .option_held = optionHeld,
    .app_role = appRole,
    .quick_look = system_quick_look.hook,
    .share = system_share.share,
    .thumbnail = system_thumbs.provider,
    .window_frame = system_window.hook,
    .open_with = system_open_with.hook,
};

/// An NSArray of NSURLs for `paths`.
fn urlArray(paths: []const []const u8) objc.Object {
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, paths.len)});
    for (paths) |p| {
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
        objc.msg(void, arr, "addObject:", .{url});
    }
    return arr;
}

/// Copy: the files go on the pasteboard as file URLs, so Finder and other apps can paste them.
fn copyFiles(paths: []const []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    _ = objc.msg(objc.BOOL, pb, "writeObjects:", .{urlArray(paths)});
}

fn reveal(paths: []const []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(void, ws, "activateFileViewerSelectingURLs:", .{urlArray(paths)});
}

fn readFiles(gpa: std.mem.Allocator) ?[][]u8 {
    return nanoui.clipboard.readFiles(gpa) catch null;
}

fn optionHeld() bool {
    const flags = objc.msg(objc.NSUInteger, objc.class("NSEvent"), "modifierFlags", .{});
    return flags & (1 << 19) != 0; // NSEventModifierFlagOption
}

/// Cmd+Q, Cmd+H, Cmd+Opt+H and Cmd+M while a text field has the keyboard (the menu bar's
/// key equivalents are held back then): what the App and Window menus' items do.
fn appRole(role: @import("hooks.zig").AppRole) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const none: ?objc.Object = null;
    switch (role) {
        .quit => objc.msg(void, app, "terminate:", .{none}),
        .hide => objc.msg(void, app, "hide:", .{none}),
        .hide_others => objc.msg(void, app, "hideOtherApplications:", .{none}),
        .minimize => if (objc.msg(?objc.Object, app, "keyWindow", .{})) |w| objc.msg(void, w, "miniaturize:", .{none}),
    }
}
