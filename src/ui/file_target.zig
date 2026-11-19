//! What a file command acts on in a pane: the rows it shows (the list's, or the active column's),
//! what is selected among them, and the folder new things go into. Read-only; the model's
//! `file_actions.zig` does the changing. Paths borrow from the listings, so use them before the
//! next `applyPending` replaces a listing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const FileItem = @import("../core/lister.zig").FileItem;
const Pane = @import("pane.zig").Pane;
const Selection = @import("selection.zig").Selection;

pub const Shown = struct {
    items: []const FileItem,
    sel: *Selection,
    /// The folder the rows are in (new folders, pastes and drops land here).
    folder: []const u8,
    /// The column's depth; null in the list.
    column: ?usize = null,
};

pub fn shown(pane: *Pane) Shown {
    const tab = pane.tab();
    if (pane.view_mode == .column) if (tab.col.activeColumn()) |c| {
        const depth = @min(tab.col.active, tab.col.columns.items.len - 1);
        return .{ .items = c.items(), .sel = &c.selection, .folder = c.path, .column = depth };
    };
    return .{ .items = tab.exp.items, .sel = &tab.selection, .folder = tab.path() };
}

/// How many of the shown rows are selected.
pub fn count(pane: *Pane) usize {
    const s = shown(pane);
    var n: usize = 0;
    for (s.items) |it| {
        if (s.sel.contains(it.path)) n += 1;
    }
    return n;
}

/// The selected items, in row order (free the slice; the items borrow from the listing).
pub fn selected(gpa: Allocator, pane: *Pane) Allocator.Error![]FileItem {
    const s = shown(pane);
    var out: std.ArrayList(FileItem) = .empty;
    errdefer out.deinit(gpa);
    for (s.items) |it| {
        if (s.sel.contains(it.path)) try out.append(gpa, it);
    }
    return out.toOwnedSlice(gpa);
}

/// The selected paths, in row order (free the outer slice).
pub fn selectedPaths(gpa: Allocator, pane: *Pane) Allocator.Error![][]const u8 {
    const s = shown(pane);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (s.items) |it| {
        if (s.sel.contains(it.path)) try out.append(gpa, it.path);
    }
    return out.toOwnedSlice(gpa);
}

/// The one selected item, if exactly one is selected.
pub fn single(pane: *Pane) ?FileItem {
    const s = shown(pane);
    var found: ?FileItem = null;
    for (s.items) |it| {
        if (!s.sel.contains(it.path)) continue;
        if (found != null) return null;
        found = it;
    }
    return found;
}

/// The selected folders among the selection (free the slice).
pub fn selectedFolders(gpa: Allocator, pane: *Pane) Allocator.Error![][]const u8 {
    const s = shown(pane);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (s.items) |it| {
        if (it.is_directory and s.sel.contains(it.path)) try out.append(gpa, it.path);
    }
    return out.toOwnedSlice(gpa);
}
