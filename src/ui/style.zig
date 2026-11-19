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

/// Where the panes go in the window: everything right of the sidebar.
pub fn panesBounds(w: f32, h: f32) pane_sizes.Rect {
    return .{ .x = sidebar_width, .y = 0, .w = @max(0, w - sidebar_width), .h = h };
}

/// Which of the list's columns a pane this wide has room for (Name takes the rest).
pub const Columns = struct { kind: bool, date: bool };

pub fn columnsFor(pane_w: f32) Columns {
    return .{ .kind = pane_w >= 430, .date = pane_w >= 620 };
}
