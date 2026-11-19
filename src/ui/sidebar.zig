//! The sidebar view: Home, then Favorites, Pinned and Locations, on a translucent pane.
//! A click queues navigation of the focused pane (the model applies it next pass).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const style = @import("style.zig");
const drops = @import("drops.zig");

pub fn view(c: *ui.Context, m: *Model) void {
    const th = c.theme;
    // Painted over the window; the pane's own tint lets the window show through.
    const pane = ui.div(c).absolute().offset(0, 0).column().w(style.sidebar_width).h(c.size.h).pt(style.tab_strip_height + 10).pb(8).px(10)
        .glass(.{ .style = .sidebar, .tint = th.background.alpha(0.55) });
    defer pane.end();
    const here = m.sidebar.highlighted(m.focusedTab().path());
    const body = ui.div(c).column().wFull().grow().scrollY().gap(1).scrollBarIdle(2.0);
    defer body.end();
    for (m.sidebar.sections, 0..) |sec, si| {
        if (sec.kind != .home) sectionHeader(c, sec.title(), si);
        for (sec.rows.items, 0..) |row, ri| {
            const selected = if (here) |h| h.section == si and h.row == ri else false;
            ui.key(c, c.print("sidebar-{d}-{d}", .{ si, ri }));
            if (rowView(c, m, row.path, row.icon, row.title, selected)) {
                // A click goes to the focused pane; Cmd-click opens a new tab there.
                if (c.input.cmd) style.post(c, m, .{ .open_in_new_tab = row.path }) else style.post(c, m, .{ .open = row.path });
            }
        }
    }
}

fn sectionHeader(c: *ui.Context, title: []const u8, si: usize) void {
    ui.key(c, c.print("sidebar-head-{d}", .{si}));
    const h = ui.div(c).row().wFull().px(8).pt(14).pb(4);
    defer h.end();
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
}

/// A sidebar row: a click goes there; files dropped on it (from Finder, or dragged from a pane)
/// go into its folder.
fn rowView(c: *ui.Context, m: *Model, path: []const u8, symbol: []const u8, title: []const u8, selected: bool) bool {
    const th = c.theme;
    var r = ui.div(c).row().wFull().h(26).px(8).gap(8).itemsCenter().rounded(6).control();
    r = if (selected) r.bg(th.text.alpha(0.10)) else r.hover(th.text.alpha(0.06));
    defer r.end();
    ui.icon(c, symbol, .{ .size = 14, .frame = 16, .color = th.accent });
    ui.text(c, title, .{ .size = 13, .weight = if (selected) .medium else .regular, .truncate = .ellipsis });
    const it = r.interaction();
    drops.accept(c, m, r.index, path);
    if (drops.land(c, m, it.rect, path)) c.node(r.index).style.background = th.accent.alpha(0.3);
    if (it.clicked) c.changed = true;
    return it.clicked;
}
