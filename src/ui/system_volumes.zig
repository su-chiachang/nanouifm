//! The real mounted volumes, for main.zig only (the model takes a `volumes.Provider`; no test
//! reaches this): NSFileManager's list of mounted volumes (the hidden ones skipped), their names
//! and whether they can be ejected (Swift's `SidebarViewController.volumes()`), Eject through
//! NSWorkspace, and the NSWorkspace mount, unmount and rename notifications that mark a
//! `volumes.Signal`. All of it is `objc.msg`; the observer is a class nanoui's `defineClass` makes.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Allocator = std.mem.Allocator;
const volumes = @import("volumes.zig");

pub const provider: volumes.Provider = .{ .list = list, .eject = eject };

const key_ejectable = "NSURLVolumeIsEjectableKey";
const key_removable = "NSURLVolumeIsRemovableKey";
const key_internal = "NSURLVolumeIsInternalKey";
const key_local = "NSURLVolumeIsLocalKey";
const key_browsable = "NSURLVolumeIsBrowsableKey";
/// NSVolumeEnumerationSkipHiddenVolumes
const skip_hidden: objc.NSUInteger = 1 << 1;

fn flag(values: objc.Object, key: []const u8) ?bool {
    const v = objc.msg(?objc.Object, values, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    return objc.msg(objc.BOOL, v, "boolValue", .{});
}

fn list(gpa: Allocator) Allocator.Error![]volumes.Volume {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const keys = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, 5)});
    for ([_][]const u8{ key_ejectable, key_removable, key_internal, key_local, key_browsable }) |k| {
        objc.msg(void, keys, "addObject:", .{objc.nsString(k)});
    }
    var out: std.ArrayList(volumes.Volume) = .empty;
    errdefer {
        for (out.items) |v| {
            gpa.free(v.path);
            gpa.free(v.title);
        }
        out.deinit(gpa);
    }
    const urls = objc.msg(?objc.Object, fm, "mountedVolumeURLsIncludingResourceValuesForKeys:options:", .{ keys, skip_hidden }) orelse return out.toOwnedSlice(gpa);
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
        const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
        if (path.len == 0) continue;
        const values = objc.msg(?objc.Object, url, "resourceValuesForKeys:error:", .{ keys, @as(?objc.Object, null) });
        if (values) |v| if (flag(v, key_browsable) == false) continue;
        const name = objc.fromNSString(objc.msg(?objc.Object, fm, "displayNameAtPath:", .{objc.nsString(path)}));
        // Swift's rule: not the startup volume, and removable, ejectable, external or remote.
        const ejectable = !std.mem.eql(u8, path, "/") and if (values) |v|
            (flag(v, key_ejectable) orelse false) or (flag(v, key_removable) orelse false) or !(flag(v, key_internal) orelse true) or !(flag(v, key_local) orelse true)
        else
            false;
        const p = try gpa.dupe(u8, path);
        errdefer gpa.free(p);
        const t = try gpa.dupe(u8, if (name.len > 0) name else std.fs.path.basename(path));
        errdefer gpa.free(t);
        try out.append(gpa, .{ .path = p, .title = t, .ejectable = ejectable });
    }
    return out.toOwnedSlice(gpa);
}

fn eject(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    return objc.msg(objc.BOOL, ws, "unmountAndEjectDeviceAtURL:error:", .{ url, @as(?objc.Object, null) });
}

fn changed(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const signal = objc.getZig(volumes.Signal, self_obj) orelse return;
    signal.mark();
}

/// A mount, an unmount or a rename of a volume marks `signal` (and wakes the window). The observer
/// lives as long as the app.
pub fn observe(signal: *volumes.Signal) void {
    const cls = objc.defineClass(.{
        .name = "NanofmVolumeObserver",
        .methods = &.{.{ .name = "volumesChanged:", .imp = &changed, .types = "v@:@" }},
    });
    const obs = objc.msg(objc.Object, cls, "new", .{});
    objc.setZig(obs, signal);
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const center = objc.msg(objc.Object, ws, "notificationCenter", .{});
    for ([_][]const u8{ "NSWorkspaceDidMountNotification", "NSWorkspaceDidUnmountNotification", "NSWorkspaceDidRenameVolumeNotification" }) |name| {
        objc.msg(void, center, "addObserver:selector:name:object:", .{ obs, objc.sel("volumesChanged:"), objc.nsString(name), @as(?objc.Object, null) });
    }
}
