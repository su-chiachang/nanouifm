//! The layout popover (the Swift app's View > Layout): the 12 presets, each with a small picture
//! of its panes, the current one ticked. The button sits in the first pane's tab strip and the
//! popover hangs from it; a row applies the preset to the panes (see `layout_ops.applyPreset`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const pane_sizes = @import("pane_sizes.zig");
const style = @import("style.zig");

const LayoutPreset = model_mod.LayoutPreset;
const Tree = pane_sizes.Tree;

pub const popover_width: f32 = 232;

pub fn button(c: *ui.Context, m: *Model) void {
    const b = style.iconButtonAt(c, "layout", "rectangle.split.2x2", true, m.view_state.layout_menu_open);
    if (b.rect) |r| m.view_state.layout_anchor = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    if (b.clicked) m.view_state.layout_menu_open = !m.view_state.layout_menu_open;
}

/// The popover, drawn over everything while it is open (called once, last, by the panes view).
pub fn popover(c: *ui.Context, m: *Model) void {
    const vs = &m.view_state;
    const anchor: ?ui.Rect = if (vs.layout_anchor) |a| .{ .x = a.x, .y = a.y, .w = a.w, .h = a.h } else null;
    const p = kit.popover(c, "layout-menu", &vs.layout_menu_open, anchor, .{
        .placement = .bottom_end,
        .width = popover_width,
        .padding = 6,
    }) orelse return;
    defer p.end();
    const th = c.theme;
    const current: ?LayoutPreset = LayoutPreset.matching(c.alloc(), &m.layout) catch null;
    {
        const head = ui.div(c).wFull().px(8).pt(4).pb(6);
        defer head.end();
        ui.text(c, "Layout", .{ .size = 11, .weight = .semibold, .color = th.muted });
    }
    for (LayoutPreset.all) |preset| {
        ui.key(c, preset.rawName());
        const row = ui.div(c).row().wFull().h(30).px(8).gap(10).itemsCenter().rounded(6).control().hover(th.text.alpha(0.07));
        defer row.end();
        const is_current = current != null and current.? == preset;
        glyphBox(c, preset, if (is_current) th.accent else th.muted);
        ui.text(c, preset.title(), .{ .size = 13, .weight = if (is_current) .medium else .regular });
        ui.spacer(c);
        if (is_current) ui.icon(c, "checkmark", .{ .size = 11, .weight = .semibold, .color = th.accent });
        if (row.clicked()) {
            vs.layout_menu_open = false;
            style.post(c, m, .{ .apply_preset = preset });
        }
    }
}

/// The preset's panes as outlined rectangles: its shape tree drawn in a small box.
fn glyphBox(c: *ui.Context, preset: LayoutPreset, color: ui.Color) void {
    const shape = preset.shape(c.alloc()) catch return; // frame memory: nothing to free
    const box = ui.div(c).w(26).h(18).row();
    defer box.end();
    glyph(c, &shape, null, color);
}

fn glyph(c: *ui.Context, node: *const Tree, parent: ?pane_sizes.SplitAxis, color: ui.Color) void {
    var d = ui.div(c).grow();
    d = if (parent) |a| (if (a == .side_by_side) d.hFull() else d.wFull()) else d.sizeFull();
    switch (node.*) {
        .leaf => {
            const leaf = d.border(color).borderW(1).rounded(2);
            defer leaf.end();
        },
        .split => |s| {
            const inner = (if (s.axis == .side_by_side) d.row() else d.column()).gap(1.5);
            defer inner.end();
            for (s.children) |*child| glyph(c, child, s.axis, color);
        },
    }
}
