//! A pane's tab strip: a chip per tab (folder icon, name, a close button while hovered or shown),
//! the "+" button, and at the right the split button (Option-click: stacked) and, in the first
//! pane, the layout button. Pressing a chip shows its tab; pressing and moving along the strip
//! drags it to another slot (live: the chips reorder as the pointer crosses them).
//!
//! nanoui has no cross-window drag payload to lean on here, and none is needed: the strip reads
//! the pointer itself (`c.input.mouse`) while a chip is held, as nanoui's own dock tabs do, and
//! queues `move_tab` with the slot under the pointer. `slotAt` and `tabWidth` are pure so that
//! the geometry is tested without a window.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const Pane = @import("pane.zig").Pane;
const style = @import("style.zig");
const layout_menu = @import("layout_menu.zig");

pub const pad: f32 = 8;
const gap: f32 = 2;
const min_tab_w: f32 = 72;
const max_tab_w: f32 = 200;
/// Room kept at the right for the buttons: "+" after the chips, split (and layout).
const buttons_w: f32 = 3 * 30 + 8;
/// How far the pointer must move sideways before a pressed chip drags.
const drag_threshold: f32 = 4;

/// The width of every chip when `n` of them share a strip `strip_w` wide.
pub fn tabWidth(strip_w: f32, n: usize) f32 {
    const avail = strip_w - 2 * pad - buttons_w;
    return std.math.clamp(avail / @as(f32, @floatFromInt(@max(n, 1))), min_tab_w, max_tab_w);
}

/// The slot (0..n-1) under pointer x for a strip starting at `strip_x`.
pub fn slotAt(strip_x: f32, strip_w: f32, n: usize, x: f32) usize {
    if (n == 0) return 0;
    const pitch = tabWidth(strip_w, n) + gap;
    const rel = @floor((x - strip_x - pad) / pitch);
    return @intFromFloat(std.math.clamp(rel, 0, @as(f32, @floatFromInt(n - 1))));
}

/// Draws pane `index`'s strip, at window x `strip_x`, `strip_w` wide.
pub fn view(c: *ui.Context, m: *Model, index: usize, strip_x: f32, strip_w: f32) void {
    const pane = &m.panes.items[index];
    const th = c.theme;
    if (!c.input.down) m.view_state.tab_drag = null;
    const bar = ui.div(c).row().wFull().h(style.tab_strip_height).px(pad).gap(gap).itemsCenter().bg(th.background.mix(th.surface, 0.5));
    defer bar.end();
    // The first pane at the window's edge (sidebar hidden): room for the traffic lights, and the
    // button that brings the sidebar back.
    const lead = index == 0 and !m.sidebar_visible;
    const sx = if (lead) strip_x + style.lead_extra else strip_x;
    const sw = if (lead) strip_w - style.lead_extra else strip_w;
    if (lead) {
        ui.key(c, "lead-gap");
        const gap_box = ui.div(c).w(style.lead_gap).h(1);
        gap_box.end();
        if (style.iconButton(c, "sidebar-show", "sidebar.left", true, false)) style.post(c, m, .{ .run_command = .view_sidebar });
    }
    const tw = tabWidth(sw, pane.tabs.items.len);
    for (pane.tabs.items, 0..) |*t, i| {
        const ref: model_mod.TabRef = .{ .pane = pane.id, .tab = t.id };
        ui.keyInt(c, t.id);
        const active = i == pane.active;
        var chip = ui.div(c).row().w(tw).h(26).px(8).gap(6).itemsCenter().rounded(7).control();
        chip = if (active) chip.bg(th.text.alpha(0.09)) else chip.hover(th.text.alpha(0.05));
        defer chip.end();
        const it = chip.interaction();
        ui.icon(c, "folder.fill", .{ .size = 13, .frame = 15, .color = if (active) th.accent else th.muted });
        {
            const label = ui.div(c).row().grow().minW(0).clip();
            defer label.end();
            ui.text(c, t.title(), .{ .size = 12.5, .weight = if (active) .medium else .regular, .color = if (active) th.text else th.muted, .truncate = .ellipsis });
        }
        if (active or it.hovered) {
            ui.key(c, "close");
            const x = ui.div(c).w(16).h(16).center().rounded(4).control().hover(th.text.alpha(0.12));
            defer x.end();
            ui.icon(c, "xmark", .{ .size = 9, .weight = .bold, .color = th.muted });
            if (x.clicked()) style.post(c, m, .{ .close_tab = ref });
        }
        press(c, m, it, ref, i, sx, sw, pane.tabs.items.len);
    }
    if (style.iconButton(c, "new-tab", "plus", true, false)) {
        style.post(c, m, .{ .focus_pane = pane.id });
        style.post(c, m, .new_tab);
    }
    ui.spacer(c);
    if (index == 0) layout_menu.button(c, m);
    if (style.iconButton(c, "split", "rectangle.split.2x1", true, false)) {
        style.post(c, m, .{ .focus_pane = pane.id });
        style.post(c, m, .{ .split = if (c.input.alt) .stacked else .side_by_side });
    }
}

/// A chip pressed: its tab is shown at once; moving along the strip drags it.
fn press(c: *ui.Context, m: *Model, it: ui.Interaction, ref: model_mod.TabRef, index: usize, strip_x: f32, strip_w: f32, n: usize) void {
    if (!it.pressed) return;
    const vs = &m.view_state;
    const mine = if (vs.tab_drag) |d| d.tab.pane == ref.pane and d.tab.tab == ref.tab else false;
    if (!mine) {
        vs.tab_drag = .{ .tab = ref, .start_x = c.input.mouse.x, .moving = false };
        style.post(c, m, .{ .select_tab = ref });
        return;
    }
    const d = &vs.tab_drag.?;
    if (!d.moving and @abs(c.input.mouse.x - d.start_x) >= drag_threshold) d.moving = true;
    if (!d.moving) return;
    const to = slotAt(strip_x, strip_w, n, c.input.mouse.x);
    if (to != index) style.post(c, m, .{ .move_tab = .{ .tab = ref, .to = @intCast(to) } });
}

test "tabs share the strip, within limits; the slot under the pointer" {
    try std.testing.expectEqual(max_tab_w, tabWidth(900, 1));
    try std.testing.expectEqual(min_tab_w, tabWidth(300, 6));
    const w = tabWidth(600, 3);
    try std.testing.expect(w > min_tab_w and w < max_tab_w);
    try std.testing.expectEqual(@as(usize, 0), slotAt(100, 600, 3, 90));
    try std.testing.expectEqual(@as(usize, 0), slotAt(100, 600, 3, 100 + pad + 5));
    try std.testing.expectEqual(@as(usize, 1), slotAt(100, 600, 3, 100 + pad + w + gap + 1));
    try std.testing.expectEqual(@as(usize, 2), slotAt(100, 600, 3, 5000));
}
