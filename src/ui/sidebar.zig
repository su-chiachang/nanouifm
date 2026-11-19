//! The sidebar view: Home, then Favorites, Pinned and Locations (the mounted volumes), on a
//! translucent pane, with the button that hides it (Ctrl+Cmd+S; hidden, the first pane's tab strip
//! has the button that brings it back). A click queues navigation of the focused pane (Cmd-click:
//! a new tab); a right-click opens the context menu (`sidebar_menu.zig`); a volume has an eject
//! button; Favorites and Pinned rows drag to reorder and files dropped on a row go into its folder
//! (`sidebar_dnd.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const sidebar_model = @import("sidebar_model.zig");
const style = @import("style.zig");
const drops = @import("drops.zig");
const drag_kind = @import("drag_kind.zig");
const dnd = @import("sidebar_dnd.zig");
const sidebar_menu = @import("sidebar_menu.zig");

pub fn view(c: *ui.Context, m: *Model) void {
    if (!m.sidebar_visible) return;
    {
        const th = c.theme;
        // Painted over the window; the pane's own tint lets the window show through.
        const pane = ui.div(c).absolute().offset(0, 0).column().w(style.sidebar_width).h(c.size.h).pt(style.tab_strip_height + 10).pb(8).px(10)
            .glass(.{ .style = .sidebar, .tint = th.background.alpha(0.55) });
        defer pane.end();
        const here = m.sidebar.highlighted(m.focusedTab().path());
        const body = ui.div(c).column().wFull().grow().scrollY().gap(1).scrollBarIdle(2.0);
        defer body.end();
        for (m.sidebar.sections, 0..) |sec, si| {
            if (sec.kind != .home) sectionHeader(c, m, sec.title(), si);
            for (sec.rows.items, 0..) |row, ri| {
                const selected = if (here) |h| h.section == si and h.row == ri else false;
                ui.key(c, c.print("sidebar-{d}-{d}", .{ si, ri }));
                if (rowView(c, m, si, ri, row, selected)) {
                    // A click goes to the focused pane; Cmd-click opens a new tab there.
                    if (c.input.cmd) style.post(c, m, .{ .open_in_new_tab = row.path }) else style.post(c, m, .{ .open = row.path });
                }
            }
        }
    }
    toggle(c, m); // over the pane, in the window's corner
}

/// The hide button, at the top right, level with the traffic lights.
fn toggle(c: *ui.Context, m: *Model) void {
    ui.key(c, "sidebar-toggle-slot");
    const slot = ui.div(c).absolute().offset(style.sidebar_width - 42, 4);
    defer slot.end();
    if (style.iconButton(c, "sidebar-hide", "sidebar.left", true, false)) style.post(c, m, .{ .run_command = .view_sidebar });
}

fn sectionHeader(c: *ui.Context, m: *Model, title: []const u8, si: usize) void {
    ui.key(c, c.print("sidebar-head-{d}", .{si}));
    const h = ui.div(c).row().wFull().px(8).pt(14).pb(4).rounded(6);
    defer h.end();
    const over = dnd.onHeader(c, m, si, h.interaction().rect);
    if (over == .header) c.node(h.index).style.background = c.theme.accent.alpha(0.22);
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = if (over == .header) c.theme.accent else c.theme.muted });
}

/// A sidebar row: a click goes there; files dropped on it (from Finder, or dragged from a pane)
/// go into its folder; a favorite or pin drags to reorder; a volume has an eject button.
fn rowView(c: *ui.Context, m: *Model, si: usize, ri: usize, row: sidebar_model.Row, selected: bool) bool {
    const th = c.theme;
    var r = ui.div(c).row().wFull().h(26).px(8).gap(8).itemsCenter().rounded(6).control();
    r = if (selected) r.bg(th.text.alpha(0.10)) else r.hover(th.text.alpha(0.06));
    defer r.end();
    ui.icon(c, row.icon, .{ .size = 14, .frame = 16, .color = th.accent });
    ui.text(c, row.title, .{ .size = 13, .weight = if (selected) .medium else .regular, .truncate = .ellipsis });
    ui.spacer(c);
    const ejected = row.ejectable and ejectButton(c, m, row.path);
    const it = if (row.id != null) ui.dragSource(c, r.index, drag_kind.entry(si, ri)).interaction else r.interaction();
    drops.accept(c, m, r.index, row.path);
    switch (dnd.onRow(c, m, si, ri, it.rect, row.path)) {
        .files => c.node(r.index).style.background = th.accent.alpha(0.3),
        .before => marker(c, 0),
        .after => marker(c, 24),
        .header, .none => {},
    }
    if (it.secondary_clicked) sidebar_menu.openAt(c, m, si, ri);
    if (it.clicked) c.changed = true;
    return it.clicked and !ejected;
}

/// A line where a dragged entry would land: `y` points below the row's top.
fn marker(c: *ui.Context, y: f32) void {
    ui.key(c, "drop-marker");
    const line = ui.div(c).absolute().offset(0, y).h(2).wFull().rounded(1).bg(c.theme.accent);
    line.end();
}

/// The eject button at the right of a volume's row: queues the eject. True when it was clicked.
fn ejectButton(c: *ui.Context, m: *Model, path: []const u8) bool {
    const th = c.theme;
    ui.key(c, "eject");
    const b = ui.div(c).w(18).h(18).center().rounded(9).control().hover(th.text.alpha(0.14));
    defer b.end();
    ui.icon(c, "eject.fill", .{ .size = 10, .color = th.muted });
    if (!b.clicked()) return false;
    style.post(c, m, .{ .eject = path });
    return true;
}
