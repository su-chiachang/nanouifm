//! Sizes and the few small widgets the views share.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const sidebar_width: f32 = 212;
pub const toolbar_height: f32 = 44;
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
    const th = c.theme;
    ui.key(c, key);
    var b = ui.div(c).w(30).h(26).center().rounded(6).control();
    b = if (active) b.bg(th.accent.alpha(0.18)) else if (enabled) b.hover(th.surface_hover) else b;
    defer b.end();
    ui.icon(c, symbol, .{ .size = 14, .weight = .medium, .color = if (!enabled) th.muted.alpha(0.5) else if (active) th.accent else th.text });
    const it = b.interaction();
    if (enabled and it.clicked) {
        c.changed = true;
        return true;
    }
    return false;
}
