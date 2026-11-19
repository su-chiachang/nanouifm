//! The real thing behind `Hooks.open_with`, through NSWorkspace and `objc.msg`. For main.zig only:
//! compiled and linked, never run by a test (it asks Launch Services and launches apps).
//!
//! `list`: the default app (`URLForApplicationToOpenURL:`) first, then the others from
//! `URLsForApplicationsToOpenURL:` (macOS 12+; older systems get the default only), each once,
//! named as Finder names it (the bundle's display name without ".app"). `open`:
//! `openURLs:withApplicationAtURL:configuration:completionHandler:` with no handler, so success is
//! not reported back: the call returns true once the request is made.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const hooks = @import("hooks.zig");

pub const hook: hooks.OpenWith = .{ .list = list, .open = open };

fn fileUrl(path: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

fn workspace() objc.Object {
    return objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
}

/// Appends the app at `url` unless its path is already in `out`.
fn add(gpa: Allocator, out: *std.ArrayList(hooks.OpenApp), url: objc.Object, fm: objc.Object) Allocator.Error!void {
    const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
    if (path.len == 0) return;
    for (out.items) |a| if (std.mem.eql(u8, a.path, path)) return;
    var name = objc.fromNSString(objc.msg(?objc.Object, fm, "displayNameAtPath:", .{objc.nsString(path)}));
    if (name.len == 0) name = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, name, ".app")) name = name[0 .. name.len - 4];
    const p = try gpa.dupe(u8, path);
    errdefer gpa.free(p);
    const n = try gpa.dupe(u8, name);
    errdefer gpa.free(n);
    try out.append(gpa, .{ .name = n, .path = p });
}

fn list(gpa: Allocator, file: []const u8) Allocator.Error![]hooks.OpenApp {
    const pool = objc.Pool.push();
    defer pool.pop();
    var out: std.ArrayList(hooks.OpenApp) = .empty;
    errdefer {
        for (out.items) |a| {
            gpa.free(a.name);
            gpa.free(a.path);
        }
        out.deinit(gpa);
    }
    const ws = workspace();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const url = fileUrl(file);
    if (objc.msg(?objc.Object, ws, "URLForApplicationToOpenURL:", .{url})) |def| try add(gpa, &out, def, fm);
    if (objc.msg(objc.BOOL, ws, "respondsToSelector:", .{objc.sel("URLsForApplicationsToOpenURL:")})) {
        if (objc.msg(?objc.Object, ws, "URLsForApplicationsToOpenURL:", .{url})) |urls| {
            const n = objc.msg(objc.NSUInteger, urls, "count", .{});
            var i: objc.NSUInteger = 0;
            while (i < n and out.items.len < 16) : (i += 1) {
                try add(gpa, &out, objc.msg(objc.Object, urls, "objectAtIndex:", .{i}), fm);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn open(app_path: []const u8, file: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = workspace();
    const files = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, files, "addObject:", .{fileUrl(file)});
    const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    const no_handler: ?*anyopaque = null;
    objc.msg(void, ws, "openURLs:withApplicationAtURL:configuration:completionHandler:", .{ files, fileUrl(app_path), config, no_handler });
    return true;
}
