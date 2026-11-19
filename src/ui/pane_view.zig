//! One pane drawn: tab strip, toolbar, the list, the path bar, and (with several panes) the
//! accent outline on the focused one. The pane sits at `rect` (window points) inside the panes
//! area `area`; a press anywhere in it focuses it, before the press's own action is queued.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const pane_sizes = @import("pane_sizes.zig");
const style = @import("style.zig");
const tab_strip = @import("tab_strip.zig");
const list_pane = @import("list_pane.zig");
const column_view = @import("column_view.zig");
const path_bar = @import("path_bar.zig");
const drops = @import("drops.zig");
const file_target = @import("file_target.zig");

pub fn view(c: *ui.Context, m: *Model, index: usize, rect: pane_sizes.Rect, area: pane_sizes.Rect) void {
    const pane = &m.panes.items[index];
    const th = c.theme;
    const focused = index == m.focused;
    if (!focused and c.input.pressed and !m.view_state.layout_menu_open and !m.view_state.ctx_menu.open and rect.contains(c.input.mouse.x, c.input.mouse.y))
        style.post(c, m, .{ .focus_pane = pane.id });

    ui.keyInt(c, pane.id);
    const box = ui.div(c).absolute().offset(rect.x - area.x, rect.y - area.y).size(rect.w, rect.h).column().bg(th.surface).clip();
    defer box.end();
    tab_strip.view(c, m, index, rect.x, rect.w);
    ui.divider(c);
    toolbar(c, m, pane);
    ui.divider(c);
    switch (pane.view_mode) {
        .list => list_pane.view(c, m, pane, focused, rect.w),
        .column => column_view.view(c, m, pane, focused),
    }
    ui.divider(c);
    path_bar.view(c, m, pane, rect.w);
    // Files dropped on the pane (from Finder, or dragged from another pane) land in its folder;
    // a folder row inside it was asked first and took its own.
    const dest = file_target.shown(pane).folder;
    const here: ui.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    const over = drops.land(c, m, here, dest);
    drops.accept(c, m, box.index, dest);
    if (over and m.view_state.file_drag != pane.id) { // (a pane's own rows dropped on itself: no-op)
        ui.key(c, "drop-outline");
        const o = ui.div(c).absolute().offset(0, 0).size(rect.w, rect.h).bg(th.accent.alpha(0.08)).border(th.accent).borderW(2);
        o.end();
    }

    if (focused and m.panes.items.len > 1) {
        ui.key(c, "focus-outline");
        const o = ui.div(c).absolute().offset(0, 0).size(rect.w, rect.h).border(th.accent).borderW(2);
        o.end();
    }
}

fn toolbar(c: *ui.Context, m: *Model, pane: *Pane) void {
    const tab = pane.tab();
    const bar = ui.div(c).row().wFull().h(style.toolbar_height).px(style.pad).gap(4).itemsCenter();
    defer bar.end();
    if (style.iconButton(c, "back", "chevron.left", tab.canBack(), false)) act(c, m, pane, .back);
    if (style.iconButton(c, "forward", "chevron.right", tab.canForward(), false)) act(c, m, pane, .forward);
    if (style.iconButton(c, "up", "chevron.up", std.fs.path.dirname(tab.path()) != null, false)) act(c, m, pane, .up);
    {
        const t = ui.div(c).row().grow().minW(0).px(8).clip();
        defer t.end();
        ui.text(c, tab.title(), .{ .size = 14, .weight = .semibold, .truncate = .ellipsis });
    }
    if (style.iconButton(c, "mode-list", "list.bullet", true, pane.view_mode == .list)) act(c, m, pane, .{ .set_view_mode = .list });
    if (style.iconButton(c, "mode-column", "rectangle.split.3x1", true, pane.view_mode == .column)) act(c, m, pane, .{ .set_view_mode = .column });
    if (style.iconButton(c, "hidden", if (m.show_hidden) "eye" else "eye.slash", true, m.show_hidden)) act(c, m, pane, .toggle_hidden);
}

/// Queues `a` for this pane: it gets the focus first.
fn act(c: *ui.Context, m: *Model, pane: *const Pane, a: @import("model.zig").Action) void {
    style.post(c, m, .{ .focus_pane = pane.id });
    style.post(c, m, a);
}
