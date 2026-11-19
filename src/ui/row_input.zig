//! What the pointer does to a row of the list or of a column: a click selects (cmd toggles, shift
//! extends), a double-click opens, a right-click selects the row if it isn't selected and opens
//! the context menu, pressing and moving drags the selection (to another pane's folder, a folder
//! row or the sidebar), and a folder row takes drops (from Finder or from another pane).
//! The row's own widgets (the disclosure triangle, the rename field) are the caller's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const lister = @import("../core/lister.zig");
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const style = @import("style.zig");
const context_menu = @import("context_menu.zig");
const drops = @import("drops.zig");
const rename_view = @import("rename_view.zig");

/// What a row reported, for the caller's own handling.
const Pointer = struct {
    it: ui.Interaction,
    /// This frame ends a drag that began on the row: not a click.
    released: bool,
};

/// Which row, and how a plain click would select it (the list: now; columns: queued).
const Where = union(enum) {
    list: struct { tab: *Tab, items: []const lister.FileItem, i: usize },
    column: struct { depth: usize, i: usize },
};

fn pick(c: *ui.Context, m: *Model, pane: *const Pane, w: Where) void {
    switch (w) {
        .list => |l| l.tab.selection.click(m.gpa, l.items, l.i, .{}) catch {},
        .column => |k| style.post(c, m, .{ .column_click = .{ .pane = pane.id, .depth = @intCast(k.depth), .index = @intCast(k.i), .cmd = false, .shift = false } }),
    }
}

/// Everything shared by both views: drag source, context menu, folder drop targets and the
/// highlight. Null while the row is being renamed (the field owns the pointer).
fn common(c: *ui.Context, m: *Model, pane: *const Pane, row: ui.Div, item: lister.FileItem, selected: bool, w: Where) ?Pointer {
    if (rename_view.editing(m, pane.id, item.path)) return null;
    const src = ui.dragSource(c, row.index, pane.id);
    const it = src.interaction;
    if (it.secondary_clicked) {
        style.post(c, m, .{ .focus_pane = pane.id });
        if (!selected) pick(c, m, pane, w);
        context_menu.openAt(c, m, pane.id, true);
    }
    if (src.dragging and m.view_state.file_drag == null) {
        style.post(c, m, .{ .focus_pane = pane.id });
        if (!selected) pick(c, m, pane, w);
        m.view_state.file_drag = pane.id;
    }
    if (item.is_directory) {
        drops.accept(c, m, row.index, item.path);
        if (drops.land(c, m, it.rect, item.path)) c.node(row.index).style.background = c.theme.accent.alpha(0.3);
    }
    return .{ .it = it, .released = src.released };
}

/// A row of the list view (`items` are the tab's rows, `i` this one). `toggled`: its disclosure
/// triangle was clicked.
pub fn list(c: *ui.Context, m: *Model, pane: *const Pane, tab: *Tab, items: []const lister.FileItem, i: usize, row: ui.Div, toggled: bool) void {
    const item = items[i];
    const selected = tab.selection.contains(item.path);
    const ptr = common(c, m, pane, row, item, selected, .{ .list = .{ .tab = tab, .items = items, .i = i } }) orelse return;
    const it = ptr.it;
    if (toggled) {
        c.changed = true;
        style.post(c, m, .{ .focus_pane = pane.id });
        style.post(c, m, .{ .toggle_expand = .{ .pane = pane.id, .path = item.path } });
    } else if (it.clicked and !ptr.released) {
        c.changed = true;
        style.post(c, m, .{ .focus_pane = pane.id });
        if (it.double_clicked) {
            style.post(c, m, if (item.is_directory) .{ .open = item.path } else .{ .open_file = item.path });
        } else {
            tab.selection.click(m.gpa, items, i, .{ .cmd = c.input.cmd, .shift = c.input.shift }) catch {};
        }
    }
}

/// A row of column `depth` of the column view.
pub fn column(c: *ui.Context, m: *Model, pane: *const Pane, depth: usize, items: []const lister.FileItem, i: usize, selected: bool, row: ui.Div) void {
    const item = items[i];
    const ptr = common(c, m, pane, row, item, selected, .{ .column = .{ .depth = depth, .i = i } }) orelse return;
    const it = ptr.it;
    if (it.clicked and !ptr.released) {
        c.changed = true;
        style.post(c, m, .{ .focus_pane = pane.id });
        if (it.double_clicked) {
            style.post(c, m, if (item.is_directory) .{ .open = item.path } else .{ .open_file = item.path });
        } else {
            style.post(c, m, .{ .column_click = .{
                .pane = pane.id,
                .depth = @intCast(depth),
                .index = @intCast(i),
                .cmd = c.input.cmd,
                .shift = c.input.shift,
            } });
        }
    }
}
