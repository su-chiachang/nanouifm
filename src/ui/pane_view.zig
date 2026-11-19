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
const toolbar = @import("toolbar.zig");
const list_pane = @import("list_pane.zig");
const column_view = @import("column_view.zig");
const path_bar = @import("path_bar.zig");
const drops = @import("drops.zig");
const file_target = @import("file_target.zig");
const inspector_view = @import("inspector_view.zig");
const inspector_info = @import("inspector_info.zig");

pub fn view(c: *ui.Context, m: *Model, index: usize, rect: pane_sizes.Rect, area: pane_sizes.Rect) void {
    const pane = &m.panes.items[index];
    const th = c.theme;
    const focused = index == m.focused;
    if (!focused and c.input.pressed and !m.view_state.layout_menu_open and !m.view_state.ctx_menu.open and !m.view_state.toolbar_menu.open and !m.view_state.palette.open and rect.contains(c.input.mouse.x, c.input.mouse.y))
        style.post(c, m, .{ .focus_pane = pane.id });

    ui.keyInt(c, pane.id);
    const box = ui.div(c).absolute().offset(rect.x - area.x, rect.y - area.y).size(rect.w, rect.h).column().bg(th.surface).clip();
    defer box.end();
    tab_strip.view(c, m, index, rect.x, rect.w);
    ui.divider(c);
    toolbar.view(c, m, pane, rect.w);
    ui.divider(c);
    switch (pane.view_mode) {
        .list => listBody(c, m, pane, focused, rect.w),
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

/// The list, with the inspector beside it when the pane has it on. The wrapper is there either
/// way, so the list keeps its scroll position (and its ids) when the inspector comes and goes.
fn listBody(c: *ui.Context, m: *Model, pane: *Pane, focused: bool, w: f32) void {
    const iw: f32 = if (pane.inspector) inspector_info.panelWidth(w) else 0;
    ui.key(c, "list-body");
    const row = ui.div(c).row().wFull().grow().minW(0);
    defer row.end();
    {
        ui.key(c, "list-col");
        const left = ui.div(c).column().grow().minW(0).hFull();
        defer left.end();
        list_pane.view(c, m, pane, focused, w - iw);
    }
    if (pane.inspector) inspector_view.view(c, m, pane, iw);
}
