//! Sizes and the few small widgets the views share.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const pane_sizes = @import("pane_sizes.zig");

pub const sidebar_width: f32 = 212;
pub const tab_strip_height: f32 = 34;
pub const toolbar_height: f32 = 38;
pub const header_height: f32 = 26;
pub const row_height: f32 = 24;
pub const path_bar_height: f32 = 28;
pub const kind_width: f32 = 132;
pub const size_width: f32 = 84;
pub const date_width: f32 = 184;
pub const pad: f32 = 12;

/// A small square button with an SF Symbol. `enabled` false greys it and ignores clicks;
/// `active` marks a toggle that is on. Returns whether it was clicked.
pub fn iconButton(c: *ui.Context, key: []const u8, symbol: []const u8, enabled: bool, active: bool) bool {
    return iconButtonAt(c, key, symbol, enabled, active).clicked;
}

pub const Pressed = struct { clicked: bool, rect: ?ui.Rect };

/// `iconButton`, and where the button is (for a popover to hang from).
pub fn iconButtonAt(c: *ui.Context, key: []const u8, symbol: []const u8, enabled: bool, active: bool) Pressed {
    const th = c.theme;
    ui.key(c, key);
    var b = ui.div(c).w(30).h(26).center().rounded(6).control();
    b = if (active) b.bg(th.accent.alpha(0.18)) else if (enabled) b.hover(th.surface_hover) else b;
    defer b.end();
    ui.icon(c, symbol, .{ .size = 14, .weight = .medium, .color = if (!enabled) th.muted.alpha(0.5) else if (active) th.accent else th.text });
    const it = b.interaction();
    const clicked = enabled and it.clicked;
    if (clicked) c.changed = true;
    return .{ .clicked = clicked, .rect = it.rect };
}

/// Queues `a` on the model and asks for another pass, so it shows in this frame.
pub fn post(c: *ui.Context, m: *model.Model, a: model.Action) void {
    m.queue(a) catch return;
    c.changed = true;
}

/// While the sidebar is hidden the first pane's tab strip starts at the window's edge: it keeps
/// `lead_gap` free for the traffic lights, then the sidebar toggle (30 wide), then the chips.
pub const lead_gap: f32 = 78;
/// What that takes beyond the strip's own padding (the toggle, and the row's gaps).
pub const lead_extra: f32 = lead_gap + 30 + 4;

/// Where the panes go in the window: everything right of the sidebar (all of it while the sidebar
/// is hidden).
pub fn panesBounds(w: f32, h: f32, sidebar_visible: bool) pane_sizes.Rect {
    const left = if (sidebar_visible) sidebar_width else 0;
    return .{ .x = left, .y = 0, .w = @max(0, w - left), .h = h };
}

/// Which of the list's columns a pane this wide has room for (Name takes the rest).
pub const Columns = struct { kind: bool, date: bool };

pub fn columnsFor(pane_w: f32) Columns {
    return .{ .kind = pane_w >= 430, .date = pane_w >= 620 };
}

/// Where a list at `id` (the id `c.peekId(null)` gave just before `ui.list`) should scroll to
/// bring row `row` into sight, or null when it already is. `edge` is the list's padding above
/// and below its rows.
pub fn revealOffset(c: *ui.Context, id: u64, row: usize, row_h: f32, edge: f32) ?f32 {
    const view_h = if (c.rects.get(id)) |r| r.h else c.size.h;
    const cur = ui.scrollOffset(c, id, .y);
    const top = edge + @as(f32, @floatFromInt(row)) * row_h;
    const bottom = top + row_h + edge;
    if (top - edge < cur) return @max(0, top - edge);
    if (bottom > cur + view_h) return bottom - view_h;
    return null;
}
