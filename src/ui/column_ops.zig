//! Column view's operations on a tab: building the stack of columns for the tab's folder, a
//! click or key selecting in a column (a folder selected opens the next column, anything else
//! ends the stack there), moving between columns, and type-to-select. The tab's folder follows
//! the deepest folder shown without a history entry (Swift's `setColumnLocation`), and the tab's
//! selection mirrors the last column's, so toggling to the list keeps both.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Tab = @import("tab.zig").Tab;
const Opts = @import("tab.zig").Opts;
const Listing = @import("listing.zig").Listing;
const Mods = @import("selection.zig").Mods;
const cm = @import("column_model.zig");
const Column = cm.Column;
const NavKey = @import("nav_key.zig").NavKey;
const typeahead = @import("typeahead.zig");
const isSameOrInside = @import("expansion.zig").isSameOrInside;

fn options(o: Opts) cm.Options {
    return .{ .show_hidden = o.show_hidden, .sort = o.sort };
}

/// Makes the stack match the tab's folder: nothing to do when its last column already is the
/// folder (the tab moved by drilling), else it is built again (the tab went elsewhere).
pub fn sync(gpa: Allocator, tab: *Tab, o: Opts) Allocator.Error!void {
    tab.col.freeRetired(gpa);
    if (tab.col.last()) |l| if (std.mem.eql(u8, l.path, tab.path())) return;
    try rebuild(gpa, tab, o);
}

fn parentOr(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse path;
}

fn newColumn(gpa: Allocator, path: []const u8, o: Opts) Allocator.Error!Column {
    const copy = try gpa.dupe(u8, path);
    errdefer gpa.free(copy);
    var listing = try Listing.read(gpa, path);
    errdefer listing.deinit(gpa);
    try listing.rebuild(gpa, o.show_hidden, o.sort);
    return .{ .path = copy, .listing = listing };
}

/// The stack from the remembered root (default: the folder above the tab's) to the tab's folder,
/// each column selecting the folder after it; the last has the tab's selection.
pub fn rebuild(gpa: Allocator, tab: *Tab, o: Opts) Allocator.Error!void {
    const cs = &tab.col;
    cs.truncate(gpa, 0);
    const here = tab.path();
    var root = cs.root orelse parentOr(here);
    if (!isSameOrInside(here, root)) root = parentOr(here);
    try cs.setRoot(gpa, root);
    root = cs.root.?;
    // Folders from `here` up to the root, then walked from the root down.
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(gpa);
    var cur = here;
    while (true) {
        try chain.append(gpa, cur);
        if (std.mem.eql(u8, cur, root)) break;
        cur = std.fs.path.dirname(cur) orelse break;
    }
    std.mem.reverse([]const u8, chain.items);
    for (chain.items, 0..) |p, i| {
        var col = try newColumn(gpa, p, o);
        errdefer col.deinit(gpa);
        if (i + 1 < chain.items.len) {
            try col.selection.selectOnly(gpa, chain.items[i + 1]);
        } else {
            try col.selection.copyFrom(gpa, &tab.selection);
            try col.selection.prune(gpa, col.listing.visible);
        }
        try cs.columns.append(gpa, col);
    }
    cs.active = cs.columns.items.len - 1;
    cs.reveal = true;
}

/// A column's selection changed: the columns after it follow, the tab's folder and selection too.
fn afterSelection(gpa: Allocator, tab: *Tab, o: Opts, depth: usize) Allocator.Error!void {
    const cs = &tab.col;
    var location: []const u8 = cs.columns.items[depth].path;
    var drilled = false;
    if (cs.columns.items[depth].single()) |it| if (it.is_directory) {
        drilled = true;
        location = it.path;
        const next_is_it = depth + 1 < cs.columns.items.len and std.mem.eql(u8, cs.columns.items[depth + 1].path, it.path);
        if (next_is_it) {
            if (cs.columns.items.len > depth + 2) cs.columns.items[depth + 1].selection.clear(gpa);
            cs.truncate(gpa, depth + 2);
        } else {
            cs.truncate(gpa, depth + 1);
            var col = try newColumn(gpa, it.path, o);
            errdefer col.deinit(gpa);
            try cs.columns.append(gpa, col);
        }
    };
    if (!drilled) cs.truncate(gpa, depth + 1);
    cs.active = depth;
    try tab.setColumnLocation(location, o);
    try tab.selection.copyFrom(gpa, &cs.last().?.selection);
    cs.reveal = true;
}

/// A click on row `index` of column `depth`.
pub fn click(gpa: Allocator, tab: *Tab, o: Opts, depth: usize, index: usize, mods: Mods) Allocator.Error!void {
    if (depth >= tab.col.columns.items.len) return;
    try tab.col.columns.items[depth].selection.click(gpa, tab.col.columns.items[depth].items(), index, mods);
    try afterSelection(gpa, tab, o, depth);
}

fn select(gpa: Allocator, tab: *Tab, o: Opts, depth: usize, index: usize, extend: bool) Allocator.Error!void {
    const col = &tab.col.columns.items[depth];
    try col.selection.moveTo(gpa, col.items(), index, extend);
    col.reveal = index;
    try afterSelection(gpa, tab, o, depth);
}

pub fn key(gpa: Allocator, tab: *Tab, o: Opts, k: NavKey, shift: bool) Allocator.Error!void {
    const cs = &tab.col;
    if (cs.columns.items.len == 0) return;
    const depth = @min(cs.active, cs.columns.items.len - 1);
    const col = &cs.columns.items[depth];
    const items = col.items();
    switch (k) {
        .up, .down, .home, .end => {
            if (items.len == 0) return;
            const lead = col.selection.leadIndex(items);
            const target: usize = switch (k) {
                .up => if (lead) |l| l -| 1 else items.len - 1,
                .down => if (lead) |l| @min(l + 1, items.len - 1) else 0,
                .home => 0,
                else => items.len - 1,
            };
            try select(gpa, tab, o, depth, target, shift);
        },
        .right => { // into the folder selected here
            const sel = col.single() orelse return;
            if (!sel.is_directory or depth + 1 >= cs.columns.items.len) return;
            cs.active = depth + 1;
            const next = &cs.columns.items[depth + 1];
            if (next.selection.count() == 0 and next.items().len > 0) try select(gpa, tab, o, depth + 1, 0, false);
        },
        .left => { // back out of this column: its selection goes, the stack ends here
            if (depth == 0) return;
            col.selection.clear(gpa);
            cs.truncate(gpa, depth + 1);
            cs.active = depth - 1;
            try tab.setColumnLocation(cs.columns.items[depth].path, o);
            try tab.selection.copyFrom(gpa, &cs.last().?.selection);
            cs.reveal = true;
        },
    }
}

/// Selects the first row of the active column whose name starts with `prefix`.
pub fn typeSelect(gpa: Allocator, tab: *Tab, o: Opts, prefix: []const u8) Allocator.Error!bool {
    const cs = &tab.col;
    if (cs.columns.items.len == 0) return false;
    const depth = @min(cs.active, cs.columns.items.len - 1);
    const i = typeahead.find(cs.columns.items[depth].items(), prefix) orelse return false;
    try select(gpa, tab, o, depth, i, false);
    return true;
}

/// Selects `paths` (all in one folder, shown by one of the stack's columns) and scrolls the
/// first into sight; the columns after it follow, as for a click. Paths no column shows are
/// ignored.
pub fn selectPaths(gpa: Allocator, tab: *Tab, o: Opts, paths: []const []const u8) Allocator.Error!void {
    if (paths.len == 0) return;
    const folder = std.fs.path.dirname(paths[0]) orelse return;
    const cs = &tab.col;
    for (cs.columns.items, 0..) |*col, depth| {
        if (!std.mem.eql(u8, col.path, folder)) continue;
        col.selection.clear(gpa);
        var first: ?usize = null;
        for (paths) |p| {
            const i = col.listing.indexOf(p) orelse continue;
            try col.selection.click(gpa, col.items(), i, .{ .cmd = true });
            if (first == null) first = i;
        }
        col.reveal = first;
        return afterSelection(gpa, tab, o, depth);
    }
}
