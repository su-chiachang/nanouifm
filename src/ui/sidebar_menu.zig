//! The sidebar's context menu (Swift's `SidebarViewController.menu(forRow:)`): Open, Open in New
//! Tab, Open in Split, Reveal in Finder, then Remove from Sidebar for a favorite or pin and Eject
//! for a volume that can be. Drawn with nanoui's popover at the pointer, rows as the other
//! context menus draw them (`context_menu.rows`); each choice queues an `Action`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const context_menu = @import("context_menu.zig");
const sidebar_model = @import("sidebar_model.zig");
const style = @import("style.zig");

pub const State = struct {
    open: bool = false,
    /// Where the pointer was, in window points.
    x: f32 = 0,
    y: f32 = 0,
    /// The row it belongs to.
    section: u8 = 0,
    row: u32 = 0,
};

pub fn openAt(c: *ui.Context, m: *Model, section: usize, row: usize) void {
    m.view_state.sidebar_menu = .{ .open = true, .x = c.input.mouse.x, .y = c.input.mouse.y, .section = @intCast(section), .row = @intCast(row) };
    c.changed = true;
}

const Choice = enum { open, new_tab, split, reveal, remove, eject };

const Entry = struct { choice: ?Choice, item: kit.MenuItem };

/// The menu's lines for `row`: the entries, in order (frame memory).
pub fn lines(c: *ui.Context, row: sidebar_model.Row) []const Entry {
    var out: std.ArrayList(Entry) = .empty;
    const sep: Entry = .{ .choice = null, .item = .{ .separator = true } };
    out.append(c.alloc(), .{ .choice = .open, .item = .{ .label = "Open", .icon = "folder" } }) catch {};
    out.append(c.alloc(), .{ .choice = .new_tab, .item = .{ .label = "Open in New Tab", .icon = "plus.rectangle.on.rectangle" } }) catch {};
    out.append(c.alloc(), .{ .choice = .split, .item = .{ .label = "Open in Split", .icon = "rectangle.split.2x1" } }) catch {};
    out.append(c.alloc(), .{ .choice = .reveal, .item = .{ .label = "Reveal in Finder", .icon = "magnifyingglass" } }) catch {};
    if (row.id != null) {
        out.append(c.alloc(), sep) catch {};
        out.append(c.alloc(), .{ .choice = .remove, .item = .{ .label = "Remove from Sidebar", .icon = "minus.circle", .danger = true } }) catch {};
    }
    if (row.ejectable) {
        out.append(c.alloc(), sep) catch {};
        out.append(c.alloc(), .{ .choice = .eject, .item = .{ .label = "Eject", .icon = "eject" } }) catch {};
    }
    return out.items;
}

/// The menu, drawn over everything while it is open (called once, last).
pub fn view(c: *ui.Context, m: *Model) void {
    const st = &m.view_state.sidebar_menu;
    if (!st.open) return;
    if (st.section >= m.sidebar.sections.len or st.row >= m.sidebar.sections[st.section].rows.items.len) {
        st.open = false; // the row went away
        return;
    }
    const row = m.sidebar.sections[st.section].rows.items[st.row];
    const entries = lines(c, row);
    const items = c.alloc().alloc(kit.MenuItem, entries.len) catch return;
    for (entries, items) |e, *it| it.* = e.item;
    const anchor: ui.Rect = .{ .x = st.x, .y = st.y - 6, .w = 0, .h = 0 };
    const p = kit.popover(c, "sidebar-menu", &st.open, anchor, .{ .placement = .bottom_start, .width = 224, .padding = 5 }) orelse return;
    defer p.end();
    const chosen = context_menu.rows(c, items) orelse return;
    st.open = false;
    c.changed = true;
    const choice = entries[chosen].choice orelse return;
    switch (choice) {
        .open => style.post(c, m, .{ .open = row.path }),
        .new_tab => style.post(c, m, .{ .open_in_new_tab = row.path }),
        .split => style.post(c, m, .{ .open_in_split = row.path }),
        .reveal => if (m.hooks.reveal) |f| f(&.{row.path}),
        .remove => if (row.id) |id| style.post(c, m, .{ .sidebar_remove = id }),
        .eject => style.post(c, m, .{ .eject = row.path }),
    }
}
