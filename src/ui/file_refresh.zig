//! Keeping the panes truthful after files change: reading again the tabs that show a folder, and
//! selecting what an operation produced (scrolled into sight). Used by every file operation,
//! undo/redo and live refresh. Nothing here holds a path across a reload: callers pass paths
//! they own.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const Tab = @import("tab.zig").Tab;
const Pane = @import("pane.zig").Pane;
const column_ops = @import("column_ops.zig");

fn columnShows(t: *const Tab, folder: []const u8) bool {
    for (t.col.columns.items) |c| if (std.mem.eql(u8, c.path, folder)) return true;
    return false;
}

/// Whether `t` draws the contents of `folder`: as its own folder, an open folder of its list,
/// or one of its columns.
pub fn shows(t: *const Tab, folder: []const u8) bool {
    return std.mem.eql(u8, t.path(), folder) or t.exp.isExpanded(folder) or columnShows(t, folder);
}

fn reloadShowing(m: *Model, list: []const []const u8, later: bool) Allocator.Error!void {
    for (m.panes.items) |*p| {
        for (p.tabs.items) |*t| {
            for (list) |f| {
                if (!shows(t, f)) continue;
                try reload(m, p, t, later);
                break;
            }
        }
    }
}

/// `later`: through the loader when listing is asynchronous. Otherwise now, on this thread, and a
/// request still on its way for the tab is forgotten (it would bring older rows).
fn reload(m: *Model, p: *Pane, t: *Tab, later: bool) Allocator.Error!void {
    if (later) return t.reload(m.opts(p));
    m.loader.cancel(t.id, .reload);
    try t.reload(p.opts(m.show_hidden));
}

/// Reads again every tab (of any pane) that shows one of `folders`, keeping what is selected,
/// NOW: for file operations, which select what they made as soon as it is listed. (The
/// operations themselves run on the main thread too.)
pub fn folders(m: *Model, list: []const []const u8) Allocator.Error!void {
    return reloadShowing(m, list, false);
}

/// `folders` for a change somebody else made (the watcher): through the loader, so a big folder
/// does not stall a frame.
pub fn foldersLater(m: *Model, list: []const []const u8) Allocator.Error!void {
    return reloadShowing(m, list, true);
}

/// The folders that hold `paths` (each once), for `folders`. Free with `freeParents`.
pub fn parentsOf(gpa: Allocator, paths: []const []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    outer: for (paths) |p| {
        const d = std.fs.path.dirname(p) orelse continue;
        for (out.items) |o| if (std.mem.eql(u8, o, d)) continue :outer;
        try out.append(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

/// Reads again the tabs that show the folders holding `paths`.
pub fn parents(m: *Model, paths: []const []const u8) Allocator.Error!void {
    const list = try parentsOf(m.gpa, paths);
    defer m.gpa.free(list);
    try folders(m, list);
}

/// Every tab again (after undo/redo: the service doesn't say what it touched).
pub fn all(m: *Model) Allocator.Error!void {
    for (m.panes.items) |*p| for (p.tabs.items) |*t| try reload(m, p, t, false);
}

/// Selects `paths` in pane `pane_index` (those its rows show) and scrolls the first into sight.
pub fn select(m: *Model, pane_index: usize, paths: []const []const u8) Allocator.Error!void {
    if (pane_index >= m.panes.items.len or paths.len == 0) return;
    const pane = &m.panes.items[pane_index];
    const tab = pane.tab();
    if (try m.loader.selectAfter(tab.id, paths)) return; // its rows are still being read: select when they land
    const opts = m.opts(pane);
    if (pane.view_mode == .column) return column_ops.selectPaths(m.gpa, tab, opts, paths);
    tab.selection.clear(m.gpa);
    var first: ?usize = null;
    for (paths) |p| {
        const i = tab.exp.indexOf(p) orelse continue;
        try tab.selection.click(m.gpa, tab.exp.items, i, .{ .cmd = true });
        if (first == null) first = i;
    }
    tab.reveal = first;
}
