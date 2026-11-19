//! The panes of the window: the layout tree laid out over the area right of the sidebar, each
//! pane drawn by `pane_view`, a draggable divider between neighbours (a hairline with a wider
//! grab band, read the way nanoui's dock reads its dividers: the press latches the divider and
//! each move of the pointer along it shifts the weights), and the layout popover on top.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const pane_sizes = @import("pane_sizes.zig");
const pane_view = @import("pane_view.zig");
const layout_menu = @import("layout_menu.zig");
const toolbar_menu = @import("toolbar_menu.zig");
const style = @import("style.zig");

/// How far past each side of the hairline a press still grabs it.
const grab_slop: f32 = 4;

/// Where every pane and divider is now (window points), for a window of `size`.
pub fn frame(arena: std.mem.Allocator, m: *const Model, size: ui.Size) std.mem.Allocator.Error!pane_sizes.Frame {
    return pane_sizes.layout(arena, &m.layout, &m.sizes, style.panesBounds(size.w, size.h, m.sidebar_visible));
}

pub fn view(c: *ui.Context, m: *Model) void {
    const area = style.panesBounds(c.size.w, c.size.h, m.sidebar_visible);
    const fr = frame(c.alloc(), m, c.size) catch return;
    const root = ui.div(c).absolute().offset(area.x, area.y).size(area.w, area.h).bg(c.theme.surface);
    defer root.end();
    for (fr.panes) |pr| {
        const index = m.paneIndex(pr.id) orelse continue;
        pane_view.view(c, m, index, pr.rect, area);
    }
    for (fr.dividers) |d| divider(c, m, d, area);
    layout_menu.popover(c, m);
    toolbar_menu.popover(c, m);
}

fn divider(c: *ui.Context, m: *Model, d: pane_sizes.Divider, area: pane_sizes.Rect) void {
    const th = c.theme;
    const vertical = d.axis == .side_by_side; // a vertical line between side-by-side panes
    var r = d.rect;
    if (vertical) {
        r.x -= grab_slop;
        r.w += 2 * grab_slop;
    } else {
        r.y -= grab_slop;
        r.h += 2 * grab_slop;
    }
    ui.key(c, c.print("divider-{d}-{d}", .{ d.split, d.index }));
    const grab = ui.div(c).absolute().offset(r.x - area.x, r.y - area.y).size(r.w, r.h).center();
    defer grab.end();
    const it = grab.interaction();
    const vs = &m.view_state;
    const mine = if (vs.divider) |g| g.split == d.split and g.index == d.index else false;
    if (it.hovered or mine) c.cursor = if (vertical) .resize_left_right else .resize_up_down;
    const along = if (vertical) c.input.mouse.x else c.input.mouse.y;
    if (it.pressed and !mine and vs.divider == null) {
        vs.divider = .{ .split = d.split, .index = d.index, .last = along };
    } else if (mine) {
        if (!c.input.down) {
            vs.divider = null;
        } else if (along != vs.divider.?.last) {
            _ = pane_sizes.drag(&m.sizes, d, along - vs.divider.?.last);
            vs.divider.?.last = along;
            c.changed = true;
        }
    }
    const hot = (it.hovered and vs.divider == null) or mine;
    var line = ui.div(c).bg(if (hot) th.accent.alpha(0.55) else th.border);
    line = if (vertical) line.w(if (hot) 3 else 1).hFull() else line.h(if (hot) 3 else 1).wFull();
    line.end();
}
