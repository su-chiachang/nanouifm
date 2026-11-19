//! The model's side of the sidebar: Remove from Sidebar, drops that add or reorder favorites,
//! Open in Split, Eject, the mounted volumes, and the Add to Favorites command. (Pin to Sidebar
//! is `file_actions.pin`.) Run from `Model.applyPending` and the command registry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const sidebar_model = @import("sidebar_model.zig");
const volumes = @import("volumes.zig");
const target = @import("file_target.zig");
const layout_ops = @import("layout_ops.zig");

/// Reads the mounted volumes again and makes Locations follow them (with no provider, the rows
/// the config gave stay).
pub fn refreshVolumes(m: *Model) Allocator.Error!void {
    const prov = m.volumes orelse return;
    const list = try prov.list(m.gpa);
    defer volumes.Provider.freeList(m.gpa, list);
    const items = try m.gpa.alloc(sidebar_model.Item, list.len);
    defer m.gpa.free(items);
    for (list, items) |v, *it| it.* = .{ .path = v.path, .title = v.title, .ejectable = v.ejectable };
    _ = try m.sidebar.setLocations(items);
}

pub fn remove(m: *Model, id: @import("../core/state_model.zig").Uuid) void {
    _ = m.sidebar.removeEntry(id);
}

pub fn add(m: *Model, a: model_mod.SidebarAdd) Allocator.Error!void {
    const path = try model_mod.normalize(m.gpa, a.path);
    defer m.gpa.free(path);
    try m.sidebar.addEntry(a.kind, path, if (a.at) |i| @as(usize, i) else null);
}

/// Open in Split from the sidebar: the folder in a pane docked right of the focused one.
pub fn openInSplit(m: *Model, folder: []const u8) Allocator.Error!void {
    const path = try model_mod.normalize(m.gpa, folder);
    defer m.gpa.free(path);
    try layout_ops.dock(m, m.focused, .right, path);
    m.clearNotice();
}

/// The eject button: the provider unmounts it (a failure raises the banner); the list is read
/// again either way, since the system's notification may come late.
pub fn eject(m: *Model, path: []const u8) Allocator.Error!void {
    const f = (m.volumes orelse return).eject orelse return;
    if (!f(path)) {
        const name = std.fs.path.basename(path);
        const msg = try std.fmt.allocPrint(m.gpa, "Can't eject \"{s}\".", .{if (name.len == 0) path else name});
        defer m.gpa.free(msg);
        try m.raise(msg);
    }
    try refreshVolumes(m);
}

/// Add to Favorites: the selected folders, or the folder shown when nothing is selected.
pub fn addFavorite(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var folders = try target.selectedFolders(a, m.focusedPane());
    if (target.count(m.focusedPane()) == 0) {
        folders = try a.dupe([]const u8, &.{target.shown(m.focusedPane()).folder});
    } else if (folders.len == 0) {
        return m.raise("Only folders can be added to Favorites.");
    }
    for (folders) |f| try m.sidebar.addEntry(.favorites, f, null);
}
