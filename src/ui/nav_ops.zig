//! The model's side of selection and keyboard work: the view mode, arrows and Return, type-to-
//! select, disclosure triangles and column clicks, each routed to the list's or the columns'
//! operations by the focused pane's mode. Run by `Model.applyPending`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const ViewMode = @import("pane.zig").ViewMode;
const NavKey = @import("nav_key.zig").NavKey;
const Mods = @import("selection.zig").Mods;
const FileItem = @import("../core/lister.zig").FileItem;
const column_ops = @import("column_ops.zig");
const list_nav = @import("list_nav.zig");

/// The shown tab of every column-view pane has its stack (called at the start of each pass).
pub fn syncColumns(m: *Model) Allocator.Error!void {
    for (m.panes.items) |*p| if (p.view_mode == .column) try column_ops.sync(m.gpa, p.tab(), m.opts(p));
}

/// Switches the focused pane. Each tab keeps its folder (columns drilled into set it) and its
/// selection; the column stack is built when the mode turns to columns and let go when it leaves.
pub fn setViewMode(m: *Model, mode: ViewMode) Allocator.Error!void {
    const pane = m.focusedPane();
    if (pane.view_mode == mode) return;
    pane.view_mode = mode;
    const tab = pane.tab();
    switch (mode) {
        .column => try column_ops.sync(m.gpa, tab, m.opts(pane)),
        .list => {
            tab.col.truncate(m.gpa, 0);
            tab.reveal = tab.selection.leadIndex(tab.exp.items);
        },
    }
    m.typeahead.clear();
}

pub fn key(m: *Model, k: NavKey, shift: bool) Allocator.Error!void {
    const pane = m.focusedPane();
    m.typeahead.clear();
    switch (pane.view_mode) {
        .list => try list_nav.key(m.gpa, pane.tab(), m.opts(pane), k, shift),
        .column => try column_ops.key(m.gpa, pane.tab(), m.opts(pane), k, shift),
    }
}

pub fn typeSelect(m: *Model, ch: u21, time: f64) Allocator.Error!void {
    const prefix = m.typeahead.feed(ch, time);
    if (prefix.len == 0) return;
    const pane = m.focusedPane();
    _ = switch (pane.view_mode) {
        .list => try list_nav.typeSelect(m.gpa, pane.tab(), prefix),
        .column => try column_ops.typeSelect(m.gpa, pane.tab(), m.opts(pane), prefix),
    };
}

/// The rows the keyboard and Return work on in `pane`, and what is selected among them.
fn shown(pane: *Pane) struct { items: []const FileItem, sel: *const @import("selection.zig").Selection } {
    const tab = pane.tab();
    if (pane.view_mode == .column) if (tab.col.activeColumn()) |c| return .{ .items = c.items(), .sel = &c.selection };
    return .{ .items = tab.exp.items, .sel = &tab.selection };
}

/// Return: a single selected folder is opened (the tab goes there, with a history entry); files
/// open in their default apps.
pub fn openSelection(m: *Model) Allocator.Error!void {
    const s = shown(m.focusedPane());
    var folder: ?[]const u8 = null;
    var count: usize = 0;
    for (s.items) |it| {
        if (!s.sel.contains(it.path)) continue;
        count += 1;
        if (it.is_directory) folder = it.path;
    }
    if (folder) |f| {
        if (count == 1) return m.navigate(f);
    }
    for (s.items) |it| {
        if (s.sel.contains(it.path) and !it.is_directory) try m.openFile(it.path);
    }
}

/// A disclosure triangle: opens or closes `path` in the list of pane `pane_id`.
pub fn toggleExpand(m: *Model, pane_id: u32, path: []const u8) Allocator.Error!void {
    const i = m.paneIndex(pane_id) orelse return;
    const pane = &m.panes.items[i];
    const tab = pane.tab();
    try tab.setExpanded(path, !tab.exp.isExpanded(path), m.opts(pane));
}

pub fn columnClick(m: *Model, pane_id: u32, depth: u32, index: u32, mods: Mods) Allocator.Error!void {
    const i = m.paneIndex(pane_id) orelse return;
    const pane = &m.panes.items[i];
    m.typeahead.clear();
    try column_ops.click(m.gpa, pane.tab(), m.opts(pane), depth, index, mods);
}
